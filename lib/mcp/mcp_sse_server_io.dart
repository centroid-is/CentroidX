import 'dart:io' as io;

import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show
        TfcMcpServer,
        McpDatabase,
        StateReader,
        AlarmReader,
        DrawingIndex,
        PlcCodeIndex,
        TechDocIndex,
        McpToolToggles,
        NodeBrowser,
        ProposalCallback,
        ScreenCapturer,
        ProposalFeedbackBus;

/// Hosts an MCP server using Streamable HTTP transport.
///
/// Claude Desktop (or any MCP client) connects via `http://localhost:<port>/mcp`.
/// Uses [StreamableMcpServer] from mcp_dart 2.0 to handle session routing and
/// multi-client connections automatically.
class McpSseServer {
  StreamableMcpServer? _streamableServer;
  int _port = 0;

  /// Whether the server is currently running.
  bool get isRunning => _streamableServer != null;

  /// The port the server is listening on (0 if not running).
  int get port => _port;

  /// Start the Streamable HTTP MCP server on [port].
  Future<void> start(
    int port, {
    required StateReader stateReader,
    required AlarmReader alarmReader,
    required McpDatabase database,
    McpToolToggles toggles = McpToolToggles.allEnabled,
    DrawingIndex? drawingIndex,
    PlcCodeIndex? plcCodeIndex,
    TechDocIndex? techDocIndex,
    NodeBrowser? nodeBrowser,

    /// Renders the live UI to a PNG for the screenshot tools.
    ScreenCapturer? screenCapturer,
    ProposalCallback? onProposal,

    /// Shared across every session: the operator decides once, and each
    /// session's `await_proposal_feedback` reads the same decision log.
    ProposalFeedbackBus? feedbackBus,
  }) async {
    if (isRunning) return;

    final server = StreamableMcpServer(
      serverFactory: (sessionId) {
        final tfcServer = TfcMcpServer(
          database: database,
          stateReader: stateReader,
          alarmReader: alarmReader,
          drawingIndex: drawingIndex,
          plcCodeIndex: plcCodeIndex,
          techDocIndex: techDocIndex,
          nodeBrowser: nodeBrowser,
          screenCapturer: screenCapturer,
          toggles: toggles,
          onProposal: onProposal,
          feedbackBus: feedbackBus,
        );
        return tfcServer.mcpServer;
      },
      // Bind IPv4 loopback explicitly.  'localhost' resolved to ::1 only, so
      // clients that try 127.0.0.1 first -- Node, and therefore mcp-remote and
      // Claude Desktop -- got a connection refused.
      host: '127.0.0.1',
      port: port,
      path: '/mcp',
    );

    await server.start();
    // Only set fields after successful start — otherwise isRunning
    // returns true on a failed bind and the server becomes unrecoverable.
    _streamableServer = server;
    _port = port;

    io.stderr.writeln('McpSseServer: listening on http://localhost:$_port/mcp');
  }

  /// Stop the server and clean up resources.
  Future<void> stop() async {
    final server = _streamableServer;
    _streamableServer = null;
    _port = 0;

    if (server != null) {
      await server.stop();
      io.stderr.writeln('McpSseServer: stopped');
    }
  }
}
