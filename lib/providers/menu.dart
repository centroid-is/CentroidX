/// The navigation menu, derived rather than cached.
///
/// ## What this replaces
///
/// The menu used to be assembled **once, before `runApp`**, out of a
/// device-local cache of the pages, and pushed into the `RouteRegistry`
/// singleton. Every consumer — the navigation bar, its popups, the startup
/// resolver — then read that singleton synchronously, outside Riverpod.
/// `main.dart` carried the admission: *"if a second HMI adds a page, we will
/// need to restart the app twice"*.
///
/// Two things follow from that shape, and both are defects rather than
/// trade-offs:
///
/// * **The bar could not change between logins.** Nothing in the pipeline read
///   the session, so signing in could not add or remove a destination. The
///   only filtering that existed lived inside one popup widget.
/// * **The bar could not change when the pages did.** A page created on
///   another station reached this one's database, but not its menu.
///
/// So the source of truth moves here, as two providers:
///
/// * [menuTreeProvider] — the **full** tree, session-blind, recomposed
///   whenever the pages change. This is what the page editor, the startup
///   resolver and the back-arrow helper see.
/// * [visibleMenuProvider] — that tree **filtered for the session in force**.
///   This is what the navigation bar and its popups render. Watching the
///   session here is what makes the bar change between logins.
///
/// ## The distinction that must survive refactors
///
/// **The page editor is never a consumer of [visibleMenuProvider].** It is a
/// `configure` surface for editing the whole tree; handing it an operator's
/// filtered view would make pages un-editable and un-orderable for the very
/// person managing them, and would look like data loss. It reads the full
/// tree. The same goes for `resolveStartupPath`, which asks "is this path
/// routable" — permission is the route gate's question, and folding it in here
/// would silently re-target the startup page instead of showing the honest
/// refusal.
///
/// ## What this must not do
///
/// Nothing in this file may be read by `stateManProvider`,
/// `preferencesProvider` or `accessPolicyProvider`. The dependency runs one
/// way — pages and session in, widgets out — so a sign-in rebuilds the bar and
/// nothing upstream of it. The failure a violation buys is documented on
/// `accessPolicyProvider`: every OPC UA connection and subscription on the
/// panel dropped on each sign-in.
library;

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart' show AccessSession;
import '../access_routes.dart';
import '../core/access_authority.dart';
import '../models/menu_item.dart';
import '../page_creator/page.dart';
import '../route_registry.dart';
import '../widgets/access_gate.dart';
import '../widgets/page_access_gate.dart';
import 'access.dart';
import 'gateway_link.dart';
import 'page_manager.dart';

part 'menu.g.dart';

/// How the app shell turns the page manager's pages into the whole top-level
/// menu — the built-in entries, the Advanced section, the persisted order.
///
/// A hook rather than a direct call because that composition lives in the app
/// shell (`centroid-hmi/lib/navigation.dart`), which knows the Advanced entry
/// list and the platform flags, and which depends on this package rather than
/// the other way round. `main()` overrides this provider with the real
/// composer; the default composes the pages alone, which is what a test or
/// another entry point wants.
typedef MenuComposer = List<MenuItem> Function(PageManager);

/// Who composes the menu, or **null for "nobody here does"**.
///
/// Null is the default and it is not a degenerate case: it means this entry
/// point has no page-to-menu composition of its own, so the `RouteRegistry`
/// contents — whatever seeded them — *are* the menu, and [menuTreeProvider]
/// reads them without ever writing them. That covers the page-editor harness,
/// the widget tests that register a menu by hand, and any embedder that builds
/// its own navigation.
///
/// The alternative — defaulting to "the pages alone" — was tried and is wrong:
/// it silently deletes every entry the registry holds that did not come from
/// the page manager, which in the editor harness is the built-in destinations
/// the Pages dialog exists to reorder.
///
/// `main()` overrides this with the shell's real composition, and *that* is
/// what makes the provider the owner of the menu in the app.
final menuComposerProvider = Provider<MenuComposer?>((ref) => null);

