import 'package:test/test.dart';
import 'package:tfc_dart/core/shift.dart';

void main() {
  // Mon 2026-08-31 .. Sun 2026-09-06 is the week under test.
  final threeShift = ShiftManConfig(shifts: [
    ShiftDef(name: 'Day', startMinutes: 7 * 60, durationMinutes: 8 * 60),
    ShiftDef(name: 'Evening', startMinutes: 15 * 60, durationMinutes: 8 * 60),
    ShiftDef(
        name: 'Night',
        startMinutes: 23 * 60,
        durationMinutes: 8 * 60,
        weekdays: [
          DateTime.monday,
          DateTime.tuesday,
          DateTime.wednesday,
          DateTime.thursday,
          DateTime.friday,
        ]),
  ]);

  group('shiftsStartingOn', () {
    test('resolves the day pattern in start order', () {
      final shifts =
          ShiftCalendar(threeShift).shiftsStartingOn(DateTime(2026, 9, 1));
      expect(shifts.map((s) => s.def.name), ['Day', 'Evening', 'Night']);
      expect(shifts.first.start, DateTime(2026, 9, 1, 7));
      expect(shifts.first.end, DateTime(2026, 9, 1, 15));
    });

    test('night shift crosses midnight but belongs to its start day', () {
      final night = ShiftCalendar(threeShift)
          .shiftsStartingOn(DateTime(2026, 9, 1))
          .last;
      expect(night.start, DateTime(2026, 9, 1, 23));
      expect(night.end, DateTime(2026, 9, 2, 7));
      expect(night.productionDate, DateTime(2026, 9, 1));
    });

    test('weekday filter drops the weekend night shift', () {
      // 2026-09-05 is a Saturday.
      final saturday =
          ShiftCalendar(threeShift).shiftsStartingOn(DateTime(2026, 9, 5));
      expect(saturday.map((s) => s.def.name), ['Day', 'Evening']);
    });
  });

  group('shiftContaining', () {
    final calendar = ShiftCalendar(threeShift);

    test('finds the shift around an ordinary instant', () {
      final shift = calendar.shiftContaining(DateTime(2026, 9, 1, 10, 30));
      expect(shift?.def.name, 'Day');
    });

    test('early morning belongs to yesterday\'s night shift', () {
      final shift = calendar.shiftContaining(DateTime(2026, 9, 2, 3));
      expect(shift?.def.name, 'Night');
      expect(shift?.productionDate, DateTime(2026, 9, 1));
    });

    test('start is inclusive, end is exclusive', () {
      expect(
          calendar.shiftContaining(DateTime(2026, 9, 1, 7))?.def.name, 'Day');
      expect(calendar.shiftContaining(DateTime(2026, 9, 1, 15))?.def.name,
          'Evening');
    });

    test('a gap in the pattern contains nothing', () {
      // Saturday has no night shift; Sunday 03:00 is uncovered.
      expect(calendar.shiftContaining(DateTime(2026, 9, 6, 3)), isNull);
    });
  });

  group('byOffset', () {
    final calendar = ShiftCalendar(threeShift);
    // Wednesday 2026-09-02 10:00, mid day-shift.
    final now = DateTime(2026, 9, 2, 10);

    test('offset 0 is the current shift', () {
      expect(calendar.byOffset(now, 0)?.label,
          calendar.shiftContaining(now)?.label);
    });

    test('walking backwards crosses midnight in order', () {
      expect(calendar.byOffset(now, -1)?.def.name, 'Night');
      expect(calendar.byOffset(now, -1)?.productionDate, DateTime(2026, 9, 1));
      expect(calendar.byOffset(now, -2)?.def.name, 'Evening');
      expect(calendar.byOffset(now, -3)?.def.name, 'Day');
      expect(calendar.byOffset(now, -3)?.productionDate, DateTime(2026, 9, 1));
    });

    test('offset 0 during a gap is the most recently started shift', () {
      // Sunday 03:00: Saturday evening (15:00-23:00) is the latest start.
      final inGap = DateTime(2026, 9, 6, 3);
      final shift = calendar.byOffset(inGap, 0);
      expect(shift?.def.name, 'Evening');
      expect(shift?.productionDate, DateTime(2026, 9, 5));
    });

    test('future offsets and empty configs return null', () {
      expect(calendar.byOffset(now, 1), isNull);
      expect(ShiftCalendar(ShiftManConfig()).byOffset(now, 0), isNull);
      final disabled = ShiftManConfig(shifts: [
        ShiftDef(
            name: 'Never',
            startMinutes: 0,
            durationMinutes: 60,
            weekdays: []),
      ]);
      expect(ShiftCalendar(disabled).byOffset(now, 0), isNull);
    });
  });

  test('config survives a JSON round trip', () {
    final decoded = ShiftManConfig.fromJson(threeShift.toJson());
    expect(decoded.shifts.length, 3);
    expect(decoded.shifts.last.weekdays, threeShift.shifts.last.weekdays);
    expect(decoded.toJson(), threeShift.toJson());
  });
}
