/// Golden images of the standard popup surfaces, for design review.
///
/// Each golden renders a full 1920×1080 "HMI screen" — an app bar, a mock
/// plant view and a bottom navigation bar — with the pane or dialog on top,
/// so what is under review is how the popup sits in the app, not just the
/// widget in isolation. That is the point of the non-modal design: the plant
/// view stays visible and live beside it.
///
/// The three device shapes are the ones the standard has to cover:
///   * conveyor        — commands (jog), live numbers, setpoints, a trend
///   * elevator / lift — read-only position and configuration
///   * 3rd party I/O   — a channel overview whose bulk detail lives in a
///                       floating dialog
///
/// To update: flutter test test/widgets/panes_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/analog_box.dart'
    show AnalogBoxConfig, AnalogBoxPane;
import 'package:tfc/page_creator/assets/conveyor.dart'
    show conveyorTrendColors, kConveyorFreqSeries, kConveyorCurrentSeries;
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/io_pane.dart';
import 'package:tfc/page_creator/assets/sensor.dart'
    show
        SensorConfig,
        SensorFbPane,
        SensorFbState,
        SensorKind,
        kSensorTrendSeries,
        kSensorTrendCompactPadding,
        sensorTrendColors;
import 'package:tfc/painter/beckhoff/io8.dart' show IOState;
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/graph.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/zoomable_canvas.dart';

// ---------------------------------------------------------------------------
// Screen scaffolding — a stand-in for a real HMI page
// ---------------------------------------------------------------------------

/// A 1080p operator panel — the size the plant actually runs.
const Size _screen = Size(1920, 1080);

/// A mock plant view: a belt line with a lift, drawn flat so the goldens stay
/// stable. It exists to show what the pane covers and what it leaves visible.
class _MockPlantView extends StatelessWidget {
  const _MockPlantView();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget belt(double width, {bool running = true}) => Container(
          width: width,
          height: 26,
          decoration: BoxDecoration(
            color: running ? Colors.green.shade700 : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.black54),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 60, 40, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('INFEED — LINE 1',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 24),
          Row(children: [
            belt(220),
            const SizedBox(width: 12),
            belt(160),
            const SizedBox(width: 12),
            belt(120, running: false),
          ]),
          const SizedBox(height: 40),
          Row(children: [
            belt(140),
            const SizedBox(width: 12),
            Container(
              width: 60,
              height: 90,
              decoration: BoxDecoration(
                border: Border.all(color: scheme.onSurface, width: 2),
                borderRadius: BorderRadius.circular(4),
              ),
              alignment: Alignment.bottomCenter,
              child: Container(height: 14, color: Colors.green.shade700),
            ),
            const SizedBox(width: 12),
            belt(180),
          ]),
        ],
      ),
    );
  }
}

/// The app chrome the panes are designed to sit inside: `BaseScaffold`'s
/// AppBar on top and NavigationBar at the bottom — the pane insets exist so
/// an operator can still read alarms and navigate with a pane open.
Widget _screenApp({required ThemeData theme, required Widget body}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('SVN — Infeed'),
        actions: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Center(child: Text('11-08-2026 09:14:22')),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 1,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.factory), label: 'Line'),
          NavigationDestination(icon: Icon(Icons.warning), label: 'Alarms'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Setup'),
        ],
        onDestinationSelected: (_) {},
      ),
      body: body,
    ),
  );
}

/// Pumps the screen, opens [pane] docked, and settles.
///
/// With [inset] the plant view sits in the runtime page's own wrapper — an
/// aspect-fitted [ZoomableCanvas] inside a [SidePaneInset] — so the golden
/// shows the page re-fitting beside the pane instead of running under it.
Future<void> _pumpWithPane(
  WidgetTester tester, {
  required ThemeData theme,
  required Widget Function(BuildContext context) pane,
  void Function(BuildContext context)? afterOpen,
  bool inset = false,
}) async {
  await tester.binding.setSurfaceSize(_screen);
  // 1:1 pixels: the goldens are for reading, and a 3× capture would put
  // multi-megabyte PNGs in the repo for every review round.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(closeSidePane);

  late BuildContext pageContext;
  await tester.pumpWidget(_screenApp(
    theme: theme,
    body: Builder(builder: (context) {
      pageContext = context;
      const plant = _MockPlantView();
      return inset
          ? const SidePaneInset(child: ZoomableCanvas(child: plant))
          : plant;
    }),
  ));
  showSidePane(context: pageContext, id: 'golden', builder: pane);
  await tester.pumpAndSettle();
  if (afterOpen != null) {
    afterOpen(pageContext);
    await tester.pumpAndSettle();
  }
}

// ---------------------------------------------------------------------------
// Pane bodies — one per device shape
// ---------------------------------------------------------------------------

