/// The soak's forensics: streamed to disk as the run goes, bounded in memory,
/// and pasteable into an issue without the run.
///
/// **The question this file answers.** An invariant trips at minute 23. What
/// must ALREADY be on disk for that to be diagnosable without re-running
/// twenty-three minutes? Everything below is an answer to that and nothing
/// here is a convenience.
///
/// **Never `package:logger`, and this is measured rather than stylistic.** The
/// package is already a dependency of `tfc_relay_local` and it would be the
/// obvious thing to reach for. Do not: trace level with `PrettyPrinter` costs
/// *seconds* of lag per burst (project memory, PR #210), which in a
/// thirty-five-minute hot loop does not merely slow the run down — it changes
/// what is being measured, and a soak whose instrument perturbs the subject
/// would trip its own invariant 5. A raw `IOSink` from `File.openWrite()` with
/// one `jsonEncode` per line is the whole mechanism.
///
/// **The sizing, so nobody "improves" this into a buffer.** At a 5 s
/// checkpoint cadence over 35 minutes, `metrics.jsonl` is about 420 lines.
/// That is trivially small, trivially greppable, and it turns *"when did this
/// start growing?"* into one `jq` invocation over a file that already exists.
/// There is nothing to optimise and the cost of getting it wrong is the whole
/// artifact.
///
/// **The recorder must not become the leak it is recording.** Pitfall 1, and
/// it has already happened once in this repository: 07-RESEARCH trap 15
/// records `FrameSeam` retaining every inbound frame as a `String` until
/// twenty seconds of ticks made a gate case *"the unbounded memory growth it
/// is asserting against."* So: metrics stream, events stream, frames go in a
/// fixed-capacity ring, and every object this journal holds is enumerated in
/// [SoakJournal.retainedInventory] — which one case drives across five
/// thousand checkpoints and asserts flat. **A field that retains something and
/// is not in that inventory is invisible to the case that proves the harness
/// is honest**; add it there in the same edit.
///
/// **Both clocks, at every checkpoint.** Each checkpoint carries `monotonicMs`
/// from the run's [SoakClock] *and* a wall reading. This is 09-review WR-01's
/// owed cross-check: the reaper's stall forgiveness now compares in one clock
/// domain, the two domains agree under every lever the gate can pull
/// (`Isolate.pause`, `SIGSTOP`), and they diverge exactly under a VM-snapshot
/// stun where the guest's monotonic clock does not observe the freeze. The
/// soak cannot produce a snapshot, so it cannot produce a verdict — what it
/// can do is make a divergence **visible in the artifact** rather than
/// invisible by construction, which costs one field per line. If the two ever
/// drift apart across a run, the reaper's behaviour over that window is the
/// first thing to read. The wall reading is output and never input: nothing in
/// the soak decides anything on it.
library;

import 'dart:convert';
import 'dart:io';

import 'invariant.dart';

/// Where the journal writes, relative to the package root — which is the
/// working directory `dart test` runs from.
///
/// Under `build/` on purpose: `packages/tfc_relay_local/.gitignore` ignores
/// `build/soak/` and the repository root already ignores `build/`, so an
/// artifact directory cannot reach a commit by accident. Moving this constant
/// out from under `build/` means moving the ignore rule in the same edit.
const String defaultSoakJournalDir = 'build/soak';

/// How many inbound frames each panel's ring retains.
///
/// **Two hundred per panel, five panels, one thousand frames of headroom.** At
/// the storm's cadence a panel sees a few frames a second, so two hundred is
/// roughly the last minute before a trip — which is the window a trip is
/// diagnosed from. Thirty-five minutes of frames would be six figures per
/// panel and is exactly trap 15.
const int frameRingCapacity = 200;

