/// The close codes this gateway sends that `CloseCodes` does not name yet.
///
/// **These belong in `CloseCodes` (`tfc_relay_protocol`'s `methods.dart`), and
/// this file is not a second table.** They live here because 16-09's scope is
/// this package while the protocol package was owned by another plan in the
/// same wave. Promotion is a two-line move and the deletion of this file;
/// nothing but the constant's spelling changes when it happens. What must
/// **not** happen in the meantime is a number being reused, so these continue
/// `CloseCodes`' sequence (4001–4005) rather than starting one of their own.
///
/// **Why either of them exists at all.** `error_codes.dart`'s doctrine is that
/// a code exists so a client can *behave differently*, and by that rule alone
/// neither of these would earn one: both mean "reconnect", as `heartbeatTimeout`
/// does. What earns them is the other reader. `ConnectionClose` — the gateway's
/// own close ledger — records **codes, not sentences**, so the code is the only
/// thing that survives to tell an operator which of these happened. Sharing
/// 4003 for the first would send an engineer looking at a heartbeat that was
/// never due; sharing 4002 for the second would tell them the gateway is going
/// away when it is not.
///
/// Its own file rather than a corner of `relay_server.dart` because both the
/// listening end and the tick engine's sweep raise them, and the engine cannot
/// import the server that owns it.
library;

abstract final class GatewayCloseCodes {
  /// The peer completed the upgrade and never said `hello` inside
  /// `ServerConfig.preHelloDeadline`.
  ///
  /// Reconnect and complete the handshake: the credential was never the
  /// problem, because it was never presented.
  static const preHelloTimeout = 4006;

  /// The gateway was already holding `ServerConfig.maxUnhelloedSessions`
  /// connections that had not said `hello`.
  ///
  /// Reconnect with backoff. This is transient and it is about the gateway's
  /// load, not about this peer's credential — which is exactly what 4001 would
  /// have said instead, sending a panel to re-authenticate a token that is
  /// perfectly good.
  static const unhelloedBudget = 4007;
}
