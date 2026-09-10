/// The MCP server settings card, behind a compile-time seam.
///
/// MCP is off in the browser by decision, not by accident — see
/// `docs/web-client-scope.md`. The card is still *named* by the preferences
/// page on every platform, so the web arm supplies an inert one rather than
/// making the call site conditional.
library;

export 'mcp_server_section_io.dart'
    if (dart.library.js_interop) 'mcp_server_section_web.dart';
