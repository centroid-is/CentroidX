/// The route gate for the plant's own pages: the group it needs, and the
/// whitelist of the person standing at the panel.
///
/// `AccessGate` (`access_gate.dart`) guards the nine built-in Advanced routes,
/// which are declared with a literal group at the route table. This is its
/// sibling for page-manager pages, and it differs in exactly two ways:
///
/// * **It takes a path, not a group.** A page's group is whatever the page
///   editor published it for, declared into `RouteRegistry` by
///   `declareMenuRouteGroups` — there is no literal at the call site to hand
///   down.
/// * **It asks the second question too.** The group says what a page needs;
///   the whitelist says whether this audience may see this page at all. Both
///   must pass, and the group question is asked first (see
///   [resolvePageAccess]).
///
/// **This closes a hole rather than only adding a feature.** Before this
/// widget, page-manager routes were registered as a bare `AssetView`: a page
/// raised above `operate` in the page editor vanished from the menu and still
/// opened to anyone who typed its URL. Hiding was the whole of the
/// enforcement, which `docs/access-control-spec.md` §6 names as the failure
/// mode a guard beside an unenumerated hole has. A page must not be reachable
/// by a route the menu refuses to show.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';
import '../core/access_authority.dart';

import '../access_routes.dart';
import '../providers/access.dart';
// `relayCanAuthenticateProvider` — whether the gateway link can actually carry
// a credential. The gate, the lock badge and the menu filter all read this one
// provider so they cannot disagree about a dead link.
import '../providers/gateway_link.dart';
import '../providers/menu.dart' show visibleMenuProvider;
// `kSessionWhileLoading` only — the single definition of the session a guard
// resolves on while `accessSessionProvider` is still loading. Imported rather
// than re-declared so the boot window has one answer across the write guards
// and this one; the dependency runs this way only, and nothing here is read by
// `access_policy.dart`.
import '../providers/access_policy.dart' show kSessionWhileLoading;
import 'access_gate.dart';
import 'access_sign_in_dialog.dart';
import 'base_scaffold.dart';
import 'nav_dropdown.dart' show beamSafelyKids;

