/// The log's two clocks, and the watermark that keeps them from disagreeing.
///
/// [WriteOutcomeLog] prunes on the RECORDING side's clock (`entry.atMs`) and
/// answers `insideWindow` on the PANEL's clock (the cmd's ULID mint instant).
/// Those are the same number only when the two machines agree. A panel running
/// Δ ahead mints at `atMs + Δ`, so there is a Δ-wide interval in which the
/// entry has been pruned and its mint instant still reads inside the window —
/// and the caller, finding no entry, concludes the command never arrived.
///
/// That conclusion is `WriteNotReceived`: the one outcome meaning **safe to
/// re-send**, and a re-send is a second command to a machine.
///
/// `witnessed`'s future bound does not cover it. It refuses a command minted
/// ahead of `now()`, which holds only until this side's clock passes the mint
/// instant — and the interval a panel re-queries in after an outage is on the
/// far side of that.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  const ttl = Duration(seconds: 60);
  const fingerprint = (key: 'CN01.MOT01.speed', value: 1, expect: null);

  /// A log whose clock the case drives.
  ({WriteOutcomeLog log, void Function(int) advanceTo}) logAt(int startMs) {
    var clock = startMs;
    // `startedAtMs` is sampled from `now()` at construction, so the clock is
    // already at `startMs` when the log is built.
    final log = WriteOutcomeLog(ttl: ttl, now: () => clock);
    return (log: log, advanceTo: (int ms) => clock = ms);
  }

  test('a pruned outcome is never reported as never-received, however far the '
      'panel\'s clock runs ahead', () {
    const start = 1_700_000_000_000;
    const skew = Duration(seconds: 15);
    final harness = logAt(start);

    // The gateway records at `start`; the panel minted the id 15 s "later".
    final cmd = newUlid(nowMs: start + skew.inMilliseconds);
    harness.log.record(cmd, WriteApplied(cmd, readback: 1, at: start),
        fingerprint: fingerprint);

    // The disagreement interval: past the TTL on the gateway's clock
    // (61 s since atMs), not past it on the panel's (46 s since mint).
    harness.advanceTo(start + const Duration(seconds: 61).inMilliseconds);
    final mintedAt = ulidMs(cmd)!;

    expect(harness.log.entryFor(cmd), isNull,
        reason: 'the entry is pruned on the gateway\'s own clock — that half '
            'is correct and is what makes the next line matter');
    expect(harness.log.witnessed(mintedAt), isTrue,
        reason: 'the future-bound defence has already lapsed: the gateway\'s '
            'clock has passed the mint instant, so the skew now reads as an '
            'ordinary past time');
    expect(harness.log.insideWindow(mintedAt), isFalse,
        reason: 'and this is the clause that has to catch it. An instant the '
            'log has already forgotten is not inside the window it still '
            'answers for — otherwise the absence of an entry the log deleted '
            'itself becomes evidence that the plant was never touched');
  });

  test('the watermark rises to the MINT instant, not the record instant', () {
    const start = 1_700_000_000_000;
    final harness = logAt(start);
    final cmd = newUlid(nowMs: start + const Duration(seconds: 30).inMilliseconds);
    harness.log.record(cmd, WriteApplied(cmd, readback: 1, at: start),
        fingerprint: fingerprint);

    harness.advanceTo(start + const Duration(seconds: 61).inMilliseconds);
    harness.log.prune();

    // A DIFFERENT command minted a second before the pruned one is also
    // forgotten: the log cannot answer for anything at or before the instant
    // it has discarded, and `insideWindow` is the quantity that must say so.
    final older = ulidMs(newUlid(
        nowMs: start + const Duration(seconds: 29).inMilliseconds))!;
    expect(harness.log.insideWindow(older), isFalse,
        reason: 'bounding on the record time instead would leave every '
            'skewed id below the watermark still reading as inside');
  });

  test('an unskewed log still answers never-received inside its window', () {
    // The control: the watermark must not swallow the verdict it exists to
    // qualify. A command minted inside the TTL that was never recorded is
    // genuinely never-received, and must stay so.
    const start = 1_700_000_000_000;
    final harness = logAt(start);
    final cmd = newUlid(nowMs: start + const Duration(seconds: 5).inMilliseconds);

    harness.advanceTo(start + const Duration(seconds: 20).inMilliseconds);
    final mintedAt = ulidMs(cmd)!;

    expect(harness.log.witnessed(mintedAt), isTrue);
    expect(harness.log.insideWindow(mintedAt), isTrue,
        reason: 'nothing has been forgotten, the id is inside the TTL and no '
            'outcome was recorded — this is the case the verdict is FOR');
  });

  test('a fresh command survives an unrelated prune', () {
    // The watermark is raised by forgetting, so a case that forgets an old
    // command must not thereby disqualify a new one.
    const start = 1_700_000_000_000;
    final harness = logAt(start);
    final old = newUlid(nowMs: start);
    harness.log.record(old, WriteApplied(old, readback: 1, at: start),
        fingerprint: fingerprint);

    harness.advanceTo(start + const Duration(seconds: 61).inMilliseconds);
    final fresh = ulidMs(newUlid(
        nowMs: start + const Duration(seconds: 40).inMilliseconds))!;
    harness.log.prune();

    expect(harness.log.insideWindow(fresh), isTrue,
        reason: 'forgetting a command from a minute ago says nothing about '
            'one minted since');
  });
}
