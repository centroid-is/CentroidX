/// The clock that notices silence on main — and only runs while somebody is
/// watching.
///
/// ## Why a clock at all
///
/// Phase 12 gave main honest qualities *from the worker*: a link that faults
/// says so, a tag that is retired says so, an isolate that dies says so. What
/// none of those cover is a value that simply **stops arriving**. A frozen OPC
/// UA session, a PLC that stopped scanning, a weigher that answered its last
/// frame an hour ago — every one of them looks, to an event-driven pipeline,
/// exactly like a tag that has not changed. The page renders the same numbers,
/// in the same colour, at the same refresh rate, as a page watching a running
/// plant, and nobody can see the difference by looking. That is the single
/// failure CLAUDE.md names as the reason this whole project exists, and a
/// declared `staleAfter` with nothing sweeping for it is that failure waiting
/// to happen.
///
/// So this file is the sweep, and it is deliberately a **decorator** over
/// [BackendValueSource] rather than an edit to the one 13-03 wrote. Everything
/// it needs is on the seam `backend_seams.dart` declared for it —
/// [BackendValueSource.markStale], [BackendValueSource.announceLinkLoss],
/// [BackendValueSource.announceLinkUp] — and wrapping is what lets it see the
/// two things the seam cannot express: *which keys somebody is actually
/// watching*, and *when a value last arrived for one of them*.
///
/// ## Freshness ages on a monotonic anchor, never on the RTC
///
/// The doctrine that has caught four defects across v1.0, and the reason
/// [_monotonic] is a process-wide [Stopwatch] rather than a pair of
/// `DateTime` readings. *How long since this value arrived* is an elapsed-time
/// question, and the wall clock **steps**: NTP corrects it, an operator sets
/// it, a suspended VM resumes with a different one, DST moves it twice a year.
/// A backwards correction larger than [staleAfter] made the old subtraction
/// negative for every key in the store at once, so the sweep degraded nothing
/// and the whole plant read fresh from PLCs nobody had heard from (08-REVIEW
/// CR-02, fixed client-side in `6a499d65`); a forward step did the mirror
/// image and greyed every panel at once.
///
/// There is deliberately **no clock seam to hand in**. A seam that accepts a
/// steppable clock is a seam somebody steps, and an injected clock is
/// precisely the machinery that stops testing a watchdog: a source that never
/// runs its sweep passes every fake-clock case and shows a frozen-fresh page
/// in the plant (`harness.dart:80-96`).
///
/// ## Five rules, and each one is a decision
///
///  1. **The sweep may only ever degrade.** If it could raise a quality, an
///     operator would watch a fault clear itself while the fault was still
///     happening — the same lie as a stale value, arrived at from the other
///     direction and harder to catch because it looks like recovery. A key
///     already carrying news at or worse than [relay.Quality.badStale]'s band
///     stages nothing at all, which also means the four-times-per-deadline
///     cadence costs a listening page **zero** rebuilds until something moves.
///  2. **Health keys are skipped by [relay.PipeKeys.isPipeKey]** — a prefix
///     test, never a roster lookup. `PIPE.connected` changes only when the
///     link changes, so on a healthy pipe it is *always* older than any
///     deadline; staling it greys out the one indicator an operator uses to
///     decide whether to believe the rest of the screen, and greys it out
///     exactly when nothing is wrong (HLTH-02). The prefix is what makes a
///     health key invented in a later phase correct on the day it is invented.
///
///     **Alarm keys are skipped too, by [relay.AlarmKeys.isAlarmKey], and for
///     a different reason.** A health key is skipped because it changes on a
///     *cadence this object cannot see* — the link either moves or it does
///     not. `ALARM.active` is skipped because alarm state changes on *events*:
///     the engine republishes the active set when a rule transitions and at no
///     other time, so on a healthy plant the last publish is arbitrarily old
///     and that is exactly what "no alarms" looks like. Silence here is news,
///     not the absence of news, and badging it stale greys out the alarm
///     banner on a plant where nothing is wrong (D-9, P-6). The two conditions
///     are separate lines rather than one because the reasons are separate;
///     `alarm_keys.dart` pins that neither prefix is a prefix of the other, so
///     they can never quietly collapse into one.
///  3. **Only watched keys are aged.** A key nobody watches has no monitored
///     item upstream (13-03's refcount) and no box on any screen, so it cannot
///     be fresh and there is nobody to tell. Ageing the whole key mapping
///     would grey out every unbound tag on a perfectly healthy plant. The
///     anchor for a key is set when the first watcher attaches, because that
///     is the earliest instant this source could have begun noticing silence
///     about it.
///  4. **The timer is listener-gated.** It arms on the first watched key and
///     disarms when the last one goes. An always-on `Timer.periodic` in
///     `tfc_dart` plumbing fails unrelated widget tests ("A Timer is still
///     pending…") and burns CPU on an idle backend; the pipe's own endpoints
///     already follow this rule.
///  5. **A link transition is ONE announcement.** Never one per key: at 1500
///     keys on a page a per-key fan-out is 1500 events for one event,
///     delivered in the instant the client is trying to redraw — a denial of
///     service against the operator's own screen. Sparkplug sends one NDEATH
///     for a whole node for this reason. And never one per sweep tick either:
///     an outage that re-announces itself four times a deadline for as long as
///     the PLC is down is the same denial of service arrived at slowly. See
///     [_onWorkerDied] for what "the link" means when there are three workers.
///
/// ## What this file does NOT do
///
/// **It does not close D-12-08-a and does not widen it.** There is a measured
/// ~9 s window in which a blackholed key still shows its last number badged
/// `good` before `badCommFault` arrives (12-08). [kBackendStaleAfter] is 10 s,
/// chosen from *above* that window, so the sweep never beats the link's own
/// announcement to the screen — and by the time the sweep could act, the key
/// is already `badCommFault`, which rule 1 leaves alone. Phase 16's HARD-01
/// (freshness anchored per link, so a link's own publish cycle proves a
/// constant tag alive) is where that window closes. Lowering [staleAfter] to
/// hide it would make a healthy constant tag decay, which is F3 — the very
/// defect Phase 16 is reproducing.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The process-wide monotonic anchor every age in this file is measured on.
///
/// A [Stopwatch] and not a clock: it counts elapsed time from an arbitrary
/// origin and cannot be stepped by NTP, by an operator, by DST or by a VM
/// resume. One instance for the process, because two sweeps comparing ages
/// against two different origins would disagree about the same key.
final Stopwatch _monotonic = Stopwatch()..start();

