// The wiring that turns the seam on.
//
// 04-01 built `TagBindingResolver`, 04-03 built `AccessTemplateStore`, 04-04
// taught the guard to ask per member. Nothing connected them. These tests are
// about the connection, and about the one property the connection must not
// cost: a template edit must not rebuild `stateManProvider`, because that
// provider holds every OPC UA connection on the panel.
//
// The boot property — that the snapshot loads without anybody opening the key
// repository — lives in `access_templates_boot_test.dart`, deliberately in its
// own file so a reviewer can find it by name.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// The `Database` wrapper `databaseProvider` yields, over an in-memory Drift
/// database. Only `db` is reached by anything under test.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;
}

class _FakeStateMan extends Fake implements StateMan {
  @override
  List<String> get keys => const ['ST101.CN01'];
}

/// A store whose two reads can be made to throw, for the Postgres-blink case.
class _FlakyStore extends Fake implements AccessTemplateStore {
  _FlakyStore(this.inner);

  final AccessTemplateStore inner;
  bool throwing = false;

  @override
  Future<List<AccessTemplate>> list() async {
    if (throwing) throw StateError('the template database blinked');
    return inner.list();
  }

  @override
  Future<Map<String, String>> bindings() async {
    if (throwing) throw StateError('the template database blinked');
    return inner.bindings();
  }
}

class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;

  /// A sign-in, without any explicit invalidation of anything downstream.
  void becomeSignedIn(AccessSession next) {
    _session = next;
    state = AsyncData(next);
  }
}

/// A session that never resolves, for the boot-window floor.
class _NeverSession extends AccessSessionController {
  @override
  Future<AccessSession> build() => Completer<AccessSession>().future;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String _kKey = 'ST101.CN01';
const String _kJog = 'p_cmd_JogFwd';
const String _kManualFreq = 'p_cfg_ManualFreq';

/// The phase's acceptance criterion in one template: the conveyor's frequency
/// needs `device` to change, but jogging it stays `operate`.
AccessTemplate _conveyor() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        _kManualFreq: AccessGroup.device,
        _kJog: AccessGroup.operate,
      },
    );

AccessSession _anonymous() => AccessSession.anonymous(const {
      AccessGroup.operate,
    });

AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

