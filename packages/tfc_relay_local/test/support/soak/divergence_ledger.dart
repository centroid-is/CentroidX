/// Every divergence the soak saw, what caused it, and the one number the
/// keyframe decision turns on.
///
/// **This file is not an invariant. It is evidence for a decision.**
/// STATE.md records that periodic keyframes were narrowed to *"Phase 8, opt-in,
/// default off"*; 08-CONTEXT ruling 2 then deferred them past this soak,
/// recorded in `08-PLAN-INDEX.md` as *"not a deviation; a ruling"*. The user's
/// ruling, as relayed, is that *if the soak finds residue, keyframes come back
/// as the evidence-backed fix* — so the soak is the arbiter and it has to emit
/// a **verdict** rather than a pass or a fail.
///
/// **Which is why the causes are attributed and not counted.** A keyframe fixes
/// some divergences and not others: a lost push is exactly what a periodic
/// snapshot repairs, and a subscription that could not be re-established is
/// exactly what it does not — keyframes do not arrive on a page that does not
/// exist. A single number would be worthless. The difference between *"add
/// keyframes"* and *"add keyframes because fourteen unhealed lostPush
/// divergences survived their stable windows, longest thirty-four seconds"* is
/// the difference between a decision and a guess, and it is the whole reason
/// [DivergenceCause] exists rather than an `int`.
///
/// **`unattributed` IS the verdict number.** Everything else in the taxonomy is
/// a claim about a mechanism somebody can check. `unattributed` is the honest
/// admission that a panel and the plant disagreed and this harness cannot say
/// why — and that is precisely the residue the keyframe question is about. The
/// one way to make this artifact lie is to widen a cause's detector until it
/// absorbs a divergence it does not actually explain, which is why every
/// detector below reads a surface the shipping client publishes for its own
/// reasons and none of them reads a hint this file planted.
///
/// **SCOPE FENCE, ABSOLUTE.** No keyframe is built in this phase regardless of
/// what this prints — no config flag, no protocol field, no `keyframe`
/// identifier anywhere in the phase's diff, proved by a grep in the
/// verification. This file produces the evidence; building is a post-milestone
/// decision with the user (11-CONTEXT scope fences).
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'invariant.dart';
import 'soak_observables.dart';
import 'soak_timeline.dart';

// ------------------------------------------------------------- the taxonomy

/// Why one panel's value disagreed with the plant's.
///
/// Every arm carries **whether a keyframe would have fixed it**, in this doc
/// rather than in a plan or a summary, because the person who needs that
/// sentence is the one reading `lostPush=14 resyncFailure=3` months from now
/// and deciding what to do about it. A taxonomy whose keyframe relevance lives
/// somewhere else is a counter with extra steps.
enum DivergenceCause {
  /// A `u` frame the client never applied, and no later frame to notice it.
  ///
  /// **Would a keyframe fix it? YES** — this is the case a periodic snapshot
  /// exists for, and 07-RESEARCH-PUBSUB Part 14's case 2 is this exact shape.
  ///
  /// **The shipped detector** is the tick's per-subscription sequence compared
  /// against the client's `lastSeq` (`connection_supervisor.dart:761-762`,
  /// Phase 7's fix for G1a). The detector fires and rebuilds the page; the
  /// rebuild leaves no complaint behind when it works, deliberately, so the
  /// only public evidence that it fired is the **gateway's own generation
  /// counter advancing** — which is the reading `divergence_gate_test.dart`
  /// takes as `_rebuildsServed`, and it is what [SoakPanelResyncView.pageRebuilds]
  /// reports. When the rebuild does *not* fix it, the client says so in words on
  /// `complaints` (`:769-782`), and [lostPushSurvivedRebuild] is that sentence.
  ///
  /// **The signature, stated so it can be argued with.** An established page,
  /// a value behind plant truth, rendered under **good** quality — a panel
  /// showing a number the gateway has already superseded with nothing on screen
  /// to say so, which is PROJECT.md's stale-but-plausible failure and G1's
  /// library doc in one line.
  lostPush,

