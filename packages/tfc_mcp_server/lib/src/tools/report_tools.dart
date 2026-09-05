import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../safety/risk_gate.dart';
import '../services/proposal_service.dart';
import '../services/report_service.dart';
import 'tool_registry.dart';

/// Registers the static-report MCP tools.
///
/// Read side: list_reports, get_report_definition, generate_report,
/// resolve_shift, get_shift_calendar.
///
/// Write side: create_report, update_report, delete_report and
/// set_shift_calendar **change nothing**. They validate, then return a
/// proposal, exactly like every other write-shaped tool in this package —
/// see `no_identity_gate_test.dart` for why that invariant is what stands in
/// for an identity gate here. A person applies the proposal in the report
/// editor, and that save goes through `GuardedReportStore`, which asks the
/// live session for `configure` and records the answer.
///
/// The earlier version of these four applied immediately, on the argument
/// that a report only reads. Access control retired it: a report is rendered
/// on an unraised page, so authoring one is a way to publish what it selects
/// to an anonymous panel, and this package has no session to authorize that
/// with.
void registerReportTools(ToolRegistry registry, ReportService service) {
  CallToolResult resultFrom(Map<String, dynamic> result,
      {String Function(Map<String, dynamic>)? render}) {
    final error = result['error'];
    if (error is String) {
      return CallToolResult(
        content: [TextContent(text: error)],
        isError: true,
      );
    }
    final text = render != null ? render(result) : jsonEncode(result);
    return CallToolResult(content: [TextContent(text: text)]);
  }

  registry.registerTool(
    name: 'list_reports',
    description: 'List the configured static reports: id, name, description, '
        'range kind (shift/day/week) and section count.',
    inputSchema: JsonSchema.object(properties: {}),
    handler: (arguments, extra) async {
      final reports = await service.listReports();
      if (reports.isEmpty) {
        return CallToolResult(content: [
          TextContent(
              text: 'No reports are configured yet. '
                  'Use create_report to add one.')
        ]);
      }
      return CallToolResult(
          content: [TextContent(text: jsonEncode(reports))]);
    },
  );

  registry.registerTool(
    name: 'get_report_definition',
    description: 'Get the full JSON definition of one report, as accepted by '
        'create_report and update_report.',
    inputSchema: JsonSchema.object(
      properties: {
        'report_id': JsonSchema.string(description: 'Report id'),
      },
      required: ['report_id'],
    ),
    handler: (arguments, extra) async {
      final id = arguments['report_id'] as String;
      final definition = await service.getReportDefinition(id);
      if (definition == null) {
        return CallToolResult(
          content: [
            TextContent(
                text: 'No report with id "$id". '
                    'Use list_reports to see what exists.')
          ],
          isError: true,
        );
      }
      return CallToolResult(
          content: [TextContent(text: jsonEncode(definition))]);
    },
  );

  registry.registerTool(
    name: 'generate_report',
    description: 'Generate a report over one period and return its rendered '
        'content. By default the report\'s own period (shift, day or week) '
        'is used: offset 0 is the current period ("so far"), -1 the '
        'previous one, and so on backwards. Pass from/to (ISO 8601) for an '
        'explicit range instead.',
    inputSchema: JsonSchema.object(
      properties: {
        'report_id': JsonSchema.string(description: 'Report id'),
        'offset': JsonSchema.integer(
          description:
              'Periods back from now: 0 = current, -1 = previous. Default 0.',
        ),
        'from': JsonSchema.string(
          description: 'Explicit range start (ISO 8601), with "to"',
          format: 'date-time',
        ),
        'to': JsonSchema.string(
          description: 'Explicit range end (ISO 8601), with "from"',
          format: 'date-time',
        ),
      },
      required: ['report_id'],
    ),
    handler: (arguments, extra) async {
      final result = await service.generateReport(
        reportId: arguments['report_id'] as String,
        offset: (arguments['offset'] as num?)?.toInt() ?? 0,
        from: arguments['from'] != null
            ? DateTime.parse(arguments['from'] as String)
            : null,
        to: arguments['to'] != null
            ? DateTime.parse(arguments['to'] as String)
            : null,
      );
      return resultFrom(result, render: (r) => r['text'] as String);
    },
  );

  registry.registerTool(
    name: 'resolve_shift',
    description: 'Resolve a shift from the shift calendar to a concrete time '
        'interval: offset 0 is the current (or most recent) shift, -1 the '
        'one before. Also returns the configured shift pattern.',
    inputSchema: JsonSchema.object(
      properties: {
        'offset': JsonSchema.integer(
          description:
              'Shifts back from now: 0 = current, -1 = previous. Default 0.',
        ),
      },
    ),
    handler: (arguments, extra) async {
      final result = await service.resolveShift(
        offset: (arguments['offset'] as num?)?.toInt() ?? 0,
      );
      return resultFrom(result);
    },
  );

  registry.registerTool(
    name: 'get_shift_calendar',
    description: 'Get the configured shift pattern: each shift\'s name, '
        'start_minutes after midnight, duration_minutes, and weekdays '
        '(1=Monday..7=Sunday).',
    inputSchema: JsonSchema.object(properties: {}),
    handler: (arguments, extra) async {
      final result = await service.getShifts();
      return resultFrom(result);
    },
  );
}

