/// The gateway's two `StateManApi` decorators, and what each does with the
/// four access families.
///
/// Plan 17-03 added `accessTemplates`, `accessAdmin`, `audit` and
/// `backendConfig` to `StateManApi`. This package has two decorators, they are
/// composed **policy over health over source** (`relay_server.dart:755`), and
/// the two answer differently on purpose:
///
///  * **`PolicyStateMan` refuses.** It is the outermost object every handler is
///    handed, and it has no gate for these four families — 17-07 writes it. A
///    decorator that delegated an ungated family would put twenty-nine
///    administration methods on the wire with nothing between them and the
///    store, which is the fail-open this phase's whole architecture exists to
///    prevent. `canSee`-as-absence and `requireOperate` are the two shapes this
///    file already has for "no"; a family with neither yet gets the third.
///  * **`SessionHealthStateMan` delegates.** It adds health keys and nothing
///    else, and it delegates its four data-service getters already. It has a
///    source, so refusing would be *faking* an absence rather than reporting
///    one. Delegating adds no authority: whatever it forwards to is still
///    behind the policy decorator above it.
///
/// ## Why `PolicyStateMan` refuses with an `UnsupportedError` and not a
/// `forbidden`
///
/// A `forbidden` is an **authorisation verdict** — it says "your role does not
/// allow this", and under D-05 every such verdict writes an audit row naming a
/// station and a role. That row would be false. Nothing has been decided about
/// the caller's authority here; what is absent is the gate itself. An
/// `UnsupportedError` says the composition is incomplete, which is the fact,
/// and `data_handlers.dart:216` already treats it as the survivable case.
///
/// ## The anti-vacuity half
///
/// Each refusal group is paired with a **live control** on the same object: the
/// four data-service getters still hand back their decorators. Without it, a
/// `PolicyStateMan` that had stopped working entirely would pass every refusal
/// arm below.
///
/// ## Note for 17-04
///
/// This file imports `AllVisibleOperatorWrites` and `Identity` only to build a
/// `PolicyStateMan` at all. Plan 17-04 replaces both; when it does, the fixture
/// below is a two-line mechanical change and none of the properties move.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/health/session_health_state_man.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

/// The four getters this file judges.
const accessFamilies = <String>[
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
];

/// Reaches one access family without knowing which class [api] is.
///
/// A switch over the literal rather than a mirror invocation: a mirror would
/// report `NoSuchMethodError` for a member that was never declared, which is
/// indistinguishable here from the refusal being tested.
Object? reachFamily(StateManApi api, String member) => switch (member) {
      'accessTemplates' => api.accessTemplates,
      'accessAdmin' => api.accessAdmin,
      'audit' => api.audit,
      'backendConfig' => api.backendConfig,
      _ => throw ArgumentError('unknown access family "$member"'),
    };

