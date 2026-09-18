import 'package:tfc_dart/core/state_man_types.dart' show StateMan;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart' show NodeBrowser;

/// Always null: there is no OPC UA session in a browser to browse.
///
/// The bridge's own comment already says "null unless StateMan is up:
/// browsing needs a live PLC session", and every caller honours it. This is
/// that same absence, decided at compile time rather than at runtime.
NodeBrowser? makeNodeBrowser(StateMan stateMan) => null;
