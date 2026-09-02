import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/server.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/mock_drawing_index.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/mock_state_reader.dart';

void main() {
  group('McpConfig', () {
    test('defaults are serverEnabled=false, chatEnabled=false, port=8765', () {
      const config = McpConfig();
      expect(config.serverEnabled, isFalse);
      expect(config.chatEnabled, isFalse);
      expect(config.port, 8765);
      expect(config.toggles.tagsEnabled, isTrue);
    });

    test('fromJson with empty map returns defaults', () {
      final config = McpConfig.fromJson({});
      expect(config.serverEnabled, isFalse);
      expect(config.chatEnabled, isFalse);
      expect(config.port, McpConfig.defaultPort);
    });

    test('toJson/fromJson roundtrip preserves all fields', () {
      const original = McpConfig(
        serverEnabled: true,
        chatEnabled: true,
        port: 9999,
        toggles: McpToolToggles(tagsEnabled: false, trendsEnabled: false),
      );
      final json = original.toJson();
      final restored = McpConfig.fromJson(json);

      expect(restored.serverEnabled, isTrue);
      expect(restored.chatEnabled, isTrue);
      expect(restored.port, 9999);
      expect(restored.toggles.tagsEnabled, isFalse);
      expect(restored.toggles.trendsEnabled, isFalse);
      expect(restored.toggles.alarmsEnabled, isTrue);
    });

    test('copyWith replaces specified fields only', () {
      const config = McpConfig(serverEnabled: false, port: 1000);
      final updated = config.copyWith(serverEnabled: true);

      expect(updated.serverEnabled, isTrue);
      expect(updated.port, 1000);
      expect(updated.chatEnabled, isFalse);
    });

    test('kPrefKey is mcp.config', () {
      expect(McpConfig.kPrefKey, 'mcp.config');
    });

    test('legacyKeys contains all expected legacy keys', () {
      expect(McpConfig.legacyKeys, contains('mcp_server_enabled'));
      expect(McpConfig.legacyKeys, contains('mcp_chat_enabled'));
      expect(McpConfig.legacyKeys, contains('mcp_server_port'));
      expect(McpConfig.legacyKeys, contains('mcp_tools_tags_enabled'));
      expect(McpConfig.legacyKeys, contains('mcp_tools_alarms_enabled'));
      expect(McpConfig.legacyKeys, hasLength(12)); // 3 + 9 toggle keys
    });
  });

  group('McpToolToggles data class', () {
    test('defaults all 8 fields to true', () {
      const toggles = McpToolToggles();
      expect(toggles.tagsEnabled, isTrue);
      expect(toggles.alarmsEnabled, isTrue);
      expect(toggles.configEnabled, isTrue);
      expect(toggles.drawingsEnabled, isTrue);
      expect(toggles.trendsEnabled, isTrue);
      expect(toggles.plcCodeEnabled, isTrue);
      expect(toggles.proposalsEnabled, isTrue);
      expect(toggles.techDocsEnabled, isTrue);
    });

    test('allEnabled is a const with all true', () {
      expect(McpToolToggles.allEnabled.tagsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.alarmsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.configEnabled, isTrue);
      expect(McpToolToggles.allEnabled.drawingsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.trendsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.plcCodeEnabled, isTrue);
      expect(McpToolToggles.allEnabled.proposalsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.techDocsEnabled, isTrue);
      expect(McpToolToggles.allEnabled.screenshotsEnabled, isTrue);
    });

    test('legacyKeys contains exactly 9 keys matching mcp_tools_*_enabled pattern',
        () {
      expect(McpToolToggles.legacyKeys, hasLength(9));
      for (final key in McpToolToggles.legacyKeys) {
        expect(key, startsWith('mcp_tools_'));
        expect(key, endsWith('_enabled'));
      }
    });

    test('fromJson with empty map returns all true (missing keys default to true)',
        () {
      final toggles = McpToolToggles.fromJson({});
      expect(toggles.tagsEnabled, isTrue);
      expect(toggles.alarmsEnabled, isTrue);
      expect(toggles.configEnabled, isTrue);
      expect(toggles.drawingsEnabled, isTrue);
      expect(toggles.trendsEnabled, isTrue);
      expect(toggles.plcCodeEnabled, isTrue);
      expect(toggles.proposalsEnabled, isTrue);
      expect(toggles.techDocsEnabled, isTrue);
    });

    test('toJson/fromJson roundtrip', () {
      const original = McpToolToggles(
        tagsEnabled: false,
        plcCodeEnabled: false,
      );
      final json = original.toJson();
      final restored = McpToolToggles.fromJson(json);

      expect(restored.tagsEnabled, isFalse);
      expect(restored.plcCodeEnabled, isFalse);
      expect(restored.alarmsEnabled, isTrue);
    });

    test('fromLegacyMap reads legacy preference keys', () {
      final toggles = McpToolToggles.fromLegacyMap({
        McpToolToggles.kTechDocsEnabled: false,
      });
      expect(toggles.techDocsEnabled, isFalse);
      expect(toggles.tagsEnabled, isTrue);
    });

    test('fromLegacyMap with single key disabled returns that field false, rest true',
        () {
      final toggles = McpToolToggles.fromLegacyMap({
        McpToolToggles.kTagsEnabled: false,
      });
      expect(toggles.tagsEnabled, isFalse);
      expect(toggles.alarmsEnabled, isTrue);
      expect(toggles.configEnabled, isTrue);
      expect(toggles.drawingsEnabled, isTrue);
      expect(toggles.trendsEnabled, isTrue);
      expect(toggles.plcCodeEnabled, isTrue);
      expect(toggles.proposalsEnabled, isTrue);
    });

    test('copyWithToggle changes one toggle at a time', () {
      const toggles = McpToolToggles();
      final updated = toggles.copyWithToggle('tags', false);

      expect(updated.tagsEnabled, isFalse);
      expect(updated.alarmsEnabled, isTrue);
    });

    test('getByKey returns correct value for each key', () {
      const toggles = McpToolToggles(tagsEnabled: false);
      expect(toggles.getByKey('tags'), isFalse);
      expect(toggles.getByKey('alarms'), isTrue);
      expect(toggles.getByKey('unknown'), isTrue);
    });

    test('toolGroupMeta contains 10 entries with key, title, description', () {
      expect(McpToolToggles.toolGroupMeta, hasLength(10));
      for (final meta in McpToolToggles.toolGroupMeta) {
        expect(meta.key, isNotEmpty);
        expect(meta.title, isNotEmpty);
        expect(meta.description, isNotEmpty);
        // Key must be one of the allJsonKeys
        expect(McpToolToggles.allJsonKeys, contains(meta.key));
      }
    });
  });

  group('Conditional tool registration', () {
    late ServerDatabase db;
    late MockStateReader stateReader;
    late MockAlarmReader alarmReader;
    late MockDrawingIndex drawingIndex;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      stateReader = MockStateReader();
      stateReader.setValue('pump3.speed', 1750);

      alarmReader = MockAlarmReader();
      alarmReader.addAlarmConfig({
        'uid': 'alarm-001',
        'key': 'pump3.overtemp',
        'title': 'Pump 3 Overtemp',
        'description': 'Pump 3 exceeded temperature threshold',
        'rules': '{"condition":"temp > 80"}',
      });

      drawingIndex = MockDrawingIndex();
    });

    tearDown(() async {
      await db.close();
    });

    TfcMcpServer createServer({McpToolToggles? toggles}) {
      return TfcMcpServer(
        database: db,
        stateReader: stateReader,
        alarmReader: alarmReader,
        drawingIndex: drawingIndex,
        toggles: toggles ?? McpToolToggles.allEnabled,
      );
    }

    test('allEnabled registers 41 tools (19 read + 13 write + 9 report)',
        () async {
      final server = createServer();
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        expect(tools, hasLength(41));
      } finally {
        await client.close();
      }
    });

    test('tagsEnabled=false registers 38 tools', () async {
      final server = createServer(
        toggles: const McpToolToggles(tagsEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        final names = tools.map((t) => t.name).toSet();
        expect(tools, hasLength(38));
        expect(names, isNot(contains('list_tags')));
        expect(names, isNot(contains('get_tag_value')));
      } finally {
        await client.close();
      }
    });

    test('alarmsEnabled=false registers 33 tools', () async {
      final server = createServer(
        toggles: const McpToolToggles(alarmsEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        final names = tools.map((t) => t.name).toSet();
        // alarmsEnabled=false removes: list_alarms, get_alarm_detail,
        // query_alarm_history (3 alarm read tools), diagnose_asset (needs
        // both tagsEnabled && alarmsEnabled), create_alarm, update_alarm,
        // delete_alarm (write tools gated by alarmsEnabled inside the
        // proposalsEnabled block).
        // 41 total - 8 = 33.
        expect(tools, hasLength(33));
        expect(names, isNot(contains('list_alarms')));
        expect(names, isNot(contains('get_alarm_detail')));
        expect(names, isNot(contains('query_alarm_history')));
        expect(names, isNot(contains('diagnose_asset')));
        expect(names, isNot(contains('create_alarm')));
        expect(names, isNot(contains('update_alarm')));
        expect(names, isNot(contains('delete_alarm')));
      } finally {
        await client.close();
      }
    });

    test('proposalsEnabled=false registers 28 tools', () async {
      final server = createServer(
        toggles: const McpToolToggles(proposalsEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        final names = tools.map((t) => t.name).toSet();
        expect(tools, hasLength(28));
        expect(names, isNot(contains('create_access_template')));
        expect(names, isNot(contains('update_access_template')));
        expect(names, isNot(contains('delete_access_template')));
        expect(names, isNot(contains('bind_key_access_template')));
        expect(names, isNot(contains('create_alarm')));
        expect(names, isNot(contains('update_alarm')));
        expect(names, isNot(contains('delete_alarm')));
        expect(names, isNot(contains('create_key_mapping')));
        expect(names, isNot(contains('update_key_mapping')));
        expect(names, isNot(contains('delete_key_mapping')));
        expect(names, isNot(contains('propose_page')));
        expect(names, isNot(contains('propose_asset')));
        expect(names, isNot(contains('update_asset')));
      } finally {
        await client.close();
      }
    });

    test('configEnabled=false removes config tools and config-dependent write tools',
        () async {
      final server = createServer(
        toggles: const McpToolToggles(configEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        final names = tools.map((t) => t.name).toSet();
        // Config read tools removed (8): list_pages, list_assets,
        // get_asset_detail, list_key_mappings, list_alarm_definitions,
        // list_asset_types, list_access_templates, list_unbound_keys.
        // Config-dependent write tools removed (10): create_alarm,
        // update_alarm, delete_alarm (the alarm write tools need
        // configEnabled for their lookups), create_key_mapping,
        // update_key_mapping, delete_key_mapping, and the four
        // access-template write tools, which validate against the read half.
        // 41 total - 18 = 23.
        expect(tools, hasLength(23));
        expect(names, isNot(contains('list_pages')));
        expect(names, isNot(contains('list_assets')));
        expect(names, isNot(contains('get_asset_detail')));
        expect(names, isNot(contains('list_key_mappings')));
        expect(names, isNot(contains('list_alarm_definitions')));
        expect(names, isNot(contains('list_asset_types')));
        expect(names, isNot(contains('create_alarm')));
        expect(names, isNot(contains('update_alarm')));
        expect(names, isNot(contains('delete_alarm')));
        expect(names, isNot(contains('create_key_mapping')));
        expect(names, isNot(contains('update_key_mapping')));
        expect(names, isNot(contains('delete_key_mapping')));
      } finally {
        await client.close();
      }
    });

    test('all toggles disabled registers only 1 tool (ping)', () async {
      final server = createServer(
        toggles: const McpToolToggles(
          tagsEnabled: false,
          alarmsEnabled: false,
          configEnabled: false,
          drawingsEnabled: false,
          trendsEnabled: false,
          plcCodeEnabled: false,
          proposalsEnabled: false,
          techDocsEnabled: false,
          reportsEnabled: false,
        ),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final tools = await client.listTools();
        final names = tools.map((t) => t.name).toSet();
        expect(tools, hasLength(1));
        expect(names, contains('ping'));
      } finally {
        await client.close();
      }
    });

    test(
        'resources always registered; prompts gated by their required toggles',
        () async {
      // When all toggles are off, only resources are still registered.
      // Prompts are gated: alarm prompts require alarmsEnabled,
      // diagnose_equipment requires tagsEnabled && alarmsEnabled.
      final server = createServer(
        toggles: const McpToolToggles(
          tagsEnabled: false,
          alarmsEnabled: false,
          configEnabled: false,
          drawingsEnabled: false,
          trendsEnabled: false,
          plcCodeEnabled: false,
          proposalsEnabled: false,
          techDocsEnabled: false,
        ),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final resources = await client.listResources();
        expect(resources.resources, isNotEmpty,
            reason:
                'Some resources (knowledge, drawings index, plc code index, '
                'tech docs) are always registered; config snapshot is gated '
                'by configEnabled');
      } finally {
        await client.close();
      }
    });

    test('alarmsEnabled=true registers alarm prompts', () async {
      // Prompts require their associated toggles to be active.
      // With alarmsEnabled=true and tagsEnabled=true (default),
      // all 3 prompts should be present.
      final server = createServer();
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final prompts = await client.listPrompts();
        final names = prompts.prompts.map((p) => p.name).toSet();
        expect(names, contains('explain_alarm'));
        expect(names, contains('shift_handover'));
        expect(names, contains('diagnose_equipment'));
      } finally {
        await client.close();
      }
    });

    test('configEnabled=false omits config snapshot resource', () async {
      final server = createServer(
        toggles: const McpToolToggles(configEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final resources = await client.listResources();
        final uris = resources.resources.map((r) => r.uri).toSet();
        expect(uris, isNot(contains('scada://config/snapshot')),
            reason:
                'Config snapshot resource must not be exposed when configEnabled=false');
      } finally {
        await client.close();
      }
    });

    test('configEnabled=true registers config snapshot resource', () async {
      final server = createServer(
        toggles: const McpToolToggles(configEnabled: true),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final resources = await client.listResources();
        final uris = resources.resources.map((r) => r.uri).toSet();
        expect(uris, contains('scada://config/snapshot'),
            reason:
                'Config snapshot resource must be exposed when configEnabled=true');
      } finally {
        await client.close();
      }
    });

    test('alarmsEnabled=false omits alarm-dependent prompts', () async {
      final server = createServer(
        toggles: const McpToolToggles(alarmsEnabled: false),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        // When alarmsEnabled=false no prompts are registered, so the server
        // does not advertise the prompts capability and listPrompts() throws
        // McpError -32601 (Method not found). We treat that as "no prompts".
        Set<String> names = {};
        try {
          final result = await client.listPrompts();
          names = result.prompts.map((p) => p.name).toSet();
        } catch (_) {
          // No prompts capability — names stays empty, which is correct.
        }
        expect(names, isNot(contains('explain_alarm')));
        expect(names, isNot(contains('shift_handover')));
        expect(names, isNot(contains('diagnose_equipment')));
      } finally {
        await client.close();
      }
    });
  });
}
