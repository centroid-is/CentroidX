import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
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
        TechDocIndex,
        TfcMcpServer;

import 'mcp_transports_types.dart';

/// Builds the in-process MCP server, connects it to its own end of a pipe
/// pair, and hands back the other end for the app's client.
///
/// Two `StreamController<List<int>>` in opposite directions: the server reads
/// what the client writes and vice versa. Everything but the returned
/// transport is owned by [InProcessMcpServer.close].
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
}) async {
  final clientToServer = StreamController<List<int>>();
  final serverToClient = StreamController<List<int>>();

  // Server reads from clientToServer, writes to serverToClient.
  final serverTransport = IOStreamTransport(
    stream: clientToServer.stream,
    sink: serverToClient.sink,
  );

  // Client reads from serverToClient, writes to clientToServer.
  final clientTransport = IOStreamTransport(
    stream: serverToClient.stream,
    sink: clientToServer.sink,
  );

  final server = TfcMcpServer(
    database: database,
    stateReader: stateReader,
    alarmReader: alarmReader,
    drawingIndex: drawingIndex,
    plcCodeIndex: plcCodeIndex,
    techDocIndex: techDocIndex,
    screenCapturer: screenCapturer,
    toggles: toggles,
    onProposal: onProposal,
    feedbackBus: feedbackBus,
  );

  await server.connect(serverTransport);

  return InProcessMcpServer(
    clientTransport: clientTransport,
    close: () {
      try {
        clientToServer.close();
      } catch (_) {}
      try {
        serverToClient.close();
      } catch (_) {}
      try {
        // `closeDatabase: false` — the app owns the database's lifecycle, not
        // the MCP server.
        server.close(closeDatabase: false);
      } catch (_) {}
    },
  );
}

/// A transport to an MCP server running as a child process.
Transport stdioMcpTransport({
  required String command,
  List<String> args = const [],
  Map<String, String>? environment,
}) =>
    StdioClientTransport(StdioServerParameters(
      command: command,
      args: args,
      environment: environment,
    ));
