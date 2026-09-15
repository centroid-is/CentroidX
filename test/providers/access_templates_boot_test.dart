// The snapshot loads at boot, and the window before it does has a name.
//
// This file is separate from `access_templates_test.dart` on purpose. The
// property it asserts is the one a plan-check found missing and it should be
// findable by filename, not buried among the wiring cases:
//
//   `tagBindingResolverProvider` is keepAlive, starts empty and has no
//   dependencies. `accessPolicyProvider` and `tagAccessProvider` read **the
//   resolver**, not the loader. So unless something forces the loader to run, a
//   station with templates created and keys bound comes up with an empty
//   resolver, `groupFor` answers null for everything, every write is permitted,
//   and the panel is byte-identically indistinguishable from one nobody
//   configured — with the only thing that would have loaded it being the act of
//   opening the page that reports unbound keys.
//
// The test that matters is the first one below: a container that reads **only**
// `accessPolicyProvider` resolves a bound key.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:tfc/core/access_template_store.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;

class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;
}

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

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;
}

const String _kKey = 'ST101.CN01';
const String _kJog = 'p_cmd_JogFwd';
const String _kManualFreq = 'p_cfg_ManualFreq';

AccessTemplate _conveyor() => AccessTemplate(
      name: 'conveyor',
      rules: const {
        _kManualFreq: AccessGroup.device,
        _kJog: AccessGroup.operate,
      },
    );

AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() => db.close());

  AccessTemplateStore rawStore() => AccessTemplateStore(
        db: db,
        session: _withUsers,
        audit: const NullAuditSink(),
        station: 'test',
      );

  /// The station as the commissioning engineer left it: a template created and
  /// a key bound, written *before* the app boots.
  Future<void> seedConveyor() async {
    final store = rawStore();
    await store.create(_conveyor());
    await store.bind(_kKey, 'conveyor');
  }

  ProviderContainer boot({List<Override> extra = const []}) {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
      accessSessionProvider.overrideWith(() => _FixedSession(_withUsers())),
      // 17-12: the store provider consults the transport row before choosing
      // its route; an empty device-local store reads as direct mode.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      ...extra,
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Lets every scheduled microtask and pending future settle, which is what a
  /// booting panel does while the first frame is drawn.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('the load happens without the key repository', () {
    test(
        'a container that reads only accessPolicyProvider resolves a bound key',
        () async {
      // Blocker 1, in one test. No widget is built, `accessTemplatesProvider`
      // is never read by this test, and `/advanced/key-repository` is never
      // opened. The only thing this container ever asks for is the policy —
      // which is exactly what `stateManProvider` asks for at boot.
      await seedConveyor();

      final container = boot();
      final policy = container.read(accessPolicyProvider);

      await settle();

      expect(policy.groupForTag(_kKey, member: _kManualFreq),
          AccessGroup.device,
          reason: 'a station with bindings configured must come up enforcing '
              'them, whether or not anybody opens the key repository');
      expect(policy.groupForTag(_kKey, member: _kJog), AccessGroup.operate);
      expect(policy.groupForTag('ST999.UNBOUND', member: _kManualFreq),
          AccessGroup.operate,
          reason: 'unbound keys answer the operate floor (2026-09-02 ruling)');
    });

    test('reading the resolver alone is enough to start the load', () async {
      await seedConveyor();

      final container = boot();
      final resolver = container.read(tagBindingResolverProvider);
      expect(resolver.state, TagBindingSnapshotState.neverLoaded,
          reason: 'nothing has loaded yet at the instant the resolver is '
              'first read');

      await settle();

      expect(resolver.state, TagBindingSnapshotState.loaded);
      expect(resolver.boundKeyCount, 1);
    });

    test('the kick does not rebuild the policy or change its identity',
        () async {
      await seedConveyor();

      final container = boot();
      final before = container.read(accessPolicyProvider);
      await settle();
      final after = container.read(accessPolicyProvider);

      expect(identical(before, after), isTrue,
          reason: 'the kick is one-way: the resolver starts the load, and the '
              'load never rebuilds the resolver or anything above it');
      expect(before.groupForTag(_kKey, member: _kManualFreq),
          AccessGroup.device,
          reason: 'the instance captured before the load answers the new '
              'snapshot, which is what the callback on a mutable object buys');
    });
  });

  group('the window before the first load has a name', () {
    test('neverLoaded before the load settles, loaded after, same container',
        () async {
      await seedConveyor();

      final container = boot();
      final resolver = container.read(tagBindingResolverProvider);

      expect(resolver.state, TagBindingSnapshotState.neverLoaded);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.operate,
          reason: 'the boot window answers the operate floor — which the '
              'anonymous Operator session holds, so a booting panel still '
              'writes; only bindings above the floor wait for the load');

      await settle();

      expect(resolver.state, TagBindingSnapshotState.loaded);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device);
    });

    test('an empty database ends at loaded, not neverLoaded', () async {
      // The deliberate case. Nothing is bound because nobody bound anything —
      // which must not read the same as a snapshot that never arrived.
      final container = boot();
      container.read(tagBindingResolverProvider);
      await settle();

      final resolver = container.read(tagBindingResolverProvider);
      expect(resolver.state, TagBindingSnapshotState.loaded);
      expect(resolver.boundKeyCount, 0);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.operate);
    });

    test('a station with no database also ends at loaded', () async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => null),
        accessSessionProvider.overrideWith(() => _FixedSession(_withUsers())),
        localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      ]);
      addTearDown(container.dispose);

      container.read(tagBindingResolverProvider);
      await settle();

      expect(container.read(tagBindingResolverProvider).state,
          TagBindingSnapshotState.loaded,
          reason: 'a station commissioned without Postgres gates nothing '
              'deliberately, and says so');
    });

    test('a failed first load leaves the resolver at neverLoaded, and the '
        'provider it hangs off still builds', () async {
      final container = boot(extra: [
        accessTemplateStoreProvider
            .overrideWith((ref) async => _FlakyStore(rawStore())..throwing = true),
      ]);

      final resolver = container.read(tagBindingResolverProvider);
      await settle();

      expect(resolver.state, TagBindingSnapshotState.neverLoaded,
          reason: 'there is no previous snapshot to call stale');
      // The kick swallows: a failed template load must not take down the
      // provider every guard on the panel depends on.
      expect(identical(resolver, container.read(tagBindingResolverProvider)),
          isTrue);
      expect(container.read(accessPolicyProvider).groupForTag(_kKey),
          AccessGroup.operate);
    });

    test('a failed load after a good one leaves stale, with the answers '
        'unchanged', () async {
      await seedConveyor();
      late _FlakyStore flaky;
      final container = boot(extra: [
        accessTemplateStoreProvider
            .overrideWith((ref) async => flaky = _FlakyStore(rawStore())),
      ]);

      final resolver = container.read(tagBindingResolverProvider);
      await settle();
      expect(resolver.state, TagBindingSnapshotState.loaded);

      flaky.throwing = true;
      container.invalidate(accessTemplatesProvider);
      await expectLater(
          container.read(accessTemplatesProvider.future), throwsStateError);

      expect(resolver.state, TagBindingSnapshotState.stale);
      expect(resolver.groupFor(_kKey, _kManualFreq), AccessGroup.device,
          reason: 'T-04-26: a Postgres blink must not unrestrict every bound '
              'key on the panel for the duration of a retry');
    });
  });
}
