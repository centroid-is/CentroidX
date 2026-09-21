import 'package:flutter/material.dart';

abstract final class SolarizedColors {
  static const Color base03 = Color.fromARGB(255, 0, 43, 54);
  static const Color base02 = Color.fromARGB(255, 7, 54, 66);
  static const Color base01 = Color.fromARGB(255, 88, 110, 117);
  static const Color base00 = Color.fromARGB(255, 101, 123, 131);
  static const Color base0 = Color.fromARGB(255, 131, 148, 150);
  static const Color base1 = Color.fromARGB(255, 147, 161, 161);
  static const Color base2 = Color.fromARGB(255, 238, 232, 213);
  static const Color base3 = Color.fromARGB(255, 253, 246, 227);
  static const Color yellow = Color.fromARGB(255, 181, 137, 0);
  static const Color orange = Color.fromARGB(255, 203, 75, 22);
  static const Color red = Color.fromARGB(255, 220, 50, 47);
  static const Color magenta = Color.fromARGB(255, 211, 54, 130);
  static const Color violet = Color.fromARGB(255, 108, 113, 196);
  static const Color blue = Color.fromARGB(255, 38, 139, 210);
  static const Color cyan = Color.fromARGB(255, 42, 161, 152);
  static const Color green = Color.fromARGB(255, 133, 153, 0);
}

/// ISA-101 inspired palette: gray surfaces, muted equipment-state colors,
/// saturated red reserved for faults/alarms.
abstract final class MutedColors {
  static const Color surfaceLight = Color(0xFFECEDEE);
  static const Color containerLight = Color(0xFFDEE1E3);
  static const Color onSurfaceLight = Color(0xFF3C3F41);
  static const Color surfaceDark = Color(0xFF232628);
  static const Color containerDark = Color(0xFF2C3033);
  static const Color onSurfaceDark = Color(0xFFC2C7CB);
  static const Color slate = Color(0xFF4A6572);
  static const Color slateBright = Color(0xFF7FA3B8);
  static const Color gray = Color(0xFF78838B);

  static const Color runningGreen = Color(0xFF8DA28A);
  static const Color manualOchre = Color(0xFFB09F72);
  static const Color forcedOrange = Color(0xFFC2793F);
  static const Color cleanBlue = Color(0xFF8197AC);
  static const Color stoppedGray = Color(0xFF8E8E8E);
  static const Color stoppedGrayDark = Color(0xFF636363);
  static const Color alarmRed = Color(0xFFFF1744);
  static const Color unknownViolet = Color(0xFF9588A7);
  static const Color onState = Color(0xFFF5F5F5);
}

/// Semantic equipment-state colors (conveyors, drives, ...), themed per
/// color scheme so assets don't hardcode `Colors.*`.
@immutable
class HmiStateColors extends ThemeExtension<HmiStateColors> {
  const HmiStateColors({
    required this.green,
    required this.yellow,
    required this.blue,
    required this.grey,
    required this.red,
    required this.violet,
    required this.orange,
    required this.onState,
  });

  /// The scheme's green — running/auto by convention.
  final Color green;

  /// The scheme's yellow — manual mode by convention.
  final Color yellow;

  /// The scheme's blue — cleaning mode by convention.
  final Color blue;

  /// The scheme's grey — stopped/idle by convention.
  final Color grey;

  /// The scheme's red — faults/trips; deliberately the most saturated.
  final Color red;

  /// The scheme's violet — unreadable/unrecognized state by convention.
  final Color violet;

  /// The scheme's orange — forced/override by repo convention, and reused for
  /// an elevated session. The two are the same idea: the panel is not in its
  /// normal state and somebody should be able to see that from across the
  /// room.
  final Color orange;

  /// Text/glyphs drawn on top of any of the state colors above.
  final Color onState;

  static const solarizedLight = HmiStateColors(
    green: SolarizedColors.green,
    yellow: SolarizedColors.yellow,
    blue: SolarizedColors.blue,
    grey: SolarizedColors.base1,
    red: SolarizedColors.red,
    violet: SolarizedColors.magenta,
    orange: SolarizedColors.orange,
    onState: SolarizedColors.base3,
  );

  static const solarizedDark = HmiStateColors(
    green: SolarizedColors.green,
    yellow: SolarizedColors.yellow,
    blue: SolarizedColors.blue,
    grey: SolarizedColors.base01,
    red: SolarizedColors.red,
    violet: SolarizedColors.magenta,
    orange: SolarizedColors.orange,
    onState: SolarizedColors.base3,
  );

  static const mutedLight = HmiStateColors(
    green: MutedColors.runningGreen,
    yellow: MutedColors.manualOchre,
    blue: MutedColors.cleanBlue,
    grey: MutedColors.stoppedGray,
    red: MutedColors.alarmRed,
    violet: MutedColors.unknownViolet,
    orange: MutedColors.forcedOrange,
    onState: MutedColors.onState,
  );

