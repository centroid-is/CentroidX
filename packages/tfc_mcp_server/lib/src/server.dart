import 'dart:async';

import 'package:logger/logger.dart' as log;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase;

import 'audit/audit_log_service.dart';
import 'interfaces/alarm_reader.dart';
import 'interfaces/drawing_index.dart';
import 'interfaces/plc_code_index.dart';
import 'interfaces/node_browser.dart';
import 'interfaces/screen_capturer.dart';
import 'interfaces/state_reader.dart';
import 'interfaces/tech_doc_index.dart';
import 'logging/stderr_logger.dart';
import 'prompts/diagnose_equipment_prompt.dart';
import 'prompts/explain_alarm_prompt.dart';
import 'prompts/shift_handover_prompt.dart';
import 'resources/config_snapshot_resource.dart';
import 'resources/drawings_index_resource.dart';
import 'resources/history_resource.dart';
import 'resources/plc_code_index_resource.dart';
import 'resources/knowledge_resource.dart';
import 'resources/tech_docs_resource.dart';
import 'services/access_template_service.dart';
import 'services/alarm_context_service.dart';
import 'services/alarm_service.dart';
import 'services/config_service.dart';
import 'services/diagnostic_service.dart';
import 'services/drawing_service.dart';
import 'services/drift_drawing_index.dart';
import 'services/plc_code_service.dart';
import 'services/tech_doc_service.dart';
import 'services/tag_service.dart';
import 'services/trend_service.dart';
import 'services/report_service.dart';
import 'expression/expression_validator.dart';
import 'safety/elicitation_risk_gate.dart';
import 'services/proposal_feedback_bus.dart';
import 'services/proposal_service.dart';
import 'tools/access_template_tools.dart';
import 'tools/alarm_tools.dart';
import 'tools/alarm_tree_tools.dart';
import 'tools/alarm_write_tools.dart';
import 'tools/asset_write_tools.dart';
import 'tools/config_tools.dart';
import 'tools/diagnostic_tools.dart';
import 'tools/drawing_tools.dart';
import 'tools/plc_code_tools.dart';
import 'tools/tech_doc_tools.dart';
import 'tools/key_mapping_write_tools.dart';
import 'tools/page_write_tools.dart';
import 'tools/ping_tool.dart';
import 'tools/proposal_feedback_tools.dart';
import 'tools/browse_tools.dart';
import 'tools/screenshot_tools.dart';
import 'tools/tag_tools.dart';
import 'tools/tool_registry.dart';
import 'tools/tool_toggles.dart';
import 'tools/asset_type_catalog_tools.dart';
import 'tools/trend_tools.dart';
import 'tools/report_tools.dart';
import 'server_instructions.dart';

