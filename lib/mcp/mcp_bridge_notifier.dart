import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart'
    show
        McpConfig,
        McpDatabase,
        StateReader,
        AlarmReader,
        DrawingIndex,
        PlcCodeIndex,
        TechDocIndex,
        McpToolToggles,
        NodeBrowser,
        ScreenCapturer,
        ProposalFeedbackBus;

import '../core/diagnostic_log.dart';
import '../llm/llm_models.dart';
import '../llm/llm_provider.dart';
// Both behind compile-time seams: hosting a server, and speaking to one over
// a pipe, are things `package:mcp_dart` exports only off the web.
import 'mcp_sse_server.dart';
import 'mcp_transports.dart';

/// The single preference key for the consolidated MCP config JSON.
///
/// Re-exported from [McpConfig.kPrefKey] for convenience.
const kMcpConfigKey = McpConfig.kPrefKey;

/// Environment variable overriding the path to the MCP server binary for a
/// spawned subprocess.
///
/// The developer knob: [McpBridgeNotifier.resolveServerPath] consults it
/// before falling back to the platform-specific location under
/// `packages/tfc_mcp_server/build/cli/`. Renamed rather than deleted when the
/// legacy acronym was retired — unlike the operator variable that used to
/// travel alongside it, this one still has a job. Spelled once, here.
const kMcpServerPathEnvVar = 'CENTROIDX_MCP_SERVER_PATH';

/// Connection state for the MCP bridge.
enum McpConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// Immutable state for the MCP bridge.
class McpBridgeState {
  /// Current connection state.
  final McpConnectionState connectionState;

  /// Available tools from the connected MCP server.
  final List<Tool>? tools;

  /// The port the HTTP server is listening on (when running).
  final int? port;

  /// Error message if connection failed.
  final String? error;

  const McpBridgeState({
    required this.connectionState,
    this.tools,
    this.port,
    this.error,
  });

  /// Creates the initial disconnected state.
  factory McpBridgeState.initial() => const McpBridgeState(
        connectionState: McpConnectionState.disconnected,
      );

  McpBridgeState copyWith({
    McpConnectionState? connectionState,
    List<Tool>? tools,
    int? port,
    String? error,
  }) {
    return McpBridgeState(
      connectionState: connectionState ?? this.connectionState,
      tools: tools ?? this.tools,
      port: port ?? this.port,
      error: error ?? this.error,
    );
  }
}

/// Manages the lifecycle of an MCP server connection.
///
/// Supports two connection modes:
///
/// **In-process mode** ([connectInProcess]): Creates an [IOStreamTransport]
/// pair to wire a [TfcMcpServer] directly in the Flutter process. Used when
/// StateMan/AlarmMan are available for live data access.
///
/// **Subprocess mode** ([connect]): Spawns the MCP server binary via
/// [StdioClientTransport]. Used as a fallback (e.g., Claude Desktop).
///
/// Both modes present the same [McpClient] interface for tool calls.
class McpBridgeNotifier extends ChangeNotifier {
  McpClient? _client;
  // `Transport`, not `StdioClientTransport`: the concrete class is in
  // mcp_dart's non-web half, and this field is the only thing that named it.
  Transport? _transport;
  McpBridgeState _state = McpBridgeState.initial();
  bool _disposed = false;

  // In-process mode. The server, both pipes and their teardown live behind
  // the transport seam — see `mcp_transports.dart`.
  InProcessMcpServer? _inProcess;
  bool _isInProcess = false;

  /// Broadcast stream that emits proposal JSON whenever a write tool
  /// (create_alarm, create_page, etc.) successfully wraps a proposal.
  ///
  /// This fires from inside the MCP server process -- both the in-process
  /// bridge and the SSE HTTP server. The chat UI listens to this stream
  /// to inject proposal messages, ensuring proposals are visible even when
  /// tool execution does not go through [ChatNotifier]'s tool loop
  /// (e.g., when an external Agent SDK proxy executes tools via SSE).
  final StreamController<String> _proposalController =
      StreamController<String>.broadcast();

  /// Stream of proposal JSON strings emitted by write tools.
  Stream<String> get proposalStream => _proposalController.stream;

