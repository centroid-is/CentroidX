/// The `StateManApi` a panel holds: the same shape as `ChannelStateMan`, with
/// the four things that file deliberately omits wired around it.
///
/// `channel_state_man.dart:11-16` says outright that it was written as a
/// rehearsal for this class — "same store, same synchronous-answers-from-cache
/// shape, same `subscribe` adapter over the same node. What it is missing is
/// everything a socket forces — reconnect, resync, sequence gaps and
/// per-request deadlines". This file is that class with the missing four
/// supplied, so it is a copy where it can be (including the comments, because
/// the comments are the reasoning) and different only where a socket makes it
/// different. Those differences, in full:
///
///  1. **No connection at construction.** The shared contract suite calls
///     `StateManApi Function() make` synchronously (04-RESEARCH Finding 6), so
///     there is nothing to await in a constructor. `_peer` is therefore not a
///     field here at all: it is owned by [ConnectionSupervisor], swapped on
///     every reconnect, and read through [ConnectionSupervisor.peer] at the
///     moment of each call. That constraint is also the right production shape
///     — a panel boots with the rest of the line, and a client that threw at
///     power-on would put the plant's start-up order in the operator's hands.
///
///  2. **Every async method waits on the readiness barrier.** `read`, `listen`,
///     `keys` and `subscribe` do not: they are cache reads by design
///     (`state_man_api.dart:90-96`, "synchronous and never a round trip"), and
///     a page that blocked on the socket before it could paint would be grey at
///     exactly the moment an operator needs to see the last known value marked
///     stale.
///
///  3. **Handler registration is per connection, not per client.** In
///     `ChannelStateMan` the `registerMethod` block lives in the constructor
///     because there is one `Peer` for life. A fresh `Peer` per socket means
///     fresh registrations per socket, so that block lives in the supervisor's
///     per-connection setup and not here.
///
///  4. **Every request carries a deadline** (`deadline.dart`), and every
///     failure goes through one classifier (`failure_taxonomy.dart`). A closed
///     transport is reported by `json_rpc_2` as a `StateError`, so a call site
///     that caught only `RpcException` would never see the link die.
///
/// **One store per subscription, and why this class owns the map.** A
/// `ValueStore` holds a single sequence counter, so N subscriptions sharing one
/// store rebuild client-side the false-gap hazard the server refuses
/// server-side (04-04). The supervisor takes `subscriptions` and `storeFor` by
/// reference and never invents an entry — page lifecycle is this class's, which
/// is why the maps live here and the supervisor only re-establishes what it is
/// given.
///
/// **This class owns the panel's one pinned `HttpClient`**, which is what
/// makes it `dart:io`-only — the same price `ws_transport.dart` pays and for
/// the same reason: a `SecurityContext` can only be handed to a dial through
/// an `HttpClient`, and SEC-02 is that context. It is built once here, closed
/// over by the default dial, and closed in [RemoteStateMan.dispose]; a fresh
/// one per attempt would re-parse the mounted root and leak a connection pool
/// on every reconnect, on the one path that only runs when something is
/// already wrong.
///
/// What breaks in the plant without this file: nothing on a panel can read a
/// tag. It is the whole client surface.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'backoff.dart';
import 'client_config.dart';
import 'client_sub_apis.dart';
import 'clock_offset.dart';
import 'connection_supervisor.dart';
import 'deadline.dart';
import 'failure_taxonomy.dart';
import 'freshness_watchdog.dart';
import 'heartbeat_pump.dart';
import 'readiness_barrier.dart';
import 'subscription_state.dart';
import 'ws_transport.dart';

/// The subscription a client opens for the keys it was constructed with.
///
/// One name, because a panel shows pages and this class is handed a page's key
/// set; a second subscription is a second entry in [_subscriptions], which is
/// the shape the supervisor and the resync engine already take.
const String defaultPageSubscription = 'page';

/// A `StateManApi` whose values only ever arrive over a WebSocket.
final class RemoteStateMan implements StateManApi {
  /// Points a client at [uri] and starts dialling. Never throws, never blocks.
  ///
  /// [keys] is the page this panel is showing. It becomes one subscription,
  /// re-established by the supervisor on every reconnect; an empty set is a
  /// legitimate client that reads and writes without watching anything.
  RemoteStateMan({
    required this.uri,
    required this.config,
    Set<String> keys = const <String>{},
    String page = defaultPageSubscription,
    Backoff? backoff,
    PeerInfo client = const PeerInfo('tfc_relay_client', '0.1.0'),
    void Function(StatusParams status)? onStatus,
    void Function(String reason)? onBye,
    Future<ConnectAttempt> Function(Uri uri)? dial,
  }) : _page = page {
    // First, before anything is allocated and long before anything is dialled.
    // The combination this refuses — `wss` with no pinned root — cannot be
    // diagnosed from the failure it produces: every handshake dies with the
    // same `CERTIFICATE_VERIFY_FAILED` a genuine impostor produces
    // (06-RESEARCH §A.3). A panel that constructs and then fails forever is a
    // support call about an attack that is not happening.
    config.checkDialable(uri);

    // One per panel, built here, closed in [dispose] (T-06-22).
    //
    // Not one per attempt. `SecurityContext` parses the root PEM when it is
    // built, and an `HttpClient` owns a connection pool; a panel on a flapping
    // link redials all shift, so a context built inside the dial would re-read
    // the file and leak a pool per attempt — on the one code path that already
    // only runs when something is wrong. Held here rather than in
    // `ConnectionSupervisor` because that class's `dial:` seam is documented
    // as "one attempt in, one `ConnectAttempt` out": hanging an object with a
    // lifetime off it would make it something else.
    final tls = config.tls;
    if (tls != null) {
      // The provisioned root and nothing else. With `withTrustedRoots: false`
      // the machine's own store is never consulted, so a rogue root installed
      // on the station cannot vouch for anything claiming to be the gateway
      // (T-06-20) — which is also why our own gateway is refused by a client
      // that skips this (SEC-02's system-roots arm). The root arrives one of
      // two ways — a mounted file, or the PEM text the trust-acquisition flow
      // pinned after the operator approved its fingerprint — and both land on
      // the same context: the pin does not know or care how it was
      // provisioned, which is what `tls_pem_pin_test.dart`'s foreign-CA arm
      // holds it to.
      final context = SecurityContext(withTrustedRoots: false);
      final pem = tls.rootCertPem;
      if (pem != null) {
        context.setTrustedCertificatesBytes(utf8.encode(pem));
      } else {
        context.setTrustedCertificates(tls.rootCertPath!);
      }
      _pinned = HttpClient(
        context: context,
      )
        // The second bound under the abandoned dial.
        // `IOWebSocketChannel.connect` applies `connectTimeout` as a
        // `Future.timeout`, which abandons the connect rather than cancelling
        // it, leaving roughly three descriptors per attempt that nothing
        // reclaims (06-07: fds 36→64 over six seconds of redials). The
        // backoff does not bound that — at the 30 s cap a panel pointed at a
        // gateway that swallows handshakes accumulates for the whole fault —
        // and `HttpClient.connectionTimeout` *cancels*.
        ..connectionTimeout = config.connectTimeout;
    }

    if (keys.isNotEmpty) {
      _subscriptions[page] =
          SubscriptionState(subId: page, keys: <String>{...keys});
      for (final key in keys) {
        _subOf[key] = page;
      }
    }

    // The app heartbeat, built here beside the watchdog because the two are
    // the same lifetime and opposite directions: the watchdog judges the
    // gateway's silence, the pump prevents ours. Unlike the watchdog it is
    // **owned here rather than handed over** — the supervisor is given it only
    // so the `hello` handler can teach it the gateway's deadline, and this
    // class starts it, stops it and disposes it, next to every other thing
    // that follows `LinkState`. Its closures read `_supervisor`, which is
    // assigned on the next statement; nothing calls them before then.
    _heartbeat = HeartbeatPump(
      config: config,
      isReady: () => _supervisor.state == LinkState.ready,
      peer: () => _supervisor.peer,
      // The delivery ack (16-02-DECISION §5.1). Read straight off the
      // subscription state the resync path already maintains, so the pump
      // owns no counter of its own that could disagree with what this client
      // has actually applied — and so an ack can never claim a frame the
      // supervisor rejected.
      //
      // `lastSeq == null` is an unestablished subscription: it has been asked
      // for but no snapshot has landed, so there is nothing it could honestly
      // acknowledge. Those are omitted rather than sent as a zero, which the
      // gateway would read as a page 10 000 frames behind.
      ackSource: () => {
        for (final state in _subscriptions.values)
          if (state.lastSeq case final seq?) state.subId: seq,
      },
      // A gateway whose deadline this panel's floor cannot beat reaps it
      // anyway, with the pump running (07-REVIEW WR-01). It surfaces on the
      // one diagnostic list this client has rather than in the silence that
      // hid the original defect for a phase.
      onComplaint: (complaint) => _supervisor.resync.complain(complaint),
    );

    // Built here and handed over: `ConnectionSupervisor.dispose` disposes the
    // watchdog and the barrier it was given, so these must not be shared with a
    // second supervisor (04-07 handoff). This client owns exactly one.
    _supervisor = ConnectionSupervisor(
      uri: uri,
      config: config,
      backoff: backoff ??
          Backoff(base: config.backoffBase, cap: config.backoffCap),
      barrier: ReadinessBarrier(),
      watchdog: FreshnessWatchdog(
        config: config,
        // Pushed rather than dropped (04-REVIEW CR-06). The watchdog computed
        // all of this correctly and nothing above it could read a word: an
        // empty callback here, `_supervisor` private, and `FreshnessWatchdog`
        // deliberately not exported. Deferring the Flutter widgets defers the
        // *rendering*; it does not defer the signal, and there was no signal.
        onViewFreshnessChanged: (stale) {
          if (!_freshness.isClosed) _freshness.add(stale);
        },
      ),
      subscriptions: _subscriptions,
      storeFor: _storeFor,
      heartbeat: _heartbeat,
      client: client,
      onStatus: onStatus,
      onBye: onBye,
      // The gateway's `preferences.changed` reaches every local listener
      // through the one API that owns the broadcast controller.
      onPreferenceChanged: (key) => preferences.announce(key),
      // In production this is [_dialGateway]: `connect` with this panel's one
      // pinned client and its dial ceiling closed over. A harness supplies its
      // own so a contract leg can be built synchronously against a server
      // whose port is only known asynchronously — see
      // `connection_supervisor.dart`'s `_dial`.
      dial: dial ?? _dialGateway,
    );

    // Attached **before** `start()`. The supervisor can reach `ready` in the
    // same event-loop turn the connect completes in, so a listener attached
    // afterwards waits for a transition that already happened — the ordering
    // trap `ws_fault_test.dart:118-121` names from the other end.
    _transitions = _supervisor.states.listen(_onLinkState);
    _supervisor.start();
  }

