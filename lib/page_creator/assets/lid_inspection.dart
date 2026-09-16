/// Lid inspection asset — a camera button that is also an alarm beacon.
///
/// A box-lid inspection camera lives off the PLC: a separate service grabs
/// each lid, scores it with an anomaly model, and decides against a
/// threshold. This asset is how that service reaches the operator.
///
/// It extends the alarm beacon ([AlarmVisibilityConfig]) rather than copying
/// it: the beacon already knows how to watch a set of alarm uids, pulse in the
/// alarm's colour, and — because the navigation providers discover beacons by
/// type — light the page's navigation entry and drive auto-navigation. A
/// subclass inherits all of that. What this asset adds on top:
///
///  * a visible tile (the beacon is invisible when idle; a camera is not),
///    coloured by the live verdict and pulsing while a bound alarm is active;
///  * a side pane with the latest inspected frame and its heat-map, the score
///    against the threshold, the recent anomalies, a score trend, and the
///    service's manual controls (arm / shadow, collect training lids, train,
///    reload) and threshold setpoint;
///  * a configure form that can mint the anomaly alarm itself, and carries
///    the setup instructions for the service, the key mappings and the
///    training workflow.
///
/// ## How the service is wired — no new transport
///
/// The service is an OPC UA server ([LidNode] is the node contract) and a
/// writer of one Postgres row per lid (`lid_inspection`, see
/// `package:tfc_dart/core/lid_inspection.dart`). Nothing else. The HMI
/// subscribes to the nodes through `StateMan` like any PLC tag, so:
///
///  * the anomaly alarm is an ordinary `AlarmConfig` with the formula
///    `<prefix>.Anomaly AND <prefix>.Armed` — acknowledge, history, downtime
///    grouping, the alarm editor, all unchanged;
///  * the score trend is the collector historising `<prefix>.Score`;
///  * the manual controls are `StateMan.write`s, so the access rules gate
///    them exactly as they gate a conveyor's setpoints;
///  * images ride the database, the way technical documents already do.
///
/// There is deliberately no file watcher, no HTTP route and no backend code:
/// the backend has no HTTP server and no asset fetches over the network, and
/// a second alarm path beside the expression evaluator would be a second
/// alarm system.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/theme.dart' show HmiStateColors;
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/lid_inspection.dart';

import '../../providers/alarm.dart';
import '../../providers/lid_inspection.dart';
import '../../providers/state_man.dart';
import '../../widgets/alarm.dart'
    show AlarmNotificationColors, ViewActiveAlarm;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/setpoint_field.dart';
import '../../widgets/panes/side_pane.dart';
import '../../widgets/panes/standard_dialog.dart';
import '../../widgets/tag_access_guard.dart';
import 'alarm_visibility.dart';
import 'button.dart' show ButtonPainter, ButtonType;
import 'common.dart';
import 'sensor.dart' show SensorTrendGraphLoader;

part 'lid_inspection.g.dart';

// ---------------------------------------------------------------------------
// Node contract
// ---------------------------------------------------------------------------

/// The OPC UA nodes the inspection service exposes, one per camera, all under
/// one key prefix (`LID01.Score`, `LID01.Threshold`, …).
///
/// This enum is the contract: the asset subscribes by these suffixes, the
/// configure form's help text is generated from it, and the service's node
/// set must match it name for name. Changing a suffix here is a change to the
/// service and to every station's key mappings.
enum LidNode {
  score('Score', 'Double', 'Anomaly score of the last inspected lid — '
      'historise this one to get the trend.'),
  threshold('Threshold', 'Double', 'Score at or above which a lid is an '
      'anomaly. Written from the pane\'s Setpoints section.',
      writable: true),
  anomaly('Anomaly', 'Boolean', 'True from the moment a lid scores at or '
      'above the threshold until the next lid scores below it. The alarm '
      'formula reads this.'),
  armed('Armed', 'Boolean', 'False is shadow mode: lids are scored and '
      'recorded, no alarm follows. Written from the pane\'s Manual section.',
      writable: true),
  lastId('LastId', 'String', 'Id of the last inspection row in the '
      'database — the pane reloads its pictures when this changes.'),
  secondsSinceLast('SecondsSinceLast', 'Int32', 'Seconds since a lid was '
      'last inspected, refreshed every second; alarm on it to catch a '
      'silent camera while the line runs.'),
  cameraOk('CameraOk', 'Boolean', 'False while the service cannot grab '
      'frames from the camera.'),
  lidType('LidType', 'String', 'Name of the lid type (and so the model) in '
      'use.'),
  modelVersion('ModelVersion', 'String', 'Version stamp of the loaded '
      'model.'),
  trainingState('TrainingState', 'String', 'idle, collecting, training, '
      'failed — what the training workflow is doing.'),
  goodSamples('GoodSamples', 'Int32', 'Number of good-lid images in the '
      'training set for the current lid type.'),
  command('Command', 'String', 'Written by the pane: collect:<n>, train, '
      'reload. The service acts on it and clears it.',
      writable: true, subscribed: false);

  const LidNode(this.suffix, this.type, this.meaning,
      {this.writable = false, this.subscribed = true});

  /// The part after the prefix in the key name.
  final String suffix;

  /// OPC UA data type, as the service must declare it.
  final String type;

  /// One-sentence meaning, for the help text.
  final String meaning;

  /// Whether the HMI writes it.
  final bool writable;

  /// Whether the tile and pane subscribe to it. [command] is write-only.
  final bool subscribed;

  /// The full key under [prefix].
  String keyFor(String prefix) => '$prefix.$suffix';
}

/// The commands the pane writes to [LidNode.command].
class LidCommand {
  LidCommand._();
  static String collect(int lids) => 'collect:$lids';
  static const String train = 'train';
  static const String reload = 'reload';
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

@JsonSerializable(explicitToJson: true)
class LidInspectionConfig extends AlarmVisibilityConfig {
  @override
  String get displayName => 'Lid inspection';

  @override
  String get category => 'Visualization';

