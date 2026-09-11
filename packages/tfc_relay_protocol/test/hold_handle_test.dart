/// The hold-to-run handle, judged by what an operator's finger can cause.
///
/// Every hold verb lives here rather than on `StateManApi` (05-RESEARCH §B.2):
/// a method on the interface is a thing any connected client may invoke
/// against any key, and a bare `tick(key, n)` is a write primitive with no
/// engage in front of it.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The compile-time tripwire for [HoldEnded]: an exhaustive switch with no
/// default arm and no wildcard arm, so a sixth reason cannot be added without
/// somebody writing down what it means for the machine
/// (`relay_session.dart:298-306` is the idiom).
String operatorConsequenceOf(HoldEnded reason) => switch (reason) {
      HoldEnded.operatorLetGo => 'the operator let go of the button',
      HoldEnded.lifecycle => 'the app stopped being in front of the operator',
      HoldEnded.disconnect => 'the link to the gateway went down',
      HoldEnded.refused => 'the engage never took, so nothing was ever held',
      HoldEnded.disposed => 'the source was torn down under the hold',
    };

/// Records what the plant side of a handle saw, in order.
final class _Plant {
  final ticks = <int>[];
  final releases = <int>[];
  WriteResult releaseOutcome =
      const WriteApplied('01RELEASE', readback: 0, at: 1);

  void onTick(int counter) => ticks.add(counter);

  Future<WriteResult> onRelease(int counter) async {
    releases.add(counter);
    return releaseOutcome;
  }
}

const _applied = WriteApplied('01ENGAGE', readback: 1, at: 1);
const _rejected =
    WriteRejected('01ENGAGE', WriteReason('interlocked', message: 'guard open'));

void main() {
  late _Plant plant;

  setUp(() => plant = _Plant());

  HoldHandle handleWith(WriteResult engagement, {int startCounter = 1}) =>
      HoldHandle(
        key: 'ST101.CN01.jog',
        engagement: engagement,
        onTick: plant.onTick,
        onRelease: plant.onRelease,
        startCounter: startCounter,
      );

  group('a hold that took', () {
    test('is held, and its counter starts at the value the engage wrote', () {
      final hold = handleWith(_applied);
      expect(hold.isHeld, isTrue);
      expect(hold.counter, 1);
      expect(hold.key, 'ST101.CN01.jog');
      expect(hold.engagement, same(_applied));
    });

    test('advances the counter on every tick and the plant sees each value',
        () {
      final hold = handleWith(_applied);
      hold.tick();
      hold.tick();
      expect(hold.counter, 3);
      expect(plant.ticks, [2, 3],
          reason: 'the engage already wrote 1; the ticks that follow are the '
              'liveness the PLC deadman is watching');
    });

    test('writes a zero on release and says why it ended', () async {
      final hold = handleWith(_applied);
      final outcome = await hold.release(reason: HoldEnded.lifecycle);
      expect(plant.releases, [0],
          reason: '0 is reserved for released (05-RESEARCH §B.6)');
      expect(hold.isHeld, isFalse);
      expect(await hold.onReleased, HoldEnded.lifecycle);
      expect(outcome, same(plant.releaseOutcome));
    });

    test('releases for the operator by default', () async {
      final hold = handleWith(_applied);
      await hold.release();
      expect(await hold.onReleased, HoldEnded.operatorLetGo);
    });
  });

  group('a hold that never took', () {
    test('a hold whose engage was refused is not held and is already released',
        () async {
      final hold = handleWith(_rejected);
      expect(hold.isHeld, isFalse);
      expect(await hold.onReleased, HoldEnded.refused);
      expect(hold.engagement, same(_rejected));
    });

    test('is not feedable', () {
      final hold = handleWith(_rejected);
      hold.tick();
      hold.tick();
      expect(plant.ticks, isEmpty,
          reason: 'a hold nobody took must not be able to advance a deadman '
              'counter — that would be liveness with no engage behind it');
      expect(hold.counter, 1);
    });

    test('releasing it writes nothing, because there is nothing to release',
        () async {
      final hold = handleWith(_rejected);
      await hold.release();
      expect(plant.releases, isEmpty);
    });

    test('an unknown engage is treated as not held either', () async {
      final hold = handleWith(
          const WriteUnknown('01ENGAGE', WriteReason('link_lost')));
      expect(hold.isHeld, isFalse);
      expect(await hold.onReleased, HoldEnded.refused);
      hold.tick();
      expect(plant.ticks, isEmpty,
          reason: 'an engage that may or may not have landed is not evidence '
              'that the machine is under a hold');
    });
  });

  group('release is idempotent', () {
    test('a second release does not write a second zero', () async {
      final hold = handleWith(_applied);
      final first = hold.release();
      final second = hold.release();
      expect(second, same(first),
          reason: 'the second caller gets the first release, not a new write');
      await Future.wait([first, second]);
      expect(plant.releases, [0]);
    });

    test('a tick after release does not reach the plant', () async {
      final hold = handleWith(_applied);
      await hold.release();
      hold.tick();
      expect(plant.ticks, isEmpty,
          reason: 'the machine stops when the counter stops; a tick after the '
              'release write would restart the deadman the release just ended');
    });

    test('the reason of the first release is the one that stands', () async {
      final hold = handleWith(_applied);
      await hold.release(reason: HoldEnded.disconnect);
      await hold.release(reason: HoldEnded.operatorLetGo);
      expect(await hold.onReleased, HoldEnded.disconnect);
    });

    test('onReleased completes even when the release write fails', () async {
      plant.releaseOutcome =
          const WriteUnknown('01RELEASE', WriteReason('link_lost'));
      final hold = handleWith(_applied);
      final outcome = await hold.release(reason: HoldEnded.disconnect);
      expect(outcome, isA<WriteUnknown>());
      expect(await hold.onReleased, HoldEnded.disconnect,
          reason: 'the machine stopped when the counter stopped; the release '
              "write's outcome is informational");
    });
  });

  test('the counter wraps to one rather than going negative', () {
    // 2^31-1 ticks at 10 Hz is ~6.8 years of continuous holding, so this
    // cannot happen; a signed DINT going negative is an ugly thing to explain
    // to an integrator, so it is written anyway (D-P5-E).
    final hold = handleWith(_applied, startCounter: 2147483647);
    hold.tick();
    expect(hold.counter, 1);
    hold.tick();
    expect(hold.counter, 2);
    expect(plant.ticks, [1, 2]);
    expect(plant.ticks.every((n) => n > 0), isTrue);
  });

  test('every reason a hold can end names an operator consequence', () {
    final sentences = {
      for (final reason in HoldEnded.values) operatorConsequenceOf(reason),
    };
    expect(sentences, hasLength(HoldEnded.values.length),
        reason: 'the switch above has no default arm on purpose: a sixth '
            'reason must not compile until somebody writes down what it '
            'means for the machine');
    expect(HoldEnded.values, hasLength(5));
  });
}
