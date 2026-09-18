/// Invariant 2 — **every write reaches exactly one terminal state.**
///
/// Applied, rejected or unknown; never two, never dropped, never duplicated at
/// the plant. This is the second half of CLAUDE.md's Core Value and the half
/// that moves machinery.
///
/// ## Why it reconciles continuously, and against what
///
/// §7.8 says a write is *"never duplicated server-side (server logs applied
/// writes, compared after the run)"*. **There is no after-the-run comparison to
/// make** — `WriteOutcomeLog` prunes on every record and every read against a
/// sixty-second TTL, so at minute 35 it holds at most the last minute.
/// [AppliedWriteLedger]'s class doc carries the argument and the line numbers;
/// it is **deviation 3** in `soak_registry.dart`, seeded on day one per
/// 11-CONTEXT ruling 3.
///
/// So this checker does two things the clause does not describe:
///
///  * **Continuous.** A double resolution is recorded at the instant it
///    happens, carrying both states and the schedule offset — because the
///    offset at that instant is what makes it diagnosable, and thirty minutes
///    later the gateway's own log has forgotten the write entirely.
///  * **Against a durable plant-side record.** [AppliedWriteLedger] answers
///    *"was this applied twice?"* at minute 35 about a write that happened at
///    minute 3.
///
/// ## The three places a write can be, and the one qualifier that is not a
/// loophole
///
/// At run end, every write **that reached a socket** is either in this
/// checker's terminal map or in `RemoteStateMan.debugUnresolvedCmds` — never
/// both, never neither.
///
/// The qualifier is the client's documented behaviour rather than an escape
/// hatch. `remote_state_man.dart:832-836` removes a command that never left the
/// process from `_unresolved` **on purpose**: re-querying it on every reconnect
/// for the rest of the shift is how a panel with a dead link grows an
/// unresolved set until `writeStatus` is refused for being over
/// `maxKeysPerSubscribe` — which takes the recovery path for the *genuine*
/// unknowns down with it. A checker that demanded terminality of a write that
/// never left the process would be asserting against that protection. The
/// sabotage that removes the qualifier is in 11-04's SUMMARY with the number of
/// false violations one ninety-second run produced.
///
/// Asking whether a write reached a socket is done from outside, the only way
/// it can be: an established outcome proves the far side answered, and an
/// `unknown` is disambiguated by whether the client kept the command
/// (`SoakWriteRecord.reachedASocket`, computed by the driver at the instant the
/// call returned).
///
/// ## What is terminal
///
/// `applied`, `rejected` and `not_received` are **established**: the far side
/// took a position. `unknown` is not — it is precisely the verdict that stays
/// re-queryable, and a write sitting at `unknown` in `debugUnresolvedCmds` is
/// the pipe behaving correctly rather than a write in limbo. All four are
/// counted, because the distribution is evidence about the storm; only three
/// are terminal.
///
/// ## `debugUnresolvedCmds` is shared with invariant 4
///
/// 11-05's bounded-memory checker reads the same counter as a **slope**. This
/// one asks whether a command is *in* it and whether it is bounded *at all*.
/// Cross-referenced in both docs, so a change to either is read by whoever owns
/// the other; the structure itself is `long_outage_gate_test.dart`'s.
library;

import '../../../soak/soak_registry.dart';
import '../invariant.dart';
import '../soak_observables.dart';

/// Resolved writes per minute below which this checker's green is not
/// evidence.
///
/// **Eight, against a probe that issues thirty.** The driver's write probe acts
/// every two seconds (`writeProbeCadence`), so an unobstructed minute offers
/// thirty judgeable resolutions and the storm's own `PanelWrite` entries add
/// more. A floor at eight leaves room for a herd mostly blackholed, a gateway
/// restarting, and a runner losing slices — while still failing the two things
/// a floor is for: a probe that stopped, and a run whose writes never resolved.
///
/// **The probe is why this number can exist at all.** 11-03 measured the
/// ninety-second lane arm at seed 11 as playing **zero** events: every one of
/// its eighteen applied entries is a link mutation. Judging only the storm's
/// writes would take zero readings on every push, fail the vacuity gate, and do
/// it in the arm that runs on every commit. See `writeProbeCadence`.
const int terminalStateFloorPerMinute = 8;

