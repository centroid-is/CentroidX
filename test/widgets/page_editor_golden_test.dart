/// Golden images of the page editor, for design review.
///
/// Each golden renders the real editor on a 1920×1080 operator panel — the
/// size the plant actually runs — in the app's own theme, so what is under
/// review is how the surface sits on a real screen rather than a widget in
/// isolation.
///
/// Three things are being reviewed here:
///
///   * **The asset config pane.** It replaced a modal dialog, so the thing to
///     look at is what stays visible and reachable beside it: the canvas, the
///     asset being edited and the page selector.
///   * **Unpublished pages.** A draft has to be obvious in two places — the
///     Pages dialog where it is toggled, and the canvas where the page is
///     built — or it gets left switched off.
///   * **One editing mode.** The pan/select toggle is gone, so a tap selects
///     and configuring moved into the right-click menu. What to look at is
///     the canvas chrome where the toggle used to sit, and the menu that
///     took over from it.
///
/// The dense-editor golden is deliberately a Beckhoff bus coupler: a
/// two-column subdevice manager is the widest config editor there is, and it
/// is the one that decided the pane's default width.
///
/// Every case pumps through [testGoldenWidgets] rather than `testWidgets`,
/// which pins the scaffold's header clock. Without it these goldens re-render
/// a new timestamp on every run and none of them can ever match.
///
/// To update: flutter test test/widgets/page_editor_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tfc/core/startup_url.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/drawn_box.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/text.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/theme.dart';

import '../helpers/page_editor_harness.dart';
import 'package:tfc/providers/preferences.dart'
    show createDeviceLocalPreferences;

/// A 1080p operator panel.
const Size _screen = Size(1920, 1080);

/// Pumps the real editor at panel size with [pages] on it.
Future<void> _pumpEditor(
  WidgetTester tester, {
  required ThemeData theme,
  required Map<String, AssetPage> pages,
  String? select,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(buildEditorUnderTest(
    PageManager(prefs: FakeEditorPreferences(), pages: pages),
    theme: theme,
  ));
  await tester.pumpAndSettle();

  if (select != null) {
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.text(select));
    await tester.pumpAndSettle();
  }
}

/// A one-page map holding [assets].
Map<String, AssetPage> _onePage(List<Asset> assets) => {
      '/': AssetPage(
        menuItem: const MenuItem(label: 'Chiller', path: '/', icon: Icons.home),
        assets: assets,
        mirroringDisabled: true,
        navigationPriority: 0,
      ),
    };

/// A section holding a published page and a draft, so the Pages dialog shows
/// both states side by side.
Map<String, AssetPage> _pagesWithADraft() => {
      '/': AssetPage(
        menuItem:
            const MenuItem(label: 'Overview', path: '/', icon: Icons.home),
        assets: [],
        mirroringDisabled: true,
        navigationPriority: 0,
      ),
      '/lines': AssetPage(
        menuItem: const MenuItem(
          label: 'Lines',
          path: '/lines',
          icon: Icons.account_tree,
          isSection: true,
          children: [
            MenuItem(
                label: 'Line 1', path: '/lines/one', icon: Icons.conveyor_belt),
            MenuItem(
                label: 'Chiller', path: '/lines/chiller', icon: Icons.ac_unit),
          ],
        ),
        assets: [],
        mirroringDisabled: true,
        navigationPriority: 1,
      ),
      '/lines/one': AssetPage(
        menuItem: const MenuItem(
            label: 'Line 1', path: '/lines/one', icon: Icons.conveyor_belt),
        assets: [],
        mirroringDisabled: true,
        navigationPriority: 0,
      ),
      '/lines/chiller': AssetPage(
        menuItem: const MenuItem(
            label: 'Chiller', path: '/lines/chiller', icon: Icons.ac_unit),
        assets: [],
        mirroringDisabled: true,
        navigationPriority: 1,
        published: false,
      ),
    };