  /// The return path for the operator's decision on those proposals.
  ///
  /// The counterpart to [_proposalController]: proposals go out through the
  /// callback, decisions come back in here, and an external MCP client reads
  /// them with `await_proposal_feedback`. Owned by the bridge rather than by
  /// a server, because both the in-process server and every HTTP session
  /// share one -- a decision is a decision regardless of which of them
  /// proposed the change.
  ///
  /// Fed by `proposalFeedbackRelayProvider`; the bounded ring buffer inside
  /// means a decision made while no client is attached is still there when
  /// one connects.
  final ProposalFeedbackBus feedbackBus = ProposalFeedbackBus();

  /// Callback wired into [TfcMcpServer]'s [ProposalService.onProposal].
  void _onProposal(Map<String, dynamic> wrapped) {
    if (_disposed) return;
    try {
      _proposalController.add(jsonEncode(wrapped));
    } catch (e) {
      logDiagnostic('McpBridgeNotifier._onProposal: failed to emit: $e');
    }
  }

  /// Simulates a proposal callback for testing.
  ///
  /// This is the same as [_onProposal] but exposed for tests that cannot
  /// start a real SSE or in-process MCP server. Invoke with a wrapped
  /// proposal map (including `_proposal_type`).
  @visibleForTesting
  void testFireProposal(Map<String, dynamic> wrapped) => _onProposal(wrapped);

  /// Optional UI-driven elicitation handler.
  ///
  /// When set, MCP elicitation requests are routed to this callback
  /// (typically showing an [ElicitationDialog]). When null, elicitation
  /// auto-accepts with `{confirm: true}` for backwards compatibility.
  Future<ElicitResult> Function(ElicitRequest request)? elicitationHandler;

  /// The current state of the bridge.
  McpBridgeState get currentState => _state;

  /// Update the state and notify listeners.
  void _setState(McpBridgeState newState) {
    _state = newState;
    if (!_disposed) notifyListeners();
  }

  /// Visible for testing: set state externally to simulate server lifecycle.
  @visibleForTesting
  void testSetState(McpBridgeState newState) => _setState(newState);

  /// Available tools from the connected MCP server.
  List<Tool> get tools => _state.tools ?? [];

  /// Waits for the bridge to reach [McpConnectionState.connected].
  ///
  /// If already connected, returns immediately. If currently connecting,
  /// waits until the state transitions to connected, error, or disconnected.
  /// Times out after [timeout] (default 10 seconds).
  ///
  /// Throws [TimeoutException] if the timeout is exceeded.
  /// Throws [StateError] if the bridge transitions to error or disconnected.
  Future<void> waitForReady({Duration timeout = const Duration(seconds: 10)}) {
    if (_state.connectionState == McpConnectionState.connected) {
      return Future<void>.value();
    }
    if (_state.connectionState != McpConnectionState.connecting) {
      return Future<void>.error(StateError(
        'Bridge is not connecting (state: ${_state.connectionState})',
      ));
    }

    final completer = Completer<void>();

    void listener() {
      if (completer.isCompleted) return;
      final cs = _state.connectionState;
      if (cs == McpConnectionState.connected) {
        completer.complete();
      } else if (cs == McpConnectionState.error ||
          cs == McpConnectionState.disconnected) {
        completer.completeError(StateError(
          'Bridge connection failed (state: $cs, error: ${_state.error})',
        ));
      }
    }

    addListener(listener);

    return completer.future.timeout(timeout).whenComplete(() {
      removeListener(listener);
    });
  }

