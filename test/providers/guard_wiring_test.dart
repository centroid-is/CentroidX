// The wiring: the policy every guard consults, the stream every denial lands
// on, the two providers that put the guards in front of every caller, and the
// counted set of writes the app makes on its own behalf.
//
// `ProviderContainer` rather than widget tests — this is provider graph
// behaviour and does not need a tree.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/shared_row_preferences.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/access_routes.dart';
import 'package:tfc/page_creator/assets/recipes.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import '../helpers/test_helpers.dart'
    show createTestConfigStore, useInMemoryDeviceLocalPreferences;

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
    // The real backend is the OS keychain, which outlives the process and is
    // shared by every test in the run: without this, whichever test writes
    // `state_man_config` first is the only one that observes the write, and on
    // macOS every run re-asks for the keychain password. `setInstance` clears
    // the process-wide secret caches too.
    SecureStorage.setInstance(_MemorySecrets());
  });

  group('accessPolicyProvider', () {
    test('answers the same group for every route as accessGroupForRoute does',
        () async {
      // Two sources for one truth: `kRaisedRoutes` reaches the policy through
      // its `routes` parameter and the registry through `installRaisedRoutes`.
      // Comparing the two answers is what makes the duplication safe; an
      // expected-value table here would drift silently the day somebody edits
      // one side.
      RouteRegistry().clearRouteGroups();
      installRaisedRoutes();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(accessPolicyProvider);

      for (final path in kRaisedRoutes.keys) {
        expect(policy.groupForRoute(path), accessGroupForRoute(path),
            reason: 'the policy and the registry disagree about $path');
      }
      // And a path nobody raised, so the test cannot pass by both sides
      // answering `administer` for everything.
      expect(policy.groupForRoute('/alarms'), accessGroupForRoute('/alarms'));
      expect(policy.groupForRoute('/alarms'), AccessGroup.operate);
    });

    test('carries all ten raised routes, not an empty map', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(accessPolicyProvider);

      // Seven since plan 03-14 raised '/advanced/knowledge-base', eight since
      // 05-07 raised '/advanced/audit-trail', nine since 06-10 raised
      // '/advanced/access', ten since v1.2's 04-06 raised
      // '/advanced/config-history' at `configure` — its own entry, deliberately
      // not a widened audit-trail one; the length is asserted so an empty or
      // truncated map fails here rather than showing up as a route that
      // quietly opens.
      expect(kRaisedRoutes, hasLength(10));
      expect(
          policy.groupForRoute('/advanced/page-editor'), AccessGroup.configure);
      expect(policy.groupForRoute('/advanced/knowledge-base'),
          AccessGroup.configure);
      expect(policy.groupForRoute(kServerConfigRoute), AccessGroup.administer);
      expect(policy.groupForRoute(kConfigHistoryRoute), AccessGroup.configure);
      expect(policy.groupForRoute(kAuditTrailRoute), AccessGroup.users);
      expect(policy.groupForRoute(kAccessAdminRoute), AccessGroup.users);
    });

    test('answers the operate floor for every key until a snapshot loads', () {
      // Rewritten twice. It used to say "binds no tag" (no lookup), then
      // "answers null until a load" (04-05's empty resolver). Since the
      // 2026-09-02 ruling the empty resolver answers the operate floor, so a
      // bare container gates everything at `operate` — which the anonymous
      // Operator session holds — rather than gating nothing, throwing, or
      // locking the plant. `access_templates_test.dart` covers the loaded
      // case.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final policy = container.read(accessPolicyProvider);

      expect(policy.groupForTag('Line1.p_cmd_JogFwd'), AccessGroup.operate);
      expect(policy.groupForTag('anything', member: 'at_all'),
          AccessGroup.operate);
    });

    test('is the same instance on a second read — it is a pure value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
          identical(container.read(accessPolicyProvider),
              container.read(accessPolicyProvider)),
          isTrue);
    });

    test('the source reaches no provider that could cascade into it', () {
      // The policy is a pure value and this file is the leaf both guards hang
      // off. `databaseProvider` and `preferencesProvider` must not appear at
      // all; `accessSessionProvider` appears exactly once, inside the write-time
      // `sessionInForce` callback, and every occurrence of it must be a
      // `ref.read` — a watch there rebuilds StateMan on every sign-in and drops
      // every OPC UA connection on the panel.
      //
      // Comment lines are stripped so that the comment naming the rule cannot
      // satisfy the test enforcing it.
      final source = File('lib/providers/access_policy.dart').readAsLinesSync();
      final code =
          source.where((l) => !l.trimLeft().startsWith('//')).join('\n');

      for (final forbidden in const [
        'databaseProvider',
        'preferencesProvider'
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: 'lib/providers/access_policy.dart must not reach '
                '$forbidden — it is the leaf both guards depend on');
      }

      final sessionUses = 'accessSessionProvider'.allMatches(code).length;
      final sessionReads =
          'ref.read(accessSessionProvider'.allMatches(code).length;
      expect(sessionUses, greaterThan(0));
      expect(sessionReads, sessionUses,
          reason: 'every use of accessSessionProvider here must be a '
              'ref.read at write time, never a watch at a provider build');

      // And the policy provider reads exactly one thing: the resolver, which
      // itself has no dependencies and therefore never rebuilds.
      //
      // Extended by 04-05 rather than relaxed. This used to assert
      // `const AccessPolicy(routes: kRaisedRoutes)` — the policy carried no
      // tag lookup at all — and Phase 4 supplies one. The property the
      // original assertion was protecting is *not* "the policy is const"; it
      // is "nothing this provider reads can be invalidated". So the exact
      // shape of the line is pinned, and the two ways of breaking that
      // property are named: a `watch` of the resolver, or any reference to the
      // loader.
      expect(code, contains('AccessPolicy accessPolicy(Ref ref) =>'));
      expect(code, contains('routes: kRaisedRoutes'));
      expect(
          code, contains('tagBindings: ref.read(tagBindingResolverProvider)'));
      expect(code, isNot(contains('ref.watch(tagBindingResolverProvider)')));
      expect(code, isNot(contains('accessTemplatesProvider')),
          reason: 'a dependency on the loader would rebuild the policy on '
              'every template edit, rebuild stateManProvider, and drop every '
              'OPC UA connection on the panel');
      expect(code, contains('accessDenialsProvider'));
    });
  });

  group('accessDenialsProvider', () {
    test('is broadcast: two listeners both see the same denial', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final stream = container.read(accessDenialsProvider);
      final first = <AccessDenied>[];
      final second = <AccessDenied>[];
      final subA = stream.listen(first.add);
      final subB = stream.listen(second.add);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);

      reportAccessDenial(container.read(_refProbe), _denial('key_mappings'));
      await Future<void>.delayed(Duration.zero);

      expect(first, hasLength(1));
      expect(second, hasLength(1));
      expect(first.single.itemKey, 'key_mappings');
    });

    test('drops events when nobody is listening rather than buffering them',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final stream = container.read(accessDenialsProvider);
      // Nobody attached yet. A denial four screens ago must not be replayed at
      // the operator the moment a prompt widget mounts.
      reportAccessDenial(
          container.read(_refProbe), _denial('state_man_config'));
      await Future<void>.delayed(Duration.zero);

      final seen = <AccessDenied>[];
      final sub = stream.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
    });

    test('the controller is closed when the container is disposed', () async {
      final container = ProviderContainer();
      final stream = container.read(accessDenialsProvider);
      final done = Completer<void>();
      final sub = stream.listen((_) {}, onDone: done.complete);
      addTearDown(sub.cancel);

      container.dispose();
      await done.future.timeout(const Duration(seconds: 2));

      expect(done.isCompleted, isTrue);
    });

    test('reporting after dispose is a no-op, not a StateError', () {
      final container = ProviderContainer();
      final ref = container.read(_refProbe);
      container.read(accessDenialsProvider);
      container.dispose();

      // A guard's `onDenied` can fire from an in-flight write while the app is
      // tearing down. Adding to a closed controller throws; the operator would
      // see a crash instead of nothing.
      expect(
          () => reportAccessDenial(ref, _denial('anything')), returnsNormally);
    });
  });

  group('the wrapping', () {
    test('preferencesProvider answers the row-backed store', () async {
      final w = await _wiring();
      // Since 04-05 the shared store is `config_item` rows and the check lives
      // one layer down, in `GuardedConfigStore.writePreference` — which is
      // what lets one `action_id` cover the audit row and the change rows
      // together. It is still a `Preferences`, which is why no caller changed.
      expect(await w.prefs, isA<SharedRowPreferences>());
      expect(await w.prefs, isA<Preferences>());
    });

    test('stateManProvider answers a GuardedStateMan around the built inner',
        () async {
      final w = await _wiring();
      final sm = await w.stateMan;

      expect(sm, isA<GuardedStateMan>());
      // The decorator, not the inner: a caller that got the inner back would be
      // unguarded and nothing would say so.
      expect(identical(sm, w.inner), isFalse);
    });

    test('both providers build on a station with no database at all', () async {
      // `auditSinkProvider` answers `NullAuditSink` there, which plan 01-07
      // established as a station that keeps working with no trail.
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWith((ref) async => null),
        stationNameProvider.overrideWithValue(_kStation),
        collectorProvider.overrideWith((ref) async => null),
        stateManFactoryProvider.overrideWithValue(({
          required StateManConfig config,
          required KeyMappings keyMappings,
          List<DeviceClient> deviceClients = const [],
        }) async =>
            _FakeStateMan()),
      ]);
      addTearDown(container.dispose);

      expect(
          await container.read(auditSinkProvider.future), isA<NullAuditSink>());
      expect(await container.read(preferencesProvider.future),
          isA<SharedRowPreferences>());
      expect(await container.read(stateManProvider.future),
          isA<GuardedStateMan>());
    });

    test('a refused write publishes on accessDenialsProvider', () async {
      final w = await _wiring();
      final prefs = await w.prefs;

      await expectLater(
        prefs.setString('server_config_envelope', 'nope'),
        throwsA(isA<AccessDenied>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(w.denials, hasLength(1));
      expect(w.denials.single.itemKey, 'server_config_envelope');
    });

    test('the audit rows carry this station', () async {
      final w = await _wiring();
      final prefs = await w.prefs;

      await prefs.setString('theme_mode', 'dark');
      expect(w.sink.rows.where((r) => r.itemKey == 'theme_mode'), isNotEmpty);
      expect(w.sink.rows.first.station, _kStation);
    });

    test('GuardedStateMan reads its baseline through the inner StateMan',
        () async {
      final w = await _wiring();
      final sm = await w.stateMan;

      await sm.write('Line1.p_cmd_JogFwd', DynamicValue(value: true));

      // Without `readBaseline` wired to the inner `read`, a struct write is one
      // blob rather than one row per member that moved.
      expect(w.inner.reads, contains('Line1.p_cmd_JogFwd'));
      expect(w.inner.writes, hasLength(1));
    });
  });

  group('the session is a callback, not a watch', () {
    test('signing in and out does not rebuild stateManProvider', () async {
      final w = await _wiring(withDatabase: true);
      final before = await w.stateMan;
      await w.container.read(accessSessionProvider.future);

      final result = await w.session.signIn('jon', 'correct horse');
      expect(result, AccessSignInResult.ok);
      expect(w.container.read(accessSessionProvider).value!.isElevated, isTrue);
      await w.session.signOut();
      expect(
          w.container.read(accessSessionProvider).value!.isElevated, isFalse);

      final after = await w.stateMan;
      // The whole point: a rebuild here drops every OPC UA connection and every
      // subscription on the panel, every time somebody signs in.
      expect(identical(before, after), isTrue);
      expect(w.inner.closeCalls, 0);
    });

    test('signing in and out does not rebuild preferencesProvider', () async {
      final w = await _wiring(withDatabase: true);
      final before = await w.prefs;
      await w.container.read(accessSessionProvider.future);

      await w.session.signIn('jon', 'correct horse');
      await w.session.signOut();

      expect(identical(before, await w.prefs), isTrue);
    });

    test(
        'a write refused before sign-in is permitted after it, on the same '
        'guard instance', () async {
      final w = await _wiring(withDatabase: true);
      final prefs = await w.prefs;
      await w.container.read(accessSessionProvider.future);

      await expectLater(
          prefs.setString('key_mappings', '{}'), throwsA(isA<AccessDenied>()));

      await w.session.signIn('jon', 'correct horse');

      // Same object, opposite answer. That is only possible if the guard reads
      // the session at write time rather than holding the one it was built
      // with — and it is the behaviour a `ref.watch` would fake by rebuilding.
      expect(identical(prefs, await w.prefs), isTrue);
      await prefs.setString('key_mappings', '{}');
    });

    test('a write permitted while elevated is refused after signing out',
        () async {
      final w = await _wiring(withDatabase: true);
      final prefs = await w.prefs;
      await w.container.read(accessSessionProvider.future);
      await w.session.signIn('jon', 'correct horse');
      await prefs.setString('key_mappings', '{}');

      await w.session.signOut();

      // The elevation window this milestone exists to close: a captured session
      // would keep granting `configure` long after the operator signed out.
      await expectLater(prefs.setString('key_mappings', '{"a":1}'),
          throwsA(isA<AccessDenied>()));
    });

    test('neither provider watches the session', () {
      // The behavioural tests above are the real gate; this one names the
      // regression so a reader who adds the watch is told why not. Comment
      // lines are stripped, so the comment explaining the rule cannot satisfy
      // the test enforcing it.
      for (final path in const [
        'lib/providers/state_man.dart',
        'lib/providers/preferences.dart',
      ]) {
        final code = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(code.contains('ref.watch(accessSessionProvider'), isFalse,
            reason: '$path must reach the session through the guard\'s '
                'callback, never a watch');
        expect(code, isNotEmpty);
      }
    });
  });

  group('boot with nothing stored and nobody signed in', () {
    test('all four providers build, with no throw and zero denial events',
        () async {
      final w = await _wiring();

      final prefs = await w.prefs;
      await w.stateMan;
      await w.container.read(pageManagerProvider.future);
      await w.container.read(alarmManProvider.future);
      // There is no longer an unawaited write on this path to wait for — the
      // page-layout seed is deleted — but the pump stays: it is what would
      // surface a denial arriving a microtask late if one ever came back, and
      // asserting "no throw" alone would pass while the operator met a prompt
      // on every cold boot.
      await pumpEventQueue();

      expect(w.denials, isEmpty,
          reason: 'boot produced ${w.denials.map((d) => d.itemKey)}');

      // And every default actually landed, so the test cannot pass by nothing
      // having been written at all.
      //
      // `key_mappings` is deliberately not here any more. Since 02-05 the boot
      // default is `GuardedConfigStore.seedDefaultIfEmpty`, which writes one
      // `config_item` row against a **reachable and genuinely empty** shared
      // database and does nothing at all offline — and this container has no
      // database. `guarded_config_store_test.dart`'s "the boot seed" group is
      // where that write is proved, trail and all.
      expect(
          await prefs.getString('state_man_config', secret: true), isNotNull);
      expect(await prefs.getString('alarm_man_config'), isNotNull);

      // And `page_editor_data` deliberately did **not** land. Since 03-04 a
      // station with no stored layout comes up on the built-in default held
      // in memory and persists nothing: the seed was a write of the plant's
      // layout at boot, with nobody signed in, against a `configure` key. The
      // first Save by a person is what stores a layout now — gated, awaited
      // and audited.
      expect(await prefs.getString('page_editor_data'), isNull,
          reason: 'the boot seed is deleted; a write here is it coming back');
    });

    test('every boot default is in the trail, marked origin: system', () async {
      final w = await _wiring();
      await w.stateMan;
      await w.container.read(pageManagerProvider.future);
      await w.container.read(alarmManProvider.future);
      await pumpEventQueue();

      // 'page_editor_data' is not here either, and for a stronger reason: as
      // of 03-04 there is no boot write of it at all.
      expect(w.sink.rows.where((r) => r.itemKey == 'page_editor_data'),
          isEmpty,
          reason: 'the page-layout seed is deleted; a trail row for it is the '
              'seed having come back');

      for (final key in const [
        // 'key_mappings' has moved to the configuration store's own seed —
        // see the comment in the test above, and
        // `guarded_config_store_test.dart`'s "writes the example key once, as
        // the system, with a row".
        'state_man_config',
        'alarm_man_config',
      ]) {
        final rows = w.sink.rows.where((r) => r.itemKey == key);
        expect(rows, isNotEmpty, reason: 'no audit row for $key');
        expect(rows.every((r) => r.origin == 'system'), isTrue,
            reason: '$key was recorded as ${rows.map((r) => r.origin)}');
        expect(rows.every((r) => r.allowed), isTrue);
      }
    });

    test('PageManager.save() is still refused to an anonymous session',
        () async {
      final w = await _wiring();
      final manager = await w.container.read(pageManagerProvider.future);
      await pumpEventQueue();

      // The seed unlocked `load()`, not the editor. `page_editor.dart` saves
      // through this same instance, and that write is a person editing pages.
      await expectLater(manager.save(), throwsA(isA<AccessDenied>()));
    });

    test(
        'the escape did not become the path: an operator write of the same '
        'key is still refused', () async {
      final w = await _wiring();
      final prefs = await w.prefs;
      final store = await w.configStore;
      await w.stateMan;

      // The boot default for these keys went through the unchecked path. An
      // ordinary write of the very same key, by a session, is a different
      // thing — and for key mappings it is now the guarded *store* that has to
      // say so, since that is where the write goes.
      await expectLater(store.saveKeyMappings(KeyMappings(nodes: {})),
          throwsA(isA<AccessDenied>()));
      await expectLater(prefs.setString('alarm_man_config', '{"alarms":[]}'),
          throwsA(isA<AccessDenied>()));
    });

    test('a refused key-mapping save is in the trail, and reaches the denial '
        'stream', () async {
      final w = await _wiring();
      final store = await w.configStore;

      await expectLater(store.saveKeyMappings(KeyMappings(nodes: {})),
          throwsA(isA<AccessDenied>()));
      await pumpEventQueue();

      final rows = w.sink.rows.where((r) => r.itemKey == 'key_mappings');
      expect(rows, hasLength(1));
      expect(rows.single.allowed, isFalse);
      expect(rows.single.surface, 'pref');
      expect(rows.single.station, _kStation);
      expect(w.denials.map((d) => d.itemKey), contains('key_mappings'));
    });
  });

  group('the key-mapping live apply survives a reconnect (C-1)', () {
    test('an edit applies before and after preferencesProvider is rebuilt',
        () async {
      // The regression this milestone exists to close. `stateManProvider`
      // reads preferences with `ref.read` on purpose — a watch would drop
      // every OPC UA connection on the panel each time the database
      // reconnected — so the old listener was attached to the `Preferences`
      // instance that existed at boot. `preferencesProvider` builds a NEW one
      // on every reconnect, and from that moment the listener was watching an
      // object nobody wrote to again: key-mapping edits silently stopped
      // applying, forever, after the first database blip.
      //
      // The store outlives every provider rebuild, so the listener now hangs
      // off it. Rebuilding `preferencesProvider` between two edits is what
      // tells the two designs apart: the old one applies the first and misses
      // the second.
      final w = await _wiring(withConfigStore: true);
      final store = await w.configStore;
      await w.stateMan;

      await store.inner.writeKeyMappings(
          _mappingsOf({'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'}),
          actionId: 'a1',
          who: 'jon',
          roleName: 'Engineering');
      await pumpEventQueue();
      expect(w.inner.appliedDiffs.map((d) => d.added.single.id),
          ['CN04.Belt.Speed']);

      // The reconnect, as the app performs it.
      final before = await w.prefs;
      w.container.invalidate(preferencesProvider);
      final after = await w.prefs;
      expect(identical(before, after), isFalse,
          reason: 'the premise: a rebuild really does replace the object the '
              'old listener was holding');
      // And the store did not go with it.
      expect(identical(store, await w.configStore), isTrue);

      await store.inner.writeKeyMappings(
          _mappingsOf({
            'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed',
            'CN07.Belt.Speed': 'GVL.Conveyors[7].Speed',
          }),
          actionId: 'a2',
          who: 'jon',
          roleName: 'Engineering');
      await pumpEventQueue();

      expect(w.inner.appliedDiffs, hasLength(2),
          reason: 'the second edit never reached StateMan — the listener went '
              'deaf when preferencesProvider was rebuilt');
      expect(w.inner.appliedDiffs.last.added.single.id, 'CN07.Belt.Speed');
      expect(w.inner.appliedMappings.last.nodes.keys,
          containsAll(['CN04.Belt.Speed', 'CN07.Belt.Speed']));
    });

    test('the store\'s diff reaches StateMan, not a recomputed one', () async {
      // SC-3's other half, from the app side: the object handed to
      // `updateKeyMappings` is the one the store computed while deciding which
      // rows to write.
      final w = await _wiring(withConfigStore: true);
      final store = await w.configStore;
      await w.stateMan;

      final result = await store.inner.writeKeyMappings(
          _mappingsOf({'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed'}),
          actionId: 'a1',
          who: 'jon',
          roleName: 'Engineering');
      await pumpEventQueue();

      expect(identical(w.inner.appliedDiffs.single, result.diff), isTrue);
    });
  });

  group('recipes: opening an asset is not saving one', () {
    test('an anonymous session can open a recipes asset with no denial event',
        () async {
      final w = await _wiring();
      final prefs = await w.prefs;
      final systemPrefs =
          await w.container.read(systemPreferencesProvider.future);

      final recipes = await readRecipes(prefs, systemPrefs, 'Line1');
      await pumpEventQueue();

      expect(recipes, isEmpty);
      expect(w.denials, isEmpty);
      expect(await prefs.getString('Line1.recipes'), '[]');
      // Recorded, not exempted.
      final rows = w.sink.rows.where((r) => r.itemKey == 'Line1.recipes');
      expect(rows, hasLength(1));
      expect(rows.single.origin, 'system');
    });

    test('an anonymous session cannot save a recipe', () async {
      final w = await _wiring();
      final prefs = await w.prefs;

      // The Shift Leader requirement, from the other side: `.recipes` is a
      // `setpoints` key and this write is a person changing a recipe.
      await expectLater(
        writeRecipes(
            prefs, 'Line1', [Recipe(name: 'A', value: DynamicValue(value: 1))]),
        throwsA(isA<AccessDenied>()),
      );
      await pumpEventQueue();
      expect(w.denials.map((d) => d.itemKey), contains('Line1.recipes'));
    });

    test('a shift leader can save a recipe', () async {
      final w = await _wiring(withDatabase: true);
      final prefs = await w.prefs;
      await w.container.read(accessSessionProvider.future);
      await w.session.signIn('jon', 'correct horse');

      await writeRecipes(
          prefs, 'Line1', [Recipe(name: 'A', value: DynamicValue(value: 1))]);

      expect(await prefs.getString('Line1.recipes'), isNotNull);
      final rows = w.sink.rows.where((r) => r.itemKey == 'Line1.recipes');
      expect(rows.single.origin, 'operator');
      expect(rows.single.who, 'jon');
    });
  });

  group('the system write path is capped', () {
    test('the files that use it are exactly the ones the constant names', () {
      final found = _filesUsingTheSystemWritePath();
      final expected = kSystemWriteCallSites
          .toSet()
          .difference(kSystemWriteCallSitesOwed.toSet());

      // Non-vacuous: a walk that found nothing would satisfy a one-directional
      // subset assertion trivially.
      expect(found, isNotEmpty);
      expect(
          kSystemWriteCallSitesOwed
              .toSet()
              .difference(kSystemWriteCallSites.toSet()),
          isEmpty,
          reason: 'an owed entry must also be a declared call site');

      expect(found.difference(expected), isEmpty,
          reason: 'these files use the system write path and are not on '
              'kSystemWriteCallSites: ${found.difference(expected)}');
      expect(expected.difference(found), isEmpty,
          reason: 'these files are on kSystemWriteCallSites but no longer use '
              'the system write path: ${expected.difference(found)}');
    });

    test('anything still owed names the plan that owns it, and no stale owner '
        'marker is left behind', () {
      final code = File('lib/providers/access_policy.dart').readAsStringSync();
      // While a file is owed the cap test's expected set is narrowed by it, so
      // the reason and the owner have to be in the source or the narrowing is
      // invisible.
      for (final owed in kSystemWriteCallSitesOwed) {
        expect(code, contains(owed));
        expect(code, contains(RegExp(r'TODO\(\d\d-\d\d\)')),
            reason: 'an owed entry must name the plan that closes it');
      }
      // 03-09 routed both files 03-06 left owed. The marker outliving the
      // thing it marked is how an allow-list stops meaning anything.
      expect(kSystemWriteCallSitesOwed, isEmpty,
          reason: 'collector.dart and mcp_bridge.dart are routed as of 03-09');
      expect(code, isNot(contains('TODO(03-09)')));
    });
  });

  group('disposal', () {
    test('closes the inner StateMan exactly once, and not the decorator too',
        () async {
      final w = await _wiring();
      await w.stateMan;

      w.container.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(w.inner.closeCalls, 1);
    });
  });
}

