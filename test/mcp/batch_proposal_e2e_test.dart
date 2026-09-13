/// End-to-end test: multiple MCP create_alarm calls → multiple proposals.
///
/// Verifies that when the LLM calls create_alarm 10 times (e.g., "create an
/// alarm for all 10 motors"), each call delivers a separate proposal through
/// the server's proposal callback and each is independently trackable in
/// [ProposalStateNotifier].
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import 'package:tfc/providers/proposal_state.dart';

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

PendingProposal _pending(Map<String, dynamic> wrapped) => PendingProposal(
      id: nextLocalProposalId(),
      proposalType: wrapped['_proposal_type'] as String,
      title: wrapped['title'] as String,
      proposalJson: jsonEncode(wrapped),
      operatorId: 'local',
      createdAt: DateTime.now(),
    );

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.inMemoryForTest();
  });

  tearDown(() async {
    await db.close();
  });

  test('10 create_alarm calls deliver 10 separate proposals', () async {
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

    // Call create_alarm 10 times (simulating "create alarm for all 10 motors")
    final returned = <Map<String, dynamic>>[];
    for (var i = 1; i <= 10; i++) {
      final result = await client.callTool(CallToolRequest(
        name: 'create_alarm',
        arguments: {
          'title': 'Motor $i Fault',
          'key': 'motor$i.fault',
          'description': 'Motor $i fault alarm',
          'rules': [
            {
              'level': 'error',
              'formula': 'motor$i.fault > 0',
            },
          ],
        },
      ));

      final text =
          result.content.whereType<TextContent>().map((c) => c.text).join();
      returned.add(jsonDecode(text) as Map<String, dynamic>);
    }

    // Verify all 10 proposals are unique
    expect(returned, hasLength(10));
    final uids = returned.map((p) => p['uid'] as String).toSet();
    expect(uids, hasLength(10), reason: 'All UIDs should be unique');

    for (final p in returned) {
      expect(p['_proposal_type'], 'alarm');
    }

    // Every one of them reached the UI through the callback, in order, and
    // carrying the same content the tool returned.
    expect(delivered, hasLength(10));
    for (var i = 0; i < 10; i++) {
      expect(delivered[i]['_proposal_type'], 'alarm');
      expect(delivered[i]['title'], 'Motor ${i + 1} Fault');
      expect(jsonEncode(delivered[i]), jsonEncode(returned[i]));
    }

    // Cleanup
    await client.close();
    server.mcpServer.close();
  });

  test('ProposalStateNotifier tracks 10 proposals and batch-accepts them',
      () async {
    final notifier = ProposalStateNotifier();

    for (var i = 1; i <= 10; i++) {
      notifier.addProposal(_pending({
        '_proposal_type': 'alarm',
        'uid': 'motor-$i',
        'title': 'Motor $i Fault',
      }));
    }

    expect(notifier.state.pendingCount, 10);
    expect(notifier.state.ofType('alarm'), hasLength(10));

    final accepted = await notifier.acceptAllOfType('alarm');
    expect(accepted, hasLength(10));
    expect(notifier.state.pendingCount, 0);
  });

  test('the same proposal arriving twice is deduplicated by its JSON',
      () async {
    // An in-app tool call surfaces a proposal twice: once from the server
    // callback and once from the tool result. The two copies are minted
    // separate ids, so only the JSON comparison can collapse them.
    final notifier = ProposalStateNotifier();

    final wrapped = [
      for (var i = 1; i <= 5; i++)
        {
          '_proposal_type': 'alarm',
          'uid': 'motor-$i',
          'title': 'Motor $i Fault',
        }
    ];

    for (final w in wrapped) {
      notifier.addProposal(_pending(w));
    }
    expect(notifier.state.pendingCount, 5);

    for (final w in wrapped) {
      notifier.addProposal(_pending(w));
    }
    expect(notifier.state.pendingCount, 5);
    expect(
      notifier.state.proposals.map((p) => p.id).toSet(),
      hasLength(5),
      reason: 'ids stay unique even though the JSON collided',
    );
  });
}
