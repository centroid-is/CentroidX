/// The lock on a menu entry the session cannot open.
///
/// Advisory, never an enforcement point. `AccessGate` on the route is the
/// check (`lib/widgets/access_gate.dart`); this only tells the operator which
/// doors need a key before they walk to one. A menu that hid the entry would
/// teach them the feature does not exist, and a greyed one would teach them
/// the panel is broken — so the entry stays visible, enabled and tappable, and
/// the locked page on the other side is what offers the sign-in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../access_routes.dart';
import '../providers/access.dart';
import '../providers/gateway_link.dart';
import 'access_gate.dart';

/// A lock glyph for the menu entry at [path], and nothing at all when that
/// entry opens.
///
/// **The `operate` short-circuit comes first, before anything is watched.**
/// Every route this build does not raise answers [AccessGroup.operate], which
/// is what an anonymous session already holds, so the answer is known from the
/// path alone. That is what makes the badge free for the hundreds of ordinary
/// page entries: they neither subscribe to the session nor cause
/// `accessAuthorityProvider` to be built, and a station that raises no routes
/// renders its whole menu without ever reading the database or the station
/// keychain. It is also why adding this widget to a menu row cannot change how
/// that row lays out — with nothing to show it is a `SizedBox.shrink()`,
/// measured at `Size.zero` by `test/widgets/access_lock_badge_test.dart`.
///
/// **It calls [resolveAccessGate] rather than deciding for itself.** A badge
/// with its own copy of "locked when…" is how a lock ends up on a page that
/// opens, or an open page ends up wearing a lock — the first time one of the
/// two copies is edited. The only things it decides are the path lookups, and
/// both of those come from `lib/access_routes.dart`, which is where the route
/// table gets them too. In particular the database-outage exemption is
/// [routeAllowedWhenNobodyCanSignIn] and never a boolean literal, so
/// Server Config's badge and Server Config's gate agree in every repository
/// state, including both causes of an unavailable one.
///
/// **Waiting renders nothing, like a lock.** A menu popup is built in one
/// frame and read immediately; a lock that appears a frame late is better than
/// one that flashes on every menu open. Same ruling as `AccessStatusAction`,
/// which renders nothing rather than a placeholder while the session resolves.
///
/// **No tooltip.** This lives inside a popup route, and a tooltip overlay above
/// a popup overlay is a bug waiting to happen. The explanation belongs on the
/// locked page, which is one tap away.
/// True when [path] names a route this session cannot open.
///
/// **One copy of the question, deliberately.** [AccessLockBadge] draws a lock
/// from this and the navigation menu hides an entry from it. Two copies of
/// "locked when..." is exactly how a lock ends up on a page that opens, or a
/// page vanishes that would have opened — the first time one of them is edited.
/// It calls [resolveAccessGate] for the same reason the badge did: the route
/// gate and the menu must agree in every repository state, including both
/// causes of an unavailable one.
///
/// **Call it from `build`.** It `watch`es, so a menu rebuilt after somebody
/// signs in shows the entries they can now reach without being reopened.
/// Pass `watch: false` from a callback that runs OUTSIDE `build` — a
/// `PopupMenuButton.itemBuilder`, for instance, which Flutter invokes when the
/// menu opens rather than while the owning widget is building. `ref.watch` is
/// only legal during build, and calling it from such a callback does not
/// rebuild anything; it silently fails to track. A popup is built afresh every
/// time it opens, so a read is the right answer there anyway.
bool accessRouteLocked(WidgetRef ref, String? path, {bool watch = true}) {
  final group = accessGroupForRoute(path);
  if (group == AccessGroup.operate) return false;
  final state = resolveAccessGate(
    group: group,
    authority: watch
        ? ref.watch(accessAuthorityProvider)
        : ref.read(accessAuthorityProvider),
    session: watch
        ? ref.watch(accessSessionProvider)
        : ref.read(accessSessionProvider),
    allowWhenNobodyCanSignIn: routeAllowedWhenNobodyCanSignIn(path),
    // The same provider `AccessGate` watches, for the same reason the path
    // predicate is shared: a badge that decided the link's health for itself
    // would put a lock on Server Config while the gate opened it.
    relayCanAuthenticate: watch
        ? ref.watch(relayCanAuthenticateProvider)
        : ref.read(relayCanAuthenticateProvider),
  );
  return state == AccessGateState.denied;
}

class AccessLockBadge extends ConsumerWidget {
  const AccessLockBadge({super.key, required this.path});

  /// The route the menu entry navigates to. Null — a section header, which
  /// groups rather than routes — is never locked.
  final String? path;

  /// The glyph's size. Smaller than the entry's own 20 px icon: the badge
  /// annotates the row, it is not a second subject in it.
  static const double glyphSize = 16.0;

  /// The gap between the label and the glyph, kept **inside** this widget so
  /// that an unlocked row contributes exactly zero width. A `SizedBox` beside
  /// the badge in the caller would survive the badge disappearing, and every
  /// ordinary menu row in the app would silently gain 8 px.
  static const double gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = accessGroupForRoute(path);
    if (group == AccessGroup.operate) return const SizedBox.shrink();
    if (!accessRouteLocked(ref, path)) return const SizedBox.shrink();

    return Semantics(
      // Named, not just drawn: a glyph-only lock says nothing to a screen
      // reader, and `group.name` is the same word the roles screen ticks.
      label: 'Locked. Needs the "${group.name}" permission.',
      child: Padding(
        padding: const EdgeInsets.only(left: gap),
        child: Icon(
          Icons.lock_outline,
          size: glyphSize,
          // Not `HmiStateColors.orange`, which means forced/override and, since
          // plan 01-08, an elevated session — a locked entry and an elevated
          // one would read alike. Not red either: a lock is not a fault.
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
