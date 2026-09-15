/// The resilience catalogue's Phase 9 rows — F22-F28 — in the tree, as data.
///
/// **Why this file exists.** The F1-F28 scenario catalogue lives in
/// `relay-websocket-notes.md` §7.5-7.9 at the main checkout root. That file is
/// untracked, so it is absent from every worktree an executor or a reviewer
/// ever opens, and STATE.md has carried "phases 7, 9 and 11 need it on hand"
/// as a standing concern since Phase 5. This file is the in-tree copy of the
/// rows Phase 9 gates: F22-F28 transcribed character-for-character from
/// 09-PATTERNS §0's embedded §7.9 table, plus — new for gate B — the §7.9
/// prose items those seven rows compress, because three of the phase's seeded
/// deviations descope clauses the Expect column never spells out and a
/// deviation is only checkable against text nobody paraphrased.
///
/// **Why this is a SECOND registry, physically separate from gate A's**
/// (`packages/tfc_relay_client/test/gate/f_row_registry.dart`), rather than
/// seven rows appended there:
///
///  1. No `package:` URI reaches another package's `test/` directory, so a
///     case in this package could not import a registry that lives in that
///     one — the rows have to be data beside the cases that quote them.
///  2. Gate A's `_declaredRows = 27` and its empty-`gateOutstanding`
///     assertion are Phase 7's closing condition and RES-01's evidence.
///     Growing either would retroactively un-close a finished phase.
///  3. Gate A's strangers arm already says, in the tree today, that *"An F22
///     here belongs in Phase 9"* — its manifest rejects these rows by name.
///     That is not an accident to work around; it is the instruction.
///
/// The [GateRow.expectation] and [GateRow.injection] strings are deliberately
/// **not** wrapped across adjacent literals. A wrapped literal is
/// byte-identical at runtime and not byte-identical on disk, and the whole
/// value of this file is that `grep -F 'every other key keeps flowing'` finds
/// the same bytes in the catalogue, in this registry and in the case that
/// quotes it.
///
/// **Five declarations, five jobs.**
///
/// [gateRows] is the catalogue. [catalogueProse] is the §7.9 prose behind it,
/// keyed by row. [gateOutstanding] is what the phase has not delivered yet,
/// one entry per undelivered row, each naming the plan that owes it — every
/// plan deletes its own entries in the same commit that lands its rows, and
/// 09-09 asserts the map is empty. [gateDeviations] is the part that keeps
/// the gate honest: every catalogue clause the phase's green does **not**
/// cover, with the measurement or the ruling and where it goes instead.
/// [followUpDestinations] is the closed set a deviation may send a clause to.
///
/// **Why an outstanding list rather than a red suite.** A permanently red
/// test makes every intermediate plan's phase gate red, and a phase whose own
/// gate is red cannot tell a new failure from a known one — the run report
/// stops being read, which is the failure mode the gate exists to prevent one
/// level up. So the red list is produced once, by running the manifest with
/// this map emptied, and recorded verbatim in 09-01-SUMMARY.md; after that
/// the same information lives here, where it is machine-checked in both
/// directions and shrinks by deletion. Gate A's precedent, applied unchanged.
library;

/// One row of the catalogue.
final class GateRow {
  const GateRow({
    required this.id,
    required this.scenario,
    required this.injection,
    required this.expectation,
    required this.quoteAnchor,
  });

  /// `F22`…`F28`. The name an auditor reads in the catalogue and searches for
  /// in this package's `test/gate/`.
  final String id;

  /// The row's short name — the catalogue's Scenario column.
  final String scenario;

  /// §7.9's Injection column, verbatim. Three of the seven seeded deviations
  /// are about the injection rather than the expectation (F22's and F27's
  /// durations, F25's lever), and a deviation is only checkable against text
  /// nobody paraphrased.
  final String injection;

  /// The catalogue's Expect column, verbatim.
  final String expectation;

