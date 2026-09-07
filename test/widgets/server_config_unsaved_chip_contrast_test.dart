/// The Transport card's "Unsaved" marker must read as *attention, not alarm* —
/// and must be legible in both brightnesses of both station schemes.
///
/// Phase 15-07's golden review flagged the old marker as "dark-red-on-red in
/// the dark theme … the lowest-contrast element in any of the 26 images", and
/// the owner reported the same from real hardware. The old widget was
/// `Chip(backgroundColor: colorScheme.errorContainer)` — and neither Solarized
/// scheme sets `errorContainer`, so it fell back to `colorScheme.error`:
/// saturated fault red, under the default M3 label colour (`onSurfaceVariant`,
/// which also falls back — to `onSurface`). Measured, that pairing is 1.15:1
/// in solarized dark and 1.02:1 in solarized light. Red-on-red in both.
///
/// Two properties are pinned here, per theme:
///
///  1. **The fill is not fault red.** Only fault red may be saturated in this
///     repo (HMI colour vocabulary), and unsaved changes are not a fault —
///     they are the normal state of a keyboard mid-edit.
///  2. **Label-on-fill contrast is at least 3.0:1** — WCAG 1.4.11's minimum
///     for UI components, and comfortably above both schemes' body text.
///
/// A golden is not a substitute for this arm: a suite that generates its own
/// frames cannot notice that the frame it generated is illegible, and the
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

/// The marker's rendered label colour, its raw fill, and the fill composited
/// over the card it sits on.
///
/// Reads the *resolved* colours, not the widget's inputs: the old chip never
/// set a label colour at all, and the theme's default is exactly what the
/// operator was squinting at.
({Color label, Color rawFill, Color fill}) _unsavedColours(
    WidgetTester tester, ThemeData theme) {
  final text = find.text('Unsaved');
  final label =
      tester.renderObject<RenderParagraph>(text).text.style?.color;
  expect(label, isNotNull,
      reason: 'the marker label must resolve to a colour');

  Color? rawFill;
  final chip = find.ancestor(of: text, matching: find.byType(Chip));
  if (chip.evaluate().isNotEmpty) {
    rawFill = tester.widget<Chip>(chip.first).backgroundColor;
  } else {
    final deco = find.ancestor(of: text, matching: find.byType(DecoratedBox));
    expect(deco, findsAtLeastNWidgets(1),
        reason: 'the marker must paint a fill — a bare label in the tile '
            'header would not read as a badge at all');
    final decoration =
        tester.widget<DecoratedBox>(deco.first).decoration as BoxDecoration;
    rawFill = decoration.color;
  }
  expect(rawFill, isNotNull, reason: 'the marker must have a fill colour');

  // What the operator actually sees behind the label: a translucent fill is
  // composited over the card the tile lives on (M3 cards default to
  // `surfaceContainerLow`, which both station schemes set).
  final card = theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;
  return (
    label: label!,
    rawFill: rawFill!,
    fill: Color.alphaBlend(rawFill, card),
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
  /// `_hasUnsavedChanges` is genuinely true and the marker is showing.
  Future<void> pumpUnsaved(WidgetTester tester, ThemeData theme) async {
    await tester.binding.setSurfaceSize(const Size(800, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAndLoad(tester, buildTestableServerConfig(theme: theme));
    await tester.tap(find.text('Transport'));
    await settle(tester);
    await tester.tap(find.text('Relay gateway'));
    await settle(tester);

    // Anti-vacuity: everything below is only a statement about the marker if
    // the marker is actually on screen. (The section headers' own badges say
    // 'Unsaved Changes', not 'Unsaved', and no section is edited here.)
    expect(find.text('Unsaved'), findsOneWidget,
        reason: 'the transport mode was changed and not saved — the marker '
            'must be showing');
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
    testWidgets('unsaved marker is not fault red — $name', (tester) async {
      await pumpUnsaved(tester, theme);
      final colours = _unsavedColours(tester, theme);

      final scheme = theme.colorScheme;
      for (final forbidden in [scheme.error, scheme.errorContainer]) {
        expect(
          colours.rawFill.withValues(alpha: 1.0),
          isNot(equals(forbidden.withValues(alpha: 1.0))),
          reason: 'unsaved changes are attention, not a fault: only fault red '
              'may be saturated, and an error-family fill spends it on the '
              'normal state of a keyboard mid-edit ($name)',
        );
      }
    });

    testWidgets('unsaved marker label reads at 3:1 or better — $name',
        (tester) async {
      await pumpUnsaved(tester, theme);
      final colours = _unsavedColours(tester, theme);

      expect(
        _contrast(colours.label, colours.fill),
        greaterThanOrEqualTo(3.0),
        reason: 'WCAG 1.4.11 minimum for UI components. The old chip measured '
            '1.15:1 in solarized dark — 15-07 called it "the lowest-contrast '
            'element in any of the 26 images" ($name: label ${colours.label} '
            'on effective fill ${colours.fill})',
      );
    });
  }
}
