/// Sensors riding a wagon: where they sit on its belt, that they move with
/// it, and that a tap on one opens that sensor rather than the conveyor.
///
/// A wagon carries one or two of these — the photo eyes that see a pallet at
/// an end of its belt — so they are configured on the conveyor and drawn
/// inside its box. A sensor dropped on the page as its own asset would stay
/// put while the wagon drove away from it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

const _size = Size(600, 160);
const _frontKey = 'line1.wagon1.eyeFront';
const _backKey = 'line1.wagon1.eyeBack';
const _beltKey = 'line1.wagon1.belt';

ConveyorPainter _painter({
  required List<WagonSensorEntry> sensors,
  double wagonPosition = 0.5,
  bool across = true,
  bool reverse = false,
}) =>
    ConveyorPainter(
      color: Colors.green,
      batches: const {},
      angle: 0,
      paintSize: _size,
      onRails: true,
      railInk: Colors.black,
      wagonPosition: wagonPosition,
      wagonFraction: 0.2,
      wagonBeltAcross: across,
      reverseDirection: reverse,
    );

class _SensorStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      Stream<DynamicValue>.value(DynamicValue(value: key == _frontKey));

  @override
  String resolveKey(String key) => key;

  // The sensor pane asks what is being collected on the key, to decide
  // whether it may offer a trend. Nothing is, here.
  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});
}

