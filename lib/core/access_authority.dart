/// What can verify a credential on this station.
///
/// The gate's first question, and the one it used to ask badly. Until 2026-09
/// `resolveAccessGate` took an `AsyncValue<AccessRepository?>` and read a
/// resolved null as "nobody can be authenticated here" — true on a direct
/// station with no Postgres, and false on a gateway panel, where
/// `databaseProvider` returns null *by design* (`lib/providers/database.dart`)
/// and the credential is verified server-side over the socket. That misreading
/// denied every raised route on a gateway panel no matter who signed in.
///
/// A pure enum, in `lib/core/` rather than beside the provider that computes
/// it, so the gate stays a pure function over a value a truth table can
/// enumerate — and so nothing in `lib/providers/` has to import a widget file
/// to name it.
library;

/// Where a sign-in is verified on this station.
enum AccessAuthority {
  /// Nowhere. Direct mode with no reachable Postgres: `signIn` can only answer
  /// `AccessSignInResult.unavailable`, so a locked page would be a prompt that
  /// cannot be passed. This is the state the Server Config exemption exists
  /// for.
  none,

  /// A local [AccessRepository] over this station's own Postgres. Direct mode,
  /// configured and reachable.
  local,

  /// The gateway, over the relay socket. The panel holds no user table and
  /// decides nothing: `RemoteStateMan.sessionLogin` hands the credential to
  /// the backend, which verifies it (Argon2id) and answers with the user, role
  /// and groups it resolved.
  ///
  /// A gateway session is therefore never a claim the panel made up, and never
  /// one that outlives its backing: gateway sessions are per-run, neither
  /// persisted nor restored (`AccessSessionController`, `_isGateway`). That is
  /// why [relay] may fall through to the session where [none] may not.
  relay,
}