  /// A `u` named a handle this session never announced.
  ///
  /// **Would a keyframe fix it? YES** — and the client-side resync-on-unknown-
  /// handle fix Phase 7 shipped for G1b already covers it, so **residue
  /// attributed here means that fix has a hole**, which is a finding in its own
  /// right and not only an argument for keyframes.
  ///
  /// **The shipped detector** records a complaint naming the handle and skips
  /// the key while the rest of the batch is applied and the sequence advances
  /// (`connection_supervisor.dart:673-687`). The sequence stays intact and the
  /// cache does not, which is why [lostPush]'s detector cannot see this one:
  /// the tick agrees with the client to the number.
  unknownHandle,

  /// A value from generation *g* read after a snapshot for *g+1*.
  ///
  /// **Would a keyframe fix it? NO — and it should not.** Discarding a replayed
  /// batch is `ValueStore`'s correct behaviour (`value_store.dart:212`,
  /// `BatchReplay`), and the resync engine re-establishes rather than applying
  /// it (`resync_engine.dart:149-153`). **A divergence attributed here is a
  /// DETECTOR bug, not a pipe bug**: it means this checker read a panel across
  /// a rebuild boundary and compared a pre-snapshot cache with post-snapshot
  /// plant truth. It stays in residue for exactly that reason — a detector that
  /// cannot be trusted makes the verdict untrustworthy, and the verdict should
  /// say so rather than quietly subtract it.
  generationChange,

  /// `ResyncEngine._recover` failed and the page went unestablished.
  ///
  /// **Would a keyframe fix it? NO** — keyframes do not arrive on a
  /// subscription that does not exist. This is the one cause in the taxonomy
  /// where the keyframe answer is *"you are fixing the wrong thing"*.
  ///
  /// **The shipped detector** is the complaint `_recover` writes on the way
  /// down (`resync_engine.dart:207-209`): *"could not be re-established and is
  /// now unestablished … Its values are gone from the cache rather than left on
  /// screen under good quality"*.
  resyncFailure,

  /// The upstream epoch bumped and this link's keys are legitimately bad.
  ///
  /// **Would a keyframe fix it? NO — it is the system working.** A `ServerStatus.
  /// StartTime` change bumps the epoch, forces a re-browse and marks the link's
  /// keys bad-quality until the browse completes (`epoch.dart:26`, 08-08). The
  /// panel is *correctly* refusing to vouch for a value it cannot currently
  /// justify.
  ///
  /// **Excluded from residue, never from the record** — see
  /// [DivergenceLedger.residue] for that decision and its reason at the site
  /// where it is applied.
  epochChange,

  /// None of the above.
  ///
  /// **THE VERDICT NUMBER.** 11-CONTEXT ruling 5, set before any full run:
  /// `unattributed == 0 && residue == 0` closes the keyframe decision and
  /// STATE.md's deferral resolves; anything else reopens it with this ledger as
  /// the evidence.
  ///
  /// **Would a keyframe fix it? UNKNOWN, and that is the answer that matters.**
  /// A divergence nobody can explain is the one a periodic snapshot is
  /// insurance against, because insurance is what you buy against the failures
  /// you have not characterised.
  unattributed,
}

/// The complaint the client writes when a tick-sequence rebuild did not help.
///
/// Matched as a substring of `RemoteStateMan.complaints`. Quoted from
/// `connection_supervisor.dart:770-771` rather than paraphrased: this is the
/// same rule `f_row_registry.dart` applies to catalogue clauses, and a
/// paraphrase here would be a detector that silently stops matching the day
/// somebody rewords the message.
const String lostPushSurvivedRebuild =
    'was rebuilt on a tick-sequence mismatch and the mismatch survived the '
    'rebuild';

/// The complaint the client writes for a handle it never agreed to.
///
/// From `connection_supervisor.dart:684-685`.
const String unknownHandleComplaint = 'which this session never announced';

