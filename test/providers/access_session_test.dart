// `AccessSessionController`: the session, its restore across a restart, and
// the listener-gated inactivity countdown.
//
// `ProviderContainer` with overrides rather than widget tests — this is
// provider logic and does not need a tree.
//
// The timeout tests use real short durations (a few hundred milliseconds)
// rather than `fake_async`. `InactivityMonitor` is a real `Timer` behind a
// broadcast stream, and the whole point of these tests is the *interaction*
// between Riverpod's listener lifecycle and that timer; a fake clock that only
// the test advances would not exercise it.

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

/// A stand-in for `LocalAuthProvider` that honours the same null-versus-throw
/// contract: null for an unrecognised credential, a throw for infrastructure.
class _FakeAuthProvider implements AuthProvider, PasswordSelfService {
  _FakeAuthProvider(
    this.users, {
    this.stationAccounts = const {},
    this.extraRoles = const {},
  });

  /// username -> (password, roleName)
  final Map<String, ({String password, String roleName})> users;

  /// Usernames flagged as station accounts (schema v8).
  final Set<String> stationAccounts;

  /// username -> the roles it holds beyond its primary one (schema v9).
  final Map<String, List<String>> extraRoles;

  /// When set, `authenticate` throws instead of answering — a database outage.
  bool unavailable = false;

  /// Every password this fake was handed, so a test can assert nothing leaked
  /// it onward.
  final List<String> seenPasswords = [];

  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    seenPasswords.add(password);
    if (unavailable) throw StateError('the database is unreachable');
    final cred = users[username];
    if (cred == null || cred.password != password) return null;
    return AuthenticatedUser(
      username: username,
      roleName: cred.roleName,
      additionalRoles: extraRoles[username] ?? const [],
      stationAccount: stationAccounts.contains(username),
    );
  }

  // ---- PasswordSelfService ------------------------------------------------

  /// When set, `changePassword` throws — the same outage `unavailable` stands
  /// for on the login path, kept separate so a test can break one without the
  /// other.
  bool changeUnavailable = false;

  /// Usernames whose row has been deleted out from under a live session.
  final Set<String> vanished = {};

  /// Every password `changePassword` was handed, current and new alike, so a
  /// test can assert neither reached an audit row.
  final List<String> seenChangePasswords = [];

  @override
  Future<PasswordChangeResult> changePassword({
    required String username,
    required String currentPassword,
    required String newPassword,
  }) async {
    seenChangePasswords.addAll([currentPassword, newPassword]);
    if (changeUnavailable) throw StateError('the database is unreachable');
    if (vanished.contains(username)) return PasswordChangeResult.accountMissing;

    final cred = users[username];
    if (cred == null) return PasswordChangeResult.accountMissing;
    if (cred.password != currentPassword) {
      return PasswordChangeResult.wrongCurrentPassword;
    }

    users[username] = (password: newPassword, roleName: cred.roleName);
    return PasswordChangeResult.ok;
  }
}

/// An `AuthProvider` with no password to change — the shape OIDC will have.
///
/// The controller asks `auth is PasswordSelfService` rather than assuming, and
/// this is what makes that question have two answers in the suite. Without it
/// the capability check is exercised only on its true branch, which is the
/// branch that cannot regress.
class _NoSelfServiceAuthProvider implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
          String username, String password) async =>
      const AuthenticatedUser(username: 'jon', roleName: 'Engineering');
}

/// A sink that keeps every row, so the audit assertions in
/// `access_audit_test.dart` and the "nothing leaks" checks here can look at it.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// Everything a test needs to drive the controller.
class _Harness {
  _Harness({
    required this.container,
    required this.db,
    required this.repository,
    required this.auth,
    required this.sink,
  });

  final ProviderContainer container;
  final AppDatabase db;
  final AccessRepository repository;
  final _FakeAuthProvider auth;
  final _RecordingSink sink;

  AccessSessionController get notifier =>
      container.read(accessSessionProvider.notifier);

  /// The resolved session, or null while the provider is loading or errored.
  AccessSession? get session => container.read(accessSessionProvider).valueOrNull;

  Future<AccessSession> settle() =>
      container.read(accessSessionProvider.future);

  Future<String?> storedPayload() =>
      container.read(localPreferencesProvider).getString(kAccessSessionPrefKey);

  Future<void> writeStoredPayload(String payload) => container
      .read(localPreferencesProvider)
      .setString(kAccessSessionPrefKey, payload);

  /// The account this panel is committed to, straight from the store rather
  /// than through the controller — so an assertion about the commitment cannot
  /// be satisfied by the controller's in-memory idea of it.
  Future<String?> panelAccountPref() => container
      .read(localPreferencesProvider)
      .getString(kAccessPanelAccountPrefKey);

  /// The itemKeys of the auth rows written so far, in order.
  List<String> get authItemKeys => sink.rows
      .where((r) => r.surface == 'auth')
      .map((r) => r.itemKey)
      .toList();
}

const String _kStation = 'test-panel';

/// [timeout] is what an account with **no** stored minutes resolves to: the
/// default. An account that has a value of its own gets ten milliseconds per
/// stored minute — the countdown runs on real timers, and a window measured in
/// minutes cannot be waited out in a test.
///
/// Ten, rather than one, because the stored number still has to be a legal
/// one: `AccessRepository.setInactivityTimeout` refuses anything outside
/// 1..480, so the scale decides how long a test window can be. At ×10 the
/// ceiling is a comfortable 4.8s instead of 480ms.
Future<_Harness> _harness({
  Duration timeout = const Duration(minutes: 15),
  Map<String, ({String password, String roleName})>? users,
  Set<String> stationAccounts = const {},
  Map<String, List<String>> extraRoles = const {},
  bool withDatabase = true,
  AppDatabase? reuseDb,
}) async {
  // `reuseDb` is what makes a restart testable: a second container over the
  // *same* database and the same preference store is exactly what a relaunch
  // is, and a fresh database would make every restore fail for the wrong
  // reason.
  final db = reuseDb ?? AppDatabase.inMemoryForTest();
  if (reuseDb == null) addTearDown(() => db.close());
  // Force the migration to run, so the four seeded roles exist before the
  // session provider asks for them.
  await db.customSelect('SELECT 1').getSingle();

  final repository = AccessRepository(db);
  final auth = _FakeAuthProvider(
      users ??
          {
            'jon': (password: 'correct horse', roleName: 'Engineering'),
            'sigga': (password: 'hunter2', roleName: 'Shift Leader'),
          },
      stationAccounts: stationAccounts,
      extraRoles: extraRoles);
  final sink = _RecordingSink();

  final container = ProviderContainer(
    overrides: [
      accessRepositoryProvider
          .overrideWith((ref) async => withDatabase ? repository : null),
      authProviderProvider.overrideWith((ref) async => withDatabase ? auth : null),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      inactivityTimeoutResolverProvider.overrideWithValue((minutes) =>
          minutes == null ? timeout : Duration(milliseconds: minutes * 10)),
    ],
  );
  addTearDown(container.dispose);

  return _Harness(
    container: container,
    db: db,
    repository: repository,
    auth: auth,
    sink: sink,
  );
}