  /// Where the gateway is.
  final Uri uri;

  /// The deadlines, the backoff window and the staleness horizon.
  final ClientConfig config;

  /// The subscription this client's constructor keys were filed under.
  final String _page;

  /// The pages this panel is showing. Read by the supervisor; owned here.
  final Map<String, SubscriptionState> _subscriptions =
      <String, SubscriptionState>{};

  /// One cache per subscription — see the library doc on the shared-counter
  /// hazard a single store would rebuild.
  final Map<String, ValueStore> _stores = <String, ValueStore>{};

  /// key → the subscription whose store holds it.
  ///
  /// Fixed at the moment the key is first filed, and never moved: a key that
  /// changed stores would change *node identity*, and a widget holds the node
  /// it was handed.
  final Map<String, String> _subOf = <String, String>{};

  /// Closers for the streams [subscribe] handed out that are still open.
  ///
  /// The shape is `channel_state_man.dart:114-119`'s, including the
  /// self-deregistering closer: a registry that only grows is a leak, and a
  /// panel runs for a shift.
  final _closeHandedOutStreams = <Future<void> Function()>{};

  /// Commands whose outcome this client cannot establish.
  ///
  /// A `WriteUnknown` is the only verdict that lands here and the only one that
  /// stays: applied, rejected and never-received are all settled answers, and
  /// re-querying a settled answer is a question nobody needed asked.
  final _unresolved = <String>{};

  /// key per unresolved command, so a re-query's answer can be adopted.
  ///
  /// A `writeStatus` result carries a `cmd` and no key, and the readback has to
  /// land on the tag it was read from. Bounded by [_unresolved]: an entry
  /// leaves the moment its command settles.
  final _keyOf = <String, String>{};

  /// Every `writeStatus` re-query this client has issued, in order.
  ///
  /// The observable the no-re-actuation property is asserted against: an
  /// implementation that re-sent the write instead would leave this empty and
  /// [debugWritesSent] one higher.
  final _writeStatusQueries = <List<String>>[];

  /// What those re-queries came *back* with, in order.
  ///
  /// The other half of the same observable, and the one 04-REVIEW CR-02 was
  /// found through: a case can assert that the re-query went out and that
  /// nothing was re-sent while the gateway is answering `not_received` — the
  /// one verdict that licenses re-actuating a machine — about every command
  /// whose fate is genuinely unknown.
  final _writeStatusAnswers = <WriteResult>[];

  /// How many entries each debug history keeps. See [_record].
  static const int _debugHistory = 64;

  final _resolved = StreamController<WriteResult>.broadcast();

  /// Transitions of the whole view between fresh and stale. Broadcast, and fed
  /// by the watchdog's own transition callback — so it emits when the answer
  /// changes and not twenty times a second.
  final _freshness = StreamController<bool>.broadcast();

  var _writesSent = 0;
  var _requerying = false;
  var _requeryWanted = false;

  /// The one client every dial of this panel's goes through, or null when
  /// [ClientConfig.tls] is null and the panel dials plaintext.
  ///
  /// Built once in the constructor and closed in [dispose]. Nothing reassigns
  /// it: a second one would mean a second parse of the root PEM and a second
  /// connection pool, which is the flapping-link leak T-06-22 names.
  HttpClient? _pinned;

  late final ConnectionSupervisor _supervisor;
  late final StreamSubscription<LinkState> _transitions;

  /// The app heartbeat. Started on entry to `ready`, stopped on leaving it and
  /// on [dispose] — see [_onLinkState].
  late final HeartbeatPump _heartbeat;

  var _disposed = false;

  /// Commands still in flight, for the case that has to prove the set was not
  /// empty when the re-query ran.
  List<String> get debugUnresolvedCmds => List<String>.unmodifiable(_unresolved);

  /// The cmd lists this client has re-queried, in order.
  List<List<String>> get debugWriteStatusQueries => [
        for (final query in _writeStatusQueries) List<String>.unmodifiable(query),
      ];

  /// The answers those re-queries came back with, in order.
  List<WriteResult> get debugWriteStatusAnswers =>
      List<WriteResult>.unmodifiable(_writeStatusAnswers);

  /// Every write whose outcome was established *after* the call that made it
  /// had already resolved — the `writeStatus` re-query's answers.
  ///
  /// Broadcast, and never a second source of truth: what an applied outcome
  /// says about the value is already in the store by the time this emits. It
  /// exists so an operator who was shown "unknown" is shown the resolution
  /// when it arrives, rather than having to remember to ask.
  Stream<WriteResult> get onWriteResolved => _resolved.stream;

  /// How many `write` requests reached the wire. Never more than one per call.
  int get debugWritesSent => _writesSent;

  // -------------------------------------------------------------- the link

  /// Where the connection is right now, for the operator-facing indicator.
  LinkState get linkState => _supervisor.state;

  /// Every transition, in order.
  Stream<LinkState> get linkStates => _supervisor.states;

  /// Whether a call issued right now would go straight out.
  bool get isReady => _supervisor.barrier.isOpen;

  /// Why the last connection ended, in words an integrator can act on.
  String? get lastDownReason => _supervisor.lastDownReason;

  /// Set when the gateway refused this build outright and the loop gave up.
  String? get stopReason => _supervisor.stopReason;

  /// Why the gateway last told this connection to rebuild, when that reason was
  /// a stall — `'gateway_stalled'`, or null when no stall has been announced on
  /// the current connection.
  ///
  /// **Distinct from [lastDownReason] and [stopReason] on purpose.** Those two
  /// are about the *socket*: it dropped, or the gateway refused this build. This
  /// is about the gateway's own event loop freezing while the socket stayed up
  /// — the F22 case an operator must be able to tell apart from "you
  /// disconnected", because a Veeam snapshot froze the plant for everyone at
  /// once and no cable was pulled. The gateway puts the fact on the wire
  /// (`ResyncParams.reason == 'gateway_stalled'`); this getter is where it
  /// finally reaches a surface a widget can bind to.
  ///
  /// Reset on a fresh connection: a stall reported over a previous socket is
  /// not a fact about this one.
  String? get stallReason => _supervisor.stallReason;

  /// How long the gateway said it was frozen, in milliseconds — the **absolute**
  /// figure the gateway sent (`ResyncParams.stalledMs`), never recomputed from
  /// this panel's clock. Null when no stall has been announced on this
  /// connection, **or** when the gateway announced one without a duration:
  /// `ResyncParams.stalledMs` is nullable on the wire and is stored as-is, so
  /// a widget must not treat a non-null [stallReason] as a promise that this
  /// is non-null — the complaint text already words both cases.
  ///
  /// It is the whole content of the operator sentence: "the plant view was
  /// frozen for N ms". It lives here rather than only in [complaints] because a
  /// complaint list is a diagnostic an engineer reads tomorrow, not a value a
  /// widget renders now.
  int? get stalledMs => _supervisor.stalledMs;

  /// How long ago this connection's stall was announced — the "when" a widget
  /// renders beside [stalledMs], so "gateway stalled for 5015 ms" cannot read
  /// as current hours after the fact (09-REVIEW IN-05). Null exactly when
  /// [stallReason] is null; cleared with the pair on a fresh connection.
  ///
  /// Measured on this panel's monotonic clock: it is the *capture* age of a
  /// display fact, not a wire fact, so there is no gateway clock arithmetic
  /// to drift and no NTP step can age or un-age it. Deliberately not a
  /// `StateManApi` member, like the rest of the stall surface — this is the
  /// designed getter seam `lastDownReason` established.
  Duration? get stallAge => _supervisor.stallAge;

  /// Configuration problems collected while re-establishing pages — a rejected
  /// key, a snapshot entry naming a handle nobody announced. Never thrown: a
  /// page carries ~1500 hand-edited keys and one typo must cost one tag.
  List<String> get complaints =>
      List<String>.unmodifiable(_supervisor.resync.complaints);

  /// Every timer this client *schedules*: the watchdog's one link deadline,
  /// plus the pending reconnect when an attempt is scheduled.
  ///
  /// Two is the ceiling, and the ceiling is the design — a panel that flaps
  /// all shift accumulates one orphaned timer per cycle if a teardown misses
  /// one, and the one that is missed fires into a connection that no longer
  /// exists. It deliberately does **not** count the per-call timers
  /// `Future.timeout` allocates (04-REVIEW IN-01): those are owned by the call
  /// and cancelled when it settles either way, which is the property that
  /// actually matters — no timer outlives the thing it belongs to — and a
  /// panel with ten calls out legitimately holds twelve.
  int get debugTimerCount => _supervisor.debugTimerCount;

