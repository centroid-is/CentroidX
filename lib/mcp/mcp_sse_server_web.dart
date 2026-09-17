import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show
        AlarmReader,
        DrawingIndex,
        McpDatabase,
        McpToolToggles,
        NodeBrowser,
        PlcCodeIndex,
        ProposalCallback,
        ProposalFeedbackBus,
        ScreenCapturer,
        StateReader,
        TechDocIndex;

/// The same shape as the station's server, permanently not running.
///
/// A browser tab cannot bind a port, and `StreamableMcpServer` is not part of
/// `package:mcp_dart`'s web exports in any case. [isRunning] answering false
/// is what the Preferences card and the app bar already render when the server
/// has not been started, so nothing above this needs a second code path.
class McpSseServer {
  bool get isRunning => false;

  int get port => 0;

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
    ScreenCapturer? screenCapturer,
    ProposalCallback? onProposal,
    ProposalFeedbackBus? feedbackBus,
  }) async =>
      throw UnsupportedError(
          'This build runs in a browser, which cannot listen on port $port for '
          'an MCP client to connect to. Run the MCP server on the station.');

  Future<void> stop() async {}
}
