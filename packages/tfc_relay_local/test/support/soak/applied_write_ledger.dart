/// The durable record of what the plant actually applied — the thing §7.8 asked
/// for and this codebase cannot otherwise produce.
///
/// **The clause, and why it cannot be honoured as written.** §7.8 says a write
/// is *"never duplicated server-side (server logs applied writes, compared
/// after the run)"*. **There is no after-the-run comparison to make.** The
/// gateway's own `WriteOutcomeLog` prunes on **every** record and **every**
/// read — `write_outcome_log.dart:210-214`, a `removeWhere` against a horizon
/// of `now() - ttl` — and the ttl is `ServerConfig.writeOutcomeTtl`, **default
/// 60 seconds**, at `server_config.dart:337`. After thirty-five minutes it
/// holds at most the last minute of the run, so a comparison performed at the
/// end would be a comparison of the last sixty seconds wearing the label of the
/// whole soak, which is worse than no comparison at all. F17b already found the
/// operational half of the same fact: past the TTL the gateway *"cannot tell
/// 'never arrived' from 'arrived, and forgotten'"*.
///
/// `WriteOutcomeLog.recordedOutcomes` is not the log either, and its own doc
/// says so: *"read by the test that proves the log is bounded (T-04-06);
/// nothing in production depends on it."* It is a **boundedness observable**,
/// not a ledger. Anybody who finds it and wonders why the soak did not use it
/// should find the answer here rather than re-deriving it — and the measurement
/// is taken rather than argued, in `soak_meta_test.dart`'s *"the entry outlives
/// the gateway's own log"*, which prints both counts side by side at +61 s.
///
/// This is **deviation 3** in `soak_registry.dart`, seeded on day one by 11-01
/// per 11-CONTEXT ruling 3, and the replacement is strictly more information
/// than the clause asked for: every applied write is on this ledger for the
/// whole run, so *"applied twice?"* is answerable at minute 35 about a write
/// that happened at minute 3.
///
/// **Test-only, and the sweep in `freeze_test.dart` keeps it that way.** 08-03
/// task 2's rule is that levers never go on a production class; this hangs off
/// the test `FakeUpstreamLink` and is referenced from no file under `lib/`. The
/// sweep is mechanical rather than a convention, because a convention is a
/// thing somebody eventually does not know about.
///
/// **`nthWrite` is the identity; the cmd id is opaque and nothing keys on it.**
/// The client mints command ids with `Random.secure` (`ulid.dart:17-21`) and
/// does so deliberately — a predictable write id lets a hostile client re-query
/// another operator's outcome — so two runs of one seed produce *different*
/// ids for the *same* storm. Any forensics keyed on them is not reproducible.
/// The *n*-th write of the run is, and that is what [AppliedWriteEntry.nthWrite]
/// is. The cmd is carried anyway, because joining an application to the outcome
/// the client saw needs it *within* one run; it is simply not an identity
/// across runs. **Do not "fix" this by keying on the cmd.**
library;

/// One application, as the plant side saw it.
final class AppliedWriteEntry {
  const AppliedWriteEntry({
    required this.nthWrite,
    required this.key,
    required this.value,
    required this.monotonicMs,
    required this.cmd,
    this.panel,
  });

  /// The run-stable identity: this was the *n*-th write the plant applied,
  /// counting from one.
  final int nthWrite;

  final String key;

  /// What the device took. The written value, since this fake plant clamps
  /// nothing.
  final Object? value;

  /// Elapsed milliseconds on this ledger's own monotonic clock.
  ///
  /// Monotonic and not wall: freeze 9 keeps `DateTime.now()` out of the soak
  /// trees, and *when did this land* is an elapsed-time question wherever it is
  /// asked — 07-REVIEW CR-01's lesson applies to the record as much as to the
  /// verdict.
  final int monotonicMs;

  /// **Opaque.** See the library doc: `Random.secure`, not reproducible, and
  /// nothing may key on it across runs.
  final String cmd;

  /// Which panel acted, if the driver said so before the write crossed. The
  /// plant side cannot know it: a write arrives at an `UpstreamLink` with a
  /// key, a value and a cmd, and no station id.
  final String? panel;

  @override
  String toString() => '#$nthWrite ${panel ?? '(unattributed)'} '
      '$key=$value @ ${monotonicMs}ms cmd=$cmd';
}

