// Tapping one of a wagon's stations rings that station, not every station.
//
// BUG: a dock opened its pane from the conveyor's own context, so the pane's
// subject was the whole conveyor, and the plant view traced the conveyor's hit
// shape — the wagon plus every dock beside the rail. Tap one station and all
// of them were outlined.
//
// FIX: each dock names its own `AssetPart` as the subject and publishes its
// own rectangle, so the ring is that dock's alone. The wagon's own panes still
// ring the conveyor (`asset_stack_open_pane_mark_golden_test`).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/wagon_station_docks.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;
import '../../helpers/wagon_fixtures.dart';

const _stationsKey = 'line1.wagon1.stations';
const _positionKey = 'line1.wagon1.position';
const _beltKey = 'line1.wagon1.belt';

class _RailStateMan extends Fake implements StateMan {
  _RailStateMan(this.values);

  final Map<String, DynamicValue> values;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final v = values[key];
    return v == null ? const Stream<DynamicValue>.empty() : Stream.value(v);
  }

  @override
  String resolveKey(String key) => key;
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() => closeSidePane(immediate: true));

  /// What the ring encloses, in screen coordinates.
  Rect markBounds(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byKey(openPaneMarkKey));
    final origin = tester.getTopLeft(find.byKey(openPaneMarkKey));
    var rect = Rect.fromLTRB(double.infinity, double.infinity,
        double.negativeInfinity, double.negativeInfinity);
    for (final ring in (paint.painter! as HitBoundaryPainter).contours) {
      for (final local in ring) {
        final p = local + origin;
        rect = Rect.fromLTRB(math.min(rect.left, p.dx), math.min(rect.top, p.dy),
            math.max(rect.right, p.dx), math.max(rect.bottom, p.dy));
      }
    }
    return rect;
  }

  /// A frame for the pane, one past the post-frame trace, and the fade. Not
  /// `pumpAndSettle`: the ring's dashes crawl for as long as it is up.
  Future<void> pumpMarked(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a station pane rings that station alone', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final config = ConveyorConfig(
      key: _beltKey,
      onRails: true,
      stationsKey: _stationsKey,
      positionKey: _positionKey,
      wagonLength: 0.12,
    )
      // Left half of the page, clear of the pane docked on the right.
      ..coordinates = Coordinates(x: 0.3, y: 0.4)
      ..size = const RelativeSize(width: 0.5, height: 0.3);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        collectorProvider.overrideWith((ref) async => null),
        stateManProvider.overrideWith((ref) async => _RailStateMan({
              _stationsKey: stationArray([
                station('Infeed', position: 0),
                station('Outfeed A', position: 5000, type: 1, loc: 1),
                station('Outfeed B', position: 10000, type: 1),
              ]),
              _positionKey: DynamicValue(value: 50.0),
              _beltKey: DynamicValue(value: true),
            })),
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

    final paintFinder = find
        .descendant(of: find.byType(Conveyor), matching: find.byType(CustomPaint))
        .first;
    final painter =
        tester.widget<CustomPaint>(paintFinder).painter! as ConveyorPainter;
    final origin = tester.getTopLeft(paintFinder);
    final docks = painter.docks(painter.paintSize!);
    expect(docks, hasLength(3));
    WagonDock dock(String name) =>
        docks.firstWhere((d) => d.station.name == name);

    final air = HitBoundaryStyle.selection.standoff;

    void expectRinged(WagonDock d) {
      final body = d.body.shift(origin);
      final bounds = markBounds(tester);
      expect(bounds.center.dx, closeTo(body.center.dx, 2),
          reason: 'the ring belongs to ${d.station.name}');
      expect(bounds.center.dy, closeTo(body.center.dy, 2));
      expect(bounds.width, closeTo(body.width + 2 * air, 3),
          reason: 'the ring is the one dock, not the row of them');
      expect(bounds.height, closeTo(body.height + 2 * air, 3));
    }

    await tester.tapAt(origin + dock('Outfeed A').body.center);
    await pumpMarked(tester);
    expect(isSidePaneOpen(), isTrue);
    expectRinged(dock('Outfeed A'));

    // Another station: the pane swaps and the ring moves with it.
    await tester.tapAt(origin + dock('Infeed').body.center);
    await pumpMarked(tester);
    expectRinged(dock('Infeed'));
  });
}