/// `BackendValueSource` with a watchdog and a link-transition policy on top.
///
/// See the library doc. Composed at the root as
/// `BackendStateMan(values: BackendFreshnessSweep(values: liveValues, …))`.
final class BackendFreshnessSweep implements BackendValueSource {
  /// Wraps [values] with a watchdog on a [staleAfter] deadline.
  ///
  /// [pipe] is the *link-transition observer* and nothing else: with it, a
  /// worker's death and its respawn each become one announcement; without it
  /// this object is a freshness sweep and no more. Nullable so a composition
  /// that has no acquisition pipe behind it is a legal object rather than one
  /// that needs a stub — a permissive default is a production hole with a
  /// test's name on it (`backend_seams.dart`).
  ///
  /// [interval] defaults to [intervalFor] of the deadline. It is not a
  /// constant because it is derived from a number the caller supplies.
  BackendFreshnessSweep({
    required BackendValueSource values,
    required this.staleAfter,
    PipeMainEndpoint? pipe,
    Duration? interval,
    Logger? logger,
  })  : _values = values,
        _pipe = pipe,
        interval = interval ?? intervalFor(staleAfter),
        _logger = logger ?? Logger() {
    if (pipe == null) return;
    // Registered in the constructor rather than by the composition root, for
    // 13-03's reason about `onKeyRetired`: an obligation wired at a call site
    // is an obligation that can be forgotten at a call site.
    pipe.onWorkerDied = _onWorkerDied;
    pipe.onWorkerReady = _onWorkerReady;
  }

  final BackendValueSource _values;
  final PipeMainEndpoint? _pipe;
  final Logger _logger;

  /// How long a value may go unheard-of before it stops being trustworthy.
  @override
  final Duration staleAfter;

  /// This sweep's cadence. See [intervalFor] for how it was chosen.
  final Duration interval;

  /// The floor under [intervalFor]. [relay.minimumFreshnessInterval], under
  /// this object's own name.
  ///
  /// An implausibly short deadline out of a configuration file must not turn
  /// the sweep into a busy loop on the one isolate serving every client.
  static const Duration minimumInterval = relay.minimumFreshnessInterval;

