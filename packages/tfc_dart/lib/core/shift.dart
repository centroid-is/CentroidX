import 'package:json_annotation/json_annotation.dart';

part 'shift.g.dart';

/// One named shift in the plant's daily pattern.
///
/// A shift is anchored to the wall-clock day it *starts* on: a night shift
/// running 23:00–07:00 belongs to the day it began, which is also the
/// production-day convention reports use. [startMinutes] is minutes after
/// local midnight, so 23:00 is 1380; [durationMinutes] may carry the shift
/// across midnight.
@JsonSerializable(explicitToJson: true)
class ShiftDef {
  String name;

  /// Minutes after local midnight when the shift starts (0..1439).
  @JsonKey(name: 'start_minutes')
  int startMinutes;

  /// How long the shift runs. May cross midnight.
  @JsonKey(name: 'duration_minutes')
  int durationMinutes;

  /// Weekdays the shift *starts* on, [DateTime.monday] (1) through
  /// [DateTime.sunday] (7). A Friday night shift ending Saturday morning
  /// lists only friday.
  List<int> weekdays;

  ShiftDef({
    required this.name,
    required this.startMinutes,
    required this.durationMinutes,
    List<int>? weekdays,
  }) : weekdays = weekdays ??
            [
              DateTime.monday,
              DateTime.tuesday,
              DateTime.wednesday,
              DateTime.thursday,
              DateTime.friday,
              DateTime.saturday,
              DateTime.sunday,
            ];

  factory ShiftDef.fromJson(Map<String, dynamic> json) =>
      _$ShiftDefFromJson(json);
  Map<String, dynamic> toJson() => _$ShiftDefToJson(this);
}

/// The plant's shift pattern, stored as one JSON blob in the shared
/// preferences table so every station and the MCP server agree on it.
@JsonSerializable(explicitToJson: true)
class ShiftManConfig {
  static const String configKey = 'shift_config';

  List<ShiftDef> shifts;

  ShiftManConfig({List<ShiftDef>? shifts}) : shifts = shifts ?? [];

  factory ShiftManConfig.fromJson(Map<String, dynamic> json) =>
      _$ShiftManConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ShiftManConfigToJson(this);
}

/// A shift definition resolved onto a concrete date: the half-open interval
/// `[start, end)` a report actually queries.
class ResolvedShift {
  final ShiftDef def;
  final DateTime start;
  final DateTime end;

  const ResolvedShift({required this.def, required this.start, required this.end});

  /// The production day this shift belongs to — the day it started.
  DateTime get productionDate => DateTime(start.year, start.month, start.day);

  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  String _two(int n) => n.toString().padLeft(2, '0');

  /// e.g. `Day 2026-09-01 07:00–15:00`.
  String get label => '${def.name} '
      '${start.year}-${_two(start.month)}-${_two(start.day)} '
      '${_two(start.hour)}:${_two(start.minute)}–'
      '${_two(end.hour)}:${_two(end.minute)}';

  @override
  String toString() => 'ResolvedShift($label)';
}

/// Resolves the configured shift pattern onto concrete dates.
///
/// This is the whole trick of shift-based reporting: everything downstream is
/// ordinary time-range querying once `(date, shift)` has been turned into
/// `[start, end)`. "Current shift" is the interval containing now, and
/// browsing backwards is index arithmetic on the resolved sequence.
class ShiftCalendar {
  final ShiftManConfig config;

  ShiftCalendar(this.config);

  bool get isEmpty =>
      config.shifts.isEmpty || config.shifts.every((s) => s.weekdays.isEmpty);

  /// Shifts starting on the calendar day of [day], sorted by start time.
  List<ResolvedShift> shiftsStartingOn(DateTime day) {
    final midnight = DateTime(day.year, day.month, day.day);
    final out = <ResolvedShift>[];
    for (final def in config.shifts) {
      if (!def.weekdays.contains(midnight.weekday)) continue;
      // Wall-clock construction rather than midnight + Duration, so a DST
      // change earlier in the day cannot slide the start time.
      final start = DateTime(day.year, day.month, day.day,
          def.startMinutes ~/ 60, def.startMinutes % 60);
      out.add(ResolvedShift(
        def: def,
        start: start,
        end: start.add(Duration(minutes: def.durationMinutes)),
      ));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// The shift whose interval contains [t], if any. A night shift that began
  /// yesterday still contains this morning's early hours, so the previous day
  /// is searched too. When shifts overlap, the latest-starting one wins — it
  /// is the one an operator "on shift" at [t] belongs to.
  ResolvedShift? shiftContaining(DateTime t) {
    ResolvedShift? best;
    for (final dayOffset in [0, -1]) {
      final day = DateTime(t.year, t.month, t.day + dayOffset);
      for (final shift in shiftsStartingOn(day)) {
        if (shift.contains(t) &&
            (best == null || shift.start.isAfter(best.start))) {
          best = shift;
        }
      }
    }
    return best;
  }

  /// The last [count] shifts with `start <= now`, most recent first. The shift
  /// containing [now] (if any) is index 0, then backwards in time.
  ///
  /// The scan is bounded so a config whose weekdays never match (e.g. all
  /// shifts disabled) terminates with what it found.
  List<ResolvedShift> lastShifts(DateTime now, int count,
      {int maxDaysBack = 400}) {
    if (isEmpty || count <= 0) return const [];
    final out = <ResolvedShift>[];
    for (var d = 0; d <= maxDaysBack && out.length < count; d++) {
      final day = DateTime(now.year, now.month, now.day - d);
      final started = shiftsStartingOn(day)
          .where((s) => !s.start.isAfter(now))
          .toList()
        ..sort((a, b) => b.start.compareTo(a.start));
      out.addAll(started);
    }
    return out.take(count).toList();
  }

  /// The shift [offset] steps back from now: 0 is the current (or most
  /// recently started) shift, -1 the one before it. Positive offsets are
  /// meaningless here and return null, as does an offset past the horizon.
  ResolvedShift? byOffset(DateTime now, int offset) {
    if (offset > 0) return null;
    final back = -offset;
    final shifts = lastShifts(now, back + 1);
    return shifts.length > back ? shifts[back] : null;
  }
}
