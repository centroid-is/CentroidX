import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_edit_overlay.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';

const Size _canvas = Size(800, 600);

class _Block extends BaseAsset {
  _Block({required double x, required double y, String? name}) {
    coordinates = Coordinates(x: x, y: y);
    size = const RelativeSize(width: 0.12, height: 0.1);
    text = name;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => const {};
}

/// A device with two sockets on its bottom edge, like an ATV320.
class _Drive extends BaseAsset implements NetworkPorted {
  _Drive({required double x, required double y, String? name}) {
    coordinates = Coordinates(x: x, y: y);
    size = const RelativeSize(width: 0.05, height: 0.4);
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

/// The overlay on its own canvas, which is all it needs — it takes the page as
/// a plain list rather than reaching for one.
Future<int> pumpOverlay(
  WidgetTester tester, {
  required EtherCatLinkConfig link,
  required List<Asset> assets,
  VoidCallback? onBeginEdit,
  VoidCallback? onEndEdit,
  VoidCallback? onConfigure,
  void Function(Offset local, Offset global)? onSecondaryTap,
}) async {
  var changes = 0;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _canvas.width,
          height: _canvas.height,
          child: Stack(
            children: [
              LinkEditOverlay(
                link: link,
                assets: assets,
                canvas: _canvas,
                onBeginEdit: onBeginEdit ?? () {},
                onEndEdit: onEndEdit,
                onConfigure: onConfigure,
                onSecondaryTap: onSecondaryTap,
                onChanged: () => changes++,
              ),
            ],
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return changes;
}

/// Canvas pixels → screen, for driving gestures.
Offset onCanvas(WidgetTester tester, Offset canvasPoint) {
  final origin = tester.getTopLeft(find.byType(LinkEditOverlay));
  return origin + canvasPoint;
}

void main() {
  late _Block a;
  late _Block b;
  late EtherCatLinkConfig link;
  late List<Asset> page;

  setUp(() {
    a = _Block(x: 0.15, y: 0.5, name: 'EK1100')..ensureId();
    b = _Block(x: 0.85, y: 0.5, name: 'EP2338')..ensureId();
    link = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      ),
    );
    page = [a, b, link];
  });

  Offset resolvedPoint(int index) =>
      link.run.resolve(_canvas, _anchorsFor(page)).points[index];

  testWidgets('a fresh run has no corners and two end handles', (tester) async {
    await pumpOverlay(tester, link: link, assets: page);
    // Two ends plus one ghost on the single segment.
    expect(link.run.waypoints, isEmpty);
    expect(find.byType(GestureDetector), findsWidgets);
  });

  testWidgets('dragging the ghost midpoint makes a corner', (tester) async {
    await pumpOverlay(tester, link: link, assets: page);
    final mid = (resolvedPoint(0) + resolvedPoint(1)) / 2;

    await tester.dragFrom(onCanvas(tester, mid), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(link.run.waypoints, hasLength(1),
        reason: 'the ghost should have become a real corner');
    // Dragged up, so it sits above the straight line between the ports.
    expect(resolvedPoint(1).dy, lessThan(mid.dy - 50));
  });

  testWidgets('a corner drags to a new place', (tester) async {
    link.run.waypoints.add(LinkWaypoint.onRun(0.5, 0.0));
    await pumpOverlay(tester, link: link, assets: page);
    final before = resolvedPoint(1);

    await tester.dragFrom(onCanvas(tester, before), const Offset(60, -90));
    await tester.pumpAndSettle();

    final after = resolvedPoint(1);
    expect(after.dx, greaterThan(before.dx + 30));
    expect(after.dy, lessThan(before.dy - 40));
    expect(link.run.waypoints, hasLength(1), reason: 'still one corner');
  });

  testWidgets('dropping a corner on its neighbour deletes it', (tester) async {
    // The gesture the benches offered alongside the menu: drag it away and it
    // is gone, without going hunting for a command.
    link.run.waypoints.add(LinkWaypoint.onRun(0.5, -0.3));
    await pumpOverlay(tester, link: link, assets: page);

    final corner = resolvedPoint(1);
    final end = resolvedPoint(0);
    await tester.dragFrom(onCanvas(tester, corner), end - corner);
    await tester.pumpAndSettle();

    expect(link.run.waypoints, isEmpty);
  });

  testWidgets('dragging an end onto another device re-plugs it',
      (tester) async {
    final c = _Block(x: 0.5, y: 0.9, name: 'EL9222')..ensureId();
    page = [a, b, c, link];
    await pumpOverlay(tester, link: link, assets: page);

    final end = resolvedPoint(link.run.waypoints.length + 1);
    final target = Offset(
        c.coordinates.x * _canvas.width, c.coordinates.y * _canvas.height);
    await tester.dragFrom(onCanvas(tester, end), target - end);
    await tester.pumpAndSettle();

    expect(link.run.to.assetId, c.id,
        reason: 'the end should now belong to the device it was dropped on');
    expect(link.run.to.port, isNotNull);
  });

  testWidgets('dragging an end onto empty canvas unplugs it', (tester) async {
    await pumpOverlay(tester, link: link, assets: page);

    final end = resolvedPoint(link.run.waypoints.length + 1);
    const empty = Offset(400, 60);
    await tester.dragFrom(onCanvas(tester, end), empty - end);
    await tester.pumpAndSettle();

    expect(link.run.to.assetId, isNull);
    expect(link.run.to.x, closeTo(empty.dx / _canvas.width, 0.05));
  });

  testWidgets('right-clicking a corner offers delete and what it follows',
      (tester) async {
    link.run.waypoints.add(LinkWaypoint.onRun(0.5, -0.2));
    await pumpOverlay(tester, link: link, assets: page);

    await tester.tapAt(onCanvas(tester, resolvedPoint(1)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Delete point'), findsOneWidget);
    expect(find.text('Straighten run'), findsOneWidget);
    expect(find.text('Stays where it is'), findsOneWidget);
    expect(find.text('Follows both ends'), findsOneWidget);
    // Named by the devices the run is plugged into, not by opaque ids.
    expect(find.text('Moves with EK1100'), findsOneWidget);
    expect(find.text('Moves with EP2338'), findsOneWidget);
  });

  testWidgets('Delete point removes that corner', (tester) async {
    link.run.waypoints
      ..add(LinkWaypoint.onRun(0.3, -0.2))
      ..add(LinkWaypoint.onRun(0.7, -0.2));
    await pumpOverlay(tester, link: link, assets: page);
    final second = resolvedPoint(2);

    await tester.tapAt(onCanvas(tester, resolvedPoint(1)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete point'));
    await tester.pumpAndSettle();

    expect(link.run.waypoints, hasLength(1));
    // The one that survived is the second, so the right index was removed.
    expect(resolvedPoint(1), within(distance: 0.01, from: second));
  });

  testWidgets('pinning a corner to a device changes what holds it',
      (tester) async {
    link.run.waypoints.add(LinkWaypoint.onRun(0.4, -0.2));
    await pumpOverlay(tester, link: link, assets: page);

    await tester.tapAt(onCanvas(tester, resolvedPoint(1)),
        buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moves with EK1100'));
    await tester.pumpAndSettle();

    expect(link.run.waypoints.single.pinnedTo, a.id);
    expect(link.run.waypoints.single.t, isNull,
        reason: 'the rule it no longer uses must be cleared');
  });

  testWidgets('a pinned corner then ignores the far device', (tester) async {
    link.run.waypoints.add(LinkWaypoint.pinned('${a.id}', 0.1, -0.1));
    await pumpOverlay(tester, link: link, assets: page);
    final before = resolvedPoint(1);

    b.coordinates = Coordinates(x: 0.6, y: 0.2);
    await pumpOverlay(tester, link: link, assets: page);

    expect(resolvedPoint(1), within(distance: 0.01, from: before));
  });

  testWidgets('right-clicking the cable adds a point there', (tester) async {
    await pumpOverlay(tester, link: link, assets: page);
    final mid = (resolvedPoint(0) + resolvedPoint(1)) / 2;

    await tester.tapAt(onCanvas(tester, mid), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Add point here'), findsOneWidget);

    await tester.tap(find.text('Add point here'));
    await tester.pumpAndSettle();

    expect(link.run.waypoints, hasLength(1));
  });

  testWidgets('dragging an end leaves every corner where it was',
      (tester) async {
    // The "it just goes nuts" report. Corners held in the run's frame swung
    // across the page with every pixel the end moved.
    final cable = _shortCableWithCorners();
    final onPage = <Asset>[cable];
    await pumpOverlay(tester, link: cable, assets: onPage);
    Offset at(int i) =>
        cable.run.resolve(_canvas, _anchorsFor(onPage)).points[i];
    final corners = [at(1), at(2), at(3)];
    final end = at(4);

    final gesture = await tester.startGesture(onCanvas(tester, end));
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(const Offset(25, -30));
      await tester.pump();
      for (var c = 0; c < 3; c++) {
        expect(at(c + 1), within(distance: 1, from: corners[c]),
            reason: 'corner $c moved during step $i of the end drag');
      }
    }
    await gesture.up();
    await tester.pumpAndSettle();
    for (var c = 0; c < 3; c++) {
      expect(at(c + 1), within(distance: 1, from: corners[c]));
    }
  });

  testWidgets('an end dropped just below a socket plugs into that socket',
      (tester) async {
    // A drive's sockets are on the edge of its box. Letting go a little
    // outside it used to land on empty canvas and unplug the cable.
    final drive = _Drive(x: 0.5, y: 0.45, name: 'Drive 2');
    page = [a, b, drive, link];
    await pumpOverlay(tester, link: link, assets: page);

    final portB = Offset((0.5 - 0.025 + 0.05 * 0.65) * _canvas.width,
        (0.45 + 0.2) * _canvas.height);
    final end = resolvedPoint(1);
    await tester.dragFrom(
        onCanvas(tester, end), portB + const Offset(0, 13) - end);
    await tester.pumpAndSettle();

    expect(link.run.to.assetId, drive.id);
    expect(link.run.to.port, 'B');
  });

  testWidgets('a dragged end snaps to a socket before it is dropped',
      (tester) async {
    final drive = _Drive(x: 0.5, y: 0.45, name: 'Drive 2');
    page = [a, b, drive, link];
    await pumpOverlay(tester, link: link, assets: page);

    final portA = Offset((0.5 - 0.025 + 0.05 * 0.35) * _canvas.width,
        (0.45 + 0.2) * _canvas.height);
    final end = resolvedPoint(1);
    final target = portA + const Offset(4, 12);
    final gesture = await tester.startGesture(onCanvas(tester, end));
    await gesture.moveBy((target - end) / 2);
    await gesture.moveBy((target - end) / 2);
    await tester.pump();

    expect(resolvedPoint(1), within(distance: 0.5, from: portA),
        reason: 'the end should sit on the socket it will plug into');
    expect(drive.id, isNull,
        reason: 'hovering must not give the device an id, only a drop');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(link.run.to.assetId, drive.id);
    expect(link.run.to.port, 'A');
  });

  testWidgets('a corner dropped near, but not on, a neighbour is kept',
      (tester) async {
    link.run.waypoints.add(LinkWaypoint.onRun(0.5, -0.3));
    await pumpOverlay(tester, link: link, assets: page);

    final corner = resolvedPoint(1);
    final end = resolvedPoint(0);
    await tester.dragFrom(
        onCanvas(tester, corner), end + const Offset(12, -12) - corner);
    await tester.pumpAndSettle();

    expect(link.run.waypoints, hasLength(1));
  });

  testWidgets('double-clicking the cable asks for its form', (tester) async {
    var opened = 0;
    await pumpOverlay(tester,
        link: link, assets: page, onConfigure: () => opened++);
    final quarter =
        resolvedPoint(0) + (resolvedPoint(1) - resolvedPoint(0)) / 4;

    await tester.tapAt(onCanvas(tester, quarter));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(onCanvas(tester, quarter));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('right-clicking the cable hands the spot to the editor',
      (tester) async {
    Offset? local;
    await pumpOverlay(tester,
        link: link, assets: page, onSecondaryTap: (l, _) => local = l);
    final quarter =
        resolvedPoint(0) + (resolvedPoint(1) - resolvedPoint(0)) / 4;

    await tester.tapAt(onCanvas(tester, quarter), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(local, within(distance: 0.5, from: quarter));
    expect(find.text('Add point here'), findsNothing,
        reason: 'the editor shows its own menu instead');
  });

  testWidgets('one drag is one undo step and one settle', (tester) async {
    var begins = 0, ends = 0;
    link.run.waypoints.add(LinkWaypoint.onRun(0.5, -0.2));
    await pumpOverlay(tester,
        link: link,
        assets: page,
        onBeginEdit: () => begins++,
        onEndEdit: () => ends++);

    final gesture =
        await tester.startGesture(onCanvas(tester, resolvedPoint(1)));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(10, 10));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(begins, 1);
    expect(ends, 1);
  });

  testWidgets('every edit reports a change so the page is re-encoded',
      (tester) async {
    // A drag that never told the editor would be lost on save, which is the
    // silent kind of broken.
    var changes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: _canvas.width,
            height: _canvas.height,
            child: Stack(children: [
              LinkEditOverlay(
                link: link,
                assets: page,
                canvas: _canvas,
                onBeginEdit: () {},
                onChanged: () => changes++,
              ),
            ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final mid = (resolvedPoint(0) + resolvedPoint(1)) / 2;
    await tester.dragFrom(onCanvas(tester, mid), const Offset(0, -100));
    await tester.pumpAndSettle();

    expect(changes, greaterThan(0));
  });
}

LinkAnchors _anchorsFor(List<Asset> assets) => PageLinkAnchors(assets, _canvas);

/// A short free cable with corners drawn well off to one side of it: its ends
/// 2 % of the page apart, its corners one to two run lengths away. The shape
/// that made every corner swing when an end was dragged.
EtherCatLinkConfig _shortCableWithCorners() => EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(x: 0.30, y: 0.70),
        to: LinkEnd(x: 0.32, y: 0.70),
        waypoints: [
          LinkWaypoint.onRun(0.10, 1.30),
          LinkWaypoint.onRun(0.50, 2.20),
          LinkWaypoint.onRun(0.80, 1.00),
        ],
      ),
    );
