/// The two transports that put an MCP server behind the app's client, behind a
/// compile-time seam.
///
/// `package:mcp_dart` exports its whole server module only off the web
/// (`src/exports.dart` if not `dart.library.js_interop`), so `McpServer`,
/// `IOStreamTransport` and `StdioClientTransport` simply do not exist in a
/// browser — and neither does the process this app would spawn, nor the pipe
/// it would spawn it over. The client half, `Transport` and every protocol
/// type are exported everywhere, which is why `McpBridgeNotifier` itself needs
/// no web copy: only these two constructors do.
library;

export 'mcp_transports_types.dart';
export 'mcp_transports_io.dart'
    if (dart.library.js_interop) 'mcp_transports_web.dart';
