import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Z-order in the page editor is list order: `AssetStack` renders
/// `AssetPage.assets` in sequence, so the head of the list is the back of the
/// stack. "Send to back" therefore moves the selection to the head.
///
/// These cover the ordering itself; the helpers are generic so the algorithm
/// can be exercised without building real assets.
void main() {
  group('sendToBackOrder', () {
    test('moves a single asset to the head', () {
      expect(sendToBackOrder(['a', 'b', 'c'], {'c'}), ['c', 'a', 'b']);
    });

    test('leaves an asset already at the back alone', () {
      expect(sendToBackOrder(['a', 'b', 'c'], {'a'}), ['a', 'b', 'c']);
    });

    test('preserves relative order within the selection', () {
      // b before d in the input, so b stays before d in the result.
      expect(
        sendToBackOrder(['a', 'b', 'c', 'd'], {'d', 'b'}),
        ['b', 'd', 'a', 'c'],
      );
    });

    test('preserves relative order of the assets left behind', () {
      expect(
        sendToBackOrder(['a', 'b', 'c', 'd', 'e'], {'c'}),
        ['c', 'a', 'b', 'd', 'e'],
      );
    });

    test('handles a non-contiguous selection', () {
      expect(
        sendToBackOrder(['a', 'b', 'c', 'd', 'e'], {'a', 'c', 'e'}),
        ['a', 'c', 'e', 'b', 'd'],
      );
    });

    test('moving everything is a no-op', () {
      expect(sendToBackOrder(['a', 'b'], {'a', 'b'}), ['a', 'b']);
    });

    test('ignores targets that are not on the page', () {
      expect(sendToBackOrder(['a', 'b'], {'zz'}), ['a', 'b']);
    });

    test('does not modify the input list', () {
      final input = ['a', 'b', 'c'];
      sendToBackOrder(input, {'c'});
      expect(input, ['a', 'b', 'c']);
    });
  });

  group('isAlreadyAtBack', () {
    test('true for the bottom-most asset', () {
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'a'}), isTrue);
    });

    test('false for anything above it', () {
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'b'}), isFalse);
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'c'}), isFalse);
    });

    test('true for a contiguous run at the back', () {
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'a', 'b'}), isTrue);
    });

    test('false when the run is contiguous but not at the back', () {
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'b', 'c'}), isFalse);
    });

    test('false for a non-contiguous selection touching the back', () {
      expect(isAlreadyAtBack(['a', 'b', 'c'], {'a', 'c'}), isFalse);
    });

    test('true when every asset is selected', () {
      expect(isAlreadyAtBack(['a', 'b'], {'a', 'b'}), isTrue);
    });

    test('true for an empty selection — nothing to move', () {
      expect(isAlreadyAtBack(['a', 'b'], <String>{}), isTrue);
    });

    test('true for an empty page', () {
      expect(isAlreadyAtBack(<String>[], {'a'}), isTrue);
    });

    test('agrees with sendToBackOrder being a no-op', () {
      // The predicate exists to disable the menu entry, so it must be exactly
      // the cases where reordering would change nothing.
      const page = ['a', 'b', 'c', 'd'];
      for (final targets in [
        {'a'},
        {'b'},
        {'c'},
        {'a', 'b'},
        {'b', 'c'},
        {'a', 'c'},
        {'a', 'b', 'c', 'd'},
        <String>{},
      ]) {
        final unchanged =
            sendToBackOrder(page, targets).toString() == page.toString();
        expect(isAlreadyAtBack(page, targets), unchanged,
            reason: 'mismatch for targets $targets');
      }
    });
  });

  _secondaryTapTests();
}

/// Minimal asset so the stack can be driven without real PLC state.
class _TestBoxAsset extends BaseAsset {
  @override
  String get displayName => 'TestBox';
  @override
  String get category => 'Test';

  final String name;

  /// Mirrors production assets that wrap their visual in their own
  /// GestureDetector; used to prove a tap coordinate is really on the asset.
  final VoidCallback? onInternalTap;

