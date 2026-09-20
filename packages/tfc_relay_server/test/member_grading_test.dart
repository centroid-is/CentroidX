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

    test('an unnamed member takes the key-level answer', () {
      // Documented rather than approved. `written_members.dart` answers
      // `[null]` when it cannot diff, and the key-level answer is the LEAST
      // gated one the template can give. The gateway's baseline is
      // synchronous, so this window is narrower here than in the app — but it
      // is the same window, and it is the one way member gating is bypassed.
      expect(adapter.canWrite(_key, operator, members: const [null]), isTrue,
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
      expect(gated.canWrite(_key, operator, members: const [null]), isFalse,
          reason: 'the fallback is the key-level ANSWER, not the absence of '
              'one — a template that gates the whole key still gates an '
              'undiffable write');
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

    test('no baseline is the key-level question', () {
      expect(writtenMembers(null, {'p_cfg_ManualFreq': 60.0}), [null],
          reason: 'a value with nothing to compare against has no members to '
              'name');
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
