import 'package:tfc_dart/core/state_man_types.dart' show StateMan;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart' show NodeBrowser;

import 'state_man_node_browser.dart';

/// The OPC UA node browser for [stateMan].
NodeBrowser? makeNodeBrowser(StateMan stateMan) =>
    StateManNodeBrowser(stateMan);