  static const mutedDark = HmiStateColors(
    green: MutedColors.runningGreen,
    yellow: MutedColors.manualOchre,
    blue: MutedColors.cleanBlue,
    grey: MutedColors.stoppedGrayDark,
    red: MutedColors.alarmRed,
    violet: MutedColors.unknownViolet,
    orange: MutedColors.forcedOrange,
    onState: MutedColors.onState,
  );

  /// The theme's state colors, falling back to Solarized when the theme was
  /// built without the extension (bare `MaterialApp` in tests).
  static HmiStateColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<HmiStateColors>() ??
        (theme.brightness == Brightness.dark ? solarizedDark : solarizedLight);
  }

  @override
  HmiStateColors copyWith({
    Color? green,
    Color? yellow,
    Color? blue,
    Color? grey,
    Color? red,
    Color? violet,
    Color? orange,
    Color? onState,
  }) {
    return HmiStateColors(
      green: green ?? this.green,
      yellow: yellow ?? this.yellow,
      blue: blue ?? this.blue,
      grey: grey ?? this.grey,
      red: red ?? this.red,
      violet: violet ?? this.violet,
      orange: orange ?? this.orange,
      onState: onState ?? this.onState,
    );
  }

  @override
  HmiStateColors lerp(HmiStateColors? other, double t) {
    if (other == null) return this;
    return HmiStateColors(
      green: Color.lerp(green, other.green, t)!,
      yellow: Color.lerp(yellow, other.yellow, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      grey: Color.lerp(grey, other.grey, t)!,
      red: Color.lerp(red, other.red, t)!,
      violet: Color.lerp(violet, other.violet, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      onState: Color.lerp(onState, other.onState, t)!,
    );
  }
}

/// Alarm severity colors — deliberately identical in every scheme, so the
/// alarm system is unaffected by the operator's color scheme choice: alarm
/// colors must stay reserved and consistent (ISA-18.2). The values are what
/// the alarm banners have always rendered under Solarized.
@immutable
class AlarmColors extends ThemeExtension<AlarmColors> {
  const AlarmColors({
    required this.info,
    required this.onInfo,
    required this.warning,
    required this.onWarning,
    required this.error,
    required this.onError,
  });

  final Color info;
  final Color onInfo;
  final Color warning;
  final Color onWarning;
  final Color error;
  final Color onError;

  /// Signal green, not Solarized's `#859900`. That olive reads as drab
  /// khaki on a plant floor and, on the beacon asset, at 0.04 of page width
  /// it was barely distinguishable from the equipment behind it.
  static const Color signalGreen = Color(0xFF00E676);

  /// Signal yellow, not Solarized's `#B58900`. That one is a brown-mustard
  /// -- the darkest of the three severities, which inverted the intended
  /// reading: a warning looked less urgent than an info.
  static const Color signalYellow = Color(0xFFFFEA00);

  /// Text and outline drawn ON the two bright fills. The Solarized `base2`
  /// cream that was here fails contrast against them; near-black passes
  /// comfortably on both.
  static const Color onSignal = Color(0xFF0A0F0C);

  static const light = AlarmColors(
    info: signalGreen,
    onInfo: onSignal,
    warning: signalYellow,
    onWarning: onSignal,
    error: SolarizedColors.red,
    onError: SolarizedColors.base2,
  );

  // Identical to [light] by design -- see the class comment. The dark scheme
  // used to render info as blue, which broke that rule and meant an info
  // alarm changed colour with the operator's theme.
  static const dark = AlarmColors(
    info: signalGreen,
    onInfo: onSignal,
    warning: signalYellow,
    onWarning: onSignal,
    error: SolarizedColors.red,
    onError: SolarizedColors.base2,
  );

  static AlarmColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AlarmColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AlarmColors copyWith({
    Color? info,
    Color? onInfo,
    Color? warning,
    Color? onWarning,
    Color? error,
    Color? onError,
  }) {
    return AlarmColors(
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      error: error ?? this.error,
      onError: onError ?? this.onError,
    );
  }

  @override
  AlarmColors lerp(AlarmColors? other, double t) {
    if (other == null) return this;
    return AlarmColors(
      info: Color.lerp(info, other.info, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      error: Color.lerp(error, other.error, t)!,
      onError: Color.lerp(onError, other.onError, t)!,
    );
  }
}

/// A named slot in the active color scheme, for persisting "theme green"
/// instead of a baked RGBA value. Assets that store an [HmiColorRole] follow
/// the scheme when it changes; a literal color never does.
enum HmiColorRole {
  green('Green'),
  yellow('Yellow'),
  blue('Blue'),
  grey('Grey'),
  red('Red'),
  violet('Violet'),
  primary('Primary'),
  secondary('Secondary'),
  tertiary('Tertiary'),
  error('Error'),
  surface('Surface'),
  onSurface('Text');

  const HmiColorRole(this.displayName);

  /// Label shown in the color picker's theme strip.
  final String displayName;

  Color resolve(BuildContext context) {
    final states = HmiStateColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    switch (this) {
      case HmiColorRole.green:
        return states.green;
      case HmiColorRole.yellow:
        return states.yellow;
      case HmiColorRole.blue:
        return states.blue;
      case HmiColorRole.grey:
        return states.grey;
      case HmiColorRole.red:
        return states.red;
      case HmiColorRole.violet:
        return states.violet;
      case HmiColorRole.primary:
        return scheme.primary;
      case HmiColorRole.secondary:
        return scheme.secondary;
      case HmiColorRole.tertiary:
        return scheme.tertiary;
      case HmiColorRole.error:
        return scheme.error;
      case HmiColorRole.surface:
        return scheme.surface;
      case HmiColorRole.onSurface:
        return scheme.onSurface;
    }
  }
}

/// The color schemes offered in preferences. [solarized] is the historical
/// default; [muted] follows ISA-101's muted, gray-first guidance.
enum AppColorScheme {
  solarized('Solarized'),
  muted('Muted');

  const AppColorScheme(this.displayName);
  final String displayName;
}

/// The app's typeface. Bundled by `centroid-hmi/pubspec.yaml` under exactly
/// this family name; `test/core/app_font_bundled_test.dart` holds the two
/// together.
const String kAppFontFamily = 'dejavu-sans';

ThemeData _themeFromColorScheme(ColorScheme scheme, HmiStateColors states) {
  return ThemeData(
      colorScheme: scheme,
      extensions: [
        states,
        scheme.brightness == Brightness.dark
            ? AlarmColors.dark
            : AlarmColors.light,
      ],
      fontFamily: kAppFontFamily,
      textTheme: const TextTheme(),
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: scheme.primary.withAlpha(100),
        selectionHandleColor: scheme.primary,
      ),
      scrollbarTheme: const ScrollbarThemeData(
          thumbVisibility: WidgetStatePropertyAll(true)),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      shadowColor: scheme.surfaceBright,
      // The bottom sheet maximum is used for board datetime picker
      bottomSheetTheme:
          BottomSheetThemeData(constraints: BoxConstraints(maxWidth: 1000.0)));
}

(ThemeData, ThemeData) themesForScheme(AppColorScheme scheme) {
  switch (scheme) {
    case AppColorScheme.solarized:
      return solarized();
    case AppColorScheme.muted:
      return muted();
  }
}

(ThemeData, ThemeData) solarized() {
  ColorScheme solarizedDarkColorScheme = const ColorScheme.dark(
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

  ColorScheme solarizedLightColorScheme = const ColorScheme.light(
    brightness: Brightness.light,
    primary: SolarizedColors.green,
    onPrimary: SolarizedColors.base2,
    secondary: SolarizedColors.base1,
    onSecondary: SolarizedColors.base2,
    error: SolarizedColors.red,
    onError: SolarizedColors.base2,
    surface: SolarizedColors.base3,
    onSurface: SolarizedColors.base00,
    tertiary: SolarizedColors.yellow,
    onTertiary: SolarizedColors.base2,
    surfaceContainerLow: SolarizedColors.base2,
    surfaceContainerHighest: SolarizedColors.base2,
  );

  final solarizedLight = _themeFromColorScheme(
      solarizedLightColorScheme, HmiStateColors.solarizedLight);
  final solarizedDark = _themeFromColorScheme(
      solarizedDarkColorScheme, HmiStateColors.solarizedDark);
  return (solarizedLight, solarizedDark);
}

(ThemeData, ThemeData) muted() {
  ColorScheme isaDarkColorScheme = const ColorScheme.dark(
    brightness: Brightness.dark,
    primary: MutedColors.slateBright,
    onPrimary: MutedColors.surfaceDark,
    secondary: MutedColors.gray,
    onSecondary: MutedColors.surfaceDark,
    error: MutedColors.alarmRed,
    onError: MutedColors.onState,
    surface: MutedColors.surfaceDark,
    onSurface: MutedColors.onSurfaceDark,
    tertiary: MutedColors.manualOchre,
    onTertiary: MutedColors.surfaceDark,
    surfaceContainerLow: MutedColors.containerDark,
    surfaceContainerHighest: MutedColors.containerDark,
  );

  ColorScheme isaLightColorScheme = const ColorScheme.light(
    brightness: Brightness.light,
    primary: MutedColors.slate,
    onPrimary: MutedColors.surfaceLight,
    secondary: MutedColors.gray,
    onSecondary: MutedColors.surfaceLight,
    error: MutedColors.alarmRed,
    onError: MutedColors.onState,
    surface: MutedColors.surfaceLight,
    onSurface: MutedColors.onSurfaceLight,
    tertiary: MutedColors.manualOchre,
    onTertiary: MutedColors.surfaceLight,
    surfaceContainerLow: MutedColors.containerLight,
    surfaceContainerHighest: MutedColors.containerLight,
  );

  final isaLight =
      _themeFromColorScheme(isaLightColorScheme, HmiStateColors.mutedLight);
  final isaDark =
      _themeFromColorScheme(isaDarkColorScheme, HmiStateColors.mutedDark);
  return (isaLight, isaDark);
}
