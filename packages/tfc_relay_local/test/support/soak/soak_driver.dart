/// The composed pipe under the storm: one real gateway, N real panels behind N
/// real fault proxies, the merged timeline played on one clock, and the
/// population floor underneath all of it.
///
/// **The driver is a player, not an author.** Every random draw in this phase
/// happened at generation time, in `soak_event.dart`, from
/// `SeededScenarioRandom`. Which key a panel subscribes, which value it writes,
/// which panel writes, which alias goes down — all of it arrives here as a
/// `SoakEvent` arm and none of it is decided here. That is what makes a repro
/// log a reproduction rather than a summary, and it is why this file contains
/// no draw at all: `Random(`, `DateTime.now()` and `DateTime.timestamp(` are
/// all swept out of the soak trees by freeze 9.
///
/// **The trees, and the composed run is wider than the trees.** Freeze 9's
/// scopes are `test/soak/` and `test/support/soak/`. The pipe this driver
/// stands up reaches six wall-clock sites one directory up, outside both:
/// `fake_upstream_link.dart:337` (the `at:` stamp on every `WriteApplied`,
/// which crosses the wire to the panel), `:421` (`_lastDeathAt`, published as
/// `UpstreamLinkDriver.lastDeathAt`), and four wait-loop deadlines in
/// `gate_b_fixture.dart` (`:80`, `:82`, `:746`, `:748`).
///
/// **None of them feeds a verdict today, and that was checked rather than
/// assumed:** `terminal_state.dart` stamps everything from
/// `SoakWriteRecord.at`, which is `_playClock.elapsed`, and no checker reads
/// `WriteApplied.at` or `lastDeathAt`. The two fixture files are shared with
/// gate B, so widening the sweep to them would put a soak freeze in charge of
/// a file gate B owns. What a future checker must not do is age a verdict on
/// one of those six — that would be a wall-clock verdict freeze 9 passes, and
/// it is the exact class 11-04 sabotage 2 belongs to.
///
/// **What it composes is what ships.** Phase 10's CR-01 is the standing lesson:
/// its timeseries family was dead in the shipping gateway because the one
/// composition that ships — server plus policy plus real store — had never been
/// assembled by any test, while every fake made the bug idempotent and
/// invisible. *Capability flags prove a leg ran; parity proves the legs agree;
/// neither proves the stack a panel talks to was ever assembled.* So this
/// driver stands up the real `RelayServer` building its own session policy
/// through `RelaySession`, real listening sockets, real `RemoteStateMan`
/// panels over real TCP, and the real `LocalStateMan` over per-alias
/// `FakeUpstreamLink`s. The only fake in the picture is the PLC, which is the
/// one participant CI cannot have.
///
/// It composes [gateBFixture] rather than standing a second herd up beside it.
/// That fixture already assembles those five pieces in `buildGateway`'s own
/// order, in this package, with the teardown argument written out — a parallel
/// herd would be a second answer to a question that has one.
///
/// **Panel 0 is the control, and the exclusion is this file's job.** The
/// generator cannot tell a control panel from an ordinary one
/// (`soak_event.dart`'s contract: *"`panels` is the set the storm may target,
/// and the caller excludes the control by not passing it in"*). So [SoakDriver]
/// never passes the control's name to [buildTimeline], never gives its proxy to
/// the link half, and refuses to start against any timeline that names it —
/// see [SoakDriver.start]. The argument for having a control at all is
/// `long_outage_gate_test.dart`'s, applied to a herd: *"the server released the
/// dead session" is only worth saying if the server did not also release live
/// ones — which is exactly what it did on the build before 07-08b, once every
/// six seconds, to every panel in the plant.* An all-faulted population cannot
/// see that class of regression; one healthy panel makes it glaring.
///
/// **One clock, one chained timer, and why there is no second playback.** The
/// merged timeline is a **total** order — 11-02 sorted it on
/// `(offset, streamIndex, indexWithinStream)` precisely so that two entries at
/// one offset have a defined relative order that the length of the list cannot
/// change. Playing it means playing it *in that order*, from one clock. Running
/// the link half through per-proxy `ScenarioPlayback` instances would give each
/// its own `Stopwatch` and discard the very ordering the merge exists to fix,
/// so [SoakDriver] walks `merged` itself with one chained timer off one
/// `Stopwatch` — `ScenarioPlayback`'s own shape and its own reasons (a lever
/// that takes a moment to apply does not push every later offset out; there is
/// only ever one pending timer, so "no timer fires after stop" is a property of
/// the shape) — and pulls the link levers through
/// [ScenarioPlayback.apply], which is the existing exhaustive switch over
/// `FaultMutation` and is not restated here.
///
/// **A lever that fired into nothing is a first-class outcome.** Every arm of
/// [SoakDriver.apply] returns a [SoakApplyOutcome] naming the lever it pulled
/// and saying whether it did anything. A storm that quietly narrows itself —
/// a second `disconnectUpstream` on an alias already down returns early
/// (`fake_upstream_link.dart:397`), an unsubscribe from a panel holding no
/// subscription — is the failure mode both halves of the artifact hide on their
/// own: `repro.log` says it was planned and `events.jsonl` says it was applied,
/// and neither says it did nothing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_dart/core/state_man.dart'
    show KeyMappingEntry, KeyMappings;
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show RemoteStateMan, defaultPageSubscription;
import 'package:tfc_relay_local/tfc_relay_local.dart' show UpstreamLinkState;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart'
    show SessionSubscriptionCounts;
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';

import '../../soak/soak_registry.dart' show declaredCheckers;
import '../gate_b_fixture.dart';
import '../keymap_fixtures.dart' show opcUaEntry;
import 'applied_write_ledger.dart';
import 'invariant.dart';
import 'soak_event.dart';
import 'soak_journal.dart';
import 'soak_observables.dart';
import 'soak_timeline.dart';

// ------------------------------------------------------------------ the herd

/// How many panels the soak stands up.
///
/// **Five, of which one is the control.** 11-RESEARCH §C.4's number: four
/// stormed panels is enough for the herd effects the phase is about (a reaper
/// taking live sessions, a fan-out that punishes bystanders) and small enough
/// that a 35-minute run on a hosted runner is not measuring the runner.
const int defaultSoakHerdSize = 5;

/// The environment variable that overrides [defaultSoakHerdSize].
///
/// **The same name gate A's fixture uses** (`gate_fixture.dart`, default 20),
/// deliberately: an operator debugging a herd effect sets one variable and both
/// lanes widen. The defaults differ because the lanes do — gate A's herd holds
/// for one scenario, this one holds for thirty-five minutes.
const String herdSizeVariable = 'RELAY_HERD_N';

/// Reads [herdSizeVariable] out of [environment], or [defaultSoakHerdSize].
///
/// Refuses anything under three: two panels is one stormed panel and one
/// control, which cannot show a herd effect at all, and one panel is a control
/// with no storm.
int soakHerdSize(Map<String, String> environment) {
  final raw = environment[herdSizeVariable];
  if (raw == null || raw.isEmpty) return defaultSoakHerdSize;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 3) {
    throw ArgumentError('$herdSizeVariable="$raw" is not a herd: it must parse '
        'as an integer of at least 3 — one control plus at least two stormed '
        'panels, below which there is no herd effect for the control to be a '
        'control against');
  }
  return parsed;
}

/// The panel the storm may never reach.
const int soakControlPanelIndex = 0;

/// Panel *i*'s name, which is also its station id in the token file.
String soakPanelName(int index) => 'panel-$index';

/// The four PLCs the plant stands in for — SVN's own aliases.
const List<String> soakAliases = <String>[
  'ST101',
  'ST201',
  'ST301',
  'BAADER',
];

/// Keys per alias.
///
/// **Ten, not gate B's fifty.** Five panels each subscribing every key of four
/// aliases is `panels × aliases × keys` values per sweep on one isolate; at
/// fifty that is a thousand, and thirty-five minutes of it measures the encoder
/// rather than the invariants. Ten keeps four aliases' worth of realistic
/// `AREA.DEV.SUB` names in play at two hundred values a sweep.
const int soakKeysPerAlias = 10;

/// Panel *i*'s credential.
///
/// Deterministic, long enough for `FileTokenValidator.minTokenLength`, and
/// visibly a fixture rather than something anybody would mistake for a plant
/// secret.
///
/// **Top-level so there is exactly one spelling of it.** T-11-30's sweep over
/// the uploaded artifact needs the same literal the fixture presents, and a
/// needle written out a second time in the test is a sweep that keeps passing
/// on the day the token changes — the drift 08-04's freeze exists to prevent,
/// applied to a credential.
String soakTokenForPanel(int index) =>
    'soak-${soakPanelName(index)}-000000000000000';

/// How often the plant moves every key.
///
/// Slower than gate B's 100 ms for the same reason the page is narrower: this
/// runs for thirty-five minutes rather than for one assertion.
const Duration soakSweepPeriod = Duration(milliseconds: 250);

/// How long a value may go unheard-of before the gateway must stop letting it
/// claim to be current.
///
/// **Five seconds — `LocalStateMan`'s own default, and deliberately not gate
/// B's thirty.** Gate B widened it because its rows hold a pipe still for one
/// assertion and a five-second deadline would grey the page between two steps
/// of a scripted scenario. The soak is the opposite shape: it runs for
/// thirty-five minutes against a plant that moves every key four times a
/// second, so the shipping number is both reachable and the one worth proving.
///
/// It is also what makes invariant 1 sharp. The freshness budget a checker
/// holds a *fresh* verdict to is this plus the mechanics of noticing and
/// delivering it ([soakFreshnessBudget]); at thirty seconds that budget would
/// be forty and most of a ninety-second arm, which is a bound almost nothing
/// could breach.
const Duration soakStaleAfter = Duration(seconds: 5);

/// How old a value may be while a panel still renders it as current.
///
/// Every term is somebody else's number and none of them is invented here:
///
///  * [soakStaleAfter] — the gateway's declared deadline for a plant value.
///  * `staleAfter ~/ 4` — `FreshnessSweep.intervalFor`, so a value is reported
///    stale within 125 % of its deadline rather than within 200 %.
///  * three seconds — `ClientConfig.freshnessDeadline`, the longest the panel
///    may go without a frame of any kind before it greys the view itself. It is
///    the delivery half: the degrade the gateway staged still has to cross a
///    tick and a socket.
///  * two seconds of slack for the scheduler on a loaded hosted runner. Named
///    rather than folded into one of the others, because it is the only term
///    here that is a guess.
const Duration soakFreshnessBudget = Duration(
  milliseconds: 5000 + 1250 + 3000 + 2000,
);

// -------------------------------------------------------------- the cadences

/// The fast sampler's cadence — 11-04's freshness checker.
const Duration fastCheckerCadence = Duration(milliseconds: 25);

/// The checkpoint cadence: the journal, the population floor, 11-05 and 11-06.
const Duration checkpointCadence = Duration(seconds: 5);

/// The rate-window cadence — 11-05's log-ceiling checker.
const Duration rateWindowCadence = Duration(minutes: 1);

/// How often the driver's write probe performs one operator action.
///
/// **Two seconds, and the probe exists because the storm does not write often
/// enough to judge.** 11-03 measured the ninety-second lane arm at seed 11:
/// **zero** events play, all eighteen applied entries are link mutations, and
/// twenty seeds put the median at one or two events by ninety seconds. A soak
/// whose write invariant judged only `PanelWrite` entries would therefore take
/// **no** judgeable reading on every push — a checker at zero against a floor
/// of one, failing the vacuity gate, in the one arm that runs on every commit.
///
/// So the driver supplies operator actions at a fixed cadence and the storm
/// supplies the weather. That division is the point: the probe decides nothing
/// about *what happens to* a write — it writes into whatever the timeline has
/// armed, so a blackholed panel's probe times out into `unknown` and a
/// flapping one's may or may not land, which is exactly the distribution
/// invariant 2 needs and cannot manufacture honestly by staging outcomes on the
/// fake.
///
/// **It is not the driver authoring the storm.** Nothing here is drawn: the
/// panel, the key and the value are functions of a counter, so two runs of one
/// seed issue the same probe writes in the same order. The precedent is in this
/// file already — `GateBPlantDriver` moves every key every 250 ms and is not a
/// storm event either. What the timeline owns is the faults; what the harness
/// owns is a plant that moves and an operator who acts.
///
/// Two seconds gives forty-five writes in the lane arm and about a thousand at
/// thirty-five minutes, which is a floor with room and a per-tick cost of one
/// RPC.
const Duration writeProbeCadence = Duration(seconds: 2);

