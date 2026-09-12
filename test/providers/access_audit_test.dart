// One audit row per auth event, and no row for an outage.
//
// The assertions are on list *length*, not `contains`. "At least one row" would
// pass with a duplicate, and a duplicated login row is a trail that reads as
// two people signing in — which is exactly the kind of quiet wrongness that
// makes a trail stop being believed.

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/preferences.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

const String _kStation = 'packing-hall-2';
const String _kPassword = 'correct horse battery staple';

class _FakeAuthProvider implements AuthProvider {
  bool unavailable = false;

  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    if (unavailable) throw StateError('the database is unreachable');
    if (username == 'jon' && password == _kPassword) {
      return const AuthenticatedUser(username: 'jon', roleName: 'Engineering');
    }
    return null;
  }
}

/// Keeps every row so the tests can count them.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  /// When set, `record` throws — the "audit failure must not block a sign-in"
  /// case.
  bool throwOnRecord = false;

  @override
  Future<void> record(AuditRecord entry) async {
    if (throwOnRecord) throw StateError('the audit table is unreachable');
    rows.add(entry);
  }
}

class _Harness {
  _Harness(this.container, this.sink, this.repository, this.auth);

  final ProviderContainer container;
  final _RecordingSink sink;
  final AccessRepository repository;
  final _FakeAuthProvider auth;

  AccessSessionController get notifier =>
      container.read(accessSessionProvider.notifier);

  AccessSession? get session =>
      container.read(accessSessionProvider).valueOrNull;

  Future<AccessSession> settle() => container.read(accessSessionProvider.future);

  Future<void> writeStoredPayload(String payload) => container
      .read(localPreferencesProvider)
      .setString(kAccessSessionPrefKey, payload);
}

/// [timeout] is what an account with **no** stored minutes resolves to: the
/// default. `jon` is authenticated by the fake above and has no `app_user`
/// row, so this is the window the expiry tests below actually get — which is
/// what lets them arm a countdown in milliseconds rather than waiting out a
/// quarter of an hour. An account that does carry minutes gets ten
/// milliseconds per stored minute, the same scale `access_session_test.dart`
/// uses.
Future<_Harness> _harness({
  Duration timeout = const Duration(minutes: 15),
}) async {
  final db = AppDatabase.inMemoryForTest();
  addTearDown(() => db.close());
  await db.customSelect('SELECT 1').getSingle();

  final repository = AccessRepository(db);
  final auth = _FakeAuthProvider();
  final sink = _RecordingSink();

  final container = ProviderContainer(
    overrides: [
      accessRepositoryProvider.overrideWith((ref) async => repository),
      authProviderProvider.overrideWith((ref) async => auth),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      inactivityTimeoutResolverProvider.overrideWithValue((minutes) =>
          minutes == null ? timeout : Duration(milliseconds: minutes * 10)),
    ],
  );
  addTearDown(container.dispose);

  return _Harness(container, sink, repository, auth);
}

