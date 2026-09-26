/// What a checker is allowed to see, stated as two narrow interfaces rather
/// than as a reference to [SoakDriver].
///
/// **Why the indirection exists at all.** A checker that took the driver would
/// be a checker whose positive control needs a composed pipe: five real panels,
/// a real gateway, a real socket and a bound port, for an arm whose entire job
/// is to prove one counter moves. 11-04's acceptance criteria say the controls
/// run "in seconds", and a control that costs ninety is a control somebody
/// eventually stops running. So each checker declares the narrow thing it
/// needs, `SoakDriver` implements both, and a control substitutes one member of
/// one interface and leaves the rest of the composition alone.
///
/// **It is not a fake of the pipe.** [SoakPanelView] is satisfied by a real
/// `RemoteStateMan` in every lane run — the lying decorator in
/// `soak_meta_test.dart` wraps a *live* panel and overrides one verdict. Phase
/// 10's CR-01 is the standing lesson about fakes making a bug idempotent and
/// invisible, and the shape here is chosen so the fake is never the thing under
/// test: what a control replaces is the *answer*, never the stack that produced
/// it.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'applied_write_ledger.dart';
import 'invariant.dart';
import 'soak_event.dart';

// ------------------------------------------------------- the run-end pass

/// A checker with something to say once the storm has played out.
///
/// Two of this phase's invariants are only half continuous. Invariant 1's
/// distribution — *did anything ever go stale, and did anything ever recover* —
/// is a statement about the whole run and cannot be evaluated at 25 ms;
/// invariant 2's *every write is in exactly one of two places* is false at
/// every instant a write is in flight and true only once the run has stopped
/// issuing them. [finish] is where both are asked, and the driver calls it for
/// every registered checker after the last entry and before the verdict block
/// is read, so a distribution failure prints in the same block as the counters
/// that explain it.
abstract interface class SoakRunEndCheck {
  /// Records anything that can only be judged once. Never throws — the same
  /// rule [InvariantChecker.sample] follows, for the same reason.
  void finish();
}

// ------------------------------------------------------------- one panel

/// One panel's operator-facing surface, as a freshness checker reads it.
///
/// Three members and no more, because three is what CLI-04 says an operator can
/// tell apart: the link is gone ([viewIsStale]), this page's plant-side source
/// is not being re-evaluated ([pageIsStale]), and this one value is what it is
/// ([read]). A checker that could reach further would end up asserting against
/// the client's internals rather than against what a widget renders, and the
/// invariant is about the render.
abstract interface class SoakPanelView {
  /// Its position in the herd. Zero is the control.
  int get index;

  /// `panel-N`.
  String get name;

  /// Whether the link has gone a whole freshness deadline without a frame of
  /// any kind — `RemoteStateMan.viewIsStale`.
  bool get viewIsStale;

  /// Whether this panel's one subscription page is being re-evaluated —
  /// `RemoteStateMan.isSubscriptionStale(defaultPageSubscription)`.
  ///
  /// One page rather than a set, because the fixture files every key of every
  /// panel under `defaultPageSubscription`: the panels are constructed with
  /// their whole key list, and `RemoteStateMan.subscribe` is a view of a store
  /// node rather than a second wire subscription.
  bool get pageIsStale;

  /// The value a widget would render for [key], or null if none has arrived.
  DynamicValue? read(String key);
}

// -------------------------------------------------------- what a write did

/// Which side of a write's life one record describes.
enum SoakWriteStage {
  /// The call was made. Nothing is known about its fate yet.
  issued,

  /// `RemoteStateMan.write` returned — the direct path.
  direct,

  /// `onWriteResolved` emitted.
  ///
  /// **This is the only thing that stream carries**, and it is worth knowing
  /// before reading invariant 2: `_settle` is called from `_requeryWriteStatus`
  /// and nowhere else (`remote_state_man.dart:1096-1101`), so the direct
  /// outcome of a write never appears on it. A checker fed by `onWriteResolved`
  /// alone would see only the writes a reconnect had to reconcile, and would
  /// report a floor of a few dozen as though it were the run's whole write
  /// traffic.
  lateResolution,
}

