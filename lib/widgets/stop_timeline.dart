import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_interval.dart';
import 'package:tfc_dart/core/alarm_tree.dart';
import 'package:tfc_dart/core/stop_interval_source.dart';

import '../providers/alarm.dart';
import 'alarm.dart' show formatAlarmGroup;
import 'button_graph.dart' show showSetDatePicker;
import 'stop_timeline_geometry.dart';
import 'stop_timeline_painter.dart';

/// What the stop timeline is asked to show.
///
/// The tree it draws is the alarm definitions themselves, grouped by
/// [AlarmConfig.group], so there is almost nothing to specify — a spec
/// picks which part of that tree to show. Severity colours, what a leaf
/// means, how deep it nests: none of that is the caller's to decide, which
/// is why a stop view can never drift out of step with the alarm system.
class StopTimelineSpec {
  const StopTimelineSpec({
    this.groups = const [],
    this.periodHours = 12,
    this.headerText,
  });

  /// Which groups to draw. Empty is the whole alarm tree.
  final List<List<String>> groups;

  /// How much history is loaded and the overview strip covers, when no
  /// rolling span has been picked at runtime.
  final int periodHours;

  /// Header text, or null for the default.
  final String? headerText;
}

/// What one row of the timeline draws, resolved once per data change.
class _Lane {
  _Lane({
    required this.row,
    required this.series,
    required this.depth,
  });

  final AlarmTreeRow row;

  /// Prepared once per (data, filter) change — never per frame.
  final AlarmIntervalSeries series;
  final int depth;

  bool get isGroup => row.isGroup;
  String get label => row.label;
}

/// Loads the alarm tree and its history, then hands both to
/// [StopTimelineView].
///
/// The split is what makes the timeline testable: everything below this class
/// is pure presentation over data it is given, so a golden can render a whole
/// shift without an `AlarmMan`, a `StateMan` or a database behind it.
class StopTimeline extends ConsumerStatefulWidget {
  const StopTimeline(
      {super.key, this.config = const StopTimelineSpec(), this.clock});

  final StopTimelineSpec config;

  /// Fixed clock for tests and goldens: bounds the fetch window and is
  /// handed to the view, whose live edge and once-a-second repaint it also
  /// stills. Live when null.
  final DateTime? clock;

  @override
  ConsumerState<StopTimeline> createState() => _StopTimelineState();
}

class _StopTimelineState extends ConsumerState<StopTimeline> {
  StopIntervalSource _source = StopIntervalSource.empty;
  AlarmTree? _tree;
  Object? _error;

  /// An absolute range the operator picked, or null for the live rolling
  /// period. It bounds the fetch as well as the view: loading a shift from
  /// last week out of a 2000-row newest-first buffer would return rows from
  /// yesterday and draw an empty chart.
  DateTimeRange? _range;

  /// A rolling span picked at runtime, or null for [StopTimelineSpec.periodHours].
  Duration? _interval;

  /// Bumped by every [_load] so a superseded one cannot stomp the winner —
  /// changing the range twice in a row starts two overlapping fetches.
  int _generation = 0;

  /// The three inputs to [_source], kept apart so a stream event can rebuild
  /// it without a database round trip: the last database fetch, AlarmMan's
  /// in-memory ring of cleared activations, and the latest active set. The
  /// ring matters because the database row for a clear is written
  /// fire-and-forget — refetching on the clear event races it and can lose
  /// the stop for a minute; the ring has it instantly, and
  /// [StopIntervalSource.fromAlarms] value-dedupes it against the row once
  /// that lands.
  List<AlarmActive> _history = const [];
  List<AlarmActive> _ring = const [];
  List<AlarmActive> _active = const [];

  /// The standing subscriptions that make the view live: a new activation
  /// appears the moment it fires, a cleared one closes the moment it clears —
  /// not the next time the period is changed. [_man] is who they listen to —
  /// an accepted alarm edit invalidates the provider and builds a new
  /// AlarmMan, and subscriptions left on the orphan would go silent for good.
  StreamSubscription<Set<AlarmActive>>? _activeSub;
  StreamSubscription<List<AlarmActive?>>? _historySub;
  AlarmMan? _man;

  /// True while a period change's fetch is in flight — the stale view stays
  /// up, with a thin progress strip over it instead of a spinner remount.
  bool _reloading = false;

  /// Live safety net: the rolling fetch window goes stale as the clock walks
  /// past it, and rows written by other stations never announce themselves.
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    // A fixed clock means a test or a golden; timers there are only flake.
    if (widget.clock == null) {
      _refresh = Timer.periodic(const Duration(minutes: 1), (_) => _load());
    }
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _historySub?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  /// The stretch of history to fetch: the picked range, or the live one the
  /// view is about to draw.
  ///
  /// Bounding the live fetch too is what makes the row limit go far enough. A
  /// busy plant can spend all 2000 rows on the last two hours, and an
  /// unbounded newest-first query then draws a week-long period with six days
  /// missing — silently, and looking like a week with no stops in it.
  DateTimeRange _fetchWindow() {
    final range = _range;
    if (range != null) return range;
    final now = widget.clock ?? DateTime.now();
    return DateTimeRange(start: now.subtract(_span), end: now);
  }

