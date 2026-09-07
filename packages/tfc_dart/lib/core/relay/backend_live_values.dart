/// The backend's live read surface: the pipe's cache, refcounted, with the
/// health keys served like any plant tag.
///
/// This is `BackendValueSource` (`backend_seams.dart`) implemented over
/// [PipeMainEndpoint]. It is the honest cost named in the milestone findings
/// §8: **main serves reads from a cache rather than from a link.** Nothing on
/// this file's read path reaches through the isolate boundary, because a read
/// that could be parked by a blackholed PLC is the multi-second stall Phase 12
/// exists to have removed. The only thing that ever crosses is a
/// [PipeResnapshot] — one batched control message, on a deadline, that resolves
/// whether or not anybody answers.
///
/// ## Four properties, and each one is a decision
///
///  1. **A key nobody watches costs no monitored item.** `listen(key)` hands
///     back a handle immediately for any key at all, and the *listener* — not
///     the handle — is what subscribes. The refcount lives on the handle's
///     0→1 and 1→0 listener transitions, the same release-at-zero shape
///     `fanin.dart` uses in the gateway and for the reason its comment gives
///     at length: the release is then a line of code with a name, and it
///     happens when the last watcher goes rather than ten minutes later while
///     the PLC keeps paying.
///  2. **A synchronous read is null until the plant has been heard from.** The
///     pipe's own `read` never returns null — an un-arrived key is
///     `uncertainNotYetKnown`, which is a real [relay.DynamicValue] — and
///     passing that straight through would tell a widget a reading exists when
///     none does. See [read] for why the test is derived from the store rather
///     than kept in a set.
///  3. **`PIPE.*` is not an API.** *"There is no health method."* The health
///     keys go through the same store, the same qualities and the same handles
///     as a temperature (`pipe_keys.dart`), and [PipeKeys.connected] is seeded
///     **true** at construction because a health indicator that reads
///     "unknown" until the first fault tells an operator nothing at the moment
///     they most need telling.
///  4. **Phase 12's IN-02 is discharged here.** A key the upstream retires
///     leaves the worker's own `_subscribed` set populated — "main is the only
///     thing that retracts it" — and `_disarmTickIfIdle` only runs on an
///     unsubscribe, so a worker whose last subscribed key was retired keeps
///     its 50 ms drain timer running for the life of the process. This class
///     is the consumer that owed the retraction: [PipeMainEndpoint.onKeyRetired]
///     drives [PipeMainEndpoint.unsubscribe] and the `PipeUnsubscribe` crosses.
///
/// ## What this file deliberately does NOT do
///
/// **It starts no timer.** Freshness is plan 13-07's, and a `Timer.periodic` in
/// this plumbing has broken unrelated suites before (the project's
/// listener-gating rule). [staleAfter] is a declared number that 13-07's sweep
/// reads; the sweep itself lives there.
///
/// **It does not call `pipe.shutdown()` on [dispose].** The pipe outlives the
/// adapter — killing the plant's acquisition isolates because one relay client
/// went away is not this class's decision.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`:
/// two classes in this solve are called `DynamicValue`, and the prefix is what
/// keeps them apart.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// How long a value may go unrefreshed before it stops being trustworthy.
///
/// **Ten seconds, and the number is chosen from above rather than from below.**
/// The floor is irrelevant: the pipe drains every 50 ms, so a key that is
/// genuinely moving refreshes two hundred times inside any single second, and
/// almost any deadline would do. What has to fit is the *slowest legitimate*
/// gap — an OPC UA subscription's publishing interval, plus the worker's
/// monitor ladder, plus the drain tick — and the measured number for that is
/// D-12-08-a: roughly **nine seconds** between a key being blackholed and
/// `badCommFault` actually arriving for it.
///
/// A deadline inside that window would badge a whole PLC stale for one sweep
/// and then un-badge it the moment the real fault landed, which teaches
/// operators that grey means nothing — the single thing they must never learn.
/// Ten seconds sits just outside it, so the freshness sweep never beats the
/// link's own announcement to the screen.
///
/// It is deliberately not smaller "to be safe". D-12-08-a is closed by Phase
/// 16's HARD-01 (freshness anchored per link), and 13-CONTEXT says in as many
/// words not to paper over that window here with an arbitrary timeout.
const Duration kBackendStaleAfter = Duration(seconds: 10);

