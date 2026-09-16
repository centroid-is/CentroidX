import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart'
    show AlarmPulsePainter;
import 'package:tfc/page_creator/assets/lid_inspection.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/lid_inspection.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/lid_inspection.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/image_fixtures.dart';
import 'alarm_visibility_config_test.dart' show activeFx;

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<({String key, DynamicValue value})> writes = [];

  /// Keys whose subscribe throws, as an unmapped key does.
  final Set<String> refused = {};

  void push(String key, Object? value) => _streams
      .putIfAbsent(key, BehaviorSubject<DynamicValue>.new)
      .add(DynamicValue(value: value));

  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});

  @override
  String resolveKey(String key) => key;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (refused.contains(key)) throw StateError('No mapping for $key');
    return _streams.putIfAbsent(key, BehaviorSubject<DynamicValue>.new).stream;
  }

  @override
  Future<DynamicValue> read(String key) async {
    final s = _streams[key];
    if (s == null || !s.hasValue) throw StateError('No value for $key');
    return s.value;
  }

  @override
  Future<void> write(String key, DynamicValue value) async =>
      writes.add((key: key, value: value));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented');
}

class _FakeStore implements LidInspectionStore {
  _FakeStore({this.latestRecord, this.recentRecords = const [], this.bytes =
      const {}});

  LidInspectionRecord? latestRecord;
  List<LidInspectionRecord> recentRecords;
  Map<String, Uint8List> bytes;
  int latestCalls = 0;

  @override
  Future<LidInspectionRecord?> latest(String camera) async {
    latestCalls++;
    return latestRecord;
  }

  @override
  Future<List<LidInspectionRecord>> recent(String camera,
          {int limit = 10, bool anomaliesOnly = true}) async =>
      recentRecords.take(limit).toList();

  @override
  Future<Uint8List?> image(String id, {bool heatmap = false}) async =>
      bytes[heatmap ? '$id/heat' : id];
}

LidInspectionRecord _record(String id,
        {double score = 0.87, bool anomaly = true, bool hasImage = true}) =>
    LidInspectionRecord(
      id: id,
      camera: 'LID01',
      time: DateTime.utc(2026, 9, 15, 14, 30, 12),
      score: score,
      threshold: 0.62,
      anomaly: anomaly,
      armed: true,
      lidType: 'lid_40x30_a',
      modelVersion: 'patchcore_r18_2026-09-10',
      inferenceMs: 180,
      hasImage: hasImage,
    );

