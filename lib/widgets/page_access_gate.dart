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
import 'package:tfc_dart/core/access/access_repository.dart';

import '../access_routes.dart';
import '../providers/access.dart';
// `kSessionWhileLoading` only — the single definition of the session a guard
// resolves on while `accessSessionProvider` is still loading. Imported rather
// than re-declared so the boot window has one answer across the write guards
// and this one; the dependency runs this way only, and nothing here is read by
// `access_policy.dart`.
import '../providers/access_policy.dart' show kSessionWhileLoading;
import 'access_gate.dart';
import 'access_sign_in_dialog.dart';
import 'base_scaffold.dart';

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
/// could give. `routeAllowedWhenRepositoryUnavailable` is the single place
/// that knows which path it is, and asking it here is what keeps the menu,
/// the badge and the gate agreeing in every repository state.
///
/// **The boot and outage window resolves unfiltered**, via
/// [kSessionWhileLoading], whose `allowedPages` is null. The reasoning is the
/// same one `AccessRepository.anonymousRole` makes for falling back to the
/// seeded groups: a panel that blanks every page because the session has not
/// resolved yet — which on a cut database link is tens of seconds — reads as
/// broken, and the write guards still refuse whatever is on screen. Note this
/// only ever applies to a page the group gate already let through, because a
/// raised page resolves `waiting` above and never reaches this line.
AccessGateState resolvePageAccess({
  required AccessGroup group,
  required String path,
  required AsyncValue<AccessRepository?> repository,
  required AsyncValue<AccessSession> session,
}) {
  final byGroup = resolveAccessGate(
    group: group,
    repository: repository,
    session: session,
    allowWhenRepositoryUnavailable: routeAllowedWhenRepositoryUnavailable(path),
  );
  if (byGroup != AccessGateState.allowed) return byGroup;

  // The one route the whitelist may not touch. Asked here rather than at the
  // two call sites so the menu filter and the gate cannot come to different
  // answers about it — see `routeExemptFromPageWhitelist`, which is where the
  // reasoning lives.
  if (routeExemptFromPageWhitelist(path)) return AccessGateState.allowed;

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

/// The page a whitelist hides: what happened, and the one thing that might
/// change it.
///
/// Never a dead end and never an error — the same rules `AccessLockedBody`
/// follows. It carries no "request access" and no "go back": the app bar and
/// the navigation bar are both present (the gate brings its own scaffold), so
/// leaving is already possible, and there is nobody in this build to request
/// access from.
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
                    session.roleName,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: secondary,
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
    final repository = ref.watch(accessRepositoryProvider);
    final session = ref.watch(accessSessionProvider);

    final state = resolvePageAccess(
      group: group,
      path: path,
      repository: repository,
      session: session,
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
          repository: repository,
          session: session,
          allowWhenRepositoryUnavailable:
              routeAllowedWhenRepositoryUnavailable(path),
        );
        return BaseScaffold(
          title: title,
          body: byGroup == AccessGateState.denied
              ? AccessLockedBody(group: group, openSignIn: openSignIn)
              : PageNotAvailableBody(openSignIn: openSignIn),
        );
      case AccessGateState.waiting:
        return BaseScaffold(
          title: title,
          body: const Center(
            child: CircularProgressIndicator(key: kAccessGateWaitingKey),
          ),
        );
    }
  }
}
