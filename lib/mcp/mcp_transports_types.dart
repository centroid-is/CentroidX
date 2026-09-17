/// The handle an in-process MCP server hands back, with nothing
/// platform-specific in its shape.
///
/// [Transport] is exported by `mcp_dart` on every platform, so this type can
/// be named from a web build; `McpServer`, `IOStreamTransport` and
/// `StdioClientTransport` cannot, which is what the seam beside this file is
/// for.
library;

import 'package:mcp_dart/mcp_dart.dart' show Transport;

class InProcessMcpServer {
  const InProcessMcpServer({required this.clientTransport, required this.close});

  /// The transport the app's own `McpClient` connects to.
  final Transport clientTransport;

  /// Tears down the server and both pipes. Never closes the database: that is
  /// owned by the Flutter app, not by the MCP server.
  final void Function() close;
}
