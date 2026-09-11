/// The Transport card's save button is the **one** indicator of unsaved
/// state — and its unsaved face must be legible in both brightnesses of both
/// station schemes.
///
/// This file used to pin the card's `_UnsavedPill` (the `Unsaved` marker in
/// the tile's trailing slot). The owner ruled the pill out of existence: the
/// three-state save button (`Save Configuration` / `All Changes Saved` /
/// `Cannot save yet`) already carries the unsaved fact, and a second spelling
/// of one fact is the duplication this codebase deletes on principle. The
/// arms are retargeted, not deleted — the property worth keeping was never
/// "the pill exists", it was "the thing that says *unsaved* is readable".
///
/// Two properties are pinned here, per theme:
///
///  1. **The pill stays dead.** After an edit to the transport mode, no
///     `Unsaved` text appears anywhere on the page — the save button's label
///     and enabled state are the sole spelling of the fact.
///  2. **The unsaved label reads at 3:1 or better against the button's own
///     fill** — WCAG 1.4.11's minimum for UI components. Phase 15-07's golden
///     review already caught one illegible unsaved marker ("dark-red-on-red …
///     the lowest-contrast element in any of the 26 images"); the button is
///     now the only unsaved surface left, so it inherits the guard.
///
/// A golden is not a substitute for these arms: a suite that generates its
/// own frames cannot notice that the frame it generated is illegible, and the
/// `server_config_transport_advisory*` goldens contained the old chip for a
/// whole phase without failing anything.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import 'package:tfc/theme.dart';

import '../helpers/test_helpers.dart';

/// WCAG relative-luminance contrast ratio, 1.0 (none) to 21.0 (black/white).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The save button's rendered label colour and its resolved fill, composited
/// over the card it sits on.
///
/// Reads the *resolved* colours, not the widget's inputs: the button's
/// unsaved state passes `backgroundColor: null` and lets the theme decide,
/// and whatever the theme decides is exactly what the operator is reading.
/// The fill is taken from the button's own [Material] — the surface the
/// framework actually paints — rather than re-deriving M3 defaults here.
({Color label, Color fill}) _saveButtonColours(
    WidgetTester tester, ThemeData theme) {
  final text = find.text('Save Configuration');
  final label = tester.renderObject<RenderParagraph>(text).text.style?.color;
  expect(label, isNotNull,
      reason: 'the save button label must resolve to a colour');

  final material = tester.widget<Material>(
      find.ancestor(of: text, matching: find.byType(Material)).first);
  final rawFill = material.color;
  expect(rawFill, isNotNull,
      reason: 'the save button must paint a fill — its Material is the '
          'surface the label sits on');

  // What the operator actually sees behind the label: a translucent fill is
  // composited over the card the tile lives on (M3 cards default to
  // `surfaceContainerLow`, which both station schemes set).
  final card = theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;
  return (
    label: label!,
    fill: Color.alphaBlend(rawFill!, card),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());

    // The Import/Export card at the bottom of the page reads PackageInfo in
    // initState; unmocked it throws MissingPluginException mid-pump.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (call) async => <String, dynamic>{
        'appName': 'tfc',
        'packageName': 'is.centroid.tfc',
        'version': '0.0.0',
        'buildNumber': '0',
      },
    );
  });

  /// Pumps the page under [theme] and edits the transport mode by hand, so
  /// `_hasUnsavedChanges` is genuinely true and the save button is showing
  /// its unsaved face.
  Future<void> pumpUnsaved(WidgetTester tester, ThemeData theme) async {
    await tester.binding.setSurfaceSize(const Size(800, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAndLoad(tester, buildTestableServerConfig(theme: theme));
    await tester.tap(find.text('Transport'));
    await settle(tester);
    await tester.tap(find.text('Relay gateway'));
    await settle(tester);
    // A gateway with no address is a refusal ('Cannot save yet'), which is a
    // different face of the button. Type a dialable address so the state
    // under test really is unsaved-and-valid. No CA anything: since the
    // one-field flow, trust is fetched and approved at Save, so an unpinned
    // wss address is exactly the unsaved-and-valid state.
    await tester.enterText(
        find.byType(TextField).first, 'wss://10.50.10.11:9443');
    await settle(tester);

    // Anti-vacuity: everything below is only a statement about the unsaved
    // state if the page is genuinely in it. The label and the enabled state
    // together are the button's unsaved face — `All Changes Saved` is
    // disabled and grey, `Cannot save yet` is a refusal; this is neither.
    // (The section save buttons only render once a section holds servers,
    // and this page starts empty — the one `Save Configuration` on screen
    // is the Transport card's.)
    final save = find.ancestor(
        of: find.text('Save Configuration'),
        matching: find.byType(ElevatedButton));
    expect(save, findsOneWidget,
        reason: 'the transport mode was changed and not saved — the save '
            'button must be wearing its unsaved label');
    expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull,
        reason: 'unsaved-and-valid must be savable — a dead button under an '
            'unsaved label would be indistinguishable from a refusal');
  }

  // Both brightnesses of both station schemes. The measured fact that
  // solarizedLight and solarizedDark differ only in `grey` is about
  // HmiStateColors — their ColorSchemes differ everywhere, so the fill and
  // label land on different surfaces in each of the four.
  final (solarizedLightTheme, solarizedDarkTheme) =
      themesForScheme(AppColorScheme.solarized);
  final (mutedLightTheme, mutedDarkTheme) =
      themesForScheme(AppColorScheme.muted);
  final themes = <String, ThemeData>{
    'solarized light': solarizedLightTheme,
    'solarized dark': solarizedDarkTheme,
    'muted light': mutedLightTheme,
    'muted dark': mutedDarkTheme,
  };

  for (final MapEntry(key: name, value: theme) in themes.entries) {
    testWidgets('the save button is the one unsaved indicator — $name',
        (tester) async {
      await pumpUnsaved(tester, theme);

      // The Transport card's pill is gone by owner ruling, and this arm is
      // what keeps it gone. The finder is page-wide on purpose: the section
      // headers' own narrow-layout badges also spell `Unsaved`, and none of
      // them may show either when only the transport mode was edited.
      expect(find.text('Unsaved'), findsNothing,
          reason: 'the save button is the sole indicator of unsaved state — '
              'a second spelling of the same fact is the duplication this '
              'codebase deletes on principle ($name)');
    });

    testWidgets('unsaved save-button label reads at 3:1 or better — $name',
        (tester) async {
      await pumpUnsaved(tester, theme);
      final colours = _saveButtonColours(tester, theme);

      expect(
        _contrast(colours.label, colours.fill),
        greaterThanOrEqualTo(3.0),
        reason: 'WCAG 1.4.11 minimum for UI components. The button is the '
            'only unsaved surface left on this card, so an illegible label '
            'here is an operator who cannot see they have not saved '
            '($name: label ${colours.label} on effective fill '
            '${colours.fill})',
      );
    });
  }
}
