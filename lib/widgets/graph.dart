import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:cristalyse/cristalyse.dart' as cs;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../theme.dart';
import '../providers/theme.dart';
import 'button_graph.dart';

part 'graph.g.dart';

/// -------------------- Data models --------------------

@JsonEnum()
enum GraphType {
  line,
  bar,
  scatter,
  pie,
  // real-time / time on X
  timeseries,
  barTimeseries,
}

@JsonSerializable(explicitToJson: true)
class GraphAxisConfig {
  final String? title;
  final String unit;
  final double? min;
  final double? max;
  final bool boolean;
  @JsonKey(defaultValue: false)
  final bool integersOnly;

  /// Decimal places for the tick LABELS, independent of where the ticks fall.
  ///
  /// Distinct from [integersOnly], which asks the tick engine for whole-numbered
  /// gridlines and is free to answer with fewer of them: our y ticks are evenly
  /// spaced across the data range (`simpleLinear`), so on a short plot the range
  /// is divided into as few as two, and rounding THOSE to integers can leave a
  /// step wider than the range itself — the top label then disappears entirely
  /// rather than being rounded. This rounds the printed text and moves nothing.
  ///
  /// Null keeps the default: whole values print bare, fractional ones to one
  /// place.
  ///
  /// Rounding can collide: an axis spanning less than one unit at `decimals: 0`
  /// prints the same text at top and bottom. Worth accepting where the quantity
  /// genuinely has no fractional meaning — that span only happens when the
  /// thing being counted has all but stopped.
  final int? decimals;

  const GraphAxisConfig({
    this.title,
    required this.unit,
    this.min,
    this.max,
    this.boolean = false,
    this.integersOnly = false,
    this.decimals,
  });

  factory GraphAxisConfig.fromJson(Map<String, dynamic> json) =>
      _$GraphAxisConfigFromJson(json);
  Map<String, dynamic> toJson() => _$GraphAxisConfigToJson(this);
}

@JsonSerializable(explicitToJson: true)
class GraphConfig {
  final GraphType type;
  final GraphAxisConfig xAxis;
  final GraphAxisConfig yAxis;
  final GraphAxisConfig? yAxis2;

  /// For timeseries: window width to show (e.g. last 10s/5m/1h)
  final Duration? xSpan;

  /// For timeseries: explicit viewport
  @JsonKey(includeFromJson: false, includeToJson: false)
  final DateTimeRange? xRange;

  @JsonKey(defaultValue: true)
  final bool pan;
  @JsonKey(defaultValue: true)
  final bool zoom;

  @JsonKey(defaultValue: false)
  final bool tooltip;

  /// Draw cristalyse's own legend down the right-hand side of the plot.
  ///
  /// Off for pane previews: at tile size that legend column costs more width
  /// than the plot it explains — a 100px trend tile ends up half chart, half
  /// series names. `PaneGraphTile` names the series in its header instead.
  @JsonKey(defaultValue: true)
  final bool legend;

  // Stroke or bar width or point size
  @JsonKey(defaultValue: 2)
  final double width;

  /// Fallback palette for series without explicit color
  static const List<Color> colors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.purple,
    Colors.orange,
    Colors.pink,
    Colors.brown,
    Colors.grey,
    Colors.teal,
    Colors.lime,
    Colors.indigo,
    Colors.cyan,
    Colors.amber,
    Colors.deepPurple,
    Colors.deepOrange,
    Colors.yellow,
  ];

  const GraphConfig({
    required this.type,
    required this.xAxis,
    required this.yAxis,
    this.yAxis2,
    this.xSpan,
    this.xRange,
    this.pan = true,
    this.width = 2,
    this.zoom = true,
    this.tooltip = false,
    this.legend = true,
  });

  factory GraphConfig.fromJson(Map<String, dynamic> json) =>
      _$GraphConfigFromJson(json);
  Map<String, dynamic> toJson() => _$GraphConfigToJson(this);
}

/// -------------------- Pan event surface --------------------

class GraphPanEvent {
  /// Current visible X range (data coordinates)
  final double? visibleMinX;
  final double? visibleMaxX;

  /// Current visible Y range (data coordinates)
  final double? visibleMinY;
  final double? visibleMaxY;

  /// Pan delta from last position (screen coordinates)
  final Offset? delta;

  /// Total pan distance from start (screen coordinates)
  final Offset? totalDelta;

