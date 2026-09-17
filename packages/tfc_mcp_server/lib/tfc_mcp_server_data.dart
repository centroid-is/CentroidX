/// The half of this package that does not host an MCP server.
///
/// ## Why there are two barrels
///
/// `McpServer` comes from `package:mcp_dart`, whose own barrel exports the
/// server module only off the web (`src/exports.dart`, with
/// `src/exports_web.dart` in its place under `dart.library.js_interop` — and
/// that one says, in as many words, "No server exports for web platform").
/// Twelve libraries here name `McpServer` directly: the server, its three
/// prompts, its six resources, the elicitation gate and the tool registry.
/// Every one of the individual tool libraries then imports the registry, which
/// brings the count of exports this barrel has to leave out to twenty-nine.
///
/// A `show` clause on the import does not help. `export` puts a library in the
/// importer's compilation graph whether or not any name is taken from it, so a
/// single `import '.../tfc_mcp_server.dart' show DrawingIndex;` compiled all
/// twenty-nine, and the web build failed with forty-six errors about a type
/// nobody in this repository wrote.
///
/// So the full barrel keeps every export and is what a station imports, and
/// this one omits the server half. What is left — the interfaces, the
/// services, the drift database and its row types, the safety scanner, the
/// expression validator, the proposal bus — is plain Dart and compiles
/// anywhere. That is everything the Flutter app's own screens name.
///
/// Import this one unless you are building or hosting a server. The app does
/// that in exactly two places, both behind compile-time seams:
/// `lib/mcp/mcp_transports.dart` and `lib/mcp/mcp_sse_server.dart`.
library;

export 'src/server_instructions.dart';
export 'src/logging/stderr_logger.dart';
export 'src/database/server_database.dart';
export 'src/database/server_database_config.dart';
export 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase;
export 'src/interfaces/state_reader.dart';
export 'src/interfaces/alarm_reader.dart';
export 'src/interfaces/drawing_index.dart';
export 'src/interfaces/plc_code_index.dart';
export 'src/interfaces/tech_doc_index.dart';
export 'src/interfaces/node_browser.dart';
export 'src/interfaces/screen_capturer.dart';
export 'src/interfaces/empty_readers.dart';
export 'src/interfaces/server_alias_provider.dart';
export 'src/audit/audit_log_service.dart';
export 'src/safety/safety_scanner.dart';
export 'src/safety/risk_gate.dart';
export 'src/safety/proposal_declined_exception.dart';
export 'src/expression/expression_validator.dart';
export 'src/services/proposal_feedback_bus.dart';
export 'src/services/proposal_service.dart';
export 'src/services/tag_service.dart';
export 'src/services/alarm_service.dart';
export 'src/services/config_service.dart';
export 'src/services/drawing_service.dart';
export 'src/services/drift_drawing_index.dart';
export 'src/services/drift_plc_code_index.dart';
export 'src/services/drift_tech_doc_index.dart';
export 'src/services/plc_code_service.dart';
export 'src/services/tech_doc_service.dart';
export 'src/services/trend_service.dart';
export 'src/services/report_service.dart';
export 'src/services/alarm_context_service.dart';
export 'src/services/asset_type_catalog.dart';
export 'src/services/diagnostic_service.dart';
export 'src/services/plc_context_service.dart';
export 'src/tools/read_toggles.dart';
export 'src/tools/tool_toggles.dart';
export 'src/parser/twincat_zip_extractor.dart';
export 'src/parser/twincat_xml_parser.dart';
export 'src/parser/structured_text_parser.dart';
export 'src/parser/schneider_xml_parser.dart';
export 'src/compiler/call_graph_builder.dart';
