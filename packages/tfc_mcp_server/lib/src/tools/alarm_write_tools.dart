import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:uuid/uuid.dart';

import '../expression/expression_validator.dart';
import '../safety/risk_gate.dart';
import '../services/config_service.dart';
import '../services/proposal_service.dart';
import 'tool_registry.dart';

const _uuid = Uuid();

/// Registers create_alarm, update_alarm and delete_alarm MCP write tools.
///
/// These tools generate alarm configuration proposals from LLM-provided
/// arguments. They validate boolean expressions, present diffs via
/// elicitation, and return proposal JSON for the Flutter layer to route
/// to the alarm editor. None of them writes to the database.
void registerAlarmWriteTools({
  required ToolRegistry registry,
  required ConfigService configService,
  required RiskGate riskGate,
  required ExpressionValidator expressionValidator,
  required ProposalService proposalService,
}) {
  _registerCreateAlarm(
    registry: registry,
    riskGate: riskGate,
    expressionValidator: expressionValidator,
    proposalService: proposalService,
  );
  _registerUpdateAlarm(
    registry: registry,
    configService: configService,
    riskGate: riskGate,
    expressionValidator: expressionValidator,
    proposalService: proposalService,
  );
  _registerDeleteAlarm(
    registry: registry,
    configService: configService,
    riskGate: riskGate,
    proposalService: proposalService,
  );
}

/// Validates a formula via ExpressionValidator: checks isValid and round-trip.
/// Returns null on success, or an error message string on failure.
String? _validateFormula(
    ExpressionValidator validator, String formula, int ruleIndex) {
  if (!validator.isValid(formula)) {
    return 'Invalid expression in rule $ruleIndex: "$formula"';
  }

  // Round-trip check: parse -> serialize -> compare
  final tokens = validator.parse(formula);
  final serialized = validator.serialize(tokens);
  if (serialized != formula) {
    return 'Expression round-trip failed in rule $ruleIndex: '
        '"$formula" became "$serialized"';
  }

  return null;
}

/// Builds a rules list in AlarmConfig.toJson() format from LLM-provided args.
List<Map<String, dynamic>> _buildRules(List<dynamic> rawRules) {
  return rawRules.map((rule) {
    final r = rule as Map<String, dynamic>;
    return {
      'level': r['level'] ?? 'info',
      'expression': {
        'value': {'formula': r['formula'] as String}
      },
      'acknowledgeRequired': r['acknowledge_required'] ?? false,
      // Stored as AlarmRule.toJson writes it: whole milliseconds, absent
      // when there is no delay.
      if (_onDelayMs(r) case final ms? when ms > 0) 'onDelayMs': ms,
    };
  }).toList();
}

/// A rule's `on_delay_seconds` in milliseconds, or null when not given.
int? _onDelayMs(Map<String, dynamic> rule) {
  final seconds = rule['on_delay_seconds'];
  if (seconds is! num) return null;
  return (seconds * 1000).round();
}

/// Checks the non-expression fields of a rule, returning an error or null.
String? _validateRule(Map<String, dynamic> rule, int ruleIndex) {
  final seconds = rule['on_delay_seconds'];
  if (seconds == null) return null;
  if (seconds is! num || !seconds.isFinite || seconds < 0) {
    return 'Invalid on_delay_seconds in rule $ruleIndex: "$seconds" '
        '(seconds, 0 or more)';
  }
  return null;
}

