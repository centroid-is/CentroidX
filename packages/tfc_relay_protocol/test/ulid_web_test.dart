/// The ULID's 48-bit time prefix, checked on a **32-bit-bitwise** backend.
///
/// These cases pass on the VM whatever the implementation does, and that is the
/// point of the file: every one of them was green on the VM while `newUlid()`
/// was silently wrong under `dart2js`, because JavaScript's bitwise operators
/// coerce to **signed 32 bits** and the timestamp field is 48. Run them with
/// `-p chrome` (dart2js) and nothing else — see the compile-target note below.
///
/// **`dart2wasm` cannot substitute for this.** Wasm has true 64-bit integers
/// and produces the correct id, so a Wasm smoke test — which is what
/// `relay-comm-design.md` §8 originally scheduled — passes while the defect
/// ships. `flutter build web` emits dart2js, and `dart test -p chrome` uses
/// dart2js, so dart2js is the only backend that both matters and reproduces it.
///
/// What was actually wrong, measured on the real package before the fix:
///
/// ```text
/// VM      : 01M16HNP00E3SJHFRAN1K5PYMS
/// dart2js : 00016HNP000JJQTTA2X8HTGWGQ
/// ```
///
/// Uniqueness survived — the 80-bit suffix is drawn from `Random.secure()` and
/// never touches a shift — so nothing would have collided. What did not survive
/// is the **time-sortability the file calls load-bearing**: two mints 2^32 ms
/// (49.7 days) apart produced an identical prefix, and every browser-minted id
/// would have sorted before every native one for ever.
@TestOn('browser')
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

// **Every constant here is a literal, and that is not a style choice.**
//
// The first draft of this file wrote them as `1 << 32` and `1 << 40`, and all
// of them evaluated to **0** under dart2js — because a 32-bit shift is exactly
// the defect these cases exist to catch. The test contained the bug it was
// testing for, and reported the fixed code as still broken. A test may not
// build its inputs with the construct under test.

/// The first millisecond that does not fit in 32 bits — `2^32`.
const int _beyond32 = 4294967296;

/// `2^32 - 1`, the last millisecond that does fit.
const int _last32 = 4294967295;

/// `2^40`, well inside the field and well outside 32 bits.
const int _twoTo40 = 1099511627776;

/// The 48-bit field's modulus, `2^48`.
const int _twoTo48 = 281474976710656;

/// What the largest representable timestamp encodes to.
///
/// **Not `ZZZZZZZZZZ`**, which the first draft asserted and which is wrong:
/// ten base-32 characters carry 50 bits and the field is 48, so the top
/// character can only reach `7` (`2^48 - 1` divided by `32^9` is 7.99…). Ten
/// `Z`s would be `2^50 - 1` and would mean the timestamp had spilled two bits
/// past its field — the opposite of the property this pins.
const String _topOfField = '7ZZZZZZZZZ';

String _prefixOf(String ulid) => ulid.substring(0, 10);

