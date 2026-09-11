/// The credential check in the `hello` path — the seam, and the permissive
/// default that stands in it until Phase 6.
///
/// **The capability, declared where it is registered.** This phase ships the
/// seam and the wiring that calls it on every `hello` before the version is
/// negotiated; Phase 6 ships the validator that actually reads a token
/// (SEC-03), together with TLS and origin enforcement. SRV-01's "rejects
/// unauthenticated clients" is met today by what the session already refuses:
/// a client that sends any other method before `hello`, a `hello` whose params
/// do not decode, and a `hello` naming no protocol version the server speaks.
/// Those are asserted in `session_hello_test.dart`, so the requirement has
/// teeth now and gains a credential later.
///
/// Writing it as an injected interface rather than a `TODO` is what makes the
/// Phase 6 change a one-line substitution at the call site instead of surgery
/// on the handshake, and what lets this phase test the rejection path — the
/// path that will matter — with a validator that says no.
library;

import 'dart:typed_data';

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'auth/identity.dart';

/// Judges the credential a client presented in its `hello`.
///
/// Given the whole [HelloParams] rather than a token string, and the reason is
/// no longer the one this doc used to give. It said "a credential may arrive
/// in `capabilities`"; since 06-02 the credential has a typed slot,
/// `HelloParams.token`, precisely so that it never rides in an open map the
/// session logs and copies (`relay_session.dart:729-739`). What survives is
/// the other argument this doc already made: an implementation that wants to
/// bind a token to a client name or a resumed session id needs to see them
/// together. The signature is unchanged; only the justification was wrong.
abstract interface class TokenValidator {
  /// Asynchronous because a real validator talks to something — a key set, an
  /// introspection endpoint, a directory — and a synchronous signature would
  /// have to be broken to add one.
  ///
  /// **Constraint on an implementation: resolve without awaiting external
  /// I/O.** The `Future` may be asynchronous in the microtask sense; it must
  /// not be asynchronous in the *event* sense. `RelayServer.reloadTokens`
  /// awaits the credential set's reload and then sweeps the sessions that
  /// already carry an identity, and it is safe today only because
  /// `FileTokenValidator.validate` contains no `await`: a hello in flight
  /// therefore assigns its identity in a microtask, and microtasks drain
  /// before the reload's I/O completion can be delivered, so the interleaving
  /// that would matter cannot occur.
  ///
  /// An implementation that awaits real work — a directory lookup, a cache
  /// with a refresh-on-miss, an HMAC service — reopens the window: the hello
  /// resolves against the *pre-reload* credential set, the sweep runs while
  /// the session's identity is still null and skips it, and the session is
  /// then handed a revoked identity that no sweep will visit again. It keeps
  /// its access for the life of the socket.
  ///
  /// If a validator genuinely has to wait on something, do the waiting
  /// **outside** this method — load the answer into memory on a cadence of its
  /// own, the way `FileTokenValidator` does with `reload` — and make this call
  /// a lookup. `auth_test.dart` pins the property for the one implementation
  /// this repository ships.
  Future<TokenVerdict> validate(HelloParams params);
}

/// The two answers, sealed so a caller must handle both.
sealed class TokenVerdict {
  const TokenVerdict();
}

final class TokenAccepted extends TokenVerdict {
  const TokenAccepted(this.identity, {this.credentialDigest});

  final StationIdentity identity;

  /// A one-way digest of the credential that was accepted, when the validator
  /// has one — never the credential.
  ///
  /// **What it is for.** [StationIdentity] is deliberately credential-free,
  /// which means two different tokens that name the same station as the same
  /// account with the same role are *equal* identities. That is the right
  /// shape for everything downstream of the handshake, and it is blind to the
  /// one revocation an operator actually performs: a leaked token is
  /// remediated by **replacing** it, and the session holding the leaked one
  /// then still matches what the file says about its station. Carrying the
  /// digest beside the identity is what lets
  /// `RevocableTokenValidator.stillValid` tell "this station is still
  /// entitled" from "this *credential* is still the one".
  ///
  /// **Safe to hold and to log**, by the same argument [StationIdentity] is: a
  /// SHA-256 of a token at or above the loader's 24-character floor is not
  /// reversible, and the digest is already what the loaded credential set is
  /// keyed by (`file_token_validator.dart`'s library doc).
  ///
  /// Null from a validator that has no such thing —
  /// [PermissiveTokenValidator] accepted no credential at all.
  final Uint8List? credentialDigest;
}

