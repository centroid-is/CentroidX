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

import 'dart:async';

import 'package:drift/drift.dart' show UpdateKind, Variable;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../database.dart' as db;
import '../database_drift.dart' as drift;
import '../preferences.dart' as store;

// =============================================================== the historian

/// The ceilings one timeseries answer may be, applied before the query.
///
/// **The configurable number is the relay server's own**
/// (`server_config.dart`: `maxTimeseriesPoints` 6000) and is handed in rather
/// than re-spelled. That config class is deliberately NOT named or imported
/// here — the name does not appear in this file, and a grep says so — so this
/// file stays composable from a test with literals and 13-06 owns the mapping
/// from config onto it. (Two more ceilings, `maxBuckets` and `maxIntervalMs`,
/// bounded the count method until the 2026-09-07 dead-code audit cut it.)
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
    this.maxRows = 40000,
  }) {
    _positive('maxPoints', maxPoints);
    _positive('maxRows', maxRows);
  }

  /// The smallest `maxPoints` that does not make the database fall back.
  ///
  /// Three, and not a knob, because it is a property of the code being called
  /// rather than of this deployment: `queryTimeseriesDataDownsampled` computes
  /// `(maxPoints / 3).floor()` buckets and answers a full raw read when that
  /// is zero (`database.dart:1570-1573`).
  static const int minPoints = 3;

  /// Ceiling on `maxPoints` in one downsampled read.
  final int maxPoints;

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
  String toString() =>
      'TimeseriesLimits(maxPoints: $maxPoints, maxRows: $maxRows)';
}

/// The three `Database` methods [BackendTimeseries] needs, and nothing else.
///
/// Signatures verbatim from `database.dart:1396`, `:1428` and `:1557`,
/// including the parameter names and the defaults, so
/// [DatabaseTimeseriesSource] is a forwarding call and nothing is re-decided on
/// the way through. (`:1714`'s count method was the fourth until the
/// 2026-09-07 dead-code audit cut this mirror; the `database.dart` member
/// itself is main-era and stays, flagged for the main cleanup PR.)
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
}

/// `TimeseriesApi` over the backend's historian, bounded before it is asked.
///
/// ## Every argument is a value somebody on a socket chose
///
/// The table name, the window, the point budget and the ordering all arrive
/// from a connected client, and they reach a SQL string unescaped in the
/// layer below: `tableQuery` interpolates `orderBy` into an `ORDER BY` clause
/// where a subquery is legal grammar, and `queryTimeseriesDataDownsampled`
/// interpolates its own quoted table.
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
/// prevent. The `server_config.dart` point ceiling is checked against the
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
  /// (`database.dart:1410-1423` only ever adds a key it found a row for), and a
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
  /// floors to zero (`database.dart:1565-1609`, and the doc at `:991`). Two of
  /// those are refused up front, from the arguments. The rest can only be seen
  /// afterwards, and the shape they take is an answer larger than the budget,
  /// so an answer larger than the budget is refused rather than forwarded. A
  /// month of one-second samples is millions of points and a chart has
  /// hundreds of pixels; forwarding them under the bounded method's name is
  /// the denial of service the bounded method exists to prevent.
  ///
  /// An over-budget answer is not *only* the fallback, though, and the
  /// refusal distinguishes the two. The bucketed path can also overrun by a
  /// bucket — three rows — when the bucket width and `time_bucket`'s
  /// alignment disagree about how many buckets a window spans (13-12: 50
  /// points asked for, 51 answered). That is a defect in the sizing, in
  /// `database.dart`, and sending its reader to the fallback's doc comment
  /// sends them to the wrong file.
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
          '(database.dart:1570-1573)');
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
      // Two different defects arrive here and they live in different files,
      // so the refusal says which one it is looking at rather than guessing.
      //
      // The bucketed path emits exactly three rows per bucket (min, max,
      // last), so its answer is always a multiple of three and never more
      // than a bucket or two past the budget when the bucket arithmetic slips
      // — that is a boundary bug in the *sizing*, in database.dart. The
      // fallback path returns every row in the window, which is a number with
      // no relation to maxPoints at all. A month of one-second samples is
      // millions of rows; three extra points is not.
      final overshootMultiple = rows.length % 3 == 0;
      final overBy = rows.length - maxPoints;
      final looksLikeBoundaryOvershoot = overshootMultiple && overBy <= 3;
      throw ArgumentError('$member asked for at most $maxPoints points and the '
          'database answered ${rows.length}. It is refused rather than '
          'forwarded: the whole reason this method exists separately is that '
          'an unbounded result does not fit on the link. '
          '${looksLikeBoundaryOvershoot ? 'The answer is $overBy over the '
              'budget and a multiple of three, so this is the bucketed path '
              'returning one bucket too many, not the raw fallback — a raw '
              'read of this window would be orders of magnitude larger. Look '
              'at the bucket sizing and the time_bucket origin in '
              '`Database.queryTimeseriesDataDownsampled` / '
              '`buildDownsampleSql` (database.dart): a window that does not '
              'begin on a bucket boundary, or one whose span divides the '
              'width exactly, spans one more bucket than it was sized for.' : 'The answer bears no relation to the budget, which is the shape '
              'of the silent fallback to a raw query (database.dart:991) — '
              'usually a struct table, which has no `value` column to bucket, '
              'or a non-numeric column type. Ask for a narrower window '
              'through queryTimeseriesData, or plot one member.'}');
    }
    return _project(member, tableName, series.member, rows);
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
        '(database.dart:1739), so a name nothing in the key mappings claims '
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