  Duration get _span =>
      _interval ?? Duration(hours: widget.config.periodHours);

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final man = await ref.read(alarmManProvider.future);
      final window = _fetchWindow();
      final history = await man.getRecentAlarms(
        limit: 2000,
        from: window.start,
        to: window.end,
      );
      if (!mounted || generation != _generation) return;
      // The seeded streams deliver their current value to a new listener, so
      // the first events double as the initial read the `.first` await used
      // to be.
      if (!identical(man, _man)) {
        _man = man;
        _activeSub?.cancel();
        _historySub?.cancel();
        _activeSub = man.activeAlarms().listen(_onActive);
        _historySub = man.history().listen(_onRing);
      }
      setState(() {
        // An alarm the editor marked as not a stop is out at the source:
        // no lane, and no share of the header counts or the overview strip,
        // which only ever ask about uids the tree contains.
        _tree = AlarmTree.fromConfigs(
            man.config.alarms.where((a) => a.countsAsStop).toList());
        _history = history;
        _reloading = false;
        _rebuildSource();
        _error = null;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      // With something already on screen, a failed refresh keeps the last
      // good data — the minute timer retries — rather than replacing a
      // working chart with an error page.
      if (_tree != null) {
        debugPrint('StopTimeline refresh failed: $e');
        setState(() => _reloading = false);
        return;
      }
      setState(() {
        _reloading = false;
        _error = e;
      });
    }
  }

  /// The live set changed: a stop that just began, or one whose ack-required
  /// condition just dropped. Drawn straight from the event.
  void _onActive(Set<AlarmActive> active) {
    // Snapshot immediately: AlarmMan emits its own mutable set, the same
    // instance every time — held references alias the current state.
    _active = List.of(active);
    if (!mounted || _tree == null) return;
    setState(_rebuildSource);
  }

  /// The ring of cleared activations changed: something just closed. This is
  /// the in-memory record — it beats the database row, which is written
  /// fire-and-forget and may not be readable yet.
  void _onRing(List<AlarmActive?> rows) {
    _ring = [
      for (final row in rows)
        if (row != null) row
    ];
    if (!mounted || _tree == null) return;
    setState(_rebuildSource);
  }

  void _rebuildSource() {
    // The ring holds the last thousand clears regardless of age; without the
    // window filter they would inflate the header counts and the overview
    // strip of a short period. The database fetch is already bounded.
    final window = _fetchWindow();
    bool overlaps(AlarmActive row) {
      final deactivated = row.deactivated;
      return row.notification.timestamp.isBefore(window.end) &&
          (deactivated == null || !deactivated.isBefore(window.start));
    }

    _source = StopIntervalSource.fromAlarms(
      history: [..._history, ..._ring.where(overlaps)],
      active: _active,
    );
  }

  /// An absolute range, or null to go back to the live rolling period.
  void _setRange(DateTimeRange? range) {
    setState(() {
      _range = range;
      _error = null;
      _reloading = true;
    });
    _load();
  }