/// The real conveyor trend chart, fed canned samples.
///
/// This is `Graph` itself — not a stand-in — so the golden shows what an
/// operator sees: time along the bottom, frequency on the left axis and
/// current on the right. Timestamps are fixed constants so the image is
/// reproducible.
class _TrendChart extends StatelessWidget {
  const _TrendChart({this.showButtons = false, this.compact = false});

  final bool showButtons;

  /// Mirrors `ConveyorStatsGraph.compact` — bare tick labels for the pane
  /// preview, units spelled out in the tile caption.
  final bool compact;

  /// 2026-08-11 09:00:00Z, then a sample a minute.
  static const int _t0 = 1786532400000;
  static const int _step = 60000;

  static const List<double> _frequency = [
    41.2,
    43.8,
    47.9,
    48.1,
    48.0,
    48.2,
    47.6,
    48.2,
    48.3,
    48.1,
    44.7,
    41.0,
    45.6,
    48.0,
    48.2,
    48.1,
  ];
  static const List<double> _current = [
    2.10,
    2.44,
    3.02,
    3.10,
    3.06,
    3.14,
    2.88,
    3.12,
    3.20,
    3.08,
    2.61,
    2.05,
    2.79,
    3.05,
    3.16,
    3.14,
  ];

  @override
  Widget build(BuildContext context) {
    final data = <Map<String, dynamic>>[
      for (var i = 0; i < _frequency.length; i++)
        {
          'x': (_t0 + i * _step).toDouble(),
          'y': _frequency[i],
          's': kConveyorFreqSeries,
        },
      for (var i = 0; i < _current.length; i++)
        {
          'x': (_t0 + i * _step).toDouble(),
          'y2': _current[i],
          's': kConveyorCurrentSeries,
        },
    ];
    // An explicit xRange, not xSpan: the live chart windows on
    // DateTime.now(), which would slide the canned samples out of view and
    // make this golden change every run.
    // Both axes through the same helper the live chart uses, so the golden
    // shows the notched range an operator actually gets rather than a
    // hand-picked one.
    final freqRange = stableTrendRange(
      _frequency.reduce(math.min),
      _frequency.reduce(math.max),
    );
    // Current is framed from zero — see ConveyorStatsGraph.
    final currentRange =
        stableTrendRange(0, _current.reduce(math.max), floor: 0);
    return Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: GraphAxisConfig(unit: compact ? '' : 'Time'),
        yAxis: GraphAxisConfig(
          unit: compact ? '' : 'Hz',
          min: freqRange.min,
          max: freqRange.max,
        ),
        yAxis2: GraphAxisConfig(
          unit: compact ? '' : 'A',
          min: currentRange.min,
          max: currentRange.max,
        ),
        xRange: DateTimeRange(
          start: DateTime.fromMillisecondsSinceEpoch(_t0),
          end: DateTime.fromMillisecondsSinceEpoch(
            _t0 + (_frequency.length - 1) * _step,
          ),
        ),
        // The pane preview names its traces in the tile header instead.
        legend: !compact,
      ),
      data: data,
      showButtons: showButtons,
      categoryColors: conveyorTrendColors,
      chartTheme: Theme.of(context).brightness == Brightness.dark
          ? darkChartTheme(
              padding: compact ? kCompactChartPadding : kChartPadding)
          : lightChartTheme(
              padding: compact ? kCompactChartPadding : kChartPadding),
      redraw: () {},
    ).build(context);
  }
}

/// A frequency setpoint field, mirroring `_FrequencyField` in conveyor.dart.
///
/// [focused] renders the mid-edit state — a typed-but-uncommitted value with
/// the hint that Enter sends it, which is the whole interaction: nothing
/// reaches the drive until the operator commits.
Widget _freqField(String label, String value, {bool focused = false}) {
  return Builder(
    builder: (context) => TextFormField(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        suffixText: 'Hz',
        isDense: true,
        helperText: focused ? 'Enter to send' : null,
        enabledBorder: focused
            ? OutlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
              )
            : null,
      ),
    ),
  );
}

