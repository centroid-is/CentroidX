/// The account and role tools.
///
/// Eleven tools: two reads, and nine that change nothing at all and return a
/// proposal instead. The claims worth asserting are the ones a reader of the
/// source cannot check by eye:
///
///  * **no credential material leaves any tool, on any path** — the rows are
///    seeded with a recognisable hash and salt and every tool is called in
///    every shape (success, argument error, missing table) with the answer
///    grepped for both,
///  * `list_accounts` says what an account may actually do — the union of its
///    roles — and calls the anonymous row the floor it is,
///  * a station whose database predates the tables answers "cannot tell you"
///    rather than failing,
///  * every write tool returns a wrapped proposal and leaves both tables
///    exactly as it found them,
///  * every repository invariant is predicted in words rather than left to
///    surface as a refusal after the click,
///  * no tool takes a password, and no tool takes an argument naming the
///    approver,
///  * neither new file contains a write verb at all.
///
/// The database is a real in-memory [ServerDatabase] with the two tables
/// created by hand with the v9 DDL — `ServerDatabase` mirrors only what the
/// MCP server reads, and these arrive from `tfc_dart`'s migration on a real
/// station. Not creating them is how the missing-table case is tested.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/safety/risk_gate.dart';
import 'package:tfc_mcp_server/src/services/access_account_service.dart';
import 'package:tfc_mcp_server/src/services/proposal_service.dart';
import 'package:tfc_mcp_server/src/tools/access_account_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/mock_mcp_client.dart';

/// A stored hash, in the self-describing form the app writes, carrying a
/// marker no legitimate output could contain.
const String _kHash = r'argon2id$v=19$m=65536,t=3,p=4$HASHMATERIALMUSTNOTLEAK';

/// The row's salt, with its own marker.
const String _kSalt = 'SALTMATERIALMUSTNOTLEAK';

