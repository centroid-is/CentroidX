/// The shared write-outcome log, judged directly.
///
/// This log is what answers `writeStatus`, and `writeStatus` is the only place
/// a client is ever told that a re-send is safe. Every arm here is therefore a
/// safety arm rather than a data-structure arm: the question behind all of them
/// is "when may this log let a caller reach [WriteNotReceived]?"
///
/// The clock is injected throughout — `int Function()`, never `DateTime.now()`
/// — so an aged entry is modelled with arithmetic rather than with a sleep.
/// That is the same convention `tfc_relay_server`'s `FakeClock` was written
/// for; it is restated locally here because `tfc_relay_protocol` has no test
/// support library and may not take a dependency on one.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// A millisecond counter that only moves when it is moved.
final class _Clock {
  _Clock(this.nowMs);

  int nowMs;

  void advance(int ms) => nowMs += ms;

  int now() => nowMs;
}

/// A round epoch anchor, well above 2^32 so that a decoder or a comparison
/// that silently folded to 32 bits would not accidentally agree here.
const int _epochStart = 1700000000000;

const Duration _ttl = Duration(seconds: 60);

const WriteFingerprint _setSpeed1200 =
    (key: 'CN01.MOT01.speed', value: 1200, expect: null);
const WriteFingerprint _setSpeed1450 =
    (key: 'CN01.MOT01.speed', value: 1450, expect: null);

WriteResult _applied(String cmd, {Object? readback = 1200}) =>
    WriteApplied(cmd, readback: readback, at: _epochStart);

