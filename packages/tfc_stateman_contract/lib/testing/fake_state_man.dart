/// The reference implementation the contract suite is developed against.
///
/// It is not a mock. It is a real, in-memory `StateManApi` backed by the same
/// [ValueStore] the server and client implementations use, with a control
/// surface ([StateManHarness]) standing in for the plant. Two jobs follow from
/// that: it proves a case is satisfiable before any production code exists, and
/// it is the honest baseline the deliberately damaged variants in
/// `broken_subscribe.dart` are measured against.
///
/// Backing it with the real store is the point. A fake with its own hand-rolled
/// notification logic would let the suite pass against something no production
/// implementation resembles; here the k-of-n rebuild property is satisfied by
/// the same code that will satisfy it on the gateway.
///
/// It lives under `lib/testing/` rather than `lib/src/` because the server and
/// client packages import it — a Phase 3 test that needs a state source with a
/// known value in it should not have to build one.
///
/// It runs a real freshness watchdog on the wall clock rather than on an
/// injected one. That costs the freshness cases a real `staleAfter` of runtime
/// each, and it is worth it: a sweep that only advances when a test advances a
/// fake clock is precisely the machinery that then fails to run in the plant,
/// and this fake exists to prove a case is satisfiable by something a real
/// implementation resembles.
///
/// The five reserved `PIPE.` health keys are served through the ordinary value
/// path (design §4.7, HLTH-01) — there is no health method here because there
/// is none on the wire — and are excluded from the freshness sweep (HLTH-02).
///
/// Every member of `StateManApi` is genuinely implemented: the four
/// data-service sub-APIs are the in-memory implementations in
/// `fake_data_services.dart`, and the four access families are
/// [FakeAccessServices] in `fake_access_services.dart` — both injectable
/// through the constructor so a driver can seed a browse tree, a recorded series
/// or a session without subclassing. No member is left throwing to name a plan
/// that has not been written yet, and that absence is the property saying the
/// interface has been contracted end to end — every area of it has a case
/// judging it.
///
/// Plan 17-03 added `accessTemplates`, `accessAdmin`, `audit` and
/// `backendConfig`; 17-03b left them refusing by name until a contract case
/// existed to judge them; plan 17-05 wrote those cases and gave this fake the
/// in-memory reference implementation they judge. The session those families
/// consult is swapped through the test-only [actAs] lever (declared by
/// [StateManAccessHarness]), in the same one-way lane the value levers travel —
/// because the property the access contract judges is "the same implementation
/// answers differently to different sessions", and a lever, not a constructor
/// argument, is how one live instance shows both a refusal and its twin.
library;

import 'dart:async';

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../src/access_contract.dart';
import '../src/data_services_contract.dart';
import '../src/harness.dart';
import '../src/hold_harness.dart';
import '../src/write_contract.dart';
import 'fake_access_services.dart';
import 'fake_data_services.dart';

