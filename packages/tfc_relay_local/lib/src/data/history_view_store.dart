/// The eleven `HistoryViewApi` methods over `tfc_dart`'s history tables — the
/// mapping layer between drift's untyped row bags and the wire's records.
///
/// ## This file does not import the database layer, and that is deliberate
///
/// `freeze_test.dart` pins the number of files under this package's `lib/`
/// that import `tfc_dart/core/database*.dart` at **two** — the write adapter
/// (`collect/timescale_sink.dart`) and the read adapter
/// (`data/timescale_reader.dart`) — because `Database`'s constructor starts a
/// flush timer and its connect ladder retries forever, and every additional
/// import site is another place those leak onto the gateway's value path and
/// another place a second connection pool gets built without anyone deciding
/// to (T-10-28).
///
/// A third history-shaped adapter would have been a third site. It is not one:
/// this file takes [DatabaseSupplier] — declared next door in
/// `timescale_reader.dart` — and reaches the drift methods through the value
/// it returns. Dart resolves members on a static type without the type's
/// library being imported, so the seam holds at two and this file still calls
/// `createHistoryView` directly. Nothing is re-declared, nothing is copied,
/// and there is exactly one `Database` in the process.
///
/// The supplier is a supplier for the same two reasons the reader's is: the
/// sink connects in the background and swaps its instance on reconnect, so a
/// pinned instance is stale after the first one, and `null` means the
/// historian is not up — [HistorianUnavailable], retryable, never a hang and
/// never an empty answer. An empty answer here is worse than a refusal: a view
/// picker that says "you have saved nothing" is a picker an operator saves
/// their view into a second time.
///
/// ## The four ways the wire shape and the database shape disagree
///
/// Each of these is a wrong answer that looks like a right one, which is why
/// each has its own paragraph at the site rather than a line in a changelog.
///
/// 1. **drift hands back untyped `Map<String, dynamic>` bags** for keys and
///    graphs (`database_drift.dart:685`, `:704`). Mapped field by field here;
///    no `dynamic` leaves this file.
/// 2. **`createHistoryView` reads its graph map's keys with `int.tryParse` and
///    silently skips whatever fails** (`:610`, and again at `:655` on the
///    update path). The wire type is `Map<int, …>`, so the drop is unreachable
///    from a client — see [graphConfigRows], which is where that claim is made
///    good rather than assumed.
/// 3. **A graph's `name` is nullable in the database and non-nullable on the
///    wire.** [graphConfigRows] and [graphRecordFrom] carry the decision and
///    its consequence.
/// 4. **`getGlobalRetentionHorizon` builds a LOCAL instant and swallows every
///    failure as `null`** (`:774`, `:775-778`). See
///    [HistoryViewStore.getGlobalRetentionHorizon].
///
/// ## PHASE 10 READS AND NEVER WRITES — and what that does not mean
///
/// The sweep over this directory forbids `insertTimeseriesData` and
/// `registerRetentionPolicy`: no sample is recorded here and no retention
/// policy is installed, uninstalled or reinstalled from the read path, which
/// is the two-writer fight 8b settled while the application's own collector
/// still runs. Saving a *view* is not historising: it writes four small
/// configuration tables the application's HMI has always written, and
/// `HistoryViewApi` is four-fifths mutators.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show
        DataServiceMethods,
        HistoryViewApi,
        HistoryViewGraphRecord,
        HistoryViewKeyRecord,
        HistoryViewPeriodRecord,
        HistoryViewRecord,
        ResultTooLarge;

import 'read_limits.dart';
import 'timescale_reader.dart' show DatabaseSupplier, HistorianUnavailable;

/// `HistoryViewApi` over the four history tables.
final class HistoryViewStore implements HistoryViewApi {
  HistoryViewStore({required this.database, this.log, ReadLimits? limits})
      : limits = limits ?? ReadLimits();

  /// The shared instance, borrowed per call. See the library doc.
  final DatabaseSupplier database;

  /// The outbound ceilings. See `read_limits.dart` for the arithmetic.
  final ReadLimits limits;

