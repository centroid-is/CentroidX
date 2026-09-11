/// Whether the panel is still hearing from the gateway at all — one deadline
/// for the whole link, restarted by anything that arrives on it.
///
/// Source: 04-RESEARCH Finding 5. The gateway's fan-out was measured at a dead
/// flat **50.0 ms** — 121 tick notifications in 7001 ms, inter-tick deltas
/// `[51, 50, 50, 49, 50, 51, …]`, no drift, no outliers — with a production
/// default period of 100 ms, and **zero update frames** in that window because
/// nothing in the plant changed. The tick alone is the liveness signal.
///
/// **Why no number here is derived from that measurement.** Reading CLI-04's
/// "3× tick" literally against the measured cadence gives a 150–300 ms
/// deadline, and then one garbage collection pause on the panel, or one Wi-Fi
/// retransmit on the plant WAN, greys every value on the screen at once while
/// the gateway is perfectly healthy. Grey that cries wolf is grey the operator
/// stops reading. So the *link* deadline is [ClientConfig.freshnessDeadline] —
/// a configured duration, default 3 s — and nothing derives it from the
/// transport cadence.
///
/// The cadence itself the client does now learn: `hello` advertises
/// `capabilities.tickMs` (it returned `capabilities: {}` when Finding 5
/// measured it; the gateway has sent it since 04-06). [learnedTickMs] takes
/// it, and it is consumed in exactly one place for exactly one purpose — the
/// *per-subscription* limit, which is a statement about how often the plant
/// re-evaluates a page rather than about how long the socket may go quiet.
/// Confusing the two is what 04-REVIEW WR-08 was.
///
/// **One timer, not one per subscription** (Finding 5's timer discipline). N
/// timers on a 1500-key page is N cancellations to get right on every
/// reconnect, and the one that is missed fires into a torn-down page. And the
/// reset comes from frames, never from socket state: `readyState` lies after
/// an OS sleep (STACK), so liveness is what arrived, not what the socket says
/// about itself.
///
/// What breaks in the plant without this file: silence is ambiguous. A socket
/// half-opened over a sleeping NAT looks exactly like a quiet plant, and the
/// operator reads a five-minute-old tank level as current. Freshness is the
/// product.
///
/// ---
///
/// **The second half — the subscriptions, and no timers at all.** [sawTick]
/// records each `SubTick.evaluatedAt` and subtracts; nothing in that half
/// schedules anything. It exists for F25 (04-RESEARCH Finding 3), the dead
/// subscription on a live socket: ticks keep arriving, the link is provably
/// up, and one subscription's plant-side source has stopped evaluating. The
/// link watchdog above cannot see that — every frame it needs is still
/// landing — so a value the PLC stopped producing would render as current
/// forever.
///
/// That fault is **the plant's, not the stream's** (the 04-CONTEXT ruling), so
/// per-subscription staleness never triggers a resync. This class has no
/// collaborator it could ask and no way to express the request: tearing down a
/// healthy subscription set because one tag went quiet is how a single dead
/// PLC point takes out an entire panel, repeatedly, for as long as the tag
/// stays dead.
///
/// The two halves keep separate state and separate methods because CLI-04's
/// entire point is that the operator can tell three states apart: the link is
/// gone, this one value is not being evaluated, everything is fine.
///
/// **Whose clock.** Per-subscription age is measured in the *gateway's* time,
/// never the panel's. On a tick that is free — `TickParams.serverTime` and
/// `SubTick.evaluatedAt` are both server wall-clock epoch ms, verified live in
/// 04-RESEARCH Finding 5b. Between ticks the gateway's clock has to be
/// *estimated*, and [serverNowMs] is that estimate. It is built from an anchor
/// pair — one gateway instant against one reading of this panel's **monotonic**
/// elapsed clock — and it never reads the panel's wall clock at all.
///
/// **Why not the wall clock and an offset** (07-REVIEW CR-01). The shape this
/// replaced converted `DateTime.now()` into server time with the offset
/// captured at `hello`, which was correct exactly as long as the two clocks'
/// relationship stayed what it was at the handshake. Nothing maintained that:
/// the offset was captured once per connection, and 07-08b's heartbeat turned
/// connections from six-second things into multi-day ones. An NTP correction on
/// a fish-factory panel with a dead CMOS battery (`clock_offset.dart:19-21`)
/// then moved every verdict by the whole step — backwards, a subscription whose
/// plant-side source had genuinely stopped read **fresh**, which is the one
/// thing CLAUDE.md's Core Value forbids; forwards, the grey plant CLI-05 rules
/// out. A `Stopwatch` cannot step, so neither can the verdict.
///
/// **Why the anchor is re-derived from ticks, and why not from every tick.**
/// A monotonic clock does not step but it does drift — tens of ppm against the
/// gateway's disciplined clock is seconds a day, and the limit here is
/// seconds — so the anchor has to follow the gateway over a long connection.
/// Every tick carries `serverTime` and is therefore a sample of it. But a
/// sample is only ever *late*: transit delay makes the gateway look earlier
/// than it is, never later. Adopting every sample would mean a link whose
/// frames are minutes behind re-bases the estimate onto its own backlog and
/// reports the page it is minutes behind on as current — F20's lie, which
/// 07-11 wired this surface to catch. So [_sampleServerClock] adopts a sample
/// that *raises* the estimate unconditionally (a raise can only mean the anchor
/// had fallen behind) and one that lowers it only within one tick period, which
/// is jitter and accumulated drift rather than a link falling behind.
library;

