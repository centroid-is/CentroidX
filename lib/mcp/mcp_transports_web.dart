import 'package:mcp_dart/mcp_dart.dart' show Transport;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show
        AlarmReader,
        DrawingIndex,
        McpDatabase,
        McpToolToggles,
        PlcCodeIndex,
        ProposalCallback,
        ProposalFeedbackBus,
        ScreenCapturer,
        StateReader,
        TechDocIndex;

import 'mcp_transports_types.dart';

Never _noServer(String what) => throw UnsupportedError(
    'No MCP server can be hosted in a browser, so $what is unavailable. '
    '`package:mcp_dart` exports its server module only off the web, and a '
    'page cannot spawn a process or listen on a port. The copilot needs a '
    'server it can reach; a browser build has none of its own.');

/// Refused: `McpServer` does not exist in a web build of `mcp_dart`.
Future<InProcessMcpServer> startInProcessMcpServer({
  required McpDatabase database,
  required StateReader stateReader,
  required AlarmReader alarmReader,
  DrawingIndex? drawingIndex,
  PlcCodeIndex? plcCodeIndex,
  TechDocIndex? techDocIndex,
  ScreenCapturer? screenCapturer,
  required McpToolToggles toggles,
  ProposalCallback? onProposal,
  ProposalFeedbackBus? feedbackBus,
}) async =>
    _noServer('the in-process bridge');

/// Refused: a browser cannot spawn the server binary, nor speak to a pipe.
Transport stdioMcpTransport({
  required String command,
  List<String> args = const [],
  Map<String, String>? environment,
}) =>
    _noServer('a subprocess server at "$command"');
