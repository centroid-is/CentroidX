import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/preferences.dart'
    show InMemoryPreferences, PreferencesApi;
import 'package:tfc_mcp_server/src/tools/read_toggles.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';

/// Mimics the database-backed `Preferences`, whose `remove()` also erases
/// the key from its local-cache mirror — the same physical store the
/// device-local preferences live in.
class _MirroringPrefs extends InMemoryPreferences {
  final PreferencesApi mirror;
  _MirroringPrefs(this.mirror);

  @override
  Future<void> remove(String key) async {
    await super.remove(key);
    await mirror.remove(key);
  }
}

void main() {
  group('migrateMcpConfigToDeviceLocal', () {
    test('seeds local from shared consolidated blob and cleans shared',
        () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();
      const config = McpConfig(
        serverEnabled: true,
        chatEnabled: true,
        port: 9999,
        toggles: McpToolToggles(tagsEnabled: false),
      );
      await shared.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));
      await shared.setBool('mcp_server_enabled', false); // stale legacy key

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      final migrated = await readMcpConfigFromPreferences(local);
      expect(migrated, config);
      expect(await shared.getString(McpConfig.kPrefKey), isNull);
      expect(await shared.getBool('mcp_server_enabled'), isNull);
    });

    test('seeds local from shared legacy keys when no blob exists', () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();
      await shared.setBool('mcp_server_enabled', true);
      await shared.setInt('mcp_server_port', 7777);
      await shared.setBool(McpToolToggles.kTrendsEnabled, false);
      await shared.setBool(McpToolToggles.kTagsEnabled, true);

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      final migrated = await readMcpConfigFromPreferences(local);
      expect(migrated.serverEnabled, isTrue);
      expect(migrated.port, 7777);
      expect(migrated.toggles.trendsEnabled, isFalse);
      // Carried down as written, not re-defaulted on the way.
      expect(migrated.toggles.tagsEnabled, isTrue);
      // Never written on the shared side, so it arrives off.
      expect(migrated.toggles.alarmsEnabled, isFalse);
      for (final key in McpConfig.legacyKeys) {
        expect(await shared.containsKey(key), isFalse,
            reason: 'legacy key $key must be removed from the shared store');
      }
    });

    test('existing local config wins over shared, shared still cleaned',
        () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();
      const sharedConfig = McpConfig(serverEnabled: true, port: 1111);
      const localConfig = McpConfig(serverEnabled: false, port: 2222);
      await shared.setString(
          McpConfig.kPrefKey, jsonEncode(sharedConfig.toJson()));
      await local.setString(
          McpConfig.kPrefKey, jsonEncode(localConfig.toJson()));

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      expect(await readMcpConfigFromPreferences(local), localConfig);
      expect(await shared.getString(McpConfig.kPrefKey), isNull);
    });

    test('local config survives when shared removals mirror into the '
        'same store', () async {
      final local = InMemoryPreferences();
      final shared = _MirroringPrefs(local);
      const sharedConfig = McpConfig(serverEnabled: true, port: 1111);
      const localConfig = McpConfig(serverEnabled: false, port: 2222);
      await shared.setString(
          McpConfig.kPrefKey, jsonEncode(sharedConfig.toJson()));
      await local.setString(
          McpConfig.kPrefKey, jsonEncode(localConfig.toJson()));

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      expect(await readMcpConfigFromPreferences(local), localConfig,
          reason: 'shared.remove() erasing the mirrored key must not '
              'destroy the device-local config');
    });

    test('does nothing when neither store has any config', () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      expect(await local.getString(McpConfig.kPrefKey), isNull,
          reason: 'a fresh install must not fabricate a config blob');
    });

    test('is idempotent', () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();
      const config = McpConfig(serverEnabled: true, port: 4321);
      await shared.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);
      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      expect(await readMcpConfigFromPreferences(local), config);
      expect(await shared.getString(McpConfig.kPrefKey), isNull);
    });

    test('ignores a corrupted shared blob but still cleans it up', () async {
      final shared = InMemoryPreferences();
      final local = InMemoryPreferences();
      await shared.setString(McpConfig.kPrefKey, 'not json {');

      await migrateMcpConfigToDeviceLocal(shared: shared, local: local);

      expect(await local.getString(McpConfig.kPrefKey), isNull);
      expect(await shared.getString(McpConfig.kPrefKey), isNull);
    });
  });

  group('togglesFromEnvJson', () {
    test('parses toggles from the env payload', () {
      const toggles = McpToolToggles(tagsEnabled: false, trendsEnabled: false);
      final parsed = togglesFromEnvJson(jsonEncode(toggles.toJson()));
      expect(parsed, toggles);
    });

    test('returns null for absent, empty, or malformed payloads', () {
      expect(togglesFromEnvJson(null), isNull);
      expect(togglesFromEnvJson(''), isNull);
      expect(togglesFromEnvJson('not json {'), isNull);
      expect(togglesFromEnvJson('[1,2]'), isNull);
    });
  });

  group('McpConfig equality', () {
    test('equal values compare equal', () {
      const a = McpConfig(
          serverEnabled: true,
          port: 1234,
          toggles: McpToolToggles(alarmsEnabled: false));
      const b = McpConfig(
          serverEnabled: true,
          port: 1234,
          toggles: McpToolToggles(alarmsEnabled: false));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing port is not equal', () {
      const a = McpConfig(port: 1234);
      const b = McpConfig(port: 1235);
      expect(a, isNot(b));
    });

    test('differing toggles are not equal', () {
      const a = McpConfig(toggles: McpToolToggles(tagsEnabled: true));
      const b = McpConfig();
      expect(a, isNot(b));
    });
  });
}