AccessDenied _denial(String key) => AccessDenied(key, AccessGroup.configure);

/// The two tokens that reach the unchecked write path.
///
/// `systemWrites` is the member on `SharedRowPreferences` (and, until 04-12
/// retires it, on `GuardedPreferences`);
/// `systemPreferencesProvider` is how everything but `preferences.dart` gets
/// hold of it. Capping only the first would leave the provider readable from
/// anywhere, which is the same hole one indirection further out.
const List<String> _systemWriteTokens = [
  'systemWrites',
  'systemPreferencesProvider',
];

/// Every file under `lib/` whose **code** reaches the system write path.
///
/// Whole-line comments are stripped, so the comment naming the rule cannot
/// satisfy the test enforcing it, and generated `.g.dart` files are skipped —
/// `preferences.g.dart` necessarily names the provider it generates, and a
/// generated file is not a call site anybody chose.
Set<String> _filesUsingTheSystemWritePath() {
  final found = <String>{};
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is! File) continue;
    // Separators normalised: the constant this is compared against spells its
    // paths with forward slashes, and listSync hands back backslashes on
    // Windows.
    final path = entity.path.replaceAll(r'\', '/');
    if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
    final code = entity
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    if (_systemWriteTokens.any(code.contains)) found.add(path);
  }
  return found;
}

