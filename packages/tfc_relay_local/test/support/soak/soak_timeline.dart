/// The two halves of the storm, merged by a **total** order, with the quiet
/// windows the resync invariant needs designed in rather than hoped for.
///
/// **Why the third sort key exists.** `List.sort` is not stable in Dart: for
/// anything past a short list it is a dual-pivot quicksort, and two entries
/// the comparator calls equal can come out in either order depending on how
/// many other entries there are. Sorting the merged timeline on offset alone
/// therefore makes the relative order of two entries at one offset depend on
/// the *length* of the list — so adding a fifteenth event kind, or one more
/// link fault, could silently reorder a pair somewhere else in a storm whose
/// repro log is already pasted into an issue. [mergeTotalOrder] sorts on
/// `(offset, streamIndex, indexWithinStream)`, which is unique for every
/// entry, so there are no ties to break and the length cannot matter.
///
/// **Why the quiet windows are injected rather than waited for.** Invariant 3
/// — *after each stable window of at least [minStableWindow], every subscribed
/// key equals plant truth* — needs intervals in which nothing is armed. §7.8's
/// own link cadence is 1–10 s, so such intervals occur by luck and cannot be
/// counted on. 11-RESEARCH §C.3 lists three ways out and this file takes the
/// third:
///
///  * **(a) widen the link gap band to 1–15 s.** Makes quiet *more likely*,
///    changes §7.8's own specified cadence, and needs a declared deviation for
///    a property that is still emergent afterwards.
///  * **(b) weight `clean` up in the soak profile.** Same objection: more
///    likely, never guaranteed, and it changes the storm's character in a way
///    that is hard to reason about — a profile biased toward clearing is a
///    calmer storm everywhere, not just where the calm is needed.
///  * **(c) inject explicit quiet windows.** Taken. The windows are
///    *computed*, at generation time, from the duration alone; the event
///    generator draws around them and the merged timeline carries an explicit
///    clear for every incumbent at each window's start. §7.8's 1–10 s cadence
///    is untouched, so the link half needs no deviation at all, and "the
///    resync invariant had eight windows to judge" becomes a fact about the
///    seed rather than a fact about the run.
///
/// Naming (a) and (b) is the point: the next person reading this will have the
/// same three ideas, and two of them are worse for reasons that are not
/// obvious until they are written down.
///
/// **The link half is never regenerated.** [SoakTimeline.link] is exactly what
/// `ScenarioSchedule.generate(seed: seed, duration: d)` returns for that seed,
/// with its defaults, so `schedule_test.dart` still describes it and a link
/// repro log printed by any other phase still means what it said. What the
/// storm actually *plays* is [SoakTimeline.merged], which withholds the link
/// entries that fall inside a quiet window — see [buildTimeline].
///
/// **`ScenarioWeights.soak` is the default and it excludes `killOnce`.** That
/// matters twice. Pitfall 7's tail bias — a storm that drew `killOnce` skips
/// every later `cutMidFrame` and `reject`, because the proxy has no lever that
/// disarms it — cannot apply to this profile. And none of the profile's five
/// names exclude each other (`scenario_schedule.dart:356-359`), so the
/// exclusion table is never consulted for a default soak at all. Widening to
/// `ScenarioWeights.everything` would bring both back; do not do it without
/// reading this paragraph and `scenario_schedule.dart:462-470`.
library;

import 'package:tfc_stateman_contract/faults.dart';

import 'soak_event.dart';

// ----------------------------------------------------------------- the window

/// The shortest interval in which convergence is *required* rather than hoped
/// for.
///
/// **Ten seconds, and it is a floor rather than a measurement — yet.**
/// 11-RESEARCH §B.3 derives it: the client's per-subscription staleness limit
/// is `tickMs × 30` and the ordinary tick is 50–100 ms, so 1.5–3 s covers
/// detection, and a resync round trip on a recovered link is sub-second. Ten
/// seconds leaves better than 3× margin without making windows rare.
///
/// **11-06 owns the measurement** (11-PLAN-INDEX assumption A4: *"N = 10 s is
/// measured, not inherited"*), and it reads or replaces THIS constant rather
/// than declaring a second one. A window shorter than the observed convergence
/// p95 would report divergences that were simply not finished converging,
/// which is the worst possible failure for an artifact whose whole purpose is
/// separating real residue from noise.
const Duration minStableWindow = Duration(seconds: 10);