  GraphPanEvent(cs.PanInfo info)
      : visibleMinX = info.visibleMinX,
        visibleMaxX = info.visibleMaxX,
        visibleMinY = info.visibleMinY,
        visibleMaxY = info.visibleMaxY,
        delta = info.delta,
        totalDelta = info.totalDelta;
}

/// What a chart shows before it has anything to plot: the plot area's
/// gridlines, faintly.
///
/// It used to be a spinner in the middle of the window. A spinner says
/// "nothing here yet" and nothing else, and when the data arrives the whole
/// area changes at once. Gridlines say "a chart goes here", and the arrival
/// fills in a frame the eye has already taken in. No axis text: a label here
/// would be a guess at a domain the data has not given yet.
class _GraphSkeleton extends StatelessWidget {
  const _GraphSkeleton();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _GridSkeletonPainter(
        Theme.of(context).colorScheme.outlineVariant.withAlpha(110),
      ),
    );
  }
}

class _GridSkeletonPainter extends CustomPainter {
  _GridSkeletonPainter(this.color);

  final Color color;

  static const _lines = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 1; i <= _lines; i++) {
      final y = (size.height * i / (_lines + 1)).roundToDouble() + 0.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridSkeletonPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// -------------------- Graph  --------------------

class Graph {
  final GraphConfig config;

  /// CristalyseChart().data([
  ///   {'x': 1, 'y': 2, 'y2': 85, 'category': 'A'},
  ///   {'x': 2, 'y': 3, 'y2': 92, 'category': 'B'},
  /// ])
  final List<Map<String, dynamic>> data;
  final bool showButtons;
  final Map<String, Color> categoryColors;

  /// Panning callbacks
  final void Function(GraphPanEvent event)? onPanStart;
  final void Function(GraphPanEvent event)? onPanUpdate;
  final void Function(GraphPanEvent event)? onPanEnd;
  final void Function()? onNowPressed; // When the user clicks the now button
  final void Function()? onSetDatePressed;
  final void Function() redraw;
  final cs.TooltipBuilder? tooltipBuilder;

  Graph(
      {required this.config,
      required this.data,
      this.onPanStart,
      this.onPanUpdate,
      this.onPanEnd,
      this.onNowPressed,
      this.onSetDatePressed,
      this.showButtons = true,
      required this.redraw,
      cs.ChartTheme? chartTheme,
      this.tooltipBuilder,
      this.categoryColors = const {}})
      : _data = data,
        _chartWidget = const _GraphSkeleton() {
    _chart = _createChart();
    if (chartTheme != null) {
      _chart.theme(chartTheme);
    }
    if ((config.type == GraphType.timeseries ||
            config.type == GraphType.barTimeseries) &&
        config.xSpan != null) {
      _lastPanInfo = cs.PanInfo(
          visibleMinX: DateTime.now()
              .subtract(config.xSpan!)
              .millisecondsSinceEpoch
              .toDouble(),
          visibleMaxX: DateTime.now().millisecondsSinceEpoch.toDouble(),
          state: cs.PanState.start);
    } else if (config.xAxis.min != null && config.xAxis.max != null) {
      _lastPanInfo = cs.PanInfo(
          visibleMinX: config.xAxis.min!,
          visibleMaxX: config.xAxis.max!,
          state: cs.PanState.start);
    } else {
      _lastPanInfo =
          cs.PanInfo(visibleMinX: 0, visibleMaxX: 0, state: cs.PanState.start);
    }
    if (_data.isNotEmpty) {
      _chart.data(_data);
      if (categoryColors.isNotEmpty) {
        _chart.customPalette(categoryColors: categoryColors);
      }
      _chartWidget = _chart.build();
      _isLoading = false;
    }
  }

  late final List<Map<String, dynamic>> _data;
  late cs.CristalyseChart _chart;
  Widget _chartWidget;

  /// Replace the loading skeleton with a message. A fetch that throws -- a key whose
  /// table was never created because it is not collected, a database that
  /// is down -- used to leave the chart on its spinner for good, because
  /// nothing ever called [addData]. The operator reads "still loading" and
  /// waits; the truth is "there is nothing to load, and here is why".
  void showError(String message) {
    _isLoading = false;
    _errored = true;
    _chartWidget = Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off,
                    color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
    redraw();
  }

  bool _showDate = false; // if viewport is not today, show date
  late cs.PanInfo _lastPanInfo;
  bool _isLoading = true;

  /// Set by [showError]; the "No data from ... to ..." footer stays off then,
  /// since the message in the chart area already says why there is none.
  bool _errored = false;
  final cs.PanController _panController = cs.PanController();
  bool _nowDisabled = false;

  void theme(cs.ChartTheme theme) {
    _chart.theme(theme);
  }

  void panForward(double maxX) {
    if (_lastPanInfo.visibleMaxX == null || _lastPanInfo.visibleMinX == null) {
      return;
    }
    final currentWindowSize =
        _lastPanInfo.visibleMaxX! - _lastPanInfo.visibleMinX!;
    // check if visibleMaxX is already bigger than maxX
    if (_lastPanInfo.visibleMaxX! > maxX) {
      return;
    }
    // Check if we are half a percent from the new maxX if we are, we really dont need to pan
    if ((maxX - _lastPanInfo.visibleMaxX!) / currentWindowSize <= 0.005) {
      return;
    }
    final newMinX = maxX - currentWindowSize;
    _panController.panTo(cs.PanInfo(
      visibleMinX: newMinX,
      visibleMaxX: maxX,
      state: cs.PanState
          .start, // start is the most innocent state, we dont want this to cause any heavy actions
    ));
  }

  void setNowButtonDisabled(bool disabled) {
    _nowDisabled = disabled;
    redraw();
  }

  void _setXAxis(cs.CristalyseChart chart) {
    cs.LabelCallback? xLabels;
    if (config.type == GraphType.timeseries ||
        config.type == GraphType.barTimeseries) {
      xLabels = (v) {
        final date = DateTime.fromMillisecondsSinceEpoch(v.toInt());
        return _formatTime(date, showDate: _showDate);
      };
    }
    if (config.type == GraphType.timeseries) {
      if (config.xRange != null) {
        chart.scaleXContinuous(
            min: config.xRange?.start.millisecondsSinceEpoch.toDouble(),
            max: config.xRange?.end.millisecondsSinceEpoch.toDouble(),
            labels: xLabels,
            tickConfig: cs.TickConfig(simpleLinear: true),
            title: config.xAxis.title);
      } else if (config.xSpan != null) {
        chart.scaleXContinuous(
            min: DateTime.now()
                .subtract(config.xSpan!)
                .millisecondsSinceEpoch
                .toDouble(),
            max: DateTime.now().millisecondsSinceEpoch.toDouble(),
            labels: xLabels,
            tickConfig: cs.TickConfig(simpleLinear: true),
            title: config.xAxis.title);
      } else {
        chart.scaleXContinuous(
            min: config.xAxis.min,
            max: config.xAxis.max,
            labels: xLabels,
            tickConfig: cs.TickConfig(simpleLinear: true),
            title: config.xAxis.title);
      }
    } else if (config.type == GraphType.barTimeseries) {
      chart.scaleXOrdinal(labels: xLabels, title: config.xAxis.title);
    }
  }

  cs.CristalyseChart _createChart() {
    cs.PanConfig? panConfig;
    if (config.pan) {
      panConfig = cs.PanConfig(
          enabled: true,
          updateXDomain: true,
          updateYDomain: false,
          throttle: const Duration(milliseconds: 1000),
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanStart: _onPanStart,
          controller: _panController,
          // It is hard to detect if there is gap in data, so if we got data from 14:00 - 15:00 and nothing betwen 15:00 and 17:00 and then real time after that, lets just keep this off
          boundaryClampingX: false);
    }

    final chart = cs.CristalyseChart()
        .mapping(x: 'x', y: 'y', color: 's')
        .scaleYContinuous(
          min: config.yAxis.min,
          max: config.yAxis.max,
          labels: (v) => _numLabel(v, config.yAxis.unit, config.yAxis.boolean,
              config.yAxis.decimals),
          tickConfig: cs.TickConfig(
              simpleLinear: true,
              integersOnly: config.yAxis.integersOnly,
              ticks: config.yAxis.boolean ? [0.0, 1.0] : null),
          title: config.yAxis.title,
        )
        .interaction(
          pan: panConfig,
          tooltip: config.tooltip
              ? cs.TooltipConfig(
                  builder: tooltipBuilder ?? cs.DefaultTooltips.simple('y'),
                  showDelay: const Duration(milliseconds: 50),
                  hideDelay: const Duration(milliseconds: 500),
                  followPointer: false,
                )
              : null,
        )
        .animate(duration: Duration.zero);

    if (config.legend) {
      chart.legend(
          position: cs.LegendPosition.right,
          interactive: true,
          showTitles: true);
    }

    for (final yaxis in [
      cs.YAxis.primary,
      if (config.yAxis2 != null) cs.YAxis.secondary
    ]) {
      switch (config.type) {
        case GraphType.line:
        case GraphType.timeseries:
          chart.geomLine(strokeWidth: config.width, yAxis: yaxis, alpha: 1.0);
          break;
        case GraphType.bar:
        case GraphType.barTimeseries:
          chart.geomBar(
              width: config.width,
              yAxis: yaxis,
              alpha: 1.0,
              style: cs.BarStyle.grouped);
          break;
        case GraphType.scatter:
          chart.geomPoint(size: config.width, yAxis: yaxis, alpha: 1.0);
          break;
        case GraphType.pie:
          chart.geomPie(strokeWidth: config.width);
          break;
      }
    }

    _setXAxis(chart);

    if (config.yAxis2 != null) {
      chart.mappingY2('y2').scaleY2Continuous(
            min: config.yAxis2?.min,
            max: config.yAxis2?.max,
            labels: (v) => _numLabel(
                v,
                config.yAxis2?.unit ?? '',
                config.yAxis2?.boolean ?? false,
                config.yAxis2?.decimals),
            tickConfig: cs.TickConfig(
                simpleLinear: true,
                integersOnly: config.yAxis2?.integersOnly ?? false,
                ticks: config.yAxis2?.boolean ?? false ? [0.0, 1.0] : null),
            title: config.yAxis2?.title,
          );
    }
    return chart;
  }

  void addAll(List<Map<String, dynamic>> input) {
    _data.addAll(input);
    _sliceAndRedraw(_lastPanInfo);
  }

  void removeWhere(bool Function(Map<String, dynamic>) predicate) {
    _data.removeWhere(predicate);
    _sliceAndRedraw(_lastPanInfo);
  }

  Widget build(BuildContext context) {
    DateTimeRange? currentDateRange;
    if (_lastPanInfo.visibleMinX != null && _lastPanInfo.visibleMaxX != null) {
      currentDateRange = DateTimeRange(
        start: DateTime.fromMillisecondsSinceEpoch(
            _lastPanInfo.visibleMinX!.toInt()),
        end: DateTime.fromMillisecondsSinceEpoch(
            _lastPanInfo.visibleMaxX!.toInt()),
      );
    } else if (config.xSpan != null) {
      currentDateRange = DateTimeRange(
        start: DateTime.now().subtract(config.xSpan!),
        end: DateTime.now(),
      );
    }

    Widget? noData;
    if (_data.isEmpty && !_isLoading && !_errored) {
      var txt =
          "No data from: ${_lastPanInfo.visibleMinX} to: ${_lastPanInfo.visibleMaxX}";
      if (config.type == GraphType.timeseries ||
          config.type == GraphType.barTimeseries) {
        txt =
            "No data from: ${DateTime.fromMillisecondsSinceEpoch(_lastPanInfo.visibleMinX!.toInt())} to: ${DateTime.fromMillisecondsSinceEpoch(_lastPanInfo.visibleMaxX!.toInt())}";
      }
      noData = Center(
        child: Text(txt),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _chartWidget),
              // Still fetching: a hairline across the top of the plot rather
              // than a spinner in the middle of it. The plot area, the legend
              // and the button row are already where they will stay, so the
              // data arriving fills the frame in instead of replacing it.
              if (_isLoading && !_errored)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
        if (noData != null) noData,
        if (noData != null)
          SizedBox(
            height: 10,
          ),
        // Drawn while loading too. Held back until the first data, the row
        // popped in underneath the plot and shoved it up by its own height,
        // the moment the operator had started reading it.
        if (showButtons)
          ButtonGraph(
              dateRange: currentDateRange,
              nowDisabled: _nowDisabled,
              onSetDatePressed: () {
                onSetDatePressed?.call();
              },
              onSetDateResult: (dateRange) {
                _panController.panTo(cs.PanInfo(
                  visibleMinX:
                      dateRange?.start.millisecondsSinceEpoch.toDouble(),
                  visibleMaxX: dateRange?.end.millisecondsSinceEpoch.toDouble(),
                  state: cs.PanState.end,
                ));
              },
              onNow: () {
                double window = 0;
                if (config.xSpan != null) {
                  window = config.xSpan!.inMilliseconds.toDouble();
                }
                if (_lastPanInfo.visibleMinX != null &&
                    _lastPanInfo.visibleMaxX != null) {
                  window =
                      _lastPanInfo.visibleMaxX! - _lastPanInfo.visibleMinX!;
                }
                if (config.type == GraphType.timeseries ||
                    config.type == GraphType.barTimeseries && window > 0) {
                  _panController.panTo(cs.PanInfo(
                    visibleMinX:
                        DateTime.now().millisecondsSinceEpoch.toDouble() -
                            window,
                    visibleMaxX:
                        DateTime.now().millisecondsSinceEpoch.toDouble(),
                    state: cs.PanState.end,
                  ));
                }
                onNowPressed?.call();
              },
              onZoomOut: () {
                if (config.type == GraphType.timeseries ||
                    config.type == GraphType.barTimeseries &&
                        config.xSpan != null) {
                  final visibleMinX = _lastPanInfo.visibleMinX;
                  final visibleMaxX = _lastPanInfo.visibleMaxX;
                  if (visibleMinX != null && visibleMaxX != null) {
                    final windowSize = visibleMaxX - visibleMinX;
                    final delta = windowSize * -1 / 10;
                    // lets just zoom to right side
                    final newVisibleMinX = visibleMinX + delta;
                    final newVisibleMaxX = visibleMaxX;

                    _panController.panTo(cs.PanInfo(
                      visibleMinX: newVisibleMinX,
                      visibleMaxX: newVisibleMaxX,
                      state: cs.PanState.end,
                    ));
                  } else {
                    // dont know
                  }
                }
              },
              onZoomIn: () {
                if (config.type == GraphType.timeseries ||
                    config.type == GraphType.barTimeseries &&
                        config.xSpan != null) {
                  final visibleMinX = _lastPanInfo.visibleMinX;
                  final visibleMaxX = _lastPanInfo.visibleMaxX;
                  if (visibleMinX != null && visibleMaxX != null) {
                    final windowSize = visibleMaxX - visibleMinX;
                    final delta = windowSize * 1 / 10;
                    // lets just zoom out from the left side
                    final newVisibleMinX = visibleMinX + delta;
                    final newVisibleMaxX = visibleMaxX;

                    _panController.panTo(cs.PanInfo(
                      visibleMinX: newVisibleMinX,
                      visibleMaxX: newVisibleMaxX,
                      state: cs.PanState.end,
                    ));
                  } else {
                    // dont know
                  }
                }
              }),
      ],
    );
  }

  void _onPanStart(cs.PanInfo info) {
    _lastPanInfo = info;
    onPanStart?.call(GraphPanEvent(info));
  }

  void _onPanUpdate(cs.PanInfo info) {
    _lastPanInfo = info;
    _sliceAndRedraw(info);
    onPanUpdate?.call(GraphPanEvent(info));
  }

  void _onPanEnd(cs.PanInfo info) {
    _lastPanInfo = info;
    if (config.type == GraphType.timeseries ||
        config.type == GraphType.barTimeseries) {
      final now = DateTime.now();
      if (info.visibleMinX != null && info.visibleMaxX != null) {
        _showDate = now.day !=
                DateTime.fromMillisecondsSinceEpoch(info.visibleMinX!.toInt())
                    .day ||
            now.day !=
                DateTime.fromMillisecondsSinceEpoch(info.visibleMaxX!.toInt())
                    .day;
      }
    }
    _sliceAndRedraw(info);

    onPanEnd?.call(GraphPanEvent(info));
  }

  void _sliceAndRedraw(cs.PanInfo info) {
    if (info.visibleMinX == null || info.visibleMaxX == null) return;
    final visibleMinX = info.visibleMinX!;
    final visibleMaxX = info.visibleMaxX!;
    final windowSize = info.visibleMaxX! - info.visibleMinX!;

    final slicedData = _data
        .where((e) =>
            e['x'] >= visibleMinX - windowSize &&
            e['x'] <= visibleMaxX + windowSize)
        .toList();

    _chart.data(slicedData);
    if (categoryColors.isNotEmpty) {
      _chart.customPalette(categoryColors: categoryColors);
    }
    _isLoading = false;
    _chartWidget = _chart.build();

    redraw();
  }

  static String _numLabel(num v, String unit, bool boolean, [int? decimals]) {
    if (boolean) {
      return v == 0.0
          ? 'False'
          : v == 1.0
              ? 'True'
              : '';
    }
    final text = decimals != null
        ? v.toStringAsFixed(decimals)
        : (v == v.roundToDouble())
            ? v.toInt().toString()
            : v.toStringAsFixed(1);
    return unit.isEmpty ? text : '$text $unit';
  }

  static String _formatTime(DateTime dt, {required bool showDate}) {
    return _fmt(dt, showDate ? 'MM/dd HH:mm:ss' : 'HH:mm:ss');
  }

  static String _fmt(DateTime dt, String pattern) {
    return DateFormat(pattern).format(dt);
  }
}

