/// The four `TimeseriesApi` methods over `tfc_dart`'s `Database` — **the
/// second and last file in this package that knows `Database` exists**, and
/// the mirror of 8b-02's `TimescaleSink`.
///
/// `freeze_test.dart` pins the count of database-importing files at two and
/// names both. The point of the seam is the same in this direction as in the
/// write direction: everything else in the package stays testable with no
/// database, and `Database`'s constructor-started flush timer and its
/// retry-forever connect ladder cannot leak onto the gateway's value path.
///
/// ## PHASE 10 READS AND NEVER WRITES
///
/// There is no insert path here and no retention path, and a sweep in
/// `freeze_test.dart` asserts it over this whole directory.
/// `Database.registerRetentionPolicy` does not merely register: it *uninstalls
/// and reinstalls* a differing policy (`database.dart:847-864`), which is the
/// fight 8b spent a whole verdict avoiding while the application's collector
/// still runs against the same server. A read path that touched it would
/// restart that fight from the side nobody was watching.
///
/// ## One `Database`, borrowed rather than built
///
/// The constructor takes a **supplier**, not an instance. Two reasons, and the
/// first is the one the threat register cares about:
///
///  * *A second pool doubles connections against a plant Postgres* (T-10-28)
///    and gives 8b's `SELECT application_name, count(*) FROM pg_stat_activity
///    GROUP BY 1` a second name to explain. The composition root hands over
///    the instance `TimescaleSink` already owns.
///  * *The sink connects in the background and the gateway does not wait for
///    it* (8b's WR-03). So the instance does not exist yet when this object is
///    constructed, and it is replaced on reconnect. A supplier is what lets
///    the reader borrow whatever the composition currently holds; a pinned
///    instance would be stale after the first reconnect. `null` means the
///    historian is not up, which is [HistorianUnavailable] — retryable, not a
///    refusal, and never a hang.
///
/// `DatabaseConfig.queryTimeout` (declared at `database.dart:107`, defaulting
/// at `:129`, threaded to the pool by drift at `database_drift.dart:503` and
/// `:552`) is the first of the three result-size bounds and the only free one:
/// it makes a badly-planned query die in the database rather than in a send
/// buffer. It is set where the `DatabaseConfig` is built —
/// `CollectionConfig.queryTimeout`, `timescale_sink.dart`'s `_databaseConfig`
/// — which is also the only place it can be set, since this object never
/// builds one.
///
/// ## The member projection
///
/// 10-CONTEXT ruling 2: a struct series is served **one scalar member at a
/// time**, addressed `<series>:<member>`, and the wire's sample type stays
/// `num`. That is a `SELECT` of one column plus `time` — not a fetch of the
/// whole row followed by a filter. The two are indistinguishable in the
/// output, which is exactly why the test asserts the executed query's *column
/// list*: fetching every member to serve one would ship the byte problem
/// ruling 2 exists to solve while claiming to have solved it.
///
/// An **unaddressed** struct is a refusal ([StructSeriesUnaddressed]), not a
/// `Map`. `client_sub_apis.dart:257` decodes every point as
/// `TimeseriesData<num>`; a `Map` there is a `CastError` at the panel, which
/// an operator reads as "the chart is broken" rather than as "you did not say
/// which member" (T-10-30).
///
/// ## What the refusals surface as — CLOSED in 10-10
///
/// Until 10-10 every exception in this file reached the wire as `handlerFailed`
/// (-32011) through `relay_session.dart`'s catch-all: right for
/// [HistorianUnavailable] and for a database error, **wrong for the other
/// seven**, because -32011 is documented as possibly transient and a panel may
/// therefore retry forever a request that can never succeed. 10-07, 10-08 and
/// 10-09 each recorded it as a follow-up with no owner.
///
/// It could not be closed from either end, and the reason was structural: the
/// family is declared here, the wire code is chosen in
/// `tfc_relay_server/data_handlers.dart`, and the dependency edge runs local →
/// server and never the other way — so the handler could not name the type. It
/// is closed by `SourceRefusal` in the package both ends share:
/// [TimeseriesReadRefusal] implements it, decides `retryable` with an
/// **exhaustive switch** over its own sealed family, and `_sized` answers
/// `INVALID_PARAMS` for a permanent one while rethrowing a retryable one to the
/// catch-all that was always right for it.
///
/// In the composed gateway `_PolicyTimeseries` answers an unmappable series as
/// one that does not exist *before* the reader sees it, so [UnknownSeries] is
/// reachable only when the policy's resolver and the reader's disagree — a
/// mis-composition, which is worth an error rather than an empty chart.
library;

