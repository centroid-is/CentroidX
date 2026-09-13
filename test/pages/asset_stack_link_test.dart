import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// A visible block standing in for a terminal, so the stack has something with
/// a real box to position the cable against.
class _Block extends BaseAsset {
  _Block({required double x, required double y}) {
    coordinates = Coordinates(x: x, y: y);
    size = const RelativeSize(width: 0.1, height: 0.08);
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.blue);
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => const {};
}

/// The rect `AssetStack` gave [asset], in canvas pixels.
Rect frameOf(WidgetTester tester, Asset asset) {
  final finder = find.byKey(ObjectKey(asset), skipOffstage: false);
  expect(finder, findsOneWidget, reason: 'asset was not positioned at all');
  return tester.getRect(finder);
}

Future<void> pumpStack(WidgetTester tester, List<Asset> assets,
    {Size size = const Size(800, 600)}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
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
  );
  await tester.pump();
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    // AssetStack reads the page's mirror flags out of preferences on build.
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      'asset_stack_config': jsonEncode({'xMirror': false, 'yMirror': false}),
    });
  });

  testWidgets('a cable is positioned from the devices it plugs into',
      (tester) async {
    // Its own coordinates are the default 0.5/0.5 with a 3% box; if the stack
    // used those the frame would be a small square in the middle of the page
    // rather than a band spanning the two blocks.
    final a = _Block(x: 0.2, y: 0.3)..ensureId();
    final b = _Block(x: 0.8, y: 0.7)..ensureId();
    final cable = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      ),
    );

    await pumpStack(tester, [a, b, cable]);

    final frame = frameOf(tester, cable);
    // X2 on `a` is its right face (0.25), X1 on `b` its left (0.75).
    expect(frame.width, greaterThan(0.4 * 800));
    expect(frame.height, greaterThan(0.3 * 600));
  });

  testWidgets('moving a device moves the cable, without touching the cable',
      (tester) async {
    final a = _Block(x: 0.2, y: 0.3)..ensureId();
    final b = _Block(x: 0.8, y: 0.7)..ensureId();
    final cable = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      ),
    );

    await pumpStack(tester, [a, b, cable]);
    final before = frameOf(tester, cable);

    // Nothing on the cable is edited -- only the terminal moves.
    a.coordinates = Coordinates(x: 0.1, y: 0.1);
    await pumpStack(tester, [a, b, cable]);
    final after = frameOf(tester, cable);

    expect(after.left, lessThan(before.left));
    expect(after.top, lessThan(before.top));
  });

  testWidgets('the cable never writes its derived box back into its config',
      (tester) async {
    // AssetStack builds from a config that lives for the whole mount, and the
    // stack's own comment says a build must not edit it in place. The derived
    // box has to stay a local.
    final a = _Block(x: 0.2, y: 0.3)..ensureId();
    final b = _Block(x: 0.8, y: 0.7)..ensureId();
    final cable = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: a.id, port: 'X2'),
        to: LinkEnd(assetId: b.id, port: 'X1'),
      ),
    );
    final storedX = cable.coordinates.x;
    final storedW = cable.size.width;

    await pumpStack(tester, [a, b, cable]);

    expect(cable.coordinates.x, storedX);
    expect(cable.size.width, storedW);
  });

  testWidgets('every other asset still sits where it was dropped',
      (tester) async {
    // boxOn is additive: a page without a cable must position identically.
    final a = _Block(x: 0.25, y: 0.5)..ensureId();
    await pumpStack(tester, [a]);
    final frame = frameOf(tester, a);
    expect(frame.center.dx, closeTo(0.25 * 800, 1.0));
    expect(frame.center.dy, closeTo(0.5 * 600, 1.0));
    expect(frame.width, closeTo(0.1 * 800, 1.0));
  });

  testWidgets('a cable whose devices are gone still draws somewhere sane',
      (tester) async {
    // Both terminals deleted out from under it. The ends fall back to their
    // stored coordinates rather than collapsing onto the origin.
    final cable = EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: 'gone-a', port: 'X2', x: 0.2, y: 0.4),
        to: LinkEnd(assetId: 'gone-b', port: 'X1', x: 0.7, y: 0.6),
      ),
    );
    await pumpStack(tester, [cable]);

    final frame = frameOf(tester, cable);
    expect(frame.width, greaterThan(0.4 * 800));
    expect(frame.left, greaterThan(0));
  });

  testWidgets('the page is published to the assets inside it', (tester) async {
    // PageAssetsScope is how a cable finds its devices at all; without it the
    // run silently falls back to LinkAnchors.none and draws between its own
    // stored coordinates, which looks plausible and is wrong.
    final a = _Block(x: 0.2, y: 0.3)..ensureId();
    await pumpStack(tester, [a]);

    final scope = tester.firstWidget<PageAssetsScope>(
        find.byType(PageAssetsScope, skipOffstage: false));
    expect(scope.assets, contains(a));
    expect(scope.canvas, const Size(800, 600));
  });
}