/// -------------------- Chart theme (Riverpod) --------------------

@riverpod
class ChartThemeNotifier extends _$ChartThemeNotifier {
  @override
  cs.ChartTheme build() {
    // Watch the theme mode
    final themeMode = ref.watch(themeNotifierProvider);

    return themeMode.when(
      data: (mode) => _createChartTheme(mode),
      loading: () => _createChartTheme(ThemeMode.system),
      error: (_, __) => _createChartTheme(ThemeMode.system),
    );
  }

  cs.ChartTheme _createChartTheme(ThemeMode mode) {
    final isDark = mode == ThemeMode.dark;
    return isDark ? darkChartTheme() : lightChartTheme();
  }
}

/// Gutter reserved for axis labels around the plot.
///
/// The historic value was `left: 20` and nothing anywhere else, which is why
/// tick labels used to wrap ("5"/"0" stacked) and print over the caption and
/// the x-axis row in a small chart. A tick reads "48.20 Hz", so the left
/// gutter has to fit that; the right axis and the time row need their own.
const EdgeInsets kChartPadding =
    EdgeInsets.only(left: 20, right: 0, top: 0, bottom: 0);

/// Padding for a chart drawn small — a pane preview. Units are dropped from
/// the ticks there, so the gutters only have to fit bare numbers, but they do
/// have to exist or the labels land on top of the surrounding text.
const EdgeInsets kCompactChartPadding =
    EdgeInsets.only(left: 34, right: 38, top: 6, bottom: 20);

