/// The gateway's `StateManApi`: one composer over the key router, the ordered
/// upstream links and one value store.
///
/// ## Why the 2,796-line `StateMan` composer does not enter the gateway
///
/// This is the decision the whole package rests on, and it is written here by
/// line so the next reader does not have to re-derive it. `ClientWrapper`,
/// `ModbusDeviceClientAdapter` and `M2400DeviceClientAdapter` *are* wrapped —
/// they carry years of plant scar tissue (a two-phase resubscribe that fixed a
/// measured monitored-item storm, a heartbeat-derived effective status with a
/// 15 s stale / 30 s grace window, the classification that tells a transient
/// `Inactivity` from a fatal `SubscriptionDeleted`) and none of that is worth
/// rewriting. The composer above them is a different matter, and four of its
/// properties are the anti-patterns `StateManApi` exists to replace:
///
///  1. **`read` throws on every failure path**
///     (`packages/tfc_dart/lib/core/state_man.dart:1876`). A read that throws
///     is a read whose caller has to invent a quality, and an invented quality
///     is how a plausible number survives the loss of the thing producing it.
///  2. **`write` throws too** (`:2042`), which collapses "I cannot tell whether
///     it happened" into "it failed" — the one distinction the whole write path
///     exists to preserve.
///  3. **`subscribe` is a `Future<Stream<…>>`** (`:2054`), the shape
///     `state_man_api.dart:80-84` names as how a widget ends up missing the
///     first values of its own subscription.
///  4. **Its values carry no quality.** `tfc_dart`'s `DynamicValue` and this
///     package's are two different classes with one name, and only one of them
///     has `quality` and `sourceTime` as fields. Everything crossing into the
///     gateway is a translation between them, and the translation is where the
///     two facts get minted rather than lost.
///
/// ## Nothing is spawned by the constructor
///
/// `StateMan._` starts two unawaited background loops per OPC UA client
/// (`:1364`, `:1398`) with a bare `Logger()` and no error seam, in a
/// constructor. That is the shape being replaced. Here construction allocates
/// and connects nothing; [start] opens the links under a bounded deadline and
/// [dispose] closes them, so a failure to reach a PLC is a value the caller
/// receives rather than an exception raised inside somebody else's `new`.
///
/// ## Explicit delegation, never `noSuchMethod`
///
/// Every member is written out. `policy_state_man.dart:80-87` gives the reason
/// and `cert_health_state_man.dart:153-158` repeats it: a forwarder silently
/// absorbs a member added to `StateManApi` in a later phase — the new member
/// works, unpoliced, and nothing says so. Here a new member is a compile error,
/// and a compile error is a decision. `freeze_test.dart` pins the spelling out
/// of `lib/` so the shortcut cannot be taken later either.
///
/// ## The write path is here, and there is one of it
///
/// `write` is 08-06's and so is the single line that crosses into a plant
/// ([_crossIntoThePlant]). Three states, no throw to report an outcome, no
/// retry anywhere, and readback as the only confirmation — the badge on a
/// value says "sent", and only an upstream sample says "confirmed".
///
/// ## Nothing here is unimplemented any more
///
/// `holdToRun` was 08-06 task 3's, `browse` 08-11's, and `timeseries`,
/// `historyViews` and `preferences` were Phase 10's — 10-07, 10-08 and 10-09
/// task 3 respectively. Each threw an `UnimplementedError` naming the plan
/// that owed it, and each throw was deleted by the commit that made the member
/// answer. `declaredUnimplementedMembers` in `freeze_test.dart` reached
/// **zero** in 10-09's, which is where this paragraph changed tense.
///
/// That was 07-01's `gateOutstanding` doctrine and it worked: a self-deleting
/// list with an owner beats a red suite, because a phase whose own gate is red
/// cannot tell a new failure from a known one. The three data-services members
/// now refuse a gateway composed **without a database** instead, which is a
/// deployment fact rather than unwritten code — see [timeseries],
/// [historyViews] and [preferences], and note that the last of the three
/// deliberately does not use the same exception as the other two.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'data/preference_store.dart';
import 'fanin.dart';
import 'freshness_sweep.dart';
import 'ingest.dart';
import 'key_router.dart';
import 'local_browse.dart';
import 'pipe_health.dart';
import 'upstream_link.dart';
import 'write_translation.dart';

/// The `StateManApi` the gateway serves every session from.
final class LocalStateMan implements StateManApi {
  LocalStateMan({
    required List<UpstreamLink> links,
    required this.router,
    this.staleAfter = const Duration(seconds: 5),
    this.linger = Duration.zero,
    this.readDeadline = const Duration(seconds: 5),
    this.connectDeadline = const Duration(seconds: 10),
    this.writeDeadline = const Duration(seconds: 5),
    this.writeOutcomeTtl = const Duration(minutes: 10),
    this.maxWriteOutcomes = 4096,
    Map<String, UpstreamAddressSpace> browseSpaces =
        const <String, UpstreamAddressSpace>{},
    TimeseriesApi? timeseries,
    HistoryViewApi? historyViews,
    PreferenceStore? preferences,
    DateTime Function()? now,
    int Function()? elapsedMs,
  })  : links = List<UpstreamLink>.unmodifiable(links),
        _timeseries = timeseries,
        _historyViews = historyViews,
        _preferences = preferences,
        browseSpaces =
            Map<String, UpstreamAddressSpace>.unmodifiable(browseSpaces),
        _now = now ?? DateTime.now,
        _elapsedMs = elapsedMs {
    _startedMs = _now().millisecondsSinceEpoch;
    // Allocation only. Nothing here opens a socket, starts a clock or spawns a
    // loop — see the library doc on why `StateMan._`'s constructor is the shape
    // being replaced.
    //
    // The health producer is the one thing that *writes* during construction,
    // and that is its whole point: every per-link key exists before anything
    // can subscribe. An indicator that reads unknown until the first fault
    // tells an operator nothing at the moment they most need telling.
    _health = PipeHealth(links: this.links, store: _store, elapsedMs: _elapsed);
    _sweep = FreshnessSweep(
      staleAfter: staleAfter,
      store: _store,
      lastArrival: _lastArrival,
      degrade: _degrade,
      elapsedMs: _elapsed,
    );
    _fanIn = FanIn(
      router: router,
      onValue: _onUpstreamValue,
      onRefusedRoute: _refuse,
      onUpstreamEnded: _onUpstreamEnded,
      onUpstreamError: _onUpstreamError,
      linger: linger,
      // The listener gate. The sweep's clock runs on the transition off zero
      // watchers and stops on the return to it — with nobody watching there is
      // no timer, and the synchronous re-derivation in [read] is what makes
      // that safe rather than merely cheap (state_man.dart:966-992).
      onFirstWatcher: () => _sweep.start(),
      onLastWatcher: () => _sweep.stop(),
    );
    // Seeded here for the same reason the per-link keys are: an indicator that
    // reads unknown until the first fault tells an operator nothing at the
    // moment they most need telling.
    _publishPlantConnected();
  }

  /// The configured links, in the order the router offers keys to them.
  ///
  /// Held here as well as inside the router because the *lifecycle* is this
  /// class's: [start] connects them and [dispose] closes them, following
  /// `createM2400DeviceClients`' division of labour, whose comment says in so
  /// many words that "the caller is responsible for calling connect() and
  /// dispose() on the returned clients" (`state_man.dart:1292-1293`). The
  /// router only ever asks them to `resolve`.
  final List<UpstreamLink> links;

  /// Which link owns a key, or which named refusal it earns.
  final KeyRouter router;

  /// The live address space behind each browsable alias.
  ///
  /// Empty by default, and an empty map is a working gateway: browse is a
  /// capability and not a duty. An alias whose link says
  /// [UpstreamLink.supportsBrowse] but has no entry here is a *configuration*
  /// gap — the tree stops at that root and the reason lands in
  /// [LocalBrowse.incidents] rather than in an exception.
  final Map<String, UpstreamAddressSpace> browseSpaces;

  /// How long a value may go unheard-of before it must stop claiming to be
  /// current. 08-05's freshness sweep is what notices; see `freshness_sweep.dart`.
  final Duration staleAfter;

  /// How long an upstream subscription survives its last client subscriber.
  ///
  /// Zero by default and that is the correct gateway behaviour — a page close
  /// should stop costing the PLC a monitored item, which is SRV-07 and the
  /// departure from `AutoDisposingStream`'s ten-minute idle timer
  /// (`state_man.dart:2674-2676`). See `fanin.dart` for why the knob exists.
  final Duration linger;

  /// The bound on a single upstream round trip.
  ///
  /// Required at every call site by [UpstreamLink]'s signatures and defaulted
  /// here rather than there, so an omission is impossible and a deployment's
  /// choice is still one constructor argument.
  final Duration readDeadline;

  /// The bound on opening one link.
  final Duration connectDeadline;

  /// The bound on one write round trip.
  ///
  /// Separate from [readDeadline] because the two failures cost different
  /// things: a read that gives up leaves a value visibly stale, and a write
  /// that gives up leaves an outcome nobody knows — which is the answer an
  /// operator has to go and check a tag over.
  final Duration writeDeadline;

  /// How long the plant-side outcome log vouches for a cmd.
  ///
  /// Past this, `writeStatus` answers `WriteUnknown(outcome_expired)` rather
  /// than `WriteNotReceived`: an outcome this source has forgotten is not an
  /// outcome that never happened, and `not_received` is the one answer that
  /// tells an operator a re-send is safe.
  final Duration writeOutcomeTtl;

  /// How many settled outcomes the log holds before the oldest is dropped.
  ///
  /// A gateway runs for months; an unbounded map of every write it has ever
  /// settled is a leak with an audit trail's name on it.
  final int maxWriteOutcomes;

  /// Injectable **wall** clock, and only for the facts that have to be
  /// comparable with a peer's clock: the ULID arithmetic in [_statusOf], the
  /// mint time of a cmd, the instant an outcome was settled.
  ///
  /// **Never for an age.** 07-REVIEW CR-01 settled that argument on the client
  /// and 08-REVIEW CR-02 found it again here: `DateTime.now()` steps — NTP
  /// corrects it, an operator sets it, a suspended VM resumes with a different
  /// one — so subtracting two readings of it can answer a negative number, and
  /// a negative age reads as *fresh*. See [_elapsed].
  final DateTime Function() _now;

  /// The monotonic anchor every elapsed-time question is asked of.
  ///
  /// A `Stopwatch` and not a clock: it cannot be stepped, so an NTP correction
  /// on the plant PC moves nothing here. This is the gateway-side half of
  /// `6a499d65` ("age staleness on a monotonic anchor, not the panel's RTC"),
  /// and it matters more here than it did there — a step on a panel misleads
  /// one operator, a step on the gateway makes every key in the store read
  /// fresh at once.
  ///
  /// It is not a timer and does not appear in [liveTimers]: a `Stopwatch` is
  /// arithmetic over a monotonic counter, with nothing to cancel.
  final Stopwatch _uptime = Stopwatch()..start();

  /// The injected elapsed clock, or null for [_uptime].
  ///
  /// **The injected type is the elapsed one**, deliberately — 07-REVIEW's note
  /// on `c4e62845`: a seam that can be handed a wall clock is a seam somebody
  /// hands a wall clock, and the defect returns wearing the fix's clothes.
  final int Function()? _elapsedMs;

  /// Milliseconds since this source was constructed, monotonic.
  int _elapsed() => _elapsedMs?.call() ?? _uptime.elapsedMilliseconds;