/// The longest a generated window gets, however long the run is.
///
/// Twenty seconds is 11-RESEARCH §C.3's own figure. Past it a window is not
/// buying more evidence — convergence either happened in the first ten seconds
/// or it is residue — and it is buying less storm.
const Duration maxStableWindow = Duration(seconds: 20);

/// The largest gap between two windows, however long the run is.
///
/// Without the cap a two-hour run would put its windows twelve minutes apart
/// and invariant 3 would sample the same eight times it samples in
/// thirty-five minutes.
const Duration maxWindowCadence = Duration(minutes: 4);

/// The most of a run that may be quiet.
///
/// **This is the clause that makes the arithmetic work at 90 seconds**, and it
/// is 11-02's own addition rather than the plan's. The plan derives the
/// cadence as `duration / 9`, which puts eight windows in *any* run: at 35
/// minutes that is eight 20-second windows in 2,100 seconds (7.6 % quiet, the
/// intended design), and at 90 seconds it is eight 10-second windows in 90
/// seconds — 89 % quiet, leaving ten seconds of actual storm. The short arm
/// would then be a soak in name only, and the fault-driven non-vacuity arms
/// 11-04 and 11-05 depend on would have nothing to fire into.
///
/// Capping the quiet at a third of the run resolves it with the plan's own
/// numbers intact: 35 minutes still gets its eight 20-second windows, and 90
/// seconds gets **three** 10-second windows with 60 seconds of storm left —
/// which is exactly the shape the plan's revised text describes in prose while
/// its formula says otherwise.
const int quietFractionDenominator = 3;

/// The shortest arm that can generate a stable window at all.
///
/// **Thirty seconds, and it falls straight out of the arithmetic below**:
/// [computeStableWindows] caps the quiet at
/// `duration / quietFractionDenominator` and a window is at least
/// [minStableWindow], so a run shorter than the two multiplied together
/// produces none.
///
/// It lives here, beside the two constants it is derived from, rather than in
/// 11-06's checker — a number computed from two constants in one file and
/// written down in another is a number that goes stale the day either of them
/// moves. `soak_test.dart` runs 8- and 12-second auxiliary arms that fall below
/// it, and invariant 3 and the divergence ledger both decline to set a floor
/// they cannot reach on such a run: an arm too short to generate a window is an
/// arm that never asked invariant 3 a question. A run at or above this that
/// generated no windows is a different thing entirely and fails loudly.
final Duration minDurationForAStableWindow =
    minStableWindow * quietFractionDenominator;

/// Where the storm is required to be silent, computed from the duration alone.
///
/// Pure, and that is the whole point: because the schedule exists before the
/// clock starts, the windows are known a priori and invariant 3 can be told
/// *where to look* instead of watching for quiet reactively. 11-RESEARCH §B.3
/// calls this the gift of a pure generated timeline.
///
/// The arithmetic, in full, because a reader checking a printed window count
/// needs it:
///
///  1. window length `L = clamp(minStableWindow, duration / 18, maxStableWindow)`
///     — half the nominal cadence, floored so a window is always judgeable and
///     capped so it never eats the storm;
///  2. nominal cadence `C = min(duration / 9, maxWindowCadence)`;
///  3. count `N = min(duration ~/ C - 1, (duration / quietFractionDenominator) ~/ L)`
///     — the first term is the plan's, the second is the quiet-fraction cap;
///  4. the N windows are spread evenly at `duration / (N + 1)`, so the run
///     begins and ends in storm rather than in silence.
///
/// `L <= duration / (N + 1)` always holds under (3), so the windows never
/// overlap and the last one always ends inside the run — proved by a case
/// rather than left as an assertion here.
List<StableWindow> computeStableWindows(Duration duration) {
  if (duration <= Duration.zero) return const <StableWindow>[];

  final micros = duration.inMicroseconds;
  var length = micros ~/ 18;
  if (length < minStableWindow.inMicroseconds) {
    length = minStableWindow.inMicroseconds;
  }
  if (length > maxStableWindow.inMicroseconds) {
    length = maxStableWindow.inMicroseconds;
  }

  var cadence = micros ~/ 9;
  if (cadence > maxWindowCadence.inMicroseconds) {
    cadence = maxWindowCadence.inMicroseconds;
  }
  if (cadence <= 0) return const <StableWindow>[];

  final byCadence = micros ~/ cadence - 1;
  final byQuietFraction = (micros ~/ quietFractionDenominator) ~/ length;
  final count = byCadence < byQuietFraction ? byCadence : byQuietFraction;
  if (count <= 0) return const <StableWindow>[];

  final spacing = micros ~/ (count + 1);
  return List<StableWindow>.unmodifiable(<StableWindow>[
    for (var k = 1; k <= count; k++)
      StableWindow(
        Duration(microseconds: spacing * k),
        Duration(microseconds: spacing * k + length),
      ),
  ]);
}