/// One probe in every [writeProbeReadOnlyEvery] goes to a key that cannot be
/// written, so `rejected` is in the distribution by construction.
///
/// **Four.** `rejected` is the one outcome a healthy pipe under a storm will
/// otherwise never produce — the fake plant takes every write it is given — and
/// invariant 2's distribution asserts all three states appeared. Without a
/// deliberate lever the assertion would fail every green run, which is the
/// worst kind of arm: one that has to be relaxed to be usable.
const int writeProbeReadOnlyEvery = 4;

/// The key the probe writes to when it wants a refusal.
///
/// **A `PIPE.` key, and the refusal is the shipping gateway's own.**
/// `LocalStateMan._settle` answers a `PipeKeyRoute` with
/// `WriteRejected('unroutable_key', status: 'Bad_NotWritable')` and the message
/// *"the key is in the gateway's own namespace, which is produced here and
/// never written into from a session"* — a permanent, real, read-only path,
/// not a lever bolted onto a fake for the occasion. 08-11's `readOnlyKey` is
/// the same idea one layer down, on `FakeStateMan`; this composition's
/// equivalent is the health namespace, and it has the advantage of being a key
/// every panel already subscribes.
final String soakReadOnlyKey = PipeKeys.connected;

/// How often the driver reads each panel's connectivity.
///
/// **Finer than [checkpointCadence], and the plan says "every checkpoint".**
/// Five seconds cannot see a panel that flapped down and back inside one
/// second, and a control-panel arm that misses the dip it exists to catch is
/// worse than no arm. The *floor* is evaluated on these samples and the numbers
/// are *journalled* at the checkpoint, so the artifact still reads at the
/// cadence everything else in it does.
const Duration panelSampleCadence = Duration(milliseconds: 250);

// -------------------------------------------------------- the population floor

/// How long the connected-panel count may sit below its floor.
///
/// **Seventy-five seconds, and the arithmetic is the point.** The floor is
/// `herdSize - 1`: one panel may be missing at any instant without penalty,
/// because the storm is entitled to take one down. What is not permitted is
/// staying there, and the window has to be long enough for the longest
/// *legitimate* excursion and short enough to catch a cull.
///
/// The longest legitimate excursion is a token revocation. The session closes
/// 4001 immediately, the panel's single redial is refused, and Phase 6 stops
/// its reconnect loop for good — by design, because a panel that retried a
/// rejected credential would hammer the gateway all shift. The paired
/// [TokenRestore] arrives at a drawn offset inside
/// `SoakEventSchedule.tokenRestoreWindow`, **60 s** at the outside, after which
/// this driver redials and the panel needs a hello and a snapshot. Sixty plus
/// fifteen seconds of slack for that redial is seventy-five.
///
/// What it still catches, and what a longer window would not: a redial loop
/// that gives up, a reaper taking live sessions, and a revocation whose restore
/// did not land — all three are *monotonic*, so they sit below the floor from
/// the moment they start until the end of the run.
///
/// **It is a weak instrument in the 90-second arm and that is stated rather
/// than hidden**: seventy-five of ninety seconds is most of the run, so the
/// short arm's floor catches only a pipe that never stood up. The 35-minute arm
/// is where this number earns its keep, which is the same division of labour
/// `soakDeviations` entry 1 draws for everything else in this phase.
///
/// Overridable per driver — `soak_driver_test.dart` shortens it so that the
/// case proving the floor trips is not itself seventy-five seconds long. What
/// that case is about is the trip, its offset and the run continuing; the value
/// of the grace is this constant's business and is argued here, once.
const Duration populationFloorGraceDefault = Duration(seconds: 75);

/// How many `trip-N.txt` records one run may leave behind.
///
/// **`violationLogCapacity`'s argument, applied to the disk.** The in-memory
/// log stops retaining at two hundred because "retaining them would make the
/// harness the leak it is measuring"; the trip writer had no cap at all, so
/// the artifact directory grew without bound where the log did not. A
/// `GatewayRestart` that exhausts its rebind budget fails every subsequent
/// write, and at the probe's one-per-two-seconds that is about 690 violations
/// over the rest of a thirty-five-minute arm — several megabytes of
/// near-identical records in the uploaded CI artifact.
///
/// **Twenty, not two hundred, and the difference is what a trip record is
/// for.** A retained violation is a row in a list; a trip record is four to
/// eight kilobytes with the last twenty checkpoints quoted inline, meant to be
/// OPENED. Nobody opens the two-hundredth. The first occurrence is the
/// diagnostic — the same argument `ViolationLog` makes for keeping the first
/// rather than the last — and [SoakDriver.tripRecordsSuppressed] says how many
/// were not written, so the cap cannot be mistaken for the count.
const int soakTripRecordCap = 20;

// ------------------------------------------------------------- the endpoint

/// Where the driver's panels dial.
///
/// **The seam, built now and deliberately not used yet.** 11-CONTEXT ruling 6
/// records the on-site arm against a deployed SVN gateway as a post-milestone
/// follow-up, and 11-RESEARCH open question 2's answer is that the cost of the
/// seam now is one field and the cost of retrofitting it later is a rewrite of
/// everything that composes. [SoakEndpoint.inProcess] is what every lane runs;
/// [SoakEndpoint.deployed] is the on-site arm's future consumer, and the driver
/// refuses it today with a message that says so rather than half-working.
final class SoakEndpoint {
  /// The gateway this process composes and owns. Every lane, today.
  const SoakEndpoint.inProcess() : deployedGateway = null;

  /// A gateway already running somewhere else — the on-site arm.
  const SoakEndpoint.deployed(Uri uri) : deployedGateway = uri;

  /// Null for [SoakEndpoint.inProcess].
  final Uri? deployedGateway;

  bool get isInProcess => deployedGateway == null;

  @override
  String toString() => deployedGateway?.toString() ?? 'in-process';
}

// -------------------------------------------------------------- the outcome

/// What one timeline entry actually did.
///
/// [lever] is the *name of the mechanism pulled*, not the name of the event —
/// `FakeUpstreamLink.disconnectUpstream` rather than `upstreamLinkDown`. That
/// distinction is what makes the arm-coverage case in `soak_driver_test.dart`
/// worth having on top of the sealed type: a switch collapsed into one
/// `default:` arm still compiles and still handles every event, but it cannot
/// produce fourteen distinct lever names.
final class SoakApplyOutcome {
  /// The lever was pulled and something happened.
  const SoakApplyOutcome.fired(this.kind, this.lever, {this.note})
      : fired = true;

  /// The lever was pulled and the world did not move — the storm quietly
  /// narrowing itself, which is a finding rather than a nothing.
  const SoakApplyOutcome.fizzled(this.kind, this.lever, String this.note)
      : fired = false;

  /// The `SoakEventKinds` name, or `link:<mode>` for the fault half.
  final String kind;

  /// The mechanism this arm pulls, spelled as the code spells it.
  final String lever;

  /// Whether the world moved.
  final bool fired;

  /// Why it did not, or anything worth journalling about a firing.
  final String? note;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'lever': lever,
        'fired': fired,
        if (note != null) 'note': note,
      };

  @override
  String toString() =>
      '$kind via $lever ${fired ? 'fired' : 'FIZZLED'}${note == null ? '' : ' — $note'}';
}

// -------------------------------------------------------------- the registry

/// One checker and the cadence the driver ticks it at.
///
/// The cadence belongs to the checker and not to the driver: a freshness
/// sampler at 25 ms and a rate window at one minute are two different
/// instruments, and a driver that ticked everything at one rate would either
/// make the fast one useless or the slow one a hot loop. [SoakDriver] holds no
/// opinion about what any of them measures.
final class SoakCheckerRegistration {
  const SoakCheckerRegistration(this.checker, this.cadence);

  /// 11-04's freshness sampler.
  SoakCheckerRegistration.fast(InvariantChecker checker)
      : this(checker, fastCheckerCadence);

  /// 11-05's and 11-06's checkpoint-cadence instruments.
  SoakCheckerRegistration.checkpoint(InvariantChecker checker)
      : this(checker, checkpointCadence);

  /// A per-minute rate window.
  SoakCheckerRegistration.perMinute(InvariantChecker checker)
      : this(checker, rateWindowCadence);

  final InvariantChecker checker;
  final Duration cadence;
}

// ------------------------------------------------------------ the population

/// What the driver knows about one panel's connectivity.
///
/// Connectivity only, and deliberately so: freshness is 11-04's, convergence is
/// 11-06's, and a driver that judged either would be a sixth checker nobody
/// declared. What is here is the input to the population floor, plus the two
/// counters that fall out of the same sampling for free and give the control's
/// arm something to be sharp about.
final class SoakPanelHealth {
  SoakPanelHealth(this.index);

  final int index;

  /// How many times this panel went from ready to not-ready.
  int readyDips = 0;

  /// How many samples found it not ready.
  int notReadySamples = 0;

  /// How many samples found its whole view stale.
  int staleViewSamples = 0;

  /// How many samples were taken at all — the denominator, without which the
  /// two counters above are numbers with no scale.
  int samples = 0;

  /// Link mutations the storm applied to this panel's proxy. **Zero for the
  /// control, by construction**, which is the assertion the whole design turns
  /// on.
  int mutationsApplied = 0;

  bool _wasReady = true;

  void observe({required bool ready, required bool staleView}) {
    samples++;
    if (!ready) {
      notReadySamples++;
      if (_wasReady) readyDips++;
    }
    if (staleView) staleViewSamples++;
    _wasReady = ready;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'panel': soakPanelName(index),
        'samples': samples,
        'readyDips': readyDips,
        'notReadySamples': notReadySamples,
        'staleViewSamples': staleViewSamples,
        'mutationsApplied': mutationsApplied,
      };

  @override
  String toString() => '${soakPanelName(index)}: $readyDips dips, '
      '$notReadySamples/$samples not ready, '
      '$staleViewSamples/$samples stale view, '
      '$mutationsApplied mutations';
}

// ---------------------------------------------------------------- the driver