// ============================================================= history views

/// The eleven `AppDatabase` history-view methods, and nothing else.
///
/// Signatures verbatim from `database_drift.dart:983-1160`, generated row
/// classes and untyped bags included. **Mapping those onto the protocol's
/// plain records is this seam's whole reason to exist**: an ORM row out of a
/// 10,000-line generated file can neither live in a zero-dependency package
/// nor cross a socket with its field names intact (`history_view.dart:1-13`),
/// and the conversion has to happen somewhere that a test can reach without a
/// Postgres.
abstract interface class HistoryViewSource {
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]);

  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, Map<String, dynamic>>? keyConfigs,
      Map<String, Map<String, dynamic>>? graphConfigs]);

  Future<void> deleteHistoryView(int id);

  Future<List<drift.HistoryViewData>> selectHistoryViews();

  Future<Map<String, Map<String, dynamic>>> getHistoryViewKeys(int viewId);

  Future<Map<int, Map<String, dynamic>>> getHistoryViewGraphs(int viewId);

  Future<List<String>> getHistoryViewKeyNames(int viewId);

  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end);

  Future<void> deleteHistoryViewPeriod(int id);

  Future<List<drift.HistoryViewPeriodData>> listHistoryViewPeriods(int viewId);

  Future<DateTime?> getGlobalRetentionHorizon();
}

/// [HistoryViewSource] over the backend's own `AppDatabase`.
final class DatabaseHistoryViewSource implements HistoryViewSource {
  const DatabaseHistoryViewSource(this.database);

  final drift.AppDatabase database;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, Map<String, dynamic>>? keyConfigs,
          Map<String, Map<String, dynamic>>? graphConfigs]) =>
      database.createHistoryView(name, keys, keyConfigs, graphConfigs);

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, Map<String, dynamic>>? keyConfigs,
          Map<String, Map<String, dynamic>>? graphConfigs]) =>
      database.updateHistoryView(id, name, keys, keyConfigs, graphConfigs);

  @override
  Future<void> deleteHistoryView(int id) => database.deleteHistoryView(id);

  @override
  Future<List<drift.HistoryViewData>> selectHistoryViews() =>
      database.selectHistoryViews();

  @override
  Future<Map<String, Map<String, dynamic>>> getHistoryViewKeys(int viewId) =>
      database.getHistoryViewKeys(viewId);

  @override
  Future<Map<int, Map<String, dynamic>>> getHistoryViewGraphs(int viewId) =>
      database.getHistoryViewGraphs(viewId);

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) =>
      database.getHistoryViewKeyNames(viewId);

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      database.addHistoryViewPeriod(viewId, name, start, end);

  @override
  Future<void> deleteHistoryViewPeriod(int id) =>
      database.deleteHistoryViewPeriod(id);

  @override
  Future<List<drift.HistoryViewPeriodData>> listHistoryViewPeriods(
          int viewId) =>
      database.listHistoryViewPeriods(viewId);

  @override
  Future<DateTime?> getGlobalRetentionHorizon() =>
      database.getGlobalRetentionHorizon();
}

