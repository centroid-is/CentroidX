/// What the editor shows while a cable is selected: every socket on the page
/// marked, and the one a dragged end will plug into lit up and named.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_link_painter.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_edit_overlay.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/theme.dart' show HmiStateColors;

import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/golden_tolerance.dart';

const _key = Key('link_edit_overlay_golden');
const Size _canvas = Size(480, 320);

/// A drive-shaped block with its two sockets on the bottom edge, where an
/// ATV320 declares them. Drawn plainly: the golden is about the overlay.
class _Drive extends BaseAsset implements NetworkPorted {
  _Drive(double x, String name) {
    coordinates = Coordinates(x: x, y: 0.4);
    size = const RelativeSize(width: 0.12, height: 0.5);
    text = name;
  }

  @override
  List<NetworkPort> get networkPorts => const [
        NetworkPort('A', PortSide.bottom, at: 0.35, description: 'In'),
        NetworkPort('B', PortSide.bottom, at: 0.65, description: 'Out'),
      ];

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => const {};
}

Widget _scene(List<Asset> page, EtherCatLinkConfig link) {
  const states = HmiStateColors.solarizedLight;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFFFDF6E3),
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(
            width: _canvas.width,
            height: _canvas.height,
            // Repaints the ink with every edit, as the editor does, so the
            // drawn cable follows a dragged end.
            child: StatefulBuilder(builder: (context, setState) {
              final resolved =
                  link.run.resolve(_canvas, PageLinkAnchors(page, _canvas));
              return Stack(
                children: [
                  for (final a in page.whereType<_Drive>())
                    Positioned(
                      left:
                          (a.coordinates.x - a.size.width / 2) * _canvas.width,
                      top: (a.coordinates.y - a.size.height / 2) *
                          _canvas.height,
                      width: a.size.width * _canvas.width,
                      height: a.size.height * _canvas.height,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFF363C44),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Center(
                          child: Text(a.text ?? '',
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFFEEE8D5))),
                        ),
                      ),
                    ),
                  CustomPaint(
                    size: _canvas,
                    painter: EtherCatLinkPainter(
                      link: resolved,
                      color: linkHealthColor(states, LinkHealth.idle),
                      strokeWidth: 4,
                      selected: true,
                    ),
                  ),
                  LinkEditOverlay(
                    link: link,
                    assets: page,
                    canvas: _canvas,
                    onBeginEdit: () {},
                    onChanged: () => setState(() {}),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    ),
  );
}

void main() {
  useTolerantGoldenComparator();
  setUpAll(loadGoldenFonts);

  group('cable edit overlay goldens', skip: goldenSkip, () {
    testWidgets('a selected cable marks every socket on the page',
        (tester) async {
      final one = _Drive(0.3, 'Drive 1')..ensureId();
      final two = _Drive(0.6, 'Drive 2')..ensureId();
      final link = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: one.id, port: 'B'),
          to: LinkEnd(assetId: two.id, port: 'A'),
          waypoints: [
            LinkWaypoint.onPage(0.318, 0.8),
            LinkWaypoint.onPage(0.582, 0.8),
          ],
          radius: 0.03,
        ),
      );
      final page = <Asset>[one, two, link];

      await tester.pumpWidget(_scene(page, link));
      await expectLater(
          find.byKey(_key), matchesGoldenFile('goldens/link_edit_ports.png'));
    });

    testWidgets('a dragged end snaps to the socket it will plug into',
        (tester) async {
      final one = _Drive(0.3, 'Drive 1')..ensureId();
      final two = _Drive(0.6, 'Drive 2')..ensureId();
      final link = EtherCatLinkConfig(
        run: LinkRun(
          from: LinkEnd(assetId: one.id, port: 'B'),
          to: LinkEnd(x: 0.85, y: 0.85),
          waypoints: [LinkWaypoint.onPage(0.318, 0.8)],
          radius: 0.03,
        ),
      );
      final page = <Asset>[one, two, link];

      await tester.pumpWidget(_scene(page, link));
      final origin = tester.getTopLeft(find.byType(LinkEditOverlay));
      final end = Offset(0.85 * _canvas.width, 0.85 * _canvas.height);
      // Port A of the second drive, and a finger a little below and right of it.
      final portA = Offset(
          (0.6 - 0.06 + 0.12 * 0.35) * _canvas.width, 0.65 * _canvas.height);
      final target = portA + const Offset(6, 14);

      final gesture = await tester.startGesture(origin + end);
      for (var i = 1; i <= 5; i++) {
        await gesture.moveTo(origin + end + (target - end) * (i / 5));
        await tester.pump();
      }
      await expectLater(
          find.byKey(_key), matchesGoldenFile('goldens/link_edit_snap.png'));
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
