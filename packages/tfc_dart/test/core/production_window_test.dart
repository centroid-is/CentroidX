import 'package:test/test.dart';
import 'package:tfc_dart/core/production_window.dart';
import 'package:tfc_dart/core/report.dart';
import 'package:tfc_dart/core/report_math.dart';
import 'package:tfc_dart/core/report_result.dart';

/// The day shift these cases all describe: 07:00 to 15:00.
void main() {
  final start = DateTime(2026, 9, 1, 7);
  final end = DateTime(2026, 9, 1, 15);
  final afterwards = DateTime(2026, 9, 1, 16);
  DateTime at(int minutes) => start.add(Duration(minutes: minutes));

  SampleWindow win(
    List<(int, double)> samples, {
    double? boundary,
    int? boundaryAt,
    DateTime? from,
    DateTime? to,
  }) =>
      SampleWindow(
        start: from ?? start,
        end: to ?? end,
        boundaryValue: boundary,
        boundaryTime: boundary == null
            ? null
            : (boundaryAt == null ? (from ?? start) : at(boundaryAt)),
        samples: [for (final (m, v) in samples) Sample(at(m), v)],
      );

  final producing = ActivityRule(key: 'Line1.avgBPM1Minute', above: 0.5);
  final washing = ActivityRule(
    key: 'CVS01.CN03.FD01',
    member: 'p_stat_RunMode',
    equalsValue: 4,
  );

  List<StateSegment> segmentsOf(
    SampleWindow running, {
    SampleWindow? cleaning,
    Duration? maxGap,
    DateTime? from,
    DateTime? to,
  }) =>
      signalSegments(
        running: running,
        cleaning: cleaning,
        runningRule: producing,
        cleaningRule: cleaning == null ? null : washing,
        maxGap: maxGap,
        start: from ?? start,
        cap: to ?? end,
      );

  ProductionWindow resolve(
    List<StateSegment> segments, {
    DateTime? now,
    DateTime? nominalStart,
    DateTime? nominalEnd,
    List<SignalLane> lanes = const [],
  }) =>
      resolveProductionWindow(
        nominalStart: nominalStart ?? start,
        nominalEnd: nominalEnd ?? end,
        now: now ?? afterwards,
        segments: segments,
        lanes: lanes,
      );

  group('a shift that ran', () {
    test('production all shift concludes at the planned end', () {
      final w = resolve(segmentsOf(win([], boundary: 5)));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.actualStart, start);
      expect(w.concludedAt, end);
      expect(w.endedEarly, isFalse);
      expect(w.running, const Duration(hours: 8));
      expect(w.availability, 1.0);
    });

    test('a late start moves the window, not the shift', () {
      // Stopped when the shift opened; first batch at 09:12.
      final w = resolve(segmentsOf(win([(132, 5)], boundary: 0)));
      expect(w.actualStart, at(132));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.effectiveStart, at(132));
      expect(w.idle, const Duration(minutes: 132));
    });

    test('a pause production came back from is not an ending', () {
      // Down 10:00–11:45, then running to the end.
      final w = resolve(segmentsOf(
          win([(180, 0), (285, 4)], boundary: 5)));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.concludedAt, end);
      expect(w.idle, const Duration(minutes: 105));
      expect(w.availability, closeTo(375 / 480, 1e-9));
    });

    test('a washing changeover mid-shift is not an ending either', () {
      final w = resolve(segmentsOf(
        win([(180, 0), (205, 6)], boundary: 5),
        cleaning: win([(180, 4), (205, 2)], boundary: 2),
      ));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.cleaning, const Duration(minutes: 25));
      // Washing is planned downtime, so it leaves the availability divisor.
      expect(w.availability, 1.0);
    });
  });

  group('a shift that ended early', () {
    test('stopping for good concludes the shift where it stopped', () {
      // Last batch at 13:42, nothing after.
      final w = resolve(segmentsOf(win([(402, 0)], boundary: 5)));
      expect(w.reason, ConclusionReason.idle);
      expect(w.concludedAt, at(402));
      expect(w.effectiveEnd, at(402));
      expect(w.endedEarly, isTrue);
      expect(w.tentative, isFalse);
    });

    test('the conclusion is where production stopped, not where the wash '
        'started', () {
      final w = resolve(segmentsOf(
        win([(402, 0)], boundary: 5),
        // Idle 13:42–13:55, then washing until 14:40.
        cleaning: win([(415, 4), (460, 1)], boundary: 1),
      ));
      expect(w.reason, ConclusionReason.cleaning);
      expect(w.concludedAt, at(402));
      expect(w.cleaning, const Duration(minutes: 45));
    });

    test('a short quiet tail is not enough to call it', () {
      // Stopped at 14:40 — 20 minutes, under the 30-minute threshold.
      final w = resolve(segmentsOf(win([(460, 0)], boundary: 5)));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.concludedAt, end);
    });

    test('but a wash in that short tail is', () {
      // Stopped 14:45, washed 14:48–15:00: 15 minutes of tail, 12 of washing.
      final w = resolve(segmentsOf(
        win([(465, 0)], boundary: 5),
        cleaning: win([(468, 4)], boundary: 1),
      ));
      expect(w.reason, ConclusionReason.cleaning);
      expect(w.concludedAt, at(465));
    });
  });

  group('missing data', () {
    test('nothing recorded at all is no production, not an idle shift', () {
      final w = resolve(segmentsOf(win([])));
      expect(w.reason, ConclusionReason.noProduction);
      expect(w.isEmpty, isTrue);
      expect(w.actualStart, isNull);
      expect(w.availability, isNull);
      expect(w.segments.single.state, ProductionState.noData);
    });

    test('a line that stood still all shift is no production too', () {
      final w = resolve(segmentsOf(win([], boundary: 0)));
      expect(w.reason, ConclusionReason.noProduction);
      expect(w.segments.single.state, ProductionState.idle);
    });

    test('a collector that died reads as no data, never as idle time', () {
      // Sampled every 30 minutes until 12:00, then silence.
      final samples = [for (var m = 30; m <= 300; m += 30) (m, 5.0)];
      final w = resolve(segmentsOf(
        win(samples, boundary: 5),
        maxGap: const Duration(hours: 1),
      ));
      expect(w.reason, ConclusionReason.noData);
      expect(w.concludedAt, at(360));
      expect(w.noData, const Duration(hours: 2));
      expect(w.idle, Duration.zero);
    });

    test('without a declared sample interval the last value simply stands',
        () {
      final samples = [for (var m = 30; m <= 300; m += 30) (m, 5.0)];
      final w = resolve(segmentsOf(win(samples, boundary: 5)));
      expect(w.reason, ConclusionReason.shiftEnd);
      expect(w.noData, Duration.zero);
    });
  });

  group('a shift still running', () {
    test('a long quiet stretch reads as possibly concluded', () {
      final w = resolve(
        segmentsOf(win([(402, 0)], boundary: 5, to: at(447)), to: at(447)),
        now: at(447),
      );
      expect(w.reason, ConclusionReason.idle);
      expect(w.concludedAt, at(402));
      expect(w.tentative, isTrue);
    });

    test('and starting again takes it back', () {
      final w = resolve(
        segmentsOf(
          win([(402, 0), (440, 4)], boundary: 5, to: at(447)),
          to: at(447),
        ),
        now: at(447),
      );
      expect(w.reason, ConclusionReason.ongoing);
      expect(w.concludedAt, isNull);
      expect(w.effectiveEnd, at(447));
      expect(w.tentative, isFalse);
    });

    test('nothing produced yet says so', () {
      final w = resolve(
        segmentsOf(win([], boundary: 0, to: at(20)), to: at(20)),
        now: at(20),
      );
      expect(w.reason, ConclusionReason.noProduction);
      expect(w.tentative, isTrue);
      expect(w.toText(), 'No production in this range yet.');
    });
  });

  test('a night shift crossing midnight is ordinary arithmetic', () {
    final nightStart = DateTime(2026, 9, 1, 23);
    final nightEnd = DateTime(2026, 9, 2, 7);
    final stopped = DateTime(2026, 9, 2, 4, 10);
    final segments = signalSegments(
      running: SampleWindow(
        start: nightStart,
        end: nightEnd,
        boundaryValue: 5,
        boundaryTime: nightStart,
        samples: [Sample(stopped, 0)],
      ),
      runningRule: producing,
      start: nightStart,
      cap: nightEnd,
    );
    final w = resolveProductionWindow(
      nominalStart: nightStart,
      nominalEnd: nightEnd,
      now: DateTime(2026, 9, 2, 8),
      segments: segments,
    );
    expect(w.reason, ConclusionReason.idle);
    expect(w.concludedAt, stopped);
  });

  test('two lines: the shift is over when the last one finishes', () {
    final lineOne = segmentsOf(win([(402, 0)], boundary: 5));
    final lineTwo = segmentsOf(win([(450, 0)], boundary: 5));
    final merged = mergeSignals([lineOne, lineTwo], start: start, cap: end);
    final w = resolve(
      merged,
      lanes: [
        SignalLane(label: 'Line 1', segments: lineOne),
        SignalLane(label: 'Line 2', segments: lineTwo),
      ],
    );
    expect(w.concludedAt, at(450));
    expect(w.lanes.length, 2);
  });

  group('stop alarms name the stopped time', () {
    test('an alarm over idle time becomes a stop', () {
      final segments = overlayStops(
        segmentsOf(win([(120, 0), (180, 5)], boundary: 5)),
        [TimeRange(at(120), at(140))],
      );
      final w = resolve(segments);
      expect(w.fault, const Duration(minutes: 20));
      expect(w.idle, const Duration(minutes: 40));
    });

    test('an alarm while the line runs does not', () {
      final segments = overlayStops(
        segmentsOf(win([], boundary: 5)),
        [TimeRange(at(120), at(140))],
      );
      expect(resolve(segments).fault, Duration.zero);
    });

    test('an alarm standing over the tail still ends the shift there', () {
      final segments = overlayStops(
        segmentsOf(win([(402, 0)], boundary: 5)),
        [TimeRange(at(402), end)],
      );
      final w = resolve(segments);
      expect(w.reason, ConclusionReason.idle);
      expect(w.concludedAt, at(402));
      expect(w.fault, const Duration(minutes: 78));
    });
  });

  group('rules', () {
    test('a bare rule reads a collected boolean', () {
      final rule = ActivityRule(key: 'Line1.running');
      expect(rule.test(1), isTrue);
      expect(rule.test(0), isFalse);
    });

    test('equals reads an enum column, and outranks above', () {
      final rule = ActivityRule(key: 'd', member: 'p_stat_RunMode', equalsValue: 4);
      expect(rule.test(4), isTrue);
      expect(rule.test(2), isFalse);
    });

    test('above is a rate threshold', () {
      final rule = ActivityRule(key: 'bpm', above: 0.5);
      expect(rule.test(0.6), isTrue);
      expect(rule.test(0.5), isFalse);
    });
  });

  test('the same history resolves the same window twice', () {
    List<StateSegment> build() => segmentsOf(
          win([(402, 0)], boundary: 5),
          cleaning: win([(415, 4)], boundary: 1),
        );
    expect(resolve(build()).toJson().toString(),
        resolve(build()).toJson().toString());
  });
}