  /// Where a swallowed failure goes. Optional and injected, following
  /// `IngestLog`'s shape: a store constructed in a test asserts what it was
  /// told, and one constructed by `bin/relay_gateway.dart` writes to the
  /// gateway's logger. Null is a gateway that says nothing, which is the
  /// right default for a fixture and the wrong one for a plant — the
  /// composition root supplies it.
  final void Function(String message)? log;

  @override
  Future<int> createHistoryView(String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) async {
    // Already one transaction upstream (database_drift.dart:588).
    return (database() ?? _noHistorian()).db.createHistoryView(
        name, keys, keyConfigRows(keyConfigs), graphConfigRows(graphConfigs));
  }

  @override
  Future<void> updateHistoryView(int id, String name, List<String> keys,
      [Map<String, HistoryViewKeyRecord>? keyConfigs,
      Map<int, HistoryViewGraphRecord>? graphConfigs]) async {
    // Also already one transaction upstream (`:632`), which is what makes the
    // delete-then-reinsert of every key and graph row safe. The ids of those
    // rows are NOT stable across an update, and nothing on the wire claims
    // they are — the records carry the key and the graph index, which are the
    // identities a caller can hold.
    return (database() ?? _noHistorian()).db.updateHistoryView(
        id, name, keys, keyConfigRows(keyConfigs), graphConfigRows(graphConfigs));
  }

  /// Deletes view [id] and everything recorded against it, atomically.
  ///
  /// **The transaction is added here, and this is the decision the plan asked
  /// to have made either way.** Upstream's `deleteHistoryView`
  /// (`database_drift.dart:672-678`) issues four separate statements with no
  /// transaction around them, under a comment saying the keys cascade. Both
  /// halves of that are true at once, and the combination is why it has not
  /// bitten yet: the three child tables really do declare
  /// `REFERENCES history_view(id) ON DELETE CASCADE`, so on Postgres the
  /// *first* statement already does the whole job and the other three match
  /// nothing. The failure mode is therefore narrow — a connection lost between
  /// statements two and four on a deployment where the cascade is not in force
  /// (SQLite with `foreign_keys` off, or a schema built by a migration path
  /// that skipped the constraint) leaves a view deleted from the picker with
  /// its keys, graphs and periods still on disk, reachable by nothing and
  /// deletable by nothing.
  ///
  /// One transaction costs one round trip and removes the mode entirely,
  /// without depending on which dialect is underneath or on whether a
  /// constraint survived a migration. The contract asserts the delete is total
  /// (`data_services_contract.dart:307-317`) and a partial delete would pass
  /// that contract on a good day, which is the shape of bug this project
  /// exists to refuse.
  @override
  Future<void> deleteHistoryView(int id) async {
    final db = (database() ?? _noHistorian()).db;
    return db.transaction(() => db.deleteHistoryView(id));
  }

  @override
  Future<List<HistoryViewRecord>> selectHistoryViews() async {
    final rows = await (database() ?? _noHistorian()).db.selectHistoryViews();
    _bound(rows.length, 'history.selectViews',
        'the view picker lists every saved chart on this gateway');
    return [
      for (final row in rows)
        HistoryViewRecord(
          id: row.id,
          name: row.name,
          // `.toUtc()`, both here and below. drift stamps these with a
          // `clientDefault(() => DateTime.now())` — a LOCAL instant. The
          // instant itself is right either way (epoch milliseconds do not
          // care about the flag), but `DateTime ==` compares the flag as well
          // as the value, so a local-flagged createdAt is never equal to the
          // UTC one the record decodes back to, and anything that formats it
          // with `toIso8601String` emits a wall clock with no zone on it.
          createdAt: row.createdAt.toUtc(),
          updatedAt: row.updatedAt?.toUtc(),
        ),
    ];
  }

  @override
  Future<Map<String, HistoryViewKeyRecord>> getHistoryViewKeys(int viewId) async {
    final rows = await (database() ?? _noHistorian()).db.getHistoryViewKeys(viewId);
    _bound(rows.length, 'history.getKeys', 'view $viewId plots that many keys');
    return {
      for (final entry in rows.entries)
        entry.key: keyRecordFrom(entry.key, entry.value),
    };
  }