import 'dart:async';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// What arrived from the gateway.
///
/// A vocabulary rather than a bare `sawFrame()` because the distinction is
/// exactly the one the watchdog must *not* make: every one of these proves the
/// link is alive, and an implementation that rescheduled on ticks only would
/// call a plant dead precisely when it was busiest.
enum InboundFrame {
  /// The fixed-cadence heartbeat. On an idle plant it is the only traffic.
  tick,

  /// A subscription update: values actually changed.
  update,

  /// A reply to something this panel asked for.
  rpcResponse,
}

/// Announced when the whole view flips between fresh and stale, and only then.
typedef ViewFreshnessChanged = void Function(bool stale);

/// One deadline for the link, restarted by any inbound frame.
final class FreshnessWatchdog {
  /// Where the deadline comes from. Nothing here invents a duration.
  final ClientConfig config;

  /// Called on transitions only — an indicator that repaints twenty times a
  /// second is an indicator nobody sees change.
  final ViewFreshnessChanged onViewFreshnessChanged;

  /// What to *do* about a link that has gone quiet, as opposed to what to
  /// display about it.
  ///
  /// Assigned by the supervisor after construction, because this object is
  /// built by the client above and handed down (04-07's ownership rule). Left
  /// null the watchdog only observes, which is the state 04-REVIEW CR-06
  /// found: the expiry flipped a bool, nothing closed the peer, nothing
  /// touched `LinkState`, and a half-open socket read `ready` with frozen
  /// values for as long as the panel stayed on.
  void Function()? onQuiet;

  /// The gateway's advertised fan-out period, from `hello`'s capabilities.
  ///
  /// Null until a handshake has answered, and null forever against a gateway
  /// that advertises none. See [_subscriptionLimitMs] for what it buys.
  int? get tickMs => _tickMs;
  int? _tickMs;

  /// Records the cadence the gateway announced at [tickMs].
  ///
  /// **The link deadline is deliberately not derived from it** and never will
  /// be — that is the 04-CONTEXT ruling this file's doc argues at length. What
  /// the cadence is for is the *per-subscription* limit, which is a statement
  /// about how often the plant re-evaluates a page and has nothing to do with
  /// how long the socket may go quiet (04-REVIEW WR-06, WR-08).
  void learnedTickMs(Object? advertised) {
    final ms = advertised is num && advertised.isFinite && advertised > 0
        ? advertised.toInt()
        : null;
    _tickMs = ms;
  }

  /// The one timer. Not `late`, not a list: the type is the design.
  Timer? _deadline;

  bool _viewIsStale = false;
  bool _disposed = false;

  /// Last known `evaluatedAt` per subscription id, in the gateway's clock.
  final Map<String, int> _evaluatedAt = <String, int>{};

  /// The verdict from the most recent tick.
  Set<String> _staleSubs = const <String>{};

  /// The gateway instant this panel's clock is anchored to, and the reading of
  /// [_monotonic] taken at the same moment. Null until the first anchor.
  int? _serverAnchorMs;
  int? _localAnchorMs;

  /// Elapsed milliseconds from a clock that cannot be stepped.
  ///
  /// Injected only by the suite, which needs to move it without waiting.
  final int Function() _monotonic;

  FreshnessWatchdog({
    required this.config,
    required this.onViewFreshnessChanged,
    int Function()? monotonic,
  }) : _monotonic = monotonic ?? _elapsedClock();

