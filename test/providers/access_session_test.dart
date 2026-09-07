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
class _FakeAuthProvider implements AuthProvider {
  _FakeAuthProvider(this.users, {this.stationAccounts = const {}});

  /// username -> (password, roleName)
  final Map<String, ({String password, String roleName})> users;

  /// Usernames flagged as station accounts (schema v8).
  final Set<String> stationAccounts;

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
      stationAccount: stationAccounts.contains(username),
    );
  }
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
}

const String _kStation = 'test-panel';

Future<_Harness> _harness({
  Duration? timeout = const Duration(minutes: 15),
  Map<String, ({String password, String roleName})>? users,
  Set<String> stationAccounts = const {},
  bool withDatabase = true,
}) async {
  final db = AppDatabase.inMemoryForTest();
  addTearDown(() => db.close());
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
      stationAccounts: stationAccounts);
  final sink = _RecordingSink();

  final container = ProviderContainer(
    overrides: [
      accessRepositoryProvider
          .overrideWith((ref) async => withDatabase ? repository : null),
      authProviderProvider.overrideWith((ref) async => withDatabase ? auth : null),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      inactivityTimeoutProvider.overrideWith((ref) async => timeout),
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

    test('with expiry disabled, the session never expires and poke leaves it '
        'that way', () async {
      // The panel-PC station account: sign in once at commissioning, live
      // signed in forever. `expiresAt: null` is the model's own "never" —
      // `isExpiredAt` already treats it so — and _attach declines to arm a
      // monitor for it, so there is no countdown to fire.
      final h = await _harness(timeout: null);
      await h.settle();

      await h.notifier.signIn('jon', 'correct horse');
      expect(h.session!.isElevated, isTrue);
      expect(h.session!.expiresAt, isNull);

      h.notifier.poke();
      await h.settle();
      expect(h.session!.expiresAt, isNull,
          reason: 'an activity extension must not conjure an expiry onto a '
              'session configured to have none');
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
          auditSinkProvider.overrideWith((ref) async => _RecordingSink()),
          stationNameProvider.overrideWithValue(_kStation),
          inactivityTimeoutProvider
              .overrideWith((ref) async => throw StateError('no prefs')),
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
}
