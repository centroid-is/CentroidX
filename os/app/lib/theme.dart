import 'package:flutter/material.dart';

/// Sizing is driven by fingers, not cursors. Every interactive target is at
/// least [minTarget] high, text is large enough to read standing at a panel,
/// and the on-screen keyboard covers the bottom of the screen -- so forms scroll
/// and nothing important is anchored to the bottom edge.
const double minTarget = 64;
const double fieldGap = 20;

/// The weston input panel on these stations is a fixed 720x200 and weston keeps
/// whatever size the panel first claims, so reserve it: a focused field must
/// never end up behind the keyboard.
const double keyboardReserve = 220;

/// Solarized, lifted from the HMI's own `lib/theme.dart` rather than
/// approximated, so the installer and the thing it installs look like one
/// product. The HMI defaults to this scheme (`providers/theme.dart` falls back
/// to `AppColorScheme.solarized`).
class SolarizedColors {
  static const Color base03 = Color.fromARGB(255, 0, 43, 54);
  static const Color base02 = Color.fromARGB(255, 7, 54, 66);
  static const Color base01 = Color.fromARGB(255, 88, 110, 117);
  static const Color base00 = Color.fromARGB(255, 101, 123, 131);
  static const Color base0 = Color.fromARGB(255, 131, 148, 150);
  static const Color base1 = Color.fromARGB(255, 147, 161, 161);
  static const Color yellow = Color.fromARGB(255, 181, 137, 0);
  static const Color orange = Color.fromARGB(255, 203, 75, 22);
  static const Color red = Color.fromARGB(255, 220, 50, 47);
  static const Color blue = Color.fromARGB(255, 38, 139, 210);
  static const Color green = Color.fromARGB(255, 133, 153, 0);
}

/// The HMI's solarized dark scheme, field for field.
const ColorScheme solarizedDark = ColorScheme.dark(
  brightness: Brightness.dark,
  primary: SolarizedColors.blue,
  onPrimary: SolarizedColors.base02,
  secondary: SolarizedColors.base01,
  onSecondary: SolarizedColors.base02,
  error: SolarizedColors.red,
  onError: SolarizedColors.base02,
  surface: SolarizedColors.base03,
  onSurface: SolarizedColors.base01,
  tertiary: SolarizedColors.yellow,
  onTertiary: SolarizedColors.base02,
  surfaceContainerLow: SolarizedColors.base02,
  surfaceContainerHighest: SolarizedColors.base02,
);

/// Body text uses base0 rather than the scheme's `onSurface` (base01).
///
/// base01-on-base03 is correct for the HMI's dense read-at-a-glance surfaces,
/// but this app is read once, standing up, by someone typing a password they
/// cannot see. Solarized's own guidance puts base0 as the body foreground on a
/// base03 background; base01 is the comment tone.
const Color bodyForeground = SolarizedColors.base0;
const Color headingForeground = SolarizedColors.base1;

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: solarizedDark,
    scaffoldBackgroundColor: solarizedDark.surface,
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
          fontSize: 30, fontWeight: FontWeight.w600, color: headingForeground),
      titleMedium: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w500, color: headingForeground),
      bodyLarge: TextStyle(fontSize: 19, color: bodyForeground),
      bodyMedium: TextStyle(fontSize: 17, color: bodyForeground),
      labelLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      labelStyle: TextStyle(color: bodyForeground, fontSize: 18),
      helperStyle: TextStyle(color: SolarizedColors.base01, fontSize: 14),
      filled: true,
      fillColor: SolarizedColors.base02,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(200, minTarget),
        textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(150, minTarget),
        foregroundColor: bodyForeground,
        // Neither HMI scheme sets colorScheme.outline, so it renders invisible
        // on dark; use an explicit onSurface alpha instead.
        side: const BorderSide(color: SolarizedColors.base01),
        textStyle: const TextStyle(fontSize: 19),
      ),
    ),
    dividerColor: SolarizedColors.base02,
  );
}
