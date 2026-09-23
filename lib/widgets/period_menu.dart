/// The period control shared by the views that read a stretch of history: a
/// rolling interval, or an absolute range off the picker this repo already
/// has.
///
/// It started as the stop timeline's own menu. The alarm History list needed
/// the same control for the same reason — without one it could only ever show
/// whatever happened to be in memory, so yesterday's night shift was not
/// reachable at all — and two menus offering different spans, with different
/// words for "back to live", would be two answers to one question.
library;

import 'package:flutter/material.dart';

import 'button_graph.dart' show showSetDatePicker;

/// What opens when "Pick a date range…" is chosen.
///
/// A parameter rather than a direct call so the menu is testable. The default
/// is [showSetDatePicker], a third-party modal from `board_datetime_picker`
/// whose rendering is not this repo's to pin — it must never be opened inside
/// a golden.
typedef PeriodRangePicker = Future<DateTimeRange?> Function(
  BuildContext context,
  DateTimeRange? current,
);

/// The rolling spans offered off the period menu.
///
/// A shift, a day and a week — the stretches history is actually asked about.
/// Anything else is what the date-range picker is for.
const kPeriodPresets = <(String, Duration)>[
  ('Last hour', Duration(hours: 1)),
  ('Last 4 hours', Duration(hours: 4)),
  ('Last 8 hours', Duration(hours: 8)),
  ('Last 12 hours', Duration(hours: 12)),
  ('Last 24 hours', Duration(hours: 24)),
  ('Last 7 days', Duration(days: 7)),
];

/// Menu value for "back to live", which no [Duration] can stand for.
const Object kPeriodLiveAction = 'live';

/// Menu value for the date-range picker.
const Object kPeriodPickRangeAction = 'range';

/// The window, with the day spelled out whenever "today" would be a guess.
String periodWindowLabel(DateTimeRange window, DateTime now) {
  final crossesDay = !_sameDay(window.start, window.end);
  if (!crossesDay && _sameDay(window.end, now)) {
    return '${_hhmm(window.start)} – ${_hhmm(window.end)}';
  }
  final end = crossesDay
      ? '${_dayLabel(window.end)} ${_hhmm(window.end)}'
      : _hhmm(window.end);
  return '${_dayLabel(window.start)} ${_hhmm(window.start)} – $end';
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _dayLabel(DateTime t) => '${_two(t.day)}/${_two(t.month)}';
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The menu itself, over whatever [child] the host uses to name the period.
///
/// The host keeps the state — a [range] it was given, or an [interval] rolling
/// off the clock — because the host is what has to refetch when either
/// changes. This widget only offers the choices and reports the pick.
class PeriodMenu extends StatelessWidget {
  const PeriodMenu({
    super.key,
    required this.keyPrefix,
    required this.child,
    required this.window,
    required this.defaultSpan,
    this.range,
    this.interval,
    this.onRangeChanged,
    this.onIntervalChanged,
    this.pickRange = showSetDatePicker,
    this.tooltip = 'Period shown',
  });

  /// Namespaces the widget keys, so a page holding two of these can still
  /// address one: `<prefix>-period-menu`, `-period-live`, `-interval-<min>`
  /// and `-pick-range`.
  final String keyPrefix;

  /// What the operator taps — normally [PeriodMenuLabel].
  final Widget child;

  /// The stretch the picker opens on, read when the menu is used rather than
  /// held, because a live window moves while the menu is on screen.
  final DateTimeRange Function() window;

  /// The rolling span when [interval] is null, so the right preset ticks.
  final Duration defaultSpan;

  /// An absolute range the operator picked, or null for the live rolling
  /// period. Only when it is set is "Back to live" worth offering.
  final DateTimeRange? range;

  /// The rolling span picked at runtime, or null for [defaultSpan].
  final Duration? interval;

  /// An absolute range, or null to go back to the live rolling period.
  final ValueChanged<DateTimeRange?>? onRangeChanged;

  /// A rolling span ending now.
  final ValueChanged<Duration>? onIntervalChanged;

  final PeriodRangePicker pickRange;

  final String tooltip;

  Duration get _liveSpan => interval ?? defaultSpan;

  @override
  Widget build(BuildContext context) {
    final live = range == null;

    return PopupMenuButton<Object>(
      key: ValueKey('$keyPrefix-period-menu'),
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        if (!live)
          PopupMenuItem<Object>(
            key: ValueKey('$keyPrefix-period-live'),
            value: kPeriodLiveAction,
            child: const Text('Back to live'),
          ),
        if (!live) const PopupMenuDivider(),
        for (final (label, span) in kPeriodPresets)
          CheckedPopupMenuItem<Object>(
            key: ValueKey('$keyPrefix-interval-${span.inMinutes}'),
            value: span,
            checked: live && _liveSpan == span,
            child: Text(label),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          key: ValueKey('$keyPrefix-pick-range'),
          value: kPeriodPickRangeAction,
          child: const Text('Pick a date range…'),
        ),
      ],
      onSelected: (value) {
        if (value is Duration) {
          onIntervalChanged?.call(value);
        } else if (value == kPeriodLiveAction) {
          onRangeChanged?.call(null);
        } else {
          _pick(context);
        }
      },
      child: child,
    );
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await pickRange(context, window());
    // Null is the operator cancelling, which changes nothing. Emitting here
    // would turn a dismissed modal into a fresh query.
    if (picked == null) return;
    onRangeChanged?.call(picked);
  }
}

/// The default face of a [PeriodMenu]: which stretch is on screen, and that it
/// can be changed.
///
/// The calendar icon while the period rolls with the clock, the history icon
/// once an absolute range is pinned — the one glyph that says whether what is
/// on screen is still moving.
class PeriodMenuLabel extends StatelessWidget {
  const PeriodMenuLabel({
    super.key,
    required this.label,
    required this.live,
    this.iconSize = 12,
    this.textStyle,
  });

  final String label;
  final bool live;
  final double iconSize;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (textStyle ?? theme.textTheme.labelSmall)
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(live ? Icons.calendar_month : Icons.history,
            size: iconSize, color: theme.colorScheme.onSurface),
        const SizedBox(width: 4),
        Text(label, maxLines: 1, softWrap: false, style: style),
        Icon(Icons.arrow_drop_down,
            size: iconSize + 2, color: theme.colorScheme.onSurface),
      ],
    );
  }
}