  _TestBoxAsset(this.name, {required Coordinates coords, this.onInternalTap}) {
    coordinates = coords;
    size = const RelativeSize(width: 0.2, height: 0.2);
  }

  @override
  Widget build(BuildContext context) {
    const visual = ColoredBox(color: Color(0xFFFF0000));
    if (onInternalTap == null) return visual;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onInternalTap,
      child: visual,
    );
  }

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: 'TestBoxAsset'};
}

Widget _wrapStack({
  required List<Asset> assets,
  void Function(Asset, Offset)? onSecondaryTap,
  bool absorb = true,
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: LayoutBuilder(
              builder: (context, constraints) => AssetStack(
                assets: assets,
                constraints: constraints,
                selectedAssets: const {},
                mirroringDisabled: true,
                onSecondaryTap: onSecondaryTap,
                absorb: absorb,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A point at relative ([fx], [fy]) within the rendered stack.
Offset _pointOn(WidgetTester tester, double fx, double fy) {
  final r = tester.getRect(find.byType(AssetStack));
  return Offset(r.left + r.width * fx, r.top + r.height * fy);
}

/// Guards the wiring the unit tests above cannot reach: the host-supplied
/// context menu must take precedence over the AI-only one, so "Send to back"
/// is reachable whether or not MCP chat is available.
void _secondaryTapTests() {
  group('AssetStack secondary tap', () {
    setUp(() {
      useInMemoryDeviceLocalPreferences();
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    testWidgets('right-click in edit mode reports the asset to the host',
        (tester) async {
      final left = _TestBoxAsset('left', coords: Coordinates(x: 0.25, y: 0.5));
      final right =
          _TestBoxAsset('right', coords: Coordinates(x: 0.75, y: 0.5));

      final taps = <String>[];
      await tester.pumpWidget(_wrapStack(
        assets: [left, right],
        onSecondaryTap: (asset, _) => taps.add((asset as _TestBoxAsset).name),
      ));
      await tester.pumpAndSettle();

      // Compute from the real rect: the stack is centred in the test window,
      // so hard-coded offsets would miss (and silently pass).
      await tester.tapAt(_pointOn(tester, 0.75, 0.5),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(taps, ['right'],
          reason: 'host callback should receive the right-clicked asset');
    });

    testWidgets('is ignored in runtime mode', (tester) async {
      // Runtime mode is the operator-facing path, where secondary tap belongs
      // to the debug/chat menu. A host callback must not silently take it
      // over and change what operators get.
      var internalTaps = 0;
      final asset = _TestBoxAsset(
        'a',
        coords: Coordinates(x: 0.5, y: 0.5),
        onInternalTap: () => internalTaps++,
      );

      final taps = <String>[];
      await tester.pumpWidget(_wrapStack(
        assets: [asset],
        absorb: false,
        onSecondaryTap: (a, _) => taps.add('fired'),
      ));
      await tester.pumpAndSettle();

      final point = _pointOn(tester, 0.5, 0.5);
      // Prove the coordinate is on the asset, so the secondary-tap assertion
      // below is a real result rather than a miss.
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(internalTaps, 1, reason: 'coordinate should be on the asset');

      await tester.tapAt(point, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(taps, isEmpty,
          reason: 'onSecondaryTap is documented as edit-mode only');
    });

    testWidgets('does not fire on a primary tap', (tester) async {
      final asset = _TestBoxAsset('a', coords: Coordinates(x: 0.5, y: 0.5));

      final taps = <String>[];
      await tester.pumpWidget(_wrapStack(
        assets: [asset],
        onSecondaryTap: (a, _) => taps.add('fired'),
      ));
      await tester.pumpAndSettle();

      final point = _pointOn(tester, 0.5, 0.5);
      // Sanity: a secondary tap here *does* land on the asset, so the primary
      // tap below is a real miss rather than a mis-aimed one.
      await tester.tapAt(point, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(taps, ['fired'], reason: 'coordinate should be on the asset');
      taps.clear();

      await tester.tapAt(point);
      await tester.pumpAndSettle();

      expect(taps, isEmpty);
    });
  });
}