/// The complaint `ResyncEngine._recover` writes on the way down.
///
/// From `resync_engine.dart:207-208`.
const String unestablishedComplaint =
    'could not be re-established and is now unestablished';

// ---------------------------------------------------------------- the event

/// One divergence, complete enough to argue about without the run that
/// produced it.
///
/// Every field is here because somebody reading this months later needs it, and
/// the three that are easy to leave out are the three that cost the most:
///
///  * [nth] — **stable identity across runs.** Command ids are `Random.secure`
///    (`ulid.dart:17-21`) and are not; the *n*-th divergence of the run is.
///  * [scheduleOffset] — the position in the **generated** timeline, so the
///    fault that was armed is a lookup into `repro.log` rather than a replay of
///    twenty-three minutes.
///  * [healedWithinMs] — **null is the residue discriminator.** A divergence
///    that healed inside its window is the pipe converging, which is what
///    invariant 3 says should happen; one that survived to the window's end is
///    the evidence the keyframe question is about. One nullable field carries
///    the whole distinction.
final class DivergenceEvent {
  DivergenceEvent({
    required this.nth,
    required this.panelId,
    required this.subId,
    required this.key,
    required this.scheduleOffset,
    required this.wallOffsetMs,
    required this.cause,
    required this.clientValue,
    required this.plantValue,
    required this.clientQuality,
    required this.plantQuality,
    required this.generation,
    required this.windowIndex,
    this.healedWithinMs,
    this.lastSeq,
    this.tickSeq,
    this.isControl = false,
  });

  /// The *n*-th divergence this run recorded, control events included.
  final int nth;

  /// `panel-N`.
  final String panelId;

  /// The page the key is filed under — `defaultPageSubscription` in this
  /// fixture, because `gate_b_fixture.dart` constructs every panel with its
  /// whole key list.
  final String subId;

  final String key;

  /// Where in the generated timeline this happened.
  final Duration scheduleOffset;

  /// Monotonic milliseconds into the run, for correlating with
  /// `metrics.jsonl`. **Monotonic and never a wall reading** — freeze 9 keeps
  /// `DateTime.now()` out of the soak trees, and 07-REVIEW CR-01 is why.
  final int wallOffsetMs;

  final DivergenceCause cause;

  /// How long it took to heal, or **null if it never did** — the residue
  /// discriminator.
  final int? healedWithinMs;

  final Object? clientValue;
  final Object? plantValue;
  final Quality? clientQuality;
  final Quality plantQuality;

  /// The gateway's rebuild counter for this page at the moment of the reading.
  ///
  /// **How G1 is told from G4.** A divergence whose generation advanced while
  /// it was open was seen by the tick-sequence detector; one read *across* an
  /// advance is a detector artifact. The two are different findings and this
  /// number is what separates them.
  final int generation;

  /// Which computed stable window it was seen in.
  final int windowIndex;

  /// The client's applied sequence, when a case can supply it.
  ///
  /// **Null in the composed run, and stated rather than hidden.**
  /// `SubscriptionState.lastSeq` lives inside `ConnectionSupervisor` and the
  /// client publishes no getter for it; reaching for it would mean editing
  /// `tfc_relay_client/lib`, which this plan measures and does not change. The
  /// field is here because the unit arms *can* supply it and because a reader
  /// comparing this record against `divergence_gate_test.dart`'s will look for
  /// it. [generation] is the substitute the composed run actually uses.
  final int? lastSeq;

  /// The sequence the gateway advertised, when a case can supply it. Null in
  /// the composed run for [lastSeq]'s reason.
  final int? tickSeq;

  /// Whether the ledger's own positive control produced it.
  ///
  /// **Counted separately and excluded from the verdict's totals**, because a
  /// control that fed the residue count would make every run print *needed* and
  /// the verdict would mean nothing. It is printed as the verdict's **warrant**
  /// instead — see [DivergenceLedger.verdictBlock].
  final bool isControl;

