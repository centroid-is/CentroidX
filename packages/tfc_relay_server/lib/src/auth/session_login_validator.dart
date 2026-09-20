/// The credential mechanism for a gateway that reads **no provisioned
/// station credential file** — increment A of the 2026-09-08 ruling:
/// *"remove the need of station credential file, i am pretty certain we
/// concluded that it is not required."*
///
/// **What it admits is deliberately nobody.** A hello presenting no
/// credential at all is accepted, and the identity it is accepted *as* is the
/// **anonymous** one — [StationIdentity.anonymous], carrying whatever
/// [anonymous] answers and no credential digest. That is the same identity a
/// not-signed-in panel holds in direct mode, and from here on it is graded by
/// the same `AccessPolicy`, on the same surfaces, with the same refusals.
///
/// **This used to be a third state, and deleting that is the change.** The
/// identity was a `const` sentinel holding nothing, and because holding
/// nothing is not fail-closed on a wire whose reads are deliberately ungated
/// (§11's deferral), `relay_session.dart` bolted a blanket method-level gate
/// on top: everything refused but `hello`, `ping` and the two session-auth
/// names. It worked, and it cost two things. It made "what may a panel do
/// with nobody signed in" a question with two different answers depending on
/// the transport, one of which the master system could not see. And it closed
/// a ring: a panel reads `key_mappings` **in order to build** the client it
/// would have to sign in through, so it could not boot — measured on the rig
/// on 2026-09-09, where a credential-less session was admitted, could reach
/// `session.login`, and was refused the one preference it needed to get
/// there.
///
/// The gate is gone. What refuses an anonymous session now is the policy, and
/// only the policy: `key_mappings` still takes `configure` to write and it
/// still says so by name. What an anonymous session may *read* is what a
/// walk-up panel may read, which on both transports is everything — that was
/// already true and is `_PolicyPreferences`' documented rule, not a widening
/// made here.
///
/// **Why admitting-with-nothing is not the D-06 refusal.** D-06 refuses to
/// admit an *unknown account* with an empty set, because in the trail that is
/// indistinguishable from an account whose role deliberately grants nothing.
/// Here no account was named at all, and the identity says so: its `who` is
/// `anonymous`, the same string every direct-mode guard writes for the same
/// state. The two cannot be confused because only one of them has a username
/// that is anyone's.
///
/// **The migration posture is a decorator.** While a deployment still has a
/// token file, [stations] wraps its `FileTokenValidator` and every hello that
/// *does* present a credential is delegated verbatim — same acceptance, same
/// refusals, same digest, same revocation cases. A deployment whose file is
/// gone constructs this with no delegate, and a presented credential is then
/// refused with a message naming sign-in as the replacement. That is D-06's
/// own migration manner: refuse and name the replacement, never translate.
///
/// **What the sweep does with nobody.** [stillValid] re-reads what the plant
/// grants an anonymous session and retires the session when that has changed —
/// the same comparison a station and a signed-in person already get, rather
/// than the unconditional `true` this carried until the parallel it claimed
/// was checked and found false. An unchanged row keeps the session, so a
/// sign-in screen is never closed for being a sign-in screen. Everything else
/// stays fail-closed — an identity this validator cannot account for is not
/// honoured.
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