/// Whether this session may open the page at [path].
///
/// The one function that answers the question, called by the route gate, the
/// navigation menu's filter and the lock badge. A second copy of it is how a
/// hidden page starts opening, or a visible page starts locking — the first
/// time one of the copies is edited.
///
/// **Order is load-bearing: the group gate first, always.** The whitelist is a
/// filter and never a grant, so it is consulted only once the group question
/// has already answered `allowed`. Ask it first and a page listed in somebody's
/// whitelist would open regardless of the group it was published for.
///
/// **The access screen is exempt from the whitelist half.** Every other
/// built-in under Advanced is whitelistable and is offered in the Pages
/// editor, but `/advanced/access` answers to its `users` group and nothing
/// else: it is the screen that repairs a whitelist, so a whitelist that could
/// hide it would be a station nobody can fix. `routeExemptFromPageWhitelist`
/// is the single place that knows which route that is, for the same reason
/// `routeAllowedWhenRepositoryUnavailable` is.
///
/// **The outage exemption is honoured, not hardcoded false.** No page-manager
/// page is Server Config, so for a page this always resolves false — but the
/// navigation filter asks this same function about built-in routes too, and
/// hardcoding false there hid Server Config the moment the database went
/// away. That is the one page whose whole job is getting a station out of an
/// outage, and losing it is worse than any other wrong answer this function
/// could give. [routeAllowedWhenNobodyCanSignIn] is the single place that
/// knows which path it is, and asking it here is what keeps the menu, the
/// badge and the gate agreeing in every authority state.
///
/// **An unresolved session waits; it does not guess.** Until
/// `accessSessionProvider` answers, which page-manager pages this panel may
/// show is simply not known — the whitelist lives in the database and the
/// session is what reads it. This used to resolve unfiltered, on
/// [kSessionWhileLoading], so that a slow database never blanked a panel. It
/// did not blank one; it did something worse. On a station that restricts what
/// anonymous may see, the home page rendered in full — running its `initState`,
/// its queries and its OPC UA subscriptions — for the one to two seconds the
/// Postgres connection takes, and was then replaced by a refusal. The operator
/// saw their plant page appear and be taken away, which reads as a fault in the
/// panel, and the page behind the refusal had already been built and had
/// already subscribed. Waiting is the honest answer to a question nobody has
/// answered yet, and [AccessCheckingBody] is what waiting looks like: a screen
/// that says what is happening and offers the sign-in, rather than a page that
/// will be withdrawn.
///
/// The cost is stated plainly because it is real and it is paid by every
/// station, including the ones that restrict nothing: a panel with no
/// whitelist configured now shows that screen for the length of its database
/// connect before its home page, where it used to show the page at once. That
/// is the trade this file takes deliberately — one honest screen that resolves
/// into the right thing, rather than a page that appears and is taken back —
/// and it is bounded by exactly the same connect the rest of the app already
/// waits on. It is **not** unbounded: `databaseProvider` resolves to null when
/// the connection gives up (measured at 10 012 ms on a routable host that never
/// answers — see `bootstrapPageManagerProvider`), the session then resolves on
/// the seeded floor, and the paragraph below is what opens the panel up again.
///
/// A station with **no Postgres configured at all** pays nothing: `database`
/// returns null without connecting, so the repository, the session and this
/// question all resolve inside the first frames. The cost is the connect, and
/// only a station that has one pays it.
///
/// **An errored session still resolves unfiltered**, via
/// [kSessionWhileLoading], whose `allowedPages` is null. The reasoning is the
/// one `AccessRepository.anonymousRole` makes for falling back to the seeded
/// groups: a session that has failed will not un-fail on its own, so waiting on
/// it is waiting forever, and a panel permanently stuck on a sign-in screen is
/// the failure this whole file is careful not to ship. The write guards still
/// refuse whatever is on screen. Note both halves of this only ever apply to a
/// page the group gate already let through, because a raised page resolves
/// `waiting` above and never reaches this line.
AccessGateState resolvePageAccess({
  required AccessGroup group,
  required String path,
  required AsyncValue<AccessAuthority> authority,
  required AsyncValue<AccessSession> session,
  bool relayCanAuthenticate = true,
}) {
  final byGroup = resolveAccessGate(
    group: group,
    authority: authority,
    session: session,
    allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(path),
    relayCanAuthenticate: relayCanAuthenticate,
  );
  if (byGroup != AccessGateState.allowed) return byGroup;

  // The one route the whitelist may not touch. Asked here rather than at the
  // two call sites so the menu filter and the gate cannot come to different
  // answers about it — see `routeExemptFromPageWhitelist`, which is where the
  // reasoning lives.
  if (routeExemptFromPageWhitelist(path)) return AccessGateState.allowed;

  // Neither a value nor an error: the session has not answered, so the
  // whitelist question has no answer either. See the doc above for why this
  // waits rather than resolving unfiltered.
  if (!session.hasValue && !session.hasError) return AccessGateState.waiting;

  final resolved = session.valueOrNull ?? kSessionWhileLoading;
  return resolved.pageVisible(path)
      ? AccessGateState.allowed
      : AccessGateState.denied;
}

/// The headline on a page the whitelist hides.
///
/// Deliberately **not** "Sign in to open this page", which is what the group
/// lock says. A whitelist refusal is not a missing permission — it is a page
/// this audience was not given — and telling somebody to sign in would send
/// them hunting for a credential that changes nothing. Signing in *can* help,
/// because a different account may carry a different whitelist, which is why
/// the button is still there; the headline just does not promise it.
const String kPageNotAvailableHeadline = 'This page is not available';

/// Why, without naming a permission there is none of.
const String kPageNotAvailableNote =
    'It has not been published to the pages this panel is set up to show.';