/// Attach a listener to the session provider and remove it at the end of the
/// test. Returns the subscription so a test can close it early — which is what
/// the listener-gating assertions are about.
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
    // Real Argon2id/PBKDF2 cost makes `createUser` take seconds a piece, and
    // the panel-account tests need real `app_user` rows.
    Pbkdf2Kdf.iterationsForTest = 10;
    addTearDown(() => Pbkdf2Kdf.iterationsForTest = null);
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
  });

  group('build', () {
    test('with no stored session yields anonymous with the Operator groups',
        () async {
      final h = await _harness();
      final session = await h.settle();

      expect(session.isElevated, isFalse);
      expect(session.user, isNull);
      expect(session.roleName, kOperatorRoleName);
      expect(session.groups, {AccessGroup.operate});
      expect(session.expiresAt, isNull);
    });

    test('the anonymous groups come from the Operator row, not a constant',
        () async {
      final h = await _harness();
      // Ticking `setpoints` on Operator grants it to every logged-out panel —
      // the documented footgun. This asserts the session honours it.
      await h.repository.upsertRole(const AccessRole(
        name: kOperatorRoleName,
        groups: {AccessGroup.operate, AccessGroup.setpoints},
      ));

      final session = await h.settle();
      expect(session.groups, {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('with no database at all yields anonymous with the seeded groups',
        () async {
      final h = await _harness(withDatabase: false);
      final session = await h.settle();

      expect(session.isElevated, isFalse);
      expect(session.groups, {AccessGroup.operate});
    });
  });

  group('signIn', () {
    test('with valid credentials elevates the session', () async {
      final h = await _harness();
      await h.settle();

      final result = await h.notifier.signIn('jon', 'correct horse');

      expect(result, AccessSignInResult.ok);
      final session = h.session!;
      expect(session.isElevated, isTrue);
      expect(session.user!.username, 'jon');
      expect(session.roleName, 'Engineering');
      expect(session.can(AccessGroup.administer), isTrue);
    });

    test('resolves the groups from the role row, not from the user', () async {
      final h = await _harness();
      await h.settle();
      await h.repository.upsertRole(const AccessRole(
        name: 'Shift Leader',
        groups: {AccessGroup.operate, AccessGroup.setpoints, AccessGroup.force},
      ));

      await h.notifier.signIn('sigga', 'hunter2');
      expect(h.session!.groups, {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.force,
      });
    });

    test('with a wrong password returns badCredentials and stays anonymous',
        () async {
      final h = await _harness();
      await h.settle();

      final result = await h.notifier.signIn('jon', 'wrong');

      expect(result, AccessSignInResult.badCredentials);
      expect(h.session!.isElevated, isFalse);
      expect(h.session!.roleName, kOperatorRoleName);
    });

    test('with an unknown username returns badCredentials', () async {
      final h = await _harness();
      await h.settle();

      expect(
        await h.notifier.signIn('nobody', 'whatever'),
        AccessSignInResult.badCredentials,
      );
      expect(h.session!.isElevated, isFalse);
    });

    test(
        'returns unavailable and stays anonymous when the auth provider throws',
        () async {
      final h = await _harness();
      await h.settle();
      h.auth.unavailable = true;

      final result = await h.notifier.signIn('jon', 'correct horse');

      expect(result, AccessSignInResult.unavailable);
      expect(h.session!.isElevated, isFalse);
    });

    test('returns unavailable when there is no auth provider', () async {
      final h = await _harness(withDatabase: false);
      await h.settle();

      expect(
        await h.notifier.signIn('jon', 'correct horse'),
        AccessSignInResult.unavailable,
      );
      expect(h.session!.isElevated, isFalse);
    });

    test('sets expiresAt to now plus the configured inactivity timeout',
        () async {
      final h = await _harness(timeout: const Duration(minutes: 20));
      await h.settle();

      final pinned = DateTime.utc(2026, 8, 28, 12);
      await withClock(Clock.fixed(pinned), () async {
        await h.notifier.signIn('jon', 'correct horse');
      });

      expect(h.session!.expiresAt, pinned.add(const Duration(minutes: 20)));
    });

    test('a station account signs in with no expiry even under a normal '
        'timeout', () async {
      // The account-level half of the panel-PC story: the freezer display's
      // identity never expires ANYWHERE, while jon on the same panel keeps
      // the fifteen minutes. The station-wide disable switch is the blunt
      // sibling; this is the precise one.
      final h = await _harness(stationAccounts: {'jon'});
      await h.settle();

      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.isElevated, isTrue);
      expect(h.session!.expiresAt, isNull);

      h.notifier.poke();
      await h.settle();
      expect(h.session!.expiresAt, isNull,
          reason: 'an activity extension must not conjure an expiry onto a '
              'station account');
    });

    test('the account\'s own timeout wins over the default', () async {
      // The whole point of the change: the window belongs to whoever signed
      // in, not to the panel they happened to walk up to.
      final h = await _harness(timeout: const Duration(minutes: 15));
      await h.settle();
      await h.repository.createUser(
          username: 'jon', password: 'correct horse', roleName: 'Engineering');
      await h.repository.setInactivityTimeout('jon', 20);

      final pinned = DateTime.utc(2026, 8, 28, 12);
      await withClock(Clock.fixed(pinned), () async {
        await h.notifier.signIn('jon', 'correct horse');
      });

      expect(h.session!.inactivityTimeout, const Duration(milliseconds: 200));
      expect(h.session!.expiresAt, pinned.add(const Duration(milliseconds: 200)),
          reason: 'the harness scales stored minutes into milliseconds; what '
              'is asserted is that the row decided the window, not the '
              'default');
    });

    test('an account with no value of its own gets the default', () async {
      // NULL in the column is "no value of its own", never "never expires" —
      // the one way to read it wrong that would mint immortal sessions for
      // every account carried over from v7.
      final h = await _harness(timeout: const Duration(minutes: 15));
      await h.settle();
      await h.repository.createUser(
          username: 'jon', password: 'correct horse', roleName: 'Engineering');

      await h.notifier.signIn('jon', 'correct horse');

      expect(h.session!.inactivityTimeout, const Duration(minutes: 15));
      expect(h.session!.expiresAt, isNotNull);
    });

    test('two accounts on one panel each get their own window', () async {
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
          username: 'jon', password: 'correct horse', roleName: 'Engineering');
      await h.repository.setInactivityTimeout('jon', 20);
      await h.repository.createUser(
          username: 'sigga', password: 'hunter2', roleName: 'Shift Leader');
      await h.repository.setInactivityTimeout('sigga', 90);

      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.inactivityTimeout, const Duration(milliseconds: 200));

      await h.notifier.signIn('sigga', 'hunter2');
      expect(h.session!.inactivityTimeout, const Duration(milliseconds: 900),
          reason: 'signing in over another session must take the new '
              'account\'s window, not keep the previous one\'s');
    });

    test('a station account has no timeout at all', () async {
      final h = await _harness(stationAccounts: {'freezer'}, users: {
        'freezer': (password: 'cold', roleName: kOperatorRoleName),
      });
      await h.settle();
      await h.repository.createUser(
          username: 'freezer', password: 'cold', roleName: kOperatorRoleName);
      // Even with minutes stored against it: the flag outranks the column.
      await h.repository.setInactivityTimeout('freezer', 20);

      await h.notifier.signIn('freezer', 'cold');

      expect(h.session!.inactivityTimeout, isNull);
      expect(h.session!.expiresAt, isNull);
    });

    test('the stored payload carries no password, hash or salt', () async {
      final h = await _harness();
      await h.settle();
      await h.notifier.signIn('jon', 'correct horse');

      final payload = (await h.storedPayload())!;
      expect(payload, contains('jon'));
      expect(payload.toLowerCase(), isNot(contains('correct horse')));
      expect(payload.toLowerCase(), isNot(contains('password')));
      expect(payload.toLowerCase(), isNot(contains('hash')));
      expect(payload.toLowerCase(), isNot(contains('salt')));
      // The resolved groups are deliberately absent too: they are re-resolved
      // from the role on restore, so a hand-edited file cannot add one.
      expect(payload, isNot(contains('groups')));
    });
  });

  group('signOut', () {
    test('returns to anonymous', () async {
      final h = await _harness();
      await h.settle();
      await h.notifier.signIn('jon', 'correct horse');

      await h.notifier.signOut();

      expect(h.session!.isElevated, isFalse);
      expect(h.session!.roleName, kOperatorRoleName);
      expect(h.session!.expiresAt, isNull);
    });

    test('clears the stored session', () async {
      final h = await _harness();
      await h.settle();
      await h.notifier.signIn('jon', 'correct horse');
      expect(await h.storedPayload(), isNotNull);

      await h.notifier.signOut();

      expect(await h.storedPayload(), isNull);
    });

    test('is harmless while already anonymous', () async {
      final h = await _harness();
      await h.settle();

      await expectLater(h.notifier.signOut(), completes);
      expect(h.session!.isElevated, isFalse);
    });
  });

  group('poke', () {
    test('while elevated pushes expiresAt forward', () async {
      final h = await _harness(timeout: const Duration(minutes: 15));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      final before = h.session!.expiresAt!;

      await withClock(Clock.fixed(before.add(const Duration(minutes: 1))),
          () async {
        h.notifier.poke();
      });

      expect(h.session!.expiresAt!.isAfter(before), isTrue);
    });

    test('while elevated re-arms the countdown', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      await Future<void>.delayed(const Duration(milliseconds: 250));
      h.notifier.poke();
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // 500ms after signing in — past the original expiry, before the poked
      // one.
      expect(h.session!.isElevated, isTrue);
      expect(h.notifier.timerIsRunning, isTrue);
    });

    test('while anonymous is a no-op and arms nothing', () async {
      final h = await _harness();
      await h.settle();
      _listen(h);

      h.notifier.poke();

      expect(h.session!.isElevated, isFalse);
      expect(h.session!.expiresAt, isNull);
      expect(h.notifier.timerIsRunning, isFalse);
    });

    test('during AsyncLoading does not throw', () async {
      final h = await _harness();
      // Deliberately NOT awaited: `BaseScaffold` wires poke() to pointer-down
      // from the first frame, which is before build() has resolved on a cold
      // start.
      expect(h.container.read(accessSessionProvider), isA<AsyncLoading<AccessSession>>());
      expect(h.notifier.poke, returnsNormally);

      await h.settle();
    });

    test('after the provider has errored does not throw', () async {
      final container = ProviderContainer(
        overrides: [
          accessRepositoryProvider.overrideWith((ref) async => null),
          authProviderProvider.overrideWith((ref) async => null),
          // The build's own failure: it awaits this before it can publish a
          // session, so the provider lands in `AsyncError` — which is the
          // state this test is about.
          auditSinkProvider
              .overrideWith((ref) async => throw StateError('no sink')),
          stationNameProvider.overrideWithValue(_kStation),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(accessSessionProvider.future),
        throwsA(isA<StateError>()),
      );
      expect(container.read(accessSessionProvider), isA<AsyncError<AccessSession>>());
      expect(container.read(accessSessionProvider.notifier).poke,
          returnsNormally);
    });
  });

  group('the listener-gated countdown', () {
    // Reading `.notifier` is not a listener of the provider's *value*, which
    // is what makes every assertion in this group meaningful: the harness can
    // ask the controller whether its timer is armed without arming it.

    test('no timer is armed before anything listens', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      await h.notifier.signIn('jon', 'correct horse');

      expect(h.session!.isElevated, isTrue);
      expect(h.notifier.timerIsRunning, isFalse);
    });

    test('no timer is armed while the session is anonymous', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      _listen(h);

      expect(h.notifier.timerIsRunning, isFalse);
    });

    test('a timer is armed while elevated and listened to', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      expect(h.notifier.timerIsRunning, isTrue);
    });

    test('removing the last listener disarms it', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      final sub = _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      expect(h.notifier.timerIsRunning, isTrue);

      sub.close();

      expect(h.notifier.timerIsRunning, isFalse);
    });

    test('adding a listener back re-arms it', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      final sub = _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      sub.close();
      expect(h.notifier.timerIsRunning, isFalse);

      _listen(h);

      expect(h.notifier.timerIsRunning, isTrue);
    });

    test('a restored session arms as soon as the first listener attaches',
        () async {
      // The boot case: the root scaffold listens once and never stops, so
      // there is no cancel-then-resume edge to hang the countdown off.
      final h = await _harness(timeout: const Duration(milliseconds: 400));
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

      _listen(h);
      final session = await h.settle();

      expect(session.isElevated, isTrue);
      expect(h.notifier.timerIsRunning, isTrue);
    });
  });

  group('expiry', () {
    test('the state returns to anonymous when the countdown elapses', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 300));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(h.session!.isElevated, isFalse);
      expect(h.notifier.timerIsRunning, isFalse);
    });

    test('the stored session is cleared on timeout', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 300));
      await h.settle();
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      expect(await h.storedPayload(), isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(await h.storedPayload(), isNull);
    });

    test('re-attaching mid-session arms for the time remaining, not a fresh '
        'full timeout', () async {
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      final sub = _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      // Detach at ~250ms, re-attach at ~280ms: 120ms should be left, so the
      // session ends at ~400ms. A fresh full timeout would end it at ~680ms.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      sub.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      _listen(h);

      await Future<void>.delayed(const Duration(milliseconds: 270));

      expect(h.session!.isElevated, isFalse,
          reason: 'at ~550ms the session must be over; if it is not, the '
              're-attach armed for the full timeout instead of the remainder');
    });

    test('the next poke after a re-attach restores the full timeout', () async {
      // This is the bullet that fails if the controller builds a fresh
      // `InactivityMonitor(timeout: remaining)` per re-attach instead of
      // calling `arm`: a new monitor would make every later poke re-arm for
      // that remainder.
      final h = await _harness(timeout: const Duration(milliseconds: 400));
      await h.settle();
      final sub = _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      await Future<void>.delayed(const Duration(milliseconds: 250));
      sub.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      _listen(h);
      // ~120ms remained; poking must restore the full 400ms.
      h.notifier.poke();

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(h.session!.isElevated, isTrue,
          reason: 'the poke should have armed for the full 400ms, so at '
              '~250ms afterwards the session is still alive');
      expect(h.notifier.timerIsRunning, isTrue);
    });

    test(
        're-attaching after a detach longer than the timeout expires '
        'immediately', () async {
      // Pausing the countdown must not extend the session by wall-clock time.
      final h = await _harness(timeout: const Duration(milliseconds: 200));
      await h.settle();
      final sub = _listen(h);
      await h.notifier.signIn('jon', 'correct horse');

      sub.close();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.session!.isElevated, isTrue,
          reason: 'nothing was listening, so nothing had run yet');

      _listen(h);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(h.session!.isElevated, isFalse);
      expect(h.notifier.timerIsRunning, isFalse);
    });
  });

  group('restore', () {
    Future<void> store(
      _Harness h, {
      required String username,
      required String roleName,
      required Duration fromNow,
    }) =>
        h.writeStoredPayload(jsonEncode({
          'username': username,
          'roleName': roleName,
          'displayName': null,
          'expiresAt': clock.now().add(fromNow).toUtc().toIso8601String(),
        }));

    test('an unexpired stored session comes back elevated', () async {
      final h = await _harness();
      await store(h,
          username: 'jon',
          roleName: 'Engineering',
          fromNow: const Duration(minutes: 5));

      final session = await h.settle();

      expect(session.isElevated, isTrue);
      expect(session.user!.username, 'jon');
      expect(session.roleName, 'Engineering');
    });

    test('the groups are re-resolved from the role, not read from the payload',
        () async {
      final h = await _harness();
      // Narrow Engineering before the restore. The payload carries no groups,
      // so the restored session must reflect the edit.
      await h.repository.upsertRole(const AccessRole(
        name: 'Engineering',
        groups: {AccessGroup.operate},
      ));
      await store(h,
          username: 'jon',
          roleName: 'Engineering',
          fromNow: const Duration(minutes: 5));

      final session = await h.settle();

      expect(session.groups, {AccessGroup.operate});
      expect(session.can(AccessGroup.administer), isFalse);
    });

    test('an expired stored session yields anonymous and is cleared', () async {
      final h = await _harness();
      await store(h,
          username: 'jon',
          roleName: 'Engineering',
          fromNow: const Duration(minutes: -1));

      final session = await h.settle();

      expect(session.isElevated, isFalse);
      expect(await h.storedPayload(), isNull);
    });

    test('a stored session naming a role that no longer exists yields '
        'anonymous and is cleared', () async {
      final h = await _harness();
      await store(h,
          username: 'jon',
          roleName: 'Nonexistent',
          fromNow: const Duration(minutes: 5));

      final session = await h.settle();

      expect(session.isElevated, isFalse);
      expect(await h.storedPayload(), isNull);
    });

    test('a corrupt payload yields anonymous, is cleared, and does not throw',
        () async {
      final h = await _harness();
      await h.writeStoredPayload('{not json at all');

      final session = await h.settle();

      expect(session.isElevated, isFalse);
      expect(await h.storedPayload(), isNull);
    });

    test('a payload with no expiry is not restorable', () async {
      final h = await _harness();
      await h.writeStoredPayload(
          jsonEncode({'username': 'jon', 'roleName': 'Engineering'}));

      final session = await h.settle();

      expect(session.isElevated, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The panel account
  // -------------------------------------------------------------------------

  /// A panel committed to a station account: it survives a human signing in
  /// over it, their timeout, their sign-out and a restart, and it re-resolves
  /// everything it needs from the database every time it comes back.
  ///
  /// The fake auth provider and the `app_user` table are seeded together on
  /// purpose. In production `LocalAuthProvider` reads the same row the resume
  /// path re-reads, so a test where the two disagree would be testing a state
  /// the app cannot reach — except in the tests that make them disagree
  /// deliberately, which is what the account-deleted and demoted cases are.
  group('the panel account', () {
    const users = {
      'freezer': (password: 'panel pw', roleName: kOperatorRoleName),
      'jon': (password: 'correct horse', roleName: 'Engineering'),
    };

    Future<_Harness> panel({
      Duration timeout = const Duration(minutes: 15),
      AppDatabase? reuseDb,
    }) async {
      final h = await _harness(
        users: users,
        stationAccounts: const {'freezer'},
        timeout: timeout,
        reuseDb: reuseDb,
      );
      if (reuseDb == null) {
        await h.repository.createUser(
            username: 'freezer',
            password: 'panel pw',
            roleName: kOperatorRoleName);
        await h.repository.setStationAccount('freezer', true);
        await h.repository.createUser(
            username: 'jon', password: 'correct horse', roleName: 'Engineering');
      }
      return h;
    }

    /// Sign the panel in as `freezer` and commit it. The commissioning act.
    Future<_Harness> committed(
        {Duration timeout = const Duration(minutes: 15)}) async {
      final h = await panel(timeout: timeout);
      await h.settle();
      await h.notifier.signIn('freezer', 'panel pw');
      expect(await h.notifier.commitPanelAccount(), isTrue);
      return h;
    }

    test('committing stores the username and nothing else', () async {
      final h = await committed();

      expect(await h.panelAccountPref(), 'freezer');
      expect(
        await h.storedPayload(),
        isNull,
        reason: 'the panel lives in its own key; a copy in the human session '
            'slot would be a second, staler answer that a restart rejects for '
            'having no expiry',
      );
    });

    test('refuses to commit a session that is not a station account', () async {
      final h = await panel();
      await h.settle();
      await h.notifier.signIn('jon', 'correct horse');

      expect(await h.notifier.commitPanelAccount(), isFalse);
      expect(await h.panelAccountPref(), isNull);
    });

    test('refuses to commit while anonymous', () async {
      final h = await panel();
      await h.settle();

      expect(await h.notifier.commitPanelAccount(), isFalse);
      expect(await h.panelAccountPref(), isNull);
    });

    test('a human signing in over the panel leaves the commitment alone',
        () async {
      final h = await committed();

      await h.notifier.signIn('jon', 'correct horse');

      expect(h.session!.user!.username, 'jon');
      expect(await h.panelAccountPref(), 'freezer',
          reason: 'signing in over a panel must not un-commission it');
    });

    test('a human signing out hands the panel back', () async {
      final h = await committed();
      await h.notifier.signIn('jon', 'correct horse');

      await h.notifier.signOut();

      expect(h.session!.isElevated, isTrue);
      expect(h.session!.user!.username, 'freezer');
      expect(h.session!.roleName, kOperatorRoleName);
      expect(await h.panelAccountPref(), 'freezer');
      expect(h.authItemKeys, containsAllInOrder(['logout', 'session.resume']));
    });

    test('a human timing out hands the panel back', () async {
      final h = await committed(timeout: const Duration(milliseconds: 120));
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.user!.username, 'jon');

      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(h.session!.user!.username, 'freezer',
          reason: 'the whole point: an operator does not have to sign the '
              'panel back in after somebody borrowed it');
      expect(h.authItemKeys,
          containsAllInOrder(['session.timeout', 'session.resume']));
    });

    test('the resumed panel never expires and arms no countdown', () async {
      final h = await committed(timeout: const Duration(milliseconds: 120));
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(h.session!.user!.username, 'freezer');
      expect(h.session!.expiresAt, isNull);
      expect(h.notifier.timerIsRunning, isFalse,
          reason: 'a panel does not time out, so nothing may be armed for it');
    });

    test('the panel account itself cannot be signed out', () async {
      // Anybody walking past could press it, and the panel would sit anonymous
      // with its raised pages hidden until somebody with the station account's
      // password came back. Releasing it is an administrator's act.
      final h = await committed();
      h.sink.rows.clear();

      await h.notifier.signOut();

      expect(h.session!.user!.username, 'freezer');
      expect(await h.panelAccountPref(), 'freezer');
      expect(h.authItemKeys, isEmpty,
          reason: 'a refused sign-out is not a logout');
    });

    test('a panel resumed at restart cannot be signed out either', () async {
      // The restore path used to leave `_onPanelSession` false, so the panel's
      // first pointer-down copied it into the human slot.
      final h = await committed();
      final restarted = await panel(reuseDb: h.db);
      await restarted.settle();

      await restarted.notifier.signOut();
      restarted.notifier.poke();
      await Future<void>.delayed(Duration.zero);

      expect(restarted.session!.user!.username, 'freezer');
      expect(await restarted.panelAccountPref(), 'freezer');
      expect(await restarted.storedPayload(), isNull,
          reason: 'the panel lives in its own key, never in the human slot');
    });

    test('the read-out follows a commit and the release that ends it',
        () async {
      // The Session card watches this provider. Nothing else tells it the
      // commitment changed: the key is device-local, the writes happen inside
      // the controller, and committing does not move the session — a human
      // signed in over the panel sees their own name either way. Without the
      // invalidations it would show the answer from whenever it was first
      // built and stay wrong until a reload.
      final h = await panel();
      await h.settle();
      final sub = h.container.listen<AsyncValue<String?>>(
          panelAccountProvider, (_, __) {});
      addTearDown(sub.close);

      expect(await h.container.read(panelAccountProvider.future), isNull);

      await h.notifier.signIn('freezer', 'panel pw');
      expect(await h.notifier.commitPanelAccount(), isTrue);
      expect(await h.container.read(panelAccountProvider.future), 'freezer');

      await h.notifier.signIn('jon', 'correct horse');
      expect(await h.notifier.releasePanelAccount(), isTrue);
      expect(await h.container.read(panelAccountProvider.future), isNull,
          reason: 'releasing is the documented way out, so it is the one the '
              'card has to follow');
    });

    test('a resume refusal shows up in the read-out too', () async {
      // The account was demoted under a committed panel: the resume un-commits
      // it, and the card must not go on naming an account that can no longer
      // be a panel. `_clearPanelAccount` is the one funnel for all three
      // refusals.
      final h = await committed();
      final sub = h.container.listen<AsyncValue<String?>>(
          panelAccountProvider, (_, __) {});
      addTearDown(sub.close);
      expect(await h.container.read(panelAccountProvider.future), 'freezer');

      await h.notifier.signIn('jon', 'correct horse');
      await h.repository.setStationAccount('freezer', false);
      await h.notifier.signOut();

      expect(await h.container.read(panelAccountProvider.future), isNull);
    });

    group('releasing the panel', () {
      test('by a person holding users, over the panel', () async {
        final h = await committed();
        await h.notifier.signIn('jon', 'correct horse');
        h.sink.rows.clear();

        expect(await h.notifier.releasePanelAccount(), isTrue);

        expect(await h.panelAccountPref(), isNull);
        expect(h.session!.user!.username, 'jon',
            reason: 'their session stands; the panel just has no floor now');
        final row = h.sink.rows.single;
        expect(row.itemKey, 'panel.release');
        expect(row.who, 'jon');
        expect(row.member, 'freezer');
        expect(row.allowed, isTrue);

        await h.notifier.signOut();
        expect(h.session!.isElevated, isFalse,
            reason: 'nothing to return to once the panel is released');
      });

      test('by the panel itself, when its own role holds users', () async {
        final h = await committed();
        await h.repository.setRole('freezer', 'Engineering');
        await h.notifier.refreshGroupsFromRoles();
        expect(h.session!.can(AccessGroup.users), isTrue);
        h.sink.rows.clear();

        expect(await h.notifier.releasePanelAccount(), isTrue);

        expect(await h.panelAccountPref(), isNull);
        expect(h.session!.isElevated, isFalse,
            reason: 'the released identity was the live session');
        expect(h.authItemKeys, isNot(contains('logout')),
            reason: 'nobody signed out; the release row is the record');
        expect(h.sink.rows.map((r) => r.itemKey), contains('panel.release'));
      });

      test('is refused for a session without users', () async {
        final h = await committed();
        h.sink.rows.clear();

        expect(await h.notifier.releasePanelAccount(), isFalse);

        expect(await h.panelAccountPref(), 'freezer');
        expect(h.session!.user!.username, 'freezer');
        final row = h.sink.rows.single;
        expect(row.itemKey, 'panel.release');
        expect(row.allowed, isFalse,
            reason: 'a refused release is somebody trying to decommission a '
                'panel, and that is worth a row');
      });

      test('writes nothing when the panel is not committed', () async {
        final h = await panel();
        await h.settle();
        await h.notifier.signIn('jon', 'correct horse');
        h.sink.rows.clear();

        expect(await h.notifier.releasePanelAccount(), isFalse);
        expect(h.sink.rows, isEmpty);
      });

      test('keeps the station-account flag through a role refresh', () async {
        // `refreshGroupsFromRoles` rebuilt the user without it, so any admin
        // write on the panel's own screen turned the panel into a person —
        // with a sign-out and a change-password entry.
        final h = await committed();

        await h.notifier.refreshGroupsFromRoles();

        expect(h.session!.user!.stationAccount, isTrue);
      });
    });

    test('the commitment survives a restart', () async {
      final h = await committed();
      final restarted = await panel(reuseDb: h.db);

      final session = await restarted.settle();

      expect(session.isElevated, isTrue);
      expect(session.user!.username, 'freezer');
      expect(session.expiresAt, isNull);
    });

    test('a human session still live at restart wins over the panel', () async {
      final h = await committed();
      await h.notifier.signIn('jon', 'correct horse');

      final restarted = await panel(reuseDb: h.db);
      final session = await restarted.settle();

      expect(session.user!.username, 'jon',
          reason: 'the person signed in is who is standing there; the panel is '
              'the floor they land on when that ends');
    });

    test('the role is re-resolved at resume, not read from the commitment',
        () async {
      final h = await committed();
      await h.notifier.signIn('jon', 'correct horse');
      // The account is moved to a wider role while a human holds the panel.
      await h.repository.setRole('freezer', 'Shift Leader');

      await h.notifier.signOut();

      expect(h.session!.roleName, 'Shift Leader');
      expect(
        h.sink.rows.lastWhere((r) => r.itemKey == 'session.resume').roleName,
        'Shift Leader',
        reason: 'the row must say what the panel actually came back holding',
      );
    });

    test('a deleted account un-commits the panel at the next resume', () async {
      final h = await committed();
      await h.notifier.signIn('jon', 'correct horse');
      await h.repository.deleteUser('freezer');

      await h.notifier.signOut();

      expect(h.session!.isElevated, isFalse);
      expect(await h.panelAccountPref(), isNull);
    });

    test('an account demoted from station account un-commits the panel',
        () async {
      final h = await committed();
      await h.notifier.signIn('jon', 'correct horse');
      // "This is a person now" — and a person's identity is not what a panel
      // silently wears.
      await h.repository.setStationAccount('freezer', false);

      await h.notifier.signOut();

      expect(h.session!.isElevated, isFalse);
      expect(await h.panelAccountPref(), isNull);
    });

    test('a database outage does not un-commit the panel', () async {
      final h = await committed();

      // No repository: the same state a boot before Postgres opens is in.
      final blind = await _harness(
        users: users,
        stationAccounts: const {'freezer'},
        withDatabase: false,
        reuseDb: h.db,
      );
      final session = await blind.settle();

      expect(session.isElevated, isFalse,
          reason: 'resuming against an unresolvable group set is worse than '
              'anonymous');
      expect(
        await blind.panelAccountPref(),
        'freezer',
        reason: 'a panel that dropped because Postgres blinked must come back '
            'when Postgres does, with nobody driving to the plant',
      );
    });

    test('a fresh sign-in as the panel account is the panel\'s session',
        () async {
      final h = await committed();
      // Reachable: the commit prompt is suppressed when the panel already
      // holds this account, so this session is the panel's identity without
      // ever having been resumed into.
      await h.notifier.signIn('freezer', 'panel pw');

      expect(await h.storedPayload(), isNull,
          reason: 'no copy in the human slot, exactly as for a resume');

      await h.notifier.signOut();

      expect(await h.panelAccountPref(), 'freezer');
      expect(h.session!.user!.username, 'freezer',
          reason: 'the same refusal the resumed panel gets');
    });

    test('a person signing in over the panel writes no logout for it',
        () async {
      // The panel is not ending — it is the floor this session returns to, and
      // `session.resume` marks that when it happens.
      final h = await committed();
      h.sink.rows.clear();

      await h.notifier.signIn('jon', 'correct horse');

      expect(h.authItemKeys, ['login']);
    });

    test('the panel comes back when the database does', () async {
      final h = await committed();

      // The boot-before-Postgres window: anonymous, still committed.
      final blind = await _harness(
        users: users,
        stationAccounts: const {'freezer'},
        withDatabase: false,
        reuseDb: h.db,
      );
      expect((await blind.settle()).isElevated, isFalse);

      // `build` watches `accessRepositoryProvider`, so the database arriving
      // rebuilds the controller and re-runs the restore. This is what makes
      // "refuse freely, clear never" a recovery rather than a wedge.
      final recovered = await _harness(
        users: users,
        stationAccounts: const {'freezer'},
        reuseDb: h.db,
      );
      final session = await recovered.settle();

      expect(session.isElevated, isTrue);
      expect(session.user!.username, 'freezer');
    });

    test('an empty stored value is not an account named ""', () async {
      final h = await panel();
      await h.container
          .read(localPreferencesProvider)
          .setString(kAccessPanelAccountPrefKey, '');

      final session = await h.settle();

      expect(session.isElevated, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // The per-account timeout, after the sign-in that established it
  // -------------------------------------------------------------------------
  group('the account timeout while a session is running', () {
    /// A harness with `jon` as a real row, signed in and listened to.
    Future<_Harness> signedInJon({int? minutes}) async {
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
          username: 'jon', password: 'correct horse', roleName: 'Engineering');
      if (minutes != null) {
        await h.repository.setInactivityTimeout('jon', minutes);
      }
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      return h;
    }

    test('shortening it mid-session pulls the expiry in', () async {
      final h = await signedInJon(minutes: 400);
      final before = h.session!.expiresAt!;

      await h.repository.setInactivityTimeout('jon', 100);
      await h.notifier.refreshGroupsFromRoles();

      expect(h.session!.inactivityTimeout, const Duration(milliseconds: 1000));
      expect(h.session!.expiresAt!.isBefore(before), isTrue,
          reason: 'an administrator narrowing the window must narrow the '
              'session already running under it');
      expect(h.session!.isElevated, isTrue,
          reason: 'narrowed, not ended — there is time left on the new value');
      expect(h.notifier.timerIsRunning, isTrue,
          reason: 'the monitor counts the old value until it is replaced, so '
              'the swap has to re-arm one for the new one');
    });

    test('lengthening it mid-session does not extend the session', () async {
      final h = await signedInJon(minutes: 200);
      final before = h.session!.expiresAt!;

      await h.repository.setInactivityTimeout('jon', 400);
      await h.notifier.refreshGroupsFromRoles();

      expect(h.session!.expiresAt, before,
          reason: 'an edit in another tab is not activity at the panel; the '
              'wider window applies from the next pointer-down');
    });

    test('a shortened window is persisted, so a restart cannot restore the '
        'wider one', () async {
      final h = await signedInJon(minutes: 400);

      await h.repository.setInactivityTimeout('jon', 100);
      await h.notifier.refreshGroupsFromRoles();

      final stored = jsonDecode((await h.storedPayload())!) as Map;
      expect(DateTime.parse(stored['expiresAt'] as String).toUtc(),
          h.session!.expiresAt!.toUtc());
    });

    test('the timeout is re-resolved on restore, and the payload cannot widen '
        'it', () async {
      // The payload deliberately carries no timeout — like the groups and the
      // pages, it is re-read from the row. A stored expiry further out than
      // the account's current window is pulled in.
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
          username: 'jon', password: 'correct horse', roleName: 'Engineering');
      await h.repository.setInactivityTimeout('jon', 50);
      await h.writeStoredPayload(jsonEncode({
        'username': 'jon',
        'roleName': 'Engineering',
        'displayName': null,
        'expiresAt':
            clock.now().add(const Duration(days: 1)).toUtc().toIso8601String(),
      }));

      final restart = await _harness(reuseDb: h.db);
      final session = await restart.settle();

      expect(session.isElevated, isTrue);
      expect(session.inactivityTimeout, const Duration(milliseconds: 500));
      expect(
          session.expiresAt!
              .isBefore(clock.now().add(const Duration(minutes: 1))),
          isTrue,
          reason: 'a hand-edited payload naming a far-future expiry must not '
              'outlive the window the administrator set');
    });
  });

  // -------------------------------------------------------------------------
  // More than one role (schema v9)
  // -------------------------------------------------------------------------

  group('several roles', () {
    test('the session holds the union of what its roles grant', () async {
      // Shift Leader has no `device` and no `force`; Maintenance has both and
      // no `configure`. Holding both must grant everything either grants.
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();

      await h.notifier.signIn('sigga', 'hunter2');

      final session = h.session!;
      expect(session.roleNames, ['Shift Leader', 'Maintenance']);
      expect(session.can(AccessGroup.setpoints), isTrue,
          reason: 'from Shift Leader');
      expect(session.can(AccessGroup.device), isTrue, reason: 'from Maintenance');
      expect(session.can(AccessGroup.force), isTrue, reason: 'from Maintenance');
      expect(session.can(AccessGroup.configure), isFalse,
          reason: 'neither role grants it, and a union invents nothing');
    });

    test('the primary role is identity, not precedence', () async {
      // `Operator` primarily, `Engineering` additionally. What the account may
      // do comes from both, so it administers — a resolution that looked only
      // at `role_name` would deny it.
      final h = await _harness(
        users: {'jon': (password: 'correct horse', roleName: kOperatorRoleName)},
        extraRoles: {
          'jon': ['Engineering'],
        },
      );
      await h.settle();

      await h.notifier.signIn('jon', 'correct horse');

      expect(h.session!.roleName, kOperatorRoleName);
      expect(h.session!.can(AccessGroup.administer), isTrue);
    });

    test('the trail row names every role, not just the first', () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();

      await h.notifier.signIn('sigga', 'hunter2');

      final login = h.sink.rows.firstWhere((r) => r.itemKey == 'login');
      expect(login.roleName, 'Shift Leader + Maintenance',
          reason: 'a row saying only the primary role would misdescribe the '
              'authority a write was made under');
    });

    test('page whitelists union across the roles', () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();
      await h.repository.setRoleAllowedPages('Shift Leader', {'/line'});
      await h.repository.setRoleAllowedPages('Maintenance', {'/drives'});

      await h.notifier.signIn('sigga', 'hunter2');

      expect(h.session!.allowedPages, {'/line', '/drives'});
      expect(h.session!.pageVisible('/line'), isTrue);
      expect(h.session!.pageVisible('/packing'), isFalse);
    });

    test('a role with no whitelist admits every page for the whole account',
        () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();
      await h.repository.setRoleAllowedPages('Shift Leader', {'/line'});

      await h.notifier.signIn('sigga', 'hunter2');

      expect(h.session!.allowedPages, isNull,
          reason: 'Maintenance has no whitelist, so it sees every page — and '
              'binding it to the other role would make adding a role *remove* '
              'pages');
    });

    test('the personal override still replaces the whole role level',
        () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();
      await h.repository.setRoleAllowedPages('Shift Leader', {'/line'});
      await h.repository.setRoleAllowedPages('Maintenance', {'/drives'});
      await h.repository.createUser(
        username: 'sigga',
        password: 'hunter2',
        roleName: 'Shift Leader',
        additionalRoles: ['Maintenance'],
      );
      await h.repository.setUserAllowedPages('sigga', {'/only'});

      await h.notifier.signIn('sigga', 'hunter2');

      expect(h.session!.allowedPages, {'/only'});
    });

    test('an extra role that has been deleted is dropped, not a refusal',
        () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Ghost'],
      });
      await h.settle();

      final result = await h.notifier.signIn('sigga', 'hunter2');

      expect(result, AccessSignInResult.ok);
      expect(h.session!.roleNames, ['Shift Leader'],
          reason: 'the session answers as the roles that actually resolved; '
              'refusing the login would lock somebody out because a second '
              'role they held was deleted on another station');
    });

    test('a role added on another station reaches a live session', () async {
      final h = await _harness();
      await h.settle();
      await h.repository.createUser(
        username: 'jon',
        password: 'correct horse',
        roleName: kOperatorRoleName,
      );
      h.auth.users['jon'] =
          (password: 'correct horse', roleName: kOperatorRoleName);
      _listen(h);
      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.can(AccessGroup.administer), isFalse);

      // Somebody on the access screen ticks a second role.
      await h.repository.setRoles('jon', [kOperatorRoleName, 'Engineering']);
      await h.notifier.refreshGroupsFromRoles();

      expect(h.session!.roleNames, [kOperatorRoleName, 'Engineering']);
      expect(h.session!.can(AccessGroup.administer), isTrue,
          reason: 'a second role must take effect the way a role edit does — '
              'without the person signing out and back in');
    });

    test('a restart re-resolves every role from the database', () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();
      await h.notifier.signIn('sigga', 'hunter2');
      expect(h.session!.roleNames, ['Shift Leader', 'Maintenance']);

      // The same database and the same preference store: a relaunch.
      final again = await _harness(reuseDb: h.db, extraRoles: {
        'sigga': ['Maintenance'],
      });
      final restored = await again.settle();

      expect(restored.isElevated, isTrue);
      expect(restored.roleNames, ['Shift Leader', 'Maintenance']);
      expect(restored.can(AccessGroup.device), isTrue);
    });

    test('an extra role deleted while the station was off does not restore',
        () async {
      final h = await _harness(extraRoles: {
        'sigga': ['Maintenance'],
      });
      await h.settle();
      await h.notifier.signIn('sigga', 'hunter2');

      await h.repository.deleteRole('Maintenance');
      final again = await _harness(reuseDb: h.db, extraRoles: {
        'sigga': ['Maintenance'],
      });
      final restored = await again.settle();

      expect(restored.isElevated, isTrue,
          reason: 'the primary role still resolves, so the account keeps its '
              'session');
      expect(restored.roleNames, ['Shift Leader']);
      expect(restored.can(AccessGroup.device), isFalse,
          reason: 'the payload stores names, never groups — so a role that is '
              'gone takes its groups with it');
    });
  });

  group('the retired per-station settings', () {
    test('are removed from the device-local store at boot', () async {
      // Support reads the preferences mirror. A stale `true` disable flag
      // sitting in it would look like it still meant something — and it is
      // exactly the setting whose replacement (a station account) somebody
      // will need to be told about.
      final h = await _harness();
      final prefs = h.container.read(localPreferencesProvider);
      await prefs.setInt('access.inactivity_timeout_minutes', 45);
      await prefs.setBool('access.inactivity_timeout_disabled', true);

      final restart = await _harness(reuseDb: h.db);
      await restart.settle();

      final after = restart.container.read(localPreferencesProvider);
      expect(await after.containsKey('access.inactivity_timeout_minutes'),
          isFalse);
      expect(await after.containsKey('access.inactivity_timeout_disabled'),
          isFalse);
    });

    test('a session under the old disable flag now expires like any other',
        () async {
      // The upgrade's one behavioural change, asserted rather than assumed:
      // the flag is ignored, so a human signing in on a panel that had it set
      // gets their account's window.
      final h = await _harness(timeout: const Duration(milliseconds: 200));
      await h.container
          .read(localPreferencesProvider)
          .setBool('access.inactivity_timeout_disabled', true);
      await h.settle();
      _listen(h);

      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.expiresAt, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(h.session!.isElevated, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Self-service password change
  //
  // Four results, and the two of them that write a row. The assertions that
  // matter most here are the negative ones: that the session comes out of a
  // successful change *identical*, and that neither password reaches the
  // trail.
  // -------------------------------------------------------------------------
  group('changeOwnPassword', () {
    /// A harness with somebody already signed in.
    Future<_Harness> signedIn({
      Set<String> stationAccounts = const {},
    }) async {
      final h = await _harness(stationAccounts: stationAccounts);
      await h.settle();
      _listen(h);
      await h.notifier.signIn(
        stationAccounts.contains('freezer') ? 'freezer' : 'jon',
        stationAccounts.contains('freezer') ? 'cold' : 'correct horse',
      );
      return h;
    }

    test('the right current password changes it and writes one row', () async {
      final h = await signedIn();
      final before = h.session!;
      final storedBefore = await h.storedPayload();
      h.sink.rows.clear();

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'correct horse',
        newPassword: 'battery staple',
      );

      expect(result, AccessPasswordChangeResult.ok);
      expect(h.authItemKeys, ['password.change']);

      final row = h.sink.rows.single;
      expect(row.surface, 'auth');
      expect(row.who, 'jon');
      expect(row.station, _kStation);
      expect(row.roleName, 'Engineering');
      expect(row.allowed, isTrue);
      expect(row.groupRequired, isEmpty,
          reason: 'self-service is gated on nothing, and the row must say so');

      // The new password works and the old one does not — asserted through the
      // fake's own store rather than through the controller.
      expect(await h.auth.authenticate('jon', 'battery staple'), isNotNull);
      expect(await h.auth.authenticate('jon', 'correct horse'), isNull);

      // The session is untouched: same identity, same role, same expiry.
      final after = h.session!;
      expect(after.isElevated, isTrue);
      expect(after.user!.username, before.user!.username);
      expect(after.roleName, before.roleName);
      expect(after.expiresAt, before.expiresAt,
          reason: 'a password change is not activity — the countdown must not '
              'be extended by it');
      expect(await h.storedPayload(), storedBefore,
          reason: 'and nothing re-persisted it — the in-memory expiry being '
              'unchanged would not catch a `_persist` that rewrote the same '
              'value with a new clock');
    });

    test('neither password reaches the audit row', () async {
      final h = await signedIn();
      h.sink.rows.clear();

      await h.notifier.changeOwnPassword(
        currentPassword: 'correct horse',
        newPassword: 'battery staple',
      );

      final dumped = h.sink.rows.map((r) => r.toString()).join('\n');
      expect(dumped, isNot(contains('correct horse')));
      expect(dumped, isNot(contains('battery staple')));
      for (final row in h.sink.rows) {
        expect(row.oldValue, isNull);
        expect(row.newValue, isNull);
        expect(row.reason, isNull);
      }
    });

    test('a wrong current password refuses and writes the failure', () async {
      final h = await signedIn();
      final before = h.session!;
      h.sink.rows.clear();

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'not it',
        newPassword: 'battery staple',
      );

      expect(result, AccessPasswordChangeResult.wrongCurrentPassword);
      expect(h.authItemKeys, ['password.change.failed']);
      expect(h.sink.rows.single.allowed, isFalse);
      expect(h.sink.rows.single.who, 'jon');

      // Nothing changed, and the session is intact.
      expect(await h.auth.authenticate('jon', 'correct horse'), isNotNull);
      expect(h.session!.expiresAt, before.expiresAt);
      expect(h.session!.isElevated, isTrue);
    });

    test('nobody signed in is its own answer', () async {
      final h = await _harness();
      await h.settle();

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'correct horse',
        newPassword: 'battery staple',
      );

      expect(result, AccessPasswordChangeResult.notSignedIn);
      expect(h.authItemKeys, isEmpty,
          reason: 'nothing was attempted, so nothing is worth recording');
    });

    test('an outage is unavailable and writes no row', () async {
      // The rule `signIn` keeps, kept here too: a database blip must not land
      // in the trail as somebody failing to change their password.
      final h = await signedIn();
      h.sink.rows.clear();
      h.auth.changeUnavailable = true;

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'correct horse',
        newPassword: 'battery staple',
      );

      expect(result, AccessPasswordChangeResult.unavailable);
      expect(h.sink.rows, isEmpty);
      expect(h.session!.isElevated, isTrue,
          reason: 'an outage must not sign anybody out');
    });

    test('no database is unavailable', () async {
      final h = await _harness(withDatabase: false);
      await h.settle();

      expect(
        await h.notifier.changeOwnPassword(
          currentPassword: 'correct horse',
          newPassword: 'battery staple',
        ),
        AccessPasswordChangeResult.notSignedIn,
        reason: 'with no database nobody is signed in, and that is the more '
            'useful of the two true answers',
      );
    });

    test('a provider without the capability is unavailable', () async {
      // The OIDC shape. `access_status_action.dart` would not offer the menu in
      // this state either, so reaching here means a second call site — and it
      // must refuse rather than throw.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();
      final sink = _RecordingSink();

      final container = ProviderContainer(
        overrides: [
          accessRepositoryProvider
              .overrideWith((ref) async => AccessRepository(db)),
          authProviderProvider
              .overrideWith((ref) async => _NoSelfServiceAuthProvider()),
          auditSinkProvider.overrideWith((ref) async => sink),
          stationNameProvider.overrideWithValue(_kStation),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(accessSessionProvider.notifier);
      await container.read(accessSessionProvider.future);
      await notifier.signIn('jon', 'anything');

      expect(
        await notifier.changeOwnPassword(
          currentPassword: 'anything',
          newPassword: 'battery staple',
        ),
        AccessPasswordChangeResult.unavailable,
      );
      expect(
        sink.rows.where((r) => r.itemKey.startsWith('password.')),
        isEmpty,
      );
    });

    test('a station account is refused and records nothing', () async {
      // Belt and braces behind `access_status_action.dart`, which does not
      // offer the menu for these sessions at all. A station account's password
      // is commissioning material: it is shared, so "your own password" is not
      // a thing it has, and it belongs to an administrator on the users screen.
      final h = await _harness(
        users: {'freezer': (password: 'cold', roleName: 'Operator')},
        stationAccounts: const {'freezer'},
      );
      await h.settle();
      _listen(h);
      await h.notifier.signIn('freezer', 'cold');
      h.sink.rows.clear();

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'cold',
        newPassword: 'warm',
      );

      expect(result, AccessPasswordChangeResult.unavailable);
      expect(h.sink.rows, isEmpty);
      expect(await h.auth.authenticate('freezer', 'cold'), isNotNull,
          reason: 'the refusal must be before the write, not after it');
    });

    test('an account deleted mid-session drops the session', () async {
      // Not a wrong password and not an outage. The session is floored, and the
      // answer matches what the app bar is about to show: no identity. A
      // message about a log beside a badge that just disappeared would describe
      // a different event from the one on screen.
      final h = await signedIn();
      h.sink.rows.clear();

      // The row is inserted and then deleted, rather than never existing.
      // `refreshGroupsFromRoles` drops on `repo.user()` returning null, so a
      // test with no row at all passes for the wrong reason — it would keep
      // passing if the delete stopped happening. Written straight through
      // drift because `AccessRepository.deleteUser` refuses to remove the last
      // account holding `users`, and this test is about what becomes of a
      // session whose row is gone, not about how it went.
      await h.db.into(h.db.appUser).insert(AppUserCompanion.insert(
            username: 'jon',
            roleName: 'Engineering',
            // Never verified: the auth provider is faked, and nothing on this
            // path reads the stored form.
            passwordHash: 'unused-by-this-test',
            salt: 'unused-by-this-test',
            createdAt: DateTime.utc(2026, 1, 1),
          ));
      expect(await h.repository.user('jon'), isNotNull);

      await (h.db.delete(h.db.appUser)
            ..where((t) => t.username.equals('jon')))
          .go();
      h.auth.vanished.add('jon');

      final result = await h.notifier.changeOwnPassword(
        currentPassword: 'correct horse',
        newPassword: 'battery staple',
      );

      expect(result, AccessPasswordChangeResult.notSignedIn);
      expect(h.session!.isElevated, isFalse);
      expect(
        h.sink.rows.where((r) => r.itemKey.startsWith('password.')),
        isEmpty,
        reason: 'an account being gone is not a password event',
      );
    });
  });
}
