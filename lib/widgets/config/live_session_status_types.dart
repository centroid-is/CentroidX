/// What a config card needs to know about a live session, without naming the
/// session.
library;

import 'package:tfc_dart/core/state_man_types.dart'
    show ConnectionStatus, EffectiveDeviceStatus;

/// The connection state of one configured server, as the card renders it.
///
/// A flat record rather than the session object, because the session is a
/// `ClientWrapper` — an open62541 handle, and so `dart:ffi`. Every field is
/// nullable and null means the same thing it has always meant here: this
/// process holds no session for that server, which is the normal case in
/// gateway mode and the only case in a browser.
class LiveSessionStatus {
  const LiveSessionStatus({
    this.connectionStatus,
    this.connectionStream,
    this.effectiveStatus,
    this.effectiveStatusStream,
  });

  final ConnectionStatus? connectionStatus;
  final Stream<ConnectionStatus>? connectionStream;

  /// Data-plane health: catches the frozen-session shape where the channel
  /// stays formally open but no value ever arrives again.
  final EffectiveDeviceStatus? effectiveStatus;
  final Stream<EffectiveDeviceStatus>? effectiveStatusStream;
}
