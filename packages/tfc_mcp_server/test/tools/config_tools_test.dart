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

  group('check_config_consistency', () {
    // The production arm of SC-6. The check itself is proven in tfc_dart, over
    // planted violations and over real writes to Postgres; what is proven here
    // is that an engineer can point it at a plant database through MCP and get
    // an answer they can act on — including when the answer is "I could not
    // check", which must never be dressed up as "clean".
    late ServerDatabase db;
    late McpServer mcpServer;
    late MockMcpClient client;

    setUp(() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );
      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: AuditLogService(db),
      );
      registerConfigTools(registry, ConfigService(db));
      client = await MockMcpClient.connect(mcpServer);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    Future<String> check([Map<String, dynamic> arguments = const {}]) async {
      final result = await client.callTool('check_config_consistency',
          Map<String, dynamic>.from(arguments));
      expect(result.isError, isNot(true));
      return (result.content.first as TextContent).text;
    }

    test('is listed among the tools', () async {
      final names = (await client.listTools()).map((t) => t.name);
      expect(names, contains('check_config_consistency'));
    });

    test('says so when the tables are not there, rather than "no violations"',
        () async {
      // A ServerDatabase opened on a database tfc_dart has not migrated. Every
      // other read in ConfigService answers "nothing configured" here; this
      // one must not, because an unread table and a consistent one are the
      // same empty list.
      final text = await check();

      expect(text, contains('Could not check'));
      expect(text, isNot(contains('no violations')));
    });

    test('reports a clean database as clean', () async {
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      await insertConfigRow(db,
          kind: 'key_mapping', id: 'CN01.RUN', payload: {'ns': 4});
      await insertConfigChangeRow(db,
          kind: 'key_mapping',
          id: 'CN01.RUN',
          newValue: entityOf({'ns': 4}));

      expect(await check(), contains('no violations'));
    });

    test('lists planted violations with the invariant each breaks', () async {
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      // A row the log never heard of, and an asset whose page is gone.
      await insertConfigRow(db,
          kind: 'key_mapping', id: 'CN01.RUN', payload: {'ns': 4});
      await insertConfigRow(db,
          kind: 'asset',
          id: 'a1',
          parentId: 'page-gone',
          sortIndex: 0,
          payload: {'asset_name': 'lamp'});

      final text = await check();

      expect(text, contains('inconsistencies (3)'));
      expect(text, contains('missing_history'));
      expect(text, contains('orphaned_parent'));
      expect(text, contains('CN01.RUN'));
      expect(text, contains('page-gone'));
    });

    test('reports a position moved behind the log', () async {
      // The position pin, through the tool: the payload matches its history
      // exactly and only `sort_index` differs.
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      await insertConfigRow(db,
          kind: 'asset', id: 'a1', sortIndex: 3, payload: {'asset_name': 'l'});
      await insertConfigChangeRow(db,
          kind: 'asset',
          id: 'a1',
          newValue: entityOf({'asset_name': 'l'}, sortIndex: 0));

      final text = await check();

      expect(text, contains('entity_disagrees'));
      expect(text, contains('"sort_index":3'));
      expect(text, contains('"sort_index":0'));
    });

    test('caps the values it renders', () async {
      // T-04-08b: a violation carries whole entities, and an entity can be
      // megabytes of base64. The response must not become the payload.
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      final huge = 'A' * 5000;
      await insertConfigRow(db,
          kind: 'preference', id: 'big', payload: {'blob': huge});
      await insertConfigChangeRow(db,
          kind: 'preference', id: 'big', newValue: entityOf({'blob': 'B'}));

      final text = await check();

      expect(text, contains('entity_disagrees'));
      expect(text, contains('chars total'));
      expect(text, isNot(contains(huge)));
      expect(text.length, lessThan(1500));
    });

    test('limit bounds the list without hiding the count', () async {
      await createConfigItemTable(db);
      await createConfigChangeTable(db);
      for (var i = 0; i < 5; i++) {
        await insertConfigRow(db,
            kind: 'key_mapping', id: 'CN0$i.RUN', payload: {'ns': i});
      }

      final text = await check({'limit': 2});

      expect(text, contains('inconsistencies (5, showing 2)'));
      expect(text, contains('CN00.RUN'));
      expect(text, isNot(contains('CN04.RUN')));
    });
  });
}
