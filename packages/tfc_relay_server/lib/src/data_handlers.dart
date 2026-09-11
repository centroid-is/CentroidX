/// The bodies of the data-service methods: browse, timeseries, history views,
/// and — from 10-05 — preferences.
///
/// Same rule as `value_handlers.dart` and `session_handlers.dart`, for the same
/// reason: **nothing in here registers anything.** Handlers are handed to
/// `RelaySession._on`, which is the one seam where a method enters the table
/// and therefore the one place the handshake gate and the error armor are
/// applied. A handler that registered itself would be a handler that arrived
/// ungated, and an ungated `browse.fetchRoots` is the plant's whole address
/// space enumerated by a peer that never authenticated. A grep for the peer's
/// registration call over this file is meant to come back empty.
///
/// ## The bodies are copied from the contract kit, never imported
///
/// The contract kit's `served_state_man.dart:482-510` already serves these four
/// methods correctly over its own channel, and this file is a deliberate copy
/// of them rather than a call into it. `handler_table_test.dart:264-296` sweeps
/// this package's production `lib/` for the kit's package name and requires
/// **zero** hits — including in prose, which is why the name is not written
/// anywhere in this file. It is a **dev** dependency, the harness a test suite
/// runs against, and a gateway that imported its test kit at runtime would ship
/// the fake plant, the seeding levers and the fault injectors into the plant.
///
/// So the duplication is the point, and the two copies are expected to drift
/// only where the wire differs: the kit wraps every body in its own `_answer`,
/// and this one does not, because `RelaySession._on` already supplies exactly
/// that armor (`relay_session.dart:813-835`).
///
/// ## What a refusal here looks like
///
/// `_refuse`, copied in shape from `value_handlers.dart:883-885`: the general
/// `RpcException` constructor with INVALID_PARAMS and a **pre-substituted**
/// `data`, never `RpcException.invalidParams`, which takes no `data` — and a
/// refusal with no `data` is exactly the one `serialize` fills in for you with
/// the offending request. One request carrying `1e999` then makes the error
/// itself unencodable, the peer drops it, and a caller with no deadline waits
/// forever (the 02-05 hang).
library;

import 'dart:async';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'server_config.dart';

/// How this object announces something to the client, and the only thing it
/// can do to the peer.
///
/// A callback rather than the `rpc.Peer` itself, and the narrowness is the
/// point: this file's first rule is that **nothing in here registers
/// anything**, and a peer in scope is a peer something could call
/// `registerMethod` on. What `RelaySession` passes is a closure that sends one
/// notification and refuses to send anything at all before `hello`, before
/// which there is no station the gateway can name.
typedef PreferenceNotifier = void Function(
    String method, Map<String, Object?> params);

/// The handler bodies for one session's data-service methods.
///
/// Holds no state of its own: every answer is the source's, encoded. The
/// hiding rule is **not** applied here — it lives one layer down, in
/// `PolicyStateMan`'s `_PolicyBrowse`, so that a handler added by a later plan
/// cannot forget it (T-06-38). What this object is handed is already the
/// policed view.
final class DataHandlers {
  DataHandlers({
    required this.source,
    required this.config,
    required this.resolver,
    required this.notify,
  });

  /// The source being served, already seen through this session's policy.
  ///
  /// **Named `source`, and it must not be renamed to `api`.** The same pin
  /// `policy_state_man.dart:97-104` records:
  /// `tfc_relay_client/test/no_retry_test.dart:216-262` counts `api.write(`,
  /// `api.holdToRun(` and `hold.release(` over this package's `lib/` at
  /// exactly one occurrence each, because those are the gateway's only
  /// crossings into the plant and a second one is a second actuation. None of
  /// the thirty-four data-service methods writes to the plant, so the hazard
  /// here is purely the name — and the failure it produces is a message about
  /// *retries* on a file that has nothing to do with retrying.
  final StateManApi source;

  /// Where this gateway's per-request bounds live.
  ///
  /// The timeseries family is the first data-service family whose arguments
  /// scale the work the *database* does — `maxPoints`, `howMany` and
  /// `intervalMs` all multiply a query's cost, and `tables` multiplies the
  /// number of queries — so it is the first that needs the same ceilings
  /// `subscribe` and `readMany` already have. `browse` needed none: its
  /// arguments are one node each.
  final ServerConfig config;

  /// How a node id and a table name become a plant key.
  ///
  /// Held here and **not consulted by the four browse handlers**: a
  /// `BrowseNode` id is an upstream address-space identifier rather than a
  /// plant key (`client_sub_apis.dart:179-183`), and turning one into a key so
  /// `canSee` can be asked is `_PolicyBrowse`'s job, one layer down, where a
  /// handler added by a later plan cannot forget it. What reads this field is
  /// 10-03's timeseries family, which is keyed by table and has no other way
  /// to find the key its samples belong to.
  ///
  /// Required, with no default, all the way up to `RelayServer` — see that
  /// class's `resolver` parameter for the argument.
  final SeriesResolver resolver;

  /// How this object tells its client that a preference moved.
  ///
  /// See [PreferenceNotifier] for why it is a callback and not the peer, and
  /// [watchPreferences] for what is sent through it.
  final PreferenceNotifier notify;

  // ------------------------------------------------------- preference change

  /// This session's listener on the shared preference store.
  ///
  /// Null before [watchPreferences] runs, after [releasePreferenceWatch], and
  /// for a source that declares no preference store at all.
  StreamSubscription<String>? _preferenceChanges;

  /// The keys that have moved since the last flush.
  ///
  /// **A set, not a list.** A key written twice while an operator held a
  /// slider is one key that changed, and a frame naming it twice makes every
  /// listener on the far side redraw twice.
  final _pending = <String>{};

  var _flushScheduled = false;
  var _released = false;

