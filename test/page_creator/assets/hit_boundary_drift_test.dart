// A published hit shape has to keep being true.
//
// The plant view outlines the shape an asset publishes with `AssetHitShape`
// rather than probing it, because probing costs ten thousand hit tests per
// pane and an asset that knows its own shape should not have to be
// interrogated for it. The price of that is a promise: the published path is
// the path the hit test answers from. Nothing in the type system holds
// anyone to it — a refactor that changes `ConveyorPainter.hitTest` and leaves
// `hitShape` alone would put the mark quietly back to lying, which is the one
// failure the mark exists to prevent.
//
// So this is the alarm. It probes the widget's real hit test the expensive
// way and holds the answer against the published path, point by point. It
// belongs here and not in the app: CI has the ten thousand hit tests to
// spare, and an operator opening a pane does not.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart'
    show DynamicValue, EnumField, LocalizedText, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/hit_probe.dart';
import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  /// Pumps [asset] alone on a canvas and hands back the two things to compare:
  /// the box that decides whether a tap lands on it, and the shape the asset
  /// says it takes taps on, in that box's coordinates.
  Future<({RenderBox box, Path shape})> pumpAsset(
    WidgetTester tester,
    Asset asset, {
    Size surface = const Size(900, 500),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fake = _FakeStateMan()
      ..push('cn/drive', _runningDrive())
      ..push('gate/state', _bool(true));
    await tester.pumpWidget(ProviderScope(
      overrides: [stateManProvider.overrideWith((_) async => fake)],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [asset],
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              absorb: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    ({Path path, RenderBox box})? published;
    void findShape(Element element) {
      if (published != null) return;
      final widget = element.widget;
      if (widget is AssetHitShape) {
        final ro = element.findRenderObject();
        if (ro is RenderBox && ro.hasSize) {
          published = (path: widget.shape(), box: ro);
        }
        return;
      }
      element.visitChildElements(findShape);
    }

    final stack = tester.element(find.byType(AssetStack));
    final box = assetHitBox(stack);
    stack.visitChildElements(findShape);

    expect(box, isNotNull, reason: 'the asset has a hit box');
    expect(published, isNotNull,
        reason: 'this asset is meant to publish a hit shape');

    // The published path is measured in the wrapped widget's box; the probe
    // asks in the hit box's. Bring the two into the same coordinates.
    final shape = published!.path
        .transform(published!.box.getTransformTo(box!).storage);
    return (box: box!, shape: shape);
  }

  /// Fails when the published shape and the real hit test disagree.
  ///
  /// Sampled over the whole box and a margin around it. Points within
  /// [edge] of the shape's outline are not counted: the path is
  /// anti-aliased arithmetic and `contains` is exact, so the two are allowed
  /// to differ on the line itself — just not on either side of it.
  void expectShapeMatchesHitTest(
    ({RenderBox box, Path shape}) asset, {
    double edge = 1.5,
  }) {
    final rings = flattenPath(asset.shape, step: 1);
    double distanceToOutline(Offset point) {
      var nearest = double.infinity;
      for (final ring in rings) {
        for (final vertex in ring) {
          final d = (vertex - point).distance;
          if (d < nearest) nearest = d;
        }
      }
      return nearest;
    }

    final sweep = sweepHitTest(asset.box);
    final disagreements = <String>[];
    var sampled = 0;
    for (final (points, reachable) in [
      (sweep.hits, true),
      (sweep.misses, false),
    ]) {
      for (final point in points) {
        if (distanceToOutline(point) <= edge) continue;
        sampled++;
        if (asset.shape.contains(point) == reachable) continue;
        if (disagreements.length < 12) {
          disagreements.add(reachable
              ? '$point takes a tap the published shape excludes'
              : '$point is inside the published shape but takes no tap');
        }
      }
    }

    expect(sampled, greaterThan(500), reason: 'the sweep covered the asset');
    expect(
      disagreements,
      isEmpty,
      reason: 'the published shape must be the shape the hit test answers '
          'from — if this fails, one of the two was changed without the '
          'other and the plant view is now outlining the wrong thing',
    );
  }

  testWidgets('a straight belt publishes the band it takes taps on',
      (tester) async {
    final asset = ConveyorConfig(key: 'cn/drive')
      ..beltWidthRelative = 0.1
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.6, height: 0.3);

    expectShapeMatchesHitTest(await pumpAsset(tester, asset));
  });

  testWidgets('a turned belt publishes the arc it takes taps on',
      (tester) async {
    final asset = ConveyorConfig(
      key: 'cn/drive',
      turns: [ConveyorTurnEntry(position: 0.45, angle: 70, radius: 1.4)],
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.6, height: 0.4);

    expectShapeMatchesHitTest(await pumpAsset(tester, asset));
  });

  testWidgets('a rotated turned belt does too', (tester) async {
    // The asset rotates inside its own box, so the shape and the hit test
    // both live in the rotated frame. They agree there or they do not.
    final asset = ConveyorConfig(
      key: 'cn/drive',
      turns: [ConveyorTurnEntry(position: 0.5, angle: 60, radius: 1.4)],
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 30)
      ..size = const RelativeSize(width: 0.5, height: 0.35);

    expectShapeMatchesHitTest(await pumpAsset(tester, asset));
  });

  testWidgets('a diverter gate publishes the arm it takes taps on',
      (tester) async {
    // The arm as drawn at rest, hub included — not the box it is laid out in.
    final gate = ConveyorGateConfig(
      gateVariant: GateVariant.pneumatic,
      stateKey: 'gate/state',
      forceOpenKey: 'gate/force_open',
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.2, height: 0.3);

    final asset = await pumpAsset(tester, gate);
    expectShapeMatchesHitTest(asset);

    // And it is narrower than the box, which is the whole point: the empty
    // half of a portrait box no longer takes taps.
    final face = Offset.zero & asset.box.size;
    final target = asset.shape.getBounds();
    expect(target.height, lessThan(face.height * 0.75),
        reason: 'the arm does not fill the height of its box');
    expect(target.left, greaterThanOrEqualTo(0),
        reason: 'the hub painted outside the box cannot answer a tap, so the '
            'gate does not claim it');
  });

  testWidgets('an alarm beacon publishes the marker it takes taps on',
      (tester) async {
    // The beacon draws a small marker in the middle of a much larger placed
    // box and only takes taps there, so the mark has to outline the marker —
    // a face-sized rectangle around a dot is the drift this test exists for.
    final beacon = AlarmVisibilityConfig(showWhenInactive: true)
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.3, height: 0.3);

    final asset = await pumpAsset(tester, beacon);
    expectShapeMatchesHitTest(asset);

    // And it really is a fraction of the box, not the box under another name.
    final face = Offset.zero & asset.box.size;
    final target = asset.shape.getBounds();
    expect(target.width, lessThan(face.width * 0.5),
        reason: 'the empty box around the marker no longer takes taps');
  });

  testWidgets('an asset that publishes nothing takes taps on its whole face',
      (tester) async {
    // The other half of the promise. The mark draws the face of an asset that
    // publishes no shape, so that face had better be what answers a pointer —
    // an asset whose real hit area were smaller (an inset, a shrunken InkWell)
    // would be marked as claiming more than it takes.
    final sensor = SensorConfig(
      kind: SensorKind.opticField,
      detectionKey: 'sensor/det',
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.2, height: 0.3);

    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fake = _FakeStateMan()..push('sensor/det', _bool(false));
    await tester.pumpWidget(ProviderScope(
      overrides: [stateManProvider.overrideWith((_) async => fake)],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [sensor],
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              absorb: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AssetHitShape), findsNothing,
        reason: 'a sensor takes taps on its box, so it publishes no shape');

    final box = assetHitBox(tester.element(find.byType(AssetStack)))!;
    final sweep = sweepHitTest(box, margin: 6);
    final face = Offset.zero & box.size;
    for (final point in sweep.hits) {
      expect(face.inflate(1).contains(point), isTrue,
          reason: '$point takes a tap from outside the face that is marked');
    }
    for (final point in sweep.misses) {
      expect(face.deflate(1).contains(point), isFalse,
          reason: '$point is inside the marked face but takes no tap');
    }
  });

  testWidgets('a belt that fills its box publishes nothing', (tester) async {
    // No configured band and no turns: the belt is the box, and there is no
    // narrower shape to publish. The plant view marks the face, which is
    // right — so the asset must not claim otherwise.
    final asset = ConveyorConfig(key: 'cn/drive')
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.6, height: 0.2);

    await tester.binding.setSurfaceSize(const Size(900, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fake = _FakeStateMan()..push('cn/drive', _runningDrive());
    await tester.pumpWidget(ProviderScope(
      overrides: [stateManProvider.overrideWith((_) async => fake)],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [asset],
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              absorb: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AssetHitShape), findsNothing);
  });
}

/// An `FB_ATV320` HMI struct for a belt running in auto — enough for the
/// conveyor to render live and take taps.
DynamicValue _runningDrive() {
  const modes = ['stopped', 'auto', 'manual', 'clean', 'fault'];
  final runMode = DynamicValue(value: modes.indexOf('auto'));
  runMode.enumFields = {
    for (var i = 0; i < modes.length; i++)
      i: EnumField(i, modes[i], LocalizedText(modes[i], 'en'),
          LocalizedText('', 'en')),
  };

  final drive = DynamicValue();
  drive['p_stat_State'] = 0;
  drive['p_stat_LastFault'] = 0;
  drive['p_stat_RunMode'] = runMode;
  drive['p_stat_Frequency'] = 42.0;
  drive['p_stat_Current'] = 3.2;
  drive['p_stat_RunMinutes'] = 128;
  drive['p_stat_JogFwd'] = false;
  drive['p_stat_JogBwd'] = false;
  drive['p_stat_ManualStopOnRelease'] = true;
  drive['p_cfg_ManualFreq'] = 20.0;
  drive['p_cfg_AutoFreq'] = 50.0;
  drive['p_cfg_CleaningFreq'] = 20.0;
  return drive;
}

DynamicValue _bool(bool value) =>
    DynamicValue(value: value, typeId: NodeId.boolean);

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, DynamicValue value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(value);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<void> write(String key, DynamicValue value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}
