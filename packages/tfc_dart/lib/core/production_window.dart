/// Works out when production actually ran inside a report's planned range.
///
/// Every function here is pure: recorded samples in, segments and a window
/// out. That is the whole point — "the shift ended at 13:42" has to be a fact
/// anyone can recompute from the same history, not a judgement made once at
/// generation time. The engine fetches; this file decides.
library;

import 'report.dart';
import 'report_math.dart';
import 'report_result.dart';

/// A value that stood over one stretch, or null where nothing was recorded.
class _Held {
  final DateTime from;
  final DateTime to;
  final double? value;

  const _Held(this.from, this.to, this.value);
}

DateTime _min(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

/// Step-holds [w] across `[start, cap)`, marking stretches where the record
/// has gone quiet for longer than [maxGap] as unknown rather than holding the
/// last value across them.
///
/// [maxGap] null means "this key only reports changes": silence is not
/// absence, and the standing value holds however long it takes. That is the
/// honest default, and why a key sampled on an interval has to say so.
List<_Held> _hold(
  SampleWindow w,
  Duration? maxGap,
  DateTime start,
  DateTime cap,
) {
  final out = <_Held>[];
  void add(DateTime from, DateTime to, double? v) {
    if (to.isAfter(from)) out.add(_Held(from, to, v));
  }

  var cursor = start;
  double? standing;
  DateTime? standingSince;
  if (w.boundaryValue != null) {
    standing = w.boundaryValue;
    standingSince = w.boundaryTime ?? start;
  }

  /// Fills `[cursor, until)` with the standing value, cut short by the gap.
  void fill(DateTime until) {
    if (!until.isAfter(cursor)) return;
    if (standing == null) {
      add(cursor, until, null);
      return;
    }
    if (maxGap == null) {
      add(cursor, until, standing);
      return;
    }
    var expires = (standingSince ?? cursor).add(maxGap);
    if (expires.isBefore(cursor)) expires = cursor;
    final held = _min(expires, until);
    add(cursor, held, standing);
    add(held, until, null);
  }

  for (final s in w.samples) {
    if (!cap.isAfter(cursor)) break;
    final at = _min(s.time, cap);
    fill(at);
    if (at.isAfter(cursor)) cursor = at;
    standing = s.value;
    standingSince = at;
  }
  fill(cap);
  return out;
}

/// The value standing at [t] in a held list, and whether it is known.
(bool known, double value) _at(List<_Held> held, DateTime t) {
  for (final h in held) {
    if (!t.isBefore(h.from) && t.isBefore(h.to)) {
      final v = h.value;
      return v == null ? (false, 0) : (true, v);
    }
  }
  return (false, 0);
}

List<StateSegment> _coalesce(List<StateSegment> segments) {
  final out = <StateSegment>[];
  for (final s in segments) {
    if (!s.to.isAfter(s.from)) continue;
    if (out.isNotEmpty && out.last.state == s.state && out.last.to == s.from) {
      final prev = out.removeLast();
      out.add(StateSegment(from: prev.from, to: s.to, state: s.state));
    } else {
      out.add(s);
    }
  }
  return out;
}

List<DateTime> _changePoints(
  Iterable<List<_Held>> lists,
  DateTime start,
  DateTime cap,
) {
  final points = <DateTime>{start, cap};
  for (final list in lists) {
    for (final h in list) {
      if (h.from.isAfter(start) && h.from.isBefore(cap)) points.add(h.from);
      if (h.to.isAfter(start) && h.to.isBefore(cap)) points.add(h.to);
    }
  }
  final sorted = points.toList()..sort();
  return sorted;
}

/// One signal's state over `[start, cap)`.
///
/// Running outranks washing: a line that is producing is producing, whatever
/// a cleaning flag says. Washing outranks idle, because a wash is a thing
/// somebody is doing, and idle is the absence of one.
List<StateSegment> signalSegments({
  required SampleWindow running,
  SampleWindow? cleaning,
  required ActivityRule runningRule,
  ActivityRule? cleaningRule,
  Duration? maxGap,
  required DateTime start,
  required DateTime cap,
}) {
  if (!cap.isAfter(start)) return const [];
  final runHeld = _hold(running, maxGap, start, cap);
  final cleanHeld = cleaning == null
      ? const <_Held>[]
      : _hold(cleaning, maxGap, start, cap);

  final points = _changePoints([runHeld, cleanHeld], start, cap);
  final out = <StateSegment>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final from = points[i];
    final to = points[i + 1];
    final (runKnown, runValue) = _at(runHeld, from);
    final ProductionState state;
    if (runKnown && runningRule.test(runValue)) {
      state = ProductionState.running;
    } else {
      final (cleanKnown, cleanValue) = _at(cleanHeld, from);
      if (cleaningRule != null && cleanKnown && cleaningRule.test(cleanValue)) {
        state = ProductionState.cleaning;
      } else if (!runKnown) {
        state = ProductionState.noData;
      } else {
        state = ProductionState.idle;
      }
    }
    out.add(StateSegment(from: from, to: to, state: state));
  }
  return _coalesce(out);
}