/// One thing that happened to one write, stamped where it happened.
///
/// **The schedule offset is taken by the driver at the instant, not by the
/// checker at its next tick.** A double resolution is diagnosable only against
/// the faults that were armed when it occurred, and 25 ms of sampling lag is
/// enough to put the reading in the next entry's window.
final class SoakWriteRecord {
  const SoakWriteRecord({
    required this.nth,
    required this.cmd,
    required this.panel,
    required this.key,
    required this.value,
    required this.stage,
    required this.at,
    required this.probe,
    this.outcome,
    this.reachedASocket = false,
  });

  /// The run-stable identity: the *n*-th write this run issued.
  final int nth;

  /// The idempotency id. Opaque across runs — see [AppliedWriteLedger].
  final String cmd;

  /// `panel-N`.
  final String panel;

  final String key;
  final Object? value;

  final SoakWriteStage stage;

  /// `applied`, `rejected`, `unknown`, `not_received`, or null at
  /// [SoakWriteStage.issued].
  final String? outcome;

  /// Whether any bytes were offered to a socket for this write.
  ///
  /// **Not a failure when false, and not a loophole in the invariant.** A cmd
  /// that never left the process is removed from `_unresolved` **on purpose**
  /// (`remote_state_man.dart:832-836`): re-querying it on every reconnect for
  /// the rest of the shift is how a panel with a dead link grows an unresolved
  /// set until `writeStatus` is refused for being over `maxKeysPerSubscribe`,
  /// taking the recovery path for the genuine unknowns down with it. A checker
  /// that demanded terminality of such a write would be asserting against that
  /// protection.
  final bool reachedASocket;

  /// The play clock at the instant this was recorded.
  final Duration at;

  /// Whether the driver's write probe issued it, as opposed to a `PanelWrite`
  /// the generator drew.
  final bool probe;

  @override
  String toString() => 'write #$nth $panel $key=$value ${stage.name}'
      '${outcome == null ? '' : ' -> $outcome'}'
      '${stage == SoakWriteStage.direct ? ' (socket=$reachedASocket)' : ''}';
}

// --------------------------------------------------------- the sources

/// What invariant 1 reads.
abstract interface class SoakFreshnessSource {
  /// The run's seed, so a violation can be reproduced from its own text.
  int get seed;

  /// What the run was DECLARED to be — 90 s in the lane, 35 min behind
  /// `RELAY_SOAK`. Every floor scales off this and never off measured elapsed
  /// time (`invariant.dart`'s rule), and it is read from the source rather than
  /// frozen into a checker at construction because a checker is built before
  /// the driver that knows the answer.
  Duration get declaredDuration;

  /// The play clock — the position in the generated timeline right now.
  Duration get scheduleOffset;

  /// Every panel, control first.
  List<SoakPanelView> get panelViews;

  /// The keys a freshness verdict is judged over.
  ///
  /// Includes the `PIPE.` health keys; the checker excludes them **by prefix**,
  /// which is where the exclusion belongs (08-PATTERNS freeze 8). Handing the
  /// checker a pre-filtered list would move the decision here and make the
  /// prefix arm test nothing.
  List<String> get freshnessKeys;

  /// The panel the storm may never aim at.
  int get controlPanelIndex;

  /// How many plant-wide arms the storm has applied so far.
  ///
  /// A gateway restart, a keymapping reload and every upstream arm reach the
  /// control like everybody else — the control's property is *"the storm never
  /// AIMS at it"*, never *"it is never disturbed"*. This counter is what lets
  /// the control's freshness arm be sharp about the panel-targeted half only.
  int get plantWideArmsApplied;

  /// How old a value may be while the panel still renders it fresh.
  Duration get freshnessBudget;

  /// What the soak's own plant is publishing for [key] right now, or null for
  /// a key no link carries.
  ///
  /// **Invariant 1 reads this for one narrow reason and it is not a shortcut
  /// to invariant 3's comparison.** This checker's arrival proxy is a change
  /// in the rendered triple, which is sound only while the premise in
  /// `freshness_honesty.dart` holds — that the plant moves every key every
  /// 250 ms with a number that never repeats. `PlantMutate` breaks it by
  /// design: an override re-emits ONE value every poll cycle for the rest of
  /// the run, so the arrivals continue and the render surface stops being able
  /// to see them. A panel rendering exactly the value a pinned key is being
  /// published with is not showing an old number, whatever the proxy says.
  SoakPlantTruth? plantTruthFor(String key);
}