/// Who is signed in, and that it is their role rather than their credentials
/// that decides. Shown when somebody is already signed in, for the same reason
/// `kAccessLockedRoleNote` is.
String kPageNotAvailableRoleNote(String who, String role) =>
    'You are signed in as $who ($role). '
    'That identity is not set up to see this page.';

/// Told to whoever can fix it, in the words of the screen that fixes it.
const String kPageNotAvailableFixNote =
    'Pages are assigned to roles and accounts under Advanced → Access.';

/// The body's key, so a test can tell this refusal from the group lock.
const Key kPageNotAvailableBodyKey = Key('page-not-available-body');

/// The Sign in action on the not-available body.
const Key kPageNotAvailableSignInKey = Key('page-not-available-sign-in');

/// The heading over the pages this session *can* open.
///
/// Phrased as an offer rather than an apology: the operator is standing on a
/// refusal and the useful next sentence is where they may go instead.
const String kPageNotAvailableElsewhereHeadline = 'Pages you can open';

/// The offered destinations, so a test can find them as a group.
const Key kPageNotAvailableDestinationsKey =
    Key('page-not-available-destinations');

/// How many destinations the refusal lists before it stops.
///
/// A bound rather than a scroll: this is a way out, not a second menu, and the
/// navigation bar under it holds the whole of it. Six fits two rows on a panel
/// without pushing the sign-in button off the bottom.
const int kPageNotAvailableMaxDestinations = 6;

/// The page a whitelist hides: what happened, and the one thing that might
/// change it.
///
/// Never a dead end and never an error — the same rules `AccessLockedBody`
/// follows. It carries no "request access" and no "go back": there is nobody
/// in this build to request access from, and back is wherever the operator
/// already was.
///
/// **It does carry the pages this session can open**, and that is a repair
/// rather than a decoration. "Leaving is already possible because the gate
/// brings its own scaffold" was true only while the navigation bar was on it,
/// and a session whitelisted down to pages inside one section used to get no
/// bar at all — a refusal screen with nothing on it but a sign-in button that
/// the operator's own account will not change. The bar is fixed
/// (`VisibleMenu.showsBar`), and the destinations are named here as well
/// because this is where the operator is looking, because the bar is
/// suppressed in fullscreen, and because a lone section in the bar is a
/// dropdown nobody has a reason to suspect is a dropdown.
///
/// **It does not redirect.** Landing the session on the first page it can open
/// was the other candidate and is the wrong one for the same reason
/// `resolveStartupPath` refuses to ask the permission question: a panel that
/// silently substitutes a different page for the one somebody asked for hides
/// the misconfiguration that put them there, and a deep link or an alarm jump
/// would quietly land somewhere else. The refusal is honest and the way out is
/// one tap; that is the trade.
class PageNotAvailableBody extends ConsumerWidget {
  const PageNotAvailableBody({
    super.key,
    this.openSignIn = showAccessSignInDialog,
  });

  /// How the sign-in prompt is opened. Injectable so a widget test can count
  /// the taps without standing up a dialog route — the `AccessStatusAction`
  /// idiom.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary =
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final session = ref.watch(accessSessionProvider).valueOrNull;

    // The same list the navigation bar is built from, one level deeper. Asked
    // of `visibleMenuProvider` rather than of the session's whitelist directly,
    // so a page this station cannot route, or one the group gate still holds
    // shut, is never offered here as a way out.
    //
    // The refused page cannot appear in it: it is refused by the very filter
    // this list comes out of.
    final elsewhere = ref.watch(visibleMenuProvider).reachablePages;