/// How many checkpoints the trip record quotes inline.
///
/// Exactly twenty, held in a fixed ring. This is the one place the journal
/// legitimately holds state across the run: a trip record with no history
/// before it says what broke and not when it started, and re-reading
/// `metrics.jsonl` from inside the run to find out would mean the journal
/// reading its own output.
const int metricsTailCapacity = 20;

/// Prints the seed, and does it before anything else does anything.
///
/// **The first line of stdout, before any composition.** A run killed by a CI
/// timeout, an OOM or a cancelled workflow still names its seed, which is the
/// cheapest insurance available and the difference between a failure that can
/// be reproduced and one that cannot. Everything else in this file is written
/// to disk; this one thing is printed, because a killed process's stdout
/// survives and its file handles may not.
void announceSoakSeed(int seed, {required Duration declaredDuration}) {
  print('soak seed=$seed duration=$declaredDuration — reproduce with: '
      '${soakReproductionCommand(seed)}');
}

/// The exact command that reproduces a run.
///
/// Literal rather than assembled from the environment: a reader pastes this,
/// and a command that reads `$RELAY_SOAK_SEED` back out of the shell it is
/// printed into reproduces whatever that shell happens to hold.
String soakReproductionCommand(int seed) =>
    'RELAY_SOAK=1 RELAY_SOAK_SEED=$seed dart test test/soak --tags soak';

/// One inbound frame, as much of it as a trip record needs.
final class JournalledFrame {
  const JournalledFrame({
    required this.arrival,
    required this.seq,
    required this.summary,
  });

  /// Monotonic offset at which it arrived.
  final Duration arrival;

  /// The tick sequence it carried, where it had one.
  final int? seq;

  /// A short rendering — never the whole frame. Trap 15 is about retaining
  /// frame *strings*, and a ring of two hundred whole frames is the same bug
  /// with a bound on it.
  final String summary;

  Map<String, Object?> toJson() => <String, Object?>{
        'arrivalMs': arrival.inMilliseconds,
        'seq': seq,
        'summary': summary,
      };
}

/// A fixed-capacity ring of the most recent frames for one panel.
///
/// Evicts the **oldest**, which is the opposite of [ViolationLog] keeping the
/// first, and the difference is deliberate: a violation flood is one finding
/// whose first instance is the diagnostic, while a trip is diagnosed from what
/// arrived immediately before it. Two bounded structures, two directions, both
/// stated where somebody would otherwise make them agree.
/// **Unit-tested, and the composed run does not feed it.** Nothing in
/// `soak_driver.dart` calls [SoakJournal.frame]; the only callers are this
/// library's own tests. So `_rings` is always empty on a real run and no
/// `frames-<panel>.jsonl` has ever existed.
///
/// That is recorded here, and said in the trip record itself, because the
/// alternative is the failure the rest of this apparatus exists to refuse: a
/// reader opening `trip-0.txt` for the window a trip is diagnosed from, seeing
/// an empty ring, and concluding the frames were checked and were quiet. A
/// skip and a pass must not look identical.
///
/// It is kept rather than deleted because the ring itself is correct and
/// bounded — it evicts oldest and counts evictions — and the missing half is a
/// producer, which is a client-side hook the soak does not have. Whoever adds
/// one should delete this paragraph in the same commit.
final class FrameRing {
  FrameRing({this.capacity = frameRingCapacity});

  final int capacity;
  final List<JournalledFrame> _entries = <JournalledFrame>[];
  int _evicted = 0;

  void add(JournalledFrame frame) {
    _entries.add(frame);
    if (_entries.length > capacity) {
      _entries.removeAt(0);
      _evicted++;
    }
  }

  /// Oldest retained first.
  List<JournalledFrame> get entries =>
      List<JournalledFrame>.unmodifiable(_entries);

  /// How many fell off the back.
  int get evicted => _evicted;

  int get length => _entries.length;
}

/// Streams the run's forensics to `build/soak/`.
final class SoakJournal {
  SoakJournal._(this.seed, this.directory, this._metrics, this._events);

