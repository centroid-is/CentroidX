/// Reaching the live OPC UA sessions behind a [StateMan], when there are any.
///
/// `clients` is no longer a [StateMan] member. A `List<ClientWrapper>` is a
/// list of open62541 sessions, so naming it on the interface put `dart:ffi`
/// into the closure of every library that guards or holds a `StateMan` —
/// which is nearly all of them, and is what made the app unbuildable for a
/// browser.
///
/// The callers that genuinely need a session are the browse and diagnostic
/// surfaces: the node browser, the array-index picker, the Server Config
/// status chips, the Schneider asset's field descriptions. Each already had to
/// cope with an empty list. This function keeps that explicit and keeps the
/// type out of the interface.
///
/// This file is native-only by construction — it names [ClientWrapper], which
/// is an OPC UA session and therefore `dart:ffi`. It must never be reachable
/// from a web entrypoint; only the `_io` arm of a seam may import it.
library;

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The live OPC UA sessions [stateMan] holds, unwrapping an access guard.
///
/// Empty when this process holds none, which is a normal state and not an
/// error.
List<ClientWrapper> opcUaSessionsOf(StateMan stateMan) {
  if (stateMan is OpcUaStateMan) return stateMan.clients;
  if (stateMan is GuardedStateMan) {
    return stateMan.innerAs<OpcUaStateMan>()?.clients ?? const [];
  }
  return const [];
}
