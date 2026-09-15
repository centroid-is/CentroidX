import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/lid_inspection.dart';
import 'package:tfc/providers/alarm.dart' show alarmManProvider;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/lid_inspection.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import 'alarm_visibility_config_test.dart' show activeFx;

const _boundary = Key('lid_inspection_golden');

// ── Fixtures ────────────────────────────────────────────────────────────────

/// A synthetic inspected lid: a light lid on a grey belt with a printed band
/// and a dark scratch; with [heat], a red blob over the scratch as a model's
/// heat-map overlay would show. Drawn, not loaded, so the golden has a
/// picture that reads as a picture without a binary fixture in the repo.
Future<Uint8List> _lidPng({required bool heat}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const w = 320.0, h = 240.0;
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF6E7A86));
  canvas.drawRRect(
    RRect.fromRectAndRadius(
        const Rect.fromLTWH(24, 20, 272, 200), const Radius.circular(14)),
    Paint()..color = const Color(0xFFE8ECEF),
  );
  canvas.drawRect(const Rect.fromLTWH(48, 60, 224, 30),
      Paint()..color = const Color(0xFF3B5B7A));
  canvas.drawLine(
    const Offset(180, 120),
    const Offset(250, 190),
    Paint()
      ..color = const Color(0xFF2B2B2B)
      ..strokeWidth = 4,
  );
  if (heat) {
    canvas.drawCircle(
      const Offset(215, 155),
      70,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(215, 155),
          70,
          const [Color(0xCCFF3B30), Color(0x00FF3B30)],
        ),
    );
  }
  final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

LidInspectionRecord _record(String id,
        {double score = 0.87,
        bool anomaly = true,
        bool armed = true,
        bool hasImage = true,
        int minute = 30}) =>
    LidInspectionRecord(
      id: id,
      camera: 'LID01',
      time: DateTime.utc(2026, 9, 15, 14, minute, 12),
      score: score,
      threshold: 0.62,
      anomaly: anomaly,
      armed: armed,
      lidType: 'lid_40x30_a',
      modelVersion: 'patchcore_r18_2026-09-10',
      inferenceMs: 180,
      hasImage: hasImage,
    );