/// Compact gutters for a preview with only a left-hand y-axis.
///
/// [kCompactChartPadding] reserves a right gutter wide enough for a second
/// axis' tick labels; a single-axis trend only has to keep the last time
/// label on the x-axis from running off the tile, which is half a label's
/// width.
const EdgeInsets kCompactChartPaddingSingleAxis =
    EdgeInsets.only(left: 34, right: 30, top: 6, bottom: 20);

/// [theme] with different gutters — the one thing a compact preview has to
/// change about whatever chart theme the app resolved.
///
/// cristalyse's `ChartTheme` has no `copyWith`, and re-deriving light/dark
/// from the widget tree would drift from the theme the rest of the chart is
/// already drawn with.
cs.ChartTheme chartThemeWithPadding(cs.ChartTheme theme, EdgeInsets padding) {
  return cs.ChartTheme(
    backgroundColor: theme.backgroundColor,
    plotBackgroundColor: theme.plotBackgroundColor,
    primaryColor: theme.primaryColor,
    borderColor: theme.borderColor,
    gridColor: theme.gridColor,
    axisColor: theme.axisColor,
    gridWidth: theme.gridWidth,
    axisWidth: theme.axisWidth,
    pointSizeDefault: theme.pointSizeDefault,
    pointSizeMin: theme.pointSizeMin,
    pointSizeMax: theme.pointSizeMax,
    colorPalette: theme.colorPalette,
    padding: padding,
    axisTextStyle: theme.axisTextStyle,
    axisLabelStyle: theme.axisLabelStyle,
    categoryGradients: theme.categoryGradients,
  );
}