/// Opens the config pane for the asset drawn at canvas-relative ([fx], [fy]).
///
/// Right-click, then "Edit". A plain tap used to do this, back when the editor
/// had a mode in which tapping selected instead; with one mode a tap always
/// selects, so configuring lives in the menu.
Future<void> _openConfigPane(WidgetTester tester, double fx, double fy) =>
    chooseFromAssetMenu(tester, fx, fy, 'Edit');

Asset _textAsset() => TextAssetConfig.preview()
  ..coordinates = Coordinates(x: 0.22, y: 0.35)
  ..size = const RelativeSize(width: 0.16, height: 0.09)
  ..text = 'Brine temperature';

Asset _busCoupler() => BeckhoffEK1100Config()
  ..coordinates = Coordinates(x: 0.22, y: 0.4)
  ..size = const RelativeSize(width: 0.22, height: 0.28);

/// Dashed, so the dash-length and dash-spacing sliders are on show too.
Asset _drawnBox() => DrawnBoxConfig.preview()
  ..coordinates = Coordinates(x: 0.22, y: 0.4)
  ..size = const RelativeSize(width: 0.18, height: 0.12);

/// A labelled box at ([x], [y]).
Asset _labelledBox(double x, double y, String label, {double? angle}) =>
    DrawnBoxConfig.preview()
      ..coordinates = Coordinates(x: x, y: y, angle: angle)
      ..size = const RelativeSize(width: 0.13, height: 0.09)
      ..text = label
      ..textPos = TextPos.inside;

/// A short conveyor line — enough assets to select several of, and the shape
/// of page the selection actions exist for.
List<Asset> _line() => [
      _labelledBox(0.16, 0.30, 'CN01'),
      _labelledBox(0.36, 0.30, 'CN02'),
      _labelledBox(0.56, 0.30, 'CN03'),
      _labelledBox(0.16, 0.62, 'ST101'),
      _labelledBox(0.36, 0.62, 'ST201', angle: 45),
      _labelledBox(0.56, 0.62, 'ST301'),
    ];

