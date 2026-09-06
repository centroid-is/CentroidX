/// The historical half of the backend's `StateManApi`: `timeseries`,
/// `historyViews` and `preferences`, answered from the `Database`,
/// `AppDatabase` and `Preferences` that `centroidx-backend` already holds.
///
/// ## Why this is a re-implementation and must stay one
///
/// `tfc_relay_local` already has three tested classes doing exactly this —
/// `data/timescale_reader.dart` (`TimescaleReader`),
/// `data/history_view_store.dart` (`HistoryViewStore`) and
/// `data/preference_store.dart` (`PreferenceStore`), with their ceilings in
/// `data/read_limits.dart`. **They cannot be imported here.**
/// `tfc_relay_local` depends on `tfc_dart` (`tfc_relay_local/pubspec.yaml:36`),
/// so the edge that would let this file name one of them is a dependency
/// cycle, and `package_edge_test.dart` fails on the attempt.
///
/// So their *decisions* are carried across and re-stated over `Database`
/// directly. Anybody reading the two side by side and reaching for a
/// de-duplication should read this paragraph first: the duplication is
/// structural, not an oversight. What was carried across, and from where:
///
///  * **Refuse, never truncate, and never clamp** (`read_limits.dart:21-30`).
///    A truncated series is a line that stops in mid-air, and the operator
///    reads the truncation point as *now*. Every ceiling in this file refuses
///    with a message naming the ceiling, the value measured and the method
///    that would answer the same question inside it.
///  * **The row ceiling is the sum across a multi-series read**
///    (`read_limits.dart:153-159`), because four tables each at the cap is
///    four times the budget in one frame, arrived at by obeying the limit four
///    times.
///  * **`clear` is a remove per key and not a delegation**
///    (`preference_store.dart:446-488`): upstream's `Preferences.clear` empties
///    the memory cache and never touches Postgres, so through a gateway it is
///    a clear that undoes itself on the next rebuild.
///  * **`StateError` for the historian, `UnsupportedError` for preferences**
///    (`local_state_man.dart:1407-1490`). See [BackendTimeseries] and
///    [BackendPreferences] for the reasoning; the distinction is mechanical,
///    not stylistic — `data_handlers.dart:216` catches exactly
///    `UnsupportedError`, on every session, unconditionally.
///
/// What was deliberately **not** carried across is the reader's
/// `information_schema` column introspection: it decides struct-vs-scalar
/// before the query, which needs a live catalogue and cannot be judged without
/// one. This file decides from the rows it got back instead. The cost is
/// recorded on [BackendTimeseries.queryTimeseriesData].
///
/// ## The seams, and why they are here
///
/// Each of the three classes takes a narrow interface over the backend's real
/// object rather than the object itself: [TimeseriesSource] over `Database`'s
/// four timeseries methods, [HistoryViewSource] over `AppDatabase`'s eleven
/// history-view methods, [PreferenceSource] over `Preferences`. Each has a
/// one-line production adapter at the bottom of its section, and 13-09's
/// `db`-tagged lane swaps a live TimescaleDB in behind the same three.
///
/// The seams also buy the one thing a live database cannot: an arm can assert
/// **what the source was asked for**, which is the only way to state
/// "downsampling happened where the data is" as a property rather than as a
/// comment.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../database.dart' as db;

// =============================================================== the historian

/// The ceilings one timeseries answer may be, applied before the query.
///
/// **The three configurable numbers are the relay server's own**
/// (`server_config.dart:332-334`: `maxTimeseriesPoints` 6000,
/// `maxTimeseriesBuckets` 1000, `maxTimeseriesIntervalMs` 86_400_000) and are
/// handed in rather than re-spelled. That config class is deliberately NOT
/// named or imported here — the name does not appear in this file, and a grep
/// says so — so this file stays composable from a test with three literals
/// and 13-06 owns the mapping from config onto it.
///
/// [maxRows] has no counterpart in `server_config.dart` and is 10-07's
/// `ReadLimits.maxTimeseriesRows`, carried across unchanged. It is the only
/// ceiling on the **raw** read: `data_handlers.dart` bounds `maxPoints`,
/// `howMany` and the bucket width at the trust boundary but bounds nothing at
/// all on `queryTimeseriesData`, which is the path a chart takes when somebody
/// widens its window from a day to a month. At SVN's 5 s sampling 40 000 rows
/// is 2.3 days: a day is answered, a week and a month are refused with
/// `queryTimeseriesDataDownsampled` named as the fix.
final class TimeseriesLimits {
  TimeseriesLimits({
    this.maxPoints = 6000,
    this.maxBuckets = 1000,
    this.maxIntervalMs = 86400000,
    this.maxRows = 40000,
  }) {
    _positive('maxPoints', maxPoints);
    _positive('maxBuckets', maxBuckets);
    _positive('maxIntervalMs', maxIntervalMs);
    _positive('maxRows', maxRows);
  }