/// The soak, as an object that can be ticked.
///
/// 11-RESEARCH §A.2's argument, which is the same one `long_outage_gate_test`
/// makes for checkpoints over end-state readings: five invariants sampled
/// continuously against five panels are five independent state machines with
/// five different cadences, and interleaved inside one `test()` body they share
/// one stack, one set of locals and one failure message. So the machinery is
/// here and `soak_test.dart` is thin.
///
/// It arrives with **zero checkers registered**, and that is deliberate. It
/// composes the pipe, plays the merged timeline, writes the journal, holds the
/// population and proves all of that at 90 seconds — real evidence on its own,
/// and the thing that must not bit-rot. 11-04, 11-05 and 11-06 then register
/// against a driver that already works.
final class SoakDriver
    implements
        SoakFreshnessSource,
        SoakWriteSource,
        SoakStructureSource,
        SoakLogSource,
        SoakResyncSource {
  SoakDriver({
    required this.seed,
    required this.duration,
    this.endpoint = const SoakEndpoint.inProcess(),
    this.checkers = const <SoakCheckerRegistration>[],
    this.journalPath = defaultSoakJournalDir,
    Map<String, String>? environment,
    SoakTimeline? timeline,
    int? herdSize,
    Duration? populationFloorGrace,
  })  : herdSize =
            herdSize ?? soakHerdSize(environment ?? Platform.environment),
        floorGrace = populationFloorGrace ?? populationFloorGraceDefault,
        _given = timeline;

  /// The run's seed. Both halves of the storm derive from it and nothing else
  /// does.
  @override
  final int seed;

  /// What the run was *declared* to be. Every floor scales off this and never
  /// off measured elapsed time — `invariant.dart`'s rule.
  final Duration duration;

  /// The same number, under the name the checkers' interface gives it.
  @override
  Duration get declaredDuration => duration;

  /// Where the panels dial.
  final SoakEndpoint endpoint;

  /// The checkers to tick, each at its own cadence.
  final List<SoakCheckerRegistration> checkers;

  /// Where `metrics.jsonl`, `events.jsonl`, `repro.log` and any trip records
  /// land.
  @override
  final String journalPath;

  /// How many panels, control included.
  final int herdSize;

  /// How long the connected count may sit below [populationFloor] before a
  /// violation is recorded. See [populationFloorGraceDefault] for the
  /// arithmetic.
  final Duration floorGrace;

  final SoakTimeline? _given;

  /// Panel names the storm is allowed to aim at — **everything but the
  /// control**. This is the list [buildTimeline] is given, and the reason the
  /// generated timeline cannot name the control at all.
  List<String> get stormPanels => <String>[
        for (var i = 0; i < herdSize; i++)
          if (i != soakControlPanelIndex) soakPanelName(i),
      ];

  /// The control's name, which no storm entry may contain.
  String get controlPanel => soakPanelName(soakControlPanelIndex);

  // ------------------------------------------------------- built by [start]

  SoakTimeline? _timeline;
  GateBFixture? _fixture;
  SoakJournal? _journal;
  SoakClock? _clock;
  Directory? _tokenDir;
  String? _tokenFilePath;

  /// The storm, once [start] has built or accepted it.
  SoakTimeline get timeline => _require(_timeline, 'timeline');

  /// The composed pipe.
  GateBFixture get fixture => _require(_fixture, 'fixture');

  /// The forensics sink.
  SoakJournal get journal => _require(_journal, 'journal');

  /// Monotonic elapsed and the declared duration. Nothing else.
  SoakClock get clock => _require(_clock, 'clock');

  T _require<T>(T? value, String what) => value ??
      (throw StateError('the soak driver has no $what until start() has '
          'completed; a caller reading one early wants to be told that rather '
          'than shown a default'));

  // ------------------------------------------------------------- observables

  /// Everything recorded, bounded — see [ViolationLog].
  final ViolationLog violationLog = ViolationLog();

  /// The recorded breaches, oldest first.
  List<SoakViolation> get violations => violationLog.entries;

  final List<SoakTimelineEntry> _applied = <SoakTimelineEntry>[];
  final List<SoakApplyOutcome> _outcomes = <SoakApplyOutcome>[];
  final List<String> _fizzled = <String>[];
  final Map<int, SoakPanelHealth> _health = <int, SoakPanelHealth>{};
  final Map<String, int> _leversByKind = <String, int>{};

  /// Timeline entries the driver reached and pulled a lever for, in order.
  List<SoakTimelineEntry> get applied =>
      List<SoakTimelineEntry>.unmodifiable(_applied);

  /// What every applied entry did.
  List<SoakApplyOutcome> get outcomes =>
      List<SoakApplyOutcome>.unmodifiable(_outcomes);

  /// Entries the run never reached — planned and not applied.
  List<SoakTimelineEntry> get neverReached => <SoakTimelineEntry>[
        for (final entry in timeline.merged)
          if (!_applied.contains(entry)) entry,
      ];

  /// Levers that fired into nothing, rendered for a report.
  List<String> get fizzled => List<String>.unmodifiable(_fizzled);

  /// Per-panel connectivity, keyed by index.
  Map<int, SoakPanelHealth> get health => Map<int, SoakPanelHealth>.unmodifiable(_health);

  /// The control's connectivity.
  SoakPanelHealth get controlHealth => _health[soakControlPanelIndex]!;

  // ------------------------------------------- what the checkers are given
  //
  // `SoakFreshnessSource` and `SoakWriteSource` are the two narrow views a
  // checker gets. They are implemented here rather than exposed as a second
  // object because everything they answer is already this class's — and
  // because a control that needs to substitute one answer should be able to
  // decorate one interface rather than stand up a parallel pipe.

  /// Where the storm has got to. Public because a violation recorded by a
  /// checker has to carry the timeline position, not just the wall offset.
  @override
  Duration get scheduleOffset => _playClock.elapsed;

  @override
  int get controlPanelIndex => soakControlPanelIndex;

  /// Every panel, control first, as the operator-facing surface a freshness
  /// checker reads.
  ///
  /// Rebuilt per call on purpose: [GateBFixture.redial] replaces a panel's
  /// `RemoteStateMan` outright (Phase 6 ends a refused panel's reconnect loop
  /// for good, so a restore is an application restart), and a view cached at
  /// `start()` would go on reading a disposed client for the rest of the run.
  @override
  List<SoakPanelView> get panelViews => <SoakPanelView>[
        for (var i = 0; i < fixture.panels.length; i++)
          _LivePanelView(i, fixture.panels[i].client),
      ];

  /// Every key every panel subscribed, health keys included.
  ///
  /// Deliberately **not** filtered to [plantKeys]: the `PIPE.` exclusion is the
  /// checker's, by prefix, and handing it a pre-filtered list would move the
  /// decision here and leave the prefix arm proving nothing (08-PATTERNS
  /// freeze 8).
  @override
  List<String> get freshnessKeys => fixture.keys.toList(growable: false);

  @override
  Duration get freshnessBudget => soakFreshnessBudget;

  // ----------------------------------------------------- what invariant 3 reads

  /// Every panel's convergence surface, control first.
  ///
  /// Rebuilt per call for [panelViews]' reason, with one addition: the
  /// gateway-side rebuild counter is read through the session whose identity
  /// names this panel, and a panel with no live session carries its last known
  /// count rather than reporting zero. Reporting zero would make every
  /// disconnection look like the page having been rebuilt back to the
  /// beginning, which is the one reading the `lostPush` detector must not get
  /// wrong.
  @override
  List<SoakPanelResyncView> get panelResyncViews => <SoakPanelResyncView>[
        for (var i = 0; i < fixture.panels.length; i++)
          _LivePanelResyncView(
              i, fixture.panels[i].client, _pageRebuildsFor(soakPanelName(i))),
      ];

  @override
  List<StableWindow> get stableWindows => timeline.stableWindows;

  @override
  Duration get plantSweepPeriod => soakSweepPeriod;

  /// The aliases whose epoch bump is still settling.
  ///
  /// **Bounded to one settling span, and that bound is the property.** See the
  /// `UpstreamEpochBump` arm for why: an entry here is subtracted from
  /// `DivergenceLedger.residue` *and* missing from `countOf(unattributed)`, so
  /// a stale entry moves both halves of the keyframe verdict at once.
  @override
  Set<String> get epochBumpedAliases => Set<String>.unmodifiable(_epochBumped);

  final Set<String> _epochBumped = <String>{};

  /// Which bump each alias's pending recovery belongs to, so a later bump
  /// extends the exemption instead of an earlier recovery ending it early.
  final Map<String, int> _epochBumpGeneration = <String, int>{};

  /// The keys a `PlantMutate` has pinned, and to what.
  ///
  /// **The soak's own record of what it told the plant to do.** `overrideRaw`
  /// files the value inside `GateBPlantDriver`'s private map, so the only way
  /// to read plant truth back would be to ask the client — which is the one
  /// thing invariant 3 must not do, because it would be comparing a cache with
  /// itself. Recorded here at the instant the lever is pulled, which is also
  /// the instant the timeline says it happened.
  final Map<String, Object?> _plantOverrides = <String, Object?>{};

  /// What the plant is publishing for [key] right now.
  ///
  /// Two shapes — see [SoakPlantTruth]. An overridden key answers with the
  /// value the soak scripted; every other key answers with the sweep counter,
  /// because `GateBPlantDriver` writes one monotonically increasing integer to
  /// every clean key of every link on every cycle.
  @override
  SoakPlantTruth? plantTruthFor(String key) {
    final alias = key.split('.').first;
    if (!soakAliases.contains(alias)) return null;
    if (_plantOverrides.containsKey(key)) {
      return SoakPlantTruth(value: _plantOverrides[key], overridden: true);
    }
    final latest = fixture.driver.latest;
    if (latest == null) return null;
    return SoakPlantTruth(value: latest, overridden: false, sweepIndex: latest);
  }

  /// The gateway's rebuild counter for one panel's page.
  ///
  /// `SubscriptionState.generation`, the reading `divergence_gate_test.dart`
  /// takes as `_rebuildsServed` — one generation is minted per subscribe from a
  /// gateway-wide counter, so it rises on every re-establishment and never
  /// falls. Sessions are matched by `StationIdentity.station`, which the soak's
  /// own token file sets to the panel's name (`_writeTokenFile`).
  int _pageRebuildsFor(String panel) {
    if (_fixture == null) return 0;
    for (final session in fixture.server.sessions.sessions) {
      if (session.identity?.station != panel) continue;
      final state = session.subscriptions.get(defaultPageSubscription);
      if (state == null) continue;
      return _lastRebuilds[panel] = state.generation;
    }
    return _lastRebuilds[panel] ?? 0;
  }

  final Map<String, int> _lastRebuilds = <String, int>{};

  /// How many plant-wide arms the storm has applied so far.
  ///
  /// The control's freshness arm is written against the panel-TARGETED half of
  /// the storm only, and this is the number that lets it be. `GatewayRestart`,
  /// `KeymappingReload` and every upstream arm belong to everybody — the
  /// control's property is *"the storm never AIMS at it"*, which
  /// [_refuseIfTheStormCanReachTheControl] enforces, and not *"it is never
  /// disturbed"*, which nothing could.
  @override
  int get plantWideArmsApplied => _plantWideArms;

  int _plantWideArms = 0;

  /// What the plant applied, for the whole run — the record §7.8 asked for and
  /// `WriteOutcomeLog` cannot be. See [AppliedWriteLedger] for deviation 3.
  @override
  final AppliedWriteLedger appliedWrites = AppliedWriteLedger();

  final List<SoakWriteRecord> _writeRecords = <SoakWriteRecord>[];

  @override
  List<SoakWriteRecord> get writeRecords =>
      List<SoakWriteRecord>.unmodifiable(_writeRecords);

  /// Every command every panel still considers in flight.
  ///
  /// Union across the herd, and read live rather than mirrored: a mirror can
  /// disagree with the client, and the one thing worse than not knowing whether
  /// a write is outstanding is being told the wrong answer.
  @override
  List<String> get unresolvedCmds => <String>[
        if (_fixture != null)
          for (final panel in fixture.panels) ...panel.client.debugUnresolvedCmds,
      ];

  /// Commands that went down with a client [GateBFixture.redial] replaced.
  ///
  /// **Read at the instant it is asked rather than captured at the redial, and
  /// the difference is a race.** [issueWrite] reads its client before its
  /// `await` and `redial` is fired un-awaited from the `TokenRestore` arm, so a
  /// write still in flight lands in the retired client *after* a capture would
  /// have run. Nothing removes from a disposed client's `_unresolved` —
  /// `RemoteStateMan.dispose` never touches it — so reading it late is a strict
  /// superset of anything a capture could have seen, and cannot miss a
  /// straggler.
  ///
  /// The offsets that make an orphan attributable come from [panelRestarts]
  /// instead, which records the event rather than the set.
  @override
  List<String> get orphanedCmds => <String>[
        if (_fixture != null)
          for (final retired in fixture.retiredClients)
            ...retired.debugUnresolvedCmds,
      ];

  @override
  List<SoakPanelRestart> get panelRestarts =>
      List<SoakPanelRestart>.unmodifiable(_panelRestarts);

  final List<SoakPanelRestart> _panelRestarts = <SoakPanelRestart>[];

  /// How many writes the probe has issued. A denominator for the verdict block.
  int get probeWrites => _probeWrites;
  int _probeWrites = 0;

  /// How many probes fell due inside a stable window and were held.
  ///
  /// Printed on the verdict's writes line, so a run's write count names the
  /// cadence it actually kept rather than the one the timer promised.
  int get probeWritesWithheld => _probeWritesWithheld;
  int _probeWritesWithheld = 0;

  // ------------------------------------------- what invariant 4 is given
  //
  // One method rather than ten getters, because the readings in a checkpoint
  // row have to be SIMULTANEOUS. Ten pulls under a storm can straddle a gateway
  // restart, and a row with a session count from before it and a subscription
  // count from after is a row that reads as a leak.

  /// Every watched structure, read at one instant.
  ///
  /// **RSS is not here.** The allocator's number is written by [_checkpoint]
  /// into `metrics.jsonl` at this same cadence and is read by no assertion
  /// anywhere — `bounded_memory.dart` quotes the doctrine in full and
  /// `soak_meta_test.dart` sweeps the tree for the spelling.
  @override
  SoakStructureReading readStructures() {
    if (_fixture == null) {
      return const SoakStructureReading(
        perPanel: <int, Map<String, int>>{},
        plantWide: <String, int>{},
      );
    }
    final panels = fixture.panels;
    final perPanel = <int, Map<String, int>>{
      for (var i = 0; i < panels.length; i++)
        i: <String, int>{
          unresolvedCmdsStructure: panels[i].client.debugUnresolvedCmds.length,
          complaintsStructure: panels[i].client.complaints.length,
          staleSubscriptionsStructure:
              panels[i].client.debugStaleSubscriptionsAtLastTick.length,
          writeStatusQueriesStructure:
              panels[i].client.debugWriteStatusQueries.length,
        },
    };

    // The send-buffer clause, through the shipping health verdict. The raw
    // depth lives on a private `_Connection` and nothing public hands it out;
    // `PIPE.link_degraded` is `pendingCount > ceiling || pendingBytes >
    // byteCeiling` composed by the gateway itself. See
    // `degradedPanelsStructure` for the whole argument, including the fact that
    // `pendingBytes` is the priority lane only.
    var degraded = 0;
    for (final panel in panels) {
      final verdict = panel.client.read(PipeKeys.linkDegraded);
      if (verdict?.value == true) degraded++;
    }

    final server = fixture.server;
    final plantWide = <String, int>{
      recordedOutcomesStructure: server.writeOutcomes.recordedOutcomes,
      sessionsStructure: server.sessions.sessionCount,
      subscriptionsStructure: server.sessions.subscriptionCount,
      listenersStructure: server.sessions.listenerCount,
      degradedPanelsStructure: degraded,
    };
    final skips = <String, String>{};
    final carried = <String>{};
    if (!canCountOpenSockets) {
      // By name, in the platform's own words, never by silence.
      skips[openSocketsStructure] = openSocketCountSkipReason;
    } else {
      // On its own cadence: the macOS branch of `openSocketCount()` is a
      // SYNCHRONOUS `lsof` subprocess, measured at ~50 ms with the isolate
      // stopped, and a soak about behaviour under stress must not spend 1 % of
      // itself frozen inside its own instrument. See
      // `openSocketCheckpointCadence`.
      if (_structureReadings % openSocketCheckpointCadence == 0) {
        _lastOpenSockets = openSocketCount();
      } else {
        carried.add(openSocketsStructure);
      }
      plantWide[openSocketsStructure] = _lastOpenSockets;
    }
    _structureReadings++;
    return SoakStructureReading(
      perPanel: perPanel,
      plantWide: plantWide,
      skips: skips,
      carriedForward: carried,
    );
  }

  int _structureReadings = 0;
  int _lastOpenSockets = 0;

  // ------------------------------------------- what invariant 5 is given

  @override
  List<SoakPanelLogView> get panelLogs => <SoakPanelLogView>[
        if (_fixture != null)
          for (var i = 0; i < fixture.panels.length; i++)
            _LivePanelLogView(i, fixture.panels[i].client,
                _health[i]?.readyDips ?? 0),
      ];

  /// Lines the gateway has produced, through the seam a deployed gateway logs
  /// through.
  ///
  /// `buildGateway`'s default is `_logServerError(log)` —
  /// `gateway_config.dart:492-497`, installed at `:643` — so the fixture's
  /// collector holds exactly the lines the plant's gateway would have written.
  @override
  int get gatewayLogLines =>
      _fixture == null ? 0 : fixture.gatewayComplaints.length;

  /// Ingest refusals that actually reached a sink — `IngestLog.logged`, damped
  /// to once per key per process.
  @override
  int get plantIngestLogLines =>
      _fixture == null ? 0 : fixture.plant.ingestLog.logged;

  /// How many panels are ready right now.
  int get connectedPanels => _fixture == null
      ? 0
      : fixture.panels.where((one) => one.client.isReady).length;

  /// The floor the connected count must return to.
  int get populationFloor => herdSize - 1;

  Duration? _belowFloorSince;

  /// The longest continuous stretch spent below [populationFloor].
  Duration worstBelowFloor = Duration.zero;

  /// `planned` against `applied`, in `ScenarioPlayback.divergenceReport`'s
  /// shape and for its reason: a divergence between what was planned and what
  /// happened is the failure a soak cannot otherwise see, because both halves
  /// look fine on their own.
  String get divergenceReport {
    final missed = neverReached;
    return <String>[
      timeline.reproLog,
      '--- applied ${_applied.length} of ${timeline.merged.length} ---',
      for (final entry in _applied) entry.toString(),
      if (missed.isNotEmpty) ...<String>[
        '--- planned and NEVER REACHED (${missed.length}) ---',
        for (final entry in missed) entry.toString(),
      ],
      if (_fizzled.isNotEmpty) ...<String>[
        '--- applied and FIRED INTO NOTHING (${_fizzled.length}) ---',
        ..._fizzled,
      ],
    ].join('\n');
  }

  /// One line per checker, plus the driver's own population and control lines.
  ///
  /// **Printed on a green run too.** A green run's numbers are the baseline the
  /// next red run is read against, and a block that only appears on failure is
  /// a block nobody has ever seen working.
  String get verdictBlock {
    final lines = <String>[
      'soak verdict — seed=$seed duration=$duration endpoint=$endpoint',
      '  timeline    : ${timeline.merged.length} planned, '
          '${_applied.length} applied, ${neverReached.length} never reached, '
          '${_fizzled.length} fired into nothing',
      '  levers      : ${_leversByKind.entries.map((e) => '${e.key}:${e.value}').join(', ')}',
      if (tripRecordsSuppressed > 0)
        '  trip records: capped at $soakTripRecordCap; '
            '$tripRecordsSuppressed further violations left no file. The '
            'first occurrences are the diagnosis and they are all here',
      '  population  : floor $populationFloor of $herdSize, connected now '
          '$connectedPanels, worst stretch below floor '
          '${formatSoakOffset(worstBelowFloor)} (grace '
          '${formatSoakOffset(floorGrace)})',
      for (var i = 0; i < herdSize; i++)
        '  ${i == soakControlPanelIndex ? 'CONTROL     ' : 'panel $i     '}: '
            '${_health[i]}',
    ];
    if (checkers.isEmpty) {
      lines.add('  checkers    : none registered — 11-04, 11-05 and 11-06 '
          'each add theirs against a driver that already works');
    } else {
      for (final registration in checkers) {
        final checker = registration.checker;
        lines.add('  ${checker.name.padRight(12)}: '
            '${checker.judgedSamples} judged readings against a floor of '
            '${checker.minimumSamplesForAVerdict}, ticked every '
            '${registration.cadence.inMilliseconds} ms, '
            '${checker.violationTotal} violations'
            '${checker.violationOverflow > 0 ? ' (${checker.violations.length} retained, ${checker.violationOverflow} past the cap)' : ''}');
        // A checker's own counters, when it has any worth reading. The two
        // numbers that make invariant 1's green mean something — did anything
        // ever go stale, did anything ever recover — are not on the interface
        // and would otherwise print nowhere.
        final own = checker.toString();
        if (!own.startsWith('Instance of')) {
          lines.add('                $own');
        }
      }
    }
    // Declared names with nothing registered against them, so the audit reads
    // as INCOMPLETE rather than as complete-and-passing. A missing checker is
    // otherwise invisible: the block prints one row per registration, so an
    // invariant nobody wrote simply has no row, which looks exactly like an
    // invariant that had nothing to say.
    final registered = <String>{for (final one in checkers) one.checker.name};
    final pending = <String>[
      for (final name in declaredCheckers)
        if (!registered.contains(name)) name,
    ];
    if (pending.isNotEmpty) {
      lines.add('  PENDING     : ${pending.join(', ')} — declared in '
          'soak_registry.dart and not registered, so this audit is incomplete '
          'rather than complete and passing');
    }
    // The shared observable, said once. Invariants 4 and 5 both watch
    // `complaints.length`, so a genuine flood trips both — and a report in
    // which they appear as two independent findings corroborating each other
    // is pitfall 8 exactly. The sentence is the deliverable.
    final shared = sharedObservableFindings(
        <InvariantChecker>[for (final one in checkers) one.checker]);
    if (shared != null) lines.add(shared);
    lines.add('  writes      : $_writesIssued issued ($_probeWrites by the '
        'probe every ${writeProbeCadence.inSeconds}s, one in '
        '$writeProbeReadOnlyEvery to $soakReadOnlyKey), $appliedWrites');
    lines.add('  violations  : ${violationLog.total} recorded '
        '(${violationLog.entries.length} retained, ${violationLog.overflow} '
        'overflowed)');
    if (violationLog.entries.isNotEmpty) {
      lines.add('  first       : ${violationLog.entries.first}');
    }
    return lines.join('\n');
  }

  // ------------------------------------------------------------------ the run

  /// Builds the storm, refuses one that can reach the control, composes the
  /// pipe, writes `repro.log` and `config.json`, and starts the clock.
  ///
  /// **The refusal is the point and it happens before anything is composed.** A
  /// control panel the storm can reach is not a control, and the failure would
  /// otherwise be silent: every assertion still passes, and the one arm that
  /// could have caught a gateway punishing healthy panels has quietly stopped
  /// being able to.
  Future<void> start() async {
    if (!endpoint.isInProcess) {
      throw UnsupportedError('this driver composes its own gateway; dialling '
          '${endpoint.deployedGateway} is the on-site arm, which 11-CONTEXT '
          'ruling 6 records as a post-milestone follow-up. The seam is here '
          'so that arm is a change to this method rather than a rewrite of '
          'everything that composes — it is deliberately not built');
    }

    final storm = _given ??
        buildTimeline(
          seed: seed,
          duration: duration,
          // The control's name is NOT in this list, and that is the whole
          // mechanism: `soak_event.dart`'s contract puts the exclusion on the
          // caller because the generator cannot tell one panel from another.
          panels: stormPanels,
          aliases: soakAliases,
          keys: stormKeys,
        );
    _refuseIfTheStormCanReachTheControl(storm);
    _timeline = storm;

    // Before anything is composed: a run killed on the way up still leaves its
    // seed and its timeline behind.
    final journal = _journal = SoakJournal.open(seed: seed, path: journalPath);
    journal.writeReproLog(storm.reproLog);
    journal.writeConfig(<String, Object?>{
      'declaredDurationMs': duration.inMilliseconds,
      'herdSize': herdSize,
      'controlPanel': controlPanel,
      'stormPanels': stormPanels,
      'aliases': soakAliases,
      'keysPerAlias': soakKeysPerAlias,
      'sweepPeriodMs': soakSweepPeriod.inMilliseconds,
      'populationFloor': populationFloor,
      'populationFloorGraceMs': floorGrace.inMilliseconds,
      'panelSampleCadenceMs': panelSampleCadence.inMilliseconds,
      'checkpointCadenceMs': checkpointCadence.inMilliseconds,
      'endpoint': endpoint.toString(),
      'checkers': <String>[for (final one in checkers) one.checker.name],
      'mergedEntries': storm.merged.length,
      'stableWindows': storm.stableWindows.length,
    });

    _tokenDir = Directory.systemTemp.createTempSync('relay-soak-tokens-');
    _tokenFilePath = '${_tokenDir!.path}/tokens.json';
    _writeTokenFile();

    _fixture = await gateBFixture(
      panels: herdSize,
      aliases: soakAliases,
      keysPerAlias: soakKeysPerAlias,
      proxyPerPanel: true,
      sweepPeriod: soakSweepPeriod,
      staleAfter: soakStaleAfter,
      serverConfig: ServerConfig(
        tick: ServerConfig.minTick,
        auth: AuthConfig(tokenFilePath: _tokenFilePath!),
      ),
      tokenFor: _tokenForPanel,
    );

    for (var i = 0; i < herdSize; i++) {
      _health[i] = SoakPanelHealth(i);
    }
    // The plant-side record, hung off the TEST fake and nowhere near lib/ —
    // see AppliedWriteLedger's doc for deviation 3, and freeze 10 for the pin.
    for (final link in fixture.links) {
      link.inner.onWriteApplied = (key, value, cmd) =>
          appliedWrites.recordApplied(key: key, value: value, cmd: cmd);
    }
    _clock = SoakClock(declaredDuration: duration);
    _ensureWriteWatch();
    _startTickers();
  }

  /// Walks [SoakTimeline.merged] on one chained timer and returns when the run
  /// has played out or [stop] has been called.
  ///
  /// One timer, chained off one [Stopwatch], for `ScenarioPlayback`'s two
  /// reasons held whole: a lever that takes a moment to apply does not push
  /// every later offset out, and there is only ever one pending timer, so "no
  /// timer fires after [stop]" is a property of the shape rather than a
  /// bookkeeping claim.
  ///
  /// The run does not end at the last entry — it ends at [duration]. A storm
  /// whose last draw lands at minute 31 still has four minutes of plant, of
  /// checkers and of the population floor to answer for.
  Future<void> play() async {
    if (_stopped) {
      throw StateError('this driver has been stopped; build a new one rather '
          'than restarting it — a stopped driver schedules nothing, so play() '
          'would return a future that never completes and the failure would '
          'name the test file instead of this object');
    }
    final existing = _finished;
    if (existing != null) return existing.future;
    final finished = _finished = Completer<void>();
    _playClock.start();
    _schedule();
    await finished.future;
    // Whatever is still in flight — a write, a query, a redial — is given the
    // chance to land and to record itself before the verdict is read. `.wait`
    // rather than a loop of awaits: every one of these already carries its own
    // catchError into the violation log, so none of them can throw here.
    await Future.wait(_inFlight);
    _runEndPass();
  }

  /// Asks every checker the questions that can only be answered once.
  ///
  /// After the last entry and the last in-flight future, before the verdict
  /// block is read — so a distribution failure prints in the same block as the
  /// counters that explain it. A [SoakRunEndCheck] that throws is recorded here
  /// rather than allowed out: [GuardedSampling] makes that true for `sample`,
  /// and a run-end pass that took the whole verdict with it would be the same
  /// failure one call later.
  void _runEndPass() {
    for (final registration in checkers) {
      final checker = registration.checker;
      if (checker is! SoakRunEndCheck) continue;
      final endCheck = checker as SoakRunEndCheck;
      try {
        endCheck.finish();
      } catch (error) {
        _record(SoakViolation(
          checker: checker.name,
          monotonic: clock.elapsed,
          scheduleOffset: _playClock.elapsed,
          detail: 'the run-end pass threw, so this checker\'s whole-run '
              'questions — its distribution and its control arms — went '
              'unasked: $error',
        ));
      }
    }
  }

  /// [start], then [play]. The whole run, minus the verdict, which the caller
  /// prints.
  Future<void> run() async {
    await start();
    await play();
  }

  /// Stops the storm and every ticker. Idempotent, and no timer fires after it.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _pending?.cancel();
    _pending = null;
    _playClock.stop();
    for (final ticker in _tickers) {
      ticker.cancel();
    }
    _tickers.clear();
    for (final recovery in _recoveries) {
      recovery.cancel();
    }
    _recoveries.clear();
    final finished = _finished;
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  /// Backwards, no `.timeout`, journal last.
  ///
  /// Backwards because that is the order `gate_b_fixture.dart` argues for and
  /// this driver is one layer above it: tickers, then the storm, then the pipe,
  /// then the journal. The journal goes last because it is the only thing a
  /// failed run leaves behind, and a `.timeout` on a dispose path is a sink
  /// half-written (project memory: no `.timeout` in dispose paths).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    // **Every step in a `finally`, and the journal in the outermost one.**
    // The ordering argument above is only safe if nothing before the journal
    // can throw, and plenty can: cancelling subscriptions on clients a redial
    // replaced, `fixture.dispose()` awaiting five panel disposals and a server
    // close and five `proxy.shutdown()`s — on sockets the storm has been
    // shutting down all run — and a recursive delete of the token directory.
    // A `FaultProxy.shutdown()` throwing there used to skip `_journal.close()`
    // entirely, leaving `metrics.jsonl` and `events.jsonl` holding whatever
    // `IOSink` buffering had not flushed: the last checkpoints and the last
    // applied events, which are exactly what a trip at minute 34 is diagnosed
    // from. `_disposed` is set at the top so a second call is a no-op, and
    // `addTearDown(driver.dispose)` is the only caller, so nobody retried.
    try {
      try {
        for (final held in _subscriptions.values) {
          await held.sub.cancel();
        }
        _subscriptions.clear();
        for (final watch in _writeWatches) {
          await watch.cancel();
        }
        _writeWatches.clear();
        _watchedClients.clear();
      } finally {
        await _fixture?.dispose();
      }
    } finally {
      try {
        final dir = _tokenDir;
        if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
      } finally {
        // Last, and with no timeout: the artifact is the only thing a failed
        // run leaves behind.
        await _journal?.close();
      }
    }
  }

  // ---------------------------------------------------------------- internals

  final Stopwatch _playClock = Stopwatch();
  final List<Timer> _tickers = <Timer>[];
  final List<Timer> _recoveries = <Timer>[];
  final List<Future<void>> _inFlight = <Future<void>>[];
  /// Live storm-opened subscriptions, by `panel|key`, **with the client that
  /// holds them**.
  ///
  /// The client is half the key in effect: [GateBFixture.redial] replaces a
  /// panel's `RemoteStateMan` outright and a handle filed against the old one
  /// names a subscription on a disposed object. The driver rebuilds
  /// `panelViews`, `panelResyncViews` and `panelLogs` per call for exactly
  /// this reason; this map was the one that did not, so a later
  /// `PanelSubscribe` reported "already held" about a dead client and a later
  /// `PanelUnsubscribe` reported "dropped" for cancelling nothing.
  final Map<String, ({RemoteStateMan client, StreamSubscription<DynamicValue> sub})>
      _subscriptions = <String, ({RemoteStateMan client, StreamSubscription<DynamicValue> sub})>{};

  /// The live subscription under [handle], dropping it if the client that
  /// opened it has since been replaced.
  StreamSubscription<DynamicValue>? _liveSubscription(
      String handle, RemoteStateMan current) {
    final held = _subscriptions[handle];
    if (held == null) return null;
    if (identical(held.client, current)) return held.sub;
    // The old client is disposed, so its subscription is already dead; drop
    // the handle rather than cancelling into a closed object.
    _subscriptions.remove(handle);
    return null;
  }
  final Set<int> _revoked = <int>{};
  Completer<void>? _finished;
  Timer? _pending;
  int _index = 0;
  int _reloads = 0;
  bool _stopped = false;
  bool _disposed = false;

  /// Plant keys only — the `PIPE.*` health keys the fixture also subscribes are
  /// deliberately not here.
  ///
  /// `[MT-6]`'s instruction is that the driver must not make 11-04's job
  /// harder: its freshness checker excludes the health keys by prefix, because
  /// a `PIPE.` value is the pipe reporting on itself and is not a plant reading
  /// that can be stale. Rather than only avoiding the problem, this getter
  /// hands the next plan the exact set it wants.
  List<String> get plantKeys => <String>[
        for (final alias in soakAliases) ...gateBPage(alias, soakKeysPerAlias),
      ];

  /// The key pool the storm draws its writes and mutations from.
  ///
  /// A slice of [plantKeys] rather than all of it, matching
  /// `SoakEventSchedule.keysPerAlias`: a storm that spread its mutations over
  /// forty keys would touch each one about twice in thirty-five minutes, and
  /// invariant 3's comparison wants keys that actually move.
  List<String> get stormKeys => <String>[
        for (final alias in soakAliases)
          ...gateBPage(alias, soakKeysPerAlias)
              .take(SoakEventSchedule.keysPerAlias),
      ];

  /// Panel *i*'s credential. Deterministic, long enough for
  /// `FileTokenValidator.minTokenLength`, and visibly a fixture rather than
  /// something anybody would mistake for a plant secret.
  String _tokenForPanel(int index) => soakTokenForPanel(index);

  /// Writes the credential set as it now stands, owner-only.
  ///
  /// **A file rewrite, not an in-memory call, and that is the shape of the real
  /// mechanism.** `AuthConfig` holds a path and never a secret, so revocation
  /// at SVN is an operator editing the mounted file and the gateway re-reading
  /// it. `RelayServer.reloadTokens` is the re-read; this is the edit.
  void _writeTokenFile() {
    final path = _tokenFilePath!;
    File(path).writeAsStringSync(jsonEncode(<String, Object?>{
      'tokens': <String, Object?>{
        for (var i = 0; i < herdSize; i++)
          if (!_revoked.contains(i))
            // 17-04b's user model: the file names a USER and a STATION and has
            // structurally nowhere to put a grant — a `role` key here is
            // refused at load. What the station may do comes from the account
            // the resolver answers with (`soakAccounts` in
            // `gate_b_fixture.dart`), not from this file.
            _tokenForPanel(i): <String, Object?>{
              'username': soakPanelName(i),
              'station': soakPanelName(i),
            },
      },
    }));
    if (!Platform.isWindows) {
      // `FileTokenValidator.load` refuses a credential file any other account
      // can read, which is the right rule and one a temp file does not meet by
      // default.
      Process.runSync('chmod', <String>['600', path]);
    }
  }

  /// Throws unless every entry of [storm] leaves the control alone.
  void _refuseIfTheStormCanReachTheControl(SoakTimeline storm) {
    if (storm.panels.contains(controlPanel)) {
      throw StateError('this timeline was generated with $controlPanel in its '
          'panel list, so the storm may aim at the control. The exclusion is '
          'the CALLER\'s — soak_event.dart cannot tell a control panel from an '
          'ordinary one — and a control the storm can reach is not a control: '
          'every invariant still passes and the one arm that could catch a '
          'gateway punishing healthy panels has quietly stopped being able to');
    }
    for (final entry in storm.merged) {
      final payload = entry.payload;
      if (payload is! SoakEvent) continue;
      final aimed = _panelNamedBy(payload);
      if (aimed == controlPanel) {
        throw StateError('timeline entry $entry aims at $controlPanel, which '
            'is the control panel this run\'s strongest assertion rests on. '
            'A control the storm can reach is not a control, and the failure '
            'would be silent — every invariant would still pass');
      }
    }
  }

  /// Which panel an event is aimed at, or null for the plant-wide arms.
  String? _panelNamedBy(SoakEvent event) => switch (event) {
        PanelSubscribe(:final panel) => panel,
        PanelUnsubscribe(:final panel) => panel,
        PanelWrite(:final panel) => panel,
        PanelQuery(:final panel) => panel,
        TokenRevocation(:final stationId) => stationId,
        TokenRestore(:final stationId) => stationId,
        // Plant-wide by nature: an upstream link, an epoch, the routing table
        // and the gateway process itself belong to everybody. The control is
        // not exempt from a gateway restart — nothing could make it so — which
        // is why the control's property is "the storm never AIMS at it" rather
        // than "it is never disturbed".
        UpstreamLinkDown() ||
        UpstreamLinkUp() ||
        UpstreamEpochBump() ||
        UpstreamMassDegrade() ||
        UpstreamSlowResolve() ||
        GatewayRestart() ||
        KeymappingReload() ||
        PlantMutate() =>
          null,
      };

  int _indexOfPanel(String name) {
    for (var i = 0; i < herdSize; i++) {
      if (soakPanelName(i) == name) return i;
    }
    throw StateError('no panel named "$name" in a herd of $herdSize');
  }

  void _startTickers() {
    _tickers.add(Timer.periodic(panelSampleCadence, (_) => _samplePanels()));
    _tickers.add(Timer.periodic(checkpointCadence, (_) => _checkpoint()));
    _tickers.add(Timer.periodic(writeProbeCadence, (_) => _probeWrite()));
    for (final registration in checkers) {
      _tickers.add(Timer.periodic(registration.cadence,
          (_) => registration.checker.sample(clock)));
    }
  }

  // ------------------------------------------------------------ the writes

  /// One synthetic operator action. See [writeProbeCadence] for why it exists.
  ///
  /// Everything about it is a function of the counter — which panel, which key,
  /// which value — so two runs of one seed issue the same probe writes in the
  /// same order. Nothing here is drawn and nothing reads a clock.
  void _probeWrite() {
    if (_stopped || _disposed || _fixture == null) return;
    final n = _probeWrites++;
    final readOnly = n % writeProbeReadOnlyEvery == 0;
    final keys = plantKeys;
    _track(
      issueWrite(
        panelIndex: n % herdSize,
        key: readOnly ? soakReadOnlyKey : keys[n % keys.length],
        // Unique per write, which is what makes
        // `AppliedWriteLedger.appearances(key, value)` a clean duplicate test:
        // two applications of one pair can then only be one write applied
        // twice.
        value: _probeValueBase + n,
        probe: true,
      ),
      'the write probe\'s action $n',
    );
  }

  /// Writes are numbered from here so a probe value cannot collide with the
  /// plant sweep's own counter, which starts at 1000 and climbs by one per
  /// sweep (`GateBPlantDriver.from`).
  static const int _probeValueBase = 900000;

  /// Issues one write, records what it did, and never throws.
  ///
  /// **The cmd is minted here rather than by the client, and there are two
  /// reasons that are not "convenience".**
  ///
  ///  1. The plant-side ledger has to be told which panel acted **before** the
  ///     write crosses. An `UpstreamLink.write` arrives with a key, a value and
  ///     a cmd and no station id, so attribution after the fact would race the
  ///     application on a fast link.
  ///  2. `writeStatus` decodes the id as a ULID (`value_handlers.dart:752`) and
  ///     answers `unrecognized_cmd` to anything else — so an invented id would
  ///     leave every re-queried write permanently unresolved and invariant 2's
  ///     late-resolution half would never fire once. [newUlid] is the same
  ///     generator the client would have used, called one layer out.
  ///
  /// `cmd:` is a documented parameter of `StateManApi.write` for exactly this
  /// case — a caller relaying an action already minted upstream of it — so this
  /// is a production path rather than a seam invented for the soak. The storm's
  /// own `PanelWrite` entries go through here too, so the run has one write
  /// path and not two.
  Future<void> issueWrite({
    required int panelIndex,
    required String key,
    required Object? value,
    required bool probe,
  }) async {
    final panel = soakPanelName(panelIndex);
    final client = fixture.panels[panelIndex].client;
    final cmd = newUlid();
    final nth = ++_writesIssued;
    appliedWrites.attribute(cmd, panel);
    _writeRecords.add(SoakWriteRecord(
      nth: nth,
      cmd: cmd,
      panel: panel,
      key: key,
      value: value,
      stage: SoakWriteStage.issued,
      at: _playClock.elapsed,
      probe: probe,
    ));

    WriteResult result;
    try {
      result = await client.write(key, value, cmd: cmd);
    } catch (error) {
      // `write` promises never to throw to report an outcome, so anything here
      // is a defect in the process rather than a condition of the plant —
      // recorded as a violation and not swallowed into a fourth outcome.
      _record(SoakViolation(
        checker: 'population',
        monotonic: clock.elapsed,
        scheduleOffset: _playClock.elapsed,
        panel: panel,
        key: key,
        detail: 'write threw instead of reporting an outcome, which the API '
            'promises it never does (no queue, no retry, three states): '
            '$error',
      ));
      return;
    }

    // **The reached-a-socket question, asked the only way it can be from
    // outside.** An established outcome is proof the far side answered. An
    // `unknown` is ambiguous, and the client itself has already resolved the
    // ambiguity: it keeps a dispatched command in `_unresolved` and drops an
    // undispatched one immediately (`remote_state_man.dart:832-836`).
    final reached = result is! WriteUnknown ||
        client.debugUnresolvedCmds.contains(cmd);
    _writeRecords.add(SoakWriteRecord(
      nth: nth,
      cmd: cmd,
      panel: panel,
      key: key,
      value: value,
      stage: SoakWriteStage.direct,
      outcome: soakOutcomeName(result),
      reachedASocket: reached,
      at: _playClock.elapsed,
      probe: probe,
    ));
  }

  int _writesIssued = 0;

  /// Subscribes to any panel client that is not being watched yet.
  ///
  /// Called from the 250 ms panel sampler rather than once at `start()`,
  /// because [GateBFixture.redial] replaces a panel's client outright when a
  /// revoked station is restored — Phase 6 ends a refused panel's reconnect
  /// loop for good, so a restore is an application restart. A subscription
  /// taken once at start would go on listening to a disposed client and the
  /// new one's late resolutions would be invisible.
  void _ensureWriteWatch() {
    for (final panel in fixture.panels) {
      final client = panel.client;
      if (!_watchedClients.add(client)) continue;
      _writeWatches.add(client.onWriteResolved.listen((outcome) {
        final issued = _issuedByCmd(outcome.cmd);
        _writeRecords.add(SoakWriteRecord(
          nth: issued?.nth ?? -1,
          cmd: outcome.cmd,
          panel: issued?.panel ?? soakPanelName(panel.index),
          key: issued?.key ?? '(unknown)',
          value: issued?.value,
          stage: SoakWriteStage.lateResolution,
          outcome: soakOutcomeName(outcome),
          reachedASocket: true,
          at: _playClock.elapsed,
          probe: issued?.probe ?? false,
        ));
      }));
    }
  }

  SoakWriteRecord? _issuedByCmd(String cmd) {
    for (final record in _writeRecords) {
      if (record.cmd == cmd && record.stage == SoakWriteStage.issued) {
        return record;
      }
    }
    return null;
  }

  final Set<RemoteStateMan> _watchedClients = <RemoteStateMan>{};
  final List<StreamSubscription<WriteResult>> _writeWatches =
      <StreamSubscription<WriteResult>>[];

  /// One connectivity reading per panel, and the floor evaluated against it.
  void _samplePanels() {
    if (_stopped || _disposed) return;
    _ensureWriteWatch();
    final panels = fixture.panels;
    for (var i = 0; i < panels.length; i++) {
      final client = panels[i].client;
      _health[i]!.observe(
        ready: client.isReady,
        staleView: client.viewIsStale,
      );
    }
    _evaluatePopulationFloor();
  }

  /// The floor: at most one panel missing, and never for longer than
  /// [floorGrace].
  ///
  /// A breach is a **violation with its offset**, never an abort. A soak that
  /// stopped at the first breach would report one finding and leave the other
  /// four invariants' thirty minutes unmeasured, which is the whole argument
  /// for a driver that ticks checkers rather than a `test()` body that asserts.
  void _evaluatePopulationFloor() {
    final connected = connectedPanels;
    final now = clock.elapsed;
    if (connected >= populationFloor) {
      _belowFloorSince = null;
      // **Reset with the stretch, or the comment below is false.** It says
      // "one violation per breach"; a flag set once and never cleared is one
      // per RUN. A revocation whose restore lands late trips the floor at
      // +05:00 and is recorded; a reaper regression that takes three panels at
      // +22:00 then records nothing, and the second breach is the interesting
      // one. The run is already red from the first, so this costs forensics
      // rather than the verdict — but it costs the second breach its trip
      // record and its schedule offset.
      _floorBreachReported = false;
      return;
    }
    final since = _belowFloorSince ??= now;
    final stretch = now - since;
    if (stretch > worstBelowFloor) worstBelowFloor = stretch;
    if (stretch <= floorGrace) return;
    // One violation per breach, not one per sample: the log is capped at two
    // hundred and a permanently culled herd would otherwise fill it with the
    // same finding four times a second and push every other checker's first
    // occurrence out.
    if (_floorBreachReported) return;
    _floorBreachReported = true;
    _record(SoakViolation(
      checker: 'population',
      monotonic: now,
      scheduleOffset: _playClock.elapsed,
      detail: 'only $connected of $herdSize panels have been connected for '
          '${formatSoakOffset(stretch)}, under a floor of $populationFloor and '
          'past a grace of ${formatSoakOffset(floorGrace)}. Every per-panel '
          'invariant is now passing on a fraction of the population with '
          'nothing else saying so',
      observed: connected,
      expected: populationFloor,
    ));
  }

  bool _floorBreachReported = false;

  void _record(SoakViolation violation) {
    violationLog.add(violation);
    writeTripFor(violation);
  }

  /// How many trip records were not written because the run was past
  /// [soakTripRecordCap]. Printed in the verdict block when non-zero.
  int tripRecordsSuppressed = 0;

  int _tripsWritten = 0;

  /// Writes one violation's trip record — the seed, the schedule offset, the
  /// modes the timeline had armed, the last twenty checkpoints and the frame
  /// ring for the panel it names.
  ///
  /// **Public because the checkers' violations need it and had never had it.**
  /// This was reachable only from [_record], which is the population floor and
  /// nothing else, while every violation the soak has ever recorded on a real
  /// run came from a checker. The failure message the run prints has always
  /// ended "The rest are in build/soak/, one trip record each" — measured on
  /// the 35-minute arm, that was six violations and no trip records at all,
  /// which is T-11-31's mitigation not holding.
  ///
  /// Called once per violation at run end rather than at the instant, because
  /// a checker's log is what the run has: the checkpoint tail is the last
  /// twenty of the run, and the offset the violation carries is still the
  /// instant it happened.
  void writeTripFor(SoakViolation violation) {
    // **Capped, for `violationLog`'s own reason applied to the disk.** The
    // in-memory log stops retaining at `violationLogCapacity` because
    // "retaining them would make the harness the leak it is measuring"; this
    // call had no cap at all, so the artifact directory was unbounded where
    // the log was bounded. A `GatewayRestart` that exhausts its rebind budget
    // fails every subsequent write, and at the probe's one-per-two-seconds
    // that is ~690 more violations over the rest of a thirty-five-minute arm
    // — several megabytes of near-identical `trip-N.txt`, uploaded as the CI
    // artifact. The first twenty are the diagnosis and the rest make the
    // artifact harder to read than no artifact.
    if (_tripsWritten >= soakTripRecordCap) {
      tripRecordsSuppressed++;
      return;
    }
    _tripsWritten++;
    _journal?.writeTrip(violation, armedModes: _armedModesAt(violation));
  }

  /// Which link modes the *timeline* had armed at a violation's offset.
  ///
  /// A lookup into the artifact everybody else reads, never a running mirror of
  /// proxy state — `soak_journal.dart`'s rule, and its reason: a mirror can
  /// disagree with the proxy, and the one thing worse than not recording the
  /// armed modes is recording the wrong ones.
  List<String> _armedModesAt(SoakViolation violation) {
    final at = violation.scheduleOffset;
    if (at == null || _timeline == null) return const <String>[];
    final armed = <String>{};
    for (final entry in timeline.merged) {
      if (entry.offset > at) break;
      final payload = entry.payload;
      if (payload is! FaultMutation) continue;
      if (payload.arms) {
        armed.add(payload.mode);
      } else {
        armed.remove(payload.mode);
      }
    }
    return armed.toList(growable: false);
  }

  void _checkpoint() {
    if (_stopped || _disposed) return;
    journal.checkpoint(clock, <String, Object?>{
      'connectedPanels': connectedPanels,
      'populationFloor': populationFloor,
      'worstBelowFloorMs': worstBelowFloor.inMilliseconds,
      'appliedEntries': _applied.length,
      'fizzled': _fizzled.length,
      'violations': violationLog.total,
      'panels': <Object?>[for (final one in _health.values) one.toJson()],
      'rss': ProcessInfo.currentRss,
      'checkers': <String, Object?>{
        for (final one in checkers)
          one.checker.name: <String, Object?>{
            'judgedSamples': one.checker.judgedSamples,
            'floor': one.checker.minimumSamplesForAVerdict,
            'violations': one.checker.violations.length,
          },
      },
    });
  }

  void _schedule() {
    if (_stopped) return;
    final finished = _finished;
    if (_index >= timeline.merged.length) {
      // The storm is spent but the run is not: hold to the declared duration so
      // the tail of a run is measured rather than skipped.
      final remaining = duration - _playClock.elapsed;
      if (remaining <= Duration.zero) {
        _playClock.stop();
        if (finished != null && !finished.isCompleted) finished.complete();
        return;
      }
      _pending = Timer(remaining, () {
        _pending = null;
        if (_stopped) return;
        _playClock.stop();
        if (finished != null && !finished.isCompleted) finished.complete();
      });
      return;
    }
    final due = timeline.merged[_index].offset - _playClock.elapsed;
    _pending = Timer(due < Duration.zero ? Duration.zero : due, _fire);
  }

  Future<void> _fire() async {
    _pending = null;
    if (_stopped) return;
    final entry = timeline.merged[_index];
    SoakApplyOutcome outcome;
    try {
      outcome = await _applyEntry(entry);
    } catch (error, stack) {
      // A lever that threw is a violation and not the end of the run: the other
      // four hundred entries still have something to say.
      outcome = SoakApplyOutcome.fizzled(
          _kindOf(entry), 'threw', '$error\n${stack.toString().split('\n').take(3).join('\n')}');
      _record(SoakViolation(
        checker: 'population',
        monotonic: clock.elapsed,
        scheduleOffset: entry.offset,
        detail: 'the lever for $entry threw: $error',
      ));
    }
    // Checked after the await, for `ScenarioPlayback._fire`'s reason: stop()
    // may have run while a lever that awaits its own teardown was in flight,
    // and appending here would leave an applied log with an entry after the
    // stop that ended the run.
    if (_stopped) return;
    _applied.add(entry);
    _outcomes.add(outcome);
    _leversByKind.update(outcome.kind, (n) => n + 1, ifAbsent: () => 1);
    final payload = entry.payload;
    if (payload is SoakEvent && _panelNamedBy(payload) == null) {
      // Counted whether or not it fired: a gateway restart that fizzled still
      // took the pipe down and back on the way to finding out.
      _plantWideArms++;
    }
    if (!outcome.fired) _noteFizzle(entry.offset, outcome);
    journal.event(clock, <String, Object?>{
      'offsetMs': entry.offset.inMilliseconds,
      'stream': SoakStreams.labelOf(entry.streamIndex),
      'payload': entry.payload.toString(),
      ...outcome.toJson(),
    });
    _index++;
    _schedule();
  }

  String _kindOf(SoakTimelineEntry entry) {
    final payload = entry.payload;
    if (payload is SoakEvent) return payload.kind;
    if (payload is FaultMutation) return 'link:${payload.mode}';
    return 'unknown';
  }

  /// Link and quiet-clear entries go to a proxy; event entries go to [apply].
  Future<SoakApplyOutcome> _applyEntry(SoakTimelineEntry entry) async {
    final payload = entry.payload;
    // `_applyEvent` and not `apply`: the public entry point records a fizzle
    // itself, so that a lever pulled from anywhere is reported, and `_fire`
    // below records for every stream. Going through `apply` here would count
    // an event's fizzle twice.
    if (payload is SoakEvent) return _applyEvent(payload);
    if (payload is FaultMutation) {
      final index = panelForMode(payload.mode);
      final panel = fixture.panels[index];
      // `ScenarioPlayback.apply` and not a second switch: it is the existing
      // exhaustive switch over the sealed FaultMutation, and a ninth proxy
      // lever must fail to compile in one place, not two.
      await ScenarioPlayback.apply(panel.proxy, payload);
      _health[index]!.mutationsApplied++;
      return SoakApplyOutcome.fired(
          'link:${payload.mode}', 'FaultProxy.${payload.mode}',
          note: 'panel $index');
    }
    throw StateError('a merged timeline entry carried a ${payload.runtimeType}, '
        'which is neither a SoakEvent nor a FaultMutation: $entry');
  }

  void _track(Future<void> work, String what) {
    _inFlight.add(work.catchError((Object error) {
      _record(SoakViolation(
        checker: 'population',
        monotonic: _clock == null ? Duration.zero : clock.elapsed,
        scheduleOffset: _playClock.elapsed,
        detail: '$what failed after the lever returned: $error',
      ));
    }));
  }

  // ------------------------------------------------------------- the levers

  /// Which panel's proxy carries [mode].
  ///
  /// **By mode, never round-robin, and the control is not in the range.** The
  /// link half arms and clears: a `flap` armed at +12 s is cleared at +19 s by
  /// a later entry or by a quiet window's injected clear. Partitioning entries
  /// by position would send an arm to one panel and its clear to another,
  /// leaving the first flapping for the rest of the run and the second clearing
  /// something it never had. Partitioning by *mode* keeps every arm with its
  /// own clear, and with `ScenarioWeights.soak`'s four arming modes and four
  /// stormed panels it also happens to give each stormed panel its own weather:
  /// panel 1 flaps, panel 2 is slow, panel 3 is throttled, panel 4 is
  /// blackholed. The control gets none of it, which is the whole point.
  int panelForMode(String mode) {
    final declared = faultModes.indexOf(mode);
    if (declared < 0) {
      throw ArgumentError.value(mode, 'mode', 'not in faultModes, so no proxy '
          'lever answers to it and the storm would arm nothing');
    }
    final stormed = herdSize - 1;
    return 1 + declared % stormed;
  }

  /// Pulls the lever one [SoakEvent] names.
  ///
  /// **An exhaustive switch over the sealed type, with no `default:` arm
  /// anywhere.** A fifteenth arm added to `soak_event.dart` is a compile error
  /// here rather than a storm entry that logs itself and does nothing — which
  /// is the entire reason 11-02 made the type sealed.
  Future<SoakApplyOutcome> apply(SoakEvent event) async {
    final outcome = await _applyEvent(event);
    // Recorded here rather than only on the playback path, so that a lever
    // pulled by anything — a case, a later plan's own harness — cannot fire
    // into nothing without the driver saying so. `_applyEntry` deliberately
    // calls `_applyEvent` instead, or a played event would be counted twice.
    if (!outcome.fired) _noteFizzle(_playClock.elapsed, outcome);
    return outcome;
  }

  void _noteFizzle(Duration at, SoakApplyOutcome outcome) =>
      _fizzled.add('[${formatSoakOffset(at)}] $outcome');

  Future<SoakApplyOutcome> _applyEvent(SoakEvent event) async {
    switch (event) {
      case UpstreamLinkDown(:final alias):
        final link = fixture.linkFor(alias);
        if (link.inner.state == UpstreamLinkState.disconnected) {
          return SoakApplyOutcome.fizzled(event.kind,
              'FakeUpstreamLink.disconnectUpstream',
              '$alias was already down; disconnectUpstream returns early '
                  '(fake_upstream_link.dart:397), so this entry narrowed the '
                  'storm instead of widening it');
        }
        link.inner.disconnectUpstream();
        return SoakApplyOutcome.fired(
            event.kind, 'FakeUpstreamLink.disconnectUpstream');

      case UpstreamLinkUp(:final alias):
        final link = fixture.linkFor(alias);
        if (link.inner.state != UpstreamLinkState.disconnected) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'FakeUpstreamLink.reconnectUpstream',
              '$alias was already up, so its paired recovery restored nothing');
        }
        link.inner.reconnectUpstream();
        return SoakApplyOutcome.fired(
            event.kind, 'FakeUpstreamLink.reconnectUpstream');

      case UpstreamEpochBump(:final alias):
        // The plain fake's bump, not `GateBLink.bumpEpoch`'s four-step
        // choreography. The choreographed one raises a latch that only
        // `completeReBrowse` lowers, and nothing in the timeline carries a
        // re-browse-complete arm — closing it on a driver-invented timer would
        // be the driver authoring an event, which is the one thing this class
        // must not do. `soak_event.dart`'s own doc names `FakeUpstreamLink
        // .bumpEpoch()` as this arm's lever.
        final link = fixture.linkFor(alias);
        final before = link.inner.epoch;
        link.inner.bumpEpoch();
        // The one cause invariant 3's ledger excludes from residue needs to
        // know the bump happened, and nothing else in the process records it:
        // the epoch is opaque above `epoch.dart` and comparing two of them for
        // recency is explicitly forbidden there.
        //
        // **And it needs to know when the bump STOPPED applying, which is the
        // whole of this arm's care.** `eventual_resync.dart:484-488` attributes
        // any non-good-quality divergence on a bumped alias to
        // `DivergenceCause.epochChange`, and that is the one cause
        // `DivergenceLedger.residue` subtracts — so an entry in this set is
        // subtracted from residue AND absent from `countOf(unattributed)`,
        // which is both terms of `keyframesNotNeeded`. One alias left in here
        // permanently is ten of the forty plant keys exempt from the
        // milestone's headline decision number for the rest of the run, and
        // the storm draws this lever about four times in thirty-five minutes.
        //
        // What the bump actually excuses is bad quality until the re-browse
        // completes (`epoch.dart:26`, 08-08) — a transient condition — so the
        // exemption is cleared after the span the GENERATOR declares for this
        // kind, exactly as `UpstreamSlowResolve` clears its latency below.
        // Honouring `recoverySpanOf` is the driver agreeing with the timeline
        // rather than authoring a number of its own.
        //
        // Generation-stamped so a second bump EXTENDS the exemption rather
        // than the first bump's recovery cutting it short — the defect
        // `upstreamSlowResolve` has and this arm does not.
        _epochBumped.add(alias);
        final epochGeneration = (_epochBumpGeneration[alias] ?? 0) + 1;
        _epochBumpGeneration[alias] = epochGeneration;
        _scheduleRecovery(SoakEventSchedule.recoverySpanOf(event.kind), () {
          if (_epochBumpGeneration[alias] != epochGeneration) return;
          _epochBumped.remove(alias);
        });
        return SoakApplyOutcome.fired(
            event.kind, 'FakeUpstreamLink.bumpEpoch',
            note: '$alias $before -> ${link.inner.epoch}');

      case UpstreamMassDegrade(:final alias):
        // 08-09's pair, kept separate on the fake precisely so this reads as
        // one announcement for however many keys.
        final link = fixture.linkFor(alias);
        final before = link.inner.statusNotifications;
        // **Asked of the link rather than assumed.** The generator guards
        // `upstreamEpochBump` against a down alias and `upstreamLinkDown`
        // against a second down; it has no rule for this kind, so the draw can
        // and does land on an alias that is already disconnected — where every
        // key is already bad-quality from `disconnectUpstream`'s own
        // `applyLinkLoss` and `announceLinkState` re-announces a state nothing
        // changed. This arm had the before/after numbers in hand and returned
        // `fired` regardless, which is the storm quietly narrowing itself
        // while `events.jsonl` says it widened.
        if (link.inner.state == UpstreamLinkState.disconnected) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'FakeUpstreamLink.applyLinkLoss+announceLinkState',
              '$alias was already disconnected, so every key it carries was '
                  'already bad-quality and this degraded nothing');
        }
        link.inner.applyLinkLoss();
        link.inner.announceLinkState();
        final after = link.inner.statusNotifications;
        if (after == before) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'FakeUpstreamLink.applyLinkLoss+announceLinkState',
              '$alias announced nothing new ($before), so no panel saw a '
                  'degrade');
        }
        return SoakApplyOutcome.fired(
            event.kind, 'FakeUpstreamLink.applyLinkLoss+announceLinkState',
            note: '$alias, announcements $before -> $after');

      case UpstreamSlowResolve(:final alias, :final latency):
        final link = fixture.linkFor(alias);
        link.inner.readLatency = latency;
        link.inner.writeLatency = latency;
        // Cleared after the span the GENERATOR declares for this kind, not
        // after one this file invented: `recoverySpanOf` is what the generator
        // uses to keep the storm out of a quiet window, so honouring it is the
        // driver agreeing with the timeline rather than authoring against it.
        // Without a clear the alias stays slow for the rest of the run, and no
        // arm emits a reset.
        _scheduleRecovery(
            SoakEventSchedule.recoverySpanOf(event.kind), () {
          link.inner.readLatency = Duration.zero;
          link.inner.writeLatency = Duration.zero;
        });
        return SoakApplyOutcome.fired(
            event.kind, 'FakeUpstreamLink.readLatency+writeLatency',
            note: '$alias ${latency.inMilliseconds}ms for '
                '${SoakEventSchedule.recoverySpanOf(event.kind).inSeconds}s');

      case GatewayRestart():
        final before = fixture.server.port;
        await fixture.restartGateway();
        return SoakApplyOutcome.fired(
            event.kind, 'GateBFixture.restartGateway',
            note: 'rebound port $before; every panel redials');

      case TokenRevocation(:final stationId):
        final index = _indexOfPanel(stationId);
        if (_revoked.contains(index)) {
          return SoakApplyOutcome.fizzled(event.kind,
              'RelayServer.reloadTokens',
              '$stationId was already revoked, so the rewrite changed nothing '
                  'and no session was swept');
        }
        _revoked.add(index);
        _writeTokenFile();
        await fixture.server.reloadTokens();
        return SoakApplyOutcome.fired(
            event.kind, 'RelayServer.reloadTokens',
            note: '$stationId dropped from the token file and swept (4001)');

      case TokenRestore(:final stationId):
        final index = _indexOfPanel(stationId);
        if (!_revoked.remove(index)) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'GateBFixture.redial',
              '$stationId was not revoked, so there was nothing to restore');
        }
        _writeTokenFile();
        await fixture.server.reloadTokens();
        // The rewrite alone does not bring the panel back. Phase 6 ends the
        // reconnect loop for good on a refused credential — by design — so a
        // restore is an application restart, and that is what `redial` is.
        // Not awaited: a panel coming back must not hold the storm's clock.
        // **Recorded before the call, and it is the event that is recorded.**
        // Invariant 2 needs to know that this panel's client was replaced and
        // when, so that a write still unresolved on the retired object can be
        // told from one that was genuinely lost. A record of the FACT is safe
        // here where a capture of the retired client's unresolved SET would
        // not be: `issueWrite` holds its client across an `await` and the
        // redial below is deliberately un-awaited, so a write in flight lands
        // in that set afterwards. The set is read late, by `orphanedCmds`;
        // only the offset comes from here.
        _panelRestarts.add(
            SoakPanelRestart(panel: stationId, at: _playClock.elapsed));
        _track(fixture.redial(index), 'the redial of $stationId after restore');
        return SoakApplyOutcome.fired(event.kind, 'GateBFixture.redial',
            note: '$stationId back in the token file; a new client dialled');

      case KeymappingReload():
        // Alternating between the shipped table and the same table plus one
        // spare key nobody subscribes. Deterministic — a function of how many
        // reloads the timeline has already asked for — so it stays replayable,
        // and not a no-op: re-ingesting a byte-identical table would classify
        // nothing, add nothing and re-point nothing, which is a lever firing
        // into its own reflection.
        final spare = _reloads.isEven;
        final next = spare
            ? KeyMappings(nodes: <String, KeyMappingEntry>{
                ...fixture.mappings.nodes,
                _spareKey: opcUaEntry(
                    alias: soakAliases.first, identifier: _spareKey),
              })
            : fixture.mappings;
        _reloads++;
        final result = fixture.plant.router.applyKeyMappings(next);
        final moved = result.added.length +
            result.removed.length +
            result.changed.length;
        if (moved == 0) {
          return SoakApplyOutcome.fizzled(event.kind,
              'KeyRouter.applyKeyMappings',
              're-ingesting the routing table added, removed and changed '
                  'nothing, so nothing was re-pointed');
        }
        return SoakApplyOutcome.fired(
            event.kind, 'KeyRouter.applyKeyMappings',
            note: '${result.added.length} added, ${result.removed.length} '
                'removed, ${result.changed.length} changed, '
                '${result.rejected.length} rejected');

      case PanelSubscribe(:final panel, :final keys):
        final client = fixture.panels[_indexOfPanel(panel)].client;
        final opened = <String>[];
        for (final key in keys) {
          final handle = '$panel|$key';
          if (_liveSubscription(handle, client) != null) continue;
          _subscriptions[handle] =
              (client: client, sub: client.subscribe(key).listen((_) {}));
          opened.add(key);
        }
        if (opened.isEmpty) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'RemoteStateMan.subscribe',
              '$panel already held every one of ${keys.join('+')}');
        }
        // **The note says what the lever DID, not what its name suggests.**
        // `RemoteStateMan.subscribe` returns a broadcast view of an existing
        // store node — it wraps `_storeOf(key).node(key)` in a local
        // `StreamController` and opens no wire subscription — and the fixture
        // has already filed every plant key under `defaultPageSubscription`,
        // so this cannot move the gateway's session, subscription or listener
        // counts. Deviation 'no subscription-lifecycle coverage' is the long
        // form; this note is so a reader of `events.jsonl` does not have to
        // find it.
        return SoakApplyOutcome.fired(event.kind, 'RemoteStateMan.subscribe',
            note: '$panel opened a LOCAL broadcast view of '
                '${opened.join('+')} (no wire subscription; the page already '
                'held the key)');

      case PanelUnsubscribe(:final panel, :final keys):
        final dropped = <String>[];
        final client = fixture.panels[_indexOfPanel(panel)].client;
        for (final key in keys) {
          final handle = '$panel|$key';
          final live = _liveSubscription(handle, client);
          if (live == null) continue;
          _subscriptions.remove(handle);
          await live.cancel();
          dropped.add(key);
        }
        if (dropped.isEmpty) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'StreamSubscription.cancel',
              '$panel held no subscription to ${keys.join('+')}, so this '
                  'unsubscribe cancelled nothing');
        }
        // Local too — see the subscribe arm. Cancelling this closes a
        // controller in the panel's own process and leaves the gateway's
        // subscription untouched.
        return SoakApplyOutcome.fired(
            event.kind, 'StreamSubscription.cancel',
            note: '$panel dropped its LOCAL view of ${dropped.join('+')} '
                '(the page subscription is untouched)');

      case PanelWrite(:final panel, :final key, :final value):
        final index = _indexOfPanel(panel);
        final client = fixture.panels[index].client;
        if (!client.isReady) {
          return SoakApplyOutcome.fizzled(event.kind, 'RemoteStateMan.write',
              '$panel is not connected, so the operator action never reached '
                  'a socket');
        }
        // Not awaited: a write's three-state outcome can take the whole write
        // deadline, and a storm that waited for it would drift its own
        // timeline. `issueWrite` records the issue, the direct outcome and
        // whether it reached a socket, and carries its own failures into the
        // violation log — invariant 2 judges what it records.
        _track(issueWrite(panelIndex: index, key: key, value: value,
            probe: false), 'the write $panel $key=$value');
        return SoakApplyOutcome.fired(event.kind, 'RemoteStateMan.write',
            note: '$panel $key=$value');

      case PanelQuery(:final panel, :final series, :final window):
        final client = fixture.panels[_indexOfPanel(panel)].client;
        if (!client.isReady) {
          return SoakApplyOutcome.fizzled(
              event.kind,
              'ClientTimeseriesApi.queryTimeseriesData',
              '$panel is not connected, so the query never reached a socket');
        }
        // Anchored on a fixed instant rather than on the wall clock: freeze 9
        // keeps `DateTime.now()` out of the soak trees, and a query window is
        // not a measurement of anything here. There is no database in this
        // lane, so a refusal is entirely ordinary — what the soak asserts is
        // that a query answers or refuses and never drops the session.
        _track(
            client.timeseries
                .queryTimeseriesData(series, _queryAnchor,
                    from: _queryAnchor.subtract(window))
                .then((_) {}, onError: (Object _) {}),
            'the query $panel $series');
        return SoakApplyOutcome.fired(
            event.kind, 'ClientTimeseriesApi.queryTimeseriesData',
            note: '$panel $series over ${window.inMinutes}m');

      case PlantMutate(:final key, :final value):
        final alias = key.split('.').first;
        if (!soakAliases.contains(alias)) {
          return SoakApplyOutcome.fizzled(event.kind,
              'GateBPlantDriver.overrideRaw',
              'no link carries "$key", so the plant did not move');
        }
        // `overrideRaw` rather than one `setValue`: the plant driver sweeps
        // every key every 250 ms, so a single write is overwritten before any
        // panel could see it. An override is what a real device does — it
        // keeps reporting the new number until something changes it — and it
        // is what makes "plant truth" a thing invariant 3 can compare against.
        fixture.driver.overrideRaw(fixture.linkFor(alias), key, value);
        // The soak's own record of plant truth, written where the lever is
        // pulled. Invariant 3 compares against this and never against a second
        // reading of the client — see [plantTruthFor].
        _plantOverrides[key] = value;
        return SoakApplyOutcome.fired(
            event.kind, 'GateBPlantDriver.overrideRaw',
            note: '$key=$value from the next poll cycle on');
    }
  }

  /// A key no panel subscribes, so [KeymappingReload] can move the routing
  /// table without moving anything a checker is watching.
  static const String _spareKey = 'ST101.CN99.SPARE01.setpoint';

  /// A fixed instant for [PanelQuery]'s window. Not a clock: freeze 9 keeps the
  /// wall out of the soak trees, and this decides nothing.
  static final DateTime _queryAnchor = DateTime.utc(2026, 1, 1);

  void _scheduleRecovery(Duration after, void Function() recover) {
    late final Timer timer;
    timer = Timer(after, () {
      _recoveries.remove(timer);
      if (_stopped || _disposed) return;
      recover();
    });
    _recoveries.add(timer);
  }
}