void main() {
  final (light, dark) = solarized();

  // Same font wiring as `panes_golden_test.dart`: the themes ask for
  // 'roboto-mono' by name, and MaterialIcons is not registered in the test
  // environment — without both, the goldens render as Ahem blocks.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        (Platform.resolvedExecutable.contains('flutter')
            ? null
            : File(Platform.resolvedExecutable).parent.path);
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  setUp(setUpEditorEnvironment);

  group('asset config pane', () {
    testGoldenWidgets('editor with no pane — the canvas as it was', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage([_textAsset()]));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_canvas_dark.png'),
      );
    });

    testGoldenWidgets('text asset — dark', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage([_textAsset()]));
      await _openConfigPane(tester, 0.22, 0.35);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_config_pane_text_dark.png'),
      );
    });

    testGoldenWidgets('text asset — light', (tester) async {
      await _pumpEditor(tester, theme: light, pages: _onePage([_textAsset()]));
      await _openConfigPane(tester, 0.22, 0.35);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_config_pane_text_light.png'),
      );
    });

    // Sliders now carry an editable field, because 1% of a track this narrow
    // is about a pixel and an exact value was not reachable by dragging. The
    // drawn box is the one to look at: three sliders, label beside the track,
    // so the field has the least room to fit in.
    testGoldenWidgets('sliders with typed values', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage([_drawnBox()]));
      await _openConfigPane(tester, 0.22, 0.4);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_config_pane_sliders_dark.png'),
      );
    });

    // An asset far enough right that the pane would sit on top of it. What is
    // under review: the whole canvas has re-fitted itself beside the pane —
    // the page smaller but complete, daylight between canvas and pane, the
    // asset in plain view, and the pane at its full preferred width.
    testGoldenWidgets('the canvas insets beside the pane it opened', (tester) async {
      await _pumpEditor(
        tester,
        theme: dark,
        pages: _onePage([_labelledBox(0.72, 0.4, 'CN04')]),
      );
      await _openConfigPane(tester, 0.72, 0.4);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_config_pane_inset.png'),
      );
    });

    // The widest editor in the registry: two columns, a subdevice list and a
    // dropdown. If the pane's default width is wrong, it shows here first.
    testGoldenWidgets('bus coupler — the densest editor', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage([_busCoupler()]));
      await _openConfigPane(tester, 0.22, 0.4);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_config_pane_dense_dark.png'),
      );
    });
  });

  group('unpublished pages', () {
    testGoldenWidgets('Pages dialog — a draft beside a published page',
        (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _pagesWithADraft());
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_pages_draft_dark.png'),
      );
    });

    // The startup-page toggle shares this dialog: a lit rocket and a
    // "Startup page — this station" subtitle on the chosen row, hollow
    // rockets on every other page row, none on sections.
    testGoldenWidgets('Pages dialog — a nested page chosen as startup',
        (tester) async {
      // Into the store the dialog reads, which since v1.2 plan 01-05 is the
      // one `setUpEditorEnvironment` seeds, not the platform instance.
      await createDeviceLocalPreferences()
          .setString(startupUrlPrefsKey, '/lines/one');
      await _pumpEditor(tester, theme: dark, pages: _pagesWithADraft());
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_pages_startup_dark.png'),
      );
    });

    testGoldenWidgets('canvas — editing a draft page', (tester) async {
      await _pumpEditor(
        tester,
        theme: dark,
        pages: _pagesWithADraft(),
        select: 'Chiller',
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_draft_badge_dark.png'),
      );
    });
  });

  group('asset palette', () {
    testGoldenWidgets('the full grid', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage(_line()));
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_palette_dark.png'),
      );
    });

    // "multivac" names no tile — the machine lives inside the 3rd-party
    // umbrella asset. The search matches the per-kind keywords, so the tile
    // that CAN become a Multivac is the one result.
    testGoldenWidgets('searching for a machine hidden in an umbrella tile',
        (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage(_line()));
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'multivac');
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_palette_multivac_dark.png'),
      );
    });
  });

  group('one editing mode', () {
    testGoldenWidgets('a marquee selection, with no mode to enter first',
        (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage(_line()));

      // This same drag would have panned the canvas before. The bottom-right
      // chrome, where the pan/select toggle used to sit, now holds only the
      // grow/shrink pair — and only while something is selected.
      await marquee(tester, 0.05, 0.12, 0.68, 0.45);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_selection_dark.png'),
      );
    });

    // The modifier-held marquee, caught mid-drag: the top row was selected,
    // and a second rubber band with Ctrl/Cmd held is passing over CN02. What
    // to look at is that CN02's selection border is gone while the box covers
    // it — the marquee toggles against the selection — and CN01/CN03 keep
    // theirs.
    testGoldenWidgets('a modifier marquee mid-drag, toggling one asset out',
        (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage(_line()));
      await marquee(tester, 0.05, 0.12, 0.68, 0.45);

      await tester.sendKeyDownEvent(editorModifier);
      final gesture = await tester.startGesture(onCanvas(tester, 0.28, 0.14));
      await tester.pump();
      await gesture.moveTo(onCanvas(tester, 0.33, 0.20));
      await tester.pump();
      await gesture.moveTo(onCanvas(tester, 0.44, 0.38));
      await tester.pump();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_marquee_toggle_dark.png'),
      );

      await gesture.up();
      await tester.sendKeyUpEvent(editorModifier);
      await tester.pumpAndSettle();
    });

    testGoldenWidgets('the asset context menu', (tester) async {
      await _pumpEditor(tester, theme: dark, pages: _onePage(_line()));
      await marquee(tester, 0.05, 0.12, 0.68, 0.45);

      await tester.tapAt(onCanvas(tester, 0.36, 0.30),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/page_editor_context_menu_dark.png'),
      );

      // Dismiss, so no route outlives the test.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
    });
  });
}