void _registerCreateAlarm({
  required ToolRegistry registry,
  required RiskGate riskGate,
  required ExpressionValidator expressionValidator,
  required ProposalService proposalService,
}) {
  registry.registerTool(
    name: 'create_alarm',
    description: 'Create a new alarm configuration proposal. '
        'Returns proposal JSON for the operator to review -- does not write to database.',
    inputSchema: JsonSchema.object(
      properties: {
        'title': JsonSchema.string(
          description: 'Alarm title (e.g., "Pump 3 Overcurrent")',
        ),
        'description': JsonSchema.string(
          description:
              'Alarm description (e.g., "Current exceeds 15A threshold")',
        ),
        'key': JsonSchema.string(
          description:
              'Optional alarm key (e.g., "pump3.overcurrent")',
        ),
        'group': JsonSchema.array(
          description: 'Where the alarm sits in the alarm tree, outermost '
              'first -- ["Line 3", "Multivac"] puts it in Multivac, which is '
              'in Line 3. Call get_alarm_tree first to reuse the names that '
              'already exist rather than inventing near-duplicates. Omit or '
              'pass [] to leave it ungrouped.',
          items: JsonSchema.string(),
        ),
        'bind_to_group': JsonSchema.boolean(
          description: 'True when this alarm IS the group named by `group` '
              'rather than one alarm inside it -- the coarse "this machine '
              'stopped" signal for equipment with no finer alarms yet. '
              'Only one alarm per group can be bound.',
          defaultValue: false,
        ),
        'counts_as_stop': JsonSchema.boolean(
          description: 'Whether an activation of this alarm counts as '
              'downtime in the stop analysis. Default true; set false for '
              'advisory alarms that never halt the line.',
          defaultValue: true,
        ),
        'rules': JsonSchema.array(
          description: 'Alarm rules with severity and expression',
          items: JsonSchema.object(
            properties: {
              'level': JsonSchema.string(
                description: 'Severity level',
                enumValues: ['info', 'warning', 'error'],
              ),
              'formula': JsonSchema.string(
                description:
                    'Boolean expression (e.g., "pump3.current > 15")',
              ),
              'acknowledge_required': JsonSchema.boolean(
                description: 'Whether acknowledgement is required',
                defaultValue: false,
              ),
              'on_delay_seconds': JsonSchema.number(
                description: 'How long the formula must hold, without a '
                    'break, before the alarm goes active -- filters a '
                    'flickering signal. It clears as soon as the formula '
                    'does. Omit or 0 to raise immediately.',
              ),
            },
            required: ['level', 'formula'],
          ),
        ),
      },
      required: ['title', 'description', 'rules'],
    ),
    handler: (arguments, extra) async {
      final title = arguments['title'] as String;
      final description = arguments['description'] as String;
      final key = arguments['key'] as String?;
      final group = (arguments['group'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ??
          const <String>[];
      final bindToGroup = arguments['bind_to_group'] as bool? ?? false;
      final countsAsStop = arguments['counts_as_stop'] as bool? ?? true;
      final rawRules = arguments['rules'] as List<dynamic>;

      // Validate all expressions before building proposal
      for (var i = 0; i < rawRules.length; i++) {
        final rule = rawRules[i] as Map<String, dynamic>;
        final formula = rule['formula'] as String;
        final error = _validateFormula(expressionValidator, formula, i) ??
            _validateRule(rule, i);
        if (error != null) {
          return CallToolResult(
            content: [TextContent(text: error)],
            isError: true,
          );
        }
      }

      // Build proposal JSON matching AlarmConfig.toJson() format
      final rules = _buildRules(rawRules);
      final proposal = <String, dynamic>{
        'uid': _uuid.v4(),
        'title': title,
        'description': description,
        'rules': rules,
        'group': group,
        // Binding to the root is meaningless -- there is no group to be --
        // so it is dropped rather than stored as a flag that does nothing.
        'bindToGroup': bindToGroup && group.isNotEmpty,
        'countsAsStop': countsAsStop,
      };
      if (key != null) {
        proposal['key'] = key;
      }

      // Format diff for elicitation
      final diffFields = <String, dynamic>{
        'title': title,
        'description': description,
        if (key != null) 'key': key,
        if (group.isNotEmpty) 'group': group.join(' > '),
        if (bindToGroup && group.isNotEmpty)
          'bindToGroup': 'this alarm IS the group',
        if (!countsAsStop) 'countsAsStop': 'not counted as a stop',
        'rules': rules
            .map((r) =>
                '${r['level']}: ${r['expression']['value']['formula']}'
                '${r['onDelayMs'] == null ? '' : ' (after ${r['onDelayMs'] / 1000} s)'}')
            .join(', '),
      };
      final diff =
          proposalService.formatCreateDiff('Alarm', title, diffFields);

      // Elicit confirmation -- ProposalDeclinedException propagates to middleware
      await riskGate.requestConfirmation(
        description: 'Create alarm: $title',
        level: RiskLevel.medium,
        details: {'diff': diff},
      );

      // Wrap with _proposal_type and return as JSON
      final wrapped = await proposalService.wrapProposal('alarm', proposal);
      return CallToolResult(
        content: [TextContent(text: jsonEncode(wrapped))],
      );
    },
  );
}

void _registerUpdateAlarm({
  required ToolRegistry registry,
  required ConfigService configService,
  required RiskGate riskGate,
  required ExpressionValidator expressionValidator,
  required ProposalService proposalService,
}) {
  registry.registerTool(
    name: 'update_alarm',
    description: 'Update an existing alarm configuration. '
        'Shows before/after diff for operator review -- does not write to database.',
    inputSchema: JsonSchema.object(
      properties: {
        'alarm_uid': JsonSchema.string(
          description: 'UID of the alarm to update',
        ),
        'title': JsonSchema.string(
          description: 'Updated alarm title',
        ),
        'description': JsonSchema.string(
          description: 'Updated alarm description',
        ),
        'key': JsonSchema.string(
          description: 'Updated alarm key',
        ),
        'group': JsonSchema.array(
          description: 'Move the alarm to this place in the alarm tree, '
              'outermost first -- ["Line 3", "Multivac"]. Call '
              'get_alarm_tree first to reuse names that already exist. '
              'Pass [] to move it to the root. Omit to leave it where it is.',
          items: JsonSchema.string(),
        ),
        'bind_to_group': JsonSchema.boolean(
          description: 'True when this alarm IS its group rather than one '
              'alarm inside it. Omit to leave unchanged.',
        ),
        'counts_as_stop': JsonSchema.boolean(
          description: 'Whether an activation counts as downtime in the '
              'stop analysis. Omit to leave unchanged.',
        ),
        'rules': JsonSchema.array(
          description: 'Updated alarm rules (replaces all existing rules)',
          items: JsonSchema.object(
            properties: {
              'level': JsonSchema.string(
                description: 'Severity level',
                enumValues: ['info', 'warning', 'error'],
              ),
              'formula': JsonSchema.string(
                description: 'Boolean expression',
              ),
              'acknowledge_required': JsonSchema.boolean(
                description: 'Whether acknowledgement is required',
                defaultValue: false,
              ),
              'on_delay_seconds': JsonSchema.number(
                description: 'How long the formula must hold, without a '
                    'break, before the alarm goes active -- filters a '
                    'flickering signal. It clears as soon as the formula '
                    'does. Omit or 0 to raise immediately.',
              ),
            },
            required: ['level', 'formula'],
          ),
        ),
      },
      required: ['alarm_uid'],
    ),
    handler: (arguments, extra) async {
      final alarmUid = arguments['alarm_uid'] as String;

      // Look up existing alarm.
      //
      // Read fresh, never from the TTL cache: every field the caller
      // omitted is merged from this map and written back by the accept,
      // so a copy taken before the last accepted edit reverts whatever
      // changed since. That is how a title-only update moved an alarm
      // back to the root and dropped its bindToGroup with it.
      final existing =
          await configService.getAlarmConfig(alarmUid, refresh: true);
      if (existing == null) {
        return CallToolResult(
          content: [
            TextContent(text: 'No alarm found with UID: $alarmUid'),
          ],
          isError: true,
        );
      }

      // Build updated proposal by merging provided fields over existing
      final newTitle =
          arguments['title'] as String? ?? existing['title'] as String;
      final newDescription = arguments['description'] as String? ??
          existing['description'] as String;
      final newKey =
          arguments['key'] as String? ?? existing['key'] as String?;

      // Omitted means "leave where it is"; [] means "move to the root".
      final existingGroup = (existing['group'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      final newGroup = arguments.containsKey('group') &&
              arguments['group'] != null
          ? (arguments['group'] as List<dynamic>)
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList()
          : existingGroup;
      final newBindToGroup = arguments['bind_to_group'] as bool? ??
          (existing['bindToGroup'] as bool? ?? false);
      final newCountsAsStop = arguments['counts_as_stop'] as bool? ??
          (existing['countsAsStop'] as bool? ?? true);

      List<Map<String, dynamic>> newRules;
      if (arguments.containsKey('rules') && arguments['rules'] != null) {
        final rawRules = arguments['rules'] as List<dynamic>;

        // Validate new expressions
        for (var i = 0; i < rawRules.length; i++) {
          final rule = rawRules[i] as Map<String, dynamic>;
          final formula = rule['formula'] as String;
          final error = _validateFormula(expressionValidator, formula, i) ??
            _validateRule(rule, i);
          if (error != null) {
            return CallToolResult(
              content: [TextContent(text: error)],
              isError: true,
            );
          }
        }

        newRules = _buildRules(rawRules);
      } else {
        // Keep existing rules
        newRules =
            (existing['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      }

      // Build the updated proposal.
      //
      // Accepting this replaces the stored alarm with what is here, so every
      // field the alarm had has to survive the trip. `group`/`bindToGroup`
      // are the alarm's place in the tree; dropping them would silently
      // re-home the alarm at the root.
      final proposal = <String, dynamic>{
        'uid': alarmUid,
        'title': newTitle,
        'description': newDescription,
        'rules': newRules,
        'group': newGroup,
        // Binding to the root is meaningless -- there is no group to be.
        'bindToGroup': newBindToGroup && newGroup.isNotEmpty,
        'countsAsStop': newCountsAsStop,
      };
      if (newKey != null) {
        proposal['key'] = newKey;
      }

      // Compute before/after changes for diff
      final changes = <String, String>{};
      if (newTitle != existing['title']) {
        changes['title'] = '${existing['title']} -> $newTitle';
      }
      if (newDescription != existing['description']) {
        changes['description'] =
            '${existing['description']} -> $newDescription';
      }
      if (!_sameGroup(newGroup, existingGroup)) {
        changes['group'] = '${_groupLabel(existingGroup)} -> '
            '${_groupLabel(newGroup)}';
      }
      if (newBindToGroup != (existing['bindToGroup'] as bool? ?? false)) {
        changes['bindToGroup'] =
            '${existing['bindToGroup'] ?? false} -> $newBindToGroup';
      }
      if (newCountsAsStop != (existing['countsAsStop'] as bool? ?? true)) {
        changes['countsAsStop'] =
            '${existing['countsAsStop'] ?? true} -> $newCountsAsStop';
      }
      if (newKey != existing['key']) {
        changes['key'] = '${existing['key']} -> $newKey';
      }
      if (arguments.containsKey('rules')) {
        changes['rules'] = 'Updated';
      }

      final diff = proposalService.formatUpdateDiff(
          'Alarm', newTitle, changes);

      // Elicit confirmation -- ProposalDeclinedException propagates to middleware
      await riskGate.requestConfirmation(
        description: 'Update alarm: $newTitle',
        level: RiskLevel.medium,
        details: {'diff': diff},
      );

      // Wrap with _proposal_type and return as JSON
      final wrapped =
          await proposalService.wrapProposal('alarm', proposal, op: 'update');
      return CallToolResult(
        content: [TextContent(text: jsonEncode(wrapped))],
      );
    },
  );
}

void _registerDeleteAlarm({
  required ToolRegistry registry,
  required ConfigService configService,
  required RiskGate riskGate,
  required ProposalService proposalService,
}) {
  registry.registerTool(
    name: 'delete_alarm',
    description: 'Propose removing an alarm definition. Returns proposal JSON '
        'for the alarm editor -- does not write to the database. Use this for '
        'a duplicate alarm: two definitions carrying the same formula both '
        'fire, so the operator sees every event twice. Page beacons bind to '
        'alarms by uid, and the confirmation names any that would be left '
        'watching nothing.',
    inputSchema: JsonSchema.object(
      properties: {
        'alarm_uid': JsonSchema.string(
          description: 'UID of the alarm to remove (must already exist). '
              'Get it from list_alarm_definitions.',
        ),
      },
      required: ['alarm_uid'],
    ),
    handler: (arguments, extra) async {
      final alarmUid = arguments['alarm_uid'] as String;

      // Fresh, like update: the confirmation names the alarm's title, and
      // a stale one asks the operator to agree to deleting something
      // that is no longer called that.
      final existing =
          await configService.getAlarmConfig(alarmUid, refresh: true);
      if (existing == null) {
        return CallToolResult(
          content: [TextContent(text: 'No alarm found with UID: $alarmUid')],
          isError: true,
        );
      }

      final title = existing['title'] as String;

      // Surfaced before the operator agrees, not after: a beacon whose alarm
      // is gone stays on the page and never lights again, and nothing in the
      // editor points back at what it used to watch.
      final refs = await configService.findAlarmReferences(alarmUid);
      final watchers = refs
          .map((r) =>
              '${r['label'] ?? r['asset'] ?? 'asset'} on page "${r['page']}"')
          .join('; ');

      final changes = <String, String>{
        'alarm': '$title -> (deleted)',
        'watched by': refs.isEmpty
            ? 'nothing -> nothing left watching'
            : '$watchers -> left bound to a deleted alarm',
      };
      final diff = proposalService.formatUpdateDiff('Alarm', title, changes);

      // High, like delete_key_mapping: once the editor saves the removal
      // there is no undo, and the rules go with it.
      // ProposalDeclinedException propagates to middleware.
      await riskGate.requestConfirmation(
        description: refs.isEmpty
            ? 'Delete alarm: $title'
            : 'Delete alarm: $title -- ${refs.length} page asset(s) '
                'still watching it',
        level: RiskLevel.high,
        details: {'diff': diff},
      );

      // The whole config travels, not just the uid: the editor rebuilds an
      // AlarmConfig from this JSON to show what is about to go, and
      // AlarmConfig.fromJson needs title, description and rules to parse.
      final proposal = <String, dynamic>{
        'uid': alarmUid,
        'title': title,
        'description': existing['description'],
        'rules': existing['rules'],
        'group': existing['group'] ?? const <String>[],
        'bindToGroup': existing['bindToGroup'] ?? false,
      };
      if (existing['key'] != null) {
        proposal['key'] = existing['key'];
      }

      final wrapped =
          await proposalService.wrapProposal('alarm', proposal, op: 'delete');
      return CallToolResult(
        content: [TextContent(text: jsonEncode(wrapped))],
      );
    },
  );
}


/// Whether two alarm-tree addresses name the same group.
bool _sameGroup(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// An alarm-tree address as an operator reads it in a confirmation diff.
String _groupLabel(List<String> group) =>
    group.isEmpty ? '(ungrouped)' : group.join(' > ');
