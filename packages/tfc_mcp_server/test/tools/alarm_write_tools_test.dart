import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:test/test.dart';

import 'package:tfc_mcp_server/src/audit/audit_log_service.dart';
import 'package:tfc_mcp_server/src/database/server_database.dart';
import 'package:tfc_mcp_server/src/expression/expression_validator.dart';
import 'package:tfc_mcp_server/src/safety/proposal_declined_exception.dart';
import 'package:tfc_mcp_server/src/safety/risk_gate.dart';
import 'package:tfc_mcp_server/src/services/config_service.dart';
import 'package:tfc_mcp_server/src/services/proposal_service.dart';
import 'package:tfc_mcp_server/src/tools/alarm_write_tools.dart';
import 'package:tfc_mcp_server/src/tools/tool_registry.dart';
import '../helpers/config_rows.dart' as rows;
import '../helpers/mock_mcp_client.dart';
import '../helpers/test_database.dart';

void main() {
  group('Alarm write tools', () {
    late ServerDatabase db;
    late McpServer mcpServer;
    late MockMcpClient client;
    late ConfigService configService;

    /// Helper to set up tools with a NoOpRiskGate (auto-confirm).
    Future<void> setupWithAutoConfirm() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');

      configService = ConfigService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );

      final auditService = AuditLogService(db);
      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      registerAlarmWriteTools(
        registry: registry,
        configService: configService,
        riskGate: NoOpRiskGate(),
        expressionValidator: ExpressionValidator(),
        proposalService: ProposalService(),
      );

      client = await MockMcpClient.connect(mcpServer);
    }

    /// Captured by [setupWithCapturingGate] on the last confirmation.
    String? capturedDescription;
    Map<String, dynamic>? capturedDetails;

    /// Helper to set up tools with a gate that records the confirmation.
    Future<void> setupWithCapturingGate(void Function(RiskLevel) onLevel) async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');

      configService = ConfigService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );

      final auditService = AuditLogService(db);
      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      registerAlarmWriteTools(
        registry: registry,
        configService: configService,
        riskGate: _CapturingRiskGate((description, level, details) {
          capturedDescription = description;
          capturedDetails = details;
          onLevel(level);
        }),
        expressionValidator: ExpressionValidator(),
        proposalService: ProposalService(),
      );

      client = await MockMcpClient.connect(mcpServer);
    }

    /// Helper to set up tools with elicitation that declines.
    Future<void> setupWithDecline() async {
      db = createTestDatabase();
      await db.customStatement('SELECT 1');

      configService = ConfigService(db);

      mcpServer = McpServer(
        const Implementation(name: 'test-server', version: '0.1.0'),
        options: McpServerOptions(
          capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
        ),
      );

      final auditService = AuditLogService(db);
      final registry = ToolRegistry(
        mcpServer: mcpServer,
        auditLogService: auditService,
      );

      registerAlarmWriteTools(
        registry: registry,
        configService: configService,
        riskGate: _DecliningRiskGate(),
        expressionValidator: ExpressionValidator(),
        proposalService: ProposalService(),
      );

      client = await MockMcpClient.connect(mcpServer);
    }

    /// Seeds alarm definitions where AlarmMan really keeps them.
    ///
    /// The `alarm` table is empty on every deployment -- nothing writes it --
    /// so seeding it would test a lookup no operator ever exercises.
    Future<void> seedAlarms(List<Map<String, dynamic>> alarms) =>
        rows.seedPreferenceRow(db, 'alarm_man_config', {'alarms': alarms});

    /// Rewrites the stored alarm config, the way accepting an edit does.
    ///
    /// The whole `alarm_man_config` payload is replaced on every save, so this
    /// is an UPDATE where [seedAlarms] is an INSERT.
    Future<void> reseedAlarms(List<Map<String, dynamic>> alarms) =>
        db.customStatement(
          'UPDATE config_item SET payload = ? '
          'WHERE kind = ? AND id = ? AND scope = ?',
          [
            // The envelope production writes — see `seedPreferenceRow`.
            jsonEncode({
              'type': 'String',
              'value': jsonEncode({'alarms': alarms}),
            }),
            'preference',
            'alarm_man_config',
            'shared',
          ],
        );

    /// Seeds page rows so an alarm can have a beacon pointing at it.
    ///
    /// [pages] is keyed by page id and the beacons live in each page's
    /// `assets` list, which the seed splits into rows the way a save does.
    Future<void> seedPages(Map<String, Map<String, dynamic>> pages) =>
        rows.seedPages(db, pages);

    Map<String, dynamic> alarmJson({
      required String uid,
      String? key,
      required String title,
      required String description,
      List<Map<String, dynamic>> rules = const [],
      List<String>? group,
      bool? bindToGroup,
      bool? countsAsStop,
    }) =>
        {
          'uid': uid,
          if (key != null) 'key': key,
          'title': title,
          'description': description,
          'rules': rules,
          if (group != null) 'group': group,
          if (bindToGroup != null) 'bindToGroup': bindToGroup,
          if (countsAsStop != null) 'countsAsStop': countsAsStop,
        };

    /// Reads back the stored alarm config, to prove a tool did not write it.
    Future<List<dynamic>> storedAlarms() async {
      final found = await db.customSelect(
        'SELECT payload FROM config_item '
        'WHERE kind = ? AND id = ? AND scope = ?',
        variables: [
          Variable.withString('preference'),
          Variable.withString('alarm_man_config'),
          Variable.withString('shared'),
        ],
      ).get();
      if (found.isEmpty) return const [];
      // The row is the `{type, value}` envelope; the document is its value.
      final envelope =
          jsonDecode(found.first.read<String>('payload')) as Map<String, dynamic>;
      final payload =
          jsonDecode(envelope['value'] as String) as Map<String, dynamic>;
      return payload['alarms'] as List<dynamic>;
    }

    tearDown(() async {
      await client.close();
      await db.close();
    });

    group('create_alarm', () {
      test('valid args with single rule returns proposal JSON', () async {
        await setupWithAutoConfirm();

        final result = await client.callTool('create_alarm', {
          'title': 'Pump 3 Overcurrent',
          'description': 'Current exceeds 15A threshold',
          'key': 'pump3.overcurrent',
          'rules': [
            {
              'level': 'error',
              'formula': 'pump3.current > 15',
              'acknowledge_required': true,
            }
          ],
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['_proposal_type'], equals('alarm'));
        expect(json['title'], equals('Pump 3 Overcurrent'));
        expect(json['description'], equals('Current exceeds 15A threshold'));
        expect(json['key'], equals('pump3.overcurrent'));
        expect(json['uid'], isNotNull);
        expect(json['rules'], isList);
        final rules = json['rules'] as List;
        expect(rules.length, equals(1));
        expect(rules[0]['level'], equals('error'));
        expect(rules[0]['expression']['value']['formula'],
            equals('pump3.current > 15'));
        expect(rules[0]['acknowledgeRequired'], isTrue);
      });

      test('valid args with compound expression returns proposal', () async {
        await setupWithAutoConfirm();

        final result = await client.callTool('create_alarm', {
          'title': 'Compound Alarm',
          'description': 'Tests AND expression',
          'rules': [
            {
              'level': 'warning',
              'formula': 'a > 1 AND b < 2',
            }
          ],
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['_proposal_type'], equals('alarm'));
        final rules = json['rules'] as List;
        expect(rules[0]['expression']['value']['formula'],
            equals('a > 1 AND b < 2'));
      });

      test('invalid expression returns isError=true', () async {
        await setupWithAutoConfirm();

        final result = await client.callTool('create_alarm', {
          'title': 'Bad Alarm',
          'description': 'Invalid expression',
          'rules': [
            {
              'level': 'error',
              'formula': 'AND > >',
            }
          ],
        });

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text.toLowerCase(), contains('invalid expression'));
      });

      test('expression round-trip failure returns isError=true', () async {
        await setupWithAutoConfirm();

        // An expression with extra whitespace that would fail round-trip
        // We use a mock validator that claims valid but produces different
        // serialize output. Instead, let's use a formula that the validator
        // considers valid but round-trip changes it.
        // Actually, ExpressionValidator normalizes whitespace, so
        // "pump3.current  >  15" would round-trip to "pump3.current > 15".
        // The round-trip check should catch this.
        final result = await client.callTool('create_alarm', {
          'title': 'Roundtrip Alarm',
          'description': 'Expression changes on roundtrip',
          'rules': [
            {
              'level': 'error',
              // Extra spaces will get normalized during round-trip
              'formula': 'pump3.current  >  15',
            }
          ],
        });

        // The extra spaces will be parsed as part of the variable name,
        // causing a whitespace error in the parser.
        expect(result.isError, isTrue);
      });

      test('declined elicitation returns non-error decline message', () async {
        await setupWithDecline();

        final result = await client.callTool('create_alarm', {
          'title': 'Declined Alarm',
          'description': 'This will be declined',
          'rules': [
            {
              'level': 'info',
              'formula': 'pump3.current > 15',
            }
          ],
        });

        // ToolRegistry catches ProposalDeclinedException and returns non-error
        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        expect(text.toLowerCase(), contains('declined'));
      });

      test('proposal JSON never writes to database', () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(uid: 'alarm-0', title: 'Existing', description: 'Stays'),
        ]);

        await client.callTool('create_alarm', {
          'title': 'No Write Alarm',
          'description': 'Should not write to DB',
          'rules': [
            {
              'level': 'error',
              'formula': 'pump3.current > 15',
            }
          ],
        });

        final alarms = await storedAlarms();
        expect(alarms, hasLength(1));
        expect(alarms.first['uid'], 'alarm-0');
      });
    });

    group('create_alarm grouping', () {
      test('a new alarm can be created straight into a group', () async {
        await setupWithAutoConfirm();
        final result = await client.callTool('create_alarm', {
          'title': 'Vacuum not reached',
          'description': 'Chamber did not pull down',
          'group': ['Line 3', 'Multivac'],
          'rules': [
            {'level': 'warning', 'formula': 'mv.vacuum < 0.8'}
          ],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], equals(['Line 3', 'Multivac']));
        expect(json['bindToGroup'], isFalse);
      });

      test('a new alarm can be bound to its group', () async {
        await setupWithAutoConfirm();
        final result = await client.callTool('create_alarm', {
          'title': 'Strapper stopped',
          'description': 'No diagnosis alarm exists for it yet',
          'group': ['Line 3', 'Afak'],
          'bind_to_group': true,
          'rules': [
            {'level': 'error', 'formula': 'afak.running == false'}
          ],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['bindToGroup'], isTrue);
      });

      test('create_alarm carries counts_as_stop into the proposal',
          () async {
        await setupWithAutoConfirm();
        final result = await client.callTool('create_alarm', {
          'title': 'Door open',
          'description': 'Advisory only',
          'counts_as_stop': false,
          'rules': [
            {'level': 'warning', 'formula': 'door.open == true'},
          ],
        });
        final proposal =
            jsonDecode((result.content.first as TextContent).text)
                as Map<String, dynamic>;
        expect(proposal['countsAsStop'], isFalse);
      });

      test('a new alarm with no group is ungrouped, not missing the field',
          () async {
        await setupWithAutoConfirm();
        final result = await client.callTool('create_alarm', {
          'title': 'T',
          'description': 'D',
          'rules': [
            {'level': 'info', 'formula': 'a > 1'}
          ],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], isEmpty);
        expect(json['bindToGroup'], isFalse);
      });
    });

    group('update_alarm', () {
      test('valid args with existing alarm returns updated proposal',
          () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Old Title',
            description: 'Old description',
            rules: [
              {
                'level': 'error',
                'expression': {
                  'value': {'formula': 'pump3.current > 15'}
                },
                'acknowledgeRequired': true,
              },
            ],
          ),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'New Title',
          'description': 'New description',
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        final json = jsonDecode(text) as Map<String, dynamic>;
        expect(json['_proposal_type'], equals('alarm'));
        expect(json['title'], equals('New Title'));
        expect(json['description'], equals('New description'));
        expect(json['uid'], equals('alarm-1'));
      });

      test('an update keeps the alarm where it sits in the tree', () async {
        // AlarmConfig.group/bindToGroup place an alarm in the alarm tree,
        // and accepting an update proposal replaces the stored alarm with the
        // proposal wholesale -- so if the proposal did not carry the group,
        // renaming an alarm would silently re-home it at the root and empty
        // out whatever grouped by it.
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Film reel empty',
            description: 'The upper film reel ran out',
            group: ['Line 3', 'Multivac'],
          ),
          alarmJson(
            uid: 'alarm-2',
            title: 'Multivac stopped',
            description: 'No finer alarm matched',
            group: ['Line 3', 'Multivac'],
            bindToGroup: true,
          ),
        ]);

        final renamed = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'Film reel ran out',
        });
        final leaf =
            jsonDecode((renamed.content.first as TextContent).text)
                as Map<String, dynamic>;
        expect(leaf['title'], equals('Film reel ran out'));
        expect(leaf['group'], equals(['Line 3', 'Multivac']));
        expect(leaf['bindToGroup'], isFalse);

        final bound = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-2',
          'description': 'Nothing finer matched',
        });
        final boundJson =
            jsonDecode((bound.content.first as TextContent).text)
                as Map<String, dynamic>;
        expect(boundJson['group'], equals(['Line 3', 'Multivac']));
        expect(boundJson['bindToGroup'], isTrue);
      });

      test('an update keeps an alarm excluded from the stop analysis '
          'excluded', () async {
        // Same failure shape as the group test above: the proposal replaces
        // the stored alarm wholesale, so a title-only update that did not
        // carry countsAsStop would silently turn an advisory alarm back
        // into downtime.
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Door open',
            description: 'The cabinet door is open',
            countsAsStop: false,
          ),
        ]);

        final renamed = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'Cabinet door open',
        });
        final proposal =
            jsonDecode((renamed.content.first as TextContent).text)
                as Map<String, dynamic>;
        expect(proposal['title'], equals('Cabinet door open'));
        expect(proposal['countsAsStop'], isFalse);
      });

      test('a stored alarm from before countsAsStop existed updates to '
          'counting as a stop', () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Jam',
            description: 'Belt jammed',
          ),
        ]);

        final renamed = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'Belt jam',
        });
        final proposal =
            jsonDecode((renamed.content.first as TextContent).text)
                as Map<String, dynamic>;
        expect(proposal['countsAsStop'], isTrue);
      });

      test('merges over the stored config, not a cached copy of it', () async {
        // The merge is the dangerous half of update_alarm: every field the
        // caller omits is taken from the stored alarm and written back
        // verbatim when the operator accepts. ConfigService caches that
        // lookup for five minutes and nothing ever calls invalidateCache(),
        // so without a forced re-read a title-only update proposes the group
        // the alarm had up to five minutes ago -- moving it back to the root
        // and dropping bindToGroup with it, silently, on accept.
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Film reel empty',
            description: 'The upper film reel ran out',
            group: ['Line 3'],
          ),
        ]);

        // A first call warms whatever cache the service keeps.
        await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'Film reel ran out',
        });

        // The operator regroups it in the editor and accepts; the row is
        // rewritten under the running server.
        await reseedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Film reel ran out',
            description: 'The upper film reel ran out',
            group: ['Line 3', 'Multivac'],
            bindToGroup: true,
          ),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'description': 'The upper film reel is empty',
        });
        final proposal =
            jsonDecode((result.content.first as TextContent).text)
                as Map<String, dynamic>;

        expect(proposal['group'], equals(['Line 3', 'Multivac']),
            reason: 'a partial update must merge over the stored alarm, not '
                'over a snapshot from before the last accepted edit');
        expect(proposal['bindToGroup'], isTrue);
        expect(proposal['title'], equals('Film reel ran out'));
      });

      test('update_alarm can move an alarm into a group', () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(uid: 'a', title: 'Film reel empty', description: 'D'),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'a',
          'group': ['Line 3', 'Multivac'],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], equals(['Line 3', 'Multivac']));
        expect(json['title'], equals('Film reel empty'));
      });

      test('update_alarm can move an alarm back to the root', () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(
              uid: 'a', title: 'T', description: 'D', group: ['Line 3']),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'a',
          'group': <String>[],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], isEmpty);
      });

      test('update_alarm can bind an alarm to its group', () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(
              uid: 'a',
              title: 'Multivac stopped',
              description: 'D',
              group: ['Line 3', 'Multivac']),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'a',
          'bind_to_group': true,
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['bindToGroup'], isTrue);
        expect(json['group'], equals(['Line 3', 'Multivac']));
      });

      test('binding at the root is dropped, since there is no group to be',
          () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(uid: 'a', title: 'T', description: 'D'),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'a',
          'bind_to_group': true,
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['bindToGroup'], isFalse);
      });

      test('empty group segments are dropped rather than making blank groups',
          () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(uid: 'a', title: 'T', description: 'D'),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'a',
          'group': ['Line 3', '', 'Multivac'],
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], equals(['Line 3', 'Multivac']));
      });

      test('an alarm with no group proposes an empty one, not a missing one',
          () async {
        await setupWithAutoConfirm();
        await seedAlarms([
          alarmJson(uid: 'rootish', title: 'T', description: 'D'),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'rootish',
          'title': 'T2',
        });
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['group'], isEmpty);
        expect(json['bindToGroup'], isFalse);
      });

      test('an alarm that exists only in preferences can be updated',
          () async {
        // The regression this pins: update_alarm looked the alarm up in the
        // `alarm` table, which nothing writes, so every real alarm came back
        // "No alarm found" and the tool could not change anything.
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'pref-only',
            title: 'Only In Preferences',
            description: 'Never written to the alarm table',
          ),
        ]);
        expect(await db.select(db.serverAlarm).get(), isEmpty);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'pref-only',
          'title': 'Renamed',
        });

        expect(result.isError, isNot(true));
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['title'], 'Renamed');
      });

      test('rules left out keep the ones already configured', () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-1',
            title: 'Keeps Rules',
            description: 'Only the title changes',
            rules: [
              {
                'level': 'warning',
                'expression': {
                  'value': {'formula': 'pump3.current > 15'}
                },
                'acknowledgeRequired': false,
              },
            ],
          ),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-1',
          'title': 'Renamed',
        });

        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        final rules = json['rules'] as List;
        expect(rules, hasLength(1));
        expect(rules.first['expression']['value']['formula'],
            'pump3.current > 15');
      });

      test('non-existent alarm_uid returns isError=true', () async {
        await setupWithAutoConfirm();

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'nonexistent',
          'title': 'Updated',
        });

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text, contains('No alarm found with UID: nonexistent'));
      });

      test('updated expression validates before elicitation', () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-2',
            title: 'Existing Alarm',
            description: 'Existing',
            rules: [
              {
                'level': 'error',
                'expression': {
                  'value': {'formula': 'pump3.current > 15'}
                },
                'acknowledgeRequired': true,
              },
            ],
          ),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-2',
          'rules': [
            {
              'level': 'error',
              'formula': 'AND > >',
            }
          ],
        });

        expect(result.isError, isTrue);
        final text = (result.content.first as TextContent).text;
        expect(text.toLowerCase(), contains('invalid expression'));
      });

      test('declined update returns non-error decline message', () async {
        await setupWithDecline();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-3',
            title: 'To Decline',
            description: 'Will be declined',
          ),
        ]);

        final result = await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-3',
          'title': 'Updated Title',
        });

        expect(result.isError, isNot(true));
        final text = (result.content.first as TextContent).text;
        expect(text.toLowerCase(), contains('declined'));
      });

      test('update does not write to database', () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'alarm-4',
            title: 'Original',
            description: 'Original desc',
          ),
        ]);

        await client.callTool('update_alarm', {
          'alarm_uid': 'alarm-4',
          'title': 'Modified',
        });

        final alarms = await storedAlarms();
        expect(alarms, hasLength(1));
        expect(alarms.first['title'], equals('Original'));
      });
    });

    group('delete_alarm', () {
      /// The duplicate-alarm case this tool exists for: two alarms with the
      /// same formula, one of them wired to a beacon.
      Future<void> seedDuplicatePair() async {
        await seedAlarms([
          alarmJson(
            uid: 'dup-1',
            title: 'Duplicate Alarm',
            description: 'The stray copy',
            rules: [
              {
                'level': 'error',
                'expression': {
                  'value': {'formula': 'line1.estop == false'}
                },
                'acknowledgeRequired': false,
              },
            ],
          ),
          alarmJson(
            uid: 'keep-1',
            title: 'Kept Alarm',
            description: 'The one the beacon watches',
          ),
        ]);
      }

      test('returns a delete proposal for an existing alarm', () async {
        await setupWithAutoConfirm();
        await seedDuplicatePair();

        final result = await client.callTool('delete_alarm', {
          'alarm_uid': 'dup-1',
        });

        expect(result.isError, isNot(true));
        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['_proposal_type'], 'alarm');
        expect(json['_op'], 'delete');
        expect(json['uid'], 'dup-1');
      });

      test('carries the whole alarm so the editor can show what goes',
          () async {
        // AlarmConfig.fromJson needs title, description and rules. A payload
        // of just the uid would not parse, and the editor would drop the
        // proposal on the floor.
        await setupWithAutoConfirm();
        await seedDuplicatePair();

        final result = await client.callTool('delete_alarm', {
          'alarm_uid': 'dup-1',
        });

        final json = jsonDecode((result.content.first as TextContent).text)
            as Map<String, dynamic>;
        expect(json['title'], 'Duplicate Alarm');
        expect(json['description'], 'The stray copy');
        expect(json['rules'], isList);
        expect((json['rules'] as List), hasLength(1));
      });

      test('non-existent alarm_uid returns isError=true', () async {
        await setupWithAutoConfirm();
        await seedDuplicatePair();

        final result = await client.callTool('delete_alarm', {
          'alarm_uid': 'nonexistent',
        });

        expect(result.isError, isTrue);
        expect((result.content.first as TextContent).text,
            contains('No alarm found with UID: nonexistent'));
      });

      test('confirms at high risk -- a removal cannot be undone', () async {
        RiskLevel? capturedLevel;
        await setupWithCapturingGate((level) => capturedLevel = level);
        await seedDuplicatePair();

        await client.callTool('delete_alarm', {'alarm_uid': 'dup-1'});

        expect(capturedLevel, RiskLevel.high);
      });

      test('names the page assets still watching the alarm', () async {
        await setupWithCapturingGate((_) {});
        await seedDuplicatePair();
        await seedPages({
          'page-home': {
            'menu_item': {'label': 'Home', 'path': 'Home'},
            'assets': [
              {
                'asset_name': 'AlarmVisibilityConfig',
                'alarm_uids': ['dup-1'],
                'text': 'Line 1 beacon',
              },
            ],
          },
        });

        await client.callTool('delete_alarm', {'alarm_uid': 'dup-1'});

        expect(capturedDescription, contains('1 page asset'));
        expect(capturedDetails?['diff'], contains('Line 1 beacon'));
        expect(capturedDetails?['diff'], contains('Home'));
      });

      test('says so when nothing references the alarm', () async {
        await setupWithCapturingGate((_) {});
        await seedDuplicatePair();

        await client.callTool('delete_alarm', {'alarm_uid': 'dup-1'});

        expect(capturedDetails?['diff'], contains('nothing'));
      });

      test('declined delete returns non-error decline message', () async {
        await setupWithDecline();
        await seedDuplicatePair();

        final result = await client.callTool('delete_alarm', {
          'alarm_uid': 'dup-1',
        });

        expect(result.isError, isNot(true));
        expect((result.content.first as TextContent).text.toLowerCase(),
            contains('declined'));
      });

      test('does not write to database', () async {
        await setupWithAutoConfirm();
        await seedDuplicatePair();

        await client.callTool('delete_alarm', {'alarm_uid': 'dup-1'});

        final alarms = await storedAlarms();
        expect(alarms, hasLength(2));
        expect(alarms.map((a) => a['uid']), contains('dup-1'));
      });
    });

    group('ConfigService.getAlarmConfig', () {
      test('returns alarm config with parsed rules', () async {
        await setupWithAutoConfirm();

        await seedAlarms([
          alarmJson(
            uid: 'cfg-alarm',
            title: 'Config Test',
            description: 'Test desc',
            rules: [
              {
                'level': 'error',
                'expression': {
                  'value': {'formula': 'pump3.current > 15'}
                },
                'acknowledgeRequired': false,
              },
            ],
          ),
        ]);

        final config = await configService.getAlarmConfig('cfg-alarm');
        expect(config, isNotNull);
        expect(config!['uid'], equals('cfg-alarm'));
        expect(config['title'], equals('Config Test'));
        expect(config['rules'], isList);
        expect((config['rules'] as List).length, equals(1));
      });

      test('returns null for non-existent uid', () async {
        await setupWithAutoConfirm();

        final config = await configService.getAlarmConfig('nope');
        expect(config, isNull);
      });
    });
  });
}

/// A RiskGate that records what it was asked to confirm, then agrees.
///
/// The confirmation text is the only thing the operator sees before a delete,
/// so what it says is worth asserting on.
class _CapturingRiskGate implements RiskGate {
  _CapturingRiskGate(this.onConfirm);

  final void Function(String description, RiskLevel level,
      Map<String, dynamic>? details) onConfirm;

  @override
  Future<RiskConfirmation> requestConfirmation({
    required String description,
    required RiskLevel level,
    Map<String, dynamic>? details,
  }) async {
    onConfirm(description, level, details);
    return RiskConfirmation(confirmed: true);
  }
}

/// A RiskGate that always throws ProposalDeclinedException.
class _DecliningRiskGate implements RiskGate {
  @override
  Future<RiskConfirmation> requestConfirmation({
    required String description,
    required RiskLevel level,
    Map<String, dynamic>? details,
  }) async {
    throw ProposalDeclinedException('Proposal declined by operator.');
  }
}