import 'package:drift/drift.dart' show Variable;
// Prefixed, because `tfc_dart` and the protocol package each define a
// `TimeseriesData` and this file's whole job is translating one into the
// other. The seam sweep matches the URI, not the prefix.
import 'package:tfc_dart/core/database.dart' as ts;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show
        DataServiceMethods,
        ResolvedSeries,
        ResultTooLarge,
        SeriesResolver,
        SourceRefusal,
        TimeseriesApi,
        TimeseriesData;

import 'read_limits.dart';

/// Whatever `Database` the composition currently holds, or null while the
/// historian is not up.
typedef DatabaseSupplier = ts.Database? Function();

/// Why a read was refused. Sealed so the disposition below is a switch the
/// compiler checks rather than a string match.
sealed class TimeseriesReadRefusal implements SourceRefusal {
  const TimeseriesReadRefusal(this.message);

  @override
  final String message;

  /// Whether retrying the identical request could ever succeed.
  ///
  /// **An exhaustive switch, and that is the whole value of the family being
  /// sealed.** Written as `this is HistorianUnavailable` until 10-10, which
  /// was correct and silently fragile: a subclass added later inherited
  /// "permanent" by default, and the dangerous direction is a new *retryable*
  /// refusal doing so — a panel would then be told its perfectly good query
  /// was malformed every time whatever went away came back. Written as a
  /// switch, adding a subclass is a compile error here.
  ///
  /// `data_handlers.dart`'s `_sized` reads this bit and answers
  /// `INVALID_PARAMS` for false, leaving true to the catch-all's
  /// `handlerFailed` (-32011), which the wire documents as possibly transient
  /// and which is right for exactly one of these.
  @override
  bool get retryable => switch (this) {
        HistorianUnavailable() => true,
        UnknownSeries() => false,
        StructSeriesUnaddressed() => false,
        UnknownSeriesMember() => false,
        SeriesNotNumeric() => false,
        UnsupportedOrdering() => false,
        SeriesTableMissing() => false,
        DownsampleUnbounded() => false,
      };

  @override
  String toString() => message;
}

/// The series is not in the collection plan.
final class UnknownSeries extends TimeseriesReadRefusal {
  UnknownSeries(this.wireName)
      : super('no series named "$wireName" is collected by this gateway, so '
            'there is no table to read. If this is a chart that worked '
            'before the cutover, its samples are in the application '
            'collector\'s own unprefixed table and are reached by running '
            'the one-shot migration or by declaring a read-side alias');

  final String wireName;
}

/// The table is a struct and the caller named no member.
final class StructSeriesUnaddressed extends TimeseriesReadRefusal {
  StructSeriesUnaddressed(this.wireName, this.members)
      : super('"$wireName" is recorded as a structure with one column per '
            'member, so it has no single scalar series. Ask for one member: '
            '${members.map((m) => '$wireName:$m').join(', ')}');

  final String wireName;
  final List<String> members;
}

/// The caller named a member the table does not have.
final class UnknownSeriesMember extends TimeseriesReadRefusal {
  UnknownSeriesMember(this.wireName, this.member, this.members)
      : super('"$wireName" has no member "$member". It has: '
            '${members.join(', ')}');

  final String wireName;
  final String member;
  final List<String> members;
}

/// The column holds something a chart cannot plot.
final class SeriesNotNumeric extends TimeseriesReadRefusal {
  SeriesNotNumeric(this.wireName, this.dataType)
      : super('"$wireName" is stored as $dataType, and the pipe carries '
            'samples as numbers. Sending it would be a CastError at whatever '
            'is drawing the chart');

  final String wireName;
  final String dataType;
}

/// An `orderBy` outside the two values the API's own contract uses.
final class UnsupportedOrdering extends TimeseriesReadRefusal {
  UnsupportedOrdering(this.orderBy)
      : super('orderBy must be "time ASC" or "time DESC"; "$orderBy" is '
            'neither. The fragment is concatenated into an ORDER BY clause '
            'unchanged (database_drift.dart:909), so it is refused rather '
            'than sanitized — a sanitizer invites the question of whether it '
            'is complete');

  final String orderBy;
}

/// The historian is not connected right now.
final class HistorianUnavailable extends TimeseriesReadRefusal {
  HistorianUnavailable()
      : super('the historian is not connected; this is worth retrying');
}