/// What invariant 2 reads.
abstract interface class SoakWriteSource {
  /// The run's seed, so a violation can be reproduced from its own text.
  int get seed;

  /// What the run was declared to be. Floors scale off this.
  Duration get declaredDuration;

  /// The play clock.
  Duration get scheduleOffset;

  /// Every write event so far, append-only and in order.
  ///
  /// **Pulled by index rather than pushed.** The checker consumes what it has
  /// not seen on each tick, so a checker registered after the first write still
  /// sees it and there is no subscription lifecycle to get wrong across a
  /// redial — which replaces the panel's whole client object
  /// (`GateBFixture.redial`).
  List<SoakWriteRecord> get writeRecords;

  /// Every command every panel still considers in flight, union across the
  /// herd. `RemoteStateMan.debugUnresolvedCmds`.
  ///
  /// **Invariant 4 reads the same counter** (11-05 task 1): it is the
  /// unresolved-write set `long_outage_gate_test.dart` already watches as a
  /// slope. Invariant 2 asks whether a command is in it; invariant 4 asks
  /// whether it grows. Cross-referenced in both docs so a change to one is
  /// read by whoever owns the other.
  List<String> get unresolvedCmds;

  /// Commands still in flight on a client [GateBFixture.redial] replaced.
  ///
  /// **A fourth place a write can be, and it is deliberately not folded into
  /// [unresolvedCmds].** A restore is an application restart (`redial`'s own
  /// doc), so the retired client's set is memory a real restarted panel would
  /// not have. Answering "still outstanding" out of it would satisfy the
  /// invariant with the harness's own bookkeeping rather than with anything an
  /// operator could rely on — the failure invariant 2 exists to catch, wearing
  /// the instrument's clothes.
  ///
  /// What the retired object legitimately is, is the only surviving record of
  /// *what the restart destroyed*. An instrument is required to remember what
  /// the plant forgot; what it must not do is call that memory something it is
  /// not. So these are reported as orphaned, counted in the distribution line,
  /// and never counted as pending.
  ///
  /// Identity and not magnitude — see the note on `_LivePanelLogView` in
  /// `soak_driver.dart` for why invariant 5 sums a count forward across the
  /// same event and this one cannot.
  List<String> get orphanedCmds;

  /// Every client replacement this run performed, in order.
  ///
  /// The **fact**, recorded where `redial` is called, rather than a set
  /// captured at that instant. `SoakDriver.issueWrite` holds the old client
  /// across its `await`, and `redial` is fired un-awaited, so a write still in
  /// flight lands in the retired client *after* any capture would have run. A
  /// record of an event cannot miss a set.
  ///
  /// Read with [orphanedCmds] by whoever is deciding whether a particular
  /// write was orphaned: membership alone is not the question, because a
  /// bucket that admits on membership alone is an exemption nothing constrains.
  List<SoakPanelRestart> get panelRestarts;

  /// What the plant actually applied.
  AppliedWriteLedger get appliedWrites;
}

/// One panel's client being replaced, and when.
final class SoakPanelRestart {
  const SoakPanelRestart({required this.panel, required this.at});

  /// `panel-N`, as [SoakWriteRecord.panel] spells it.
  final String panel;

  /// The play clock at the instant `redial` was called.
  final Duration at;

  @override
  String toString() => '$panel restarted at ${formatSoakOffset(at)}';
}

// ------------------------------------------------ what a checkpoint measured

/// Every structure invariant 4 watches, read at one instant.
///
/// **A whole reading rather than a getter per structure**, and the reason is the
/// one thing a slope detector cannot survive without: the readings in a
/// checkpoint row have to be simultaneous. A checker that pulled ten getters
/// would take ten readings across however long the pulls took, and under a
/// storm that window contains a gateway restart — which is how a row ends up
/// with a session count from before it and a subscription count from after.
///
/// [skips] is what makes a platform skip **visible**. `openSocketCount()` cannot
/// answer on Windows (`fd_count.dart:46`), and the difference between "this
/// structure read zero" and "this structure could not be read here" is the whole
/// of `gate_manifest_test.dart`'s skip audit at one structure's scale. A skipped
/// structure is absent from [plantWide] and present here with the reason the
/// platform gave, in its own words.
///
/// [carriedForward] is the third case, between "read" and "cannot be read here":
/// a structure whose value in [plantWide] is the last one taken rather than a
/// fresh one. Only [openSocketsStructure] is ever in it, and
/// [openSocketCheckpointCadence] says why. It is separate from [skips] because
/// the row still carries a number and the number is still true — it is just not
/// new, and a rule about slopes must not count it as a reading.
final class SoakStructureReading {
  const SoakStructureReading({
    required this.perPanel,
    required this.plantWide,
    this.skips = const <String, String>{},
    this.carriedForward = const <String>{},
  });