void main() {
  /// A policy decorator over a plain in-memory plant.
  ///
  /// `identityOf` answers null deliberately: the refusals below must not depend
  /// on who is asking, because nothing about them is an authorisation verdict.
  /// The live control is chosen to need no identity either — the four
  /// data-service getters hand back their decorators without consulting one.
  PolicyStateMan policyOverPlant() {
    final plant = FakeStateMan();
    addTearDown(plant.dispose);
    return PolicyStateMan(
      source: plant,
      policy: const AllVisibleOperatorWrites(),
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => null,
    );
  }

  group('PolicyStateMan refuses the four access families', () {
    for (final member in accessFamilies) {
      test('$member refuses, naming itself', () {
        expect(
          () => reachFamily(policyOverPlant(), member),
          throwsA(isA<UnsupportedError>().having((e) => e.message.toString(),
              'message', contains('PolicyStateMan.$member'))),
          reason: 'the decorator every handler is handed must say which member '
              'has no gate; "unsupported" alone names nothing to wire',
        );
      });
    }

    test('no refusal is dressed up as an authorisation verdict', () {
      // The failure mode this arm exists for: somebody "improves" the refusal
      // into a `forbidden`, and every access call a panel makes starts writing
      // a deny row attributing a refusal to a station whose role was never
      // consulted. A false audit row is worse than a missing one, because it is
      // the kind a reviewer believes.
      for (final member in accessFamilies) {
        Object? caught;
        try {
          reachFamily(policyOverPlant(), member);
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<UnsupportedError>(),
            reason: '$member refused with $caught. A refusal here is an '
                'incomplete composition, not a decision about the caller');
        final message = (caught as UnsupportedError).message.toString();
        expect(message.toLowerCase(), isNot(contains('forbidden')),
            reason: '$member: see above — this is not a verdict about a role');
        expect(message.toLowerCase(), isNot(contains('not implemented')),
            reason: '$member: the member IS implemented; the gate is what is '
                'absent');
      }
    });

    test('the refusal is not delegation in disguise: a source that ANSWERS is '
        'still refused', () {
      // The fail-open, stated directly — and the fixture matters more than the
      // assertion. A `FakeStateMan` source refuses these four itself, so a
      // `PolicyStateMan` that delegated to one would *still throw* and this arm
      // would pass while the decorator did nothing. That is a vacuous pin, and
      // sabotage (c) found it: replacing the refusal with `source.accessAdmin`
      // left this arm green.
      //
      // So the source here genuinely answers. Now delegation is observable as a
      // non-throw, and the arm fails exactly when the decorator stops deciding.
      final answering = _ConfigAnsweringSource();
      addTearDown(answering.dispose);
      final api = PolicyStateMan(
        source: answering,
        policy: const AllVisibleOperatorWrites(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => null,
      );

      // The control on the fixture itself: the source really does answer, so a
      // refusal below is the decorator's decision and not the source's.
      expect(answering.backendConfig, isA<BackendConfigApi>(),
          reason: 'if this throws, the fixture stopped answering and the arm '
              'below is vacuous again');

      Object? returned;
      var threw = false;
      try {
        returned = api.backendConfig;
      } catch (_) {
        threw = true;
      }
      expect(threw, isTrue,
          reason: 'PolicyStateMan.backendConfig answered with $returned by '
              'passing its source through. There is no gate in front of these '
              'families yet, so an answer is an ungated administration '
              'surface — D-10 grades all five config methods `administer`');
    });

    test('LIVE CONTROL: the four data-service getters still decorate', () {
      // Without this, a PolicyStateMan that threw from every getter would pass
      // every arm above and the file would be judging a broken fixture.
      final api = policyOverPlant();
      expect(api.browse, isA<BrowseApi>());
      expect(api.timeseries, isA<TimeseriesApi>());
      expect(api.historyViews, isA<HistoryViewApi>());
      expect(api.preferences, isA<PreferencesApi>());
    });
  });

  group('SessionHealthStateMan delegates the four access families', () {
    /// The health overlay over a source that refuses by name.
    ///
    /// `BackendStateMan` is not reachable from this package, so the refusing
    /// source here is another `PolicyStateMan`. That makes the delegation
    /// observable: if the overlay forwards, the message names *PolicyStateMan*;
    /// if it threw one of its own, it would name itself.
    SessionHealthStateMan healthOverRefusingSource() =>
        SessionHealthStateMan(source: policyOverPlant());

    for (final member in accessFamilies) {
      test('$member is forwarded, not answered locally', () {
        expect(
          () => reachFamily(healthOverRefusingSource(), member),
          throwsA(isA<UnsupportedError>().having(
              (e) => e.message.toString(),
              'the message comes from the source, not the overlay',
              allOf(contains('PolicyStateMan.$member'),
                  isNot(contains('SessionHealthStateMan'))))),
          reason: 'the overlay adds health keys and no authority. A refusal it '
              'minted itself would hide which layer actually has nothing '
              'behind it, and would have to be un-minted by 17-07',
        );
      });
    }

    test('LIVE CONTROL: the overlay forwards a working member too', () {
      // The anti-vacuity half of the delegation claim: an overlay that threw
      // on *everything* would also satisfy the four arms above. This shows the
      // forwarding is real by forwarding something that succeeds.
      final plant = FakeStateMan();
      addTearDown(plant.dispose);
      final health = SessionHealthStateMan(source: plant);
      expect(health.preferences, same(plant.preferences));
      expect(health.browse, same(plant.browse));
    });
  });

  group('the shipped composition is fail-closed', () {
    test('policy over health over source refuses every access family', () {
      // The order `relay_server.dart` actually builds, asserted end to end.
      // Neither decorator alone is the property — what matters is that the
      // object a handler is handed refuses, whatever is underneath it.
      final plant = FakeStateMan();
      addTearDown(plant.dispose);
      final stack = PolicyStateMan(
        source: SessionHealthStateMan(source: plant),
        policy: const AllVisibleOperatorWrites(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => null,
      );

      for (final member in accessFamilies) {
        expect(
          () => reachFamily(stack, member),
          throwsA(isA<UnsupportedError>().having((e) => e.message.toString(),
              'message', contains('PolicyStateMan.$member'))),
          reason: 'the outermost decorator is the one a handler holds, so it '
              'is the one that has to say no',
        );
      }

      // LIVE CONTROL, inline: the same stack still serves the data services.
      // A stack that had fallen over would refuse the four above for the wrong
      // reason.
      expect(stack.preferences, isA<PreferencesApi>());
      expect(stack.timeseries, isA<TimeseriesApi>());
    });
  });
}

/// A source whose `backendConfig` genuinely answers.
///
/// Exists so the fail-open arm above has something to observe. Every other
/// member is `FakeStateMan`'s, including the other three access refusals — the
/// single override is the whole point, and a broader stub would blur which
/// object the arm is judging.
///
/// `backendConfig` is the family chosen because its two return types
/// ([BackendConfigDocument] and [ConfigValidation]) are declared in
/// `tfc_relay_protocol` itself. The other three answer with `tfc_access`'s own
/// types (`AccessTemplate`, `AccessRole`, `AuditRecord`), and this package does
/// not depend on `tfc_access` yet — 17-04 adds that edge, and when it does this
/// arm can be widened to all four.
class _ConfigAnsweringSource extends FakeStateMan {
  @override
  BackendConfigApi get backendConfig => _AnsweringBackendConfig();
}

/// The answer a fail-open would let through.
final class _AnsweringBackendConfig implements BackendConfigApi {
  @override
  Future<BackendConfigDocument> read() async =>
      const BackendConfigDocument(configJson: '{}');

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {}

  @override
  Future<BackendConfigDocument?> previous() async => null;

  @override
  Future<void> restorePrevious({String? reason}) async {}
}