  /// A fresh monotonic clock, one per watchdog. Only differences are ever read
  /// from it, so where it starts does not matter.
  static int Function() _elapsedClock() {
    final elapsed = Stopwatch()..start();
    return () => elapsed.elapsedMilliseconds;
  }

  /// Whether the link has gone [ClientConfig.freshnessDeadline] without a
  /// single frame of any kind.
  bool get viewIsStale => _viewIsStale;

  /// 0 before the first frame and after [dispose], 1 while armed — never more,
  /// whatever else the client is tracking. The suite asserts this because the
  /// count is the design, not an implementation detail.
  int get debugTimerCount => _deadline == null ? 0 : 1;

  /// How many subscriptions this watchdog has an `evaluatedAt` for.
  ///
  /// Zero means [staleSubscriptionsNow] iterates an empty map and returns the
  /// empty set **however long the link stays quiet** — correctly, because the
  /// panel has not been told what to age. `evaluatedAt` arrives on `tick`
  /// frames only, so a case that starves the link before the first tick can
  /// never reach a stale verdict and will wait out any budget it is given.
  ///
  /// `debug` for the same reason [debugTimerCount] is: it is a precondition a
  /// test establishes, never a thing a screen renders. It exists because
  /// [serverNowMs] is not that precondition — the clock is anchored at `hello`
  /// (`connection_supervisor.dart:712`, the only caller of
  /// [anchorServerClock]), which is several frames earlier, so a case waiting
  /// on the clock has established less than its name suggests.
  int get debugEvaluatedSubCount => _evaluatedAt.length;

  /// Records an inbound frame of any [kind] and restarts the link deadline.
  ///
  /// Runs on every frame — twenty times a second on the measured cadence — so
  /// it stays a cancel and a reschedule and nothing else.
  ///
  /// **It does not clear the badge, and that is the whole of 16-10 / S9.**
  /// This method used to call [_becomeFresh] as well, which made one call do
  /// two jobs whose difference is invisible until a resync takes real time: a
  /// frame arriving proves the *link* is alive, and proves nothing whatever
  /// about whether the values on the screen came from it. The `hello` response
  /// is a frame, and it answers seconds before the first snapshot lands. See
  /// [viewBecameFresh] for where the badge moved to and why.
  void sawFrame(InboundFrame kind) {
    if (_disposed) return;
    _deadline?.cancel();
    _deadline = Timer(config.freshnessDeadline, _linkWentQuiet);
  }

  /// The view is now showing data from the current connection.
  ///
  /// Called by the supervisor from `_enter(LinkState.ready)` and from nowhere
  /// else — a state reached, by construction, only after `ResyncEngine.onHello`
  /// has returned with every page's store cleared and its snapshot adopted.
  ///
  /// **Why this is not [sawFrame]'s job** (16-10, finding S9). The badge is the
  /// one surface an operator uses to decide whether to trust the screen, and it
  /// used to clear on any inbound frame. The order it ran in was: enter
  /// `resyncing`, await `hello`, **clear the badge**, then subscribe each page
  /// in turn and adopt its snapshot, then enter `ready`. Every page held its
  /// pre-outage values under [Quality.good] for the whole of that middle
  /// stretch, with a badge saying the view was fresh. After a sixty-second
  /// outage that is a minute-old number displayed as current, and not for a
  /// millisecond of it: the snapshots land one page at a time, each behind its
  /// own subscribe round trip, on precisely the multi-page slow link this
  /// client was designed for. 16-01 widened that window further, deliberately
  /// and correctly, by giving snapshots their own deadline instead of a ping's
  /// — a **flat** `ClientConfig.snapshotDeadline` of 15 s.
  ///
  /// Flat, and not the payload-scaled `base + perKey × keys.length` that
  /// 16-01's own plan and CONTEXT specified. That was overruled at
  /// implementation and ratified 2026-09-07, for the reason `a192c504` gives:
  /// this is not the link-death detector and does not need to scale like one.
  /// A socket that has gone silent is already torn down in three seconds by
  /// the watchdog below, resyncing state included; 15 s bounds only the
  /// narrower failure `deadline.dart` exists for — a peer answering everything
  /// else while one request never settles. The cost is that a three-key page
  /// waits as long as a fifteen-hundred-key page, which is a slower failure,
  /// not a wrong one.
  ///
  /// This paragraph previously asserted the scaled form as fact and was wrong
  /// about the shipped code for a day; it is written out in full here because
  /// a comment that describes a design nobody built is how the next reader
  /// gets misled.
  ///
  /// **The promise changed, not just the timing.** The badge used to mean "a
  /// frame arrived"; it now means "this view is showing data from the current
  /// connection". Those are different statements and the old one was the
  /// finding.
  ///
  /// **The stale direction did not move.** [_linkWentQuiet] is a different
  /// property on a different timer and `stall_gate_test.dart:41-49` documents
  /// it. Nor did what the badge *measures*: it stays link-level and is never
  /// coupled to store contents — `latency_gate_test.dart:146-161` is emphatic
  /// that this verdict and [staleSubscriptions] are deliberately independent,
  /// and coupling them would turn every slow-moving tag into a grey panel.
  void viewBecameFresh() {
    if (_disposed) return;
    _becomeFresh();
  }

