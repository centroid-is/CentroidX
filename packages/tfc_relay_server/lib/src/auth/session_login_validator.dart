/// The credential mechanism for a gateway that reads **no provisioned
/// station credential file** — increment A of the 2026-09-08 ruling:
/// *"remove the need of station credential file, i am pretty certain we
/// concluded that it is not required."*
///
/// **What it admits is deliberately nobody.** A hello presenting no
/// credential at all is accepted — that is the one new thing — and the
/// identity it is accepted *as* is [awaitingSignIn]: a self-naming sentinel
/// with the **empty group set** and no credential digest. Empty groups alone
/// are not the fail-closed story on this wire (reads are deliberately
/// ungated, §11's deferral), so `relay_session.dart` holds a session carrying
/// this identity to `hello` and `ping` alone until a sign-in replaces it.
/// The sign-in itself — a person's `app_user` username and password, verified
/// server-side through the same seam `LocalAuthProvider` already implements —
/// is a later increment; until it lands, an awaiting session is a sign-in
/// screen with a live socket and nothing else.
///
/// **Why admitting-with-nothing is not the D-06 refusal.** D-06 refuses to
/// admit an *unknown account* with an empty set, because in the trail that is
/// indistinguishable from an account whose role deliberately grants nothing.
/// Here no account was named at all: the emptiness is the designed,
/// self-describing state of "nobody yet", and the sentinel's names say so
/// everywhere they can be printed. The two states cannot be confused because
/// only one of them has a username that is anyone's.
///
/// **The migration posture is a decorator.** While a deployment still has a
/// token file, [stations] wraps its `FileTokenValidator` and every hello that
/// *does* present a credential is delegated verbatim — same acceptance, same
/// refusals, same digest, same revocation cases. A deployment whose file is
/// gone constructs this with no delegate, and a presented credential is then
/// refused with a message naming sign-in as the replacement. That is D-06's
/// own migration manner: refuse and name the replacement, never translate.
///
/// **What the sweep does with nobody.** [stillValid] answers true for the
/// sentinel, always: a panel sitting at the sign-in screen holds nothing a
/// sweep could revoke, and the sweep visits every live session on every poll
/// tick. Everything else stays fail-closed — an identity this validator
/// cannot account for is not honoured.
///
/// Like `file_token_validator.dart`, every string literal in this file is
/// written around the seven `AccessGroup` names and the two seed role names:
/// `session_login_validator_test.dart` greps the stripped source, because a
/// credential mechanism that can spell a permission is a credential mechanism
/// one refactor away from granting it.
library;

import 'dart:typed_data';

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../token_validator.dart';
import 'file_token_validator.dart';
import 'identity.dart';

/// The role name the awaiting-sign-in sentinel carries.
///
/// Names itself, for [kPermissiveRoleName]'s reason: it lands in
/// `AccessSession.roleName`, in `StationIdentity.toString`, and in any audit
/// row a misrouted caller ever attributes to it. "Awaiting sign-in" reads as
/// the state it is; a neutral name would read as a role somebody created.
/// Deliberately **not** a row in `app_role` and deliberately never resolved:
/// nobody is not an account.
const String kAwaitingSignInRoleName = 'Awaiting sign-in (nobody)';

/// Admits a credential-less hello as [awaitingSignIn]; delegates a presented
/// station credential to the wrapped file validator while one exists.
final class SessionLoginValidator implements RevocableTokenValidator {
  /// [stations] is the deployment's `FileTokenValidator`, while it still has
  /// one — the migration posture. Null is the end state: no file, and a
  /// presented credential refused by name.
  ///
  /// Typed as the concrete class rather than the interface on purpose: the
  /// token file is the only station-credential mechanism there is, the
  /// delegation exists solely so no deployment needs a flag day, and this
  /// parameter is deleted with the file. A seam here would be a seam
  /// inviting a second credential mechanism to live forever.
  SessionLoginValidator({this.stations});

  /// The wrapped file validator, or null once the deployment has crossed
  /// over. Public because `RelayServer.reloadTokensIfChanged` needs the
  /// digest-guarded reload the interface deliberately does not carry.
  final FileTokenValidator? stations;

  /// The station string of the sentinel. Self-naming: it reaches close
  /// reasons and logs, and must never read as a station somebody configured.
  static const String station = 'no-station-awaiting-sign-in';

  static const AuthenticatedUser _nobody = AuthenticatedUser(
    username: 'nobody-awaiting-sign-in',
    roleName: kAwaitingSignInRoleName,
    // A panel rather than a person, the same honest labelling
    // `PermissiveTokenValidator` argues for: the socket belongs to a wall
    // screen, and nothing about being nobody gives it an inactivity window.
    stationAccount: true,
  );

  /// Who a session is until somebody signs in: nobody, holding nothing.
  ///
  /// The `AccessSession` names [_nobody] as its user rather than leaving the
  /// user null, and that is load-bearing: a null-user `AccessSession` answers
  /// `roleName` with the direct-mode anonymous role — the one that means "an
  /// unattended panel may do what that role grants". A relay session nobody
  /// signed in on means the opposite, and must never print as that role.
  ///
  /// The group set is empty and const: there is structurally nothing here
  /// that could grant, which is `StationIdentity`'s own argument about
  /// credentials applied to permissions.
  static const StationIdentity awaitingSignIn = StationIdentity(
    user: _nobody,
    station: station,
    session: AccessSession(user: _nobody, groups: {}),
  );

  @override
  Future<TokenVerdict> validate(HelloParams params) async {
    final token = params.token;
    if (token == null || token.isEmpty) {
      // The admission this class exists for. No digest: no credential was
      // presented, and a digest here would be a claim about a secret that
      // does not exist.
      return const TokenAccepted(awaitingSignIn);
    }
    final delegate = stations;
    if (delegate == null) {
      // Never the credential itself in the reason — `TokenRejected`'s rule,
      // and the reason travels into a -32003 message and the gateway's log.
      return const TokenRejected(
          'a credential was presented on hello, and this gateway reads no '
          'station credential file to check it against. Stations sign in '
          'over the socket now: connect with no credential and sign in with '
          'an account, the way a person does');
    }
    return delegate.validate(params);
  }

  @override
  Future<void> reload() async => stations?.reload();

  /// The digest-guarded reload the embedder's poll calls, delegated.
  ///
  /// With no wrapped file there is nothing that could have changed and the
  /// answer is honestly false — the sweep still runs on every poll tick
  /// (17-11's discipline: the digest guards the parse, never the sweep), it
  /// just has no file-driven case left to find.
  Future<bool> reloadIfChanged() async =>
      await stations?.reloadIfChanged() ?? false;

  @override
  bool stillValid(StationIdentity identity, Uint8List? credentialDigest) {
    if (identity == awaitingSignIn) {
      // Nobody holds nothing; there is nothing to revoke. Closing the
      // sign-in screen once per poll tick would make the gateway unusable
      // before anyone could sign in.
      return true;
    }
    final delegate = stations;
    if (delegate == null) {
      // Fail closed: with no file there is no way this validator minted the
      // identity being asked about, and a sweep that answered "still fine"
      // would keep alive a session whose provenance nothing can explain.
      return false;
    }
    return delegate.stillValid(identity, credentialDigest);
  }
}
