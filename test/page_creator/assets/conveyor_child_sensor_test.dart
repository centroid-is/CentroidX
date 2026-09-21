/// Sensors bolted along a conveyor's belt: where they sit, that they stand
/// beside the band rather than on it, that they ride a wagon, and that a tap
/// on one opens that sensor rather than the conveyor.
///
/// Placement is the gates': a fraction along the belt, and which of its two
/// edges. A photo eye is bolted to a bracket beside the belt and looks
/// across it — it is not lying on the belt, which is where these were drawn
/// when they were a wagon's own "front and back" sensors.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart' show GateSide;
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/test_helpers.dart'
    show createTestPreferences, useInMemoryDeviceLocalPreferences;

const _size = Size(600, 160);
const _eyeKey = 'line1.conv1.eyeIn';
const _otherKey = 'line1.conv1.eyeOut';
const _beltKey = 'line1.conv1.belt';

ConveyorPainter _painter({
  bool onRails = false,
  bool across = true,
  bool reverse = false,
  double wagonPosition = 0.5,
  double? beltWidth,
  ConveyorPathGeometry? geometry,
}) =>
    ConveyorPainter(
      color: Colors.green,
      batches: const {},
      angle: 0,
      paintSize: _size,
      onRails: onRails,
      railInk: Colors.black,
      wagonPosition: wagonPosition,
      wagonFraction: 0.2,
      wagonBeltAcross: across,
      reverseDirection: reverse,
      straightBeltWidth: beltWidth,
      geometry: geometry,
    );

ChildSensorEntry _entry(String key,
        {double position = 0.5, GateSide side = GateSide.left}) =>
    ChildSensorEntry(
        position: position,
        side: side,
        sensor: SensorConfig(detectionKey: key));

class _SensorStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      Stream<DynamicValue>.value(DynamicValue(value: key == _eyeKey));

  @override
  String resolveKey(String key) => key;

  // The sensor pane asks what is being collected on the key, to decide
  // whether it may offer a trend. Nothing is, here.
  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});
}

/// A single housing, looking out from the edge it is bolted to.
({Rect rect, double facing}) _housing(ConveyorPainter painter,
        {double position = 0.5, GateSide side = GateSide.left}) =>
    painter.sensorMount(_size,
        position: position, side: side, kind: SensorKind.opticField);

/// A through-beam pair: a sender on one edge of the band, a receiver on the
/// other.
({Rect rect, double facing}) _pair(ConveyorPainter painter,
        {double position = 0.5, GateSide side = GateSide.left}) =>
    painter.sensorMount(_size,
        position: position, side: side, kind: SensorKind.redLight);

/// Where [mount] actually lands on screen: its box is the glyph's own, turned
/// about its centre by `facing`, so a quarter turn swaps the two axes.
Rect _onScreen(({Rect rect, double facing}) mount) {
  final quarterTurned = (cos(mount.facing)).abs() < 0.5;
  return Rect.fromCenter(
      center: mount.rect.center,
      width: quarterTurned ? mount.rect.height : mount.rect.width,
      height: quarterTurned ? mount.rect.width : mount.rect.height);
}