// -------------------------------------------------------------- the views

/// One real panel, seen through the three members a freshness checker may use.
///
/// **A view and not a fake.** Every member below forwards to the shipping
/// `RemoteStateMan` — `viewIsStale` is its watchdog's verdict, `pageIsStale` is
/// the live per-subscription one (computed on read, so a saturated link
/// delivering old frames cannot agree with itself for ever), and `read` is what
/// a widget would render. The one thing this class adds is the subscription id,
/// and it adds it because the fixture's shape decides it rather than the
/// checker's.
final class _LivePanelView implements SoakPanelView {
  _LivePanelView(this.index, this._client);

  final RemoteStateMan _client;

  @override
  final int index;

  @override
  String get name => soakPanelName(index);

  @override
  bool get viewIsStale => _client.viewIsStale;

  /// **One page, and that is the fixture's doing.** `gate_b_fixture.dart`
  /// constructs every panel with its whole key list, so every key is filed
  /// under `defaultPageSubscription`; `RemoteStateMan.subscribe` then hands out
  /// a view of a store node rather than opening a second wire subscription. A
  /// checker that iterated a set of subscription ids would be iterating a set
  /// of one and reading as though it were general.
  @override
  bool get pageIsStale => _client.isSubscriptionStale(defaultPageSubscription);

