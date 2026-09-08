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
/// different places. [AlarmMan] writes a row to `alarm_history` from
/// `_removeActiveAlarm`, i.e. **when an alarm clears** — so the table holds
/// closed intervals only, and an alarm that is standing right now is missing
/// from it entirely. The live set from `activeAlarms()` holds exactly the
/// ones the table lacks.
///
/// Read one and you get a chart that omits the single stop the operator came
/// to look at. So both are read and unioned, the same way
/// `alarmHistoryEntries` already does for the alarm history list.
class StopIntervalSource {
  /// Closed activations, from `alarm_history`.
  final List<StopActivation> closed;

  /// Open activations, from the live active set. Their intervals have a null
  /// end and run to whatever clock the caller reads them against.
  final List<StopActivation> open;

  StopIntervalSource({required this.closed, required this.open});

  static final empty = StopIntervalSource(closed: const [], open: const []);

  /// Builds the union from the two sources [AlarmMan] exposes.
  ///
  /// [history] is what `getRecentAlarms()` returned; [active] is the latest
  /// `activeAlarms()` event. An alarm appearing in both — which happens for a
  /// frame as `AlarmMan` moves an instance from the active set into the
  /// history buffer — is counted once, as closed, because the closed record is
  /// the more complete one.
  factory StopIntervalSource.fromAlarms({
    required Iterable<AlarmActive> history,
    required Iterable<AlarmActive> active,
  }) {
    final closed = <StopActivation>[];
    // By value, not identity: the same activation reaches this from three
    // places — the live set, AlarmMan's in-memory ring buffer, and a database
    // row reconstructed as a fresh instance — and only (uid, start, rule
    // level) names it in all three. History is read first, so the closed
    // record wins over a live one.
    final seen = <String>{};
    String keyOf(AlarmActive e) => '${e.alarm.config.uid}'
        '@${e.notification.timestamp.microsecondsSinceEpoch}'
        '@${e.notification.rule.level.name}';

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
}
