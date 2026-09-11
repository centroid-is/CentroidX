/// The route gate: one decision, taken in one place, in front of a page.
///
/// This is the phase's only enforcement point. Putting it at the route rather
/// than inside each page means a menu tap, a deep link and a stored startup
/// path all meet the same gate, and a page that forgets to ask is not a hole.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../core/access_authority.dart';
import '../providers/access.dart';
import '../providers/gateway_link.dart';
import 'access_sign_in_dialog.dart';
import 'base_scaffold.dart';

/// What the gate does with a route: show it, lock it, or show neither yet.
enum AccessGateState {
  /// Build the child. Nothing is added around it.
  allowed,

  /// Show the locked page — which explains what is missing and offers a
  /// sign-in. Never an error.
  denied,

  /// Neither the page nor the lock: something the decision depends on has not
  /// resolved yet.
  waiting,
}

/// Whether [group] may be opened, given what the two access providers currently
/// say.
///
/// Pure on purpose: no `BuildContext`, no `ref`, no widgets. The
/// no-authority half of this rule is the part of the phase that is easiest to
/// get subtly wrong, and a pure function is the only version of it a truth
/// table can pin exhaustively.
///
/// The checks run in one order and the order is load-bearing: [AccessGroup
/// .operate] first, then the authority, then the session. Checking the session
/// first would let a station with nothing behind it resolve on a session that
/// has no authority behind it — a stale in-memory session claiming `configure`
/// after the database it was resolved against went away.
///
/// **[authority], not the repository.** It took an
/// `AsyncValue<AccessRepository?>` until 2026-09 and read a resolved null as
/// "nobody can be authenticated here". That is true in direct mode and false
/// on a gateway panel, where `databaseProvider` returns null by design and the
/// credential is verified server-side over the socket — so every raised route
/// was denied there no matter who signed in, and the navigation menu (which
/// hides what this function denies) dropped the whole `/advanced` section from
/// under a signed-in engineer. The function never looked at the repository
/// object, only at whether one existed; [AccessAuthority] is that question
/// asked honestly, and it makes the state "gateway mode WITH a local
/// repository" — impossible in production — unrepresentable here too.
///
/// **No authority, one door opens.** With [AccessAuthority.none], `signIn` can
/// only answer `AccessSignInResult.unavailable` (`lib/providers/access.dart`),
/// so a locked Server Config would be a sign-in prompt that cannot be passed,
/// guarding the page where the database is configured. That is true whether the
/// station was never configured or somebody mistyped the Postgres IP and saved
/// — and the second is the case that matters, because without this a typo turns
/// into an on-site recovery. `PROJECT.md` is explicit that the realistic failure
/// here is accident and shift confusion, not a malicious insider. So
/// [allowWhenNobodyCanSignIn] is passed true for exactly one route
/// (`kServerConfigRoute`) and false everywhere else.
///
/// **No authority, the other five stay shut.** The argument above is entirely
/// about reaching the database configuration page. It says nothing about Page
/// Editor, Alarm Editor, Key Repository, IP Settings or Preferences —
/// `centroid-hmi/lib/navigation.dart:48-50` already calls those surfaces that
/// store secrets — and an outage is a state a commissioned station enters
/// mid-shift, inducible from a Save button. Opening them would hand every gated
/// route to whoever is standing at the panel for the length of it.
///
/// **[AccessAuthority.relay] is an authority, so the session decides.** A
/// gateway panel holds no user table and invents nothing: the backend verifies
/// the credential and answers with the user, role and groups, and the session
/// that results is per-run — never persisted, never restored (`_isGateway` in
/// `lib/providers/access.dart`). The stale-session hazard the ordering exists
/// to stop therefore cannot arise on a relay authority: every elevated gateway
/// session in memory was minted by the server during this run.
///
/// **The Server Config exemption does NOT fire on a healthy relay, and that
/// is the whole of [relayCanAuthenticate].** For one revision it did: the
/// exemption was keyed on "no local repository", which a gateway panel
/// satisfies *for its whole life* — `databaseProvider` returns before reading
/// a row whenever the transport is gateway — so a condition written for a
/// transient Postgres outage became a permanent open door on every gateway
/// panel, on the one page that edits the transport, the gateway address, the
/// database settings and every PLC endpoint. Server Config was reachable at a
/// gateway panel with nobody signed in.
///
/// The argument that put it there was not wrong, only asked of the wrong
/// witness. It said the panel cannot tell a healthy gateway from a mistyped
/// URL, because `relaySignIn` exists whenever a client was *constructed* —
/// which is exactly the state a wrong URL leaves. True of `relaySignIn`, and
/// false of the panel: `gatewayLinkProvider` has told it apart since phase 15,
/// in seven kinds. [relayCanAuthenticate] is that report reduced to the one
/// bit this function needs (`gatewayLinkCanAuthenticate`), and it makes the
/// exemption fire on the honest condition — **nobody can sign in here** —
/// rather than on "there is no local repository", which was only ever a proxy
/// for it and stopped being one.
///
/// So a reachable gateway gates Server Config on `administer` like every other
/// raised route, and a gateway that cannot carry a credential opens it, which
/// is the mistyped-URL recovery the paragraph above is about. The recovery
/// arrives about fifteen seconds later than it used to — the patience window
/// `describeGatewayLink` spends before it will call a link unreachable — and
/// that is the entire cost of closing the door.
///
/// **Loading is neither.** `AsyncLoading` is [AccessGateState.waiting], so a
/// slow connection is never mistaken for a missing one. That matters more for
/// [authority] than it did for the repository: `NavDropdownState` HIDES what
/// this function denies, and the authority is unresolved for a moment on every
/// boot while the device-local transport row is read.
///
/// **The cost, accepted deliberately:** an unreachable database leaves Server
/// Config reachable by anyone at the panel, so someone could repoint the station
/// at a Postgres they control holding a known Engineering account and sign in.
/// That takes physical access to the panel plus a prepared server, and physical
/// access already defeats this milestone by design — spec §8, anyone with
/// UaExpert or `psql` walks around every guard. Bricking a plant's station over
/// a typo is the likelier and worse failure.
///
/// The parameter is named for the condition it enforces, and has now been
/// wrong in both directions. `allowWhenUnconfigured` claimed a condition
/// narrower than the code enforced; `allowWhenRepositoryUnavailable` claimed
/// one broader than the code should ever have enforced, and that name is what
/// made a permanent gateway exemption read as a database outage. It fires when
/// nothing on this station can verify a credential — an absent authority, or a
/// relay authority with no link under it — and the name says exactly that.
AccessGateState resolveAccessGate({
  required AccessGroup group,
  required AsyncValue<AccessAuthority> authority,
  required AsyncValue<AccessSession> session,
  required bool allowWhenNobodyCanSignIn,
  bool relayCanAuthenticate = true,
}) {
  // Anonymous holds `operate`, so an unraised route must cost neither a frame
  // nor a lock — not even while the providers behind the other branches are
  // still resolving.
  if (group == AccessGroup.operate) return AccessGateState.allowed;

  // Nothing resolved yet — neither a value nor an error. Merely slow is not
  // missing.
  if (!authority.hasValue && !authority.hasError) {
    return AccessGateState.waiting;
  }

  // An error means the authority could not even be determined — the repository
  // threw rather than resolving. That is the same fact as a resolved
  // [AccessAuthority.none]: this station cannot authenticate anybody. Both are
  // gated identically for every route, exactly as they were when this function
  // held the repository itself.
  final authority0 =
      authority.hasError ? AccessAuthority.none : authority.requireValue;

  // Can anything here verify a credential? [AccessAuthority.none] says no by
  // itself. [AccessAuthority.relay] says "the gateway can" — a claim with a
  // wire under it, and [relayCanAuthenticate] is whether that wire is there.
  // [AccessAuthority.local] is the one that needs no second question: the gate
  // never looked past the repository's existence in direct mode and still does
  // not, so direct stations behave exactly as they did.
  final nobodyCanSignIn = switch (authority0) {
    AccessAuthority.none => true,
    AccessAuthority.local => false,
    AccessAuthority.relay => !relayCanAuthenticate,
  };

  // The exemption, before the session and for every authority that cannot
  // verify anybody: Server Config is where a wrong Postgres address and a
  // wrong gateway URL are both fixed, and neither can be fixed from a page
  // that demands the very sign-in it has just broken.
  if (nobodyCanSignIn && allowWhenNobodyCanSignIn) {
    return AccessGateState.allowed;
  }

  // Nothing can verify a credential here, so nothing the session claims has
  // anything behind it.
  if (authority0 == AccessAuthority.none) return AccessGateState.denied;

  // An authority exists — local or relay — so a sign-in can succeed and the
  // session is the answer. Server Config's exemption is inert from here on.
  if (session.hasError) return AccessGateState.denied;
  if (!session.hasValue) return AccessGateState.waiting;
  return session.requireValue.can(group)
      ? AccessGateState.allowed
      : AccessGateState.denied;
}