Widget _jogButton(BuildContext context, IconData icon, String label,
    {bool active = false}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      RawMaterialButton(
        shape: const CircleBorder(),
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
        onPressed: () {},
        child: Icon(
          icon,
          size: 36,
          color: active ? Colors.green : Theme.of(context).disabledColor,
        ),
      ),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

/// Conveyor: the busiest shape — commands, live numbers, a trend and
/// setpoints, all still inside one screen of pane.
SidePane _conveyorPane(BuildContext context) {
  return SidePane(
    title: 'CN-04',
    subtitle: 'Infeed conveyor',
    icon: Icons.conveyor_belt,
    status: const PaneStatus.running(),
    actions: [
      PaneAction.destructive(
        label: 'Fault reset',
        icon: Icons.restart_alt,
        onPressed: () {},
      ),
    ],
    child: PaneBody(
      // Deliberately written out of order: the golden is what proves
      // [PaneBody] sorts into Status → Trend → Manual → Setpoints rather
      // than rendering whatever a pane author happened to type first.
      sections: [
        PaneBodySection.manual(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _jogButton(context, Icons.arrow_back, 'Reverse'),
                  _jogButton(context, Icons.arrow_forward, 'Forward',
                      active: true),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Jog continuous',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  // Mirrors the real pane at stop-on-release: continuous off.
                  Switch(value: false, onChanged: (_) {}),
                ],
              ),
              const SizedBox(height: 10),
              _freqField('Manual frequency', '30.00'),
            ],
          ),
        ),
        PaneBodySection.status(
          trailing:
              TextButton(onPressed: () {}, child: const Text('Reset hours')),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: const [
              PaneTileRow(children: [
                PaneMetricTile(
                    label: 'Frequency',
                    value: '48.20',
                    unit: 'Hz',
                    icon: Icons.speed),
                PaneMetricTile(
                    label: 'Current',
                    value: '3.14',
                    unit: 'A',
                    icon: Icons.bolt),
                PaneMetricTile(
                    label: 'Run hours',
                    value: '412:35',
                    unit: 'h:m',
                    icon: Icons.schedule),
              ]),
              SizedBox(height: 8),
              PaneDetailRow(label: 'HMIS', value: 'Running'),
              PaneDetailRow(label: 'Last fault', value: 'None'),
            ],
          ),
        ),
        PaneBodySection.trend(
          child: PaneGraphTile(
            legend: conveyorTrendColors,
            height: 100,
            preview: const _TrendChart(compact: true),
            expandedBuilder: (_) => const _TrendChart(showButtons: true),
          ),
        ),
        PaneBodySection.setpoints(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _freqField('Auto', '50.00')),
              const SizedBox(width: 8),
              Expanded(child: _freqField('Cleaning', '27.50', focused: true)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Elevator / lift: read-only, dominated by one number.
SidePane _elevatorPane(BuildContext context) {
  return const SidePane(
    title: 'Elevator',
    subtitle: 'ST201.EL01.POS',
    icon: Icons.elevator,
    status: PaneStatus.running('Live'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneSection(
          title: 'Position',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              PaneTileRow(children: [
                PaneMetricTile(
                    label: 'Travel',
                    value: '64',
                    unit: '%',
                    icon: Icons.height),
                PaneMetricTile(
                    label: 'Tween',
                    value: '250',
                    unit: 'ms',
                    icon: Icons.timer_outlined),
              ]),
              SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(4)),
                child: LinearProgressIndicator(value: 0.64, minHeight: 8),
              ),
            ],
          ),
        ),
        Divider(height: 1),
        PaneSection(
          title: 'Details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              PaneDetailRow(label: 'Position key', value: 'ST201.EL01.POS'),
              PaneDetailRow(label: 'Current position', value: '64%'),
              PaneDetailRow(label: 'Tween duration', value: '250 ms'),
              PaneDetailRow(label: 'Out-of-range', value: 'no'),
              PaneDetailRow(label: 'Stale', value: 'no'),
              PaneDetailRow(label: 'Simulate motion', value: 'off'),
              PaneDetailRow(label: 'Children', value: '2 attached'),
            ],
          ),
        ),
      ],
    ),
  );
}

/// A 16-square channel read-out, the same shape the Advantys pane renders.
class _ChannelStripDemo extends StatelessWidget {
  const _ChannelStripDemo();

  @override
  Widget build(BuildContext context) {
    const high = [
      true,
      false,
      true,
      true,
      false,
      false,
      true,
      false,
      true,
      true,
      false,
      true,
      false,
      true,
      false,
      false,
    ];
    const forced = {2, 11};
    final theme = Theme.of(context);

    Widget cell(int i) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 22,
                  decoration: BoxDecoration(
                    color: (high[i] ? Colors.green : theme.disabledColor)
                        .withValues(alpha: high[i] ? 0.85 : 0.25),
                    borderRadius: BorderRadius.circular(4),
                    border: forced.contains(i)
                        ? Border.all(color: Colors.orange, width: 2)
                        : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text('${i + 1}', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        );

    return Column(
      children: [
        Row(children: [for (int i = 0; i < 8; i++) cell(i)]),
        const SizedBox(height: 6),
        Row(children: [for (int i = 8; i < 16; i++) cell(i)]),
      ],
    );
  }
}

/// A stand-in for the wide per-channel grid that opens in a floating dialog.
class _ChannelGridDemo extends StatelessWidget {
  const _ChannelGridDemo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget channel(int i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 44, child: Text('Ch${i + 1}')),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i.isEven ? Colors.green : theme.disabledColor,
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Auto')),
                  ButtonSegment(value: 1, label: Text('Low')),
                  ButtonSegment(value: 2, label: Text('High')),
                ],
                selected: {i == 2 ? 1 : 0},
                showSelectedIcon: false,
                onSelectionChanged: (_) {},
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: TextField(
                  decoration:
                      InputDecoration(labelText: 'Description', isDense: true),
                ),
              ),
            ],
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (int i = 0; i < 6; i++) channel(i)],
    );
  }
}

