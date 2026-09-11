import 'alarm.dart';
import 'alarm_interval.dart';

/// One activation of one alarm, as the timeline needs it.
///
/// Distinct from [AlarmInterval], which is the anonymous shape the lanes draw:
/// this one still knows which alarm it belongs to, so the Pareto can group by
/// it and the detail row can name it.
class StopActivation {
  /// The alarm this activation belongs to, by [AlarmConfig.uid].
  final String alarmUid;

  final AlarmInterval interval;

  const StopActivation({required this.alarmUid, required this.interval});

  DateTime get start => interval.start;
  bool get isOpen => interval.isOpen;
  AlarmLevel get level => interval.level;

  @override
  String toString() => 'StopActivation($alarmUid, $interval)';
}

/// Turns alarm activations into the intervals the timeline draws.
///
/// The reason this exists at all is that the two halves of the record live in
/// different places. `alarm_history` is what the plant database knows; the
/// live set from `activeAlarms()` is what this panel is watching right now.
/// Neither is complete on its own — a panel that has only just started reads
/// its standing alarms out of the table, and a station whose database is
/// unreachable still has a live set — so both are read and unioned, the same
/// way `alarmHistoryEntries` already does for the alarm history list.
///
/// Before 14-06 the table held **closed** intervals only, because a row was
/// written when an alarm cleared. It now holds a row for as long as the alarm
/// stands, which is why an open history entry is an ordinary case here and not
/// an anomaly.
class StopIntervalSource {
  /// Closed activations, from `alarm_history`.
  final List<StopActivation> closed;

  /// Open activations, from the live active set. Their intervals have a null
  /// end and run to whatever clock the caller reads them against.
  final List<StopActivation> open;

  StopIntervalSource({required this.closed, required this.open});

  static final empty = StopIntervalSource(closed: const [], open: const []);

  /// Builds the union from the two sources an [AlarmSource] exposes.
  ///
  /// [history] is what `getRecentAlarms()` returned; [active] is the latest
  /// `activeAlarms()` event. An alarm appearing in both is counted once, as
  /// closed, because the history record is the more complete one.
  factory StopIntervalSource.fromAlarms({
    required Iterable<AlarmActive> history,
    required Iterable<AlarmActive> active,
  }) {
    final closed = <StopActivation>[];
    // NOTE (merge, #468): `main` grew its own value-key here —
    // `(uid, timestamp.microsecondsSinceEpoch, rule.level.name)`. This
    // one is kept because the paragraphs above are the reason a
    // MICROSECOND key double-counts: the two halves reach this from
    // producers of different resolution, which is exactly the defect
    // CR-03 measured. The level-vs-ruleIndex difference is covered —
    // two rules of one alarm standing at one instant are two
    // activations either way.
    // Keyed by VALUE, on (uid, ruleIndex, start).
    //
    // This used to be a `Set<AlarmActive>.identity()`, whose stated
    // precondition was that it is the same instance `AlarmMan` moves between
    // the two collections. That precondition is false as of 14-06: the history
    // half is decoded out of `alarm_history` and the live half arrives off the
    // pipe (or out of the local active set), so one standing alarm is two
    // different objects and an identity set sees two activations. Every live
    // alarm in the plant would be drawn twice, and every stop it belongs to
    // double-counted (P-8, D-12).
    //
    // `AlarmActive` has no value equality — and giving it one would change
    // what a dozen widgets mean by `==` — so the key is built here instead.
    // `ruleIndex` is in it because two rules of one alarm can stand at the
    // same instant and are two activations; it is nullable because a pre-v7
    // row states none, and two such rows for one alarm at one instant are
    // still one activation.
    //
    // **The instant is normalised to UTC milliseconds, and that is not
    // cosmetic (CR-03).** A raw `DateTime` key put the double-count straight
    // back, for two independent reasons:
    //
    //  * **Resolution.** The history half is drift-read out of the TEXT column
    //    at MICROSECOND resolution, and the writer stored the full
    //    `toIso8601String()`, so microseconds survive the `::timestamp` round
    //    trip. The live half is
    //    `DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs)` — and
    //    `activeAtMs` is `stamp.at.toUtc().millisecondsSinceEpoch`, so the
    //    wire truncates by construction. An OPC UA `sourceTimestamp` is a
    //    100 ns tick, so a plant instant of `12:00:00.123456Z` is the ordinary
    //    case: it keys as `.123456` against `.123000` and one standing alarm
    //    becomes two activations.
    //  * **Mode.** `DateTime.==` compares the `isUtc` flag too, so a producer
    //    that hands over a local-mode instant misses at ANY precision.
    //
    // Milliseconds because that is the coarsest representation on the wire;
    // anything finer cannot match across the two halves, and anything coarser
    // would start merging genuinely distinct stops — measured: rounding this
    // key to whole seconds turns the "two activations one millisecond apart"
    // arm red on its own.
    //
    // **The `.toUtc()` below is documentary, not load-bearing, and that was
    // measured rather than assumed.** `millisecondsSinceEpoch` is already an
    // absolute instant, so dropping the call changes no value on any machine
    // in any zone — a sabotage run that removed it turned NOTHING red, which
    // is reported here rather than left to look like coverage. The mode half
    // of the defect is fixed by leaving `DateTime` behind at all. It is kept
    // because a bare `millisecondsSinceEpoch` on a key that two different
    // producers feed reads as if the mode had simply not been thought about.
    final seen = <(String, int?, int)>{};

    (String, int?, int) keyOf(AlarmActive entry) => (
          entry.alarm.config.uid,
          entry.notification.ruleIndex,
          entry.notification.timestamp.toUtc().millisecondsSinceEpoch,
        );

    for (final entry in history) {
      if (!seen.add(keyOf(entry))) continue;
      final deactivated = entry.deactivated;
      // A history entry with no deactivation time has not actually closed;
      // treat it as open rather than inventing an end for it.
      closed.add(StopActivation(
        alarmUid: entry.alarm.config.uid,
        interval: AlarmInterval(
          start: entry.notification.timestamp,
          end: deactivated,
          level: entry.notification.rule.level,
        ),
      ));
    }

    final open = <StopActivation>[];
    for (final entry in active) {
      if (!seen.add(keyOf(entry))) continue;
      // An ack-required alarm stays in the active set after its condition
      // clears, carrying the clear time in [AlarmActive.deactivated]. The
      // machine is running again; only the paperwork is outstanding. Drawing
      // it as still-growing downtime until somebody presses OK would charge
      // the line for the operator's coffee break.
      final deactivated = entry.deactivated;
      final activation = StopActivation(
        alarmUid: entry.alarm.config.uid,
        interval: AlarmInterval(
          start: entry.notification.timestamp,
          end: deactivated,
          level: entry.notification.rule.level,
        ),
      );
      (deactivated == null ? open : closed).add(activation);
    }

    return StopIntervalSource(closed: closed, open: open);
  }

