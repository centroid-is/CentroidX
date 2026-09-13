import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'preferences.dart' show localPreferencesProvider;

part 'theme.g.dart';

/// Both notifiers hold a `ref`, so they read [localPreferencesProvider] rather
/// than calling the factory — the provider is the overridable route, and a
/// test that wants a seeded store should not have to open a database to get
/// one.
///
/// The two key names are unchanged on purpose. Until milestone v1.2 they were
/// written through `SharedPreferences.getInstance()`, whose legacy API stores
/// them as `flutter.theme_mode` and `flutter.color_scheme`; the one-shot
/// import in `device_local_store.dart` strips that prefix, so a station
/// upgrading finds its theme exactly where these two now look for it.
@riverpod
class ThemeNotifier extends _$ThemeNotifier {
  static const String _key = 'theme_mode';

  @override
  Future<ThemeMode> build() async {
    final prefs = ref.read(localPreferencesProvider);
    final String? themeName = await prefs.getString(_key);
    return _themeStringToMode(themeName);
  }

  Future<void> setTheme(ThemeMode mode) async {
    state = AsyncData(mode);
    await ref.read(localPreferencesProvider).setString(_key, mode.name);
  }

  static ThemeMode _themeStringToMode(String? themeName) {
    switch (themeName) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}

@riverpod
class ColorSchemeNotifier extends _$ColorSchemeNotifier {
  static const String _key = 'color_scheme';

  @override
  Future<AppColorScheme> build() async {
    final prefs = ref.read(localPreferencesProvider);
    final String? name = await prefs.getString(_key);
    return AppColorScheme.values.asNameMap()[name] ?? AppColorScheme.solarized;
  }

  Future<void> setScheme(AppColorScheme scheme) async {
    state = AsyncData(scheme);
    await ref.read(localPreferencesProvider).setString(_key, scheme.name);
  }
}
