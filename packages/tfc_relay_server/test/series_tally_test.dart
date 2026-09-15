/// What the unmappable-series tally is allowed to remember (10-REVIEW WR-04).
///
/// The tally is the reconciliation 10-CONTEXT amendment 6 forces: the wire
/// answers an unmappable series exactly as a nonexistent one, and the gateway
/// keeps a count and the names so the gap is diagnosable without being
/// enumerable. Both halves are memory, and **both are grown by whoever is
/// connecting**.
///
/// `_keepNames` bounded the cardinality at 64 and cited T-04-06's shape for it.
/// That was the wrong citation: T-04-06 bounds *bytes*, and sixty-four strings
/// of unspecified length is not a bound on bytes. Nothing else stood in the way
/// — the handler checked the grammar and not the length, a frame may be 1 MiB,
/// and `_names` is never pruned — so one authenticated station could pin tens
/// of megabytes for the life of the process and log a line of the same size per
/// name.
///
/// `DataHandlers` now refuses an over-long name at ingress; this file is the
/// belt behind that belt, for an embedder or a policy layer reaching the tally
/// without passing a handler.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';

void main() {
  test('an over-long name is truncated before it is remembered', () {
    final tally = SeriesMappingTally();
    final long = 'A' * 40_000;

    tally.record(long);

    expect(tally.unmappableNames, hasLength(1));
    final kept = tally.unmappableNames.single;
    expect(kept.length, lessThan(long.length),
        reason: 'the name is chosen by a caller; the memory it costs must not '
            'be');
    expect(kept, startsWith('A' * SeriesMappingTally.maxNameChars));
    expect(kept, contains('40000'),
        reason: 'a truncated entry has to say how long the original was, or '
            'the diagnostic reads as an ordinary key with a long name rather '
            'than as somebody probing the gateway');
  });

  test('what is reported is the truncated name, not the whole one', () {
    final reported = <String>[];
    final tally = SeriesMappingTally(
        report: (Object message, _, __) => reported.add('$message'));

    tally.record('B' * 40_000);

    expect(reported, hasLength(1));
    expect(reported.single.length, lessThan(1000),
        reason: 'this is the half that is not merely memory: the reporter is '
            'the gateway log, and 64 novel names meant 64 lines of up to a '
            'megabyte each. A log nobody can open is a log nobody reads');
  });

  test('an ordinary plant key is kept whole', () {
    // The anti-vacuity arm. A tally that truncated everything would satisfy
    // both cases above and would also make every diagnostic useless — the
    // point of keeping the name is that somebody adds it to the collection
    // plan, and half a key is not a key.
    final tally = SeriesMappingTally();

    tally.record('CN09.MOT01.speed');
    tally.record('CN09.MOT01.speed:current');

    expect(tally.unmappableNames,
        containsAll(<String>['CN09.MOT01.speed', 'CN09.MOT01.speed:current']));
    expect(tally.unmappableQueries, 2,
        reason: 'the count is per query and is exact and unbounded; only the '
            'names are bounded');
  });

  test('a name at exactly the bound is kept whole', () {
    final tally = SeriesMappingTally();
    final atBound = 'C' * SeriesMappingTally.maxNameChars;

    tally.record(atBound);

    expect(tally.unmappableNames.single, atBound,
        reason: 'the boundary in the direction that matters: truncating at '
            'the bound would put an ellipsis on a name that fits');
  });

  test('the cardinality bound still holds, and says so', () {
    final tally = SeriesMappingTally(keepNames: 2);

    tally
      ..record('one')
      ..record('two')
      ..record('three');

    expect(tally.unmappableNames, hasLength(2));
    expect(tally.namesTruncated, isTrue);
    expect(tally.unmappableQueries, 3,
        reason: 'the count keeps rising after the names stop, which is why '
            'namesTruncated is exposed rather than left implicit');
  });
}