  /// The key prefix the service's nodes are mapped under, e.g. `LID01`.
  /// Every [LidNode] key is `<prefix>.<suffix>`.
  @JsonKey(name: 'key_prefix', defaultValue: '')
  String keyPrefix;

  /// The `camera` column value of this camera's rows in `lid_inspection`.
  /// Empty means "same as the key prefix", which is what the service does
  /// by default.
  @JsonKey(name: 'camera', defaultValue: '')
  String camera;

  /// How many recent anomalies the pane lists.
  @JsonKey(name: 'recent_limit', defaultValue: 8)
  int recentLimit;

  /// How many good lids one "Collect good lids" press asks the service to
  /// add to the training set.
  @JsonKey(name: 'training_batch', defaultValue: 20)
  int trainingBatch;

  LidInspectionConfig({
    this.keyPrefix = '',
    this.camera = '',
    this.recentLimit = 8,
    this.trainingBatch = 20,
    super.alarmUids,
    super.announceInNavigation,
  }) : super(showWhenInactive: true) {
    textPos = TextPos.below;
    size = const RelativeSize(width: 0.09, height: 0.07);
  }

  /// Palette/preview instance: a static "OK" tile with sample figures.
  LidInspectionConfig.preview()
      : keyPrefix = 'LID01',
        camera = '',
        recentLimit = 8,
        trainingBatch = 20,
        super(showWhenInactive: true) {
    isPreview = true;
    textPos = TextPos.below;
    size = const RelativeSize(width: 0.09, height: 0.07);
  }

  factory LidInspectionConfig.fromJson(Map<String, dynamic> json) =>
      _$LidInspectionConfigFromJson(json);

  @override
  Map<String, dynamic> toJson() => _$LidInspectionConfigToJson(this);

  /// The `camera` value to read rows by.
  String get cameraId => camera.isEmpty ? keyPrefix : camera;

  /// The key for [node] on this camera.
  String key(LidNode node) => node.keyFor(keyPrefix);

  /// The title the tile and pane show.
  String get title {
    final t = text;
    if (t != null && t.isNotEmpty) return t;
    return keyPrefix.isEmpty ? 'Lid inspection' : keyPrefix;
  }

  @override
  Widget build(BuildContext context) => LidInspectionTile(config: this);

  @override
  Widget configure(BuildContext context) =>
      _LidInspectionConfigEditor(config: this);
}

/// The anomaly alarm this asset mints for itself: one rule, error level,
/// acknowledge required so a one-lid event stays on screen until someone has
/// looked at the picture, and NOT a stop — a bad lid does not halt the line.
///
/// The formula ANDs in `Armed` so shadow mode is silent without anybody
/// editing the alarm. The uid is derived from the prefix so a second press of
/// "Create anomaly alarm" updates the same alarm instead of adding a twin.
AlarmConfig lidAnomalyAlarmConfig(LidInspectionConfig config) {
  final prefix = config.keyPrefix;
  return AlarmConfig(
    uid: lidAnomalyAlarmUid(prefix),
    title: '${config.title}: lid anomaly',
    description: 'Camera $prefix scored a lid at or above its threshold '
        'while armed. Open the Lid inspection tile for the picture and the '
        'heat-map.',
    rules: [
      AlarmRule(
        level: AlarmLevel.error,
        expression: ExpressionConfig(
          value: Expression(
            formula: '${LidNode.anomaly.keyFor(prefix)} AND '
                '${LidNode.armed.keyFor(prefix)}',
          ),
        ),
        acknowledgeRequired: true,
      ),
    ],
    countsAsStop: false,
  );
}

/// The uid [lidAnomalyAlarmConfig] uses for [prefix].
String lidAnomalyAlarmUid(String prefix) => 'lid-anomaly:$prefix';

// ---------------------------------------------------------------------------
// Live state
// ---------------------------------------------------------------------------

/// The latest value of every subscribed [LidNode], plus which subscriptions
/// failed. Immutable; the tracker emits a new one per change.
class LidInspectionLive {
  final Map<LidNode, DynamicValue> values;

  /// Subscribe errors by node — a key that is not mapped, or a server that
  /// refused. The message is what the pane shows.
  final Map<LidNode, String> errors;

  const LidInspectionLive(
      {this.values = const {}, this.errors = const {}});

  LidInspectionLive withValue(LidNode node, DynamicValue value) =>
      LidInspectionLive(
        values: {...values, node: value},
        errors: errors,
      );

  LidInspectionLive withError(LidNode node, String message) =>
      LidInspectionLive(
        values: values,
        errors: {...errors, node: message},
      );

  double? get score => _d(LidNode.score);
  double? get threshold => _d(LidNode.threshold);
  bool? get anomaly => _b(LidNode.anomaly);
  bool? get armed => _b(LidNode.armed);
  bool? get cameraOk => _b(LidNode.cameraOk);
  String? get lastId => _s(LidNode.lastId);
  int? get secondsSinceLast => _i(LidNode.secondsSinceLast);
  String? get lidType => _s(LidNode.lidType);
  String? get modelVersion => _s(LidNode.modelVersion);
  String? get trainingState => _s(LidNode.trainingState);
  int? get goodSamples => _i(LidNode.goodSamples);

  double? _d(LidNode n) {
    final v = values[n];
    return v == null || v.isNull ? null : v.asDouble;
  }

  bool? _b(LidNode n) {
    final v = values[n];
    return v == null || v.isNull ? null : v.asBool;
  }

  int? _i(LidNode n) {
    final v = values[n];
    return v == null || v.isNull ? null : v.asInt;
  }

  String? _s(LidNode n) {
    final v = values[n];
    if (v == null || v.isNull) return null;
    final s = v.asString;
    return s.isEmpty ? null : s;
  }