  /// The smallest `maxPoints` that does not make the database fall back.
  ///
  /// Three, and not a knob, because it is a property of the code being called
  /// rather than of this deployment: `queryTimeseriesDataDownsampled` computes
  /// `(maxPoints / 3).floor()` buckets and answers a full raw read when that
  /// is zero (`database.dart:1522-1525`).
  static const int minPoints = 3;

  /// Ceiling on `maxPoints` in one downsampled read.
  final int maxPoints;

  /// Ceiling on `howMany` buckets in one count — which *is* the number of
  /// `UNION ALL` subqueries in one statement (`database.dart:1686-1695`).
  final int maxBuckets;

  /// Ceiling on the bucket width, in milliseconds, of one count.
  final int maxIntervalMs;

  /// Ceiling on the rows one answer may carry, summed across its series.
  final int maxRows;

  static void _positive(String name, int value) {
    if (value <= 0) {
      throw ArgumentError('TimeseriesLimits.$name ($value) must be positive: a '
          'non-positive ceiling refuses every query, and a backend that '
          'refuses every query presents to an operator as "the historian is '
          'empty"');
    }
  }

  @override
  String toString() => 'TimeseriesLimits(maxPoints: $maxPoints, maxBuckets: '
      '$maxBuckets, maxIntervalMs: $maxIntervalMs, maxRows: $maxRows)';
}

/// The four `Database` methods [BackendTimeseries] needs, and nothing else.
///
/// Signatures verbatim from `database.dart:1352`, `:1384`, `:1509` and `:1666`,
/// including the parameter names and the defaults, so
/// [DatabaseTimeseriesSource] is a forwarding call and nothing is re-decided on
/// the way through.
abstract interface class TimeseriesSource {
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from});

  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from});

  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000});

  Future<Map<DateTime, int>> countTimeseriesDataMultiple(
      String tableName, Duration interval, int howMany,
      {DateTime? since});
}

/// [TimeseriesSource] over the backend's own `Database`.
final class DatabaseTimeseriesSource implements TimeseriesSource {
  const DatabaseTimeseriesSource(this.database);

  final db.Database database;

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) =>
      database.queryTimeseriesData(tableName, to, orderBy: orderBy, from: from);

  @override
  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
              {String? orderBy = 'time ASC', DateTime? from}) =>
          database.queryTimeseriesDataMultiple(tableNames, to,
              orderBy: orderBy, from: from);

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
          String tableName, DateTime from, DateTime to,
          {int maxPoints = 1000}) =>
      database.queryTimeseriesDataDownsampled(tableName, from, to,
          maxPoints: maxPoints);

  @override
  Future<Map<DateTime, int>> countTimeseriesDataMultiple(
          String tableName, Duration interval, int howMany,
          {DateTime? since}) =>
      database.countTimeseriesDataMultiple(tableName, interval, howMany,
          since: since);
}

