/// What the gateway was asked for that it has no mapping for.
///
/// ## Why a count exists at all
///
/// A timeseries method is keyed by a **series name**, and a series name has to
/// become a physical table and a plant key before anything can be read or
/// policed. When [SeriesResolver] cannot make that translation, two rules
/// collide:
///
///  * **The wire answer must be indistinguishable from a series that does not
///    exist.** A refusal that named the series would let a station enumerate
///    the historian one name at a time — the same existence oracle the hiding
///    rule exists to close (T-10-12). So the answer is an empty series, and it
///    is identical to the answer a hidden series gets.
///  * **But an unmappable series must be *visible*, not merely refused**
///    (10-CONTEXT amendment 6). Fail-closed without a way to see what was
///    closed is a chart that renders as a flat line for months while nobody
///    knows a table was never mapped.
///
/// The reconciliation is this object. The *wire* says nothing; the **gateway
/// side** records it. Both halves are load-bearing and a future reader is
/// likely to want to "fix" one of them: making the refusal informative breaks
/// the hiding rule, and dropping the count makes fail-closed silent. Neither
/// is an improvement.
///
/// ## The honest limit
///
/// The gateway maps what the *gateway* collects. A chart pointed at a
/// pre-cutover table — one the application's own collector wrote, under a name
/// with no `gw_` prefix and no entry in the collection plan — resolves to
/// nothing and is therefore answered as a series that does not exist, until
/// either the migration runs or the configuration declares a read-side alias
/// for it. That is the correct default and it will look exactly like a
/// database problem the first time it happens (research §C.2, Trap 7). This
/// count is what turns that afternoon into one query.
library;

import '../error_reporter.dart';

/// A running count of series names no [SeriesResolver] could map, and the
/// first few names, for whoever is holding the keymappings.
///
/// One per gateway, not per session: a panel that reconnects every few minutes
/// would otherwise reset the very number that is supposed to accumulate.
/// `RelayServer` owns one and hands it to every session it accepts.
final class SeriesMappingTally {
  SeriesMappingTally({RelayErrorHandler? report, int keepNames = 64})
      : _report = report,
        _keepNames = keepNames;

  /// Where a newly-seen unmappable name is announced, **once**.
  ///
  /// Reported through the package's one error seam rather than through a
  /// logging framework it does not have, with [StackTrace.empty] — which
  /// `error_reporter.dart` defines as "this is a condition rather than a
  /// defect: something a peer can produce at will, already summarized in the
  /// message". A trace here would be unbounded log volume chosen by whoever is
  /// connecting, and so would a line per *query* rather than per distinct
  /// name: a dashboard polling one broken chart every five seconds is one
  /// mapping gap, not seventeen thousand of them.
  final RelayErrorHandler? _report;

  /// How many distinct names are kept. The count is exact and unbounded; the
  /// *names* are bounded, because they are memory an authenticated client can
  /// grow one novel string at a time (T-04-06's shape, applied here).
  final int _keepNames;

  /// The longest fragment of a name kept **or logged**.
  ///
  /// **[_keepNames] bounds cardinality; this bounds size, and T-04-06's shape
  /// is the second one** (10-REVIEW WR-04). Citing T-04-06 for a count was the
  /// mistake: that threat bounds *bytes*, and sixty-four strings of
  /// unspecified length is not a bound on bytes. Nothing else stood in the way
  /// — `DataHandlers._series` checked only the grammar, `maxKeysPerSubscribe`
  /// is 2000, and a frame may be 1 MiB — so one authenticated station sending
  /// sixty-four novel long names pinned tens of megabytes here **for the life
  /// of the process** ([_names] is never pruned), and fired [_report] with the
  /// whole string interpolated into the message each time: sixty-four log
  /// lines of up to a megabyte.
  ///
  /// 200 characters is generous against the plant's own convention
  /// (`AREAnn.DEVnn.SUBnn` plus at most one member), and `DataHandlers`
  /// refuses a longer name at ingress anyway. This is the belt behind that
  /// belt, for a caller reaching the tally without passing a handler.
  static const int maxNameChars = 200;

  final _names = <String>{};

  var _queries = 0;

  /// How many queries have named a series this gateway cannot map.
  ///
  /// Every query, not every distinct name — the two answer different
  /// questions, and this is the one that says whether anything is still
  /// asking.
  int get unmappableQueries => _queries;

  /// The distinct unmappable names seen, up to the cap.
  ///
  /// This is the field somebody acts on: each entry is a series a chart is
  /// asking for that the collection plan does not produce.
  Set<String> get unmappableNames => Set.unmodifiable(_names);

  /// Whether [unmappableNames] stopped recording new names.
  ///
  /// Exposed rather than left implicit so a reader is never misled into
  /// treating a capped list as the whole story — the count keeps rising after
  /// the names stop.
  bool get namesTruncated => _names.length >= _keepNames;

  /// Records one query that named a series with no mapping.
  ///
  /// The name is truncated to [maxNameChars] **before** it is remembered or
  /// logged: the name is chosen by a caller and the memory it costs must not
  /// be. A truncated entry says how long the original was, so the sentence
  /// stays actionable — "the collection plan does not name this" reads
  /// differently when the thing is 40 000 characters long.
  void record(String wireName) {
    _queries++;
    final short = wireName.length <= maxNameChars
        ? wireName
        : '${wireName.substring(0, maxNameChars)}…'
            '(${wireName.length} chars)';
    if (_names.length >= _keepNames || !_names.add(short)) return;
    _report?.call(
        'a chart asked for the series "$short", which this gateway has no '
        'mapping for; it is answered as a series that does not exist. Either '
        'the collection plan does not name it, or it is a pre-cutover table '
        'the application collector wrote and no read-side alias has been '
        'declared for it',
        StackTrace.empty,
        'series mapping');
  }

  @override
  String toString() => 'SeriesMappingTally($_queries queries, '
      '${_names.length} distinct${namesTruncated ? '+' : ''}: '
      '${_names.join(', ')})';
}
