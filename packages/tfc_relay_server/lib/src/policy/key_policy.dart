/// Which tags a station may see, and which it may actuate.
///
/// **Source: 06-CONTEXT decision 2**, which records the user's framing as the
/// reason this file exists at all: *"What if it should be hidden. Let's think
/// about the future even though we don't implement all at once."* So the seam
/// ships now and the hiding data does not. The shipped implementation is
/// [AccessPolicyKeyPolicy] — everything visible, and every write question
/// forwarded to `AccessPolicy`.
///
/// ## This file is an adapter. It states no rule.
///
/// Phase 17's constitution, from the user: *"I dont want duplication, and I
/// would like that there would be one master access control system, the
/// websocket can build on top of that"*. The rule "a tag write needs `operate`"
/// is therefore **not written here**. It is written once, in
/// `AccessPolicy.groupForTag`'s operate floor, and this file asks. What used to
/// be here — a comparison of the identity's role against one value of a
/// two-valued enum this package declared itself — was the second copy, and it
/// disagreed with the first in both directions (17-CONTEXT D-03, D-04).
///
/// ## What breaks in the plant without this file
///
/// A wall display in the canteen can start a conveyor. A station is a username
/// in a token file with nothing behind it until the database says who that is
/// and what its role may do, and this interface is where the wire asks
/// (T-06-35).
///
/// The quieter half is [canSee]. A gateway that answers *forbidden* for a tag
/// a station may not see has told that station the tag exists; ask about a
/// thousand names, keep the ones answered *forbidden* instead of *unknown*,
/// and the plant's address space has been enumerated by a peer that may not
/// read a byte of it (T-06-36). CONTEXT locks the answer as architecture: a
/// hidden key is **indistinguishable from a key that does not exist**. That is
/// why [canSee] is a visibility question and not a permission question — there
/// is no "you may not see this" answer on the wire, only "this source does not
/// serve that tag".
///
/// ## All three members are synchronous, and that is a decision
///
/// `session_handlers.dart:255-264` catches a `SubscriptionLimitExceeded` for a
/// race that is unreachable today — there is no `await` between the
/// `atCapacity` check and the `put` — and its comment names *this phase* as
/// "the obvious thing to introduce the await that opens the race". An
/// asynchronous policy is exactly that `await`. The cost of opening it is not
/// theoretical: a subscription that slipped past a full ceiling surfaces as
/// `-32011 handlerFailed`, whose documented meaning is "possibly transient:
/// retrying is legitimate", so a panel would retry a limit it can never get
/// under.
///
/// There is nothing here to await. Every question is a switch over constants
/// plus a set membership test, and the group set the identity is carrying was
/// resolved once, at `hello`, from a user cache the same reload refreshes the
/// token set from (`file_token_validator.dart`'s `UserResolver`). A future
/// policy that genuinely needs a directory lookup should cache into memory on
/// reload — the way the token set does — rather than make this interface
/// asynchronous. `key_policy_test.dart` pins the return types of all three
/// members by mirrors so the change cannot be made absent-mindedly.
///
/// ## The open case: a key hidden *after* subscribe
///
/// 06-RESEARCH §E.5, recorded here because this is where whoever opens it will
/// be standing. CONTEXT asks what happens to the `u` and resync frames of a
/// live subscription whose key becomes hidden. **In Phase 6 that state is
/// unreachable**, and it is unreachable structurally rather than by luck:
/// policy is static per session (the [StationIdentity] is minted once, in
/// `_hello`, and `relay_session.dart` assigns it with `??=` so it cannot be
/// replaced),
/// and the only thing that changes a live session's authorization is
/// revocation — which does not re-evaluate anything, it closes the session
/// with `CloseCodes.authExpired`. There is no live re-evaluation path, and the
/// push machinery has no arm for one: `TickEngine` fans out from
/// `SubscriptionState.watch` listeners attached at subscribe time and never
/// re-consults a key list.
///
/// So whoever adds dynamic policy — a policy that can change under a live
/// session — is opening that case, and owes it three things this phase does
/// not have: a way to drop a live subscription's handle mid-stream, a decision
/// about whether the client is told (it must not be, or the drop leaks the
/// existence the hiding rule conceals), and a resync that does not walk the
/// panel's cache backwards.
library;