  /// Starts announcing preference changes to this session's client.
  ///
  /// ## One listener per session, deliberately
  ///
  /// The gateway serves every session from **one shared source**
  /// (`relay_server.dart:213-214`, "One instance, shared"), so what attaches
  /// here is one listener per session on one broadcast stream, and each
  /// session cancels its own in `RelaySession._teardown`, beside
  /// `subscriptions.clear()`.
  ///
  /// The alternative — one server-level subscription fanning out over the
  /// session registry — is the tidier-looking shape and is **not** what this
  /// is, for two reasons worth writing down. It would need its own registry
  /// walk to replace what `_teardown` already does for free; and it would take
  /// the teardown property away from the place that can measure it, because
  /// "the listener came off when the session died" is only assertable when the
  /// listener belonged to the session. `teardown_test.dart` counts exactly
  /// that, as a rate, across kill cycles.
  ///
  /// ## Coalesced, and on a timer rather than a microtask
  ///
  /// `sendNotification` lands in the session's priority lane, which is
  /// byte-capped at 8 MiB, entry-capped, drained only by the tick and **not
  /// conflated** (`session_sink.dart:56-57`, `send_buffer.dart:185-196`). So a
  /// `clear()` over five hundred preference keys, un-coalesced, is five
  /// hundred frames per connected client and then a `BufferDisconnect`, which
  /// `relay_session.dart:416-424` turns into `close(4004)`: a settings page
  /// evicting every panel in the plant and reporting it to the operators as
  /// backpressure (T-10-19).
  ///
  /// The flush is scheduled with **`Timer.run`** — a zero-duration one-shot —
  /// and **not** with `scheduleMicrotask`, which is the shape the contract
  /// kit's own flush uses. That difference was measured rather than assumed,
  /// and the reason is in the source this listens to.
  ///
  /// The kit coalesces changes that arrive from `ValueListenable` callbacks,
  /// which fire **synchronously** inside the loop that made them: by the time
  /// the microtask queue is reached, every key is already pending. A
  /// preference store announces through a broadcast `StreamController`
  /// instead, and an asynchronous broadcast controller delivers one event per
  /// microtask, scheduling the next delivery from inside the previous one — so
  /// a flush scheduled from the first delivery lands in the queue *ahead* of
  /// the second key. Measured with `scheduleMicrotask`: a five-hundred-key
  /// `clear()` produced **five hundred frames, each naming one key**, which is
  /// the exact failure this method exists to prevent.
  ///
  /// A timer callback runs only after the microtask queue has drained
  /// completely, so every delivery of the burst is pending before the flush
  /// looks. It coalesces one *turn* of the event loop rather than one
  /// synchronous block, which is a little wider than the kit's shape and still
  /// nothing to do with wall time: `Duration.zero` cannot make the count a
  /// client sees depend on how fast the machine ran, and the frame is on the
  /// wire in the same tick either way.
  ///
  /// `Timer.run` and never a constructed `Timer(...)`: `teardown_test.dart`
  /// sweeps this package for the second spelling, because a retained timer can
  /// outlive the turn it was scheduled in and hold a closed session's buffer,
  /// listeners and socket with it. This one cannot.
  ///
  /// ## `UnsupportedError` is caught, and nothing else is
  ///
  /// A source with no preference store is legitimate — the contract's
  /// data-services sub-suite is skipped for such a source, with a reason on
  /// the record — and refusing to serve it at all would turn a declared
  /// absence into a startup failure. Nothing else is caught, because nothing
  /// else here is a shape a correct source can have.
  void watchPreferences() {
    try {
      _preferenceChanges = source.preferences.onPreferencesChanged.listen(
        (key) {
          if (_released) return;
          _pending.add(key);
          _scheduleFlush();
        },
        // A store that errors is not a reason to tear down a session that is
        // otherwise serving the plant: the values path is a different stream
        // and a different source. The change is lost, which is the honest
        // outcome — there is nothing here that could re-derive it.
        onError: (Object _) {},
      );
    } on UnsupportedError {
      _preferenceChanges = null;
    }
  }

  /// Detaches this session's listener and drops anything it had buffered.
  ///
  /// Called from `RelaySession._teardown`. Idempotent: [_released] is set
  /// synchronously, so a flush already scheduled finds nothing to do even
  /// though the microtask outlives this call.
  Future<void> releasePreferenceWatch() async {
    _released = true;
    _pending.clear();
    final watch = _preferenceChanges;
    _preferenceChanges = null;
    await watch?.cancel();
  }

  void _scheduleFlush() {
    if (_flushScheduled || _released) return;
    _flushScheduled = true;
    Timer.run(_flush);
  }

  /// One notification per flush, however many keys moved.
  ///
  /// [_pending] is cleared **before** [notify] is consulted rather than after,
  /// and that ordering matters for the one session state that drops frames: a
  /// peer that has not said `hello` is told nothing, and buffering the keys it
  /// was not told about would leave a socket that never authenticates growing
  /// a set of every preference key on the gateway.
  void _flush() {
    _flushScheduled = false;
    if (_released || _pending.isEmpty) return;
    final keys = _pending.toList(growable: false);
    _pending.clear();
    notify(DataServiceMethods.preferencesChanged, {'keys': keys});
  }

  // ------------------------------------------------------------------ browse

  /// The top level of the address space.
  ///
  /// An empty list is a legitimate answer — a source with nothing to browse —
  /// and null is not: the client decodes null as a missing answer and the tree
  /// shows a spinner that never resolves.
  Future<Object?> browseFetchRoots(rpc.Parameters _) async =>
      [for (final node in await source.browse.fetchRoots()) node.toJson()];

  /// One level, under the node the caller names.
  Future<Object?> browseFetchChildren(rpc.Parameters params) async {
    final parent = _node(params, 'parent', DataServiceMethods.browseFetchChildren);
    return [
      for (final node in await source.browse.fetchChildren(parent))
        node.toJson(),
    ];
  }

  /// Everything the detail pane shows about one node.
  Future<Object?> browseFetchDetail(rpc.Parameters params) async {
    final node = _node(params, 'node', DataServiceMethods.browseFetchDetail);
    return (await source.browse.fetchDetail(node)).toJson();
  }

  /// The chain from a root to [targetId], root first, or null.
  ///
  /// **Null and the empty list stay apart** (`served_state_man.dart:501-507`).
  /// Null is "cannot resolve"; an empty list would claim the target sits zero
  /// nodes from a root, and a panel restoring a saved selection would select
  /// the root instead of dropping the pre-selection. A page saved last year
  /// against a tag since renamed in the PLC is the ordinary case.
  Future<Object?> browseResolvePath(rpc.Parameters params) async {
    final raw = params['targetId'].valueOr(null);
    if (raw is! String || raw.isEmpty) {
      throw _refuse(
          DataServiceMethods.browseResolvePath,
          'browse.resolvePath needs a non-empty string "targetId": the id of '
          'the node to resolve a path to');
    }
    final chain = await source.browse.resolvePath(raw);
    return chain == null ? null : [for (final node in chain) node.toJson()];
  }

  // -------------------------------------------------------------- timeseries

  /// Samples for one series up to `to`, optionally from `from`.
  ///
  /// The window travels as **epoch milliseconds**, decoded here exactly once
  /// (`served_state_man.dart:762-764`). `to` has no honest default: answering
  /// "now" for a caller that forgot it would answer a different question than
  /// the one asked, and the caller could not tell.
  Future<Object?> timeseriesQuery(rpc.Parameters params) async {
    const method = DataServiceMethods.timeseriesQuery;
    final table = _series(params, 'table', method);
    final to = _requiredInstant(params, 'to', method);
    final from = _instant(params, 'from', method);
    final orderBy = _orderBy(params, method);
    _requireForwardWindow(from, to, method);
    return _points(await _sized(
        method,
        () => source.timeseries
            .queryTimeseriesData(table, to, orderBy: orderBy, from: from)));
  }