ProductionState _stateAt(List<StateSegment> segments, DateTime t) {
  for (final s in segments) {
    if (!t.isBefore(s.from) && t.isBefore(s.to)) return s.state;
  }
  return ProductionState.noData;
}

/// Merges several signals into the plant's state.
///
/// The plant is producing while anything is producing; washing while
/// something washes and nothing produces; idle only when at least one signal
/// is known to be idle; and no-data when none of them knows anything.
List<StateSegment> mergeSignals(
  List<List<StateSegment>> lanes, {
  required DateTime start,
  required DateTime cap,
}) {
  if (lanes.isEmpty || !cap.isAfter(start)) return const [];
  if (lanes.length == 1) return _coalesce(lanes.first);

  final points = <DateTime>{start, cap};
  for (final lane in lanes) {
    for (final s in lane) {
      if (s.from.isAfter(start) && s.from.isBefore(cap)) points.add(s.from);
      if (s.to.isAfter(start) && s.to.isBefore(cap)) points.add(s.to);
    }
  }
  final sorted = points.toList()..sort();

  final out = <StateSegment>[];
  for (var i = 0; i + 1 < sorted.length; i++) {
    final from = sorted[i];
    final states = [for (final lane in lanes) _stateAt(lane, from)];
    final state = states.contains(ProductionState.running)
        ? ProductionState.running
        : states.contains(ProductionState.cleaning)
            ? ProductionState.cleaning
            : states.contains(ProductionState.idle)
                ? ProductionState.idle
                : ProductionState.noData;
    out.add(StateSegment(from: from, to: sorted[i + 1], state: state));
  }
  return _coalesce(out);
}

/// Names the stopped time an alarm explains.
///
/// Only idle and no-data time becomes [ProductionState.fault]: an alarm
/// standing while the line runs is a warning, not a stop, and the signal is
/// the better witness of what the line was doing.
List<StateSegment> overlayStops(
  List<StateSegment> merged,
  List<TimeRange> stops,
) {
  if (stops.isEmpty) return merged;
  final out = <StateSegment>[];
  for (final seg in merged) {
    if (seg.state == ProductionState.running ||
        seg.state == ProductionState.cleaning) {
      out.add(seg);
      continue;
    }
    final cuts = <DateTime>{seg.from, seg.to};
    for (final s in stops) {
      if (s.from.isAfter(seg.from) && s.from.isBefore(seg.to)) cuts.add(s.from);
      if (s.to.isAfter(seg.from) && s.to.isBefore(seg.to)) cuts.add(s.to);
    }
    final sorted = cuts.toList()..sort();
    for (var i = 0; i + 1 < sorted.length; i++) {
      final from = sorted[i];
      final to = sorted[i + 1];
      final covered = stops.any((s) => !from.isBefore(s.from) && from.isBefore(s.to));
      out.add(StateSegment(
        from: from,
        to: to,
        state: covered ? ProductionState.fault : seg.state,
      ));
    }
  }
  return _coalesce(out);
}

