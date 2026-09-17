/// The Streamable-HTTP MCP server this app can host, behind a compile-time
/// seam.
///
/// `StreamableMcpServer` is in `package:mcp_dart`'s server module, which is
/// exported only off the web — and a browser tab could not listen on a port
/// for Claude Desktop to dial in the first place. The web arm keeps the same
/// shape and refuses to start, so the Preferences card renders its "not
/// running" state rather than the file failing to compile.
library;

export 'mcp_sse_server_io.dart'
    if (dart.library.js_interop) 'mcp_sse_server_web.dart';