  /// Whether this survived its window.
  bool get isResidue => healedWithinMs == null;

  Map<String, Object?> toJson() => <String, Object?>{
        'nth': nth,
        'panel': panelId,
        'sub': subId,
        'key': key,
        'scheduleOffsetMs': scheduleOffset.inMilliseconds,
        'monotonicMs': wallOffsetMs,
        'cause': cause.name,
        'healedWithinMs': healedWithinMs,
        'clientValue': clientValue,
        'plantValue': plantValue,
        'clientQuality': clientQuality?.code,
        'plantQuality': plantQuality.code,
        'lastSeq': lastSeq,
        'tickSeq': tickSeq,
        'generation': generation,
        'window': windowIndex,
        'control': isControl,
      };

  @override
  String toString() => '#$nth ${formatSoakOffset(scheduleOffset)} $panelId '
      '$key client=$clientValue/${clientQuality?.code} '
      'plant=$plantValue/${plantQuality.code} gen=$generation '
      'window=$windowIndex ${cause.name} '
      '${healedWithinMs == null ? 'RESIDUE' : 'healed in ${healedWithinMs}ms'}'
      '${isControl ? ' [control]' : ''}';
}

// --------------------------------------------------------------- the ledger

/// How many events are retained before the ledger starts counting instead.
///
/// **Two hundred, the same number and the same arithmetic as
/// [violationLogCapacity].** A single stuck panel diverges on every key of
/// every sample; retaining them would make this artifact the unbounded growth
/// invariant 4 is asserting against (07-RESEARCH trap 15, and pitfall 1).
/// [DivergenceLedger.total] and the per-cause counters are maintained
/// **outside** the retained list, so a capped ledger still reports the whole
/// run's numbers — a cap without a counter would report two hundred for a run
/// that had eighty thousand, which is a worse lie than the memory it saves.
const int divergenceLedgerCapacity = 200;

/// The threshold, and it was set **before** any full run.
///
/// **11-CONTEXT ruling 5, 2026-09-01**, taken at the overnight discuss gate and
/// flagged for the user's morning review because it operationalises their own
/// ruling: *"if the soak finds residue, keyframes come back as the
/// evidence-backed fix"*. The strictest honest reading of that is zero, so:
/// `unattributed == 0 && residue == 0` closes the decision and STATE.md's
/// deferral resolves; **anything else reopens it with this ledger as the
/// evidence.**
///
/// **There is no tolerance band, deliberately.** A threshold chosen after
/// seeing the numbers is not a threshold — it is a description of the numbers
/// wearing a threshold's clothes. This number was **set before the run** — at
/// the discuss gate on 2026-09-01, and written into this file before the first
/// arm was ever played. That is the only thing that makes the verdict
/// defensible, and it is why this is a constant rather than a parameter.
const int keyframeVerdictThreshold = 0;

/// The whole run's divergences, their causes, and the verdict they produce.
///
/// **It is registered as a checker and audited through the same vacuity gate as
/// the five invariants**, which is the point of it being in `declaredCheckers`
/// at all. An empty ledger whose control never fired is not evidence that
/// nothing diverged — it is a recorder nobody proved was plugged in — and the
/// audit that catches that is the same one that catches a freshness sampler
/// that stopped: [judgedSamples] against [minimumSamplesForAVerdict].
///
/// **It records violations of nothing.** [violations] stays empty on a run
/// whose residue is enormous, because a failing verdict is a **finding for the
/// user, not a broken pipe** — the test fails on invariant violations and the
/// verdict is evidence about a design decision. Conflating the two would make
/// the keyframe question un-askable without a red build, which is the one way
/// to guarantee nobody ever asks it. The only thing that lands in [violations]
/// is the mixin catching a throw from this recorder itself.
final class DivergenceLedger with GuardedSampling implements SoakRunEndCheck {
  DivergenceLedger(this._source, {this.capacity = divergenceLedgerCapacity});

  final SoakResyncSource _source;

  /// How many events are retained. See [divergenceLedgerCapacity].
  final int capacity;

