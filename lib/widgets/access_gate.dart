/// The route gate: one decision, taken in one place, in front of a page.
///
/// This is the phase's only enforcement point. Putting it at the route rather
/// than inside each page means a menu tap, a deep link and a stored startup
/// path all meet the same gate, and a page that forgets to ask is not a hole.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import '../providers/access.dart';
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
/// repository-unavailable half of this rule is the part of the phase that is
/// easiest to get subtly wrong, and a pure function is the only version of it a
/// truth table can pin exhaustively.
///
/// The checks run in one order and the order is load-bearing: [AccessGroup
/// .operate] first, then the repository, then the session. Checking the session
/// first would let an unavailable-repository station resolve on a session that
/// has no authority behind it — a stale in-memory session claiming `configure`
/// after the database it was resolved against went away.
///
/// **No repository, one door opens.** With no repository, `signIn` can only
/// answer `AccessSignInResult.unavailable` (`lib/providers/access.dart`), so a
/// locked Server Config would be a sign-in prompt that cannot be passed,
/// guarding the page where the database is configured. That is true whether the
/// station was never configured or somebody mistyped the Postgres IP and saved
/// — and the second is the case that matters, because without this a typo turns
/// into an on-site recovery. `PROJECT.md` is explicit that the realistic failure
/// here is accident and shift confusion, not a malicious insider. So
/// [allowWhenRepositoryUnavailable] is passed true for exactly one route
/// (`kServerConfigRoute`) and false everywhere else.
///
/// **No repository, the other five stay shut.** The argument above is entirely
/// about reaching the database configuration page. It says nothing about Page
/// Editor, Alarm Editor, Key Repository, IP Settings or Preferences —
/// `centroid-hmi/lib/navigation.dart:48-50` already calls those surfaces that
/// store secrets — and an outage is a state a commissioned station enters
/// mid-shift, inducible from a Save button. Opening them would hand every gated
/// route to whoever is standing at the panel for the length of it.
///
/// **Loading is neither.** `AsyncLoading` is [AccessGateState.waiting], so a
/// slow connection is never mistaken for a missing one.
///
/// **The cost, accepted deliberately:** an unreachable database leaves Server
/// Config reachable by anyone at the panel, so someone could repoint the station
/// at a Postgres they control holding a known Engineering account and sign in.
/// That takes physical access to the panel plus a prepared server, and physical
/// access already defeats this milestone by design — spec §8, anyone with
/// UaExpert or `psql` walks around every guard. Bricking a plant's station over
/// a typo is the likelier and worse failure.
///
/// The parameter is named for the condition it enforces. It is deliberately not
/// `allowWhenUnconfigured`: it fires on *any* unavailable repository,
/// unconfigured or unreachable alike, and a name claiming the narrower condition
/// would be the same defect class as a mitigation sentence that describes its
/// own hole. There is likewise no provider anywhere in this phase that
/// distinguishes the two causes — under this ruling it would discriminate
/// nothing.
AccessGateState resolveAccessGate({
  required AccessGroup group,
  required AsyncValue<AccessRepository?> repository,
  required AsyncValue<AccessSession> session,
  required bool allowWhenRepositoryUnavailable,
}) {
  // Anonymous holds `operate`, so an unraised route must cost neither a frame
  // nor a lock — not even while the providers behind the other branches are
  // still resolving.
  if (group == AccessGroup.operate) return AccessGateState.allowed;

  // Nothing resolved yet — neither a value nor an error. Merely slow is not
  // missing.
  if (!repository.hasValue && !repository.hasError) {
    return AccessGateState.waiting;
  }

  // An error means the repository could not even be constructed, which is the
  // same fact as a resolved null: this station cannot authenticate anybody.
  // Both are gated identically for every route.
  final repository0 = repository.hasError ? null : repository.requireValue;
  if (repository0 == null) {
    return allowWhenRepositoryUnavailable
        ? AccessGateState.allowed
        : AccessGateState.denied;
  }

  // A repository exists, so a sign-in can succeed and the session is the
  // authority — including for Server Config, whose exemption is inert from
  // here on.
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
/// **No repository parameter.** This is a [ConsumerWidget] and watches
/// `accessRepositoryProvider` itself. Threading the repository down from the
/// gate would give two places that could disagree about whether a database
/// exists, and the disagreement would show as a locked page that offers a
/// sign-in it knows cannot succeed.
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
    final repository = ref.watch(accessRepositoryProvider);

    // Unavailable is a resolved null or an error; still loading is neither, and
    // says nothing yet.
    final noDatabase = repository.hasError ||
        (repository.hasValue && repository.requireValue == null);

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
                    session.roleLabel,
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
/// [group] and [allowWhenRepositoryUnavailable] are handed in at the route
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
    this.allowWhenRepositoryUnavailable = false,
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

  /// Whether an unavailable access repository opens this route. Defaults to
  /// false, so a caller that forgets it gets the strict behaviour; see
  /// [resolveAccessGate] for why exactly one route passes it true.
  final bool allowWhenRepositoryUnavailable;

  /// How the locked page opens the sign-in prompt. Injectable for the same
  /// reason `AccessStatusAction` makes it injectable.
  final AccessSignInOpener openSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = resolveAccessGate(
      group: group,
      repository: ref.watch(accessRepositoryProvider),
      session: ref.watch(accessSessionProvider),
      allowWhenRepositoryUnavailable: allowWhenRepositoryUnavailable,
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