  /// Panel index -> structure name -> size. The client-side half.
  final Map<int, Map<String, int>> perPanel;

  /// Structure name -> size, for the server and the process. The half that has
  /// no panel to attribute it to.
  final Map<String, int> plantWide;

  /// Structure name -> why it could not be read on this platform.
  final Map<String, String> skips;

  /// Structures whose value in [plantWide] is carried from an earlier
  /// checkpoint rather than read at this one.
  final Set<String> carriedForward;
}

// -------------------------------------------------------- the structure names

/// The unresolved-write set, per panel — `RemoteStateMan.debugUnresolvedCmds`.
///
/// The structure `long_outage_gate_test.dart` already watches as a slope, and
/// the one invariant 2 caps absolutely at 64. The two readers are deliberate: a
/// ceiling catches the set that exploded, a slope catches the set that never
/// stops climbing, and neither sees what the other does.
const String unresolvedCmdsStructure = 'unresolvedCmds';

/// The uncapped complaint list, per panel — `ResyncEngine.complaints`.
///
/// **Shared with invariant 5.** See the library doc.
const String complaintsStructure = 'complaints';

/// The subscriptions the client judged stale at the last tick, per panel.
///
/// Standing in for the resync engine's private `_inFlight` map — see the
/// library doc for why, and for the fact that it is a substitution.
const String staleSubscriptionsStructure = 'staleSubscriptions';

/// The client's retained `writeStatus` query history, per panel.
///
/// Bounded by construction at `RemoteStateMan._debugHistory` (64), which is why
/// it is worth watching: a structure with a declared cap is the cheapest place
/// to notice that the code enforcing the cap stopped running.
const String writeStatusQueriesStructure = 'writeStatusQueries';

/// Settled write outcomes the gateway is still vouching for.
///
/// `WriteOutcomeLog.recordedOutcomes` (`write_outcome_log.dart:167`). **This one
/// proves the prune runs.** The log sweeps its horizon on `record`, `entryFor`
/// and `prune` and nowhere else, so a run in which this climbs past the TTL's
/// worth of writes is a run in which the sweep stopped.
const String recordedOutcomesStructure = 'recordedOutcomes';

/// Live sessions on the gateway — `SessionRegistry.sessionCount`.
const String sessionsStructure = 'sessions';

/// Every live session's subscriptions, summed —
/// `SessionSubscriptionCounts.subscriptionCount`.
const String subscriptionsStructure = 'subscriptions';

/// Every live session's attached listeners, summed —
/// `SessionSubscriptionCounts.listenerCount`.
///
/// Derived on read rather than tallied, which is the property that makes it
/// worth asserting: *"a maintained count can drift from the thing it counts,
/// and a teardown assertion reading a drifted tally is an assertion that passes
/// while the listeners are still attached"* (`subscription_registry.dart:276`).
const String listenersStructure = 'listeners';

/// How many panels currently render `PIPE.link_degraded` as true.
///
/// **The send-buffer clause's observable, and it is a verdict rather than a
/// depth — deliberately, because the depth is not reachable.**
/// `ConflatingSendBuffer` lives on a private `_Connection` inside
/// `relay_server.dart`; nothing public hands it out, and adding a getter would
/// be a change to `tfc_relay_server/lib`, which this plan does not make. What
/// the gateway *does* publish is `_SessionProbe.linkDegraded`, which is the
/// composition of both numbers the clause is about:
/// `pendingCount > (peakThreshold ?? maxPending) || pendingBytes >
/// maxPendingBytes` (`relay_server.dart:896-903`).
///
/// **`pendingBytes` counts the priority lane only** — `_priorityBytes`,
/// `send_buffer.dart:104` — so it is not total egress and a checker reporting
/// it as a byte count would be overstating what it measured (08-PATTERNS §6).
/// Folded into the verdict here, it says the one thing an operator needs: this
/// session is shedding.
///
/// F27c already asserts the buffer itself, directly, as a unit arm with a hand
/// clock. That is where the depth evidence lives; this is the composed run's
/// view of the same thing.
const String degradedPanelsStructure = 'degradedPanels';

