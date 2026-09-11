/// The soak's ledger of record: what it checks, and where it departs from the
/// catalogue's own words.
///
/// **This is deliberately not a registry of rows.** 11-RESEARCH §F.1 says it
/// in one sentence — *the soak must not have a manifest of rows* — because a
/// row table is the gate's shape, and copying it here would recreate gate A at
/// length instead of adding the thing the soak exists for. Gates A and B keep
/// the per-scenario evidence, one case per catalogue line. What the soak owns
/// is that those behaviours survive being **interleaved** for thirty-five
/// minutes, and the artifact analogous to `gate_manifest_test.dart`'s row
/// audit is therefore this file's two lists:
///
///  * [declaredCheckers] — the five invariants plus the divergence ledger,
///    audited by `judgedSamples >= minimumSamplesForAVerdict` rather than by a
///    row count, and swept in reverse so that a sixth checker cannot appear
///    without the audit knowing about it.
///  * [soakDeviations] — every place this phase does something other than what
///    `relay-websocket-notes.md` §7.8 literally says, with the clause quoted
///    **verbatim**, the number used instead, and the argument.
///
/// **Why the deviations are seeded on day one rather than collected at the
/// end.** 09-01 put its registry first and 07-13 explains why: a departure
/// applied silently is a departure the next reader believes never happened,
/// and by the end of a phase nobody can reconstruct which of the numbers in
/// the code were chosen and which were inherited. All five below were decided
/// at the discuss gate (11-CONTEXT rulings 2 and 3) or forced by a measurement
/// somebody already made, and every one of them is written down before a
/// single fault fires.
///
/// **None of the five is a descope.** Two of them (2 and 3) are *measured
/// refutations* of the catalogue text in the gate-A sense: §7.8 asks for
/// something this repository has already proved cannot be asserted honestly,
/// and the entry carries the measurement that proves it. The other three are
/// scope statements — a duration, a platform and a deployment tier — each of
/// which changes where the evidence comes from and none of which changes what
/// is being claimed.
///
/// The counts are **not** in this file. `soak_manifest_test.dart` writes down
/// how many entries and how many checker names it expects, for
/// `gate_manifest_test.dart:44-50`'s reason: a sweep that derives both sides
/// of its comparison from the same source asserts nothing, and an entry
/// deleted here would take its own count with it.
library;

// ---------------------------------------------------------------- the checkers

/// Invariant 1 — no value is rendered fresh whose age exceeds its deadline.
const String freshnessHonesty = 'freshnessHonesty';

/// Invariant 2 — every write reaches exactly one terminal state.
const String terminalStateWrites = 'terminalStateWrites';

/// Invariant 3 — after each stable window, every subscribed key equals plant
/// truth.
const String eventualResync = 'eventualResync';

/// Invariant 4 — client and server structures stay bounded across the run.
const String boundedMemory = 'boundedMemory';

/// Invariant 5 — a flapping link cannot produce a log flood.
const String boundedLogs = 'boundedLogs';

/// Not an invariant: the divergence ledger, which produces the keyframe
/// verdict.
///
/// It is in this list because it is subject to exactly the same vacuity
/// question as the five checkers — an empty ledger whose control never fired
/// is not evidence that nothing diverged — and 11-06 audits it through the
/// same gate rather than through a second mechanism.
const String divergenceLedger = 'divergenceLedger';

/// Every name the soak may register a checker under.
///
/// The list is a **closed set in both directions**. A checker registered under
/// a name that is not here fails the audit, which is what stops a sixth
/// checker being added without anybody deciding it should exist; and a name
/// here with no checker registered against it prints as *pending* rather than
/// silently reading as covered. 11-04 registers two of these, 11-05 registers
/// two more, and 11-06 registers the last two.
const List<String> declaredCheckers = <String>[
  freshnessHonesty,
  terminalStateWrites,
  eventualResync,
  boundedMemory,
  boundedLogs,
  divergenceLedger,
];

// -------------------------------------------------------------- the deviations

/// One place the soak does something other than what §7.8 says.
///
/// Modelled on `f_row_registry.dart`'s `Deviation` with one field changed:
/// there is no `row`, because there are no rows, and there is an [instead]
/// instead — the soak's departures are mostly *numbers*, and a departure whose
/// replacement number is not written down cannot be checked by anybody who did
/// not write it.
final class SoakDeviation {
  const SoakDeviation({
    required this.id,
    required this.clause,
    required this.instead,
    required this.reasoning,
  });

  /// A short handle, used in prose and in the printed block.
  final String id;

  /// The §7.8 text this entry departs from, **verbatim**.
  ///
  /// Paraphrase it and nobody can check the deviation against the catalogue,
  /// which is the only thing an entry here is for
  /// (`f_row_registry.dart:142-145`).
  final String clause;

