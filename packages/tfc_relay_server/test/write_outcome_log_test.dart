/// The outcome log judged as data: what an entry remembers about the *request*
/// it was recorded for, and the window it is still entitled to speak about.
///
/// The log's behaviour over a wire is covered where it is reached from —
/// `value_handlers_test.dart` drives every handler that consults it. What is
/// asserted here is the piece 05-03 adds underneath that: an entry now carries
/// the [WriteFingerprint] of the write it recorded, so the gateway can tell one
/// operator action arriving twice from two different actuations colliding on
/// one id. That distinction is the whole of the idempotency window, and getting
/// it wrong in the generous direction reports a setpoint as applied that nobody
/// applied.
///
/// Everything here is arithmetic on a hand-cranked clock, for the same reason
/// the neighbouring suites are: a TTL is a claim about *when*, not about how
/// long a test is willing to sleep.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fake_clock.dart';

/// Far enough from zero that a ULID minted on it is a plausible id, matching
/// `value_handlers_test.dart`.
const int _epochStart = 1_760_000_000_000;

const Duration _ttl = Duration(seconds: 60);

/// The request an operator's press turns into: set the line speed to 1200.
const WriteFingerprint _setSpeed1200 =
    (key: 'CN01.MOT01.speed', value: 1200, expect: null);

WriteResult _applied(String cmd, {Object? readback = 1200}) =>
    WriteApplied(cmd, readback: readback, at: _epochStart);

void main() {
  group('the request an outcome was recorded for', () {
    test('a replay of the same key, value and expect is the same write', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      expect(log.entryFor('CMD-A')!.matches(_setSpeed1200), isTrue,
          reason: 'this is the operator\'s same press arriving twice — a '
              'client that restarted and still holds the id it minted. The '
              'honest answer is the outcome that press already got, not a '
              'second actuation and not a refusal');
    });

    test('two writes under one id with different values are not the same write',
        () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      expect(
          log.entryFor('CMD-A')!.matches(
              (key: 'CN01.MOT01.speed', value: 1500, expect: null)),
          isFalse,
          reason: 'answering 1500 with the outcome of the write that set 1200 '
              'would put "applied" on a setpoint the plant never received. '
              'This is the case a key-only comparison silently passes');
    });

    test('a different key under one id is not the same write', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      expect(
          log.entryFor('CMD-A')!
              .matches((key: 'CN02.MOT01.speed', value: 1200, expect: null)),
          isFalse,
          reason: 'the same number to a different motor is a different '
              'machine moving');
    });

    test('a reordered params map is the same write', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record(
          'CMD-A',
          _applied('CMD-A'),
          fingerprint: (
            key: 'CN01.MOT01.recipe',
            value: {'speed': 1200, 'ramp': 5},
            expect: null,
          ));

      expect(
          log.entryFor('CMD-A')!.matches((
            key: 'CN01.MOT01.recipe',
            value: {'ramp': 5, 'speed': 1200},
            expect: null,
          )),
          isTrue,
          reason: 'JSON object order is not semantically meaningful, so a '
              'client that rebuilt its params map in a different iteration '
              'order must not have its own replay refused as a new write. '
              'Comparing encoded strings would fail exactly here');
    });

    test('a DINT 1 and a REAL 1.0 are not the same write', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A', readback: 1),
          fingerprint: (key: 'CN01.MOT01.enable', value: 1, expect: null));

      expect(
          log.entryFor('CMD-A')!
              .matches((key: 'CN01.MOT01.enable', value: 1.0, expect: null)),
          isFalse,
          reason: 'two differently typed tags, and `jsonEquals` holds numbers '
              'to their runtime type on purpose. The safe direction on this '
              'path is a refusal, which means "definitively no effect"');
    });

    test('a replay carrying a different compare-and-set guard is not the same '
        'write', () {
      // D-P5-A's sibling, D-P5-B: "set 1450" and "set 1450 only if it still
      // reads 1200" are two different operator intents.
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A', readback: 1450),
          fingerprint:
              (key: 'CN01.MOT01.speed', value: 1450, expect: 1200));

      expect(
          log.entryFor('CMD-A')!
              .matches((key: 'CN01.MOT01.speed', value: 1450, expect: null)),
          isFalse,
          reason: 'answering the unguarded write with the guarded one\'s '
              'outcome reports that a check passed which was never made');
    });

    // REMOVED by 18-04: 'an entry recorded with no fingerprint matches
    // nothing'.
    //
    // That arm recorded an outcome with no fingerprint and asserted the entry
    // then matched nothing. Its subject no longer exists: the shared
    // `WriteOutcomeLog` makes `fingerprint` **required and non-nullable**, so
    // the state the arm constructed is now unrepresentable and the line no
    // longer compiles.
    //
    // The branch it covered was already dead in production — this file's own
    // doc recorded that both record sites in `value_handlers.dart` have the
    // decoded `WriteParams` in scope — so nothing but this arm ever built one.
    // Making the unsafe state unrepresentable is strictly stronger than
    // refusing it at runtime.
    //
    // The guarantee did not go unguarded. It moved and changed kind: it is now
    // a STRUCTURAL arm in
    // `tfc_relay_protocol/test/write_outcome_log_test.dart` ("the fingerprint
    // is compared, and the type system refuses a null one"), which asserts on
    // `record`'s own function type. A behavioural arm cannot exist for this —
    // the nullable and non-nullable shapes both refuse a replay — which is
    // exactly why reverting the improvement would otherwise be silent.

    test('the entry hands back the request it was recorded for', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      expect(log.entryFor('CMD-A')!.fingerprint, _setSpeed1200,
          reason: 'records compare structurally, so the entry carrying the '
              'request is directly inspectable — the handler builds one from '
              'the decoded WriteParams and asks the entry about it');
    });
  });

  // The widened entry changes *what* is stored, never *when* it is forgotten.
  group('the window, unchanged by the widening', () {
    test('an outcome past the TTL is forgotten, fingerprint and all', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      clock.advance(const Duration(seconds: 61).inMilliseconds);

      expect(log.entryFor('CMD-A'), isNull,
          reason: 'past the TTL the id is indistinguishable from one nobody '
              'has used; the write goes upstream on its merits');
      expect(log.recordedOutcomes, 0,
          reason: 'the entry got bigger by a key and two decoded values, both '
              'bounded at ingress by maxFrameBytes. The bound that matters is '
              'still "writes within the TTL" (T-04-06)');
    });

    test('witnessed() still refuses a cmd from before the log started and one '
        'from the future', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      expect(log.witnessed(_epochStart - 1), isFalse);
      expect(log.witnessed(_epochStart + 1), isFalse);
      expect(log.witnessed(_epochStart), isTrue,
          reason: 'not_received needs positive evidence, and the two clamps '
              'above are it. Nothing in the fingerprint work touches them');
    });

    test('insideWindow() still measures against the TTL', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      clock.advance(const Duration(seconds: 61).inMilliseconds);

      expect(log.insideWindow(_epochStart), isFalse);
      expect(log.insideWindow(clock.nowMs), isTrue);
    });

    test('a recorded outcome replaces whatever the id held before', () {
      final clock = FakeClock(start: _epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record(
          'CMD-A',
          WriteUnknown('CMD-A', const WriteReason('in_flight')),
          fingerprint: _setSpeed1200);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      expect(log.entryFor('CMD-A')!.result, isA<WriteApplied>(),
          reason: 'the in-flight pre-record is superseded by the settled one, '
              'which is what makes a replay after settling read applied');
      expect(log.recordedOutcomes, 1);
    });
  });
}
