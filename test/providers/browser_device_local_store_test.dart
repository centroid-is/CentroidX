@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
// The web arm by name, not through the seam: it has no browser-only import —
// `shared_preferences` resolves to whatever platform instance is installed,
// which below is the in-memory one — so the VM can exercise the arm a web
// build compiles. The station arm is `boot_ordering_test.dart`'s.
import 'package:tfc/providers/device_local_store_open_web.dart' as web;
import 'package:tfc_dart/core/config/config_item.dart' show ConfigScope;

/// The browser's device-local store.
///
/// What it has to be: a store `initDeviceLocalPreferences` can open in a tab
/// (there was none, and every read on the boot path threw), that survives a
/// reload (the browser's restart-to-apply), and that reports — through
/// `kHasDeviceLocalMirror` — that no `ConfigStore` can be built over it.
void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Future<web.DeviceLocalStoreHandle> open() => web.openDeviceLocalStore(
        scope: ConfigScope.forStation('a-browser'),
        logger: Logger(level: Level.off),
      );

  group('the browser device-local store', () {
    test('opens with no database, and says so', () async {
      final opened = await open();
      expect(opened.db, isNull,
          reason: 'a browser has no SQLite, so nothing here can back a '
              'ConfigStore');
      expect(web.kHasDeviceLocalMirror, isFalse,
          reason: 'stateManProvider and pageManagerProvider branch on this '
              'rather than on the throw a missing mirror would be');
    });

    test('keeps the transport row across a reopen — the reload case',
        () async {
      const pointed = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9443',
      );
      await writeGatewayConfig((await open()).store, pointed);

      // A second open is a second tab, or the same one after a reload: the
      // platform store is the same `localStorage` underneath.
      expect(await readGatewayConfig((await open()).store), pointed,
          reason: 'Server Config saves the row here and tells the operator '
              'to restart; in a browser that is a reload, and the address '
              'must still be there');
    });

    test('forwards every member of PreferencesApi', () async {
      final store = (await open()).store;

      await store.setBool('b', true);
      await store.setInt('i', 7);
      await store.setDouble('d', 2.5);
      await store.setString('s', 'seven');
      await store.setStringList('l', ['a', 'b']);

      expect(await store.getBool('b'), isTrue);
      expect(await store.getInt('i'), 7);
      expect(await store.getDouble('d'), 2.5);
      expect(await store.getString('s'), 'seven');
      expect(await store.getStringList('l'), ['a', 'b']);
      expect(await store.containsKey('s'), isTrue);
      expect(await store.containsKey('missing'), isFalse);
      expect(await store.getKeys(), {'b', 'i', 'd', 's', 'l'});
      expect(await store.getKeys(allowList: {'s', 'i'}), {'s', 'i'});
      expect(await store.getAll(allowList: {'s'}), {'s': 'seven'});

      await store.remove('s');
      expect(await store.getString('s'), isNull);

      await store.clear(allowList: {'b', 'i'});
      expect(await store.getKeys(), {'d', 'l'});
      await store.clear();
      expect(await store.getKeys(), isEmpty);
    });
  });
}