  /// ---------------------------------------------------------------------
  /// Part two: the subscriptions. Arithmetic only — nothing below this line
  /// schedules anything, and nothing below it can ask the stream to be torn
  /// down and rebuilt. See the library doc: the fault is the plant's.
  /// ---------------------------------------------------------------------

  /// Records a tick: restarts the link deadline **and** re-judges every
  /// subscription against the gateway's own clock.
  ///
  /// It calls [sawFrame] itself rather than trusting the caller to make two
  /// calls per tick. A caller that had to remember both would eventually
  /// forget one, and the forgotten one greys a running plant.
  void sawTick(TickParams tick) {
    if (_disposed) return;
    sawFrame(InboundFrame.tick);
    _sampleServerClock(tick.serverTime);
    for (final entry in tick.subs.entries) {
      _evaluatedAt[entry.key] = entry.value.evaluatedAt;
    }
    // `tick.serverTime` and `evaluatedAt` are both the gateway's wall clock
    // (Finding 5b), so this comparison never touches the panel's clock.
    _staleSubs = _staleAt(tick.serverTime);
  }

  /// Subscriptions whose plant-side source had stopped evaluating as of the
  /// last tick.
  ///
  /// Distinct from [viewIsStale] on purpose: this set can be non-empty while
  /// the link is provably healthy, which is the whole of F25 — the gateway is
  /// fine, one PLC tag is not, and the operator needs to be told which.
  Set<String> get staleSubscriptions => _staleSubs;

  /// The same verdict for the one id a widget renders.
  bool isSubscriptionStale(String subId) => _staleSubs.contains(subId);

  /// Anchors the gateway's clock at a handshake.
  ///
  /// `hello` is the one moment this panel knows a gateway instant whose
  /// transit delay is half a round trip rather than a queue — see the library
  /// doc on why a tick is a worse sample than this one.
  void anchorServerClock(int serverTimeMs) {
    if (_disposed) return;
    _serverAnchorMs = serverTimeMs;
    _localAnchorMs = _monotonic();
  }

  /// The gateway's clock now, estimated from the anchor and locally elapsed
  /// time. Null until something has anchored it.
  ///
  /// Never a function of the panel's wall clock: see the library doc's "whose
  /// clock", and 07-REVIEW CR-01 for what it cost when it was.
  int? get serverNowMs {
    final serverAt = _serverAnchorMs;
    final localAt = _localAnchorMs;
    if (serverAt == null || localAt == null) return null;
    return serverAt + (_monotonic() - localAt);
  }

  /// The live verdict: every subscription aged against [serverNowMs].
  ///
  /// Empty before the first anchor, which is a client that has not completed a
  /// handshake and has no subscriptions to judge either.
  ///
  /// **Live, because a saturated link keeps delivering old frames**
  /// (07-RESEARCH §B.4): [staleSubscriptions], the verdict stored at the last
  /// tick, compares two fields of one delayed frame, agrees with itself for
  /// ever, and renders a minute-behind page as current.
  Set<String> staleSubscriptionsNow() {
    final now = serverNowMs;
    return now == null ? const <String>{} : _staleAt(now);
  }

  /// The same live verdict for the one id a widget renders.
  ///
  /// One lookup rather than a set built and thrown away, because this is the
  /// per-rebuild path (07-REVIEW IN-01).
  bool isSubscriptionStaleNow(String subId) {
    final now = serverNowMs;
    if (now == null) return false;
    final at = _evaluatedAt[subId];
    return at != null && now - at > _subscriptionLimitMs;
  }

  /// Forgets a subscription — an unsubscribe, or a snapshot that dropped it.
  ///
  /// Without this, an id that came and went keeps its last `evaluatedAt`
  /// forever and goes on raising a fault about a value no screen displays.
  void forgetSubscription(String subId) {
    _evaluatedAt.remove(subId);
    _staleSubs = _staleSubs.where((id) => id != subId).toSet();
  }