ProviderSubscription<AsyncValue<AccessSession>> _listen(_Harness h) {
  final sub = h.container.listen<AsyncValue<AccessSession>>(
    accessSessionProvider,
    (_, __) {},
  );
  addTearDown(sub.close);
  return sub;
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
  });

  group('a successful sign-in', () {
    test('writes exactly one row', () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', _kPassword);

      expect(h.sink.rows, hasLength(1));
    });

    test('the row names the auth surface, the login event and the user',
        () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', _kPassword);

      final row = h.sink.rows.single;
      expect(row.surface, 'auth');
      expect(row.itemKey, 'login');
      expect(row.allowed, isTrue);
      expect(row.who, 'jon');
      expect(row.roleName, 'Engineering');
      expect(row.station, _kStation);
    });

    test('the role in the row is the resolved one, not the stored string',
        () async {
      final h = await _harness();
      await h.settle();
      // Narrowing Engineering does not rename it, but it does prove the row is
      // built from the row that was looked up.
      await h.repository.upsertRole(const AccessRole(
        name: 'Engineering',
        groups: {AccessGroup.operate},
      ));

      await h.notifier.signIn('jon', _kPassword);

      expect(h.sink.rows.single.roleName, 'Engineering');
    });
  });

  group('a failed sign-in', () {
    test('writes exactly one row, marked as a denial', () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', 'wrong');

      expect(h.sink.rows, hasLength(1));
      final row = h.sink.rows.single;
      expect(row.itemKey, 'login.failed');
      expect(row.allowed, isFalse);
      expect(row.who, 'jon');
      expect(row.station, _kStation);
    });

    test('the role is Operator — the attempt came from an anonymous session',
        () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('nobody', 'wrong');

      expect(h.sink.rows.single.roleName, kOperatorRoleName);
      expect(h.sink.rows.single.who, 'nobody');
    });
  });

  group('an outage', () {
    test('writes no row at all', () async {
      final h = await _harness();
      await h.settle();
      h.auth.unavailable = true;

      final result = await h.notifier.signIn('jon', _kPassword);

      expect(result, AccessSignInResult.unavailable);
      expect(h.sink.rows, isEmpty,
          reason: 'a database blip is not a failed login attempt; a trail full '
              'of phantom failures during an outage is a trail nobody reads');
    });
  });

  group('signOut', () {
    test('writes exactly one row naming the departing user and role', () async {
      final h = await _harness();
      await h.settle();
      await h.notifier.signIn('jon', _kPassword);
      h.sink.rows.clear();

      await h.notifier.signOut();

      expect(h.sink.rows, hasLength(1));
      final row = h.sink.rows.single;
      expect(row.itemKey, 'logout');
      expect(row.allowed, isTrue);
      expect(row.who, 'jon');
      expect(row.oldValue, 'Engineering');
      expect(row.station, _kStation);
    });

    test('while already anonymous writes no row', () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signOut();

      expect(h.sink.rows, isEmpty);
    });
  });

  group('an inactivity timeout', () {
    test('writes exactly one row with a reason', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 300));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', _kPassword);
      h.sink.rows.clear();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(h.sink.rows, hasLength(1));
      final row = h.sink.rows.single;
      expect(row.itemKey, 'session.timeout');
      expect(row.who, 'jon');
      expect(row.roleName, 'Engineering');
      expect(row.reason, isNotNull);
      expect(row.reason, isNotEmpty);
    });
  });

  group('restoring a stored session', () {
    test(
        'writes one session.timeout row when it expired while the app was not '
        'running', () async {
      final h = await _harness();
      await h.writeStoredPayload(jsonEncode({
        'username': 'jon',
        'roleName': 'Engineering',
        'displayName': null,
        'expiresAt': clock
            .now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      }));

      await h.settle();

      expect(h.sink.rows, hasLength(1));
      final row = h.sink.rows.single;
      expect(row.itemKey, 'session.timeout');
      expect(row.who, 'jon');
      expect(row.roleName, 'Engineering');
      expect(row.reason, isNotNull);
      expect(row.reason!.toLowerCase(), contains('not running'));
    });

    test('writes no row when it is still valid — a restart is not an auth '
        'event', () async {
      final h = await _harness();
      await h.writeStoredPayload(jsonEncode({
        'username': 'jon',
        'roleName': 'Engineering',
        'displayName': null,
        'expiresAt': clock
            .now()
            .add(const Duration(minutes: 5))
            .toUtc()
            .toIso8601String(),
      }));

      final session = await h.settle();

      expect(session.isElevated, isTrue);
      expect(h.sink.rows, isEmpty);
    });
  });

  group('every row', () {
    test('carries a distinct actionId', () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', _kPassword);
      await h.notifier.signOut();
      await h.notifier.signIn('jon', _kPassword);

      final ids = h.sink.rows.map((r) => r.actionId).toList();
      expect(ids, hasLength(3));
      expect(ids.toSet(), hasLength(3),
          reason: 'one human action is one correlation id; two sign-ins are '
              'two actions');
    });

    test('has origin "operator"', () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', _kPassword);
      await h.notifier.signOut();
      await h.notifier.signIn('jon', 'wrong');

      expect(h.sink.rows, hasLength(3));
      for (final row in h.sink.rows) {
        expect(row.origin, 'operator');
      }
    });

    test('carries an empty groupRequired — signing in is not gated on a group',
        () async {
      final h = await _harness();
      await h.settle();

      await h.notifier.signIn('jon', _kPassword);

      expect(h.sink.rows.single.groupRequired, isEmpty);
    });

    test('leaks no password in oldValue, newValue or reason', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 300));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'wrong');
      await h.notifier.signIn('jon', _kPassword);
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(h.sink.rows, hasLength(3));
      for (final row in h.sink.rows) {
        for (final field in [row.oldValue, row.newValue, row.reason]) {
          if (field == null) continue;
          expect(field, isNot(contains(_kPassword)));
          expect(field, isNot(contains('wrong')));
        }
      }
    });
  });

  group('a sink that throws', () {
    test('does not prevent the sign-in from succeeding', () async {
      final h = await _harness();
      await h.settle();
      h.sink.throwOnRecord = true;

      final result = await h.notifier.signIn('jon', _kPassword);

      expect(result, AccessSignInResult.ok);
      expect(h.session!.isElevated, isTrue);
      expect(h.session!.user!.username, 'jon');
    });

    test('does not prevent a sign-out from completing', () async {
      final h = await _harness();
      await h.settle();
      await h.notifier.signIn('jon', _kPassword);
      h.sink.throwOnRecord = true;

      await h.notifier.signOut();

      expect(h.session!.isElevated, isFalse);
    });
  });
}