  /// A rolling span ending now. Always live, so it drops any absolute range.
  void _setInterval(Duration interval) {
    setState(() {
      _interval = interval;
      _range = null;
      _error = null;
      _reloading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // The view stays mounted across refetches: only the very first load has
    // nothing to show. Swapping to a spinner on every period change threw
    // away the operator's expansion, filters and view mode with it.
    if (_tree == null) {
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Could not load alarms.\n$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(children: [
      StopTimelineView(
        config: widget.config,
        tree: _tree!,
        source: _source,
        range: _range,
        interval: _interval,
        onRangeChanged: _setRange,
        onIntervalChanged: _setInterval,
        clock: widget.clock,
      ),
      // For the moment between a period pick and its fetch the lanes still
      // slice the old period's data; the strip says so without tearing the
      // view down.
      if (_reloading)
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: LinearProgressIndicator(minHeight: 2),
        ),
    ]);
  }
}

/// The timeline proper: lanes, collapse, pan, zoom, the overview strip and the
/// detail row, over data it is handed.
class StopTimelineView extends StatefulWidget {
  const StopTimelineView({
    super.key,
    required this.config,
    required this.tree,
    required this.source,
    this.range,
    this.interval,
    this.onRangeChanged,
    this.onIntervalChanged,
    this.clock,
  });

  final StopTimelineSpec config;
  final AlarmTree tree;
  final StopIntervalSource source;

  /// An absolute period to show, or null for the live rolling one.
  final DateTimeRange? range;

  /// The rolling span when [range] is null, or null for the configured
  /// [StopTimelineSpec.periodHours].
  final Duration? interval;

  /// Called with the operator's pick from the date-range picker.
  final ValueChanged<DateTimeRange?>? onRangeChanged;

  /// Called with a rolling span picked off the interval menu.
  final ValueChanged<Duration>? onIntervalChanged;

  /// Fixed clock for tests and goldens. Live when null, which also stops the
  /// per-second repaint that keeps a standing alarm growing.
  final DateTime? clock;

  @override
  State<StopTimelineView> createState() => _StopTimelineViewState();
}

class _StopTimelineViewState extends State<StopTimelineView> {
  /// Panning writes here rather than calling setState: the painters listen to
  /// it directly, so a drag repaints the lanes without rebuilding the tree
  /// above them.
  late final ValueNotifier<TimelineWindow> _window;

  final Set<String> _expanded = {};
  final Set<AlarmLevel> _levels = {...AlarmLevel.values};

  /// The selection, held as *coordinates* — which lane, which start — rather
  /// than as an interval object. Data refreshes every few seconds now, and an
  /// object reference into the previous fetch is orphaned by each one; the
  /// coordinates survive, and are resolved against the current series each
  /// build (see [_resolveSelection]).
  String? _selectedLaneKey;
  DateTime? _selectedStart;
  String? _selectedLabel;

  bool _showTable = false;
  ParetoGrouping _grouping = ParetoGrouping.alarm;
  bool _rankByCount = false;

  /// The clock, frozen per frame so every lane and every statistic agrees
  /// about "now". A notifier rather than a field so the painters can repaint
  /// off its ticks: the now line and a standing alarm's live edge must move
  /// even when nothing else changes.
  late final ValueNotifier<DateTime> _clockN;
  DateTime get _now => _clockN.value;
  Timer? _tick;

  /// Whether the view is docked to the live edge and rolls with the clock.
  /// Panning or zooming into the past undocks; pushing back against the
  /// right edge — or picking a new period — docks again.
  late bool _followLive;

  /// Coalesces window changes into one rebuild per frame, so the lane
  /// statistics and the Pareto keep up with a pan without rebuilding the
  /// tree on every pointer event.
  bool _windowRebuildQueued = false;

  static const double _labelWidth = 210;
  static const double _groupRowHeight = 38;
  static const double _alarmRowHeight = 30;

  /// The span the overview strip covers and panning is clamped to.
  ///
  /// A picked range pins it; otherwise it rolls with the clock, at the
  /// runtime interval if one was picked and the configured one if not. The
  /// live period keeps [livePad] of future inside its bounds — the opening
  /// window ends there, and `clampTo` must not yank that sliver away on the
  /// first pan.
  TimelineWindow get _period {
    final range = widget.range;
    if (range != null) return TimelineWindow(range.start, range.end);
    return TimelineWindow(
        _now.subtract(_liveSpan), _now.add(livePad(_liveSpan)));
  }

  Duration get _liveSpan =>
      widget.interval ?? Duration(hours: widget.config.periodHours);

  /// Where the view starts out. A picked range is shown whole — that is what
  /// picking it asked for — and so is a picked rolling span: "Last 24 hours"
  /// answered with the same three hours as before looks like a dead control.
  /// Only the configured default opens on its last three hours, the
  /// shift-so-far rather than a day squeezed into a lane.
  TimelineWindow _openingWindow() {
    final range = widget.range;
    if (range != null) {
      var end = range.end;
      // A degenerate pick (start == end) would make every xOf a division by
      // zero; give it the minimum span instead of NaN geometry.
      if (!end.isAfter(range.start.add(TimelineWindow.minSpan))) {
        end = range.start.add(TimelineWindow.minSpan);
      }
      return TimelineWindow(range.start, end);
    }
    final span = widget.interval ??
        (_liveSpan < const Duration(hours: 3)
            ? _liveSpan
            : const Duration(hours: 3));
    return TimelineWindow(
        _now.subtract(span), _now.add(livePad(_liveSpan)));
  }

  @override
  void initState() {
    super.initState();
    _clockN = ValueNotifier(widget.clock ?? DateTime.now());
    _followLive = widget.range == null;
    _window = ValueNotifier(_openingWindow());
    _window.addListener(_onWindowChanged);
    // The live edge really is live: the window rolls with the clock while it
    // is docked there, so the axis, the header read-out and a standing
    // alarm's bar all keep moving. A repaint and a slide only, never a
    // refetch. A fixed clock means a test or a golden, where a ticking timer
    // would only cause flake.
    if (widget.clock == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final now = DateTime.now();
        if (widget.range == null && _followLive) {
          final span = _window.value.span;
          final end = now.add(livePad(_liveSpan));
          _window.value = TimelineWindow(end.subtract(span), end);
        }
        setState(() => _clockN.value = now);
      });
    }
  }

  @override
  void didUpdateWidget(StopTimelineView old) {
    super.didUpdateWidget(old);
    // A new period is a new question, so the view goes back to the top of it
    // rather than leaving the old window hanging outside the new bounds --
    // where `clampTo` would drag it to an edge nobody asked for. The
    // selection went with the old period too.
    if (old.range != widget.range ||
        old.interval != widget.interval ||
        old.config.periodHours != widget.config.periodHours) {
      _clockN.value = widget.clock ?? DateTime.now();
      _followLive = widget.range == null;
      _window.value = _openingWindow();
      _selectedLaneKey = null;
      _selectedStart = null;
      _selectedLabel = null;
    }
  }

  /// One rebuild per frame however many times the window moved, so labels
  /// and statistics track a pan instead of freezing until the next tick.
  void _onWindowChanged() {
    if (_windowRebuildQueued) return;
    _windowRebuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _windowRebuildQueued = false;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _window.removeListener(_onWindowChanged);
    _window.dispose();
    _clockN.dispose();
    super.dispose();
  }

  /// Lanes for the rows currently visible, with their series prepared.
  List<_Lane> _visibleLanes() {
    final rows = widget.tree.rows(groups: widget.config.groups);

    final lanes = <_Lane>[];
    var hiddenBelow = -1; // depth of the collapsed group we are inside
    for (final row in rows) {
      if (hiddenBelow >= 0) {
        if (row.depth > hiddenBelow) continue;
        hiddenBelow = -1;
      }
      lanes.add(_Lane(row: row, series: _seriesFor(row), depth: row.depth));
      if (row.isGroup && !_expanded.contains(_keyOf(row))) {
        hiddenBelow = row.depth;
      }
    }
    return lanes;
  }