  /// The preview tile's figures.
  static LidInspectionLive sample({bool anomaly = false, bool armed = true}) =>
      LidInspectionLive(values: {
        LidNode.score: DynamicValue(value: anomaly ? 0.87 : 0.31),
        LidNode.threshold: DynamicValue(value: 0.62),
        LidNode.anomaly: DynamicValue(value: anomaly),
        LidNode.armed: DynamicValue(value: armed),
        LidNode.cameraOk: DynamicValue(value: true),
        LidNode.lidType: DynamicValue(value: 'lid_40x30_a'),
        LidNode.modelVersion: DynamicValue(value: 'patchcore_r18_2026-09-10'),
        LidNode.trainingState: DynamicValue(value: 'idle'),
        LidNode.goodSamples: DynamicValue(value: 240),
      });
}

/// What the tile says about the camera, most urgent first.
enum LidInspectionState {
  /// The score key could not be subscribed — not mapped, or the service's
  /// server is unreachable. The message is in [LidInspectionLive.errors].
  unavailable,

  /// Subscribed, no value yet.
  connecting,

  /// The service runs but cannot grab frames.
  offline,

  /// Armed and the last lid tripped the threshold.
  anomaly,

  /// Shadow mode and the last lid tripped the threshold: recorded, silent.
  shadowAnomaly,

  /// Shadow mode, last lid fine.
  shadow,

  /// Armed, last lid fine.
  ok,
}

/// Pure: [live] → state. Unknown `Armed` counts as armed, because a service
/// that does not publish the node has nothing to be quiet about.
LidInspectionState lidInspectionState(LidInspectionLive live) {
  if (live.errors.containsKey(LidNode.score)) {
    return LidInspectionState.unavailable;
  }
  if (!live.values.containsKey(LidNode.score)) {
    return LidInspectionState.connecting;
  }
  if (live.cameraOk == false) return LidInspectionState.offline;
  final armed = live.armed ?? true;
  if (live.anomaly == true) {
    return armed
        ? LidInspectionState.anomaly
        : LidInspectionState.shadowAnomaly;
  }
  return armed ? LidInspectionState.ok : LidInspectionState.shadow;
}

/// The pane's header chip for [state].
PaneStatus lidInspectionPaneStatus(LidInspectionState state) =>
    switch (state) {
      LidInspectionState.unavailable => const PaneStatus.unknown('Unavailable'),
      LidInspectionState.connecting => const PaneStatus.unknown('Connecting'),
      LidInspectionState.offline => const PaneStatus.stale('Camera offline'),
      LidInspectionState.anomaly => const PaneStatus.fault('Anomaly'),
      LidInspectionState.shadowAnomaly =>
        const PaneStatus.warning('Anomaly (shadow)'),
      LidInspectionState.shadow => const PaneStatus.warning('Shadow mode'),
      LidInspectionState.ok => const PaneStatus.running('OK'),
    };

/// The tile's second line for [state] and [live]: the verdict and the score.
String lidInspectionTileCaption(LidInspectionState state, LidInspectionLive live) {
  String score() {
    final s = live.score;
    return s == null ? '' : ' ${s.toStringAsFixed(2)}';
  }

  return switch (state) {
    LidInspectionState.unavailable => 'Unavailable',
    LidInspectionState.connecting => 'Connecting…',
    LidInspectionState.offline => 'Camera offline',
    LidInspectionState.anomaly => 'ANOMALY${score()}',
    LidInspectionState.shadowAnomaly => 'Shadow · anomaly${score()}',
    LidInspectionState.shadow => 'Shadow${score()}',
    LidInspectionState.ok => 'OK${score()}',
  };
}

/// The tile's fill for [state], from the theme's muted state palette. Only
/// the anomaly is saturated (fault red); shadow mode is the same yellow as
/// manual mode on a conveyor — "not doing its automatic job"; OK is the
/// running green; anything that is not a verdict is grey. The palette, not
/// `colorScheme.primary`, so the same verdict is the same colour on both
/// themes.
Color lidInspectionTileColor(BuildContext context, LidInspectionState state) {
  final colors = HmiStateColors.of(context);
  return switch (state) {
    LidInspectionState.anomaly => colors.red,
    LidInspectionState.shadowAnomaly ||
    LidInspectionState.shadow =>
      colors.yellow,
    LidInspectionState.ok => colors.green,
    LidInspectionState.unavailable ||
    LidInspectionState.connecting ||
    LidInspectionState.offline =>
      colors.grey,
  };
}

/// Subscribes every [LidNode] of one camera and folds the values into a
/// stream of [LidInspectionLive] snapshots.
///
/// Takes the subscribe function rather than a `StateMan` so it can be tested
/// with a map of subjects, and so a subscribe failure on one node (an
/// unmapped key) is recorded on that node instead of taking the others down.
class LidLiveTracker {
  LidLiveTracker({
    required this.keyFor,
    required this.subscribe,
  });

  final String Function(LidNode node) keyFor;
  final Future<Stream<DynamicValue>> Function(String key) subscribe;

  final _subject =
      BehaviorSubject<LidInspectionLive>.seeded(const LidInspectionLive());
  final _subs = <StreamSubscription<DynamicValue>>[];
  bool _disposed = false;

  Stream<LidInspectionLive> get stream => _subject.stream;
  LidInspectionLive get current => _subject.value;

  void start() {
    for (final node in LidNode.values) {
      if (!node.subscribed) continue;
      subscribe(keyFor(node)).then((stream) {
        if (_disposed) return;
        _subs.add(stream.listen(
          (value) => _emit(current.withValue(node, value)),
          onError: (Object e) => _emit(current.withError(node, '$e')),
        ));
      }, onError: (Object e) => _emit(current.withError(node, '$e')));
    }
  }

  void _emit(LidInspectionLive live) {
    if (_disposed) return;
    _subject.add(live);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    await _subject.close();
  }
}

// ---------------------------------------------------------------------------
// Tile
// ---------------------------------------------------------------------------

/// The button on the mimic.
///
/// Coloured by the live verdict, and — the beacon half — carrying the alarm
/// pulse at its corner while a bound alarm is active. Tapping opens the pane.
class LidInspectionTile extends ConsumerStatefulWidget {
  final LidInspectionConfig config;
  const LidInspectionTile({super.key, required this.config});