void main() {
  test('a timestamp above 2^32 does not fold onto its low 32 bits', () {
    // The exact failure: on a 32-bit-bitwise backend these two mints produce
    // the same prefix, because 2^32 ms is shifted away entirely.
    final low = _prefixOf(newUlid(nowMs: 7));
    final high = _prefixOf(newUlid(nowMs: _beyond32 + 7));

    expect(high, isNot(equals(low)),
        reason: 'two mints 2^32 ms apart share a time prefix, so the '
            'timestamp folded onto its low 32 bits');
  });

  test('prefixes sort in time order across the 32-bit boundary', () {
    // Sortability is the property the id exists for; a dedup log that cannot
    // order two ids cannot tell which write an operator pressed first.
    final ascending = <int>[
      1,
      1048576, // 2^20
      _last32,
      _beyond32,
      _beyond32 + 1,
      _twoTo40,
      _twoTo48 - 1,
    ];

    final prefixes = [for (final ms in ascending) _prefixOf(newUlid(nowMs: ms))];
    final sorted = [...prefixes]..sort();

    expect(prefixes, equals(sorted),
        reason: 'encoded prefixes must sort the way their timestamps do; '
            'got $prefixes');
  });

  test('the whole 48-bit field is reachable, and nothing spills past it', () {
    // The top of the field must encode as the top of the alphabet, and the
    // random suffix must be untouched by it.
    final top = newUlid(nowMs: _twoTo48 - 1);
    expect(_prefixOf(top), equals(_topOfField),
        reason: 'the maximum 48-bit timestamp must fill the field exactly, '
            'and must not spill past it');
    expect(top.length, equals(26));
  });

  test('a timestamp beyond 48 bits wraps into range rather than spilling', () {
    // The doc promises masking, and the arithmetic replacement must keep it:
    // a nonsense clock reading may not push bits into the random characters.
    final wrapped = _prefixOf(newUlid(nowMs: _twoTo48 + 5));
    final inRange = _prefixOf(newUlid(nowMs: 5));

    expect(wrapped, equals(inRange),
        reason: 'a reading past 2^48 must wrap into the field, exactly as the '
            'documented mask did');
  });

  test('two mints in one millisecond still sort by their suffix', () {
    // The bump path uses only small integers and is web-safe, but it is the
    // other half of the ordering promise, so it is pinned on this backend too.
    final first = newUlid(nowMs: _beyond32);
    final second = newUlid(nowMs: _beyond32);

    expect(_prefixOf(second), equals(_prefixOf(first)));
    expect(second.compareTo(first), greaterThan(0),
        reason: 'a second id from the same millisecond must sort after the '
            'first');
  });

  // --------------------------------------------------- the decode half
  //
  // **These are the only arms in the repo that can see the bug they guard.**
  //
  // `ulidMs` had three private copies before Phase 18 and three of the four
  // computed the timestamp with `<<` and `|`. On the VM that is *identical*
  // to the multiply-and-add form — a five-bit shift is a multiply by 32 on
  // 64-bit ints, and the low bits are always clear so the or is an add — so
  // every VM suite in this repo was green the entire time the defect shipped.
  // That is precisely how it survived in three copies.
  //
  // Here it is visible, because this is the backend that breaks. Measured on
  // the bitwise form under dart2js, these arms return 3487918080 and 0 rather
  // than the real millisecond: 1970, for ids minted this year.
  //
  // If these arms are ever deleted as redundant with ulid_test.dart, the
  // decoder goes back to being guarded only by suites that cannot fail.

  test('a timestamp above 2^32 decodes back to itself', () {
    // The mirror of the first encoder arm. A 32-bit-coerced decoder folds
    // this onto its low bits and dates a fresh command to 1970 — which on the
    // write path turns `not_received`, the verdict that tells an operator a
    // re-send is safe, into `unknown`.
    expect(ulidMs(newUlid(nowMs: _beyond32 + 7)), equals(_beyond32 + 7));
    expect(ulidMs(newUlid(nowMs: _twoTo40)), equals(_twoTo40));
  });

  test('the 2023 prefix decodes to exactly 1700000000000 on this backend', () {
    // The literal ulid_test.dart carries for a reader who never runs chrome.
    // There it passes under both arithmetics and documents the bug; here it
    // is an actual gate. Written as a literal, never computed — a test may
    // not build its inputs with the construct under test.
    expect(ulidMs('01HF7YAT000123456789ABCDEF'), equals(1700000000000));
  });

  test('the whole 48-bit field round-trips through encode and decode', () {
    // The top of the field is the worst case for a 32-bit fold: the bitwise
    // form saturates every id at or above 2^32 into the low word, so this one
    // comes back as 4294967295 rather than 2^48 - 1.
    expect(ulidMs(newUlid(nowMs: _twoTo48 - 1)), equals(_twoTo48 - 1));
    expect(ulidMs(newUlid(nowMs: _last32)), equals(_last32),
        reason: 'the last millisecond that does fit in 32 bits must survive '
            'too — a fix that only handles the large case is not a fix');
  });

  test('a non-id is still not datable on this backend', () {
    // The null-versus-zero distinction the callers rely on is arithmetic-free,
    // but it is cheap to pin here and its loss would be silent.
    expect(ulidMs(''), isNull);
    expect(ulidMs('01HF7YAU000123456789ABCDEF'), isNull);
    expect(ulidMs(newUlid(nowMs: 0)), equals(0));
  });
}
