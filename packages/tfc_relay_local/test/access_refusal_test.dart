/// `LocalStateMan` refuses the four access families, by name, and keeps
/// serving the plant.
///
/// Plan 17-03 added `accessTemplates`, `accessAdmin`, `audit` and
/// `backendConfig` to `StateManApi`, which made this package stop compiling.
/// **No Phase 17 plan owns this file** (17-03's Finding F-C), so the decision
/// recorded here is this file's own.
///
/// ## The decision, and how it differs from the other three refusals
///
/// `timeseries`, `historyViews` and `preferences` refuse **conditionally**: a
/// gateway with a `collection:` block composes all three, and `fanin_test.dart`
/// proves each is composable as well as that it refuses. That is what makes
/// their absence a *deployment fact*.
///
/// The four access families are not like that. This package has no access store
/// to compose, no constructor argument that could carry one, and nothing in
/// Phase 17 that adds one: the access stores live in `tfc_dart`
/// (`lib/core/access/`, D-02) and are served by `BackendStateMan`, which is the
/// composition the backend actually runs. `LocalStateMan` is the plant leg —
/// DeviceClients and a historian — and administering roles is not on it.
///
/// So these four refuse **unconditionally**, and the arm below says so rather
/// than leaving a reader to infer it from the absence of a composable variant.
///
/// ## It is an `UnsupportedError` and not an `UnimplementedError`
///
/// `freeze_test.dart`'s `declaredUnimplementedMembers` is **0**, and it must
/// stay 0: that ledger counts members somebody still owes code for. Nobody owes
/// these four an implementation here — the answer *is* the refusal. An
/// `UnimplementedError` would put this package back into debt it does not have,
/// and `UnimplementedError implements UnsupportedError` besides
/// (`dart:core errors.dart:595`), so the wrong choice would be invisible to a
/// catch clause and visible only to the ledger.
///
/// ## The anti-vacuity half
///
/// Every refusal is paired with a **live control** on the same object. A
/// `LocalStateMan` that had failed to construct would refuse everything and
/// pass every arm below on its own.
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_upstream_link.dart';
import 'support/keymap_fixtures.dart';

/// The four getters this file judges.
const accessFamilies = <String>[
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
];

/// Reaches one access family without knowing which class [api] is.
Object? reachFamily(StateManApi api, String member) => switch (member) {
      'accessTemplates' => api.accessTemplates,
      'accessAdmin' => api.accessAdmin,
      'audit' => api.audit,
      'backendConfig' => api.backendConfig,
      _ => throw ArgumentError('unknown access family "$member"'),
    };

void main() {
  late LocalStateMan man;
  late FakeUpstreamLink link;

  setUp(() async {
    link = FakeUpstreamLink(alias: st101Alias, keys: const [st101Key]);
    man = LocalStateMan(
      links: [link],
      router: KeyRouter.overLinks(
        [link],
        mappings: keyMappingsOf(const [st101Key], alias: st101Alias),
      ),
    );
    await man.start();
    addTearDown(man.dispose);
  });

  group('LocalStateMan refuses the four access families', () {
    for (final member in accessFamilies) {
      test('$member refuses, naming itself', () {
        expect(
          () => reachFamily(man, member),
          throwsA(isA<UnsupportedError>().having((e) => e.message.toString(),
              'message', contains('LocalStateMan.$member'))),
          reason: 'a gateway that answered "unsupported" without naming the '
              'member leaves an integrator guessing which of four families '
              'this leg does not carry',
        );
      });
    }

    test('the refusal is an UnsupportedError and never an UnimplementedError',
        () {
      // freeze_test.dart's ledger is 0 and must stay 0. An UnimplementedError
      // here would claim somebody owes this package four implementations, and
      // nobody does: administering roles is not on the plant leg. The catch
      // clauses cannot tell the two apart, so only the ledger and this arm can.
      for (final member in accessFamilies) {
        expect(() => reachFamily(man, member), throwsUnsupportedError);
        expect(() => reachFamily(man, member), isNot(throwsUnimplementedError),
            reason: '$member: an UnimplementedError names a plan that owes '
                'code; the answer here IS the refusal');
      }
    });

    test('the refusal is unconditional — there is no collaborator to compose',
        () {
      // The contrast with `timeseries` / `historyViews` / `preferences`, whose
      // refusals `fanin_test.dart` pairs with a composed variant. There is no
      // such variant here and there is deliberately no constructor argument to
      // build one from, so this arm asserts what a reader would otherwise have
      // to infer from a missing test: a fully-composed LocalStateMan refuses
      // these four exactly as an empty one does.
      final composed = LocalStateMan(
        links: const <UpstreamLink>[],
        router: KeyRouter.overLinks(const <UpstreamLink>[],
            mappings: KeyMappings(nodes: <String, KeyMappingEntry>{})),
      );
      addTearDown(composed.dispose);
      for (final member in accessFamilies) {
        expect(() => reachFamily(composed, member), throwsUnsupportedError,
            reason: '$member: if this ever stops throwing, somebody has given '
                'this package an access store and the file doc above is out '
                'of date');
      }
    });

    test('no family answers with an empty store instead of refusing', () {
      for (final member in accessFamilies) {
        Object? returned;
        var threw = false;
        try {
          returned = reachFamily(man, member);
        } catch (_) {
          threw = true;
        }
        expect(threw, isTrue,
            reason: 'LocalStateMan.$member answered with $returned. An empty '
                'template list from the plant leg is an answer about a store '
                'this object has never opened');
      }
    });

    test('LIVE CONTROL: the same gateway still serves the plant', () async {
      // Without this, the four arms above are satisfied by a LocalStateMan
      // that never started — which refuses everything for a reason that has
      // nothing to do with access control.
      //
      // The value goes in through the composer's own ingest seam rather than
      // through the link, for `fanin_test.dart`'s reason: it is the shortest
      // path that proves the value lane is alive, and it does not depend on
      // the fan-in's routing having been exercised first.
      expect(man.browse, isA<BrowseApi>());
      expect(man.keys, contains(st101Key));
      man.applyUpstreamBatch({st101Key: DynamicValue(value: 42)});
      expect(man.read(st101Key)?.value, 42,
          reason: 'the value lane must be demonstrably working, or the four '
              'refusals above are a broken fixture wearing a decision');
    });
  });
}