  /// The same window for several series in one round trip, keyed by name.
  ///
  /// **One entry per requested series, built from the request** — never from
  /// whatever the source happened to answer. An absent entry and an empty
  /// entry are different answers and only one of them is true: a chart that
  /// iterates the names it asked for and finds no entry drops the series from
  /// its legend, which an operator reads as "this tag is flat" rather than as
  /// "nothing was recorded".
  ///
  /// Assembling the map here rather than forwarding the source's is what makes
  /// that a property of the gateway. 10-07's reader answers out of a database
  /// that has no row for a silent table, and the policy filter below this
  /// answers nothing at all for a series the station may not see — both would
  /// produce a short map, and both are covered by this loop.
  Future<Object?> timeseriesQueryMultiple(rpc.Parameters params) async {
    const method = DataServiceMethods.timeseriesQueryMultiple;
    final tables = _seriesList(params, 'tables', method);
    final to = _requiredInstant(params, 'to', method);
    final from = _instant(params, 'from', method);
    final orderBy = _orderBy(params, method);
    _requireForwardWindow(from, to, method);
    final answers = await _sized(
        method,
        () => source.timeseries.queryTimeseriesDataMultiple(tables, to,
            orderBy: orderBy, from: from));
    return {
      for (final table in tables) table: _points(answers[table] ?? const []),
    };
  }

  /// At most `maxPoints` samples spanning the window.
  Future<Object?> timeseriesQueryDownsampled(rpc.Parameters params) async {
    const method = DataServiceMethods.timeseriesQueryDownsampled;
    final table = _series(params, 'table', method);
    final from = _requiredInstant(params, 'from', method);
    final to = _requiredInstant(params, 'to', method);
    final maxPoints = _requiredInt(params, 'maxPoints', method,
        atLeast: ServerConfig.minTimeseriesPoints,
        atMost: config.maxTimeseriesPoints,
        why: 'below ${ServerConfig.minTimeseriesPoints} the downsampler '
            'computes zero buckets and silently falls back to the unbounded '
            'raw query, which is the one thing this method exists to avoid; '
            'above ${config.maxTimeseriesPoints} the caller is not drawing a '
            'chart, because a chart has hundreds of pixels');
    _requireForwardWindow(from, to, method);
    return _points(await _sized(
        method,
        () => source.timeseries.queryTimeseriesDataDownsampled(table, from, to,
            maxPoints: maxPoints)));
  }

  // ----------------------------------------------------------- history views

  /// Saves a view and answers its id.
  ///
  /// ## The graph-index trap, and why it cannot be reached from here
  ///
  /// `graphConfigs` is keyed by **graph index**, an `int`, and JSON objects key
  /// by `String` — so the map crosses the wire String-keyed and is converted
  /// back exactly once, at this boundary, by `historyViewGraphsFromJson`.
  ///
  /// Upstream's own `createHistoryView` parses those keys with `int.tryParse`
  /// and, when one fails, **silently skips the entry**
  /// (`database_drift.dart:610` and `:655`, the update path). A chart that
  /// saved four graphs would get three back and nothing would have said so.
  /// That drop is unreachable through this gateway for one reason and it is
  /// worth stating rather than trusting: **the wire type is
  /// `Map<int, HistoryViewGraphRecord>`**, so a key that will not parse is
  /// refused here, before the source is touched — see [_graphConfigs].
  ///
  /// **Do not "simplify" this to an untyped map.** An `Object?`-valued bag
  /// forwarded straight down would put the silent drop back on the wire, and
  /// it would be invisible: the call succeeds, the id comes back, and the
  /// missing graph is discovered by an engineer wondering why the second axis
  /// has no title.
  ///
  /// On the way **up** the same conversion runs in reverse
  /// (`historyViewGraphsToJson`), and a String key that will not parse is a
  /// decode failure on the client rather than a dropped entry — which is the
  /// correct asymmetry: a gateway may refuse its caller's input, but a client
  /// silently discarding part of a stored view would hide a database problem.
  Future<Object?> historyCreateView(rpc.Parameters params) async {
    const method = DataServiceMethods.historyCreateView;
    return source.historyViews.createHistoryView(
      _viewName(params, method),
      _viewKeys(params, method),
      _keyConfigs(params, method),
      _graphConfigs(params, method),
    );
  }

  /// Replaces the name, keys and configuration of a view.
  ///
  /// **Replaces, never merges** — the frozen signature's semantics, and the
  /// only method that exists for taking a line off a chart. A union here would
  /// make removing a key impossible through the API.
  Future<Object?> historyUpdateView(rpc.Parameters params) async {
    const method = DataServiceMethods.historyUpdateView;
    await source.historyViews.updateHistoryView(
      _viewId(params, 'id', method),
      _viewName(params, method),
      _viewKeys(params, method),
      _keyConfigs(params, method),
      _graphConfigs(params, method),
    );
    return null;
  }

  /// Deletes a view and everything recorded against it.
  ///
  /// The cascade — key rows, graph rows, saved windows — is spelled out by
  /// hand in the database layer rather than left to a foreign key, so it is
  /// behaviour this gateway carries across rather than inherits. Rows that
  /// outlive their view are how a deleted view comes back as a partial one
  /// after the next restart.
  Future<Object?> historyDeleteView(rpc.Parameters params) async {
    const method = DataServiceMethods.historyDeleteView;
    await source.historyViews.deleteHistoryView(_viewId(params, 'id', method));
    return null;
  }

  /// Every saved view, for the picker.
  ///
  /// Takes no parameters, and answers a list — empty when nothing has been
  /// saved, never null, for `browse.fetchRoots`' reason.
  ///
  /// **[_sized]** (10-REVIEW WR-05). The picker's row count is chosen by
  /// whoever has been saving charts, the answer goes into the un-conflated
  /// priority lane, and `flushPriority` writes the whole lane out before a
  /// 4004 — so an unbounded answer here evicts the panel and reports it as
  /// backpressure. The ceiling is `ReadLimits.maxHistoryViewRows`.
  Future<Object?> historySelectViews(rpc.Parameters _) =>
      _sized(DataServiceMethods.historySelectViews, () async => [
            for (final view in await source.historyViews.selectHistoryViews())
              view.toJson(),
          ]);

  /// The plotted keys of a view, keyed by key name.
  ///
  /// **A short answer is a legitimate one.** The policy layer below this drops
  /// keys a station may not see, so a view can honestly come back plotting
  /// fewer keys than were saved — and, at the limit, none. That is the rule
  /// `_PolicyHistoryViews` exists for: a view that vanished would itself say a
  /// view exists.
  Future<Object?> historyGetKeys(rpc.Parameters params) async {
    const method = DataServiceMethods.historyGetKeys;
    final viewId = _viewId(params, 'viewId', method);
    return _sized(method, () async {
      final keys = await source.historyViews.getHistoryViewKeys(viewId);
      return {
        for (final entry in keys.entries) entry.key: entry.value.toJson(),
      };
    });
  }

  /// The per-graph configuration of a view, keyed by graph index.
  ///
  /// String-keyed on the wire and back again exactly once, for the reason
  /// [historyCreateView] gives at length. **Unfiltered by policy**: a graph
  /// index is not a key and there is nothing to hide in a title or an axis
  /// unit.
  Future<Object?> historyGetGraphs(rpc.Parameters params) async {
    const method = DataServiceMethods.historyGetGraphs;
    final viewId = _viewId(params, 'viewId', method);
    return _sized(
        method,
        () async => historyViewGraphsToJson(
            await source.historyViews.getHistoryViewGraphs(viewId)));
  }