  /// A short distinctive fragment of [expectation] that the file holding this
  /// row's case must contain.
  ///
  /// This is how the manifest checks that a case *quotes* its catalogue line
  /// instead of paraphrasing it. Each anchor is short enough to survive an
  /// 80-column doc comment on one line, and distinctive enough that it cannot
  /// arrive in a file by accident.
  final String quoteAnchor;

  /// The catalogue text a [Deviation.clause] quoting this row's table cells
  /// must be a substring of.
  ///
  /// §7.9 has an Injection column for every one of these seven rows, so both
  /// cells are quotable and gate B needs no G-row special case — which is why
  /// this is `[injection, expectation]` unconditionally where gate A's
  /// version branches on the row family. Prose-sourced clauses are checked
  /// against [catalogueProse] instead, by the manifest.
  List<String> get verbatimText => [injection, expectation];
}

/// Whether a row has no case at all, or a case that does not yet judge all of
/// it.
enum OutstandingKind {
  /// No case in this package's `test/gate/` names this row.
  missing,

  /// A case exists and named clauses of the row are not yet asserted.
  partial,
}

/// One row the phase has not finished, and who owes it.
final class Outstanding {
  const Outstanding({
    required this.kind,
    required this.owner,
    required this.clause,
  });

  final OutstandingKind kind;

  /// The plan id that owes this row, `09-\d\d`, from 09-PLAN-INDEX.md's
  /// wave table.
  final String owner;

  /// What is not yet judged.
  final String clause;
}

/// One catalogue clause the phase's green does not cover.
final class Deviation {
  const Deviation({
    required this.row,
    required this.clause,
    required this.source,
    required this.reason,
    required this.followUp,
  });

  /// A row id that [gateRows] declares.
  final String row;

  /// A verbatim substring of the text [source] names. Paraphrase it and
  /// nobody can check the deviation against the catalogue, which is the only
  /// thing an entry here is for.
  final String clause;

  /// Which of the row's three texts [clause] was quoted from:
  /// `'expectation'`, `'injection'` or `'prose'`.
  ///
  /// New over gate A's shape, and not decoration: the Expect column
  /// compresses requirements the §7.9 prose states in full, and orchestrator
  /// ruling 1 (09-CONTEXT) names one of them — the animation ceiling — as a
  /// day-one deviation. A registry that could only quote the Expect column
  /// would silently drop clauses the user asked to have recorded.
  final String source;

  /// Why the green does not cover it. A descope with a measurement is a
  /// finding; one without is an excuse.
  final String reason;

  /// Where it goes instead — one of [followUpDestinations]. A closed set,
  /// because an open-ended follow-up field becomes a wishlist within two
  /// phases.
  final String followUp;
}

/// The seven rows Phase 9 gates, F22-F28, from `relay-websocket-notes.md`
/// §7.9 "Additional test scenarios" via 09-PATTERNS §0's character-for-
/// character transcription.
const List<GateRow> gateRows = <GateRow>[
  GateRow(
    id: 'F22',
    scenario: 'Gateway stall',
    injection: 'SIGSTOP gateway 45 s; 5 clients, 3 upstreams',
    expectation: 'every value returns to good quality unaided (Ignition\'s bug: stuck until hand-toggled); historian marks the gap; clients shown "gateway stalled", not "you disconnected"',
    quoteAnchor: 'clients shown "gateway stalled", not "you disconnected"',
  ),
  GateRow(
    id: 'F23',
    scenario: 'Ghost-session leak',
    injection: 'connect client, `kill -9`, repeat ×200',
    expectation: 'gateway memory and upstream monitored-item count return to baseline',
    quoteAnchor: 'return to baseline',
  ),
  GateRow(
    id: 'F24',
    scenario: 'PLC reprogrammed',
    injection: 'restart one upstream / reassign its NodeIds mid-session',
    expectation: 'no stale-handle read ever returns a value; affected keys bad-quality until re-browse completes; other PLCs unaffected',
    quoteAnchor: 'no stale-handle read ever returns a value',
  ),
  GateRow(
    id: 'F25',
    scenario: 'Dead subscription, live socket',
    injection: 'server stops evaluating one subscription, connection + other subs healthy',
    expectation: 'client flags exactly that subscription stale',
    quoteAnchor: 'client flags exactly that subscription stale',
  ),
  GateRow(
    id: 'F26',
    scenario: 'Stuck momentary',
    injection: 'hold jog, then (a) pull cable (b) kill app (c) background app',
    expectation: 'machine stops in all three — deadman counter stops advancing',
    quoteAnchor: 'deadman counter stops advancing',
  ),
  GateRow(
    id: 'F27',
    scenario: 'Alarm flood on restore',
    injection: 'drop 1 of 4 upstreams with 50 active alarms, restore at 60 s; 1 of 5 clients disconnected throughout',
    expectation: 'one link-down alarm, not 50; all five clients converge on identical alarm + ack state',
    quoteAnchor: 'one link-down alarm, not 50',
  ),
  GateRow(
    id: 'F28',
    scenario: 'Poison values',
    injection: 'feed NaN, ±Inf, `1e999`, Latin-1 bytes from upstream',
    expectation: 'no frame ever fails to encode; affected key gets non-finite/encoding quality code; every other key keeps flowing',
    quoteAnchor: 'every other key keeps flowing',
  ),
];