/// The TFC MCP Server wrapping [McpServer] from mcp_dart.
///
/// This server communicates over stdio using [StdioServerTransport].
/// Every tool call creates an audit trail via [AuditLogService].
///
/// **Subprocess contract:** This binary expects SIGTERM for clean shutdown.
/// It will close database connections and flush logs before exiting.
/// The Flutter-side McpBridgeNotifier (Phase 5) spawns this process
/// and sends SIGTERM when the chat widget is disposed.
class TfcMcpServer {
  TfcMcpServer({
    required McpDatabase database,
    required StateReader stateReader,
    required AlarmReader alarmReader,
    DrawingIndex? drawingIndex,
    PlcCodeIndex? plcCodeIndex,
    TechDocIndex? techDocIndex,
    /// Live address-space browsing. Null in standalone/database-only mode,
    /// where there is no PLC session to browse.
    NodeBrowser? nodeBrowser,

    /// Renders the running UI to a PNG. Null in standalone/database-only
    /// mode, where there is no window and nothing to photograph.
    ScreenCapturer? screenCapturer,
    McpToolToggles toggles = McpToolToggles.allEnabled,
    McpServer? mcpServer,
    log.Logger? logger,
    ProposalCallback? onProposal,

    /// Where operator decisions on proposals are published, so an external
    /// MCP client can be told what happened to what it proposed. Null in
    /// standalone/database-only mode, where nobody is clicking anything.
    ProposalFeedbackBus? feedbackBus,
  })  : _mcpServer = mcpServer ??
            McpServer(
              const Implementation(
                  name: 'tfc-mcp-server', version: '0.1.0'),
              options: McpServerOptions(
                // How to drive this server, handed to every client in the
                // initialize result. A fresh client on a fresh machine gets
                // the load-bearing rules -- proposals are not writes, the
                // alias is mandatory, verify before proposing -- without
                // having to be told them by a person.
                instructions: kTfcServerInstructions,
                capabilities: ServerCapabilities(
                  tools: ServerCapabilitiesTools(),
                  resources: ServerCapabilitiesResources(),
                  // Advertised so server-initiated notifications are
                  // legitimate for clients that check. mcp_dart registers the
                  // logging/setLevel handler whenever this is present, so
                  // there is no repeat of the prompts hang described below.
                  logging: <String, dynamic>{},
                  // Prompts are only registered when alarms are enabled (see
                  // the registerPrompt calls below). Advertising the
                  // capability with zero prompts registered leaves
                  // prompts/list without a handler in mcp_dart, and over
                  // Streamable HTTP the resulting error never closes the
                  // stream -- clients hang instead of getting an answer.
                  prompts: toggles.alarmsEnabled
                      ? ServerCapabilitiesPrompts()
                      : null,
                ),
              ),
            ),
        _database = database,
        _logger = logger ?? createServerLogger() {
    // Create audit service from database
    final auditService = AuditLogService(_database);

    // Create tool registry with audit middleware
    final registry = ToolRegistry(
      mcpServer: _mcpServer,
      auditLogService: auditService,
    );

    // Create services
    final tagService = TagService(stateReader);
    final alarmService = AlarmService(
      alarmReader: alarmReader,
      db: _database,
    );
    final configService = ConfigService(_database);
    final effectiveDrawingIndex = drawingIndex ?? DriftDrawingIndex(_database);
    final drawingService = DrawingService(effectiveDrawingIndex);
    final plcCodeService = plcCodeIndex != null
        ? PlcCodeService(plcCodeIndex, configService)
        : null;
    final techDocService = techDocIndex != null
        ? TechDocService(techDocIndex)
        : null;

    // Create trend and context services (Phase 7)
    final accessTemplateService = AccessTemplateService(_database);
    final trendService = TrendService(_database);

    // Static reports: definitions + shift calendar live in the shared
    // preferences table, so the service works identically standalone and
    // in-process.
    final reportService = ReportService(_database);
    final alarmContextService = AlarmContextService(
      alarmService: alarmService,
      tagService: tagService,
      trendService: trendService,
      configService: toggles.configEnabled ? configService : null,
    );

    // Register tool groups based on toggle config.
    // Ping is always registered (health check, not a domain tool group).
    registerPingTool(registry);

    if (toggles.tagsEnabled) {
      registerTagTools(registry, tagService);
      // Browsing rides with the tag group: same read-only, live-PLC nature,
      // and it is only useful to someone already allowed to read tags.
      if (nodeBrowser != null) {
        registerBrowseTools(registry, nodeBrowser);
      }
    }
    if (toggles.alarmsEnabled) {
      registerAlarmTools(registry, alarmService);
      // The tree rides with the alarm group: it is read-only and only means
      // anything to someone already allowed to read alarms.
      registerAlarmTreeTools(registry, alarmService);
    }
    if (toggles.configEnabled) {
      registerConfigTools(registry, configService);
      registerAssetTypeCatalogTools(registry);
      // Templates are configuration to *read* and authorization to *change*,
      // so the two halves are gated differently: the reads ride with the
      // other config reads here, and the four proposal tools land under
      // `proposalsEnabled` below.
      registerAccessTemplateTools(
        registry: registry,
        service: accessTemplateService,
        configService: configService,
      );
    }
    if (toggles.drawingsEnabled) {
      registerDrawingTools(registry, drawingService);
    }
    if (toggles.plcCodeEnabled && plcCodeService != null) {
      registerPlcCodeTools(registry, plcCodeService);
    }
    if (toggles.trendsEnabled) {
      registerTrendTools(registry, trendService);
    }
    if (toggles.techDocsEnabled && techDocService != null) {
      registerTechDocTools(registry, techDocService);
    }
    if (toggles.reportsEnabled) {
      registerReportTools(registry, reportService);
    }
    // Only when something can actually draw. A standalone server has no
    // window, and a tool that always answers "no window" is worse than a
    // tool that is honestly absent from tools/list.
    if (toggles.screenshotsEnabled && screenCapturer != null) {
      registerScreenshotTools(registry, screenCapturer);
    }

    // ── Composite diagnostic tool ────────────────────────────────────────
    // Always registered when tags and alarms are enabled (its core deps).
    // Optional services (drawings, PLC code, tech docs) degrade gracefully.
    if (toggles.tagsEnabled && toggles.alarmsEnabled) {
      final diagnosticService = DiagnosticService(
        tagService: tagService,
        alarmService: alarmService,
        configService: toggles.configEnabled ? configService : null,
        trendService: toggles.trendsEnabled ? trendService : null,
        drawingService: toggles.drawingsEnabled ? drawingService : null,
        plcCodeService: toggles.plcCodeEnabled ? plcCodeService : null,
        techDocService: toggles.techDocsEnabled ? techDocService : null,
      );
      registerDiagnosticTools(registry, diagnosticService);
    }

    // ── Write tools (proposal-only, gated by ElicitationRiskGate) ──────
    if (toggles.proposalsEnabled) {
      final riskGate = ElicitationRiskGate(_mcpServer);
      final expressionValidator = ExpressionValidator();
      final proposalService = ProposalService(onProposal: onProposal);

      if (toggles.alarmsEnabled && toggles.configEnabled) {
        registerAlarmWriteTools(
          registry: registry,
          configService: configService,
          riskGate: riskGate,
          expressionValidator: expressionValidator,
          proposalService: proposalService,
        );
      }
      if (toggles.reportsEnabled) {
        // Same pairing the access-template writes use: proposals carries the
        // write half, reportsEnabled put the read half on the registry.
        registerReportWriteTools(
          registry: registry,
          service: reportService,
          riskGate: riskGate,
          proposalService: proposalService,
        );
      }
      if (toggles.configEnabled) {
        // Beside the other write tools and under the same pairing
        // registerAlarmWriteTools uses: the proposals toggle carries it, and
        // configEnabled is what put the read half -- which these validate
        // against -- on the registry in the first place.
        registerAccessTemplateWriteTools(
          registry: registry,
          service: accessTemplateService,
          riskGate: riskGate,
          proposalService: proposalService,
        );
        registerKeyMappingWriteTools(
          registry,
          configService: configService,
          riskGate: riskGate,
          proposalService: proposalService,
        );
      }
      registerPageWriteTools(
        registry: registry,
        riskGate: riskGate,
        proposalService: proposalService,
      );
      registerAssetWriteTools(
        registry: registry,
        riskGate: riskGate,
        proposalService: proposalService,
      );

      // The return half of the proposal path. Without it a proposal is a
      // one-way message: an external client over HTTP proposes twenty
      // changes and never learns that the operator accepted eighteen of
      // them, because the decision only ever reached the in-app chat.
      if (feedbackBus != null) {
        registerProposalFeedbackTools(registry, feedbackBus);
        _wireFeedbackNotifications(feedbackBus);
      }
    }

    // Resources (registered directly on McpServer, outside the audit
    // middleware)
    if (toggles.configEnabled) {
      registerConfigSnapshotResource(_mcpServer, configService);
    }
    if (toggles.alarmsEnabled) {
      registerHistoryResource(_mcpServer, alarmService);
    }
    registerDrawingsIndexResource(
        _mcpServer, toggles.drawingsEnabled ? drawingService : null);
    registerKnowledgeResource(_mcpServer);
    registerPlcCodeIndexResource(_mcpServer, plcCodeService);
    registerTechDocsResource(_mcpServer, techDocService);

    // Prompts (registered directly on McpServer, outside the audit
    // middleware)
    if (toggles.alarmsEnabled) {
      registerExplainAlarmPrompt(_mcpServer, alarmContextService);
      registerShiftHandoverPrompt(_mcpServer, alarmService, tagService);
    }

    // Diagnostic prompt (Phase 7) -- uses all data sources.
    // Gated by tagsEnabled && alarmsEnabled to match the diagnose_asset tool.
    if (toggles.tagsEnabled && toggles.alarmsEnabled) {
      registerDiagnoseEquipmentPrompt(
        _mcpServer,
        alarmService,
        tagService,
        toggles.trendsEnabled ? trendService : null,
        toggles.configEnabled ? configService : null,
        toggles.drawingsEnabled ? drawingService : null,
        toggles.plcCodeEnabled ? plcCodeService : null,
        toggles.techDocsEnabled ? techDocService : null,
      );
    }

    _logger.i('TFC MCP Server initialized with audit trail');
  }

