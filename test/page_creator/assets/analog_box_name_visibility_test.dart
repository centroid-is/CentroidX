// An analog box's name is two things at once — the caption painted beside the
// bar on the mimic, and the title of the side pane the bar opens. Before this
// they shared one field, so naming a box for its pane unavoidably stamped a
// caption on the page, and clearing the caption left the pane titled "Analog
// value".
//
// `AnalogBoxConfig.showName` separates them, exactly as
// `SectionButtonConfig.showName` already does. Contract under test:
//   - true by default, and true for JSON saved before the field existed, so
//     no placed box changes appearance;
//   - `showLabel` (what `AssetStack` asks) follows it;
//   - off hides the caption on the page without un-naming the box: the pane
//     is still titled with the same string;
//   - it round-trips through JSON, sits in the editor form, and can be set on
//     a row of boxes at once through `bulkProperties`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// A placed, named box with no keys bound: every stream is unconfigured, so
/// the bar paints its static self and no `StateMan` is needed.
AnalogBoxConfig _box({required bool showName}) => AnalogBoxConfig(
      analogKey: '',
      units: 'l',
      showName: showName,
    )
      ..text = 'Tank level'
      ..textPos = TextPos.below
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.2, height: 0.2);

Widget _page(List<Asset> assets) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
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
    );

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
  });

  group('the default', () {
    test('a new box shows its name', () {
      // The caption is the default. A switch that started off would silently
      // strip every box an operator adds from now on.
      final fresh = AnalogBoxConfig(analogKey: 'some.key');
      expect(fresh.showName, isTrue);
      expect(fresh.showLabel, isTrue);
      expect(AnalogBoxConfig.preview().showName, isTrue);
    });

    test('a page saved before the switch existed keeps its caption', () {
      final legacy = _box(showName: true).toJson()..remove('show_name');
      final back = AnalogBoxConfig.fromJson(legacy);
      expect(back.showName, isTrue,
          reason: 'every box on a placed page has a caption today');
      expect(back.showLabel, isTrue);
    });

    test('the choice round-trips through JSON', () {
      final json = _box(showName: false).toJson();
      expect(json['show_name'], isFalse);
      final back = AnalogBoxConfig.fromJson(json);
      expect(back.showName, isFalse);
      expect(back.showLabel, isFalse);
      expect(back.text, 'Tank level',
          reason: 'hiding the caption must not throw the name away');
    });
  });

  group('showLabel follows the flag', () {
    test('off hides the caption without clearing the name', () {
      final cfg = _box(showName: false);
      expect(cfg.showLabel, isFalse,
          reason: 'the page asks showLabel, not showName');
      expect(cfg.text, 'Tank level');
    });

    testWidgets('the page paints the caption when it is on', (tester) async {
      await tester.pumpWidget(_page([_box(showName: true)]));
      await tester.pump();
      expect(find.text('Tank level'), findsOneWidget);
    });

    testWidgets('the page paints no caption when it is off', (tester) async {
      await tester.pumpWidget(_page([_box(showName: false)]));
      await tester.pump();
      expect(find.text('Tank level'), findsNothing);
    });
  });

  testWidgets('a hidden caption still titles the pane', (tester) async {
    // The whole point: the name survives to head the pane, which is what the
    // page author named the box for.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 380,
            height: 760,
            child: AnalogBoxPane(
              config: _box(showName: false),
              value: 42,
              onWrite: (_, __) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Tank level'), findsOneWidget);
  });

  group('the editor form', () {
    // Built through the asset's own `configure()`, so a toggle that never
    // made it into the form fails here rather than passing on the field
    // alone.
    Future<void> pumpEditor(WidgetTester tester, AnalogBoxConfig cfg) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              child: Builder(builder: cfg.configure),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // The form is taller than the test surface; the switch sits below the
      // fold, where a tap would silently miss it.
      await tester.ensureVisible(find.byKey(const Key('analog-name-visible')));
      await tester.pumpAndSettle();
    }

    testWidgets('starts on the choice the config already has', (tester) async {
      final cfg = _box(showName: false);
      await pumpEditor(tester, cfg);
      expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const Key('analog-name-visible')))
            .value,
        isFalse,
      );

      await tester.tap(find.byKey(const Key('analog-name-visible')));
      await tester.pump();
      expect(cfg.showName, isTrue);
      expect(cfg.text, 'Tank level',
          reason: 'the switch hides the caption, it does not rename the box');
    });
  });

  group('bulk editing', () {
    test('a row of boxes can be set at once', () {
      // A row of these is configured together — that is what bulk properties
      // are for, and the caption is exactly the kind of thing set for a whole
      // row rather than one box at a time.
      final boxes = [
        _box(showName: true),
        _box(showName: true),
        _box(showName: true),
      ];
      for (final box in boxes) {
        final prop = box.bulkProperties
            .whereType<BoolBulkProperty>()
            .firstWhere((p) => p.id == 'AnalogBoxConfig.showName');
        expect(prop.read(), isTrue);
        prop.apply(false);
      }
      expect(boxes.every((b) => b.showName == false), isTrue);
      expect(boxes.every((b) => b.showLabel == false), isTrue);
      expect(boxes.every((b) => b.text == 'Tank level'), isTrue);
    });
  });
}