  /// Connect to the MCP server in-process using [IOStreamTransport].
  ///
  /// Creates a [TfcMcpServer] with the provided readers directly in the
  /// Flutter app process, wired via in-memory stream controllers. This
  /// avoids subprocess overhead and enables live data access via
  /// StateManStateReader and AlarmManAlarmReader.
  ///
  /// [database] is the server database for queries and audit logging.
  /// [stateReader] provides live tag values from StateMan subscriptions.
  /// [alarmReader] provides alarm configs from AlarmMan.
  /// [llmProvider] is optionally wired to handle sampling requests.
  /// [drawingIndex] provides optional drawing search capability.
  /// [plcCodeIndex] provides optional PLC code search capability.
  Future<void> connectInProcess({
    required McpDatabase database,
    required StateReader stateReader,
    required AlarmReader alarmReader,
    LlmProvider? llmProvider,
    DrawingIndex? drawingIndex,
    PlcCodeIndex? plcCodeIndex,
    TechDocIndex? techDocIndex,
    ScreenCapturer? screenCapturer,
    McpToolToggles? toggles,
  }) async {
    // Guard: skip if an in-process client is already active or connecting.
    // We check `_isInProcess && _client != null` rather than just the
    // connection state because the SSE server may keep the overall state
    // at `connected` even after the in-process client has been torn down
    // (e.g. chat bubble closed while Claude Desktop is still connected).
    if (_isInProcess && _client != null) return;
    if (_state.connectionState == McpConnectionState.connecting) return;

    _setState(_state.copyWith(connectionState: McpConnectionState.connecting));

    try {
      // The server, the pipe pair and the server's own end of it.
      _inProcess = await startInProcessMcpServer(
        database: database,
        stateReader: stateReader,
        alarmReader: alarmReader,
        drawingIndex: drawingIndex,
        plcCodeIndex: plcCodeIndex,
        techDocIndex: techDocIndex,
        screenCapturer: screenCapturer,
        toggles: toggles ?? McpToolToggles.allEnabled,
        onProposal: _onProposal,
        feedbackBus: feedbackBus,
      );
      final clientTransport = _inProcess!.clientTransport;

      // Create and configure MCP client
      _client = McpClient(
        const Implementation(name: 'tfc-hmi', version: '1.0.0'),
        options: McpClientOptions(
          capabilities: ClientCapabilities(
            sampling: const ClientCapabilitiesSampling(),
            elicitation: const ClientElicitation.formOnly(),
          ),
        ),
      );

      // Wire sampling request handler to route to LlmProvider
      _wireSamplingHandler(llmProvider);

      // Wire elicitation handler: delegates to UI dialog when available,
      // falls back to auto-accept for backwards compatibility.
      _client!.onElicitRequest = buildElicitHandler();

      // Connect client to its transport
      await _client!.connect(clientTransport);

      _isInProcess = true;

      // Fetch available tools
      final toolsResult = await _client!.listTools();
      _setState(McpBridgeState(
        connectionState: McpConnectionState.connected,
        tools: toolsResult.tools,
        port: _sseServer.isRunning ? _sseServer.port : null,
      ));
    } catch (e) {
      _setState(McpBridgeState(
        connectionState: McpConnectionState.error,
        error: e.toString(),
      ));
      logDiagnostic('McpBridgeNotifier: Failed to connect in-process: $e');
      // Clean up partial connection
      _cleanupInProcessResources();
    }
  }

  /// Connect to the MCP server subprocess.
  ///
  /// Resolves the server binary path, spawns the process with the correct
  /// environment variables, and initializes the MCP client connection.
  ///
  /// The subprocess inherits [dbEnv] and nothing else. It carries no
  /// operator identity, because MCP tools do not write: they return
  /// proposals that a human approves in the app, under their own name and
  /// against their own permissions. See `kMcpAuditOperator` in
  /// `packages/tfc_mcp_server/lib/src/audit/audit_log_service.dart` for the
  /// full reasoning and for what an MCP audit row therefore records.
  ///
  /// [dbEnv] contains CENTROID_PG* database connection variables.
  /// [llmProvider] is optionally wired to handle sampling requests.
  /// [envProvider] is injectable for testing (defaults to Platform.environment).
  Future<void> connect({
    required Map<String, String> dbEnv,
    LlmProvider? llmProvider,
    String Function(String)? envProvider,
  }) async {
    if (_state.connectionState == McpConnectionState.connected ||
        _state.connectionState == McpConnectionState.connecting) {
      return;
    }

    // Before `resolveServerPath`, which reads `Platform.environment` and
    // therefore throws in a browser: the error the operator reads should name
    // the reason, not the first `dart:io` member the code happened to touch.
    if (kIsWeb) {
      _setState(const McpBridgeState(
        connectionState: McpConnectionState.error,
        error: 'A browser cannot start the MCP server: it has no process to '
            'spawn and no pipe to speak to it over. Run the copilot on the '
            'station.',
      ));
      return;
    }

    _setState(_state.copyWith(connectionState: McpConnectionState.connecting));

    try {
      final serverPath = resolveServerPath(envProvider: envProvider);

      _transport = stdioMcpTransport(
        command: serverPath,
        args: const [],
        environment: dbEnv,
      );

      _client = McpClient(
        const Implementation(name: 'tfc-hmi', version: '1.0.0'),
        options: McpClientOptions(
          capabilities: ClientCapabilities(
            sampling: const ClientCapabilitiesSampling(),
            elicitation: const ClientElicitation.formOnly(),
          ),
        ),
      );

      // Wire sampling request handler to route to LlmProvider
      _wireSamplingHandler(llmProvider);

      // Wire elicitation handler: delegates to UI dialog when available,
      // falls back to auto-accept for backwards compatibility.
      _client!.onElicitRequest = buildElicitHandler();

      await _client!.connect(_transport!);

      _isInProcess = false;

      // Fetch available tools
      final toolsResult = await _client!.listTools();
      _setState(McpBridgeState(
        connectionState: McpConnectionState.connected,
        tools: toolsResult.tools,
      ));
    } catch (e) {
      _setState(McpBridgeState(
        connectionState: McpConnectionState.error,
        error: e.toString(),
      ));
      logDiagnostic('McpBridgeNotifier: Failed to connect: $e');
      // Clean up partial connection
      _client = null;
      try {
        await _transport?.close();
      } catch (_) {}
      _transport = null;
    }
  }

