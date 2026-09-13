/// The access-template tools (spec §7c).
///
/// Six tools: two reads, and four that change nothing at all and return a
/// proposal instead. The claims worth asserting here are the ones a reader of
/// the source cannot check by eye:
///
///  * `list_unbound_keys` answers with the **same** definition the key
///    repository renders — `TagBindingResolver.unboundKeys` — so a dangling
///    binding is reported and a live one is not,
///  * a station whose database predates the access tables answers "nothing is
///    gated" rather than failing,
///  * every write tool returns a wrapped proposal and leaves both tables
///    exactly as it found them,
///  * a bulk bind of N keys is **one** proposal, because forty proposals is
///    forty approvals and the point of §7c is that a person approves once,
///  * no tool takes an argument naming the approver,
///  * neither new file contains a write verb at all.
///
/// The database is a real in-memory [ServerDatabase] with the two access
/// tables created by hand — `ServerDatabase` mirrors only the tables the MCP
/// server reads, and these two arrive from `tfc_dart`'s migration on a real
/// station. Creating them here with the same DDL is what lets the
/// missing-table case be tested by simply *not* creating them.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/safety/risk_gate.dart';
import 'package:tfc_mcp_server/src/services/access_template_service.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/services/proposal_service.dart';
import 'package:tfc_mcp_server/src/tools/access_template_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/config_rows.dart';
import '../helpers/mock_mcp_client.dart';