// ------------------------------------------------------------------ the merge

/// Which generator an entry came from. The middle key of the total order.
abstract final class SoakStreams {
  /// `ScenarioSchedule.generate` — the proxy levers.
  static const int link = 0;

  /// The clears this file injects at each quiet window's start.
  static const int quietClear = 1;

  /// `SoakEventSchedule.generate` — everything outside the proxy.
  static const int event = 2;

  static String labelOf(int stream) => switch (stream) {
        link => 'link',
        quietClear => 'quiet',
        event => 'event',
        _ => throw ArgumentError.value(stream, 'stream', 'no such stream'),
      };
}

/// One entry of the merged timeline, carrying its position in the total order.
///
/// [streamIndex] and [indexWithinStream] are not decoration: they are the
/// second and third sort keys, and keeping them on the entry is what lets a
/// case assert the order is total instead of assuming it.
final class SoakTimelineEntry {
  const SoakTimelineEntry({
    required this.offset,
    required this.streamIndex,
    required this.indexWithinStream,
    required this.payload,
  });

  final Duration offset;
  final int streamIndex;
  final int indexWithinStream;

  /// A `FaultMutation` for the link and quiet-clear streams, a [SoakEvent] for
  /// the event stream. Deliberately not a third sealed type wrapping the two:
  /// 11-03's `apply` switches on the two existing sealed types, and a wrapper
  /// would be a translation layer with its own opinions — the exact thing
  /// `scenario_schedule.dart:82-89` argues against.
  final Object payload;

  @override
  bool operator ==(Object other) =>
      other is SoakTimelineEntry &&
      other.offset == offset &&
      other.streamIndex == streamIndex &&
      other.indexWithinStream == indexWithinStream &&
      other.payload == payload;

  @override
  int get hashCode =>
      Object.hash(offset, streamIndex, indexWithinStream, payload);

  @override
  String toString() => '[${formatScheduleStamp(offset)}] '
      '${SoakStreams.labelOf(streamIndex).padRight(5)} $payload';
}

/// Interleaves the two halves under a **total** order.
///
/// Sorted by `(offset, streamIndex, indexWithinStream)`. The third key is
/// there because `List.sort` is not stable, so two entries at one offset from
/// two streams would otherwise be free to swap between runs of the same seed
/// as soon as anything changed the length of the list — a replay break in the
/// one place nobody would think to look, and the whole forensics story rests
/// on replay.
///
/// Each list must already be in non-decreasing offset order, which both
/// generators guarantee; [indexWithinStream] is the position in the list as
/// given.
List<SoakTimelineEntry> mergeTotalOrder(
  List<ScheduledFault> link,
  List<ScheduledSoakEvent> events, {
  List<ScheduledFault> quietClears = const <ScheduledFault>[],
}) {
  final merged = <SoakTimelineEntry>[
    for (var i = 0; i < link.length; i++)
      SoakTimelineEntry(
        offset: link[i].offset,
        streamIndex: SoakStreams.link,
        indexWithinStream: i,
        payload: link[i].mutation,
      ),
    for (var i = 0; i < quietClears.length; i++)
      SoakTimelineEntry(
        offset: quietClears[i].offset,
        streamIndex: SoakStreams.quietClear,
        indexWithinStream: i,
        payload: quietClears[i].mutation,
      ),
    for (var i = 0; i < events.length; i++)
      SoakTimelineEntry(
        offset: events[i].offset,
        streamIndex: SoakStreams.event,
        indexWithinStream: i,
        payload: events[i].event,
      ),
  ];

  // The third key is the one that matters, and it is the one a later reader
  // will be tempted to delete: `List.sort` is not stable, so without it two
  // entries at one offset are free to swap as soon as the list length changes.
  merged.sort((a, b) {
    final byOffset = a.offset.compareTo(b.offset);
    if (byOffset != 0) return byOffset;
    final byStream = a.streamIndex.compareTo(b.streamIndex);
    if (byStream != 0) return byStream;
    return a.indexWithinStream.compareTo(b.indexWithinStream);
  });

  return List<SoakTimelineEntry>.unmodifiable(merged);
}

// --------------------------------------------------------------- the timeline