  /// A quarter of the deadline, floored at [minimumInterval] —
  /// [relay.freshnessIntervalFor].
  ///
  /// **The interval is chosen deliberately and the reasoning is this**, because
  /// it is two costs pulling against each other. It bounds how late a stale
  /// badge can be: a value is reported stale within 125 % of its deadline
  /// rather than within 200 %, and that margin is what keeps a freshness case
  /// green on a loaded machine instead of racing its own budget. And it is CPU
  /// the backend spends whether or not anything is wrong — at the production
  /// [kBackendStaleAfter] this is one pass over the *watched* key set every
  /// 2.5 s, which on a page of 1500 keys is 1500 map lookups and a band
  /// comparison, and stages nothing at all unless something has actually gone
  /// quiet (rule 1). A quarter is the same arithmetic the gateway's
  /// `FreshnessSweep.intervalFor` settled on; the two sides of the pipe having
  /// one answer is worth more here than a second opinion — which is why the
  /// arithmetic now lives in `tfc_relay_protocol`, below both, instead of being
  /// carried twice with a comment promising the two would stay in step. Kept as
  /// a static member because callers and cases name it.
  static Duration intervalFor(Duration staleAfter) =>
      relay.freshnessIntervalFor(staleAfter);

  /// The clock. A named field, so `freeze_test.dart`-style timer scans can see
  /// exactly one of them in this file.
  Timer? _timer;

  /// Whether the clock is running right now.
  bool get running => _timer != null;

  /// How many passes have been made. A diagnostic, and the observable that
  /// tells a case the gate actually opened.
  int get sweeps => _sweeps;
  int _sweeps = 0;

  /// Every key this sweep has asked the source to degrade.
  ///
  /// A diagnostic, and the observable that lets an arm prove the sweep did not
  /// even *ask* about a health key. Asserting on the health key's quality
  /// alone cannot: [BackendValueSource.markStale] carries its own prefix guard,
  /// so a sweep that asked would still be refused, and the arm would pass
  /// against a sweep whose own exclusion had been deleted. Bounded by the keys
  /// that have ever been watched, which is bounded by the key mappings.
  Set<String> get degraded => Set<String>.unmodifiable(_degraded);
  final Set<String> _degraded = <String>{};

  /// One handle per key, so two callers watching one tag share one registration
  /// with the sweep and one refcount underneath.
  final Map<String, _SweptKey> _watched = <String, _SweptKey>{};

  /// When each **watched** key was last heard from, on [_monotonic].
  ///
  /// Milliseconds and not a `DateTime`: see the library doc. A key leaves this
  /// map when its last watcher goes, because an unwatched key has no monitored
  /// item to be fresh from and nobody to tell.
  final Map<String, int> _lastHeard = <String, int>{};

  /// The broadcast controllers [subscribe] handed out, closed on [dispose].
  final List<StreamController<relay.DynamicValue>> _streams =
      <StreamController<relay.DynamicValue>>[];

  /// The same, for [subscribeStamped]. A separate list because the element
  /// types differ; closed alongside [_streams] on [dispose].
  final List<StreamController<StampedValue>> _stampedStreams =
      <StreamController<StampedValue>>[];

  /// Which workers are currently dead, by index. See [_onWorkerDied].
  final Set<int> _downWorkers = <int>{};

  /// True while this object is applying its own mutation to the source.
  ///
  /// A degradation notifies, and a notification is how [_heard] learns a value
  /// arrived — so without this the sweep would record its own staling as a
  /// fresh reading, reset the anchor, and never stale the key again.
  bool _applying = false;

  bool _disposed = false;

  // ------------------------------------------------------------- the handles

