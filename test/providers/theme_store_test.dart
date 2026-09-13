/// The two device-local UI preferences, read through the store the rest of the
/// app uses.
///
/// `theme_mode` and `color_scheme` were the last two keys reached through
/// `SharedPreferences.getInstance()`, whose legacy API prefixes every key it
/// writes with `flutter.`. The 01-04 import strips that prefix, so what a
/// station upgrading from the old store finds under `theme_mode` is what it
/// last saved under `flutter.theme_mode` — which is why these tests seed the
/// bare key and assert the notifier finds it.
///
/// `loadSavedDbusCredentials` is here for the same reason and not in a page
/// test: it is a top-level function with no `ref`, so it reads the factory
/// rather than the provider, and the two routes are worth pinning side by
/// side.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/dbus_login.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/theme.dart';
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import '../helpers/test_helpers.dart';

/// A container whose `localPreferencesProvider` is [store].
///
/// The override is the point: both notifiers hold a `ref`, so they take the
/// overridable route rather than the factory, and a test can hand them a store
/// without opening a database.
ProviderContainer containerWith(PreferencesApi store) {
  final container = ProviderContainer(
    overrides: [localPreferencesProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('ThemeNotifier', () {
    test('reads theme_mode out of the device-local store', () async {
      final store = InMemoryPreferences();
      await store.setString('theme_mode', 'dark');

      final container = containerWith(store);

      expect(
        await container.read(themeNotifierProvider.future),
        ThemeMode.dark,
      );
    });

    test('falls back to system when the import never saw the key', () async {
      final container = containerWith(InMemoryPreferences());

      expect(
        await container.read(themeNotifierProvider.future),
        ThemeMode.system,
      );
    });

    test('setTheme writes the mode back to the store', () async {
      final store = InMemoryPreferences();
      final container = containerWith(store);
      await container.read(themeNotifierProvider.future);

      await container.read(themeNotifierProvider.notifier).setTheme(
            ThemeMode.light,
          );

      expect(await store.getString('theme_mode'), 'light');
      expect(container.read(themeNotifierProvider).value, ThemeMode.light);
    });
  });

  group('ColorSchemeNotifier', () {
    test('reads color_scheme out of the device-local store', () async {
      final store = InMemoryPreferences();
      await store.setString('color_scheme', 'muted');

      final container = containerWith(store);

      expect(
        await container.read(colorSchemeNotifierProvider.future),
        AppColorScheme.muted,
      );
    });

    test('falls back to solarized when the key is absent', () async {
      final container = containerWith(InMemoryPreferences());

      expect(
        await container.read(colorSchemeNotifierProvider.future),
        AppColorScheme.solarized,
      );
    });

    test('an unknown stored name also falls back to solarized', () async {
      final store = InMemoryPreferences();
      await store.setString('color_scheme', 'chartreuse');

      final container = containerWith(store);

      expect(
        await container.read(colorSchemeNotifierProvider.future),
        AppColorScheme.solarized,
      );
    });

    test('setScheme writes the name back to the store', () async {
      final store = InMemoryPreferences();
      final container = containerWith(store);
      await container.read(colorSchemeNotifierProvider.future);

      await container.read(colorSchemeNotifierProvider.notifier).setScheme(
            AppColorScheme.muted,
          );

      expect(await store.getString('color_scheme'), 'muted');
    });
  });

  group('loadSavedDbusCredentials', () {
    setUp(() => SecureStorage.setInstance(FakeSecureStorage()));

    test('reads all five keys through the factory', () async {
      final store = useInMemoryDeviceLocalPreferences();
      await store.setString('connectionType', ConnectionType.system.name);
      await store.setString('host', 'st101.local');
      await store.setString('username', 'centroid');
      await store.setBool('autoLogin', true);
      await store.setString('sshPrivateKeyPath', '/home/centroid/.ssh/id_ed25519');

      final creds = await loadSavedDbusCredentials();

      expect(creds.type, ConnectionType.system);
      expect(creds.host, 'st101.local');
      expect(creds.username, 'centroid');
      expect(creds.autoLogin, isTrue);
      expect(creds.sshPrivateKeyPath, '/home/centroid/.ssh/id_ed25519');
    });

    test('an empty store gives the remote default and no auto-login', () async {
      useInMemoryDeviceLocalPreferences();

      final creds = await loadSavedDbusCredentials();

      expect(creds.type, ConnectionType.remote);
      expect(creds.host, isNull);
      expect(creds.username, isNull);
      expect(creds.autoLogin, isFalse);
      expect(creds.sshPrivateKeyPath, isNull);
    });

    test('an empty sshPrivateKeyPath reads back as null', () async {
      final store = useInMemoryDeviceLocalPreferences();
      await store.setString('sshPrivateKeyPath', '');

      expect((await loadSavedDbusCredentials()).sshPrivateKeyPath, isNull);
    });
  });
}