/// `BackendValueSource` over [PipeMainEndpoint]'s cache. See the library doc.
final class BackendLiveValues implements BackendValueSource {
  /// Composes the live half over an already-built pipe.
  ///
  /// [keyMappings] is what the backend already loaded to decide which worker
  /// got spawned with which keys, so [keys] cannot disagree with the router.
  BackendLiveValues({
    required PipeMainEndpoint pipe,
    required KeyMappings keyMappings,
    this.staleAfter = kBackendStaleAfter,
    Logger? logger,
  })  : _pipe = pipe,
        _keyMappings = keyMappings,
        _logger = logger ?? Logger() {
    _seedHealth();
    // IN-02. Registered in the constructor rather than by the composition root
    // so that the obligation cannot be forgotten at a call site: an adapter
    // that exists is an adapter that retracts.
    pipe.onKeyRetired = _onRetired;
  }

  final PipeMainEndpoint _pipe;
  final KeyMappings _keyMappings;
  final Logger _logger;

  @override
  final Duration staleAfter;

  /// The `PIPE.` names this adapter can actually answer for.
  ///
  /// **Exactly one, on purpose.** `PipeKeys.declared` lists eighteen, but every
  /// other name on it has a producer somewhere else: the client mints group 1,
  /// the gateway session overlay mints group 2, `LocalStateMan` mints groups 3
  /// and 5, the certificate overlay mints group 4. Seeding a key this adapter
  /// cannot move would put a permanently `errorConfig` box on a page with
  /// nothing behind it — the "key nothing will ever route" that `pipe_keys.dart`
  /// exists to prevent — and [keys] would then offer it to the picker as
  /// something to bind.
  ///
  /// Spelled through the constant, never as a quoted prefixed string: such a
  /// literal anywhere in any `lib/` is exactly the drift `pipe_keys.dart` is a
  /// whole file about, and it is enforced by grep rather than by a type.
  static const List<String> healthKeys = <String>[relay.PipeKeys.connected];

  /// The `ALARM.` names this adapter **declares but does not produce**.
  ///
  /// **A separate list from [healthKeys], and the separation is the point.**
  /// [healthKeys] exists because this class IS the producer of
  /// `PIPE.connected` — it seeds it true at construction, flips it on link
  /// loss and back on recovery. This class is **not** the producer of
  /// `ALARM.active`: the alarm engine is, and it publishes into the same
  /// [PipeMainEndpoint.store] the way [_seedHealth] does. All this list does is
  /// make the key *declared*, so the relay server answers a subscription for it
  /// instead of `unknownKey` — the failure the rig measured for
  /// `PIPE.upstream.*` (FIND-3), where the producer existed, the value existed,
  /// and every panel that asked was refused.
  ///
  /// Two different reasons must not share one list. Folded into [healthKeys],
  /// the next reader to add a seed beside `PIPE.connected` would seed this too
  /// — and a seeded empty active set is the claim that no alarm is active,
  /// made by an object that has never evaluated a rule. Until the engine has
  /// run, "not heard from yet" is the honest reading, and an unseeded key
  /// already says exactly that.
  ///
  /// Spelled through the constant, never as a quoted prefixed string:
  /// `alarm_keys.dart` is a whole file about that drift, and the enforcement is
  /// a grep rather than a type.
  static const List<String> alarmKeys = <String>[relay.AlarmKeys.active];

  /// One handle per key, so two callers watching one tag share one upstream
  /// registration.
  final Map<String, _WatchedKey> _watched = <String, _WatchedKey>{};

