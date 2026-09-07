// The leaf access providers: what each of them does on a station with no
// database, and how the device-local inactivity timeout is read.
//
// The "no database" path is not an edge case here. `databaseProvider` yields
// null both during the boot window before the connection opens and for a
// station commissioned with no Postgres at all, so every one of these
// providers has to resolve rather than throw when it is handed null.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/routes.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// A container whose database is explicitly absent.
ProviderContainer _noDatabaseContainer() {
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
  });

  group('with no database', () {
    test('accessRepositoryProvider resolves to null rather than throwing',
        () async {
      final container = _noDatabaseContainer();
      expect(await container.read(accessRepositoryProvider.future), isNull);
    });

    test('authProviderProvider resolves to null', () async {
      final container = _noDatabaseContainer();
      expect(await container.read(authProviderProvider.future), isNull);
    });

    test('auditSinkProvider is a NullAuditSink', () async {
      final container = _noDatabaseContainer();
      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isA<NullAuditSink>());
    });

    test('the NullAuditSink accepts a row without throwing', () async {
      final container = _noDatabaseContainer();
      final sink = await container.read(auditSinkProvider.future);
      await expectLater(
        sink.record(AuditRecord.login(
          who: 'jon',
          station: 'panel-1',
          roleName: kOperatorRoleName,
          actionId: newActionId(),
        )),
        completes,
      );
    });

    test(
        'firstUserWindowOpenProvider is false — an unreachable database must '
        'not look like an open commissioning window', () async {
      final container = _noDatabaseContainer();
      expect(await container.read(firstUserWindowOpenProvider.future), isFalse);
    });

    test('inactivityTimeoutProvider still resolves', () async {
      final container = _noDatabaseContainer();
      expect(
        await container.read(inactivityTimeoutProvider.future),
        kDefaultInactivityTimeout,
      );
    });
  });

  group('stationNameProvider', () {
    test('is a non-empty hostname', () {
      final container = _noDatabaseContainer();
      expect(container.read(stationNameProvider), isNotEmpty);
    });
  });

  group('inactivityTimeoutProvider', () {
    test('defaults to 15 minutes with no stored preference', () async {
      final container = _noDatabaseContainer();
      expect(
        await container.read(inactivityTimeoutProvider.future),
        const Duration(minutes: 15),
      );
    });

    test('honours a stored value', () async {
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setInt(kAccessInactivityMinutesPrefKey, 45);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        const Duration(minutes: 45),
      );
    });

    test('clamps an absurdly large value to the eight-hour ceiling', () async {
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setInt(kAccessInactivityMinutesPrefKey, 100000);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        kMaxInactivityTimeout,
      );
    });

    test('clamps zero up to the one-minute floor', () async {
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setInt(kAccessInactivityMinutesPrefKey, 0);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        kMinInactivityTimeout,
      );
    });

    test('the disable flag answers null — no expiry at all', () async {
      // The panel-PC case: a station that lives signed in as its area
      // account. Explicitly flagged, never inferred from a zero — the
      // zero-clamp pins below are what keep a hand-edited store from
      // accidentally minting immortal sessions.
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setBool(kAccessInactivityDisabledPrefKey, true);
      expect(await container.read(inactivityTimeoutProvider.future), isNull);
    });

    test('the disable flag off leaves the minutes in force', () async {
      final container = _noDatabaseContainer();
      final prefs = container.read(localPreferencesProvider);
      await prefs.setBool(kAccessInactivityDisabledPrefKey, false);
      await prefs.setInt(kAccessInactivityMinutesPrefKey, 45);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        const Duration(minutes: 45),
      );
    });

    test('clamps a negative value up to the one-minute floor', () async {
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setInt(kAccessInactivityMinutesPrefKey, -5);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        kMinInactivityTimeout,
      );
    });

    test('reads the device-local store, not the shared one', () async {
      // The shared, database-backed `preferencesProvider` is deliberately not
      // overridden here: if the timeout ever started reading from it this test
      // would hang or throw rather than quietly returning the default.
      final container = _noDatabaseContainer();
      await container
          .read(localPreferencesProvider)
          .setInt(kAccessInactivityMinutesPrefKey, 3);
      expect(
        await container.read(inactivityTimeoutProvider.future),
        const Duration(minutes: 3),
      );
    });
  });

  // The other half of the audit chain. `access_audit_test.dart` proves the
  // controller hands a record to whatever `auditSinkProvider` returns, and
  // `drift_audit_sink_test.dart` proves a `DriftAuditSink` turns a record into
  // a row. Neither says the provider hands back a *DriftAuditSink* when a
  // database is actually present — so both halves could pass on a station that
  // silently audits into a `NullAuditSink` and writes nothing at all.
  group('with a database', () {
    test('auditSinkProvider is a DriftAuditSink, not a NullAuditSink',
        () async {
      final appDb = AppDatabase.inMemoryForTest();
      final db = Database(appDb);
      addTearDown(() async => appDb.close());

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
      );
      addTearDown(container.dispose);

      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isA<DriftAuditSink>());
      expect(sink, isNot(isA<NullAuditSink>()));

      await db.dispose();
    });
  });

  group('AppRoutes', () {
    test('names the first-user route plans 01-08 and 01-09 both reference', () {
      expect(AppRoutes.firstUser, '/access/first-user');
    });
  });
}