/// 3rd party equipment: a whole-module glance, detail behind a tile.
///
/// Only used as the backdrop for the floating-dialog golden — the module pane
/// itself is captured by the real-helper goldens above, which run production
/// code rather than this stand-in.
SidePane _thirdPartyPane(BuildContext context) {
  return const SidePane(
    title: 'DI-3725-A',
    subtitle: 'Advantys STB · 16 DI',
    icon: Icons.developer_board,
    status: PaneStatus.warning('2 forced'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneSection(
          title: 'Channels',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _ChannelStripDemo(),
              SizedBox(height: 10),
              PaneTileRow(children: [
                PaneMetricTile(
                    label: 'High', value: '8', unit: '/ 16', icon: Icons.input),
                PaneMetricTile(
                    label: 'Forced',
                    value: '2',
                    unit: '/ 16',
                    icon: Icons.pan_tool),
              ]),
            ],
          ),
        ),
        Divider(height: 1),
        PaneSection(
          title: 'Detail',
          child: PaneExpandTile(
            label: 'Channel detail',
            summary: 'Force, filters and descriptions for all 16',
            icon: Icons.grid_on,
            expandedBuilder: _channelGridBuilder,
          ),
        ),
      ],
    ),
  );
}

Widget _channelGridBuilder(BuildContext context) => const _ChannelGridDemo();

/// Elevator/lift, analog module, drive, sensor and gate bodies.
///
/// These mirror the real pane bodies field-for-field; the I/O panes below go
/// one better and run the production helper itself.

/// Beckhoff EL3054 — four analog inputs and their history.
SidePane _analogPane(BuildContext context) {
  return const SidePane(
    title: 'AI-3054',
    subtitle: 'Beckhoff · 4 AI',
    icon: Icons.linear_scale,
    status: PaneStatus.running('Live'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneSection(
          title: 'Inputs',
          child: PaneTileRow(children: [
            PaneMetricTile(
                label: 'Infeed', value: '4.21', icon: Icons.input, width: 164),
            PaneMetricTile(
                label: 'Brine', value: '11.87', icon: Icons.input, width: 164),
            PaneMetricTile(
                label: 'Chill', value: '-1.40', icon: Icons.input, width: 164),
            PaneMetricTile(
                label: 'I4', value: '—', icon: Icons.input, width: 164),
          ]),
        ),
        Divider(height: 1),
        PaneSection(
          title: 'Trend',
          child: PaneGraphTile(
            label: 'Infeed (mA)',
            height: 100,
            preview: _AnalogTrendChart(),
            expandedBuilder: _analogTrendBuilder,
          ),
        ),
      ],
    ),
  );
}

Widget _analogTrendBuilder(BuildContext context) => const _AnalogTrendChart();

/// A single-series analog trace, so the analog module's golden is not
/// labelled with the conveyor's frequency/current legend.
class _AnalogTrendChart extends StatelessWidget {
  const _AnalogTrendChart();

  static const List<double> _samples = [
    3.90,
    3.98,
    4.12,
    4.31,
    4.28,
    4.16,
    4.05,
    4.22,
    4.44,
    4.51,
    4.38,
    4.20,
    4.09,
    4.15,
    4.26,
    4.21,
  ];

  @override
  Widget build(BuildContext context) {
    final data = <Map<String, dynamic>>[
      for (var i = 0; i < _samples.length; i++)
        {
          'x': (_TrendChart._t0 + i * _TrendChart._step).toDouble(),
          'y': _samples[i],
          's': 'Infeed',
        },
    ];
    final range = stableTrendRange(
      _samples.reduce(math.min),
      _samples.reduce(math.max),
    );
    return Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: const GraphAxisConfig(unit: ''),
        yAxis: GraphAxisConfig(unit: '', min: range.min, max: range.max),
        xRange: DateTimeRange(
          start: DateTime.fromMillisecondsSinceEpoch(_TrendChart._t0),
          end: DateTime.fromMillisecondsSinceEpoch(
            _TrendChart._t0 + (_samples.length - 1) * _TrendChart._step,
          ),
        ),
        // One series, named by the tile header — see AnalogBoxTrendGraph.
        legend: false,
      ),
      data: data,
      showButtons: false,
      categoryColors: const {'Infeed': Colors.blue},
      chartTheme: Theme.of(context).brightness == Brightness.dark
          ? darkChartTheme(padding: kCompactChartPaddingSingleAxis)
          : lightChartTheme(padding: kCompactChartPaddingSingleAxis),
      redraw: () {},
    ).build(context);
  }
}