  /// What this phase does instead, stated as a number wherever it is one.
  final String instead;

  /// Why. A departure with a measurement is a finding; one without is an
  /// excuse.
  final String reasoning;
}

/// Every departure from §7.8's literal text, seeded on day one.
///
/// Later plans **append** — 11-04 if the short arm's terminal-state
/// distribution needs gating, 11-05 if the server-side half of the log clause
/// is deviated — and the phase is expected to close between five and seven.
/// None may be deleted without saying what now satisfies the clause.
const List<SoakDeviation> soakDeviations = <SoakDeviation>[
  SoakDeviation(
    id: 'the 90-second default',
    clause: '30+ min',
    instead: '90 s in the lane on every push; 35 min behind RELAY_SOAK',
    reasoning: 'the two durations measure two different properties and the '
        'entry exists so neither is read as the other. The 90-second property '
        'is that the machinery cannot silently rot between full runs: every '
        'checker samples, every positive control is exercised, the journal is '
        'written and parsed. The 35-minute property is RES-03\'s actual '
        'evidence, and only it can catch something that takes twenty minutes '
        'to accumulate. A soak that only runs on demand is broken on the '
        'morning you need it, so the short arm runs on every push and the '
        'full arm runs on its own job. The precedent is literal: gateDeviations '
        'F2 shortens the catalogue\'s 60 s flap to 20 s in the lane and F17 '
        'shortens its 10-minute blackhole to 30 s, both behind the same '
        'RELAY_SOAK variable this arm uses. 11-CONTEXT ruling 2; 07-CONTEXT '
        'user ruling 2 is where the shape came from.',
  ),
  SoakDeviation(
    id: 'invariant 4 is asserted structurally; RSS is journalled and never '
        'asserted',
    clause: 'Client and server heap high-water marks bounded across the run.',
    instead: 'structural checkpoint slopes over the nine structures the clause '
        'is actually about, at 5 s; ProcessInfo.currentRss written to '
        'metrics.jsonl and asserted nowhere',
    reasoning: 'this is not weaker than §7.8; it is the only version of §7.8 '
        'that can fail on a real leak. The doctrine is already in the tree, '
        'measured, at long_outage_gate_test.dart:71-83, and it is quoted here '
        'in full so that this entry can be checked without opening that file: '
        '"Memory is asserted structurally and never off ProcessInfo.currentRss. '
        '07-RESEARCH assumption A9: RSS on this VM moves by megabytes for '
        'reasons that have nothing to do with the code under test, so a bound '
        'loose enough not to flake is loose enough not to catch a leak. What '
        'is asserted instead is the structure the clause is actually about — '
        'the unresolved-write set and the count of writes that reached a '
        'socket — sampled through the outage so that a leak shows as a slope '
        'rather than as one end-state reading, which is teardown_test.dart\'s '
        'checkpoint doctrine. No line of code in either arm reads '
        'ProcessInfo.currentRss — the only two occurrences of that name in '
        'this file are in this paragraph, and there is no coarse 10x '
        'smoke-detector ceiling in the soak arm either: a ceiling loose enough '
        'to survive the VM\'s own allocator is one no leak this row could '
        'produce would ever trip, and it would read like a memory assertion to '
        'the next person." A high-water mark is an RSS reading by another '
        'name, so the clause as written is the ceiling that paragraph refuses. '
        'RSS is still recorded at every checkpoint, because a human reading '
        'the journal next to the structures is exactly what it is good for. '
        '11-CONTEXT ruling 3.',
  ),
  SoakDeviation(
    id: 'invariant 2 reconciles continuously against a test-only plant-side '
        'ledger',
    clause: 'server logs applied writes, compared after the run',
    instead: 'a test-only append-only ledger on the plant side of the fake '
        'upstream, reconciled continuously and again at end of run',
    reasoning: 'there is no after-the-run comparison to make. The server\'s '
        'own WriteOutcomeLog prunes on every record and every read — '
        'write_outcome_log.dart:211-214, removeWhere against a horizon of '
        'now() - ttl — and the ttl is ServerConfig.writeOutcomeTtl, default '
        '60 s at server_config.dart:337. After thirty-five minutes it holds at '
        'most the last minute of the run, so a comparison performed at the end '
        'would be a comparison of the last sixty seconds wearing the label of '
        'the whole soak, which is worse than no comparison at all. F17b '
        'already found the operational half of this: past the TTL the gateway '
        'cannot tell "never arrived" from "arrived, and forgotten". The '
        'replacement is strictly more information — every applied write is on '
        'the ledger for the whole run, so "applied twice?" is answerable at '
        'minute 35 for a write that happened at minute 3. The ledger is '
        'test-only and lives under test/, per 08-03 task 2\'s rule that levers '
        'never go on a production class. 11-CONTEXT ruling 3.',
  ),
  SoakDeviation(
    id: 'the full arm is judged on Ubuntu only',
    clause: 'Client and server heap high-water marks bounded across the run.',
    instead: 'the 35-minute arm runs on ubuntu-latest only; the 90-second arm '
        'runs on all three OSes',
    reasoning: 'the descriptor half of invariant 4 cannot be judged on '
        'Windows: openSocketCount() needs /proc/self/fd or lsof and '
        'canCountOpenSockets is false there (fd_count.dart:46, with '
        'openSocketCountSkipReason saying so in the words a run report will '
        'show), and macOS runners are billed at ten times Linux for a '
        'thirty-five-minute job. This entry exists so that a green full run is '
        'not read as a three-platform verdict — a result judged on a column of '
        'the matrix where it never ran is precisely the failure '
        'gate_manifest_test.dart\'s skip audit was built to catch, and at this '
        'scale nobody would notice it from the run report. The short arm still '
        'runs everywhere, so the machinery is exercised on all three platforms '
        'even though the endurance evidence comes from one.',
  ),
  SoakDeviation(
    id: 'no docker-compose integration tier',
    clause: 'F10–F11 and the chaos soak belong in the docker-compose '
        'integration tier like #93\'s split compose files',
    instead: 'in-process fixtures on ephemeral ports with real sockets, in '
        'packages/tfc_relay_local/test/soak/',
    reasoning: 'that tier was never built, and this repository\'s integration '
        'story went somewhere else: real sockets and real gateways composed '
        'in process, on ports drawn at bind time so two worktrees can run the '
        'suite at once. For this phase in particular the in-process form is '
        'stronger rather than merely cheaper, because every invariant '
        'observable is a live object — debugUnresolvedCmds, complaints, the '
        'resync engine\'s in-flight map, the plant-side ledger — where a '
        'compose tier would leave the soak scraping logs for the same facts '
        'and inferring the ones that never get logged. §7.8 was written before '
        'any of those observables existed. The one thing the compose tier '
        'would add that this does not is process isolation between client and '
        'server, and 11-CONTEXT ruling 6 records the honest version of that: '
        'the on-site arm against a deployed gateway, post-milestone, with the '
        'config seam built now so the retrofit is not a rewrite.',
  ),
  SoakDeviation(
    id: 'no subscription-lifecycle coverage',
    clause: 'subscription churn under fault — sessions, subscriptions and '
        'listeners bounded across a storm that opens and closes them',
    instead: 'the storm draws panelSubscribe and panelUnsubscribe, and NEITHER '
        'can move the gateway\'s sessionCount, subscriptionCount or '
        'listenerCount. Gate B\'s own rows are where that coverage lives.',
    reasoning: 'two facts make it structural rather than a gap somebody could '
        'close by tuning the storm. RemoteStateMan.subscribe returns a '
        'broadcast view of an EXISTING store node — it wraps '
        '_storeOf(key).node(key) in a local StreamController and opens no wire '
        'subscription at all. And gateBFixture constructs every panel with its '
        'whole key list, so all forty plant keys are already filed under '
        'defaultPageSubscription before the storm starts; stormKeys is a strict '
        'subset of plantKeys, so EVERY panelSubscribe the storm can draw names '
        'a key the panel already holds. The two levers therefore create and '
        'destroy local broadcast controllers, which is a real thing to do to a '
        'client and is not subscription lifecycle. The consequence worth '
        'writing down: a regression in which subscribe began opening a real '
        'wire subscription per call and leaking it — precisely what invariant '
        '4 watches subscriptionsStructure and listenersStructure FOR — would '
        'be invisible to the two levers that name subscriptions, because they '
        'never reach the wire. Closing it means constructing panels with '
        'subsets of the key list, which is gate B\'s fixture and gate B\'s '
        'sixty-five rows. NO WAVE MAY CITE THESE TWO LEVERS AS '
        'SUBSCRIPTION-LIFECYCLE COVERAGE.',
  ),
];

