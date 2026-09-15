/// The server-global key→handle table: the one property encode-once is built
/// on.
///
/// 03-RESEARCH Finding 2 measured the alternative: `Peer.sendNotification`
/// JSON-encodes once per peer, 7 639 µs/tick against 110 µs at 100 clients ×
/// 200 keys — 69.6× the cost, with no error, invisible until production.
/// Finding 3 is what makes the 110 µs version possible: the `c`/`q`/`r` body
/// is byte-identical for every client, so it is encoded once per tick and each
/// client's envelope is concatenated around it. That only holds if two clients
/// subscribing to the same key are handed the *same integer*.
///
/// Mint handles per subscription instead and every client needs its own remap
/// of every key in the body — which is the 69.6× strategy with extra steps,
/// arrived at by accident. So the assertion below ("same key yields the same
/// handle across sessions") is not a convenience property; it is the whole
/// performance decision, stated as a test that bites.
///
/// Handle lifetime is PERMANENT this phase (03-CONTEXT amendment: bounded key
/// space). The table has no release method, and the size assertions here are
/// the first half of that guarantee; 03-11's teardown test asserts the second
/// half against session churn.
library;

import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:test/test.dart';

void main() {
  test('the same key yields the same handle across sessions', () {
    final table = HandleTable();

    // Two sessions, subscribing independently, one shared key.
    final sessionA = table.handlesFor(['AREA01.CN01.MOT01', 'AREA01.CN02.MOT01']);
    final sessionB = table.handlesFor(['AREA01.CN02.MOT01', 'AREA01.CN03.MOT01']);

    expect(sessionB['AREA01.CN02.MOT01'], sessionA['AREA01.CN02.MOT01'],
        reason: 'if two panels watching one motor get different integers for '
            'it, the update body stops being byte-identical and the server '
            'silently pays a per-client encode — measured at 69.6x');

    expect(table.handleFor('AREA01.CN02.MOT01'), sessionA['AREA01.CN02.MOT01'],
        reason: 'a third asker, on any path into the table, must land on the '
            'same integer as the first two');
  });

  test('asking twice returns the same handle and mints nothing', () {
    final table = HandleTable();

    final first = table.handleFor('ST101.TANK01.LEVEL');
    final second = table.handleFor('ST101.TANK01.LEVEL');

    expect(second, first);
    expect(table.size, 1,
        reason: 'a repeat subscribe must not grow a table that never shrinks');
  });

  test('handles are dense and start at 1', () {
    final table = HandleTable();

    final handles = table.handlesFor(['a', 'b', 'c']).values.toList();

    expect(handles, [1, 2, 3],
        reason: 'dense small integers are what keep the wire body short; '
            '0 is reserved so a missing handle cannot read as a valid one');
  });

  test('keyOf inverts handleFor', () {
    final table = HandleTable();

    for (final key in ['a', 'b', 'c']) {
      expect(table.keyOf(table.handleFor(key)), key,
          reason: 'the server resolves a write or a removal back to its key '
              'through this map; a wrong inverse writes to the wrong tag');
    }
  });

  test('an unminted handle resolves to null, not to some other key', () {
    final table = HandleTable();
    table.handleFor('a');

    expect(table.keyOf(999), isNull);
    expect(table.keyOf(0), isNull,
        reason: 'handles start at 1 precisely so that a zero-valued field '
            'decoded from a bad frame resolves to nothing');
  });

  test('the table only grows: no release, no reuse', () {
    final table = HandleTable();

    final first = table.handleFor('a');
    table.handleFor('b');
    expect(table.size, 2);

    // Simulate a session's whole lifetime ending and another starting. The
    // table is server-global, so nothing here may shrink it.
    final laterSession = table.handlesFor(['a', 'c']);
    expect(laterSession['a'], first,
        reason: 'a handle handed out before a disconnect is still that key\'s '
            'handle afterwards — reuse would point a reconnecting panel at '
            'somebody else\'s tag');
    expect(table.size, 3,
        reason: 'permanent lifetime this phase (bounded key space); the table '
            'grows with distinct keys seen and never with sessions');

    expect(table.keys, containsAll(['a', 'b', 'c']));
  });

  test('handlesFor preserves order and agrees with handleFor', () {
    final table = HandleTable();

    final batch = table.handlesFor(['x', 'y', 'x']);

    expect(batch.keys, ['x', 'y'],
        reason: 'a duplicate key in one subscribe is one entry, not two');
    expect(batch['x'], table.handleFor('x'));
    expect(table.size, 2);
  });
}