/// Schneider ATV320 — drive parameters with an unwritten edit pending.
SidePane _drivePane(BuildContext context) {
  Widget param(String name, String value) => PaneDetailRow(
        label: name,
        value: value,
      );
  return SidePane(
    title: 'ATV320',
    subtitle: 'ST201.CN04.DRV.cfg',
    icon: Icons.settings_input_component,
    status: const PaneStatus.warning('Unwritten changes'),
    actions: [
      PaneAction.primary(label: 'Write', icon: Icons.upload, onPressed: () {}),
    ],
    child: PaneSection(
      title: 'Parameters',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          param('ACC — acceleration', '3.0 s'),
          param('DEC — deceleration', '3.0 s'),
          param('LSP — low speed', '0.0 Hz'),
          param('HSP — high speed', '50.0 Hz'),
          param('ITH — motor thermal current', '4.20 A'),
          param('UFR — IR compensation', '100'),
        ],
      ),
    ),
  );
}

/// A sensor bound to an `FB_Sensor` — the REAL [SensorFbPane], not a
/// stand-in, fed a canned `ST_Sensor_HMI` snapshot instead of a PLC.
///
/// This is the surface under review: an operator watching a photo eye can read
/// how long it has been blocked and retune the debounce without a download.
/// [fault] swaps in the case the FB flags when it sees neither the NO nor the
/// NC contact — the state is unknowable, so the chip must not say "Clear".
Widget _sensorFbPane(BuildContext context, {bool fault = false}) {
  return SensorFbPane(
    config: SensorConfig(
      kind: SensorKind.opticField,
      detectionKey: 'sensors.CVS01_CN04_PX01.HMI',
      tag: 'CN04-S1',
    ),
    state: SensorFbState(
      output: !fault,
      rawNO: !fault,
      rawNC: false,
      fault: fault,
      hasNC: true,
      blockedFor: fault ? Duration.zero : const Duration(milliseconds: 4200),
      clearFor: fault ? const Duration(minutes: 5, seconds: 3) : Duration.zero,
      onDelay: const Duration(milliseconds: 50),
      offDelay: const Duration(milliseconds: 20),
    ),
    // Goldens never write; the pane is rendered, not driven.
    onWrite: (_, __) {},
    // The key has data gathering configured, so the pane carries the inline
    // blocked/clear trend — canned samples through the real chart, like the
    // conveyor's `_TrendChart` above.
    trendTile: PaneGraphTile(
      height: 84,
      preview: const _SensorTrendChart(compact: true),
      expandedTitle: 'CN04-S1 — trend',
      expandedBuilder: (_) => const _SensorTrendChart(),
    ),
  );
}

/// Canned blocked/clear samples through the REAL chart machinery — the
/// sensor-pane counterpart of [_TrendChart]. A photo eye blocking as batches
/// pass: mostly clear, blocked a beat at a time.
class _SensorTrendChart extends StatelessWidget {
  const _SensorTrendChart({this.compact = false});

  final bool compact;

  /// 2026-08-11 09:00:00Z, then a sample every 20 s.
  static const int _t0 = 1786532400000;
  static const int _step = 20000;

  static const List<int> _blocked = [
    0,
    0,
    1,
    1,
    0,
    0,
    0,
    1,
    0,
    0,
    1,
    1,
    1,
    0,
    0,
    1,
  ];

  @override
  Widget build(BuildContext context) {
    final data = <Map<String, dynamic>>[
      for (var i = 0; i < _blocked.length; i++)
        {
          'x': (_t0 + i * _step).toDouble(),
          'y': _blocked[i],
          's': kSensorTrendSeries,
        },
    ];
    // An explicit xRange, not xSpan — same reasoning as [_TrendChart]: the
    // live chart windows on DateTime.now(), which would slide the canned
    // samples out of view and churn this golden every run.
    return Graph(
      config: GraphConfig(
        type: GraphType.timeseries,
        xAxis: GraphAxisConfig(unit: compact ? '' : 'Time'),
        yAxis:
            const GraphAxisConfig(unit: '', boolean: true, min: -0.1, max: 1.1),
        xRange: DateTimeRange(
          start: DateTime.fromMillisecondsSinceEpoch(_t0),
          end: DateTime.fromMillisecondsSinceEpoch(
            _t0 + (_blocked.length - 1) * _step,
          ),
        ),
        // One series on a true/false axis — see SensorTrendGraph.
        legend: !compact,
      ),
      data: data,
      showButtons: false,
      categoryColors: sensorTrendColors,
      chartTheme: Theme.of(context).brightness == Brightness.dark
          ? darkChartTheme(
              padding: compact ? kSensorTrendCompactPadding : kChartPadding)
          : lightChartTheme(
              padding: compact ? kSensorTrendCompactPadding : kChartPadding),
      redraw: () {},
    ).build(context);
  }
}