  /// One map, one batch entry point — the same [ValueStore] the server and
  /// client implementations use, so the k-of-n notification promise is
  /// satisfied by production code rather than by anything written here.
  final ValueStore _store = ValueStore();

  /// When each key last had a value *arrive* for it, **on [_elapsed]**.
  ///
  /// Deliberately not the value's own `sourceTime`: an upstream may not fill
  /// it, and a source that dated freshness from a field the PLC leaves null
  /// would consider every value it has ever received to be infinitely old
  /// (`fake_state_man.dart:133-140`).
  ///
  /// And deliberately not a `DateTime` either — see [_elapsed]. The two
  /// numbers subtracted to answer "how old is this" must both come off a clock
  /// that only goes forward.
  final Map<String, int> _lastArrival = <String, int>{};

  /// The refcount that makes thirty panels on one key cost the PLC one
  /// monitored item, and releases it when the last of them goes (SRV-07).
  late final FanIn _fanIn;

  /// The clock that notices silence. Listener-gated; see `freshness_sweep.dart`.
  late final FreshnessSweep _sweep;

  /// The per-link health producer. Seeded at construction; see
  /// `pipe_health.dart`.
  late final PipeHealth _health;

  /// The per-link health keys this instance produces, by alias.
  ///
  /// Exposed so a diagnostics caller — and 08-12's session overlay, which has
  /// to know which names it must *not* also claim — can enumerate them without
  /// a second roster.
  List<String> healthKeysFor(String alias) => PipeHealth.keysFor(alias);

  /// The collection historian's health producer (8b-03).
  ///
  /// The runner publishes the six `PIPE.collect.*` keys through this, so
  /// they arrive in the same store by the same route as the per-link ones —
  /// subscribable like a temperature, outside freshness accounting, judged
  /// on the read path. Exposed as the producer's own narrow type rather
  /// than by giving the runner the store: the store is this class's one
  /// private map, and handing it out would be an unpoliced write path into
  /// every key the gateway serves.
  CollectHealth get collectHealth => _health.collect;

  /// Which keys have already been complained about, so a struct failing at
  /// 10 Hz costs one log line rather than the log file.
  final IngestLog _ingestLog = IngestLog();

  /// One counting handle per key, so [listen] answers the same object every
  /// time and the fan-in learns when the first listener arrives and the last
  /// one leaves.
  final Map<String, _WatchedKey> _handles = <String, _WatchedKey>{};

  bool _disposed = false;

  // ---------------------------------------------------------------- lifecycle

  /// Opens every configured link, bounded.
  ///
  /// Sequential rather than concurrent, because the order is the caller's and
  /// a plant with four PLCs is four connects, not four hundred. A link that
  /// cannot be reached does not stop the others: [UpstreamLink.connect] is
  /// bounded by [connectDeadline] and a gateway that refused to start because
  /// one PLC was in a download would take the other three off the screens too.
  ///
  /// **What that bounds, exactly** (08-REVIEW WR-05). [connectDeadline] bounds
  /// *one link*, and because the walk is sequential the worst case for this
  /// method is `connectDeadline × links.length` — four dark PLCs on the
  /// default is forty seconds before the socket is bound, not ten. That is the
  /// honest number and it is the price of the sequential walk; what it is
  /// **not** any more is five times that again, which is what it was while
  /// each phase inside `connect` re-spent the whole deadline.
  ///
  /// A deployment that cannot afford the multiplication should size
  /// [connectDeadline] against its link count. Connecting concurrently would
  /// trade it away but would also start every PLC's session at once on a
  /// gateway whose whole design is one process pacing the plant, so it is a
  /// decision for evidence rather than a tidy-up.
  Future<void> start() async {
    for (final link in links) {
      // Subscribed BEFORE the connect, so the link coming up is an event this
      // source saw rather than a state it later noticed. One subscription per
      // link and one handler behind it: the degradation, the health keys and
      // the announcement are three things that must happen in one order, and
      // three independent listeners on the same stream would run in whatever
      // order they happened to be registered.
      // **The emitted state is carried into the handler**, not dropped so the
      // handler can re-read the link (08-REVIEW WR-06). See [_onLinkState].
      _linkStates
          .add(link.stateStream.listen((state) => _onLinkState(link, state)));
      // The epoch is a second, independent thing that can change about a link:
      // 08-08's rule is that a PLC download is not a reconnection, so the two
      // streams move two different keys and neither moves the other's. The
      // link has already degraded and re-browsed by the time this fires — all
      // that is owed here is republishing what it now says about itself.
      _linkEpochs.add(link.epochStream.listen((_) => _health.onLinkEvent(link)));
      try {
        await link.connect(deadline: connectDeadline);
      } catch (error) {
        // Never a throw out of start(). The link's own state and
        // PIPE.upstream.<alias>.state are where a failed connect is reported —
        // a subscribable fact rather than an exception the caller has to
        // decide the meaning of.
        _noteLinkStartFailure(link, error);
      }
      // Asked, whether or not it answered. Before this the link's keys read
      // null-under-errorConfig, which is "nobody has asked" — a different
      // statement from a link known to be down, and the one the seed makes.
      _health.onLinkEvent(link);
      // Re-derived after every connect, not only from the state stream: a link
      // that was already connected when this source was built emits no
      // transition at all, and `PIPE.connected` would then sit at the value
      // the constructor guessed for the rest of the process.
      _publishPlantConnected();
    }
  }

