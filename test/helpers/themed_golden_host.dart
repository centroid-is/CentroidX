/// The real station themes, for goldens that are about colour.
///
/// Three golden files in this phase need the same host, so it lives here
/// rather than being copied a fourth time.
/// `test/page_creator/assets/festo_vtug_golden_test.dart:62-88` is where the
/// shape comes from and it says why in its own words; this is that paragraph,
/// moved somewhere every themed golden can reach it:
///
/// > A pane golden built on a bare `ThemeData` cannot catch the thing dark
/// > goldens exist to catch: neither Solarized scheme sets
/// > `colorScheme.outline`, so a widget that borrows it draws an edge that is
/// > invisible on base03 and perfectly fine in the light image.
///
/// That is the whole argument for [themedGoldenHost] over a bare `MaterialApp`,
/// and for shooting **both** brightnesses rather than one. A light-only golden
/// of a widget that borrowed the scheme's edge role is a green test over an
/// invisible border (project memory `solarized-outline-is-invisible`).
///
/// ## Why `.textTheme.apply(fontFamily:)` is not redundant
///
/// `lib/theme.dart:349` already sets `fontFamily: 'roboto-mono'` on the
/// `ThemeData` — and then `:350` sets `textTheme: const TextTheme()`, which
/// carries no family and wins for every widget that reads a named text style.
/// So the family has to be re-applied to the text theme itself. Without the
/// `.apply` below, text renders in whatever the default is rather than in the
/// face the plant actually reads.
///
/// ## The font family, and why nothing is registered here
///
/// The station themes ask for the family `roboto-mono`. [loadGoldenFonts]
/// registers exactly that spelling alongside `Roboto` — plan 15-00 amended it
/// and **measured** the amendment load-bearing in both directions with a
/// `TextPainter` probe (`roboto-mono` measured 400.0 wide before, the Ahem
/// fallback, and 240.04 after). So [loadThemedGoldenFonts] just calls it, and
/// this file registers nothing locally: a second registration is the exact
/// duplication that amendment existed to remove.
///
/// Getting this wrong yields Ahem boxes — uniform rectangles where text should
/// be, and text that is mirror-symmetric, which is also why a golden can never
/// pin text handedness (project memory `goldens-cant-pin-text-handedness`).
library;

import 'package:flutter/material.dart';
import 'package:tfc/theme.dart' show solarized;

import 'golden_fonts.dart';

/// The fonts a themed golden needs, for a `setUpAll`.
///
/// One call, so the three golden files in this phase cannot drift apart about
/// which families are registered.
Future<void> loadThemedGoldenFonts() => loadGoldenFonts();

/// The real station themes, with `roboto-mono` applied to the text theme.
///
/// `solarized()` returns **(light, dark)** in that order — both pre-existing
/// callers destructure it that way
/// (`festo_vtug_golden_test.dart:71`, `base_scaffold_appbar_golden_test.dart:57`).
ThemeData themedGoldenTheme({bool dark = false}) {
  final (light, darkTheme) = solarized();
  final base = dark ? darkTheme : light;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'roboto-mono'),
  );
}

/// Solarized base03 — the dark scheme's background.
const Color kThemedGoldenDarkBackground = Color(0xFF002B36);

/// Solarized base2 — the light scheme's background.
const Color kThemedGoldenLightBackground = Color(0xFFEEE8D5);

/// [child], centred, under the real station theme for [dark].
Widget themedGoldenHost(Widget child, {bool dark = false, Color? background}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themedGoldenTheme(dark: dark),
      home: Scaffold(
        backgroundColor: background ??
            (dark ? kThemedGoldenDarkBackground : kThemedGoldenLightBackground),
        body: Center(child: child),
      ),
    );