  /// Just the key names of a view, for callers that need no aliases.
  Future<Object?> historyGetKeyNames(rpc.Parameters params) async {
    const method = DataServiceMethods.historyGetKeyNames;
    final viewId = _viewId(params, 'viewId', method);
    return _sized(
        method, () => source.historyViews.getHistoryViewKeyNames(viewId));
  }

  /// Saves a time window on a view and answers its id.
  ///
  /// **Both instants are epoch milliseconds and both decode as UTC.** This is
  /// the surface where that convention earns its keep: "Vakt 1" is a shift an
  /// operator comes back to, and a window that returns an hour off lands on
  /// the wrong shift with nothing on screen saying so. Every conclusion drawn
  /// from the chart is then about hours nobody looked at.
  Future<Object?> historyAddPeriod(rpc.Parameters params) async {
    const method = DataServiceMethods.historyAddPeriod;
    final viewId = _viewId(params, 'viewId', method);
    final name = _viewName(params, method);
    final start = _requiredInstant(params, 'start', method);
    final end = _requiredInstant(params, 'end', method);
    // Refused rather than stored, for `_requireForwardWindow`'s reason: a
    // saved shift that ends before it starts renders as nothing later, and a
    // chart showing nothing is read as a plant that did nothing.
    _requireForwardWindow(start, end, method);
    return source.historyViews.addHistoryViewPeriod(viewId, name, start, end);
  }

  /// Deletes a saved window.
  Future<Object?> historyDeletePeriod(rpc.Parameters params) async {
    const method = DataServiceMethods.historyDeletePeriod;
    await source.historyViews
        .deleteHistoryViewPeriod(_viewId(params, 'id', method));
    return null;
  }

  /// Every saved window on a view, oldest first.
  Future<Object?> historyListPeriods(rpc.Parameters params) async {
    const method = DataServiceMethods.historyListPeriods;
    final viewId = _viewId(params, 'viewId', method);
    return _sized(method, () async => [
          for (final period
              in await source.historyViews.listHistoryViewPeriods(viewId))
            period.toJson(),
        ]);
  }

  /// The oldest instant any series is still retained for, or null.
  ///
  /// **Null and an instant at the epoch are opposite answers**, and this is
  /// the one method on this wire where confusing them is easy: 0 is a
  /// perfectly good epoch millisecond. Null means "nothing has been discarded
  /// yet" — a chart may scroll back as far as it likes and absence of data is
  /// absence of events. Zero would mean everything before 1970 is gone, which
  /// against any real window means *all* of it. The client decodes against
  /// exactly this distinction (`raw == null ? null : timeOf(raw)`), so the
  /// null must survive as null rather than being defaulted here.
  ///
  /// **No contract check covers this method.**
  /// `data_services_contract.dart:4-30` forbids an eighth data-services case
  /// upstream, and none of the seven that exist calls it — so a wrong answer
  /// here leaves every leg of the contract suite green. Its judgement lives in
  /// `data_handlers_test.dart`, in a group that says so by name.
  ///
  /// The gateway does **not** widen upstream's catch. `getGlobalRetentionHorizon`
  /// swallows a permissions error and answers null (`database_drift.dart:776-779`),
  /// which reads on the wire as "nothing has been discarded" — a repudiation
  /// hazard this plan accepts at the wire and 10-08 makes visible at the
  /// reader. Catching more here would only move the same silence.
  Future<Object?> historyRetentionHorizon(rpc.Parameters _) async =>
      (await source.historyViews.getGlobalRetentionHorizon())
          ?.millisecondsSinceEpoch;

  // ------------------------------------------------------------- preferences

  /// Every key the store holds, or every key in the allow list that it holds.
  ///
  /// **A list on the wire, not a set**: JSON has no set, and the client builds
  /// one back on the far side (`client_sub_apis.dart`'s `getKeys`).
  Future<Object?> prefGetKeys(rpc.Parameters params) async =>
      (await source.preferences
              .getKeys(allowList: _allowList(params, DataServiceMethods.prefGetKeys)))
          .toList();

  /// Every key and value, filtered the same way — and **[_sized]**, because
  /// this is the second place a `ResultTooLarge` is raised.
  ///
  /// It was not wrapped when the mapping landed: 10-03 wrapped the four
  /// timeseries methods and nothing else raised one yet. 10-10's byte ceiling
  /// does, and unwrapped it would leave the handler uncaught and reach the
  /// wire through `relay_session.dart`'s catch-all as `handlerFailed`
  /// (-32011) — which the wire documents as possibly transient. A settings
  /// page over a store larger than the cap would then retry forever something
  /// no retry can fix, on every panel that opened it.
  Future<Object?> prefGetAll(rpc.Parameters params) => _sized(
      DataServiceMethods.prefGetAll,
      () => source.preferences.getAll(
          allowList: _allowList(params, DataServiceMethods.prefGetAll)));

  /// A stored bool, or null when the key is absent.
  ///
  /// **A wrong-typed stored value is not caught here**, and that is the
  /// decision the seven typed getters share. `PreferencesApi` promises a
  /// `TypeError` for a value of another type, the store's own cast is what
  /// raises it, and `RelaySession._answer` maps it to `typeMismatch` (-32010)
  /// — which is precisely the code 10-01 taught the client to turn back into a
  /// `TypeError` (`client_sub_apis.dart`'s `withTypedErrors`). A handler that
  /// caught it and answered null would render a settings page's *default* over
  /// a value that is really there, and nothing would say so.
  ///
  /// **`async`, and the six below it are too** (10-REVIEW IN-01). A
  /// non-`async` body evaluates `_prefKey` before the delegated future is
  /// created, so a refusal throws *synchronously* out of a `Future`-returning
  /// method rather than rejecting the returned future. That is the regression
  /// 10-08 caught, arriving in a third place. It is defused on the wire —
  /// `RelaySession._on` registers every handler as
  /// `_answer(method, () async => handler(params))`, and the `() async =>`
  /// converts the synchronous throw into a future error inside `_answer`'s
  /// `try` — so the exposure is a direct caller using `.catchError` on the
  /// returned future, which is exactly how the earlier instances were found.
  /// One keyword each, and a future reader does not have to re-derive the
  /// seam argument. `HistoryViewStore` states the same rule at its own
  /// `_noHistorian`.
  Future<Object?> prefGetBool(rpc.Parameters params) async =>
      source.preferences.getBool(_prefKey(params, DataServiceMethods.prefGetBool));

  Future<Object?> prefGetInt(rpc.Parameters params) async =>
      source.preferences.getInt(_prefKey(params, DataServiceMethods.prefGetInt));

  Future<Object?> prefGetDouble(rpc.Parameters params) async =>
      source.preferences
          .getDouble(_prefKey(params, DataServiceMethods.prefGetDouble));

  Future<Object?> prefGetString(rpc.Parameters params) async =>
      source.preferences
          .getString(_prefKey(params, DataServiceMethods.prefGetString));