AccessSession _withDevice() => const AccessSession(
      user: AuthenticatedUser(username: 'jon', roleName: 'Maintenance'),
      groups: {AccessGroup.operate, AccessGroup.device},
    );

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() => db.close());

  /// A container with a real store over the in-memory database.
  ({ProviderContainer container, _FixedSession session}) wired({
    AccessSession? session,
    List<Override> extra = const [],
  }) {
    final notifier = _FixedSession(session ?? _withUsers());
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
      accessSessionProvider.overrideWith(() => notifier),
      // 17-12: the store provider consults the transport row before choosing
      // its route; an empty device-local store reads as direct mode.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      ...extra,
    ]);
    addTearDown(container.dispose);
    return (container: container, session: notifier);
  }

  /// A container with no database at all — the commissioned-without-Postgres
  /// station.
  ProviderContainer databaseless() {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => null),
      accessSessionProvider.overrideWith(() => _FixedSession(_anonymous())),
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// A store straight onto the in-memory database, holding `users`.
  ///
  /// These tests are about the loader and the resolver, not about the gate —
  /// 04-03's own suite drives a `configure`-only session into all six writes.
  /// Seeding through a store of its own also keeps the fixtures independent of
  /// whichever session a container happens to be in.
  AccessTemplateStore rawStore() => AccessTemplateStore(
        db: db,
        session: _withUsers,
        audit: const NullAuditSink(),
        station: 'test',
      );

  Future<void> seedConveyor({bool bind = true}) async {
    final store = rawStore();
    await store.create(_conveyor());
    if (bind) await store.bind(_kKey, 'conveyor');
  }

  // -------------------------------------------------------------------------
  // The resolver
  // -------------------------------------------------------------------------

  group('tagBindingResolverProvider', () {
    test('is one object for the life of the container', () {
      final w = wired();
      expect(
          identical(w.container.read(tagBindingResolverProvider),
              w.container.read(tagBindingResolverProvider)),
          isTrue);
    });

    test('starts neverLoaded, which is not the same value as loaded-and-empty',
        () {
      final w = wired();
      expect(w.container.read(tagBindingResolverProvider).state,
          TagBindingSnapshotState.neverLoaded);
    });

    test('keeps its identity across two loads, and the answers still move',
        () async {
      final w = wired();
      final resolver = w.container.read(tagBindingResolverProvider);

      await w.container.read(accessTemplatesProvider.future);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.operate);

      await seedConveyor();
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);

      expect(
          identical(resolver, w.container.read(tagBindingResolverProvider)),
          isTrue,
          reason:
              'a rebuilt resolver would mean a rebuilt accessPolicyProvider '
              'and, through it, a rebuilt stateManProvider — every OPC UA '
              'connection on the panel dropped by a template edit');
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device,
          reason: 'the identity cannot be preserved by the snapshot having '
              'failed to land');
    });
  });

  // -------------------------------------------------------------------------
  // The store provider
  // -------------------------------------------------------------------------

  group('accessTemplateStoreProvider', () {
    test('is null when the station has no database', () async {
      expect(await databaseless().read(accessTemplateStoreProvider.future),
          isNull);
    });

    test('is a store when there is one', () async {
      final w = wired();
      expect(await w.container.read(accessTemplateStoreProvider.future),
          isA<AccessTemplateStore>());
    });

    test('takes the session at write time, so a sign-in does not rebuild it',
        () async {
      final w = wired(session: _anonymous());
      await w.container.read(accessSessionProvider.future);
      final before = await w.container.read(accessTemplateStoreProvider.future);

      w.session.becomeSignedIn(_withUsers());
      await Future<void>.delayed(Duration.zero);

      final after = await w.container.read(accessTemplateStoreProvider.future);
      expect(identical(before, after), isTrue,
          reason: 'a watch on the session here would rebuild the store and '
              'its database handle on every sign-in');
      // And the new session is the one the gate consults: the write succeeds.
      await after!.create(_conveyor());
      expect(await after.list(), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // The loader
  // -------------------------------------------------------------------------

  group('accessTemplatesProvider', () {
    test('reads both tables into one snapshot', () async {
      final w = wired();
      await seedConveyor();

      w.container.invalidate(accessTemplatesProvider);
      final templates = await w.container.read(accessTemplatesProvider.future);
      final resolver = w.container.read(tagBindingResolverProvider);

      expect(templates.map((t) => t.name), ['conveyor']);
      expect(resolver.templateCount, 1);
      expect(resolver.boundKeyCount, 1,
          reason: 'applying the templates without the bindings leaves a '
              'window in which every binding dangles');
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device);
      expect(resolver.groupFor(_kKey, _kJog), AccessGroup.operate);
      expect(resolver.state, TagBindingSnapshotState.loaded);
    });

    test('with no database sets an empty snapshot and does not throw',
        () async {
      final container = databaseless();
      final templates = await container.read(accessTemplatesProvider.future);

      expect(templates, isEmpty);
      final resolver = container.read(tagBindingResolverProvider);
      expect(resolver.state, TagBindingSnapshotState.loaded,
          reason: 'a station with no database binds nothing deliberately, and '
              'must not read as one whose snapshot never loaded');
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.operate,
          reason: 'no database means no bindings, and no binding means the '
              'operate floor — not unrestricted (2026-09-02 ruling)');
    });

    test('a binding write followed by an invalidate changes the answer',
        () async {
      final w = wired();
      await seedConveyor(bind: false);
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);
      final resolver = w.container.read(tagBindingResolverProvider);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.operate);

      await rawStore().bind(_kKey, 'conveyor');
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);

      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device);
    });

    test('a template edit followed by an invalidate changes the answer',
        () async {
      final w = wired();
      await seedConveyor();
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);
      final resolver = w.container.read(tagBindingResolverProvider);
      expect(resolver.groupFor(_kKey, _kJog), AccessGroup.operate);

      await rawStore().update(AccessTemplate(
          name: 'conveyor', rules: const {_kJog: AccessGroup.device}));
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);

      expect(resolver.groupFor(_kKey, _kJog), AccessGroup.device);
    });

    test(
        'loading twice with the same data changes neither the answers nor '
        'the identity', () async {
      final w = wired();
      await seedConveyor();

      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);
      final resolver = w.container.read(tagBindingResolverProvider);
      final first = resolver.groupFor(_kKey, _kManualFreq);

      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);

      expect(identical(resolver, w.container.read(tagBindingResolverProvider)),
          isTrue);
      expect(resolver.groupFor(_kKey, _kManualFreq), first);
      expect(resolver.state, TagBindingSnapshotState.loaded);
    });

    test('a throwing store leaves the previous snapshot answering as before',
        () async {
      late _FlakyStore flaky;
      final w = wired(extra: [
        accessTemplateStoreProvider
            .overrideWith((ref) async => flaky = _FlakyStore(rawStore())),
      ]);
      await w.container.read(accessTemplateStoreProvider.future);
      await seedConveyor();
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);
      final resolver = w.container.read(tagBindingResolverProvider);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device);

      flaky.throwing = true;
      w.container.invalidate(accessTemplatesProvider);
      await expectLater(
          w.container.read(accessTemplatesProvider.future), throwsStateError);

      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device,
          reason: 'a Postgres blink must not silently unrestrict every bound '
              'key on the panel for the duration of a retry');
      expect(resolver.state, TagBindingSnapshotState.stale,
          reason: 'the answers are unchanged and the fact that they are old '
              'is carried by state, exactly as markStale promises');
    });

    test('a first load that fails leaves the resolver at neverLoaded',
        () async {
      final w = wired(extra: [
        accessTemplateStoreProvider.overrideWith((ref) async =>
            _FlakyStore(rawStore())..throwing = true),
      ]);

      await expectLater(
          w.container.read(accessTemplatesProvider.future), throwsStateError);
      expect(w.container.read(tagBindingResolverProvider).state,
          TagBindingSnapshotState.neverLoaded,
          reason: 'markStale is a no-op on neverLoaded: there is no previous '
              'snapshot to call stale');
    });
  });

  // -------------------------------------------------------------------------
  // The two properties the source has to carry
  // -------------------------------------------------------------------------

  group('the source of lib/providers/access_templates.dart', () {
    /// Comment lines stripped, so the comment naming a rule cannot satisfy the
    /// test enforcing it.
    String code() => File('lib/providers/access_templates.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('registers no preferences-changed listener', () {
      // Bindings left the key-mapping blob in the 2026-08-30 ruling, so a
      // key-mapping save cannot change one and there is nothing here to
      // subscribe to. `stateManProvider` next door *does* listen, so the
      // omission would read as an oversight — T-04-28 makes it an assertion
      // instead. A listener in long-lived plumbing is also the always-on
      // subscription spec §10 forbids.
      expect(code(), isNot(contains('onPreferencesChanged')),
          reason: 'there is nothing here to listen to, and a listener in '
              'keepAlive plumbing is a leak with no owner');
      expect(code(), isNot(contains('preferencesProvider')));
    });

    test(
        'every use of accessSessionProvider is a read, save the one watch '
        'tagAccessProvider makes on purpose', () {
      // The idiom is `guard_wiring_test.dart:135-139`'s, not a zero-grep: a
      // flat "must not appear" gate would be unsatisfiable the moment
      // `tagAccessProvider` lands, and a gate a later task has to delete is
      // worse than no gate. The property that actually holds is that every
      // *other* use is a `ref.read` at write time.
      //
      // The exemption, named with its reason: a widget must rebuild on
      // sign-in so a control stops rendering a lock the moment the operator
      // is allowed through it. The plant connection must not. Both facts are
      // true at once, and this constant is where the difference is declared.
      const deliberateWatch = 'ref.watch(accessSessionProvider)';

      final source = code();
      expect(deliberateWatch.allMatches(source).length, 1,
          reason: 'exactly one deliberate watch, inside tagAccessProvider');

      final rest = source.replaceAll(deliberateWatch, '');
      final uses = 'accessSessionProvider'.allMatches(rest).length;
      final reads = 'ref.read(accessSessionProvider'.allMatches(rest).length;
      expect(reads, uses,
          reason: 'every other use of the session here must be a ref.read at '
              'write time — a watch would rebuild the store, and with it a '
              'database handle, on every sign-in');
    });
  });

  // -------------------------------------------------------------------------
  // Task 2: the policy, and the synchronous answer widgets get
  // -------------------------------------------------------------------------

  group('accessPolicyProvider now answers for real', () {
    test('a bound key resolves through the policy once the snapshot loads',
        () async {
      final w = wired();
      await seedConveyor();
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);

      final policy = w.container.read(accessPolicyProvider);
      expect(
          policy.groupForTag(_kKey, member: _kManualFreq), AccessGroup.device);
      expect(policy.groupForTag(_kKey, member: _kJog), AccessGroup.operate);
      expect(policy.groupForTag('ST999.UNBOUND', member: _kManualFreq),
          AccessGroup.operate,
          reason: 'every unbound key answers the operate floor — the '
              '2026-09-02 ruling replacing spec §7b\'s fail-open half');
    });

    test(
        'is still one instance, and a template load does not rebuild '
        'stateManProvider', () async {
      var stateManBuilds = 0;
      final w = wired(extra: [
        stateManProvider.overrideWith((ref) async {
          stateManBuilds++;
          // `watch`, where production uses `read`. A read would make this test
          // vacuous — it could not observe an invalidation even if one
          // happened. The watch is what turns "the policy was invalidated"
          // into a failure here.
          ref.watch(accessPolicyProvider);
          return _FakeStateMan();
        }),
      ]);
      await w.container.read(stateManProvider.future);
      final policyBefore = w.container.read(accessPolicyProvider);
      expect(stateManBuilds, 1);

      await seedConveyor();
      w.container.invalidate(accessTemplatesProvider);
      await w.container.read(accessTemplatesProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(stateManBuilds, 1,
          reason: 'T-04-25: a template edit that rebuilt stateManProvider '
              'would drop every OPC UA connection on the panel');
      expect(identical(policyBefore, w.container.read(accessPolicyProvider)),
          isTrue);
      expect(
          w.container
              .read(accessPolicyProvider)
              .groupForTag(_kKey, member: _kManualFreq),
          AccessGroup.device,
          reason: 'and the same instance answers the new binding, which is '
              'the whole point of the callback on a mutable resolver');
    });
  });

  group('tagAccessProvider', () {
    Future<TagAccess> loaded(ProviderContainer container) async {
      await seedConveyor();
      container.invalidate(accessTemplatesProvider);
      await container.read(accessTemplatesProvider.future);
      return container.read(tagAccessProvider);
    }

    test(
        'an anonymous session may jog the bound conveyor but may not '
        'reconfigure it', () async {
      final w = wired(session: _anonymous());
      final access = await loaded(w.container);

      expect(access.canWrite(_kKey, member: _kJog), isTrue);
      expect(access.canWrite(_kKey, member: _kManualFreq), isFalse);
    });

    test('an unbound key is writable for anonymous — the Operator role holds '
        'the operate floor', () async {
      final w = wired(session: _anonymous());
      final access = await loaded(w.container);

      expect(access.groupFor('ST999.UNBOUND', member: _kManualFreq),
          AccessGroup.operate);
      expect(access.canWrite('ST999.UNBOUND', member: _kManualFreq), isTrue,
          reason: 'the anonymous session maps to Operator, which holds '
              'operate — the floor locks nothing on a stock station');
    });

    test('templateFor names the template a key is bound to', () async {
      final w = wired(session: _anonymous());
      final access = await loaded(w.container);

      expect(access.templateFor(_kKey)?.name, 'conveyor');
      expect(access.templateFor('ST999.UNBOUND'), isNull);
    });

    test(
        'TagAccess and AccessPolicy give the same answer for both conveyor '
        'members, through one container', () async {
      // T-04-27. Two objects deciding one question by different routes is
      // precisely how a control ends up locked against a write that would
      // have succeeded, or open in front of one that will be refused.
      final w = wired(session: _anonymous());
      final access = await loaded(w.container);
      final policy = w.container.read(accessPolicyProvider);
      final session = _anonymous();

      for (final member in const [_kJog, _kManualFreq, 'p_stat_Running']) {
        final group = policy.groupForTag(_kKey, member: member);
        expect(access.groupFor(_kKey, member: member), group,
            reason: 'the UI and the guard must resolve $member identically');
        final guardWouldAllow = group == null || session.can(group);
        expect(access.canWrite(_kKey, member: member), guardWouldAllow,
            reason: 'the lock the UI renders for $member must match the '
                'decision the guard will take for the same write');
      }
    });

    test('a sign-in changes canWrite with no explicit invalidation', () async {
      final w = wired(session: _anonymous());
      await w.container.read(accessSessionProvider.future);
      await loaded(w.container);
      expect(
          w.container
              .read(tagAccessProvider)
              .canWrite(_kKey, member: _kManualFreq),
          isFalse);

      w.session.becomeSignedIn(_withDevice());
      await w.container.read(accessSessionProvider.future);

      expect(
          w.container
              .read(tagAccessProvider)
              .canWrite(_kKey, member: _kManualFreq),
          isTrue,
          reason: 'a widget must re-render on sign-in, which is why this one '
              'provider watches the session where the store must not');
    });

    test(
        'while the session is still loading it resolves on '
        'kSessionWhileLoading', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
        accessSessionProvider.overrideWith(_NeverSession.new),
        localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      ]);
      addTearDown(container.dispose);
      final access = await loaded(container);

      for (final member in const [_kJog, _kManualFreq]) {
        final group = access.groupFor(_kKey, member: member);
        expect(access.canWrite(_kKey, member: member),
            group == null || kSessionWhileLoading.can(group),
            reason: 'T-04-29: a control must not render unlocked and then '
                'lock a frame later');
      }
      expect(access.canWrite(_kKey, member: _kManualFreq), isFalse);
    });

    test('no member of TagAccess returns a future', () {
      // Spec §7b's tap-time requirement, and the thing the 2026-08-30 ruling
      // put at risk by moving bindings into a table. An `await` anywhere in
      // this chain would pass every other test in this plan and silently end
      // tap-time elevation, so the signatures are derived from source rather
      // than assumed.
      final source =
          File('lib/providers/access_templates.dart').readAsStringSync();
      final start = source.indexOf('class TagAccess {');
      expect(start, greaterThan(-1));
      final end = source.indexOf('\n}', start);
      final body = source.substring(start, end);

      expect(body, isNot(contains('Future')),
          reason: 'no member of TagAccess may return one — the prompt appears '
              'when the control is tapped, not when a write fails');
      expect(body, isNot(contains('async')));

      // And statically, so a signature change stops compiling rather than
      // merely failing a grep.
      final w = wired();
      final TagAccess access = w.container.read(tagAccessProvider);
      final AccessGroup Function(String, {String? member}) groupFor =
          access.groupFor;
      final bool Function(String, {String? member}) canWrite = access.canWrite;
      final AccessTemplate? Function(String) templateFor = access.templateFor;
      expect(groupFor(_kKey, member: _kJog), AccessGroup.operate);
      expect(canWrite(_kKey, member: _kJog), isTrue);
      expect(templateFor(_kKey), isNull);
    });
  });

  group('the source of lib/providers/access_policy.dart', () {
    String source() =>
        File('lib/providers/access_policy.dart').readAsStringSync();

    test(
        'the "no lookup is supplied" paragraph is gone, replaced by one that '
        'says what is', () {
      final code = source();
      expect(code, isNot(contains('No [TagBindingLookup] is supplied')),
          reason: 'that paragraph explained a decision that has changed; it '
              'is rewritten, not deleted');
      expect(code, contains('tagBindingResolverProvider'));
      expect(code, contains('TagBindingLookup'),
          reason: 'the replacement paragraph still has to name what is '
              'supplied and why it is a callback on a mutable object');
    });

    test('the policy reads the resolver and never the loader', () {
      final code = File('lib/providers/access_policy.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      expect(
          code, contains('tagBindings: ref.read(tagBindingResolverProvider)'));
      expect(code, isNot(contains('ref.watch(tagBindingResolverProvider)')),
          reason: 'a watch would make the policy rebuildable, and the '
              'resolver is the one provider that never rebuilds');
      expect(code, isNot(contains('accessTemplatesProvider')),
          reason: 'making the policy depend on the loader is the obvious fix '
              'and the one this design forbids: it would rebuild the policy '
              'on every template edit, rebuild stateManProvider, and drop '
              'every OPC UA connection on the panel');
    });
  });
}