import 'package:tfc_access/tfc_access.dart';

import '../auth/identity.dart';

/// Whether a station may know a key exists.
///
/// The seam this file exists for, extracted so [AccessPolicyKeyPolicy] can hold
/// it without pretending to be the thing that decides. The default answers
/// true for everything, which is the shipped behaviour: there is no hiding data
/// in the tree, and a seam that hid a tag nobody had configured would be policy
/// invented by the plumbing.
typedef KeyVisibility = bool Function(String key, StationIdentity identity);

bool _everythingIsVisible(String key, StationIdentity identity) => true;

/// The one question every key-touching surface asks about a station.
///
/// Injected at [RelayServer] construction in the style `TokenValidator` is
/// (`relay_server.dart:141`), so a deployment supplies its own and a test
/// supplies one that hides a tag. It is consulted through
/// `PolicyStateMan` — one decorator per session, between the handlers and
/// the shared source — rather than at each call site, which is the property
/// that keeps a handler added in Phase 10 from being able to forget it
/// (T-06-38).
///
/// Deliberately **not** a member of `StateManApi` or any of its four
/// sub-interfaces (06-CONTEXT amendment 3). `api_surface_test.dart:213-226`
/// calls that 49-member set "the access-control policy" — capability there is
/// defined by surface — so an access-control *query* on it would be the thing
/// it guards asking itself for permission. The seam is server-side, and this
/// package is downstream of the protocol package, so the mistake is not
/// expressible.
abstract interface class KeyPolicy {
  /// Whether [identity] may know that [key] exists.
  ///
  /// A false answer means the key is **absent**, not refused: it is filtered
  /// out of `keys`, which is the one getter `read`, `readFresh`, `readMany`,
  /// `subscribe` and `write` all already gate on, so a hidden tag takes the
  /// nonexistent-tag path on every one of them without any of them being
  /// edited (06-RESEARCH §E.2). Answering "forbidden" instead is the
  /// information disclosure the hiding rule exists to prevent.
  bool canSee(String key, StationIdentity identity);

  /// Whether [identity] may actuate [key].
  ///
  /// Only ever asked about a key [canSee] has already allowed — the existence
  /// check runs first on the write path, so a hidden key is refused as
  /// nonexistent and never reaches this question. That ordering is what keeps
  /// the two refusals from leaking into each other, and `value_handlers.dart`
  /// carries it as a comment beside the gate.
  ///
  /// **This one answer gates both `write` and `holdToRun`** (orchestrator
  /// ruling OQ5). A hold-to-run engage is reached only through
  /// `write(hold: true)` (`value_handlers.dart:541-556`) — there is no second
  /// wire method — so one check covers both today. The obvious future split is
  /// a third member, `canHold`, for a deployment that lets a station change a
  /// setpoint but not jog a machine by hand; it is deliberately not built,
  /// because a member with no policy data behind it is a name pretending to be
  /// a rule.
  ///
  /// **[canWritePreference] is not that mistake, and the difference is the
  /// data.** A hypothetical `canHold` would have had none. This one has
  /// `kPrefAccessRules` behind it the day it lands — thirty-four rules the app
  /// has been enforcing since Phase 3.
  bool canWrite(String key, StationIdentity identity);

