/// Interactive sign-in over the socket — the wire half of the 2026-09-08
/// ruling's increment B (*"remove the need of station credential file"*).
///
/// A panel admitted with no credential holds the awaiting-sign-in sentinel
/// and may do nothing but wait (`SessionLoginValidator`, increment A). This
/// file is the method that ends the waiting: a person's `app_user` username
/// and password cross inside the `wss://` frame, the **server** verifies them
/// (Argon2id through the `AuthProvider` seam `tfc_access` already declares),
/// resolves user → role → groups from the database exactly as the token path
/// does, and answers with what it resolved. The client supplies no identity
/// anywhere — D-11's rule, unchanged: attribution is to a user the server
/// verified, never to a claim.
///
/// **The password travels in a params object, never a bare argument** —
/// [NewUserParams]' own discipline, for its own reason: a class can withhold
/// the credential from `toString` where a parameter list cannot, and
/// `toString` output reaches log files that live longer and travel further
/// than the database does. No digest is computed on the client, because a
/// client-computed digest *is* the password.
///
/// **There is deliberately no retained-credential field in either shape.**
/// Whether a remembered login gets minted and server-verified is increment
/// C's one open decision, reserved to the owner; a field here would be that
/// decision made by omission. Sign in, hold the session for this run — the
/// socket closing ends it.
library;

import 'dart:convert';

import 'package:tfc_access/tfc_access.dart';

import 'access_api.dart';

/// The stable markers a `session.login` / `session.logout` refusal carries in
/// its message, spelled once so both ends match by constant rather than by a
/// retyped substring.
///
/// A marker tells the panel *what to render* — the sign-in screen, the "wrong
/// password" line, the "cannot reach" line — and none of them ever carries
/// the credential, the reason rule `TokenRejected` states. The two
/// bad-credential cases (unknown username, wrong password) share ONE marker
/// deliberately: two would let anybody at the panel enumerate which usernames
/// exist by watching which one comes back.
abstract final class SessionAuthMarkers {
  /// A session nobody has signed in on was asked to do anything but wait.
  /// Already on the wire since increment A (`relay_session.dart`'s gate);
  /// named here so the login path and the gate spell it identically.
  static const String awaitingSignIn = 'awaiting_sign_in';

  /// The username or password was not recognised. One marker for both.
  static const String badCredentials = 'bad_credentials';

  /// Verification could not be *attempted* — the user source threw, or the
  /// gateway's account cache has nothing to resolve against. Kept apart from
  /// [badCredentials] all the way to the form: a database blip is not
  /// somebody mistyping a password, and telling them it was sends them off
  /// to reset a credential that was never the problem.
  static const String userSourceUnavailable = 'user_source_unavailable';

  /// This session already authenticated with a station credential at hello.
  /// Signing a person in **over** a station's base identity is elevation
  /// semantics — deferred, explicitly, by the remove-station-credential
  /// design §5 — so the refusal names the file instead of half-implementing
  /// the stacked model.
  static const String stationCredentialSession = 'station_credential_session';

  /// A second `session.login` on a session somebody is already signed in on,
  /// refused the way a second `hello` is: sign out first.
  static const String alreadySignedIn = 'already_signed_in';

  /// This gateway was composed without a sign-in verifier, so there is
  /// nothing to check a password against. A deployment fact, not a
  /// credential verdict.
  static const String signInNotServed = 'sign_in_not_served';
}

/// The arguments of `session.login`.
///
/// [station] is this panel's own name for **where** it stands — the audit
/// trail's `station` column, the same self-reported hostname a direct-mode
/// panel writes into its own rows. It is a location label and never an
/// identity: who signed in is decided by the server from the verified row,
/// and no field of this class can influence that. Null when the panel has
/// nothing to say; the server then labels the rows with its own sentinel.
final class SessionLoginParams {
  const SessionLoginParams({
    required this.username,
    required this.password,
    this.station,
  });

  /// The `app_user` username being signed in. Untrusted input straight off
  /// the login form; the server truncates it before any audit row.
  final String username;

  /// The credential. Withheld from [toString]; see the library doc.
  final String password;

  /// Where this panel says it stands. A label for the trail, never an
  /// identity — see the class doc.
  final String? station;

  Map<String, Object?> toJson() => <String, Object?>{
        'username': username,
        'password': password,
        if (station != null) 'station': station,
      };

  static SessionLoginParams fromJson(Map<String, Object?> json) =>
      SessionLoginParams(
        username: json['username'] as String,
        password: json['password'] as String,
        station: json['station'] as String?,
      );

  @override
  String toString() => 'SessionLoginParams(username: $username, '
      'station: $station, password: <withheld>)';
}

/// What a successful `session.login` answers: who the server verified, and
/// what that account's role grants right now.
///
/// [user] is [AuthenticatedUser] for [AccessAdminApi.listUsers]' reason —
/// that class carries **no password-specific fields at all**, so no hash can
/// reach this wire by somebody forgetting to strip it. [groups] were chased
/// user → role → groups through the database by the server; the client
/// renders them and enforces nothing with them — every relayed operation is
/// graded again server-side against the session's identity.
final class SessionLoginResult {
  const SessionLoginResult({required this.user, required this.groups});

  /// The `app_user` row the server resolved, verbatim.
  final AuthenticatedUser user;

  /// What the row's role grants, as of the moment the login was accepted.
  final Set<AccessGroup> groups;

  Map<String, Object?> toJson() => <String, Object?>{
        'user': authenticatedUserToJson(user),
        'groups': accessGroupsToWire(groups),
      };

  static SessionLoginResult fromJson(Map<String, Object?> json) =>
      SessionLoginResult(
        user: authenticatedUserFromJson(
            (json['user'] as Map).cast<String, Object?>()),
        groups: accessGroupsFromWire((json['groups'] as String?) ?? ''),
      );

  @override
  String toString() => 'SessionLoginResult(${user.username}, '
      '${user.roleName}, ${groups.length} group(s))';
}

/// Encodes a group set as the wire carries one: a JSON array of enum names,
/// in declaration order — `AccessRole.encodeGroups`' exact spelling, restated
/// for a bare set because the role class's encoder is an instance member.
///
/// The inverse is [accessGroupsFromWire], whose forgiving decode (unknown
/// names dropped, garbage reads as the empty set) is what makes this pair
/// safe across builds that disagree about which groups exist.
String accessGroupsToWire(Set<AccessGroup> groups) => jsonEncode(
      AccessGroup.values.where(groups.contains).map((g) => g.name).toList(),
    );