/// The resolver named a table the catalogue does not have.
final class SeriesTableMissing extends TimeseriesReadRefusal {
  SeriesTableMissing(this.wireName, this.table)
      : super('"$wireName" resolves to table "$table", and the catalogue has '
            'no columns for it — the table is not there. Either the '
            'collection plan names a table nothing ever created, or '
            'retention dropped it');

  final String wireName;
  final String table;
}

/// Which of `queryTimeseriesDataDownsampled`'s four silent fallbacks fired.
enum DownsampleFallback {
  /// `database.dart:1471` — `rangeMs <= 0`.
  zeroWidthWindow,

  /// `database.dart:1477` — `(maxPoints / 3).floor()` is zero.
  tooFewPoints,

  /// `database.dart:1487` — the `value` column's type could not be read.
  undetectableColumn,

  /// `database.dart:1512` — the column's type is not one it aggregates.
  notAggregatable,
}

/// The bounded method would have answered with the unbounded raw query.
///
/// Four conditions, and each of them is a `return queryTimeseriesData(...)`
/// inside `queryTimeseriesDataDownsampled` — the raw window over the whole
/// table, with the bounded method's name on it and nothing in the log. Refused
/// here rather than caught by the row cap, because a backstop that fires tells
/// nobody *which* condition sent them there.
final class DownsampleUnbounded extends TimeseriesReadRefusal {
  DownsampleUnbounded._(this.wireName, this.condition, String message)
      : super(message);

  /// `database.dart:1471` — the window has no width.
  factory DownsampleUnbounded._zeroWidth(String wireName, DateTime at) =>
      DownsampleUnbounded._(
          wireName,
          DownsampleFallback.zeroWidthWindow,
          'the window for "$wireName" starts and ends at the same instant '
          '(${at.toUtc().toIso8601String()}), so there is nothing to bucket. '
          'Downsampling it would return the raw query over the whole table '
          'instead (database.dart:1471). Ask for a window with width, or '
          'call queryTimeseriesData if the raw rows are what is wanted');

  /// `database.dart:1477` — `(maxPoints / 3).floor()` is zero buckets.
  factory DownsampleUnbounded._tooFewPoints(String wireName, int maxPoints) =>
      DownsampleUnbounded._(
          wireName,
          DownsampleFallback.tooFewPoints,
          'maxPoints was $maxPoints and a bucket produces three points, so '
          '($maxPoints / 3).floor() is zero buckets and the downsampler '
          'returns the unbounded raw query (database.dart:1477). The floor is '
          '3 — the wire refuses this too (ServerConfig.minTimeseriesPoints), '
          'and this is the belt for a caller that did not come through a '
          'handler');

  /// `database.dart:1512` — the column's type is not one it aggregates.
  factory DownsampleUnbounded._notAggregatable(
          String wireName, String column, String dataType) =>
      DownsampleUnbounded._(
          wireName,
          DownsampleFallback.notAggregatable,
          '"$wireName" stores its samples in a $dataType column ("$column"), '
          'which the downsampler does not aggregate — it would answer the '
          'unbounded raw query over the whole table instead '
          '(database.dart:1512). A boolean in particular has no meaningful '
          'min/max/last per bucket; read it raw with queryTimeseriesData, '
          'where it is served as 1 and 0');

  final String wireName;

  /// Which condition fired, by name.
  final DownsampleFallback condition;
}

/// `TimeseriesApi` over a shared `Database`, with every table name resolved
/// before any statement is built.
final class TimescaleReader implements TimeseriesApi {
  TimescaleReader(
      {required this.database, required this.resolver, ReadLimits? limits})
      : limits = limits ?? ReadLimits();

  /// The shared instance, borrowed per call. See the library doc.
  final DatabaseSupplier database;

  /// The outbound ceilings. See `read_limits.dart` for the arithmetic.
  final ReadLimits limits;

  /// The only thing between a client-supplied string and a `FROM` clause.
  final SeriesResolver resolver;

  /// The two orderings the frozen signature's own default is drawn from
  /// (`state_man_api.dart:269`). The handler allow-lists these too (10-03);
  /// this is the last belt, for a caller that reaches the reader without
  /// passing through one — a contract leg, or an embedder.
  static const Set<String> _orderings = {'time ASC', 'time DESC'};

  /// Postgres types a chart can plot. Everything else is refused rather than
  /// nulled out sample by sample, which would be a chart of nothing with no
  /// explanation anywhere.
  static const Set<String> _numericTypes = {
    'smallint',
    'integer',
    'bigint',
    'real',
    'double precision',
    'numeric',
    'boolean',
  };