  @override
  DynamicValue? read(String key) => _client.read(key);
}

/// One real panel, seen through the members invariant 3 and the ledger use.
///
/// **A view and not a fake**, exactly as [_LivePanelView] is: the three
/// inherited members forward to the shipping `RemoteStateMan`, and the three
/// added ones are surfaces it already publishes — `isReady`, the complaint list
/// itself, and the gateway's own generation counter for this panel's page. The
/// ledger's attribution reads nothing this harness planted, which is what stops
/// the taxonomy from being tunable.
final class _LivePanelResyncView implements SoakPanelResyncView {
  _LivePanelResyncView(this.index, this._client, this.pageRebuilds);

  final RemoteStateMan _client;

  @override
  final int index;

  @override
  String get name => soakPanelName(index);

  @override
  bool get viewIsStale => _client.viewIsStale;

  @override
  bool get pageIsStale => _client.isSubscriptionStale(defaultPageSubscription);

  @override
  DynamicValue? read(String key) => _client.read(key);

  @override
  bool get established => _client.isReady;

  @override
  List<String> get complaints => _client.complaints;

  @override
  final int pageRebuilds;
}

/// One live panel's complaint surface, as invariant 5 reads it.
///
/// Built per call for the same reason [SoakDriver.panelViews] is:
/// [GateBFixture.redial] replaces a panel's `RemoteStateMan` outright, and a
/// view cached at `start()` would go on counting a disposed client's
/// complaints — which, for an invariant about a list that never shrinks, would
/// read as a panel that stopped complaining rather than as a panel that was
/// replaced.
///
/// # Reading a live-client observable across a redial: the choice, once
///
/// **Building per call fixes the stale half and creates the other half**, and
/// every checker that reads a live-client observable has to answer it: the new
/// client's counter starts at zero, so the reading DROPS mid-run for a reason
/// that has nothing to do with the property being judged. There are two
/// correct answers and which one applies depends on what the observable is.
///
/// **A complaint is a thing that HAPPENED**, so its count is a magnitude and
/// the run's total is the honest number: invariant 5 accumulates across
/// incarnations ([BoundedLogsWindow.push]) and never needs to know which
/// client produced which complaint. **An unresolved command is a thing still
/// PENDING**, so it is an identity question — *where did this cmd go?* — and
/// summing magnitudes answers nothing. A checker asking that one has to reach
/// the retired client itself, which is what [GateBFixture.retiredClients] is
/// for.
///
/// Do not derive one from the other. A drop in a monotone counter is enough to
/// notice a replacement and is not enough to name it, and `debugUnresolvedCmds`
/// is not monotone.
final class _LivePanelLogView implements SoakPanelLogView {
  _LivePanelLogView(this.index, this._client, this.reestablishments);

  @override
  final int index;

  final RemoteStateMan _client;

  @override
  String get name => soakPanelName(index);

  @override
  bool get established => _client.isReady;

  @override
  int get complaints => _client.complaints.length;

  @override
  final int reestablishments;
}

/// The wire word for one outcome.
///
/// A `switch` over the sealed type rather than a `runtimeType` string, so a
/// fifth `WriteResult` arm fails to compile here instead of arriving in the
/// distribution counters as a name nobody expects.
String soakOutcomeName(WriteResult result) => switch (result) {
      WriteApplied() => 'applied',
      WriteRejected() => 'rejected',
      WriteUnknown() => 'unknown',
      WriteNotReceived() => 'not_received',
    };