/// How many applications the ledger retains before it starts counting instead.
///
/// **Five thousand, and the arithmetic is generous on purpose.** A 35-minute
/// storm draws roughly eleven events a minute, of which a fraction are
/// `PanelWrite`; the driver's own write probe adds one every few seconds. Even
/// counting both, a full run applies hundreds rather than thousands, so this
/// cap is several times the worst case and should never be reached.
///
/// It exists anyway, because a cap that is never hit is still the difference
/// between a bounded harness and a hopeful one — pitfall 1, and 07-RESEARCH
/// trap 15's memory of a gate case becoming *"the unbounded memory growth it is
/// asserting against"*. What makes the cap safe rather than a second lie is
/// [isTruncated]: past it, [appearances] is a floor and says so.
const int appliedWriteLedgerCapacity = 5000;

/// Append-only, bounded, and the only thing in this phase that can answer
/// *"was this applied twice?"* half an hour later.
final class AppliedWriteLedger {
  AppliedWriteLedger({this.capacity = appliedWriteLedgerCapacity})
      : _elapsed = Stopwatch()..start();

  /// How many entries are retained. See [appliedWriteLedgerCapacity].
  final int capacity;

  final Stopwatch _elapsed;
  final List<AppliedWriteEntry> _entries = <AppliedWriteEntry>[];
  final Map<String, String> _panelOf = <String, String>{};
  int _applied = 0;
  int _overflow = 0;

  /// Every retained application, oldest first.
  ///
  /// The **first** are kept rather than the last, as `ViolationLog` keeps the
  /// first violations and for the same reason: what a soak needs is when a
  /// thing started.
  List<AppliedWriteEntry> get entries =>
      List<AppliedWriteEntry>.unmodifiable(_entries);

  /// How many applications were recorded past [capacity].
  int get overflow => _overflow;

  /// Every application, retained or not.
  int get total => _applied;

  /// Whether this ledger has forgotten anything.
  ///
  /// The one thing a reconciliation must ask before believing [appearances]:
  /// past the cap the answer is a **floor**, and reading a floor as an answer
  /// would report "applied once" about a write the ledger had dropped.
  bool get isTruncated => _overflow > 0;

  /// Names the panel behind [cmd], before the write reaches the plant.
  ///
  /// Called by the driver at the moment it issues the write. The plant side has
  /// no station id to work from, and attributing after the fact would race the
  /// application on a slow link.
  void attribute(String cmd, String panel) {
    _panelOf[cmd] = panel;
  }

  /// One write reached the plant and the plant took it.
  ///
  /// Called from the test `FakeUpstreamLink`, on the line that publishes the
  /// value and answers `WriteApplied` — so an application recorded here is one
  /// the device reported holding, which is the only confirmation this system
  /// accepts.
  void recordApplied({
    required String key,
    required Object? value,
    required String cmd,
  }) {
    _applied++;
    if (_entries.length >= capacity) {
      _overflow++;
      return;
    }
    _entries.add(AppliedWriteEntry(
      nthWrite: _applied,
      key: key,
      value: value,
      monotonicMs: _elapsed.elapsedMilliseconds,
      cmd: cmd,
      panel: _panelOf[cmd],
    ));
  }

  /// How many times [key] was applied carrying [value].
  ///
  /// The question `WriteOutcomeLog` structurally cannot answer. A floor rather
  /// than an answer when [isTruncated].
  int appearances(String key, Object? value) {
    var seen = 0;
    for (final entry in _entries) {
      if (entry.key == key && entry.value == value) seen++;
    }
    return seen;
  }

  /// Every application recorded under [cmd] — normally none or one.
  ///
  /// **Two is the duplicate the invariant forbids**, and it is the sharper
  /// question than [appearances] because a storm may legitimately write one
  /// value to one key twice under two different commands. Within a run the cmd
  /// is a perfectly good join; it is only across runs that it means nothing.
  List<AppliedWriteEntry> forCmd(String cmd) => <AppliedWriteEntry>[
        for (final entry in _entries)
          if (entry.cmd == cmd) entry,
      ];

  @override
  String toString() => 'appliedWrites: $total applied '
      '(${_entries.length} retained, $_overflow overflowed)';
}