/// What the locked page says, kept at the top of the file so the tests assert
/// against the string the widget renders rather than one they supply — the
/// `lib/pages/first_user.dart` idiom.
const String kAccessLockedHeadline = 'Sign in to open this page';

/// Which permission is missing, named by [AccessGroup.name] — the same word the
/// roles screen shows, so "needs configure" and the tick box that grants it
/// read alike.
String kAccessLockedGroupNote(AccessGroup group) =>
    'This page needs the "${group.name}" permission.';

/// Who is signed in, and why that is not enough. Shown instead of nothing when
/// somebody is already signed in: "sign in" is confusing advice to a person who
/// already did.
String kAccessLockedRoleNote(String who, String role, AccessGroup group) =>
    'You are signed in as $who ($role). '
    'That role does not include "${group.name}".';

/// The station has no repository behind it, so signing in cannot succeed yet.
///
/// **Names no cause on purpose.** A station that was never configured and one
/// whose Postgres will not answer are the same `AsyncData(null)` to every
/// provider here, and — now that Server Config opens in both — the next step is
/// the same either way. A line that guessed would send a commissioning engineer
/// and an operator hunting different wrong problems, which is exactly what
/// `_kNoDatabase` in `lib/pages/first_user.dart` documents.
const String kAccessLockedNoDatabaseNote =
    'This station has no reachable database, so signing in will not work '
    'until it does. The connection is set up in Server Config.';

