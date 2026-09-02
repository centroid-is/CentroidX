import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/identity/env_operator_identity.dart';
import 'package:tfc_mcp_server/src/server.dart';
import 'package:tfc_mcp_server/src/services/report_service.dart';
import 'package:tfc_mcp_server/src/tools/report_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/mock_state_reader.dart';
import '../helpers/test_database.dart';

const _reportToolNames = [
  'list_reports',
  'get_report_definition',
  'generate_report',
  'resolve_shift',
  'get_shift_calendar',
  'set_shift_calendar',
  'create_report',
  'update_report',
  'delete_report',
];

void main() {
  group('registration through TfcMcpServer toggles', () {
    late ServerDatabase db;

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');
    });

    tearDown(() => db.close());

    TfcMcpServer createServer(McpToolToggles toggles) {
      return TfcMcpServer(
        identity: EnvOperatorIdentity(
          environmentProvider: () => {'TFC_USER': 'op1'},
        ),
        database: db,
        stateReader: MockStateReader(),
        alarmReader: MockAlarmReader(),
        toggles: toggles,
      );
    }

    test('report tools appear when the group is enabled', () async {
      final client =
          await MockMcpClient.connect(createServer(McpToolToggles.allEnabled)
              .mcpServer);
      try {
        final names = (await client.listTools()).map((t) => t.name).toList();
        for (final name in _reportToolNames) {
          expect(names, contains(name));
        }
      } finally {
        await client.close();
      }
    });

    test('report tools vanish when the group is disabled', () async {
      final client = await MockMcpClient.connect(
          createServer(const McpToolToggles(reportsEnabled: false))
              .mcpServer);
      try {
        final names = (await client.listTools()).map((t) => t.name).toList();
        for (final name in _reportToolNames) {
          expect(names, isNot(contains(name)));
        }
        // Only the reports group is off — its neighbours stay.
        expect(names, contains('query_trend_data'));
      } finally {
        await client.close();
      }
    });
  });

  group('end-to-end through a client', () {
    late ServerDatabase db;
    late MockMcpClient client;

    // Fixed mid-shift clock: Tuesday 2026-09-01 10:00.
    final now = DateTime(2026, 9, 1, 10);

    setUp(() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');

      final mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );
      final registry = ToolRegistry(
        mcpServer: mcpServer,
        identity: EnvOperatorIdentity(
          environmentProvider: () => {'TFC_USER': 'op1'},
        ),
        auditLogService: AuditLogService(db),
      );
      registerReportTools(
          registry, ReportService(db, clock: () => now));
      client = await MockMcpClient.connect(mcpServer);

      await db.customStatement(
          'CREATE TABLE "line.temperature" ("value" REAL, "time" TEXT)');
      await db.customStatement(
          'INSERT INTO "line.temperature" ("time", "value") VALUES (?, ?)',
          [
            DateTime(2026, 9, 1, 8).toUtc().toIso8601String(),
            25,
          ]);
    });

    tearDown(() async {
      await client.close();
      await db.close();
    });

    String textOf(CallToolResult result) =>
        (result.content.single as TextContent).text;

    test('configure shifts, create a report, generate the current shift',
        () async {
      final setShifts = await client.callTool('set_shift_calendar', {
        'shifts': [
          {'name': 'Day', 'start_minutes': 420, 'duration_minutes': 480},
        ],
      });
      expect(setShifts.isError, isNot(isTrue));

      final create = await client.callTool('create_report', {
        'config': {
          'id': 'shift1',
          'name': 'Shift report',
          'range': 'shift',
          'sections': [
            {
              'type': 'kpi',
              'metrics': [
                {
                  'key': 'line.temperature',
                  'label': 'Temp',
                  'aggregate': 'last',
                  'unit': '°C',
                },
              ],
            },
            {'type': 'text', 'title': 'Notes', 'text': 'All quiet.'},
          ],
        },
      });
      expect(create.isError, isNot(isTrue), reason: textOf(create));

      final generated =
          await client.callTool('generate_report', {'report_id': 'shift1'});
      expect(generated.isError, isNot(isTrue), reason: textOf(generated));
      final text = textOf(generated);
      expect(text, contains('Shift report'));
      expect(text, contains('(so far)'));
      expect(text, contains('25.0 °C'));
      expect(text, contains('All quiet.'));

      final resolved = await client.callTool('resolve_shift', {});
      expect(textOf(resolved), contains('Day'));

      final listed = await client.callTool('list_reports', {});
      expect(textOf(listed), contains('shift1'));
    });

    test('an invalid section type comes back as a helpful isError', () async {
      final create = await client.callTool('create_report', {
        'config': {
          'id': 'bad',
          'name': 'Bad',
          'sections': [
            {'type': 'hologram'}
          ],
        },
      });
      expect(create.isError, isTrue);
      expect(textOf(create), contains('hologram'));
      expect(textOf(create), contains('alarm_summary'));
    });

    test('generate_report for a missing report is isError', () async {
      final result =
          await client.callTool('generate_report', {'report_id': 'ghost'});
      expect(result.isError, isTrue);
      expect(textOf(result), contains('list_reports'));
    });
  });
}