/// `TimeseriesApi` over the backend's historian, bounded before it is asked.
///
/// ## Every argument is a value somebody on a socket chose
///
/// The table name, the window, the point budget, the bucket width and the
/// ordering all arrive from a connected client, and three of them reach a SQL
/// string unescaped in the layer below: `countTimeseriesDataMultiple`
/// interpolates `FROM "$tableName"` with no quote doubling at all
/// (`database.dart:1691`), `tableQuery` interpolates `orderBy` into an
/// `ORDER BY` clause where a subquery is legal grammar, and
/// `queryTimeseriesDataDownsampled` interpolates its own quoted table.
///
/// So two belts, the house convention on ingress:
///
///  1. **The name is resolved, never trusted.** [resolver] turns a wire series
///     name into a table this backend actually records, and a name it refuses
///     never reaches the source. This is the second of the two belts
///     `data_handlers.dart:1066-1084` describes — that one enforces the
///     *grammar* and deliberately leaves "there is no such series" to the
///     reader, so that it can be counted rather than echoed. Here is the
///     reader.
///  2. **`orderBy` is an allow-list of two**, matching
///     `data_handlers.dart:1018`. Refused, never sanitized: a sanitizer
///     invites the question of whether it is complete.
///
/// ## And bounded before the query, not after it
///
/// A read that has already run has already cost what the bound exists to
/// prevent. The three `server_config.dart` ceilings are checked against the
/// arguments before anything is asked of the database. Two checks necessarily
/// come after, and both are stated as such: the row budget (nothing knows the
/// row count until the rows exist) and the downsample fallback detector — see
/// [queryTimeseriesDataDownsampled].
final class BackendTimeseries implements relay.TimeseriesApi {
  /// Composes over the seam. [source] null is a backend with no historian, and
  /// every member then refuses by name.
  BackendTimeseries({
    required this.source,
    required this.resolver,
    required this.limits,
  });

  /// The production spelling: over the `Database` the backend already holds.
  BackendTimeseries.overDatabase({
    required db.Database? database,
    required relay.SeriesResolver resolver,
    required TimeseriesLimits limits,
  }) : this(
          source: database == null ? null : DatabaseTimeseriesSource(database),
          resolver: resolver,
          limits: limits,
        );

  final TimeseriesSource? source;

  /// The only way a caller-supplied string becomes a table name.
  final relay.SeriesResolver resolver;

  final TimeseriesLimits limits;

  /// The two orderings this backend will pass down, verbatim from
  /// `data_handlers.dart:1018`.
  static const _orderings = {'time ASC', 'time DESC'};

  // ------------------------------------------------------------------ members