  final McpServer _mcpServer;
  final McpDatabase _database;
  final log.Logger _logger;

  /// Live forwarding of operator decisions to this session's client.
  StreamSubscription<Map<String, dynamic>>? _feedbackSub;

  /// Pushes each operator decision to this session as a
  /// `notifications/tfc/proposal_feedback` notification.
  ///
  /// Best-effort garnish, not the mechanism. A notification with no related
  /// request id goes to the client's standalone GET stream, and mcp_dart
  /// discards it outright when the client holds none -- which most clients
  /// do not. `await_proposal_feedback` is what actually delivers a decision
  /// reliably; this only saves a client that does hold a GET stream from
  /// waiting for its next poll to return.
  ///
  /// One subscription per [TfcMcpServer], and there is one of those per HTTP
  /// session, so sessions prune themselves: the subscription is cancelled
  /// when this session's transport closes.
  void _wireFeedbackNotifications(ProposalFeedbackBus bus) {
    _feedbackSub = bus.stream.listen((entry) {
      if (!_mcpServer.isConnected) return;
      // Unawaited and swallowed: a client that has gone away must not turn
      // an operator's button click into an unhandled error.
      _mcpServer.server
          .notification(JsonRpcNotification(
            method: 'notifications/tfc/proposal_feedback',
            params: entry,
          ))
          .catchError((Object e) {
        _logger.d('proposal feedback notification not delivered: $e');
      });
    });

    final previousOnClose = _mcpServer.server.onclose;
    _mcpServer.server.onclose = () {
      _feedbackSub?.cancel();
      _feedbackSub = null;
      previousOnClose?.call();
    };
  }

  /// The underlying [McpServer] instance.
  McpServer get mcpServer => _mcpServer;

  /// Connect the server to a [Transport] (typically [StdioServerTransport]).
  Future<void> connect(Transport transport) async {
    _logger.i('TFC MCP Server connecting via transport...');
    await _mcpServer.connect(transport);
    _logger.i('TFC MCP Server connected.');
  }

  /// Clean up server resources.
  ///
  /// When [closeDatabase] is true (the default, used by standalone binary),
  /// closes the database connection to flush audit records and release the
  /// connection pool. When false (used in-process), the caller owns the
  /// database and manages its lifecycle.
  Future<void> close({bool closeDatabase = true}) async {
    _logger.i('TFC MCP Server shutting down...');
    await _feedbackSub?.cancel();
    _feedbackSub = null;
    if (closeDatabase) {
      await _database.close();
    }
    _logger.i('TFC MCP Server shutdown complete.');
  }
}