/// Admits a credential-less hello as the anonymous identity; delegates a
/// presented station credential to the wrapped file validator while one
/// exists.
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
  ///
  /// [accounts] is the same synchronous account source the file validator
  /// reads (`UserResolver`, answered from the embedder-refreshed cache) —
  /// here it is what the sweep judges a **signed-in person** against, the
  /// third provenance [stillValid] accounts for. Null in a deployment that
  /// serves no interactive sign-in, and then a login-minted identity is
  /// never honoured — fail closed, since nothing could have minted one.
  /// [anonymous] answers what a session with nobody signed in may do, and it
  /// is the ONLY thing this class knows about permissions — it is a function
  /// it calls, never a set it can spell. Direct mode's source is the
  /// `Operator` row (`AccessRepository.anonymousGroups`); the backend
  /// composition is what points this at the same one.
  ///
  /// **Null is fail-closed and is the default.** A gateway that has wired no
  /// source admits a credential-less hello as an identity holding nothing, so
  /// every write question the policy asks about it answers no. That is a
  /// deliberate default rather than a missing feature: the alternative — a
  /// built-in set — would be this file grading, which is the one thing it may
  /// never do.
  SessionLoginValidator({this.stations, this.accounts, this.anonymous});

  /// The wrapped file validator, or null once the deployment has crossed
  /// over. Public because `RelayServer.reloadTokensIfChanged` needs the
  /// digest-guarded reload the interface deliberately does not carry.
  final FileTokenValidator? stations;

  /// Where a signed-in person's username is re-resolved on every sweep
  /// tick, or null when this gateway serves no sign-in. See the constructor.
  final UserResolver? accounts;

  /// What a session with nobody signed in holds. See the constructor.
  final Set<AccessGroup> Function()? anonymous;

  /// The identity a credential-less hello is admitted as, built fresh so the
  /// group set is whatever the source says **now**.
  ///
  /// Built per call rather than cached: the source reads a row an operator can
  /// edit while the gateway runs, and a cached identity would keep admitting
  /// panels on the grants that row held at boot. Direct mode has the same
  /// property by construction — it reads the row at the moment it builds the
  /// session — and `AccessSession.anonymous` asks callers to do exactly that.
  StationIdentity anonymousIdentity() => StationIdentity.anonymous(
        groups: anonymous?.call() ?? const {},
        station: station,
      );

  /// The station string an anonymous session speaks for. Self-naming: it
  /// reaches close reasons, logs and audit rows, and must never read as a
  /// station somebody configured.
  ///
  /// There is nothing better available. A station label is what a credential
  /// carries, and this session presented none — the hello's `client` PeerInfo
  /// is the panel's own claim about itself and grading or attributing on a
  /// self-declared name is exactly what the credential mechanism exists to
  /// prevent. So an anonymous action's trail row names the state rather than a
  /// machine, and tracing it back to a panel is the socket's business, not the
  /// trail's.
  static const String station = 'no-station-signed-in';

  @override
  Future<TokenVerdict> validate(HelloParams params) async {
    final token = params.token;
    if (token == null || token.isEmpty) {
      // The admission this class exists for. No digest: no credential was
      // presented, and a digest here would be a claim about a secret that
      // does not exist.
      //
      // Not `const` any more, and that is the change: the identity carries a
      // group set read from the database at this instant, so what an
      // unauthenticated panel may do is the master system's live answer
      // rather than a compile-time one.
      return TokenAccepted(anonymousIdentity());
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
    if (identity.isAnonymous) {
      // **Retired when the row CHANGES, never merely for being anonymous.**
      //
      // This used to `return true` unconditionally, and the comment defending
      // it said that was "the same posture a station session has". It is the
      // opposite of what the two arms below and `file_token_validator.dart`
      // do: both re-resolve on every tick, compare the whole row and the
      // group set, and answer false on any change so the sweep closes the
      // session with 4001. Only anonymous was frozen, and the parallel that
      // justified it did not exist.
      //
      // Freezing also put the wire at odds with the panel. Direct mode
      // re-grades a sitting anonymous session in place
      // (`lib/providers/access.dart`'s `refreshGroupsFromRoles`, the
      // `!session.isElevated` arm), so a site that pulled `operate` from the
      // anonymous row to stop a walk-up panel being misused saw the panels
      // narrow and every socket keep writing. The 2026-09-16 rule is that
      // both transports answer the same question the same way.
      //
      // **A close and not a re-grade**, which is `key_policy.dart`'s own
      // mechanism: authorization is static per session precisely because
      // nothing re-consults the policy mid-stream — `TickEngine` fans out
      // from listeners attached at subscribe time, and the read floor is
      // asked at subscribe. Swapping the group set under a live session
      // would leave subscriptions admitted under `operate` still streaming
      // past a withdrawn floor, with no signal the client could act on. A
      // close is the one move the machinery already has.
      //
      // What the operator sees: one blink within a poll. The tick refreshes
      // the account cache *before* the sweep, so the re-hello mints the
      // narrowed identity, its resync subscribe is refused with the
      // `awaiting_sign_in` marker, and the client holds the socket on its
      // sign-in screen — the same experience a demoted signed-in person
      // already gets.
      //
      // The original concern stands and is answered: closing a sign-in
      // screen once per tick would make the gateway unusable, and an
      // unchanged row never closes anything. A database blink cannot trigger
      // it either — the account cache keeps its previous snapshot on a failed
      // refresh, so the sets compare equal.
      final now = anonymous?.call();
      if (now == null) return true;
      return sameGroups(now, identity.session.groups);
    }
    if (credentialDigest == null) {
      // The third provenance: a **signed-in person**, minted by the
      // `session.login` handler after a server-side Argon2id verification.
      // No credential is at rest anywhere — increment C's open decision —
      // so there is no digest; what there is instead is the account row,
      // and the row is re-resolved live and compared WHOLE, exactly the
      // judgement `FileTokenValidator.stillValid` makes past its digest
      // lookup: a deleted account is a revocation, a re-roled or re-marked
      // one would mint a different identity now, and a group unticked on
      // the role retires the session on the next tick (the 4001 property,
      // for people).
      final resolve = accounts;
      if (resolve == null) {
        // Fail closed: a gateway serving no sign-in cannot have minted a
        // digest-less identity, and a sweep that answered "still fine"
        // would keep alive a session whose provenance nothing can explain.
        return false;
      }
      final ResolvedUser? resolved;
      try {
        resolved = resolve(identity.user.username);
      } on Object {
        // Unreachable is not revoked, and this runs on a poll against
        // every live session — the file validator's exact asymmetry, for
        // its exact reason: a blinking database must not sign the whole
        // plant out.
        return true;
      }
      if (resolved == null) return false;
      if (resolved.user != identity.user) return false;
      final held = identity.session.groups;
      return resolved.groups.length == held.length &&
          resolved.groups.containsAll(held);
    }
    final delegate = stations;
    if (delegate == null) {
      // Fail closed: with no file there is no way this validator minted the
      // digest-carrying identity being asked about.
      return false;
    }
    return delegate.stillValid(identity, credentialDigest);
  }
}
