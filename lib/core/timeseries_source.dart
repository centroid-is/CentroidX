/// Where a chart's history comes from — the one seam both transports answer.
///
/// ## The gap this closes
///
/// `TimeseriesKeyTracker.start()` opened with
/// `final db = await _database(); if (db == null || !_alive) return;`, and
/// every other timeseries call site in the app did the same shape:
/// `ref.read(databaseProvider.future)`, then `db.queryTimeseriesData(...)`.
///
/// On a gateway-mode panel `databaseProvider` answers **null by design** —
/// `lib/providers/database.dart` branches on the transport before it reads the
/// config row, because the backend is the only process that may touch
/// TimescaleDB. So on every gateway panel that guard was the whole of the
/// timeseries surface: the tracker returned before subscribing, the charts
/// returned before querying, and nothing anywhere said so. A plant that had
/// been recording all week rendered as a plant with no history — an empty
/// answer presented as a fact, which is the failure class this milestone
/// exists to remove.
///
/// The wire has carried the three reads since Phase 10 plan 03
/// (`DataServiceMethods.timeseriesMethods`). Nothing in the app called them.
///
/// ## Why an interface rather than a nullable `Database` everywhere
///
/// The call sites do not want a database; they want three questions answered.
/// Handing them a `Database?` is what made the transport branch invisible —
/// null had one meaning ("Postgres is not up, try later") and silently
/// acquired a second ("this station has no database and never will"). Two
/// facts behind one null is how the bug survived. [TimeseriesSource] is the
/// question, and the two implementations below are the two answers.
///
/// ## Server-side gating
///
/// Nothing here checks a permission, deliberately. The relayed reads go
/// through the gateway's `PolicyStateMan._PolicyTimeseries`, which resolves
/// each series name to its plant key and drops the ones this station may not
/// see (`policy_state_man.dart:752`, pinned by
/// `packages/tfc_relay_server/test/policy_test.dart`). Authorisation is
/// enforced server-side — Jón's hard requirement — and a second check here
/// would be a second policy, which `test/core/no_second_policy_test.dart`
/// exists to refuse.
///
/// ## What a failure must look like
///
/// **Throw. Never answer an empty list.** `[]` is what a tag that has recorded
/// nothing looks like, and a chart cannot tell the two apart — the same rule
/// `relay_alarm_source.dart`'s `getRecentAlarms` carries, for the same
/// measured reason. The direct implementation keeps `Database`'s own
/// behaviour, which already throws on a failed query.
library;

import 'dart:async';

import 'package:tfc_dart/core/database.dart' as db;
import 'package:tfc_dart/core/database_drift.dart' as drift;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// One historised row a source observed being appended.
///
/// A record rather than the raw NOTIFY payload: the payload is a Postgres
/// implementation detail (a JSON string with an `action` discriminator), and
/// the relay has no payload at all. What a reader needs from a push is the two
/// fields, so the seam carries the two fields.
typedef TimeseriesInsert = ({DateTime time, Object? value});

/// The three historical reads, plus the push channel where there is one.
///
/// The three query members are `Database`'s own signatures verbatim — same
/// names, same positional arguments, same defaults — so porting a call site is
/// a change of receiver and nothing else. They are also, field for field,
/// `tfc_relay_protocol`'s `TimeseriesApi`; that is not a coincidence, it is
/// what makes the relayed implementation a translation rather than a
/// re-interpretation.
abstract interface class TimeseriesSource {
  /// Samples for one series from [to] onwards, or within `[from, to]` when
  /// [from] is given.
  ///
  /// The second positional argument is named `to` for `Database`'s reason and
  /// is a *lower* bound when [from] is null (`database.dart:1454-1459` queries
  /// `time >= to`). Confusing, carried verbatim on purpose: the app, the wire
  /// and the backend all mean the same thing by it, and renaming it here would
  /// make this the one place they disagree.
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
      String tableName, DateTime to,
      {String? orderBy = 'time ASC', DateTime? from});

  /// The same window for several series, keyed by series name.
  ///
  /// **One entry per requested table.** An absent entry and an empty entry are
  /// different answers, and a chart that iterates the names it asked for drops
  /// a missing one from its legend — which an operator reads as "this tag is
  /// flat" rather than as "nothing was recorded".
  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from});

  /// At most [maxPoints] samples spanning the window, bucketed where the data
  /// is.
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
      String tableName, DateTime from, DateTime to, {int maxPoints = 1000});

  /// Live appends to [tableName], or **null** when this transport has no push
  /// channel at all.
  ///
  /// Three states, and the third is the one worth the parameter:
  ///
  ///  * a stream — the channel is open and rows will arrive on it;
  ///  * a **throw** — this transport pushes, but the channel could not be
  ///    opened right now (the table does not exist yet, the connection is
  ///    down). A caller retries, with backoff;
  ///  * **null** — this transport does not push and never will. A caller
  ///    polls, on purpose, and does not warn about it.
  ///
  /// Collapsing the third into the second is what would make a gateway panel
  /// log a re-subscribe warning on every sweep, forever, about a channel that
  /// was never coming — and a fault line that cries wolf is a fault line
  /// nobody reads.
  Future<Stream<TimeseriesInsert>?> liveInserts(String tableName);
}

// -----------------------------------------------------------------------------
// Direct mode: this station's own Postgres
// -----------------------------------------------------------------------------