  @override
  String get name => 'divergenceLedger';

  @override
  final ViolationLog violationLog = ViolationLog();

  final List<DivergenceEvent> _entries = <DivergenceEvent>[];
  final Map<DivergenceCause, int> _byCause = <DivergenceCause, int>{};
  final Map<DivergenceCause, int> _residueByCause = <DivergenceCause, int>{};
  int _overflow = 0;
  int _total = 0;
  int _healed = 0;
  /// Lines recorded and not yet on disk. Drained every tick by
  /// [takeReading]; see there for why it is not the cursor it replaced.
  final List<String> _unstreamed = <String>[];
  final List<DivergenceEvent> _controls = <DivergenceEvent>[];

  /// Retained events, oldest first — the first occurrence is the diagnostic.
  List<DivergenceEvent> get entries =>
      List<DivergenceEvent>.unmodifiable(_entries);

  /// The control's events, kept apart from the run's.
  List<DivergenceEvent> get controlEvents =>
      List<DivergenceEvent>.unmodifiable(_controls);

  /// How many events were recorded past [capacity].
  int get overflow => _overflow;

  /// Every divergence the run recorded, **excluding** the control's.
  int get total => _total;

  /// How many healed inside their window.
  int get healed => _healed;

  /// How many are counted under [cause], control excluded.
  int countOf(DivergenceCause cause) => _byCause[cause] ?? 0;

  /// How many **unhealed** are counted under [cause], control excluded.
  int residueOf(DivergenceCause cause) => _residueByCause[cause] ?? 0;

  /// The number the keyframe decision turns on, beside [unattributed].
  ///
  /// **`epochChange` is excluded here and nowhere else, and this is the one
  /// judgement call in the taxonomy.** The reason, at the site where it is
  /// applied: an epoch bump legitimately marks a link's keys bad-quality until
  /// the re-browse completes (`epoch.dart:26`, 08-08), so those divergences are
  /// the system working exactly as designed. Counted into residue they would
  /// dominate it — the storm bumps epochs on purpose — and a residue number
  /// dominated by the expected case hides whatever real finding sits under it.
  ///
  /// **Excluded from residue, NEVER from the record.** Every epoch divergence
  /// is in [entries] with its `nth` and its schedule offset, is streamed to the
  /// journal like every other, and prints in the per-cause line of the verdict
  /// block. If this exclusion ever swallows something real, the evidence to
  /// find it is already written down; if the exclusion itself were a filter on
  /// the *record*, it would not be.
  int get residue {
    var sum = 0;
    for (final cause in DivergenceCause.values) {
      if (cause == DivergenceCause.epochChange) continue;
      sum += residueOf(cause);
    }
    return sum;
  }

  /// The verdict number. See [DivergenceCause.unattributed].
  int get unattributed => countOf(DivergenceCause.unattributed);

  /// Whether the keyframe decision closes on this run's evidence.
  ///
  /// [keyframeVerdictThreshold] is the whole of it, and it was set before the
  /// run.
  bool get keyframesNotNeeded =>
      unattributed <= keyframeVerdictThreshold &&
      residue <= keyframeVerdictThreshold;

  /// Records one divergence and streams it to the journal.
  void record(DivergenceEvent event) {
    if (event.isControl) {
      // Kept apart from [entries] as well as from the counters. The control is
      // the verdict's WARRANT and not one of the run's divergences: a reader
      // scanning the retained list for what went wrong must not find a
      // synthetic reading this harness supplied sitting among the real ones.
      _controls.add(event);
      return;
    }
    _total++;
    _byCause[event.cause] = countOf(event.cause) + 1;
    if (event.isResidue) {
      _residueByCause[event.cause] = residueOf(event.cause) + 1;
    } else {
      _healed++;
    }
    // **Before `_retain`**, which is what makes the file the record and the
    // retained list merely the print. See [takeReading].
    _unstreamed.add('${jsonOf(event)}\n');
    _retain(event);
  }