/// The whole storm for one seed: both halves, the merge, and the windows.
final class SoakTimeline {
  SoakTimeline({
    required this.seed,
    required this.duration,
    required List<ScheduledFault> link,
    required List<ScheduledSoakEvent> events,
    required List<ScheduledFault> quietClears,
    required List<SoakTimelineEntry> merged,
    required List<StableWindow> stableWindows,
    required List<String> panels,
    required List<String> aliases,
  })  : link = List<ScheduledFault>.unmodifiable(link),
        events = List<ScheduledSoakEvent>.unmodifiable(events),
        quietClears = List<ScheduledFault>.unmodifiable(quietClears),
        merged = List<SoakTimelineEntry>.unmodifiable(merged),
        stableWindows = List<StableWindow>.unmodifiable(stableWindows),
        panels = List<String>.unmodifiable(panels),
        aliases = List<String>.unmodifiable(aliases);

  /// The run's seed. Both halves derive from it and nothing else does.
  final int seed;

  final Duration duration;

  /// Exactly what `ScenarioSchedule.generate` returns for [seed] — untouched,
  /// so Phase 2's tests still describe it and a link repro log printed
  /// anywhere else still means what it said.
  final List<ScheduledFault> link;

  /// The event half.
  final List<ScheduledSoakEvent> events;

  /// The clears injected at each window's start, one per mode armed then.
  final List<ScheduledFault> quietClears;

  /// **What actually gets played.** The link entries falling inside a quiet
  /// window are withheld from this list; [link] keeps them.
  final List<SoakTimelineEntry> merged;

  /// Where the storm is silent, and where invariant 3 is allowed to judge.
  final List<StableWindow> stableWindows;

  final List<String> panels;
  final List<String> aliases;

  /// How many link entries the quiet windows withheld.
  int get linkEntriesWithheld =>
      link.length -
      merged.where((e) => e.streamIndex == SoakStreams.link).length;

  /// The `(seed, schedule log)` artifact for the whole storm.
  ///
  /// Extends `ScenarioSchedule.reproLog`'s header rather than replacing it,
  /// and keeps its property: *a log pasted into an issue is self-contained*.
  /// A reader six weeks later needs both seeds and the salt between them, both
  /// gap bands, the weights, how many panels and aliases the storm had to aim
  /// at, and where the quiet windows were — because a divergence reported
  /// inside a window means something different from one outside it.
  String get reproLog {
    final windows = stableWindows.isEmpty
        ? 'none'
        : '${stableWindows.length} of '
            '${stableWindows.first.length.inMilliseconds}ms every '
            '${_cadenceMs}ms';
    final linkProfile = ScenarioWeights.soak.byMode.entries
        .map((e) => '${e.key}:${e.value}')
        .join(',');
    final eventProfile = SoakEventWeights.soak.byKind.entries
        .map((e) => '${e.key}:${e.value}')
        .join(',');
    return <String>[
      'soak seed=$seed duration=$duration entries=${merged.length}',
      '  link   seed=$seed entries=${link.length} '
          '(${merged.where((e) => e.streamIndex == SoakStreams.link).length} '
          'played, $linkEntriesWithheld withheld inside quiet windows) '
          'band=1-10s weights=$linkProfile',
      '  events seed=$seed^0x${SoakEventSchedule.eventStreamSalt.toRadixString(16).toUpperCase()}'
          '=${SoakEventSchedule.eventSeedFor(seed)} entries=${events.length} '
          'band=${SoakEventSchedule.defaultMinGap.inSeconds}-'
          '${SoakEventSchedule.defaultMaxGap.inSeconds}s weights=$eventProfile',
      '  panels ${panels.length} ${panels.join(',')} '
          'aliases ${aliases.length} ${aliases.join(',')}',
      '  quiet  $windows; clears=${quietClears.length}'
          '${stableWindows.isEmpty ? '' : ' [${stableWindows.join(' ')}]'}',
      for (final entry in merged) entry.toString(),
    ].join('\n');
  }

  int get _cadenceMs => stableWindows.length < 2
      ? stableWindows.isEmpty
          ? 0
          : stableWindows.first.start.inMilliseconds
      : (stableWindows[1].start - stableWindows[0].start).inMilliseconds;
}