/// The four report writes, on the proposal path.
///
/// Registered under `proposalsEnabled` beside the other write tools rather
/// than under `reportsEnabled`, and the pairing is the point: these produce
/// proposals, so the toggle that carries proposals is the one that carries
/// them. `reportsEnabled` puts the read half — which they validate against —
/// on the registry in the first place.
void registerReportWriteTools({
  required ToolRegistry registry,
  required ReportService service,
  required RiskGate riskGate,
  required ProposalService proposalService,
}) {
  CallToolResult resultFrom(Map<String, dynamic> result) {
    final error = result['error'];
    if (error is String) {
      return CallToolResult(
          content: [TextContent(text: error)], isError: true);
    }
    return CallToolResult(content: [TextContent(text: jsonEncode(result))]);
  }

  registry.registerTool(
    name: 'set_shift_calendar',
    description: 'Propose a replacement for the plant\'s shift calendar. '
        'Returns a proposal for a person to apply in the report editor; '
        'changes nothing by itself. Each shift: name, start_minutes '
        '(0..1439 after local '
        'midnight), duration_minutes (may cross midnight), and optional '
        'weekdays the shift STARTS on (1=Monday..7=Sunday, default all).',
    inputSchema: JsonSchema.object(
      properties: {
        'shifts': JsonSchema.array(
          description: 'The full shift pattern (replaces the existing one)',
          items: JsonSchema.object(
            properties: {
              'name': JsonSchema.string(description: 'Shift name, e.g. Day'),
              'start_minutes': JsonSchema.integer(
                  description: 'Minutes after local midnight, e.g. 420'),
              'duration_minutes': JsonSchema.integer(
                  description: 'Shift length in minutes, e.g. 480'),
              'weekdays': JsonSchema.array(
                description: '1=Monday..7=Sunday; omit for every day',
                items: JsonSchema.integer(),
              ),
            },
            required: ['name', 'start_minutes', 'duration_minutes'],
          ),
        ),
      },
      required: ['shifts'],
    ),
    handler: (arguments, extra) async {
      final result = await service.validateShifts(arguments['shifts'] as List);
      if (result['error'] is String) return resultFrom(result);

      final shifts = (result['shifts'] as List).cast<Map<String, dynamic>>();
      final diff = proposalService.formatCreateDiff(
          'Shift calendar', '${shifts.length} shifts', {
        for (final shift in shifts)
          shift['name'].toString(): _describeShift(shift),
        'applied by': 'a person holding "configure", in the report editor',
      });
      await riskGate.requestConfirmation(
        description: 'Replace the shift calendar',
        level: RiskLevel.medium,
        details: {'diff': diff},
      );
      final wrapped = await proposalService.wrapProposal(
        'shift_calendar',
        <String, dynamic>{
          'title': 'Shift calendar (${shifts.length} shifts)',
          'shifts': shifts,
        },
        op: 'update',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );

  registry.registerTool(
    name: 'create_report',
    description: 'Propose a new report definition. Returns a proposal for a '
        'person to apply in the report editor; changes nothing by itself. The '
        'config needs id, name, range (shift/day/week) and sections, each '
        'section typed one of: '
        '${ReportService.validSectionTypes.join(', ')}. '
        'Use get_report_definition on an existing report to see the shape.',
    inputSchema: JsonSchema.object(
      properties: {
        'config': JsonSchema.object(
          description: 'Full report definition JSON',
        ),
      },
      required: ['config'],
    ),
    handler: (arguments, extra) async {
      final result = await service.validateNewReport(
          (arguments['config'] as Map).cast<String, dynamic>());
      if (result['error'] is String) return resultFrom(result);
      return _reportProposal(
        proposalService: proposalService,
        riskGate: riskGate,
        report: result['report'] as Map<String, dynamic>,
        op: 'create',
      );
    },
  );

  registry.registerTool(
    name: 'update_report',
    description: 'Propose a replacement for an existing report definition by '
        'id. Returns a proposal for a person to apply in the report editor; '
        'changes nothing by itself. Send the FULL definition, not a patch — '
        'read it first with get_report_definition.',
    inputSchema: JsonSchema.object(
      properties: {
        'report_id': JsonSchema.string(description: 'Report id to replace'),
        'config': JsonSchema.object(
          description: 'Full replacement report definition JSON',
        ),
      },
      required: ['report_id', 'config'],
    ),
    handler: (arguments, extra) async {
      final result = await service.validateReportUpdate(
        arguments['report_id'] as String,
        (arguments['config'] as Map).cast<String, dynamic>(),
      );
      if (result['error'] is String) return resultFrom(result);
      return _reportProposal(
        proposalService: proposalService,
        riskGate: riskGate,
        report: result['report'] as Map<String, dynamic>,
        op: 'update',
      );
    },
  );

  registry.registerTool(
    name: 'delete_report',
    description: 'Propose deleting a report definition by id. Returns a '
        'proposal for a person to apply in the report editor; changes nothing '
        'by itself.',
    inputSchema: JsonSchema.object(
      properties: {
        'report_id': JsonSchema.string(description: 'Report id to delete'),
      },
      required: ['report_id'],
    ),
    handler: (arguments, extra) async {
      final result = await service
          .validateReportDelete(arguments['report_id'] as String);
      if (result['error'] is String) return resultFrom(result);
      return _reportProposal(
        proposalService: proposalService,
        riskGate: riskGate,
        report: result['report'] as Map<String, dynamic>,
        op: 'delete',
      );
    },
  );
}

/// One line describing a shift, for a proposal's diff table.
String _describeShift(Map<String, dynamic> shift) {
  final start = shift['start_minutes'] as int;
  final duration = shift['duration_minutes'] as int;
  String hhmm(int minutes) =>
      '${(minutes ~/ 60) % 24}'.padLeft(2, '0') +
      ':${minutes % 60}'.padLeft(3, '0');
  final weekdays = shift['weekdays'];
  final days = weekdays is List && weekdays.length < 7
      ? ', days ${weekdays.join('/')}'
      : '';
  return 'starts ${hhmm(start)}, runs ${duration ~/ 60}h$days';
}

/// Wraps one report definition as a proposal, after the risk gate.
///
/// The definition travels whole rather than as a diff of its sections: the
/// editor stages it into its buffer, and a half-applied report is not a thing
/// anybody wants to review.
Future<CallToolResult> _reportProposal({
  required ProposalService proposalService,
  required RiskGate riskGate,
  required Map<String, dynamic> report,
  required String op,
}) async {
  final sections = (report['sections'] as List?) ?? const [];
  final name = report['name'] ?? report['id'];
  final diff = proposalService.formatCreateDiff('Report', '$name', {
    'id': report['id'],
    'range': report['range'],
    'sections': sections.isEmpty
        ? 'none'
        : sections
            .map((s) => (s as Map)['type'])
            .join(', '),
    'applied by': 'a person holding "configure", in the report editor',
  });
  await riskGate.requestConfirmation(
    description: '${op[0].toUpperCase()}${op.substring(1)} report: $name',
    level: RiskLevel.medium,
    details: {'diff': diff},
  );
  final wrapped = await proposalService.wrapProposal(
    'report',
    <String, dynamic>{
      'title': 'Report "$name"',
      ...report,
    },
    op: op,
  );
  return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
}