  /// Opens (and creates) the journal directory and both streamed sinks.
  ///
  /// Synchronous by design: this runs before the clock starts, and an `await`
  /// here is one more thing between the seed reaching stdout and the run
  /// beginning.
  factory SoakJournal.open({
    required int seed,
    String path = defaultSoakJournalDir,
  }) {
    final directory = Directory(path)..createSync(recursive: true);
    return SoakJournal._(
      seed,
      directory,
      File('${directory.path}/metrics.jsonl').openWrite(),
      File('${directory.path}/events.jsonl').openWrite(),
    );
  }

  /// The run's seed, which every artifact carries.
  final int seed;

  /// Where everything lands.
  final Directory directory;

  final IOSink _metrics;
  final IOSink _events;

  /// The last [metricsTailCapacity] checkpoints, for the trip record.
  final List<Map<String, Object?>> _metricsTail = <Map<String, Object?>>[];

  final Map<String, FrameRing> _rings = <String, FrameRing>{};

  int _checkpoints = 0;
  int _events_ = 0;
  int _trips = 0;

  // ------------------------------------------------ before the clock starts

  /// Writes the merged timeline, before the first fault fires.
  ///
  /// Before, not after: the end of the run may not arrive, and a storm whose
  /// timeline was going to be written at minute 35 is unreproducible if it
  /// dies at minute 23.
  void writeReproLog(String reproLog) {
    File('${directory.path}/repro.log').writeAsStringSync('$reproLog\n');
  }

  /// Writes the run's constants: durations, gap bands, weights, the panel
  /// count, which panel is the control, and every number each checker judges
  /// against.
  ///
  /// A verdict read six months later against changed defaults is
  /// uninterpretable, and the defaults are exactly the thing nobody thinks to
  /// record.
  void writeConfig(Map<String, Object?> config) {
    final withSeed = <String, Object?>{'seed': seed, ...config};
    File('${directory.path}/config.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(withSeed)}\n');
  }

  // ------------------------------------------------------ streamed as it goes

  /// One metrics checkpoint. Written immediately; retained only in the
  /// twenty-entry tail.
  void checkpoint(SoakClock clock, Map<String, Object?> metrics) {
    final record = <String, Object?>{
      'checkpoint': _checkpoints++,
      'monotonicMs': clock.elapsed.inMilliseconds,
      'wallMs': _wallMs(),
      ...metrics,
    };
    _metrics.writeln(jsonEncode(record));
    _metricsTail.add(record);
    if (_metricsTail.length > metricsTailCapacity) _metricsTail.removeAt(0);
  }

  /// One timeline entry, **as applied**.
  ///
  /// Planned is in `repro.log`; this is what actually fired. *Planned ≠
  /// applied* is a real failure mode — a lever that silently did not — and
  /// each half hides it on its own.
  void event(SoakClock clock, Map<String, Object?> entry) {
    _events.writeln(jsonEncode(<String, Object?>{
      'event': _events_++,
      'monotonicMs': clock.elapsed.inMilliseconds,
      'wallMs': _wallMs(),
      ...entry,
    }));
  }

  /// One inbound frame, into that panel's ring. Never to disk until a trip.
  void frame(String panel, JournalledFrame frame) {
    (_rings[panel] ??= FrameRing()).add(frame);
  }

  // ------------------------------------------------------------- at the trip