  /// A handle for [key] that also tells the sweep somebody is watching.
  ///
  /// The wrapper exists for the transition, not for the value: a listener
  /// attached straight to the inner handle would notify perfectly and the
  /// sweep would never learn the key was on a screen.
  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) => _watch(key);

  /// The same store as a stream, over the same wrapped handle.
  ///
  /// Broadcast, because two widgets watching one key is the normal case and
  /// the second must not be refused. The registration is driven by the
  /// stream's own listeners, so a `subscribe` nobody listens to costs nothing
  /// — neither a monitored item nor a place in the sweep.
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

  _SweptKey _watch(String key) => _watched.putIfAbsent(
      key, () => _SweptKey(this, key, _values.listen(key)));

  // ---------------------------------------------------------- the passthrough

  /// The wrapped source's stamped stream — with the sweep told somebody is
  /// watching.
  ///
  /// **The emissions pass straight through, and that is deliberate.** This
  /// sweep badges a value's *quality* stale; it has nothing to say about where
  /// the instant on it came from, and re-emitting through its own listenable
  /// would mean re-deriving the provenance at a point that does not know it.
  /// Where the stamp came from is a fact about the reading, decided at the
  /// pipe, and it belongs to the object that recorded it.
  ///
  /// **The registration does NOT pass through, and that was the bug.** A bare
  /// forward here left the alarm engine — the only stamped consumer, and since
  /// ALRM-03 the only road it takes — invisible to the sweep: rule 3 ages only
  /// watched keys, nothing else watched an alarm input, so a quiet plant never
  /// staled one and D-3's quality gate never suspended the rule
  /// (`alarm_two_panels_test.dart` arm 7). So this holds a listener on the
  /// swept handle for exactly as long as the stamped stream has listeners —
  /// the same 0→1/1→0 gate [subscribe] rides — purely for the side effects
  /// [_SweptKey] exists for: registration, and the arrival anchor.
  @override
  Stream<StampedValue> subscribeStamped(String key) {
    final watched = _watch(key);
    final inner = _values.subscribeStamped(key);
    // The values come from [inner]; this listener carries no values at all.
    void registration() {}
    late final StreamController<StampedValue> controller;
    StreamSubscription<StampedValue>? forwarding;
    controller = StreamController<StampedValue>.broadcast(
      onListen: () {
        watched.addListener(registration);
        forwarding = inner.listen(controller.add,
            onError: controller.addError, onDone: controller.close);
      },
      onCancel: () {
        watched.removeListener(registration);
        forwarding?.cancel();
        forwarding = null;
      },
    );
    _stampedStreams.add(controller);
    return controller.stream;
  }

  @override
  relay.DynamicValue? read(String key) => _values.read(key);

  @override
  Future<relay.DynamicValue> readFresh(String key) => _values.readFresh(key);

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) =>
      _values.readMany(keys);

  @override
  List<String> get keys => _values.keys;

  @override
  int get roundTrips => _values.roundTrips;

  @override
  int get statusNotifications => _values.statusNotifications;

  @override
  void markStale(Iterable<String> keys) => _values.markStale(keys);

  @override
  void markPending(String key) => _values.markPending(key);

  @override
  void clearPending(String key) => _values.clearPending(key);

  @override
  void applyReadback(String key, relay.DynamicValue value) =>
      _values.applyReadback(key, value);

  @override
  void announceLinkLoss(String reason) => _values.announceLinkLoss(reason);

  @override
  void announceLinkUp() => _values.announceLinkUp();

  // --------------------------------------------------------------- the sweep

  /// One pass over the watched set.
  ///
  /// Three rules, and each one is a decision — see the library doc:
  /// health and alarm keys are skipped by prefix (two prefixes, two reasons);
  /// a key with no recorded arrival is
  /// skipped (nothing has ever come for it, so it is `notYetKnown` and not
  /// stale, which are different statements); and a key already carrying news
  /// at or worse than `badStale`'s band stages nothing, so a quiet plant costs
  /// no rebuilds and no quality is ever improved.
  ///
  /// The whole pass is **one** [markStale] call. Fifty keys going quiet
  /// together is one batch, not fifty.
  void sweep() {
    _sweeps++;
    final now = _monotonic.elapsedMilliseconds;
    final stale = <String>[];
    for (final entry in _watched.entries) {
      final key = entry.key;
      // The four conditions are `relay.isStaleNow`, shared with the gateway's
      // `FreshnessSweep` so neither side can be corrected without the other.
      //
      // `skipAlarmKeys: true`, stated rather than defaulted. This is the one
      // place the two sweeps genuinely differ: the gateway passes `false`
      // because no alarm producer writes into its store, and this side passes
      // `true` because `AlarmEngine` publishes into the pipe store underneath
      // it. The argument is required precisely so that difference is two call
      // sites a reader can compare instead of a missing line in one file. See
      // rule 2 for why alarm keys are a second reason and not the same one as
      // `PIPE.`, and the kernel's library doc for both at length.
      if (!relay.isStaleNow(
        key: key,
        quality: entry.value.value.quality,
        lastHeardMs: _lastHeard[key],
        nowMs: now,
        staleAfter: staleAfter,
        skipAlarmKeys: true,
      )) {
        continue;
      }
      stale.add(key);
    }
    if (stale.isEmpty) return;
    _degraded.addAll(stale);
    // One line per transition, never per tick: the band guard above means a
    // key that is already stale stages nothing, so a plant that has gone quiet
    // logs once and then says nothing more about it.
    _logger.w('backend freshness: ${stale.length} key(s) went quiet for longer '
        'than ${staleAfter.inMilliseconds} ms and are now badged stale');
    _apply(() => _values.markStale(stale));
  }

  /// Runs [mutation] with [_applying] raised, so the notifications it causes
  /// are not mistaken for readings from the plant.
  void _apply(void Function() mutation) {
    _applying = true;
    try {
      mutation();
    } finally {
      _applying = false;
    }
  }

  // ------------------------------------------------------ the link transition

  /// A worker died: announce it **once**, and only once the upstream as a whole
  /// is gone.
  ///
  /// **"The link" here is the upstream, not one isolate, and that is the
  /// careful part.** [BackendValueSource.announceLinkLoss] degrades every key
  /// the source has heard about and drops `PIPE.connected` — a
  /// whole-of-upstream statement. Firing it because *one* of three acquisition
  /// workers died would grey out ST201 and ST301 because ST101's isolate
  /// exited, which is exactly the blast radius 12-08 measured away: one dark
  /// PLC starves only its own isolate, and a mimic with half its boxes greyed
  /// for the wrong reason sends someone to the wrong end of the building.
  /// Nothing is lost by staying quiet, because the dead worker's own keys were
  /// already degraded on this same turn by the pipe (`_onWorkerDied` →
  /// `_markBad(piped, badCommFault)`), scoped to exactly what it was piping.
  ///
  /// What is *not* covered by staying quiet is a per-link health key —
  /// `PIPE.upstream.<alias>.connected` is declared in `pipe_keys.dart` and this
  /// adapter serves none of that group (13-03: every other declared name has a
  /// producer in another package). Naming which PLC went dark, rather than
  /// only that all of them did, is that group's job and not this policy's.
  ///
  /// So: one announcement on the transition into "every worker is down", and
  /// none afterwards. A second death adds nothing to [_downWorkers] that was
  /// not already there, and the sweep tick never announces at all.
  void _onWorkerDied(int worker) {
    if (_disposed) return;
    if (!_downWorkers.add(worker)) return;
    final total = _pipe?.workerCount ?? 0;
    if (total == 0 || _downWorkers.length < total) return;
    _logger.w('backend freshness: every acquisition worker is down '
        '($total of $total) — announcing the upstream loss once');
    _apply(() => _values.announceLinkLoss(
        'every acquisition worker is down ($total of $total)'));
  }

  /// A generation announced itself: announce the recovery once, if a loss was
  /// announced.
  ///
  /// Symmetric with [_onWorkerDied] and equally single. Fires on the FIRST
  /// worker to come back, because that is the transition out of "every worker
  /// is down"; the second and third add nothing.
  ///
  /// The recovery itself is a **snapshot and never a delta replay**: the pipe
  /// re-sends `PipeSubscribe` for the whole subscription set on respawn
  /// (12-06) and [BackendValueSource.announceLinkUp] resnapshots what is being
  /// watched, so a key comes back carrying whatever the plant says *now*. This
  /// file remembers no values and replays none, deliberately — a remembered
  /// number put back on recovery is a number nobody measured, presented as a
  /// measurement, at the exact moment an operator is looking to see what
  /// changed while they were blind.
  void _onWorkerReady(int worker) {
    if (_disposed) return;
    final total = _pipe?.workerCount ?? 0;
    final wasAllDown = total > 0 && _downWorkers.length == total;
    if (!_downWorkers.remove(worker)) return;
    if (!wasAllDown) return;
    _logger.i('backend freshness: an acquisition worker is back — announcing '
        'the upstream recovery once');
    _apply(_values.announceLinkUp);
  }

  // --------------------------------------------------------------- the gating

  /// The first watcher on [key] arrived.
  ///
  /// The anchor starts **now** rather than at whenever the cached value
  /// happened to land. Nothing before this instant was observable: the key had
  /// no monitored item, so no arrival could have been heard, and claiming an
  /// age this object never measured would badge a key stale for a silence that
  /// may never have happened.
  void _register(String key) {
    if (_disposed) return;
    _lastHeard[key] = _monotonic.elapsedMilliseconds;
    _arm();
  }

  /// The last watcher on [key] left.
  void _deregister(String key) {
    _lastHeard.remove(key);
    if (_lastHeard.isEmpty) _disarm();
  }

  /// A value arrived for [key] — unless this object is the one that moved it.
  void _heard(String key) {
    if (_applying) return;
    if (!_lastHeard.containsKey(key)) return;
    _lastHeard[key] = _monotonic.elapsedMilliseconds;
  }

  void _arm() {
    if (_timer != null) return;
    // No immediate pass: every key in [_lastHeard] was anchored at the instant
    // its watcher attached, so a pass right now can only find keys that were
    // already being watched and were already swept on the previous tick.
    _timer = Timer.periodic(interval, (_) => sweep());
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  // ------------------------------------------------------------ the teardown

  /// Cancels the clock, gives the pipe's link hooks back, and disposes the
  /// source beneath.
  ///
  /// **Nothing on the timer path is awaited.** `Timer.cancel` is synchronous
  /// and there is no in-flight pass to join: a sweep is a loop over a map and a
  /// single `markStale`. The one `await` is the wrapped source's own
  /// [BackendValueSource.dispose], which the composition root would otherwise
  /// have no way to reach through this decorator.
  ///
  /// Idempotent: the contract cases register `dispose` with `addTearDown` and
  /// also call it inside the case.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _disarm();

    final pipe = _pipe;
    if (pipe != null) {
      // Only if they are still ours: the composition root may have re-pointed
      // them, and stealing another consumer's hook on the way out would leave
      // whoever owns the pipe next with no link signal at all.
      //
      // `==` and not `identical`: two tear-offs of one instance method on one
      // object are equal but need not be the same object, so `identical` here
      // silently never matches and the hooks are never dropped (13-03 shipped
      // exactly that bug against `onKeyRetired` and its own arm caught it).
      if (pipe.onWorkerDied == _onWorkerDied) pipe.onWorkerDied = null;
      if (pipe.onWorkerReady == _onWorkerReady) pipe.onWorkerReady = null;
    }

    for (final watched in _watched.values) {
      watched._teardown();
    }
    _watched.clear();
    _lastHeard.clear();

    await Future.wait(<Future<void>>[
      for (final controller in _streams)
        if (!controller.isClosed) controller.close(),
      for (final controller in _stampedStreams)
        if (!controller.isClosed) controller.close(),
    ]);
    _streams.clear();
    _stampedStreams.clear();

    await _values.dispose();
  }
}

