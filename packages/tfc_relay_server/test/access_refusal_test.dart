/// The gateway's two `StateManApi` decorators, and what each does with the
/// four access families — **post-17-07, where the gate this file used to wait
/// for exists**.
///
/// The previous edition of this file pinned the 17-03b interim: PolicyStateMan
/// threw `UnsupportedError` from all four getters, deliberately not a
/// `forbidden`, because with no gate a deny row would have been FALSE — "a
/// false audit row is worse than a missing one". 17-07 wrote the gate, so the
/// pins invert on schedule:
///
///  * **`PolicyStateMan` gates.** The four getters hand back per-member
///    decorators. A wrongly-grouped (or identity-less) caller is refused with
///    a real `forbidden` — an authorisation VERDICT, with a deny row behind
///    it — and the **source is never consulted**: each decorator holds its
///    source as a thunk evaluated only after the gate passes.
///  * **`SessionHealthStateMan` still delegates.** It adds health keys and no
///    authority; a refusal that reaches a caller through it must be the
///    source's, never one it minted itself.
///
/// The deep arms — per-member grading, deny rows, live controls with a
/// `users`-holding session — are `policy_access_gate_test.dart`'s. This file
/// keeps the two decorators' *shapes* honest: who gates, who delegates, and
/// that a source which genuinely answers is still not reachable around the
/// gate.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
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
/// indistinguishable here from the behaviour being tested.
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
  /// `identityOf` answers null deliberately: a pre-hello session holds
  /// nothing, and every gated member below must fail closed on it.
  PolicyStateMan policyOverPlant({StateManApi? source}) {
    final plant = source ?? FakeStateMan();
    if (plant is FakeStateMan) addTearDown(plant.dispose);
    return PolicyStateMan(
      source: plant,
      policy: const AccessPolicyKeyPolicy(),
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => null,
    );
  }

  group('PolicyStateMan gates the four access families', () {
    test('the four getters answer decorators — no throw, no source touched',
        () {
      // What used to be four UnsupportedError arms. Obtaining the family is
      // free now; the gate sits on the MEMBERS. The fixture proves the source
      // was not consulted: FakeStateMan's own four getters still refuse by
      // name (17-05 has not landed), so touching one here would throw.
      final api = policyOverPlant();
      expect(api.accessTemplates, isA<AccessTemplateApi>());
      expect(api.accessAdmin, isA<AccessAdminApi>());
      expect(api.audit, isA<AuditApi>());
      expect(api.backendConfig, isA<BackendConfigApi>());
    });

    test('a gated member with no identity is refused as a VERDICT — '
        'forbidden, not UnsupportedError', () async {
      // The inversion this file exists to record: with the gate in place the
      // refusal IS a decision about the caller, so it is a forbidden with a
      // deny row behind it (policy_audit_test.dart owns the row arms).
      final api = policyOverPlant();
      Object? caught;
      try {
        await api.audit.distinctWho();
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<rpc.RpcException>(),
          reason: 'a null identity is "nothing", not "everything", and the '
              'answer is now an authorisation verdict rather than an '
              'incomplete-composition marker');
      expect((caught! as rpc.RpcException).code, ServerErrorCodes.forbidden);
      expect((caught as rpc.RpcException).message,
          contains('definitively had no effect'),
          reason: 'the safety wording survives on this family too');
    });

    test('a source that ANSWERS is still not reachable around the gate', () {
      // The fail-open, stated directly — the fixture matters more than the
      // assertion. This source's backendConfig genuinely answers, so a gate
      // that consulted the source before (or instead of) deciding would be
      // observable as a non-throw or as a recorded call.
      final answering = _ConfigAnsweringSource();
      addTearDown(answering.dispose);
      final api = policyOverPlant(source: answering);

      // The control on the fixture itself.
      expect(answering.backendConfig, isA<BackendConfigApi>(),
          reason: 'if this throws, the fixture stopped answering and the arm '
              'below is vacuous');

      expect(() => api.backendConfig.read(),
          throwsA(isA<rpc.RpcException>()
              .having((e) => e.code, 'code', ServerErrorCodes.forbidden)),
          reason: 'D-10 grades all five config members administer, and a '
              'session with no identity holds nothing');
      expect(answering.config.reached, isEmpty,
          reason: 'and the answering source was never consulted: the thunk is '
              'evaluated only after the gate passes, so a refused caller '
              'cannot cost a lookup');
    });

    test('LIVE CONTROL: the four data-service getters still decorate', () {
      // Without this, a PolicyStateMan that threw from every getter would
      // pass every arm above and the file would be judging a broken fixture.
      final api = policyOverPlant();
      expect(api.browse, isA<BrowseApi>());
      expect(api.timeseries, isA<TimeseriesApi>());
      expect(api.historyViews, isA<HistoryViewApi>());
      expect(api.preferences, isA<PreferencesApi>());
    });
  });

  group('SessionHealthStateMan delegates the four access families', () {
    for (final member in accessFamilies) {
      test('$member is forwarded, not answered locally', () {
        // 17-05 gave FakeStateMan real stores behind all four getters, so
        // "forwarded" is now provable at its strongest: the overlay must hand
        // back the very instance the source holds. An overlay that minted its
        // own store — or threw — fails the identity. (All four families are
        // backed by ONE FakeAccessServices, so a member-crossing overlay is
        // not distinguishable here; the handler-table tests own that.)
        final plant = FakeStateMan();
        addTearDown(plant.dispose);
        final health = SessionHealthStateMan(source: plant);
        expect(
          reachFamily(health, member),
          same(reachFamily(plant, member)),
          reason: 'the overlay adds health keys and no authority',
        );
      });
    }

    test('LIVE CONTROL: the overlay forwards a working member too', () {
      // The anti-vacuity half of the delegation claim: an overlay that threw
      // on *everything* would also satisfy the four arms above.
      final plant = FakeStateMan();
      addTearDown(plant.dispose);
      final health = SessionHealthStateMan(source: plant);
      expect(health.preferences, same(plant.preferences));
      expect(health.browse, same(plant.browse));
    });
  });

  group('the shipped composition is fail-closed', () {
    test('policy over health over source: gated members refuse, services '
        'serve', () async {
      // The order `relay_server.dart` actually builds, asserted end to end:
      // the object a handler is handed decides, whatever is underneath it.
      final plant = FakeStateMan();
      addTearDown(plant.dispose);
      final stack = PolicyStateMan(
        source: SessionHealthStateMan(source: plant),
        policy: const AccessPolicyKeyPolicy(),
        resolver: const PermissiveSeriesResolver(),
        tally: SeriesMappingTally(),
        identityOf: () => null,
      );

      // A gated member on every family refuses as a verdict, pre-source —
      // FakeStateMan underneath would have thrown UnsupportedError had the
      // thunk been evaluated, so the forbidden also proves the ordering.
      for (final probe in <Future<void> Function()>[
        () => stack.accessTemplates.delete('Drives'),
        () => stack.accessAdmin.listUsers(),
        () => stack.audit.distinctWho(),
        () => stack.backendConfig.read(),
      ]) {
        Object? caught;
        try {
          await probe();
        } catch (error) {
          caught = error;
        }
        expect(caught, isA<rpc.RpcException>());
        expect((caught! as rpc.RpcException).code, ServerErrorCodes.forbidden);
      }

      // LIVE CONTROL, inline: the same stack still serves the data services.
      expect(stack.preferences, isA<PreferencesApi>());
      expect(stack.timeseries, isA<TimeseriesApi>());
    });
  });
}

/// A source whose `backendConfig` genuinely answers, and records being asked.
class _ConfigAnsweringSource extends FakeStateMan {
  final config = _AnsweringBackendConfig();

  @override
  BackendConfigApi get backendConfig => config;
}

/// The answer a fail-open would let through — with a recorder, so "the source
/// was never consulted" is a measurement rather than a hope.
final class _AnsweringBackendConfig implements BackendConfigApi {
  final reached = <String>[];

  @override
  Future<BackendConfigDocument> read() async {
    reached.add('read');
    return const BackendConfigDocument(configJson: '{}');
  }

  @override
  Future<ConfigValidation> validate(String configJson) async {
    reached.add('validate');
    return const ConfigValidation(ok: true);
  }

  @override
  Future<void> write(String configJson, {String? reason}) async =>
      reached.add('write');

  @override
  Future<BackendConfigDocument?> previous() async {
    reached.add('previous');
    return null;
  }

  @override
  Future<void> restorePrevious({String? reason}) async =>
      reached.add('restorePrevious');
}