/// The paths the router can actually serve, or null for "do not filter".
///
/// **Why the live menu needs this.** The route table is built once, before
/// `runApp`, from the pages this station had cached locally at that moment.
/// The menu is no longer built once — it recomposes when `pageManagerProvider`
/// answers with the database's copy — so the two can now disagree in a way
/// they could not before: a page created on *another* station reaches this
/// one's database, and would appear in the menu with no route behind it. The
/// operator would tap it and get "not found", which is a worse failure than
/// not seeing it at all.
///
/// So the menu is intersected with what the router holds. The honest
/// consequence, unchanged from before this work and stated rather than
/// quietly kept: **a page added on another station still needs a restart of
/// this one to appear.** Making the route table itself live is a larger
/// change — Beamer's `RoutesLocationBuilder` stacks a page for every matching
/// route, so a `'*'` fallback would add one on top of every route in the app,
/// and rebuilding the delegate resets navigation state.
///
/// Null — the default, and what every test and harness gets — means no
/// filtering, so a menu assembled by hand is shown as assembled. `main()`
/// overrides it with the route table's own key set.
final routablePathsProvider = Provider<Set<String>?>((ref) => null);

/// The full menu tree: every published page and every built-in entry, composed
/// live and session-blind.
///
/// Recomposes when [pageManagerProvider] answers — which is when the database
/// copy of the pages lands, and again whenever the page editor saves and
/// invalidates it. Until then it composes from [bootstrapPageManagerProvider],
/// the device-local cache `main()` seeds, exactly as the plant page already
/// does; a station whose database is slow shows its last-known menu rather
/// than nothing.
///
/// **Route groups are redeclared here**, through [RouteRegistry.replaceMenu],
/// because the groups and the tree are the same fact and must not be able to
/// come from two different snapshots of it.
///
/// The `RouteRegistry` menu list is written here as a mirror for the handful
/// of synchronous readers that have not migrated (the page editor, two
/// scaffold helpers). New code reads this provider.
@Riverpod(keepAlive: true)
List<MenuItem> menuTree(Ref ref) {
  final composer = ref.watch(menuComposerProvider);
  final manager = ref.watch(pageManagerProvider).valueOrNull ??
      ref.watch(bootstrapPageManagerProvider);

  // Two cases where this provider composes nothing and owns nothing:
  //
  //  * no composer — this entry point does not build a menu from pages, so
  //    the registry's contents are the menu (see [menuComposerProvider]);
  //  * no page manager — the first frames of a cold start with an empty local
  //    cache. The answer is the registry's current contents, **not** an empty
  //    menu, which would blank the navigation bar for those frames.
  //
  // The list itself is returned rather than a copy, deliberately: it is the
  // live menu in this case, and a snapshot would go stale the moment whoever
  // owns it added an entry.
  if (composer == null || manager == null) return RouteRegistry().menuItems;

  final tree = composer(manager);

  RouteRegistry().replaceMenu(
    tree,
    declareGroups: () {
      // The built-in raised routes first, then the groups the operator
      // published pages and sections for, which layers on top. The order is
      // load-bearing and is why both calls sit inside one closure — see
      // `declareMenuRouteGroups`.
      installRaisedRoutes();
      declareMenuRouteGroups(tree);
    },
  );

  return tree;
}

/// The menu as **this session** may see it, plus the index mapping the
/// navigation bar needs.
///
/// A value type rather than a bare list because the index hazard has to be
/// solved once, here, instead of in each widget: the destinations, the
/// selected index and the tap handler must all index the *same* filtered list.
/// A filtered render list beside an unfiltered tap list sends a tap to the
/// wrong page — the same class of defect as the popup that was sized from a
/// second count of the tree.
class VisibleMenu {
  const VisibleMenu(this.topLevel);

  /// The top-level entries this session may see, **in [menuTreeProvider]
  /// order**. A pure filter and never a sort: ordering stays the page
  /// editor's business (`page_editor_top_level_order`), visibility stays this
  /// provider's, and the two never negotiate.
  final List<MenuItem> topLevel;

  /// The index into [topLevel] of the entry owning [path], or null.
  ///
  /// Walks into sections, so a page inside Advanced selects Advanced. Null for
  /// a path this session cannot see — including the page it is standing on,
  /// which happens when somebody signs out while looking at a page their floor
  /// identity does not have. The bar then selects nothing rather than
  /// selecting the wrong thing.
  int? indexOfPath(String? path) {
    if (path == null) return null;
    for (var i = 0; i < topLevel.length; i++) {
      if (_owns(topLevel[i], path)) return i;
    }
    return null;
  }

  static bool _owns(MenuItem item, String path) {
    if (item.path == path) return true;
    for (final child in item.children) {
      if (_owns(child, path)) return true;
    }
    return false;
  }

  /// Whether a navigation bar can be built at all.
  ///
  /// Material's `NavigationBar` asserts at least two destinations, so a
  /// session whitelisted down to one page or none gets no bar. That is an
  /// existing, tested state — fullscreen mode already renders
  /// `bottomNavigationBar: null` — and it is not a dead end: the app bar, with
  /// its sign-in control, is on every scaffold.
  bool get showsBar => topLevel.length >= 2;

