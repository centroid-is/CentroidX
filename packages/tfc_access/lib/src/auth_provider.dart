import 'access_group.dart';
import 'authenticated_user.dart';

/// The single seam behind which authentication lives.
///
/// One interface, so a second implementation — OIDC, one day — can be added
/// without touching a caller. `LocalAuthProvider` (plan 01-03) is the only
/// implementation this milestone ships.
abstract class AuthProvider {
  /// Resolve [username] and [password] to a user, or null.
  ///
  /// **Null means the credentials were not recognised.** Throwing means
  /// infrastructure failed — the database was unreachable, the connection
  /// dropped mid-query.
  ///
  /// The distinction is load-bearing, not stylistic: the caller writes an
  /// audit row with `allowed: false` for a null, and must not record a
  /// database outage as somebody's failed login attempt. A trail that reports
  /// twenty failed logins during a five-minute network blip is a trail nobody
  /// trusts afterwards.
  Future<AuthenticatedUser?> authenticate(String username, String password);
}

/// What became of a self-service password change.
///
/// Three outcomes, and the throw that is not one of them. The split follows
/// [AuthProvider.authenticate]'s rule exactly: a value means the request was
/// judged, a throw means it could not be — the database was unreachable, the
/// connection dropped mid-query. Collapsing an outage into
/// [wrongCurrentPassword] would send somebody off to recover a password that
/// was never the problem, and would put a phantom failure in the trail.
enum PasswordChangeResult {
  /// The stored row now holds the new password.
  ok,

  /// The current password did not verify against the stored row.
  ///
  /// Also what a row mangled by hand in `psql` returns. That is not a
  /// credential failure in spirit, but it is one in effect, and the
  /// alternative — a `FormatException` off a dialog — takes the screen down
  /// over a row the person at the panel did not write.
  wrongCurrentPassword,

  /// The account is gone from `app_user`.
  ///
  /// A real state, not an outage: an administrator can delete an account while
  /// its owner has a session open. It is deliberately **not**
  /// [wrongCurrentPassword] — telling somebody their password is wrong when
  /// their account no longer exists is a wrong answer that costs them the next
  /// ten minutes — and deliberately not a throw, because nothing failed.
  accountMissing,
}

/// Changing your own password, for the implementations that have one to change.
///
/// **A separate interface from [AuthProvider], on purpose.** The whole reason
/// `AuthProvider` is an interface is that a second implementation — OIDC, one
/// day — drops in without touching a caller. OIDC has no password this
/// application owns and could not implement this method; putting it on
/// `AuthProvider` would force every future implementation to carry a member it
/// must throw from, which is the seam rotting on the day it is first used.
///
/// So the capability is asked for rather than assumed. A caller writes
/// `auth is PasswordSelfService` and offers the affordance only when the answer
/// is yes — and on the day the station moves to OIDC the affordance disappears
/// on its own, with no call site edited and nothing left pointing at a screen
/// that cannot work.
///
/// ## What this is not
///
/// Not an administrator resetting somebody else's password. That is
/// `AccessRepository.setPassword` behind the `users` group, it records itself
/// as `user.password` on the admin surface, and it verifies nothing because an
/// administrator has no current password to present. This interface is the
/// other half: the account's own holder, proving they hold it, with no group
/// required. The two must not be collapsed — one of them is gated and the
/// other one must never be.
abstract class PasswordSelfService {
  /// Verify [currentPassword] against [username]'s stored row, and on success
  /// replace it with [newPassword].
  ///
  /// [username] comes from the live session, never from a field somebody typed.
  /// That is what makes this method free of the username-enumeration defence
  /// `AuthProvider.authenticate` has to carry: there is no unknown name to
  /// probe for, because the only name that reaches here is one already signed
  /// in.
  ///
  /// **Check-then-act, and knowingly so.** The verify and the write are two
  /// statements, so an administrator resetting the same row in between loses to
  /// this write. Last-writer-wins is the right answer — both parties hold a
  /// credential they believe is current, and the repository's own rule forbids
  /// holding a transaction open across a ~150 ms derivation, which is what
  /// closing the window would cost every caller to protect a race nobody has
  /// hit.
  ///
  /// Throws [ArgumentError] for an empty [newPassword] — carrying no value, so
  /// the credential cannot reach a log through the message.
  Future<PasswordChangeResult> changePassword({
    required String username,
    required String currentPassword,
    required String newPassword,
  });
}

/// Raised when a write is refused because the current role lacks the group it
/// requires.
///
/// Vocabulary only in this phase — Phase 1 gates nothing, so nothing throws
/// this yet. The guards in Phase 3 (`AccessGate`, `GuardedStateMan`,
/// `GuardedPreferences`) are what will.
class AccessDenied implements Exception {
  const AccessDenied(this.itemKey, this.required);

  /// The tag, preference key or route that was refused.
  final String itemKey;

  /// The group the caller would have needed.
  final AccessGroup required;

  @override
  String toString() =>
      'AccessDenied: "$itemKey" requires the ${required.name} group.';
}