/// Hands a test the `Ref` that [reportAccessDenial] takes.
///
/// The entry point is typed to `Ref` because every production caller is a
/// provider's `onDenied` closure, which has one. A test has a container, so it
/// borrows one here rather than the entry point growing a second signature for
/// the benefit of tests.
final _refProbe = Provider<Ref>((ref) => ref);

// ---------------------------------------------------------------------------
// Task 2 — the wrapping, and the property that keeps the plant connected.
// ---------------------------------------------------------------------------

/// A `StateMan` that records what reached it and opens no connection.
///
/// `noSuchMethod` here is a *test* fake, not a decorator: an unimplemented
/// member throwing in a test is a red test, where the same hook in
/// `GuardedStateMan` would be a hole that only shows up on a plant. That is why
/// `guarded_state_man_test.dart` forbids it there and this file uses it.
class _FakeStateMan implements StateMan {
  int closeCalls = 0;
  final List<String> reads = [];
  final List<(String, DynamicValue)> writes = [];
  final Map<String, DynamicValue> values = {};

  /// Every diff the live-apply listener handed over, in order. The C-1
  /// regression is counted here.
  final List<ConfigDiff> appliedDiffs = [];

  /// The mappings that came with each of them.
  final List<KeyMappings> appliedMappings = [];