/// How many commands may be outstanding at once before that is a finding.
///
/// **Sixty-four.** The probe issues one write every two seconds and each
/// resolves or settles into the unresolved set within one `writeDeadline` (2 s)
/// plus a reconnect; the storm adds roughly eleven events a minute of which a
/// fraction are writes. A steady state above a handful means commands are
/// arriving faster than they settle, and the consequence is concrete rather
/// than theoretical: `writeStatus` re-queries the whole set on every entry to
/// `ready`, and past `maxKeysPerSubscribe` the gateway refuses the request —
/// so an unresolved set that only grows eventually disables the recovery path
/// for every genuine unknown on that panel.
///
/// A ceiling and not a slope. The slope is invariant 4's (11-05 task 1), on the
/// same counter; this is the absolute backstop underneath it.
const int unresolvedCeilingDefault = 64;

/// The shortest declared duration this checker will ask its distribution of.
///
/// **Sixty seconds, and the gate is not a softening.** `unknown` is the one
/// outcome the harness cannot manufacture: it needs a link to break **during a
/// write's round trip**, which is a coincidence between the probe's two-second
/// cadence and whatever the timeline has armed. Ten ninety-second lane runs at
/// seed 11 produced between two and five of them, so at the arm's own length it
/// is reliable; `soak_test.dart`'s auxiliary cases declare eight and twelve
/// seconds — three writes — and asserting it there would fail a smoke test of
/// the machinery for a property it was never running long enough to have.
///
/// Both real arms (90 s and 35 min) are past this floor, so nothing that claims
/// to be evidence escapes the assertion. [TerminalStateChecker.distributionWasAsked]
/// is printed either way, because a green short run must not read as a
/// distribution that held.
///
/// **Invariant 1's distribution is deliberately not gated**, and the asymmetry
/// is real: freshness is sampled forty times a second from the first tick, so a
/// run of any length with a fault in it produces both a fresh and a stale
/// reading. Writes are two seconds apart.
const Duration distributionArmFloor = Duration(seconds: 60);

/// What was established about one command, and when.
final class _Terminal {
  const _Terminal(this.state, this.at);

  /// `applied`, `rejected` or `not_received`.
  final String state;

  /// The schedule offset at the instant it was established.
  final Duration at;
}