  @override
  ConsumerState<LidInspectionTile> createState() => _LidInspectionTileState();
}

class _LidInspectionTileState extends ConsumerState<LidInspectionTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  LidLiveTracker? _tracker;
  StreamSubscription<LidInspectionLive>? _liveSub;
  StreamSubscription<List<AlarmActive>>? _alarmSub;
  LidInspectionLive _live = const LidInspectionLive();
  List<AlarmActive> _active = const [];
  String? _subscribedPrefix;
  String? _subscribedUids;
  bool _pressed = false;

  String get _paneId => 'lid-inspection:${identityHashCode(widget.config)}';

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.config.isPreview) {
      _live = LidInspectionLive.sample();
    } else {
      _subscribeLive();
      _subscribeAlarms();
    }
  }

  @override
  void didUpdateWidget(covariant LidInspectionTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.config.isPreview) return;
    if (_subscribedPrefix != widget.config.keyPrefix) _subscribeLive();
    if (_subscribedUids != widget.config.alarmUids.join('\x00')) {
      _subscribeAlarms();
    }
  }

  @override
  void dispose() {
    closeSidePane(id: _paneId, immediate: true);
    _liveSub?.cancel();
    _alarmSub?.cancel();
    _tracker?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _subscribeLive() {
    _liveSub?.cancel();
    _tracker?.dispose();
    _subscribedPrefix = widget.config.keyPrefix;
    final config = widget.config;
    final tracker = LidLiveTracker(
      keyFor: config.key,
      subscribe: (key) async {
        final sm = await ref.read(stateManProvider.future);
        return sm.subscribe(key);
      },
    );
    _tracker = tracker;
    _liveSub = tracker.stream.listen((live) {
      if (!mounted) return;
      setState(() => _live = live);
    });
    tracker.start();
  }

  void _subscribeAlarms() {
    _alarmSub?.cancel();
    _subscribedUids = widget.config.alarmUids.join('\x00');
    _alarmSub = ref
        .read(alarmManProvider.future)
        .asStream()
        .switchMap((alarmMan) => alarmMan.activeAlarms())
        .map((set) => matchingActiveAlarms(set, widget.config.alarmUids))
        .listen((list) {
      if (!mounted) return;
      setState(() => _active = list);
      _syncPulse();
    }, onError: (Object e, StackTrace s) {
      if (!mounted) return;
      setState(() => _active = const []);
      _syncPulse();
    });
  }

  /// The ticker runs only while an alarm is active — an idle tile costs no
  /// repaints (the beacon's rule, for the same 24/7 reason).
  void _syncPulse() {
    if (_active.isNotEmpty) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  /// Test-only: drive the tile into the state a live emission would.
  @visibleForTesting
  void debugSet({LidInspectionLive? live, List<AlarmActive>? active}) {
    setState(() {
      if (live != null) _live = live;
      if (active != null) _active = matchingActiveAlarms(active, const []);
    });
    _syncPulse();
  }

  void _showPane() {
    showSidePane(
      context: context,
      id: _paneId,
      builder: (_) => LidInspectionPane(config: widget.config),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final state = lidInspectionState(_live);
    final fill = lidInspectionTileColor(context, state);
    final onFill = HmiStateColors.of(context).onState;
    final alarmColors =
        _active.isEmpty ? null : _active.first.notification.getColors(context);

    return LayoutBuilder(builder: (context, constraints) {
      final side = constraints.biggest.shortestSide;
      final badge = (side * 0.36).clamp(16.0, 48.0);
      return Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const RoundedRectangleBorder(),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            _showPane();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: ButtonPainter(
                    color: fill,
                    isPressed: _pressed,
                    buttonType: ButtonType.square,
                    borderColor: alarmColors?.$1,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          state == LidInspectionState.anomaly ||
                                  state == LidInspectionState.shadowAnomaly
                              ? Icons.report
                              : Icons.photo_camera,
                          size: (side * 0.34).clamp(8.0, constraints.maxHeight / 2),
                          color: onFill,
                        ),
                        Flexible(
                          child: AutoSizedText(
                            config.title,
                            maxFontSize: side * 0.18,
                            style: TextStyle(
                              color: onFill,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Flexible(
                          child: AutoSizedText(
                            lidInspectionTileCaption(state, _live),
                            maxFontSize: side * 0.15,
                            style: TextStyle(color: onFill),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (alarmColors != null)
                // Inside the box, not hanging off its corner: the page
                // clips each asset to its rect, and a badge past the edge
                // would be cut or land on a neighbour.
                Positioned(
                  top: 2,
                  right: 2,
                  width: badge,
                  height: badge,
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _pulse,
                        // Rings in the on-state colour, not the alarm's:
                        // an armed anomaly paints the tile in the same red
                        // the alarm card uses, and red rings on a red tile
                        // are invisible exactly when they matter. The dot's
                        // outline carries the alarm colour instead.
                        builder: (context, _) => CustomPaint(
                          painter: AlarmPulsePainter(
                            color: onFill,
                            dotOutlineColor: alarmColors.$1,
                            progress: _pulse.value,
                            dotRadiusFactor: 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Side pane — data layer
// ---------------------------------------------------------------------------

/// Everything the pane needs, resolved: live nodes, the latest record with
/// its bytes, the recent anomalies, the bound alarms.
class LidInspectionPane extends ConsumerStatefulWidget {
  final LidInspectionConfig config;
  const LidInspectionPane({super.key, required this.config});

  @override
  ConsumerState<LidInspectionPane> createState() => _LidInspectionPaneState();
}

class _LidInspectionPaneState extends ConsumerState<LidInspectionPane> {
  LidInspectionConfig get config => widget.config;

  late final LidLiveTracker _tracker;
  StreamSubscription<LidInspectionLive>? _liveSub;
  StreamSubscription<List<AlarmActive>>? _alarmSub;
  LidInspectionLive _live = const LidInspectionLive();
  List<AlarmActive> _active = const [];

  LidInspectionStore? _store;
  String? _storeMessage;
  LidInspectionRecord? _latest;
  Uint8List? _latestImage;
  Uint8List? _latestHeatmap;
  List<LidInspectionRecord> _recent = const [];
  String? _loadedForId;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tracker = LidLiveTracker(
      keyFor: config.key,
      subscribe: (key) async {
        final sm = await ref.read(stateManProvider.future);
        return sm.subscribe(key);
      },
    );
    _liveSub = _tracker.stream.listen((live) {
      if (!mounted) return;
      setState(() => _live = live);
      // A new LastId means a new row — reload. LastId absent (older service,
      // or not mapped) falls back to reloading on every score change.
      final marker = live.lastId ?? live.score?.toString();
      if (marker != _loadedForId) _reload(marker);
    });
    _tracker.start();

    _alarmSub = ref
        .read(alarmManProvider.future)
        .asStream()
        .switchMap((alarmMan) => alarmMan.activeAlarms())
        .map((set) => matchingActiveAlarms(set, config.alarmUids))
        .listen((list) {
      if (mounted) setState(() => _active = list);
    }, onError: (Object e, StackTrace s) {
      if (mounted) setState(() => _active = const []);
    });

    _resolveStore();
  }

  Future<void> _resolveStore() async {
    try {
      final store = await ref.read(lidInspectionStoreProvider.future);
      if (!mounted) return;
      setState(() {
        _store = store;
        _storeMessage = store == null
            ? 'No station database — pictures are not available here.'
            : null;
      });
      if (store != null) await _reload(_loadedForId, force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _storeMessage = 'Database unavailable: $e');
    }
  }

  Future<void> _reload(String? marker, {bool force = false}) async {
    final store = _store;
    if (store == null) return;
    if (_loading && !force) return;
    _loading = true;
    _loadedForId = marker;
    try {
      final latest = await store.latest(config.cameraId);
      final recent =
          await store.recent(config.cameraId, limit: config.recentLimit);
      Uint8List? image;
      Uint8List? heatmap;
      if (latest != null && latest.hasImage) {
        image = await store.image(latest.id);
        heatmap = await store.image(latest.id, heatmap: true);
      }
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _latestImage = image;
        _latestHeatmap = heatmap;
        _recent = recent;
        _storeMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _storeMessage =
          'Could not read lid_inspection: $e. Has the inspection service '
          'created its table? (See Setup in the tile\'s configure form.)');
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _alarmSub?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  Future<void> _write(LidNode node, Object value) async {
    final sm = await ref.read(stateManProvider.future);
    final key = config.key(node);
    await writeTag(ref, sm, key, DynamicValue(value: value));
  }

  @override
  Widget build(BuildContext context) {
    final scoreKey = config.key(LidNode.score);
    return LidInspectionPaneView(
      config: config,
      live: _live,
      active: _active,
      latest: _latest,
      latestImage: _latestImage,
      latestHeatmap: _latestHeatmap,
      recent: _recent,
      storeMessage: _storeMessage,
      thumbnail: _store == null ? null : (id) => _store!.image(id),
      heatmapOf: _store == null ? null : (id) => _store!.image(id, heatmap: true),
      trend: PaneGraphTile(
        legend: {'Score': HmiStateColors.of(context).blue},
        height: kPaneTrendTileHeight,
        preview: SensorTrendGraphLoader(
          keyName: scoreKey,
          showButtons: false,
          compact: true,
          xSpan: const Duration(minutes: 30),
        ),
        expandedTitle: 'Anomaly score',
        expandedSize: kPaneTrendDialogSize,
        expandedBuilder: (context) => SensorTrendGraphLoader(
          keyName: scoreKey,
          xSpan: const Duration(hours: 2),
        ),
      ),
      onArmed: (armed) => _write(LidNode.armed, armed),
      onCommand: (command) => _write(LidNode.command, command),
      onThreshold: (value) => _write(LidNode.threshold, value),
    );
  }
}

// ---------------------------------------------------------------------------
// Side pane — pure view
// ---------------------------------------------------------------------------

/// Pure rendering of the pane — driven by resolved data so tests and goldens
/// can pump it with no `StateMan`, no database and no `AlarmMan`.
class LidInspectionPaneView extends StatelessWidget {
  final LidInspectionConfig config;
  final LidInspectionLive live;
  final List<AlarmActive> active;
  final LidInspectionRecord? latest;
  final Uint8List? latestImage;
  final Uint8List? latestHeatmap;
  final List<LidInspectionRecord> recent;

  /// Why records are missing, when they are: no database, table absent.
  final String? storeMessage;

  /// Lazily loads a thumbnail / heat-map for a recent row; null disables the
  /// thumbnails (no store).
  final Future<Uint8List?> Function(String id)? thumbnail;
  final Future<Uint8List?> Function(String id)? heatmapOf;

  /// The Trend section's tile; null shows the "not historised" hint instead.
  final Widget? trend;

  final ValueChanged<bool>? onArmed;
  final ValueChanged<String>? onCommand;
  final ValueChanged<double>? onThreshold;

  const LidInspectionPaneView({
    super.key,
    required this.config,
    required this.live,
    this.active = const [],
    this.latest,
    this.latestImage,
    this.latestHeatmap,
    this.recent = const [],
    this.storeMessage,
    this.thumbnail,
    this.heatmapOf,
    this.trend,
    this.onArmed,
    this.onCommand,
    this.onThreshold,
  });

  static final _time = DateFormat('dd.MM HH:mm:ss');

  static String formatTime(DateTime t) => _time.format(t.toLocal());

  @override
  Widget build(BuildContext context) {
    final state = lidInspectionState(live);
    final theme = Theme.of(context);
    final colors = HmiStateColors.of(context);
    final scoreError = live.errors[LidNode.score];

    return SidePane(
      title: config.title,
      subtitle: live.lidType,
      icon: Icons.photo_camera,
      status: lidInspectionPaneStatus(state),
      child: PaneBody(
        sections: [
          PaneBodySection.status(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (scoreError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Not reading ${config.key(LidNode.score)}: $scoreError',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final alarm in active)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ViewActiveAlarm(alarm: alarm),
                  ),
                PaneTileRow(children: [
                  PaneMetricTile(
                    label: 'Score',
                    value: live.score?.toStringAsFixed(2) ?? '—',
                    icon: Icons.analytics_outlined,
                    valueColor: switch (state) {
                      LidInspectionState.anomaly => colors.red,
                      LidInspectionState.shadowAnomaly => colors.yellow,
                      _ => null,
                    },
                  ),
                  PaneMetricTile(
                    label: 'Threshold',
                    value: live.threshold?.toStringAsFixed(2) ?? '—',
                    icon: Icons.linear_scale,
                  ),
                ]),
                const SizedBox(height: 8),
                _LatestFrame(
                  latest: latest,
                  image: latestImage,
                  heatmap: latestHeatmap,
                  storeMessage: storeMessage,
                ),
                if (latest != null) ...[
                  PaneDetailRow(
                    label: 'Last lid',
                    value: formatTime(latest!.time),
                  ),
                  PaneDetailRow(
                    label: 'Verdict',
                    value: latest!.anomaly
                        ? (latest!.armed ? 'Anomaly' : 'Anomaly (shadow)')
                        : 'OK',
                    valueColor: latest!.anomaly ? colors.red : null,
                  ),
                  if (latest!.inferenceMs != null)
                    PaneDetailRow(
                      label: 'Inference',
                      value: '${latest!.inferenceMs} ms',
                    ),
                ],
                if (live.secondsSinceLast case final s?)
                  PaneDetailRow(
                    label: 'Since last lid',
                    value: '$s s',
                  ),
              ],
            ),
          ),
          PaneBodySection.trend(
            child: trend ??
                Text(
                  'Historise ${config.key(LidNode.score)} in the key '
                  'mappings to see the score trend here.',
                  style: theme.textTheme.bodySmall,
                ),
          ),
          PaneBodySection.manual(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  key: const Key('lid-armed'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Armed'),
                  subtitle: Text(
                    (live.armed ?? true)
                        ? 'An anomaly raises the alarm'
                        : 'Shadow mode: anomalies are recorded, no alarm',
                  ),
                  value: live.armed ?? true,
                  onChanged: onArmed == null ? null : (v) => onArmed!(v),
                ),
                const SizedBox(height: 4),
                PaneDetailRow(
                  label: 'Training',
                  value: live.trainingState ?? '—',
                ),
                PaneDetailRow(
                  label: 'Good lids in set',
                  value: live.goodSamples?.toString() ?? '—',
                ),
                PaneDetailRow(
                  label: 'Model',
                  value: live.modelVersion ?? '—',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('lid-collect'),
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text('Collect ${config.trainingBatch} good lids'),
                      onPressed: onCommand == null
                          ? null
                          : () => onCommand!(
                              LidCommand.collect(config.trainingBatch)),
                    ),
                    OutlinedButton.icon(
                      key: const Key('lid-train'),
                      icon: const Icon(Icons.model_training),
                      label: const Text('Train model'),
                      onPressed: onCommand == null
                          ? null
                          : () => onCommand!(LidCommand.train),
                    ),
                    OutlinedButton.icon(
                      key: const Key('lid-reload'),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reload model'),
                      onPressed: onCommand == null
                          ? null
                          : () => onCommand!(LidCommand.reload),
                    ),
                  ],
                ),
              ],
            ),
          ),
          PaneBodySection.setpoints(
            child: SetpointField<double>(
              fieldKey: 'lid-threshold',
              label: 'Threshold',
              text: live.threshold?.toStringAsFixed(2) ?? '',
              current: live.threshold ?? 0,
              parse: (t) {
                final v = double.tryParse(t.replaceAll(',', '.'));
                return v == null || v < 0 || v > 1 ? null : v;
              },
              onSubmitted: (v) => onThreshold?.call(v),
              locked: onThreshold == null,
            ),
          ),
          PaneBodySection.details(
            title: 'Recent anomalies',
            child: _RecentList(
              recent: recent,
              thumbnail: thumbnail,
              heatmapOf: heatmapOf,
            ),
          ),
        ],
      ),
    );
  }
}

/// The latest inspected frame, tappable to zoom, or the reason there is
/// none.
class _LatestFrame extends StatelessWidget {
  final LidInspectionRecord? latest;
  final Uint8List? image;
  final Uint8List? heatmap;
  final String? storeMessage;

  const _LatestFrame({
    required this.latest,
    required this.image,
    required this.heatmap,
    required this.storeMessage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (storeMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(storeMessage!, style: theme.textTheme.bodySmall),
      );
    }
    if (latest == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('No lid has been inspected yet.',
            style: theme.textTheme.bodySmall),
      );
    }
    if (image == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Last lid was OK — no picture is kept for OK lids.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InspectionFrameTile(
        record: latest!,
        image: image!,
        heatmap: heatmap,
      ),
    );
  }
}

/// A stored frame at pane width; tap opens the zoomable viewer with the
/// frame / heat-map toggle.
class InspectionFrameTile extends StatelessWidget {
  final LidInspectionRecord record;
  final Uint8List image;
  final Uint8List? heatmap;

  const InspectionFrameTile({
    super.key,
    required this.record,
    required this.image,
    this.heatmap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: Key('lid-frame-${record.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => showInspectionViewer(
        context,
        record: record,
        image: image,
        heatmap: heatmap,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.memory(image, fit: BoxFit.cover, gaplessPlayback: true),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.zoom_in, size: 14),
                      const SizedBox(width: 4),
                      Text(record.score.toStringAsFixed(2),
                          style: theme.textTheme.labelSmall),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the frame in a floating dialog with pinch/scroll zoom so a small
/// defect can be looked at, and a Frame / Heat-map toggle.
Future<void> showInspectionViewer(
  BuildContext context, {
  required LidInspectionRecord record,
  required Uint8List image,
  Uint8List? heatmap,
}) {
  return showFloatingDialog<void>(
    context: context,
    id: 'lid-inspection-viewer:${record.id}',
    title: 'Lid ${LidInspectionPaneView.formatTime(record.time)}',
    subtitle: 'Score ${record.score.toStringAsFixed(2)} / '
        '${record.threshold.toStringAsFixed(2)}'
        '${record.modelVersion == null ? '' : ' · ${record.modelVersion}'}',
    icon: Icons.photo_camera,
    status: record.anomaly
        ? const PaneStatus.fault('Anomaly')
        : const PaneStatus.running('OK'),
    size: const Size(900, 700),
    scrollable: false,
    builder: (_) => InspectionViewer(image: image, heatmap: heatmap),
  );
}

/// The viewer body: zoomable image with a frame / heat-map switch.
class InspectionViewer extends StatefulWidget {
  final Uint8List image;
  final Uint8List? heatmap;
  const InspectionViewer({super.key, required this.image, this.heatmap});

  @override
  State<InspectionViewer> createState() => _InspectionViewerState();
}

class _InspectionViewerState extends State<InspectionViewer> {
  bool _heat = false;

  @override
  Widget build(BuildContext context) {
    final bytes = _heat ? (widget.heatmap ?? widget.image) : widget.image;
    return Column(
      children: [
        if (widget.heatmap != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Frame')),
                ButtonSegment(value: true, label: Text('Heat-map')),
              ],
              selected: {_heat},
              onSelectionChanged: (s) => setState(() => _heat = s.first),
            ),
          ),
        Expanded(
          child: InteractiveViewer(
            maxScale: 12,
            child: SizedBox.expand(
              child: Image.memory(bytes,
                  fit: BoxFit.contain, gaplessPlayback: true),
            ),
          ),
        ),
      ],
    );
  }
}

/// The recent-anomalies rows: time, score, and a thumbnail where one is
/// stored; tap opens the viewer.
class _RecentList extends StatelessWidget {
  final List<LidInspectionRecord> recent;
  final Future<Uint8List?> Function(String id)? thumbnail;
  final Future<Uint8List?> Function(String id)? heatmapOf;

  const _RecentList({
    required this.recent,
    required this.thumbnail,
    required this.heatmapOf,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (recent.isEmpty) {
      return Text('No anomalies recorded.', style: theme.textTheme.bodySmall);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in recent)
          _RecentRow(record: r, thumbnail: thumbnail, heatmapOf: heatmapOf),
      ],
    );
  }
}

class _RecentRow extends StatefulWidget {
  final LidInspectionRecord record;
  final Future<Uint8List?> Function(String id)? thumbnail;
  final Future<Uint8List?> Function(String id)? heatmapOf;

  const _RecentRow({
    required this.record,
    required this.thumbnail,
    required this.heatmapOf,
  });

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    final load = widget.thumbnail;
    if (load != null && widget.record.hasImage) _bytes = load(widget.record.id);
  }

  Future<void> _open(Uint8List image) async {
    final heat = await widget.heatmapOf?.call(widget.record.id);
    if (!mounted) return;
    await showInspectionViewer(context,
        record: widget.record, image: image, heatmap: heat);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.record;
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) {
        final bytes = snap.data;
        return ListTile(
          key: Key('lid-recent-${r.id}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: SizedBox(
            width: 56,
            height: 42,
            child: bytes == null
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(Icons.image_not_supported_outlined,
                        size: 18),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(bytes,
                        fit: BoxFit.cover, gaplessPlayback: true),
                  ),
          ),
          title: Text(LidInspectionPaneView.formatTime(r.time)),
          subtitle: Text(
            'Score ${r.score.toStringAsFixed(2)}'
            '${r.armed ? '' : ' · shadow'}'
            '${r.lidType == null ? '' : ' · ${r.lidType}'}',
          ),
          onTap: bytes == null ? null : () => _open(bytes),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Config editor
// ---------------------------------------------------------------------------

/// The setup instructions shown at the top of the configure form.
///
/// Generated from [LidNode] so the node table can never drift from what the
/// asset subscribes to. A function of the config so the key names in it are
/// the operator's own prefix, not a placeholder.
String lidInspectionSetupHelp(LidInspectionConfig config) {
  final prefix = config.keyPrefix.isEmpty ? 'LID01' : config.keyPrefix;
  final camera = config.cameraId.isEmpty ? prefix : config.cameraId;
  final nodes = StringBuffer();
  for (final n in LidNode.values) {
    nodes.writeln('  • ${n.keyFor(prefix)}  (${n.type}'
        '${n.writable ? ', written by the HMI' : ''}) — ${n.meaning}');
  }
  return '''
1. The inspection service (Python: pypylon + Anomalib, see docs/lid-inspection.md) runs an OPC UA server. Add that server under Server config, then map its nodes in Key mappings with exactly these key names — the asset subscribes by suffix:
$nodes
2. Historise ${LidNode.score.keyFor(prefix)} (Key mappings, collect, no sample interval: one row per lid) so the pane's Trend section has data.

3. Press "Create anomaly alarm" below. It adds an acknowledge-required error alarm with the formula "${LidNode.anomaly.keyFor(prefix)} AND ${LidNode.armed.keyFor(prefix)}" and binds this tile to it, so the tile pulses, the page's navigation entry lights, and the alarm shows in the alarm list. Edit it in the Alarm editor like any other.

4. Pictures. The service writes one row per lid to the lid_inspection table in the station database (camera = "$camera"), with the frame and heat-map as JPEG for anomalies and near-misses. The service creates the table itself; the DDL is in docs/lid-inspection.md. Nothing to configure here beyond the camera name if it differs from the prefix.

5. Training set. Before the first model, and after any change to camera, lens, lighting, exposure or position, the service needs 100–300 good lids covering every acceptable variation (colour batches, print shifts). Two ways to give it those:
  • from the pane's Manual section: "Collect ${config.trainingBatch} good lids" tells the service to save the next ${config.trainingBatch} frames straight into the training set — run it while known-good lids pass, repeat until "Good lids in set" is enough;
  • from files: copy PNG/JPEG frames into the service's model folder, /data/models/<lid type>/dataset/good/ (and optional known defects into dataset/defect/ for threshold validation).

6. Train. "Train model" fits the model on the training set and exports it; the pane's Training row goes collecting, then training, then idle, and Model shows the new version stamp. Inference keeps running on the previous model until "Reload model". Then set the threshold in Setpoints just above the highest score the good lids reach, and verify with a scratched or marked lid.

7. Leave the camera in shadow mode (Armed off) for a few days first: anomalies are recorded and listed here but raise no alarm. Arm it when the recorded anomalies look right.
''';
}

/// Editor body for [LidInspectionConfig]. Edits mutate the live config in
/// place — the page editor's config pane mirrors them onto the canvas.
class _LidInspectionConfigEditor extends ConsumerStatefulWidget {
  final LidInspectionConfig config;
  const _LidInspectionConfigEditor({required this.config});

  @override
  ConsumerState<_LidInspectionConfigEditor> createState() =>
      _LidInspectionConfigEditorState();
}

class _LidInspectionConfigEditorState
    extends ConsumerState<_LidInspectionConfigEditor> {
  bool _helpOpen = false;

  LidInspectionConfig get config => widget.config;

  Future<void> _createAlarm() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final alarmMan = await ref.read(alarmManProvider.future);
      final alarm = lidAnomalyAlarmConfig(config);
      final exists =
          alarmMan.config.alarms.any((a) => a.uid == alarm.uid);
      if (exists) {
        alarmMan.updateAlarm(alarm);
      } else {
        alarmMan.addAlarm(alarm);
      }
      ref.invalidate(alarmManProvider);
      if (!mounted) return;
      setState(() {
        if (!config.alarmUids.contains(alarm.uid)) {
          config.alarmUids.add(alarm.uid);
        }
      });
      messenger?.showSnackBar(SnackBar(
        content: Text(exists
            ? 'Updated alarm "${alarm.title}".'
            : 'Created alarm "${alarm.title}" and bound this tile to it.'),
      ));
    } catch (e) {
      messenger?.showSnackBar(
          SnackBar(content: Text('Could not create the alarm: $e')));
    }
  }

  Widget _alarmPicker() {
    return FutureBuilder<AlarmMan>(
      future: ref.watch(alarmManProvider.future),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Alarm service unavailable — cannot list alarms.',
              style: Theme.of(context).textTheme.bodySmall);
        }
        if (!snapshot.hasData) {
          return Text('Loading alarms…',
              style: Theme.of(context).textTheme.bodySmall);
        }
        final alarms = snapshot.data!.alarms.map((a) => a.config).toList();
        if (alarms.isEmpty) {
          return Text(
            'No alarms configured yet — press "Create anomaly alarm".',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return AlarmPickerList(
          alarms: alarms,
          selectedUids: config.alarmUids,
          onSelectionChanged: () => setState(() {}),
          maxHeight: 200,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 380,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Setup help --
            Container(
              key: const Key('lid-setup-help'),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => setState(() => _helpOpen = !_helpOpen),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Setup: service, keys, alarm, '
                              'pictures, training',
                              style: theme.textTheme.titleSmall),
                        ),
                        Icon(_helpOpen ? Icons.expand_less : Icons.expand_more,
                            size: 18),
                      ],
                    ),
                  ),
                  if (_helpOpen) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      lidInspectionSetupHelp(config),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Keys --
            TextFormField(
              key: const Key('lid-key-prefix'),
              initialValue: config.keyPrefix,
              decoration: const InputDecoration(
                labelText: 'Key prefix',
                hintText: 'LID01',
                helperText: 'Nodes are mapped as <prefix>.Score, '
                    '<prefix>.Threshold, …',
              ),
              onChanged: (v) => setState(() => config.keyPrefix = v.trim()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('lid-camera'),
              initialValue: config.camera,
              decoration: InputDecoration(
                labelText: 'Camera name in the database',
                hintText: config.keyPrefix.isEmpty ? 'same as prefix' : config.keyPrefix,
                helperText: 'Leave empty unless the service writes rows '
                    'under another name',
              ),
              onChanged: (v) => setState(() => config.camera = v.trim()),
            ),
            const SizedBox(height: 16),

            // -- Alarm --
            Text('Alarm', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'The tile pulses and announces in navigation for the alarms '
              'ticked here. "Create anomaly alarm" makes the standard one '
              'for this camera and ticks it.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('lid-create-alarm'),
              onPressed: config.keyPrefix.isEmpty ? null : _createAlarm,
              icon: const Icon(Icons.add_alert_outlined),
              label: const Text('Create anomaly alarm'),
            ),
            const SizedBox(height: 8),
            _alarmPicker(),
            SwitchListTile(
              title: const Text('Announce in navigation'),
              subtitle: Text(
                config.announceInNavigation
                    ? 'While an alarm here is active, this page\'s '
                        'navigation entry pulses'
                    : 'Alarms show on this page only',
              ),
              value: config.announceInNavigation,
              onChanged: (v) =>
                  setState(() => config.announceInNavigation = v),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 16),

            // -- Pane --
            Text('Pane', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            TextFormField(
              key: const Key('lid-recent-limit'),
              initialValue: config.recentLimit.toString(),
              decoration: const InputDecoration(
                labelText: 'Recent anomalies listed',
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) setState(() => config.recentLimit = n);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('lid-training-batch'),
              initialValue: config.trainingBatch.toString(),
              decoration: const InputDecoration(
                labelText: 'Good lids per "Collect" press',
                helperText: 'How many frames one press adds to the '
                    'training set',
              ),
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) {
                  setState(() => config.trainingBatch = n);
                }
              },
            ),
            const SizedBox(height: 16),

            // -- Label --
            TextFormField(
              initialValue: config.text,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'Shown on the tile and as the pane title',
              ),
              onChanged: (v) =>
                  setState(() => config.text = v.isEmpty ? null : v),
            ),
            const SizedBox(height: 16),
            Text('Label Position', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            DropdownButton<TextPos>(
              value: config.textPos ?? TextPos.below,
              isExpanded: true,
              onChanged: (value) => setState(() => config.textPos = value!),
              items: TextPos.values
                  .map((e) =>
                      DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                  .toList(),
            ),
            const SizedBox(height: 16),
            SizeField(
              initialValue: config.size,
              onChanged: (v) => setState(() => config.size = v),
            ),
            const SizedBox(height: 16),
            CoordinatesField(
              initialValue: config.coordinates,
              onChanged: (c) => setState(() => config.coordinates = c),
            ),
          ],
        ),
      ),
    );
  }
}