void main() {
  late _FakeStateMan sm;
  late LidInspectionConfig config;

  setUp(() {
    sm = _FakeStateMan();
    config = LidInspectionConfig(keyPrefix: 'LID01')..text = 'Lids';
  });
  tearDown(closeSidePane);

  Widget wrap(Widget child, {LidInspectionStore? store}) {
    return ProviderScope(
      overrides: [
        stateManProvider.overrideWith((_) async => sm),
        lidInspectionStoreProvider.overrideWith((_) async => store),
        collectorProvider.overrideWith((_) async => null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 110,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  void pushOk({double score = 0.31}) {
    sm.push('LID01.Score', score);
    sm.push('LID01.Threshold', 0.62);
    sm.push('LID01.Anomaly', false);
    sm.push('LID01.Armed', true);
    sm.push('LID01.CameraOk', true);
  }

  Future<void> settle(WidgetTester tester) async {
    // Subscriptions resolve over a couple of microtask turns; the tile has
    // no timers of its own while idle.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  group('Tile', () {
    testWidgets('connects, then reads OK with the score', (tester) async {
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      await settle(tester);
      expect(find.text('Connecting…'), findsOneWidget);

      pushOk();
      await settle(tester);
      expect(find.text('OK 0.31'), findsOneWidget);
      expect(find.text('Lids'), findsOneWidget);
      expect(find.byIcon(Icons.photo_camera), findsOneWidget);
    });

    testWidgets('an anomaly flips the caption and the icon', (tester) async {
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      pushOk();
      await settle(tester);

      sm.push('LID01.Score', 0.87);
      sm.push('LID01.Anomaly', true);
      await settle(tester);
      expect(find.text('ANOMALY 0.87'), findsOneWidget);
      expect(find.byIcon(Icons.report), findsOneWidget);

      sm.push('LID01.Armed', false);
      await settle(tester);
      expect(find.text('Shadow · anomaly 0.87'), findsOneWidget);
    });

    testWidgets('an unmapped Score key reads Unavailable', (tester) async {
      sm.refused.add('LID01.Score');
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      await settle(tester);
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('CameraOk false reads Camera offline', (tester) async {
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      pushOk();
      sm.push('LID01.CameraOk', false);
      await settle(tester);
      expect(find.text('Camera offline'), findsOneWidget);
    });

    testWidgets('the preview instance is static with sample figures',
        (tester) async {
      await tester.pumpWidget(
          wrap(LidInspectionTile(config: LidInspectionConfig.preview())));
      await settle(tester);
      expect(find.text('OK 0.31'), findsOneWidget);
      expect(sm._streams, isEmpty, reason: 'a preview never subscribes');
    });

    testWidgets('pulses at the corner only while a bound alarm is active',
        (tester) async {
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      pushOk();
      await settle(tester);
      Finder pulse() => find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is AlarmPulsePainter);
      expect(pulse(), findsNothing);

      final state = tester.state(find.byType(LidInspectionTile)) as dynamic;
      state.debugSet(active: [activeFx(uid: 'lid-anomaly:LID01')]);
      await tester.pump();
      expect(pulse(), findsOneWidget);

      state.debugSet(active: <Never>[]);
      await tester.pump();
      expect(pulse(), findsNothing);
    });

    testWidgets('tapping opens the pane, and it closes with the tile',
        (tester) async {
      await tester.pumpWidget(wrap(LidInspectionTile(config: config)));
      pushOk();
      await settle(tester);

      await tester.tap(find.byType(LidInspectionTile));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LidInspectionPaneView), findsOneWidget);
      expect(find.text('Lids'), findsWidgets);

      await tester.pumpWidget(wrap(const SizedBox()));
      await settle(tester);
      expect(find.byType(LidInspectionPaneView), findsNothing);
    });
  });

  group('Pane', () {
    Future<void> openPane(WidgetTester tester, {LidInspectionStore? store}) async {
      // The pane is taller than the default 800x600 test window; give it
      // room so every section is on screen and tappable without scrolling.
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          wrap(LidInspectionTile(config: config), store: store));
      pushOk();
      await settle(tester);
      await tester.tap(find.byType(LidInspectionTile));
      // The pane slides in; zero-duration pumps would leave it parked
      // off-screen at the animation's start. (pumpAndSettle cannot be used:
      // the trend tile's loader spins forever without a collector.)
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      // The store resolves and reloads over a few more turns.
      await settle(tester);
    }

    testWidgets('without a database it says pictures are unavailable',
        (tester) async {
      await openPane(tester);
      expect(find.textContaining('No station database'), findsOneWidget);
      expect(find.text('0.31'), findsOneWidget);
      // Threshold appears twice: the metric tile and the setpoint field.
      expect(find.text('0.62'), findsNWidgets(2));
    });

    testWidgets('shows the latest frame, its rows and the recent anomalies',
        (tester) async {
      final store = _FakeStore(
        latestRecord: _record('ev1'),
        recentRecords: [_record('ev1'), _record('ev0', score: 0.7)],
        bytes: {
          'ev1': fixtureJpegBytes,
          'ev1/heat': fixtureJpegBytes,
          'ev0': fixtureJpegBytes,
        },
      );
      await openPane(tester, store: store);

      expect(find.byKey(const Key('lid-frame-ev1')), findsOneWidget);
      expect(find.text('Anomaly'), findsWidgets);
      expect(find.text('180 ms'), findsOneWidget);
      expect(find.byKey(const Key('lid-recent-ev1')), findsOneWidget);
      expect(find.byKey(const Key('lid-recent-ev0')), findsOneWidget);
      expect(find.text('Score 0.70 · lid_40x30_a'), findsOneWidget);
    });

    testWidgets('an OK latest lid with no picture says so', (tester) async {
      final store = _FakeStore(
          latestRecord: _record('ok1', score: 0.2, anomaly: false, hasImage: false));
      await openPane(tester, store: store);
      expect(find.textContaining('no picture is kept for OK lids'),
          findsOneWidget);
      expect(find.text('No anomalies recorded.'), findsOneWidget);
    });

    testWidgets('a new LastId reloads the records', (tester) async {
      final store = _FakeStore(latestRecord: _record('ev1', hasImage: false));
      await openPane(tester, store: store);
      final before = store.latestCalls;
      expect(before, greaterThan(0));

      sm.push('LID01.LastId', 'ev2');
      await settle(tester);
      await settle(tester);
      expect(store.latestCalls, greaterThan(before));
    });

    testWidgets('a store that throws reports it, and names the table',
        (tester) async {
      await openPane(tester, store: _ThrowingStore());
      expect(find.textContaining('lid_inspection'), findsOneWidget);
    });

    testWidgets('manual buttons write the commands to <prefix>.Command',
        (tester) async {
      await openPane(tester);

      await tester.ensureVisible(find.byKey(const Key('lid-collect')));
      await tester.tap(find.byKey(const Key('lid-collect')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('lid-train')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('lid-reload')));
      await settle(tester);

      expect(sm.writes.map((w) => (w.key, w.value.value)), [
        ('LID01.Command', 'collect:20'),
        ('LID01.Command', 'train'),
        ('LID01.Command', 'reload'),
      ]);
    });

    testWidgets('the Armed switch writes <prefix>.Armed', (tester) async {
      await openPane(tester);
      await tester.ensureVisible(find.byKey(const Key('lid-armed')));
      await tester.tap(find.byKey(const Key('lid-armed')));
      await settle(tester);
      expect(sm.writes.map((w) => (w.key, w.value.value)),
          [('LID01.Armed', false)]);
    });

    testWidgets('submitting the threshold writes <prefix>.Threshold',
        (tester) async {
      await openPane(tester);
      final field = find.byKey(const Key('lid-threshold'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '0.7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(sm.writes.map((w) => (w.key, w.value.value)),
          [('LID01.Threshold', 0.7)]);
    });

    testWidgets('a threshold outside 0..1 is not written', (tester) async {
      await openPane(tester);
      final field = find.byKey(const Key('lid-threshold'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(sm.writes, isEmpty);
    });
  });

  group('LidLiveTracker', () {
    test('folds values per node and records a refused node without '
        'losing the others', () async {
      final subjects = <String, BehaviorSubject<DynamicValue>>{};
      final tracker = LidLiveTracker(
        keyFor: (n) => n.keyFor('LID01'),
        subscribe: (key) async {
          if (key == 'LID01.GoodSamples') throw StateError('unmapped');
          return subjects
              .putIfAbsent(key, BehaviorSubject<DynamicValue>.new)
              .stream;
        },
      );
      tracker.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      subjects['LID01.Score']!.add(DynamicValue(value: 0.5));
      subjects['LID01.Anomaly']!.add(DynamicValue(value: false));
      await Future<void>.delayed(Duration.zero);

      final live = tracker.current;
      expect(live.score, 0.5);
      expect(live.anomaly, isFalse);
      expect(live.errors.keys, [LidNode.goodSamples]);
      expect(live.errors[LidNode.goodSamples], contains('unmapped'));
      expect(subjects.containsKey('LID01.Command'), isFalse,
          reason: 'Command is write-only and never subscribed');

      await tracker.dispose();
      expect(subjects.values.every((s) => !s.hasListener), isTrue);
    });
  });
}

class _ThrowingStore implements LidInspectionStore {
  @override
  Future<LidInspectionRecord?> latest(String camera) async =>
      throw Exception('relation "lid_inspection" does not exist');

  @override
  Future<List<LidInspectionRecord>> recent(String camera,
          {int limit = 10, bool anomaliesOnly = true}) async =>
      throw Exception('relation "lid_inspection" does not exist');

  @override
  Future<Uint8List?> image(String id, {bool heatmap = false}) async => null;
}