/// `HistoryViewApi` over the backend's saved views.
///
/// ## Every instant is absolute
///
/// Every `DateTime` that leaves this class goes through [_utc]. The driver
/// hands a `timestamptz` back in whatever zone the session is in, and the
/// protocol's records carry epoch milliseconds and decode as UTC
/// (`history_view.dart:15-18`) — so a record built from a local `DateTime` is
/// not `==` to the one that comes back off the wire, and a saved shift lands
/// an hour out twice a year. `DateTime` equality in Dart compares `isUtc` as
/// well as the instant, which is what makes that testable rather than
/// seasonal.
///
/// ## Bounded, because these rows are caller-grown
///
/// [maxRows] is 10-07's `ReadLimits.maxHistoryViewRows`, and the reason it
/// exists is not the same as the timeseries one: a timeseries answer is
/// bounded by how long the plant has been running, and these four reads are
/// bounded by how many rows a client has created. `createHistoryView` and
/// `addHistoryViewPeriod` are row factories reachable from the wire, so an
/// `operate` station in a loop is the whole amplification
/// (`read_limits.dart:171-178`). One ceiling covers the picker, a view's keys,
/// its graphs and its windows: the same hazard from the same door, and four
/// numbers would be four things to keep in step for a distinction nobody can
/// act on.
final class BackendHistoryViews implements relay.HistoryViewApi {
  BackendHistoryViews({required this.source, this.maxRows = 5000});

  /// The production spelling: over the `AppDatabase` the backend already holds.
  BackendHistoryViews.overDatabase({
    required drift.AppDatabase? database,
    int maxRows = 5000,
  }) : this(
          source:
              database == null ? null : DatabaseHistoryViewSource(database),
          maxRows: maxRows,
        );

  final HistoryViewSource? source;