  /// Every alarm the configured groups actually cover.
  ///
  /// The header counts and the overview strip are about what this view is
  /// showing, not about the whole plant — a timeline scoped to Multivac that
  /// reports the site's alarm counts is lying about its own subject.
  Map<String, AlarmConfig> _scopedAlarms() {
    final alarms = <String, AlarmConfig>{};
    for (final row in widget.tree.rows(groups: widget.config.groups)) {
      if (row.isGroup) {
        // subtreeAlarms already includes the group's own bound alarm, and the
        // map dedupes what nested groups report twice.
        for (final alarm in row.group!.subtreeAlarms) {
          alarms[alarm.uid] = alarm;
        }
      } else {
        alarms[row.alarm!.uid] = row.alarm!;
      }
    }
    return alarms;
  }

  Set<String> _scopedUids() => _scopedAlarms().keys.toSet();

  String _keyOf(AlarmTreeRow row) =>
      row.isGroup ? 'g:${row.group!.path.join('/')}' : 'a:${row.alarm!.uid}';

  AlarmIntervalSeries _seriesFor(AlarmTreeRow row) {
    if (!row.isGroup) {
      final alarm = row.alarm!;
      if (!_levels.contains(alarm.rules.isEmpty
          ? AlarmLevel.info
          : alarm.rules.first.level)) {
        return AlarmIntervalSeries(const [], now: _now);
      }
      return widget.source.seriesFor(alarm.uid, now: _now);
    }
    final uids = row.group!.subtreeAlarms
        .where((a) => _levels.contains(
            a.rules.isEmpty ? AlarmLevel.info : a.rules.first.level))
        .map((a) => a.uid);
    return AlarmIntervalSeries(widget.source.mergedFor(uids, now: _now),
        now: _now);
  }

  void _pan(double dx, double width) {
    _moveWindow(_window.value.panBy(dx, width));
  }

  void _zoom(double factor, double anchor) {
    _moveWindow(_window.value.zoomBy(factor, anchor));
  }

  /// Every operator-driven window move lands here, so undocking from the
  /// live edge cannot be forgotten by one of the gestures: looking into the
  /// past stops the clock from dragging the view along, and pushing back up
  /// against the right edge re-docks it.
  void _moveWindow(TimelineWindow window) {
    final clamped = window.clampTo(_period);
    _window.value = clamped;
    if (widget.range == null) {
      _followLive = !clamped.end.isBefore(_period.end);
    }
  }