  Future<Object?> prefGetStringList(rpc.Parameters params) async =>
      source.preferences
          .getStringList(_prefKey(params, DataServiceMethods.prefGetStringList));

  /// Whether the store holds [key] at all.
  ///
  /// "Absent" and "set to null" are different answers and a settings page
  /// renders a default for one and a blank for the other, which is why this
  /// method exists beside the getters rather than being inferred from a null.
  Future<Object?> prefContainsKey(rpc.Parameters params) async =>
      source.preferences
          .containsKey(_prefKey(params, DataServiceMethods.prefContainsKey));

  Future<Object?> prefSetBool(rpc.Parameters params) async {
    const method = DataServiceMethods.prefSetBool;
    final key = _prefKey(params, method);
    final raw = params['value'].valueOr(null);
    if (raw is! bool) {
      throw _refuse(
          method,
          '$method needs a bool "value", not ${raw.runtimeType}. It is refused '
          'rather than coerced: a store holding the string "true" under this '
          'key throws a TypeError on every later getBool');
    }
    await source.preferences.setBool(key, raw);
    return null;
  }

  Future<Object?> prefSetInt(rpc.Parameters params) async {
    const method = DataServiceMethods.prefSetInt;
    final key = _prefKey(params, method);
    final raw = params['value'].valueOr(null);
    if (raw is! int) {
      throw _refuse(
          method,
          '$method needs an integer "value", not ${raw.runtimeType}. Unlike '
          'setDouble, this one does **not** widen: a caller that sent 800.5 '
          'for an int preference meant something the store cannot hold, and '
          'rounding it here would decide what they meant');
    }
    await source.preferences.setInt(key, raw);
    return null;
  }

  /// Saves a double, **accepting an integral JSON number**.
  ///
  /// The one decode in this family that widens rather than narrows, and it is
  /// deliberate (`served_state_man.dart:683-692`). Dart's encoder writes an
  /// integral double as `800.0`, but a hand-written client — a curl, a Python
  /// script, an integrator's panel — sends `800`, and `jsonDecode` hands that
  /// back as an `int`. Refusing it would be refusing a value the type admits.
  ///
  /// Read through `num` and converted here, never `asDouble`: `asDouble` on an
  /// `int` raises an `RpcException` with no `data`, which `serialize` then
  /// fills with the offending request — the shape this whole file exists to
  /// avoid. Storing the `int` instead would be worse: every later `getDouble`
  /// would throw a TypeError on a tolerance a settings page had just saved.
  Future<Object?> prefSetDouble(rpc.Parameters params) async {
    const method = DataServiceMethods.prefSetDouble;
    final key = _prefKey(params, method);
    final raw = params['value'].valueOr(null);
    if (raw is! num) {
      throw _refuse(
          method,
          '$method needs a numeric "value", not ${raw.runtimeType}. An '
          'integral number is accepted and stored as a double: JSON has one '
          'number type, and a client that sent 800 for a tolerance meant 800.0');
    }
    await source.preferences.setDouble(key, raw.toDouble());
    return null;
  }

  Future<Object?> prefSetString(rpc.Parameters params) async {
    const method = DataServiceMethods.prefSetString;
    final key = _prefKey(params, method);
    final raw = params['value'].valueOr(null);
    if (raw is! String) {
      throw _refuse(
          method,
          '$method needs a string "value", not ${raw.runtimeType}');
    }
    await source.preferences.setString(key, raw);
    return null;
  }