  /// Types the **downsampler** can aggregate — `scalarNumericTypes` at
  /// `database.dart:1496-1503`, spelled here so the reader can refuse before
  /// delegating rather than discovering the fallback afterwards.
  ///
  /// **The only difference from [_numericTypes] is `boolean`**, and that is
  /// the whole of fallback 4. This reader charts a boolean as 1/0 for the raw
  /// methods, which is right; the shipped downsampler does not list it, so a
  /// boolean series asked for downsampled comes back as the unbounded raw
  /// query over the whole table. Which is a lot of tables: a run/stop flag is
  /// among the most-collected shapes there is.
  ///
  /// Arrays (`_float8` and friends, which the shipped method does handle) are
  /// absent because they never get this far: `ARRAY` is not in [_numericTypes]
  /// and `_shapeFor` refuses it as [SeriesNotNumeric] first.
  static const Set<String> _aggregatable = {
    'smallint',
    'integer',
    'bigint',
    'real',
    'double precision',
    'numeric',
  };

  @override
  Future<List<TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    _checkOrdering(orderBy);
    final db = _database();
    final series = _resolve(tableName);
    final shape = await _shapeOf(db, tableName, series);
    return _read(db, tableName, series, shape, to,
        orderBy: orderBy, from: from, budget: limits.maxTimeseriesRows);
  }

  @override
  Future<Map<String, List<TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    _checkOrdering(orderBy);
    final db = _database();

    // **Resolved first, all of them, before a single statement.** One bad
    // name refuses the batch: querying the good names and then refusing
    // would have run the statements this belt exists to prevent, and the
    // refusal would be claiming "no effect" untruthfully.
    final series = <String, ResolvedSeries>{
      for (final name in tableNames) name: _resolve(name),
    };

    // **One query per series rather than `Database.queryTimeseriesDataMultiple`'s
    // full outer join.** Not a preference — that method is unusable here.
    // It hardcodes the column list to `['value', 'time']`
    // (`database.dart:1310`), so it cannot serve a member of a struct table
    // at all, and it `coalesce`s the joined tables' timestamps into one
    // column (`database_drift.dart:937`), so a sample's own instant is lost
    // whenever two series were not sampled on the same clock — which is
    // every pair of entries with different `sample_interval_us`. N bounded
    // queries against a database on the same host is the honest trade; the
    // breadth is bounded at the handler by `maxKeysPerSubscribe` (10-03).
    //
    // **The row cap applies to the SUM, and the budget is spent down as the
    // loop goes.** A per-table cap would let four tables each at the cap
    // produce four times the budget in one frame — the exact failure the
    // budget exists to prevent, arrived at by obeying the limit four times.
    // A four-series chart is the ordinary shape here, not the exotic one.
    final answer = <String, List<TimeseriesData>>{};
    var spent = 0;
    for (final entry in series.entries) {
      final shape = await _shapeOf(db, entry.key, entry.value);
      final rows = await _read(db, entry.key, entry.value, shape, to,
          orderBy: orderBy,
          from: from,
          budget: limits.maxTimeseriesRows - spent,
          spent: spent,
          // The series that crosses the total is the one actionable fact in
          // the refusal: it is the one to narrow.
          crossedBy: entry.key);
      answer[entry.key] = rows;
      spent += rows.length;
    }
    // Built from the REQUEST, so one entry per requested series — including
    // the silent ones — is this gateway's property rather than something it
    // inherits from its source.
    return <String, List<TimeseriesData>>{
      for (final name in tableNames) name: answer[name] ?? const [],
    };
  }

  @override
  Future<List<TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    final db = _database();
    final series = _resolve(tableName);
    final shape = await _shapeOf(db, tableName, series);

    // **The four fallbacks, refused by name before anything is built.**
    //
    // `queryTimeseriesDataDownsampled` is the one method in this family that
    // exists to be bounded, and it loses its bound in four places — each one a
    // `return queryTimeseriesData(...)`, which is the unbounded raw window over
    // the whole table, wearing the bounded method's name. Silently: there is no
    // log line and the return type is the same.
    //
    // A backstop would not do. The row cap below IS a backstop and it is the
    // wrong place for this, because 40 000 rows of a table that should have
    // been bucketed is still 40 000 rows and a chart with 1920 columns; and
    // because a backstop that fires tells you nothing about which condition
    // sent you there. Refusing each one by name means a firing backstop is a
    // *missed condition*, which is worth knowing.
    final startTime = from.isBefore(to) ? from.toUtc() : to.toUtc();
    final endTime = from.isBefore(to) ? to.toUtc() : from.toUtc();
    final rangeMs = endTime.difference(startTime).inMilliseconds;
    if (rangeMs <= 0) throw DownsampleUnbounded._zeroWidth(tableName, to);
    final numBuckets = (maxPoints / 3).floor();
    if (numBuckets <= 0) {
      throw DownsampleUnbounded._tooFewPoints(tableName, maxPoints);
    }
    // The third condition — `_valueColumnType` answering null
    // (`database.dart:1487`) — is `_shapeOf`'s already: the probe answers null
    // exactly when the catalogue has no `value` column for the table, and
    // after `_shapeOf` the only way that happens is a table that is not there,
    // which is [SeriesTableMissing]. Named there rather than duplicated here,
    // because a second probe would be a second round trip answering a question
    // already answered.
    if (!_aggregatable.contains(shape.dataType)) {
      throw DownsampleUnbounded._notAggregatable(
          tableName, shape.column, shape.dataType);
    }

    // **One statement for both shapes, and it is not the shipped one.**
    //
    // Until 10-11 a scalar table was handed to `Database.
    // queryTimeseriesDataDownsampled` and only a member projection was spelled
    // here, because that method looks for a column literally named `value` and
    // silently answers the UNBOUNDED raw query when it finds none — which is
    // every struct table there is, ninety of the live plant's 140 collected
    // keys. Turning `supportsDataServices` on put the delegating branch in
    // front of `checkDownsampledRespectsMaxPoints` for the first time and it
    // broke three promises at once, on any window a bucket boundary does not
    // happen to land on:
    //
    //  1. **The bound.** `time_bucket` aligns to its own default origin, so a
    //     window divided into `numBuckets` straddles `numBuckets + 1` of them
    //     and the answer is 3 × (n + 1) points. Measured: 51 where 50 was
    //     asked for. Three points is not a denial of service; a bound the one
    //     bounded method in the family does not keep is still not a bound.
    //  2. **The left edge.** The first row is emitted at a bucket START, which
    //     with an epoch-aligned origin is *before* the window. Measured at
    //     24 ms early — and `queryTimeseriesData` two methods up refuses to
    //     return anything outside its window at all.
    //  3. **The right edge.** The last row is emitted at `bucket + interval`,
    //     past the window by up to one bucket. Measured at 31.172 s late; at
    //     the interface's default of 1000 maxPoints over a month a bucket is
    //     forty-three minutes, and the newest point is the one an operator
    //     reads as the current value.
    //
    // Two changes close all three, and neither invents data. `origin` anchors
    // the buckets to the window the caller asked for, so there are exactly
    // `numBuckets` of them and the first starts at `from`; `LEAST` clamps the
    // two synthetic instants to `to`. Synthetic is the operative word — the
    // midpoint and the bucket end are stamps this query mints, not any
    // sample's own time, so clamping one back inside the window it was
    // computed for is a correction rather than a falsification.
    //
    // The scalar branch loses nothing by joining: the shipped method's four
    // fallbacks are each already refused by name above, its `_valueColumnType`
    // probe is a second round trip answering what `_shapeOf` answered, and its
    // array handling is unreachable because `ARRAY` is not in [_numericTypes]
    // and `_shapeFor` refuses it first. `shape.column` is `value` for a scalar
    // table and the member for a projection, which is the only difference the
    // two ever had.
    // **The width, and the one millisecond that keeps the bound** (10-REVIEW
    // WR-01b). `ceil` alone leaves a hole when the range divides evenly:
    // `numBuckets * bucketMs == rangeMs` exactly, so the window's own right
    // edge is a bucket START, and a sample sitting on `to` — which the filter
    // below includes — opens bucket index `numBuckets`, the
    // `numBuckets + 1`-th. That is 3 × (n + 1) points for a bound of 3 × n:
    // the same shape 10-11 measured as "51 where 50 was asked for", surviving
    // in a narrower window that no leg exercised because no seeded sample
    // landed exactly on `to`.
    //
    // One extra millisecond makes `numBuckets` buckets strictly cover the
    // range, so `to` always falls inside the last of them. It costs the last
    // bucket at most `numBuckets` ms of extra width and cannot cost a point.
    var bucketMs = (rangeMs / numBuckets).ceil();
    if (bucketMs * numBuckets == rangeMs) bucketMs += 1;
    final column = _quoted(shape.column);
    final table = _quoted(series.table);
    // **Three distinct instants per bucket** (10-REVIEW WR-01a). The previous
    // spelling emitted `LEAST(bucket + interval * 0.5, $3)` and
    // `LEAST(bucket + interval, $3)`, and on the final bucket — which almost
    // always starts before `to` and ends after it — both evaluate to `to`.
    // The query therefore emitted `max_val` and `last_val` at the **identical
    // instant** with different values, and `ORDER BY 1` cannot separate them:
    // a chart draws a vertical spike at its right edge, or silently keeps
    // whichever its own de-duplication happens to keep. The newest point is
    // 10-11's own "the one an operator reads as the current value".
    //
    // `bend` is the bucket's last representable instant, clamped into the
    // window: `bucket + interval - 1µs` is strictly inside the bucket, so it
    // also cannot collide with the NEXT bucket's start — which the old
    // `bucket + interval` did, systematically, for every bucket rather than
    // only the last. The midpoint is then placed inside `[bucket, bend]`
    // rather than computed from the nominal width, so it is inside the window
    // by construction and the clamp it used to need is gone.
    //
    // The two `WHERE`s are the degenerate case, made explicit: a bucket whose
    // whole extent is one instant (its start is exactly `to`) has one instant
    // to report, and emitting three rows stamped identically would be the
    // defect above in miniature. Such a bucket contributes one point, so the
    // 3 × numBuckets ceiling still holds.
    final sql = '''
        WITH agg AS (
          SELECT
            time_bucket(\$1::interval, time, \$2::timestamptz) AS bucket,
            min($column)          AS min_val,
            max($column)          AS max_val,
            last($column, time)   AS last_val
          FROM $table
          WHERE time >= \$2::timestamptz AND time <= \$3::timestamptz
          GROUP BY bucket
        ), edges AS (
          SELECT bucket,
                 LEAST(bucket + \$1::interval - interval '1 microsecond',
                       \$3::timestamptz) AS bend,
                 min_val, max_val, last_val
          FROM agg
        )
        SELECT bucket AS time, min_val AS value FROM edges
        UNION ALL
        SELECT bucket + (bend - bucket) / 2, max_val AS value FROM edges
          WHERE bend >= bucket + interval '2 microseconds'
        UNION ALL
        SELECT bend, last_val AS value FROM edges WHERE bend > bucket
        ORDER BY 1
      ''';
    final rows = await db.db.customSelect(sql, variables: [
      Variable.withString('$bucketMs milliseconds'),
      Variable.withString(startTime.toIso8601String()),
      Variable.withString(endTime.toIso8601String()),
    ]).get();
    return [
      for (final row in rows)
        _sample(tableName, shape, row.data['value'], row.data['time']),
    ];
  }

  // ---------------------------------------------------------------- internals

  ts.Database _database() {
    final db = database();
    if (db == null) throw HistorianUnavailable();
    return db;
  }

  /// The wire name, resolved — or a refusal. Never a guess.
  ///
  /// A malformed name throws a `FormatException` out of `SeriesAddress.parse`
  /// rather than resolving to null: "you spelled it wrong" and "there is no
  /// such series" are different facts and the caller acts on each differently.
  ResolvedSeries _resolve(String wireName) {
    final series = resolver.resolve(wireName);
    if (series == null) throw UnknownSeries(wireName);
    return series;
  }

  void _checkOrdering(String? orderBy) {
    if (orderBy == null) return; // an explicit "no ordering", not a default
    if (!_orderings.contains(orderBy)) throw UnsupportedOrdering(orderBy);
  }

  /// What one physical table looks like, and whether the address fits it.
  ///
  /// Every refusal a request can earn is decided here, **before any statement
  /// is built**, which is what makes the refusal honestly mean "no effect".
  Future<_Shape> _shapeOf(
      ts.Database db, String wireName, ResolvedSeries series) async {
    final columns = await _columnsOf(db, series.table);
    // **An empty catalogue answer is a table that is not there**, and it is
    // named as such. Before 10-10 it fell through to the struct branch below
    // and came back as `StructSeriesUnaddressed` with an EMPTY member list —
    // "Ask for one member: " and then nothing, which sends the reader looking
    // for a member name that does not exist rather than for a table that does
    // not. It is also the exact condition the shipped downsampler's
    // `_valueColumnType` probe answers null for (`database.dart:1487`), which
    // is fallback 3 of its 4: without this the raw query then runs against a
    // table Postgres has never heard of.
    if (columns.isEmpty) throw SeriesTableMissing(wireName, series.table);
    final members = columns.keys.where((c) => c != 'time').toList()..sort();
    final member = series.member;

    if (member != null) {
      if (!columns.containsKey(member) || member == 'time') {
        throw UnknownSeriesMember(wireName, member, members);
      }
      return _shapeFor(wireName, member, columns[member]!);
    }
    // A scalar table is `("value", "time")` — 8b-03's measured shape. Anything
    // else with more than one non-time column is a struct.
    if (members.length == 1 && members.single == 'value') {
      return _shapeFor(wireName, 'value', columns['value']!);
    }
    throw StructSeriesUnaddressed(wireName, members);
  }

  static _Shape _shapeFor(String wireName, String column, String dataType) {
    if (!_numericTypes.contains(dataType)) {
      throw SeriesNotNumeric(wireName, dataType);
    }
    return _Shape(column: column, dataType: dataType);
  }

  /// `column_name → data_type`, from the catalogue.
  ///
  /// Deliberately uncached, for the reason `_valueColumnType` records at
  /// `database.dart:1421-1433`: the type is only stable while the table is,
  /// and a remembered type that outlives a retyped table fails in two
  /// different ways, one of them silently.
  ///
  /// ## The schema predicate is load-bearing (10-REVIEW WR-03)
  ///
  /// Every statement built from this answer — [_read] and the downsample CTE —
  /// names the table **unqualified**, so it resolves through `search_path`.
  /// Without `table_schema` this query does not: it matches the name in
  /// *every* schema the gateway's role can see, and returns the **union** of
  /// their columns with duplicate names collapsing arbitrarily. A staging
  /// schema, a `timescaledb_internal` chunk view, a per-tenant schema or an
  /// `archive` copy of the same table is enough, and all three consequences
  /// are silent:
  ///
  ///  * a struct table read as a scalar or the reverse, because
  ///    `members.length == 1 && members.single == 'value'` is decided on the
  ///    merged set;
  ///  * [UnknownSeriesMember] not raised for a member that exists only in the
  ///    other schema, so the query goes out naming a column the queried table
  ///    does not have and the driver error surfaces as `handlerFailed`
  ///    (-32011, **retryable**) for a request that can never succeed;
  ///  * [SeriesTableMissing] not raised for a table that exists only in the
  ///    other schema, defeating the `columns.isEmpty` guard.
  ///
  /// `current_schema()` and not a literal `'public'`: what this has to match is
  /// wherever the unqualified statements resolve, which is the deployment's
  /// business. Qualifying the generated SQL would be stronger still and is a
  /// larger change; this keeps the catalogue answer and the statement
  /// resolution in step without deciding a schema for anyone.
  Future<Map<String, String>> _columnsOf(ts.Database db, String table) async {
    final rows = await db.db.customSelect(
      r'''
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_name = $1 AND table_schema = current_schema()
      ''',
      variables: [Variable.withString(table)],
    ).get();
    return <String, String>{
      for (final row in rows)
        row.data['column_name'] as String: row.data['data_type'] as String,
    };
  }

  /// One window, one statement, and **never more than [budget] rows built**.
  ///
  /// ## `LIMIT budget + 1`
  ///
  /// The extra row is how the reader learns the answer is over the cap without
  /// building it. The two alternatives are both worse:
  ///
  ///  * *Count first, with a `SELECT COUNT(*)`.* Two round trips for every
  ///    query including the ordinary ones, and the count races the writer — at
  ///    5 s sampling a series gains rows between the count and the read, so the
  ///    number the refusal quotes is not the number the query would answer.
  ///  * *Fetch everything and measure afterwards.* By then the rows are in this
  ///    process's memory, which is the failure `ConflatingSendBuffer` is
  ///    downstream of. Measuring a 190 MB answer to decide not to send it has
  ///    already paid for it.
  ///
  /// The cost is that a refusal knows "over" and not "how far over", so it is
  /// raised with `atLeast: true` and says so. See `ResultTooLarge.atLeast`.
  ///
  /// ## One spelling, not two
  ///
  /// Until 10-10 the scalar path delegated to `Database.queryTimeseriesData`
  /// and the member path spelled its own `tableQuery`, so the where-clause
  /// shapes existed twice already. Neither door takes a `LIMIT`
  /// (`database_drift.dart`'s `tableQuery` has no such parameter, and adding
  /// one would be a `tfc_dart` change this phase does not make), so both paths
  /// now take this statement. The identifiers are quoted here because
  /// `tableQuery` interpolated its column list unquoted — and the member has
  /// already been checked against the table's real columns, so the quoting is
  /// the second belt rather than the first.
  Future<List<TimeseriesData>> _read(ts.Database db, String wireName,
      ResolvedSeries series, _Shape shape, DateTime to,
      {String? orderBy,
      DateTime? from,
      required int budget,
      int spent = 0,
      String? crossedBy}) async {
    final where = from != null
        ? r'time >= $1::timestamptz AND time <= $2::timestamptz'
        : r'time >= $1::timestamptz';
    final args = from != null
        ? [from.toUtc().toIso8601String(), to.toUtc().toIso8601String()]
        : [to.toUtc().toIso8601String()];
    // `budget` can be zero when an earlier series in a batch spent the lot;
    // `LIMIT 1` then refuses on the first row this series has, which is
    // correct — and a series with none still answers empty.
    final sql = 'SELECT ${_quoted(shape.column)}, ${_quoted('time')} '
        'FROM ${_quoted(series.table)} WHERE $where'
        '${orderBy == null ? '' : ' ORDER BY $orderBy'} '
        'LIMIT ${budget + 1}';
    final rows = await db.db.customSelect(sql,
        variables: [for (final arg in args) Variable.withString(arg)]).get();

    if (rows.length > budget) {
      throw ResultTooLarge.rows(
        limit: limits.maxTimeseriesRows,
        measured: spent + rows.length,
        atLeast: true,
        detail: crossedBy == null
            ? null
            : 'the series "$crossedBy" crossed the total; the cap is on the '
                'SUM across the batch, because four series each at the cap '
                'is four times the budget in one frame',
        suggestion: DataServiceMethods.timeseriesQueryDownsampled,
      );
    }

    return [
      for (final row in rows)
        _sample(wireName, shape, row.data[shape.column], row.data['time']),
    ];
  }

  /// One sample, built through the protocol's own constructor.
  ///
  /// Not around it: `TimeseriesData`'s factory is where a non-finite double
  /// becomes null (`timeseries.dart:63-66`). A weigher divide-by-zero that
  /// reached `jsonEncode` intact would throw and fail the whole batch for
  /// every connected client.
  TimeseriesData _sample(
      String wireName, _Shape shape, Object? raw, Object? rawTime) {
    final DateTime time;
    if (rawTime is DateTime) {
      time = rawTime;
    } else if (rawTime is String) {
      time = DateTime.parse(rawTime);
    } else {
      throw ts.DatabaseException('Unexpected time format: ${rawTime.runtimeType}');
    }
    return TimeseriesData<num?>(_numeric(wireName, shape, raw), time.toUtc());
  }

  /// The wire's sample type is `num`, because the client decodes every point
  /// as `TimeseriesData<num>`.
  ///
  /// A bool charts as 1/0 — which is what `graph.dart:949` already does at the
  /// chart, moved to the one place that can also keep the wire's type honest.
  num? _numeric(String wireName, _Shape shape, Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw;
    if (raw is bool) return raw ? 1 : 0;
    // Reachable only if a column changed type under a live table; the shape
    // check refuses everything else up front.
    throw SeriesNotNumeric(wireName, raw.runtimeType.toString());
  }

  /// Postgres identifier quoting, doubling any embedded quote — the same
  /// treatment `queryTimeseriesDataDownsampled` gives its table name at
  /// `database.dart:1483`.
  static String _quoted(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';
}

/// Which column carries this series' samples, and what Postgres calls its type.
final class _Shape {
  const _Shape({required this.column, required this.dataType});

  final String column;

  /// The catalogue's `data_type`, kept rather than reduced to a flag: the
  /// downsampler's aggregability question and the 1/0 question are different
  /// questions about it, and a second one arrived in 10-10.
  ///
  /// **There is deliberately no `isBoolean` here** (10-REVIEW IN-02, 10-07's
  /// nit before it). One was written and never read: `_numeric` decides the
  /// 1/0 treatment from `raw is bool` — the *value's* own runtime type, which
  /// is the honest question on a path where a column can be retyped under a
  /// live table — and the shape's `dataType` answers the *catalogue's*
  /// question for `_aggregatable` and `_numericTypes`. Two spellings of one
  /// question is how they drift apart; the one that survives is the one with
  /// a caller.
  final String dataType;
}