/// Builds the whole storm for [seed]. Pure: no clock, no I/O.
SoakTimeline buildTimeline({
  required int seed,
  required Duration duration,
  required List<String> panels,
  required List<String> aliases,
  Iterable<String>? keys,
}) {
  // The link half, with `ScenarioSchedule`'s own defaults — §7.8's 1–10 s
  // cadence and `ScenarioWeights.soak`'s five names. Generated ONCE and never
  // regenerated: this list is the artifact `schedule_test.dart` describes.
  final link = ScenarioSchedule.generate(seed: seed, duration: duration);

  final windows = computeStableWindows(duration);

  // The event half knows where the windows are, so it draws around them
  // rather than being filtered afterwards — a suppressed draw is recorded as a
  // suppression, where a filtered emission would just be missing.
  final events = SoakEventSchedule.generate(
    seed: seed,
    duration: duration,
    panels: panels,
    aliases: aliases,
    keys: keys,
    quietWindows: windows,
  );

  // Walk the link half in order, closing each window as it is reached: emit a
  // clear for every mode armed at that instant, and withhold the entries that
  // fall inside. Withholding is what makes the window quiet; the clears are
  // what make it quiet *when a fault was already armed going in*, which is the
  // case an empty stretch cannot distinguish from silence.
  final playedLink = <ScheduledFault>[];
  final quietClears = <ScheduledFault>[];
  // Insertion-ordered, and the order is load-bearing for the same reason
  // `ScenarioSchedule.generate`'s `armed` set is: it decides the order the
  // clears come out in, and a hash-ordered set would make a repro log depend
  // on the hash of a string.
  final armed = <String>{};
  var windowIndex = 0;

  void closeWindowsUpTo(Duration offset) {
    while (windowIndex < windows.length &&
        windows[windowIndex].start <= offset) {
      final start = windows[windowIndex].start;
      for (final mode in armed.toList()) {
        quietClears.add(ScheduledFault(start, clearForMode(mode)));
      }
      armed.clear();
      windowIndex++;
    }
  }

  bool insideAWindow(Duration offset) {
    for (final window in windows) {
      if (window.contains(offset)) return true;
    }
    return false;
  }

  for (final entry in link) {
    closeWindowsUpTo(entry.offset);
    if (insideAWindow(entry.offset)) continue;
    playedLink.add(entry);
    if (entry.mutation.arms) {
      armed.add(entry.mutation.mode);
    } else {
      armed.remove(entry.mutation.mode);
    }
  }
  // Any window after the last link entry still needs its clears: a storm whose
  // final arming draw precedes every remaining window would otherwise hold
  // that fault through all of them.
  closeWindowsUpTo(duration);

  return SoakTimeline(
    seed: seed,
    duration: duration,
    link: link,
    events: events,
    quietClears: quietClears,
    merged: mergeTotalOrder(playedLink, events, quietClears: quietClears),
    stableWindows: windows,
    panels: panels,
    aliases: aliases,
  );
}

/// The mutation that switches [mode] off.
///
/// A second copy of `ScenarioSchedule._clearFor`, which is private, and the
/// duplication is deliberate rather than overlooked. Unlike
/// `exclusiveModePairs` — where a second copy would surface as a `StateError`
/// from a lever twenty minutes into a soak, which is why the house rules
/// forbid restating it — a drift here surfaces as a quiet window that is not
/// quiet, and there is a case that walks the merged timeline and catches
/// exactly that. A second case pins this map against `faultModes`, so a ninth
/// mode added to the registry fails here rather than in a soak.
FaultMutation clearForMode(String mode) => switch (mode) {
      'flap' => const FlapMutation.off(),
      'latency' => const LatencyMutation.off(),
      'throttle' => const ThrottleMutation.off(),
      'blackhole' => const BlackholeMutation(enabled: false),
      'cutMidFrame' => const CutMidFrameMutation.off(),
      'reject' => const RejectMutation(enabled: false),
      'bufferServerToClient' =>
        const BufferServerToClientMutation(enabled: false),
      // The one mode the proxy has no lever to disarm. Loud rather than a
      // no-op clear: with `ScenarioWeights.soak` it is never drawn, so
      // reaching this means somebody widened the profile to `everything`
      // without reading the library doc, and the honest failure is here
      // rather than a "quiet" window with a pending reset still armed in it.
      'killOnce' => throw StateError(
          'killOnce cannot be cleared: FaultProxy disarms it when a '
          'connection arrives to be reset, and generation cannot know '
          'whether one will. A quiet window cannot be made quiet while it is '
          'armed, so the soak profile must not draw it — see '
          'soak_timeline.dart\'s library doc'),
      _ => throw StateError('no clear mutation for mode "$mode"; it is '
          'drawable, so a storm can arm it and then never let go'),
    };