  @override
  Future<Map<int, HistoryViewGraphRecord>> getHistoryViewGraphs(
      int viewId) async {
    final rows = await (database() ?? _noHistorian()).db.getHistoryViewGraphs(viewId);
    _bound(rows.length, 'history.getGraphs',
        'view $viewId carries that many graphs');
    return {
      for (final entry in rows.entries)
        entry.key: graphRecordFrom(entry.key, entry.value),
    };
  }

  /// The key names of view [viewId], in whatever order the database returns.
  ///
  /// **Delegated, and deliberately not sorted.** Neither this query nor
  /// `getHistoryViewKeys` carries an `ORDER BY` upstream, so both answer in
  /// the database's order — which for a freshly written view is insertion
  /// order and is not promised to be anything. Imposing an order here would
  /// make this accessor disagree with the record accessor, which is the one
  /// thing a caller holding both can actually notice. What is asserted in
  /// `history_view_read_test.dart` is therefore that the two agree and that
  /// neither moves between calls; a caller that needs a deterministic order
  /// has to sort, and now has this sentence saying so.
  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async {
    final names =
        await (database() ?? _noHistorian()).db.getHistoryViewKeyNames(viewId);
    _bound(names.length, 'history.getKeyNames',
        'view $viewId plots that many keys');
    return names;
  }

  @override
  Future<int> addHistoryViewPeriod(
      int viewId, String name, DateTime start, DateTime end) async {
    // Normalised to UTC on the way down as well as on the way up. drift
    // parameterises these two, so the instant would survive either way — but
    // the boundary rule is the rule precisely because the places that do NOT
    // parameterise (`database.dart` interpolates bucket bounds as bare ISO
    // strings with no zone, which 10-07 had to work around) are not visible
    // from the call site.
    return (database() ?? _noHistorian())
        .db
        .addHistoryViewPeriod(viewId, name, start.toUtc(), end.toUtc());
  }

  @override
  Future<void> deleteHistoryViewPeriod(int id) async {
    return (database() ?? _noHistorian()).db.deleteHistoryViewPeriod(id);
  }

  /// Every saved window on [viewId], oldest first.
  ///
  /// **The ordering is added here, and unlike [getHistoryViewKeyNames] it is
  /// not optional.** `HistoryViewApi.listHistoryViewPeriods` says "oldest
  /// first" in as many words (`state_man_api.dart:341`) and the upstream query
  /// carries no `ORDER BY`, so somebody owes it; the store is the last place
  /// that can pay before the wire. Sorted by [HistoryViewPeriodRecord.startAt]
  /// and tie-broken by id, so two windows saved over the same instant come
  /// back in the order they were created rather than in an order that changes
  /// between calls.
  ///
  /// Every instant is `.toUtc()`'d, and the three of them for one reason: the
  /// wire is UTC epoch milliseconds everywhere, `DateTime ==` compares the
  /// `isUtc` flag as well as the value, and `createdAt` is stamped by drift
  /// with a local `DateTime.now()`. A window that came back an hour off would
  /// land an operator on the wrong shift, and every conclusion they drew from
  /// the chart would be about the wrong hours.
  @override
  Future<List<HistoryViewPeriodRecord>> listHistoryViewPeriods(
      int viewId) async {
    final rows =
        await (database() ?? _noHistorian()).db.listHistoryViewPeriods(viewId);
    _bound(rows.length, 'history.listPeriods',
        'view $viewId has that many saved windows');
    final periods = [
      for (final row in rows)
        HistoryViewPeriodRecord(
          id: row.id,
          viewId: row.viewId,
          name: row.name,
          startAt: row.startAt.toUtc(),
          endAt: row.endAt.toUtc(),
          createdAt: row.createdAt.toUtc(),
        ),
    ];
    periods.sort((a, b) {
      final byStart = a.startAt.compareTo(b.startAt);
      return byStart != 0 ? byStart : a.id.compareTo(b.id);
    });
    return periods;
  }