/// The §7.9 prose items that back these rows, keyed by row id, transcribed
/// verbatim from 09-RESEARCH §A (where each item is quoted under its row):
/// item 3 for F22, item 4 for F23, item 5 for F24, item 6 for F25, item 8 for
/// F26, item 10 for F27, and items 1-2 for F28.
///
/// This map is not decoration. The Expect column compresses requirements the
/// prose states in full — F27's Expect cell says nothing about master-inhibit,
/// ack authority or the animation ceiling, yet all three are the row's known
/// descopes — and a [Deviation] whose `source` is `'prose'` quotes its clause
/// from here. Each value is one single-line literal for the same
/// never-wrap-a-literal reason the rows obey.
const Map<String, String> catalogueProse = <String, String>{
  'F22': '**Gateway event-loop stall = synchronized false disconnect on every client.** Ignition\'s forum is full of it: a Veeam/VMware snapshot froze the gateway 42 s, "tag subscriptions timed out all over the place", tags stuck erred *until manually toggled*. A Dart gateway is one isolate — more exposed than the JVM, and the trigger recurs nightly at backup time. Rules: event-loop lag monitor (alarm > 1 s drift, expose as a `PIPE.` key); heavy work (history queries, bulk encode) off-isolate; after a stall the gateway *announces* "frozen N ms" on resync so clients and historian distinguish it from a network drop. Ask what the host backup strategy is before go-live.',
  'F23': '**Ghost sessions leak PLC monitored items.** A wash-down power-cycled panel sends nothing on death; its subscription set and OPC UA monitored items linger. PLCs have hard monitored-item caps, so weeks of nightly reboots later, *new* clients fail to subscribe — a symptom with no visible link to the cause. Rules: heartbeat-driven session expiry with full teardown; refcount monitored items across clients (N clients watching one tag = one upstream item); per-client resource counts as `PIPE.` keys.',
  'F24': '**PLC program download rebuilds the NodeId space — cached-handle reads succeed and return the wrong tag\'s value.** No error, no bad quality, a weigher showing a conveyor\'s speed. Four independently-downloadable PLCs. The client↔gateway epoch (§7.5 F18) doesn\'t cover this boundary — it needs a second, per-PLC epoch: read `ServerStatus.StartTime` on session activation; if changed, drop the NodeId cache, re-browse, mark affected keys bad until re-established. Resolve by browse path / string NodeId, never cached numeric NodeIds across a session boundary.',
  'F25': '**Dead subscription on a live connection.** Home Assistant wall-dashboard failure: screen looks healthy, *some* widgets update, others are hours stale — whole-connection liveness cannot see it by construction. Rule: per-subscription sequence + last-evaluated stamp; a third UI state ("this value stopped") distinct from link-down.',
  'F26': '**Momentary buttons: the release that never arrives.** Field consensus: never set-on-press/clear-on-release. Hold-to-run = rolling-counter deadman at fixed rate, PLC runs only while the counter advances; discrete commands = HMI sets, **PLC clears**. `onTapCancel`, app-lifecycle change and connection loss all count as release.',
  'F27': '**Link-restore floods + the animation trap.** Losing one of four PLCs must raise *one* alarm, not flip every dependent alarm twice — master-inhibit: `PIPE.upstream.<alias>.connected` wired into alarm *evaluation*, not just the UI. Comms alarms get 30–120 s on-delay. Ack state is gateway-authoritative — a reconnecting client adopts it, never replays its own. An alarm re-arming after a blip is a *new occurrence* with a new id. And above N active alarms the overview switches from per-symbol blinking to a static count — the Ignition forum documents CPU collapse from alarm animations exactly at peak alarm count, and the eLinux panels have far less GPU headroom than dev machines.',
  'F28': '**`jsonEncode` throws on NaN/±Infinity** — it does not emit `null` like JS. One open-circuit 4–20 mA input or a divide-by-zero in a weigher rate calc (kg/min when the belt stops) fails the *entire batch for every client*. And `1e999` silently *decodes* to Infinity — a poison value that enters quietly and detonates on re-encode. Rule: sanitize at the OPC UA boundary, not the JSON boundary — non-finite double → `null` value + a "non-finite" quality code. Property-test the round trip (NaN, ±Inf, ±0.0, maxFinite, subnormals); fuzz the decoder with `1e999`. **`utf8.decode` throws on Latin-1 bytes.** S7 `STRING` is a byte array with no declared encoding (in practice CP1252); þ/ð/æ/ö in product names and alarm text are the *normal case* here … Fixtures say "Þorskflök í raspi", not "test string 1".',
};

