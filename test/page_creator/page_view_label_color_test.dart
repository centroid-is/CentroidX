// Regression tests for `Asset.labelColor` consumption in `page_view.dart`.
//
// Bug being fixed: `ButtonConfig.textColor` round-trips through JSON and
// the editor exposes a Default/Custom toggle, but the label render in
// `AssetStack` uses `DefaultTextStyle.of(context).style` unconditionally —
// so the configured color never made it to the painted glyph.
//
// Contract under test:
//   - When the asset returns a non-null `labelColor`, the painted Text
//     widget's style.color MUST equal that color.
//   - When the asset returns null `labelColor`, the painted Text widget's
//     style.color MUST match the ambient DefaultTextStyle's color (i.e.
//     pre-field behaviour is preserved byte-for-byte).
//
// We use a private `_LabelColorTestAsset` (extends BaseAsset) so the test
// is fully self-contained and does not depend on the still-evolving
// ButtonConfig editor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Minimal test asset: a tiny ColoredBox with a label. Carries an optional
/// `labelColor` so tests can drive both the override-set and null cases
/// through the same widget tree.
class _LabelColorTestAsset extends BaseAsset {
  @override
  String get displayName => 'LabelColorTest';
  @override
  String get category => 'Test';

  final Color? _labelColor;

  _LabelColorTestAsset({
    Coordinates? coords,
    RelativeSize? sz,
    String? labelText,
    Color? labelColor,
  }) : _labelColor = labelColor {
    if (coords != null) coordinates = coords;
    if (sz != null) size = sz;
    if (labelText != null) text = labelText;
  }

  // Default in BaseAsset returns null; ButtonConfig overrides this with
  // its `textColor` field. We expose a parameterised override here so the
  // test asserts the page-view consumes whatever the asset reports.
  @override
  Color? get labelColor => _labelColor;

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF00AA00));

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {
        constAssetName: 'LabelColorTestAsset',
        'x': coordinates.x,
        'y': coordinates.y,
      };
}

/// Wraps an [AssetStack] with a known 200x200 viewport and a custom
/// ambient [DefaultTextStyle] so we can assert the "null override
/// inherits the ambient color" branch unambiguously.
Widget _wrap({
  required List<Asset> assets,
  Color ambientColor = const Color(0xFF000000),
}) {
  return ProviderScope(
    overrides: const [],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: DefaultTextStyle(
            // Pin the ambient style so the "null labelColor inherits
            // ambient" assertion is deterministic across themes.
            style: TextStyle(color: ambientColor, fontSize: 16),
            child: SizedBox(
              width: 200,
              height: 200,
              child: LayoutBuilder(
                builder: (context, constraints) => AssetStack(
                  assets: assets,
                  constraints: constraints,
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
}

/// Finds the single label Text rendered by `AssetStack` for our asset's
/// `text` field. There is exactly one in these tests because the asset
/// itself does not paint any internal Text widgets.
Finder _labelText(String text) => find.text(text);

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('AssetStack consumes Asset.labelColor', () {
    testWidgets(
      'non-null labelColor overrides the painted Text style.color',
      (tester) async {
        final asset = _LabelColorTestAsset(
          coords: Coordinates(x: 0.5, y: 0.5),
          sz: const RelativeSize(width: 0.2, height: 0.2),
          labelText: 'LBL',
          labelColor: const Color(0xFFFF0000), // red override
        );

        await tester.pumpWidget(_wrap(
          assets: [asset],
          ambientColor: const Color(0xFF000000), // black ambient
        ));
        await tester.pump();

        final textWidget = tester.widget<Text>(_labelText('LBL'));
        expect(textWidget.style?.color, const Color(0xFFFF0000),
            reason:
                'page_view must apply Asset.labelColor to the rendered label '
                'so ButtonConfig.textColor actually takes effect.');
      },
    );

    testWidgets(
      'null labelColor leaves the painted Text style.color at the ambient default',
      (tester) async {
        final asset = _LabelColorTestAsset(
          coords: Coordinates(x: 0.5, y: 0.5),
          sz: const RelativeSize(width: 0.2, height: 0.2),
          labelText: 'LBL',
          labelColor: null,
        );

        const ambient = Color(0xFF123456);
        await tester.pumpWidget(_wrap(
          assets: [asset],
          ambientColor: ambient,
        ));
        await tester.pump();

        final textWidget = tester.widget<Text>(_labelText('LBL'));
        expect(textWidget.style?.color, ambient,
            reason:
                'when labelColor is null the label must inherit the ambient '
                'DefaultTextStyle color — pre-field behaviour stays intact.');
      },
    );
  });
}