  /// The oldest instant any series is still retained for, in **UTC**, or null
  /// when nothing has been discarded yet.
  ///
  /// ## Mismatch 3: the instant is local upstream and the wire is UTC
  ///
  /// `getGlobalRetentionHorizon` builds `DateTime.now().subtract(maxDur)`
  /// (`database_drift.dart:774`), which is local-flagged. The moment itself is
  /// right — epoch milliseconds do not care about the flag — but `DateTime ==`
  /// compares the flag, and anything that renders the value with
  /// `toIso8601String` emits a wall clock with no zone on it. A chart that
  /// draws its "no data before here" line from a horizon read as local when it
  /// is UTC puts the line an hour or thirteen off, and an operator scrolling
  /// past it sees absence of data as absence of events. `.toUtc()` here, at
  /// the boundary, is the whole fix.
  ///
  /// ## Mismatch 4: null is three different answers, and only one of them is
  /// good news
  ///
  /// Upstream returns null for **"no retention policy is installed"**, for
  /// **"the jobs view could not be read"** (no permissions, or a database that
  /// is not TimescaleDB at all) and for **"the connection is gone"** — one
  /// blanket `catch (_) { return null; }` at `:775-778`. On the wire, null
  /// means *nothing has been discarded yet*, which is the opposite of what a
  /// permissions failure should imply
  /// (`client_sub_apis.dart:398-408`: "'Nothing has been discarded yet' and
  /// 'everything since the epoch is gone' are opposite answers").
  ///
  /// **The answer is not widened and the catch is not widened.** Null stays
  /// null: a new exception type reaching the wire is a client-visible change,
  /// 10-04 already decided the wire shape, and every existing client reads
  /// null as "no horizon". What changes is that the gateway stops being
  /// *silent* about which null it just produced. On a null answer — and only
  /// then, so the ordinary case costs nothing — one cheap probe asks whether
  /// `timescaledb_information.jobs` can be read at all:
  ///
  ///  * the probe **succeeds** → the jobs view is readable and holds no
  ///    retention policy this gateway can parse. That is genuinely "nothing
  ///    has been discarded yet", and it is logged as nothing at all: a line
  ///    per panel per open is a log that rotates away the evidence of
  ///    everything else.
  ///  * the probe **throws** → the null was a failure, and the failure is
  ///    logged with the exception that caused it.
  ///
  /// **What the probe cannot do, said plainly rather than glossed:** it is a
  /// second query at a second moment, so a horizon query that failed
  /// transiently and a probe that then succeeded is reported as "no policy".
  /// The two cannot be told apart from outside without upstream distinguishing
  /// them itself, which would be a change to `tfc_dart` that this phase does
  /// not make. The narrowing is from three indistinguishable causes to two,
  /// and the one it separates out — a permissions failure or a non-Timescale
  /// database, the causes that persist — is the one an operator can act on.
  @override
  Future<DateTime?> getGlobalRetentionHorizon() async {
    final db = (database() ?? _noHistorian()).db;
    final horizon = await db.getGlobalRetentionHorizon();
    if (horizon != null) return horizon.toUtc();

    try {
      await db.customSelect('SELECT 1 FROM timescaledb_information.jobs '
          'LIMIT 1').get();
    } catch (error) {
      // **The type, not the object** (10-REVIEW WR-08). A `postgres` driver
      // exception routinely carries the host, the port, the database name and
      // the role in its `toString()`; `timescale_sink.dart` sanitises its
      // equivalents and this did not, with no reason given at the site. The
      // exposure is whoever reads the gateway's logs, which at SVN is a wider
      // set than whoever holds the database credential.
      //
      // Nothing actionable is lost. The four remedies the sentence already
      // names are what an engineer does next; the connection string adds
      // nothing to any of them, and the value returned to the wire stays null
      // either way.
      log?.call('the retention horizon could not be determined and is being '
          'reported as "nothing has been discarded yet", which may be wrong: '
          'reading timescaledb_information.jobs failed with '
          '${error.runtimeType}. A chart will draw no horizon line at all. '
          'Check that this database is TimescaleDB, that the gateway\'s role '
          'may read the jobs view, and that the connection is up');
    }
    return null;
  }

