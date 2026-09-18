/// The reference decoder and the shared one must agree on every id.
///
/// `FakeStateMan` keeps its own ULID timestamp decoder rather than importing
/// `ulidMs`, and the reason is a real one: it is the contract suite's
/// reference implementation, and a reference that imports the thing it is a
/// reference for cannot catch a bug in that thing. Phase 18 deleted the other
/// three copies and kept this one deliberately.
///
/// **This file is the price of keeping it.** The identical argument — "the
/// evidence rule has to be the same in all of them, so copy it" — is exactly
/// what let a `dart2js` defect live in three of four copies for as long as it
/// did: `ulid.dart`'s encoder was migrated off bitwise arithmetic and nothing
/// checked that the decoders had moved with it. Independence means deciding
/// the same answer independently. It does not mean being free to decide a
/// different one, and without an arm like this one there is nothing but a
/// comment saying so.
///
/// So the copy stays and it is *checked*, on the same inputs, in both
/// directions, including the values that separate the two arithmetics.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

/// Timestamps chosen to span the field and to straddle the boundary where a
/// 32-bit-coerced implementation starts folding.
///
/// `4294967296` is `2^32` — the first millisecond a bitwise decoder loses
/// under `dart2js`. `281474976710655` is `2^48 - 1`, the top of the field.
/// The rest are ordinary instants the plant will actually mint at.
const List<int> _instants = <int>[
  0,
  1,
  31,
  32,
  1000,
  2147483647,
  2147483648,
  4294967296,
  1500000000000,
  1700000000000,
  1786000000000,
  4102444800000,
  281474976710655,
];

/// Strings that are not ids, each rejected for a different reason.
const List<String> _notIds = <String>[
  '',
  '01HF7YAT000123456789ABCDE', // 25
  '01HF7YAT000123456789ABCDEFG', // 27
  '01HF7YAI000123456789ABCDEF', // I in the timestamp half
  '01HF7YAL000123456789ABCDEF', // L
  '01HF7YAO000123456789ABCDEF', // O
  '01HF7YAU000123456789ABCDEF', // U
  '01hf7yat000123456789abcdef', // lowercase
];

void main() {
  test('the reference decoder dates all twenty ids exactly as ulidMs does', () {
    // Twenty ids: thirteen minted across the whole field, plus a second draw
    // at each of the first seven instants so the differing random halves are
    // covered too — the decoder must ignore them identically in both copies.
    final ids = <String>[
      for (final ms in _instants) newUlid(nowMs: ms),
      for (final ms in _instants.take(7)) newUlid(nowMs: ms),
    ];
    expect(ids, hasLength(20), reason: 'the arm says twenty; keep it twenty');

    for (final id in ids) {
      expect(FakeStateMan.referenceUlidMs(id), ulidMs(id),
          reason: 'the reference implementation and the shared decoder '
              'disagree about $id — one of them is dating writes wrong, and '
              'on this path that is the difference between not_received and '
              'unknown');
    }
  });

  test('both decoders recover the exact millisecond, not merely the same one',
      () {
    // Agreement alone is satisfied by two copies that are wrong together —
    // which is the failure mode the shared-copy argument actually produces.
    // So each is also pinned against the value independently.
    for (final ms in _instants) {
      final id = newUlid(nowMs: ms);
      expect(ulidMs(id), ms, reason: 'ulidMs lost $ms');
      expect(FakeStateMan.referenceUlidMs(id), ms,
          reason: 'the reference decoder lost $ms');
    }
  });

  test('both decoders refuse the same non-ids', () {
    for (final bad in _notIds) {
      expect(ulidMs(bad), isNull, reason: 'ulidMs dated "$bad"');
      expect(FakeStateMan.referenceUlidMs(bad), isNull,
          reason: 'the reference decoder dated "$bad"');
    }
  });

  test('both decoders read past position 10 not at all', () {
    // Pinned in both copies: the random half is never validated, so a mangled
    // suffix still dates. A tidy-up that starts validating the whole id in one
    // copy and not the other would turn dated commands into unrecognized_cmd
    // on one side only.
    final mangled = '01HF7YAT00${'I' * 16}';
    expect(ulidMs(mangled), 1700000000000);
    expect(FakeStateMan.referenceUlidMs(mangled), 1700000000000);
  });
}