  Map<AlarmLevel, Color> _levelColors(BuildContext context) => {
        for (final level in AlarmLevel.values)
          level: colorForLevel(context, level)
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lanes = _visibleLanes();
    final selected = _resolveSelection(lanes);
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxHeight < 260;
      return Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(3),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            _header(context, compact: compact),
            if (_showTable && !compact) ...[
              _tableBar(context),
              Expanded(child: _table(context)),
            ] else ...[
              _axis(context),
              Expanded(child: _lanes(context, lanes, selected)),
            ],
            if (!compact) _brush(context),
            if (!compact && !_showTable) _detail(context, selected),
          ],
        ),
      );
    });
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final theme = Theme.of(context);
    final scoped = _scopedUids();
    final counts = <AlarmLevel, int>{for (final l in AlarmLevel.values) l: 0};
    var standing = 0;
    for (final activation in widget.source.all) {
      if (!scoped.contains(activation.alarmUid)) continue;
      final level = activation.level;
      counts[level] = (counts[level] ?? 0) + 1;
      if (activation.isOpen) standing++;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      // The embedding decides the width, so the header has to survive any
      // width. The title ellipsises and the chips scroll rather than
      // overflowing -- and the window readout, the one thing that is never
      // guessable from the lanes, keeps its space.
      child: Row(
        children: [
          // The flex weights are a priority order, not a layout accident: the
          // severity chips are filter controls and have to stay reachable, so
          // they outrank the title, which only has to stay recognisable.
          Flexible(
            flex: 2,
            child: Text(
              widget.config.headerText ?? 'Downtime',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(width: 10),
          if (!compact)
            _viewToggle(context),
          const SizedBox(width: 10),
          if (!compact)
            Flexible(
              flex: 6,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(children: [
                  for (final level in [
                    AlarmLevel.error,
                    AlarmLevel.warning,
                    AlarmLevel.info
                  ])
                    _levelChip(context, level, counts[level] ?? 0),
                ]),
              ),
            ),
          const Spacer(),
          // Only while live: "1 standing" over last week's shift reads as
          // part of that week.
          if (standing > 0 && widget.range == null) ...[
            Icon(Icons.circle,
                size: 8, color: colorForLevel(context, AlarmLevel.error)),
            const SizedBox(width: 4),
            Text('$standing standing',
                maxLines: 1, style: theme.textTheme.labelSmall),
            const SizedBox(width: 10),
          ],
          // Deliberately not Flexible: the period is the one thing in this
          // header that must never be abbreviated -- an elided date reads as
          // today. The title ellipsises instead, and still says enough.
          _periodMenu(context),
        ],
      ),
    );
  }

  /// The period control: a rolling interval, or an absolute range off the
  /// same picker the trend charts use.
  ///
  /// It hangs off the window read-out because that read-out already answers
  /// "which stretch am I looking at" — the operator who wants a different
  /// stretch reaches for the thing telling them which one they have. Without
  /// it the view could only ever show the last [StopTimelineSpec.periodHours]
  /// hours, so yesterday's night shift was not reachable at all.
  Widget _periodMenu(BuildContext context) {
    final theme = Theme.of(context);
    final live = widget.range == null;

    return PopupMenuButton<Object>(
      key: const ValueKey('stop-timeline-period-menu'),
      tooltip: 'Period shown',
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        if (!live)
          PopupMenuItem<Object>(
            key: const ValueKey('stop-timeline-period-live'),
            value: _liveAction,
            child: const Text('Back to live'),
          ),
        if (!live) const PopupMenuDivider(),
        for (final (label, span) in _intervalPresets)
          CheckedPopupMenuItem<Object>(
            key: ValueKey('stop-timeline-interval-${span.inMinutes}'),
            value: span,
            checked: live && _liveSpan == span,
            child: Text(label),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          key: const ValueKey('stop-timeline-pick-range'),
          value: _pickRangeAction,
          child: const Text('Pick a date range…'),
        ),
      ],
      onSelected: (value) {
        if (value is Duration) {
          widget.onIntervalChanged?.call(value);
        } else if (value == _liveAction) {
          widget.onRangeChanged?.call(null);
        } else {
          _pickRange(context);
        }
      },
      child: ValueListenableBuilder(
        valueListenable: _window,
        builder: (context, window, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(live ? Icons.calendar_month : Icons.history,
                size: 12, color: theme.colorScheme.onSurface),
            const SizedBox(width: 4),
            Text(
              _windowLabel(window),
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            Icon(Icons.arrow_drop_down,
                size: 14, color: theme.colorScheme.onSurface),
          ],
        ),
      ),
    );
  }

  Future<void> _pickRange(BuildContext context) async {
    final period = _period;
    final picked = await showSetDatePicker(
        context, DateTimeRange(start: period.start, end: period.end));
    if (picked == null) return;
    widget.onRangeChanged?.call(picked);
  }

  /// The window, with the day spelled out whenever "today" would be a guess.
  String _windowLabel(TimelineWindow window) {
    final crossesDay = !_sameDay(window.start, window.end);
    if (!crossesDay && _sameDay(window.end, _now)) {
      return '${_hhmm(window.start)} – ${_hhmm(window.end)}';
    }
    final end = crossesDay
        ? '${_dayLabel(window.end)} ${_hhmm(window.end)}'
        : _hhmm(window.end);
    return '${_dayLabel(window.start)} ${_hhmm(window.start)} – $end';
  }

  /// Over a window inside one day every tick reads as a time. Once the
  /// window crosses midnight, "00:00" seven times over is seven ways of
  /// saying nothing — the midnight ticks say which day begins instead.
  String _tickLabel(TimelineTick tick, TimelineWindow window) {
    final crossesDay = !_sameDay(window.start, window.end);
    if (crossesDay && tick.at.hour == 0 && tick.at.minute == 0) {
      return _dayLabel(tick.at);
    }
    return _hhmm(tick.at);
  }

  Widget _viewToggle(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(String label, bool selected, VoidCallback onTap) => InkWell(
          key: ValueKey('stop-timeline-view-${label.toLowerCase()}'),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: selected ? theme.colorScheme.primary : null,
            child: Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                    color: selected ? theme.colorScheme.onPrimary : null)),
          ),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          option('Timeline', !_showTable,
              () => setState(() => _showTable = false)),
          option('Table', _showTable, () => setState(() => _showTable = true)),
        ]),
      ),
    );
  }

  /// The Pareto's own controls: what to group by, and which question to ask.
  Widget _tableBar(BuildContext context) {
    final theme = Theme.of(context);
    Widget chip(String label, bool selected, VoidCallback onTap, String key) =>
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: InkWell(
            key: ValueKey(key),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.dividerColor),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(label, style: theme.textTheme.labelSmall),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(children: [
        Text('GROUP BY',
            style: theme.textTheme.labelSmall
                ?.copyWith(fontSize: 9, letterSpacing: 1.1)),
        const SizedBox(width: 8),
        chip('Alarm', _grouping == ParetoGrouping.alarm,
            () => setState(() => _grouping = ParetoGrouping.alarm),
            'stop-timeline-pareto-alarm'),
        chip('Group', _grouping == ParetoGrouping.group,
            () => setState(() => _grouping = ParetoGrouping.group),
            'stop-timeline-pareto-group'),
        chip('Severity', _grouping == ParetoGrouping.severity,
            () => setState(() => _grouping = ParetoGrouping.severity),
            'stop-timeline-pareto-severity'),
        const Spacer(),
        Text('RANK BY',
            style: theme.textTheme.labelSmall
                ?.copyWith(fontSize: 9, letterSpacing: 1.1)),
        const SizedBox(width: 8),
        // Two different questions: what is expensive, and what is chronic.
        chip('Lost time', !_rankByCount,
            () => setState(() => _rankByCount = false),
            'stop-timeline-rank-time'),
        chip('Count', _rankByCount,
            () => setState(() => _rankByCount = true),
            'stop-timeline-rank-count'),
      ]),
    );
  }

  /// The Pareto rows for the visible window, at the current grouping.
  List<ParetoRow> _paretoRows() {
    final window = _window.value;
    final byKey = <String, ParetoRow>{};

    // Straight from the scoped alarms, not from the display rows: a group
    // whose only alarm is its own bound one has no leaf row, and walking rows
    // would silently leave it out of the ranking.
    for (final alarm in _scopedAlarms().values) {
      final level =
          alarm.rules.isEmpty ? AlarmLevel.info : alarm.rules.first.level;
      if (!_levels.contains(level)) continue;
      final stats = widget.source
          .seriesFor(alarm.uid, now: _now)
          .statsIn(window.start, window.end);
      if (stats.count == 0) continue;

      final groupLabel =
          alarm.group.isEmpty ? 'Ungrouped' : alarm.group.join(' › ');
      final (key, label, context) = switch (_grouping) {
        ParetoGrouping.alarm => (alarm.uid, alarm.title, groupLabel),
        ParetoGrouping.group => (groupLabel, groupLabel, null),
        ParetoGrouping.severity => (level.name, _levelLabel(level), null),
      };
      final entry = ParetoRow(
        key: key,
        label: label,
        context: context,
        level: level,
        total: stats.total,
        count: stats.count,
        isOpen: stats.isOpen,
      );
      byKey[key] = byKey.containsKey(key) ? byKey[key]! + entry : entry;
    }
    return rankPareto(byKey.values, byCount: _rankByCount);
  }

  Widget _table(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _paretoRows();
    if (rows.isEmpty) {
      return Center(
        child: Text('Nothing stopped in this window.',
            style: theme.textTheme.bodySmall),
      );
    }
    final shares = paretoShares(rows);

    return ListView.builder(
      key: const ValueKey('stop-timeline-pareto'),
      padding: EdgeInsets.zero,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final row = rows[i];
        final (share, cumulative) = shares[i];
        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: theme.dividerColor.withValues(alpha: 0.5))),
          ),
          child: Row(children: [
            SizedBox(
              width: 22,
              child: Text('${i + 1}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: colorForLevel(context, row.level),
                  borderRadius: BorderRadius.circular(1)),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 4,
              child: Text(row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium),
            ),
            if (row.context != null)
              Expanded(
                flex: 3,
                child: Text(row.context!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall),
              ),
            SizedBox(
              width: 44,
              child: Text('${row.count}×',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            SizedBox(
              width: 62,
              child: Text(_durShort(row.total),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            const SizedBox(width: 10),
            // The bar is the share; the notch behind it is the running total,
            // so the 80/20 point is visible without doing the arithmetic.
            Expanded(
              flex: 4,
              child: LayoutBuilder(builder: (context, c) {
                return Stack(children: [
                  Container(
                      height: 9, color: _laneColor(theme, isGroup: false)),
                  Container(
                    height: 9,
                    width: c.maxWidth * share,
                    color: colorForLevel(context, row.level),
                  ),
                  Positioned(
                    left: (c.maxWidth * cumulative).clamp(0.0, c.maxWidth - 1),
                    width: 1,
                    top: 0,
                    bottom: 0,
                    child: ColoredBox(
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.5)),
                  ),
                ]);
              }),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 34,
              child: Text('${(share * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ]),
        );
      },
    );
  }

  Widget _levelChip(BuildContext context, AlarmLevel level, int count) {
    final on = _levels.contains(level);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        key: ValueKey('stop-timeline-level-${level.name}'),
        onTap: () => setState(() {
          if (!_levels.remove(level)) _levels.add(level);
        }),
        child: Opacity(
          opacity: on ? 1 : 0.35,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    color: colorForLevel(context, level),
                    borderRadius: BorderRadius.circular(1))),
            const SizedBox(width: 4),
            Text('${_levelLabel(level)} $count',
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 6),
          ]),
        ),
      ),
    );
  }

  String _levelLabel(AlarmLevel level) => switch (level) {
        AlarmLevel.error => 'Error',
        AlarmLevel.warning => 'Warning',
        AlarmLevel.info => 'Info',
      };

  Widget _axis(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 22,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(children: [
        SizedBox(
          width: _labelWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 3),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text('ALARM GROUP',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(letterSpacing: 1.1, fontSize: 9)),
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: _window,
            builder: (context, window, _) => LayoutBuilder(
              builder: (context, c) => Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  for (final tick in timelineTicks(window, c.maxWidth))
                    Positioned(
                      // Nudged inside rather than clipped: a picked range
                      // starts on a round hour far more often than a rolling
                      // one does, and a first tick reading ":00" is worse
                      // than one sitting a few pixels off its gridline.
                      left: (tick.x - 20)
                          .clamp(0.0, math.max(0.0, c.maxWidth - 40)),
                      bottom: 3,
                      width: 40,
                      child: Text(
                        _tickLabel(tick, window),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          fontWeight:
                              tick.isHour ? FontWeight.w600 : FontWeight.w400,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _lanes(
      BuildContext context, List<_Lane> lanes, AlarmInterval? selected) {
    final theme = Theme.of(context);
    if (lanes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            widget.config.groups.isEmpty
                ? 'No alarms are configured yet.'
                : 'No alarms are defined under '
                    '${widget.config.groups.map(formatAlarmGroup).join(' or ')}.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    return Stack(children: [
      // The lane ground runs the full height, so the area below the last row
      // still reads as part of the chart rather than as blank page.
      Positioned.fill(
        left: _labelWidth,
        child: ColoredBox(color: _laneColor(theme, isGroup: false)),
      ),
      ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: lanes.length,
        itemBuilder: (context, i) => _laneRow(context, lanes[i], selected),
      ),
      // One overlay for gridlines, the hatch and the future, rather than
      // eleven elements per row repainted on every pan frame.
      Positioned.fill(
        left: _labelWidth,
        child: IgnorePointer(
          child: CustomPaint(
            painter: StopTimelineChromePainter(
              window: _window,
              now: () => _now,
              excluded: const [],
              lineColor: theme.dividerColor.withValues(alpha: 0.35),
              hourLineColor: theme.dividerColor.withValues(alpha: 0.7),
              hatchColor: theme.colorScheme.onSurface.withValues(alpha: 0.09),
              futureColor:
                  theme.colorScheme.surface.withValues(alpha: 0.55),
              nowColor: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              // The clock is a repaint source too: the now line has to keep
              // walking even when the operator has panned into the past and
              // the window is standing still.
              repaint: Listenable.merge([_window, _clockN]),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ]);
  }

  Widget _laneRow(BuildContext context, _Lane lane, AlarmInterval? selected) {
    final theme = Theme.of(context);
    final height = lane.isGroup ? _groupRowHeight : _alarmRowHeight;
    final stats = lane.series.statsIn(_window.value.start, _window.value.end);
    // The selection belongs to one lane; handing it to every painter would
    // ring a bar in each lane that happens to share the start time.
    final laneSelected =
        _keyOf(lane.row) == _selectedLaneKey ? selected : null;

    return SizedBox(
      height: height,
      child: Row(children: [
        SizedBox(
          width: _labelWidth,
          child: _laneLabel(context, lane, stats),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => _pan(d.delta.dx, c.maxWidth),
              onTapUp: (d) => _selectAt(lane, d.localPosition.dx, c.maxWidth),
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    final anchor =
                        (event.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
                    _zoom(event.scrollDelta.dy > 0 ? 1.15 : 0.87, anchor);
                  }
                },
                child: CustomPaint(
                  size: Size(c.maxWidth, height),
                  painter: StopLanePainter(
                    series: lane.series,
                    window: _window,
                    now: () => _now,
                    colors: _levelColors(context),
                    isGroup: lane.isGroup,
                    selectedInterval: laneSelected,
                    selectionColor: theme.colorScheme.primary,
                    laneColor: _laneColor(theme, isGroup: lane.isGroup),
                    repaint: Listenable.merge([_window, _clockN]),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
          }),
        ),
      ]),
    );
  }

  Widget _laneLabel(BuildContext context, _Lane lane, IntervalStats stats) {
    final theme = Theme.of(context);
    final row = lane.row;
    final expandable = row.isGroup && row.group!.hasChildren;
    final open = _expanded.contains(_keyOf(row));

    return InkWell(
      key: ValueKey('stop-timeline-row-${_keyOf(row)}'),
      onTap: expandable
          ? () => setState(() {
                if (!_expanded.remove(_keyOf(row))) _expanded.add(_keyOf(row));
              })
          : null,
      child: Container(
        padding: EdgeInsets.only(left: 6 + lane.depth * 14.0, right: 6),
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(children: [
          SizedBox(
            width: 16,
            child: expandable
                ? Icon(open ? Icons.arrow_drop_down : Icons.arrow_right,
                    size: 16)
                : null,
          ),
          if (!row.isGroup)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: _levelMark(context, row),
            )
          else if (row.group!.bound != null)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: _boundMark(context, row.group!.bound!),
            ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: row.isGroup
                      ? theme.textTheme.labelMedium
                          ?.copyWith(fontWeight: FontWeight.w600)
                      : theme.textTheme.labelSmall,
                ),
                if (lane.isGroup || stats.count > 0)
                  Text(
                    _statLine(stats, isGroup: lane.isGroup),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      color: stats.isOpen
                          ? colorForLevel(context, AlarmLevel.error)
                          : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// A filled square: an alarm, one diagnosis among several.
  Widget _levelMark(BuildContext context, AlarmTreeRow row) {
    final level = row.alarm!.rules.isEmpty
        ? AlarmLevel.info
        : row.alarm!.rules.first.level;
    if (row.isBound) return _boundMark(context, row.alarm!);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
          color: colorForLevel(context, level),
          borderRadius: BorderRadius.circular(1)),
    );
  }

  /// A hollow ring: the alarm that *is* this group, not one inside it.
  Widget _boundMark(BuildContext context, AlarmConfig alarm) {
    final level =
        alarm.rules.isEmpty ? AlarmLevel.info : alarm.rules.first.level;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colorForLevel(context, level), width: 1.5),
      ),
    );
  }

  String _statLine(IntervalStats stats, {required bool isGroup}) {
    final buffer = StringBuffer();
    if (stats.isOpen) buffer.write('now · ');
    buffer.write('${_durShort(stats.total)} · ${stats.count}×');
    return buffer.toString();
  }

  void _selectAt(_Lane lane, double x, double width) {
    final runs = laneRuns(lane.series, _window.value, width, now: _now);
    for (final run in runs) {
      if (x >= run.x1 - 2 && x <= run.x2 + 2) {
        if (run.merged > 1) {
          // A comb of activations too close to tell apart: zoom into it
          // rather than pretending to have picked one.
          final centre =
              _window.value.timeAt((run.x1 + run.x2) / 2, width);
          final span = Duration(
              microseconds:
                  (_window.value.span.inMicroseconds * 0.3).round());
          _moveWindow(
              TimelineWindow(centre.subtract(span ~/ 2), centre.add(span ~/ 2)));
          return;
        }
        setState(() {
          _selectedLaneKey = _keyOf(lane.row);
          _selectedStart = run.interval?.start;
          _selectedLabel = lane.label;
        });
        return;
      }
    }
    setState(() {
      _selectedLaneKey = null;
      _selectedStart = null;
      _selectedLabel = null;
    });
  }

  /// The interval the stored selection coordinates point at in [lanes] —
  /// resolved fresh each build, so it is always an object out of the very
  /// series the painters are drawing, and simply disappears when the data
  /// no longer contains it.
  AlarmInterval? _resolveSelection(List<_Lane> lanes) {
    final start = _selectedStart;
    if (_selectedLaneKey == null || start == null) return null;
    for (final lane in lanes) {
      if (_keyOf(lane.row) != _selectedLaneKey) continue;
      for (final iv in lane.series.intervals) {
        if (iv.start == start) return iv;
      }
      return null;
    }
    return null;
  }

  /// What day the overview strip covers — a range now that it need not end
  /// today, so a week-long period does not label itself with one date.
  String _periodDayLabel() {
    final period = _period;
    return _sameDay(period.start, period.end)
        ? _dayLabel(period.start)
        : '${_dayLabel(period.start)} – ${_dayLabel(period.end)}';
  }

  Widget _brush(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(children: [
        SizedBox(
          width: _labelWidth,
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_periodDayLabel(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 9)),
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _centreOn(d.localPosition.dx, c.maxWidth),
              onHorizontalDragUpdate: (d) =>
                  _centreOn(d.localPosition.dx, c.maxWidth),
              child: CustomPaint(
                size: Size(c.maxWidth, 30),
                painter: StopTimelineBrushPainter(
                  period: _period,
                  window: _window,
                  intervals:
                      widget.source.mergedFor(_scopedUids(), now: _now),
                  now: () => _now,
                  colors: _levelColors(context),
                  trackColor: _laneColor(theme, isGroup: true),
                  windowColor: theme.colorScheme.primary,
                  shadeColor:
                      theme.colorScheme.surface.withValues(alpha: 0.55),
                  repaint: Listenable.merge([_window, _clockN]),
                ),
                child: const SizedBox.expand(),
              ),
            );
          }),
        ),
      ]),
    );
  }

  void _centreOn(double x, double width) {
    final t = _period.timeAt(x, width);
    final span = _window.value.span;
    _moveWindow(TimelineWindow(t.subtract(span ~/ 2), t.add(span ~/ 2)));
  }

  Widget _detail(BuildContext context, AlarmInterval? selected) {
    final theme = Theme.of(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      alignment: Alignment.centerLeft,
      child: selected == null
          ? Text('Select an activation to inspect it.',
              style: theme.textTheme.labelSmall)
          : Row(children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    color: colorForLevel(context, selected.level),
                    borderRadius: BorderRadius.circular(1)),
              ),
              const SizedBox(width: 6),
              Text(_selectedLabel ?? '',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  selected.isOpen
                      ? 'Since ${_stamp(selected.start)} · still standing · '
                          '${_durShort(selected.lengthAt(_now))}'
                      : '${_stamp(selected.start)} – '
                          '${_stamp(selected.end!)} · '
                          '${_durShort(selected.lengthAt(_now))}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ]),
    );
  }

  /// A timestamp for the detail row, with the day spelled out whenever
  /// "today" would be a guess — an alarm standing since yesterday saying
  /// only "Since 14:32:10" reads as ten minutes ago.
  String _stamp(DateTime t) =>
      _sameDay(t, _now) ? _hhmmss(t) : '${_dayLabel(t)} ${_hhmmss(t)}';
}

