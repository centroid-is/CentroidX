import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import '../services/report_service.dart';
import 'tool_registry.dart';

/// Registers the static-report MCP tools.
///
/// Read side: list_reports, get_report_definition, generate_report,
/// resolve_shift, get_shift_calendar. Write side: create_report,
/// update_report, delete_report, set_shift_calendar — these apply directly
/// (audited) rather than as proposals: a report definition only describes
/// how to read data, it can never touch the plant.
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

  registry.registerTool(
    name: 'set_shift_calendar',
    description: 'Replace the plant\'s shift calendar. Applies immediately '
        '(audited). Each shift: name, start_minutes (0..1439 after local '
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
      final result = await service.setShifts(arguments['shifts'] as List);
      return resultFrom(result);
    },
  );

  registry.registerTool(
    name: 'create_report',
    description: 'Create a new report definition. Applies immediately '
        '(audited), no operator proposal — reports only read data. The '
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
      final result = await service
          .createReport((arguments['config'] as Map).cast<String, dynamic>());
      return resultFrom(result);
    },
  );

  registry.registerTool(
    name: 'update_report',
    description: 'Replace an existing report definition by id. Applies '
        'immediately (audited). Send the FULL definition, not a patch — '
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
      final result = await service.updateReport(
        arguments['report_id'] as String,
        (arguments['config'] as Map).cast<String, dynamic>(),
      );
      return resultFrom(result);
    },
  );

  registry.registerTool(
    name: 'delete_report',
    description: 'Delete a report definition by id. Applies immediately '
        '(audited).',
    inputSchema: JsonSchema.object(
      properties: {
        'report_id': JsonSchema.string(description: 'Report id to delete'),
      },
      required: ['report_id'],
    ),
    handler: (arguments, extra) async {
      final result =
          await service.deleteReport(arguments['report_id'] as String);
      return resultFrom(result);
    },
  );
}
