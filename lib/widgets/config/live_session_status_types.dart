/// What a Server Config status chip needs from a live session, with nothing
/// platform-specific in it.
///
/// Every member is either a [ConnectionStatus], an [EffectiveDeviceStatus], a
/// stream of one, or a closure returning a string — all of which
/// `state_man_types.dart` carries with no `dart:ffi` behind them. That is the
/// point: the card is the same card on a station and in a browser, and only
/// the lookup that fills this in is platform-specific.
library;

import 'package:tfc_dart/core/state_man_types.dart'
    show ConnectionStatus, EffectiveDeviceStatus;

class LiveSessionStatus {
  const LiveSessionStatus({
    this.connectionStatus,
    this.connectionStream,
    this.effectiveStatus,
    this.effectiveStatusStream,
    this.healthDetail,
  });

  final ConnectionStatus? connectionStatus;
  final Stream<ConnectionStatus>? connectionStream;

  /// Combined link + data-plane health. Timer-derived, so it goes
  /// `opcuaUnhealthy` when values silently stop flowing — the case the pure
  /// [connectionStream] chip used to render green forever.
  final EffectiveDeviceStatus? effectiveStatus;
  final Stream<EffectiveDeviceStatus>? effectiveStatusStream;

  /// Read on demand rather than captured: the reason a client is unhealthy
  /// changes without the card rebuilding, and this string is the only place
  /// the server's own refusal message reaches an operator.
  final String? Function()? healthDetail;
}