  /// The heartbeat's own timer: 1 while the link is ready, 0 otherwise.
  ///
  /// **Counted separately rather than folded into [debugTimerCount]**, and the
  /// separation is the point. That number is a ceiling on the *reconnect*
  /// machinery — the watchdog's deadline and a pending dial — and every case
  /// that asserts it is asserting something about a link that is coming and
  /// going. Adding a term to it that is 1 exactly when the link is up would
  /// make every one of those assertions read differently on either side of a
  /// reconnect, for a timer that has nothing to do with reconnecting.
  int get debugHeartbeatTimerCount => _heartbeat.debugTimerCount;

  /// How many heartbeats this panel has put on the wire.
  ///
  /// The anti-vacuity observable for a liveness case: "nobody threw the panel
  /// off" is also true of a panel nothing was measuring, and this is how a
  /// case says the silence it held was filled by the pump rather than by luck.
  int get debugHeartbeatsSent => _heartbeat.debugHeartbeatsSent;

  // ------------------------------------------------------------ freshness

  /// Whether the link has gone [ClientConfig.freshnessDeadline] without a
  /// frame of any kind.
  ///
  /// The operator-facing half of CLAUDE.md's first constraint: half-open
  /// connections detected in seconds, staleness always visible. The client
  /// also *acts* on it — see `connection_supervisor.dart`'s `_linkWentQuiet` —
  /// so this normally goes true a moment before [linkState] leaves `ready`.
  bool get viewIsStale => _supervisor.watchdog.viewIsStale;

  /// Every transition of [viewIsStale], and only the transitions.
  Stream<bool> get viewFreshness => _freshness.stream;

  /// Subscriptions whose plant-side source is not being re-evaluated, judged
  /// against the gateway's clock **now** — not against the last frame to
  /// arrive.
  ///
  /// Distinct from [viewIsStale] on purpose, and the distinction is the whole
  /// of CLI-04: this set can be non-empty while the link is provably healthy.
  /// The gateway is fine, one page's tags are not, and the operator needs to
  /// be told which of those two it is looking at.
  ///
  /// **Live, because a saturated link keeps delivering old frames**
  /// (07-RESEARCH §B.4): the last-tick verdict compares two fields of one
  /// delayed frame, agrees with itself for ever, and renders a minute-behind
  /// page as current. Computed on read, no timer.
  ///
  /// **Not converted with [clockOffset]**, which is a display conversion and
  /// nothing else. `FreshnessWatchdog.serverNowMs` estimates the gateway's
  /// clock from a monotonic anchor, so an NTP correction on this panel cannot
  /// move the verdict (07-REVIEW CR-01).
  Set<String> get staleSubscriptions =>
      _supervisor.watchdog.staleSubscriptionsNow();

  /// The same live verdict for the one page a widget renders.
  bool isSubscriptionStale(String sub) =>
      _supervisor.watchdog.isSubscriptionStaleNow(sub);

  /// The last-tick verdict, for the cases pinning `sawTick`. Never rendered.
  Set<String> get debugStaleSubscriptionsAtLastTick =>
      _supervisor.watchdog.staleSubscriptions;

  /// Whether this panel has a gateway-clock anchor yet.
  ///
  /// **The precondition under every subscription-staleness assertion, and the
  /// one nothing else can observe.** [staleSubscriptions] ages `evaluatedAt`
  /// against `FreshnessWatchdog.serverNowMs`, which is null until a tick frame
  /// has given it something to anchor on — and a panel with no anchor reports
  /// *nothing* stale, for ever, because there is no clock to be late against.
  /// That is the right behaviour: a guess about the gateway's clock is worse
  /// than an admission of ignorance.
  ///
  /// It is also indistinguishable, from outside, from a panel that has an
  /// anchor and judges everything fresh. A case that starves a link before the
  /// first tick has landed therefore waits for a verdict that can never come,
  /// and fails on its own budget having never reached the state it is named
  /// for. Values and ticks are separate frames, so "a value arrived" does not
  /// establish it.
  ///
  /// `debug` for the same reason [debugStaleSubscriptionsAtLastTick] is: it is
  /// a precondition a test establishes, never a thing a screen renders.
  bool get debugHasServerClock =>
      _supervisor.watchdog.serverNowMs != null;

  /// How far this panel's clock sits from the gateway's, captured at the last
  /// handshake.
  ///
  /// Surfaced because a panel whose clock is ten minutes wrong renders every
  /// timestamp ten minutes wrong, and CLI-05 rules that skew warns and keeps
  /// showing values rather than greying the plant. An operator cannot act on a
  /// warning nobody exposes.
  ClockOffset get clockOffset => _supervisor.clockOffset;

  // ------------------------------------------------- answers from the store

  /// The node for [key] — the same instance every time.
  @override
  ValueListenable<DynamicValue> listen(String key) => _storeOf(key).node(key);

  /// The last known value for [key], or null if none is known yet.
  ///
  /// Synchronous and never a round trip, whatever the link is doing. Null means
  /// "not known yet", which is a different thing from a known-bad value.
  @override
  DynamicValue? read(String key) => _storeOf(key).peek(key);

  /// The keys a value has actually arrived for.
  ///
  /// Filtered on arrival, exactly as `channel_state_man.dart:131-142` filters:
  /// [listen] creates a node for any key asked of it, including one mistyped
  /// into a page config, and offering that back to the picker would launder a
  /// typo into a valid binding.
  @override
  List<String> get keys => [
        for (final store in _stores.values)
          for (final key in store.keys)
            if (store.peek(key) != null) key,
      ];

  /// A broadcast view of the same node, for stream-consuming code.
  ///
  /// A view and never a second source of truth. Returned synchronously so
  /// taking the stream and listening to it happen in one turn, which is what
  /// stops a widget missing the first values of its own subscription.
  @override
  Stream<DynamicValue> subscribe(String key) {
    final node = _storeOf(key).node(key);
    late final StreamController<DynamicValue> controller;
    void push() => controller.add(node.value);
    late final Future<void> Function() close;
    close = () async {
      _closeHandedOutStreams.remove(close);
      await controller.close();
    };
    controller = StreamController<DynamicValue>.broadcast(
      onListen: () {
        node.addListener(push);
        _closeHandedOutStreams.add(close);
      },
      onCancel: () {
        node.removeListener(push);
        _closeHandedOutStreams.remove(close);
      },
    );
    // Added twice on purpose — once here, once in `onListen`. A stream nobody
    // ever listened to still has to be closable at dispose.
    _closeHandedOutStreams.add(close);
    return controller.stream;
  }

  // -------------------------------------------------- answers over the wire

  /// Forces a round trip and resolves with a freshly-read value.
  @override
  Future<DynamicValue> readFresh(String key) async {
    final raw = await _request(Methods.readFresh, {'key': key});
    return _value(_asJson(raw)['value']);
  }

  /// One round trip for many keys.
  ///
  /// One request for however many keys, which is the promise the interface
  /// makes (`state_man_api.dart:104-109`) and the reason the diagnostics page
  /// does not pay N latencies for N tags.
  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    final raw = _asJson(await _request(Methods.readMany, {'keys': keys}));
    final values = raw['values'];
    final answer = <String, DynamicValue>{
      if (values is Map)
        for (final entry in values.entries) '${entry.key}': _value(entry.value),
    };

