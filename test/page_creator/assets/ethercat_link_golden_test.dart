
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_link_painter.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/theme.dart' show HmiStateColors;

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('ethercat_link_golden');

/// Anchors that place two device boxes by hand, so a golden can pose a cable
/// without standing up a page.
class _Devices implements LinkAnchors {
  _Devices(this.boxes);

  /// Page-relative boxes, keyed by asset id.
  final Map<String, Rect> boxes;

  @override
  Offset? portPosition(String assetId, String? port) {
    final b = boxes[assetId];
    if (b == null) return null;
    return port == 'X1' ? b.centerLeft : b.centerRight;
  }

  @override
  Offset? assetAnchor(String assetId) => boxes[assetId]?.center;
}

/// Paints a run over two device blocks, so the goldens show a cable in the
/// context that gives it meaning rather than a line on an empty field.
Widget scenario({
  required LinkRun run,
  required Map<String, Rect> devices,
  LinkHealth health = LinkHealth.healthy,
  Size canvas = const Size(520, 300),
  bool selected = false,
}) {
  const states = HmiStateColors.solarizedLight;
  final resolved = run.resolve(canvas, _Devices(devices));
  return MaterialApp(
    home: Scaffold(
      backgroundColor: const Color(0xFFFDF6E3),
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(
            width: canvas.width,
            height: canvas.height,
            child: Stack(
              children: [
                CustomPaint(
                  size: canvas,
                  painter: EtherCatLinkPainter(
                    link: resolved,
                    color: linkHealthColor(states, health),
                    strokeWidth: 5,
                    selected: selected,
                  ),
                ),
                for (final entry in devices.entries)
                  Positioned(
                    left: entry.value.left * canvas.width,
                    top: entry.value.top * canvas.height,
                    width: entry.value.width * canvas.width,
                    height: entry.value.height * canvas.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEE8D5),
                        border: Border.all(color: const Color(0xFF073642)),
                      ),
                      child: Center(
                        child: Text(entry.key,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF073642))),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final _devices = {
  'EK1100': const Rect.fromLTWH(0.06, 0.14, 0.2, 0.16),
  'EP2338': const Rect.fromLTWH(0.72, 0.62, 0.2, 0.16),
};

LinkRun _run({List<LinkWaypoint>? waypoints, double radius = 0.05}) => LinkRun(
      from: LinkEnd(assetId: 'EK1100', port: 'X2'),
      to: LinkEnd(assetId: 'EP2338', port: 'X1'),
      waypoints: waypoints,
      radius: radius,
    );

void main() {
  useTolerantGoldenComparator();

  group('EtherCAT link goldens',
      skip: goldenSkip, () {
    testWidgets('a fresh run is a straight line between two ports',
        (tester) async {
      await tester.pumpWidget(scenario(run: _run(), devices: _devices));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_straight.png'));
    });

    testWidgets('one corner, filleted', (tester) async {
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [LinkWaypoint.onRun(0.45, -0.28)]),
        devices: _devices,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_one_corner.png'));
    });

    testWidgets('a tray run: out along the top, then down', (tester) async {
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [
          LinkWaypoint.onRun(0.3, -0.34),
          LinkWaypoint.onRun(0.72, -0.12),
        ]),
        devices: _devices,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_tray_run.png'));
    });

    testWidgets('a radius too big for its segments is clamped, not honoured',
        (tester) async {
      // The same run at an absurd radius. It must stay on its own skeleton
      // rather than folding through itself.
      await tester.pumpWidget(scenario(
        run: _run(radius: 0.6, waypoints: [
          LinkWaypoint.onRun(0.3, -0.34),
          LinkWaypoint.onRun(0.72, -0.12),
        ]),
        devices: _devices,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_radius_clamped.png'));
    });

    testWidgets('degraded reads as attention, not as a fault', (tester) async {
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [LinkWaypoint.onRun(0.45, -0.28)]),
        devices: _devices,
        health: LinkHealth.degraded,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_degraded.png'));
    });

    testWidgets('a dropped link is the loudest thing on the page',
        (tester) async {
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [LinkWaypoint.onRun(0.45, -0.28)]),
        devices: _devices,
        health: LinkHealth.down,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_down.png'));
    });

    testWidgets('selection is a halo on the cable, not a box round the page',
        (tester) async {
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [LinkWaypoint.onRun(0.45, -0.28)]),
        devices: _devices,
        selected: true,
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_selected.png'));
    });

    testWidgets('the run squashes with the page, staying on its ports',
        (tester) async {
      // Same cable, half the height. The ends must still be on the boxes.
      await tester.pumpWidget(scenario(
        run: _run(waypoints: [LinkWaypoint.onRun(0.45, -0.28)]),
        devices: _devices,
        canvas: const Size(520, 150),
      ));
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_squashed.png'));
    });
  });
}