/// The analog box operator pane — the REAL [AnalogBoxPane], fed canned
/// values instead of a PLC (the dialog→pane conversion under review).
///
/// [withRangeKeys] binds the sensor-range keys: bound, the pane carries the
/// "Sensor range" section (live values + an Adjust fold); unbound, the
/// section is absent entirely — the replacement for the old dialog's
/// "Advanced" switch, which showed even for cleared keys.
Widget _analogBoxPane(BuildContext context, {bool withRangeKeys = true}) {
  final config = AnalogBoxConfig(
    analogKey: 'sensors.PT2201',
    analogSensorRangeMinKey: withRangeKeys ? 'sensors.PT2201.rangeMin' : null,
    analogSensorRangeMaxKey: withRangeKeys ? 'sensors.PT2201.rangeMax' : null,
    setpoint1Key: 'sensors.PT2201.sp1',
    setpoint1HysteresisKey: 'sensors.PT2201.sp1Hyst',
    setpoint2Key: 'sensors.PT2201.sp2',
    minValue: 0,
    maxValue: 10,
    units: 'bar',
  )..text = 'PT-2201';
  return AnalogBoxPane(
    config: config,
    value: 4.21,
    setpoint1: 4.8,
    setpoint1Hysteresis: 0.2,
    setpoint2: 5.5,
    rangeMin: 0,
    rangeMax: 10,
    // Goldens never write; the pane is rendered, not driven.
    onWrite: (_, __) {},
    trendTile: PaneGraphTile(
      // The preview drops the chart's own legend to keep the width, so the
      // header names the trace — as AnalogBoxConfig.build does.
      label: 'PT-2201',
      height: 100,
      preview: const _AnalogTrendChart(),
      expandedTitle: 'PT-2201 — trend',
      expandedBuilder: (_) => const _AnalogTrendChart(),
    ),
  );
}

/// A sensor's read-only details — the fallback shape, shown when the key is a
/// plain BOOL node with no `FB_Sensor` behind it. Values only: the tag names
/// the pane, wiring (key strings, polarity, delay keys) stays out.
SidePane _sensorPane(BuildContext context) {
  return const SidePane(
    title: 'CN04-S1',
    subtitle: 'opticField · sensor',
    icon: Icons.sensors,
    status: PaneStatus.running('Detected'),
    child: PaneSection(
      title: 'Signal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PaneDetailRow(label: 'Detection state', value: 'true'),
        ],
      ),
    ),
  );
}

/// A conveyor gate's force controls.
SidePane _gatePane(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  Widget forceButton(String label, IconData icon, {bool active = false}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: Icon(icon, size: 18),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            foregroundColor: active ? scheme.tertiary : null,
            side: active ? BorderSide(color: scheme.tertiary, width: 2) : null,
          ),
          label: Text(label),
        ),
      ),
    );
  }

  return SidePane(
    title: 'Gate',
    subtitle: 'ST101.CN04.GATE01',
    icon: Icons.swap_horiz,
    status: const PaneStatus.warning('Forced open'),
    child: PaneSection(
      title: 'Force',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const PaneDetailRow(label: 'Gate state', value: 'Open'),
          const SizedBox(height: 10),
          Row(
            children: [
              forceButton('Force open', Icons.arrow_upward, active: true),
              forceButton('Force close', Icons.arrow_downward),
            ],
          ),
        ],
      ),
    ),
  );
}

/// A Number asset as it sits on a page — the value the floating chart
/// belongs to, left readable behind the window.
class _NumberReadout extends StatelessWidget {
  const _NumberReadout();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Infeed rate', style: theme.textTheme.labelMedium),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('4.21',
                  style: theme.textTheme.displaySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('mA', style: theme.textTheme.bodyMedium),
            ],
          ),
        ],
      ),
    );
  }
}

/// Canned channel states for the I/O module goldens.
const List<IOState> _sixteenChannelStates = [
  IOState.high,
  IOState.low,
  IOState.forcedHigh,
  IOState.high,
  IOState.low,
  IOState.low,
  IOState.high,
  IOState.low,
  IOState.high,
  IOState.high,
  IOState.low,
  IOState.forcedLow,
  IOState.low,
  IOState.high,
  IOState.low,
  IOState.low,
];

const List<IOState> _eightChannelStates = [
  IOState.high,
  IOState.low,
  IOState.high,
  IOState.high,
  IOState.low,
  IOState.forcedHigh,
  IOState.low,
  IOState.low,
];