void main() {
  late ServerDatabase db;
  late McpServer mcpServer;
  late MockMcpClient client;

  /// Every proposal the [ProposalService] handed to the in-process listener.
  /// A write tool that returned a proposal without delivering one would look
  /// identical from the tool result alone.
  late List<Map<String, dynamic>> delivered;

  /// The key universe every test shares, in the plant's own convention so the
  /// prefix filter is exercised against the shape it exists for.
  final keyMappings = {
    'nodes': {
      'ST101.CN01': {
        'opcua_node': {'namespace': 2, 'identifier': 'CN01'}
      },
      'ST101.CN02': {
        'opcua_node': {'namespace': 2, 'identifier': 'CN02'}
      },
      'ST201.CN21': {
        'opcua_node': {'namespace': 2, 'identifier': 'CN21'}
      },
      'ST201.PU01': {
        'opcua_node': {'namespace': 2, 'identifier': 'PU01'}
      },
    },
  };

  /// Creates the two access tables with the DDL `tfc_dart`'s migration uses.
  Future<void> createAccessTables() async {
    await db.customStatement('CREATE TABLE IF NOT EXISTS access_template '
        '(name TEXT NOT NULL PRIMARY KEY, rules TEXT NOT NULL, '
        'updated_at TEXT NOT NULL)');
    await db.customStatement('CREATE TABLE IF NOT EXISTS access_key_binding '
        '(key_name TEXT NOT NULL PRIMARY KEY, template_name TEXT NOT NULL, '
        'updated_at TEXT NOT NULL)');
  }

  Future<void> seedTemplate(String name, Map<String, String> rules) async {
    await db.customStatement(
      'INSERT INTO access_template (name, rules, updated_at) VALUES '
      "('$name', '${jsonEncode(rules)}', '2026-08-30T10:00:00.000Z')",
    );
  }

  Future<void> seedBinding(String key, String template) async {
    await db.customStatement(
      'INSERT INTO access_key_binding (key_name, template_name, updated_at) '
      "VALUES ('$key', '$template', '2026-08-30T10:00:00.000Z')",
    );
  }

  /// Everything wired.
  ///
  /// [withTables] false is the station whose schema predates the access
  /// tables: the tools must answer, not throw.
  Future<void> setUpServer({bool withTables = true}) async {
    db = ServerDatabase.inMemory();
    await db.customStatement('SELECT 1');
    if (withTables) await createAccessTables();

    // The key universe, as the rows that replaced the blob. This is the
    // set `list_unbound_keys` measures the bindings against, so seeding the
    // blob here would measure them against a key set nothing updates.
    await seedKeyMappings(db, keyMappings);

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

    final service = AccessTemplateService(db);
    delivered = [];

    registerAccessTemplateTools(
      registry: registry,
      service: service,
      configService: ConfigService(db),
    );
    registerAccessTemplateWriteTools(
      registry: registry,
      service: service,
      riskGate: NoOpRiskGate(),
      proposalService:
          ProposalService(onProposal: (wrapped) => delivered.add(wrapped)),
    );

    client = await MockMcpClient.connect(mcpServer);
  }

  /// What the two tables hold right now, for the "wrote nothing" assertions.
  ///
  /// Read back rather than trusted: the claim is that a *proposal* changed
  /// nothing, and only the tables can say so.
  Future<String> tableState() async {
    final templates = await db
        .customSelect('SELECT name, rules FROM access_template ORDER BY name')
        .get();
    final bindings = await db
        .customSelect('SELECT key_name, template_name FROM access_key_binding '
            'ORDER BY key_name')
        .get();
    return jsonEncode([
      [for (final r in templates) r.data],
      [for (final r in bindings) r.data],
    ]);
  }

  Future<String> call(String tool,
      [Map<String, dynamic> args = const {}]) async {
    final result = await client.callTool(tool, args);
    return (result.content.first as TextContent).text;
  }

  Future<CallToolResult> callRaw(String tool,
          [Map<String, dynamic> args = const {}]) =>
      client.callTool(tool, args);

  tearDown(() async {
    await client.close();
    await db.close();
  });

  // -------------------------------------------------------------------------
  group('list_access_templates', () {
    test('names each template, its rules and the keys bound to it', () async {
      await setUpServer();
      await seedTemplate('conveyor',
          {'p_cfg_ManualFreq': 'device', 'p_cmd_JogFwd': 'operate'});
      await seedTemplate('recipes', {'*': 'setpoints'});
      await seedBinding('ST101.CN01', 'conveyor');
      await seedBinding('ST101.CN02', 'conveyor');

      final text = await call('list_access_templates');

      expect(text, contains('conveyor'));
      expect(text, contains('p_cfg_ManualFreq'));
      expect(text, contains('device'));
      expect(text, contains('p_cmd_JogFwd'));
      expect(text, contains('operate'));
      expect(text, contains('ST101.CN01'));
      expect(text, contains('ST101.CN02'));
      expect(text, contains('recipes'));
      expect(text, contains('setpoints'));
    });

    test(
        'a database with no access_template table answers empty, not an error',
        () async {
      await setUpServer(withTables: false);

      final result = await callRaw('list_access_templates');

      expect(result.isError, isNot(true),
          reason: 'a station whose schema predates the access tables must be '
              'told nothing is gated, not handed a driver error');
      final text = (result.content.first as TextContent).text;
      expect(text.toLowerCase(), contains('no access_template table'));
      expect(text.toLowerCase(), contains('needs only operate'));
    });

    test('tables present and empty says so in different words', () async {
      await setUpServer();

      final text = await call('list_access_templates');

      expect(text.toLowerCase(), isNot(contains('no access_template table')),
          reason: '"cannot tell you" and "there are none" are different '
              'claims and only one of them is true here');
      expect(text.toLowerCase(), contains('no access templates'));
    });
  });

  // -------------------------------------------------------------------------
  group('list_unbound_keys', () {
    test('includes a dangling binding and excludes a live one', () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      await seedBinding('ST101.CN01', 'conveyor');
      await seedBinding('ST101.CN02', 'deleted-template');

      final text = await call('list_unbound_keys');

      expect(text, isNot(contains('ST101.CN01')),
          reason: 'CN01 resolves to a template that exists — it is bound');
      expect(text, contains('ST101.CN02'),
          reason: 'a binding naming a template with no row resolves to no '
              'restriction at all, which is exactly as open as unbound');
      expect(text, contains('deleted-template'),
          reason: 'the dangling name has to be reported, or the agent cannot '
              'tell the two gaps apart and will propose the wrong fix');
      expect(text, contains('ST201.CN21'));
      expect(text, contains('ST201.PU01'));
    });

    test('the prefix filter narrows the answer', () async {
      await setUpServer();

      final all = await call('list_unbound_keys');
      expect(all, contains('ST101.CN01'));
      expect(all, contains('ST201.CN21'));

      final narrowed = await call('list_unbound_keys', {'prefix': 'ST201.'});
      expect(narrowed, contains('ST201.CN21'));
      expect(narrowed, contains('ST201.PU01'));
      expect(narrowed, isNot(contains('ST101.CN01')));
      expect(narrowed, isNot(contains('ST101.CN02')));
    });

    test('limit truncates and says that it did', () async {
      await setUpServer();

      final text = await call('list_unbound_keys', {'limit': 2});

      final named = ['ST101.CN01', 'ST101.CN02', 'ST201.CN21', 'ST201.PU01']
          .where(text.contains)
          .length;
      expect(named, 2);
      expect(text, contains('4'),
          reason: 'a truncated answer that does not say how many there were '
              'lets an agent believe it has swept the plant');
    });

    test(
        'a binding naming a key that no longer exists is not reported as a key',
        () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      await seedBinding('ST999.GONE', 'conveyor');

      final text = await call('list_unbound_keys');

      expect(text, isNot(contains('ST999.GONE')),
          reason: 'an orphaned binding row is not a key; reporting it would '
              'have the agent propose a binding for something that cannot be '
              'read or written');
    });

    test('every key is unbound when the tables are not there, and it says why',
        () async {
      await setUpServer(withTables: false);

      final result = await callRaw('list_unbound_keys');

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('ST101.CN01'));
      expect(text, contains('ST201.PU01'));
      expect(text.toLowerCase(), contains('no access_template table'));
    });

    test('a station with no key mappings says so rather than "none unbound"',
        () async {
      db = ServerDatabase.inMemory();
      await db.customStatement('SELECT 1');
      await createAccessTables();
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
      delivered = [];
      registerAccessTemplateTools(
        registry: registry,
        service: AccessTemplateService(db),
        configService: ConfigService(db),
      );
      client = await MockMcpClient.connect(mcpServer);

      final text = await call('list_unbound_keys');

      expect(text.toLowerCase(), contains('no key mappings'),
          reason: '"nothing is unbound" and "there is nothing to bind" are '
              'the same sentence to an agent and different facts');
    });
  });


  // -------------------------------------------------------------------------
  group('the write tools return proposals and write nothing', () {
    test('create_access_template', () async {
      await setUpServer();
      final before = await tableState();

      final text = await call('create_access_template', {
        'name': 'conveyor',
        'rules': [
          {'member': 'p_cmd_JogFwd', 'group': 'operate'},
          {'member': '*', 'group': 'device'},
        ],
      });

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['_proposal_type'], 'access_template');
      expect(proposal['_op'], 'create');
      expect(proposal['name'], 'conveyor');
      expect(proposal['rules'], {'p_cmd_JogFwd': 'operate', '*': 'device'});
      expect(delivered, hasLength(1));
      expect(delivered.single['_proposal_type'], 'access_template');
      expect(await tableState(), before,
          reason: 'a proposal is a message, not a write');
    });

    test('update_access_template', () async {
      await setUpServer();
      await seedTemplate('conveyor', {'p_cmd_JogFwd': 'operate'});
      final before = await tableState();

      final text = await call('update_access_template', {
        'name': 'conveyor',
        'rules': [
          {'member': 'p_cmd_JogFwd', 'group': 'device'},
        ],
      });

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['_proposal_type'], 'access_template');
      expect(proposal['_op'], 'update');
      expect(proposal['rules'], {'p_cmd_JogFwd': 'device'});
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('delete_access_template names the keys bound to it', () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      await seedBinding('ST101.CN01', 'conveyor');
      await seedBinding('ST101.CN02', 'conveyor');
      final before = await tableState();

      final text =
          await call('delete_access_template', {'name': 'conveyor'});

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['_proposal_type'], 'access_template');
      expect(proposal['_op'], 'delete');
      expect(proposal['bound_keys'], ['ST101.CN01', 'ST101.CN02'],
          reason: 'the approving human has to see the same list the delete '
              'dialog would show before agreeing to it');
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('bind_key_access_template', () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      final before = await tableState();

      final text = await call('bind_key_access_template', {
        'bindings': [
          {'key': 'ST101.CN01', 'template': 'conveyor'},
        ],
      });

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['_proposal_type'], 'access_template');
      expect(proposal['_op'], 'bind');
      expect(proposal['bindings'], [
        {'key': 'ST101.CN01', 'template': 'conveyor'},
      ]);
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('a bulk bind of three keys is ONE proposal carrying three bindings',
        () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      final before = await tableState();

      final text = await call('bind_key_access_template', {
        'bindings': [
          {'key': 'ST201.CN21', 'template': 'conveyor'},
          {'key': 'ST101.CN01', 'template': 'conveyor'},
          {'key': 'ST101.CN02', 'template': 'conveyor'},
        ],
      });

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['bindings'], hasLength(3));
      expect(delivered, hasLength(1),
          reason: "the whole argument of spec 7c is that an agent sweeps and "
              'a person approves in bulk; N proposals puts the clicking back');
      expect(await tableState(), before);
    });

    test('a binding with no template is an unbind, in the same proposal',
        () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});
      await seedBinding('ST101.CN02', 'conveyor');

      final text = await call('bind_key_access_template', {
        'bindings': [
          {'key': 'ST101.CN01', 'template': 'conveyor'},
          {'key': 'ST101.CN02'},
        ],
      });

      final proposal = jsonDecode(text) as Map<String, dynamic>;
      expect(proposal['bindings'], [
        {'key': 'ST101.CN01', 'template': 'conveyor'},
        {'key': 'ST101.CN02', 'template': null},
      ]);
      expect(delivered, hasLength(1));
    });

    test('no tool takes an operator or approver argument', () async {
      await setUpServer();
      final tools = await client.listTools();
      final mine = tools.where((t) =>
          t.name.contains('access_template') || t.name.contains('unbound'));
      expect(mine, hasLength(6), reason: 'six tools, as spec 7c names them');
      for (final tool in mine) {
        final properties =
            (tool.inputSchema.toJson()['properties'] as Map?) ?? const {};
        for (final name in properties.keys) {
          expect(
              name.toString().toLowerCase(),
              isNot(anyOf(
                  contains('operator'), contains('user'), contains('who'))),
              reason: '${tool.name} takes "$name". `who` is decided in the '
                  'app at the accept, from the live session; an argument '
                  'naming the approver would be a forgeable audit trail, '
                  'which is worse than none (T-04-51).');
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  group('argument errors come back as tool errors, not proposals', () {
    test('create on a name that already exists', () async {
      await setUpServer();
      await seedTemplate('conveyor', {'*': 'device'});

      final result = await callRaw(
          'create_access_template', {'name': 'conveyor', 'rules': []});

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text, contains('conveyor'));
      expect(text, contains('update_access_template'),
          reason: "the error is the agent's whole documentation of what to "
              'do instead');
      expect(delivered, isEmpty);
    });

    test('update on a template that does not exist', () async {
      await setUpServer();

      final result = await callRaw('update_access_template', {
        'name': 'nope',
        'rules': [
          {'member': '*', 'group': 'device'}
        ],
      });

      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text, contains('nope'));
      expect(delivered, isEmpty);
    });

    test('delete on a template that does not exist', () async {
      await setUpServer();

      final result = await callRaw('delete_access_template', {'name': 'nope'});

      expect(result.isError, isTrue);
      expect(delivered, isEmpty);
    });

    test('bind to a template that does not exist', () async {
      await setUpServer();

      final result = await callRaw('bind_key_access_template', {
        'bindings': [
          {'key': 'ST101.CN01', 'template': 'nope'},
        ],
      });

      expect(result.isError, isTrue);
      expect((result.content.first as TextContent).text, contains('nope'));
      expect(delivered, isEmpty,
          reason: 'a dangling binding is unrestricted; proposing one on '
              'purpose is not something this tool should make easy');
    });

    test('an unknown group is rejected and the error lists the seven',
        () async {
      await setUpServer();

      // Two layers reject this and either is a pass: the schema's `enum` of
      // the seven, enforced by mcp_dart before the handler runs, and the
      // handler's own `AccessGroup.byName` check behind it — which is what
      // answers for a client that does not enforce the schema. What the test
      // pins is that the rejection **names the seven**, whichever layer it
      // came from, because that list is the agent's only way to learn the
      // vocabulary.
      String text;
      try {
        final result = await callRaw('create_access_template', {
          'name': 'conveyor',
          'rules': [
            {'member': 'p_cmd_JogFwd', 'group': 'supervisor'},
          ],
        });
        expect(result.isError, isTrue);
        text = (result.content.first as TextContent).text;
      } on Object catch (error) {
        text = '$error';
      }

      for (final group in [
        'operate',
        'setpoints',
        'device',
        'force',
        'configure',
        'administer',
        'users',
      ]) {
        expect(text, contains(group),
            reason: 'the seven are the whole vocabulary; an error naming none '
                'of them leaves the agent guessing');
      }
      expect(delivered, isEmpty);
    });

    test('an empty bindings list is rejected', () async {
      await setUpServer();

      final result =
          await callRaw('bind_key_access_template', {'bindings': []});

      expect(result.isError, isTrue);
      expect(delivered, isEmpty);
    });

    test('an invalid template name is rejected before a proposal', () async {
      await setUpServer();

      final result = await callRaw(
          'create_access_template', {'name': '  padded  ', 'rules': []});

      expect(result.isError, isTrue);
      expect(delivered, isEmpty);
    });

    test('a station with no access tables cannot be proposed at', () async {
      await setUpServer(withTables: false);

      final result = await callRaw(
          'create_access_template', {'name': 'conveyor', 'rules': []});

      expect(result.isError, isTrue);
      final text = (result.content.first as TextContent).text;
      expect(text.toLowerCase(), contains('no access_template table'));
      expect(delivered, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('the write-nothing property', () {
    test('neither new file contains a write verb', () {
      // T-04-50, as a standing gate rather than a one-time grep. The `users`
      // check lives at the human approval precisely because this package
      // cannot write; a write verb appearing in either file is the moment
      // that argument stops being true.
      for (final path in [
        'lib/src/services/access_template_service.dart',
        'lib/src/tools/access_template_tools.dart',
      ]) {
        final source = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final verb in [
          'INSERT',
          'UPDATE ',
          'DELETE ',
          'customStatement',
          'into(',
          'insertOnConflictUpdate',
        ]) {
          expect(source, isNot(contains(verb)),
              reason: '$path contains "$verb". Nothing in tfc_mcp_server may '
                  'write: the users gate is at the approval, in the app, and '
                  'a write here would route around it entirely.');
        }
      }
    });
  });
}