// ------------------------------------------------------------- RES-03's ledger

/// One of RES-03's ROADMAP criteria, the command that demonstrates it, and the
/// number that command produced.
///
/// **Written for somebody who was not here.** 09-09's closing ledger is the
/// shape: a criterion whose evidence is a paragraph is a criterion nobody can
/// re-check, so every row carries a command that can be pasted into a shell and
/// a result that can be compared against what it prints. The results below are
/// from the thirty-five-minute arm at seed 11 on 2026-09-04, and the
/// [caveat] is the half a green tick does not say.
final class SoakEvidence {
  const SoakEvidence({
    required this.criterion,
    required this.command,
    required this.result,
    required this.caveat,
  });

  /// The ROADMAP criterion, abbreviated but not paraphrased away.
  final String criterion;

  /// A command that re-demonstrates it.
  final String command;

  /// What that command produced, with the number.
  final String result;

  /// **What this row is silent about.** Never empty: this phase produced four
  /// separate cases where a green run means less than it appears, and a ledger
  /// with a blank here would be the fifth.
  final String caveat;
}

/// RES-03, criterion by criterion.
const List<SoakEvidence> res03Ledger = <SoakEvidence>[
  SoakEvidence(
    criterion: '1. A seeded randomized fault schedule runs 30+ minutes '
        'unattended and reports pass/fail per invariant',
    command: 'cd packages/tfc_relay_local && RELAY_SOAK=1 RELAY_SOAK_SEED=11 '
        'dart test test/soak --tags soak -r expanded',
    result: '35:00 declared, 36:00 wall; 452 of 452 timeline entries applied, '
        '0 never reached; six per-invariant verdicts printed in the verdict '
        'block, each with its judged count against its floor',
    caveat: 'ONE SEED. Seed 11 is thin in three levers even at 35 minutes — '
        '1 upstreamEpochBump, 1 gatewayRestart, 1 panelUnsubscribe — so a '
        'green run is not coverage of those three. The event MACHINERY is '
        'protected on every push by soak_driver_test.dart\'s all-fourteen-arms '
        'case, and that is the coverage claim this row may make.',
  ),
  SoakEvidence(
    criterion: '2. All five invariants hold continuously',
    command: 'the same run\'s verdict block',
    result: 'freshnessHonesty 16,689,920 judged against a floor of 168,000, 0 '
        'violations; boundedLogs 1,827 windows against 350, 0; eventualResync '
        '8 windows against 7 over 127,440 key comparisons, 0; divergenceLedger '
        '1 against 1, 0; boundedMemory 420 against 210. '
        'terminalStateWrites 1,055 resolved writes against a floor of 280 and '
        '**4 violations** — see the finding below.',
    caveat: 'NOT ALL FIVE HOLD. Invariant 2 recorded four writes that reached '
        'a socket and settled nowhere, and that is a real finding rather than '
        'an instrument fault — it rides its own RED in its own plan. Invariant '
        '1\'s monotonic anchor is proved by freeze 9 and NOT by this run '
        '(11-04 sabotage 2 ran fully green with a wall-clock-aged verdict). '
        'Invariant 5\'s ceiling has never judged a non-zero reading: its '
        'sampler, floors and gates all bite, but the verdict itself has only '
        'ever compared 0.0 against 20.',
  ),
  SoakEvidence(
    criterion: '3. Re-running with the same seed reproduces the identical '
        'fault schedule',
    command: 'cd packages/tfc_relay_local && dart test '
        'test/soak/soak_schedule_test.dart',
    result: 'the unit half: the merged timeline is identical across two '
        'generations at one seed, under a TOTAL order, with the link half '
        'proved in Phase 2 at schedule_test.dart:42 and :233',
    caveat: 'The hard half PREDATES this phase. Phase 2 proved the link '
        'schedule; 11-02 extended it to the merged timeline. What this phase '
        'added is the event half and the full-duration demonstration below.',
  ),
  SoakEvidence(
    criterion: '3b. …demonstrated at full scale',
    command: 'two 35-minute runs at seed 11, then '
        'diff run1/events.jsonl run2/events.jsonl on the projection that '
        'omits both clocks and the bound port',
    result: 'see 11-07-SUMMARY. The projection is (offsetMs, stream, payload, '
        'kind, lever, fired) — monotonicMs and wallMs are on every journal '
        'line by 11-01\'s WR-01 design and epoch ids are random hex, so a raw '
        'byte diff would compare the clock rather than the storm.',
    caveat: 'Two runs on one machine. Reproducibility ACROSS machines is '
        'untested and the generator gives no reason to doubt it — it reads no '
        'clock and no platform value — but untested is untested.',
  ),
  SoakEvidence(
    criterion: '4. A deliberately injected invariant violation is caught and '
        'reported with the seed and timestamp needed to reproduce it',
    command: 'cd packages/tfc_relay_local && dart test '
        'test/soak/soak_meta_test.dart',
    result: 'six positive controls, one per checker plus the divergence '
        'ledger, each asserting its own violation is recorded and that the '
        'record names the panel, the key, the schedule offset and the seed',
    caveat: 'A positive control proves the checker can fire. It does not prove '
        'the composed run would have driven it there — and this phase has four '
        'measured cases where it would not have: 11-04 sabotage 2, 11-05 '
        'sabotage 4, and both halves of 11-06\'s epochChange finding. Each was '
        'caught by a STRUCTURAL PIN and by nothing else.',
  ),
];