/// Pumps a screen and opens the REAL `showIoModulePane` on canned data —
/// the same call Beckhoff EL1008/EL2008 and Advantys DDI/DDO make.
Future<void> _pumpIoPane(
  WidgetTester tester, {
  required ThemeData theme,
  required String title,
  required String subtitle,
  required List<IOState> states,
  String highLabel = 'High',
}) async {
  await tester.binding.setSurfaceSize(_screen);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(closeSidePane);

  late BuildContext pageContext;
  await tester.pumpWidget(_screenApp(
    theme: theme,
    body: Builder(builder: (context) {
      pageContext = context;
      return const _MockPlantView();
    }),
  ));
  showIoModulePane(
    context: pageContext,
    id: 'golden-io',
    title: title,
    subtitle: subtitle,
    highLabel: highLabel,
    // One emission, then quiet — enough for the strip to render.
    summaryStream: Stream<Map<String, DynamicValue>>.value(
      const <String, DynamicValue>{},
    ),
    statesOf: (_) => states,
    gridBuilder: (_) => const SizedBox.shrink(),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Goldens
// ---------------------------------------------------------------------------

void main() {
  final (light, dark) = solarized();

  // `flutter_test_config.dart` registers the font as 'Roboto' (Material's
  // default). The app themes ask for 'roboto-mono' by name, so register it
  // under that family too — otherwise these goldens render as Ahem blocks.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

    // Icons are load-bearing in these goldens (every header and tile carries
    // one), and the test environment does not register MaterialIcons. Pull it
    // out of the Flutter SDK cache; if the layout of the SDK ever changes,
    // fall back to boxes rather than failing the suite.
    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        (Platform.resolvedExecutable.contains('flutter')
            ? null
            : File(Platform.resolvedExecutable).parent.path);
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  group('SidePane goldens', () {
    testWidgets('conveyor — light', (tester) async {
      await _pumpWithPane(tester, theme: light, pane: _conveyorPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_conveyor_light.png'),
      );
    });

    testWidgets('conveyor — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _conveyorPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_conveyor_dark.png'),
      );
    });

    // The runtime page's pane-avoidance: the plant view is an aspect-fitted
    // canvas inside [SidePaneInset], so opening a pane re-fits the whole
    // page beside it — the tapped device stays in view — rather than the
    // pane covering the right-hand strip of the mimic.
    testWidgets('the plant view insets beside the pane — dark', (tester) async {
      await _pumpWithPane(tester,
          theme: dark, pane: _conveyorPane, inset: true);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_inset_plant_dark.png'),
      );
    });

    testWidgets('elevator — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _elevatorPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_elevator_dark.png'),
      );
    });

    testWidgets('dropdown menu opens above the pane — dark', (tester) async {
      // The pane hosts its own Navigator so a DropdownButton's menu route
      // lands on top of the pane instead of invisibly behind it (where a
      // second tap used to trip the framework's `_dropdownRoute == null`
      // assertion). The golden shows the menu sitting over the pane body.
      await _pumpWithPane(
        tester,
        theme: dark,
        pane: (_) => SidePane(
          title: 'Text',
          subtitle: 'Asset config',
          icon: Icons.tune,
          child: PaneSection(
            title: 'Layout',
            child: Row(
              children: [
                const Expanded(child: Text('Label position')),
                DropdownButton<String>(
                  value: 'Below',
                  items: const [
                    DropdownMenuItem(value: 'Above', child: Text('Above')),
                    DropdownMenuItem(value: 'Below', child: Text('Below')),
                    DropdownMenuItem(value: 'Left', child: Text('Left')),
                    DropdownMenuItem(value: 'Right', child: Text('Right')),
                  ],
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_dropdown_menu_dark.png'),
      );
    });

    // The next four run the REAL production code, not a stand-in:
    // `showIoModulePane` is what Beckhoff EL1008/EL2008 and Advantys
    // DDI3725/DDO3705 call, fed a canned emission instead of a PLC.
    testWidgets('I/O module — 16 inputs, two forced (real helper)',
        (tester) async {
      await _pumpIoPane(
        tester,
        theme: dark,
        title: 'DI-3725-A',
        subtitle: 'Advantys STB · 16 DI',
        states: _sixteenChannelStates,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_io_inputs_dark.png'),
      );
    });

    testWidgets('I/O module — 8 outputs (real helper)', (tester) async {
      await _pumpIoPane(
        tester,
        theme: dark,
        title: 'EL2008',
        subtitle: 'Beckhoff · 8 DO',
        highLabel: 'On',
        states: _eightChannelStates,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_io_outputs_dark.png'),
      );
    });

    testWidgets('analog module — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _analogPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_analog_dark.png'),
      );
    });

    testWidgets('drive parameters — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _drivePane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_drive_dark.png'),
      );
    });

    testWidgets('sensor — plain BOOL fallback — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _sensorPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_sensor_dark.png'),
      );
    });

    // The FB_Sensor binding, running the real `SensorFbPane`.
    testWidgets('sensor — FB_Sensor — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _sensorFbPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_sensor_fb_dark.png'),
      );
    });

    // The Adjust fold open: the editable debounce setpoints are reachable,
    // but only after a deliberate second tap — never on first paint.
    testWidgets('sensor — FB_Sensor debounce fold open — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _sensorFbPane);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_sensor_fb_adjust_dark.png'),
      );
    });

    testWidgets('sensor — FB_Sensor signal fault — dark', (tester) async {
      await _pumpWithPane(
        tester,
        theme: dark,
        pane: (context) => _sensorFbPane(context, fault: true),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_sensor_fb_fault_dark.png'),
      );
    });

    testWidgets('conveyor gate force — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _gatePane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_gate_dark.png'),
      );
    });

    // The analog box, running the real `AnalogBoxPane`: live value, trend,
    // inline setpoints and the sensor-range section with its Adjust fold.
    testWidgets('analog box — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _analogBoxPane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_analog_box_dark.png'),
      );
    });

    // The Adjust fold open: the range fields are reachable, but only after a
    // deliberate second tap — never on first paint.
    testWidgets('analog box — range fold open — dark', (tester) async {
      await _pumpWithPane(tester, theme: dark, pane: _analogBoxPane);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_analog_box_adjust_dark.png'),
      );
    });

    // No range keys bound → no Sensor range section, no Adjust fold — the
    // old dialog's "Advanced" toggle is gone with nothing in its place.
    testWidgets('analog box — no range keys — dark', (tester) async {
      await _pumpWithPane(
        tester,
        theme: dark,
        pane: (context) => _analogBoxPane(context, withRangeKeys: false),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/side_pane_analog_box_no_range_dark.png'),
      );
    });
  });

  group('Chart popup golden', () {
    // What the trend tile opens: the same chart full size with pan/zoom, in a
    // window the operator can drag off the pane and leave running.
    testWidgets('conveyor trend — floating chart over the pane',
        (tester) async {
      await _pumpWithPane(
        tester,
        theme: dark,
        pane: _conveyorPane,
        afterOpen: (context) => showFloatingDialog(
          context: context,
          id: 'golden-trend',
          title: 'CN-04 — trend',
          subtitle: 'Last 30 minutes',
          icon: Icons.show_chart,
          size: const Size(820, 460),
          position: const Offset(120, 200),
          scrollable: false,
          builder: (_) => const _TrendChart(showButtons: true),
        ),
      );
      addTearDown(() => closeFloatingDialog('golden-trend'));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_trend_popup_dark.png'),
      );
    });
  });

  group('Number asset golden', () {
    // A Number asset with a graph configured: tapping the value opens its
    // trend as a FLOATING dialog, so the live number stays readable behind
    // it and the window can be dragged aside. No side pane involved — the
    // asset is a single value, not a device with controls.
    testWidgets('number trend — floating chart over the live value',
        (tester) async {
      await tester.binding.setSurfaceSize(_screen);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late BuildContext pageContext;
      await tester.pumpWidget(_screenApp(
        theme: dark,
        body: Builder(builder: (context) {
          pageContext = context;
          return Stack(children: const [
            _MockPlantView(),
            Positioned(left: 520, top: 120, child: _NumberReadout()),
          ]);
        }),
      ));
      showFloatingDialog(
        context: pageContext,
        id: 'golden-number',
        title: 'Infeed rate',
        subtitle: 'Last 15 minutes',
        icon: Icons.show_chart,
        size: const Size(760, 420),
        position: const Offset(430, 300),
        scrollable: false,
        builder: (_) => const _AnalogTrendChart(),
      );
      await tester.pumpAndSettle();
      addTearDown(() => closeFloatingDialog('golden-number'));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/number_trend_popup_dark.png'),
      );
    });
  });

  group('StandardDialog goldens', () {
    testWidgets('floating dialog opened from a pane tile — dark',
        (tester) async {
      // The pairing the standard is built around: pane on the right, the
      // detail it could not hold floating over the plant view, nothing
      // blocked or dimmed.
      await _pumpWithPane(
        tester,
        theme: dark,
        pane: _thirdPartyPane,
        afterOpen: (context) => showFloatingDialog(
          context: context,
          id: 'golden-dialog',
          title: 'DI-3725-A — channels',
          subtitle: 'Force, filters and descriptions',
          icon: Icons.grid_on,
          status: const PaneStatus.warning('2 forced'),
          size: const Size(720, 420),
          position: const Offset(60, 140),
          builder: _channelGridBuilder,
        ),
      );
      addTearDown(() => closeFloatingDialog('golden-dialog'));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/floating_dialog_dark.png'),
      );
    });

    testWidgets('modal dialog — dark', (tester) async {
      await tester.binding.setSurfaceSize(_screen);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late BuildContext pageContext;
      await tester.pumpWidget(_screenApp(
        theme: dark,
        body: Builder(builder: (context) {
          pageContext = context;
          return const _MockPlantView();
        }),
      ));
      showStandardDialog<bool>(
        context: pageContext,
        title: 'Reset run hours',
        subtitle: 'CN-04 · Infeed conveyor',
        icon: Icons.timer_off_outlined,
        builder: (_) => const Text(
          'Run hours for this drive will be set to zero. '
          'The counter cannot be restored afterwards.',
        ),
        actionsBuilder: (ctx) => [
          PaneAction.destructive(
            label: 'Reset',
            icon: Icons.restart_alt,
            onPressed: () {},
          ),
        ],
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/standard_dialog_modal_dark.png'),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    });
  });
}