  /// Refuses, retryably, when the composition is holding no `Database`.
  ///
  /// **Every method here is `async`, including the ones whose body is one
  /// delegation, and that is what makes this refusal a rejected `Future`
  /// rather than a synchronous throw.** A `Future`-returning method that
  /// throws before returning one is caught by an `await` inside a `try` and
  /// missed by everything else — `store.selectHistoryViews().catchError(…)`
  /// would not see it, and neither would a caller holding the future to
  /// combine later. `TimescaleReader` is `async` throughout for the same
  /// reason; a test in `history_view_store_test.dart` calls all eleven with
  /// no historian and would fail on the first one that threw early.
  ///
  /// Spelled as a `Never`-returning helper on the right of a `??` rather than
  /// as a method that returns the database, and the reason is the whole trick
  /// this file turns: `database() ?? _noHistorian()` has the static type
  /// [DatabaseSupplier] declares, by inference, so every drift call below is
  /// statically checked — while a method here that *named* that type in its
  /// signature would need the import, and the import is the third seam site
  /// the freeze forbids. A `dynamic` return would have kept the seam and
  /// thrown the checking away, which is the trade this avoids rather than
  /// makes.
  Never _noHistorian() => throw HistorianUnavailable();

  /// Refuses an answer of [rows] rows, naming what they are.
  ///
  /// ## Why these reads need a ceiling at all (10-REVIEW WR-05)
  ///
  /// The five history reads answer into the session's **priority lane**, which
  /// is un-conflated: `SessionSink.add` appends whatever it is handed, and
  /// `_Connection.flushPriority` writes the whole lane out *before* the 4004
  /// on the way to a close. So an over-large answer here is not a slow chart,
  /// it is an eviction — and the panel is told it disconnected when what
  /// happened is that it asked for too much. That is exactly the misreport
  /// [ResultTooLarge] exists to prevent, and until this landed these five had
  /// no ceiling anywhere.
  ///
  /// What made it reachable rather than theoretical is that the row counts are
  /// **caller-grown**: `historyCreateView` and `historyAddPeriod` create rows,
  /// and until 10-REVIEW CR-03 they took no role and they still take no quota.
  ///
  /// ## The honest residual: measured after the fetch, not before
  ///
  /// `TimescaleReader._read` detects with `LIMIT budget + 1`, so nothing over
  /// the cap is ever materialised. **This cannot.** The five upstream methods
  /// (`database_drift.dart`'s `selectHistoryViews`, `getHistoryViewKeys`,
  /// `getHistoryViewGraphs`, `getHistoryViewKeyNames`,
  /// `listHistoryViewPeriods`) take no `LIMIT` parameter, and adding one is a
  /// `tfc_dart` change this cycle does not make. So the rows are in this
  /// process's memory by the time they are counted.
  ///
  /// That is a real weakening and it is written here rather than left for
  /// somebody to discover: what this closes is the **wire** half — an eviction
  /// reported as backpressure becomes a named refusal a panel can act on — and
  /// not the heap half. The heap half is bounded by the same thing that bounded
  /// it before, which is that these rows are small; 5 000 of them is 600 KB.
  /// A `LIMIT` parameter upstream is the complete fix and is the follow-up.
  ///
  /// [measured] is therefore **exact**, so [ResultTooLarge.atLeast] is not set
  /// — the opposite of the reader's row refusals, and for this reason.
  void _bound(int rows, String method, String what) {
    if (rows <= limits.maxHistoryViewRows) return;
    throw ResultTooLarge.rows(
      limit: limits.maxHistoryViewRows,
      measured: rows,
      detail: '$what. History-view rows are created by clients, so this is a '
          'count somebody grew rather than one the plant produced — the fix '
          'is usually to delete saved charts nobody opens, not to widen a '
          'window',
      // There is no narrower method to name: unlike a timeseries window, a
      // picker has no downsampled form. The honest suggestion is the delete
      // that makes the answer small again.
      suggestion: DataServiceMethods.historyDeleteView,
    );
  }
}