/// The rows this phase has not delivered yet, keyed by row id.
///
/// Seeded with all seven as [OutstandingKind.missing], each owned by the plan
/// 09-PLAN-INDEX.md's wave table assigns it. **Every later plan deletes its
/// own entries in the same commit that lands its rows**, and 09-09 asserts
/// this map is empty — that assertion is the phase's own closing condition.
///
/// Why an outstanding entry beats a red suite: a phase whose own gate is red
/// cannot tell a new failure from a known one, so the report stops being
/// read. The entry keeps the gap visible on every run while the lane stays
/// green, and it shrinks by deletion in the commit that closes it.
///
/// A [OutstandingKind.partial] entry is for a row that *has* a case whose
/// named clauses are not all asserted yet. A partial entry for a row with no
/// case is a missing entry wearing the wrong label, and the manifest says so.
/// Empty since 09-09 landed F22e (the historian arm, "historian marks the
/// gap") — the last owed clause of the last partial row. The manifest's
/// closing case asserts this map STAYS empty, because the phase is over: an
/// entry here now would be work nobody has agreed to do, recorded as though
/// somebody had.
const Map<String, Outstanding> gateOutstanding = <String, Outstanding>{};

/// Every catalogue clause the phase's green will **not** cover.
///
/// "Seven green" is a claim. "Seven green, and here are the clauses that
/// green does not assert" is a document. RES-02's checkbox evidence is this
/// list quoted in the verification document, which is why the manifest prints
/// it as a formatted block on every run rather than only asserting over it.
///
/// **Seeded with seven on day one**, because three of F27's clauses and one
/// of F23's are known to be out of scope before the first case is written
/// (09-CONTEXT rulings 1, 4 and 6), and a registry that waits for the row to
/// land before admitting the descope is a registry that reports full coverage
/// exactly while the coverage is thinnest.
///
/// Later plans **append** (09-05 adds F26's measured hold-expiry window;
/// 09-09 adds F22's historian entry only if the `db` arm is not taken). None
/// may delete an entry without saying what now asserts the clause — a
/// deletion with no replacement assertion is the gate quietly widening its
/// own promise.
const List<Deviation> gateDeviations = <Deviation>[
  Deviation(
    row: 'F27',
    clause: 'one link-down alarm, not 50',
    source: 'expectation',
    reason: 'no relay package contains an alarm engine: a sweep of every '
        'relay lib/ finds the word "alarmable" only as a property of a health '
        'key, REQUIREMENTS.md has no ALM requirement, and SVN runs today with '
        'zero alarms configured and an empty alarm_history. Orchestrator '
        'ruling 1 (09-CONTEXT) takes ROADMAP criterion 4\'s narrower pipe '
        'reading instead: one status notification for fifty degraded keys — '
        '08-09\'s announce-once — which is the same property the catalogue '
        'wanted, one layer down from alarms.',
    followUp: 'app-side (AlarmMan)',
  ),
  Deviation(
    row: 'F27',
    clause: 'all five clients converge on identical alarm + ack state',
    source: 'expectation',
    reason: 'gateway-authoritative ack state has no surface anywhere in the '
        'relay tree; AlarmMan is a tfc_dart class '
        '(packages/tfc_dart/lib/core/alarm.dart) with no pipe binding, and no '
        'master-inhibit, on-delay or pendingAck exists in any relay lib/. The '
        'row asserts convergence on identical values and qualities instead — '
        'resync-is-snapshot doing the work across five panels with one held '
        'disconnected throughout.',
    followUp: 'app-side (AlarmMan)',
  ),
  Deviation(
    row: 'F27',
    clause: 'And above N active alarms the overview switches from per-symbol blinking to a static count — the Ignition forum documents CPU collapse from alarm animations exactly at peak alarm count, and the eLinux panels have far less GPU headroom than dev machines.',
    source: 'prose',
    reason: 'a rendering concern on the eLinux panels with no counterpart in '
        'the pipe — the blink-versus-static-count switch belongs to the panel '
        'UI, which is the real owner of this sentence. The pipe\'s analogous '
        'per-item-cost-at-peak hazard is logging (the package:logger hot-path '
        'stall: trace + PrettyPrinter turns per-node logs into seconds of '
        'lag), so the row asserts bounded log growth across the restore '
        'instead.',
    followUp: 'app-side (AlarmMan)',
  ),
  Deviation(
    row: 'F23',
    clause: 'upstream monitored-item count return to baseline',
    source: 'expectation',
    reason: 'a balance is deliberately absent: one logical OPC UA key is four '
        'monitored items and the binding discards the delete future '
        '(state_man.dart:848-861), so 08-PLAN-INDEX freeze 7 pins '
        'upstreamSubscriptionsCreated as a delta of creates, never a balance. '
        'The row asserts a flat create-delta across 200 kill cycles instead '
        'of a count returning to a number nothing in the binding can compute. '
        'Measured (09-03, ghost_session_gate_test F23a): baseline 20 creates '
        'from twenty held panels, delta 0 at every checkpoint '
        '(+10/+50/+100/+200, 0.00 per cycle, linger 0 ms); the refcount '
        'sabotage that releases under live watchers moved it to 2.50 per '
        'cycle, so the flat delta is measured, not assumed.',
    followUp: 'none — accepted',
  ),
  Deviation(
    row: 'F22',
    clause: 'SIGSTOP gateway 45 s',
    source: 'injection',
    reason: 'shortened in the default lane to ~10 s against the 6 s default '
        'heartbeatDeadline — the longest duration that still exceeds the '
        'deadline by a clear margin — with the full 45 s behind RELAY_SOAK. '
        'What is being tested is silence longer than the deadline: any stall '
        'past it exercises the same announcement, the same reaper decision '
        'and the same staleness window, so the shortening preserves the '
        'property. 09-CONTEXT ruling 6, on 07-CONTEXT ruling 2\'s precedent.',
    followUp: 'none — accepted',
  ),
  Deviation(
    row: 'F27',
    clause: 'restore at 60 s',
    source: 'injection',
    reason: 'shortened to ~15 s in the default lane, full duration behind '
        'RELAY_SOAK. The property is an outage long enough that every key of '
        'the dropped alias degrades and a disconnected panel misses the '
        'entire outage-and-restore window; ~15 s preserves both, and 60 s '
        'would add 45 s to an eight-minute lane to prove the same two facts. '
        '09-CONTEXT ruling 6.',
    followUp: 'none — accepted',
  ),
  Deviation(
    row: 'F25',
    clause: 'server stops evaluating one subscription',
    source: 'injection',
    reason: 'no shipped gateway can produce this injection: '
        'TickEngine._writeTick stamps one wallMs as evaluatedAt for every '
        'subscription of every session (tick_engine.dart:400-420; the range '
        'was :376-396 before upstream growth), so the field is a statement '
        'about the tick, not about the subscription. The '
        'row uses a test-only lever and says so in writing; a second arm '
        'asserts ROADMAP criterion 3\'s own scenario from Phase 8 machinery '
        '(data_age_ms climbing, badStale per key) with no lever at all. '
        'Measured (09-04, dead_subscription_gate_test): the per-subscription '
        'limit read from the client\'s own config was 3000 ms '
        '(max(50 ms tick x 30, 3 s link deadline)) and the lever-frozen '
        'verdict flipped 3051 ms after freeze(); with no lever, data_age_ms '
        'crossed the 2000 ms staleAfter at ~2.4 s of silence and climbed '
        'monotonically to 4007 ms under repeated read-path reads while the '
        'subscriber-cached gauge held its last-pushed 0 ms throughout — the '
        'frozen-age blind spot the lever narrates is real and measured. '
        'Deriving evaluatedAt from real per-subscription source evaluation is '
        'the costed follow-up — it changes a per-tick hot path that '
        'tick_test.dart pins.',
    followUp: 'post-milestone',
  ),
  Deviation(
    row: 'F26',
    clause: '(c) background app',
    source: 'injection',
    reason: 'the gateway has no per-hold tick deadline independent of the '
        'session: a session that keeps heartbeating while its hold ticks stop '
        'holds an engaged hold with a frozen counter until the reaper takes '
        'the session. 09-CONTEXT ruling 3 is measure-first — no second timeout '
        'is added to a safety path in a gate phase, because the PLC\'s '
        'FB_HoldToRun T#1000MS TON is the safety authority (Phase 5 ruling): '
        'the machine stops the instant the counter stops advancing, which is '
        'what every F26 arm asserts. Measured (09-05, '
        'stuck_momentary_gate_test F26c): the interval between the counter '
        'freezing on pause and the tag reaching 0 was 3027 ms — one '
        'heartbeatDeadline (3000 ms, the reaper\'s deadline, read off the '
        'gateway config) plus the poll margin. That is the window in which the '
        'gateway believes a hold is live that nobody is holding; it is '
        'recorded here so a later phase can decide with the number rather than '
        'about it. The server Timer.periodic count in lib/src stays 1.',
    followUp: 'post-milestone',
  ),
];

/// Where a deviation may send a clause the green does not cover.
///
/// A closed set on purpose: an open-ended follow-up field becomes a wishlist
/// within two phases — `'later'` and `'TODO'` are not destinations and nobody
/// can grep for them at the milestone.
///
/// `'app-side (AlarmMan)'` is gate B's one addition to gate A's set, and it
/// exists because orchestrator ruling 1 names an owner outside every relay
/// package: the alarm clauses belong to `tfc_dart`'s AlarmMan and the panel
/// UI, dual-mode per the user's 2026-09-02 amendment, next milestone.
///
/// `'Phase 10'` and `'Phase 11'` have **zero** users among the seven seeded
/// deviations, and that is deliberate — do **not** prune them. It is cheaper
/// to carry the destination now than to reopen the manifest's closed-set arm
/// when a later wave or Phase 11's soak defers a clause there.
const Set<String> followUpDestinations = <String>{
  'Phase 10',
  'Phase 11',
  'post-milestone',
  'app-side (AlarmMan)',
  'none — accepted',
};
