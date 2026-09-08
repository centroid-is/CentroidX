/// End-to-end test: MCP tool call → proposal callback → PendingProposal.
///
/// Verifies the full chain from a real MCP client calling a write tool
/// through to the map the Flutter side turns into a [PendingProposal]. That
/// callback is the entire delivery path: nothing about a proposal is stored.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import 'package:tfc/providers/proposal.dart';

/// Mock client that connects in-process to an MCP server.
Future<McpClient> _connectClient(McpServer server) async {
  final clientToServer = StreamController<List<int>>();
  final serverToClient = StreamController<List<int>>();

  final serverTransport = IOStreamTransport(
    stream: clientToServer.stream,
    sink: serverToClient.sink,
  );
  final clientTransport = IOStreamTransport(
    stream: serverToClient.stream,
    sink: clientToServer.sink,
  );

  await server.connect(serverTransport);

  final client = McpClient(
    const Implementation(name: 'test-client', version: '0.1.0'),
    options: McpClientOptions(
      capabilities: ClientCapabilities(
        sampling: ClientCapabilitiesSampling(),
      ),
    ),
  );
  await client.connect(clientTransport);
  return client;
}

/// No-op reader stubs.
class _EmptyStateReader implements StateReader {
  @override
  Map<String, dynamic> get currentValues => {};
  @override
  dynamic getValue(String key) => null;
  @override
  List<String> get keys => [];
}

class _EmptyAlarmReader implements AlarmReader {
  @override
  List<Map<String, dynamic>> get alarmConfigs => [];
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.inMemoryForTest();
  });

  tearDown(() async {
    await db.close();
  });

  test('MCP create_alarm tool → proposal callback → routable proposal',
      () async {
    final delivered = <Map<String, dynamic>>[];
    final server = TfcMcpServer(
      database: db,
      stateReader: _EmptyStateReader(),
      alarmReader: _EmptyAlarmReader(),
      // Every group, which is what this always ran with: while the
      // constructor defaulted each field to true, naming `proposals`
      // added nothing and the write tools it needs -- create_alarm is
      // gated on alarms and config as well -- came from the defaults.
      toggles: McpToolToggles.allEnabled,
      onProposal: delivered.add,
    );

    final client = await _connectClient(server.mcpServer);

    final result = await client.callTool(CallToolRequest(
      name: 'create_alarm',
      arguments: {
        'title': 'Pump Overcurrent',
        'key': 'pump3.overcurrent',
        'description': 'Motor current exceeded safe threshold',
        'rules': [
          {
            'level': 'warning',
            'formula': 'pump3.current > 15',
            'acknowledge_required': false,
          },
          {
            'level': 'error',
            'formula': 'pump3.current > 20',
            'acknowledge_required': true,
          },
        ],
      },
    ));

    // The tool returned a proposal.
    final text =
        result.content.whereType<TextContent>().map((c) => c.text).join();
    final proposal = jsonDecode(text) as Map<String, dynamic>;
    expect(proposal['_proposal_type'], 'alarm');
    expect(proposal['title'], 'Pump Overcurrent');

    // The callback fired synchronously during the tool call -- no polling, no
    // waiting -- with the same content the tool result carries.
    expect(delivered, hasLength(1));
    expect(jsonEncode(delivered.single), text);

    // And the Flutter side can route what it was handed.
    final pending = PendingProposal(
      id: nextLocalProposalId(),
      proposalType: delivered.single['_proposal_type'] as String,
      title: delivered.single['title'] as String,
      proposalJson: jsonEncode(delivered.single),
      operatorId: 'local',
      createdAt: DateTime.now(),
    );
    expect(pending.proposalType, 'alarm');
    expect(pending.title, 'Pump Overcurrent');
    expect(pending.editorRoute, '/advanced/alarm-editor');
    expect(pending.editorLabel, 'Alarm Editor');
    expect(pending.action, ProposalOp.create);

    await client.close();
    server.mcpServer.close();
  });
}