/// The key configurations, as the untyped bag drift's writers take.
///
/// Null stays null: drift distinguishes "the caller said nothing about the
/// configurations" from "the caller said there are none" by a null check, and
/// collapsing the two here would be this file inventing behaviour rather than
/// wrapping it.
///
/// The `alias` written is the record's own, which is **never null**:
/// `HistoryViewKeyRecord`'s constructor has already substituted the key for an
/// absent alias, mirroring drift's `row.alias ?? row.key`. That default is
/// implemented **once**, in the protocol package, and this file re-derives
/// nothing — two implementations of one default is one too many, and the
/// contract asserts the protocol's (`data_services_contract.dart:294-296`).
///
/// The consequence, said out loud because it is not recoverable afterwards:
/// the wire cannot express "this key has no alias", only "its alias equals its
/// key". A row written for a key with no alias holds `alias = key`, exactly as
/// the application's own HMI has always written it.
Map<String, Map<String, dynamic>>? keyConfigRows(
    Map<String, HistoryViewKeyRecord>? configs) {
  if (configs == null) return null;
  return {
    for (final entry in configs.entries)
      entry.key: <String, dynamic>{
        'alias': entry.value.alias,
        'useSecondYAxis': entry.value.useSecondYAxis,
        'graphIndex': entry.value.graphIndex,
      },
  };
}

/// The graph configurations, keyed by the String drift parses back to an int.
///
/// **This function is where mismatch 2 is answered.** `createHistoryView` does
/// `int.tryParse(entry.key)` and skips the entry when it returns null, with no
/// error and no count — a chart saved with four graphs comes back with three
/// and nothing anywhere says which one went. The wire type is `Map<int, …>`,
/// so the only keys that can reach here are ints and `'$index'` is total over
/// them; `history_view_store_test.dart` asserts that rather than assuming it,
/// across both ends of the VM's int range. **Anything that widens this
/// parameter to accept a String key makes the silent drop reachable again.**
///
/// **Mismatch 3, and the decision.** The column is `text().nullable()` and the
/// wire record's `name` is a non-nullable `String` defaulting to `''` — the
/// protocol package already collapsed the two, mirroring drift's own
/// `row.name ?? ''`, so the pair cannot be told apart after a round trip
/// whichever way this maps. Given that, the empty string is written as
/// **NULL**: the application's own HMI reads these rows directly and NULL is
/// what it has always found there, so writing `''` would invent a third state
/// in a table this gateway does not own. The consequence is that a graph
/// deliberately named with the empty string and a graph never named are the
/// same row; if a legend ever needs to tell them apart, the record's field has
/// to become nullable in the protocol package first, and that is a wire change
/// rather than a store change.
Map<String, Map<String, dynamic>>? graphConfigRows(
    Map<int, HistoryViewGraphRecord>? configs) {
  if (configs == null) return null;
  return {
    for (final entry in configs.entries)
      '${entry.key}': <String, dynamic>{
        'name': entry.value.name.isEmpty ? null : entry.value.name,
        'yAxisUnit': entry.value.yAxisUnit,
        'yAxis2Unit': entry.value.yAxis2Unit,
      },
  };
}

/// One row of `getHistoryViewKeys`' bag as the record it stands for.
///
/// [key] comes from the map key rather than from the bag: it is the identity
/// the caller addresses the row by, and reading it out of the bag as well
/// would be a second source for one fact.
///
/// `alias` is passed through **as it arrives, including null**, so the
/// record's constructor applies the default. drift has usually applied it
/// already (`row.alias ?? row.key`); passing the null on rather than
/// second-guessing it is what keeps the default in one place.
HistoryViewKeyRecord keyRecordFrom(String key, Map<String, dynamic> row) =>
    HistoryViewKeyRecord(
      key: key,
      alias: row['alias'] as String?,
      useSecondYAxis: row['useSecondYAxis'] as bool? ?? false,
      graphIndex: (row['graphIndex'] as num?)?.toInt() ?? 0,
    );

/// One row of `getHistoryViewGraphs`' bag as the record it stands for.
///
/// [graphIndex] comes from the map key, because the bag does not carry it —
/// a record built with 0 instead would put every graph on the first axis.
///
/// The three `?? ''` defaults mirror drift's own and the record's own; see
/// [graphConfigRows] for the null-versus-empty decision they implement.
HistoryViewGraphRecord graphRecordFrom(int graphIndex, Map<String, dynamic> row) =>
    HistoryViewGraphRecord(
      graphIndex: graphIndex,
      name: row['name'] as String? ?? '',
      yAxisUnit: row['yAxisUnit'] as String? ?? '',
      yAxis2Unit: row['yAxis2Unit'] as String? ?? '',
    );
