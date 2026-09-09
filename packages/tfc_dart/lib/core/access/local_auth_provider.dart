import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_access/tfc_access.dart';

import 'access_repository.dart';

/// Authenticates against `app_user` with whichever derivation the stored row
/// names.
///
/// New rows are Argon2id. A `pbkdf2-sha256` row is verified forever, at the
/// count recorded in the row: existing users must not be locked out by the
/// change of algorithm.
///
/// ## The migration
///
/// A successful login also upgrades the row it authenticated against, if the
/// stored form is stale. That is transparent — nothing is asked of the user and
/// nothing is said to them — and it is the only moment it can happen, because
/// the password is in hand exactly once, here. A write-back that fails is
/// logged and ignored: the user typed the right password, and refusing them
/// over a rewrite they never asked for would be the migration locking out the
/// very people it exists to carry forward.
///
/// The only [AuthProvider] this milestone ships. A second implementation —
/// OIDC, one day — goes behind the same interface without touching a caller,
/// which is the whole reason the interface exists.
///
/// ## null versus throw
///
/// **Null means the credentials were not recognised. A throw means
/// infrastructure failed.** Nothing in here wraps the body in a try/catch that
/// turns a dropped connection into a null, and nothing should be added that
/// does. The caller (plan 01-07) writes an audit row with `allowed: false` for
/// a null; if an outage arrived as a null too, a five-minute network blip would
/// land in the trail as twenty failed login attempts, and a trail that reports
/// events that did not happen is a trail nobody trusts afterwards. The
/// distinction cannot be recovered further up, so it has to be honoured here.
///
/// ## The honest framing
///
/// This is an operational guardrail against accident, not an access control.
/// Anyone holding the station's Postgres credential can rewrite `app_user`
/// directly. What it buys is that a shoulder-surfed screen or a shared
/// workstation does not hand over somebody else's role.
class LocalAuthProvider implements AuthProvider {
  LocalAuthProvider(this.repository, {Logger? logger})
      : _logger = logger ?? Logger();

  final AccessRepository repository;
  final Logger _logger;

  /// A well-formed hash and salt to derive against when the user does not
  /// exist, so the absent-user path costs the same work as the wrong-password
  /// path.
  ///
  /// Fixed values, and deliberately not derived from any real password: nothing
  /// verifies against them, they exist to be burned. Base64 of 32 and 16 zero
  /// bytes respectively — the shapes [PasswordHasher.verify] expects, so it
  /// reaches the derivation rather than bailing out early on a decode failure.
  static const String _dummyHashB64 =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
  static const String _dummySaltB64 = 'AAAAAAAAAAAAAAAAAAAAAA==';

  /// How many dummy derivations have run.
  ///
  /// A test hook, and the only way to assert the enumeration-resistance path
  /// was taken: the honest alternative is wall-clock timing, which is far too
  /// flaky to put in a suite.
  @visibleForTesting
  static int dummyDerivations = 0;

  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    final name = username.trim();
    // Nothing to hide on this branch: an empty username is not a username
    // somebody might or might not have, so short-circuiting it leaks nothing
    // and saves a pointless derivation.
    //
    // An empty *password* is no longer short-circuited here. It used to be,
    // and it could not be once a passwordless account became a thing an
    // administrator can create: leaving the box blank is exactly how such an
    // account signs in, and refusing it before the row is read would make the
    // feature unreachable. An empty password against an account that *has* one
    // still fails, below, and against no account at all it still costs a dummy
    // derivation.
    if (name.isEmpty) return null;

    final row = await repository.user(name);

    if (row == null) {
      // Username-enumeration resistance: derive anyway, so "no such user" and
      // "wrong password" cost the same. Be honest about the weight of this —
      // it is cheap and correct, but the whole scheme is a guardrail, and an
      // attacker who can time an HMI login form can also run `psql`. It is
      // here because leaving it out would be a gratuitous difference, not
      // because it defends against a threat this deployment actually faces.
      //
      // Built at the *current* Argon2id parameters, because that is what a
      // real row costs. The residual, stated rather than absorbed: a user who
      // is still on a `pbkdf2-sha256` row costs a different amount than this
      // dummy, so the timing distinguishes "not yet migrated" from "does not
      // exist" until that row is rewritten on its owner's next login. It does
      // not distinguish existence for anyone already migrated, and it
      // self-heals as the rows turn over.
      dummyDerivations++;
      final params = Argon2idKdf.params;
      await PasswordHasher.verify(
        password: password,
        stored: PasswordHash.argon2id(
          hashB64: _dummyHashB64,
          saltB64: _dummySaltB64,
          memoryKib: params.memoryKib,
          iterations: params.iterations,
          parallelism: params.parallelism,
        ),
      );
      return null;
    }

