@TestOn('vm')

/// A template that raises one member of a tag must raise it **over the
/// WebSocket**, not only in the app.
///
/// ## What was broken
///
/// `AccessPolicyKeyPolicy.canWrite` asked
/// `groupForWireSurface(AccessSurface.tag.wireName, key)` with **no member**,
/// so a whole-struct write carrying `p_cfg_ManualFreq` was graded as though it
/// carried nothing in particular. `AccessTemplate.groupFor` then saw only the
/// `*` row and the answer fell to the operate floor. Meanwhile
/// `GuardedStateMan` graded the same write per moved member
/// (`guarded_state_man.dart:244-250`).
///
/// Two answers to one question, and the wire's was the permissive one:
/// `setpoints`, `device` and `force` collapsed into `operate` the moment the
/// value left the panel. An Operator-role session — or, on a plant whose
/// `anonymous` row holds `operate`, nobody at all — could write a
/// `force`-bound member over the socket.
///
/// ## The rule both sides now ask
///
/// `tfc_access`'s `gradeTagWrite`. These arms drive the relay's adapter; the
/// app's guard asks the same function, so a divergence between them is a
/// compile error rather than a plant visit.
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/written_members.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/scripted_policy.dart';

/// A conveyor drive: one key carrying a command and a setpoint, which is the
/// ordinary shape (spec §7b) and the whole reason the question has to be asked
/// per member.
const _key = 'ST101.CN01.MOT01';

/// Binds [_key] to a template that leaves the key at the operate floor and
/// raises exactly one member.
AccessPolicy _policyRaising(String member, AccessGroup group) {
  final resolver = TagBindingResolver()
    ..setSnapshot(
      keyToTemplate: const {_key: 'drive'},
      templates: {
        'drive': AccessTemplate(
          name: 'drive',
          rules: {member: group},
        ),
      },
    );
  return AccessPolicy(tagBindings: resolver.groupFor);
}