/// The whole locked body, so a test can assert the lock rendered at all.
const Key kAccessLockedBodyKey = Key('access-locked-body');

/// The Sign in action. Present and enabled in every state, including with no
/// repository — see [AccessLockedBody].
const Key kAccessLockedSignInKey = Key('access-locked-sign-in');

/// The honesty line's key, so a test can assert the widget carrying it is not
/// the single-line ellipsising kind.
const Key kAccessLockedHonestyKey = Key('access-locked-honesty');

/// The no-database line's key. Same reason, and the same assertion.
const Key kAccessLockedNoDatabaseKey = Key('access-locked-no-database');

/// The reading width of the text column.
///
/// A 1080p panel is wide enough to stretch these sentences into single lines
/// that the eye cannot track, so the column is constrained the way
/// `FirstUserBody` constrains its own.
const double kAccessLockedMaxWidth = 480;

/// The locked page: what is missing, why signing in may not help right now, and
/// the way through.
///
/// Never an error and never a dead end. It carries no "go back", no "retry" and
/// no "request access": leaving is the app bar's and the navigation bar's job,
/// retrying is what `databaseProvider`'s own two-second timer already does, and
/// there is nobody in this build to request access from — inventing a
/// department name would be worse than naming the permission.
///
/// **No authority parameter.** This is a [ConsumerWidget] and watches
/// [accessAuthorityProvider] itself. Threading the authority down from the
/// gate would give two places that could disagree about whether a sign-in can
/// succeed, and the disagreement would show as a locked page that offers a
/// sign-in it knows cannot succeed.
///
/// It asks the authority rather than the repository for the same reason the
/// gate does: on a gateway panel there is never a repository, and telling the
/// operator "this station has no reachable database" while a relay sign-in
/// would work perfectly well is a sentence that sends them to fix the wrong
/// thing. A dead gateway link reports itself where it actually shows up — the
/// sign-in attempt, `kAccessSignInUnavailableMessage`.
class AccessLockedBody extends ConsumerWidget {
  const AccessLockedBody({
    super.key,
    required this.group,
    this.openSignIn = showAccessSignInDialog,
  });

  /// The permission this route needs. Named on the page.
  final AccessGroup group;

  /// How the sign-in prompt is opened. Injectable so a widget test can count
  /// the taps without standing up a dialog route — the
  /// `AccessStatusAction` idiom.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary =
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    final session = ref.watch(accessSessionProvider).valueOrNull;
    final authority = ref.watch(accessAuthorityProvider);

    // Unavailable is a resolved [AccessAuthority.none] or an error; still
    // loading is neither, and says nothing yet. A relay authority is emphatically
    // not this line: the station has no database and does not want one.
    final noDatabase = authority.hasError ||
        (authority.hasValue && authority.requireValue == AccessAuthority.none);