  /// Whether [identity] may write the **preference** [key].
  ///
  /// The third member, and what sweep §3.12 point 1 said closing would need.
  /// Before it, every `preferences.set*` frame asked the same single question
  /// this interface's [canWrite] asked about a motor setpoint — so a station
  /// the gateway called `operate` could `setString('key_mappings', …)` over the
  /// pipe and re-point the plant's tag map for every panel on the site, while
  /// an operator standing at a panel holding the same grade could not. Same
  /// rows, same table, same Postgres, two answers.
  ///
  /// **Graded by key, from the app's own table.** D-03, ruled 2026-09-07: the
  /// app's `kPrefAccessRules` wins everywhere and there is no per-key
  /// exception. Keeping `key_mappings` at the tag floor was put to the user
  /// with its cost and declined, precisely because it would have kept the
  /// divergence alive in the one place it bites most often. The accepted cost
  /// is that a station whose role holds only the write floor can no longer save
  /// key mappings over the WebSocket; engineering panels are provisioned with a
  /// role that carries the higher grade.
  ///
  /// Separate from [canWrite] rather than folded into it because the two
  /// surfaces genuinely grade differently — the same string is one group as a
  /// tag and another as a preference key — and because the surface name is what
  /// travels into the audit row beside the answer.
  bool canWritePreference(String key, StationIdentity identity);
}

/// Everything is visible; every write question is forwarded to [AccessPolicy].
/// **The shipped policy.**
///
/// Named for what it does rather than for what it lacks, which is
/// `PermissiveTokenValidator`'s argument and holds for the same reason: a
/// deployment still running this in Phase 12 must be legible in a config diff.
/// `NoPolicy` or `DefaultPolicy` would read as something somebody chose.
///
/// **The rule "a tag write needs `operate`" is not stated here.** It is stated
/// once, in `AccessPolicy.groupForTag`'s operate floor, and this class asks.
/// That sentence is the whole point of Phase 17 and the reason this class
/// replaced `AllVisibleOperatorWrites`, whose `canWrite` compared the
/// identity's role against one value of a two-valued enum — a second copy of
/// the rule, in a role vocabulary the master system did not share, which
/// disagreed with the app in both directions.
///
/// Both answers stay honest rather than generous. Everything *is* visible —
/// there is no hiding data in the tree, and [visibility] defaults to saying so
/// rather than inventing a rule the plumbing would then own. And the write
/// answers are whatever the master policy says, which is the strongest form of
/// "no opinion" this class can have.
final class AccessPolicyKeyPolicy implements KeyPolicy {
  /// [policy] defaults to a bare [AccessPolicy]: no tag bindings, no route
  /// table. That is the shipped answer for the relay today — 17-11 injects the
  /// composed one — and it is not a fail-open, because `groupForTag` floors at
  /// `AccessGroup.operate` for an unbound key by the 2026-09-02 ruling.
  const AccessPolicyKeyPolicy({
    AccessPolicy policy = const AccessPolicy(),
    KeyVisibility visibility = _everythingIsVisible,
  })  : _policy = policy,
        _visibility = visibility;

  final AccessPolicy _policy;
  final KeyVisibility _visibility;

  /// True for every key under the shipped configuration.
  ///
  /// Written as a call into an injected lookup rather than as `=> true` so the
  /// seam this file exists for is still a seam — `key_policy_test.dart` drives
  /// a hiding lookup through it, which is the only way "the member is
  /// consulted" can be a claim that fails.
  @override
  bool canSee(String key, StationIdentity identity) =>
      _visibility(key, identity);

  /// Asks the master policy what writing this tag requires, then asks the
  /// session whether it holds that.
  ///
  /// [AccessSurface.tag]'s wire name rather than the literal `'tag'`, because
  /// it is the same string a `PolicyStateMan` audit row records in its
  /// `surface` column: the group that was checked and the surface that was
  /// recorded cannot disagree if there is only one place the name comes from.
  @override
  bool canWrite(String key, StationIdentity identity) => identity.session
      .can(_policy.groupForWireSurface(AccessSurface.tag.wireName, key));

  /// Asks the master policy what writing this preference key requires.
  ///
  /// `groupForPref` rather than `groupForWireSurface` with the `pref` name: the
  /// two are the same answer (the wire switch delegates), and naming the
  /// specific member here says that this surface has no open operation to
  /// collapse. See [KeyPolicy.canWritePreference] for the ruling.
  @override
  bool canWritePreference(String key, StationIdentity identity) =>
      identity.session.can(_policy.groupForPref(key));
}
