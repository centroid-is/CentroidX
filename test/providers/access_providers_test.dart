// The leaf access providers: what each of them does on a station with no
// database.
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
import 'package:tfc/routes.dart';

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
  });

  group('stationNameProvider', () {
    test('is a non-empty hostname', () {
      final container = _noDatabaseContainer();
      expect(container.read(stationNameProvider), isNotEmpty);
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
