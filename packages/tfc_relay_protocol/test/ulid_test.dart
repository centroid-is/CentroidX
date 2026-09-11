import 'package:test/test.dart';
import 'package:tfc_relay_protocol/src/ulid.dart';

/// One property per test. A `cmd` id that is short, non-unique, non-sortable
/// or guessable each breaks a different part of the write path, so each is
/// asserted on its own.
void main() {
  const crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  test('a ULID is 26 characters long', () {
    expect(newUlid(), hasLength(26));
    expect(newUlid(nowMs: 0), hasLength(26));
    expect(newUlid(nowMs: (1 << 48) - 1), hasLength(26),
        reason: 'the timestamp field never overflows into the random field');
  });

  test('a ULID uses only the Crockford base32 alphabet', () {
    for (var i = 0; i < 200; i++) {
      final id = newUlid();
      for (final unit in id.split('')) {
        expect(crockford.contains(unit), isTrue,
            reason: '"$unit" in $id is outside Crockford base32 — I, L, O and '
                'U are excluded so an operator reading an id off a screen '
                'cannot transcribe it wrong');
      }
    }
  });

  test('the timestamp is the leading 10 characters, zero at epoch', () {
    expect(newUlid(nowMs: 0).substring(0, 10), '0000000000');
    expect(newUlid(nowMs: (1 << 48) - 1).substring(0, 10), '7ZZZZZZZZZ',
        reason: '48 bits of milliseconds is the whole timestamp field');
  });

  test('ULIDs minted in different milliseconds sort in time order', () {
    final earlier = newUlid(nowMs: 1786000000000);
    final later = newUlid(nowMs: 1786000000001);
    final muchLater = newUlid(nowMs: 1786000060000);

    expect(earlier.compareTo(later), lessThan(0));
    expect(later.compareTo(muchLater), lessThan(0),
        reason: 'a dedup log sorted by cmd is sorted by when the operator '
            'acted');
  });

  test('ULIDs minted within one millisecond are distinct and ordered', () {
    final ids = [for (var i = 0; i < 500; i++) newUlid(nowMs: 1786000000000)];

    expect(ids.toSet(), hasLength(ids.length),
        reason: 'two operator actions in the same millisecond must never '
            'collide into one dedup entry');
    final sorted = [...ids]..sort();
    expect(sorted, ids,
        reason: 'the within-millisecond counter keeps later actions sorting '
            'after earlier ones');
  });

  test('an id within one millisecond is not its predecessor plus one', () {
    // WR-03. Standard ULID monotonicity increments the suffix by 1, which
    // keeps the ordering and hands anyone holding one id every neighbouring
    // id from the same millisecond — and writeStatus is queried by id.
    var adjacent = 0;
    String? previous;
    for (var i = 0; i < 500; i++) {
      final id = newUlid(nowMs: 1786000000000);
      if (previous != null && _isSuccessorOf(id, previous)) adjacent++;
      previous = id;
    }
    // A random step of exactly 1 is legitimate (~1/65536 per pair, so ~0.76%
    // of 499-pair runs see one) — the property WR-03 guards is that steps are
    // not PREDICTABLY +1. Standard-ULID monotonicity would make all 499
    // adjacent; a handful by chance is expected noise.
    expect(adjacent, lessThan(10),
        reason: 'the step between two ids in one millisecond is a secure '
            'random delta, so the next id cannot be computed from this one — '
            'all-adjacent (499) is the standard-ULID regression this forbids');
  });

  test('10,000 ULIDs from a tight loop are all distinct', () {
    final ids = <String>{};
    for (var i = 0; i < 10000; i++) {
      ids.add(newUlid());
    }
    expect(ids, hasLength(10000));
  });

  test('the random component differs across milliseconds', () {
    final suffixes = <String>{
      for (var ms = 1786000000000; ms < 1786000000100; ms++)
        newUlid(nowMs: ms).substring(10),
    };

    expect(suffixes, hasLength(100),
        reason: 'a hostile client that guesses a cmd can re-query another '
            "operator's write outcome, so the entropy is Random.secure()");
  });

  test('the random component is 16 characters and varies within a run', () {
    final a = newUlid(nowMs: 5).substring(10);
    final b = newUlid(nowMs: 6).substring(10);

    expect(a, hasLength(16));
    expect(b, hasLength(16));
    expect(a, isNot(b));
  });

  // ------------------------------------------------------- the decode half
  //
  // `ulidMs` is the inverse of the timestamp prefix `newUlid` writes. It is
  // the evidence `writeStatus` dates a command by: a datable id inside the
  // window answers `not_received`, which invites an operator to re-send. An
  // id this side cannot date answers `unknown`. Mis-dating one as the other
  // is a write-safety change, so every property below is pinned separately.

  test('a ULID round-trips to the millisecond it was minted at', () {
    // The 2100 case is the one that matters: 4102444800000 is well past 2^32,
    // so an implementation whose arithmetic is coerced to 32 bits cannot
    // produce it. The other two bracket it with a real past instant and now.
    final now = DateTime.now().millisecondsSinceEpoch;

    expect(ulidMs(newUlid(nowMs: now)), now);
    expect(ulidMs(newUlid(nowMs: 1500000000000)), 1500000000000,
        reason: '2017 — an ordinary instant this system has already seen');
    expect(ulidMs(newUlid(nowMs: 4102444800000)), 4102444800000,
        reason: '2100, past 2^32 ms: a 32-bit-coerced shift cannot reach it');
  });

  test('the top of the 48-bit field round-trips', () {
    // **This arm exists because sabotage proved the three above cannot fail
    // for a whole class of defect, and the finding generalises.**
    //
    // Every timestamp a plant will ever mint encodes with '0' in position 0:
    // the first character only becomes non-zero at 32^9 ms, which is the year
    // 3084. So an implementation that skips position 0 entirely — an off-by-one
    // in the loop bound — decodes every realistic id *correctly*, and each of
    // the round-trip cases above stays green while the decoder is broken.
    //
    // 2^48-1 encodes as `7ZZZZZZZZZ`, the only value in this file whose leading
    // character carries information. It is what makes the loop bound testable
    // at all. An arm written only from realistic examples cannot see a defect
    // at a position realistic examples never exercise.
    expect(ulidMs(newUlid(nowMs: 281474976710655)), 281474976710655);
    expect(newUlid(nowMs: 281474976710655).substring(0, 10), '7ZZZZZZZZZ',
        reason: 'if this stops being the top of the field, the arm above stops '
            'covering position 0 and the loop bound goes unguarded again');
  });

  test('the 2023 prefix decodes to exactly 1700000000000', () {
    // **Stated as a value, not as a platform, and that is deliberate.**
    //
    // This arm passes on the VM under BOTH arithmetics — the shift-and-or
    // form and the multiply-and-add form are identical on 64-bit ints — so on
    // the VM it proves only that the decode is right. Its job is the literal
    // that a `dart test -p chrome` run turns red: under dart2js the bitwise
    // form coerces to 32 bits and this same id decodes to 3487918080, which
    // is 1970-02-10. See ulid_web_test.dart for the arm that actually runs
    // on that backend.
    //
    // The prefix is written as a literal rather than computed, for the reason
    // ulid_web_test.dart records at length: a test may not build its inputs
    // with the construct under test.
    expect(ulidMs('01HF7YAT00$_suffix'), 1700000000000);
  });

  test('only a 26-character string is datable', () {
    expect(ulidMs(''), isNull);
    expect(ulidMs('01HF7YAT00$_suffix'.substring(0, 25)), isNull,
        reason: '25 characters is not an id this side could have issued');
    expect(ulidMs('01HF7YAT00${_suffix}Z'), isNull,
        reason: '27 characters is not one either');
  });

  test('a character outside Crockford base32 is not datable', () {
    // I, L, O and U are excluded from the alphabet, so their appearance in
    // the timestamp half means the string was never minted here.
    for (final bad in <String>['I', 'L', 'O', 'U']) {
      expect(ulidMs('01HF7YAT${bad}0$_suffix'), isNull,
          reason: '"$bad" in the timestamp half is not a Crockford digit');
    }
  });

  test('a character outside the alphabet past position 10 is still datable',
      () {
    // The decoder reads the timestamp half and nothing else. Pinned so a
    // later tidy-up that validates the whole id cannot silently start
    // refusing ids the minting side is perfectly entitled to have issued —
    // that would turn dated commands into `unrecognized_cmd`, which is a
    // write-safety regression in the quiet direction.
    expect(ulidMs('01HF7YAT00${'I' * 16}'), 1700000000000);
  });

  test('a lowercase id is not datable', () {
    // Current behaviour, pinned rather than improved. `newUlid` emits
    // uppercase and every decoder in the repo matches against an uppercase
    // alphabet, so lowercase has never been datable. A decoder that starts
    // accepting it starts dating ids the minting side never issued.
    expect(ulidMs('01hf7yat00${_suffix.toLowerCase()}'), isNull);
    expect(ulidMs('01hf7yat00$_suffix'), isNull);
  });

  test('an id minted at the epoch dates to 0, and 0 is not null', () {
    // The callers distinguish "not datable" (`unrecognized_cmd`, nothing can
    // be ruled out) from "dated, and very old" (`outcome_unwitnessed` or
    // `outcome_expired`). Collapsing 0 into null would turn a malformed id
    // into a merely ancient one and hand it the wrong reason string.
    expect(ulidMs(newUlid(nowMs: 0)), 0);
    expect(ulidMs('0000000000$_suffix'), 0);
    expect(ulidMs('0000000000$_suffix'), isNotNull);
  });
}

/// A fixed, legal 16-character random half. The decoder never reads it; it is
/// here so the literal timestamp prefixes above can be padded to 26 without
/// dragging the encoder into an arm that is testing the decoder.
const String _suffix = '0123456789ABCDEF';

/// True when [id] is exactly the base-32 successor of [previous] — what a
/// plain `+1` monotonicity counter produces.
bool _isSuccessorOf(String id, String previous) {
  const crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final digits = [for (final c in previous.split('')) crockford.indexOf(c)];
  for (var i = digits.length - 1; i >= 10; i--) {
    if (digits[i] < 31) {
      digits[i]++;
      break;
    }
    digits[i] = 0;
  }
  return id == [for (final d in digits) crockford[d]].join();
}