    // An account with no password signs in on its username alone. Nothing is
    // derived and nothing is compared, because there is nothing to compare
    // against: whatever was typed into the password box is ignored, including
    // a wrong guess, because a wrong guess at a password that does not exist
    // is not a failed credential.
    //
    // Asked *before* the decode, and the ordering is the safety property: the
    // marker is not a [PasswordHashAlgorithm], so [decodeStoredHash] answers
    // null for it and the branch below would refuse the login. Forgetting this
    // check therefore locks the account out rather than letting anybody in —
    // see [kNoPasswordMarker].
    //
    // Stated plainly, because it is the whole risk of the feature: **anybody
    // standing at the panel can sign in as this account and hold its role.**
    // That is what it is for — a line operator should not type on a wet
    // touchscreen — and it is why the users screen marks these accounts and
    // why the first-user window refuses to create one.
    final PasswordHash? stored;
    if (isPasswordless(row.passwordHash)) {
      stored = null;
    } else {
      // An account that *has* a password is not opened by leaving the box
      // blank. Refused before the derivation: there is no credential to check,
      // and an empty guess is not one.
      if (password.isEmpty) return null;

      final decoded = decodeStoredHash(row.passwordHash, saltB64: row.salt);
      if (decoded == null) {
        // A hash column mangled by hand. Not a credential failure in spirit,
        // but it is one in effect, and it must not take the login screen down
        // with a FormatException.
        _logger.w(
          'The stored password hash for "$name" could not be decoded — the row '
          'has been edited outside the app. Treating the login as failed.',
        );
        return null;
      }

      final ok = await PasswordHasher.verify(
        password: password,
        stored: decoded,
      );
      if (!ok) return null;
      stored = decoded;
    }

    final role = await repository.role(row.roleName);
    if (role == null) {
      // A role deleted out from under a user. Returning an AuthenticatedUser
      // here would sign somebody in against an undefined group set, which
      // resolves to "nothing" or "everything" depending on who reads it next —
      // both wrong, and neither visible to the person at the panel.
      _logger.w(
        'User "$name" holds the role "${row.roleName}", which no longer exists '
        'in app_role. Refusing the login rather than signing in against an '
        'undefined group set.',
      );
      return null;
    }

    await repository.touchLastLogin(row.username, DateTime.now().toUtc());

    // Never for a passwordless account: there is no plaintext in hand and no
    // hash to carry forward, and `stored` is null precisely so this cannot be
    // reached with nothing to rehash.
    if (stored != null && PasswordHasher.needsRehash(stored)) {
      // The migration, and the only moment it can happen: the password is in
      // hand exactly once, here, and never again. Nothing asks anybody for
      // anything and nobody is told.
      //
      // Deliberately awaited rather than fired and forgotten. A detached future
      // that errors attaches no handler and would surface as an unhandled async
      // error on a panel; its closure would hold the plaintext alive past the
      // frame that has a reason to hold it; and nothing could deterministically
      // assert the row was rewritten. The cost is one slower login per user,
      // once.
      try {
        await repository.rehashPassword(
          row.username,
          await PasswordHasher.hash(password),
        );
      } catch (e) {
        // Catching everything here is the opposite of the rule stated at the
        // top of this file, and it is deliberate. That rule — never turn an
        // infrastructure failure into a null — exists so a database outage is
        // not recorded as somebody's failed login. This block is not on that
        // path: the credentials have already been judged, the answer is "yes",
        // and the only thing that can fail is a housekeeping write nobody asked
        // for. Letting a throw escape would turn a correct password into a
        // failed login, which is precisely what the migration exists to avoid.
        _logger.w(
          'Signed "$name" in, but could not upgrade their stored password '
          'hash to the current algorithm: $e. The login stands; the upgrade '
          'will be retried on their next one.',
        );
      }
    }

    return AuthenticatedUser(
      username: row.username,
      roleName: row.roleName,
      stationAccount: row.stationAccount,
    );
  }
}