    // A key the gateway refused is still a key the caller asked about, and it
    // comes back as a value that renders rather than as an absence that does
    // not. A missing map entry is indistinguishable from a key nobody
    // requested, so a diagnostics page writes a blank cell exactly where it
    // needed to write a fault — and a renamed PLC tag then survives on a page
    // for months looking like a tag that is merely quiet.
    //
    // `errorConfig` rather than a bad-comms code: nothing is broken upstream,
    // the page is asking for a tag this source does not serve, and that is a
    // sentence an engineer can act on. Whatever the gateway put in `rejected`
    // is the diagnosis; the quality is what makes it visible.
    final rejected = raw['rejected'];
    if (rejected is Map) {
      for (final entry in rejected.entries) {
        final key = '${entry.key}';
        // Never over a real reading: if the gateway somehow answered both, the
        // reading is the more specific fact.
        answer.putIfAbsent(
            key, () => DynamicValue(quality: Quality.errorConfig));
      }
    }
    return answer;
  }

  // -------------------------------------------------------- the sub-APIs

  /// Browse, timeseries, history views and preferences — all four over the same
  /// pipe, none of them holding a source of their own.
  ///
  /// Built once and kept, rather than minted per access, for one reason that
  /// only applies to the last of them (`channel_state_man.dart:443-448`):
  /// [preferences] owns the broadcast controller every local listener reads
  /// from, and a fresh instance per getter call would hand the second listener a
  /// stream nothing ever pushes to. The other three are stateless and are kept
  /// alongside it for symmetry.
  ///
  /// None of these has a gateway handler before Phase 10; until then they
  /// surface `-32601` (04-RESEARCH Finding 4), which is the honest answer and
  /// the gap 04-10 counts.
  @override
  late final BrowseApi browse = ClientBrowseApi(_dataServiceCall);

  @override
  late final TimeseriesApi timeseries = ClientTimeseriesApi(_dataServiceCall);

  @override
  late final HistoryViewApi historyViews =
      ClientHistoryViewApi(_dataServiceCall);

  @override
  late final ClientPreferencesApi preferences =
      ClientPreferencesApi(_dataServiceCall);

  // ------------------------------------------------------- the access families
  //
  // Four proxies in `client_sub_apis.dart`, following the four above exactly:
  // built once and kept, one request and one answer per member, no state, no
  // retry, no queue. Until 17-08 these getters refused with an
  // `UnsupportedError` naming the missing proxy; now the proxy exists and the
  // honest answer moved back to the far end, where the enforcement is — the
  // check sits above the store on the gateway, and a `forbidden` comes back
  // as the same `AccessDenied` a direct-mode refusal throws
  // (`withAccessErrors` in `client_sub_apis.dart`, one code wide like
  // `withTypedErrors` beside it).
  //
  // **Why the refusal mapping is not `failure_taxonomy.dart`'s.** That seam is
  // the write path's, and it answers a different question in a different
  // shape: `writeOutcomeFor` turns every failure into a `WriteResult` — a
  // value, never a throw — because `write` promises an outcome and an
  // operator deciding whether to re-actuate machinery needs "rejected" and
  // "unknown" kept apart. An access refusal has no three-state outcome to
  // report and no machinery behind it; what it needs is the direct path's
  // exception type, thrown. Routing it through the taxonomy would mean
  // teaching a WriteResult factory to throw AccessDenied for one code, which
  // is a second behavior inside one seam — so the sub-API translation pattern
  // (`withTypedErrors`) grew a sibling instead, and the taxonomy still sees
  // every access failure a caller lets escape to a write path.
  //
  // The client sends no identity on any of these frames — the gateway
  // attributes every write to the identity it verified at `hello` — and the
  // payload pin in `test/access_proxies_test.dart` is what keeps that true.

  @override
  late final AccessTemplateApi accessTemplates =
      ClientAccessTemplateApi(_dataServiceCall);

  @override
  late final AccessAdminApi accessAdmin =
      ClientAccessAdminApi(_dataServiceCall);

  @override
  late final AuditApi audit = ClientAuditApi(_dataServiceCall);

  @override
  late final BackendConfigApi backendConfig =
      ClientBackendConfigApi(_dataServiceCall);

  /// The request the sub-APIs are handed: the same barrier, the same deadline
  /// and the same peer-at-call-time capture as every other call this client
  /// makes.
  Future<Object?> _dataServiceCall(
          String method, Map<String, Object?> params) =>
      _request(method, params);

  // --------------------------------------------------- interactive sign-in
  //
  // Increment B of the 2026-09-08 no-station-file ruling. NOT on
  // `StateManApi`, deliberately: signing in is session vocabulary like
  // `hello` and `ping`, not a value operation, and a direct-mode StateMan
  // has no session to sign in on — the app's controller branches on the
  // transport and reaches these through the one RemoteStateMan it already
  // holds (the `backendConfig` route's own pattern).

  /// The username the gateway verified this session as at `hello`, or null.
  ///
  /// Advisory display material for attribution prose, never identity —
  /// [ConnectionSupervisor.verifiedAccount] carries the whole argument.
  String? get verifiedAccount => _supervisor.verifiedAccount;

  /// Whether this session was admitted with no credential and is waiting for
  /// a `session.login` — the client's view of the gateway's awaiting-sign-in
  /// sentinel. True means the socket is up and the sign-in screen is the
  /// thing to show; the value barrier is shut until a sign-in lands.
  bool get awaitingSignIn => _supervisor.awaitingSignIn;

  /// Completes when the hello is answered — whether or not the resync that
  /// follows can. The signal `session.login` waits behind, and the one a
  /// sign-in surface can await to know its socket is up. Distinct from
  /// [isReady], which is the *value* barrier and stays shut on an awaiting
  /// session.
  Future<void> get sessionReady => _supervisor.sessionReady;

  /// Signs a person in over the socket. The SERVER verifies (Argon2id
  /// behind its `AuthProvider` seam) and answers with the resolved
  /// user + role + groups; this client supplies a username, a password and
  /// an optional station *label* for the audit trail, and decides nothing.
  ///
  /// The password crosses inside the request frame once and is held on no
  /// field — [SessionLoginParams] withholds it from `toString`, and nothing
  /// on this path logs params. No retained credential is minted or stored
  /// anywhere: that is increment C's still-open owner decision, and a
  /// reconnect therefore lands back at the sign-in screen.
  ///
  /// Refusals arrive as the gateway's own `RpcException` — the marker
  /// vocabulary is [SessionAuthMarkers], and the caller maps it to a screen.
  /// A dead link is [LinkDown], exactly as every other call answers it.
  Future<SessionLoginResult> sessionLogin({
    required String username,
    required String password,
    String? station,
  }) async {
    final raw = await _sessionRequest(
        Methods.sessionLogin,
        SessionLoginParams(
                username: username, password: password, station: station)
            .toJson());
    final result = SessionLoginResult.fromJson(_asJson(raw));
    // The gate lifted at the far end; drive the resync it deferred so this
    // client's pages subscribe and it reaches `ready`. A no-op if the
    // session was not actually awaiting (there is no such path today, but
    // the supervisor guards it), and taken down like any other resync if the
    // now-permitted subscribe still fails.
    await _supervisor.resumeAfterSignIn();
    return result;
  }

  /// Signs out: the far end returns this session to its awaiting-sign-in
  /// sentinel and refuses everything but liveness and a fresh sign-in.
  /// Idempotent on a session that is already nobody — a reconnect may have
  /// reset the far end without this client knowing.
  Future<void> sessionLogout() =>
      _sessionRequest(Methods.sessionLogout, const <String, Object?>{});

  /// A request that waits on the SESSION gate rather than the value barrier.
  ///
  /// `session.login` and `session.logout` are the two methods that must reach
  /// the wire while the value barrier is shut — an awaiting session cannot
  /// read or subscribe, so [_request]'s `barrier.ready` wait would time out
  /// into [LinkDown] and a sign-in screen could never talk to the gateway.
  /// The session gate opens the moment the hello is answered, which is
  /// exactly when these two become answerable. Same peer-at-call-time
  /// capture and same deadline as [_request]; the only difference is which
  /// gate it waits behind.
  Future<Object?> _sessionRequest(
      String method, Map<String, Object?> params) async {
    _refuseIfDisposed(method);
    final budget = config.controlDeadline;
    try {
      await _supervisor.sessionReady.timeout(budget);
    } on TimeoutException {
      throw LinkDown(method);
    }
    _refuseIfDisposed(method);
    return callWithDeadline(
      () => _supervisor.peer,
      method,
      params: params,
      deadline: budget,
    );
  }

  // ------------------------------------------------------------- the write

  /// Writes [value] to [key] and reports what became of it.
  ///
  /// **Never throws to report an outcome, and never retried.** Both halves are
  /// the property rather than an omission (`CLAUDE.md`: no queue / no retry =
  /// the write-safety property). A retry here would be invisible from the API
  /// surface — same call, same result type, slightly later — and on a plant it
  /// is a second actuation of machinery an operator commanded once. What
  /// replaces it is [Methods.writeStatus] on the next `ready`: the client asks
  /// what became of the command, it does not send the command again.
  ///
  /// The `cmd` is minted **here**, at call time, because the call is the
  /// operator action (`state_man_api.dart:121-125`). It is the only handle
  /// `writeStatus` has on this write, so it goes into [_unresolved] before the
  /// request leaves — a socket that dies between the two would otherwise lose
  /// the one identifier the outcome can ever be reconciled against.
  ///
  /// A non-finite **value** and a non-finite **expect** are both refused
  /// outright, with an `ArgumentError` and before anything reaches the wire.
  /// See the two [ArgumentError]s in [_write] for what each one would cost.
  ///
  /// This path used to sanitize the value to `null` and send it, the way
  /// telemetry does (`channel_state_man.dart:207-227`) — but that is a
  /// server *fan-out* argument (one non-finite value fails the whole frame a
  /// real pipe shares with every other client) applied to this client's own
  /// request channel, where nothing has been sent yet and refusing costs
  /// nothing at all. `WriteParams` has always refused it one layer down; the
  /// two layers now hold one policy instead of two opposite ones.
  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _write(key, value, expect: expect, cmd: cmd);

  /// [write], plus the one thing a caller may not ask for: the hold flag.
  ///
  /// The flag is not on the public member and must not be put there. The
  /// interface already has [holdToRun], and a second way to say the same
  /// thing on the same interface is the ambiguity the surface test exists to
  /// prevent (D-P5-C). It lives here so that an engage and a release are
  /// built by the one request-building body every other write goes through —
  /// one deadline, one `_unresolved` entry, one `writeStatus` recovery, and
  /// exactly one place [Methods.write] is named.
  Future<WriteResult> _write(String key, Object? value,
      {Object? expect, String? cmd, bool hold = false}) async {
    // Both walks run before either refusal so that a non-finite buried in a
    // nested structure is caught too, not just a bare double.
    final sanitizedValue = sanitize(value);
    final sanitizedExpect = sanitize(expect);
    if (sanitizedValue.hadNonFinite) {
      throw ArgumentError.value(
          value,
          'value',
          'a write cannot carry a non-finite number: it encodes to null, and '
              'a write of null actuates the device with a value nobody chose '
              'while the operator is told the write applied');
    }
    if (sanitizedExpect.hadNonFinite) {
      throw ArgumentError.value(
          expect,
          'expect',
          'a write cannot carry a non-finite compare-and-set guard: nulling '
              'it is this path\'s encoding of "no guard at all", so a guarded '
              'write would silently become an unconditional one');
    }

    // Minted here when this client *is* the operator action, carried through
    // when it is relaying one already minted upstream of it. Either way there
    // is exactly one id for one action, which is what `writeStatus` reconciles
    // against after a reconnect.
    // One id, one operator action (04-REVIEW CR-05). [_unresolved] is a `Set`,
    // so two live writes sharing an id are one entry: whichever settles first
    // removes it, and the other's `WriteUnknown` is never re-queried. The
    // gateway is worse off still — both writes go upstream and the second
    // overwrites the first's outcome, so one `writeStatus` answer is reported
    // for two actuations and it is the wrong one for at least one of them.
    //
    // An `ArgumentError` and not a `WriteResult`, as the non-finite `expect`
    // refusal above is: nothing was sent, nothing is unknown, and the caller
    // handed this client the same id twice. That is a defect in the caller,
    // and reporting it as a plant outcome is how it survives to production.
    if (cmd != null && _unresolved.contains(cmd)) {
      throw ArgumentError.value(
          cmd,
          'cmd',
          'this command id is already in flight: one id means one operator '
              'action, and a second write under it would report the first '
              'one\'s outcome for both');
    }

    final id = cmd ?? newUlid();
    _unresolved.add(id);
    // The tag this id belongs to, so a re-query's readback can be adopted onto
    // it later — a `writeStatus` answer names the command and not the key.
    _keyOf[id] = key;

    // Whether any bytes were offered to a socket for this write. A `cmd` that
    // never reached one is a `cmd` no gateway can have an opinion about, and
    // re-querying it on every reconnect for the rest of the shift is how a
    // panel with a dead link grows an unresolved set until `writeStatus` is
    // refused for being over `maxKeysPerSubscribe` — taking the recovery path
    // for the *genuine* unknowns down with it.
    var dispatched = false;

    WriteResult result;
    try {
      final raw = await _request(
        Methods.write,
        // Through the shared DTO rather than a map literal (05-REVIEW IN-02).
        // The server decodes with `WriteParams.fromJson`; a hand-rolled
        // literal at this end meant the two halves of one wire shape were
        // kept in step by the test suite alone, which is the drift the shared
        // protocol package exists to prevent — and it left the DTO's `hold`
        // serialization with no production caller at all.
        //
        // The factory's own non-finite refusal cannot fire here: both halves
        // were refused above, with the messages this path owes the caller.
        // The sanitized values are handed over rather than the raw ones only
        // because they are provably the same objects once the refusals have
        // passed — nothing survives sanitization to be changed by it.
        WriteParams(
          cmd: id,
          key: key,
          value: sanitizedValue.value,
          expect: sanitizedExpect.value,
          hold: hold,
        ).toJson(),
        deadline: config.writeDeadline,
        onSend: () {
          dispatched = true;
          _writesSent++;
        },
      );
      // **Sanitized like every other ingress, and this was the one that was
      // not** (16-04 S8). The hello result, `u`, `tick`, `resync`, `status`
      // and the preference notifications all decode through
      // `_asJson(sanitize(...).value)` in `connection_supervisor.dart`; this —
      // the one message an operator's finger is waiting on — decoded straight
      // out of `_asJson(raw)`.
      //
      // What that admitted: `"at": 1e999` decodes to `Infinity` in silence
      // (that is the whole reason F28's sanitization exists), `at is num`
      // accepts it because `Infinity` is a `num`, and `at.toInt()` throws
      // `UnsupportedError`. The taxonomy below rethrows every `Error` on
      // purpose — a defect in this process must never be reported to an
      // operator as a condition of the plant — so the throw escaped `write`,
      // which had promised an outcome and never an exception.
      //
      // Sanitized it becomes null, `at is num` is false, and
      // `WriteResult.fromJson` answers `WriteUnknown` under
      // `malformed_result:applied` — its own existing verdict for an applied
      // answer with no legible instant on it, on the stated grounds that half
      // an audit record is not proof of application. That leaves the command
      // in [_unresolved] and therefore re-queryable, which is the one property
      // an unreadable answer must not cost.
      //
      // It covers the `readback` too, and by the same rule as everywhere else:
      // a non-finite reading is not a number this panel may put on a mimic.
      result = WriteResult.fromJson(_asJson(sanitize(raw).value));
    } catch (error) {
      // One seam decides whether this means "we do not know" or "the server
      // said no", and it rethrows anything that is a defect in this process
      // rather than a condition of the plant (`failure_taxonomy.dart`).
      result = _writeOutcomeFor(id, error);
    }

    // Only an established outcome settles the command. `WriteUnknown` is the
    // one verdict that does not, which is exactly what makes it re-queryable —
    // unless this client watched the request fail to leave, in which case
    // there is nothing on the far side to reconcile against.
    if (result is! WriteUnknown || !dispatched) {
      _unresolved.remove(id);
      _keyOf.remove(id);
    }

    _adoptReadback(key, result);
    return result;
  }

  /// [writeOutcomeFor], plus the one fact the taxonomy cannot know: this
  /// client is shutting down.
  ///
  /// A page that closes while a write is parked on the barrier gets a
  /// `StateError` out of [ReadinessBarrier.dispose] or [_refuseIfDisposed], and
  /// the taxonomy rethrows an unrecognised `StateError` on purpose — a defect
  /// in this process must never be reported to an operator as a plant
  /// condition. But `write` promises never to throw to report an outcome, and
  /// a closing page handed a `StateError` instead of a `WriteResult` is that
  /// promise broken at the one moment nobody is watching the screen.
  ///
  /// [_disposed] is a fact this object owns rather than a message match, so
  /// nothing widens here the way a string predicate widens. Unknown and not
  /// never-received: what this client knows is that it stopped looking.
  WriteResult _writeOutcomeFor(String cmd, Object error) {
    if (_disposed && error is StateError) {
      return WriteUnknown(
          cmd,
          WriteReason(FailureKind.linkDown,
              message: 'the panel was shut down before this write could be '
                  'sent: ${error.message}'));
    }
    return writeOutcomeFor(cmd, error);
  }

  /// Puts an applied write's readback into the store before the write resolves.
  ///
  /// **This closes a race the caller cannot see and cannot work around.** The
  /// gateway answers the write on the RPC path and pushes the new reading on
  /// the subscription path, and the subscription path is tick-quantised and
  /// conflated — so the response routinely wins. For the caller that means
  /// `await write(...)` returns `WriteApplied(readback: 1500)` while
  /// `read(key)` still says 1200 and the value still wears the pending badge
  /// the plant stamped on it when the write went upstream. A mimic redrawn on
  /// that turn shows the operator the setpoint they typed over, still amber,
  /// after the confirmation has already arrived — and if the tick that would
  /// have corrected it is the one lost to a reconnect, it shows it until the
  /// next change on that key.
  ///
  /// The readback is not a guess: it is what the device reported holding, and
  /// `WriteResult`'s whole design is that the readback is the only confirmation
  /// there is. Adopting it is applying the confirmation, not predicting it —
  /// which is exactly why the *typed* value is never adopted, and why nothing
  /// is adopted for a rejected, unknown or never-received outcome. Those leave
  /// the last confirmed reading standing, which is the honest thing to show
  /// when nobody upstream has agreed to anything.
  ///
  /// The push that follows carries the same reading, so `applyBatch`'s equality
  /// guard makes it free: one notification for one write, not two.
  ///
  /// **Two things it refuses to adopt, and it is total over both** (16-04).
  /// A readback is a confirmation about *an instant*, and this is the one place
  /// that instant is in hand next to the instant already on the page. Neither
  /// check belongs in [ValueStore.applyBatch]: a `seq`-less batch is also how a
  /// **snapshot** is applied, and a snapshot legitimately carries stamps older
  /// than the cache when the plant is quiet — a store that refused older values
  /// outright would refuse the recovery path this whole client resyncs through.
  ///
  /// Neither refusal throws, and that is the second half of the fix. This is
  /// called from `_write` *after* the command has been struck from
  /// [_unresolved] and *outside* the try that would have turned a failure into
  /// an outcome, so anything thrown here escapes `write` — the operator is
  /// shown an error for a write that landed and was read back, about a command
  /// nothing will re-query. An operator shown a failure for a write that
  /// succeeded is an invitation to re-actuate.
  void _adoptReadback(String key, WriteResult result) {
    if (_disposed) return;
    if (result is! WriteApplied) return;

    // **S8: a stamp that is not an instant.** `1e17` ms is finite, so nothing
    // upstream of here refuses it — an unset RTC or a microsecond/millisecond
    // unit confusion produces exactly this — and
    // `DateTime.fromMillisecondsSinceEpoch` throws `RangeError` outside
    // ±[_representableMs]. The outcome itself is untouched: the gateway
    // established `applied` and named the readback the device reported
    // holding, and refusing to *stamp the page* is not grounds to unsay that.
    // Reporting unknown here would send a fitter out to look at a machine that
    // already reported back, which is how a plant learns to ignore the word.
    if (result.at.abs() > _representableMs) {
      _declineReadback(
          key,
          'the gateway stamped it ${result.at} ms from the epoch, which is not '
          'an instant this panel can represent — the write itself stands as '
          'applied, but nothing here can say when');
      return;
    }
    // `at` is epoch milliseconds on the wire; UTC here for the same reason
    // `WireValue.toDynamicValue` uses it — a local-time stamp would be compared
    // against gateway stamps that are not.
    final stamp = DateTime.fromMillisecondsSinceEpoch(result.at, isUtc: true);

    // **S3: a readback older than what is already on the page.** A write is
    // dispatched at t0 and its answer lost; the tag moves to something else at
    // t1 > t0 while the panel is dark; the resync lands that, correctly; and
    // then the reconnect's `writeStatus` re-query answers `applied` with the
    // t0 readback. Adopting it puts a superseded reading back on the mimic
    // under [Quality.good] — and the gateway conflates, so it will not re-push
    // the truth unless the tag changes again. On a quiet plant the wrong
    // number stands for the rest of the shift, wearing the one badge that says
    // it can be acted on.
    //
    // Strictly older, not "not newer": the ordinary race this method exists
    // for is the RPC answer beating a tick-quantised push carrying the same
    // reading, and those share an instant. Refusing an equal stamp would put
    // the pending badge back for a whole tick on every write.
    //
    // A cached value with no stamp at all is adopted onto, because there is
    // nothing to compare and inventing an ordering would be worse than the
    // race: it would silently stop confirming writes on every source that does
    // not report source times.
    final store = _storeOf(key);
    final cached = store.peek(key)?.sourceTime;
    if (cached != null && stamp.isBefore(cached)) {
      _declineReadback(
          key,
          'it is stamped $stamp and the reading already on the page is stamped '
          '$cached, so adopting it would put a superseded value back under '
          'good quality — and a conflating gateway would not correct it until '
          'the tag next moves');
      return;
    }

    // A clamped write reports what the device took; an unclamped one reports
    // the value back unchanged. Both are the device's word, and both clear the
    // pending badge that the write itself put on.
    store.applyBatch({
      key: DynamicValue(
        value: result.readback,
        quality: Quality.good,
        sourceTime: stamp,
      ),
    });
  }

  /// The widest instant `DateTime.fromMillisecondsSinceEpoch` accepts, either
  /// side of the epoch. Named rather than inlined so the range check and the
  /// constructor it protects cannot drift apart silently.
  static const int _representableMs = 8640000000000000;

  /// Records a readback this client would not put on the page.
  ///
  /// **Never silent.** A readback dropped without a trace is a gateway clock
  /// skew nobody can diagnose from a panel: the number on the mimic is simply
  /// right, and the operator's write confirmation simply never appears. It goes
  /// on the same surface [_answerFor] records a misaligned `writeStatus` entry
  /// on — the one the panel puts in front of an engineer — and it names the tag,
  /// because a refusal that does not say what it refused is one nobody can act
  /// on.
  ///
  /// Never thrown, for [complaints]' own stated reason: a page carries ~1500
  /// hand-edited keys and one bad answer must cost one tag.
  void _declineReadback(String key, String why) {
    _supervisor.resync
        .complain('the write readback for "$key" was not put on the page: $why');
  }

  // `_markNonFinite` lived here: it stamped [Quality.badNonFinite] on a key
  // after a write whose value had been sanitized to null, so the operator saw
  // a fault rather than a healthy empty box. Deleted rather than left as a
  // decoy — no such write can happen now that [_write] refuses a non-finite
  // value outright, and the local mark was only ever consolation for having
  // actuated the plant with null in the first place. A non-finite arriving
  // *from* the wire is a different path and still marks
  // (`subscription_state.dart`, `DynamicValue.fromWire`).

  // -------------------------------------------------------- hold-to-run

  /// Every hold this client is feeding, keyed by the tag it feeds.
  ///
  /// Small on purpose and holding no schedule: the cadence belongs to
  /// `HoldToRunController` (05-07), and a `Timer` in this file would be a
  /// second thing deciding when a machine is still wanted.
  ///
  /// A second engage on a key that already has a live hold replaces the entry.
  /// The displaced handle is still releasable by whoever holds it, and its
  /// ticks still gate on link readiness, so nothing it does can outlive the
  /// link — but it will not be released by [dispose] or by a disconnect.
  /// Two concurrent holds on one tag are a contradiction at the operator's
  /// end, not a state this client can resolve on its own.
  ///
  /// Over the pipe it does not arise: the gateway refuses a second engage on
  /// a key the session already holds (05-REVIEW WR-02), so the second
  /// `holdToRun` comes back rejected and the inert handle is never stored.
  /// The displacement above is what happens if a gateway some day answers
  /// otherwise, and it is the fail-safe half — nothing feeds an orphan, so
  /// the machine stops on the deadman.
  final _holds = <String, HoldHandle>{};

  var _holdTicksSent = 0;

  /// How many deadman ticks reached the wire — the observable 05-07's cadence
  /// cases are written against, in the style of [debugWritesSent].
  ///
  /// Counted after the gate, so it measures ticks the link actually carried
  /// rather than ticks somebody asked for.
  int get debugHoldTicksSent => _holdTicksSent;

  /// Engages a hold-to-run deadman on [key] over the pipe.
  ///
  /// The engage is an ordinary write carrying the hold flag, so it gets the
  /// three-state outcome, the deadline and the `writeStatus` recovery every
  /// other write gets; the release is the same write with 0 on it. Only the
  /// feed in between is a notification, and only because a tick has no
  /// outcome to correlate.
  @override
  Future<HoldHandle> holdToRun(String key) async {
    final engagement = await _write(key, 1, cmd: newUlid(), hold: true);
    final hold = HoldHandle(
      key: key,
      engagement: engagement,
      onTick: (counter) => _sendHoldTick(key, counter),
      onRelease: (counter) => _write(key, counter, cmd: newUlid(), hold: true),
    );
    if (hold.isHeld && !_disposed) {
      _holds[key] = hold;
      unawaited(hold.onReleased.then((_) {
        if (identical(_holds[key], hold)) _holds.remove(key);
      }));
    } else if (hold.isHeld) {
      // Engaged into a client that closed while the write was out. Nothing is
      // watching the counter and nothing will feed it; say so at once rather
      // than hand back a handle that looks live.
      unawaited(hold
          .release(reason: HoldEnded.disposed)
          .then((_) {}, onError: (Object _) {}));
    }
    return hold;
  }

  /// Hands one counter value to the link, or drops it.
  ///
  /// **A gate, not a `try`/`catch`.** `sendNotification` on a closed peer
  /// throws `StateError` synchronously (measured, 05-RESEARCH §B.1 #5), and
  /// `classifyFailure` (`failure_taxonomy.dart:143-148`) rethrows
  /// unrecognised `StateError`s on purpose — so a catch here would swallow a
  /// real defect in this process along with the one it meant to ignore.
  ///
  /// **And no queue behind it.** `_WsSink.add` goes straight to the `dart:io`
  /// sink, which buffers without bound and offers no `bufferedAmount` and no
  /// `flush()` (flutter#103306). A pump that kept ticking into a stalled
  /// socket would build exactly the queue this project forbids; the gate is
  /// what prevents it, and a dropped tick costs nothing the next one 100 ms
  /// later does not fix.
  void _sendHoldTick(String key, int counter) {
    if (_disposed || _supervisor.state != LinkState.ready) return;
    final peer = _supervisor.peer;
    if (peer == null) return;
    peer.sendNotification(
        Methods.holdTick, HoldTickParams(key: key, counter: counter).toJson());
    _holdTicksSent++;
    // A deadman tick is an inbound application frame at the gateway, so it
    // moves the reaper's deadline exactly as a ping would. An operator holding
    // a jog button sends ten a second; a heartbeat on top of that would be
    // pure cost on the one path where the panel is busiest.
    _heartbeat.noteOutbound();
  }

  /// Ends every live hold, without waiting for the release writes.
  ///
  /// Not awaited: on a link that has just gone, the release write resolves
  /// `WriteUnknown(link_down)` a deadline later, and a teardown that waited
  /// for it would hold a closing page open for a write whose outcome is
  /// informational anyway. The counter stops the moment this is called, which
  /// is the whole safety property — the PLC's deadman does the rest.
  void _releaseHolds(HoldEnded reason) {
    if (_holds.isEmpty) return;
    for (final hold in List<HoldHandle>.of(_holds.values)) {
      unawaited(
          hold.release(reason: reason).then((_) {}, onError: (Object _) {}));
    }
    _holds.clear();
  }

  // --------------------------------------------------- the acknowledge

  /// Acknowledges one active alarm — the alarm-rule instance
  /// `(alarmUid, ruleIndex)`, which is D-4's identity of an open
  /// `alarm_history` row and the whole of what the frame carries.
  ///
  /// **Not on `StateManApi`, and that is a decision rather than an oversight.**
  /// The interface is the 49-member surface `api_surface_test.dart:213-226`
  /// calls "the access-control policy": it is implemented by `LocalStateMan`,
  /// exercised by one shared contract suite against both ends, and every member
  /// on it is a thing every implementation owes an answer for. An acknowledge
  /// has no `LocalStateMan` meaning at all — on the backend the alarm engine is
  /// reached directly, not through a state-management call — so widening the
  /// surface would oblige every implementation to answer for a capability only
  /// one of them has. This is [_write]'s hold flag (D-P5-C) again, for a
  /// different reason: there the member was withheld because the interface
  /// already said the same thing twice, here because the interface has nothing
  /// to say about it.
  ///
  /// **One frame, no queue, no retry.** It goes through [_request] like
  /// everything else, so it inherits the disposed guards, the barrier wait with
  /// [config.controlDeadline] on it, the peer captured at call time, and the
  /// heartbeat's outbound note. A link that is not there produces [LinkDown]
  /// with nothing written — never a frame parked until the gateway comes back,
  /// because an acknowledge that arrives at shift change is the same queue
  /// `CLAUDE.md` forbids for a write, and the moment a re-send is acceptable
  /// here the argument for one on `write` gets made by analogy.
  ///
  /// **It keeps "never retried" and drops "never throws".** [write]'s other
  /// half is the three-state `WriteResult`, and there is no `AckResult` to
  /// invent: an acknowledge has no readback, no `ackStatus` to re-query and
  /// nothing on the plant behind it, so a three-state ladder would be three
  /// names for one fact. A refusal is thrown, and the panel shows it.
  ///
  /// **No `cmd`, no [_unresolved] entry, no [_keyOf] entry.** Those exist so
  /// `writeStatus` can reconcile a command after a reconnect. There is no
  /// `ackStatus`, so an id recorded here would be re-queried on every reconnect
  /// for the rest of the shift and never settled — growing the unresolved set
  /// until `writeStatus` is refused for being over `maxKeysPerSubscribe`, which
  /// takes the recovery path for the *genuine* unknowns down with it. That is
  /// [_write]'s own argument at its `dispatched` flag, and it applies here with
  /// more force because nothing would ever settle the entry.
  ///
  /// **Only `-32601` is translated.** See [AlarmAckUnsupported]: the method
  /// name is an additive protocol change, so METHOD_NOT_FOUND is the single
  /// observable difference between a gateway that predates this phase and one
  /// that does not. Everything else the gateway answers — the `forbidden` of a
  /// view station, the `handlerFailed` of a gateway composed without an
  /// `AlarmAckSink` — arrives exactly as it was sent, because the gateway's own
  /// sentence says which of them it is and where it is fixed.
  ///
  /// The answer means the gateway accepted the instruction and handed it to an
  /// engine. It does not mean the row moved: the operator's confirmation is the
  /// alarm leaving `AlarmKeys.active`, which is PROJECT.md's "readback is the
  /// only confirmation" applied here without an exception.
  Future<void> ackAlarm(String alarmUid, int ruleIndex) async {
    // Spelled once, read twice. The wire name and the name in the failure this
    // client raises about that wire name are the same fact, and two literals
    // are two things a rename has to find — the sweep in `no_retry_test.dart`
    // counts `Methods.write` for exactly this reason one method up.
    const method = Methods.ackAlarm;
    try {
      await _request(
        method,
        // Through the shared DTO rather than a map literal, for 05-REVIEW
        // IN-02's reason: the gateway decodes with `AckAlarmParams.fromJson`,
        // and a hand-rolled literal at this end would leave the two halves of
        // one wire shape kept in step by a test suite alone.
        AckAlarmParams(alarmUid: alarmUid, ruleIndex: ruleIndex).toJson(),
      );
    } on rpc.RpcException catch (error) {
      if (error.code != AlarmAckUnsupported.methodNotFound) rethrow;
      throw AlarmAckUnsupported(method, error.message, data: error.data);
    }
  }

  // ------------------------------------------------------ the history read

  /// The `alarm_history` rows overlapping a window, newest first.
  ///
  /// **Why this exists.** `RelayAlarmSource.getRecentAlarms` read the panel's
  /// own database, under a ruling whose premise was that a gateway-mode panel
  /// has one. `lib/providers/preferences.dart:60` now branches on the transport
  /// before it reads the config row, so a gateway panel builds `Preferences`
  /// with `db: null` and that method's `if (preferences.database == null)
  /// return []` became the only branch that ever ran — an empty history page on
  /// a plant that has had alarms all week, with nothing anywhere to say the
  /// answer was not an answer. The backend is the process that has the table.
  ///
  /// **Not on `StateManApi`**, and it is [ackAlarm]'s ruling for [ackAlarm]'s
  /// reason: the interface is the surface `api_surface_test.dart` calls "the
  /// access-control policy", implemented by `LocalStateMan` and exercised by
  /// one shared contract suite against both ends, and every member on it is
  /// something every implementation owes an answer for. Alarm history has no
  /// `LocalStateMan` meaning — on the backend the engine's history writer is
  /// reached directly, not through a state-management call — so widening the
  /// surface would oblige every implementation to answer for a capability only
  /// one of them has.
  ///
  /// **An unreadable answer throws; it never becomes an empty list.**
  /// `AlarmHistoryEntry.decodeList` refuses a shape it cannot read, and one
  /// unreadable row refuses the whole answer rather than shortening it. That is
  /// the opposite of `AlarmActiveEntry.decodeList`, which is tolerant on
  /// purpose — there the previous active set stands and a banner must not go
  /// blank, and here there is no previous set to stand on. A tolerant decode
  /// would put an empty page on screen and present it as the plant's history,
  /// which is precisely the defect this method replaces.
  ///
  /// **An impossible window is refused here**, before a frame leaves: a zero
  /// [limit], one over [AlarmHistoryParams.maxLimit], or a [from] after its
  /// [to] all throw [ArgumentError] out of the DTO's own constructor. Sending
  /// them would cost a round trip to be told the same thing in a sentence that
  /// no longer knows which argument the caller passed.
  ///
  /// **Only `-32601` is translated.** See [AlarmHistoryUnsupported]: the method
  /// name is an additive protocol change, so `METHOD_NOT_FOUND` is the single
  /// observable difference between a gateway that predates it and one that does
  /// not. Everything else the gateway answers arrives exactly as it was sent,
  /// because the gateway's own sentence says which of them it is.
  Future<List<AlarmHistoryEntry>> recentAlarms({
    int limit = 1000,
    DateTime? from,
    DateTime? to,
  }) async {
    const method = Methods.alarmHistory;
    // Built before the disposed guard and before the barrier, so an impossible
    // window is an `ArgumentError` at the call site rather than something that
    // depends on whether the link happened to be up.
    final params = AlarmHistoryParams(limit: limit, from: from, to: to);
    try {
      return AlarmHistoryEntry.decodeList(
          // Through the shared DTO rather than a map literal, for 05-REVIEW
          // IN-02's reason: the gateway decodes with
          // `AlarmHistoryParams.fromJson`, and a hand-rolled literal at this
          // end would leave the two halves of one wire shape kept in step by a
          // test suite alone.
          await _request(method, params.toJson()));
    } on rpc.RpcException catch (error) {
      if (error.code != AlarmAckUnsupported.methodNotFound) rethrow;
      throw AlarmHistoryUnsupported(method, error.message, data: error.data);
    }
  }

  /// Re-asks the gateway what became of [cmds], in the order asked.
  ///
  /// The one place a `writeStatus` frame is built, for both callers: the
  /// public member and the reconnect recovery below. A second frame-building
  /// site would be a second thing to keep aligned with the wire, and this one
  /// is already the seam the no-re-actuation property is asserted against
  /// (`debugWriteStatusQueries`).
  ///
  /// **Every element answers the command at the same index**, including the
  /// ones nothing legible came back for: a malformed entry — or one that
  /// decodes cleanly but is about a different command — becomes a
  /// [WriteUnknown] about the command it was asked under rather than being
  /// dropped, because dropping it would shift every later answer onto the
  /// wrong command — and one of those answers could be the `not_received`
  /// that invites an operator to move a machine again. The complaint is still
  /// recorded, so a page that goes half-blank has a line in the log.
  ///
  /// It never re-sends a write. That is the whole of the recovery story: the
  /// client asks what became of the command, it does not send it again.
  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) async {
    if (cmds.isEmpty) return const <WriteResult>[];
    _record(_writeStatusQueries, cmds);
    final raw = _asJson(
        await _request(Methods.writeStatus, WriteStatusParams(cmds).toJson()));
    final results = raw['results'];
    return [
      for (var i = 0; i < cmds.length; i++)
        if (results is List && i < results.length)
          _answerFor(cmds[i], results[i])
        else
          WriteUnknown(
              cmds[i],
              const WriteReason('malformed_result:writeStatus',
                  message: 'the gateway answered without an entry for this '
                      'command, so nothing about it can be ruled out')),
    ];
  }

  /// One entry of a `writeStatus` answer, decoded or accounted for.
  ///
  /// An entry that decodes cleanly but carries a different `cmd` is treated
  /// exactly as one that did not decode (05-REVIEW WR-01). Positional
  /// alignment is the interface's promise and the caller has no other way to
  /// know which command it is being told about, so an entry about some other
  /// command is not an answer about this one — however well-formed it is.
  WriteResult _answerFor(String cmd, Object? entry) {
    try {
      final decoded = WriteResult.fromJson(_asJson(entry));
      if (decoded.cmd != cmd) {
        // Substituted in place, never dropped: dropping shifts every later
        // answer onto the wrong command, which is the failure 04-REVIEW
        // deviation 4 hardened the *absent* case against. And the verdict
        // that must not survive a shift is `not_received` — the one outcome
        // in this system that licenses a second movement of a machine.
        _supervisor.resync.complain(
            'a writeStatus entry at the position asked for "$cmd" answered '
            'about "${decoded.cmd}" instead; it was discarded rather than '
            'reported against the wrong command');
        return WriteUnknown(
            cmd,
            const WriteReason('misaligned_result:writeStatus',
                message: 'the gateway answered this position about a '
                    'different command, so nothing about this one can be '
                    'ruled out'));
      }
      return decoded;
    } catch (error) {
      // One entry, not the batch (04-REVIEW WR-03). Decoding the whole list at
      // once was letting a malformed entry at index 0 discard the settled
      // outcomes of every other command in it, and on a 1500-key panel the
      // batch is not small. One typo costs one tag, here as everywhere.
      _supervisor.resync.complain(
          'a writeStatus entry could not be read and was answered as unknown '
          'rather than taken as an answer about some other command: $error');
      return WriteUnknown(
          cmd, WriteReason('malformed_result:writeStatus', message: '$error'));
    }
  }

  /// Asks the gateway what became of every command still in flight.
  ///
  /// Invoked on entry to `ready` and nowhere else. This is the whole of the
  /// recovery story for a write whose link died under it: one question about N
  /// commands, and never a re-send. A gateway that has forgotten the command
  /// answers `unknown` again, which leaves it in [_unresolved] for the next
  /// `ready` to ask about — forgetting is not evidence that it never happened.
  Future<void> _requeryWriteStatus() async {
    if (_requerying) {
      // **Wanted, not dropped** (04-REVIEW WR-01). The guard is against a
      // storm, and the flag alone turned it into a permanent skip: ready →
      // re-query sent → link drops → reconnect → this fires while the old
      // call's future has not failed yet → early return. The old call then
      // failed and cleared the flag, and nothing re-armed, so the commands
      // stayed unresolved until some later entry to ready — which on a link
      // that then behaves is never.
      _requeryWanted = true;
      return;
    }
    final cmds = List<String>.of(_unresolved);
    if (cmds.isEmpty) return;
    _requerying = true;
    try {
      for (final outcome in await writeStatus(cmds)) {
        _record(_writeStatusAnswers, outcome);
        if (outcome is WriteUnknown) continue;
        _settle(outcome);
      }
    } catch (_) {
      // A re-query that fails leaves the commands unresolved, which is the
      // honest state and the one the next `ready` will ask about again. What it
      // never becomes is a reason to send the write a second time.
    } finally {
      _requerying = false;
      if (_requeryWanted && !_disposed) {
        _requeryWanted = false;
        unawaited(_requeryWriteStatus());
      }
    }
  }

  /// One command has an established answer at last.
  ///
  /// **The recovery has to end somewhere the operator can see** (04-REVIEW
  /// WR-02). Removing the id from [_unresolved] and stopping there meant that
  /// an operator who was told "unknown", walked out to look at the machine and
  /// came back was told nothing at all when the gateway finally said "applied".
  /// So the outcome goes out on [onWriteResolved], and an applied one has its
  /// readback adopted into the store exactly as the direct path adopts one —
  /// the readback is what the device reported holding, and adopting it is
  /// applying the confirmation rather than predicting it.
  void _settle(WriteResult outcome) {
    _unresolved.remove(outcome.cmd);
    final key = _keyOf.remove(outcome.cmd);
    if (key != null) _adoptReadback(key, outcome);
    if (!_resolved.isClosed) _resolved.add(outcome);
  }

  /// Appends to a debug list, keeping only the most recent [_debugHistory].
  ///
  /// 04-REVIEW IN-02: one entry per re-query, never trimmed, is a leak with a
  /// diagnostic excuse — a panel that flaps all shift accumulates them. The
  /// question these answer ("what did the recovery just do?") is about the
  /// recent past, so the bound costs nothing that was being read.
  static void _record<T>(List<T> history, T entry) {
    history.add(entry);
    if (history.length > _debugHistory) history.removeAt(0);
  }

  // ---------------------------------------------------------------- teardown

  /// Drops every listener, closes every handed-out stream, stops the
  /// reconnect loop and releases the socket. Idempotent.
  ///
  /// Handed-out streams go **before** the link, as in
  /// `channel_state_man.dart:424-436`, and the supervisor goes last because
  /// disposing it errors the readiness barrier — which is how a call still
  /// waiting for a connection gets something it can show instead of a spinner
  /// that never stops.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Before the flag, so each release is an ordinary write with an honest
    // outcome rather than a refusal from [_refuseIfDisposed]. Not awaited: a
    // panel closing must not wait on a link that may already be gone.
    _releaseHolds(HoldEnded.disposed);
    _disposed = true;

    for (final close in List.of(_closeHandedOutStreams)) {
      await close();
    }
    _closeHandedOutStreams.clear();
    await _resolved.close();
    await _freshness.close();
    await preferences.dispose();

    // Before the supervisor, and before the transition subscription that would
    // otherwise be the only thing stopping it: a pump still armed while the
    // supervisor is torn down would fire once into a peer that is going away,
    // and a timer that outlives the object that owns it is the leak class
    // `teardown_test.dart` exists for.
    _heartbeat.dispose();

    await _transitions.cancel();
    await _supervisor.dispose();

    // After the supervisor, because until it is disposed a dial may still be
    // in flight and closing the client under it would fail that attempt with
    // something that looks like a certificate problem. `force: true` because a
    // panel closing must not wait on a socket to a gateway that may already be
    // gone — the same argument `_releaseHolds` makes at the top of this
    // method. Cleared so a second dispose is still a no-op.
    _pinned?.close(force: true);
    _pinned = null;

    for (final store in _stores.values) {
      store.dispose();
    }
  }

  // ------------------------------------------------------------- internals

  /// How this panel actually reaches the gateway.
  ///
  /// One attempt in, one [ConnectAttempt] out — the shape the supervisor's
  /// `dial:` seam insists on — with the two things only this class knows
  /// closed over: the pinned client built in the constructor, and the ceiling
  /// on how long a dial may take before the schedule takes over.
  Future<ConnectAttempt> _dialGateway(Uri uri) => connect(
        uri,
        client: _pinned,
        connectTimeout: config.connectTimeout,
      );

  /// The store for [sub], created on first use.
  ValueStore _storeFor(String sub) =>
      _stores.putIfAbsent(sub, ValueStore.new);

  /// The store that holds [key].
  ///
  /// A key nobody has filed belongs to the page subscription, so a `listen` for
  /// a tag this client was not constructed with still returns a stable node
  /// rather than a fresh one per call.
  ValueStore _storeOf(String key) => _storeFor(_subOf[key] ?? _page);

  /// One request out and one answer back, once the link is up.
  ///
  /// The barrier wait is the whole of difference (2) in the library doc, and
  /// the disposed guards on either side of it are not defensive tidiness: a
  /// page can close while its read is parked on the barrier, and a
  /// `sendRequest` on a peer that is gone throws a `StateError` out of
  /// `json_rpc_2` which the caller would have to tell apart from a real defect.
  Future<Object?> _request(
    String method,
    Map<String, Object?> params, {
    Duration? deadline,
    void Function()? onSend,
  }) async {
    _refuseIfDisposed(method);
    final budget = deadline ?? config.controlDeadline;
    try {
      await _supervisor.barrier.ready.timeout(budget);
    } on TimeoutException {
      // **Never queued behind a link that is not there.** The barrier owns no
      // clock (`readiness_barrier.dart`: "the supervisor owns the clock", and
      // the supervisor's only schedules reconnects), so an unbounded wait here
      // made every deadline in `ClientConfig` a measurement of the round trip
      // alone. Two things came of that, and the second is the dangerous one: a
      // write never settled, so the operator's spinner never stopped; and when
      // the gateway came back — ten minutes later, at shift change — the
      // request went out. A button pressed at 09:00 actuating a ram at 09:10 is
      // a queue, and `CLAUDE.md` names "no queue / no retry" as *the*
      // write-safety property.
      //
      // Reported as "no link", never as a server answer: `writeOutcomeFor`
      // turns [LinkDown] into `WriteUnknown(link_down)` and reads surface it
      // through `classifyFailure`.
      throw LinkDown(method);
    }
    _refuseIfDisposed(method);
    onSend?.call();
    // The budget again rather than what is left of it. A link that arrived at
    // the last millisecond of the wait has earned the whole round-trip window;
    // a truncated one would expire against a perfectly healthy gateway and
    // report a write it never sent as unknown. So the worst case is two
    // budgets, bounded and deliberate, instead of one budget and a queue.
    final call = callWithDeadline(
      () => _supervisor.peer,
      method,
      params: params,
      deadline: budget,
    );
    // Every request this client makes funnels through here, so this one line
    // is enough to make the heartbeat a *silence* timer rather than a
    // metronome: a panel that is reading, writing or re-querying has already
    // moved the gateway's deadline and needs no ping on top.
    //
    // **After the call and not before it** (07-REVIEW IN-05).
    // `callWithDeadline` throws `LinkDown` **synchronously** for a null peer —
    // the barrier above being open does not promise one is still there — and
    // recording that as outbound suppressed a beat for a frame that never
    // reached the wire. Bounded to one extra period of silence and harmless at
    // the derived period, but there is no reason to record a send that threw.
    _heartbeat.noteOutbound();
    return call;
  }

  /// A [StateError] of this file's own, naming the call that arrived after the
  /// close — the precedent is `channel_state_man.dart:484-492`. There is no
  /// value to invent and no round trip left to make.
  void _refuseIfDisposed(String method) {
    if (!_disposed) return;
    throw StateError(
        'RemoteStateMan was asked for "$method" after it was disposed; the '
        'link is closed, so there is no round trip left to make and no answer '
        'that would not be invented');
  }

  /// Whether the last transition seen was into `ready`.
  ///
  /// Held because *leaving* `ready` is a release trigger and a stream of
  /// states carries no memory of the one before. Without it there is no way
  /// to tell "the link just went down under a live hold" from "the link has
  /// been down since boot", and only the first of those has a machine
  /// attached to it.
  var _wasReady = false;

  /// One transition. Everything that belongs to *entering* a state rather than
  /// to the code path that got there lives here.
  void _onLinkState(LinkState state) {
    if (_disposed) return;
    final isReady = state == LinkState.ready;

    // Leaving `ready` releases every hold at once, and does not wait for a
    // write deadline to say so: the counter has already stopped reaching the
    // plant, so the machine is stopping regardless, and waiting would leave
    // the UI showing a live hold for up to two budgets. The release write is
    // still attempted — it resolves `WriteUnknown(link_down)` through
    // `_request`'s `LinkDown` path, which is the honest answer and costs
    // nothing.
    if (_wasReady && !isReady) _releaseHolds(HoldEnded.disconnect);
    _wasReady = isReady;

    // The heartbeat's whole lifetime, in two lines and in one place. It beats
    // only while the link is ready — a pump that ran through `connecting` and
    // `down` would be scheduling frames for a socket that is not there, which
    // `heartbeat_pump.dart`'s doc calls a queue and this project forbids. Both
    // calls are idempotent, so a repeated transition costs nothing and cannot
    // leave a second timer behind.
    if (isReady) {
      _heartbeat.start();
    } else {
      _heartbeat.stop();
    }

    // Entry to `ready` and nowhere else: `resyncing` means the socket answered
    // the phone, and a re-query issued then races the snapshot it is competing
    // with for the same link.
    if (!isReady) return;
    if (_unresolved.isEmpty) return;
    unawaited(_requeryWriteStatus());
  }

  /// A wire value, sanitized and quality-composed by [WireValue.fromJson].
  static DynamicValue _value(Object? raw) =>
      WireValue.fromJson(_asJson(raw)).toDynamicValue();

  /// Narrows a decoded JSON value to the map shape the protocol decoders take.
  ///
  /// `json_rpc_2` hands back whatever `jsonDecode` produced, which is a
  /// `Map<String, dynamic>` for an object and anything at all for a peer that
  /// is lying. A `FormatException` here is the honest outcome — the decoders
  /// this feeds are documented to be tolerant of *fields*, not of being handed
  /// a list where an object belongs.
  static Map<String, Object?> _asJson(Object? raw) => raw is Map
      ? {for (final entry in raw.entries) '${entry.key}': entry.value}
      : throw FormatException('expected a JSON object, got ${raw.runtimeType}');
}