  /// Samples for one series up to [to], optionally from [from].
  ///
  /// **The struct cost, stated once.** `Database` has no column projection, so
  /// a `<series>:<member>` address reads the whole recorded row and takes the
  /// member out of it here. 10-07's reader spells its own statement and reads
  /// one column; this cannot, and at SVN — where 91 whole drive structs are
  /// historised at 5 s — that is a real multiplier on the bytes a member chart
  /// costs the database, though not on the bytes that reach the socket. The
  /// [TimeseriesLimits.maxRows] budget still bounds the answer. Closing the
  /// gap properly means a projecting read on `Database`, which is a change to
  /// a file shared with the application and belongs to its own plan.
  @override
  Future<List<relay.TimeseriesData>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    const member = 'queryTimeseriesData';
    final reader = _reader(member);
    final series = _resolve(member, tableName);
    _requireOrdering(member, orderBy);
    final rows = await reader.queryTimeseriesData(series.table, to,
        orderBy: orderBy, from: from);
    _requireRowBudget(member, rows.length, tableName);
    return _project(member, tableName, series.member, rows);
  }

  /// The same window for several series in one round trip, keyed by the name
  /// the caller asked with.
  ///
  /// **Keyed by the wire name and not by the table**, and every requested name
  /// gets an entry even when nothing was recorded. `Database` answers a map
  /// with no key at all for a table it has nothing for
  /// (`database.dart:1366-1379` only ever adds a key it found a row for), and a
  /// chart iterating the names it asked for finds null, which null-handling in
  /// a legend turns into a series silently dropped. "This tag is flat" and
  /// "nothing was recorded" are different facts.
  @override
  Future<Map<String, List<relay.TimeseriesData>>> queryTimeseriesDataMultiple(
      List<String> tableNames, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from}) async {
    const member = 'queryTimeseriesDataMultiple';
    final reader = _reader(member);
    _requireOrdering(member, orderBy);
    final resolved = <String, relay.ResolvedSeries>{
      for (final name in tableNames) name: _resolve(member, name),
    };
    final answered = await reader.queryTimeseriesDataMultiple(
        [for (final series in resolved.values) series.table], to,
        orderBy: orderBy, from: from);

    var total = 0;
    for (final rows in answered.values) {
      total += rows.length;
    }
    _requireRowBudget(member, total, tableNames.join(', '));

    return {
      for (final entry in resolved.entries)
        entry.key: _project(member, entry.key, entry.value.member,
            answered[entry.value.table] ?? const []),
    };
  }

  /// At most [maxPoints] samples spanning [from]…[to], downsampled where the
  /// data is.
  ///
  /// **The fallback is detected, not passed on.**
  /// `Database.queryTimeseriesDataDownsampled` answers a full raw read, under
  /// this method's name and with no error, whenever it cannot bucket the
  /// column: a non-numeric type, a table with no `value` column at all — which
  /// is every struct table — a zero-width window, or a bucket count that
  /// floors to zero (`database.dart:1517-1561`, and the doc at `:947`). Two of
  /// those are refused up front, from the arguments. The rest can only be seen
  /// afterwards, and the shape they take is an answer larger than the budget,
  /// so an answer larger than the budget is refused rather than forwarded. A
  /// month of one-second samples is millions of points and a chart has
  /// hundreds of pixels; forwarding them under the bounded method's name is
  /// the denial of service the bounded method exists to prevent.
  @override
  Future<List<relay.TimeseriesData>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to,
      {int maxPoints = 1000}) async {
    const member = 'queryTimeseriesDataDownsampled';
    final reader = _reader(member);
    final series = _resolve(member, tableName);
    if (maxPoints > limits.maxPoints) {
      throw ArgumentError('$member refused a maxPoints of $maxPoints: this '
          'backend\'s maxPoints ceiling is ${limits.maxPoints}. Above it the '
          'caller is not drawing a chart — the widest panel in this plant is '
          '1920 px and a bucket contributes three points — it is asking for a '
          'raw query under the bounded method\'s name');
    }
    if (maxPoints < TimeseriesLimits.minPoints) {
      throw ArgumentError('$member refused a maxPoints of $maxPoints: the '
          'floor is ${TimeseriesLimits.minPoints} and it is not a knob. Below '
          'it `(maxPoints / 3).floor()` is zero and the database answers a '
          'full raw read under this method\'s name, silently '
          '(database.dart:1522-1525)');
    }
    if (from.isAfter(to)) {
      throw ArgumentError('$member was given a window whose from ($from) is '
          'after its to ($to). It is refused rather than silently swapped: '
          'the database opens with `from.isBefore(to) ? from : to`, so two '
          'callers sending opposite arguments get identical answers and '
          'neither is told which one it got');
    }
    final rows = await reader.queryTimeseriesDataDownsampled(
        series.table, from, to,
        maxPoints: maxPoints);
    if (rows.length > maxPoints) {
      throw ArgumentError('$member asked for at most $maxPoints points and the '
          'database answered ${rows.length}, which is its silent fallback to a '
          'raw query (database.dart:947) — usually a struct table, which has '
          'no `value` column to bucket. It is refused rather than forwarded: '
          'the whole reason this method exists separately is that the raw '
          'result does not fit on the link. Ask for a narrower window through '
          'queryTimeseriesData, or plot one member');
    }
    return _project(member, tableName, series.member, rows);
  }

  /// Sample counts per [interval] bucket, newest [howMany] buckets, UTC.
  @override
  Future<Map<DateTime, int>> countTimeseriesDataMultiple(
      String tableName, Duration interval, int howMany,
      {DateTime? since}) async {
    const member = 'countTimeseriesDataMultiple';
    final reader = _reader(member);
    final series = _resolve(member, tableName);
    if (howMany > limits.maxBuckets) {
      throw ArgumentError('$member refused a howMany of $howMany: this '
          'backend\'s bucket ceiling is ${limits.maxBuckets}. howMany IS the '
          'number of UNION ALL subqueries in one statement '
          '(database.dart:1686-1695), so this is a length bound on generated '
          'SQL and not a convenience limit');
    }
    if (howMany <= 0) {
      throw ArgumentError('$member refused a howMany of $howMany: a request '
          'for no buckets is a round trip the caller then waits on');
    }
    final intervalMs = interval.inMilliseconds;
    if (intervalMs > limits.maxIntervalMs) {
      throw ArgumentError('$member refused an interval of $intervalMs ms: this '
          'backend\'s interval ceiling is ${limits.maxIntervalMs} ms. A wider '
          'bucket than a day can only produce empty ones past any retention '
          'horizon this plant configures, and an empty bucket reads as "the '
          'recorder stopped"');
    }
    if (intervalMs < 1) {
      throw ArgumentError('$member refused an interval of ${interval.inMicroseconds} '
          'µs: it truncates to 0 ms, and a zero-width bucket makes every '
          'bucket in the strip cover the same instant');
    }
    final counts = await reader.countTimeseriesDataMultiple(
        series.table, interval, howMany,
        since: since);
    // The bucket starts are built from `since ?? DateTime.now()`
    // (`database.dart:1673`), which is local unless the caller made it UTC.
    // Every instant on this wire is absolute.
    return {
      for (final entry in counts.entries) entry.key.toUtc(): entry.value,
    };
  }

  // ---------------------------------------------------------------- internals

  TimeseriesSource _reader(String member) =>
      source ??
      (throw StateError('BackendTimeseries.$member is not available: this '
          'backend was composed without a Database, so it has no recorded '
          'samples to serve. Give bin/main.dart a database configuration; a '
          'backend with none constructs no historian at all. It is a '
          'StateError and not an UnsupportedError because the member is '
          'implemented and what is absent is a historian in this deployment '
          '(local_state_man.dart:1407). An empty list here would draw every '
          'chart flat, for months, with nothing saying why'));

  /// [wireName] as a table this backend records, or a refusal.
  ///
  /// A [FormatException] for a malformed name and an [ArgumentError] for one
  /// that is well formed but unmapped: "you spelled it wrong" and "there is no
  /// such series" are two different facts and the caller acts on them
  /// differently (`series_address.dart:162-165`).
  relay.ResolvedSeries _resolve(String member, String wireName) {
    final resolved = resolver.resolve(wireName);
    if (resolved != null) return resolved;
    throw ArgumentError('$member refused the series "$wireName": this backend '
        'records no such series. A name is resolved, never trusted — it '
        'reaches a table name that is interpolated into SQL unescaped '
        '(database.dart:1691), so a name nothing in the key mappings claims '
        'does not reach the database at all');
  }

  void _requireOrdering(String member, String? orderBy) {
    if (orderBy == null || _orderings.contains(orderBy)) return;
    throw ArgumentError('$member accepts an orderBy of exactly one of '
        '${_orderings.join(' or ')}, or none. It is refused rather than '
        'sanitized or completed: this string is interpolated into a SQL ORDER '
        'BY clause, where a subquery is legal grammar, so anything outside '
        'the allow list is a statement fragment the caller chose');
  }

  void _requireRowBudget(String member, int rows, String what) {
    if (rows <= limits.maxRows) return;
    throw ArgumentError('$member answered $rows rows for "$what", over this '
        'backend\'s ceiling of ${limits.maxRows}. It is refused and not '
        'truncated: a truncated series is a line that stops in mid-air and '
        'the operator reads the truncation point as now. Ask for a narrower '
        'window, or use queryTimeseriesDataDownsampled, which bounds the '
        'answer where the data is');
  }

  /// tfc_dart's samples as the wire's, with the member taken out of the row.
  List<relay.TimeseriesData> _project(String member, String wireName,
      String? selected, List<db.TimeseriesData<dynamic>> rows) {
    final out = <relay.TimeseriesData>[];
    for (final row in rows) {
      out.add(relay.TimeseriesData<dynamic>(
          _scalar(member, wireName, selected, row.value), row.time));
    }
    return out;
  }

  Object? _scalar(
      String member, String wireName, String? selected, Object? value) {
    if (value is List) {
      throw ArgumentError('$member refused "$wireName": it records an array of '
          '${value.length} values per sample and this wire carries samples as '
          'scalars. Sending it would be a CastError at whatever panel plots '
          'it, which is a red screen with no indication of which series or '
          'which member caused it');
    }
    if (value is Map) {
      final members = value.keys.map((k) => '$k').toList()..sort();
      if (selected == null) {
        throw ArgumentError('$member refused "$wireName": it records a struct '
            'of ${members.length} members, so it has no single scalar series. '
            'Ask for one member: ${members.map((m) => '$wireName:$m').join(', ')}');
      }
      if (!value.containsKey(selected)) {
        throw ArgumentError('$member refused "$wireName": the recorded row has '
            'no member "$selected". It has: ${members.join(', ')}');
      }
      return _scalar(member, wireName, null, value[selected]);
    }
    if (selected != null) {
      throw ArgumentError('$member refused "$wireName": a member was selected '
          'but the recorded sample is a scalar, not a struct, so there is no '
          '"$selected" to take out of it');
    }
    return value;
  }
}
