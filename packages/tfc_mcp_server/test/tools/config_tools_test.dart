import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/tools/config_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/config_rows.dart';
import '../helpers/mock_mcp_client.dart';

void main() {
  group('Config tools integration', () {
    late ServerDatabase db;
    late McpServer mcpServer;
    late MockMcpClient client;

    /// Two pages, as the rows store them: keyed by the page's stable id, with
    /// the path the pages map keys on inside `menu_item`.
    final pageRows = {
      'page-overview': {
        'title': 'Overview',
        'key': 'overview',
        'menu_item': {'label': 'Overview', 'path': 'overview'},
        'widgets': [
          {'type': 'gauge', 'key': 'pump3.speed'},
        ],
      },
      'page-conveyor': {
        'title': 'Conveyor Control',
        'key': 'conveyor',
        'menu_item': {'label': 'Conveyor', 'path': 'conveyor'},
        'widgets': [
          {'type': 'display', 'key': 'conveyor.speed'},
        ],
      },
    };

    /// Sample key mappings. Every value has to be one the codec accepts now
    /// that these arrive as rows — reading the blob validated nothing, so the
    /// truncated `collect` entries this fixture used to carry went unnoticed.
    final keyMappings = {
      'nodes': {
        'pump3.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Pump3.Speed'},
        },
        'conveyor.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Conv.Speed'},
        },
      },
    };

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      // Seed test data, as config_item rows
      await seedPages(db, pageRows);
      await seedKeyMappings(db, keyMappings);
      // Alarm definitions live in the alarm_man_config preference, which is
      // what AlarmMan loads and saves. The `alarm` table is never written.
      await seedPreferenceRow(db, 'alarm_man_config', {
        'alarms': [
          {
            'uid': 'alarm-1',
            'title': 'Pump 3 High Temp',
            'description': 'Temperature exceeds 80C',
            'rules': [],
          },
        ],
      });

      final auditService = AuditLogService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );

      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      final configService = ConfigService(db);
      registerConfigTools(registry, configService);

      client = await MockMcpClient.connect(mcpServer);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    test('list_pages returns formatted page list', () async {
      final result = await client.callTool('list_pages', {});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Pages'));
      expect(text, contains('overview'));
      expect(text, contains('Overview'));
      expect(text, contains('conveyor'));
      expect(text, contains('Conveyor Control'));
    });

    test('list_assets returns formatted asset summary', () async {
      final result = await client.callTool('list_assets', {});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Assets'));
      expect(text, contains('overview'));
      expect(text, contains('conveyor'));
    });

    test('get_asset_detail with valid pageKey returns page config', () async {
      final result =
          await client.callTool('get_asset_detail', {'page_key': 'overview'});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('overview'));
      expect(text, contains('Overview'));
      expect(text, contains('widgets'));
    });

    test('get_asset_detail with invalid pageKey returns isError', () async {
      final result = await client
          .callTool('get_asset_detail', {'page_key': 'nonexistent'});

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('nonexistent'));
    });

    test('list_key_mappings returns formatted mappings', () async {
      final result = await client.callTool('list_key_mappings', {});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Key Mappings'));
      expect(text, contains('pump3.speed'));
      expect(text, contains('Pump3.Speed'));
    });

    test('list_alarm_definitions returns formatted alarm definitions',
        () async {
      final result = await client.callTool('list_alarm_definitions', {});

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('Alarm Definitions'));
      expect(text, contains('alarm-1'));
      expect(text, contains('Pump 3 High Temp'));
    });
  });
}
