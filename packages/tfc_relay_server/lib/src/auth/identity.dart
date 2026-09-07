/// Who a session is, once its credential has been accepted — a **station**,
/// never a person.
///
/// What the plant has is panels bolted to walls, each with a token mounted
/// beside it. `tfc_access` already models exactly that:
/// `AuthenticatedUser.stationAccount` is *"this identity is a panel, not a
/// person, and its sessions never expire"* (schema v8). So this file no longer
/// declares an identity model of its own — it names a station and carries the
/// master system's types.
///
/// **This type cannot hold a credential**, and that is structural rather than
/// a convention: it has three fields, and none is the token. An identity is
/// what a token is exchanged *for*, so it is safe to log, safe to put in a
/// close reason, and safe to name in an error — which is exactly what the
/// revocation sweep does. `TlsConfig` carries the same discipline for key
/// material (paths, never bytes) and for the same reason: a type that cannot
/// hold the secret cannot leak it. `identity_test.dart` asserts the field names
/// rather than trusting the sentence.
///
/// **What this type no longer does is decide anything.** Phase 17's
/// constitution is *"one master access control system, the websocket can build
/// on top of that"*, and the two types this file used to declare were the
/// counter-example: `enum Role { view, operate }` was a second role vocabulary
/// beside the seven `AccessGroup`s, and `Identity {stationId, role}` was a
/// second identity axis. Both are deleted. What replaced them answers **who**;
/// the [StationIdentity.user] is the `app_user` row the server resolved, and
/// the groups on [StationIdentity.session] were chased user → role → groups
/// through the database, never read from the credential. The token file names
/// a USER and grants nothing — not even a role name (D-06 as ruled, redirected
/// 2026-09-07: *"we will use a user for a station"*).
///
/// Without this file the gateway can only answer "the credential was good",
/// which is enough to let a panel in and not enough to close one station's
/// session when its token is pulled — the whole of SEC-03's revocation clause.
library;

import 'package:tfc_access/tfc_access.dart';

/// One station, who it is, and what its role resolved to.
///
/// A const-constructible value type with value equality, because it is
/// compared rather than mutated: the revocation sweep asks the token file
/// whether the identity a live session is carrying is still the identity that
/// file — and the account row behind it — describe. An identity type with
/// reference equality would answer "no" for every session on every reload and
/// close the whole plant.
///
/// All three fields are part of that comparison, and the third is the one this
/// phase adds: after Phase 17 a role name decides `configure` and `administer`
/// as well as `operate`, so a demotion made by unticking a group on a role —
/// with the token file untouched — has to be visible to the sweep.
/// `AccessSession` has value equality over its user, its expiry and its group
/// set (`access_session.dart:141-150`, a `SetEquality`), so comparing the
/// session compares the groups; nothing here needs to reach inside it.
final class StationIdentity {
  const StationIdentity({
    required this.user,
    required this.station,
    required this.session,
  });

  /// The `app_user` row this panel authenticates as, resolved by the server.
  ///
  /// This is what an audit row's `who` column records (D-11, improved by the
  /// redirect): the token file only *named* this account, and everything on
  /// it — the role, the `stationAccount: true` marking, even the display name
  /// — is what the **server** read out of the database after verifying the
  /// credential by constant-time digest compare. Attribution is therefore to
  /// a verified user rather than to a file's claim. The client may not supply
  /// it, and there is no wire field through which a hand-rolled client could
  /// name somebody else.
  final AuthenticatedUser user;

  /// The station this session speaks for — `ST101`, `PACK-02`. Stable across
  /// reconnects, which is what makes it the thing a future `writeStatus`
  /// narrowing can be keyed on (see `write_outcome_log.dart`) where the
  /// session id cannot.
  final String station;

  /// What this station's user resolved to, as of the moment its `hello` was
  /// accepted.
  ///
  /// **The role and the groups came from the database, not from the file —
  /// the file has nowhere left to put either.** That is the whole of D-06 as
  /// redirected: the credential mechanism may answer "which identity is
  /// this" and may not answer "and therefore may do X". It does not track
  /// later edits on its own — the sweep in `RelayServer.reloadTokens` is what
  /// makes a demotion take effect, by closing the session that is still
  /// carrying the old one.
  final AccessSession session;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StationIdentity &&
          other.user == user &&
          other.station == station &&
          other.session == session;

  @override
  int get hashCode => Object.hash(user, station, session);

  /// Safe to print anywhere, by construction — see this library's doc.
  ///
  /// The station and the role **name**, and deliberately not the group set: a
  /// close reason and a log line are the two places this type is printed, and
  /// a close reason that enumerated what a station may do would publish the
  /// plant's grading to whoever is watching the socket.
  @override
  String toString() => 'StationIdentity($station, ${session.roleName})';
}
