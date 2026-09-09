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

  /// Nobody is signed in — the identity a credential-less hello is admitted
  /// as, and the direct-mode anonymous session's counterpart on this wire.
  ///
  /// **This is the third state's replacement, and the point is that it is not
  /// a third state.** A gateway used to hold such a session to `hello`, `ping`
  /// and the two session-auth names by a blanket, method-level refusal that
  /// the policy never saw — so "what may a panel do with nobody signed in"
  /// had two different answers depending on the transport, and the socket's
  /// answer could not be reasoned about in the master system's terms at all.
  /// It also closed a ring: a panel reads `key_mappings` in order to build the
  /// very client it would have to sign in through (measured on the rig,
  /// 2026-09-09). Here the question is asked once, of `AccessPolicy`, exactly
  /// as `AccessSession.anonymous` asks it at a walk-up panel.
  ///
  /// [groups] is passed in and is **customer data**, never a constant here:
  /// direct mode reads it from the `Operator` row (`AccessRepository.
  /// anonymousGroups`), and editing that row changes what an unauthenticated
  /// panel may do. See [AccessSession.anonymous], which says the same thing
  /// and names the footgun. Passing an empty set is the fail-closed answer for
  /// a gateway that has wired no source, and it is what makes every write
  /// question on this wire answer no.
  ///
  /// **The session's `user` is null and the identity's is not**, and that
  /// asymmetry is deliberate rather than an oversight of the type:
  ///
  ///  * `AccessSession.user == null` **is** what anonymous means to the master
  ///    system — `isElevated` reads it, `roleName` falls back to `Operator`
  ///    through it, and a session that named a user here would be elevated by
  ///    construction and could never be signed in on.
  ///  * [StationIdentity.user] is what an audit row's `who` column records,
  ///    and that column is not nullable. `'anonymous'` is the string every
  ///    direct-mode surface already writes there (four private `_anonymousWho`
  ///    constants across `tfc_dart`'s guards), so an anonymous action over the
  ///    socket lands in the same trail, spelled the same way, as the same
  ///    action at a panel. A relay-specific spelling would split one column in
  ///    two and nobody would notice until they filtered on it.
  factory StationIdentity.anonymous({
    required Set<AccessGroup> groups,
    required String station,
  }) =>
      StationIdentity(
        user: const AuthenticatedUser(
          username: anonymousWho,
          roleName: kOperatorRoleName,
          // A panel, not a person — so nothing about being nobody hands this
          // an inactivity window. `AccessSession.anonymous` makes the same
          // call by leaving `expiresAt` null: anonymous is the state a
          // session times out *into*, and a state that expired into itself
          // would be a panel that logged nobody out forever.
          stationAccount: true,
        ),
        station: station,
        session: AccessSession.anonymous(groups),
      );

  /// The `who` an anonymous action is attributed to, matching direct mode.
  ///
  /// Spelled here because `tfc_access` publishes no constant for it and the
  /// four copies in `tfc_dart` are all private. Hoisting them into one public
  /// constant is the right cleanup and is deliberately not done in the change
  /// that needed the fifth: it touches four guards on the app's write path.
  static const String anonymousWho = 'anonymous';

  /// True when nobody is signed in on this session.
  ///
  /// Reads the master system's own predicate rather than comparing against a
  /// sentinel object. That matters for more than tidiness: the anonymous
  /// identity now carries a group set read out of the database, so it cannot
  /// be a `const` compared with `==` — and a comparison that silently stopped
  /// matching would reopen sign-in on a session that already had somebody on
  /// it. `isElevated` is the same question `AccessSession` answers for the
  /// app bar, so the two transports cannot drift on what "signed in" means.
  bool get isAnonymous => !session.isElevated;

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