    return Center(
      key: kPageNotAvailableBodyKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kAccessLockedMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Not a lock and not a warning triangle. This page is not shut
              // against this person, it is simply not one of theirs — and it
              // is certainly not broken. `onSurfaceVariant` for the same reason
              // the locked page uses it: orange means forced/override and red
              // is the plant's fault colour.
              Icon(Icons.visibility_off_outlined,
                  size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                kPageNotAvailableHeadline,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                kPageNotAvailableNote,
                textAlign: TextAlign.center,
                maxLines: null,
                overflow: TextOverflow.visible,
                style: theme.textTheme.bodyLarge,
              ),
              if (session != null && session.isElevated) ...[
                const SizedBox(height: 12),
                Text(
                  kPageNotAvailableRoleNote(
                    session.user!.displayName,
                    session.roleLabel,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: secondary,
                ),
              ],
              // Where this session may go, before the sign-in button rather
              // than after it: the operator almost certainly has somewhere to
              // be, and signing in is the fallback rather than the answer.
              //
              // Nothing at all when the list is empty — an account that can
              // open no page is a configuration fault, and an empty heading
              // promising destinations there are none of is worse than the
              // refusal on its own.
              if (elsewhere.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  kPageNotAvailableElsewhereHeadline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  key: kPageNotAvailableDestinationsKey,
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item
                        in elsewhere.take(kPageNotAvailableMaxDestinations))
                      OutlinedButton.icon(
                        onPressed: () => beamSafelyKids(context, item),
                        icon: Icon(item.icon, size: 18),
                        label: Text(item.label),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              // Present and enabled, as on the locked page. A different account
              // can carry a different whitelist, so this is not a button that
              // cannot help — it is just not promised to.
              ElevatedButton(
                key: kPageNotAvailableSignInKey,
                onPressed: () => openSignIn(context, ref),
                child: const Text('Sign in'),
              ),
              const SizedBox(height: 24),
              Text(
                kPageNotAvailableFixNote,
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

/// Whether [session] is nobody, shown nothing: anonymous, with a whitelist that
/// admits no page at all.
///
/// The one case where the whitelist refusal should lead with the sign-in
/// rather than with "this page is not available". That sentence is written
/// for a page somebody was not given; when *no* page was given and nobody has
/// signed in, the page is not the point — the panel shows nothing to anyone
/// who is not signed in, and the one thing worth doing is signing in. A
/// gateway client that presented no credential lands here on every boot
/// (`access.dart`, `_anonymousSession`), and a browser is always such a
/// client, so this is a browser's first frame.
///
/// Not a grant and not a widening: the gate has already refused, and this
/// only chooses which refusal to show. An elevated session with an empty
/// whitelist is *not* this case — somebody did sign in, and telling them to
/// sign in is the confusion [kPageNotAvailableRoleNote] exists to avoid.
bool anonymousSeesNothing(AccessSession? session) =>
    session != null &&
    !session.isElevated &&
    session.allowedPages != null &&
    session.allowedPages!.isEmpty;

/// The headline over a panel that shows nothing until somebody signs in.
///
/// The same words as [kAccessCheckingHeadline], deliberately: both screens
/// ask for the same act. What differs is the line under it — that one says
/// the panel has not finished deciding, this one says it has.
const String kAccessSignInFirstHeadline = 'Sign in to this panel';

/// Why the sign-in comes first: not a missing permission, not an unpublished
/// page — nobody is signed in, and this panel shows no pages to anyone who is
/// not. True at a walk-up station whose `anonymous` row lists no pages, and
/// true in a browser, which the gateway admits as nobody until it signs in.
const String kAccessSignInFirstNote =
    'Nobody is signed in, and this panel shows no pages until somebody is.';

/// The body's key, so a test can tell this refusal from the other two.
const Key kAccessSignInFirstBodyKey = Key('access-sign-in-first-body');

/// The Sign in action on it.
const Key kAccessSignInFirstSignInKey = Key('access-sign-in-first-sign-in');

/// The refusal a panel shows when nobody is signed in and nothing is shown to
/// nobody: the sign-in, first and alone.
///
/// No destinations — there are none, by definition of the case — and no fix
/// note naming the access screen: the person in front of this is an operator
/// about to sign in, or a browser that just opened, and neither is the
/// administrator that sentence addresses.
class AccessSignInFirstBody extends ConsumerWidget {
  const AccessSignInFirstBody({
    super.key,
    this.openSignIn = showAccessSignInDialog,
  });

  /// How the sign-in prompt is opened. Injectable for tests, the
  /// `AccessStatusAction` idiom.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      key: kAccessSignInFirstBodyKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kAccessLockedMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The sign-in glyph, as on the checking body, and for the same
              // reason: it is what the headline asks for. Not the padlock —
              // nothing has been refused *to this person*; there is no person
              // yet.
              Icon(Icons.login, size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                kAccessSignInFirstHeadline,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                kAccessSignInFirstNote,
                textAlign: TextAlign.center,
                maxLines: null,
                overflow: TextOverflow.visible,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                key: kAccessSignInFirstSignInKey,
                onPressed: () => openSignIn(context, ref),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stands in front of a page-manager route and decides whether to show it.
///
/// Built for every page route, including the ones nothing has ever restricted.
/// That costs nothing on an unrestricted station: [resolvePageAccess] short-
/// circuits on `AccessGroup.operate` before anything is read, and a session
/// with no whitelist answers [AccessSession.pageVisible] true without touching
/// the database — so a station that raises no pages and configures no
/// whitelist renders exactly as it did before this widget existed, and adds
/// nothing around the child.
class PageAccessGate extends ConsumerWidget {
  const PageAccessGate({
    super.key,
    required this.path,
    required this.title,
    required this.child,
    this.openSignIn = showAccessSignInDialog,
  });

  /// The page's route path. Both questions are keyed on it: the group comes
  /// from [accessGroupForRoute], the whitelist is a set of these.
  final String path;

  /// The app-bar title of the refused and waiting pages. The child brings its
  /// own scaffold, so this is used only when the child is not shown.
  final String title;

  /// The page behind the gate. **Not built at all while refused** — a page
  /// must not run its `initState`, its queries or its OPC UA subscriptions
  /// behind a refusal, which is the rule `AccessGate` states and the reason
  /// this is a `child` rather than a builder that always runs.
  final Widget child;

  /// How the refusal bodies open the sign-in prompt. Injectable for tests.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = accessGroupForRoute(path);
    final authority = ref.watch(accessAuthorityProvider);
    final session = ref.watch(accessSessionProvider);
    // The same provider `AccessGate` and the lock badge watch. A page gate
    // that decided the gateway link's health for itself would refuse Server
    // Config while the badge drew it open.
    final relayCanAuthenticate = ref.watch(relayCanAuthenticateProvider);

    final state = resolvePageAccess(
      group: group,
      path: path,
      authority: authority,
      session: session,
      relayCanAuthenticate: relayCanAuthenticate,
    );

    switch (state) {
      case AccessGateState.allowed:
        return child;
      case AccessGateState.denied:
        // Which of the two refusals this is, asked the same way the gate asked
        // it — not re-derived. A page can be refused for its group or for the
        // whitelist, and the two say different things to the operator; getting
        // them the wrong way round would tell somebody to sign in for a
        // permission that is not what is missing.
        final byGroup = resolveAccessGate(
          group: group,
          authority: authority,
          session: session,
          allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(path),
          relayCanAuthenticate: relayCanAuthenticate,
        );
        //
        // And the whitelist refusal itself has two voices. "Not available"
        // is for a page this audience was not given; when nobody is signed in
        // and no page was given, the sign-in leads — see
        // [anonymousSeesNothing]. Same refusal, different first sentence.
        final Widget refusal;
        if (byGroup == AccessGateState.denied) {
          refusal = AccessLockedBody(group: group, openSignIn: openSignIn);
        } else if (anonymousSeesNothing(session.valueOrNull)) {
          refusal = AccessSignInFirstBody(openSignIn: openSignIn);
        } else {
          refusal = PageNotAvailableBody(openSignIn: openSignIn);
        }
        return BaseScaffold(title: title, body: refusal);
      case AccessGateState.waiting:
        // The same body `AccessGate` shows, for the same reason: this is the
        // screen a restricted panel now boots on, so it must be one an
        // operator can act from rather than a spinner they can only stare at.
        return BaseScaffold(
          title: title,
          body: AccessCheckingBody(openSignIn: openSignIn),
        );
    }
  }
}