  /// How long a subscription may go without being re-evaluated before it is
  /// reported stale.
  ///
  /// **Not the link deadline** (04-REVIEW WR-08). This used to be
  /// [ClientConfig.freshnessDeadline], which `client_config.dart` documents as
  /// the horizon for the *socket*: one number for the whole link. A
  /// subscription is a page of tags whose plant-side evaluation cadence has
  /// nothing to do with the socket's, so a 3 s limit marks every
  /// slowly-evaluated page permanently stale — the grey that cries wolf this
  /// file argues against two paragraphs above its own line.
  ///
  /// So it is the gateway's own advertised cadence times
  /// [ClientConfig.subscriptionStalenessMultiple], which is the only thing
  /// about the plant's evaluation rate the client can actually learn. Floored
  /// at the link deadline, because a per-subscription verdict that fired
  /// sooner than "the link is gone" would report a dead tag on a dead link and
  /// send someone to look at the wrong thing.
  int get _subscriptionLimitMs {
    final linkMs = config.freshnessDeadline.inMilliseconds;
    final tick = _tickMs;
    if (tick == null) return linkMs;
    final derived = (tick * config.subscriptionStalenessMultiple).round();
    return derived > linkMs ? derived : linkMs;
  }

  /// Takes one tick's `serverTime` as a sample of the gateway's clock.
  ///
  /// **Asymmetric on purpose**, and the asymmetry is the whole of the library
  /// doc's third paragraph. Transit delay only ever makes a sample *late*, so:
  ///
  ///  * a sample that says the gateway is **later** than this anchor predicts
  ///    can only mean the anchor had fallen behind — adopted, always;
  ///  * a sample that says it is **earlier**, by no more than one tick period,
  ///    is jitter or the drift a monotonic crystal accumulates against a
  ///    disciplined clock — adopted, so a multi-day connection tracks;
  ///  * a sample that says it is earlier by *more* than that is a link falling
  ///    behind, and adopting it would re-base the estimate onto the backlog and
  ///    report the page this panel is minutes behind on as current. Refused —
  ///    which is what makes the F20 verdict survive this change.
  ///
  /// The last rule has one escape: a shortfall past
  /// [ClientConfig.implausibleClockThreshold] is not a backlog any live session
  /// would survive, it is the gateway's own clock being corrected backwards.
  /// Refusing that for ever would leave the estimate permanently ahead and grey
  /// a healthy plant, so it re-anchors.
  void _sampleServerClock(int serverTimeMs) {
    final localNow = _monotonic();
    final serverAt = _serverAnchorMs;
    final localAt = _localAnchorMs;
    if (serverAt != null && localAt != null) {
      final shortfall = (serverAt + (localNow - localAt)) - serverTimeMs;
      final tolerated = _tickMs ?? 0;
      if (shortfall > tolerated &&
          shortfall <= config.implausibleClockThreshold.inMilliseconds) {
        return;
      }
    }
    _serverAnchorMs = serverTimeMs;
    _localAnchorMs = localNow;
  }

  /// Ages every recorded subscription against an instant in the gateway's
  /// clock. One pass of subtraction; no per-subscription timer exists to
  /// cancel, which is why a 1500-key page costs one timer in total.
  Set<String> _staleAt(int serverNowMs) {
    final limitMs = _subscriptionLimitMs;
    final stale = <String>{};
    for (final entry in _evaluatedAt.entries) {
      if (serverNowMs - entry.value > limitMs) stale.add(entry.key);
    }
    return stale;
  }

  /// Drops the deadline. Nothing fires afterwards, and later frames are
  /// ignored rather than re-arming a watchdog whose page is gone.
  void dispose() {
    _disposed = true;
    _deadline?.cancel();
    _deadline = null;
    _evaluatedAt.clear();
    _staleSubs = const <String>{};
  }

  void _linkWentQuiet() {
    _deadline = null;
    if (!_viewIsStale) {
      _viewIsStale = true;
      onViewFreshnessChanged(true);
    }
    // And then something is done about it. A link that has gone a whole
    // freshness deadline without a frame of any kind is a link this client
    // should stop believing in — the "detected in seconds" half of CLAUDE.md's
    // first constraint, which a bool nobody reads does not satisfy.
    onQuiet?.call();
  }

  void _becomeFresh() {
    if (!_viewIsStale) return;
    _viewIsStale = false;
    onViewFreshnessChanged(false);
  }
}