/// The lane ground. Derived from the surface rather than taken from a
/// Material container role, because those land almost on top of the surface in
/// the light scheme and the lanes then have no edge at all.
Color _laneColor(ThemeData theme, {required bool isGroup}) {
  final ink = theme.colorScheme.onSurface;
  return Color.alphaBlend(
      ink.withValues(alpha: isGroup ? 0.09 : 0.05), theme.colorScheme.surface);
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _hhmmss(DateTime t) => '${_hhmm(t)}:${_two(t.second)}';
String _dayLabel(DateTime t) => '${_two(t.day)}/${_two(t.month)}';
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Menu value for "back to live", which no [Duration] can stand for.
const Object _liveAction = 'live';

/// Menu value for the date-range picker.
const Object _pickRangeAction = 'range';

/// The rolling spans offered off the period menu.
///
/// A shift, a day and a week — the stretches a stop analysis is actually
/// asked about. Anything else is what the date-range picker is for.
const _intervalPresets = <(String, Duration)>[
  ('Last hour', Duration(hours: 1)),
  ('Last 4 hours', Duration(hours: 4)),
  ('Last 8 hours', Duration(hours: 8)),
  ('Last 12 hours', Duration(hours: 12)),
  ('Last 24 hours', Duration(hours: 24)),
  ('Last 7 days', Duration(days: 7)),
];

String _durShort(Duration d) {
  // A future-dated start (clock skew between stations) must not read "-42s".
  if (d.isNegative) return '0s';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  // Two days is where "h" stops being how anyone thinks about it: a week-long
  // total reading "170h 23m" is a sum, not a duration.
  if (d.inHours < 48) return '${d.inHours}h ${_two(d.inMinutes % 60)}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}
