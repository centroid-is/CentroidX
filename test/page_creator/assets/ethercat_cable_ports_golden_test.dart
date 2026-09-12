/// Where a cable actually lands on a device.
///
/// Every other cable golden in this suite poses the run against hand-written
/// anchors — `ethercat_link_golden_test.dart` defines a `_Devices` that
/// answers `X1` with the left edge and anything else with the right one. That
/// is fine for checking the *shape* of a run, and useless for checking the one
/// thing this layer adds: that an end plugs into the socket the hardware
/// really has.
///
/// The sockets are not where the fake assumes. An EK1100 carries both A (in)
/// and C (out) on its *left* face, a third of the way down and two thirds
/// down, with B on the right for the E-bus. An ATV320 carries A and B on its
/// *bottom* face, because that is where a drive's RJ45s are. Under the
/// hand-written anchors every one of those would come out of the middle of the
/// wrong edge, and no test in the repo would notice.
///
/// So these goldens drive the real [PageLinkAnchors] through [AssetStack], the
/// same path a page takes, and the picture is the assertion: the cable ends
/// touch the sockets or they do not.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/page_creator/assets/schneider.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/theme.dart';

import '../../helpers/ethercat_fake_state_man.dart';
import '../../helpers/golden_fonts.dart';
import '../../helpers/golden_platform.dart';
import '../../helpers/golden_tolerance.dart';

const _key = Key('ethercat_cable_ports');

/// A cable between two named sockets, drawn idle: `key` is empty, so nothing
/// is subscribed and the run paints in the neutral colour. The point here is
/// geometry, and a health colour would only make the two goldens differ for a
/// reason that has nothing to do with where the ends are.
EtherCatLinkConfig _cable({
  required Asset from,
  required String fromPort,
  required Asset to,
  required String toPort,
  List<LinkWaypoint> waypoints = const [],
}) =>
    EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: from.ensureId(), port: fromPort),
        to: LinkEnd(assetId: to.ensureId(), port: toPort),
        // Waypoints live in the run's own frame — t along the port-to-port
        // axis, n across it — so a corner stays put relative to the cable when
        // either device moves.
        waypoints: [...waypoints],
      ),
      thickness: 0.005,
    );

T _place<T extends Asset>(T asset,
    {required double x,
    required double y,
    required double w,
    required double h,
    double? angle}) {
  asset.coordinates = Coordinates(x: x, y: y, angle: angle);
  asset.size = RelativeSize(width: w, height: h);
  asset.ensureId();
  return asset;
}

Future<void> pumpPage(WidgetTester tester, List<Asset> assets,
    {Size size = const Size(760, 420)}) async {
  final (light, _) = solarized();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [stateManProvider.overrideWith((ref) async => EcFakeStateMan())],
      child: MaterialApp(
        theme: light,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFFFDF6E3),
          body: Center(
            child: RepaintBoundary(
              key: _key,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: AssetStack(
                  assets: assets,
                  constraints: BoxConstraints.tight(size),
                  selectedAssets: const {},
                  mirroringDisabled: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  useTolerantGoldenComparator();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      'asset_stack_config': jsonEncode({'xMirror': false, 'yMirror': false}),
    });
  });

  group('EtherCAT cables on their real sockets',
      skip: goldenSkip, () {
    testWidgets('a coupler, its E-bus, and a branch down to two drives',
        (tester) async {
      await loadGoldenFonts();

      // The coupler. A and C are both on its left face — in at 0.3, out at
      // 0.7 — and B is the E-bus leaving to the right.
      final coupler = _place(BeckhoffEK1100Config()..nameOrId = 'ST101.A1.00',
          x: 0.14, y: 0.28, w: 0.10, h: 0.46);

      // The terminal the E-bus lands on: A left, B right.
      final terminal = _place(BeckhoffEL1008Config(nameOrId: 'ST101.A1.01'),
          x: 0.30, y: 0.28, w: 0.08, h: 0.46);

      // Two drives. Their sockets are underneath, at 0.35 and 0.65 across the
      // bottom face, so a cable to a drive has to come up from below it.
      final drive1 = _place(SchneiderATV320Config(label: 'CVS01.CN01.FD01'),
          x: 0.52, y: 0.70, w: 0.058, h: 0.34);
      final drive2 = _place(SchneiderATV320Config(label: 'CVS01.CN02.FD01'),
          x: 0.80, y: 0.70, w: 0.058, h: 0.34);

      final assets = <Asset>[
        coupler,
        terminal,
        drive1,
        drive2,
        // E-bus: the coupler's right face to the terminal's left.
        _cable(from: coupler, fromPort: 'B', to: terminal, toPort: 'A'),
        // The branch out of the coupler's lower-left socket, round the corner
        // and up into the first drive's underside.
        _cable(
          from: coupler,
          fromPort: 'C',
          to: drive1,
          toPort: 'A',
          waypoints: [LinkWaypoint.onRun(0.35, 0.45)],
        ),
        // Drive to drive, both ends on the bottom face.
        _cable(from: drive1, fromPort: 'B', to: drive2, toPort: 'A'),
      ];

      await pumpPage(tester, assets);
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_cable_ports.png'));
    });

    // No rotated golden here on purpose. `PageLinkAnchors` turns a port about
    // its asset, but nothing in `beckhoff.dart` reads `coordinates.angle` —
    // every Beckhoff part draws upright whatever angle it is given. A golden
    // of a turned EK1100 would therefore show the cable leaving from thin air
    // beside an upright coupler, and pinning that as expected output would
    // make it look intended. The rotation arithmetic keeps its unit tests in
    // `link_anchors_test.dart`; the mismatch is raised on the PR.
  });
}