  /// Releases the store, the links and everything held on their behalf.
  ///
  /// Idempotent: the suite disposes in `addTearDown` and a case that disposed
  /// deliberately must not be punished for it. No `.timeout` anywhere on this
  /// path — a dispose that gives up half way leaves the thing it was disposing
  /// in a state nobody owns.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // BEFORE the flag, because the zero is written through the ordinary write
    // path and that path refuses a disposed source. A hold must not outlive
    // its source: a disposed gateway that left a counter frozen at its last
    // value is a machine nobody is holding that the PLC still thinks somebody
    // is, for as long as its deadman window lasts.
    await _releaseHolds(HoldEnded.disposed);
    _disposed = true;
    for (final subscription in _linkStates) {
      await subscription.cancel();
    }
    _linkStates.clear();
    for (final subscription in _linkEpochs) {
      await subscription.cancel();
    }
    _linkEpochs.clear();
    await _status.close();
    // Before the links, because it is the only thing here holding a
    // subscription on a connection this object does not own: the preference
    // feed's channel rides `AppDatabase`'s shared notification socket, and a
    // disposed gateway that left it attached is Trap 5 on this side — a
    // listener on a shared source that only one path cancels.
    await _preferences?.close();
    await _fanIn.dispose();
    _sweep.dispose();
    _store.dispose();
    for (final link in links) {
      await link.dispose();
    }
  }

  // --------------------------------------------------------------- value path

  /// The handle for [key] — the same instance every time.
  ///
  /// A **counting view** of the store's node rather than the node itself, and
  /// the reason is SRV-07 rather than taste. `listen` is documented as the
  /// primary read path — the one widgets use — so if only `subscribe`
  /// refcounted, thirty panels bound through `listen` would open one upstream
  /// subscription that nothing could ever release. There is no `unlisten` on
  /// the interface, which makes `removeListener` reaching zero the **only
  /// observable release point** on this path; the wire package agrees, which is
  /// why `ValueStoreNode.listenerCount` is public at `value_store.dart:118`
  /// ("this is the only place the truth lives").
  ///
  /// Taking the handle costs nothing. A diagnostics page that enumerates every
  /// key must not subscribe the whole plant by looking at it.
  @override
  ValueListenable<DynamicValue> listen(String key) {
    _touch(key);
    return _handles.putIfAbsent(
        key,
        () => _WatchedKey(
              node: _store.node(key),
              attach: () => _fanIn.attach(key),
              detach: () => _fanIn.detach(key),
            ));
  }

  /// A view of the same node, for stream-consuming code.
  ///
  /// A **plain Stream**, and its first event is the value the store already
  /// holds rather than the next change: a page opened on a slow-moving tank
  /// level would otherwise read blank until the level moved. The snapshot is
  /// pushed in `onListen`, so taking the stream and listening to it happen in
  /// the same turn and there is no window in which a change can be missed.
  @override
  Stream<DynamicValue> subscribe(String key) {
    _touch(key);
    final node = _store.node(key);
    // `Stream.multi` and not a plain `StreamController`, since 08-11: two
    // widgets watching one key is the ORDINARY case, and a single-subscription
    // stream refuses the second one with a `Bad state` — which is a broken
    // page, not a refcount. It is also not a broadcast controller, because
    // that would fire `onListen` for the first listener only and leave every
    // later one with no initial value and no refcount of its own.
    //
    // `Stream.multi` gives each listener its own controller, so the refcount
    // moves on EVERY listen and back on every cancel — a stream nobody
    // listened to still costs the PLC nothing, and two panels sharing one
    // stream object are two clients because that is what they are.
    return Stream<DynamicValue>.multi((controller) {
      void push() {
        if (!controller.isClosed) controller.add(node.value);
      }

      node.addListener(push);
      _fanIn.attach(key);
      controller.onCancel = () {
        node.removeListener(push);
        _fanIn.detach(key);
      };
      // The current value goes out on a microtask and not synchronously inside
      // the listen. Two reasons, and the second is the one a test found:
      //
      //  * a synchronous `add` during `onListen` is re-entrancy into whatever
      //    was building the widget, and
      //  * the value a new listener wants is the one the source has when the
      //    event is DELIVERED, not the one it had at the instant `listen` was
      //    called. `subscribe()` immediately followed by an arriving batch is
      //    the ordinary startup order, and a synchronous push there hands the
      //    listener the placeholder and calls it the first value.
      scheduleMicrotask(push);
    });
  }

  /// The last known value for [key], or null when nothing is known yet.
  ///
  /// Synchronous, never a round trip, and **never a throw** — reading is what a
  /// widget does during a build. Null means "not known yet", which is a
  /// different statement from a known-bad value.
  ///
  /// A key the router *refuses* is neither: the gateway has affirmatively
  /// established it cannot serve that name, so [_touch] has already put a
  /// [Quality.errorConfig] value with a **null** payload into the store and
  /// this answers it. Never a zero and never a false — on a plant floor a
  /// good-quality `0` on a mistyped speed tag is a stopped conveyor and a
  /// good-quality `false` on a mistyped permit is an interlock reading
  /// satisfied.
  @override
  DynamicValue? read(String key) {
    _touch(key);
    final cached = _store.peek(key);
    if (cached == null) return null;
    // The verdict is RE-DERIVED here, not merely reported: the sweep's clock is
    // parked whenever nobody is watching, and a read taken during a parked
    // period must still be correct. `judge` does not write to the store — a
    // read is not an event, and one that notified every listener would make a
    // diagnostics page's poll a rebuild storm.
    //
    // Two judges, and each is the identity on the other's keys: the sweep
    // returns health keys untouched (they are outside freshness accounting,
    // HLTH-02) and the producer returns everything but its own one time-derived
    // gauge untouched. Composed rather than branched, so neither has to know
    // the other exists.
    return _health.judge(key, _sweep.judge(key, cached));
  }

  /// Forces a round trip and answers a freshly-read value.
  ///
  /// One code path with [readMany] so there is exactly one place an upstream
  /// read is awaited, and therefore exactly one place a deadline could go
  /// missing.
  @override
  Future<DynamicValue> readFresh(String key) async =>
      (await readMany(<String>[key]))[key]!;

  /// One round trip for many keys.
  ///
  /// **Every key asked for gets an answer**, including keys nothing is known
  /// about and keys the router refuses — as a bad-quality value rather than a
  /// missing entry, so the caller renders a fault instead of a blank. One bad
  /// key never fails the batch.
  ///
  /// The reads are issued concurrently and awaited together: reading fifty keys
  /// over a link with 200 ms of latency must cost 200 ms and not ten seconds,
  /// which is the reason this method is on the interface at all
  /// (`state_man_api.dart:100-105`). Everything that came back from upstream is
  /// then applied as **one** batch — one pass over the store, k notifications.
  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    final results =
        await Future.wait(<Future<_ReadAnswer>>[for (final key in keys) _readOne(key)]);
    final answers = <String, DynamicValue>{};
    final arrived = <String, DynamicValue>{};
    final degraded = <String, DynamicValue>{};
    for (final result in results) {
      answers[result.key] = result.value;
      if (!result.fromUpstream) continue;
      // A round trip that came back `badCommFault` did not reach the plant, so
      // it is not news from upstream and must not reset the freshness clock —
      // otherwise a disconnected PLC polled once a second is a key that never
      // goes stale. It still lands in the store: the screen has to learn.
      if (_isLinkDegraded(result.value.quality)) {
        degraded[result.key] = result.value;
      } else {
        arrived[result.key] = result.value;
      }
    }
    applyUpstreamBatch(arrived);
    _degrade(degraded);
    return answers;
  }

  /// Whether [quality] is one the freshness and link machinery applied, rather
  /// than one the plant reported.
  ///
  /// `fake_state_man.dart:487-489`'s distinction and its reason: a source that
  /// reset *any* bad quality on a read would launder a genuine upstream fault —
  /// a non-finite reading, a bad string encoding — into a healthy number, which
  /// is the same lie as a stale value with better manners.
  static bool _isLinkDegraded(Quality quality) =>
      quality == Quality.badStale || quality == Quality.badCommFault;

  /// One key's round trip. The only place an upstream read is awaited.
  Future<_ReadAnswer> _readOne(String key) async {
    final route = router.route(key);
    switch (route) {
      case RefusedRoute():
        return (key: key, value: _refuse(route), fromUpstream: false);
      case PipeKeyRoute():
        // The gateway's own namespace: there is nothing upstream to ask. 08-09
        // produces these; until then the honest answer for an unproduced one is
        // uncertain-not-yet-known, because waiting does fix it.
        //
        // Judged through the same composition [read] uses (09-REVIEW WR-02,
        // 09-04's deferred finding). Post 08-REVIEW CR-02 the stored
        // `data_age_ms` gauge is written only on link events and arrivals, so
        // the raw peek is the frozen last-pushed figure — and readFresh/
        // readMany are the only poll a REMOTE panel has (client-side read()
        // is a local store peek). During ST101's silent-freeze reproduction
        // F25b measured the judged path climbing 38 → 4012 ms while the peek
        // held 51 ms under good quality: the gauge built to expose staleness
        // was itself stale, on the wire path, during the one incident it
        // exists for. `judge` does not write — a read is not an event.
        final cached = _store.peek(key);
        return (
          key: key,
          value: cached == null
              ? notYetKnown
              : _health.judge(key, _sweep.judge(key, cached)),
          fromUpstream: false,
        );
      case ClaimedRoute(link: final link, ref: final ref):
        final value = await link.read(ref, deadline: readDeadline);
        return (key: key, value: value, fromUpstream: true);
    }
  }

  /// Every key this source can serve.
  ///
  /// The router's key set **union** the `PIPE.*` keys this instance has
  /// actually produced — a union and not a replacement, which is
  /// `cert_health_state_man.dart:317-320`'s rule. The health half is derived
  /// from what is in the store rather than from a roster, so 08-09 adding a
  /// producer puts its key here on the day it mints one and there is no second
  /// list to keep in step.
  ///
  /// Keys the router refused are **not** here: offering a refused name back to
  /// the page editor's key picker would launder a typo into an apparently valid
  /// binding.
  @override
  List<String> get keys => <String>{
        ...router.keys,
        for (final key in _store.keys)
          if (PipeKeys.isPipeKey(key) && _store.peek(key) != null) key,
      }.toList(growable: false);

  // ------------------------------------------------------------------- ingest

  /// Applies a batch of values that genuinely arrived from upstream.
  ///
  /// One `applyBatch`, never a loop of single sets: the sequence bookkeeping and
  /// the gap check happen once per batch, and only keys whose value actually
  /// changed notify. This is also the one seam that resets the freshness clock —
  /// see [_degrade] for the other half of that distinction.
  void applyUpstreamBatch(Map<String, DynamicValue> values) {
    if (values.isEmpty) return;
    // The ARRIVAL anchor, not the wall clock: everything downstream of this
    // number is an age. See [_elapsed].
    final now = _elapsed();
    final arrivedOn = <String>{};
    for (final key in values.keys) {
      _lastArrival[key] = now;
      final alias = aliasOfKey(key);
      if (alias != null) arrivedOn.add(alias);
    }
    _store.applyBatch(values);
    // AFTER the values, never before: `data_age_ms` describes them, and a gauge
    // that moved before the thing it measures is a page rendering the new age
    // of the old number. The set is aliases and not keys, so a four-hundred-key
    // poll cycle moves at most four gauges.
    _health.noteArrivals(arrivedOn, now);
  }

  /// Converts a batch of raw upstream samples and applies it.
  ///
  /// The plant-facing entry point: a link's poll cycle or a converter's output
  /// arrives here as key/raw pairs, and **one bad tag costs one tag**. See
  /// `ingest.dart` for the per-key `try`/`catch` and why it is not per batch.
  ///
  /// One [applyUpstreamBatch] for the whole cycle, so the store makes one pass
  /// and notifies k times for k changed keys — never a loop of single sets.
  IngestOutcome ingestRaw(
    Iterable<RawSample> samples, {
    Quality quality = Quality.good,
    DateTime? sourceTime,
  }) {
    final outcome = ingestSamples(samples,
        quality: quality, sourceTime: sourceTime, log: _ingestLog);
    applyUpstreamBatch(outcome.batch);
    return outcome;
  }

  /// What this instance has refused at ingest, and how often.
  IngestLog get ingestLog => _ingestLog;

  /// Applies a quality change **without** pretending a value arrived.
  ///
  /// The distinction is the whole freshness story: marking a value stale must
  /// not make it fresh again, and losing an upstream link is not news from
  /// upstream. A single seam that reset the clock on everything would produce a
  /// source that goes stale exactly once and never again
  /// (`fake_state_man.dart:390-397`).
  void _degrade(Map<String, DynamicValue> values) {
    if (values.isEmpty) return;
    _store.applyBatch(values);
  }

  // -------------------------------------------------------------- write path

  /// Writes [value] to [key] and reports which of the three things happened.
  ///
  /// **It never throws to report an outcome.** The two throws below are
  /// programmer errors, and they are the same two the reference implementation
  /// keeps (`fake_state_man.dart:645-670`): writing through a disposed source,
  /// and re-using a command id. A throw that meant "the write failed" would
  /// collapse "the PLC may have applied this" into "this definitely did not
  /// happen", which is the anti-pattern `WriteResult` exists to make
  /// unrepresentable.
  ///
  /// Three refusals are established **before** the plant is touched, and each
  /// is a `WriteRejected` rather than a `WriteUnknown` for the same reason:
  /// nothing was sent, so there is nothing to be unsure about.
  ///
  ///  * a key the router will not route (including a `PIPE.` name — the
  ///    gateway's own namespace is produced, never written into by a client);
  ///  * an `expect` that does not match the last known value;
  ///  * a value the wire cannot represent (a cycle, or a depth past 64).
  ///
  /// A **non-finite** value or `expect` is refused before all of those, and
  /// with an `ArgumentError` rather than a `WriteRejected`, because it is the
  /// same class of caller defect as the re-used id: `jsonEncode` cannot carry
  /// NaN or ±Infinity at all, so the only way to "apply" one is to null it —
  /// which actuates the device with a value nobody chose, or turns a guarded
  /// write into an unconditional one, under a message saying the write applied.
  /// A session never gets this far with one (`value_handlers.write` refuses at
  /// the wire), and the guard is here anyway: this source is a `StateManApi`
  /// that in-process callers and the contract suite both reach directly, and
  /// "refuse everywhere" is one policy or it is none (ruled 2026-09-06).
  ///
  /// The **idempotency window** — same cmd plus same key/value answered from
  /// the log, Stripe's semantic — is deliberately not here. It attaches at one
  /// named line in `value_handlers.write`, one layer up, because it is a
  /// property of the *wire*: two frames carrying one operator action. This
  /// source stays strict, and the gateway maps the throw below to
  /// `WriteUnknown(gateway_lost_track)`.
  @override
  Future<WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) async {
    if (_disposed) {
      throw StateError('write($key) on a disposed source: the store and the '
          'upstream links are both gone, so no outcome reported here could be '
          'true. This is a lifecycle bug in the caller, not a write outcome.');
    }
    // Before an id exists: an id that exists is an action a `writeStatus` can
    // no longer answer `not_received` about, and `not_received` is the one
    // verdict that makes a re-send safe. Both walks run before either refusal
    // so a non-finite buried in a nested structure is caught too.
    if (_carriesNonFinite(value)) {
      throw ArgumentError.value(
          value,
          'value',
          'a write cannot carry a non-finite number: it encodes to null, and '
              'a write of null actuates the device with a value nobody chose '
              'while the operator is told the write applied');
    }
    if (_carriesNonFinite(expect)) {
      throw ArgumentError.value(
          expect,
          'expect',
          'a write cannot carry a non-finite compare-and-set guard: nulling '
              'it is this path\'s encoding of "no guard at all", so a guarded '
              'write would silently become an unconditional one');
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final id = cmd ?? newUlid(nowMs: nowMs);
    // `containsKey` and not `putIfAbsent`'s return value: two writes under one
    // id in the same millisecond would compare equal and slip through, and the
    // same millisecond is exactly when a double-press arrives.
    if (_mintedCmds.containsKey(id)) {
      throw ArgumentError.value(
          id,
          'cmd',
          'this source has already seen the command id "$id". One id is one '
              'operator action: a second write under it would be a second '
              'actuation reported under the first one\'s outcome, which is '
              'the failure the id exists to make impossible');
    }
    // Recorded against THIS source's clock, before the crossing, so a re-use
    // is caught while the first write is still in flight.
    _mintedCmds[id] = nowMs;
    final outcome =
        await _settle(key: key, value: value, expect: expect, cmd: id);
    // The badge and the readback are BOTH applied at the one crossing into the
    // plant ([_crossIntoThePlant]) rather than here, since 08-11. Staging the
    // badge after the outcome made the in-flight window unobservable — a write
    // held open by a stalled PLC never reached this line, so the operator saw
    // nothing at exactly the moment the badge exists for — and applying the
    // readback nowhere at all meant a clamped setpoint left the mimic showing
    // the number that was typed, labelled confirmed.
    _recordOutcome(outcome);
    return outcome;
  }

  /// Whether [value] carries a NaN or an ±Infinity anywhere inside it.
  ///
  /// **A value `sanitize` cannot walk answers `false`**, deliberately. A cycle
  /// or a depth past 64 makes it throw, and that value has its own refusal one
  /// layer down — a `WriteRejected('unrepresentable_value')`, which is the
  /// honest answer for it: nothing was sent, and an `ArgumentError` escaping
  /// from here would read to the operator as "the write failed for a reason
  /// nobody knows". Deferring to that handler is the point, not an oversight.
  bool _carriesNonFinite(Object? value) {
    try {
      return sanitize(value).hadNonFinite;
    } catch (_) {
      return false;
    }
  }

  /// Everything one write does between the id and the answer.
  Future<WriteResult> _settle({
    required String key,
    required Object? value,
    required Object? expect,
    required String cmd,
  }) async {
    final at = _now().millisecondsSinceEpoch;
    final route = router.route(key);
    switch (route) {
      case RefusedRoute():
        return WriteRejected(
            cmd, WriteReason('unroutable_key', message: route.message),
            at: at);
      case PipeKeyRoute():
        return WriteRejected(
            cmd,
            WriteReason('unroutable_key',
                message: 'the key "$key" is in the gateway\'s own namespace, '
                    'which is produced here and never written into from a '
                    'session',
                status: 'Bad_NotWritable'),
            at: at);
      case ClaimedRoute(link: final link, ref: final ref):
        // Compare-and-set, as far as this side can honestly offer it: the
        // comparison is against the last value the gateway heard, which is a
        // guard and not an atomic CAS — a protocol that can do better should
        // do it in its adapter. Refusing on a mismatch is the point; an
        // `expect` that was silently ignored would be worse than none at all,
        // because the caller believes it is guarded.
        if (expect != null) {
          final cached = _store.peek(key);
          if (cached == null || !jsonEquals(cached.value, expect)) {
            return WriteRejected(
                cmd,
                WriteReason('expect_mismatch',
                    message: 'the value this gateway last heard for "$key" is '
                        'not the one the caller compared against, so the '
                        'write was not sent'),
                at: at);
          }
        }
        final DynamicValue payload;
        try {
          payload = DynamicValue(value: value);
        } catch (error) {
          // `sanitize` throws on a cycle or a depth past 64 (08-RESEARCH §H).
          // A throw here would read to the operator as "the write failed for a
          // reason nobody knows"; this is definitively no effect.
          return WriteRejected(
              cmd,
              WriteReason('unrepresentable_value',
                  message: redactUpstreamError(error.toString())),
              at: at);
        }
        return _crossIntoThePlant(
            link: link,
            ref: ref,
            value: payload,
            cmd: cmd,
            // Carried down (08-REVIEW WR-02). The comparison itself happened
            // above and against the last value THIS side heard, which is the
            // only place it can happen; what an adapter needs is the one bit,
            // so that the array-element ruling can allow the read-modify-write
            // its own doc says a comparison makes safe.
            hasExpect: expect != null);
    }
  }

  /// **The one place in this package that asks a plant to move something.**
  ///
  /// Every write funnels through here — the operator's, a hold engage, every
  /// hold tick, the release — so there is exactly one line to read to know
  /// what the gateway does to a PLC, and exactly one place a deadline could go
  /// missing. `freeze_test.dart`'s freeze 4 pins the count at one and freeze 3
  /// pins that it is bounded; anyone adding a second site trips a named pin
  /// rather than a code review (T-08-22, `no_retry_test.dart:182-293`'s shape).
  ///
  /// There is no retry here and there is nowhere to put one: this method makes
  /// one call and returns what came back. A lost answer is `WriteUnknown` and
  /// what happens next is an operator's decision, never this code's.
  Future<WriteResult> _crossIntoThePlant({
    required UpstreamLink link,
    required UpstreamRef ref,
    required DynamicValue value,
    required String cmd,
    bool confirmByReading = true,
    bool hasExpect = false,
  }) async {
    // The last confirmed reading, kept so a refused or lost write can put it
    // back: the badge means "sent", and a write that was not sent must not
    // leave one on.
    final confirmed = _store.peek(ref.key);
    // Before the crossing, not after it. Over a slow link the pending badge is
    // the only thing telling an operator their press was registered, and an
    // operator who sees nothing presses again — which on a jog is a second
    // actuation nobody asked for.
    _markWritePending(ref.key);
    try {
      // Deliberately one line, over the usual width: `freeze_test.dart`'s
      // unbounded-await sweep reads LINES, so a call whose `deadline:` sits on
      // a continuation line reads to it as an unbounded upstream await. The
      // sweep is right to be literal — a bound it cannot see is a bound the
      // next reader cannot see either.
      final outcome = await link.write(ref, value, cmd: cmd, deadline: writeDeadline, hasExpect: hasExpect);
      await _confirmWrite(
        link: link,
        ref: ref,
        sent: value,
        outcome: outcome,
        confirmed: confirmed,
        confirmByReading: confirmByReading,
      );
      return outcome;
    } catch (error) {
      _unbadge(ref.key, confirmed);
      // `UpstreamLink.write` is contracted never to throw, so this is a bug in
      // an adapter rather than news about a plant — and the honest report of a
      // bug on the write path is still "nobody knows", because the request may
      // already have been on the wire when it happened. STATE.md's mapping.
      return WriteUnknown(
          cmd,
          WriteReason('gateway_lost_track',
              message: redactUpstreamError(error.toString())));
    }
  }

  /// Re-asks what became of [cmds], positionally.
  ///
  /// The four-piece positive-evidence rule, mirrored from
  /// `fake_state_man.dart:715-740` rather than loosened, with two answers the
  /// reference has no need for because a fake lives for one test and a gateway
  /// runs for months: [writeOutcomeTtl] expiry and cap eviction. Both answer
  /// **unknown**, never `not_received`.
  ///
  /// ### This log answers about the PLANT, and the shared one about the WIRE
  ///
  /// `WriteOutcomeLog` — since 18-04 in `tfc_relay_protocol`
  /// (`lib/src/write_outcome_log.dart`), and until then duplicated between
  /// `tfc_relay_server` and `tfc_dart` — is one per server or per backend and
  /// survives session churn; it knows whether a *frame* arrived. This one knows
  /// whether a *plant* was asked. They are deliberately not merged: a gateway
  /// restart resets this one and not that one, and pretending otherwise would
  /// let a `writeStatus` claim knowledge of a write that never reached a PLC.
  ///
  /// **This log is a third design, and 18-04 ruled that it stays one.** It is
  /// not a stale copy of the shared class, and the differences are the reason:
  ///
  ///  * **five answers, not four.** It adds `outcome_forgotten`, driven by the
  ///    [_forgottenBeforeMs] watermark that both cap eviction and TTL prune
  ///    move, so a command from an evicted era is never told `not_received`.
  ///    The shared log needs no such answer because it never evicts;
  ///  * **it is capped** at [maxWriteOutcomes] (4096) with LRU eviction, where
  ///    the shared log is unbounded in count and bounded only in time;
  ///  * **its TTL is 10 minutes**, against the shared log's 60 seconds, because
  ///    a plant-side log answers about a machine an operator may come back to,
  ///    not about a frame.
  ///
  /// Merging them would therefore be a behaviour change in both directions, not
  /// a de-duplication. The mirror of this paragraph is in the shared file's
  /// library doc.
  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) async {
    _pruneWriteOutcomes();
    return alignWriteStatusAnswers(
      cmds,
      <WriteResult>[for (final cmd in cmds) _statusOf(cmd)],
    );
  }

  WriteResult _statusOf(String cmd) {
    final held = _outcomes[cmd];
    if (held != null) return held.result;

    final mintedAt = ulidMs(cmd);
    if (mintedAt == null) {
      return WriteUnknown(
          cmd,
          const WriteReason('unrecognized_cmd',
              message: 'this is not an id this source could have issued an '
                  'outcome for, so nothing about it can be ruled out'));
    }
    final nowMs = _now().millisecondsSinceEpoch;
    if (mintedAt < _startedMs || mintedAt > nowMs) {
      return WriteUnknown(
          cmd,
          const WriteReason('outcome_unwitnessed',
              message: 'this command was minted outside the window this '
                  'source can vouch for with its own clock — before it '
                  'started recording, or ahead of it. Read the value back '
                  'before acting'));
    }
    if (nowMs - mintedAt > writeOutcomeTtl.inMilliseconds) {
      return WriteUnknown(
          cmd,
          const WriteReason('outcome_expired',
              message: 'this command is older than the window this gateway '
                  'keeps outcomes for. Read the value back before acting'));
    }
    if (mintedAt <= _forgottenBeforeMs) {
      // The log was full and dropped its oldest entries. A command from that
      // era WAS received and may well have moved the machine, so the one
      // answer it must never get is `not_received` — the log has to remember
      // that it forgot. Conservative at the edges by construction: a command
      // minted in the same millisecond as an evicted one is answered unknown
      // too, which costs a readback and saves an unasked-for actuation.
      return WriteUnknown(
          cmd,
          const WriteReason('outcome_forgotten',
              message: 'this gateway settled and then dropped outcomes from '
                  'around this command\'s time, so it cannot say this one was '
                  'never received. Read the value back before acting'));
    }
    return WriteNotReceived(cmd);
  }

  /// Settled outcomes, oldest first — a `LinkedHashMap` by insertion, which is
  /// what makes "drop the oldest" one line rather than a sort.
  final Map<String, _LoggedOutcome> _outcomes = <String, _LoggedOutcome>{};

  /// Every id this source has seen recently, so a re-use is caught while the
  /// first write is still in flight — not only after it settles.
  ///
  /// **Bounded, on the same two rules as [_outcomes]** — see
  /// [_pruneMintedCmds]. The value is the instant *this source first saw the
  /// id*, on its own clock, and deliberately not the id's ULID time: the id is
  /// minted by a client, so its ULID can be ancient, skewed or not a date at
  /// all, and none of those are facts about how long this gateway has been
  /// holding it. That is the same distinction `_LoggedOutcome` draws between
  /// `at` and the mint time, for the same reason.
  ///
  /// A `LinkedHashMap` by insertion, which is what makes "drop the oldest" one
  /// line rather than a sort.
  final Map<String, int> _mintedCmds = <String, int>{};

  /// How many minted ids the duplicate guard is holding. A diagnostic, and the
  /// observable that makes WR-08's bound falsifiable.
  int get mintedCmdCount => _mintedCmds.length;

  /// The instant this source started recording. Evidence, not decoration: a
  /// command minted before it is one this source could never have heard about.
  late final int _startedMs;

  /// The mint-time of the newest outcome the cap has evicted. See [_statusOf].
  int _forgottenBeforeMs = 0;

  /// How many settled outcomes the log is holding.
  int get writeOutcomeCount => _outcomes.length;

  /// Keys carrying the in-flight badge right now.
  ///
  /// Derived from the store rather than kept alongside it, so it cannot drift:
  /// the badge is on the value or it is not, and the freshness sweep taking it
  /// off is not something this class has to be told about.
  Set<String> get writePendingKeys => <String>{
        for (final key in _store.keys)
          if (_store.peek(key)?.quality == Quality.goodWritePending) key,
      };

  void _recordOutcome(WriteResult result) {
    _pruneWriteOutcomes();
    _outcomes[result.cmd] =
        (result: result, at: _now().millisecondsSinceEpoch);
    while (_outcomes.length > maxWriteOutcomes) {
      final oldest = _outcomes.keys.first;
      _forgottenBeforeMs =
          [_forgottenBeforeMs, ulidMs(oldest) ?? 0].reduce((a, b) => a > b ? a : b);
      _outcomes.remove(oldest);
    }
  }

  /// Drops outcomes past [writeOutcomeTtl], **and remembers that it did**.
  ///
  /// It moves [_forgottenBeforeMs], and 08-REVIEW CR-03 is why. The argument
  /// for not moving it was that an expiry is answerable on the command's own
  /// age (`outcome_expired`), and that argument holds only while
  /// `mintedAt <= at` — but the cmd is minted by the **client**
  /// (`value_handlers.dart:677` passes `request.cmd` straight through), and a
  /// panel's clock may run ahead of the gateway's.
  ///
  /// With a panel `s` milliseconds fast, an entry settled at gateway time `T`
  /// carried `at = T` and a ULID reading `T + s`. It was pruned once
  /// `now - T > ttl`; a query one millisecond later found no held outcome, a
  /// mint time inside the TTL on its own age, and a watermark nothing had
  /// moved — so it fell through to `WriteNotReceived` for a write the gateway
  /// had performed. `not_received` is documented at the field above as the one
  /// answer that tells an operator a re-send is safe, and a re-send there is a
  /// second unrequested actuation.
  ///
  /// The cap path was always safe by contrast — an evicted ULID contributed
  /// its own mint time — so this makes the two ways of forgetting behave the
  /// same. It does not widen anything else: a cmd minted after the watermark
  /// still earns `not_received` on the same four pieces of positive evidence.
  void _pruneWriteOutcomes() {
    final cutoff = _now().millisecondsSinceEpoch - writeOutcomeTtl.inMilliseconds;
    _outcomes.removeWhere((cmd, entry) {
      if (entry.at >= cutoff) return false;
      final minted = ulidMs(cmd) ?? 0;
      if (minted > _forgottenBeforeMs) _forgottenBeforeMs = minted;
      return true;
    });
    _pruneMintedCmds(cutoff);
  }

  /// Keeps [_mintedCmds] bounded, on the same two rules that bound
  /// [_outcomes].
  ///
  /// 08-REVIEW WR-08: the set had nothing removing from it, so a plant where
  /// anything writes on a schedule grew it monotonically for months — the leak
  /// [maxWriteOutcomes] exists to prevent, without even an audit trail to show
  /// for it. The asymmetry was semantic too: an id that had fallen out of
  /// `_outcomes` was answered `outcome_expired` but was still in here, so
  /// re-using a very old id threw `ArgumentError` instead of being answered.
  ///
  /// **Dropping an id is safe because the log has already forgotten its
  /// outcome.** The duplicate-id refusal exists so that one id is one operator
  /// action while that action is still answerable; past the TTL it is not
  /// answerable by anything, and [_statusOf] now says so through the watermark
  /// this prune moves.
  ///
  /// Two rules and not one, because they cover different holes: an id seen
  /// inside the window is never dropped however many arrive behind it, and the
  /// insertion-order cap bounds a burst that all arrives inside one window.
  /// Neither can reach the newest id, so a write in flight cannot have its own
  /// id evicted out from under it.
  void _pruneMintedCmds(int cutoff) {
    _mintedCmds.removeWhere((_, seenAt) => seenAt < cutoff);
    while (_mintedCmds.length > maxWriteOutcomes) {
      _mintedCmds.remove(_mintedCmds.keys.first);
    }
  }

  /// Puts the in-flight badge on [key]'s current value.
  ///
  /// The band guard and its reason are `fake_state_man.dart:936-938`'s:
  /// `goodWritePending` is a **good**-band code, so stamping it onto a stale or
  /// comm-faulted value would make a write a way of making a dead tag look
  /// alive. Applied through [_degrade] and never through [applyUpstreamBatch],
  /// because a write starting is not news from upstream — resetting the
  /// freshness clock here would let a page keep itself looking current by
  /// writing to itself.
  ///
  /// Nothing takes the badge off deliberately. The next upstream sample
  /// overwrites it (readback is the only confirmation) and, if none comes, the
  /// freshness sweep overtakes it with `badStale` — which is the operator-
  /// visible difference between "sent" and "confirmed".
  void _markWritePending(String key) {
    final cached = _store.peek(key);
    if (cached == null) return;
    if (cached.quality.band > Quality.goodWritePending.band) return;
    _degrade(<String, DynamicValue>{
      key: cached.copyWith(quality: Quality.goodWritePending),
    });
  }

  /// Applies what the device came back holding — or takes the badge off.
  ///
  /// **Readback is the only confirmation this system accepts**, and this is
  /// where that sentence becomes a value on a screen. A PLC clamping a setpoint
  /// to its configured maximum is ordinary; a mimic that shows 5000 while the
  /// machine runs at 1500 has told the operator the plant is doing something it
  /// is not, and told it *by the confirmation*, which is the one message they
  /// had no reason to doubt.
  ///
  /// The quality comes from what was **sent**, not from a fresh `good`, so a
  /// payload that left here already degraded cannot be re-labelled good by its
  /// own readback. Nothing produces such a payload today — [write] refuses a
  /// non-finite value outright since 2026-09-06, and that was the only way one
  /// was ever minted — but the rule is about the *direction* of the labelling
  /// and stays: a confirmation may lower what a value claims about itself and
  /// may never raise it.
  /// ## An acknowledgement with no readback in it (08-REVIEW CR-01)
  ///
  /// **Neither real adapter can supply a readback**, and that is a fact about
  /// the protocols rather than a gap in the adapters: OPC UA's write service
  /// answers a status code and Modbus echoes a function code, so both hand
  /// back `WriteAcknowledged(at: …)` with `readback: null`. This method used to
  /// put that null into the store under [Quality.good] — a good-quality blank
  /// on the tag the operator had just written, on **every successful write the
  /// shipped gateway made**, until the next upstream sample repainted it.
  ///
  /// The ruling is that *applied* means applied **and read back**, so when the
  /// acknowledgement carries no value this performs **one bounded read** and
  /// adopts what the device answers. A read is not a retry: it does not
  /// re-issue the command, it asks the plant what it now holds, and asking is
  /// the only way this system is permitted to be sure. It is one read and
  /// there is nowhere to put a second.
  ///
  /// If that read produces no reading either, the outcome stays [WriteApplied]
  /// — a failed readback is not evidence the write did not land — and **the
  /// store is left exactly as it was**. The subscription stream remains the
  /// truth. Never a synthetic value, never the number that was typed, and
  /// never a null under a good quality.
  Future<void> _confirmWrite({
    required UpstreamLink link,
    required UpstreamRef ref,
    required DynamicValue sent,
    required WriteResult outcome,
    required DynamicValue? confirmed,
    required bool confirmByReading,
  }) async {
    final key = ref.key;
    if (outcome is! WriteApplied) {
      _unbadge(key, confirmed);
      return;
    }
    if (outcome.readback == null) {
      // A `if (!sent.quality.isGood)` arm stood here, adopting a null rather
      // than reading the device back: a non-finite write was sanitized to a
      // null under `badNonFinite` before it crossed, and going off to read the
      // device would have replaced a known fault with whatever it happened to
      // hold. [write] now refuses that value instead of sanitizing it
      // (2026-09-06), and it was the only producer of a degraded `sent` — the
      // two crossings into the plant build their payload from a finite value
      // (`:843`) and from a hold counter (`:1361`), both good. The arm is gone
      // rather than left unreachable, because a branch nothing can enter reads
      // as live policy to the next person deciding what a bad sent quality
      // means. `_adoptReadback` still carries the sent quality forward, which
      // is where the direction rule actually lives.
      final adopted =
          confirmByReading ? await _readBack(link, ref) : null;
      if (adopted == null) {
        // Nothing was confirmed about the VALUE. Take the badge off — a badge
        // left on is a permanent amber box the operator learns to ignore — and
        // leave the reading alone for the next upstream sample to move.
        _unbadge(key, confirmed);
        return;
      }
      _adoptReadback(key, sent: sent, readback: adopted);
      return;
    }
    // **The badge comes OFF, and the readback is why.** 08-06 kept it on until
    // a later upstream sample, on the rule that readback is the only
    // confirmation. It still is — but a `WriteApplied` IS a readback:
    // `upstream_link.dart` says "applied means applied *and read back*, because
    // readback is the only confirmation this system accepts". The confirmation
    // has arrived, carrying the number the device actually holds. A badge left
    // on past it is a permanent amber box the operator learns to ignore, which
    // is what `checkWritePendingIsVisibleWhileInFlight` fails on and it is
    // right to: the window has to CLOSE for it to mean anything while it is
    // open.
    //
    _adoptReadback(key, sent: sent, readback: outcome.readback);
  }

  /// **One** bounded read, to find out what the device now holds.
  ///
  /// Answers the payload to adopt, or **null** for "the plant did not give me
  /// a reading" — which covers a timeout, a comms fault, a tag that has left
  /// the address space, and the honest not-yet-known of a link that has never
  /// delivered anything for this key. Every one of those is a reason to leave
  /// the store alone rather than to invent a value for it.
  ///
  /// It cannot throw its way out: [UpstreamLink.read] is contracted never to
  /// throw, and the `catch` is here for the adapter that breaks that contract
  /// — a bug in an adapter must not turn a successful write into an exception
  /// out of the write path.
  Future<Object?> _readBack(UpstreamLink link, UpstreamRef ref) async {
    final DynamicValue seen;
    try {
      seen = await link.read(ref, deadline: readDeadline);
    } catch (_) {
      return null;
    }
    if (seen.value == null) return null;
    // A good-band answer or nothing. `uncertainLastKnown` is the link telling
    // us it has not re-read this since it came back, which is precisely not a
    // confirmation; adopting it would label a pre-write reading "confirmed".
    if (!seen.quality.isGood) return null;
    return seen.value;
  }

  /// Puts a confirmed reading on [key], under the same two guards the badge
  /// uses.
  void _adoptReadback(String key,
      {required DynamicValue sent, required Object? readback}) {
    // A quality that was already bad when it was sent survives. Nothing mints
    // such a payload today — [write] refuses the non-finite value that was the
    // only source of one — and the rule is kept for its direction: a
    // confirmation may lower what a value claims about itself and may never
    // raise it, so a readback cannot relabel a degraded write `good`.
    final quality = sent.quality.isGood ? Quality.good : sent.quality;
    final cached = _store.peek(key);
    // The same band guard the badge uses. An applied write must not make a
    // dead tag look alive: stamping a good-band readback over a comm fault
    // would turn a write into a way of reviving a value nobody has heard from.
    if (cached != null && cached.quality.band > quality.band) return;
    // Through `_degrade` and not `applyUpstreamBatch`: nothing arrived from the
    // plant of its own accord, so the freshness clock must keep running. A
    // readback that reset it would leave the operator looking at "sent a
    // moment ago" on a value nobody has heard about for a minute.
    _degrade(<String, DynamicValue>{
      key: DynamicValue(value: readback, quality: quality),
    });
  }

  /// Puts [confirmed] back if the badge is still the only thing on the value.
  ///
  /// Guarded on the badge still being there: an upstream sample that arrived
  /// while the write was out is news and must not be overwritten by a reading
  /// from before it.
  void _unbadge(String key, DynamicValue? confirmed) {
    final cached = _store.peek(key);
    if (cached == null || cached.quality != Quality.goodWritePending) return;
    if (confirmed == null) return;
    _degrade(<String, DynamicValue>{key: confirmed});
  }

  /// Engages a hold-to-run deadman on [key] and hands back the live hold.
  ///
  /// **The deadman is an ordinary tag written through the ordinary path.** The
  /// engage is [write] and so is the release, which is what makes a hold
  /// interlockable like any other command and what puts its outcome in the
  /// same log `writeStatus` answers from. There is exactly one key and it is
  /// the one passed in.
  ///
  /// [HoldHandle] is constructed, never subclassed, and no member is added to
  /// `StateManApi` — the surface is pinned at 49 (`api_surface_test.dart:
  /// 213-224`) and the two-callback design exists precisely so one class
  /// serves the fake, the harness, the gateway and the client. `tick()` is not
  /// on the interface and must never be put there: a method there is something
  /// any connected client may invoke against any key, and a bare `tick(key, n)`
  /// is a write primitive with no engage in front of it.
  ///
  /// The counter is minted **here** and a tick's value never comes from a
  /// caller (`value_handlers.dart:628-654` discards the wire's `n` for the same
  /// reason): the liveness an operator's finger is supposed to provide must not
  /// be something a peer can assert.
  @override
  Future<HoldHandle> holdToRun(String key) {
    // **Ahead of the registry's engage guard, and it is a finding rather than
    // caution.** [write] throws a `StateError` on a disposed source *on
    // purpose* — "a lifecycle bug in the caller, not a write outcome" (`:730`,
    // pinned by `write_test.dart:541`). 18-05 adopted `tfc_dart`'s
    // throw-into-outcome guard for the engage, on the argument that a throw
    // there is a bug rather than news about a plant; that argument is right
    // about a link blowing up and wrong about this line, which is the one
    // throw on this path that is a deliberate, documented answer. Without this
    // check the guard would quietly turn it into
    // `WriteUnknown(write_path_failed)` and hand back an inert handle — a loud
    // lifecycle bug converted into a jog button that silently does nothing.
    //
    // `tfc_dart` needs no equivalent: its own write REFUSES after teardown
    // rather than throwing (`backend_writes_test.dart`, "is disposed loudly"),
    // so its guard never had this case to swallow.
    if (_disposed) {
      throw StateError('holdToRun($key) on a disposed source: the store and '
          'the upstream links are both gone, so no hold taken here could be '
          'fed and no outcome reported here could be true. This is a '
          'lifecycle bug in the caller, not a write outcome.');
    }
    return _holds.engage(key);
  }

  /// Every hold this source is currently feeding, so [dispose] can end them.
  ///
  /// Shared with `tfc_dart` since 18-05 (`hold_registry.dart`): the live set,
  /// the engage guard and release-all were the same forty lines in both
  /// packages. Three things about this construction are load-bearing:
  ///
  ///  * **[feed] is [write] and [onTick] is [_feedDeadman], and they are two
  ///    different functions.** That is difference 4 of the four the extraction
  ///    found, left exactly where it was: an engage and a release are ordinary
  ///    commands somebody may ask `writeStatus` about, and a tick is liveness
  ///    that deliberately never reaches the outcome log. A registry that
  ///    derived the tick from the feed would have moved 1 200 entries per
  ///    two-minute hold into a bounded log.
  ///  * **`awaitReleases: true` is this side's answer** to the one question the
  ///    two call sites answer differently. Awaited, and safely: every upstream
  ///    write is bounded by its *required* deadline (`upstream_link.dart`), so
  ///    there is nothing here that can hang — and a dispose that gave up half
  ///    way would leave the thing it was disposing in a state nobody owns.
  ///    `tfc_dart` passes `false` and says a teardown that waited would hang on
  ///    the dead link that caused it; that argument does not survive a required
  ///    deadline, which is why 18-05 records changing *that* side as the
  ///    deferred decision rather than this one.
  ///  * **No `onLostWrite`.** This package has no logger by design — the
  ///    constructor spawns nothing and errors become values rather than log
  ///    lines (see the header) — and the release loop this replaces swallowed
  ///    its errors silently too. Preserved rather than improved; the one thing
  ///    it now hides that it did not before is a *throw* out of the engage,
  ///    which `write` promises never to do.
  late final HoldRegistry _holds = HoldRegistry(
    feed: (key, counter) => write(key, counter),
    onTick: _feedDeadman,
    awaitReleases: true,
  );

  /// One tick: the gateway's counter, onto the plant, with nobody waiting.
  ///
  /// Fire-and-forget by design — safety comes from the counter *stopping*, so
  /// giving a tick an outcome would invite somebody to await it, and awaiting
  /// liveness is how a stalled socket becomes a queue
  /// (`hold_handle.dart:127-133`). A lost tick costs nothing a re-tick 100 ms
  /// later does not fix, so it neither ends the hold nor throws.
  ///
  /// **Ticks are deliberately not recorded in the outcome log.** The engage and
  /// the release are commands somebody may ask `writeStatus` about; a tick is
  /// liveness. At 10 Hz a two-minute hold is 1,200 of them, and recording them
  /// would evict the operator's real outcomes out of a bounded log inside
  /// seconds — which is the log answering "I forgot" about the writes that
  /// mattered so that it could remember the ones that did not.
  void _feedDeadman(String key, int counter) {
    if (_disposed) return;
    final route = router.route(key);
    // Not a ClaimedRoute means the engage cannot have applied, so there is no
    // live hold to feed. Checked rather than asserted: a route can stop being
    // claimed under a hold (a disabled alias, a keymapping reload), and the
    // right answer to that is to stop feeding, not to throw into a timer.
    if (route is! ClaimedRoute) return;
    final sent = _crossIntoThePlant(
      link: route.link,
      ref: route.ref,
      value: DynamicValue(value: counter),
      cmd: newUlid(nowMs: _now().millisecondsSinceEpoch),
      // **A tick buys no readback read**, and this is the one place that flag
      // is false. The counter is liveness the gateway minted, not a number an
      // operator is reading off a mimic, so there is nothing for a readback to
      // confirm to anybody — and at 10 Hz a read per tick would double what a
      // hold costs the PLC for the whole time somebody's finger is on the
      // button. What a tick still gets is the honest half of CR-01: no
      // good-quality blank is published for it either.
      confirmByReading: false,
    );
    // `unawaited` attaches NO error handler (project memory), and an
    // unhandled error out of a tick would take down the isolate the whole
    // gateway runs on. `state_man.dart:2369` is the shape, discipline
    // included.
    unawaited(sent.catchError((Object error) => WriteUnknown(
        'tick',
        WriteReason('gateway_lost_track',
            message: redactUpstreamError(error.toString())))));
  }

  /// Ends every live hold, writing the zero, before anything is torn down.
  ///
  /// Awaited, and safely: every upstream write is bounded by its required
  /// deadline (`upstream_link.dart`), so there is nothing here that can hang
  /// and therefore no `.timeout(` on this path — a dispose that gave up half
  /// way would leave the thing it was disposing in a state nobody owns. That
  /// argument is now `awaitReleases: true` on [_holds]; `release` is still
  /// idempotent, so a disconnect racing an operator's finger cannot put two
  /// zeros on the wire, and one throwing release still does not abandon the
  /// rest.
  Future<void> _releaseHolds(HoldEnded reason) =>
      _holds.releaseAll(reason: reason);

  // ---------------------------------------------------- the live address space

  /// Browse over the configured links, one level at a time.
  ///
  /// The same instance every time it is asked for, not a fresh one: a
  /// [LocalBrowse] accumulates [LocalBrowse.incidents], and a getter that
  /// rebuilt would throw away the record of the level that did not arrive at
  /// the moment somebody went looking for it.
  ///
  /// Keys and browse answer different questions — see `local_browse.dart`. A
  /// link with no [UpstreamLink.supportsBrowse] is absent from the tree and
  /// present in the keymapping, which is the honest description of an M2400.
  @override
  BrowseApi get browse => _browse;
  late final LocalBrowse _browse = LocalBrowse(
    links: links,
    spaces: browseSpaces,
    deadline: readDeadline,
  );

  // ----------------------------------------------------------------- history

  /// Recorded samples, over the gateway's own collection plan.
  ///
  /// The same instance every time it is asked for — `browse`'s rule, for
  /// `browse`'s reason: a getter that rebuilt would discard whatever the
  /// composition wired.
  ///
  /// **A gateway with no `collection:` block has none of this**, and says so.
  /// 8b-01 made historising a deliberate two-field act precisely so that a
  /// gateway nobody configured constructs no database object at all; there is
  /// therefore nothing to read from, and the honest answer is to fail. An
  /// empty reader would be worse than a failure in the way that matters
  /// here — it would draw every chart flat, for months, with nothing anywhere
  /// saying why.
  ///
  /// It is a [StateError] and **not** an `UnimplementedError`: the member is
  /// implemented, and what is absent is a historian in this deployment. The
  /// ledger in `freeze_test.dart` dropped from three to two in the commit
  /// that made this true, and it would be lying if it still counted this one.
  @override
  TimeseriesApi get timeseries {
    final reader = _timeseries;
    if (reader == null) {
      throw StateError('this gateway was composed without a historian, so it '
          'has no recorded samples to serve. Give it a `collection:` block '
          'with an endpoint and `enabled: true`; a gateway with no such '
          'block constructs no database object at all, deliberately '
          '(collection_config.dart\'s class doc)');
    }
    return reader;
  }

  final TimeseriesApi? _timeseries;

  /// Saved history views, when this deployment has a database.
  ///
  /// Exactly [timeseries]'s shape and for exactly its reasons, so the two are
  /// worth reading together. The member is **implemented**; what a gateway
  /// with no `collection:` block lacks is a database, and 8b-01 made having
  /// one a deliberate two-field act. So the absence is a deployment fact and
  /// this throws a [StateError] naming the composition, **not** an
  /// `UnimplementedError` naming a plan — which is what let
  /// `declaredUnimplementedMembers` honestly drop from two to one in the
  /// commit that made this true.
  ///
  /// Not an empty store: a view picker that answers "you have saved nothing"
  /// to a plant that has saved plenty is an operator saving their view a
  /// second time, and then a third.
  @override
  HistoryViewApi get historyViews {
    final store = _historyViews;
    if (store == null) {
      throw StateError('this gateway was composed without a database, so it '
          'has nowhere to keep a saved history view. Give it a `collection:` '
          'block with an endpoint and `enabled: true`; a gateway with no such '
          'block constructs no database object at all, deliberately '
          '(collection_config.dart\'s class doc)');
    }
    return store;
  }

  final HistoryViewApi? _historyViews;

  // ----------------------------------------------------------- not this phase

  /// Stored preferences, when this deployment has a database.
  ///
  /// The same instance every time it is asked for — `browse`'s rule, and here
  /// it is load-bearing rather than tidy: a session subscribes to
  /// `preferences.onPreferencesChanged` (`relay_session.dart:899`), and a
  /// getter that rebuilt would hand every session a different feed, each with
  /// its own channel subscription on the shared notification connection.
  ///
  /// **An [UnsupportedError], and NOT the [StateError] that [timeseries] and
  /// [historyViews] answer with.** The three absences are the same absence —
  /// no `collection:` block, so no database object exists at all — but this
  /// member is reached differently. `RelaySession` calls
  /// `data.watchPreferences()` on **every** session, unconditionally, and
  /// `data_handlers.dart:216` catches exactly `on UnsupportedError` for "a
  /// source with no preference store"; nothing else there is caught. A
  /// `StateError` would therefore escape session setup on every gateway with
  /// no `collection:` block, which is the default deployment — the whole
  /// plant would fail to connect over a member nobody asked for.
  ///
  /// That this getter *used* to throw at all was survivable for the same
  /// reason and by accident: `UnimplementedError implements UnsupportedError`
  /// (`dart:core` `errors.dart:595`), so the ledger's placeholder was being
  /// swallowed by that catch all along. Worth knowing before anyone
  /// "harmonises" the three refusals.
  @override
  PreferencesApi get preferences {
    final store = _preferences;
    if (store == null) {
      throw UnsupportedError('this gateway was composed without a database, '
          'so it has no shared preference store to serve. Give it a '
          '`collection:` block with an endpoint and `enabled: true`; a '
          'gateway with no such block constructs no database object at all, '
          'deliberately (collection_config.dart\'s class doc). Device-local '
          'settings are deliberately not on this pipe either way');
    }
    return store;
  }

  final PreferenceStore? _preferences;

  // ------------------------------------------------------- the access families
  //
  // The four getters plan 17-03 added to `StateManApi`. **No Phase 17 plan owns
  // this file** (17-03's Finding F-C), so the decision is recorded here.

  /// The one shape every access refusal on this class takes.
  ///
  /// **Unconditional, and that is what makes it different from the three
  /// refusals above.** [timeseries], [historyViews] and [preferences] refuse
  /// only when the gateway was composed without a database, and
  /// `fanin_test.dart` proves each is composable as well — which is what makes
  /// their absence a *deployment fact*. These four are not like that: this
  /// package has no access store to compose, no constructor argument that could
  /// carry one, and nothing in Phase 17 that adds one.
  ///
  /// The access stores live in `tfc_dart` (`lib/core/access/`, D-02) and are
  /// served by `BackendStateMan`, which is the composition the backend actually
  /// runs. `LocalStateMan` is the **plant leg** — DeviceClients and a
  /// historian — and administering roles is not on it. So the answer here *is*
  /// the refusal; nobody owes this file an implementation.
  ///
  /// An [UnsupportedError] and **never** an `UnimplementedError`.
  /// `freeze_test.dart`'s `declaredUnimplementedMembers` is 0 and counts
  /// members somebody still owes code for; putting these four in it would claim
  /// a debt that does not exist. And since `UnimplementedError implements
  /// UnsupportedError` (`dart:core errors.dart:595`), the wrong choice would be
  /// invisible to every catch clause and visible only to that ledger — which is
  /// why `access_refusal_test.dart` pins the distinction directly.
  Never _noAccessStore(String member) =>
      throw UnsupportedError('LocalStateMan.$member is not available: this '
          'gateway serves the plant, not the access-control database. The '
          'access stores live in tfc_dart (lib/core/access/) and are served by '
          'BackendStateMan; a panel in gateway mode reaches them through the '
          'backend composition, never through this leg. Nothing is missing '
          'from this deployment — the answer is that this source does not '
          'carry the $member family at all.');

  @override
  AccessTemplateApi get accessTemplates => _noAccessStore('accessTemplates');

  @override
  AccessAdminApi get accessAdmin => _noAccessStore('accessAdmin');

  @override
  AuditApi get audit => _noAccessStore('audit');

  @override
  BackendConfigApi get backendConfig => _noAccessStore('backendConfig');

  // ---------------------------------------------------------------- internals

  /// Establishes what the gateway can say about [key] before it is read.
  ///
  /// Only routes when the store holds nothing: a route is a map lookup, but a
  /// read is on the widget build path and the cheapest correct thing to do for
  /// a key that already has a value is nothing at all.
  void _touch(String key) {
    if (_store.peek(key) != null) return;
    final route = router.route(key);
    if (route is RefusedRoute) _refuse(route);
  }

  /// Records a refusal as a value, so a widget bound to a mistyped key sees a
  /// fault rather than an eternity of "not yet known".
  DynamicValue _refuse(RefusedRoute route) {
    // **`unmapped` is NOT a configuration error, and the other four are.**
    // `value_store.dart:35-39` draws the line: `errorConfig` is the one
    // non-transient code, and labelling a transient state with it "would tell
    // the operator to go fix a page that is fine, and would teach them that
    // the one non-transient error code heals on its own". A gateway's
    // keymapping is live-editable — `KeyRouter.applyKeyMappings` re-points
    // keys without a restart — so "nothing here knows this name" is a state
    // that genuinely heals, and the enum already says so in as many words
    // (`RouteRefusal.aliasDisabled` is "deliberately distinguishable from
    // unmapped"). A reserved prefix, an unsubstituted `$var`, a switched-off
    // alias and an ambiguous alias are all somebody-go-fix-the-config; those
    // keep `errorConfig`.
    //
    // And `unmapped` splits again, on whether the KEYMAPPING knows the name:
    // a key the file carries that no link claimed is a mapping pointing at a
    // server that is not there, which is somebody-go-fix-the-config; a key the
    // file has never heard of is the transient one. Without that second split
    // a tag deleted upstream — which the adapters model by ceasing to resolve
    // it — would downgrade from "go fix the page" to "wait a moment".
    final value =
        route.reason == RouteRefusal.unmapped && !router.keys.contains(route.key)
            ? notYetKnown
            : DynamicValue(value: null, quality: Quality.errorConfig);
    // Through _degrade and not applyUpstreamBatch: nothing arrived. A refusal
    // that reset the freshness clock would be a key that is never stale and
    // never true either.
    _degrade(<String, DynamicValue>{route.key: value});
    return value;
  }

  /// A link that could not be opened at [start].
  ///
  /// Nothing to publish yet — 08-09 owns `PIPE.upstream.<alias>.state` and
  /// `.last_error`, and inventing a second place to record this would be the
  /// second spelling `PipeKeys` exists to prevent. The redaction is applied
  /// here rather than there because the string must never exist unredacted
  /// outside the link (T-08-08).
  void _noteLinkStartFailure(UpstreamLink link, Object error) {
    final redacted = redactUpstreamError(error.toString()) ?? '';
    _startFailures[link.alias] = redacted;
    // Already redacted, and handed on redacted. The producer does not redact a
    // second time on purpose — one redactor, applied at the boundary the string
    // crossed, is the property worth keeping (T-08-33).
    _health.noteError(link.alias, redacted);
  }

  /// Links whose [start] connect did not succeed, by alias, redacted.
  ///
  /// Observable so a case can assert the gateway came up anyway; 08-09 turns
  /// this into `PIPE.upstream.<alias>.last_error`.
  Map<String, String> get startFailures =>
      Map<String, String>.unmodifiable(_startFailures);
  final Map<String, String> _startFailures = <String, String>{};

  /// How many repeating clocks this instance is running right now.
  ///
  /// **Zero until somebody is watching**, and that is the property rather than
  /// an implementation detail: an always-on `Timer.periodic` leaks past every
  /// widget test that builds a source without draining it, and an unobserved
  /// gateway has nobody to tell. 08-05 task 3 wires the freshness sweep behind
  /// this number.
  int get liveTimers => _sweep.running ? 1 : 0;

  /// The sweep's cadence: a quarter of [staleAfter], floored.
  Duration get sweepInterval => _sweep.interval;

  /// How many freshness passes have been made. A diagnostic, and the observable
  /// that tells a case the listener gate actually opened.
  int get freshnessSweeps => _sweep.sweeps;

  // ------------------------------------------------------- fan-in observation

  /// Clients watching [key] right now, through `listen` or `subscribe`.
  int listenerCount(String key) => _fanIn.listenerCount(key);

  /// Keys holding a live upstream subscription — the SRV-07 release assertion.
  int get openUpstreamSubscriptions => _fanIn.openUpstreamSubscriptions;

  /// Linger timers armed right now. Zero at the default [linger].
  int get liveLingerTimers => _fanIn.liveLingerTimers;

  // ---------------------------------------------------------- fan-in callbacks

  void _onUpstreamValue(String key, DynamicValue value) =>
      applyUpstreamBatch(<String, DynamicValue>{key: value});

  /// The upstream stream for [key] ended.
  ///
  /// **The node is not closed and the value is not forgotten.** The key is
  /// marked [Quality.badCommFault] and keeps its number: staleness and link
  /// loss are statements about whether the reading can be trusted, not claims
  /// that it never existed. The band guard is what stops this overwriting a
  /// key that is already worse news — `errorConfig` means the tag is gone and
  /// waiting will not fix it, and repainting that as a comm fault tells the
  /// operator to wait for something never coming back.
  void _onUpstreamEnded(String key) {
    final cached = _store.peek(key);
    if (cached == null) {
      _degrade(<String, DynamicValue>{
        key: DynamicValue(value: null, quality: Quality.badCommFault),
      });
      return;
    }
    if (Quality.badCommFault.band <= cached.quality.band) return;
    _degrade(<String, DynamicValue>{
      key: cached.copyWith(quality: Quality.badCommFault),
    });
  }

  /// An error on one key's upstream stream costs that key and nothing else.
  void _onUpstreamError(String key, Object error) {
    final redacted = redactUpstreamError(error.toString()) ?? '';
    _upstreamErrors[key] = redacted;
    // Attributed to the link as well as to the key: one tag's stream failing is
    // usually the first thing anybody notices about a PLC, and an operator
    // looking at a link indicator should not have to guess which of four
    // hundred keys carries the reason.
    final alias = aliasOfKey(key);
    if (alias != null) _health.noteError(alias, redacted);
    _onUpstreamEnded(key);
  }

  /// The last upstream error per key, already redacted (T-08-08).
  Map<String, String> get upstreamErrors =>
      Map<String, String>.unmodifiable(_upstreamErrors);
  final Map<String, String> _upstreamErrors = <String, String>{};

  // ------------------------------------------- SRV-08: degrade, then announce

  /// One subscription per configured link, opened by [start].
  final List<StreamSubscription<UpstreamLinkState>> _linkStates =
      <StreamSubscription<UpstreamLinkState>>[];

  /// The same, for identity changes. Separate because the two facts are
  /// separate: `birth_count` answers "how often has this link come back" and
  /// the epoch answers "is it still the same server", and a reprogram moves
  /// exactly one of them.
  final List<StreamSubscription<String>> _linkEpochs =
      <StreamSubscription<String>>[];

  /// Link-state announcements, **one per link event and never one per key**.
  ///
  /// 08-12 wires this to the session's `status` notification path. It carries
  /// [StatusParams] **objects** and not maps, which is 03-REVIEW WR-06 not
  /// repeated: this channel once sent a hand-built map, a conforming client
  /// routed it through `StatusParams.fromJson`, and `json['alias'] as String`
  /// threw on null — on the notification path, where nothing catches.
  Stream<StatusParams> get statusStream => _status.stream;
  final StreamController<StatusParams> _status =
      StreamController<StatusParams>.broadcast();

  /// How many link-state announcements this source has made.
  ///
  /// The observable `checkUpstreamLossAnnouncesOnce` is written against, and
  /// the number the per-key-announcement sabotage moves to twenty.
  int get statusNotifications => _statusNotifications;
  int _statusNotifications = 0;

  /// One link changed state. **Degrade, then announce.**
  ///
  /// The order is the property, not the implementation. A panel that learns the
  /// link is down and *then* reads a key which has not yet degraded sees a good
  /// value under a dead link — precisely the stale-but-plausible failure
  /// PROJECT.md names as the reason this project exists. So every value that
  /// must change has changed before anything is told that anything changed.
  ///
  /// The health keys sit between the two for the same reason: they are how a
  /// panel *learns*, so they must not be ahead of the values they describe.
  ///
  /// **[state] is the event, and the event is what this handles** (08-REVIEW
  /// WR-06). It used to be dropped and `link.state` re-read, which for the OPC
  /// UA adapter is recomputed from `wrapper.effectiveStatus` at the moment the
  /// handler runs. Broadcast delivery is asynchronous, so two transitions
  /// raised in one synchronous run — a `disconnected` immediately followed by
  /// a `connected`, which is what a flap looks like — were both handled as
  /// `connected`: [applyLinkLoss] never ran, so nothing was stamped
  /// `badCommFault`, and [applyLinkRestored] then found nothing degraded to
  /// relabel. Every key kept `Quality.good` across a link that had gone away
  /// and come back, vouched for by nothing.
  ///
  /// The OPC UA link's values were half-covered by its own `_degradeAll`,
  /// which runs synchronously inside `_onEffectiveStatus`; the Modbus, M2400
  /// and fake links had no second path at all.
  void _onLinkState(UpstreamLink link, UpstreamLinkState state) {
    switch (state) {
      case UpstreamLinkState.connected:
        applyLinkRestored(link.alias);
      case UpstreamLinkState.disconnected:
      case UpstreamLinkState.unhealthy:
      case UpstreamLinkState.reprogrammed:
        applyLinkLoss(link.alias);
      case UpstreamLinkState.connecting:
        // Deliberately no value change. "A reconnect is in progress" is news
        // about the link and not evidence about any number: the values are
        // already carrying whatever verdict the loss that preceded it left
        // them, and re-degrading them would restamp nothing and notify
        // everybody.
        break;
    }
    _health.onLinkEvent(link);
    _publishPlantConnected();
    announceLinkState(link, state);
  }

  /// `PIPE.connected` — the plant side is up, as one bit.
  ///
  /// True when **every** configured link is connected, false when any of them
  /// is not. The conjunction and not a disjunction: this is the indicator an
  /// operator glances at before trusting the rest of the screen, and a gateway
  /// that reported "connected" while one of its four PLCs was dark would make
  /// the glance worse than useless.
  ///
  /// **There is one producer and one bit** (08-REVIEW IN-01). This comment
  /// used to say the session overlay owned "the socket half" of
  /// `PipeKeys.connected`; it does not, and never did —
  /// `SessionHealthStateMan.ownKeys` lists six keys and this is not among
  /// them, and the §8 amendment in `relay-comm-design.md` now states
  /// positively that the overlay deliberately does not claim it. 08-CONTEXT
  /// ruling 9 splits per-client facts from per-plant ones, and this is a
  /// per-plant one; it lives here because this is the object that knows what
  /// a link's state is.
  ///
  /// Written through [_degrade] and not [applyUpstreamBatch]: a health key is
  /// outside freshness accounting (HLTH-02), and stamping an arrival on it
  /// would put the gateway's own bookkeeping into the clock that decides
  /// whether plant values are current.
  void _publishPlantConnected() {
    final up = links.isNotEmpty &&
        links.every((link) => link.state == UpstreamLinkState.connected);
    final cached = _store.peek(PipeKeys.connected);
    if (cached != null && cached.value == up && cached.quality.isGood) return;
    _degrade(<String, DynamicValue>{
      PipeKeys.connected: DynamicValue(value: up, quality: Quality.good),
    });
  }

  /// Degrades every key [alias] serves, in **one** [ValueStore.applyBatch].
  ///
  /// One batch, not one per key: the store's promise is that a batch costs one
  /// pass and k notifications, and a link loss is the largest batch this source
  /// will ever apply — at this plant, fifteen hundred keys.
  ///
  /// Three rules, and each of them is a way of getting SRV-08 wrong:
  ///
  ///  * **Filtered by alias.** Without it, losing one PLC greys out the other
  ///    three, and a mimic with half its boxes greyed reads as a plant fault
  ///    the plant does not have.
  ///  * **Health keys are skipped**, by prefix (HLTH-02). A light that goes out
  ///    when the thing it monitors fails is not an indicator, and
  ///    `PIPE.upstream.$alias.state` has to stay readable *while* its link is
  ///    down — that is the moment it exists for.
  ///  * **The band guard stages nothing for a key already worse.**
  ///    `errorConfig` means the tag is gone and waiting will not fix it;
  ///    `badCommFault` means the link is down and waiting might. Repainting the
  ///    first as the second tells an operator to wait for something that is
  ///    never coming back — and it wakes every listener on that key to do it.
  ///
  /// It **does not announce**. Kept separate for `fake_state_man.dart:598-605`'s
  /// stated reason: so a variant can fan the announcement out per key without
  /// touching the degradation, which is the sabotage that proves the
  /// announce-once arm bites.
  ///  * **A key with no value yet is degraded too, not skipped** (08-REVIEW
  ///    WR-13). A tag that has been subscribed but has never produced a sample
  ///    has a node and no reading, and skipping it left its subscriber sitting
  ///    at `uncertainNotYetKnown` — which means "waiting does fix it" — for a
  ///    link that is down. That is the wrong instruction, and the window is
  ///    unbounded on a tag whose PLC never came up in the first place, which
  ///    is precisely when somebody is staring at it. `_onUpstreamEnded`
  ///    already stages a null-valued `badCommFault` for the stream-ended case,
  ///    so the shape was established; this path just did not use it.
  void applyLinkLoss(String alias) {
    final batch = <String, DynamicValue>{};
    for (final key in _store.keys) {
      if (PipeKeys.isPipeKey(key)) continue;
      if (aliasOfKey(key) != alias) continue;
      final cached = _store.peek(key);
      if (cached == null) {
        // Never a zero and never a false — a null payload under the fault, so
        // the page renders "the link is down" and not a reading.
        batch[key] =
            DynamicValue(value: null, quality: Quality.badCommFault);
        continue;
      }
      if (Quality.badCommFault.band <= cached.quality.band) continue;
      batch[key] = cached.copyWith(quality: Quality.badCommFault);
    }
    _degrade(batch);
  }

  /// The snapshot after [alias] comes back: link-degraded keys read
  /// [Quality.uncertainLastKnown], **not** good.
  ///
  /// The link being back is not evidence about the number. Each value becomes
  /// good again only when it has been re-read, and a snapshot that came back
  /// good would make a reconnection a way of laundering an hour-old reading
  /// into a current one — the same lie as a stale value with better manners.
  ///
  /// Recovery is a snapshot and never a delta replay: every key that has a
  /// value comes back at once rather than waiting until it next happens to
  /// change, or a slow-moving tank level stays greyed for an hour after the
  /// link healed.
  void applyLinkRestored(String alias) {
    final batch = <String, DynamicValue>{};
    for (final key in _store.keys) {
      if (PipeKeys.isPipeKey(key)) continue;
      if (aliasOfKey(key) != alias) continue;
      final cached = _store.peek(key);
      if (cached == null) continue;
      if (!_isLinkDegraded(cached.quality)) continue;
      // A key WR-13 degraded without ever having had a reading comes back
      // "not yet known" rather than "last known": there is no last known, and
      // naming one would point a page at a value that does not exist. Waiting
      // genuinely does fix this one now that the link is back.
      batch[key] = cached.copyWith(
          quality: cached.value == null
              ? Quality.uncertainNotYetKnown
              : Quality.uncertainLastKnown);
    }
    _degrade(batch);
  }

  /// Announces [link]'s current state — **once**, however many keys it cost.
  ///
  /// Sparkplug sends one NDEATH for a whole node for the same reason: at
  /// fifteen hundred keys, one event per key is fifteen hundred events for one
  /// event, arriving in the instant the client is already re-rendering every
  /// box on the page they are all about. That is a denial of service against
  /// the operator's own screen, delivered by their own gateway at the worst
  /// possible moment.
  ///
  /// The error is [UpstreamLink.lastError], which is contracted to be redacted
  /// **at the link**. It is deliberately not redacted a second time here: one
  /// redactor used by every adapter is the property worth keeping, and a
  /// belt-and-braces pass at this call site would hide an adapter that forgot.
  ///
  /// **[state] is the transition being announced**, not whatever the link
  /// happens to report when this runs (08-REVIEW WR-06). Re-reading the link
  /// here meant two transitions raised in one turn produced two frames saying
  /// the same thing — so a client could receive two `connected`s and never the
  /// `disconnected` between them, which is a flap it has no way to know about.
  /// Defaulted to the link's current state for the callers that genuinely mean
  /// "say where this link is now", which is what [start]'s seed does.
  void announceLinkState(UpstreamLink link, [UpstreamLinkState? state]) {
    _statusNotifications++;
    if (_status.isClosed) return;
    _status.add(StatusParams(
      alias: link.alias,
      state: (state ?? link.state).wireName,
      error: link.lastError,
    ));
  }

  /// Which link serves [key], or null for a health key, a refusal, or a name
  /// no configured link claimed.
  ///
  /// **Cached, and invalidated on a keymapping reload.** A mass degradation
  /// routes every key in the store, and routing is not free — the OPC UA
  /// adapter builds a `NodeId` on every `resolve`. But the cache cannot be
  /// permanent either: a reload re-points keys at different servers, and a
  /// stale attribution would degrade the wrong PLC's keys, which is the
  /// isolation failure this method exists to prevent wearing a disguise.
  /// `KeyRouter.applyKeyMappings` mints a fresh `KeyMappingsIngestResult` on
  /// every call, so its identity is the reload signal with nothing to keep in
  /// step.
  String? aliasOfKey(String key) {
    final ingest = router.lastIngest;
    if (!identical(ingest, _aliasCacheGeneration)) {
      _aliasCache.clear();
      _aliasCacheGeneration = ingest;
    }
    if (_aliasCache.containsKey(key)) return _aliasCache[key];
    final route = router.route(key);
    final alias = route is ClaimedRoute ? route.link.alias : null;
    _aliasCache[key] = alias;
    return alias;
  }

  final Map<String, String?> _aliasCache = <String, String?>{};
  Object? _aliasCacheGeneration;
}