/// Open sockets in this process — `openSocketCount()`.
///
/// Skipped **by name** where `canCountOpenSockets` is false (`fd_count.dart:46`,
/// Windows), never by silence: the skip reason travels in the checkpoint row's
/// `skips` map and prints in the verdict block, because a descriptor clause
/// that quietly evaporates on one platform is the failure
/// `gate_manifest_test.dart`'s skip audit exists to catch.
const String openSocketsStructure = 'openSockets';

/// Every structure this invariant watches, in the order a row prints them.
///
/// A named list rather than "whatever the reading happened to contain": a
/// structure silently dropped from the reading is a structure nobody is
/// watching any more, and it would otherwise look exactly like a structure that
/// stayed flat. `soak_meta_test.dart` asserts the row's key set against this.
const List<String> boundedMemoryStructures = <String>[
  unresolvedCmdsStructure,
  complaintsStructure,
  staleSubscriptionsStructure,
  writeStatusQueriesStructure,
  recordedOutcomesStructure,
  sessionsStructure,
  subscriptionsStructure,
  listenersStructure,
  degradedPanelsStructure,
  openSocketsStructure,
];

/// The four that are read from a panel's own client.
const List<String> boundedMemoryPanelStructures = <String>[
  unresolvedCmdsStructure,
  complaintsStructure,
  staleSubscriptionsStructure,
  writeStatusQueriesStructure,
];

/// The six that belong to the gateway or to the process.
const List<String> boundedMemoryPlantWideStructures = <String>[
  recordedOutcomesStructure,
  sessionsStructure,
  subscriptionsStructure,
  listenersStructure,
  degradedPanelsStructure,
  openSocketsStructure,
];

/// How many checkpoints apart the descriptor count is actually read.
///
/// **Six, i.e. every thirty seconds, and it is the only structure on a cadence
/// of its own.** `openSocketCount()` on macOS is `Process.runSync('lsof', …)`
/// (`fd_count.dart:78`) — a **synchronous** subprocess that blocks the isolate
/// while it runs. Measured on this machine: **46–62 ms per call, six calls,
/// median 50 ms.** At every checkpoint that is a 1 % duty cycle of the whole run
/// spent with the event loop stopped, inside a soak whose entire subject is what
/// the pipe does under stress — an instrument perturbing its own measurement,
/// which is 07-RESEARCH trap 15 in CPU rather than in memory.
///
/// Every sixth checkpoint takes it to 0.17 %. The cost is resolution on one
/// series: descriptor leaks are judged at 30 s rather than 5 s, which in the
/// ninety-second lane leaves three readings and in the thirty-five-minute run
/// leaves seventy. **Three readings is not "not judged there", which this
/// comment used to say.** `openSockets` has no entry in
/// `boundedMemorySettleOverrides`, so its settle is the default 2 and `settled`
/// is `readings > settleCheckpoints` — the third reading makes the series
/// settled and the RATIO rule does judge it in the lane. Only the monotone rule
/// cannot fire there, because its own override is 10. The carry-forward line
/// in the ledger is right about the monotone rule and this text overstated it
/// to the whole series. A descriptor leak is a long-run question and seventy readings
/// is plenty of slope; a five-second one was never the point.
///
/// On the checkpoints in between, the last value is carried into the row so the
/// row shape never changes, and the structure is named in
/// [SoakStructureReading.carriedForward] so the checker does not feed a repeated
/// reading into a rule about slopes.
const int openSocketCheckpointCadence = 6;

/// What invariant 4 reads.
abstract interface class SoakStructureSource {
  /// The run's seed, so a violation can be reproduced from its own text.
  int get seed;

  /// What the run was declared to be. Floors scale off this.
  Duration get declaredDuration;

  /// The play clock.
  Duration get scheduleOffset;

  /// The panel the storm may never aim at.
  int get controlPanelIndex;

