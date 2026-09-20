/// What member-aware write grading costs, per write.
///
/// **Why this path and not another.** `ValueHandlers.write` now diffs the
/// written value against the gateway's stored one to name the members a frame
/// moves (`written_members.dart`), and asks `gradeTagWrite` for each. That is
/// new work on the one path an operator waits behind — a jog, a start, a
/// setpoint — and it recurses, so a PLC that publishes a drive carrying a
/// motor carrying its own status pays for every leaf.
///
/// **Ceilings, not pins.** Every budget here is one to two orders of
/// magnitude above what the machine that wrote them measured. They exist to
/// catch a regression that changes the shape of the cost — an accidental
/// quadratic, a per-leaf allocation, a policy lookup that starts hitting a
/// database — and not to freeze a number. A budget tight enough to be a
/// contract would be a flake on a loaded CI box, and this repo already has one
/// measurement lane that says so about itself
/// (`slow_consumer_measurement_test.dart`).
///
/// Every arm prints what it measured, so drift is visible to a person reading
/// the log even while the assertion stays green.
@TestOn('vm')
@Tags(['measurement'])
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/written_members.dart';

import '../support/scripted_policy.dart';

const String _key = 'ST101.CN01.MOT01';

/// A conveyor drive as a PLC publishes one: ten members, one of them an enum.
DynamicValue _flatDrive() => DynamicValue(value: {
      for (var i = 0; i < 8; i++) 'p_cfg_$i': DynamicValue(value: i * 1.5),
      'p_cmd_JogFwd': DynamicValue(value: false),
      'p_stat_RunMode': DynamicValue(value: 2),
    });

Map<String, Object?> _flatWrite({bool jog = true}) => {
      for (var i = 0; i < 8; i++) 'p_cfg_$i': i * 1.5,
      'p_cmd_JogFwd': jog,
      'p_stat_RunMode': 2,
    };

/// [depth] levels of nesting, each carrying four scalars and the next level.
DynamicValue _nested(int depth) {
  DynamicValue level(int remaining) => DynamicValue(value: {
        for (var i = 0; i < 4; i++) 'f$i': DynamicValue(value: i.toDouble()),
        if (remaining > 0) 'child': level(remaining - 1),
      });
  return level(depth);
}

Map<String, Object?> _nestedWrite(int depth, {double moved = 0}) {
  Map<String, Object?> level(int remaining) => <String, Object?>{
        for (var i = 0; i < 4; i++)
          'f$i': remaining == 0 && i == 0 ? moved : i.toDouble(),
        if (remaining > 0) 'child': level(remaining - 1),
      };
  return level(depth);
}

/// Runs [body] [n] times after a warm-up and reports microseconds per call.
double _perCall(String what, int n, void Function() body) {
  for (var i = 0; i < n ~/ 10 + 1; i++) {
    body();
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    body();
  }
  watch.stop();
  final per = watch.elapsedMicroseconds / n;
  print('  $what: ${per.toStringAsFixed(2)} us/call '
      '(${watch.elapsedMilliseconds} ms for $n)');
  return per;
}

void main() {
  group('naming the members a frame moves', () {
    test('a flat ten-member drive, the ordinary case', () {
      final baseline = _flatDrive();
      final written = _flatWrite();
      final per = _perCall('flat drive, 10 members', 20000,
          () => writtenMembers(baseline, written));

      expect(per, lessThan(200),
          reason: 'this runs on every jog. At 200 us a 10 Hz hold-to-run '
              'would spend 0.2% of a core on grading alone, which is the '
              'order where somebody should look rather than the order that '
              'is wrong');
    });

    test('depth scales linearly in the number of leaves, not worse', () {
      // The property that matters is the SHAPE of the curve. An accidental
      // quadratic — re-walking the baseline per level, say — would not show
      // up as a slow absolute number on a small fixture; it shows up here.
      final shallow = _nested(2);
      final deep = _nested(8);
      final shallowWrite = _nestedWrite(2);
      final deepWrite = _nestedWrite(8);

      final atTwo = _perCall('nested, depth 2 (12 leaves)', 20000,
          () => writtenMembers(shallow, shallowWrite));
      final atEight = _perCall('nested, depth 8 (36 leaves)', 20000,
          () => writtenMembers(deep, deepWrite));

      // 3x the leaves. Linear would be ~3x; allow a wide margin for constant
      // factors and a loaded machine, but refuse the quadratic (~9x) shape.
      final ratio = atEight / atTwo;
      print('  ratio depth8/depth2: ${ratio.toStringAsFixed(2)}x '
          '(3.0x leaves; linear ~3x, quadratic ~9x)');
      expect(ratio, lessThan(6.0),
          reason: 'the diff must stay linear in the number of leaves. A '
              'ratio near the square of the leaf ratio means something is '
              're-walking a level per level');
    });

    test('a deep struct that moved one leaf is still bounded', () {
      final baseline = _nested(8);
      final written = _nestedWrite(8, moved: 99);
      final per = _perCall('nested depth 8, one leaf moved', 20000,
          () => writtenMembers(baseline, written));
      expect(per, lessThan(500));
    });

    test('no baseline takes the presence walk, and it is not slower', () {
      // The cold-key path. It grades on presence rather than diffing, so it
      // must not be the expensive one — a caller can choose it.
      final written = _flatWrite();
      final per = _perCall('flat drive, no baseline (presence)', 20000,
          () => writtenMembers(null, written));
      expect(per, lessThan(200),
          reason: 'a client chooses this path by writing a key nobody has '
              'subscribed; it must not be a way to make the gateway work '
              'harder than the ordinary one');
    });
  });

  group('grading the members', () {
    late AccessPolicyKeyPolicy adapter;
    late StationIdentity operator;

    setUp(() {
      // A realistic table: 500 bound keys across 20 templates, which is the
      // order a plant has. The lookup is two map hits regardless, and this
      // arm is what would notice if it stopped being.
      final resolver = TagBindingResolver()
        ..setSnapshot(
          keyToTemplate: {
            for (var i = 0; i < 500; i++) 'ST101.CN$i.MOT01': 'tpl${i % 20}',
          },
          templates: {
            for (var i = 0; i < 20; i++)
              'tpl$i': AccessTemplate(name: 'tpl$i', rules: {
                'p_cfg_0': AccessGroup.setpoints,
                'p_frc_Out': AccessGroup.force,
              }),
          },
        );
      adapter = AccessPolicyKeyPolicy(
          policy: AccessPolicy(tagBindings: resolver.groupFor));
      operator = stationHolding(const {AccessGroup.operate});
    });

    test('one write against a 500-key binding table', () {
      final members = writtenMembers(_flatDrive(), _flatWrite());
      final per = _perCall('canWrite, 10 members, 500 bound keys', 20000,
          () => adapter.canWrite(_key, operator, members: members));
      expect(per, lessThan(200),
          reason: 'the binding lookup is two map hits per member and must '
              'stay that way; a scan over the table would show here');
    });

    test('the whole per-write cost, end to end', () {
      // What `ValueHandlers.write` actually pays: the diff and the grading.
      final baseline = _flatDrive();
      final written = _flatWrite();
      final per = _perCall('diff + grade, one write', 20000, () {
        adapter.canWrite(_key, operator,
            members: writtenMembers(baseline, written));
      });
      print('  => a 10 Hz hold-to-run spends '
          '${(per * 10 / 10000).toStringAsFixed(4)}% of one core here');
      expect(per, lessThan(400),
          reason: 'the budget an operator waits behind. Well under a '
              'millisecond is the requirement; 400 us is the alarm');
    });
  });
}
