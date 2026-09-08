import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/server.dart';
import 'package:tfc_mcp_server/src/tools/tool_toggles.dart';
import '../helpers/mock_alarm_reader.dart';
import '../helpers/mock_drawing_index.dart';
import '../helpers/mock_mcp_client.dart';
import '../helpers/mock_state_reader.dart';

/// The advertised capabilities must match what actually got registered.
///
/// Advertising prompts while zero prompts are registered leaves
/// prompts/list without a request handler in mcp_dart. The protocol layer
/// then answers -32601, but the Streamable HTTP transport only closes the
/// response stream for successful results -- so real clients that probe
/// prompts/list right after initialize hang forever instead of coming up.
void main() {
  const proposalsOnly = McpToolToggles(
    tagsEnabled: false,
    alarmsEnabled: false,
    configEnabled: false,
    drawingsEnabled: false,
    trendsEnabled: false,
    plcCodeEnabled: false,
    techDocsEnabled: false,
  );

  late ServerDatabase db;
  late MockStateReader stateReader;
  late MockAlarmReader alarmReader;
  late MockDrawingIndex drawingIndex;

  setUp(() async {
    db = ServerDatabase.inMemory();
    await db.customStatement('SELECT 1');
    stateReader = MockStateReader();
    alarmReader = MockAlarmReader();
    drawingIndex = MockDrawingIndex();
  });

  tearDown(() async {
    await db.close();
  });

  TfcMcpServer createServer(McpToolToggles toggles) {
    return TfcMcpServer(
      database: db,
      stateReader: stateReader,
      alarmReader: alarmReader,
      drawingIndex: drawingIndex,
      toggles: toggles,
    );
  }

  group('prompts capability tracks prompt registration', () {
    test('proposals-only config does not advertise prompts', () async {
      final server = createServer(proposalsOnly);
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final caps = client.serverCapabilities;
        expect(caps, isNotNull);
        expect(caps!.prompts, isNull,
            reason: 'no prompt is registered without alarms, so the '
                'capability must not be advertised');
        expect(caps.tools, isNotNull);
        expect(caps.resources, isNotNull);
      } finally {
        await client.close();
      }
    });

    test('alarms enabled advertises prompts and prompts/list responds',
        () async {
      // Alarms on and nothing else: `explain_alarm` and `shift_handover` need
      // only alarms, while `diagnose_equipment` needs tags as well, so this
      // says exactly which prompts should appear.
      final server = createServer(
        McpToolToggles.allDisabled.copyWithToggle('alarms', true),
      );
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        expect(client.serverCapabilities!.prompts, isNotNull);
        final prompts = await client.listPrompts();
        expect(
          prompts.prompts.map((p) => p.name),
          unorderedEquals(['explain_alarm', 'shift_handover']),
        );
      } finally {
        await client.close();
      }
    });

    test('all toggles enabled advertises prompts and lists all three',
        () async {
      final server = createServer(McpToolToggles.allEnabled);
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        expect(client.serverCapabilities!.prompts, isNotNull);
        final prompts = await client.listPrompts();
        expect(
          prompts.prompts.map((p) => p.name),
          unorderedEquals(
              ['explain_alarm', 'shift_handover', 'diagnose_equipment']),
        );
      } finally {
        await client.close();
      }
    });
  });

  group('resources/list responds regardless of toggles', () {
    test('proposals-only config still lists the unconditional resources',
        () async {
      final server = createServer(proposalsOnly);
      final client = await MockMcpClient.connect(server.mcpServer);
      try {
        final resources = await client.listResources();
        expect(
          resources.resources.map((r) => r.uri),
          containsAll([
            'scada://drawings/index',
            'scada://source/knowledge',
          ]),
        );
      } finally {
        await client.close();
      }
    });
  });
}