/// A stable y-axis range for a live trend.
///
/// Two separate things make a naively auto-scaled trend jump. The range gets
/// taken from every sample the collector holds — two hours — while the plot
/// only shows the last few minutes, so the visible trace is squashed flat and
/// then leaps when an old extreme finally ages out of the buffer. And the
/// exact min/max moves with every arriving sample, so even inside one window
/// the line breathes: the same signal is drawn small, then big, then small.
///
/// Feeding this the extremes of the *visible* samples fixes the first. The
/// second is fixed by snapping the padded range outward onto a 1/2/5 x 10^n
/// step, so the axis only moves when the signal genuinely leaves the notch it
/// was sitting in, and holds still while it wanders inside one.
///
/// [floor] clamps the bottom of the range — pass 0 for a quantity like
/// current where zero is the meaningful floor.
({double min, double max}) stableTrendRange(
  double min,
  double max, {
  double? floor,
}) {
  if (!min.isFinite || !max.isFinite || max < min) return (min: 0, max: 1);

  // A dead-flat signal has no span to scale to. Open a window around it that
  // grows with the reading's own magnitude, so a flat 4.2 bar and a flat
  // 4200 rpm both draw down the middle instead of on the frame.
  if (max == min) {
    final half = math.max(min.abs() * 0.05, 0.5);
    min -= half;
    max += half;
  } else {
    // Headroom above and below: scaling to the exact extremes pins the trace
    // to the plot frame, where it runs into the tick labels.
    final margin = (max - min) * 0.1;
    min -= margin;
    max += margin;
  }

  final step = _niceStep((max - min) / 4);
  var lo = (min / step).floorToDouble() * step;
  var hi = (max / step).ceilToDouble() * step;
  if (floor != null && lo < floor) lo = floor;
  if (hi <= lo) hi = lo + step;
  return (min: lo, max: hi);
}