    return Center(
      key: kAccessLockedBodyKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kAccessLockedMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A lock, not a warning triangle: this page is shut, not broken.
              // `onSurfaceVariant` rather than HmiStateColors.orange, which
              // means forced/override and — since plan 01-08 — an elevated
              // session. A locked page is neither, and red is the plant's
              // fault colour.
              Icon(Icons.lock_outline, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                kAccessLockedHeadline,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                kAccessLockedGroupNote(group),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              if (session != null && session.isElevated) ...[
                const SizedBox(height: 12),
                Text(
                  kAccessLockedRoleNote(
                    session.user!.displayName,
                    session.roleName,
                    group,
                  ),
                  textAlign: TextAlign.center,
                  style: secondary,
                ),
              ],
              if (noDatabase) ...[
                const SizedBox(height: 12),
                Text(
                  kAccessLockedNoDatabaseNote,
                  key: kAccessLockedNoDatabaseKey,
                  textAlign: TextAlign.center,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: secondary,
                ),
              ],
              const SizedBox(height: 24),
              // Enabled whatever the repository is doing. A greyed control is
              // the one thing this milestone's UI rules forbid outright: the
              // line above is how the operator is told beforehand, and
              // `kAccessSignInUnavailableMessage` is how the attempt reports
              // itself.
              ElevatedButton(
                key: kAccessLockedSignInKey,
                onPressed: () => openSignIn(context, ref),
                child: const Text('Sign in'),
              ),
              const SizedBox(height: 24),
              Text(
                kAccessSignInHonestyNote,
                key: kAccessLockedHonestyKey,
                textAlign: TextAlign.center,
                maxLines: null,
                overflow: TextOverflow.visible,
                style: secondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The waiting indicator, so a test can tell "not decided yet" from a blank
/// page and from the lock.
const Key kAccessGateWaitingKey = Key('access-gate-waiting');

/// Stands in front of a route and decides whether to show it.
///
/// **At the route, not inside the page.** A page that has to remember to ask is
/// a page that can forget, and a forgotten ask is a hole with no symptom. The
/// route is the one place a menu tap, a deep link and a stored startup path all
/// pass through, so gating there means every way in meets the same decision.
///
/// The gate knows nothing about paths, `kRaisedRoutes` or `RouteRegistry`:
/// [group] and [allowWhenNobodyCanSignIn] are handed in at the route
/// table, where the path is already spelled out. That is what lets this widget
/// land beside the route declarations without touching them, and it means the
/// gate has no way to fail open through a lookup miss.
///
/// There is no `fallback` and no `onDenied`. One behaviour, everywhere.
class AccessGate extends ConsumerWidget {
  const AccessGate({
    super.key,
    required this.group,
    required this.title,
    required this.child,
    this.allowWhenNobodyCanSignIn = false,
    this.openSignIn = showAccessSignInDialog,
  });

  /// The permission this route needs. Required with no default: a gate that
  /// could be built without one would fail open by omission.
  final AccessGroup group;

  /// The app-bar title of the locked and waiting pages. The child brings its
  /// own scaffold, so this is used only when the child is not shown.
  final String title;

  /// The page behind the gate. Not built at all while denied — a page must not
  /// run its `initState`, its queries or its subscriptions behind a lock.
  final Widget child;

  /// Whether a station where nobody can sign in opens this route. Defaults to
  /// false, so a caller that forgets it gets the strict behaviour; see
  /// [resolveAccessGate] for why exactly one route passes it true.
  ///
  /// The other half of that condition — whether a relay authority has a link
  /// under it — is not a parameter: the widget watches
  /// [relayCanAuthenticateProvider] itself, so a caller cannot pass a stale
  /// answer or a different one from the menu badge's.
  final bool allowWhenNobodyCanSignIn;

  /// How the locked page opens the sign-in prompt. Injectable for the same
  /// reason `AccessStatusAction` makes it injectable.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = resolveAccessGate(
      group: group,
      authority: ref.watch(accessAuthorityProvider),
      session: ref.watch(accessSessionProvider),
      allowWhenNobodyCanSignIn: allowWhenNobodyCanSignIn,
      // Watched, not read: a gateway that comes up under a panel showing an
      // exempt Server Config must close it again without a navigation.
      relayCanAuthenticate: ref.watch(relayCanAuthenticateProvider),
    );

    switch (state) {
      case AccessGateState.allowed:
        // Nothing wraps the child — the pages already bring their own
        // `BaseScaffold`, and a second one would double the app bar.
        //
        // This is also where signing in "re-opens the affordance without
        // replaying the original action": the session changes, `build` runs
        // again and the child appears. Nothing is pushed, popped or
        // re-navigated, so the operator is exactly where they already were,
        // and whatever they were about to do still needs doing.
        return child;
      case AccessGateState.denied:
        // A scaffold of the gate's own, so the app bar (with its sign-in
        // affordance) and the navigation bar are present: a locked page the
        // operator cannot leave would be worse than no lock.
        return BaseScaffold(
          title: title,
          body: AccessLockedBody(group: group, openSignIn: openSignIn),
        );
      case AccessGateState.waiting:
        // Not a blank page: this route was reached deliberately and an empty
        // one reads as broken. Not the child either — waiting must never be
        // mistaken for allowed.
        return BaseScaffold(
          title: title,
          body: const Center(
            child: CircularProgressIndicator(key: kAccessGateWaitingKey),
          ),
        );
    }
  }
}