  void _retain(DivergenceEvent event) {
    if (_entries.length < capacity) {
      _entries.add(event);
    } else {
      _overflow++;
    }
  }

  // --------------------------------------------------------- the audit

  /// How many events this ledger has recorded, **the control's included**.
  ///
  /// **The control is what makes this number non-zero on a healthy run**, and
  /// that is the entire design: a pipe that never diverged records nothing, and
  /// a recorder that was never plugged in records nothing, and the two are
  /// indistinguishable. So the ledger's floor is the control's one event, and a
  /// run whose control did not fire fails the same gate a blind sampler fails —
  /// naming the ledger.
  @override
  int get judgedSamples => _total + _controls.length;

  /// One — the control's event — and **zero** on an arm too short to generate
  /// a stable window.
  ///
  /// Not scaled with the duration, unlike every checker floor: the control
  /// fires once per run by construction, so a floor that scaled would be one
  /// the 35-minute arm could never reach.
  ///
  /// The zero is the same concession invariant 3 makes at
  /// [minDurationForAStableWindow] and for the same reason: the control fires
  /// inside a stable window, `soak_test.dart`'s 8- and 12-second auxiliary arms
  /// generate none, and a floor they cannot reach would fail them for a reason
  /// that has nothing to do with what they assert. Every arm that can judge
  /// invariant 3 at all still carries the floor of one.
  @override
  int get minimumSamplesForAVerdict =>
      _source.declaredDuration < minDurationForAStableWindow ? 0 : 1;

  // ------------------------------------------------------- the run-end pass

