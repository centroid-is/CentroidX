/// The wire's series naming, the mapping contract behind it, and the refusal
/// an over-large answer raises.
///
/// Three declarations, no implementations. What is asserted here is the
/// grammar — `<series>` or `<series>:<member>`, nothing else — and the two
/// properties that make it safe to put a client-supplied string in front of a
/// database: a name that does not parse is refused rather than guessed at
/// (T-10-02, the string reaches a `FROM` clause), and the interface that maps
/// it to a table ships with nothing behind it, so a permissive default cannot
/// become the production one by accident.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

void main() {
  group('SeriesAddress.parse', () {
    test('a bare series name has no member', () {
      final address = SeriesAddress.parse('Line1.Motor1');

      expect(address.series, 'Line1.Motor1',
          reason: 'the series is the whole name when nothing selects a member '
              '— the dots inside it are the plant key\'s own, not a separator '
              'this grammar owns');
      expect(address.member, isNull,
          reason: 'no colon, no member: the caller asked for the series the '
              'table records, not one scalar out of a struct row');
    });

    test('a colon selects one member of the series', () {
      final address = SeriesAddress.parse('Line1.Motor1:speed');

      expect(address.series, 'Line1.Motor1',
          reason: 'everything left of the single colon is the series');
      expect(address.member, 'speed',
          reason: '10-CONTEXT ruling 2: the gateway projects one scalar series '
              'per member, so the member travels alongside the series rather '
              'than as a second argument nobody would pass');
    });

    test('two colons are refused, not split', () {
      expect(() => SeriesAddress.parse('Line1.Motor1:speed:raw'),
          throwsA(isA<FormatException>()),
          reason: 'a member name cannot itself be addressed — projecting a '
              'member of a member is not a thing this wire does, and '
              'best-effort splitting would silently answer a different '
              'question than the one asked. Refusing at the decode boundary '
              'is the convention this package already uses');
    });

    test('an empty series is refused', () {
      expect(() => SeriesAddress.parse(''), throwsA(isA<FormatException>()),
          reason: 'an empty name would reach the resolver as a table nobody '
              'named');
      expect(() => SeriesAddress.parse(':speed'),
          throwsA(isA<FormatException>()),
          reason: 'a member with no series in front of it names nothing');
    });

    test('an empty member is refused', () {
      expect(() => SeriesAddress.parse('Line1.Motor1:'),
          throwsA(isA<FormatException>()),
          reason: 'a trailing colon is a caller that meant to select a member '
              'and did not; answering the whole series instead would ship '
              'members nobody asked for, which is exactly the option '
              '10-CONTEXT ruling 2 rejected');
    });

    test('the refusal names the offending input', () {
      expect(
          () => SeriesAddress.parse('a:b:c'),
          throwsA(isA<FormatException>().having(
              (error) => error.toString(), 'toString', contains('a:b:c'))),
          reason: 'a refusal an operator can act on has to say which name was '
              'refused — the request carries several and the log carries more');
    });
  });

  group('SeriesAddress round trip', () {
    test('a bare series survives toString and parse', () {
      final address = SeriesAddress.parse('Line1.Motor1');

      expect(address.toString(), 'Line1.Motor1',
          reason: 'the bare shape prints as itself, with no trailing colon to '
              'trip the empty-member refusal on the way back');
      expect(SeriesAddress.parse(address.toString()), address,
          reason: 'the wire spelling and the parsed value are the same fact; a '
              'round trip that lost the shape would mean two names for one '
              'series in the resolver\'s cache');
    });

    test('a member survives toString and parse', () {
      final address = SeriesAddress.parse('Line1.Motor1:speed');

      expect(address.toString(), 'Line1.Motor1:speed');
      expect(SeriesAddress.parse(address.toString()), address,
          reason: 'the member half round-trips too, or the chart asking for '
              'one scalar gets the struct');
    });

    test('an Icelandic member name survives the round trip', () {
      final address = SeriesAddress.parse('Lína1.Mótor1:hraði');

      expect(address.series, 'Lína1.Mótor1');
      expect(address.member, 'hraði',
          reason: 'a member name reaches a table column, and this project has '
              'been bitten by encoding once already (the Latin-1 S7 strings). '
              'The grammar splits on a colon and touches nothing else — no '
              'case folding, no normalisation, no ASCII assumption');
      expect(SeriesAddress.parse(address.toString()), address,
          reason: 'þ/ð/æ and the accents survive the round trip byte for byte');
    });

    test('two addresses with the same text are the same value', () {
      expect(SeriesAddress.parse('a:b'), SeriesAddress.parse('a:b'),
          reason: 'value equality, so a resolver can key a map on one');
      expect(SeriesAddress.parse('a:b').hashCode,
          SeriesAddress.parse('a:b').hashCode,
          reason: 'and the hash agrees with it');
      expect(SeriesAddress.parse('a:b'), isNot(SeriesAddress.parse('a')),
          reason: 'anti-vacuity: two different addresses must not compare '
              'equal, or every equality case above is satisfied by a type that '
              'says yes to everything');
    });
  });

  group('SeriesResolver', () {
    test('is an interface with three lookups, all nullable', () {
      // A test double rather than a shipped implementation, for the reason the
      // library doc gives: the only way to get a resolver is to supply one.
      final resolver = _FixtureResolver();

      expect(resolver.resolve('Line1.Motor1:speed')?.table, 'gw_line1_motor1',
          reason: 'resolve answers the physical table for a wire name');
      expect(resolver.resolve('Line1.Motor1:speed')?.member, 'speed',
          reason: 'and carries the member with it, so a caller cannot get the '
              'table without also knowing which column the chart asked for');
      expect(resolver.resolve('Line1.Motor1:speed')?.plantKey, 'Line1.Motor1',
          reason: 'and the plant key, which is what canSee is asked about — '
              'one object, three answers, so the answers cannot travel apart');
    });

    test('null means refuse, on every lookup', () {
      final resolver = _FixtureResolver();

      expect(resolver.resolve('Nowhere.Nothing'), isNull,
          reason: '10-CONTEXT amendment 6 is fail-closed: an unmappable table '
              'is not served. Null is the refusal, and a caller that treated '
              'it as "serve unpoliced" would be the hole this shape exists to '
              'close');
      expect(resolver.keyForTable('gw_nothing'), isNull,
          reason: 'a table with no collect entry names no plant key, so '
              'nothing can be asked about it');
      expect(resolver.keyForNode('ns=2;s=Nothing'), isNull,
          reason: 'and a node id that maps to no key is refused the same way');
    });

    test('the fixture resolves what it was given — anti-vacuity', () {
      final resolver = _FixtureResolver();

      expect(resolver.keyForTable('gw_line1_motor1'), 'Line1.Motor1',
          reason: 'if the fixture answered null to everything, the refusal '
              'cases above would pass while asserting nothing');
      expect(resolver.keyForNode('ns=2;s=Line1.Motor1'), 'Line1.Motor1',
          reason: 'same, for the node lookup');
    });
  });

  group('ResultTooLarge', () {
    test('a row overflow names the limit, the measurement and the way out',
        () {
      final refusal = ResultTooLarge.rows(
        limit: 50000,
        measured: 2678400,
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );

      expect(refusal.limit, 50000);
      expect(refusal.measured, 2678400);
      expect(refusal.unit, ResultSizeUnit.rows,
          reason: 'rows and bytes are two different ceilings and a reader has '
              'to know which one was hit — 2 678 400 bytes is nothing and '
              '2 678 400 rows is a month of one-second samples');
      expect(refusal.suggestion, DataServiceMethods.timeseriesQueryDownsampled,
          reason: 'the refusal names the method that would answer instead, '
              'because "too large" with no way out is a dead end an operator '
              'reports as a broken chart');
      expect(refusal.message, contains('50000'),
          reason: 'the limit is in the sentence, not only in a field a '
              'JSON-RPC error data map may or may not carry');
      expect(refusal.message, contains('2678400'),
          reason: 'and so is what was actually measured');
      expect(refusal.message,
          contains(DataServiceMethods.timeseriesQueryDownsampled),
          reason: 'and so is the method to call instead');
      expect(refusal.message, contains('rows'),
          reason: 'and the unit, or the two numbers are unitless');
    });

    test('a byte overflow says bytes', () {
      final refusal = ResultTooLarge.bytes(
        limit: 8 * 1024 * 1024,
        measured: 41000000,
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );

      expect(refusal.unit, ResultSizeUnit.bytes);
      expect(refusal.message, contains('bytes'),
          reason: 'the byte ceiling is the conflating send buffer\'s, and a '
              'reader tracing a 4004 needs to see which ceiling refused first');
      expect(refusal.message, isNot(contains('rows')),
          reason: 'anti-vacuity: if message ignored the unit entirely, the '
              '"contains bytes" arm would pass on a sentence that said both');
    });

    test('it is an Exception, so a handler catches it rather than dying', () {
      expect(
          ResultTooLarge.rows(
              limit: 1, measured: 2, suggestion: DataServiceMethods.prefGetAll),
          isA<Exception>(),
          reason: 'a refusal must never become a disconnect: the handler '
              'catches this and answers a named JSON-RPC error. An Error '
              'would unwind past it and take the session with it, which is '
              'reporting "your query was too large" as "you disconnected"');
    });

    test('toString carries the message', () {
      final refusal = ResultTooLarge.rows(
          limit: 10, measured: 11, suggestion: DataServiceMethods.prefGetAll);

      expect(refusal.toString(), contains(refusal.message),
          reason: 'the uncaught-in-a-log case still says what happened');
    });

    test('a floor measurement says so, rather than overclaiming a count', () {
      final refusal = ResultTooLarge.rows(
        limit: 40000,
        measured: 40001,
        atLeast: true,
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );

      expect(refusal.message, contains('at least 40001'),
          reason: 'the row ceiling is detected with LIMIT n + 1, so the '
              'refusal knows the answer is over the limit and does NOT know '
              'by how much — the real count may be 6.3 million. A sentence '
              'that says "would answer 40001 rows" tells an engineer to '
              'narrow the window by 0.0025% and hit the same wall. The '
              'doc\'s own claim for `measured` is that "how far over" is '
              'what tells an operator whether to narrow a little or a lot, '
              'and a floor has to admit it is a floor for that to be true');
    });

    test('an exact measurement does not say "at least"', () {
      final refusal = ResultTooLarge.bytes(
        limit: 1048576,
        measured: 2000000,
        suggestion: DataServiceMethods.prefGetAll,
      );

      expect(refusal.message, isNot(contains('at least')),
          reason: 'anti-vacuity for the arm above: the byte ceiling encodes '
              'the whole answer and therefore knows the exact size, so a '
              'message that hedged unconditionally would pass that arm while '
              'throwing away a number it really has');
    });

    test('the detail names what pushed a batch over, inside the sentence', () {
      final refusal = ResultTooLarge.rows(
        limit: 40000,
        measured: 40001,
        atLeast: true,
        detail: 'the series "ST301.CN21.SEN01.temp" crossed the total',
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );

      expect(refusal.message, contains('ST301.CN21.SEN01.temp'),
          reason: 'a four-series chart refused on the SUM has one actionable '
              'fact in it — which series to narrow. Carrying that only in a '
              'field the JSON-RPC error data map may or may not relay is the '
              'same mistake the limit itself would be');
    });

    test('no detail leaves the sentence unchanged', () {
      final plain = ResultTooLarge.rows(
          limit: 10, measured: 11, suggestion: DataServiceMethods.prefGetAll);

      expect(plain.message, isNot(contains('(')),
          reason: 'anti-vacuity: the detail is parenthesised, so a sentence '
              'that always carried the parentheses would pass the arm above '
              'with an empty aside in every refusal that has nothing to add');
    });
  });
}

/// A resolver a test supplies, standing in for the real one 10-07 builds.
///
/// In this file and not in `lib/`, deliberately: see the note on
/// [SeriesResolver].
final class _FixtureResolver implements SeriesResolver {
  static const _tables = {'gw_line1_motor1': 'Line1.Motor1'};
  static const _nodes = {'ns=2;s=Line1.Motor1': 'Line1.Motor1'};

  @override
  ResolvedSeries? resolve(String wireName) {
    final address = SeriesAddress.parse(wireName);
    for (final entry in _tables.entries) {
      if (entry.value == address.series) {
        return ResolvedSeries(
            table: entry.key, member: address.member, plantKey: entry.value);
      }
    }
    return null;
  }

  @override
  String? keyForTable(String table) => _tables[table];

  @override
  String? keyForNode(String nodeId) => _nodes[nodeId];
}
