/// A modal that outranks the floating windows.
///
/// Two things insert into the root overlay, and they do not compose:
///
///   * `showFloatingDialog` (`panes/standard_dialog.dart`) inserts an
///     `OverlayEntry` directly, which lands on top of everything present;
///   * `Navigator` inserts a pushed route's entries only **above the previous
///     route's** entries, never at the very top.
///
/// So a dialog route opened after a floating window sits underneath it — the
/// case `showFloatingDialog`'s own documentation warns about ("a route opened
/// from inside a floating window lands underneath it"). A trend window can
/// live with that. Sign-in cannot: asking an operator for credentials behind
/// a window they cannot see, while the plant view in front keeps taking their
/// taps, is a fault rather than a quirk.
///
/// This layer is the answer for the few modals that must always win. It is an
/// overlay entry, so it starts above every floating window, and it is
/// registered in [alwaysOnTopEntries], so `FloatingDialogs` inserts *beneath*
/// it while one is open — otherwise the next trend somebody opened would come
/// out in front again.
///
/// **It is still a route.** The entry hosts a small [Navigator] of its own and
/// the content is a real [DialogRoute] inside it, so a dialog that pops itself
/// with `Navigator.of(context).maybePop(value)` — as `AccessSignInDialog`
/// does in three places — keeps working untouched, and the value it pops with
/// is what the caller awaits. Hosting it as a bare widget would have meant
/// rewriting every pop into a callback, which is a lot of churn for a z-order
/// bug.
///
/// Deliberately not a general replacement for `showDialog`: a panel where
/// everything insisted on being on top would be a panel with no ordering at
/// all. Reach for it when being buried is a *fault*, not an inconvenience.
library;

import 'dart:async';

import 'package:flutter/material.dart';

/// The always-on-top entries currently open, oldest first.
///
/// Read by `FloatingDialogs._show` to decide where a new window goes. Exposed
/// rather than private because the two layers live in different files and the
/// ordering rule has to be visible from both — a floating window inserted
/// without consulting this is exactly the bug this file exists to fix.
final List<OverlayEntry> alwaysOnTopEntries = <OverlayEntry>[];

/// The lowest always-on-top entry, or null when none is open.
///
/// `FloatingDialogs` inserts `below:` this, so every floating window stays
/// under every always-on-top modal however many of either are open.
///
/// **Only ever a live entry.** `Overlay.insert` asserts that its `below`
/// anchor belongs to that same overlay, so an entry whose overlay went away
/// underneath it — a route change, a hot restart, a test's next `pumpWidget`
/// — would take every later floating window down with it. [_AlwaysOnTopHost]
/// drops those on dispose; the `mounted` filter here is the second line,
/// because a stale anchor breaks a window that has nothing to do with it and
/// the failure reads as a bug in the wrong file.
OverlayEntry? get lowestAlwaysOnTopEntry {
  for (final entry in alwaysOnTopEntries) {
    if (entry.mounted) return entry;
  }
  return null;
}

/// Shows [builder] in a modal route that sits above every floating window.
///
/// Completes with the value the content popped with, or null if it was
/// dismissed by the barrier or the overlay went away underneath it — the same
/// contract `showDialog` gives, so a caller reads the same either way.
Future<T?> showAlwaysOnTopDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<T?>();
  // Captured from the opener, not from the overlay: the entry builds outside
  // the caller's subtree, so any Theme or Directionality wrapped around the
  // opener would otherwise be lost on the way up.
  final themes = InheritedTheme.capture(from: context, to: null);

  late final OverlayEntry entry;
  var routeBuilt = false;

  void finish(T? value) {
    if (completer.isCompleted) return;
    alwaysOnTopEntries.remove(entry);
    if (entry.mounted) entry.remove();
    completer.complete(value);
  }

  entry = OverlayEntry(builder: (entryContext) {
    return _AlwaysOnTopHost(
      onDisposed: () => finish(null),
      child: Navigator(
        // TWO routes, and the empty one underneath is not decoration.
        // `Navigator.maybePop` *bubbles instead of popping* when the route is
        // the first in its navigator (`Route.popDisposition`), so a dialog
        // hosted as the only route here would have its
        // `Navigator.of(context).maybePop(value)` quietly do nothing — the
        // form would sit there, on top and unclosable, and the caller's await
        // would never answer. The placeholder keeps the dialog non-first, so
        // every pop the content already does behaves exactly as it did under
        // `showDialog`.
        onGenerateInitialRoutes: (_, __) {
          // Rebuilding this Navigator from scratch would ask again; a second
          // route would orphan the first and its completer. One dialog, once.
          routeBuilt = true;
          final route = DialogRoute<T>(
            context: entryContext,
            builder: (routeContext) => themes.wrap(builder(routeContext)),
            barrierDismissible: barrierDismissible,
            // The dialog is the whole layer's reason to exist, so its barrier
            // is the layer's barrier: everything below, floating windows
            // included, stops taking taps while it is up.
            barrierColor: Colors.black54,
          );
          // The one place the result is read. `popped` answers for every way
          // out — the content popping with a value, the barrier, an Escape —
          // so no exit path can leave the caller's await hanging.
          route.popped.then(finish);
          return <Route<dynamic>>[
            PageRouteBuilder<void>(
              opaque: false,
              // Nothing to see and nothing to hit: the barrier belongs to the
              // dialog above, so this must not absorb anything itself.
              pageBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            route,
          ];
        },
      ),
    );
  });

  alwaysOnTopEntries.add(entry);
  overlay.insert(entry);

  // A caller that never sees the route built at all (an overlay torn down in
  // the same frame, a test's next pumpWidget) still gets an answer.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!routeBuilt && !entry.mounted) finish(null);
  });

  return completer.future;
}

/// Tells the opener when the entry's overlay went away underneath it.
///
/// Without this the completer never answers on that path and — worse — the
/// dead entry stays in [alwaysOnTopEntries] as an anchor `Overlay.insert`
/// will assert on, so the next floating window in an unrelated part of the
/// app fails instead. `FloatingDialogs._forget` exists for the same reason.
class _AlwaysOnTopHost extends StatefulWidget {
  const _AlwaysOnTopHost({required this.child, required this.onDisposed});

  final Widget child;
  final VoidCallback onDisposed;

  @override
  State<_AlwaysOnTopHost> createState() => _AlwaysOnTopHostState();
}

class _AlwaysOnTopHostState extends State<_AlwaysOnTopHost> {
  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
