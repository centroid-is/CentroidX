// A rotated asset must be tappable along its whole painted visual, not just
// where that visual crosses its own unrotated layout rect.
//
// `AssetStack` lays every asset out in its unrotated w×h rect and lets the
// asset's internal `LayoutRotatedBox` paint out into the surrounding AABB
// (`_HitPermissiveSizedBox` keeps the page-level chain from clamping first).
// Anything the asset mounts OUTSIDE that rotated box hit-tests against the
// unrotated rect: `RenderBox.hitTest` rejects a position outside its own size
// before the child gets a say. A conveyor is the worst case for it — a long,
// thin box turned 90° paints a tall strip while its rect stays short and wide,
// so only the square where the two cross answered. On a wet-area strapper
// conveyor (0.05 × 0.03 of the canvas, turned 90°) that is the middle third of
// the belt, and the proximity sensors placed on the same spot cover most of
// what is left.
//
// The sensor was fixed for this once already; see sensor_rotated_hittest_test.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/elevator.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

class _FakeStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      Stream<DynamicValue>.value(DynamicValue());
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Widget stackApp(BaseAsset asset) {
    return ProviderScope(
      overrides: [
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [asset],
              constraints: constraints,
              absorb: false,
              selectedAssets: const {},
              mirroringDisabled: true,
            ),
          ),
        ),
      ),
    );
  }

  /// Whether a hit test at [global] reaches the asset's own tap handler.
  bool hitsDetector(WidgetTester tester, Type assetWidget, Offset global) {
    final detector = find.descendant(
      of: find.byType(assetWidget),
      matching: find.byType(GestureDetector),
    );
    expect(detector, findsOneWidget,
        reason: 'a key is configured, so the tap handler must mount');
    final target = tester.renderObject(detector);
    return tester
        .hitTestOnBinding(global)
        .path
        .any((entry) => entry.target == target);
  }

  // The test window. Every asset here resolves its box against it, exactly
  // as the widgets do through MediaQuery.
  const window = Size(800, 600);

  /// Page-space offset from the asset's centre for a point given in the
  /// asset's own (unrotated) frame, when the asset is turned 90°.
  ///
  /// `_RenderLayoutRotatedBox.hitTest` maps an incoming offset (gx, gy) from
  /// the centre onto the child point (w/2 + gy, h/2 - gx); this is that
  /// inverted, so a point picked off the painted geometry can be tapped.
  Offset pageOffsetAt90(Offset local, Size box) =>
      Offset(box.height / 2 - local.dy, local.dx - box.width / 2);

  /// Whether a page offset falls outside the asset's *unrotated* layout rect.
  ///
  /// That rect is what every render object above the rotation hit-tests
  /// against, so this is precisely the region the tap target used to be
  /// confined to. A probe that is not outside it proves nothing about the
  /// defect.
  bool outsideUnrotatedRect(Offset pageOffset, Size box) =>
      pageOffset.dx.abs() > box.width / 2 ||
      pageOffset.dy.abs() > box.height / 2;

  group('Conveyor', () {
    // The 800×600 test window makes the belt an 80×30 rect laid out
    // horizontally and, at 90°, painted as a 30×80 strip on the same centre.
    ConveyorConfig belt({double? angle}) => ConveyorConfig(key: 'AREA01.CN05')
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
      ..size = const RelativeSize(width: 0.1, height: 0.05);

    testWidgets('turned 90°, the whole painted belt is tappable',
        (tester) async {
      await tester.pumpWidget(stackApp(belt(angle: 90)));
      await tester.pumpAndSettle();

      // ±30 px along the strip is well past the 15 px half-height of the
      // unrotated rect — the stretch of belt the old clamp swallowed.
      final center = tester.getCenter(find.byType(Conveyor));
      expect(hitsDetector(tester, Conveyor, center), isTrue,
          reason: 'middle of the belt must be tappable');
      expect(
          hitsDetector(tester, Conveyor, center + const Offset(0, -30)), isTrue,
          reason: 'upstream end of the rotated belt must be tappable');
      expect(
          hitsDetector(tester, Conveyor, center + const Offset(0, 30)), isTrue,
          reason: 'downstream end of the rotated belt must be tappable');
    });

    testWidgets('turned 90°, a narrow belt claims only the band it paints',
        (tester) async {
      // beltWidthRelative is a fraction of the canvas height, so 0.02 of a
      // 600 px canvas paints a 12 px band down the middle of the 30 px-wide
      // rotated box. Widening the tap target back out to the box would take
      // taps from whatever is parked alongside the belt.
      final config = belt(angle: 90)..beltWidthRelative = 0.02;
      await tester.pumpWidget(stackApp(config));
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(Conveyor));
      expect(
          hitsDetector(tester, Conveyor, center + const Offset(0, 35)), isTrue,
          reason: 'far along the band is still the band');
      for (final beside in [const Offset(10, 0), const Offset(-10, 0)]) {
        expect(hitsDetector(tester, Conveyor, center + beside), isFalse,
            reason: 'beside the band, still inside the box: must fall through');
      }
    });

    // ---- turned belts -------------------------------------------------
    //
    // Real belts bend: a dog-leg or an S, rotated as a whole. That is where
    // a regression would hide, because the painted band leaves the straight
    // rect the old gesture layer was testing against — on the S-bend below,
    // everything but the middle of the belt sat outside it.

    ConveyorConfig sBend({double? angle}) => ConveyorConfig(
          key: 'AREA01.CN07',
          turns: [
            ConveyorTurnEntry(position: 0.3, angle: 55, radius: 1.2),
            ConveyorTurnEntry(position: 0.65, angle: -55, radius: 1.2),
          ],
        )
          ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
          ..size = const RelativeSize(width: 0.3, height: 0.1);

    ConveyorConfig dogLeg({double? angle}) => ConveyorConfig(
          key: 'AREA01.CN08',
          turns: [ConveyorTurnEntry(position: 0.35, angle: 45, radius: 1.5)],
        )
          ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
          ..size = const RelativeSize(width: 0.3, height: 0.15)
          ..beltWidthRelative = 0.03;

    /// The centerline the widget builds for [config], on the same box.
    ConveyorPathGeometry geometryOf(ConveyorConfig config) {
      final geometry = ConveyorPathGeometry.build(
        config.turns,
        config.size.toSize(window),
        thicknessFactor: config.effectiveBeltThickness,
        beltWidthOverride: config.beltWidthRelative == null
            ? null
            : config.beltWidthRelative! * window.height,
      );
      expect(geometry, isNotNull, reason: 'test setup: the belt must bend');
      return geometry!;
    }

    /// The painter the widget builds for [config] — the authority on what
    /// counts as "on the band", and the thing `deferToChild` consults.
    ConveyorPainter painterOf(ConveyorConfig config) => ConveyorPainter(
          color: Colors.green,
          batches: const {},
          angle: config.coordinates.angle ?? 0.0,
          geometry: geometryOf(config),
          straightBeltWidth: config.beltWidthRelative == null
              ? null
              : config.beltWidthRelative! * window.height,
          paintSize: config.size.toSize(window),
        );

    /// Asserts the band point at [fraction] is tappable, having first checked
    /// it is a probe worth making: on the painted band, and outside the
    /// unrotated rect.
    void expectBandTappable(
        WidgetTester tester, ConveyorConfig config, double fraction) {
      final box = config.size.toSize(window);
      final local = geometryOf(config).tangentAt(fraction).position;
      final page = pageOffsetAt90(local, box);
      expect(painterOf(config).hitTest(local), isTrue,
          reason: 'test setup: f=$fraction must be on the painted band');
      expect(outsideUnrotatedRect(page, box), isTrue,
          reason: 'test setup: f=$fraction must fall outside the unrotated '
              'rect, or it says nothing about the defect');
      final center = tester.getCenter(find.byType(Conveyor));
      expect(hitsDetector(tester, Conveyor, center + page), isTrue,
          reason: 'the band at f=$fraction must be tappable');
    }

    testWidgets('S-bend turned 90°: the band past both bends is tappable',
        (tester) async {
      final config = sBend(angle: 90);
      await tester.pumpWidget(stackApp(config));
      await tester.pumpAndSettle();

      // The bends sit at 0.3 and 0.65, so 0.75 and 0.9 are the run after
      // them — the stretch that swings furthest out of the straight rect.
      for (final f in [0.1, 0.25, 0.75, 0.9]) {
        expectBandTappable(tester, config, f);
      }
    });

    testWidgets('S-bend turned 90°: both ends of the belt are tappable',
        (tester) async {
      final config = sBend(angle: 90);
      await tester.pumpWidget(stackApp(config));
      await tester.pumpAndSettle();

      // Just inside the end caps rather than dead on them: a point exactly on
      // the outline's boundary is not reliably inside it.
      expectBandTappable(tester, config, 0.02);
      expectBandTappable(tester, config, 0.98);
    });

    testWidgets(
        'dog-leg turned 90°: the concave side of the bend falls through',
        (tester) async {
      final config = dogLeg(angle: 90);
      await tester.pumpWidget(stackApp(config));
      await tester.pumpAndSettle();

      final box = config.size.toSize(window);
      final geometry = geometryOf(config);
      final turn = config.turns.single;
      final tangent = geometry.tangentAt(turn.position);
      // A positive sweep turns towards the bottom of the screen, so the
      // centre of curvature — the concave side — lies along (-vy, vx).
      final inward = Offset(-tangent.vector.dy, tangent.vector.dx) *
          turn.angle.sign *
          geometry.beltWidth;
      final local = tangent.position + inward;

      expect(box.contains(local), isTrue,
          reason: 'test setup: the probe must be inside the belt box');
      expect(painterOf(config).hitTest(local), isFalse,
          reason: 'test setup: the probe must be off the painted band');

      final center = tester.getCenter(find.byType(Conveyor));
      expect(
          hitsDetector(tester, Conveyor, center + pageOffsetAt90(local, box)),
          isFalse,
          reason: 'the notch of a bend is not belt: it must fall through so '
              'whatever is parked there stays reachable');
    });

    testWidgets('unrotated, the belt fills its box and the box is the belt',
        (tester) async {
      await tester.pumpWidget(stackApp(belt()));
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(Conveyor));
      expect(
          hitsDetector(tester, Conveyor, center + const Offset(35, 0)), isTrue);
      expect(hitsDetector(tester, Conveyor, center + const Offset(-35, 0)),
          isTrue);
    });
  });

  group('ConveyorGate', () {
    // The gate mounted its detector at three call sites around _buildGate,
    // outside the rotation. A gate is usually square, where the rotated and
    // unrotated rects coincide and nothing shows; give it a wide box and an
    // angle and the same dead zone appears.
    ConveyorGateConfig gate({double? angle}) => ConveyorGateConfig(
          gateVariant: GateVariant.pusher,
          forceOpenKey: 'AREA01.CN01.GATE.forceOpen',
        )
          ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
          ..size = const RelativeSize(width: 0.1, height: 0.05);

    testWidgets('turned 90°, the whole rotated visual is tappable',
        (tester) async {
      await tester.pumpWidget(stackApp(gate(angle: 90)));
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(ConveyorGate));
      expect(hitsDetector(tester, ConveyorGate, center), isTrue);
      expect(hitsDetector(tester, ConveyorGate, center + const Offset(0, -30)),
          isTrue,
          reason: 'the ends of the rotated gate must answer');
      expect(hitsDetector(tester, ConveyorGate, center + const Offset(0, 30)),
          isTrue);
    });
  });

  group('Elevator', () {
    // Same root cause, same shape of fix: the elevator's detector was mounted
    // outside its LayoutRotatedBox, so a turned elevator answered only where
    // its visual crossed the unrotated rect.
    ElevatorConfig lift({double? angle}) => ElevatorConfig(positionKey: '')
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle)
      ..size = const RelativeSize(width: 0.1, height: 0.05);

    testWidgets('turned 90°, the whole rotated visual is tappable',
        (tester) async {
      await tester.pumpWidget(stackApp(lift(angle: 90)));
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(Elevator));
      expect(hitsDetector(tester, Elevator, center), isTrue);
      expect(
          hitsDetector(tester, Elevator, center + const Offset(0, -30)), isTrue,
          reason: 'the rotated visual runs along y, so its ends must answer');
      expect(
          hitsDetector(tester, Elevator, center + const Offset(0, 30)), isTrue);
    });
  });
}