  @override
  KeyMappingsUpdateResult updateKeyMappings(KeyMappings newKeyMappings,
      {ConfigDiff? diff}) {
    appliedMappings.add(newKeyMappings);
    // Not defaulted to an empty diff: the point of this fake is to see what
    // the provider passed, and a null here is a provider that stopped passing
    // the store's own diff.
    appliedDiffs.add(diff!);
    return const KeyMappingsUpdateResult(
      added: {},
      removed: {},
      changed: {},
      resubscribed: {},
      reloadReasons: [],
    );
  }

  @override
  Future<void> close() async => closeCalls++;

  @override
  String resolveKey(String key) => key;

  @override
  Future<DynamicValue> read(String key) async {
    reads.add(key);
    return values[key] ?? DynamicValue(value: null);
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key, value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Signs `jon` in as Engineering and refuses everything else.
///
/// A fake rather than `LocalAuthProvider` because the seeded database has the
/// four roles but no users, and this file is about the guards, not about
/// account creation.
class _FakeAuthProvider implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    if (username == 'jon' && password == 'correct horse') {
      return const AuthenticatedUser(username: 'jon', roleName: 'Engineering');
    }
    return null;
  }
}

/// An in-memory stand-in for the OS keychain.
class _MemorySecrets implements MySecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