/// A counting view of one store node.
///
/// Delegates every member to the node — so `value` is the node's value and a
/// registered listener is registered *on the node*, which is where
/// `listenerCount` reads from and where a teardown assertion looks. What it
/// adds is the two transitions the node has no hook for
/// (`value_store.dart:66`): first listener in, last listener out.
final class _WatchedKey implements ValueListenable<DynamicValue> {
  _WatchedKey({
    required this.node,
    required void Function() attach,
    required void Function() detach,
  })  : _attach = attach,
        _detach = detach;

  final ValueStoreNode node;
  final void Function() _attach;
  final void Function() _detach;

  int _count = 0;

  @override
  DynamicValue get value => node.value;

  @override
  void addListener(VoidCallback listener) {
    node.addListener(listener);
    _count++;
    if (_count == 1) _attach();
  }

  @override
  void removeListener(VoidCallback listener) {
    // Measured rather than assumed: removing a listener that was never added
    // is a documented no-op on the node, and a refcount that decremented on
    // one would release an upstream subscription somebody is still watching.
    final before = node.listenerCount;
    node.removeListener(listener);
    if (node.listenerCount == before) return;
    if (_count == 0) return;
    _count--;
    if (_count == 0) _detach();
  }
}

/// One settled write outcome plus the instant this gateway settled it.
///
/// The settle instant is what the TTL prunes on; the command's own mint time
/// (decoded out of the ULID) is what the evidence rule reasons about. They are
/// different facts and conflating them would let a command minted on a panel
/// with a fast clock buy itself a longer window.
typedef _LoggedOutcome = ({WriteResult result, int at});

/// One key's answer plus whether it came from the wire, so [LocalStateMan.readMany]
/// can apply exactly the ones that did as a single batch.
typedef _ReadAnswer = ({String key, DynamicValue value, bool fromUpstream});