  /// Wire the sampling request handler to route to [LlmProvider].
  void _wireSamplingHandler(LlmProvider? llmProvider) {
    if (llmProvider == null || _client == null) return;

    _client!.onSamplingRequest = (request) async {
      final messages = <ChatMessage>[];
      if (request.systemPrompt != null) {
        messages.add(ChatMessage.system(request.systemPrompt!));
      }
      for (final msg in request.messages) {
        final content = msg.content;
        final text = content is SamplingTextContent ? content.text : '';
        if (msg.role == SamplingMessageRole.user) {
          messages.add(ChatMessage.user(text));
        } else if (msg.role == SamplingMessageRole.assistant) {
          messages.add(ChatMessage.assistant(text));
        }
      }
      final response = await llmProvider.complete(messages);
      return CreateMessageResult(
        model: llmProvider.providerType.name,
        role: SamplingMessageRole.assistant,
        content: SamplingTextContent(text: response.content),
        stopReason: response.stopReason,
      );
    };
  }

  /// Builds the elicitation callback for [McpClient.onElicitRequest].
  ///
  /// If [elicitationHandler] is set, delegates to it (the UI dialog).
  /// Otherwise, auto-accepts with `{confirm: true}` so that
  /// [ElicitationRiskGate] passes the gate.
  @visibleForTesting
  Future<ElicitResult> Function(ElicitRequest) buildElicitHandler() {
    return (ElicitRequest request) async {
      final handler = elicitationHandler;
      if (handler != null) {
        return handler(request);
      }
      // Default: auto-accept (backwards-compatible behaviour).
      return const ElicitResult(action: 'accept', content: {'confirm': true});
    };
  }

  /// Disconnect the in-process or subprocess MCP client.
  ///
  /// In in-process mode: closes stream controllers and the TfcMcpServer
  /// (with `closeDatabase: false` so the app-owned database survives).
  /// In subprocess mode: calls [transport.close()] which sends SIGTERM,
  /// then SIGKILL after 2s.
  ///
  /// If the SSE HTTP server is still running, preserves its connection
  /// state and port so that Claude Desktop clients remain connected.
  Future<void> disconnect() async {
    if (_state.connectionState == McpConnectionState.disconnected &&
        !_sseServer.isRunning) {
      return;
    }

    try {
      if (_isInProcess) {
        _cleanupInProcessResources();
      } else {
        await _transport?.close();
      }
    } catch (e) {
      logDiagnostic('McpBridgeNotifier: Error during disconnect: $e');
    }

    _client = null;
    _transport = null;

    // Preserve the SSE server state when only the in-process client is
    // being disconnected (e.g. chat bubble closed while Claude Desktop
    // is still connected via HTTP).
    if (_sseServer.isRunning) {
      _setState(McpBridgeState(
        connectionState: McpConnectionState.connected,
        port: _sseServer.port,
      ));
    } else {
      _setState(McpBridgeState.initial());
    }
  }