  /// How many plant-wide arms the storm has applied so far.
  ///
  /// The same counter invariant 1 reads, for the same reason: the control's
  /// property is *"the storm never AIMS at it"* and never *"it is never
  /// disturbed"*, so the control's flat-structures arm is written against the
  /// panel-targeted half of the storm only (11-03's correction).
  int get plantWideArmsApplied;

  /// One simultaneous reading of every watched structure.
  SoakStructureReading readStructures();
}

/// One panel's complaint surface, as invariant 5 reads it.
abstract interface class SoakPanelLogView {
  /// Its position in the herd. Zero is the control.
  int get index;

  /// `panel-N`.
  String get name;

  /// Whether this panel currently holds an established session.
  ///
  /// **`RemoteStateMan.isReady`, and it is the closest public predicate to
  /// "has an established subscription".** A panel that never connected produced
  /// no complaints for a reason that is not the invariant's, so its windows are
  /// not judged — but the client exposes readiness rather than
  /// per-subscription establishment (`lastSeq != null` lives inside
  /// `ConnectionSupervisor`), and reaching for the private one would mean
  /// editing `tfc_relay_client/lib`, which this plan measures and does not
  /// change. The substitution is conservative in the right direction: a ready
  /// panel whose page is not established still gets judged, which is precisely
  /// the state `connection_supervisor.dart:692-702` warns the flood comes from.
  bool get established;

  /// `RemoteStateMan.complaints.length` — the uncapped list itself.
  int get complaints;

  /// How many times this panel has lost readiness and had to rebuild.
  ///
  /// **`SoakPanelHealth.readyDips`, and it is invariant 5's anti-vacuity
  /// observable rather than [complaints].** The complaint path is only
  /// reachable through a re-establishment: every append site in
  /// `resync_engine.dart` sits inside `_recover`'s catch (`:208`) or reads the
  /// result of a `subscribe` that came back with rejected keys (`:249`, `:252`).
  /// A panel that never rebuilt could not have complained for a reason that is
  /// not this invariant's, and a ceiling measured against that run is a ceiling
  /// measured against nothing.
  ///
  /// Read from the driver's 250 ms health sampler rather than counted from this
  /// view's own five-second `established` readings: a dip shorter than a
  /// checkpoint is still a rebuild, and the checker would miss it.
  int get reestablishments;
}

/// What invariant 5 reads.
abstract interface class SoakLogSource {
  /// The run's seed, so a violation can be reproduced from its own text.
  int get seed;

  /// What the run was declared to be. Floors scale off this.
  Duration get declaredDuration;

  /// The play clock.
  Duration get scheduleOffset;

  /// The panel the storm may never aim at.
  int get controlPanelIndex;

  /// Every panel's complaint surface, control first.
  List<SoakPanelLogView> get panelLogs;

  /// How many lines the **gateway** has produced.
  ///
  /// **This is a real log-line count and not a stand-in.** `buildGateway`'s
  /// default error sink is `_logServerError(log)` —
  /// `(error, stack, where) => log.e('[server] $where: $error')`,
  /// `gateway_config.dart:492-497`, installed at `:643` — so one entry here is
  /// exactly one line the deployed gateway would write. The soak occupies the
  /// same injectable seam with a collector instead of a logger
  /// (`gate_b_fixture.dart:656`), which is why the server half of this
  /// invariant is countable in process and needed no subprocess harness.
  int get gatewayLogLines;

  /// How many ingest refusals actually reached a log sink.
  ///
  /// `IngestLog.logged`, not `IngestLog.refusals`: the class damps to **once
  /// per key per process** precisely because *"a struct that fails at 10 Hz
  /// writes 864,000 identical lines a day"* (`ingest.dart:96-101`). It is the
  /// server-side twin of the client damping this invariant's control removes,
  /// and watching the damped number is what makes a broken damper visible.
  int get plantIngestLogLines;
}

// ------------------------------------------------- what invariant 3 reads

/// One panel's convergence surface, as invariant 3 reads it.
///
/// It extends [SoakPanelView] rather than duplicating its three members: what
/// invariant 3 compares against plant truth is *what a widget would render*,
/// which is exactly what [SoakPanelView.read] answers, and a second read path
/// would be a second opinion about the same cache.
///
/// The three members it adds are the ones the **attribution** needs, and every
/// one of them is a surface the shipping client already publishes — no lever,
/// no seam, nothing added to `tfc_relay_client/lib` for this invariant.
abstract interface class SoakPanelResyncView implements SoakPanelView {
  /// Whether this panel currently holds an established session —
  /// `RemoteStateMan.isReady`. The same substitution [SoakPanelLogView] makes,
  /// for the same reason and with the same caveat.
  bool get established;