/// The 1/2/5 x 10^n step nearest below [raw] — the tick spacings that read as
/// round numbers on an axis.
double _niceStep(double raw) {
  if (raw <= 0 || !raw.isFinite) return 1;
  final magnitude =
      math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final normalized = raw / magnitude;
  final double nice;
  if (normalized <= 1) {
    nice = 1;
  } else if (normalized <= 2) {
    nice = 2;
  } else if (normalized <= 5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * magnitude;
}

/// The solarized-dark chart theme.
///
/// Top-level rather than a private notifier method so anything rendering a
/// chart outside the provider graph — golden tests especially — draws the
/// chart an operator actually sees instead of cristalyse's white default.
cs.ChartTheme darkChartTheme({EdgeInsets padding = kChartPadding}) {
  return cs.ChartTheme(
    backgroundColor: Colors.transparent,
    plotBackgroundColor: Colors.transparent,
    primaryColor: SolarizedColors.blue,
    borderColor: Colors.transparent,
    gridColor: SolarizedColors.base01.withAlpha(75),
    axisColor: SolarizedColors.base01,
    gridWidth: 0.5,
    axisWidth: 1.0,
    pointSizeDefault: 0,
    pointSizeMin: 0,
    pointSizeMax: 0,
    colorPalette: [
      SolarizedColors.blue,
      SolarizedColors.red,
      SolarizedColors.green,
      SolarizedColors.yellow,
      SolarizedColors.orange,
      SolarizedColors.magenta,
      SolarizedColors.violet,
      SolarizedColors.cyan,
    ],
    padding: padding,
    axisTextStyle: const TextStyle(
      color: SolarizedColors.base01,
      fontSize: 12,
      fontFamily: 'roboto-mono',
    ),
    axisLabelStyle: const TextStyle(
      color: SolarizedColors.base00,
      fontSize: 12,
      fontFamily: 'roboto-mono',
    ),
  );
}

/// The solarized-light counterpart of [darkChartTheme].
cs.ChartTheme lightChartTheme({EdgeInsets padding = kChartPadding}) {
  return cs.ChartTheme(
    backgroundColor: Colors.transparent,
    plotBackgroundColor: Colors.transparent,
    primaryColor: SolarizedColors.green,
    borderColor: Colors.transparent,
    gridColor: SolarizedColors.base00.withAlpha(75),
    axisColor: SolarizedColors.base00,
    gridWidth: 0.5,
    axisWidth: 1.0,
    pointSizeDefault: 0,
    pointSizeMin: 0,
    pointSizeMax: 0,
    colorPalette: [
      SolarizedColors.green,
      SolarizedColors.red,
      SolarizedColors.blue,
      SolarizedColors.orange,
      SolarizedColors.magenta,
      SolarizedColors.violet,
      SolarizedColors.cyan,
      SolarizedColors.yellow,
    ],
    // (Padding could be computed from label sizes if needed)
    padding: padding,
    axisTextStyle: const TextStyle(
      color: SolarizedColors.base00,
      fontSize: 12,
      fontFamily: 'roboto-mono',
    ),
    axisLabelStyle: const TextStyle(
      color: SolarizedColors.base01,
      fontSize: 12,
      fontFamily: 'roboto-mono',
    ),
  );
}
