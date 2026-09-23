import 'package:flutter/material.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/alarm.dart';
import '../widgets/stop_timeline.dart';
import 'package:tfc_dart/core/alarm.dart';

class AlarmViewPage extends StatefulWidget {
  /// Fixed clock handed to the stop analysis and to the alarm History
  /// period, for goldens and tests. Live when null.
  final DateTime? debugClock;

  const AlarmViewPage({Key? key, this.debugClock}) : super(key: key);

  @override
  State<AlarmViewPage> createState() => _AlarmViewPageState();
}

class _AlarmViewPageState extends State<AlarmViewPage> {
  AlarmActive? _selectedAlarm;

  /// Whether the page shows the stop analysis — the same alarm system read
  /// as downtime instead of as a list. It lives here as a sub-view because
  /// the question it answers ("why was the line down?") is asked on this
  /// page, not on a mimic page. Deliberately not a third segment of the
  /// list's Active/History toggle: that toggle picks which *list* is shown,
  /// and sits inside the list's own search bar.
  bool _showStops = false;

  /// Set once the operator has closed the detail pane on purpose; from then
  /// on the page stops choosing for them until they pick an alarm again.
  bool _operatorCleared = false;

  void _setStops(bool stops) {
    setState(() {
      _showStops = stops;
      // A different reading is a different question; the selection belonged
      // to the old one.
      _selectedAlarm = null;
    });
  }

  void _onActiveAlarms(List<AlarmActive> active) {
    if (_operatorCleared) return;
    final current = _selectedAlarm;
    // Keep a selection that is still active; replace one that has cleared
    // (or none at all) with the worst of what is active now.
    if (current != null &&
        active.any((a) => a.notification.uid == current.notification.uid)) {
      return;
    }
    final pick = mostCriticalAlarm(active);
    if (pick?.notification.uid == current?.notification.uid) return;
    setState(() => _selectedAlarm = pick);
  }

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: _showStops ? 'Downtime' : 'Active Alarms',
      // Its own repaint boundary so a golden of the body captures the body,
      // not the window it happens to share with the app bar's live clock.
      body: RepaintBoundary(
        key: const ValueKey('alarm-view-body'),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The page's own header row: which reading of the alarm system
              // is on screen. Full-size and labelled — this is a top-level
              // destination switch for an operator at a panel, not a dense
              // filter — and in the same place in both views, so leaving the
              // stop analysis is the same gesture as entering it.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        icon: Icon(Icons.notifications_outlined),
                        label: Text('Alarms'),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        icon: Icon(Icons.align_horizontal_left),
                        label: Text('Downtime'),
                      ),
                    ],
                    selected: {_showStops},
                    onSelectionChanged: (selection) =>
                        _setStops(selection.first),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _showStops
                    ? StopTimeline(clock: widget.debugClock)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Active Alarms List (left pane)
                          Expanded(
                            flex: 2,
                            child: ListActiveAlarms(
                              clock: widget.debugClock,
                              onShow: (alarm) {
                                setState(() {
                                  _selectedAlarm = alarm;
                                  _operatorCleared = false;
                                });
                              },
                              onViewChanged: () {
                                setState(() {
                                  _selectedAlarm = null;
                                });
                              },
                              onActiveAlarms: _onActiveAlarms,
                            ),
                          ),
                          const SizedBox(width: 24),
                          // Active Alarm View (right pane)
                          Expanded(
                            flex: 3,
                            child: _selectedAlarm != null
                                ? ViewActiveAlarm(
                                    alarm: _selectedAlarm!,
                                    onClose: () {
                                      setState(() {
                                        _selectedAlarm = null;
                                        _operatorCleared = true;
                                      });
                                    },
                                  )
                                : Center(
                                    child: Text(
                                      'Select an alarm to view details',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                  ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The alarm to show when the operator has not picked one: the most severe
/// active alarm, newest first within a level. Arriving on the page to an
/// empty "Select an alarm" pane when something IS wrong was a wasted tap;
/// the worst thing on the line is what they came to read.
AlarmActive? mostCriticalAlarm(List<AlarmActive> active) {
  if (active.isEmpty) return null;
  final sorted = [...active]..sort((a, b) {
      final byLevel = b.notification.rule.level.index
          .compareTo(a.notification.rule.level.index);
      if (byLevel != 0) return byLevel;
      return b.notification.timestamp.compareTo(a.notification.timestamp);
    });
  return sorted.first;
}