/// [TimeseriesSource] over the station's own database — direct mode, unchanged.
///
/// Every member forwards. The point of the class is not what it adds but that
/// it exists: with it, `Database` stops being spelled at eight call sites, and
/// the transport branch happens once, in a provider, where it can be read.
final class DatabaseTimeseriesSource implements TimeseriesSource {
  const DatabaseTimeseriesSource(this.database);

  final db.Database database;

  /// Two sources over the same handle are the same source.
  ///
  /// **Load-bearing, and it was measured.** `timeseriesSourceProvider` mints a
  /// fresh wrapper on every rebuild, and a rebuild happens for reasons that
  /// have nothing to do with the connection — an invalidate, a settings save
  /// on an unrelated field. Consumers use "is this a source I am not already
  /// on?" to decide whether to tear down and refetch, and under reference
  /// identity every such rebuild answered yes: a full-window refetch and a
  /// dropped-and-recreated NOTIFY trigger per key, on a station whose database
  /// never went anywhere. `database_recovery_test.dart`'s "does not re-fire
  /// for the same database instance" is the arm that says so.
  @override
  bool operator ==(Object other) =>
      other is DatabaseTimeseriesSource &&
      identical(other.database, database);

  @override
  int get hashCode => identityHashCode(database);

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

  /// Opens the table's LISTEN/NOTIFY channel and decodes the inserts off it.
  ///
  /// Non-insert notifications and payloads with no `time` are dropped here
  /// rather than at the caller: they are not appends, and the seam's contract
  /// is appends. A failure to open — the table does not exist yet, the
  /// connection is down — **throws**, which is the retry-with-backoff signal
  /// [TimeseriesSource.liveInserts] documents; it is never flattened to null,
  /// which would tell the caller this station has no push channel.
  @override
  Future<Stream<TimeseriesInsert>?> liveInserts(String tableName) async {
    final channel = await database.db.enableNotificationChannel(tableName);
    return database.db.listenToChannel(channel).transform(
        StreamTransformer<String, TimeseriesInsert>.fromHandlers(
            handleData: (payload, sink) {
      final notification = drift.NotificationData.fromJson(payload);
      if (notification.action != drift.NotificationAction.insert) return;
      final raw = notification.data['time'];
      if (raw == null) return;
      sink.add((
        time: raw is DateTime ? raw : DateTime.parse('$raw'),
        value: notification.data['value'],
      ));
    }));
  }
}

// -----------------------------------------------------------------------------
// Gateway mode: the backend's TimescaleDB, over the pipe
// -----------------------------------------------------------------------------

/// [TimeseriesSource] over the relay — the gateway panel's only route to
/// history.
///
/// A translation and nothing more: three sends, and the protocol's sample type
/// becoming the app's again on the way back. No cache, no retry, no fallback
/// to a database — a route that exists will be taken, and the local one must
/// not exist here.
///
/// **It does not catch.** A gateway that could not answer is the caller's to
/// show; converting that into an empty sample list would report a fact about
/// the wire as a fact about the factory. See the library doc.
final class RelayedTimeseriesSource implements TimeseriesSource {
  const RelayedTimeseriesSource(this._api);

  final rp.TimeseriesApi _api;

  /// Two sources over the same client are the same source — see
  /// [DatabaseTimeseriesSource.==] for why this is not cosmetic. `RemoteStateMan`
  /// builds its `timeseries` proxy once and keeps it, so the identity of the
  /// proxy is the identity of the link behind it: a rebuild of this provider
  /// over a live client is not a new client, and must not cost every chart on
  /// the panel a full refetch.
  @override
  bool operator ==(Object other) =>
      other is RelayedTimeseriesSource && identical(other._api, _api);

  @override
  int get hashCode => identityHashCode(_api);

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      _samples(await _api.queryTimeseriesData(tableName, to,
          orderBy: orderBy, from: from));

  @override
  Future<Map<String, List<db.TimeseriesData<dynamic>>>>
      queryTimeseriesDataMultiple(List<String> tableNames, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async {
    final answers = await _api.queryTimeseriesDataMultiple(tableNames, to,
        orderBy: orderBy, from: from);
    // Keyed off the request, not off the answer. The gateway already builds
    // one entry per requested series for this exact reason
    // (`data_handlers.dart:334-348`); rebuilding it here means a policy filter
    // or a future short answer cannot silently delete a line from a legend.
    return {
      for (final table in tableNames) table: _samples(answers[table] ?? const []),
    };
  }

  @override
  Future<List<db.TimeseriesData<dynamic>>> queryTimeseriesDataDownsampled(
          String tableName, DateTime from, DateTime to,
          {int maxPoints = 1000}) async =>
      _samples(await _api.queryTimeseriesDataDownsampled(tableName, from, to,
          maxPoints: maxPoints));

  /// Null, always: the pipe carries no LISTEN/NOTIFY.
  ///
  /// Not an oversight and not a gap to be filled later with a subscription to
  /// the plant value. `subscribe` delivers what the tag reads *now*; a
  /// historised row is what the collector *wrote*, and the two are neither the
  /// same instants nor the same values. Feeding live tag values into a
  /// timeseries cache would invent history rows that are in no database, and a
  /// counting readout over them would answer a number no query can reproduce.
  @override
  Future<Stream<TimeseriesInsert>?> liveInserts(String tableName) async => null;

  /// The protocol's samples as the type the charts draw.
  static List<db.TimeseriesData<dynamic>> _samples(
          List<rp.TimeseriesData> raw) =>
      [for (final point in raw) db.TimeseriesData(point.value, point.time)];
}