  /// **Recursive, and it has to be.** Riverpod skips notifying listeners when
  /// a rebuilt value compares equal to the old one, so an equality that
  /// stopped at the top level would report "no change" for the case this
  /// provider exists to handle: a section that keeps its label and its (null)
  /// path while the pages *under* it are filtered away. The menu would then
  /// stay as it was resolved during the boot window — every entry visible,
  /// because nothing had resolved yet — and never update when the session
  /// did. That is the bug this comment is standing on.
  ///
  /// `MenuItem`'s own `==` is not used: it compares label, path and icon and
  /// ignores children entirely, which is the same trap one level down.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VisibleMenu && _sameTree(other.topLevel, topLevel);

  static bool _sameTree(List<MenuItem> a, List<MenuItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path || a[i].label != b[i].label) return false;
      if (!_sameTree(a[i].children, b[i].children)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_flatKeys(topLevel));

  static List<Object> _flatKeys(List<MenuItem> items) => [
        for (final item in items) ...[
          item.path ?? item.label,
          ..._flatKeys(item.children),
        ],
      ];
}

/// [menuTreeProvider] filtered by [resolvePageAccess], for the session in
/// force.
///
/// Watching `accessSessionProvider` here is the whole of amendment 2: a
/// sign-in rebuilds this provider, and every scaffold watching it rebuilds its
/// bar. Nothing upstream is touched.
///
/// A **leaf** survives when this session may open it. A **section** survives
/// when any leaf beneath it does — which is what makes a section whose pages
/// are all hidden disappear, the behaviour the popup menu already had for
/// group-locked entries.
///
/// Entries with no path and no children (neither a page nor a section) are
/// kept: they are not something this filter has an opinion about.
@Riverpod(keepAlive: true)
VisibleMenu visibleMenu(Ref ref) {
  final tree = ref.watch(menuTreeProvider);
  final authority = ref.watch(accessAuthorityProvider);
  final session = ref.watch(accessSessionProvider);
  // Watched, not assumed: on a gateway panel with a dead link nobody can sign
  // in, and the menu has to reach the same verdict the gate and the badge do.
  final relayCanAuthenticate = ref.watch(relayCanAuthenticateProvider);
  final routable = ref.watch(routablePathsProvider);

  bool visible(String path) {
    // Routability first, and it is not an access question: an entry the router
    // cannot serve must not be offered, whoever is standing at the panel. See
    // [routablePathsProvider].
    if (routable != null && !routable.contains(path)) return false;
    return _mayOpen(path, authority, session, relayCanAuthenticate);
  }

  MenuItem? filter(MenuItem item) {
    if (item.isNavigationSection) {
      // A section that never had children is **kept**. An empty section is a
      // real state — the page editor creates one before anything is put in it
      // — and this filter has no opinion about it: nothing was hidden, so
      // nothing should disappear. Only a section whose children were all
      // filtered away becomes a heading over nothing.
      if (item.children.isEmpty) return item;

      final kept = <MenuItem>[];
      for (final child in item.children) {
        final survivor = filter(child);
        if (survivor != null) kept.add(survivor);
      }
      if (kept.isEmpty) return null;
      return item.copyWith(children: kept);
    }
    final path = item.path;
    if (path == null || path.isEmpty) return item;
    return visible(path) ? item : null;
  }

  final kept = <MenuItem>[];
  for (final item in tree) {
    final survivor = filter(item);
    if (survivor != null) kept.add(survivor);
  }
  return VisibleMenu(List.unmodifiable(kept));
}

/// Whether this session may open [path] — the same question the route gate
/// and the lock badge ask, asked through the same function.
bool _mayOpen(
  String path,
  AsyncValue<AccessAuthority> authority,
  AsyncValue<AccessSession> session,
  bool relayCanAuthenticate,
) =>
    resolvePageAccess(
      group: accessGroupForRoute(path),
      path: path,
      authority: authority,
      session: session,
      relayCanAuthenticate: relayCanAuthenticate,
    ) !=
    AccessGateState.denied;

/// Convenience for the two synchronous readers that still need the whole tree
/// without a container — see the library doc's note on the page editor.
///
/// Reads the mirror rather than the provider, and is the only sanctioned way
/// to do so. Anything that can reach a `ref` should watch [menuTreeProvider]
/// instead, so it rebuilds when the pages change.
List<MenuItem> currentMenuTreeMirror() => RouteRegistry().menuItems;