  /// `RemoteStateMan.complaints`, the list itself rather than its length.
  ///
  /// **This is where three of the six causes are actually detected.** The
  /// divergence detectors Phase 7 shipped do not expose a flag — what they
  /// expose is a sentence on this list: `connection_supervisor.dart:684-685`
  /// for an unannounced handle, `:775` for a tick-sequence mismatch that
  /// survived its rebuild, and `resync_engine.dart:207-209` for a page that
  /// could not be re-established. Reading the strings is reading the shipped
  /// detector's own verdict, which is what the plan means by building the
  /// taxonomy from the gate's arms rather than from first principles.
  List<String> get complaints;

  /// How many times the **gateway** has rebuilt this panel's page.
  ///
  /// `SubscriptionState.generation`, the same reading
  /// `divergence_gate_test.dart:_rebuildsServed` and
  /// `resync_gate_test.dart:_rebuildsServed` both take: one generation is
  /// minted per subscribe, so the delta is the number of rebuilds the gateway
  /// served this page. It is the only public evidence that the tick-sequence
  /// detector fired on a divergence it then healed — the healing path leaves
  /// no complaint behind, deliberately (`connection_supervisor.dart:769-782`
  /// damps to one line per subscription per connection and only when the
  /// rebuild did **not** fix it).
  int get pageRebuilds;
}

/// What invariant 3 and the divergence ledger read.
///
/// **Plant truth is on this interface and not derived by the checker**, which
/// is the plan's own instruction restated: the soak scripted the mutation, so
/// the expected value at any offset is a lookup into the artifact everybody is
/// already reading rather than a second reading of the client. A checker that
/// asked the client twice would be comparing a cache with itself.
abstract interface class SoakResyncSource {
  /// The run's seed, so a divergence can be reproduced from its own text.
  int get seed;

  /// What the run was declared to be. Floors scale off this.
  Duration get declaredDuration;

  /// The play clock.
  Duration get scheduleOffset;

  /// The panel the storm may never aim at.
  int get controlPanelIndex;

  /// How many plant-wide arms the storm has applied so far.
  ///
  /// The same counter invariants 1 and 4 read, for 11-03's reason: the
  /// control's property is *"the storm never AIMS at it"* and never *"it is
  /// never disturbed"*. A gateway restart, a keymapping reload and every
  /// upstream arm reach the control like everybody else, so the control's
  /// convergence arm judges only the windows across which this counter did not
  /// move.
  int get plantWideArmsApplied;

  /// Every panel's convergence surface, control first.
  List<SoakPanelResyncView> get panelResyncViews;

  /// The keys convergence is judged over — the same list invariant 1 reads,
  /// with the `PIPE.` health namespace excluded **by the checker** rather than
  /// here, for 08-PATTERNS freeze 8's reason.
  List<String> get freshnessKeys;

  /// Where the timeline says the storm is silent.
  ///
  /// Computed at generation time by `computeStableWindows`, so the checker is
  /// told *where to look* instead of watching for quiet reactively. This is
  /// the gift of a pure generator that 11-RESEARCH §B.3 names, and it is why
  /// invariant 3 can fail loudly on a run that produced no windows rather than
  /// passing vacuously on one that never went quiet.
  List<StableWindow> get stableWindows;

  /// The value the plant is publishing for [key] right now, or null when no
  /// link carries it.
  SoakPlantTruth? plantTruthFor(String key);

  /// How often the plant moves every key — `soakSweepPeriod`.
  Duration get plantSweepPeriod;

  /// The aliases whose upstream epoch the storm has bumped so far.
  ///
  /// An epoch bump forces a re-browse and legitimately marks that link's keys
  /// bad-quality until it completes (`epoch.dart:26`), which is the one cause
  /// in the taxonomy that is the system working rather than failing.
  Set<String> get epochBumpedAliases;

  /// Where `verdict.txt` goes, beside the rest of the run's artifact.
  String get journalPath;
}

