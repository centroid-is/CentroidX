import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_mcp_server/src/tools/read_toggles.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';

void main() {
  group('readMcpConfigFromPreferences', () {
    test('a store nobody has configured yields every group off', () async {
      // The live path on a fresh station: `mcpConfigProvider` calls this
      // against device-local preferences, misses the blob, falls into the
      // legacy-key migration, and finds no legacy keys either. That used to
      // land on all-enabled and *persist* it, so a station that had never
      // opened the settings page came up serving the whole tool surface.
      final prefs = InMemoryPreferences();
      final config = await readMcpConfigFromPreferences(prefs);

      expect(config.serverEnabled, isFalse);
      expect(config.chatEnabled, isFalse);
      expect(config.port, McpConfig.defaultPort);
      expect(config.toggles, McpToolToggles.allDisabled);
    });

    test('and the blob it persists says so too', () async {
      // The write-back is the part that outlives the read: whatever this
      // stores is what every later read returns from the fast path.
      final prefs = InMemoryPreferences();
      await readMcpConfigFromPreferences(prefs);

      final raw = await prefs.getString(McpConfig.kPrefKey);
      expect(raw, isNotNull);
      final toggles =
          (jsonDecode(raw!) as Map<String, dynamic>)['toggles'] as Map;
      for (final key in McpToolToggles.allJsonKeys) {
        expect(toggles[key], isFalse,
            reason: 'the persisted blob enabled "$key"');
      }
    });

    test('reads from consolidated JSON key', () async {
      final prefs = InMemoryPreferences();
      final config = McpConfig(
        serverEnabled: true,
        chatEnabled: true,
        port: 9999,
        toggles: McpToolToggles.allEnabled
            .copyWithToggle('tags', false)
            .copyWithToggle('trends', false),
      );
      await prefs.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));

      final result = await readMcpConfigFromPreferences(prefs);

      expect(result.serverEnabled, isTrue);
      expect(result.chatEnabled, isTrue);
      expect(result.port, 9999);
      expect(result.toggles.tagsEnabled, isFalse);
      expect(result.toggles.trendsEnabled, isFalse);
      // Stored true survives the round trip -- the new default must not make
      // an enabled group impossible to keep enabled.
      expect(result.toggles.alarmsEnabled, isTrue);
    });

    test('migrates legacy individual keys into consolidated config', () async {
      final prefs = InMemoryPreferences();

      // Set legacy keys as if they were from an older version.
      await prefs.setBool('mcp_server_enabled', true);
      await prefs.setBool('mcp_chat_enabled', true);
      await prefs.setInt('mcp_server_port', 7777);
      await prefs.setBool(McpToolToggles.kTagsEnabled, false);
      await prefs.setBool(McpToolToggles.kTrendsEnabled, false);
      await prefs.setBool(McpToolToggles.kAlarmsEnabled, true);

      final config = await readMcpConfigFromPreferences(prefs);

      expect(config.serverEnabled, isTrue);
      expect(config.chatEnabled, isTrue);
      expect(config.port, 7777);
      expect(config.toggles.tagsEnabled, isFalse);
      // Explicitly stored as on, and it stays on.
      expect(config.toggles.alarmsEnabled, isTrue);
      expect(config.toggles.trendsEnabled, isFalse);
      // Never written by that older build, so nobody enabled it.
      expect(config.toggles.techDocsEnabled, isFalse);
      expect(config.toggles.plcCodeEnabled, isFalse);

      // Verify the consolidated key was written (migration persists).
      final raw = await prefs.getString(McpConfig.kPrefKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['serverEnabled'], isTrue);
    });

    test('second read uses consolidated key (no re-migration)', () async {
      final prefs = InMemoryPreferences();

      // Simulate migration already happened.
      final config = const McpConfig(
        serverEnabled: true,
        chatEnabled: false,
        port: 5555,
      );
      await prefs.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));

      // Even if legacy keys exist with different values, consolidated wins.
      await prefs.setBool('mcp_server_enabled', false);

      final result = await readMcpConfigFromPreferences(prefs);
      expect(result.serverEnabled, isTrue,
          reason: 'Should read from consolidated key, not legacy');
    });
  });

  group('readTogglesFromPreferences (backwards-compatible)', () {
    test('returns all-disabled when no keys are set', () async {
      final prefs = InMemoryPreferences();
      final toggles = await readTogglesFromPreferences(prefs);

      expect(toggles, McpToolToggles.allDisabled);
    });

    test('takes each legacy key as written, and nothing else', () async {
      // An older build wrote a key per group, but only for groups somebody
      // touched. The ones it never wrote are the ones nobody enabled.
      final prefs = InMemoryPreferences();
      await prefs.setBool(McpToolToggles.kTagsEnabled, false);
      await prefs.setBool(McpToolToggles.kTrendsEnabled, false);
      await prefs.setBool(McpToolToggles.kConfigEnabled, true);
      await prefs.setBool(McpToolToggles.kDrawingsEnabled, true);

      final toggles = await readTogglesFromPreferences(prefs);

      expect(toggles.tagsEnabled, isFalse);
      expect(toggles.trendsEnabled, isFalse);
      expect(toggles.configEnabled, isTrue);
      expect(toggles.drawingsEnabled, isTrue);
      // Never written by that build.
      expect(toggles.alarmsEnabled, isFalse);
      expect(toggles.plcCodeEnabled, isFalse);
      expect(toggles.proposalsEnabled, isFalse);
      expect(toggles.techDocsEnabled, isFalse);
    });

    test('reads from consolidated config when available', () async {
      final prefs = InMemoryPreferences();
      final config = McpConfig(
        toggles: McpToolToggles.allEnabled.copyWithToggle('plcCode', false),
      );
      await prefs.setString(McpConfig.kPrefKey, jsonEncode(config.toJson()));

      final toggles = await readTogglesFromPreferences(prefs);
      expect(toggles.plcCodeEnabled, isFalse);
      expect(toggles.tagsEnabled, isTrue);
    });
  });

  group('writeMcpConfigToPreferences', () {
    test('writes and reads back correctly', () async {
      final prefs = InMemoryPreferences();
      final config = McpConfig(
        serverEnabled: true,
        chatEnabled: true,
        port: 1234,
        toggles: McpToolToggles.allEnabled
            .copyWithToggle('alarms', false)
            .copyWithToggle('drawings', false),
      );

      await writeMcpConfigToPreferences(prefs, config);
      final result = await readMcpConfigFromPreferences(prefs);

      expect(result.serverEnabled, isTrue);
      expect(result.chatEnabled, isTrue);
      expect(result.port, 1234);
      expect(result.toggles.alarmsEnabled, isFalse);
      expect(result.toggles.drawingsEnabled, isFalse);
      expect(result.toggles.tagsEnabled, isTrue);
    });
  });
}