/// An in-memory state source with a lever for everything the plant would do.
class FakeStateMan
    implements
        StateManApi,
        StateManHarness,
        StateManWriteHarness,
        StateManHoldHarness,
        StateManDataHarness,
        StateManAccessHarness {
  FakeStateMan({
    this.staleAfter = const Duration(milliseconds: 300),
    Set<String> readOnlyKeys = const {},
    this.writeLatency = Duration.zero,
    FakeBrowse? browse,
    FakeTimeseries? timeseries,
    FakeHistoryViews? historyViews,
    FakePreferences? preferences,
    FakeAccessServices? access,
  })  : _readOnlyKeys = {...readOnlyKeys},
        _browse = browse ?? FakeBrowse(),
        _timeseries = timeseries ?? FakeTimeseries(),
        _historyViews = historyViews ?? FakeHistoryViews(),
        _preferences = preferences ?? FakePreferences(),
        // Starts holding every group, so out of the box the fake hides nothing;
        // an access case narrows it through actAs. That default is the honest
        // baseline — a fake that refused by construction would make the suite's
        // negative arms pass against an implementation with no gate at all.
        _access = access ??
            FakeAccessServices(
                session: AccessSession(groups: AccessGroup.values.toSet())) {
    _seedHealthKeys();
    _watchdog = Timer.periodic(_sweepInterval, (_) => sweepFreshness());
  }

  /// How long a value may go unheard-of before it must stop claiming to be
  /// current.
  ///
  /// 300 ms by default: long enough that the subscribe and store cases, which
  /// finish in single-digit milliseconds, never trip it, short enough that a
  /// freshness case waiting the deadline out on the wall clock stays cheap.
  /// The freshness driver passes a shorter one still.
  @override
  final Duration staleAfter;

  /// How long an upstream write takes to answer.
  ///
  /// Zero by default, so the ordinary write cases cost nothing. A case that
  /// needs to look *into* the in-flight window uses [stallWrites] instead,
  /// which holds it open until something says otherwise — a duration would
  /// make the case a race against a timer, which is the shape of test that
  /// passes on a laptop and flakes on CI.
  final Duration writeLatency;

  /// The reserved namespace the pipe reports on itself through (design §4.7,
  /// HLTH-01). There is no health method on the wire; these are ordinary
  /// subscribable keys, served through the same store and the same qualities
  /// as a temperature.
  static const healthPrefix = 'PIPE.';

  /// The five health keys, seeded at construction so a client can read them
  /// before anything has happened — a health indicator that reads "unknown"
  /// until the first fault is no indicator at all.
  static const healthKeys = [
    '${healthPrefix}connected',
    '${healthPrefix}rtt_ms',
    '${healthPrefix}data_age_ms',
    '${healthPrefix}reconnects',
    '${healthPrefix}epoch',
  ];

  /// One map, one batch entry point — the same store the real implementations
  /// use, so the notification-count promises are satisfied by production code
  /// rather than by test scaffolding.
  final _store = ValueStore();

  /// Keys retired by [dropKey]. Held separately from the store because the
  /// store has no concept of a tag that is gone: it would happily accept the
  /// next value for it.
  final _retiredKeys = <String>{};

  /// Closers for the streams [subscribe] has handed out that are still open,
  /// so [dispose] can shut down a consumer that never cancelled.
  ///
  /// Each closer deregisters itself, which is the difference between a
  /// registry and a leak: this class is documented as importable by the server
  /// and client packages and Phase 3/4 tests will hold one across many cases,
  /// so a list that only ever grows means a controller per `subscribe` call
  /// retained for the object's whole lifetime — and a `dispose` that awaits
  /// `close()` on every controller ever created.
  ///
  /// A [Set] with identity semantics, because two closers are never
  /// interchangeable even though nothing distinguishes their signatures.
  final _closeHandedOutStreams = <Future<void> Function()>{};

  /// When each key last had a value *arrive* for it.
  ///
  /// Deliberately not the value's own `sourceTime`: the harness leaves that
  /// null unless a case sets one, and a source that dated freshness from a
  /// field the upstream may not fill would consider every value it has ever
  /// received to be infinitely old.
  final _lastArrival = <String, DateTime>{};

  /// The freshness watchdog. Wall clock, not an injected one — a sweep that
  /// only runs when a test advances a fake clock is exactly the machinery that
  /// then fails to run in the plant.
  late final Timer _watchdog;

  /// Keys the device will not take a write for.
  ///
  /// Mutable, and seeded from the constructor: read-only devices are real
  /// (`M2400DeviceClientAdapter.write` throws `UnsupportedError` today), and
  /// which keys are read-only is a property of the device, not of the pipe.
  final Set<String> _readOnlyKeys;

  /// How many upstream attempts each `cmd` has cost.
  ///
  /// The observable the no-auto-retry property is enforced through. Every
  /// entry here must stay at 1 forever; a 2 is a machine having decided, on an
  /// operator's behalf, to actuate the plant a second time.
  final _writeAttempts = <String, int>{};

  /// Every `cmd` minted, in mint order.
  ///
  /// A `Set` and not a `List`, and that is the contract check's teeth
  /// (04-REVIEW CR-05): "every write mints its own 26-character cmd" was
  /// asserted against a list, which cannot tell two writes sharing one id from
  /// two writes with two ids. One id covering two actuations is precisely the
  /// failure `ulid.dart` names — "one of the two writes silently reports the
  /// other's outcome" — so the reference implementation refuses it.
  final _mintedCmds = <String>{};

  /// Writes that went upstream and have had no answer.
  final _stalledWrites = <_StalledWrite>[];

  /// What each key's quality was before a write put a pending badge on it, so
  /// a refusal can put it back rather than inventing a fresh `good`.
  final _pendingRestore = <String, Quality>{};

  /// Whether writes currently vanish upstream (Phase 2's `blackhole`).
  var _writesStalled = false;

  /// The answer the device has been told to give the next write only.
  WriteReason? _nextWriteReason;
  var _nextWriteUnknown = false;

  /// The value the device will end up holding for the next write, when that
  /// differs from the one written (a clamp). Kept as a flag plus a slot
  /// because null is a legitimate readback.
  Object? _nextReadback;
  var _hasNextReadback = false;

  /// Whether the upstream device link is up. Health keys are served regardless;
  /// plant keys are not.
  var _connected = true;

  var _roundTrips = 0;
  var _statusNotifications = 0;

  var _disposed = false;

  /// How often the watchdog re-evaluates ages.
  ///
  /// A quarter of the deadline, so a value is reported stale within 125% of it
  /// rather than within 200% — the contract cases allow three times the
  /// deadline, and the margin between those two numbers is what keeps them
  /// green on a loaded machine. Floored at 5 ms so an implausibly short
  /// deadline cannot turn the sweep into a busy loop.
  Duration get _sweepInterval {
    final quarter = staleAfter ~/ 4;
    return quarter < const Duration(milliseconds: 5)
        ? const Duration(milliseconds: 5)
        : quarter;
  }

  /// Health keys are excluded from the freshness sweep (HLTH-02).
  static bool isHealthKey(String key) => key.startsWith(healthPrefix);

  // ------------------------------------------------------------- value path

  /// The store's node for [key] — the same instance every time, so a widget
  /// keeps the handle it was given and a second `listen` costs nothing.
  @override
  ValueListenable<DynamicValue> listen(String key) => _store.node(key);

  /// A broadcast view of the same node, for stream-consuming code.
  ///
  /// A view, never a second source of truth: the controller carries whatever
  /// the node currently holds, pushed by a listener attached on first
  /// subscription and removed when the last subscriber cancels. That is also
  /// why nothing is replayed on listen — the snapshot lives in the store, where
  /// [read] and `listen(key).value` reach it synchronously, and this stream
  /// carries changes from the moment it is taken. Because the stream is
  /// returned synchronously (not behind a `Future`), taking it and listening to
  /// it happen in the same turn, so there is no window in which a change can be
  /// missed.
  @override
  Stream<DynamicValue> subscribe(String key) {
    final node = _store.node(key);
    late final StreamController<DynamicValue> controller;
    void push() => controller.add(node.value);
    // Registered while the stream is live and deregistered when the last
    // subscriber goes away, so the registry tracks streams that still need
    // closing rather than every stream ever handed out. Re-listening
    // re-registers, exactly as it re-attaches the node listener.
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
    _closeHandedOutStreams.add(close);
    return controller.stream;
  }

  /// How many handed-out streams are still registered for closing.
  ///
  /// Exposed because nothing else about a cancelled stream is observable from
  /// outside, and a registry that only ever grows is a leak in shipped `lib/`
  /// code rather than in a test file: this class is imported by the server and
  /// client packages, and Phase 3/4 tests hold one instance across many cases.
  int get openHandedOutStreams => _closeHandedOutStreams.length;

  /// The cached value, or null when nothing has arrived for [key] yet — the
  /// "not known" / "known to be bad" distinction the interface requires.
  @override
  DynamicValue? read(String key) => _store.peek(key);

  /// The keys this source can actually serve.
  ///
  /// Filtered on a value having arrived, rather than returning every node the
  /// store holds: `listen` creates a node for any key asked of it, including a
  /// tag mistyped into a page config, and offering that key back to the page
  /// editor's picker would launder a typo into an apparently valid binding.
  @override
  List<String> get keys => [
        for (final key in _store.keys)
          if (_store.peek(key) != null) key,
      ];

  /// Drops every listener and closes every stream handed out. Idempotent: a
  /// second call is harmless, because the suite disposes in `addTearDown` and a
  /// case that disposes deliberately must not be punished for it.
  ///
  /// Cancelling the watchdog is the part that matters most here: a timer that
  /// outlives its source keeps the whole test isolate alive and keeps sweeping
  /// a store nobody is watching, so a leak in one case surfaces as an
  /// inexplicable notification in the next one.
  ///
  /// Writes still in flight are settled as unknown rather than abandoned. A
  /// future nobody completes does not fail a test — it hangs it, for the full
  /// 30-second runner timeout, on every CI run for as long as the case exists,
  /// and reports a file name rather than a property. Unknown is also the
  /// honest answer: a source going away is not evidence the device did not
  /// take the write.
  ///
  /// The preferences change stream is closed here for the same reason the
  /// watchdog is cancelled: a broadcast controller nobody closes keeps the test
  /// isolate alive, so a leak in one case surfaces as a hang three cases later.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Before the flag, because a release is a write and [write] refuses to
    // run on a disposed source — and because a source that tore itself down
    // leaving a counter advancing is a machine nobody is holding.
    _releaseHolds(HoldEnded.disposed);
    _disposed = true;
    _watchdog.cancel();
    _loseTrackOfWritesInFlight(const WriteReason('link_lost',
        message: 'the source was disposed while the write was in flight'));
    _store.dispose();
    // A snapshot: each closer deregisters itself, and closing a controller
    // with a live subscriber runs onCancel, which does the same.
    for (final close in List.of(_closeHandedOutStreams)) {
      await close();
    }
    _closeHandedOutStreams.clear();
    await _preferences.dispose();
  }

  // --------------------------------------------------------- control surface

  /// Delivers one value, as one upstream update.
  ///
  /// [sourceTime] stays null unless given: stamping a receive time here would
  /// make two identical readings unequal and silently defeat the store's
  /// unchanged-value guard. `NotifiesOnUnchanged` in `broken_subscribe.dart`
  /// is that mistake, made on purpose.
  @override
  void setValue(String key, Object? value,
          {Quality quality = Quality.good, DateTime? sourceTime}) =>
      applyChanges({
        key: DynamicValue(value: value, quality: quality, sourceTime: sourceTime)
      });

  /// Delivers many keys as exactly one batch — one pass over the store, one
  /// sequence evaluation, k notifications. Simulates a subscription push
  /// carrying everything that moved since the last one.
  @override
  void setValues(Map<String, Object?> values) => applyChanges({
        for (final entry in values.entries)
          entry.key: DynamicValue(value: entry.value),
      });

  /// Re-delivers the current value under a different quality.
  ///
  /// Simulates what the freshness watchdog and the write path do to a value
  /// without the number itself changing: going stale, losing the upstream link,
  /// or carrying a pending write. Corresponds to Phase 2's `latency` and
  /// `blackhole` proxy modes, whichever produced the degradation.
  @override
  void setQuality(String key, Quality quality) => applyChanges({
        key: (_store.peek(key) ?? notYetKnown).copyWith(quality: quality),
      });

  /// The tag is gone upstream: [key] reads as a configuration error and never
  /// updates again.
  ///
  /// Simulates a PLC tag renamed or deleted under a page that still binds it.
  /// Retiring the key *after* the error value is applied is deliberate — the
  /// operator must be told once that the tag is gone, and told nothing after
  /// that.
  @override
  void dropKey(String key) {
    applyChanges({
      key: DynamicValue(value: null, quality: Quality.errorConfig),
    });
    _retiredKeys.add(key);
  }

  /// The single seam every lever applies through.
  ///
  /// Exists so a sabotage variant can break exactly one thing by overriding one
  /// method — a variant that had to reimplement each lever would drift from the
  /// honest fake in ways nobody intended, and "the sabotage is surgical" would
  /// stop being true.
  ///
  /// Everything routed here counts as a value *arriving*, so it resets the
  /// freshness clock. Degradations do not go through it — see [_degrade].
  void applyChanges(Map<String, DynamicValue> changes) =>
      _apply(changes, arrived: true);

  /// Applies a quality change without pretending a value arrived.
  ///
  /// The distinction is the whole freshness story: marking a value stale must
  /// not make it fresh again, and losing the upstream link is not news from
  /// upstream. A single seam that reset the clock on everything would produce
  /// a source that goes stale exactly once and never again.
  void _degrade(Map<String, DynamicValue> changes) =>
      _apply(changes, arrived: false);

  void _apply(Map<String, DynamicValue> changes, {required bool arrived}) {
    final live = <String, DynamicValue>{
      for (final entry in changes.entries)
        if (!_retiredKeys.contains(entry.key)) entry.key: entry.value,
    };
    if (live.isEmpty) return;
    if (arrived) {
      final now = DateTime.now();
      for (final key in live.keys) {
        _lastArrival[key] = now;
      }
    }
    _store.applyBatch(live);
  }

  // ------------------------------------------------------------------- reads

  /// Answers from the cache after forcing one round trip upstream.
  ///
  /// The round trip is the point: this is the call a diagnostics page and a
  /// readback check use precisely when the cache is the thing under suspicion.
  @override
  Future<DynamicValue> readFresh(String key) async {
    _roundTrips++;
    return _answerFromUpstream([key])[key]!;
  }

  /// One round trip for however many keys are asked for.
  ///
  /// [_roundTrips] is incremented once, before any key is looked at, because
  /// that is the promise: reading fifty keys over a link with 200 ms of
  /// latency costs 200 ms, not ten seconds.
  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    _roundTrips++;
    return _answerFromUpstream(keys);
  }

  @override
  int get roundTrips => _roundTrips;

  @override
  int get statusNotifications => _statusNotifications;

  /// What one round trip comes back with, and what it does to the cache.
  ///
  /// An answer for **every** key asked about, including keys nothing is known
  /// about — as a bad-quality value rather than a missing entry, so the caller
  /// renders a fault instead of a blank. Keys the round trip genuinely reached
  /// are also applied to the store, which is what makes a forced read reset
  /// the freshness clock and clear a staleness the watchdog had applied.
  Map<String, DynamicValue> _answerFromUpstream(Iterable<String> keys) {
    final answers = <String, DynamicValue>{};
    final reached = <String, DynamicValue>{};
    for (final key in keys) {
      final cached = _store.peek(key);
      if (cached == null) {
        // Nothing is known: notYetKnown carries an uncertain-band code, which
        // renders as "cannot be trusted" rather than as a good null — and
        // does not claim the tag is gone, which is what errorConfig means and
        // is a thing a round trip finding nothing does not establish.
        answers[key] = notYetKnown;
        continue;
      }
      if (_retiredKeys.contains(key) || !_reachable(key)) {
        // The tag is gone, or the link is down. Either way the answer is the
        // degraded value already in the cache — inventing a good one here is
        // the `LiesAboutQuality` sabotage.
        answers[key] = cached;
        continue;
      }
      final answer = _isLinkDegraded(cached.quality)
          ? cached.copyWith(quality: Quality.good)
          : cached;
      answers[key] = answer;
      reached[key] = answer;
    }
    if (reached.isNotEmpty) applyChanges(reached);
    return answers;
  }

  /// Whether a round trip for [key] can get an answer at all.
  bool _reachable(String key) => _connected || isHealthKey(key);

  /// Whether [quality] is one the freshness and link machinery applied.
  ///
  /// Only these two clear on a successful round trip. A source that reset
  /// *any* bad quality to good on a read would launder a genuine upstream
  /// fault — a non-finite reading, a bad string encoding — into a healthy
  /// number, which is the same lie as a stale value with better manners.
  static bool _isLinkDegraded(Quality quality) =>
      quality == Quality.badStale || quality == Quality.badCommFault;

  // -------------------------------------------------------------- freshness

  /// Re-evaluates every key's age and degrades the ones past [staleAfter].
  ///
  /// Overridable because it is the single behavior `ServesStaleReads` removes:
  /// a source whose sweep never runs delivers a page that looks exactly like a
  /// healthy one and has not been true for an hour.
  ///
  /// Two rules the loop encodes. Health keys are skipped (HLTH-02): they change
  /// only when the pipe's state changes, so on a healthy pipe they are
  /// *always* older than the deadline, and staling them would grey out the one
  /// indicator that says whether to believe the rest. And a key is only
  /// degraded if `badStale` is genuinely worse than what it already carries —
  /// a comparison rather than [Quality.worst] so that a key needing no change
  /// stages no change at all, and so the sweep never notifies a page whose
  /// values are already worse news than stale.
  void sweepFreshness() {
    final now = DateTime.now();
    final stale = <String, DynamicValue>{};
    for (final key in _store.keys) {
      if (isHealthKey(key)) continue;
      final cached = _store.peek(key);
      if (cached == null) continue;
      final arrived = _lastArrival[key];
      if (arrived == null || now.difference(arrived) < staleAfter) continue;
      if (Quality.badStale.band <= cached.quality.band) continue;
      stale[key] = cached.copyWith(quality: Quality.badStale);
    }
    if (stale.isEmpty) return;
    _degrade(stale);
  }

  // ------------------------------------------------------------- link levers

  /// The upstream device link is down (Phase 2's `flap(down)`).
  ///
  /// Idempotent: a second call while already down changes nothing and announces
  /// nothing, because it is not a second event.
  /// Writes still out are settled first, and that ordering is load-bearing:
  /// settling one restores the quality its key had before the pending badge,
  /// so doing it after [applyLinkLoss] would paint a good quality back over a
  /// key whose link is down.
  @override
  void disconnectUpstream() {
    if (!_connected) return;
    _connected = false;
    _loseTrackOfWritesInFlight(const WriteReason('link_lost',
        message: 'the upstream link dropped while the write was in flight'));
    applyLinkLoss();
    announceLinkState();
  }

  /// The upstream link is back, with a snapshot (Phase 2's `flap(up)`).
  ///
  /// Recovery is a snapshot and never a delta replay, so every key that has a
  /// value comes back at once rather than waiting until it next happens to
  /// change — otherwise a slow-moving tank level would stay greyed for an hour
  /// after the link healed.
  @override
  void reconnectUpstream() {
    if (_connected) return;
    _connected = true;
    applyLinkRestored();
    announceLinkState();
  }

  /// One pass over the store: every plant key degrades, the health keys record
  /// what happened, all in a single batch.
  ///
  /// One batch, not one per key — the store's promise is that a batch costs
  /// one pass and k notifications, and a link loss is the largest batch this
  /// source will ever apply.
  void applyLinkLoss() {
    final batch = <String, DynamicValue>{};
    for (final key in _store.keys) {
      if (isHealthKey(key)) continue;
      final cached = _store.peek(key);
      if (cached == null) continue;
      if (Quality.badCommFault.band <= cached.quality.band) continue;
      batch[key] = cached.copyWith(quality: Quality.badCommFault);
    }
    batch['${healthPrefix}connected'] = DynamicValue(value: false);
    _degrade(batch);
  }

  /// The snapshot that follows a reconnect: link-degraded keys come back good,
  /// the health counters record the reconnection.
  void applyLinkRestored() {
    final batch = <String, DynamicValue>{};
    for (final key in _store.keys) {
      if (isHealthKey(key)) continue;
      final cached = _store.peek(key);
      if (cached == null || !_isLinkDegraded(cached.quality)) continue;
      batch[key] = cached.copyWith(quality: Quality.good);
    }
    batch['${healthPrefix}connected'] = DynamicValue(value: true);
    batch['${healthPrefix}reconnects'] =
        DynamicValue(value: _healthCount('${healthPrefix}reconnects') + 1);
    // The epoch changes on every reconnect so a client can tell "the same
    // session, still running" from "a new session that may have missed
    // updates" — the distinction that decides between resuming and resyncing.
    batch['${healthPrefix}epoch'] =
        DynamicValue(value: _healthCount('${healthPrefix}epoch') + 1);
    applyChanges(batch);
  }

  /// Announces that the link's state changed — once, however many keys it cost.
  ///
  /// Kept separate from [applyLinkLoss] so a variant can fan it out per key
  /// without touching the degradation itself, which is exactly what
  /// `AnnouncesPerKey` does. Sparkplug sends one NDEATH for a whole node for
  /// the same reason: at 1500 keys, one event per key is 1500 events arriving
  /// in the instant the client is trying to redraw the page they are about.
  void announceLinkState() => _statusNotifications++;

  /// Seeds the five reserved health keys so they are readable before anything
  /// happens. A health indicator that reads "unknown" until the first fault
  /// tells an operator nothing at the moment they most need telling.
  ///
  /// `data_age_ms` and `rtt_ms` are seeded and left alone: a fake that
  /// refreshed them on a timer would notify every listener on every sweep and
  /// quietly wreck the notification-count promises the rest of the suite
  /// makes. A real gateway updates them on a slow cadence, which is a
  /// behaviour Phase 3 owns and no contract case here depends on.
  void _seedHealthKeys() => applyChanges({
        '${healthPrefix}connected': DynamicValue(value: true),
        '${healthPrefix}rtt_ms': DynamicValue(value: 0),
        '${healthPrefix}data_age_ms': DynamicValue(value: 0),
        '${healthPrefix}reconnects': DynamicValue(value: 0),
        '${healthPrefix}epoch': DynamicValue(value: 1),
      });

  int _healthCount(String key) => _store.peek(key)?.asInt ?? 0;

  // ------------------------------------------------------------------ writes

  /// Writes [value] to [key] and reports what became of it.
  ///
  /// Three things happen here and nowhere else, in this order. The `cmd` is
  /// minted — at call time, because the call *is* the operator action
  /// (CONTEXT D-04), so a re-send of the same action can carry the same id.
  /// The value picks up a pending badge, so the in-flight window is visible on
  /// the value a widget is already watching rather than on a handle object
  /// somebody has to remember to hold. And then exactly one upstream attempt
  /// is made, through [attemptUpstreamWrite] and through nothing else.
  ///
  /// A caller that is **relaying** an operator action rather than originating
  /// one passes the id that action was already minted under (see
  /// `state_man_api.dart`), and then that id — not a second one — is what
  /// [mintedCmds] records and what [upstreamWriteAttempts] counts against. That
  /// is the whole reason the parameter exists: behind a gateway, a plant that
  /// minted its own id would make "how many times did this operator action
  /// reach the device" a question nothing on either side could answer.
  ///
  /// It never throws to report an outcome. The three throws below are all
  /// programmer errors established *before* anything is attempted — writing
  /// through a disposed source, re-using a command id, and handing this a
  /// number the write path cannot carry — and a throw that meant "the write
  /// failed" would collapse "the PLC may have applied this" into "this
  /// definitely did not happen", which is the anti-pattern [WriteResult] exists
  /// to make unrepresentable.
  @override
  Future<WriteResult> write(String key, Object? value,
      {Object? expect, String? cmd}) async {
    if (_disposed) {
      throw StateError('write($key) on a disposed source: the store and the '
          'upstream link are both gone, so no outcome reported here could be '
          'true. This is a lifecycle bug in the caller, not a write outcome.');
    }
    // Before the id is minted, because an id that exists is an action that may
    // have been attempted: a `writeStatus` asking after it could no longer
    // answer `not_received`, which is the one verdict that makes a re-send
    // safe.
    //
    // The reference implementation refuses because the contract does
    // (`write_contract.dart`, `a non-finite write is refused before the plant`)
    // and the contract does because every layer beneath it already did:
    // `WriteParams`, `value_handlers.write`, `ServedStateMan.write`. Sanitizing
    // is right for telemetry — one bad reading must not fail a frame shared
    // with every client — and wrong here, where the sanitized value is a write
    // of `null` to a live tag: the device is actuated with something nobody
    // chose while the operator is told the write applied.
    if (sanitize(value).hadNonFinite) {
      throw ArgumentError.value(
          value,
          'value',
          'a write cannot carry a non-finite number: it encodes to null, and '
              'a write of null actuates the device with a value nobody chose '
              'while the operator is told the write applied');
    }
    if (sanitize(expect).hadNonFinite) {
      throw ArgumentError.value(
          expect,
          'expect',
          'a write cannot carry a non-finite compare-and-set guard: nulling '
              'it is this path\'s encoding of "no guard at all", so a guarded '
              'write would silently become an unconditional one');
    }
    final id = cmd ?? newUlid();
    if (!_mintedCmds.add(id)) {
      // A programmer error, like the disposed case above, and reported the
      // same way: nothing was attempted, so there is no outcome to report and
      // a `WriteResult` here would be an invention.
      throw ArgumentError.value(
          id,
          'cmd',
          'this source has already seen the command id "$id". One id is one '
              'operator action: a second write under it would be a second '
              'actuation reported under the first one\'s outcome, which is '
              'the failure the id exists to make impossible');
    }
    _markWritePending(key);
    final result = await attemptUpstreamWrite(id, key, value, expected: expect);
    // Recorded here, in the one place every write settles, so a write parked
    // by [stallWrites] is recorded when it settles rather than when it left —
    // which is the difference between an outcome log and a wish list.
    _outcomes[result.cmd] = result;
    return result;
  }

  /// Every outcome this source has settled, keyed by the id it settled under.
  ///
  /// Never pruned. The gateway's log has a TTL and a `outcome_expired` answer
  /// because it serves a plant for months; a fake lives for one test, so the
  /// expiry arm cannot be reached here and is deliberately not imitated.
  final _outcomes = <String, WriteResult>{};

  /// The instant this source started recording outcomes.
  ///
  /// The evidence [writeStatus] needs: a command minted before this moment is
  /// one this source could never have heard about, which is a different thing
  /// from one it never received.
  final int _startedMs = DateTime.now().millisecondsSinceEpoch;

  /// What became of each of [cmds], positionally aligned with the question.
  ///
  /// The gateway's three-piece positive-evidence rule
  /// (`value_handlers.dart:357-398`), mirrored rather than loosened. A
  /// reference implementation that answered [WriteNotReceived] more freely
  /// than the gateway does is one the contract cannot use: `not_received` is
  /// the single answer that tells an operator a re-send is safe, so an
  /// implementation is judged by how hard it is to get, not how helpful it
  /// sounds.
  ///
  ///  * a recorded outcome is the answer, always;
  ///  * an id that is not a datable ULID is `unrecognized_cmd` — nothing about
  ///    it can be ruled out;
  ///  * an id minted before this source started, or ahead of its clock, is
  ///    `outcome_unwitnessed`: forgetting is not evidence of never happening,
  ///    and a panel whose clock runs fast must not buy itself a re-send
  ///    window;
  ///  * anything left is a command this source genuinely never received.
  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) async =>
      [for (final cmd in cmds) _statusOf(cmd)];

  WriteResult _statusOf(String cmd) {
    final held = _outcomes[cmd];
    if (held != null) return held;

    final mintedAt = referenceUlidMs(cmd);
    if (mintedAt == null) {
      return WriteUnknown(
          cmd,
          const WriteReason('unrecognized_cmd',
              message: 'this is not an id this source could have issued an '
                  'outcome for, so nothing about it can be ruled out'));
    }
    if (mintedAt < _startedMs ||
        mintedAt > DateTime.now().millisecondsSinceEpoch) {
      return WriteUnknown(
          cmd,
          const WriteReason('outcome_unwitnessed',
              message: 'this command was minted outside the window this '
                  'source can vouch for with its own clock — before it '
                  'started recording, or ahead of it. Read the value back '
                  'before acting'));
    }
    return WriteNotReceived(cmd);
  }

  /// Crockford base32, the same alphabet `newUlid` encodes with.
  static const String _ulidAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// The millisecond a ULID was minted at, or null when [cmd] is not one.
  ///
  /// **This copy is deliberate and it is the only one left.** Phase 18 pulled
  /// the other three into `tfc_relay_protocol.ulidMs` and deleted them; this
  /// one stays, because `FakeStateMan` is the contract suite's *reference
  /// implementation* and a reference that imports the thing it is a reference
  /// for cannot catch a bug in that thing. The fake already imports
  /// `tfc_relay_protocol` for `DynamicValue`, `Quality` and `WriteResult`, so
  /// the independence is not absolute — but those are **vocabulary** and this
  /// is **logic**, and the whole of the argument is in that distinction. If
  /// `ulidMs` ever starts dating ids wrong, the gateway and the reference must
  /// not go wrong together and agree.
  ///
  /// **What that argument cost, and why it is now paid for.** This exact
  /// reasoning is what let a dart2js defect live in three of four copies: the
  /// encoder in `ulid.dart` was migrated off bitwise arithmetic and the copies
  /// were not, because nothing checked that they still matched. A stated
  /// invariant with no test is the failure Phase 18 exists to repay, so the
  /// independence is now **checked rather than merely asserted** — see
  /// `test/ulid_reference_agreement_test.dart`, which decodes the same ids
  /// through this method and through `ulidMs` and requires them to agree.
  /// That arm is what makes keeping this copy honest instead of merely
  /// traditional.
  ///
  /// The arithmetic is a multiply and an add, matching `ulidMs`: JavaScript
  /// coerces bitwise operators to 32 bits and the timestamp field is 48, so a
  /// shift here would fold every real timestamp onto its low 32 bits under
  /// `dart2js`. Independence means deciding the same answer independently, not
  /// being free to decide a different one.
  ///
  /// Public rather than private only so the agreement arm can reach it. It is
  /// not part of the [StateManApi] surface and no contract case calls it.
  static int? referenceUlidMs(String cmd) {
    if (cmd.length != 26) return null;
    var ms = 0;
    for (var i = 0; i < 10; i++) {
      final digit = _ulidAlphabet.indexOf(cmd[i]);
      if (digit < 0) return null;
      ms = ms * 32 + digit;
    }
    return ms;
  }

  /// Every hold this source is currently feeding.
  final _liveHolds = <HoldHandle>{};

  /// Engages a deadman on [key] with one ordinary write, and hands back the
  /// handle that feeds it.
  ///
  /// Two writes per hold and no more, however long it is held: the engage
  /// here, the release through the handle. The ticks in between go to the
  /// plant through [applyHoldTick] — never through [write], never through
  /// [attemptUpstreamWrite] — so a held button costs the write bookkeeping
  /// nothing at all.
  @override
  Future<HoldHandle> holdToRun(String key) async {
    final engagement = await write(key, 1);
    final hold = HoldHandle(
      key: key,
      engagement: engagement,
      onTick: (counter) => applyHoldTick(key, counter),
      onRelease: (counter) => write(key, counter),
    );
    if (hold.isHeld) {
      _liveHolds.add(hold);
      unawaited(hold.onReleased.then((_) => _liveHolds.remove(hold)));
    }
    return hold;
  }

  /// The plant-side seam a deadman counter arrives through.
  ///
  /// [applyChanges], the same one `setValue` uses — so a tick is a value
  /// arriving and nothing else. See [StateManHoldHarness.applyHoldTick] for
  /// why it does not check that a hold was engaged.
  @override
  void applyHoldTick(String key, int counter) =>
      applyChanges({key: DynamicValue(value: counter)});

  /// Ends every live hold, without waiting for the release writes.
  ///
  /// Not awaited on purpose: with [stallWrites] armed a release write never
  /// answers, and a `dispose` that waited for one would hang the test rather
  /// than stop the machine. The handle is released the instant this is
  /// called — the counter stops there, which is the whole safety property —
  /// and the write's outcome is informational.
  void _releaseHolds(HoldEnded reason) {
    for (final hold in List<HoldHandle>.of(_liveHolds)) {
      unawaited(
          hold.release(reason: reason).then((_) {}, onError: (Object _) {}));
    }
    _liveHolds.clear();
  }

  /// The single seam every upstream write attempt passes through.
  ///
  /// [_attempt] is called here and in no other place, which is the whole
  /// design: a retry added anywhere in a future implementation has to come
  /// back through this method to reach the device, so it becomes visible to
  /// [upstreamWriteAttempts] and therefore to the contract. A retry that could
  /// route around the counter would be a retry no test could see, and a write
  /// re-sent invisibly is a machine actuated twice on one operator decision.
  ///
  /// Overridable for the same reason [applyChanges] is: a variant that
  /// demonstrates what a well-meaning retry wrapper costs should have to break
  /// exactly this one method and inherit everything else.
  Future<WriteResult> attemptUpstreamWrite(
    String cmd,
    String key,
    Object? value, {
    Object? expected,
  }) async {
    _attempt(cmd);

    if (_readOnlyKeys.contains(key)) {
      return _refuse(
          cmd,
          key,
          const WriteReason('not_writable',
              message: 'the device does not accept writes to this key',
              status: 'Bad_NotWritable'));
    }

    // Compare-and-set. A stale expectation is a refusal, not a failure: the
    // value moved under the operator while the dialog was open, which is
    // ordinary and worth telling them about in those words.
    final cached = _store.peek(key);
    if (expected != null && cached?.value != expected) {
      return _refuse(
          cmd,
          key,
          WriteReason('value_changed',
              message: 'expected $expected, the key holds ${cached?.value}'));
    }

    final reason = _nextWriteReason;
    if (reason != null) {
      final unknown = _nextWriteUnknown;
      _nextWriteReason = null;
      _nextWriteUnknown = false;
      return unknown ? _loseTrack(cmd, key, reason) : _refuse(cmd, key, reason);
    }

    if (_writesStalled) {
      // It has gone upstream — that is why the attempt is already counted —
      // and nothing has come back. The badge stays on until something settles
      // it.
      final parked = _StalledWrite(cmd, key, value);
      _stalledWrites.add(parked);
      return parked.settled.future;
    }

    if (writeLatency > Duration.zero) await Future<void>.delayed(writeLatency);
    return _applyWrite(cmd, key, value);
  }

  /// Records one upstream attempt for [cmd].
  ///
  /// Deliberately trivial and deliberately private: the count only means
  /// anything if there is exactly one thing that can increment it.
  void _attempt(String cmd) =>
      _writeAttempts[cmd] = (_writeAttempts[cmd] ?? 0) + 1;

  /// The device took the write; the store shows what it now holds.
  ///
  /// The readback, not the written value, and they differ whenever the device
  /// has an opinion — a PLC clamping a setpoint to its configured maximum is
  /// the ordinary case. Construction still sanitizes, but nothing non-finite
  /// reaches here through [write] any more: it is refused at the top of that
  /// method, before an id is minted. What the sanitizing covers now is a
  /// readback staged by [clampNextWrite] — a lever, not an operator action —
  /// which must not be allowed to detonate the frame it would travel in.
  ///
  /// The readback is applied through [applyChanges], so it counts as an
  /// arrival and resets the freshness clock: the number on screen after a
  /// write is as young as the write.
  WriteResult _applyWrite(String cmd, String key, Object? value) {
    final readback = _hasNextReadback ? _nextReadback : value;
    _hasNextReadback = false;
    _nextReadback = null;

    final held = DynamicValue(value: readback);
    _pendingRestore.remove(key);
    applyChanges({key: held});
    return WriteApplied(cmd,
        readback: held.value, at: DateTime.now().millisecondsSinceEpoch);
  }

  /// The device said no. A successful call carrying bad news.
  WriteResult _refuse(String cmd, String key, WriteReason reason) {
    _clearWritePending(key);
    return WriteRejected(cmd, reason,
        at: DateTime.now().millisecondsSinceEpoch);
  }

  /// Nobody knows. The PLC may have applied it.
  WriteResult _loseTrack(String cmd, String key, WriteReason reason) {
    _clearWritePending(key);
    return WriteUnknown(cmd, reason);
  }

  /// Puts the in-flight badge on [key]'s current value.
  ///
  /// Band comparison rather than an unconditional set, and never
  /// [Quality.worst]: the badge is a *good*-band code, so stamping it onto a
  /// stale or comm-faulted value would launder a value nobody has heard about
  /// into a healthy one — a write would then be a way of making a dead tag
  /// look alive. Where the value is already worse than good, the worse fact
  /// stays on screen and the write proceeds regardless.
  ///
  /// Applied through [_degrade] rather than [applyChanges]: a write starting
  /// is not news from upstream, and resetting the freshness clock here would
  /// let a page keep itself looking current by writing to itself.
  void _markWritePending(String key) {
    final cached = _store.peek(key);
    if (cached == null) return;
    if (cached.quality.band > Quality.goodWritePending.band) return;
    _pendingRestore[key] = cached.quality;
    _degrade({key: cached.copyWith(quality: Quality.goodWritePending)});
  }

  /// Takes the in-flight badge back off, restoring what was there before.
  ///
  /// Only when the badge is still the thing on the value: something else may
  /// have degraded the key while the write was out — a link loss, the
  /// freshness sweep — and putting the pre-write quality back over that would
  /// report a dead link as healthy.
  void _clearWritePending(String key) {
    final previous = _pendingRestore.remove(key);
    if (previous == null) return;
    final cached = _store.peek(key);
    if (cached == null || cached.quality != Quality.goodWritePending) return;
    _degrade({key: cached.copyWith(quality: previous)});
  }

  /// Settles every write that is still out as an outcome nobody knows.
  ///
  /// Used by both endings a write in flight can meet: the link dropping and
  /// the source being disposed. Neither is evidence the PLC did not take it.
  void _loseTrackOfWritesInFlight(WriteReason reason) {
    if (_stalledWrites.isEmpty) return;
    final parked = List<_StalledWrite>.of(_stalledWrites);
    _stalledWrites.clear();
    for (final write in parked) {
      write.settled.complete(_loseTrack(write.cmd, write.key, reason));
    }
  }

  // ------------------------------------------------------------ write levers

  /// The device refuses the next write, for [reason].
  ///
  /// With [unknown] it instead loses track of it — a PLC timeout. The two are
  /// separate arguments rather than separate methods because the difference
  /// between them is the single most consequential distinction on this path,
  /// and a call site that has to name it is a call site that has thought about
  /// it.
  @override
  void failNextWrite(WriteReason reason, {bool unknown = false}) {
    _nextWriteReason = reason;
    _nextWriteUnknown = unknown;
  }

  /// The next write is taken, but the device ends up holding [readback].
  ///
  /// A setpoint clamped to a configured maximum. This is what makes "applied
  /// means applied *and read back*" a testable difference rather than a
  /// slogan: with the readback always equal to the written value, a source
  /// that merely echoes is indistinguishable from one that confirms.
  @override
  void clampNextWrite(Object? readback) {
    _nextReadback = readback;
    _hasNextReadback = true;
  }

  /// Writes go upstream and no answer comes back — Phase 2's `blackhole`.
  ///
  /// The in-flight window held open, so a case can look at it without racing
  /// a timer. Idempotent.
  @override
  void stallWrites() => _writesStalled = true;

  /// How many writes are parked upstream right now, awaiting an answer.
  ///
  /// The read side of [stallWrites], and it exists for one caller: a harness
  /// that has to cut the upstream link *while a write is genuinely out*. Driven
  /// directly that needs no observable, because `api.write(...)` has already
  /// reached this object by the time the next line of the case runs. Behind a
  /// gateway it does not — the call is still crossing a socket — so a case that
  /// drops the link on the following line drops it before the plant has ever
  /// seen the write, and then settles nothing, and the write parks forever
  /// against a stall nobody will release.
  ///
  /// Exposed as a count rather than a bool so a harness can tell "the write I
  /// am waiting for has landed" from "some write is out", and read-only because
  /// nothing outside this class may park or settle one.
  int get writesInFlight => _stalledWrites.length;

  /// Ends the stall and settles everything parked by it.
  ///
  /// Corresponds to the proxy's `flush`, with one deliberate divergence: this
  /// also ends the stall, where `flush` empties the buffer and leaves the mode
  /// armed. A lever that silently stays on is how a later case fails for a
  /// reason three cases away; a case that wants to stall again says so.
  ///
  /// No second [_attempt]: these writes were counted when they went out. They
  /// are being answered, not re-sent.
  @override
  void releaseWrites({bool applied = true}) {
    _writesStalled = false;
    final parked = List<_StalledWrite>.of(_stalledWrites);
    _stalledWrites.clear();
    for (final write in parked) {
      write.settled.complete(applied
          ? _applyWrite(write.cmd, write.key, write.value)
          : _loseTrack(
              write.cmd,
              write.key,
              const WriteReason('plc_timeout',
                  message: 'the device never answered the write')));
    }
  }

  /// Whether the device permits writes to [key].
  @override
  void setReadOnly(String key, bool readOnly) {
    if (readOnly) {
      _readOnlyKeys.add(key);
    } else {
      _readOnlyKeys.remove(key);
    }
  }

  @override
  int upstreamWriteAttempts(String cmd) => _writeAttempts[cmd] ?? 0;

  @override
  /// In mint order — the set is insertion-ordered, so this is still a
  /// history and not merely a membership test.
  List<String> get mintedCmds => List<String>.unmodifiable(_mintedCmds);

  // ---------------------------------------------------------- data services

  /// The four sub-APIs, each a real in-memory implementation.
  ///
  /// Held as their concrete types so [seedTimeseries] can reach the one lever
  /// the wire surface deliberately lacks, and exposed below as the interface
  /// types — which is what lets a sabotage variant override a getter with a
  /// wrapper without having to reimplement the service it damages.
  final FakeBrowse _browse;
  final FakeTimeseries _timeseries;
  final FakeHistoryViews _historyViews;
  final FakePreferences _preferences;

  @override
  BrowseApi get browse => _browse;

  @override
  TimeseriesApi get timeseries => _timeseries;

  @override
  HistoryViewApi get historyViews => _historyViews;

  @override
  PreferencesApi get preferences => _preferences;

  // ------------------------------------------------------- the access families
  //
  // A real in-memory reference implementation of all four families, added by
  // plan 17-05 (17-03b left these refusing until a contract case existed to
  // judge them). The session it consults is swapped through the test-only
  // [actAs] lever below, exactly as the value levers swap the plant's readings.

  final FakeAccessServices _access;

  @override
  AccessTemplateApi get accessTemplates => _access;

  @override
  AccessAdminApi get accessAdmin => _access;

  @override
  AuditApi get audit => _access;

  @override
  BackendConfigApi get backendConfig => _access;

  // -------------------------------------------------- the access control lever

  @override
  void actAs(AccessSession session) => _access.actAs(session);

  @override
  List<String> get accessStoreWrites => _access.writes;

  @override
  String? storedPasswordFor(String subject) =>
      _access.storedPasswordFor(subject);

  /// Records samples, as the gateway's recorder would.
  ///
  /// Routed to the seeded store rather than through [timeseries], so a variant
  /// that wraps the query path in something dishonest is still seeded with the
  /// truth — otherwise a sabotage would be judged against data it had already
  /// had a chance to alter.
  @override
  void seedTimeseries(String tableName, List<TimeseriesData> points) =>
      _timeseries.seed(tableName, points);
}

/// A write that has gone upstream and had no answer.
///
/// It carries what it needs to be settled later — by [FakeStateMan.releaseWrites],
/// by a link drop, or by disposal — and nothing else. In particular it does
/// not carry an attempt count: the attempt was made and counted when the write
/// went out, and settling it is an answer arriving, not a second send.
final class _StalledWrite {
  final String cmd;
  final String key;
  final Object? value;
  final settled = Completer<WriteResult>();

  _StalledWrite(this.cmd, this.key, this.value);
}