/// A StateMan that never emits: the tiles are driven through `debugSet`.
class _SilentStateMan implements StateMan {
  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});
  @override
  String resolveKey(String key) => key;
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      BehaviorSubject<DynamicValue>().stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PickerAlarmMan implements AlarmMan {
  _PickerAlarmMan(List<AlarmConfig> configs)
      : alarms = configs.map((c) => Alarm(config: c)).toSet();

  @override
  final Set<Alarm> alarms;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _scaffold(Widget child,
    {bool dark = false, List<Override> overrides = const []}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: RepaintBoundary(
            key: _boundary,
            // A Material, not a ColoredBox: the pane's ListTiles paint on
            // the nearest Material and assert when a coloured box hides it.
            child: Material(
              color: theme.colorScheme.surface,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

// ── Tile filmstrip ──────────────────────────────────────────────────────────

const _tileStates = ['ok', 'anomaly', 'shadow', 'offline', 'unavailable'];

LidInspectionLive _liveFor(String name) => switch (name) {
      'ok' => LidInspectionLive.sample(),
      'anomaly' => LidInspectionLive.sample(anomaly: true),
      'shadow' => LidInspectionLive.sample(anomaly: true, armed: false),
      'offline' => LidInspectionLive.sample().withValue(
          LidNode.cameraOk, DynamicValue(value: false)),
      'unavailable' => const LidInspectionLive(
          errors: {LidNode.score: 'No mapping for LID01.Score'}),
      _ => throw ArgumentError(name),
    };

Widget _filmstrip({bool dark = false}) {
  return _scaffold(
    dark: dark,
    overrides: [
      stateManProvider.overrideWith((_) async => _SilentStateMan()),
    ],
    Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final name in _tileStates) ...[
            SizedBox(
              width: 150,
              height: 100,
              child: LidInspectionTile(
                key: Key('tile-$name'),
                config: LidInspectionConfig(keyPrefix: 'LID01')
                  ..text = 'Lid camera',
              ),
            ),
            const SizedBox(width: 16),
          ],
          SizedBox(
            width: 150,
            height: 100,
            child: LidInspectionTile(
              key: const Key('tile-alarm'),
              config: LidInspectionConfig(
                  keyPrefix: 'LID01', alarmUids: ['lid-anomaly:LID01'])
                ..text = 'Lid camera',
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _driveFilmstrip(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  for (final name in _tileStates) {
    final state = tester.state(find.byKey(Key('tile-$name'))) as dynamic;
    state.debugSet(live: _liveFor(name));
  }
  final alarmTile = tester.state(find.byKey(const Key('tile-alarm'))) as dynamic;
  alarmTile.debugSet(
    live: _liveFor('anomaly'),
    active: [activeFx(uid: 'lid-anomaly:LID01')],
  );
  // The pulse repeats every 1800 ms; 630 ms in is progress 0.35, the same
  // phase the beacon's previews freeze at.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 630));
}

// ── Pane ────────────────────────────────────────────────────────────────────

Widget _pane(LidInspectionPaneView view,
    {required double height, bool dark = false}) {
  return _scaffold(
    dark: dark,
    SizedBox(width: 380, height: height, child: view),
  );
}

void main() {
  setUpAll(loadGoldenFonts);

  group('Lid inspection goldens', skip: goldenSkip, () {
    testWidgets('tiles: every verdict, and the alarm pulse', (tester) async {
      tester.view.physicalSize = const Size(1100, 160);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_filmstrip());
      await _driveFilmstrip(tester);
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_tiles.png'));
    });

    testWidgets('tiles on the dark theme', (tester) async {
      tester.view.physicalSize = const Size(1100, 160);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_filmstrip(dark: true));
      await _driveFilmstrip(tester);
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_tiles_dark.png'));
    });

    testWidgets('pane: anomaly with picture, alarm card, recent list',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Uint8List frame;
      late Uint8List heat;
      await tester.runAsync(() async {
        frame = await _lidPng(heat: false);
        heat = await _lidPng(heat: true);
      });

      final config = LidInspectionConfig(
          keyPrefix: 'LID01', alarmUids: ['lid-anomaly:LID01'])
        ..text = 'Lid camera';
      final view = LidInspectionPaneView(
        config: config,
        live: LidInspectionLive.sample(anomaly: true)
            .withValue(LidNode.secondsSinceLast, DynamicValue(value: 4)),
        active: [
          activeFx(
            uid: 'lid-anomaly:LID01',
            title: 'Lid camera: lid anomaly',
            description: 'Camera LID01 scored a lid at or above its '
                'threshold while armed.',
            timestamp: DateTime.utc(2026, 9, 15, 14, 30, 12),
          ),
        ],
        latest: _record('ev3'),
        latestImage: frame,
        latestHeatmap: heat,
        recent: [
          _record('ev3'),
          _record('ev2', score: 0.71, minute: 12),
          _record('ev1', score: 0.66, armed: false, minute: 2, hasImage: false),
        ],
        thumbnail: (id) async => frame,
        heatmapOf: (id) async => heat,
        onArmed: (_) {},
        onCommand: (_) {},
        onThreshold: (_) {},
      );

      await tester.pumpWidget(_pane(view, height: 1600));
      await tester.pump();
      // Raster decode runs through real async engine work.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_pane.png'));
    });

    testWidgets('pane: shadow mode, no database, nothing recorded',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final view = LidInspectionPaneView(
        config: LidInspectionConfig(keyPrefix: 'LID01')..text = 'Lid camera',
        live: LidInspectionLive.sample(armed: false)
            .withValue(LidNode.trainingState, DynamicValue(value: 'collecting'))
            .withValue(LidNode.goodSamples, DynamicValue(value: 37)),
        storeMessage: 'No station database — pictures are not available here.',
        onArmed: (_) {},
        onCommand: (_) {},
        onThreshold: (_) {},
      );
      await tester.pumpWidget(_pane(view, height: 980, dark: true));
      await tester.pump();
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_pane_shadow_dark.png'));
    });

    testWidgets('viewer: frame with the heat-map toggle', (tester) async {
      tester.view.physicalSize = const Size(640, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Uint8List frame;
      late Uint8List heat;
      await tester.runAsync(() async {
        frame = await _lidPng(heat: false);
        heat = await _lidPng(heat: true);
      });
      await tester.pumpWidget(_scaffold(
        SizedBox(
          width: 600,
          height: 480,
          child: InspectionViewer(image: frame, heatmap: heat),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('Heat-map'));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_viewer_heatmap.png'));
    });

    testWidgets('configure form, with the setup help open', (tester) async {
      tester.view.physicalSize = const Size(420, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final config = LidInspectionConfig(
          keyPrefix: 'LID01', alarmUids: ['lid-anomaly:LID01'])
        ..text = 'Lid camera';
      final alarm = lidAnomalyAlarmConfig(config);
      await tester.pumpWidget(_scaffold(
        overrides: [
          alarmManProvider.overrideWith((ref) async => _PickerAlarmMan([
                alarm,
                AlarmConfig(
                  uid: 'cn3',
                  title: 'CN03 motor fault',
                  description: 'Drive tripped',
                  rules: alarm.rules,
                ),
              ])),
        ],
        SizedBox(
          width: 380,
          height: 2560,
          child: Builder(builder: config.configure),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('lid-setup-help')));
      await tester.pump();
      await expectLater(find.byKey(_boundary),
          matchesGoldenFile('goldens/lid_inspection_editor_help.png'));
    });
  });
}
