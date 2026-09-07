import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/safety/elicitation_risk_gate.dart';
import 'package:tfc_mcp_server/src/safety/proposal_declined_exception.dart';
import 'package:tfc_mcp_server/src/safety/risk_gate.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/services/proposal_service.dart';
import 'package:tfc_mcp_server/src/tools/key_mapping_write_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/config_rows.dart';
import '../helpers/mock_mcp_client.dart';

void main() {
  group('Key mapping write tools', () {
    late ServerDatabase db;
    late McpServer mcpServer;
    late MockMcpClient client;

    /// Sample key mappings with existing entries for update tests.
    ///
    /// The `collect` entries two of these used to carry are gone: they were
    /// `{'enabled': ...}`, which `CollectEntry` has never had a field for.
    /// Reading the blob was a bare `jsonDecode` and let that through; reading
    /// the rows goes through `KeyMappingEntry.fromJson`, which does not.
    final keyMappings = {
      'nodes': {
        'belt.speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Belt.Speed'},
        },
        'pump3.pressure': {
          'opcua_node': {'namespace': 3, 'identifier': 'Pump3.Pressure'},
        },
        'weigher9v.acceptWeight': {
          'm2400_node': {
            'record_type': 'recBatch',
            'field': 'weight',
            'server_alias': 'weigher9v',
            'status_filter': 0,
          },
        },
      },
    };

    /// Helper to set up with a configurable elicitation callback.
    Future<MockMcpClient> setupWithElicitation({
      required Future<ElicitResult> Function(ElicitRequest) onElicit,
    }) async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      // Seed the key_mapping rows
      await seedKeyMappings(db, keyMappings);

      final auditService = AuditLogService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(
            tools: ServerCapabilitiesTools(),
          ),
        ),
      );

      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      final riskGate = ElicitationRiskGate(mcpServer);
      final configService = ConfigService(db);
      final proposalService = ProposalService();

      registerKeyMappingWriteTools(
        registry,
        configService: configService,
        riskGate: riskGate,
        proposalService: proposalService,
      );

      return MockMcpClient.connectWithElicitation(
        mcpServer,
        onElicit: onElicit,
      );
    }

    /// Helper to set up with auto-confirm (NoOpRiskGate).
    Future<MockMcpClient> setupAutoConfirm() async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');

      // Seed the key_mapping rows
      await seedKeyMappings(db, keyMappings);

      final auditService = AuditLogService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(
            tools: ServerCapabilitiesTools(),
          ),
        ),
      );

      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      final riskGate = NoOpRiskGate();
      final configService = ConfigService(db);
      final proposalService = ProposalService();

      registerKeyMappingWriteTools(
        registry,
        configService: configService,
        riskGate: riskGate,
        proposalService: proposalService,
      );

      return MockMcpClient.connect(mcpServer);
    }

    tearDown(() async {
      await client.close();
      await db.close();
    });

    group('create_key_mapping', () {
      test('returns proposal JSON with key, opcua_node, and _proposal_type',
          () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'motor.rpm',
          'namespace': 2,
          'identifier': 'Motor.RPM',
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['key'], 'motor.rpm');
        expect(json['opcua_node']['namespace'], 2);
        expect(json['opcua_node']['identifier'], 'Motor.RPM');
        expect(json['_proposal_type'], 'key_mapping');
      });

      test('elicitation message shows key name, namespace, identifier',
          () async {
        String? capturedMessage;
        client = await setupWithElicitation(
          onElicit: (request) async {
            capturedMessage = request.message;
            return ElicitResult(
              action: 'accept',
              content: {'confirm': true},
            );
          },
        );

        await client.callTool('create_key_mapping', {
          'key': 'motor.rpm',
          'namespace': 2,
          'identifier': 'Motor.RPM',
        });

        expect(capturedMessage, isNotNull);
        expect(capturedMessage, contains('motor.rpm'));
        expect(capturedMessage, contains('2'));
        expect(capturedMessage, contains('Motor.RPM'));
      });

      test('declined proposal returns non-error decline message', () async {
        client = await setupWithElicitation(
          onElicit: (request) async {
            return ElicitResult(action: 'decline');
          },
        );

        final result = await client.callTool('create_key_mapping', {
          'key': 'motor.rpm',
          'namespace': 2,
          'identifier': 'Motor.RPM',
        });

        // ElicitationRiskGate auto-confirms even on decline (Flutter UI is the
        // real safety gate), so the tool returns the proposal JSON.
        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['_proposal_type'], 'key_mapping');
      });

      test('does not write to database', () async {
        client = await setupAutoConfirm();

        await client.callTool('create_key_mapping', {
          'key': 'motor.rpm',
          'namespace': 2,
          'identifier': 'Motor.RPM',
        });

        // Verify the key_mapping rows are unchanged: a proposal is a
        // proposal, and nothing here is allowed to write.
        final rows = await db.customSelect(
          'SELECT id FROM config_item WHERE kind = ? ORDER BY id',
          variables: [Variable.withString('key_mapping')],
        ).get();
        final ids = rows.map((r) => r.read<String>('id')).toList();
        // The seeded keys are still there and nothing was added
        expect(ids, hasLength(3));
        expect(ids, isNot(contains('motor.rpm')));
      });
    });

    group('update_key_mapping', () {
      test('returns updated proposal for existing key', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'namespace': 4,
          'identifier': 'Belt.SpeedV2',
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['key'], 'belt.speed');
        expect(json['opcua_node']['namespace'], 4);
        expect(json['opcua_node']['identifier'], 'Belt.SpeedV2');
        expect(json['_proposal_type'], 'key_mapping');
      });

      test('returns isError for non-existent key', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('update_key_mapping', {
          'key': 'nonexistent.key',
          'namespace': 2,
        });

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('nonexistent.key'));
      });

      test('partial update changes only specified fields', () async {
        client = await setupAutoConfirm();

        // Only update namespace, keep identifier as-is
        final result = await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'namespace': 5,
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['opcua_node']['namespace'], 5);
        expect(json['opcua_node']['identifier'], 'Belt.Speed'); // unchanged
      });

      test('elicitation message shows before/after changes', () async {
        String? capturedMessage;
        client = await setupWithElicitation(
          onElicit: (request) async {
            capturedMessage = request.message;
            return ElicitResult(
              action: 'accept',
              content: {'confirm': true},
            );
          },
        );

        await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'namespace': 4,
        });

        expect(capturedMessage, isNotNull);
        expect(capturedMessage, contains('belt.speed'));
        // Should show before/after diff
        expect(capturedMessage, contains('Before'));
        expect(capturedMessage, contains('After'));
      });

      test('declined proposal returns non-error decline message', () async {
        client = await setupWithElicitation(
          onElicit: (request) async {
            return ElicitResult(action: 'decline');
          },
        );

        final result = await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'namespace': 4,
        });

        // ElicitationRiskGate auto-confirms even on decline (Flutter UI is the
        // real safety gate), so the tool returns the proposal JSON.
        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['_proposal_type'], 'key_mapping');
      });

      test('does not write to database', () async {
        client = await setupAutoConfirm();

        await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'namespace': 99,
          'identifier': 'Changed.Value',
        });

        // Verify the belt.speed row is unchanged: a proposal is a proposal.
        final found = await db.customSelect(
          'SELECT payload FROM config_item '
          'WHERE kind = ? AND id = ? AND scope = ?',
          variables: [
            Variable.withString('key_mapping'),
            Variable.withString('belt.speed'),
            Variable.withString('shared'),
          ],
        ).getSingle();
        final beltNode =
            jsonDecode(found.read<String>('payload')) as Map<String, dynamic>;
        final opcuaNode = beltNode['opcua_node'] as Map<String, dynamic>;
        // Original values unchanged
        expect(opcuaNode['namespace'], 2);
        expect(opcuaNode['identifier'], 'Belt.Speed');
      });
    });

    group('create_key_mapping for other protocols', () {
      // The mapping tools spoke only OPC UA while the plant's weighers are
      // M2400 devices. Three times running, a weigher mapping fix had to be
      // clicked into the key repository by hand because the tool could not
      // express it -- most recently sixteen combined-series duplicates.

      test('an m2400 binding round-trips into the proposal', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'weigher1v.acceptWeightCopy',
          'm2400_node': {
            'record_type': 'recBatch',
            'field': 'weight',
            'server_alias': 'weigher1v',
            'status_filter': 0,
          },
          'collect': {'name': 'batcher1.acceptWeight'},
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['key'], 'weigher1v.acceptWeightCopy');
        expect(json['m2400_node']['record_type'], 'recBatch');
        expect(json['m2400_node']['status_filter'], 0);
        expect(json.containsKey('opcua_node'), isFalse);
        // The whole point of the duplicate: its rows land in the combined
        // series, not its own.
        expect(json['collect']['name'], 'batcher1.acceptWeight');
      });

      test('a modbus binding round-trips, with a UMAS name', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'elevator.auto',
          'modbus_node': {
            'register_type': 'holdingRegister',
            'address': 0,
            'server_alias': 'm340',
          },
          'variable_name': 'M_Elevator.i_isAuto',
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['modbus_node']['register_type'], 'holdingRegister');
        expect(json['variable_name'], 'M_Elevator.i_isAuto');
      });

      test('two binding kinds at once are refused', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'confused.key',
          'namespace': 2,
          'identifier': 'Some.Node',
          'm2400_node': {'record_type': 'recStat'},
        });

        expect(result.isError, isTrue);
      });

      test('no binding at all is refused', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'unbound.key',
        });

        expect(result.isError, isTrue);
      });

      test('a variable_name without modbus_node is refused', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('create_key_mapping', {
          'key': 'umas.orphan',
          'variable_name': 'Some.Symbol',
        });

        expect(result.isError, isTrue);
      });
    });

    group('update_key_mapping for other protocols', () {
      test('replaces an m2400 binding whole', () async {
        // The accept/reject filter fix: status_filter 1 -> 0, discovered on
        // the wire. This is the edit that had to be done by hand three times.
        client = await setupAutoConfirm();

        final result = await client.callTool('update_key_mapping', {
          'key': 'weigher9v.acceptWeight',
          'm2400_node': {
            'record_type': 'recBatch',
            'field': 'weight',
            'server_alias': 'weigher9v',
            'status_filter': 15,
          },
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['m2400_node']['status_filter'], 15);
        expect(json['_op'], 'update');
      });

      test('OPC UA flat fields against an m2400 key are refused', () async {
        // The old handler cast existing namespace as int and crashed on any
        // non-OPC UA key; now it says what to do instead.
        client = await setupAutoConfirm();

        final result = await client.callTool('update_key_mapping', {
          'key': 'weigher9v.acceptWeight',
          'identifier': 'Some.Node',
        });

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('m2400'));
      });

      test('mixing binding kinds in one update is refused', () async {
        client = await setupAutoConfirm();

        final result = await client.callTool('update_key_mapping', {
          'key': 'belt.speed',
          'identifier': 'Belt.Speed2',
          'modbus_node': {'register_type': 'coil', 'address': 1},
        });

        expect(result.isError, isTrue);
      });
    });
  });
}