void main() {
  group('WriteOutcomeLog', () {
    test('1. a recorded outcome replays identically, and a second record '
        'under the same cmd replaces rather than duplicates', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      final first = _applied('CMD-A');
      log.record('CMD-A', first, fingerprint: _setSpeed1200);

      final held = log.entryFor('CMD-A');
      expect(held, isNotNull);
      expect(held!.result, same(first),
          reason: 'the log hands back the very result it was given; a log '
              'that reconstructed one could reconstruct it wrongly');
      expect(held.fingerprint, _setSpeed1200);
      expect(held.atMs, _epochStart);
      expect(log.recordedOutcomes, 1);

      final second = _applied('CMD-A', readback: 1450);
      log.record('CMD-A', second, fingerprint: _setSpeed1450);

      expect(log.recordedOutcomes, 1,
          reason: 'one cmd is one operator action, so it has one outcome. A '
              'second entry under the same id would mean the log could answer '
              'two different things about one press of a button');
      expect(log.entryFor('CMD-A')!.result, same(second));
    });

    test('2. the fingerprint is compared, and the type system refuses a null '
        'one', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('CMD-A', _applied('CMD-A'), fingerprint: _setSpeed1200);

      final held = log.entryFor('CMD-A')!;
      expect(held.matches(_setSpeed1200), isTrue);
      expect(held.matches(_setSpeed1450), isFalse,
          reason: 'answering one write from another write\'s entry puts '
              '"applied" on a setpoint nobody applied');

      // A STRUCTURAL arm, and it is here because the behavioural one cannot
      // exist. `tfc_dart` made `fingerprint` required and non-nullable; the
      // server's older copy left it nullable with a `mine == null -> false`
      // branch. Both REFUSE a replay, so no behavioural case can tell them
      // apart — and that is precisely why reverting to the nullable shape
      // would be a silent regression rather than a visible one.
      //
      // Parameter types are contravariant, so a `record` whose fingerprint is
      // non-nullable is NOT a subtype of one whose fingerprint is nullable.
      // The day someone restores the nullable shape, this flips to true.
      expect(
          log.record is void Function(String, WriteResult,
              {String? ownerHint, required WriteFingerprint? fingerprint}),
          isFalse,
          reason: 'the shared log\'s fingerprint must stay non-nullable. A '
              'nullable fingerprint is a match that silently never matches, '
              'and it is the one improvement tfc_dart made over the server\'s '
              'copy — it must not be reverted by a future merge from the '
              'server\'s history');
    });

    test('3. witnessed refuses an id minted before the log started', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      expect(log.witnessed(_epochStart - 1), isFalse,
          reason: 'absence from a log that did not exist yet is not evidence '
              'of anything; the caller must answer unknown, not never-received');
      expect(log.witnessed(_epochStart), isTrue,
          reason: 'the instant the log started is inside its own window — an '
              'exclusive bound here would blind the log to its first '
              'millisecond');
    });

    test('4. witnessed refuses an id minted in the future, at the exact '
        'boundary', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      clock.advance(5000);

      expect(log.witnessed(clock.nowMs), isTrue,
          reason: 'minted exactly now is witnessed');
      expect(log.witnessed(clock.nowMs + 1), isFalse,
          reason: 'a panel whose clock runs ahead must not buy itself a '
              'not_received window of ttl + skew');
    });

    test('5. insideWindow is inclusive at the TTL', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      final minted = clock.nowMs;
      clock.advance(_ttl.inMilliseconds);

      expect(log.insideWindow(minted), isTrue,
          reason: 'now - minted == ttl is still inside the window');
      clock.advance(1);
      expect(log.insideWindow(minted), isFalse,
          reason: 'one millisecond past the TTL is outside it. The flip '
              'between these two answers is a one-character mutation and it '
              'changes which verdict an operator is given');
    });

    test('6. prune drops what is past the TTL and keeps the rest, and the '
        'survivors are still replayable', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      log.record('OLD', _applied('OLD'), fingerprint: _setSpeed1200);
      clock.advance(_ttl.inMilliseconds + 1);
      log.record('NEW', _applied('NEW'), fingerprint: _setSpeed1450);

      expect(log.recordedOutcomes, 1);
      expect(log.entryFor('OLD'), isNull);

      final survivor = log.entryFor('NEW');
      expect(survivor, isNotNull);
      expect(survivor!.fingerprint, _setSpeed1450,
          reason: 'a surviving entry survives whole — pruning is about age, '
              'never about content');
    });

    test('7. prune is idempotent with the clock unmoved', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
      log.record('A', _applied('A'), fingerprint: _setSpeed1200);
      log.record('B', _applied('B'), fingerprint: _setSpeed1450);

      log.prune();
      expect(log.recordedOutcomes, 2);
      log.prune();
      expect(log.recordedOutcomes, 2,
          reason: 'pruning is a function of the clock, not of how often it is '
              'called. A prune that dropped a little more each time would '
              'forget live writes on a busy log');
    });

    test('8. an empty log answers entryFor with null', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      expect(log.entryFor('NEVER-SEEN'), isNull,
          reason: 'null is the state the four-piece evidence rule reasons '
              'from. An exception or a synthesised entry would either crash '
              'the caller or invent evidence it does not have');
      expect(log.recordedOutcomes, 0);
    });

    test('9. ttl and startedAtMs are readable', () {
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      expect(log.ttl, _ttl,
          reason: 'the caller interpolates the TTL into the operator-visible '
              'outcome_expired message; a log that will not say its own TTL '
              'forces every caller to hold a second copy of it');
      expect(log.startedAtMs, _epochStart,
          reason: 'startedAtMs is sampled at construction from the injected '
              'clock — the lower bound of every not_received');
    });

    test('10. the log is unbounded in count inside the TTL', () {
      // Pinning the CURRENT behaviour deliberately, not endorsing it. This log
      // is bounded in TIME and not in COUNT, which is a growth path: see the
      // deferred finding in 18-04-SUMMARY. A property nobody pinned is a
      // property a later change alters without anyone noticing.
      final clock = _Clock(_epochStart);
      final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

      for (var i = 0; i < 10000; i++) {
        log.record('CMD-$i', _applied('CMD-$i'), fingerprint: _setSpeed1200);
      }

      expect(log.recordedOutcomes, 10000,
          reason: 'no cap and no eviction: every entry inside the TTL is kept');
      expect(log.entryFor('CMD-0'), isNotNull,
          reason: 'the very first entry is still replayable, so nothing was '
              'evicted by age-of-insertion');
      expect(log.entryFor('CMD-9999'), isNotNull);
    });
  });
}
