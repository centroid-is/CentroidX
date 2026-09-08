/// End-to-end tests for the page, asset and key-mapping write tools:
/// MCP tool call → proposal callback → the routing the UI does with it.
///
/// The callback is the whole delivery path; nothing about a proposal is
/// stored, so what the callback hands over is what the operator sees.
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

/// The [PendingProposal] the Flutter side builds out of a delivered map.
PendingProposal _pending(Map<String, dynamic> wrapped) => PendingProposal(
      id: nextLocalProposalId(),
      proposalType: wrapped['_proposal_type'] as String,
      title: wrapped['title'] as String? ?? wrapped['key'] as String? ?? '',
      proposalJson: jsonEncode(wrapped),
      operatorId: 'local',
      createdAt: DateTime.now(),
    );

void main() {
  late AppDatabase db;
  late List<Map<String, dynamic>> delivered;
  late TfcMcpServer server;
  late McpClient client;

  setUp(() async {
    db = AppDatabase.inMemoryForTest();
    delivered = [];
    server = TfcMcpServer(
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
    client = await _connectClient(server.mcpServer);
  });

  tearDown(() async {
    await client.close();
    server.mcpServer.close();
    await db.close();
  });

  /// Calls [name] and returns the decoded tool result.
  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> arguments) async {
    final result =
        await client.callTool(CallToolRequest(name: name, arguments: arguments));
    final text =
        result.content.whereType<TextContent>().map((c) => c.text).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  // ── propose_page E2E ──────────────────────────────────────────────────

  test('MCP propose_page tool → proposal callback → page editor route',
      () async {
    final proposal = await call('propose_page', {
      'title': 'Pump Overview',
      'assets': [
        {
          'asset_type': 'NumberConfig',
          'key': 'pump3.speed',
          'label': 'Pump 3 Speed',
          'x': 0.1,
          'y': 0.05,
        },
        {
          'asset_type': 'LEDConfig',
          'key': 'pump3.pressure',
          'label': 'Pump 3 Pressure',
        },
      ],
    });

    expect(proposal['_proposal_type'], 'page');
    expect(proposal['title'], 'Pump Overview');
    expect(proposal['key'], 'page-pump-overview');
    expect((proposal['assets'] as List), hasLength(2));

    // Delivered to the UI, with the asset data AssetRegistry.parse needs.
    expect(delivered, hasLength(1));
    final wrapped = delivered.single;
    expect((wrapped['assets'] as List).first['asset_name'], 'NumberConfig');
    expect((wrapped['assets'] as List).first['key'], 'pump3.speed');

    final pending = _pending(wrapped);
    expect(pending.title, 'Pump Overview');
    expect(pending.proposalType, 'page');
    expect(pending.editorRoute, '/advanced/page-editor');
  });

  // ── propose_asset E2E ─────────────────────────────────────────────────

  test('MCP propose_asset tool → proposal callback → page editor route',
      () async {
    final proposal = await call('propose_asset', {
      'title': 'Pump Station',
      'page_key': '/',
      'children': [
        {
          'asset_type': 'NumberConfig',
          'key': 'pump3.speed',
          'title': 'Pump 3',
        },
        {
          'asset_type': 'LEDConfig',
          'key': 'pump4.status',
          'title': 'Pump 4',
        },
      ],
    });

    expect(proposal['_proposal_type'], 'asset');
    expect(proposal['title'], 'Pump Station');
    expect(proposal['key'], 'asset-pump-station');
    expect(proposal['page_key'], '/');
    final children = proposal['children'] as List;
    expect(children, hasLength(2));
    // Each child must have asset_name for AssetRegistry.parse
    expect(children[0]['asset_name'], 'NumberConfig');
    expect(children[0]['key'], 'pump3.speed');
    expect(children[1]['asset_name'], 'LEDConfig');
    expect(children[1]['key'], 'pump4.status');

    expect(delivered, hasLength(1));
    final wrapped = delivered.single;
    expect((wrapped['children'] as List).first['asset_name'], 'NumberConfig');

    final pending = _pending(wrapped);
    expect(pending.title, 'Pump Station');
    expect(pending.proposalType, 'asset');
    expect(pending.editorRoute, '/advanced/page-editor');
  });

  // ── create_key_mapping E2E ────────────────────────────────────────────

  test('MCP create_key_mapping tool → proposal callback → key repository route',
      () async {
    final proposal = await call('create_key_mapping', {
      'key': 'belt.speed',
      'namespace': 2,
      'identifier': 'Belt.Speed',
    });

    expect(proposal['_proposal_type'], 'key_mapping');
    expect(proposal['key'], 'belt.speed');
    expect(proposal['opcua_node'], isNotNull);
    expect(proposal['opcua_node']['namespace'], 2);
    expect(proposal['opcua_node']['identifier'], 'Belt.Speed');

    expect(delivered, hasLength(1));
    final wrapped = delivered.single;
    expect(wrapped['key'], 'belt.speed');
    expect(wrapped['opcua_node']['namespace'], 2);
    expect(wrapped['opcua_node']['identifier'], 'Belt.Speed');

    final pending = _pending(wrapped);
    expect(pending.proposalType, 'key_mapping');
    expect(pending.editorRoute, '/advanced/key-repository');
  });

  // ── Mixed proposal types E2E ──────────────────────────────────────────

  test('all three proposal types are delivered and route separately',
      () async {
    await call('propose_page', {
      'title': 'Motor Dashboard',
      'assets': [
        {
          'asset_type': 'TextAssetConfig',
          'key': 'motors-label',
          'label': 'Motors',
        },
      ],
    });

    await call('propose_asset', {
      'title': 'Motor Group',
      'children': [
        {
          'asset_type': 'NumberConfig',
          'key': 'motor1.speed',
          'title': 'Motor 1',
        },
      ],
    });

    await call('create_key_mapping', {
      'key': 'motor1.speed',
      'namespace': 3,
      'identifier': 'Motor1.Speed',
    });

    expect(delivered, hasLength(3));
    expect(delivered[0]['_proposal_type'], 'page');
    expect(delivered[0]['title'], 'Motor Dashboard');
    expect(delivered[1]['_proposal_type'], 'asset');
    expect(delivered[1]['title'], 'Motor Group');
    expect(delivered[2]['_proposal_type'], 'key_mapping');

    final routeMap = {
      for (final w in delivered)
        w['_proposal_type'] as String: _pending(w).editorRoute,
    };
    expect(routeMap['page'], '/advanced/page-editor');
    expect(routeMap['asset'], '/advanced/page-editor');
    expect(routeMap['key_mapping'], '/advanced/key-repository');
  });

  // ── update_asset E2E ──────────────────────────────────────────────────

  test('MCP update_asset tool → proposal callback → page editor route',
      () async {
    final proposal = await call('update_asset', {
      'page_key': '/',
      'asset_type': 'ThirdPartyEquipmentConfig',
      'title': 'Machine',
      'patch': {'runKey': 'Line1.Running'},
    });

    expect(proposal['_proposal_type'], 'asset_update');
    expect(proposal['page_key'], '/');
    expect((proposal['target'] as Map)['asset_type'],
        'ThirdPartyEquipmentConfig');
    expect((proposal['patch'] as Map)['runKey'], 'Line1.Running');

    expect(delivered, hasLength(1));
    final pending = _pending(delivered.single);
    // The title carries the change itself, not just the target: the banner
    // shows this string and nothing else, so "Update Machine" gave the
    // operator nothing to accept or reject on.
    expect(pending.title, 'Machine: runKey → Line1.Running');
    expect(pending.proposalType, 'asset_update');
    expect(pending.editorRoute, '/advanced/page-editor');
    expect(pending.editorLabel, 'Page Editor');
    expect(pending.action, ProposalOp.update);
  });
}