/// Refused. [reason] is for the server's log and for the error message the
/// client receives; it must not carry anything the client did not already
/// send — **and never the credential itself.**
///
/// The second clause is not implied by the first, which is why it is written
/// down. The client *did* send the token, so "nothing the client did not
/// already send" permits echoing it, and a reason that echoes it publishes
/// the credential into a `-32003` message, into this gateway's log, and into
/// whatever the panel prints on the screen an operator is looking at
/// (06-02-SUMMARY §3, T-06-26). Name the station, name the file, never the
/// secret. `auth_test.dart`'s "the credential appears in no message, close
/// reason, status frame or log" drives a distinctive literal through a
/// refusal and asserts its absence from all four.
final class TokenRejected extends TokenVerdict {
  final String reason;
  const TokenRejected(this.reason);
}

/// The role name a permissive gateway hands out.
///
/// Names itself, for the same reason [PermissiveTokenValidator.stationId] does:
/// it lands in `AuthenticatedUser.roleName`, in `AccessSession.roleName` and in
/// every audit row a permissive gateway writes. A trail full of
/// `Permissive (development)` is a deployment telling on itself; a neutral name
/// like `Default` would read as a role somebody created.
///
/// Deliberately **not** a row in `app_user` or `app_role` and deliberately not
/// resolved through the `UserResolver`: this validator has no database, which
/// is the whole of what makes it permissive.
const String kPermissiveRoleName = 'Permissive (development)';

/// Accepts every client. The default, and the whole of this phase's auth.
///
/// Named for what it does rather than for what it lacks, so a deployment that
/// still has one in Phase 6 is legible in a config diff.
///
/// **It is now permissive about permissions as well as about credentials, and
/// that is a larger claim than it used to make.** Before Phase 17 it granted
/// `operate`, one of two values; now it mints a session holding the **full**
/// `AccessGroup` set — every group the master system has, including
/// `administer` and `users`. Nothing about the deployment changed, but what the
/// label covers did, and this is why `RelayServer`'s `exposureWarning` still
/// logs before the bind rather than after it.
final class PermissiveTokenValidator implements TokenValidator {
  const PermissiveTokenValidator();

  /// The station id every client gets from a permissive gateway.
  ///
  /// Names itself, because it is going to be printed: it reaches close
  /// reasons, logs and whatever a refusal says about who was refused. A
  /// neutral-looking id like `default` reads as a station somebody configured.
  static const String stationId = 'any-station-permissive-validator';

  /// **Every group, and that is the honest label rather than a generous one.**
  ///
  /// This validator's semantics today are "everyone may do everything", and
  /// the full group set is that written down. Granting a narrower set would be
  /// a different, quieter lie: every existing fixture in this workspace runs on
  /// this default and writes through it, so a narrow set here would either
  /// break them all or — worse — leave a gateway whose declared role says one
  /// thing and whose behaviour does another. A deployment still running one
  /// stays legible in a config diff, which is this class's whole reason for
  /// having a name instead of being a null check.
  ///
  /// `stationAccount: true` because it is still a panel rather than a person;
  /// the permissiveness is in the groups, not in the kind of account.
  static final StationIdentity identity = StationIdentity(
    user: _permissiveUser,
    station: stationId,
    session: AccessSession(
      user: _permissiveUser,
      groups: AccessGroup.values.toSet(),
    ),
  );

  static final AuthenticatedUser _permissiveUser = const AuthenticatedUser(
    username: stationId,
    roleName: kPermissiveRoleName,
    stationAccount: true,
  );

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}