const String _kStation = 'test-panel';

class _Wiring {
  _Wiring({
    required this.container,
    required this.sink,
    required this.inner,
    required this.denials,
  });

  final ProviderContainer container;
  final _RecordingSink sink;
  final _FakeStateMan inner;
  final List<AccessDenied> denials;

  AccessSessionController get session =>
      container.read(accessSessionProvider.notifier);

  Future<Preferences> get prefs => container.read(preferencesProvider.future);
  Future<StateMan> get stateMan => container.read(stateManProvider.future);
  Future<GuardedConfigStore> get configStore =>
      container.read(configStoreProvider.future);
}

/// One OPC UA entry per key, built through the model so every payload is codec
/// output — a hand-written one is structurally different and would make the
/// diff report keys nobody touched.
KeyMappings _mappingsOf(Map<String, String> keysToIdentifiers) => KeyMappings(
      nodes: {
        for (final entry in keysToIdentifiers.entries)
          entry.key: KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 4, identifier: entry.value),
          ),
      },
    );

/// A container with the real `preferencesProvider` and `stateManProvider`,
/// their inner construction faked, and nothing pointed at a real database or a
/// real PLC.
Future<_Wiring> _wiring(
    {bool withDatabase = false, bool withConfigStore = true}) async {
  AccessRepository? repository;
  if (withDatabase) {
    final db = AppDatabase.inMemoryForTest();
    addTearDown(db.close);
    // Force the migration, so the four seeded roles exist.
    await db.customSelect('SELECT 1').getSingle();
    repository = AccessRepository(db);
  }

  final sink = _RecordingSink();
  final inner = _FakeStateMan();
  final denials = <AccessDenied>[];

  final container = ProviderContainer(
    overrides: [
      // No Postgres: `Preferences` falls back to its in-memory cache and the
      // local SharedPreferences, which is what a station with no database is.
      databaseProvider.overrideWith((ref) async => null),
      accessRepositoryProvider.overrideWith((ref) async => repository),
      authProviderProvider.overrideWith(
          (ref) async => repository == null ? null : _FakeAuthProvider()),
      auditSinkProvider.overrideWith((ref) async => sink),
      stationNameProvider.overrideWithValue(_kStation),
      // The seam, and the only reason it exists: proving a session transition
      // does not rebuild this provider must not open an OPC UA connection.
      stateManFactoryProvider.overrideWithValue(
        ({
          required StateManConfig config,
          required KeyMappings keyMappings,
          List<DeviceClient> deviceClients = const [],
        }) async =>
            inner,
      ),
      // `collectorProvider` watches `stateManProvider`, so leaving it real
      // would have this test reaching for a database it does not have.
      collectorProvider.overrideWith((ref) async => null),
      // On by default since 04-05: `preferencesProvider` is now backed by this
      // store, so a container without one is a station with no Postgres — and
      // every preference write in this file would be refused as offline rather
      // than checked. `sessionOf` rather than `session`, because production
      // passes `() => sessionInForce(ref)` and the tests below sign in and out
      // between two writes on one guard.
      if (withConfigStore)
        configStoreProvider.overrideWith((ref) => createTestConfigStore(
              station: _kStation,
              sessionOf: () => sessionInForce(ref),
              audit: sink,
              // Through the provider, exactly as `configStoreProvider` does:
              // handing the list straight in would leave "a refusal reaches
              // accessDenialsProvider" passing without the publish ever
              // happening.
              onDenied: (denial) => reportAccessDenial(ref, denial),
            )),
    ],
  );
  addTearDown(container.dispose);

  final sub = container.read(accessDenialsProvider).listen(denials.add);
  addTearDown(sub.cancel);

  return _Wiring(
    container: container,
    sink: sink,
    inner: inner,
    denials: denials,
  );
}
