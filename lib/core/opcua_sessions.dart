/// Reaching the live OPC UA sessions behind a [StateMan], when there are any.
///
/// `clients` is not a [StateMan] member. It was, and that was a lie with a
/// shape: a panel in gateway mode holds no OPC UA session — the gateway holds
/// them all — and a browser cannot hold one at all, so the getter answered
/// with an empty list that read to callers as "no servers are configured".
///
/// Callers that genuinely need a session are the browse and diagnostic
/// surfaces: the node browser, the array-index picker, the server-config live
/// status chip, the Schneider asset's field descriptions. Every one of them
/// already had to cope with an empty list, because gateway mode has been
/// handing them one since the transport shipped. This function makes that
/// explicit and keeps the type out of the interface.
///
/// This file is native-only by construction — it names [ClientWrapper], which
/// is an open62541 session and therefore `dart:ffi`. It must not be reachable
/// from a web entrypoint.
library;

import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The live OPC UA sessions [stateMan] holds, unwrapping an access guard.
///
/// Empty when the plant is reached over the relay instead of directly — which
/// is the normal case on a station in gateway mode, not an error.
List<ClientWrapper> opcUaSessionsOf(StateMan stateMan) {
  if (stateMan is OpcUaStateMan) return stateMan.clients;
  if (stateMan is GuardedStateMan) {
    return stateMan.innerAs<OpcUaStateMan>()?.clients ?? const [];
  }
  return const [];
}