  /// How many refcounts this adapter is holding on the pipe, per key.
  ///
  /// Its own bookkeeping, separate from `PipeMainEndpoint._refcount`, because
  /// [dispose] and [_onRetired] both have to release **exactly what this object
  /// took** and nothing another consumer of the same pipe is holding.
  final Map<String, int> _held = <String, int>{};

  /// Keys the upstream has retired. A subscription for one of these is never
  /// re-created: the tag is gone, and re-creating it puts the drain timer back
  /// where IN-02 found it.
  final Set<String> _retired = <String>{};

  /// The broadcast controllers [subscribe] handed out, closed on [dispose].
  final List<StreamController<relay.DynamicValue>> _streams =
      <StreamController<relay.DynamicValue>>[];

  /// The same, for [subscribeStamped]. A separate list because the element
  /// types differ; closed alongside [_streams] on [dispose].
  final List<StreamController<StampedValue>> _stampedStreams =
      <StreamController<StampedValue>>[];

  int _statusNotifications = 0;
  bool _disposed = false;

  // ------------------------------------------------------------- the handles

  /// A handle for [key] whose value changes in place — for **any** key.
  ///
  /// Never throws and never refuses. One mistyped tag in a page config must
  /// take out that one box on the mimic, not the mimic.
  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) => _watch(key);

  /// The same store as a stream, for stream-consuming callers.
  ///
  /// Broadcast, because two widgets watching one key is the normal case and the
  /// second one must not be refused. The upstream registration is driven by the
  /// stream's own listeners through the shared [_WatchedKey], so a `subscribe`
  /// nobody listens to costs nothing either.
  @override
  Stream<relay.DynamicValue> subscribe(String key) {
    final watched = _watch(key);
    late final StreamController<relay.DynamicValue> controller;
    void forward() {
      if (!controller.isClosed) controller.add(watched.value);
    }

    controller = StreamController<relay.DynamicValue>.broadcast(
      onListen: () => watched.addListener(forward),
      onCancel: () => watched.removeListener(forward),
    );
    _streams.add(controller);
    return controller.stream;
  }

  /// The same stream, each emission carrying the provenance of its instant.
  ///
  /// **`forward` runs inside the store's synchronous notification**, which is
  /// what makes the pair exact: `PipeMainEndpoint._applyFrame` records the
  /// frame's provenance claims BEFORE `store.applyBatch`, so by the time this
  /// listener fires, `stampSourceOf` is answering about the very value being
  /// forwarded. Reading it later — in the alarm engine, off a `CombineLatest`
  /// emission — would answer about whatever value is current then, which is not
  /// necessarily this one.
  @override
  Stream<StampedValue> subscribeStamped(String key) {
    final watched = _watch(key);
    late final StreamController<StampedValue> controller;
    void forward() {
      if (controller.isClosed) return;
      controller.add(StampedValue(watched.value, _pipe.stampSourceOf(key)));
    }

    controller = StreamController<StampedValue>.broadcast(
      onListen: () => watched.addListener(forward),
      onCancel: () => watched.removeListener(forward),
    );
    _stampedStreams.add(controller);
    return controller.stream;
  }

  _WatchedKey _watch(String key) =>
      _watched.putIfAbsent(key, () => _WatchedKey(this, key, _pipe.listen(key)));

  // ---------------------------------------------------------------- the reads

  /// The last known value for [key], or **null** when none is known yet.
  ///
  /// **Derived from the store rather than kept in a set**, and the two are the
  /// same predicate: the pipe's `ValueStore.peek` is null until a value has
  /// genuinely arrived, and an arrived value carries its own quality. A
  /// `Set<String> _heard` maintained by hand would need a listener on every
  /// node — including the keys nobody is watching, which is the cost this whole
  /// class is arranged to avoid — and would then be a second copy of a fact the
  /// store already holds, free to drift from it.
  ///
  /// The test is exactly the one the contract's own `arrived()` barrier makes
  /// (`harness.dart:_heard`), which is not a coincidence and not optional: a
  /// source that declares its page snapshots every key on it as
  /// `uncertainNotYetKnown`, so `read(key) != null` would be true from the
  /// instant the page opened and would answer "there is a reading" for every
  /// unbound box.
  @override
  relay.DynamicValue? read(String key) {
    final cached = _pipe.store.peek(key);
    if (cached == null) return null;
    if (cached.quality == relay.Quality.uncertainNotYetKnown) return null;
    return cached;
  }

  /// A value for [key] that is fresh as of the call. Exactly one round trip.
  ///
  /// The one method whose job is to bypass the cache — a readback check after a
  /// write, a diagnostics page proving a value is real. It still answers *from*
  /// the cache; what makes it fresh is that the owning worker was asked to
  /// re-deliver first. If the worker says nothing, [PipeMainEndpoint.resnapshot]
  /// gives up at its deadline and this returns whatever is there, which is
  /// honest — the alternative is a read that hangs on a blackholed PLC.
  @override
  Future<relay.DynamicValue> readFresh(String key) async {
    await _pipe.resnapshot(<String>[key]);
    return _pipe.read(key);
  }

  /// One resolution for many keys, so a diagnostics page is one wait.
  ///
  /// **Answers for every key asked of it**, including the ones nothing is known
  /// about: those come back as a [relay.DynamicValue] carrying
  /// `uncertainNotYetKnown`, never as an absent map entry. A missing entry is
  /// indistinguishable from a key that was never asked for, and the caller then
  /// writes a blank cell where it needed to write a fault.
  ///
  /// **Deliberately unbounded here, and that is not an oversight.** The breadth
  /// hazard is real — an unbounded key list on one call is a memory and CPU
  /// amplification — but it is a *trust-boundary* hazard, and the trust boundary
  /// is the relay's own RPC edge, not this method. `value_handlers.dart:283-302`
  /// already refuses a `readMany` carrying more than `maxKeysPerSubscribe`
  /// (2000 by default) with a named error, before the request ever reaches an
  /// adapter. Adding a second limit here would give the plant two numbers that
  /// can disagree, and the failure mode of disagreement is a diagnostics page
  /// that the server accepts and the adapter silently truncates. In-process
  /// callers (`bin/main.dart`, 13-09's composition) are inside the same trust
  /// domain and are bounded by the key mappings they were built from.
  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) async {
    await _pipe.resnapshot(keys);
    return <String, relay.DynamicValue>{
      for (final key in keys) key: _pipe.read(key),
    };
  }

  /// Every key this source can serve: the key mappings, plus [healthKeys],
  /// plus [alarmKeys].
  ///
  /// Nothing else. Omitting a served key hides a tag that is visibly on screen;
  /// listing an unserved one sends whoever draws the next page to bind a tag
  /// that will never produce a value.
  ///
  /// **A set, so a name appears once however many reasons it has to be here.**
  /// Nothing stops an operator naming a plant tag `ALARM.active` — the backend
  /// has no ingest refusal for the reserved prefixes yet (T-14-08; the refusal
  /// lands with the engine, which is the object that holds both the mapping and
  /// the namespace). Concatenated, that operator's file would put the same
  /// string on this list twice, and a duplicate reaches the browse surface as
  /// two identical entries nobody can tell apart and the subscribe accounting
  /// as two registrations for one monitored item. A set literal keeps insertion
  /// order, so the mappings still come first.
  @override
  List<String> get keys => <String>{
        ..._keyMappings.keys,
        ...healthKeys,
        ...alarmKeys,
      }.toList(growable: false);

  /// How many round trips this source has made upstream.
  ///
  /// Literally the pipe's [PipeMainEndpoint.resnapshots] — there is no other
  /// way for this class to reach a worker, which is what makes the counter a
  /// fact rather than an accounting convention.
  @override
  int get roundTrips => _pipe.resnapshots;

  @override
  int get statusNotifications => _statusNotifications;

  // ------------------------------------------------------- the health keys

  /// Seeds [healthKeys] before anything can subscribe.
  ///
  /// **Served from the pipe's own [PipeMainEndpoint.store], not from a second
  /// store of this class's own.** A second store would need a router in
  /// [listen], [read], [readMany] and [dispose], and every one of those routers
  /// is a place the two can disagree about a key — for instance about whether a
  /// `PIPE.` name has a node yet. Sharing the store means a health key IS a
  /// `ValueStoreNode`, with the same handle identity, the same equality guard
  /// and the same k-of-n notification arithmetic as a temperature, which is
  /// exactly the claim HLTH-01 makes. Nothing else in the process writes the
  /// `PIPE.` namespace into that store — no worker owns a reserved key, so no
  /// frame can carry one.
  void _seedHealth() {
    _pipe.store.applyBatch(<String, relay.DynamicValue>{
      // True, not unknown. `pipe_health.dart` quotes the argument: "a health
      // indicator that reads unknown until the first fault tells an operator
      // nothing at the moment they most need telling."
      relay.PipeKeys.connected: relay.DynamicValue(value: true),
    });
  }

  /// The upstream link is gone. Announced **once**, degrading every key this
  /// source has actually heard about.
  ///
  /// One `applyBatch`, never one call per key: at 1500 keys on a page a per-key
  /// fan-out is 1500 events for one event, delivered in the instant the client
  /// is trying to redraw. Sparkplug sends one NDEATH for a whole node for the
  /// same reason.
  ///
  /// A key nothing has ever been heard about is left alone. It has never been
  /// known, so `notYetKnown` remains the honest answer for it and badging it
  /// `badCommFault` would claim a link fault about a tag that may not exist.
  @override
  void announceLinkLoss(String reason) {
    _statusNotifications++;
    _logger.w('backend values: the upstream link is gone — $reason');
    final batch = <String, relay.DynamicValue>{
      relay.PipeKeys.connected: relay.DynamicValue(value: false),
    };
    for (final key in _keyMappings.keys) {
      final cached = _pipe.store.peek(key);
      if (cached == null) continue;
      if (cached.quality == relay.Quality.badCommFault) continue;
      batch[key] = cached.copyWith(quality: relay.Quality.badCommFault);
    }
    _pipe.store.applyBatch(batch);
  }

  /// The upstream link is serving again. Announced once, and resynced with a
  /// **snapshot**.
  ///
  /// Never a delta replay: a key that has a value comes back at its real
  /// quality rather than staying degraded until it next happens to change. The
  /// snapshot is exactly one [PipeResnapshot] per owning worker, so the resync
  /// costs what a resync costs and nothing more.
  @override
  void announceLinkUp() {
    _statusNotifications++;
    _pipe.store.applyBatch(<String, relay.DynamicValue>{
      relay.PipeKeys.connected: relay.DynamicValue(value: true),
    });
    final watching = _held.keys.toList(growable: false);
    if (watching.isEmpty) return;
    // Fire-and-forget WITH a handler: a bare future here would become an
    // unhandled asynchronous error, and there is nothing for a caller of a
    // void method to await.
    unawaited(_pipe.resnapshot(watching).catchError((Object error) {
      _logger.e('backend values: the recovery resnapshot failed: $error');
    }));
  }

  // ------------------------------------------- the 13-07 / 13-08 mutations

  /// Badges [keys] as no longer fresh, keeping the number underneath.
  ///
  /// **`badStale`, not `uncertainLastKnown`, and the difference is the whole
  /// member.** `quality.dart` names these two as the pair that must stay
  /// distinct: `uncertainLastKnown` is "current value unavailable, this is the
  /// last known one — the pipe may be fine", and `badStale` is "out of date
  /// past the requested freshness deadline — do not trust the number". This
  /// method is only ever called by the freshness sweep, which means the
  /// deadline has demonstrably passed, so it is the second sentence and not the
  /// first. The freshness contract judges it as such
  /// (`freshness_contract.dart`: `expect(node.value.quality,
  /// Quality.badStale)`), and it is the band the gateway's own
  /// `FreshnessSweep` has always used.
  ///
  /// The payload survives. Dropping it would be a different and wrong claim —
  /// that there is no reading at all — where "it was 1450 and we have lost
  /// touch" is actionable and "———" is not.
  ///
  /// Three kinds of key are left alone:
  ///
  ///  * **health keys**, by prefix (HLTH-02): they change on events, so they
  ///    are always older than any freshness deadline, and sweeping them would
  ///    make an indicator read stale precisely while nothing is wrong;
  ///  * **alarm keys**, by prefix, for a *different* reason: nothing upstream
  ///    refreshes `ALARM.active` on a cadence, because the alarm engine
  ///    republishes it only when a rule transitions. On a healthy plant that is
  ///    the normal condition, so a swept alarm key means the banner greys out
  ///    whenever the plant is quiet — which teaches operators that a grey
  ///    banner means nothing, at the moment they most need it to mean
  ///    something (P-6);
  ///  * **anything already carrying news at or worse than `badStale`'s band.**
  ///    A `badCommFault` key rewritten to `badStale` would swap "the link is
  ///    sick, waiting may fix it" for a weaker and less actionable claim, and
  ///    an `errorConfig` key would have a permanent fault downgraded to a
  ///    transient one. The comparison is on the band rather than on one code,
  ///    so a code invented later is handled on the day it is invented.
  @override
  void markStale(Iterable<String> keys) {
    final batch = <String, relay.DynamicValue>{};
    for (final key in keys) {
      // Additive, never a replacement: `PIPE.` stays excluded. Two prefixes,
      // two reasons, and `alarm_keys.dart` keeps them from overlapping so
      // deleting the wrong half cannot look harmless.
      if (relay.PipeKeys.isPipeKey(key)) continue;
      if (relay.AlarmKeys.isAlarmKey(key)) continue;
      final cached = _pipe.store.peek(key);
      if (cached == null) continue;
      if (relay.Quality.badStale.band <= cached.quality.band) continue;
      batch[key] = cached.copyWith(quality: relay.Quality.badStale);
    }
    if (batch.isEmpty) return;
    _pipe.store.applyBatch(batch);
  }

  /// Badges [key] as having a write in flight, keeping the current reading.
  @override
  void markPending(String key) {
    final cached = _pipe.store.peek(key);
    if (cached == null) return;
    _pipe.store.applyBatch(<String, relay.DynamicValue>{
      key: cached.copyWith(quality: relay.Quality.goodWritePending),
    });
  }

  /// Clears the in-flight badge without asserting an outcome.
  ///
  /// Called when a write resolved `unknown`. The badge must not persist
  /// forever, and clearing it is not the same act as applying a readback — so
  /// the key drops to `uncertainLastKnown` rather than back to `good`. What is
  /// on the screen is the last reading anybody measured, and after an unknown
  /// write that is precisely how much is known.
  @override
  void clearPending(String key) {
    final cached = _pipe.store.peek(key);
    if (cached == null) return;
    if (cached.quality != relay.Quality.goodWritePending) return;
    _pipe.store.applyBatch(<String, relay.DynamicValue>{
      key: cached.copyWith(quality: relay.Quality.uncertainLastKnown),
    });
  }

  /// Records [value] as the confirmed post-write reading of [key].
  @override
  void applyReadback(String key, relay.DynamicValue value) {
    _pipe.store.applyBatch(<String, relay.DynamicValue>{key: value});
  }

  // -------------------------------------------------------- the refcounting

  /// One more watcher on [key]: take a refcount on the pipe if this is the
  /// first.
  void _acquire(String key) {
    if (_disposed) return;
    if (_retired.contains(key)) return;
    _held[key] = (_held[key] ?? 0) + 1;
    _pipe.subscribe(key);
  }

  /// One fewer watcher on [key]: give the refcount back.
  void _release(String key) {
    final count = _held[key] ?? 0;
    if (count == 0) return;
    if (count == 1) {
      _held.remove(key);
    } else {
      _held[key] = count - 1;
    }
    _pipe.unsubscribe(key);
  }

  /// **IN-02, discharged.** The upstream retired [key]: give back every
  /// refcount this adapter holds for it, so the `PipeUnsubscribe` crosses and
  /// the worker's drain timer disarms.
  ///
  /// The handle is deliberately left in place, holding the `errorConfig` value
  /// the pipe has already applied. The tag being gone is a fact the operator
  /// must go on seeing — blanking it would look like an unbound box — and the
  /// key joins [_retired] so a later watcher cannot silently re-create the
  /// subscription that IN-02 is about.
  void _onRetired(String key) {
    _retired.add(key);
    var held = _held.remove(key) ?? 0;
    while (held-- > 0) {
      _pipe.unsubscribe(key);
    }
  }

  // ------------------------------------------------------------ the teardown

  /// Releases every handle and every refcount this adapter holds.
  ///
  /// Idempotent: the contract cases register `dispose` with `addTearDown` and
  /// also call it inside the case, so a second call must be a no-op rather than
  /// a failure that reports the fixture instead of the test.
  ///
  /// **It does not call `pipe.shutdown()`.** The pipe outlives this adapter and
  /// serves the backend's own collection path as well; killing the plant's
  /// acquisition isolates because a relay client went away is not this class's
  /// decision.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Only if it is still ours: the composition root may have re-pointed it,
    // and stealing another consumer's hook on the way out would leave IN-02
    // undischarged for whoever owns the pipe next.
    //
    // `==` and not `identical`: two tear-offs of one instance method on one
    // object are equal but need not be the same object, so `identical` here
    // silently never matches and the hook is never dropped.
    if (_pipe.onKeyRetired == _onRetired) _pipe.onKeyRetired = null;

    for (final watched in _watched.values) {
      watched._teardown();
    }
    _watched.clear();

    for (final entry in _held.entries.toList(growable: false)) {
      var held = entry.value;
      while (held-- > 0) {
        _pipe.unsubscribe(entry.key);
      }
    }
    _held.clear();

    await Future.wait(<Future<void>>[
      for (final controller in _streams)
        if (!controller.isClosed) controller.close(),
      for (final controller in _stampedStreams)
        if (!controller.isClosed) controller.close(),
    ]);
    _streams.clear();
    _stampedStreams.clear();
  }
}