  @override
  void finish() {
    try {
      _writeVerdictFile();
    } catch (error) {
      // Recorded rather than raised: `SoakRunEndCheck.finish` is called after
      // the last entry and a throw here would take the verdict block down with
      // it — losing the numbers to save the file that carries them.
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: _source.scheduleOffset,
        scheduleOffset: _source.scheduleOffset,
        detail: 'the verdict could not be written to '
            '${_source.journalPath}/$verdictFileName: $error. The block is '
            'still on stdout; the CI artifact will not carry it',
      ));
    }
  }

  void _writeVerdictFile() {
    // The last events, before the verdict that counts them: a reader diffing
    // the block against the file must not find the file one tick short.
    _flushPending();
    final dir = Directory(_source.journalPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}/$verdictFileName').writeAsStringSync('$verdictBlock\n');
    // **An empty file, when there is nothing to stream.** `takeReading` only
    // creates `divergences.jsonl` when it has an entry to append, so a clean
    // run left the artifact without it — and a MISSING file cannot be told
    // apart from a ledger that never ran, which is the distinction the whole
    // keyframe verdict rests on. An empty one says "the ledger ran and saw
    // nothing", which is the finding. Measured on the 35-minute arm: five
    // files uploaded, and this was not among them.
    final record = File('${dir.path}/$divergenceFileName');
    if (!record.existsSync()) record.writeAsStringSync('');
  }

  /// Streams whatever it has not yet written to the journal.
  ///
  /// **Streamed rather than accumulated**, so a thirty-five-minute run whose
  /// ledger overflowed still has every event on disk. The retained list is for
  /// the verdict block; `divergences.jsonl` is the record.
  ///
  /// **It streams from its own queue and NOT from [entries], which is the
  /// whole of the fix.** `_retain` stops appending at [capacity], so a cursor
  /// walking `_entries` catches up with a list that has stopped growing and
  /// every later tick becomes a no-op — the events past the cap reached
  /// neither the retained list nor the file, while the doc above and the
  /// verdict block both told the reader they were in the file. `record` now
  /// enqueues the line before `_retain` is given the chance to drop the event,
  /// so the cap governs what is PRINTED and nothing governs what is RECORDED.
  ///
  /// **Written synchronously, and that is deliberate rather than lazy.** The
  /// previous shape opened an append sink per tick and dropped the `close()`
  /// future: an `IOSink` error went to an unhandled async error in the test's
  /// zone twenty minutes from the line that caused it, the cursor advanced in
  /// a `finally` BEFORE the flush so a failed close lost lines and marked them
  /// written, and two overlapping append handles on one file can interleave
  /// mid-line — a corrupted record in the artifact whose entire job is to be
  /// machine-readable evidence for the keyframe decision. A synchronous append
  /// has none of those: it either wrote or it threw, the queue is drained only
  /// after it returns, and `GuardedSampling` turns a throw into a violation
  /// naming this ledger. The cost is a few hundred bytes appended every five
  /// seconds, against a checker that already spends 50 ms in a synchronous
  /// `lsof`.
  ///
  /// `_unstreamed` grows only while the write is failing — a drained queue is
  /// empty every tick — so the instrument does not become the leak it is
  /// measuring except on a filesystem that is already broken, and on that
  /// filesystem the violation log is saying so every five seconds.
  @override
  void takeReading(SoakClock clock) => _flushPending();

  /// Flushes the queue and lets a caller await it. Sync underneath; the future
  /// is for symmetry with the callers that have one.
  Future<void> flushStream() async => _flushPending();

  void _flushPending() {
    if (_unstreamed.isEmpty) return;
    final dir = Directory(_source.journalPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}/$divergenceFileName').writeAsStringSync(
        _unstreamed.join(),
        mode: FileMode.append,
        flush: true);
    // Only after the write RETURNED. The previous shape cleared its cursor in
    // a `finally`, so a failed flush lost the lines and recorded them as
    // written.
    _unstreamed.clear();
  }

  // ------------------------------------------------------------ the verdict

  /// The block, **verbatim in this shape**.
  ///
  /// It will be pasted into the milestone audit, quoted in STATE.md and read
  /// months from now, so the shape is asserted line by line in
  /// `soak_meta_test.dart` and drift fails a case. A shape that moves between
  /// runs is a shape nobody can diff.
  ///
  /// **The verdict never prints without its warrant.** The control's line is
  /// part of the block and not an adjacent print, because a ledger that
  /// recorded nothing all run reads exactly like a clean verdict — T-11-25, and
  /// the number must never be read without the evidence that the recorder
  /// works.
  String get verdictBlock {
    final causes = <String>[
      for (final cause in DivergenceCause.values)
        '${cause.name}=${residueOf(cause)}',
    ];
    return <String>[
      'divergence verdict (seed=${_source.seed}, '
          'duration=${_durationLabel(_source.declaredDuration)}, '
          'panels=${_source.panelResyncViews.length}):',
      '  total divergence events         : $total',
      '  healed within the stable window : $healed',
      '  RESIDUE (unhealed at window end): $residue',
      // **Both terms of `keyframesNotNeeded`, adjacent and labelled with what
      // each one includes.** This line did not exist, and its absence was the
      // M-08 shape landing on the headline: the predicate reads `unattributed`
      // = `countOf(unattributed)`, every unattributed event healed or not,
      // while the only `unattributed` in the block was the residue-by-cause
      // slice, `residueOf(unattributed)`. A run whose unattributed
      // divergences all healed printed zeros everywhere and then "needed,
      // evidence above", with no evidence above.
      '  UNATTRIBUTED (healed or not)    : $unattributed',
      '  residue by cause: ${causes.take(3).join(' ')}',
      '                    ${causes.skip(3).join(' ')}',
      '  KEYFRAME VERDICT: '
          '${keyframesNotNeeded ? 'not needed' : 'needed, evidence above'}',
      '  $controlLine',
      if (_overflow > 0)
        '  (the retained list is capped at $capacity; $_overflow further '
            'events are counted above and in $divergenceFileName only)',
    ].join('\n');
  }

  /// The warrant. See [verdictBlock].
  String get controlLine {
    if (_controls.isEmpty) {
      return 'ledger control: DID NOT FIRE — this verdict is not evidence. '
          'A ledger that recorded nothing all run reads exactly like a clean '
          'one, so the number above says nothing until the recorder has been '
          'shown to record (T-11-25)';
    }
    final causes = _controls.map((one) => one.cause.name).toSet().join('+');
    return 'ledger control: ${_controls.length} event'
        '${_controls.length == 1 ? '' : 's'} recorded, attributed $causes';
  }

  @override
  String toString() => verdictBlock;
}