  /// The row ceiling for one history-view read.
  final int maxRows;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, relay.HistoryViewKeyRecord>? keyConfigs,
      Map<int, relay.HistoryViewGraphRecord>? graphConfigs]) async {
    final views = _views('createHistoryView');
    return views.createHistoryView(
        name, keys, _keyBags(keyConfigs), _graphBags(graphConfigs));
  }

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, relay.HistoryViewKeyRecord>? keyConfigs,
      Map<int, relay.HistoryViewGraphRecord>? graphConfigs]) async {
    final views = _views('updateHistoryView');
    return views.updateHistoryView(
        id, name, keys, _keyBags(keyConfigs), _graphBags(graphConfigs));
  }

  @override
  Future<void> deleteHistoryView(int id) =>
      _views('deleteHistoryView').deleteHistoryView(id);

  @override
  Future<List<relay.HistoryViewRecord>> selectHistoryViews() async {
    final rows = await _views('selectHistoryViews').selectHistoryViews();
    _requireRowBudget('selectHistoryViews', rows.length);
    return [
      for (final row in rows)
        relay.HistoryViewRecord(
          id: row.id,
          name: row.name,
          createdAt: _utc(row.createdAt),
          updatedAt: row.updatedAt == null ? null : _utc(row.updatedAt!),
        ),
    ];
  }

  @override
  Future<Map<String, relay.HistoryViewKeyRecord>> getHistoryViewKeys(
      int viewId) async {
    final bags = await _views('getHistoryViewKeys').getHistoryViewKeys(viewId);
    _requireRowBudget('getHistoryViewKeys', bags.length);
    return {
      for (final entry in bags.entries)
        entry.key: relay.HistoryViewKeyRecord(
          key: '${entry.value['key'] ?? entry.key}',
          // Null and not `?? key`: the record's own constructor defaults the
          // alias to the key, and re-spelling the default here would be a
          // second place for it to drift.
          alias: entry.value['alias'] as String?,
          useSecondYAxis: entry.value['useSecondYAxis'] as bool? ?? false,
          graphIndex: (entry.value['graphIndex'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  @override
  Future<Map<int, relay.HistoryViewGraphRecord>> getHistoryViewGraphs(
      int viewId) async {
    final bags =
        await _views('getHistoryViewGraphs').getHistoryViewGraphs(viewId);
    _requireRowBudget('getHistoryViewGraphs', bags.length);
    return {
      // The drift layer keys the map by graph index and leaves the index out
      // of the bag (`database_drift.dart:1109-1116`); the record carries it as
      // a field, so it comes from the key.
      for (final entry in bags.entries)
        entry.key: relay.HistoryViewGraphRecord(
          graphIndex: entry.key,
          name: entry.value['name'] as String? ?? '',
          yAxisUnit: entry.value['yAxisUnit'] as String? ?? '',
          yAxis2Unit: entry.value['yAxis2Unit'] as String? ?? '',
        ),
    };
  }

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async {
    final names =
        await _views('getHistoryViewKeyNames').getHistoryViewKeyNames(viewId);
    _requireRowBudget('getHistoryViewKeyNames', names.length);
    return names;
  }

  @override
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      _views('addHistoryViewPeriod')
          .addHistoryViewPeriod(viewId, name, start.toUtc(), end.toUtc());

  @override
  Future<void> deleteHistoryViewPeriod(int id) =>
      _views('deleteHistoryViewPeriod').deleteHistoryViewPeriod(id);

  @override
  Future<List<relay.HistoryViewPeriodRecord>> listHistoryViewPeriods(
      int viewId) async {
    final rows =
        await _views('listHistoryViewPeriods').listHistoryViewPeriods(viewId);
    _requireRowBudget('listHistoryViewPeriods', rows.length);
    return [
      for (final row in rows)
        relay.HistoryViewPeriodRecord(
          id: row.id,
          viewId: row.viewId,
          name: row.name,
          startAt: _utc(row.startAt),
          endAt: _utc(row.endAt),
          createdAt: _utc(row.createdAt),
        ),
    ];
  }

  @override
  Future<DateTime?> getGlobalRetentionHorizon() async {
    final horizon =
        await _views('getGlobalRetentionHorizon').getGlobalRetentionHorizon();
    return horizon == null ? null : _utc(horizon);
  }

  // ---------------------------------------------------------------- internals

  HistoryViewSource _views(String member) =>
      source ??
      (throw StateError('BackendHistoryViews.$member is not available: this '
          'backend was composed without a Database, so it has nowhere to keep '
          'a saved history view. Give bin/main.dart a database configuration. '
          'It is a StateError and not an UnsupportedError because the member '
          'is implemented and what is absent is a database in this deployment '
          '(local_state_man.dart:1440). Not an empty store either: a view '
          'picker that answers "you have saved nothing" to a plant that has '
          'saved plenty is an operator saving their view a second time, and '
          'then a third'));

  void _requireRowBudget(String member, int rows) {
    if (rows <= maxRows) return;
    throw ArgumentError('$member answered $rows rows, over this backend\'s '
        'ceiling of $maxRows. It is refused and not truncated: a picker '
        'missing the view an operator saved reads as the view having been '
        'lost. These rows are caller-grown — createHistoryView and '
        'addHistoryViewPeriod are row factories reachable from the wire — so '
        'the fix is deleting views, not raising the number');
  }

  /// The wire's key records as the untyped bags the drift layer takes.
  ///
  /// `alias` is written even when it equals the key: the record defaults it on
  /// construction, and passing null would let `database_drift.dart`'s own
  /// `config?['alias'] ?? key` default it a second time, which is one rule in
  /// two places.
  static Map<String, Map<String, dynamic>>? _keyBags(
          Map<String, relay.HistoryViewKeyRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries)
                entry.key: <String, dynamic>{
                  'alias': entry.value.alias,
                  'useSecondYAxis': entry.value.useSecondYAxis,
                  'graphIndex': entry.value.graphIndex,
                },
            };

  /// The wire's graph records as the drift layer's bags.
  ///
  /// **Keyed by the decimal spelling of the index.** `createHistoryView` takes
  /// `Map<String, Map<String, dynamic>>` and calls `int.tryParse(entry.key)`,
  /// dropping silently what does not parse (`database_drift.dart:1006-1008`) —
  /// so an int key here would not be a type error, it would be a graph
  /// configuration that vanishes.
  static Map<String, Map<String, dynamic>>? _graphBags(
          Map<int, relay.HistoryViewGraphRecord>? configs) =>
      configs == null
          ? null
          : {
              for (final entry in configs.entries)
                '${entry.key}': <String, dynamic>{
                  'name': entry.value.name,
                  'yAxisUnit': entry.value.yAxisUnit,
                  'yAxis2Unit': entry.value.yAxis2Unit,
                },
            };

  /// The same instant, stated absolutely.
  static DateTime _utc(DateTime t) => t.toUtc();
}

// =============================================================== preferences

/// The `Preferences` surface [BackendPreferences] needs — **without the
/// `secret:` parameter**.
///
/// SEC-01, and the omission is the whole point of the type existing. The
/// concrete `Preferences` carries a `{bool secret = false}` on twelve members
/// (`preferences.dart:277,285,...`) which routes the call to the OS keychain
/// instead of the table. Mirroring it here would turn one client-supplied
/// boolean into remote retrieval of the secure store; the word does not appear
/// in this file and an arm greps for it, because the obvious future edit is to
/// add it back "for symmetry".
///
/// Two members are not on `PreferencesApi` and are here because `clear` needs
/// them:
///
///  * [clearFromMemory] is upstream's own `clear`, named for what it actually
///    does — it empties the memory cache and the local cache and **never
///    touches Postgres** (`preferences.dart:439-442`).
///  * [deletePreferenceRows] is the durable half, in one statement.
abstract interface class PreferenceSource {
  Future<Set<String>> getKeys({Set<String>? allowList});
  Future<Map<String, Object?>> getAll({Set<String>? allowList});
  Future<bool?> getBool(String key);
  Future<int?> getInt(String key);
  Future<double?> getDouble(String key);
  Future<String?> getString(String key);
  Future<List<String>?> getStringList(String key);
  Future<bool> containsKey(String key);
  Future<void> setBool(String key, bool value);
  Future<void> setInt(String key, int value);
  Future<void> setDouble(String key, double value);
  Future<void> setString(String key, String value);
  Future<void> setStringList(String key, List<String> value);
  Future<void> remove(String key);

  /// Upstream's `clear`: the memory and local caches, and nothing durable.
  Future<void> clearFromMemory({Set<String>? allowList});

  /// Deletes the named rows in ONE statement.
  Future<void> deletePreferenceRows(Set<String> keys);

  /// Every key whose value changed through this store.
  Stream<String> get onPreferencesChanged;
}

/// [PreferenceSource] over the backend's own `Preferences`.
///
/// Every call below uses the non-secret overload, which is what it means for
/// the parameter to be absent from the interface above.
final class PreferencesSource implements PreferenceSource {
  const PreferencesSource(this.preferences);

  final store.Preferences preferences;

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      preferences.getKeys(allowList: allowList);
  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      preferences.getAll(allowList: allowList);
  @override
  Future<bool?> getBool(String key) => preferences.getBool(key);
  @override
  Future<int?> getInt(String key) => preferences.getInt(key);
  @override
  Future<double?> getDouble(String key) => preferences.getDouble(key);
  @override
  Future<String?> getString(String key) => preferences.getString(key);
  @override
  Future<List<String>?> getStringList(String key) =>
      preferences.getStringList(key);
  @override
  Future<bool> containsKey(String key) => preferences.containsKey(key);
  @override
  Future<void> setBool(String key, bool value) =>
      preferences.setBool(key, value);
  @override
  Future<void> setInt(String key, int value) => preferences.setInt(key, value);
  @override
  Future<void> setDouble(String key, double value) =>
      preferences.setDouble(key, value);
  @override
  Future<void> setString(String key, String value) =>
      preferences.setString(key, value);
  @override
  Future<void> setStringList(String key, List<String> value) =>
      preferences.setStringList(key, value);
  @override
  Future<void> remove(String key) => preferences.remove(key);
  @override
  Future<void> clearFromMemory({Set<String>? allowList}) =>
      preferences.clear(allowList: allowList);

  @override
  Stream<String> get onPreferencesChanged => preferences.onPreferencesChanged;

  /// One `DELETE`, with the keys bound as placeholders.
  ///
  /// Placeholders rather than an array parameter, following
  /// `preferences_watch.dart:56-63` — the one shape in this repository known
  /// to bind a key list through this driver. Every key is a bound variable,
  /// so nothing a caller supplies is concatenated into the statement.
  ///
  /// A store with no database is a memory-only `Preferences`
  /// (`preferences.dart:216-222` accepts a null one), and there is then
  /// nothing durable to delete. That is not a refusal: the composition root
  /// decides whether this backend has a database, and by the time a
  /// [PreferencesSource] exists the decision has been made.
  @override
  Future<void> deletePreferenceRows(Set<String> keys) async {
    if (keys.isEmpty) return;
    final database = preferences.database;
    if (database == null) return;
    final ordered = keys.toList();
    final placeholders =
        List.generate(ordered.length, (i) => '\$${i + 1}').join(', ');
    await database.db.customUpdate(
      'DELETE FROM flutter_preferences WHERE key IN ($placeholders)',
      variables: [for (final key in ordered) Variable.withString(key)],
      updateKind: UpdateKind.delete,
    );
  }
}

/// `PreferencesApi` over the backend's shared preference store.
///
/// ## The change feed is a merge, and it is listener-gated
///
/// [onPreferencesChanged] is one broadcast controller carrying two things: the
/// store's own stream, and the keys [clear] removed — which the store cannot
/// announce, because its `clear` is memory-only and fires nothing.
///
/// The subscription to the store is taken in `onListen` and dropped in
/// `onCancel`. A feed armed at construction is an always-on subscription in
/// `tfc_dart` plumbing, which is how unrelated widget tests start failing; and
/// a backend with no session connected should be holding nothing open on the
/// store's behalf. One subscription serves every listener, which is what
/// broadcast means and what a settings page plus a chart legend both need.
///
/// ## What this feed does NOT carry
///
/// Changes made by **another process** — an HMI station at SVN writes the
/// preference table directly. `Preferences.onPreferencesChanged` fires only
/// for writes made through that instance (`preferences.dart:154-155`), and the
/// cross-process half is `preferences_watch.dart`'s LISTEN/NOTIFY, which the
/// backend already runs on its own restart-to-apply path. Merging that in here
/// would be a second consumer of the same channel with its own de-duplication
/// window, and it is 13-10's composition decision whether the backend's
/// existing watcher feeds this adapter or a second listen is opened. Recorded
/// rather than quietly half-built. Note also `pg_notify`'s 8000-byte cap: a
/// payload over it errors the firing statement, so whatever carries that news
/// must carry a key and never a value.
final class BackendPreferences implements relay.PreferencesApi {
  BackendPreferences({required this.source});

  /// The production spelling: over the `Preferences` the backend already holds.
  BackendPreferences.overPreferences(store.Preferences? preferences)
      : this(
            source:
                preferences == null ? null : PreferencesSource(preferences));

  final PreferenceSource? source;

  StreamController<String>? _feed;
  StreamSubscription<String>? _upstream;

  @override
  Stream<String> get onPreferencesChanged {
    final store = _store('onPreferencesChanged');
    return (_feed ??= StreamController<String>.broadcast(
      onListen: () => _upstream = store.onPreferencesChanged.listen(
        (key) => _feed?.add(key),
        // A store that errors is not a reason to tear down a session that is
        // otherwise serving the plant. The change is lost, which is the honest
        // outcome — there is nothing here that could re-derive it.
        onError: (Object _) {},
      ),
      onCancel: () async {
        final upstream = _upstream;
        _upstream = null;
        await upstream?.cancel();
      },
    ))
        .stream;
  }

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _store('getKeys').getKeys(allowList: allowList);

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _store('getAll').getAll(allowList: allowList);

  @override
  Future<bool?> getBool(String key) => _store('getBool').getBool(key);

  @override
  Future<int?> getInt(String key) => _store('getInt').getInt(key);

  @override
  Future<double?> getDouble(String key) => _store('getDouble').getDouble(key);

  @override
  Future<String?> getString(String key) => _store('getString').getString(key);

  @override
  Future<List<String>?> getStringList(String key) =>
      _store('getStringList').getStringList(key);

  @override
  Future<bool> containsKey(String key) =>
      _store('containsKey').containsKey(key);

  @override
  Future<void> setBool(String key, bool value) =>
      _store('setBool').setBool(key, value);

  @override
  Future<void> setInt(String key, int value) =>
      _store('setInt').setInt(key, value);

  @override
  Future<void> setDouble(String key, double value) =>
      _store('setDouble').setDouble(key, value);

  @override
  Future<void> setString(String key, String value) =>
      _store('setString').setString(key, value);

  @override
  Future<void> setStringList(String key, List<String> value) =>
      _store('setStringList').setStringList(key, value);

  @override
  Future<void> remove(String key) => _store('remove').remove(key);

  /// Removes every stored preference, or every one [allowList] names.
  ///
  /// **Not a delegation, and this is the one member that could not be.**
  /// Upstream's `clear` empties the memory cache and never touches Postgres
  /// (`preferences.dart:439-442`), so through this backend a delegation would
  /// be a clear that undoes itself: the row is still there, the next rebuild
  /// brings the key back, and nothing anywhere said the call did not do what
  /// it said.
  ///
  /// **One statement and one announcement pass, not a `remove` per key.**
  /// `remove` awaits a round trip, the event loop turns between them, and
  /// `data_handlers._scheduleFlush`'s `Timer.run` fires in every gap — eight
  /// keys measured eight frames, and five hundred keys is a priority-lane
  /// overflow that every operator reads as the network having dropped
  /// (`preference_store.dart:462-477`). So the rows go in one `DELETE`, the
  /// memory cache is emptied by upstream's own `clear` — the one call site
  /// where a memory-only clear is exactly what is wanted — and the keys are
  /// announced with no `await` between them, so the whole burst is pending
  /// before any flush timer can run.
  ///
  /// **The blast radius with no allow list is real and is not narrowed here.**
  /// This deletes `key_mappings` — 518 KiB of routing configuration the whole
  /// plant is served through — from the shared table, and reconnecting does
  /// not bring it back. The interface's own doc says an allow list is highly
  /// recommended. The gate on the call is the relay's `operate` role and
  /// narrowing it further is a policy decision, which lives in the policy
  /// layer, not here: a store that silently declined an unrestricted clear
  /// would be a behaviour nobody could predict from the interface.
  @override
  Future<void> clear({Set<String>? allowList}) async {
    final store = _store('clear');
    final keys = await store.getKeys(allowList: allowList);
    if (keys.isEmpty) return;
    await store.deletePreferenceRows(keys);
    await store.clearFromMemory(allowList: keys);
    final feed = _feed;
    if (feed == null || feed.isClosed) return;
    // No `await` in this loop. That is the whole point — see the doc above.
    for (final key in keys) {
      feed.add(key);
    }
  }

  PreferenceSource _store(String member) =>
      source ??
      (throw UnsupportedError('BackendPreferences.$member is not available: '
          'this backend was composed without a Preferences store, so it has '
          'no shared settings to serve. Give bin/main.dart a database '
          'configuration. It is an UnsupportedError and NOT the StateError '
          'the historian answers with: RelaySession calls watchPreferences() '
          'on every session unconditionally and data_handlers.dart:216 '
          'catches exactly UnsupportedError, so a StateError here would fail '
          'every connect on a backend with no database — which is the default '
          'deployment. Device-local settings are deliberately not on this '
          'pipe either way'));
}