/// One key's handle: a [relay.ValueListenable] that owns its own subscribe and
/// release transitions.
///
/// It wraps the pipe's `ValueStoreNode` rather than being one, because the
/// transition that matters is a transition of **this adapter's** watchers. A
/// listener attached straight to the node would notify perfectly and pay for
/// nothing, and the key would never be piped at all.
final class _WatchedKey implements relay.ValueListenable<relay.DynamicValue> {
  _WatchedKey(this._owner, this._key, this._node);

  final BackendLiveValues _owner;
  final String _key;
  final relay.ValueListenable<relay.DynamicValue> _node;
  final List<relay.VoidCallback> _listeners = <relay.VoidCallback>[];

  bool _attached = false;

  /// The store's value, always. There is no second copy to go stale against it.
  @override
  relay.DynamicValue get value => _node.value;

  @override
  void addListener(relay.VoidCallback listener) {
    _listeners.add(listener);
    if (_listeners.length != 1) return; // 0 -> 1 only
    _attached = true;
    _node.addListener(_onChanged);
    _owner._acquire(_key);
  }

  @override
  void removeListener(relay.VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    if (_listeners.isNotEmpty) return; // 1 -> 0 only
    if (!_attached) return;
    _attached = false;
    _node.removeListener(_onChanged);
    _owner._release(_key);
  }

  /// Iterates a copy: a listener may remove itself while being notified.
  void _onChanged() {
    for (final listener in List<relay.VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// Detaches from the store and forgets every listener. After this the handle
  /// still reads — a widget mid-dispose may still build — but notifies nobody.
  void _teardown() {
    if (_attached) {
      _attached = false;
      _node.removeListener(_onChanged);
    }
    _listeners.clear();
  }
}
