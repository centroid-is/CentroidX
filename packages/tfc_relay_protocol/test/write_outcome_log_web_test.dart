/// The outcome log's window arithmetic, on a **32-bit-bitwise** backend.
///
/// `ulid_web_test.dart` pins the decoder alone: `ulidMs` returns the right
/// millisecond under dart2js. This file pins the **composition** that decoder
/// feeds, which nothing else does on any backend:
///
/// ```text
///   ulidMs(cmd)  ->  witnessed(mintedAt)  /  insideWindow(mintedAt)
/// ```
///
/// That composition is the whole of the positive-evidence rule. A decoder that
/// folds a 2026 timestamp onto its low 32 bits does not merely return a wrong
/// number — it hands `witnessed` a date in 1970, which is before any log's
/// `startedAtMs`, so every `writeStatus` on a browser client would answer
/// `outcome_unwitnessed` and no operator would ever be told a re-send was
/// safe. Measured before 18-01's fix, the bitwise form returned 3487918080 and
/// 0 for ids minted this year.
///
/// The VM cannot see any of this: on 64-bit ints the bitwise and arithmetic
/// forms are the same function, which is exactly how the defect survived in
/// three copies. Run with `-p chrome` (dart2js) and nothing else —
/// `dart2wasm` has true 64-bit integers and would pass while the defect ships.
@TestOn('browser')
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

final class _Clock {
  _Clock(this.nowMs);

  int nowMs;

  void advance(int ms) => nowMs += ms;

  int now() => nowMs;
}

/// A 2023 epoch millisecond, written as a literal.
///
/// Never computed from a shift or a multiply: a test may not build its inputs
/// with the construct under test — the lesson `ulid_web_test.dart` records
/// after its first draft evaluated `1 << 32` to 0 under dart2js and reported
/// the fixed code as broken.
const int _epochStart = 1700000000000;

/// `2^32`, the boundary a signed-32-bit fold collapses across.
const int _beyond32 = 4294967296;

const Duration _ttl = Duration(seconds: 60);

const WriteFingerprint _setSpeed1200 =
    (key: 'CN01.MOT01.speed', value: 1200, expect: null);

void main() {
  test('an id minted now is witnessed on this backend', () {
    final clock = _Clock(_epochStart);
    final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
    clock.advance(1000);

    final cmd = newUlid(nowMs: clock.nowMs);
    final mintedAt = ulidMs(cmd);

    expect(mintedAt, equals(clock.nowMs),
        reason: 'the decoder must survive dart2js before anything downstream '
            'of it can be trusted');
    expect(log.witnessed(mintedAt!), isTrue,
        reason: 'a 2023 timestamp folded onto 32 bits dates to 1970, lands '
            'before startedAtMs, and turns every browser writeStatus into '
            'outcome_unwitnessed');
    expect(log.insideWindow(mintedAt), isTrue);
  });

  test('the TTL boundary is inclusive on this backend too', () {
    final clock = _Clock(_epochStart);
    final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
    final cmd = newUlid(nowMs: clock.nowMs);
    final mintedAt = ulidMs(cmd)!;

    clock.advance(_ttl.inMilliseconds);
    expect(log.insideWindow(mintedAt), isTrue,
        reason: 'now - minted == ttl is inside the window on every target');

    clock.advance(1);
    expect(log.insideWindow(mintedAt), isFalse);
  });

  test('a log started beyond 2^32 still refuses an id minted before it', () {
    // Both operands are past the 32-bit boundary, so a fold would collapse
    // them together and the ordering that carries the whole claim would
    // vanish — the log would vouch for a command from before it existed.
    final clock = _Clock(_beyond32 + 10000);
    final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);

    final before = ulidMs(newUlid(nowMs: _beyond32 + 9999))!;
    expect(log.witnessed(before), isFalse,
        reason: 'one millisecond before the log started is outside its window '
            'on a 32-bit backend as well as on the VM');

    final after = ulidMs(newUlid(nowMs: _beyond32 + 10000))!;
    expect(log.witnessed(after), isTrue);
  });

  test('a future-dated id is refused on this backend', () {
    final clock = _Clock(_epochStart);
    final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
    clock.advance(5000);

    final ahead = ulidMs(newUlid(nowMs: clock.nowMs + 1))!;
    expect(log.witnessed(ahead), isFalse,
        reason: 'the fast-clocked-panel refusal must hold on the browser, '
            'which is where a machine\'s clock is least controlled');
  });

  test('record and replay round-trip under a real minted id', () {
    final clock = _Clock(_epochStart);
    final log = WriteOutcomeLog(ttl: _ttl, now: clock.now);
    final cmd = newUlid(nowMs: clock.nowMs);

    log.record(cmd, WriteNotReceived(cmd), fingerprint: _setSpeed1200);

    expect(log.entryFor(cmd), isNotNull);
    expect(log.entryFor(cmd)!.matches(_setSpeed1200), isTrue);
  });
}