void main() {
  group('placement', () {
    WagonSensorEntry entry(WagonSensorEnd end, String key) =>
        WagonSensorEntry(end: end, sensor: SensorConfig(detectionKey: key));

    test('front sits at the end the belt runs towards, back at the other', () {
      final painter = _painter(sensors: []);
      final belt = painter.beltRect(_size);
      final front = painter.wagonSensorRect(_size, WagonSensorEnd.front);
      final back = painter.wagonSensorRect(_size, WagonSensorEnd.back);
      // Belt across the rails: travel runs down the screen.
      expect(front.center.dy, greaterThan(belt.center.dy));
      expect(back.center.dy, lessThan(belt.center.dy));
      for (final r in [front, back]) {
        expect(belt.contains(r.center), isTrue,
            reason: 'a sensor sits on the belt, not beside it');
        expect(r.width, closeTo(r.height, 0.01), reason: 'square glyph');
      }
    });

    test('a reversed belt swaps the two ends', () {
      final painter = _painter(sensors: [], reverse: true);
      expect(painter.wagonSensorRect(_size, WagonSensorEnd.front).center.dy,
          lessThan(painter.beltRect(_size).center.dy));
    });

    test('along the rails the ends are left and right', () {
      final painter = _painter(sensors: [], across: false);
      final belt = painter.beltRect(_size);
      expect(painter.wagonSensorRect(_size, WagonSensorEnd.front).center.dx,
          greaterThan(belt.center.dx));
      expect(painter.wagonSensorRect(_size, WagonSensorEnd.back).center.dx,
          lessThan(belt.center.dx));
    });

    test('two at one end stand side by side without overlapping', () {
      final painter = _painter(sensors: []);
      final a = painter.wagonSensorRect(_size, WagonSensorEnd.front,
          slot: 0, count: 2);
      final b = painter.wagonSensorRect(_size, WagonSensorEnd.front,
          slot: 1, count: 2);
      expect(a.overlaps(b), isFalse);
      expect(a.center.dy, closeTo(b.center.dy, 0.01));
      expect((a.center.dx + b.center.dx) / 2,
          closeTo(painter.beltRect(_size).center.dx, 0.01));
    });

    test('a sensor rides the wagon along the rail', () {
      final left = _painter(sensors: [], wagonPosition: 0)
          .wagonSensorRect(_size, WagonSensorEnd.front);
      final right = _painter(sensors: [], wagonPosition: 1)
          .wagonSensorRect(_size, WagonSensorEnd.front);
      expect(right.center.dx, greaterThan(left.center.dx + _size.width / 2));
    });

    test('the config carries them, at most two, nested in its own JSON', () {
      final config = ConveyorConfig(onRails: true, wagonSensors: [
        entry(WagonSensorEnd.front, _frontKey),
        entry(WagonSensorEnd.back, _backKey),
      ]);
      final back = ConveyorConfig.fromJson(config.toJson());
      expect(back.wagonSensors, hasLength(2));
      expect(back.wagonSensors.first.end, WagonSensorEnd.front);
      expect(back.wagonSensors.first.sensor.detectionKey, _frontKey);
      expect(back.wagonSensors.last.end, WagonSensorEnd.back);
      expect(ConveyorConfig.maxWagonSensors, 2);

      // Pages saved before the field existed.
      expect(
          ConveyorConfig.fromJson(
              ConveyorConfig().toJson()..remove('wagonSensors'))
              .wagonSensors,
          isEmpty);
    });

    test('their keys are the conveyor\'s keys', () {
      // A key nobody reports using is one the unused-key cleanup offers to
      // delete, and a sensor's key lives where the top-level scan cannot see
      // it.
      final config = ConveyorConfig(
          key: _beltKey,
          onRails: true,
          wagonSensors: [entry(WagonSensorEnd.front, _frontKey)]);
      expect(config.allKeys, containsAll([_beltKey, _frontKey]));
    });

    test('they are child assets while the wagon is drawn, and not otherwise',
        () {
      final sensors = [entry(WagonSensorEnd.front, _frontKey)];
      expect(
          ConveyorConfig(onRails: true, wagonSensors: sensors).childAssets,
          hasLength(1));
      // No rails, no wagon, nothing drawn to open a pane from.
      expect(ConveyorConfig(wagonSensors: sensors).childAssets, isEmpty);
    });
  });

  group('on the page', () {
    /// The painter actually drawn, and where its box sits on screen. The
    /// asset's own size resolves against the test window, so the painted box
    /// is not the SizedBox above it.
    Future<({ConveyorPainter painter, Offset origin})> pumpWagon(
        WidgetTester tester, List<WagonSensorEntry> sensors) async {
      final config = ConveyorConfig(
        key: _beltKey,
        onRails: true,
        wagonLength: 0.2,
        wagonSensors: sensors,
      )..size = const RelativeSize(width: 0.5, height: 0.5);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith((ref) async => _SensorStateMan()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                  width: _size.width,
                  height: _size.height,
                  child: Conveyor(config)),
            ),
          ),
        ),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      final paint = find
          .descendant(
              of: find.byType(Conveyor), matching: find.byType(CustomPaint))
          .first;
      return (
        painter: tester.widget<CustomPaint>(paint).painter! as ConveyorPainter,
        origin: tester.getTopLeft(paint),
      );
    }

    testWidgets('both sensors are drawn on the wagon', (tester) async {
      await pumpWagon(tester, [
        WagonSensorEntry(
            end: WagonSensorEnd.front,
            sensor: SensorConfig(detectionKey: _frontKey, tag: 'Eye front')),
        WagonSensorEntry(
            end: WagonSensorEnd.back,
            sensor: SensorConfig(detectionKey: _backKey, tag: 'Eye back')),
      ]);
      expect(find.byType(Sensor), findsNWidgets(2));
    });

    testWidgets('tapping one opens that sensor, not the conveyor',
        (tester) async {
      addTearDown(() => closeSidePane(immediate: true));
      final wagon = await pumpWagon(tester, [
        WagonSensorEntry(
            end: WagonSensorEnd.front,
            sensor: SensorConfig(detectionKey: _frontKey, tag: 'Eye front')),
      ]);
      final rect = wagon.painter
          .wagonSensorRect(wagon.painter.paintSize!, WagonSensorEnd.front);
      await tester.tapAt(wagon.origin + rect.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.text('Eye front'), findsWidgets);
      expect(find.text('Wagon drive'), findsNothing);
    });

    testWidgets('a sensor is drawn only while the wagon is', (tester) async {
      await pumpWagon(tester, const []);
      expect(find.byType(Sensor), findsNothing);
    });
  });
  testWidgets('the ring marks the sensor, not the whole conveyor',
      (tester) async {
    // The sensors are the conveyor's child assets, each in its own
    // SubdeviceSubject, the way a rack's slices are: the plant view rings the
    // one whose pane is open.
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    addTearDown(() => closeSidePane(immediate: true));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final config = ConveyorConfig(
      key: _beltKey,
      onRails: true,
      wagonLength: 0.2,
      wagonSensors: [
        WagonSensorEntry(
            end: WagonSensorEnd.front,
            sensor: SensorConfig(detectionKey: _frontKey, tag: 'Eye front')),
      ],
    )
      ..coordinates = Coordinates(x: 0.3, y: 0.4)
      ..size = const RelativeSize(width: 0.5, height: 0.3);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        collectorProvider.overrideWith((ref) async => null),
        stateManProvider.overrideWith((ref) async => _SensorStateMan()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [config],
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              absorb: false,
            ),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    final glyph = tester.getRect(find.byType(Sensor));
    await tester.tapAt(glyph.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));

    final paint = tester.widget<CustomPaint>(find.byKey(openPaneMarkKey));
    final origin = tester.getTopLeft(find.byKey(openPaneMarkKey));
    var bounds = Rect.fromLTRB(double.infinity, double.infinity,
        double.negativeInfinity, double.negativeInfinity);
    for (final ring in (paint.painter! as HitBoundaryPainter).contours) {
      for (final local in ring) {
        bounds = bounds.expandToInclude(
            Rect.fromCircle(center: local + origin, radius: 0));
      }
    }
    final air = HitBoundaryStyle.selection.standoff * 2;
    expect(bounds.center.dx, closeTo(glyph.center.dx, 2));
    expect(bounds.center.dy, closeTo(glyph.center.dy, 2));
    expect(bounds.width, closeTo(glyph.width + air, 3),
        reason: 'the ring is the sensor, not the conveyor');
  });
}