/// What the plant is publishing for one key, and how the soak knows.
///
/// Two shapes, because the fixture has two: `GateBPlantDriver` sweeps every
/// clean key to one monotonically increasing integer every
/// [SoakResyncSource.plantSweepPeriod], and a `PlantMutate` entry overrides one
/// key to a fixed value that is then republished every cycle for the rest of
/// the run (`gate_b_fixture.dart:overrideRaw` — *"the device does not poison
/// one sample and recover, it keeps reporting the poison"*).
///
/// The distinction is not cosmetic. An overridden key is judged on **equality**
/// because its expected value stands still; a swept key is judged on **lag in
/// sweeps**, because demanding instantaneous equality of a value that changes
/// four times a second would report the wire's own transit time as a
/// divergence — two hundred of them per sample, on a healthy pipe.
final class SoakPlantTruth {
  const SoakPlantTruth({
    required this.value,
    required this.overridden,
    this.sweepIndex,
  });

  /// What the plant last published for this key.
  final Object? value;

  /// Whether a `PlantMutate` set it. Overridden keys are judged on equality.
  final bool overridden;

  /// The sweep counter's current value, for a key the plant sweeps.
  ///
  /// Null for an overridden key, whose expected value no longer moves with the
  /// counter.
  final int? sweepIndex;

  /// The quality a value straight off this plant carries.
  ///
  /// **Always good, and that is the point of comparing quality at all.** The
  /// fake plant publishes nothing degraded; every `badStale`, `badCommFault`
  /// or `uncertainNotYetKnown` a panel renders was produced by the pipe — the
  /// gateway's freshness sweep, an epoch bump, a snapshot that has not landed.
  /// A checker that compared value alone would call a panel converged while it
  /// renders the right number under a quality the plant never sent, which is
  /// exactly the epoch path and would hide it entirely.
  Quality get quality => Quality.good;

  @override
  String toString() => overridden
      ? '$value (overridden)'
      : '$value (sweep ${sweepIndex ?? '?'})';
}

// -------------------------------------------------- the shared observable

/// The observable invariants 4 and 5 both watch.
///
/// `ResyncEngine.complaints` is a bounded-growth question to invariant 4 and a
/// rate question to invariant 5, and both are worth asking. What must not
/// happen is the two answers being read as two findings.
const String sharedObservable = 'complaints';

/// One sentence, printed when two instruments saw the same thing.
///
/// **Pitfall 8, and the sentence is the deliverable rather than a comment.** A
/// genuine complaint flood trips invariant 4's slope rules and invariant 5's
/// rate ceiling, correctly and for the same reason — and a report showing two
/// red invariants reads as two independent instruments corroborating each
/// other, which is twice the confidence the evidence supports. This returns the
/// line that says so, or null when fewer than two checkers recorded against the
/// shared observable, in which case there is nothing to disclaim.
///
/// The comparison is by [SoakViolation.key], which both checkers set to
/// [sharedObservable] on exactly these violations, and by proximity: two
/// breaches five minutes apart on the same list are two findings and are
/// reported as two.
String? sharedObservableFindings(
  List<InvariantChecker> checkers, {
  Duration window = const Duration(seconds: 5),
}) {
  final byChecker = <String, List<SoakViolation>>{};
  for (final checker in checkers) {
    for (final violation in checker.violations) {
      if (violation.key != sharedObservable) continue;
      (byChecker[checker.name] ??= <SoakViolation>[]).add(violation);
    }
  }
  if (byChecker.length < 2) return null;

  final names = byChecker.keys.toList()..sort();
  var coincident = 0;
  for (final left in byChecker[names.first]!) {
    for (final right in byChecker[names.last]!) {
      if ((left.monotonic - right.monotonic).abs() <= window) coincident++;
    }
  }
  final lead = '  SHARED      : ${names.join(' and ')} both recorded against '
      '"$sharedObservable"';
  if (coincident == 0) {
    return '$lead, at different checkpoints. Those are separate findings on '
        'one list; the shared observable is noted so nobody counts them as '
        'independent confirmation of each other.';
  }
  return '$lead within one checkpoint on $coincident '
      'occasion${coincident == 1 ? '' : 's'}. Read that as ONE FINDING SEEN BY '
      'TWO INSTRUMENTS, not as two invariants corroborating each other — they '
      'are watching the same list and asking different questions of it '
      '(growth, and rate).';
}
