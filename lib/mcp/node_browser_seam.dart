/// The MCP `browse_nodes` backend, behind a compile-time seam.
///
/// Browsing the address space means holding a live OPC UA session, which is
/// `package:open62541` and so `dart:ffi`. The MCP bridge already treats the
/// browser as optional — `NodeBrowser? nodeBrowser` is null whenever StateMan
/// is not up — so the web arm returns the same null the bridge has always
/// coped with, and every other MCP tool (alarms, config, PLC code, trends)
/// is unaffected.
library;

export 'node_browser_seam_io.dart'
    if (dart.library.js_interop) 'node_browser_seam_web.dart';