/// One key's handle: the source's own handle, plus the registration that makes
/// the sweep aware of it.
final class _SweptKey implements relay.ValueListenable<relay.DynamicValue> {
  _SweptKey(this._owner, this._key, this._inner);

  final BackendFreshnessSweep _owner;
  final String _key;
  final relay.ValueListenable<relay.DynamicValue> _inner;
  final List<relay.VoidCallback> _listeners = <relay.VoidCallback>[];

  bool _attached = false;

  /// The source's value, always. There is no second copy to go stale against
  /// the one the sweep is judging.
  @override
  relay.DynamicValue get value => _inner.value;

  @override
  void addListener(relay.VoidCallback listener) {
    _listeners.add(listener);
    if (_listeners.length != 1) return; // 0 -> 1 only
    _attached = true;
    _inner.addListener(_onChanged);
    _owner._register(_key);
  }

  @override
  void removeListener(relay.VoidCallback listener) {
    if (!_listeners.remove(listener)) return;
    if (_listeners.isNotEmpty) return; // 1 -> 0 only
    if (!_attached) return;
    _attached = false;
    _inner.removeListener(_onChanged);
    _owner._deregister(_key);
  }

  /// Iterates a copy: a listener may remove itself while being notified.
  void _onChanged() {
    _owner._heard(_key);
    for (final listener in List<relay.VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  /// Detaches from the source and forgets every listener. After this the
  /// handle still reads — a widget mid-dispose may still build — but notifies
  /// nobody.
  void _teardown() {
    if (_attached) {
      _attached = false;
      _inner.removeListener(_onChanged);
    }
    _listeners.clear();
  }
}