void main() {
  group('a through-beam pair', () {
    // A photo eye of this kind is two devices: the sender is bolted to one
    // side of the conveyor and the receiver to the other, and the beam
    // crosses the belt between them. So the glyph straddles the band — it
    // neither lies on the belt nor stands to one side of it.
    test('straddles the band, a housing on each edge', () {
      final painter = _painter(beltWidth: 40);
      final belt = painter.beltRect(_size);
      final mount = _pair(painter, position: 0.4);
      final drawn = _onScreen(mount);

      expect(mount.rect.center.dy, closeTo(belt.center.dy, 1e-9),
          reason: 'centred on the band, not off one edge');
      expect(drawn.top, lessThan(belt.top));
      expect(drawn.bottom, greaterThan(belt.bottom));
      // RedLightBeamPainter puts the housings at 0.15 and 0.85 of the glyph,
      // which this box lands on the band's two edges.
      final housings = mount.rect.width * 0.7;
      expect(housings, closeTo(belt.height, belt.height * 0.05));
      expect(mount.rect.center.dx, closeTo(belt.left + 0.4 * belt.width, 1e-9));
    });

    test('the side picks the edge that sends', () {
      // Both housings are painted alike, so this is which end of the glyph —
      // the sender is its 0.15 end — lands on which edge.
      final painter = _painter(beltWidth: 40);
      expect(_pair(painter, side: GateSide.left).facing, closeTo(pi / 2, 1e-9));
      expect(
          _pair(painter, side: GateSide.right).facing, closeTo(-pi / 2, 1e-9));
    });

    test('spans a wagon belt across its rails, and rides it', () {
      final painter = _painter(onRails: true);
      final belt = painter.beltRect(_size);
      final mount = _pair(painter);
      final drawn = _onScreen(mount);

      expect(drawn.left, lessThan(belt.left));
      expect(drawn.right, greaterThan(belt.right));
      expect(mount.facing, closeTo(0.0, 1e-9), reason: 'the beam reads +x');
      double at(double wagon) =>
          _pair(_painter(onRails: true, wagonPosition: wagon)).rect.center.dx;
      expect(at(1), greaterThan(at(0) + _size.width / 2));
    });

    test('on a belt that fills its box the beam still spans the belt', () {
      // The box the pair needs is wider than the band, and the margin either
      // side of the beam carries no ink, so it is left hanging outside the
      // asset's box rather than squeezed onto the belt.
      final painter = _painter();
      final belt = painter.beltRect(_size);
      final drawn = _onScreen(_pair(painter));
      expect(belt, Offset.zero & _size, reason: 'the belt is the whole box');
      expect(drawn.top, lessThan(belt.top));
      expect(drawn.bottom, greaterThan(belt.bottom));
    });

    test('straddles a turned band too, across its centreline', () {
      final geometry = ConveyorPathGeometry.build(
          [ConveyorTurnEntry(position: 0.5, angle: 90)], _size,
          beltWidthOverride: 24);
      final painter = _painter(geometry: geometry!);
      final tangent = geometry.tangentAt(0.25);
      final mount = painter.sensorMount(_size,
          position: 0.25, side: GateSide.left, kind: SensorKind.redLight);

      expect((mount.rect.center - tangent.position).distance, lessThan(1e-6),
          reason: 'on the centreline, straddling it');
      expect(mount.rect.width * 0.7,
          closeTo(geometry.beltWidth, geometry.beltWidth * 0.05));
    });
  });

  group('a single housing', () {
    test('stands off the band edge, its cone over the belt', () {
      final painter = _painter(beltWidth: 40);
      final belt = painter.beltRect(_size);
      final top = _housing(painter);

      expect(top.rect.center.dy, lessThan(belt.top),
          reason: 'a housing is beside the belt, not on it');
      expect(top.rect.bottom, greaterThan(belt.top),
          reason: 'but it looks over the edge, so the cone crosses it');
      expect(top.rect.width, closeTo(top.rect.height, 1e-9),
          reason: 'square, like a gate');
      expect(top.rect.center.dx, closeTo(belt.center.dx, 1e-9));
    });

    test('the other side is the other edge, and each faces the belt', () {
      final painter = _painter(beltWidth: 40);
      final belt = painter.beltRect(_size);
      final top = _housing(painter);
      final bottom = _housing(painter, side: GateSide.right);

      expect(bottom.rect.center.dy, greaterThan(belt.bottom));
      expect(bottom.rect.top, lessThan(belt.bottom));
      // The glyph looks along its own +x: down the screen from the top edge,
      // up it from the bottom one.
      expect(top.facing, closeTo(pi / 2, 1e-9));
      expect(bottom.facing, closeTo(-pi / 2, 1e-9));
    });

    test('position slides it along the belt', () {
      final painter = _painter(beltWidth: 40);
      final belt = painter.beltRect(_size);
      Rect at(double p) => _housing(painter, position: p).rect;
      expect(at(0.25).center.dx, lessThan(at(0.75).center.dx));
      expect(at(0.25).center.dx, closeTo(belt.left + 0.25 * belt.width, 1e-9));
      // At the very end the glyph is pulled back into the box rather than
      // hanging half out of it, and out-of-range values clamp.
      expect(at(1.0).right, closeTo(_size.width, 1e-9));
      expect(at(1.4), at(1.0));
      expect(at(-0.2).left, closeTo(0, 1e-9));
    });

    test('a belt that fills its box keeps the glyph inside the box', () {
      // No air beside the band to stand in: the housing hugs the belt's edge
      // rather than hanging outside the box, where it would be clipped and
      // answer no tap.
      final painter = _painter();
      final belt = painter.beltRect(_size);
      final mount = _housing(painter);
      expect(belt, Offset.zero & _size, reason: 'the belt is the whole box');
      expect(mount.rect.top, closeTo(0, 1e-9));
      expect((Offset.zero & _size).contains(mount.rect.bottomRight), isTrue);
      expect(mount.rect.center.dy, lessThan(belt.center.dy),
          reason: 'still at the edge it is bolted to');
    });

    test('reversing the belt does not move it', () {
      // The bracket is bolted where it is bolted. Unlike a wagon's dock
      // "front", this placement is the picture on screen, not the running
      // direction.
      final forward = _housing(_painter(beltWidth: 40), position: 0.2);
      final reversed =
          _housing(_painter(beltWidth: 40, reverse: true), position: 0.2);
      expect(reversed.rect, forward.rect);
      expect(reversed.facing, forward.facing);
    });

    test('across the rails the edges are left and right, and travel is down',
        () {
      final painter = _painter(onRails: true);
      final belt = painter.beltRect(_size);
      final left = _housing(painter, position: 0.9);
      final right = _housing(painter, position: 0.9, side: GateSide.right);

      expect(left.rect.center.dx, lessThan(belt.left));
      expect(right.rect.center.dx, greaterThan(belt.right));
      expect(left.facing, closeTo(0.0, 1e-9), reason: 'it looks rightwards');
      expect(right.facing, closeTo(pi, 1e-9));
      // Position runs down the screen: 0.9 is near the bottom end, and near
      // enough that the glyph is pulled back inside the box.
      expect(left.rect.bottom, closeTo(_size.height, 1e-9));
      expect(_housing(painter, position: 0.25).rect.center.dy,
          closeTo(belt.top + 0.25 * belt.height, 1e-9));
    });

    test('along the rails the edges are top and bottom again', () {
      final painter = _painter(onRails: true, across: false, beltWidth: 40);
      final belt = painter.beltRect(_size);
      final mount = _housing(painter);
      expect(mount.rect.center.dy, lessThan(belt.top));
      expect(mount.rect.center.dx, closeTo(belt.center.dx, 1e-9));
      expect(mount.facing, closeTo(pi / 2, 1e-9));
    });

    test('rides the wagon along the rail', () {
      double at(double wagon) =>
          _housing(_painter(onRails: true, wagonPosition: wagon))
              .rect
              .center
              .dx;
      expect(at(1), greaterThan(at(0) + _size.width / 2));
    });

    test('a turned belt puts it beside the centreline, facing in', () {
      // A band narrower than the box, so there is air beside it to stand in.
      final geometry = ConveyorPathGeometry.build(
          [ConveyorTurnEntry(position: 0.5, angle: 90)], _size,
          beltWidthOverride: 24);
      final painter = _painter(geometry: geometry!);
      final tangent = geometry.tangentAt(0.25);
      // Inside the bend, where the box leaves room: a turned belt is fitted
      // to its box, so the outside of a bend is up against the box edge.
      final mount = _housing(painter, position: 0.25, side: GateSide.right);

      final offset = mount.rect.center - tangent.position;
      expect(offset.distance, greaterThan(geometry.beltWidth / 2),
          reason: 'clear of the band');
      // Facing is the way back to the centreline it stepped out from.
      final home = mount.rect.center +
          Offset(cos(mount.facing), sin(mount.facing)) * offset.distance;
      expect((home - tangent.position).distance, lessThan(1e-6));
    });
  });

  group('the config', () {
    test('carries them nested in its own JSON, place and all', () {
      final config = ConveyorConfig(sensors: [
        _entry(_eyeKey, position: 0.25),
        _entry(_otherKey, position: 0.8, side: GateSide.right),
      ]);
      final back = ConveyorConfig.fromJson(config.toJson());

      expect(back.sensors, hasLength(2));
      expect(back.sensors.first.position, 0.25);
      expect(back.sensors.first.side, GateSide.left);
      expect(back.sensors.first.sensor.detectionKey, _eyeKey);
      expect(back.sensors.last.position, 0.8);
      expect(back.sensors.last.side, GateSide.right);

      // Pages saved before the field existed.
      expect(
          ConveyorConfig.fromJson(ConveyorConfig().toJson()..remove('sensors'))
              .sensors,
          isEmpty);
    });

    test('their keys are the conveyor\'s keys', () {
      // A key nobody reports using is one the unused-key cleanup offers to
      // delete, and a sensor's key lives where the top-level scan cannot see
      // it.
      final config =
          ConveyorConfig(key: _beltKey, sensors: [_entry(_eyeKey)]);
      expect(config.allKeys, containsAll([_beltKey, _eyeKey]));
    });

    test('each is a child asset, rails or no rails', () {
      // Each sits in its own SubdeviceSubject, so the plant view rings the
      // sensor whose pane is open rather than the whole belt.
      expect(ConveyorConfig(sensors: [_entry(_eyeKey)]).childAssets,
          hasLength(1));
      expect(
          ConveyorConfig(onRails: true, sensors: [_entry(_eyeKey)]).childAssets,
          hasLength(1));
      expect(ConveyorConfig().childAssets, isEmpty);
    });
  });

  group('the editor', () {
    /// The conveyor's own settings form, the way the page editor shows it.
    Widget wrap(ConveyorConfig config) => ProviderScope(
          overrides: [
            preferencesProvider.overrideWith((ref) => createTestPreferences()),
            databaseProvider.overrideWith((ref) async => null),
            stateManProvider.overrideWith(
                (ref) => throw StateError('No StateMan in tests')),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(builder: (context) => config.configure(context)),
            ),
          ),
        );

    /// The panel is a fixed-width column and the test font is far wider per
    /// glyph than the real one, so its rows overflow here and nowhere else.
    void ignoreTestFontOverflow() {
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
          return;
        }
        original?.call(details);
      };
      addTearDown(() => FlutterError.onError = original);
    }

    Future<void> openForm(WidgetTester tester, ConveyorConfig config) async {
      ignoreTestFontOverflow();
      tester.view.physicalSize = const Size(1400, 6000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(config));
      await tester.pump();
    }

    testWidgets('adding one gives it a place on the belt to move',
        (tester) async {
      final config = ConveyorConfig(key: _beltKey);
      await openForm(tester, config);

      expect(find.text('No sensors configured'), findsOneWidget);
      await tester.tap(find.byKey(const Key('conveyor_add_sensor')));
      await tester.pump();

      expect(config.sensors, hasLength(1));
      expect(config.sensors.single.position, 0.5);
      expect(config.sensors.single.side, GateSide.left);
      // The same two controls a gate gets: which edge, and where along.
      expect(find.text('Top'), findsOneWidget);
      expect(find.text('Bottom'), findsOneWidget);
      expect(find.byTooltip('Remove sensor'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove sensor'));
      await tester.pump();
      expect(config.sensors, isEmpty);
    });

    testWidgets('a wagon belt across its rails names its edges left and right',
        (tester) async {
      final config = ConveyorConfig(
        key: _beltKey,
        onRails: true,
        positionKey: 'line1.wagon1.position',
        sensors: [_entry(_eyeKey)],
      );
      await openForm(tester, config);

      expect(find.text('Left'), findsOneWidget);
      expect(find.text('Right'), findsOneWidget);
      expect(find.text('Top'), findsNothing);
    });
  });

  group('on the page', () {
    /// The painter actually drawn, and where its box sits on screen. The
    /// asset's own size resolves against the test window, so the painted box
    /// is not the SizedBox above it.
    Future<({ConveyorPainter painter, Offset origin})> pumpConveyor(
        WidgetTester tester, List<ChildSensorEntry> sensors,
        {bool onRails = false}) async {
      final config = ConveyorConfig(
        key: _beltKey,
        onRails: onRails,
        wagonLength: 0.2,
        sensors: sensors,
      )
        ..beltWidthRelative = onRails ? null : 0.05
        ..size = const RelativeSize(width: 0.5, height: 0.5);

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

    testWidgets('both sensors are drawn beside a plain belt', (tester) async {
      await pumpConveyor(tester, [
        _entry(_eyeKey, position: 0.3),
        _entry(_otherKey, position: 0.7, side: GateSide.right),
      ]);
      expect(find.byType(Sensor), findsNWidgets(2));
    });

    testWidgets('and beside a wagon belt, riding it', (tester) async {
      final wagon = await pumpConveyor(tester, [_entry(_eyeKey)],
          onRails: true);
      expect(find.byType(Sensor), findsOneWidget);
      final belt = wagon.painter.beltRect(wagon.painter.paintSize!);
      final glyph = wagon.painter
          .sensorMount(wagon.painter.paintSize!,
              position: 0.5, side: GateSide.left, kind: SensorKind.opticField)
          .rect;
      expect(glyph.center.dx, lessThan(belt.left));
    });

    testWidgets('a conveyor with no sensors draws none', (tester) async {
      await pumpConveyor(tester, const []);
      expect(find.byType(Sensor), findsNothing);
    });

    testWidgets('tapping one opens that sensor, not the conveyor',
        (tester) async {
      addTearDown(() => closeSidePane(immediate: true));
      final conveyor = await pumpConveyor(tester, [
        ChildSensorEntry(
            position: 0.3,
            sensor: SensorConfig(detectionKey: _eyeKey, tag: 'Eye in')),
      ]);
      final rect = conveyor.painter
          .sensorMount(conveyor.painter.paintSize!,
              position: 0.3, side: GateSide.left, kind: SensorKind.opticField)
          .rect;
      await tester.tapAt(conveyor.origin + rect.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SidePane), findsOneWidget);
      expect(find.text('Eye in'), findsWidgets);
      expect(find.text('Belt drive'), findsNothing);
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
      sensors: [
        ChildSensorEntry(
            position: 0.4,
            sensor: SensorConfig(detectionKey: _eyeKey, tag: 'Eye in')),
      ],
    )
      ..beltWidthRelative = 0.05
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