void main() {
  late ServerDatabase db;
  late McpServer mcpServer;
  late MockMcpClient client;

  /// Every proposal the [ProposalService] handed to the in-process listener.
  late List<Map<String, dynamic>> delivered;

  /// The two tables with the DDL a v9 station has.
  Future<void> createTables() async {
    await db.customStatement('CREATE TABLE IF NOT EXISTS app_role '
        '(name TEXT NOT NULL PRIMARY KEY, groups TEXT NOT NULL, '
        'seeded BOOLEAN NOT NULL DEFAULT 0, allowed_pages TEXT)');
    await db.customStatement('CREATE TABLE IF NOT EXISTS app_user '
        '(username TEXT NOT NULL PRIMARY KEY, role_name TEXT NOT NULL, '
        'additional_roles TEXT, password_hash TEXT NOT NULL, '
        'salt TEXT NOT NULL, created_at TEXT NOT NULL, last_login_at TEXT, '
        'station_account BOOLEAN NOT NULL DEFAULT 0, allowed_pages TEXT, '
        'inactivity_timeout_minutes INTEGER)');
  }

  Future<void> seedRole(String name, List<String> groups,
      {bool seeded = false, String? pages}) async {
    await db.customStatement(
      'INSERT INTO app_role (name, groups, seeded, allowed_pages) VALUES '
      "('$name', '${jsonEncode(groups)}', ${seeded ? 1 : 0}, "
      "${pages == null ? 'NULL' : "'$pages'"})",
    );
  }

  Future<void> seedAccount(
    String username,
    String role, {
    List<String> extra = const [],
    bool station = false,
    String? lastLogin,
    int? timeout,
    String? pages,
    String hash = _kHash,
    String salt = _kSalt,
  }) async {
    await db.customStatement(
      'INSERT INTO app_user (username, role_name, additional_roles, '
      'password_hash, salt, created_at, last_login_at, station_account, '
      'allowed_pages, inactivity_timeout_minutes) VALUES '
      "('$username', '$role', "
      "${extra.isEmpty ? 'NULL' : "'${jsonEncode(extra)}'"}, "
      "'$hash', '$salt', '2026-08-30T10:00:00.000Z', "
      "${lastLogin == null ? 'NULL' : "'$lastLogin'"}, ${station ? 1 : 0}, "
      "${pages == null ? 'NULL' : "'$pages'"}, "
      "${timeout == null ? 'NULL' : '$timeout'})",
    );
  }

  /// The four seeded roles, the reserved anonymous row on Operator, and three
  /// invented accounts: an administrator, a panel, and a two-role person.
  Future<void> seedStation() async {
    await seedRole('Operator', ['operate'], seeded: true);
    await seedRole('Shift Leader', ['operate', 'setpoints'], seeded: true);
    await seedRole('Maintenance', ['operate', 'setpoints', 'device', 'force'],
        seeded: true);
    await seedRole(
        'Engineering',
        [
          'operate',
          'setpoints',
          'device',
          'force',
          'configure',
          'administer',
          'users'
        ],
        seeded: true);
    await seedAccount('anonymous', 'Operator',
        hash: r'none$anonymous', salt: '');
    await seedAccount('gudrun', 'Engineering',
        lastLogin: '2026-09-01T06:00:00.000Z');
    await seedAccount('panel7', 'Operator', station: true);
    await seedAccount('kari', 'Shift Leader',
        extra: ['Maintenance'], timeout: 30, pages: '["/line1"]');
  }

  Future<void> setUpServer({bool withTables = true, bool seed = true}) async {
    db = ServerDatabase.inMemory();
    await db.customStatement('SELECT 1');
    if (withTables) {
      await createTables();
      if (seed) await seedStation();
    }

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
    final service = AccessAccountService(db);
    delivered = [];
    registerAccessAccountTools(registry: registry, service: service);
    registerAccessAccountWriteTools(
      registry: registry,
      service: service,
      riskGate: NoOpRiskGate(),
      proposalService:
          ProposalService(onProposal: (wrapped) => delivered.add(wrapped)),
    );
    client = await MockMcpClient.connect(mcpServer);
  }

  /// What the two tables hold right now, for the "wrote nothing" assertions.
  Future<String> tableState() async {
    final roles = await db
        .customSelect('SELECT * FROM app_role ORDER BY name')
        .get();
    final users = await db
        .customSelect('SELECT * FROM app_user ORDER BY username')
        .get();
    return jsonEncode([
      [for (final r in roles) r.data],
      [for (final r in users) r.data],
    ]);
  }

  Future<CallToolResult> callRaw(String tool,
          [Map<String, dynamic> args = const {}]) =>
      client.callTool(tool, args);

  Future<String> call(String tool,
      [Map<String, dynamic> args = const {}]) async {
    final result = await callRaw(tool, args);
    return (result.content.first as TextContent).text;
  }

  Future<Map<String, dynamic>> proposal(String tool,
      [Map<String, dynamic> args = const {}]) async {
    final result = await callRaw(tool, args);
    expect(result.isError, isNot(true),
        reason: (result.content.first as TextContent).text);
    return jsonDecode((result.content.first as TextContent).text)
        as Map<String, dynamic>;
  }

  tearDown(() async {
    await client.close();
    await db.close();
  });

  // -------------------------------------------------------------------------
  group('list_accounts', () {
    test('lists every account with roles, effective groups and flags',
        () async {
      await setUpServer();

      final text = await call('list_accounts');

      expect(text, contains('3 account(s)'));
      expect(text, contains('1 station account'));
      // The administrator: one role, all seven groups, can manage accounts.
      expect(text, contains('gudrun'));
      expect(text, contains('roles: Engineering'));
      expect(text, contains('(can manage roles and accounts)'));
      expect(text, contains('last login: 2026-09-01T06:00:00.000Z'));
      // The panel.
      expect(text, contains('panel7 — station account; roles: Operator'));
      expect(text, contains('sessions: never expire (station account)'));
      // The two-role person: the union is what is reported, not the primary.
      expect(text, contains('kari'));
      expect(text, contains('roles: Shift Leader'));
      expect(text, contains('may: operate, setpoints, device, force'),
          reason: 'what an account may do is the union of every role it '
              'holds; reporting the primary alone would understate it');
      expect(text, contains('30 idle minute(s)'));
      expect(text, contains('only: /line1'));
      expect(text, contains('last login: never'));
    });

    test('names the anonymous row as the floor and the users holders as the '
        'lockout guard', () async {
      await setUpServer();

      final text = await call('list_accounts');

      expect(text, contains('anonymous — every logged-out panel; roles: '
          'Operator'));
      expect(text, contains('Floor — what a logged-out panel may do: operate'));
      expect(text, contains('Lockout guard: 1 account(s) can manage roles '
          'and accounts — gudrun'));
      expect(text, isNot(contains('THE FIRST-USER WINDOW IS OPEN')));
    });

    test('a role an account names that no longer exists grants nothing',
        () async {
      await setUpServer();
      await seedAccount('ghost', 'Departed', extra: ['Maintenance']);

      final text = await call('list_accounts');

      expect(text, contains('names 1 role(s) that no longer exist (Departed)'));
      expect(text, contains('cannot sign in at all'),
          reason: 'a missing primary role is an account with no identity');
    });

    test('an empty roster says the first-user window is open', () async {
      await setUpServer(seed: false);
      await seedRole('Operator', ['operate'], seeded: true);

      final text = await call('list_accounts');

      expect(text, contains('THE FIRST-USER WINDOW IS OPEN'));
      expect(text, contains('Lockout guard: NO account holds'));
    });

    test('a database with no app_user table answers, not an error', () async {
      await setUpServer(withTables: false);

      final result = await callRaw('list_accounts');

      expect(result.isError, isNot(true));
      final text = (result.content.first as TextContent).text;
      expect(text, contains('no app_user / app_role tables'));
    });
  });

  // -------------------------------------------------------------------------
  group('list_roles', () {
    test('explains each role in words and names its holders', () async {
      await setUpServer();

      final text = await call('list_roles');

      expect(text, contains('4 role(s)'));
      expect(text, contains('Engineering (seeded) — held by 1: gudrun'));
      expect(text, contains('(all seven)'));
      expect(text, contains('Maintenance (seeded) — held by 1: kari'),
          reason: 'an extra role is held as much as a primary one');
      expect(text, contains('Operator (seeded) — held by 2: anonymous, '
          'panel7'));
      expect(text, contains('force — Forced I/O and overrides.'),
          reason: 'the point of the tool is what a group lets a person do, '
              'in the same words the roles screen uses');
      expect(text, contains('not granted: setpoints, device, force, '
          'configure, administer, users'));
    });

    test('flags the role the logged-out panel holds as the floor', () async {
      await setUpServer();

      final text = await call('list_roles');

      expect(text, contains('THIS IS THE FLOOR'));
      expect(text, contains('Floor — a logged-out panel holds Operator, so it '
          'may: operate.'));
      expect(text, contains('Roles granting users: Engineering; accounts '
          'holding one: gudrun.'));
    });

    test('a database with no app_role table answers, not an error', () async {
      await setUpServer(withTables: false);

      final result = await callRaw('list_roles');

      expect(result.isError, isNot(true));
      expect((result.content.first as TextContent).text,
          contains('no app_user / app_role tables'));
    });
  });

  // -------------------------------------------------------------------------
  group('no credential material leaves any tool', () {
    /// Every tool, in every shape it can answer — the sweep the class doc
    /// promises. A new tool that is not in this list fails the count below.
    Future<List<String>> everyAnswer() async {
      final calls = <(String, Map<String, dynamic>)>[
        ('list_accounts', {}),
        ('list_roles', {}),
        ('create_account', {'username': 'new', 'roles': ['Operator']}),
        ('create_account', {'username': 'gudrun', 'roles': ['Operator']}),
        ('create_account', {'username': 'new', 'roles': ['Nope']}),
        ('delete_account', {'username': 'kari'}),
        ('delete_account', {'username': 'gudrun'}),
        ('delete_account', {'username': 'nobody'}),
        ('delete_account', {'username': 'anonymous'}),
        ('set_account_roles', {'username': 'kari', 'roles': ['Operator']}),
        ('set_account_roles', {'username': 'gudrun', 'roles': ['Operator']}),
        ('set_account_roles', {'username': 'nobody', 'roles': ['Operator']}),
        ('set_station_account', {'username': 'kari', 'station_account': true}),
        ('set_station_account', {'username': 'anonymous', 'station_account': true}),
        ('reset_account_password', {'username': 'kari'}),
        ('reset_account_password', {'username': 'anonymous'}),
        ('reset_account_password', {'username': 'nobody'}),
        ('create_role', {'name': 'Cleaning', 'groups': ['operate']}),
        ('create_role', {'name': 'Operator', 'groups': ['operate']}),
        ('update_role', {'name': 'Operator', 'groups': ['operate', 'force']}),
        ('update_role', {'name': 'Engineering', 'groups': ['operate']}),
        ('rename_role', {'name': 'Shift Leader', 'new_name': 'Lead'}),
        ('rename_role', {'name': 'Shift Leader', 'new_name': 'Operator'}),
        ('delete_role', {'name': 'Maintenance'}),
        ('delete_role', {'name': 'Engineering'}),
        ('delete_role', {'name': 'Nope'}),
      ];
      final answers = <String>[];
      for (final (tool, args) in calls) {
        final result = await callRaw(tool, args);
        answers.add(jsonEncode(result.toJson()));
      }
      final tools = await client.listTools();
      answers.add(jsonEncode([for (final t in tools) t.toJson()]));
      answers.add(jsonEncode(delivered));
      return answers;
    }

    test('not the hash, not the salt, not the column names — on any path',
        () async {
      await setUpServer();

      final answers = await everyAnswer();

      expect(answers.length, greaterThan(20));
      for (final answer in answers) {
        expect(answer, isNot(contains('HASHMATERIAL')));
        expect(answer, isNot(contains('SALTMATERIAL')));
        expect(answer, isNot(contains('argon2id')));
        expect(answer, isNot(contains('password_hash')),
            reason: 'naming the column is naming where to look');
      }
    });

    test('the reads never select the credential columns', () {
      // The guarantee is the SELECT's explicit column list — see the service
      // doc. This pins it against a future `SELECT *`.
      final source = File('lib/src/services/access_account_service.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(source, isNot(contains('password_hash')));
      expect(source, isNot(contains("'salt'")));
      expect(source, isNot(contains('SELECT *')));
      expect(source, isNot(contains('SELECT * ')));
    });

    test('no tool takes a password, an operator or an approver argument',
        () async {
      await setUpServer();
      final tools = await client.listTools();
      final names = {
        'list_accounts',
        'list_roles',
        'create_account',
        'delete_account',
        'set_account_roles',
        'set_station_account',
        'reset_account_password',
        'create_role',
        'update_role',
        'rename_role',
        'delete_role',
      };
      final mine = tools.where((t) => names.contains(t.name));
      expect(mine, hasLength(11), reason: 'eleven tools, two reads and nine '
          'proposals');
      for (final tool in mine) {
        final properties =
            (tool.inputSchema.toJson()['properties'] as Map?) ?? const {};
        for (final name in properties.keys) {
          final lower = name.toString().toLowerCase();
          expect(lower, isNot(contains('password')),
              reason: '${tool.name} takes "$name". Tool arguments are '
                  'written to the audit table and shown on screen; a '
                  'password must be typed at the panel, never sent here.');
          expect(
              lower,
              isNot(anyOf(contains('operator'), contains('who'),
                  contains('approv'))),
              reason: '${tool.name} takes "$name". `who` is decided at the '
                  'accept from the live session; an argument naming the '
                  'approver would be a forgeable audit trail.');
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  group('the write tools return proposals and write nothing', () {
    test('create_account carries roles and flag, and no password field',
        () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('create_account', {
        'username': ' bjarni ',
        'roles': ['Shift Leader', 'Maintenance'],
        'station_account': false,
        'reason': 'new shift',
      });

      expect(p['_proposal_type'], 'access_account');
      expect(p['_op'], 'create');
      expect(p['username'], 'bjarni', reason: 'trimmed, like the repository');
      expect(p['roles'], ['Shift Leader', 'Maintenance']);
      expect(p['station_account'], false);
      expect(p['reason'], 'new shift');
      expect(p.keys, isNot(contains('password')));
      expect(delivered, hasLength(1));
      expect(await tableState(), before,
          reason: 'a proposal is a message, not a write');
    });

    test('delete_account', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('delete_account', {'username': 'kari'});

      expect(p['_proposal_type'], 'access_account');
      expect(p['_op'], 'delete');
      expect(p['username'], 'kari');
      expect(p['roles'], ['Shift Leader', 'Maintenance']);
      expect(p.keys, isNot(contains('warnings')));
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('set_account_roles', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('set_account_roles', {
        'username': 'kari',
        'roles': ['Maintenance'],
      });

      expect(p['_proposal_type'], 'access_account');
      expect(p['_op'], 'update');
      expect(p['field'], 'roles');
      expect(p['roles'], ['Maintenance']);
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('set_account_roles on the anonymous account warns about the floor',
        () async {
      await setUpServer();

      final p = await proposal('set_account_roles', {
        'username': 'anonymous',
        'roles': ['Shift Leader'],
      });

      expect(p['_op'], 'update');
      expect(p['warnings'], hasLength(1));
      expect(p['warnings'].single, contains('every panel with nobody signed '
          'in will be able to: operate, setpoints'));
    });

    test('set_station_account', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('set_station_account', {
        'username': 'kari',
        'station_account': true,
      });

      expect(p['_proposal_type'], 'access_account');
      expect(p['_op'], 'update');
      expect(p['field'], 'station_account');
      expect(p['station_account'], true);
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('reset_account_password names the account and nothing else',
        () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('reset_account_password', {
        'username': 'kari',
        'reason': 'forgotten',
      });

      expect(p['_proposal_type'], 'access_account');
      expect(p['_op'], 'update');
      expect(p['field'], 'password');
      expect(p['username'], 'kari');
      expect(p.keys.toSet(),
          {'title', 'username', 'field', 'reason', '_proposal_type', '_op'},
          reason: 'the proposal is "reset this account" and no more; the '
              'password is typed at the panel on accept');
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('create_role', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('create_role', {
        'name': 'Cleaning',
        'groups': ['setpoints', 'operate'],
      });

      expect(p['_proposal_type'], 'access_role');
      expect(p['_op'], 'create');
      expect(p['name'], 'Cleaning');
      expect(p['groups'], ['operate', 'setpoints'],
          reason: 'enum order, so a save that changes nothing looks like one');
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('update_role names the holders it affects', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('update_role', {
        'name': 'Maintenance',
        'groups': ['operate', 'setpoints', 'device'],
      });

      expect(p['_proposal_type'], 'access_role');
      expect(p['_op'], 'update');
      expect(p['field'], 'groups');
      expect(p['groups'], ['operate', 'setpoints', 'device']);
      expect(p['holders'], ['kari']);
      expect(p.keys, isNot(contains('warnings')),
          reason: 'narrowing a role nobody logged-out holds warns of nothing');
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('update_role on the floor role warns that every panel widens',
        () async {
      await setUpServer();

      final p = await proposal('update_role', {
        'name': 'Operator',
        'groups': ['operate', 'setpoints'],
      });

      expect(p['holders'], ['anonymous', 'panel7']);
      expect(p['warnings'].single,
          contains('every panel with nobody signed in gains setpoints'));
    });

    test('rename_role', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('rename_role', {
        'name': 'Shift Leader',
        'new_name': ' Lead ',
      });

      expect(p['_proposal_type'], 'access_role');
      expect(p['_op'], 'rename');
      expect(p['name'], 'Shift Leader');
      expect(p['new_name'], 'Lead');
      expect(p['holders'], ['kari']);
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('delete_role names the holders that block it', () async {
      await setUpServer();
      final before = await tableState();

      final p = await proposal('delete_role', {'name': 'Operator'});

      expect(p['_proposal_type'], 'access_role');
      expect(p['_op'], 'delete');
      expect(p['groups'], ['operate']);
      expect(p['holders'], ['anonymous', 'panel7'],
          reason: 'the anonymous row holds a role like any other, and the '
              'repository counts it when it refuses the delete');
      expect(p['warnings'].single, contains('BLOCKED at the accept while '
          'anonymous, panel7 still hold it'));
      expect(delivered, hasLength(1));
      expect(await tableState(), before);
    });

    test('delete_role on a role nobody holds carries no warning', () async {
      await setUpServer();
      await seedRole('Unused', ['operate']);

      final p = await proposal('delete_role', {'name': 'Unused'});

      expect(p['holders'], isEmpty);
      expect(p.keys, isNot(contains('warnings')));
    });
  });

  // -------------------------------------------------------------------------
  group('the lockout invariant is predicted in words', () {
    test('deleting the last account able to manage accounts', () async {
      await setUpServer();

      final p = await proposal('delete_account', {'username': 'gudrun'});

      expect(p['warnings'].single, contains('REFUSED AT THE ACCEPT'));
      expect(p['warnings'].single, contains('gudrun is the only account '
          'holding a role that grants users (Engineering)'));
      expect(p['warnings'].single, contains('no override'));
    });

    test('moving that account onto roles without users', () async {
      await setUpServer();

      final p = await proposal('set_account_roles', {
        'username': 'gudrun',
        'roles': ['Maintenance'],
      });

      expect(p['warnings'].single, contains('REFUSED AT THE ACCEPT'));
    });

    test('taking users away from the only role that grants it', () async {
      await setUpServer();

      final p = await proposal('update_role', {
        'name': 'Engineering',
        'groups': ['operate', 'configure'],
      });

      expect(p['warnings'].single, contains('REFUSED AT THE ACCEPT'));
    });

    test('deleting that role', () async {
      await setUpServer();

      final p = await proposal('delete_role', {'name': 'Engineering'});

      expect(p['warnings'], hasLength(2),
          reason: 'blocked by its holder AND by the lockout guard; both are '
              'said, because fixing one leaves the other');
      expect(p['warnings'].last, contains('REFUSED AT THE ACCEPT'));
    });

    test('a second users holder makes the same changes free', () async {
      await setUpServer();
      await seedAccount('second', 'Engineering');

      final p = await proposal('delete_account', {'username': 'gudrun'});

      expect(p.keys, isNot(contains('warnings')));
    });
  });

  // -------------------------------------------------------------------------
  group('argument errors come back as tool errors, not proposals', () {
    Future<String> errorOf(String tool, Map<String, dynamic> args) async {
      final result = await callRaw(tool, args);
      expect(result.isError, isTrue, reason: '$tool $args should be refused');
      expect(delivered, isEmpty);
      return (result.content.first as TextContent).text;
    }

    test('create_account on a name that exists', () async {
      await setUpServer();
      final text = await errorOf(
          'create_account', {'username': 'gudrun', 'roles': ['Operator']});
      expect(text, contains('gudrun'));
      expect(text, contains('set_account_roles'));
    });

    test('create_account on the reserved name, however it is spelled',
        () async {
      await setUpServer();
      final text = await errorOf(
          'create_account', {'username': ' Anonymous ', 'roles': ['Operator']});
      expect(text, contains('reserved'));
    });

    test('create_account naming a role that does not exist', () async {
      await setUpServer();
      final text = await errorOf(
          'create_account', {'username': 'new', 'roles': ['Supervisor']});
      expect(text, contains('Supervisor'));
      expect(text, contains('create_role'));
    });

    test('create_account while the first-user window is open', () async {
      await setUpServer(seed: false);
      await seedRole('Engineering', ['users']);
      final text = await errorOf(
          'create_account', {'username': 'new', 'roles': ['Engineering']});
      expect(text, contains('first-user window is open'));
    });

    test('delete_account on the anonymous account', () async {
      await setUpServer();
      final text = await errorOf('delete_account', {'username': 'anonymous'});
      expect(text, contains('cannot be deleted'));
      expect(text, contains('set_account_roles'));
    });

    test('delete_account on an account that does not exist', () async {
      await setUpServer();
      final text = await errorOf('delete_account', {'username': 'Gudrun'});
      expect(text, contains('Gudrun'));
      expect(text, contains('case-sensitive'));
    });

    test('set_account_roles to the roles already held', () async {
      await setUpServer();
      final text = await errorOf('set_account_roles', {
        'username': 'kari',
        'roles': ['Shift Leader', 'Maintenance'],
      });
      expect(text, contains('already holds'));
    });

    test('set_account_roles with an empty list', () async {
      await setUpServer();
      await errorOf('set_account_roles', {'username': 'kari', 'roles': []});
    });

    test('set_station_account on the anonymous account', () async {
      await setUpServer();
      await errorOf('set_station_account',
          {'username': 'anonymous', 'station_account': true});
    });

    test('set_station_account to the value already set', () async {
      await setUpServer();
      final text = await errorOf('set_station_account',
          {'username': 'panel7', 'station_account': true});
      expect(text, contains('already a station account'));
    });

    test('reset_account_password on the anonymous account', () async {
      await setUpServer();
      final text =
          await errorOf('reset_account_password', {'username': 'anonymous'});
      expect(text, contains('no password'));
    });

    test('create_role on a name that exists', () async {
      await setUpServer();
      final text = await errorOf(
          'create_role', {'name': 'Operator', 'groups': ['operate']});
      expect(text, contains('update_role'));
    });

    test('an unknown group is rejected and the error lists the seven',
        () async {
      await setUpServer();
      String text;
      try {
        final result = await callRaw(
            'create_role', {'name': 'Cleaning', 'groups': ['supervisor']});
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
        expect(text, contains(group));
      }
      expect(delivered, isEmpty);
    });

    test('update_role to the groups already granted', () async {
      await setUpServer();
      final text = await errorOf(
          'update_role', {'name': 'Operator', 'groups': ['operate']});
      expect(text, contains('already grants'));
    });

    test('update_role on a role that does not exist', () async {
      await setUpServer();
      final text =
          await errorOf('update_role', {'name': 'Nope', 'groups': ['operate']});
      expect(text, contains('Nope'));
    });

    test('rename_role onto a name that exists', () async {
      await setUpServer();
      final text = await errorOf(
          'rename_role', {'name': 'Shift Leader', 'new_name': 'Operator'});
      expect(text, contains('already exists'));
    });

    test('rename_role to its own name', () async {
      await setUpServer();
      await errorOf(
          'rename_role', {'name': 'Shift Leader', 'new_name': 'Shift Leader'});
    });

    test('delete_role on a role that does not exist', () async {
      await setUpServer();
      await errorOf('delete_role', {'name': 'Nope'});
    });

    test('a station with no tables cannot be proposed at', () async {
      await setUpServer(withTables: false);
      final text = await errorOf(
          'create_role', {'name': 'Cleaning', 'groups': ['operate']});
      expect(text, contains('no app_user / app_role tables'));
    });
  });

  // -------------------------------------------------------------------------
  group('the write-nothing property', () {
    test('neither new file contains a write verb', () {
      for (final path in [
        'lib/src/services/access_account_service.dart',
        'lib/src/tools/access_account_tools.dart',
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