  /// Writes `trip-<n>.txt`, and the ring dump for the panel it names.
  ///
  /// [armedModes] is passed in rather than mirrored: the timeline is pure and
  /// fully known, so what was armed at an instant is a **lookup into the
  /// artifact everybody else is reading**. A running mirror of proxy state
  /// could disagree with the proxy, and the one thing worse than not recording
  /// the armed modes is recording the wrong ones.
  void writeTrip(
    SoakViolation violation, {
    required List<String> armedModes,
  }) {
    final n = _trips++;
    final panel = violation.panel;
    final ring = panel == null ? null : _rings[panel];

    final out = StringBuffer()
      ..writeln('soak trip $n — seed=$seed')
      ..writeln('invariant     : ${violation.checker}')
      ..writeln('panel         : ${panel ?? '(none — not a per-panel breach)'}')
      ..writeln('key           : ${violation.key ?? '(none)'}')
      ..writeln('observed      : ${violation.observed}')
      ..writeln('expected      : ${violation.expected}')
      ..writeln('monotonic     : ${formatSoakOffset(violation.monotonic)}')
      ..writeln('schedule      : ${violation.scheduleOffset == null ? 'n/a' : formatSoakOffset(violation.scheduleOffset!)}')
      ..writeln('modes armed   : ${armedModes.isEmpty ? '(none)' : armedModes.join(', ')}')
      ..writeln('detail        : ${violation.detail}')
      ..writeln('')
      ..writeln('reproduce with:')
      ..writeln('  ${soakReproductionCommand(seed)}')
      ..writeln('')
      ..writeln('last ${_metricsTail.length} checkpoints:');
    for (final record in _metricsTail) {
      out.writeln('  ${jsonEncode(record)}');
    }
    out
      ..writeln('')
      ..writeln(ring == null
          ? 'frame ring: NOT RECORDED BY THIS RUN. SoakJournal.frame has no '
              'producer in the composed soak — nothing calls it outside this '
              'journal\'s own unit test — so no frames-<panel>.jsonl has ever '
              'been written. This is an absence of INSTRUMENTATION and not an '
              'absence of frames: do not read it as "the last minute before '
              'the trip was checked and was quiet". See the FrameRing doc.'
          : 'frame ring for $panel: ${ring.length} retained, '
              '${ring.evicted} evicted — dumped to frames-$panel.jsonl');
    File('${directory.path}/trip-$n.txt').writeAsStringSync(out.toString());

    if (panel != null && ring != null) {
      // Only on a trip. A green run's rings never reach disk, which is what
      // keeps a passing soak's artifact readable.
      final dump = StringBuffer();
      for (final frame in ring.entries) {
        dump.writeln(jsonEncode(frame.toJson()));
      }
      File('${directory.path}/frames-$panel.jsonl')
          .writeAsStringSync(dump.toString());
    }
  }

  // ------------------------------------------------------------- book-keeping

  /// Everything this journal is holding in memory, itemised.
  ///
  /// Itemised rather than totalled so that the case which drives five thousand
  /// checkpoints through it can say *what* grew when it grows. **Anything this
  /// class retains must appear here** — a field outside this map is invisible
  /// to the only case that proves the recorder is not the leak.
  Map<String, int> get retainedInventory => <String, int>{
        'metricsTail': _metricsTail.length,
        'frameRingEntries':
            _rings.values.fold(0, (sum, ring) => sum + ring.length),
        'frameRings': _rings.length,
        'openSinks': 2,
      };

  /// The sum of [retainedInventory].
  int get retainedObjects =>
      retainedInventory.values.fold(0, (sum, count) => sum + count);

  /// How many checkpoints have been written.
  int get checkpointCount => _checkpoints;

  /// How many applied events have been written.
  int get eventCount => _events_;

  /// How many trips have been recorded.
  int get tripCount => _trips;

  /// Flushes and closes both sinks.
  ///
  /// **No `.timeout` here.** A dispose path with a timeout is a dispose path
  /// that can leave a sink half-written, and the artifact is the only thing a
  /// failed run leaves behind (project memory: no `.timeout` in dispose
  /// paths).
  Future<void> close() async {
    await _metrics.flush();
    await _metrics.close();
    await _events.flush();
    await _events.close();
  }

  /// The wall reading, which is output and never input.
  ///
  /// The only place in the soak that reads it, and it decides nothing: see the
  /// WR-01 paragraph at the top of this file.
  int _wallMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
}