void main() {
  group('a raised member is enforced on the wire', () {
    final policy = _policyRaising('p_cfg_ManualFreq', AccessGroup.setpoints);
    final adapter = AccessPolicyKeyPolicy(policy: policy);
    final operator = stationHolding(const {AccessGroup.operate});
    final engineer =
        stationHolding(const {AccessGroup.operate, AccessGroup.setpoints});

    test('an operator may still jog the conveyor', () {
      expect(
          adapter.canWrite(_key, operator, members: const ['p_cmd_JogFwd']),
          isTrue,
          reason: 'the template raises one member and leaves the rest at the '
              'operate floor; a jog must not need the setpoint permission');
    });

    test('an operator may NOT move the raised setpoint', () {
      expect(
          adapter.canWrite(_key, operator,
              members: const ['p_cfg_ManualFreq']),
          isFalse,
          reason: 'this is the whole defect: before member grading reached '
              'the wire this answered true, and setpoints collapsed into '
              'operate for every key on the plant');
    });

    test('an engineer holding setpoints may', () {
      expect(
          adapter.canWrite(_key, engineer,
              members: const ['p_cfg_ManualFreq']),
          isTrue);
    });

    test('a whole-struct write is graded by the strictest member it moves', () {
      expect(
          adapter.canWrite(_key, operator,
              members: const ['p_cmd_JogFwd', 'p_cfg_ManualFreq']),
          isFalse,
          reason: 'one frame moving both members needs both permissions; a '
              'jog cannot carry a setpoint change in on its back');
    });

    test('a force-bound member is not reachable with operate alone', () {
      final forced = AccessPolicyKeyPolicy(
          policy: _policyRaising('p_frc_Output', AccessGroup.force));
      expect(
          forced.canWrite(_key, operator, members: const ['p_frc_Output']),
          isFalse,
          reason: 'forced I/O is the group the plant most needs kept apart '
              'from ordinary operation');
    });
  });

  group('the key-level fallback, and its cost stated', () {
    final policy = _policyRaising('p_cfg_ManualFreq', AccessGroup.setpoints);
    final adapter = AccessPolicyKeyPolicy(policy: policy);
    final operator = stationHolding(const {AccessGroup.operate});

    test('a scalar write takes the key-level answer', () {
      // The one shape that legitimately has no members to name. This arm used
      // to be titled "an unnamed member takes the key-level answer" and was
      // reached by a Map-shaped write with no baseline — which made it a pin
      // on an authorisation bypass rather than on a fallback. See
      // `written_members.dart` and the cold-key arms below.
      expect(adapter.canWrite(_key, operator, members: kWholeKeyWrite), isTrue,
          reason: 'the template has no whole-key row, so the key falls to the '
              'operate floor');
    });

    test('a whole-key row still gates the fallback', () {
      final resolver = TagBindingResolver()
        ..setSnapshot(
          keyToTemplate: const {_key: 'drive'},
          templates: {
            'drive': AccessTemplate(name: 'drive', rules: {
              kWholeKeyMember: AccessGroup.setpoints,
              'p_cmd_JogFwd': AccessGroup.operate,
            }),
          },
        );
      final gated = AccessPolicyKeyPolicy(
          policy: AccessPolicy(tagBindings: resolver.groupFor));
      expect(gated.canWrite(_key, operator, members: kWholeKeyWrite), isFalse,
          reason: 'the fallback is the key-level ANSWER, not the absence of '
              'one — a template that gates the whole key still gates an '
              'undiffable write');
    });
  });

  group('a cold key cannot be used to dodge member grading', () {
    // The bypass an architecture review caught after the first version of this
    // fix shipped its member diff. `writtenMembers` answered `[null]` whenever
    // it had no baseline, and the gateway has no baseline for any mapped key
    // nobody subscribes, nothing historises and no alarm rule watches — the
    // pipe "pipes only what it was asked for". The write path's existence
    // check passes for any MAPPED key and requires no prior subscribe, so the
    // missing baseline was not a window: it was a path a caller could choose.
    //
    // An `operate` session wrote the whole struct of a cold key, took the
    // key-level answer, and actuated a `force`-bound member.
    final forced = AccessPolicyKeyPolicy(
        policy: _policyRaising('p_frc_Out', AccessGroup.force));
    final operator = stationHolding(const {AccessGroup.operate});

    test('with no baseline, every member the frame carries is graded', () {
      expect(writtenMembers(null, {'p_cmd_JogFwd': true, 'p_frc_Out': 1}),
          containsAll(<String>['p_cmd_JogFwd', 'p_frc_Out']),
          reason: 'presence, not silence: a caller that has never read the '
              'tag is in no position to claim it is moving only one member');
    });

    test('so the raised member is still refused on a cold key', () {
      expect(
          forced.canWrite(_key, operator,
              members: writtenMembers(null, {'p_frc_Out': 1})),
          isFalse,
          reason: 'THE BYPASS. If this passes, an operate-only session can '
              'force an output on any tag the gateway has not sampled — which '
              'is every mapped tag nobody happens to be watching');
    });

    test('a Bad last sample is the same case', () {
      // A bad-quality relay value carries a null value, so the baseline is
      // not an object either. It must take the presence path, not the
      // key-level one.
      final bad = DynamicValue(value: null, quality: Quality.badCommFault);
      expect(
          forced.canWrite(_key, operator,
              members: writtenMembers(bad, {'p_frc_Out': 1})),
          isFalse,
          reason: 'a tag whose last sample the PLC marked Bad must not become '
              'a way to write its protected members');
    });

    test('and an honest cold jog is still allowed', () {
      expect(
          forced.canWrite(_key, operator,
              members: writtenMembers(null, {'p_cmd_JogFwd': true})),
          isTrue,
          reason: 'grading on presence costs an honest caller nothing: the '
              'frame carries only the member it is moving');
    });
  });

  group('writtenMembers names what a frame moves', () {
    DynamicValue struct(Map<String, Object?> members) => DynamicValue(
        value: {
          for (final e in members.entries) e.key: DynamicValue(value: e.value),
        });

    test('only the members that actually differ', () {
      final baseline =
          struct({'p_cmd_JogFwd': false, 'p_cfg_ManualFreq': 50.0});
      expect(
          writtenMembers(
              baseline, {'p_cmd_JogFwd': true, 'p_cfg_ManualFreq': 50.0}),
          ['p_cmd_JogFwd'],
          reason: 'a jog sends the whole struct; grading on presence rather '
              'than on change would make every jog need the setpoint group');
    });

    test('a moved setpoint is named', () {
      final baseline =
          struct({'p_cmd_JogFwd': false, 'p_cfg_ManualFreq': 50.0});
      expect(
          writtenMembers(
              baseline, {'p_cmd_JogFwd': false, 'p_cfg_ManualFreq': 60.0}),
          ['p_cfg_ManualFreq']);
    });

    test('a member the baseline does not have is named', () {
      final baseline = struct({'p_cmd_JogFwd': false});
      expect(writtenMembers(baseline, {'p_cmd_JogFwd': false, 'p_frc_Out': 1}),
          ['p_frc_Out']);
    });

    test('no baseline names what the frame carries, not nothing', () {
      expect(writtenMembers(null, {'p_cfg_ManualFreq': 60.0}),
          ['p_cfg_ManualFreq'],
          reason: 'this arm used to expect [null] — the key-level question — '
              'and that was the cold-key bypass above. A frame with members '
              'in it always names members; only a shape with none takes the '
              'key-level answer');
    });

    test('a scalar write is the key-level question', () {
      expect(writtenMembers(DynamicValue(value: 1), 2), [null]);
    });

    test('a write that changes nothing names nothing', () {
      final baseline = struct({'p_cfg_ManualFreq': 50.0});
      expect(writtenMembers(baseline, {'p_cfg_ManualFreq': 50.0}), isEmpty,
          reason: 'and gradeTagWrite reads an empty list as the key-level '
              'question, exactly as the app reads an empty diff');
    });

    test('an integral REAL is not "moved" when the client sends it as an int',
        () {
      // dart2js encodes an integral double as `50`, not `50.0`, and gateway
      // mode is the only web arm. Compared with `jsonEquals` — which holds
      // 1 != 1.0 on purpose, because it backs the idempotency fingerprint —
      // every integral REAL member of a whole-struct jog read as moved, so a
      // browser jogging a conveyor needed `setpoints`.
      //
      // Worse than over-gating: gateway mode also wraps the app in
      // GuardedStateMan, which compares with `==`. The app would allow the
      // write and the wire refuse it — two answers to one question again, in
      // the other direction.
      final baseline =
          struct({'p_cmd_JogFwd': false, 'p_cfg_ManualFreq': 50.0});
      expect(
          writtenMembers(
              baseline, {'p_cmd_JogFwd': true, 'p_cfg_ManualFreq': 50}),
          ['p_cmd_JogFwd'],
          reason: '50 and 50.0 are the same setpoint. The runtime-type '
              'distinction belongs to the write fingerprint, where a DINT 1 '
              'and a REAL 1.0 really are two different writes');
    });

    test('nested members carry a dotted path', () {
      final baseline = DynamicValue(value: {
        'motor': DynamicValue(value: {'speed': DynamicValue(value: 10)}),
      });
      expect(
          writtenMembers(baseline, {
            'motor': {'speed': 20}
          }),
          ['motor.speed'],
          reason: 'the same dotted form templates are bound against, and the '
              'same one diffDynamicValue builds');
    });
  });
}