  /// Every activation, closed and open, sorted by start.
  ///
  /// Cached: the timeline reads this every second while its clock ticks, and
  /// the instance is immutable, so sorting per read was pure waste.
  late final List<StopActivation> all = List.unmodifiable(
      [...closed, ...open]..sort((a, b) => a.start.compareTo(b.start)));

  /// Whether anything is standing right now.
  bool get hasOpen => open.isNotEmpty;

  /// Activations grouped by alarm uid, each sorted by start.
  ///
  /// Sorted but *not* necessarily disjoint: an alarm with several rules can
  /// stand under two of them at once — AlarmMan keys the active set by
  /// (uid, rule) — so [seriesFor] merges before building a series. Cached for
  /// the same reason [all] is — one lane per visible row asks for it on every
  /// clock tick.
  late final Map<String, List<AlarmInterval>> _byAlarm = () {
    final out = <String, List<AlarmInterval>>{};
    for (final activation in all) {
      (out[activation.alarmUid] ??= []).add(activation.interval);
    }
    return out;
  }();

  Map<String, List<AlarmInterval>> byAlarm() => _byAlarm;

  /// A prepared series for one alarm, ready to be queried per frame.
  ///
  /// Returns an empty series for an alarm with no activations, rather than
  /// null: a lane with nothing in it still has to draw and still reports zero.
  AlarmIntervalSeries seriesFor(
    String alarmUid, {
    required DateTime now,
    List<TimeRange> excluded = const [],
  }) {
    final intervals = byAlarm()[alarmUid] ?? const [];
    // Merged even for one alarm: two of its rules standing at once are two
    // overlapping open intervals, which the series' sorted-disjoint
    // invariant would reject in debug and silently double-count in release.
    return AlarmIntervalSeries(
      intervals.length > 1 ? mergeIntervals(intervals, now: now) : intervals,
      now: now,
      excluded: excluded,
    );
  }

  /// The merged union across several alarms — what a collapsed group lane
  /// draws, carrying the worst severity standing in each stretch.
  List<AlarmInterval> mergedFor(
    Iterable<String> alarmUids, {
    required DateTime now,
  }) {
    final grouped = byAlarm();
    final gathered = <AlarmInterval>[];
    for (final uid in alarmUids) {
      final intervals = grouped[uid];
      if (intervals != null) gathered.addAll(intervals);
    }
    return mergeIntervals(gathered, now: now);
  }

  /// The individual activations that make up one stretch of a merged lane.
  ///
  /// [mergedFor] unions everything under a group into anonymous bars, so a
  /// bar an operator taps can only say how many stops it absorbed. This is
  /// the way back to *which* ones, without expanding the tree and hunting
  /// for them — the whole point of a downtime view is that the answer is one
  /// gesture away.
  ///
  /// Bounds are inclusive: [mergeIntervals] unions intervals that merely
  /// touch, so a contributor can start exactly where the stretch does, and an
  /// exclusive test would drop it.
  ///
  /// Ordered longest first, then by start, then by uid. The uid is not
  /// decoration: `List.sort` is not stable, so without a total order two
  /// activations of equal length and start come back in whichever order the
  /// sort happened to leave them, and a test that pins the list flakes.
  ///
  /// Callers are free to re-order — the group callout reads its own list
  /// chronologically, because a merged stretch is one downtime event and the
  /// first alarm to fire is usually the cause.
  List<StopActivation> activationsIn(
    Iterable<String> alarmUids, {
    required DateTime from,
    required DateTime to,
    required DateTime now,
  }) {
    final wanted = alarmUids.toSet();
    final hits = <StopActivation>[];
    for (final activation in all) {
      if (!wanted.contains(activation.alarmUid)) continue;
      final interval = activation.interval;
      if (interval.start.isAfter(to)) continue;
      if (interval.endAt(now).isBefore(from)) continue;
      hits.add(activation);
    }
    hits.sort((a, b) {
      final byLength =
          b.interval.lengthAt(now).compareTo(a.interval.lengthAt(now));
      if (byLength != 0) return byLength;
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.alarmUid.compareTo(b.alarmUid);
    });
    return hits;
  }
}