  /// Saves a list of strings, **refusing an element that is not one**.
  ///
  /// A deliberate departure from the port source, which writes `'$entry'` per
  /// element and so turns `[1, 2]` into `['1', '2']` in silence. A gateway
  /// that coerces is a gateway deciding what its caller meant, and the caller
  /// here is a settings page whose list is read back and compared.
  Future<Object?> prefSetStringList(rpc.Parameters params) async {
    const method = DataServiceMethods.prefSetStringList;
    final key = _prefKey(params, method);
    final raw = params['value'].valueOr(null);
    if (raw is! List) {
      throw _refuse(
          method,
          '$method needs a "value" list of strings, not ${raw.runtimeType}. An '
          'empty list is allowed — a page with no recent entries yet is an '
          'ordinary state');
    }
    final value = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! String) {
        throw _refuse(
            method,
            '$method\'s "value" carries a ${entry.runtimeType} at index $i. It '
            'is refused rather than stringified: a stored ["1"] that was sent '
            'as [1] reads back as a different list than the caller saved');
      }
      value.add(entry);
    }
    await source.preferences.setStringList(key, value);
    return null;
  }

  Future<Object?> prefRemove(rpc.Parameters params) async {
    await source.preferences
        .remove(_prefKey(params, DataServiceMethods.prefRemove));
    return null;
  }

  /// Clears the store, or the part of it the allow list names.
  ///
  /// **The allow list is forwarded, never dropped.** With one, this empties a
  /// page's own section; without one, it empties every preference this gateway
  /// holds — `key_mappings`, the plant's routing configuration, included. A
  /// handler that lost the argument on the way down would turn the first into
  /// the second.
  Future<Object?> prefClear(rpc.Parameters params) async {
    await source.preferences
        .clear(allowList: _allowList(params, DataServiceMethods.prefClear));
    return null;
  }

  /// A preference key out of `"key"`.
  ///
  /// Guarded rather than left to `params['key'].asString`, for this file's
  /// standing reason: that raises an `RpcException` with no `data`. Bounded by
  /// nothing, like a view's `name` and for the same argument — ingress already
  /// refuses a frame over `ServerConfig.maxFrameBytes`, and a second bound on
  /// one hazard is a second number to keep in step.
  ///
  /// **Not checked against a namespace.** A preference key is whatever the
  /// application stores under, `key_mappings` included; deciding here which
  /// names are legitimate would be inventing configuration policy in the
  /// plumbing. What decides who may *write* one is `_PolicyPreferences`, one
  /// layer down.
  static String _prefKey(rpc.Parameters params, String method) {
    final raw = params['key'].valueOr(null);
    if (raw is! String || raw.isEmpty) {
      throw _refuse(
          method,
          '$method needs a non-empty string "key": the preference to read or '
          'write, not ${raw.runtimeType}');
    }
    return raw;
  }

  /// The `"allowList"` filter, or null for "no filter asked for".
  ///
  /// Null is a legitimate value and the client sends the field even when it is
  /// null, so the two stay distinguishable: no allow list means the whole
  /// store, which for `clear` is the difference between one page's settings
  /// and the gateway's.
  ///
  /// Shape-checked but deliberately **not bounded**, unlike `keys` and
  /// `tables`. Those two multiply the work the source does — one row written
  /// or one query run per entry — while this one only narrows an answer the
  /// store was going to compute anyway, and its size is already bounded by the
  /// frame ingress refuses above.
  static Set<String>? _allowList(rpc.Parameters params, String method) {
    final raw = params['allowList'].valueOr(null);
    if (raw == null) return null;
    if (raw is! List) {
      throw _refuse(
          method,
          '$method needs "allowList" as a list of preference keys, or absent '
          '— not ${raw.runtimeType}. Absent means the whole store, which is a '
          'different question and not a safer one');
    }
    final keys = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! String || entry.isEmpty) {
        throw _refuse(
            method,
            '$method\'s "allowList" carries a non-string or empty entry at '
            'index $i: every entry names a preference key');
      }
      keys.add(entry);
    }
    return keys;
  }

  // ------------------------------------------------------------------ shared

  /// A view's own label.
  ///
  /// Not bounded here, and that is deliberate rather than an omission: the
  /// only way a name reaches this method is inside a request frame, and
  /// ingress already refuses a frame over `ServerConfig.maxFrameBytes`. A
  /// second bound on the same hazard is a second number to keep in step.
  static String _viewName(rpc.Parameters params, String method) {
    final raw = params['name'].valueOr(null);
    if (raw is! String) {
      throw _refuse(
          method,
          '$method needs a string "name": what the view is called in the '
          'picker, not ${raw.runtimeType}');
    }
    return raw;
  }

  /// The plant keys a view plots.
  ///
  /// **Plant keys, not series names**, which is why nothing here consults the
  /// resolver: a view is a list of tags an engineer picked off the browse
  /// tree, and the timeseries family's `<series>[:<member>]` grammar is a
  /// different namespace with a different parser.
  ///
  /// Bounded by `maxKeysPerSubscribe` rather than by a fourth number, on
  /// 10-03's argument for `tables`: it is the same hazard — an unbounded
  /// breadth argument on one round trip, here writing one row per entry — and
  /// a second number for it is a second number to keep in step.
  List<String> _viewKeys(rpc.Parameters params, String method) {
    final raw = params['keys'].valueOr(null);
    if (raw is! List) {
      throw _refuse(
          method,
          '$method needs a "keys" list: the plant keys this view plots. An '
          'empty list is allowed — a view with no lines yet is a normal state '
          'while an engineer is building one — but an absent list is not, '
          'because it cannot be told from a caller that forgot the argument');
    }
    if (raw.length > config.maxKeysPerSubscribe) {
      throw _refuse(
          method,
          '$method carried ${raw.length} keys, over this server\'s limit of '
          '${config.maxKeysPerSubscribe}; split the view or raise '
          'maxKeysPerSubscribe');
    }
    final keys = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! String || entry.isEmpty) {
        throw _refuse(
            method,
            '$method\'s "keys" carries a non-string or empty entry at index '
            '$i: every entry names a plant key');
      }
      keys.add(entry);
    }
    return keys;
  }

  /// Per-key configuration — legend label, axis placement, graph — or null.
  ///
  /// Optional in the frozen signature and optional here: a view saved with no
  /// per-key configuration is the ordinary case, and every field the record
  /// carries has a default (`alias` falls back to the key's own name, which is
  /// upstream's `row.alias ?? row.key` moved inside the constructor).
  static Map<String, HistoryViewKeyRecord>? _keyConfigs(
      rpc.Parameters params, String method) {
    final raw = params['keyConfigs'].valueOr(null);
    if (raw == null) return null;
    if (raw is! Map) {
      throw _refuse(
          method,
          '$method needs "keyConfigs" as an object keyed by plant key, or '
          'absent — not ${raw.runtimeType}');
    }
    final configs = <String, HistoryViewKeyRecord>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) {
        throw _refuse(
            method,
            '$method\'s "keyConfigs" entry for "${entry.key}" is '
            '${value.runtimeType}, not an object carrying that key\'s legend '
            'label and axis placement');
      }
      configs['${entry.key}'] = HistoryViewKeyRecord.fromJson(_object(value));
    }
    return configs;
  }

  /// Per-graph configuration, keyed by graph index — or null.
  ///
  /// **The refusal below is the one that keeps upstream's silent drop
  /// unreachable.** `historyViewGraphsFromJson` parses each key with
  /// `int.parse`, which throws a `FormatException` — inside the handler, where
  /// the session would report it as `handlerFailed` (-32011), documented as
  /// "possibly transient: retrying is legitimate" for a request that will
  /// never succeed. So the keys are checked first and a bad one is refused as
  /// INVALID_PARAMS, with the reason naming what the alternative would have
  /// cost: upstream's own `createHistoryView` answers a non-numeric key by
  /// **skipping the entry** (`database_drift.dart:610`), which is a chart
  /// saving four graphs and getting three back in silence.
  static Map<int, HistoryViewGraphRecord>? _graphConfigs(
      rpc.Parameters params, String method) {
    final raw = params['graphConfigs'].valueOr(null);
    if (raw == null) return null;
    if (raw is! Map) {
      throw _refuse(
          method,
          '$method needs "graphConfigs" as an object keyed by graph index, or '
          'absent — not ${raw.runtimeType}');
    }
    for (final key in raw.keys) {
      if (key is! String || int.tryParse(key) == null) {
        throw _refuse(
            method,
            '$method\'s "graphConfigs" is keyed by graph index and "$key" is '
            'not a number. It is refused rather than dropped: the database '
            'layer parses these keys with int.tryParse and silently skips an '
            'entry that fails, so a chart would save four graphs, get three '
            'back, and nothing would have said so. The wire type is '
            'Map<int, …>, which is what makes that drop unreachable — do not '
            'widen it to an untyped map');
      }
    }
    return historyViewGraphsFromJson(raw);
  }

  /// A view or period id out of [name].
  ///
  /// **Not bounded, and not required to be positive.** An id that addresses no
  /// row is a miss, and a miss is a legitimate answer this surface has to give
  /// anyway: a picker open while somebody else deletes a view asks about it
  /// once more, and "the view is gone" is the truth rather than an error. What
  /// is refused is a value that is not an id at all — including the String
  /// `"1"`, because `params[name].asInt` would raise an `RpcException` with no
  /// `data`, which `serialize` then fills with the offending request.
  static int _viewId(rpc.Parameters params, String name, String method) {
    final raw = params[name].valueOr(null);
    if (raw is! int) {
      throw _refuse(
          method,
          '$method needs an integer "$name": the id a view or window was '
          'saved under, not ${raw.runtimeType}. Ids travel as numbers on this '
          'wire, never as their decimal spelling');
    }
    return raw;
  }


  /// The only two orderings a client may ask for.
  ///
  /// **One string, one place.** This is the whole allow-list; every ordering
  /// decision in this package reads it, and `hostile_params_test.dart` is the
  /// file that proves it bites.
  static const _orderings = {'time ASC', 'time DESC'};

  /// The ordering [params] asked for, or null for "none asked for".
  ///
  /// ## Refused, never sanitized
  ///
  /// `orderBy` reaches
  /// `'SELECT $cols FROM "$tableName"$whereClause$orderByClause'` in
  /// `database_drift.dart`'s `tableQuery`, unescaped, in a position where a
  /// subquery is legal grammar — so `'time ASC, (SELECT 1)'` is not an
  /// injection that has to escape a quote first, it is simply a longer
  /// `ORDER BY` clause. Mapping the frozen signature onto the wire without
  /// this check would ship the `query(sql)` RPC the project forbids, wearing a
  /// signature nobody reads as one.
  ///
  /// A *sanitizer* invites the question of whether it is complete. A two-value
  /// allow-list does not, and nothing is lost by it: the contract's own fake
  /// implements ordering as `_descending(orderBy) ? reversed : forward`, which
  /// is two values and a default. Case is **not** normalised and whitespace is
  /// **not** collapsed, because each of those is a transformation and a
  /// transformation is the first step of a sanitizer.
  ///
  /// ## And it is here rather than in the database
  ///
  /// `tfc_dart`'s database layer is shared with an application that has always
  /// passed its own literals. Moving the check down would either change that
  /// application's behaviour or leave this gateway trusting that it had. The
  /// gateway does not trust a client-supplied SQL fragment; it refuses one, at
  /// the boundary, before the source is reached.
  static String? _orderBy(rpc.Parameters params, String method) {
    final raw = params['orderBy'].valueOr(null);
    // Null is a legitimate value — "no ordering asked for" — and the client
    // sends the key even when it is null so the two stay distinguishable. No
    // default is invented here: the frozen signature already declares one, and
    // inventing a second would take the distinction away from the source.
    if (raw == null) return null;
    if (raw is String && _orderings.contains(raw)) return raw;
    throw _refuse(
        method,
        '$method accepts "orderBy" as exactly one of ${_orderings.join(' or ')}'
        ', or absent. It is refused rather than sanitized or completed: this '
        'string is interpolated into a SQL ORDER BY clause, where a subquery '
        'is legal grammar, so anything outside the allow-list is a statement '
        'fragment the caller chose. Case is not normalised and whitespace is '
        'not collapsed, because both are transformations and a transformation '
        'is the first step of a sanitizer');
  }

  /// A wire series name out of [name], parsed.
  ///
  /// **The grammar belt**, and it is the handler's half of a two-belt
  /// arrangement. This one refuses a string that is not a *name*: more than
  /// one colon, an empty series, a trailing colon — the `SeriesAddress`
  /// grammar, enforced through the resolver so the parse happens in exactly
  /// one place. 10-07's reader carries the other belt, refusing a name that is
  /// well formed but outside the collection plan before it can reach a
  /// statement. Both belts are cheap and two belts is the house convention on
  /// ingress (`value_handlers.dart:189-192`).
  ///
  /// **A malformed name may be echoed; an unmapped one may not.** "You spelled
  /// it wrong" and "there is no such series" are different facts: the first is
  /// something the caller already knows, and the second, said out loud, would
  /// let a station enumerate the historian one name at a time. So a name that
  /// resolves to **null** is deliberately *not* refused here — it is answered
  /// as a series that does not exist, one layer down, in `_PolicyTimeseries`,
  /// which also counts it so the gap is diagnosable (T-10-12, 10-CONTEXT
  /// amendment 6).
  /// The longest series name this gateway will accept on the wire.
  ///
  /// **A length bound as well as a shape one** (10-REVIEW WR-04). Nothing else
  /// bounded a series name: the frame cap is 1 MiB, `maxKeysPerSubscribe` is
  /// 2000, and `SeriesMappingTally` bounds how *many* novel names it remembers
  /// but not how long each is — so one authenticated station could pin tens of
  /// megabytes in the gateway for the life of the process, and log a line of
  /// up to a megabyte per name while doing it. The tally now truncates what it
  /// keeps; this is the belt on the other side, and it is free: the plant's
  /// convention is `AREAnn.DEVnn.SUBnn` plus at most one member, and the
  /// longest real key at SVN is under fifty characters.
  static const int maxSeriesNameChars = 200;

  String _series(rpc.Parameters params, String name, String method) {
    final raw = params[name].valueOr(null);
    if (raw is! String || raw.isEmpty) {
      throw _refuse(
          method,
          '$method needs a non-empty string "$name": the series to read, '
          'named as `<series>` or `<series>:<member>`');
    }
    if (raw.length > maxSeriesNameChars) {
      // The refusal does NOT echo the name — that is the whole point of
      // bounding it — and says how long it was instead.
      throw _refuse(
          method,
          '$method refused "$name": a series name may be at most '
          '$maxSeriesNameChars characters and this one is ${raw.length}. No '
          'plant key is anywhere near that; a name this long is either a '
          'mistake or memory somebody is trying to make this gateway hold');
    }
    try {
      resolver.resolve(raw);
    } on FormatException catch (malformed) {
      throw _refuse(method, '$method refused "$name": ${malformed.message}');
    }
    return raw;
  }

  /// A list of wire series names out of [name].
  ///
  /// The three arms `readMany` has (`value_handlers.dart:283-302`), in the
  /// same order and with the same message convention, because this is the
  /// same hazard: an unbounded breadth argument on one round trip.
  List<String> _seriesList(
      rpc.Parameters params, String name, String method) {
    final raw = params[name].valueOr(null);
    if (raw is! List) {
      throw _refuse(
          method,
          '$method needs a "$name" list: the one call that exists so a chart '
          'with four lines does not pay four round trips');
    }
    if (raw.isEmpty) {
      throw _refuse(
          method,
          '$method needs at least one series: a request for nothing is a '
          'round trip the client then waits on');
    }
    if (raw.length > config.maxKeysPerSubscribe) {
      throw _refuse(
          method,
          '$method carried ${raw.length} series, over this server\'s limit of '
          '${config.maxKeysPerSubscribe}; split the request or raise '
          'maxKeysPerSubscribe');
    }
    final names = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! String || entry.isEmpty) {
        throw _refuse(
            method,
            '$method\'s "$name" carries a non-string or empty entry at '
            'index $i: every entry names a series, as `<series>` or '
            '`<series>:<member>`');
      }
      // The whole call, not the one entry — unlike `readMany`, whose per-key
      // rejection map exists because a page config carries ~1500 hand-edited
      // keys and one typo must not cost the call. A chart asks for the four
      // series it is drawing, and a malformed one is a bug in the chart.
      try {
        resolver.resolve(entry);
      } on FormatException catch (malformed) {
        throw _refuse(
            method,
            '$method refused "$name" entry $i: ${malformed.message}');
      }
      names.add(entry);
    }
    return names;
  }

  /// Refuses a window whose start is after its end.
  ///
  /// **Refused, not answered empty.** The honest answer to "everything
  /// between 08:00 and 06:00" is that the question is wrong; an empty list
  /// would be read as "nothing was recorded in that window", which is a
  /// statement about the plant rather than about the request.
  ///
  /// The downsampled path needs it most: `queryTimeseriesDataDownsampled`
  /// opens with `from.isBefore(to) ? from : to` and quietly answers the window
  /// the caller did not ask for, so two callers sending opposite arguments get
  /// identical answers and neither is told which one it got.
  ///
  /// A zero-width window is accepted — "what was recorded at exactly this
  /// moment" is a real question — so the test is *after*, not *not-before*.
  static void _requireForwardWindow(
      DateTime? from, DateTime to, String method) {
    if (from == null || !from.isAfter(to)) return;
    throw _refuse(
        method,
        '$method was given a window whose "from" ($from) is after its "to" '
        '($to). It is refused rather than answered empty, and rather than '
        'silently swapped: an empty answer reads as "nothing was recorded", '
        'which is a claim about the plant instead of about the request');
  }

  /// A required instant out of [name], as epoch milliseconds.
  static DateTime _requiredInstant(
          rpc.Parameters params, String name, String method) =>
      _instant(params, name, method, required: true)!;

  /// An instant out of [name], or null when it is absent and optional.
  ///
  /// **Epoch milliseconds, never an ISO string.** That is what the client
  /// sends (`client_sub_apis.dart`'s `msOf`), and reading one through
  /// `(raw as num).toInt()` the way the port source does turns a caller's
  /// wrong type into a cast error inside the handler — which the session
  /// reports as `handlerFailed`, documented as "possibly transient: retrying
  /// is legitimate", for a request that will never succeed.
  static DateTime? _instant(rpc.Parameters params, String name, String method,
      {bool required = false}) {
    final raw = params[name].valueOr(null);
    if (raw == null) {
      if (!required) return null;
      throw _refuse(
          method,
          '$method needs "$name": an instant in epoch milliseconds. There is '
          'no default for it — substituting "now" would answer a different '
          'question than the one asked');
    }
    if (raw is! int) {
      throw _refuse(
          method,
          '$method needs "$name" as an integer number of epoch milliseconds, '
          'not ${raw.runtimeType}. Instants travel as milliseconds on this '
          'wire, in both directions');
    }
    return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
  }

  /// A required integer out of [name], inside `[atLeast, atMost]` inclusive.
  ///
  /// Each of the three integers this family carries multiplies work the
  /// *database* does, so each is read as a bound rather than coerced, and each
  /// band carries [why] — the sentence that says what the number outside it
  /// would have made the database do. A bare "out of range" is a refusal
  /// nobody can act on, and the reason is the part 10-07 and 10-10 will read
  /// when they widen one.
  static int _requiredInt(rpc.Parameters params, String name, String method,
      {required int atLeast, required int atMost, required String why}) {
    final raw = params[name].valueOr(null);
    if (raw is! int) {
      throw _refuse(
          method,
          '$method needs an integer "$name", not ${raw.runtimeType}. It '
          'scales the work the database does, so it is read as a bound '
          'rather than coerced');
    }
    if (raw < atLeast || raw > atMost) {
      throw _refuse(
          method,
          '$method\'s "$name" was $raw, outside $atLeast..$atMost: $why');
    }
    return raw;
  }

  /// Samples, encoded.
  static List<Object?> _points(List<TimeseriesData> points) =>
      [for (final point in points) point.toJson()];

  /// Runs [ask], mapping a refused-because-too-large result onto the wire.
  ///
  /// **INVALID_PARAMS, deliberately, and not `handlerFailed` (-32011).** The
  /// wire documents -32011 as "possibly transient: retrying is legitimate",
  /// and a panel that retries a month-long window forever is precisely the
  /// denial of service the bound exists to prevent. A too-large query is a bad
  /// *request*: the limit is fixed, the window is the caller's, and the fix is
  /// in the caller's hands. The message carries the limit, what was measured
  /// and the name of the method that would answer the same question inside it
  /// (`result_too_large.dart`), because a refusal an engineer cannot act on is
  /// a broken chart with extra steps.
  ///
  /// It is also **not a close**. Letting the over-large answer through would
  /// have the conflating send buffer evict the session with `4004`, which
  /// reports "your query was too large" as "you disconnected" — a
  /// query-too-large misread as backpressure, the class of failure this
  /// project exists to prevent (10-CONTEXT amendment 3).
  ///
  /// Nothing raises it yet: 10-07's reader and 10-10's byte ceiling do. The
  /// mapping is here now because the *code* is a wire decision and this is
  /// where the wire is.
  static Future<T> _sized<T>(String method, Future<T> Function() ask) async {
    try {
      return await ask();
    } on ResultTooLarge catch (tooLarge) {
      throw _refuse(method, '$method refused: ${tooLarge.message}');
    } on SourceRefusal catch (refusal) {
      // **The other half of the same sentence** (10-10). A refusal that cannot
      // become a disconnect is worth little if it becomes an infinite retry
      // instead.
      //
      // Everything a handler throws and does not catch reaches the wire as
      // `handlerFailed` (-32011) through `relay_session.dart`'s catch-all, and
      // the wire documents that code as *possibly transient: retrying is
      // legitimate*. Right for "the historian is not connected"; wrong for "no
      // series by that name is collected here", which no retry can make true.
      // 10-07, 10-08 and 10-09 each flagged it and none could close it: the
      // refusals are declared in `tfc_relay_local` and the dependency edge runs
      // local → server, so this file cannot name the sealed family.
      // [SourceRefusal] is the one fact it can name.
      //
      // A retryable refusal is **rethrown untouched**, on purpose: -32011 is
      // the correct answer for it, and a mapping that turned every source
      // refusal into a bad request would tell a panel its perfectly good query
      // was malformed every time the database bounced.
      if (refusal.retryable) rethrow;
      throw _refuse(method, '$method refused: ${refusal.message}');
    }
  }

  /// One [BrowseNode] out of [name], or a refusal that names the parameter.
  ///
  /// The decode is guarded rather than left to `params[name].asMap`, which
  /// raises a `RpcException` of its own with **no** `data` — and json_rpc_2
  /// then fills that `data` with the offending request, which is the shape
  /// this whole file exists to avoid.
  static BrowseNode _node(rpc.Parameters params, String name, String method) {
    final raw = params[name].valueOr(null);
    if (raw is! Map) {
      throw _refuse(
          method,
          '$method needs an object "$name": a browse node as the client '
          'received it, with at least an "id"');
    }
    return BrowseNode.fromJson(_object(raw));
  }

  /// A JSON map with its keys narrowed to strings.
  ///
  /// `json_rpc_2` hands back `Map<Object?, Object?>` and every `fromJson` in
  /// the protocol package takes `Map<String, Object?>`. Copied verbatim from
  /// `served_state_man.dart:746-747`.
  static Map<String, Object?> _object(Map<Object?, Object?> raw) =>
      {for (final entry in raw.entries) '${entry.key}': entry.value};

  /// A refusal with the armor already on it.
  ///
  /// See this library's doc for why `data` is pre-substituted and why the
  /// general constructor is used rather than `RpcException.invalidParams`.
  static rpc.RpcException _refuse(String method, String why) =>
      rpc.RpcException(rpc_errors.INVALID_PARAMS, why,
          data: _substitute(method));

  /// Copied verbatim from `value_handlers.dart` and `served_state_man.dart`.
  static Map<String, Object?> _substitute(String method) => {
        'method': method,
        'request': 'omitted: echoing a request that may carry a non-finite '
            'number is what makes the error itself unencodable, and an '
            'unencodable error on a path with no deadline is a hang',
      };
}