/// Turns the plant's state over the range into a [ProductionWindow].
///
/// The rule, in one sentence: production concluded when the line stopped and
/// never started again before the range ran out — provided that final quiet
/// stretch is long enough to mean it, or contains a wash.
ProductionWindow resolveProductionWindow({
  required DateTime nominalStart,
  required DateTime nominalEnd,
  required DateTime now,
  required List<StateSegment> segments,
  List<SignalLane> lanes = const [],
  List<String> notes = const [],
  Duration idleThreshold = const Duration(minutes: 30),
  Duration cleaningThreshold = const Duration(minutes: 10),
}) {
  final cap = nominalEnd.isAfter(now) ? now : nominalEnd;
  final partial = nominalEnd.isAfter(now);

  Duration total(ProductionState s) => segments
      .where((x) => x.state == s)
      .fold(Duration.zero, (a, x) => a + x.length);

  final running = total(ProductionState.running);
  final idle = total(ProductionState.idle);
  final cleaning = total(ProductionState.cleaning);
  final fault = total(ProductionState.fault);
  final noData = total(ProductionState.noData);

  ProductionWindow build({
    DateTime? actualStart,
    DateTime? concludedAt,
    required ConclusionReason reason,
    required bool tentative,
  }) {
    final effStart = actualStart ?? nominalStart;
    final effEnd = concludedAt ?? cap;
    final effUs = effEnd.difference(effStart).inMicroseconds;
    // Washing inside the window is planned downtime, so it leaves the
    // denominator — the OEE convention, and the one that stops a thorough
    // wash from reading as a bad shift.
    var washUs = 0;
    for (final s in segments) {
      if (s.state != ProductionState.cleaning) continue;
      final lo = s.from.isAfter(effStart) ? s.from : effStart;
      final hi = s.to.isBefore(effEnd) ? s.to : effEnd;
      if (hi.isAfter(lo)) washUs += hi.difference(lo).inMicroseconds;
    }
    final denom = effUs - washUs;
    return ProductionWindow(
      nominalStart: nominalStart,
      nominalEnd: nominalEnd,
      cap: cap,
      actualStart: actualStart,
      concludedAt: concludedAt,
      reason: reason,
      tentative: tentative,
      segments: segments,
      lanes: lanes,
      notes: notes,
      running: running,
      idle: idle,
      cleaning: cleaning,
      fault: fault,
      noData: noData,
      availability: reason == ConclusionReason.noProduction || denom <= 0
          ? null
          : running.inMicroseconds / denom,
    );
  }

  final firstRun = segments
      .where((s) => s.state == ProductionState.running)
      .cast<StateSegment?>()
      .firstWhere((_) => true, orElse: () => null);
  if (firstRun == null) {
    return build(
      reason: ConclusionReason.noProduction,
      tentative: partial,
    );
  }

  // The tail is everything after the last stretch of production. A pause that
  // production came back from is not an ending, however long it was.
  var tailFrom = segments.length;
  for (var i = segments.length - 1; i >= 0; i--) {
    if (segments[i].state == ProductionState.running) break;
    tailFrom = i;
  }
  final tail = segments.sublist(tailFrom);

  if (tail.isNotEmpty) {
    final tailStart = tail.first.from;
    final tailLength = cap.difference(tailStart);
    final tailCleaning = tail
        .where((s) => s.state == ProductionState.cleaning)
        .fold(Duration.zero, (a, s) => a + s.length);
    if (tailLength >= idleThreshold || tailCleaning >= cleaningThreshold) {
      final reason = tailCleaning >= cleaningThreshold
          ? ConclusionReason.cleaning
          : tail.every((s) => s.state == ProductionState.noData)
              ? ConclusionReason.noData
              : ConclusionReason.idle;
      return build(
        actualStart: firstRun.from,
        concludedAt: tailStart,
        reason: reason,
        tentative: partial,
      );
    }
  }

  // Still producing, or stopped too recently to call it.
  return partial
      ? build(
          actualStart: firstRun.from,
          reason: ConclusionReason.ongoing,
          tentative: false,
        )
      : build(
          actualStart: firstRun.from,
          concludedAt: nominalEnd,
          reason: ConclusionReason.shiftEnd,
          tentative: false,
        );
}