/// Invariant 2's instrument.
final class TerminalStateChecker
    with GuardedSampling
    implements SoakRunEndCheck {
  TerminalStateChecker(
    this.source, {
    Duration? declared,
    this.floorPerMinute = terminalStateFloorPerMinute,
    this.unresolvedCeiling = unresolvedCeilingDefault,
  }) : _declaredOverride = declared;

  /// The write records, the unresolved set and the plant-side ledger.
  final SoakWriteSource source;

  final Duration? _declaredOverride;

  /// See [terminalStateFloorPerMinute].
  final int floorPerMinute;

  /// See [unresolvedCeilingDefault].
  final int unresolvedCeiling;

  /// What the run was declared to be, read from the source because a checker is
  /// built before the driver that knows.
  Duration get declaredDuration =>
      _declaredOverride ?? source.declaredDuration;

  @override
  final String name = terminalStateWrites;

  @override
  final ViolationLog violationLog = ViolationLog();

  /// Writes that resolved — one per command, not one per sample call.
  ///
  /// 11-01's third sabotage is why every checker in this phase spells this out:
  /// with the counter counting calls, a checker that threw on every call
  /// reported five readings against a floor of one and cleared the gate.
  @override
  int judgedSamples = 0;

  int applied = 0;
  int rejected = 0;
  int unknown = 0;
  int notReceived = 0;

  /// Writes the client watched fail to leave the process. Counted rather than
  /// ignored: a run where every write died in-process measured nothing, and
  /// that has to be readable next to [judgedSamples].
  int neverReachedASocket = 0;

  /// The largest the unresolved set was seen to be.
  int worstUnresolved = 0;

  /// Writes that went down with a client a restart replaced.
  ///
  /// **A fourth accounted state, and it is printed rather than absorbed.** A
  /// write here is not a breach: the panel restarted, and `_unresolved` is
  /// in-memory only, so the command stopped being pending for a reason the
  /// harness modelled on purpose. Neither is it nothing — it is the one place
  /// the run can say out loud that a restart ends an operator's chance of ever
  /// being told what became of a write they issued.
  ///
  /// **Zero on any run with no `tokenRestore`**, which is what makes a non-zero
  /// reading mean something. Counted here and named in [toString] because the
  /// verdict block prints that: this milestone has now three times found a
  /// number that was correct, load-bearing and printed nowhere — `unattributed`
  /// most recently — and **a number that is not printed is not a standing
  /// measurement.**
  int orphanedByRestart = 0;

  /// How many commands were reported terminal twice **with the same answer**.
  ///
  /// Not a breach — see the comment at the recording site — but a real fact
  /// about the run: it counts the writes whose outcome the `writeStatus`
  /// recovery path re-reported while the original call was still in flight,
  /// which is a direct measure of how often the storm interrupted a write's
  /// round trip.
  int reResolvedInAgreement = 0;

  /// Established outcomes, by command.
  final Map<String, _Terminal> _terminal = <String, _Terminal>{};

  /// Every command this run issued, by command.
  final Map<String, SoakWriteRecord> _issued = <String, SoakWriteRecord>{};

  /// Whether the direct call watched each command reach a socket.
  final Map<String, bool> _reachedASocket = <String, bool>{};

  /// Commands an outcome has already been seen for, so [judgedSamples] counts
  /// writes and not observations.
  final Set<String> _resolved = <String>{};

  /// How far into [SoakWriteSource.writeRecords] this checker has read.
  int _consumed = 0;

  @override
  int get minimumSamplesForAVerdict => minimumSamplesForDuration(
        perMinute: floorPerMinute,
        declared: declaredDuration,
      );

  @override
  void takeReading(SoakClock clock) {
    final records = source.writeRecords;
    for (; _consumed < records.length; _consumed++) {
      _consume(records[_consumed]);
    }
    final outstanding = source.unresolvedCmds.length;
    if (outstanding > worstUnresolved) worstUnresolved = outstanding;
  }

  void _consume(SoakWriteRecord record) {
    if (record.stage == SoakWriteStage.issued) {
      _issued[record.cmd] = record;
      return;
    }
    if (record.stage == SoakWriteStage.direct) {
      _reachedASocket[record.cmd] = record.reachedASocket;
      if (!record.reachedASocket) neverReachedASocket++;
    }

    final outcome = record.outcome;
    if (outcome == null) return;
    if (_resolved.add(record.cmd)) judgedSamples++;

    switch (outcome) {
      case 'applied':
        applied++;
      case 'rejected':
        rejected++;
      case 'unknown':
        unknown++;
      case 'not_received':
        notReceived++;
    }
    // `unknown` is not an established outcome — it is the one verdict that
    // stays re-queryable, which is what makes `writeStatus` the recovery story
    // instead of a re-send.
    if (outcome == 'unknown') return;

    final already = _terminal[record.cmd];
    if (already != null) {
      // **Agreement is not a second terminal state, and this is measured
      // rather than assumed.** In roughly half of ninety-second lane runs a
      // probe write to the flapping panel is reported twice at the same
      // instant, and the sequence is the pipe working exactly as designed: the
      // cmd is in `_unresolved` from before the request left, the link flaps,
      // the re-query on the next entry to `ready` gets the gateway's own
      // recorded outcome and `_settle` fires `onWriteResolved`, and then the
      // original `write` future returns with the same answer.
      //
      // One operator action, ONE terminal state, two channels that agree. The
      // invariant forbids a write REACHING two terminal states, not an outcome
      // being reported twice — and treating agreement as a breach would make
      // the strongest arm here fire on a healthy pipe about half the time.
      // Counted, so a run where the recovery path re-reports everything says
      // so; and the "never duplicated server-side" half of §7.8 is answered by
      // the plant-side ledger, which is a different arm.
      if (already.state == outcome) {
        reResolvedInAgreement++;
        return;
      }
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: record.at,
        scheduleOffset: record.at,
        panel: record.panel,
        key: record.key,
        observed: 'a second terminal state "$outcome" at '
            '${formatSoakOffset(record.at)}',
        expected: 'nothing further after "${already.state}" at '
            '${formatSoakOffset(already.at)}',
        detail: 'seed=${source.seed} — write #${record.nth} (cmd ${record.cmd}) '
            'reached TWO terminal states: "${already.state}" at '
            '${formatSoakOffset(already.at)} and then "$outcome" at '
            '${formatSoakOffset(record.at)}. One id is one operator action '
            '(04-REVIEW CR-05), so one of these two answers is being reported '
            'about a write it is not about — and the operator is told twice, '
            'the second time contradicting the first. Recorded here at the '
            'instant rather than inferred at run end, because the gateway\'s '
            'own WriteOutcomeLog will have pruned this command inside a minute',
      ));
      return;
    }
    _terminal[record.cmd] = _Terminal(outcome, record.at);
  }

  /// The whole-run questions: exactly one place per write, no plant duplicate,
  /// and a distribution that proves the storm exercised all three states.
  @override
  void finish() {
    // Anything recorded since the last tick, including everything that landed
    // while `play()` was draining its in-flight futures.
    takeReading(SoakClock.frozenAt(source.scheduleOffset,
        declaredDuration: declaredDuration));

    final outstanding = source.unresolvedCmds.toSet();
    final orphans = source.orphanedCmds.toSet();

    for (final issued in _issued.values) {
      final cmd = issued.cmd;
      // A write with no direct record at all was still in flight when the run
      // ended. `SoakDriver.play` awaits every tracked future before this runs,
      // so it should not happen; if it does, the honest thing is to say the
      // write was not judged rather than to demand terminality of a call that
      // had not returned.
      final reached = _reachedASocket[cmd];
      if (reached == null || !reached) continue;

      final inTerminal = _terminal.containsKey(cmd);
      final inUnresolved = outstanding.contains(cmd);
      final wasOrphaned = orphans.contains(cmd) && _aRestartCouldHaveTakenIt(issued);
      if (wasOrphaned) orphanedByRestart++;
      if (inTerminal && (inUnresolved || wasOrphaned)) {
        _record(
          'write #${issued.nth} (cmd $cmd) is in BOTH the terminal map — '
          '"${_terminal[cmd]!.state}" at '
          '${formatSoakOffset(_terminal[cmd]!.at)} — and '
          '${inUnresolved ? 'the client\'s unresolved set' : 'the unresolved '
              'set of a client a restart retired'}. A settled command the '
          'client is still going to re-query on the next reconnect is one the '
          'operator will be told about twice, and the second answer may '
          'disagree with the first',
          panel: issued.panel,
          key: issued.key,
          at: issued.at,
        );
      } else if (!inTerminal && !inUnresolved && !wasOrphaned) {
        _record(
          'write #${issued.nth} (cmd $cmd) reached a socket and is in NEITHER '
          'the terminal map nor the client\'s unresolved set: nothing settled '
          'it and nothing is going to ask about it. This is a write silently '
          'lost — the failure CLAUDE.md\'s Core Value names first, and the one '
          'an operator discovers by walking out to look at the machine',
          panel: issued.panel,
          key: issued.key,
          at: issued.at,
        );
      }
    }

    _reconcileAgainstThePlant();
    _checkTheUnresolvedSet();
    _checkTheDistribution();
  }

  /// Whether a restart of [issued]'s **own** panel, **after** it was issued,
  /// could have taken this command with it.
  ///
  /// **Conditions (2) and (3) of the admissibility rule, and they are what stop
  /// "orphaned" becoming an exemption nothing constrains.** Membership in
  /// [SoakWriteSource.orphanedCmds] alone would be condition (1) on its own,
  /// and a bucket that admits on membership alone is the shape that already
  /// cost this milestone a headline number: `_epochBumped` was a set nothing
  /// removed from, and it manufactured "unattributed 0" by moving divergences
  /// out of the one bucket the verdict counted (11-CARRY-FORWARD, M-01).
  ///
  /// So orphan status is earned per write rather than granted per bucket. A
  /// command cannot hide behind a restart that belonged to another panel, or
  /// behind one that happened before it was issued, or behind none at all —
  /// each of those stays a write silently lost and still turns this arm red.
  ///
  /// The comparison is inclusive because condition (1) is doing the
  /// discriminating: a write issued on the *new* client cannot be in a
  /// *retired* client's unresolved set, so a tie at the same clock offset is
  /// already excluded by membership and does not need excluding twice.
  bool _aRestartCouldHaveTakenIt(SoakWriteRecord issued) {
    for (final restart in source.panelRestarts) {
      if (restart.panel != issued.panel) continue;
      if (issued.at <= restart.at) return true;
    }
    return false;
  }

  /// The question `WriteOutcomeLog` structurally cannot answer.
  void _reconcileAgainstThePlant() {
    final ledger = source.appliedWrites;
    if (ledger.isTruncated) {
      // Reporting the limit rather than answering past it. A reconciliation
      // that read a floor as an answer would report "no duplicates" about a
      // window it had forgotten, which is the same lie the sixty-second TTL
      // tells and the whole reason this ledger exists.
      _record(
        'the applied-write ledger is truncated — ${ledger.total} applications '
        'recorded, ${ledger.overflow} past its cap — so "was this applied '
        'twice?" can no longer be answered for the whole run, only for the '
        'part still retained. Raise appliedWriteLedgerCapacity, or find out '
        'why this run applied so many more writes than a storm should',
        observed: ledger.total,
        expected: 'at most ${ledger.capacity}',
      );
      return;
    }
    // **`_issued`, not `_terminal`, and the difference is the whole arm.**
    // `_consume` returns before filing an `unknown` into `_terminal` (:260) —
    // correctly, because `unknown` is not an established outcome. Walking
    // `_terminal` therefore skipped every command that stayed unknown for the
    // run, which is the ONE population where a duplicate application is
    // plausible: the link breaks mid-round-trip, the client is told "I cannot
    // say" and keeps the cmd re-queryable, and the gateway or the upstream
    // applies it again across the reconnect. `_checkTheDistribution` requires
    // `unknown > 0`, so that population is on every run.
    //
    // `_issued` holds every command the run made, and `forCmd` is a filter
    // over a bounded list, so this is strictly wider at no cost.
    for (final cmd in _issued.keys) {
      final applications = ledger.forCmd(cmd);
      if (applications.length <= 1) continue;
      final issued = _issued[cmd];
      _record(
        'the plant applied one command ${applications.length} times: '
        '${applications.join(' | ')}. One id is one operator action, so this '
        'is one button press that moved the machine more than once — the '
        'duplicate §7.8 asks about, answered from the plant side because the '
        'gateway\'s own log forgot it inside a minute',
        panel: issued?.panel,
        key: issued?.key,
        observed: applications.length,
        expected: 1,
        at: issued?.at,
      );
    }
  }

  void _checkTheUnresolvedSet() {
    if (worstUnresolved <= unresolvedCeiling) return;
    _record(
      'the client\'s unresolved set reached $worstUnresolved commands against '
      'a ceiling of $unresolvedCeiling. writeStatus re-queries the whole set '
      'on every entry to ready, and past maxKeysPerSubscribe the gateway '
      'refuses the request — so a set that only grows disables the recovery '
      'path for every genuine unknown on that panel. Invariant 4 watches the '
      'same structure as a slope (11-05); this is the backstop underneath it',
      observed: worstUnresolved,
      expected: 'at most $unresolvedCeiling',
    );
  }

  /// Whether the run was long enough to be asked for all three states.
  ///
  /// Printed in the verdict block either way — see [distributionArmFloor].
  bool distributionWasAsked = false;

  /// All three states, or the run never tested the invariant's hard case.
  void _checkTheDistribution() {
    if (declaredDuration < distributionArmFloor) return;
    distributionWasAsked = true;
    if (applied == 0) {
      _record(
        'no write was APPLIED over the whole run, so nothing this checker '
        'judged ever moved the plant. The invariant held against a pipe that '
        'was refusing or losing everything',
        observed: 'applied=0',
        expected: 'applied > 0',
      );
    }
    if (rejected == 0) {
      _record(
        'no write was REJECTED over the whole run. The probe writes to '
        '$_readOnlyHint one time in four precisely so this cannot happen by '
        'accident, so a zero here means those writes are not being issued or '
        'are no longer being refused',
        observed: 'rejected=0',
        expected: 'rejected > 0',
      );
    }
    if (unknown == 0) {
      _record(
        'no write came back UNKNOWN over the whole run, which means the storm '
        'never broke a link during a write\'s round trip and the invariant\'s '
        'hard case — the outcome that is neither applied nor refused, that '
        'must never be auto-retried, and that writeStatus exists to reconcile '
        '— was never tested at all',
        observed: 'unknown=0',
        expected: 'unknown > 0',
      );
    }
  }

  /// Named in a message rather than imported, so this file does not depend on
  /// the driver it is judging.
  static const String _readOnlyHint = 'a key in the PIPE. namespace';

  /// Records a run-end finding.
  ///
  /// **[at] is the instant the finding is ABOUT, not the instant it was
  /// noticed**, and it is the difference between a usable trip record and a
  /// misleading one. `SoakJournal.writeTrip` prints `modes armed` by looking
  /// `scheduleOffset` up in the timeline; stamped with `source.scheduleOffset`
  /// — the end of the run — every run-end violation named whatever the storm
  /// had armed at +35:00. The 35-minute arm's `trip-0.txt` read `monotonic:
  /// +00:00.000 / schedule: +35:00.001 / modes armed: blackhole` for a write
  /// issued around +03:24, and a reader takes that as "the panel was
  /// blackholed when this happened". The issued record is in hand at every
  /// call site that is about one write, so the honest offset costs an
  /// argument.
  ///
  /// Left at the run's end for the findings that genuinely are about the run
  /// as a whole — the distribution arms and the truncated-ledger report.
  void _record(String detail,
      {String? panel, String? key, Object? observed, Object? expected,
      Duration? at}) {
    violationLog.add(SoakViolation(
      checker: name,
      monotonic: at ?? Duration.zero,
      scheduleOffset: at ?? source.scheduleOffset,
      panel: panel,
      key: key,
      observed: observed,
      expected: expected,
      detail: 'seed=${source.seed} — $detail',
    ));
  }

  @override
  String toString() => '$name: $judgedSamples resolved writes against a floor '
      'of $minimumSamplesForAVerdict '
      '(applied $applied, rejected $rejected, unknown $unknown, '
      'not_received $notReceived, $neverReachedASocket never reached a '
      'socket, $reResolvedInAgreement re-reported in agreement, '
      '$orphanedByRestart orphaned by a panel restart across '
      '${source.panelRestarts.length} restarts); '
      '${distributionWasAsked ? 'distribution asked' : 'distribution NOT '
          'asked — declared $declaredDuration is under '
          '$distributionArmFloor'}; '
      '${_terminal.length} terminal, worst unresolved '
      '$worstUnresolved of $unresolvedCeiling; ${source.appliedWrites}';
}