/// Fails the run when the keyframe verdict says the decision must be reopened.
///
/// **The verdict used to be print-only, and a decision number that cannot
/// change visibly is not a decision number.** `keyframesNotNeeded`,
/// [DivergenceLedger.unattributed] and [DivergenceLedger.residue] were read
/// nowhere outside `soak_meta_test.dart`'s hand-built ledgers; the composed
/// run printed the block and moved on, and the ledger's own `violationLog`
/// fires on exactly one condition — the verdict FILE failing to write. So
/// `KEYFRAME VERDICT: needed` went green on both arms.
///
/// **A failure here is a design question reopening, not a fault**, and the
/// message says so. 11-CONTEXT ruling 5 closed the keyframes decision on a
/// threshold of [keyframeVerdictThreshold] measured over a composed run; a
/// run that crosses it is evidence the ruling was decided on runs that did
/// not contain the case. Whoever reads this at 3 a.m. must not go looking for
/// a broken pipe.
///
/// **The control cannot trip it**, and that is structural rather than lucky:
/// [DivergenceLedger.record] returns at the top on `isControl` before any
/// counter, so the warrant — which is unhealed by construction — never
/// reaches either term. `soak_meta_test.dart` pins that early return, because
/// deleting it would make every push red for ever.
void assertKeyframeVerdictIsClean(DivergenceLedger ledger) {
  if (ledger.keyframesNotNeeded) return;
  fail('the keyframe decision must be revisited.\n\n'
      '${ledger.verdictBlock}\n\n'
      'This is NOT a pipe fault and nothing here says the gateway is broken. '
      '11-CONTEXT ruling 5 closed the keyframes question on a threshold of '
      '$keyframeVerdictThreshold over a composed run, and this run crossed '
      'it: ${ledger.unattributed} unattributed (healed or not) and '
      '${ledger.residue} unhealed residue. Either state converged somewhere '
      'the pipe promises it converges, or the taxonomy attributed something '
      'it should have explained. Both are reasons to reopen the decision and '
      'neither is an incident.\n\n'
      'Every event is in $divergenceFileName in the run artifact, one JSON '
      'object per line, with its cause, its schedule offset and the values '
      'both sides held. Read those before reading any source file.');
}

/// Where the verdict lands beside the rest of the artifact.
///
/// `build/soak/verdict.txt` in the lane, so 11-07's upload carries it. Written
/// at [DivergenceLedger.finish] rather than at the end of the case, because a
/// run that fails an invariant still has a verdict worth reading.
const String verdictFileName = 'verdict.txt';

/// The streamed record, one JSON object per line.
const String divergenceFileName = 'divergences.jsonl';

/// One event as a JSON line.
///
/// Hand-rolled rather than `jsonEncode`d only where a value cannot be encoded:
/// a `DynamicValue`'s payload is whatever the plant sent, and a `PlantMutate`
/// can carry something `jsonEncode` refuses. Anything unencodable becomes its
/// `toString`, which is what a forensic line wants anyway.
String jsonOf(DivergenceEvent event) {
  final parts = <String>[
    for (final entry in event.toJson().entries)
      '"${entry.key}":${_encode(entry.value)}',
  ];
  return '{${parts.join(',')}}';
}

String _encode(Object? value) => switch (value) {
      null => 'null',
      final bool one => '$one',
      final num one => one.isFinite ? '$one' : '"$one"',
      _ => '"${value.toString().replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
    };

String _durationLabel(Duration duration) => duration.inSeconds % 60 == 0 &&
        duration.inMinutes > 0
    ? '${duration.inMinutes}m'
    : '${duration.inSeconds}s';