  /// Clean up in-process resources (stream controllers and TfcMcpServer).
  ///
  /// Closes the TfcMcpServer with `closeDatabase: false` so the app-owned
  /// database survives. The database lifecycle is managed by the Flutter app,
  /// not the MCP server.
  void _cleanupInProcessResources() {
    try {
      _inProcess?.close();
    } catch (_) {}
    _inProcess = null;
    _client = null;
    _isInProcess = false;
  }

  /// Call a tool on the connected MCP server.
  ///
  /// Throws [StateError] if not connected.
  Future<CallToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) {
    if (_client == null ||
        _state.connectionState != McpConnectionState.connected) {
      throw StateError(
          'Cannot call tool: MCP bridge is not connected (state: ${_state.connectionState})');
    }
    return _client!.callTool(
      CallToolRequest(name: name, arguments: arguments),
    );
  }

  /// Resolve the path to the MCP server binary.
  ///
  /// Checks [kMcpServerPathEnvVar] first, then falls back to the
  /// platform-specific default path under packages/tfc_mcp_server/build/.
  ///
  /// [envProvider] is injectable for testing (avoids depending on Platform.environment).
  static String resolveServerPath({
    String? Function(String)? envProvider,
  }) {
    final env = envProvider ?? (key) => io.Platform.environment[key];
    final envPath = env(kMcpServerPathEnvVar);
    if (envPath != null && envPath.isNotEmpty) {
      return envPath;
    }

    // Platform-specific fallback
    final platform = _currentPlatform();
    return 'packages/tfc_mcp_server/build/cli/$platform/bundle/bin/tfc_mcp_server';
  }

  /// Returns the current platform identifier for server binary resolution.
  static String _currentPlatform() {
    if (io.Platform.isMacOS) return 'macos';
    if (io.Platform.isLinux) return 'linux';
    if (io.Platform.isWindows) return 'windows';
    return 'unknown';
  }

  // ── HTTP Server Mode (Streamable HTTP) ─────────────────────────────

  final McpSseServer _sseServer = McpSseServer();

  /// Whether the HTTP server is currently running.
  bool get isRunning => _sseServer.isRunning;

  /// Start the Streamable HTTP MCP server on [port].
  Future<void> startSseServer(
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
  }) async {
    if (_sseServer.isRunning) return;

    _setState(_state.copyWith(connectionState: McpConnectionState.connecting));
    try {
      await _sseServer.start(
        port,
        stateReader: stateReader,
        alarmReader: alarmReader,
        database: database,
        toggles: toggles,
        drawingIndex: drawingIndex,
        plcCodeIndex: plcCodeIndex,
        techDocIndex: techDocIndex,
        nodeBrowser: nodeBrowser,
        screenCapturer: screenCapturer,
        onProposal: _onProposal,
        feedbackBus: feedbackBus,
      );
      _setState(McpBridgeState(
        connectionState: McpConnectionState.connected,
        port: _sseServer.port,
      ));
    } catch (e) {
      _setState(McpBridgeState(
        connectionState: McpConnectionState.error,
        error: e.toString(),
      ));
      logDiagnostic('McpBridgeNotifier: Failed to start SSE server: $e');
    }
  }

  /// Stop the HTTP server.
  ///
  /// If the in-process bridge is connected, preserves that connection state
  /// and only clears the port. Otherwise resets to the initial disconnected
  /// state.
  Future<void> stopSseServer() async {
    if (!_sseServer.isRunning) return;
    try {
      await _sseServer.stop();
    } catch (e) {
      logDiagnostic('McpBridgeNotifier: Error stopping SSE server: $e');
    }
    // Preserve the in-process bridge state when stopping the SSE server.
    // Only reset to initial if there is no in-process connection alive.
    if (_isInProcess && _client != null) {
      _setState(McpBridgeState(
        connectionState: _state.connectionState,
        tools: _state.tools,
        port: null,
        error: _state.error,
      ));
    } else {
      _setState(McpBridgeState.initial());
    }
  }

  /// Dispose the bridge (disconnect client + stop HTTP server).
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await stopSseServer();
    _proposalController.close();
    await feedbackBus.close();
    super.dispose();
  }
}
