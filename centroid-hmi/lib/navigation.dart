/// The navigation menu's shape, separated from `main.dart` so it can be
/// tested without booting the app: which built-ins sit at the top level,
/// why the Advanced menu is unconditional and the route gate decides access,
/// and where `/` falls back to when the Home page has been deleted.
library;

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:tfc/core/feature_flags.dart';

export 'package:tfc/core/startup_url.dart' show resolveStartupPath;
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/routes.dart';

/// History View's menu entry. Lives under Advanced by default; the operator
/// can move it to the top level from the page editor's Pages dialog, which
/// records it in the persisted top-level order (see
/// [historyViewIsTopLevel]).
const historyViewMenuItem = MenuItem(label: 'History View', path: AppRoutes.historyView, icon: Icons.history);

/// Whether the operator moved History View to the top level: membership in
/// the persisted top-level order is the single source of truth, so there is
/// no second placement key to drift out of sync. An install that never
/// promoted it (or one whose order predates the promotion feature) keeps
/// History under Advanced.
bool historyViewIsTopLevel(List<String> topLevelOrder) => topLevelOrder.contains(AppRoutes.historyView);

/// Reports' menu entry. Same deal as History View: under Advanced by
/// default, promoted to the top level from the page editor's Pages dialog,
/// with membership in the persisted order as the only record (see
/// [reportsIsTopLevel]).
const reportsMenuItem = MenuItem(label: 'Reports', path: AppRoutes.reports, icon: Icons.summarize);

/// Whether the operator moved Reports to the top level. Membership in the
/// persisted top-level order is the single source of truth — the same rule
/// [historyViewIsTopLevel] uses, which works precisely because Advanced is
/// the default: an install that never arranged its menu has no entry, and
/// no entry means "leave it where it started".
bool reportsIsTopLevel(List<String> topLevelOrder) => topLevelOrder.contains(AppRoutes.reports);

/// Top-level menu entries the app itself provides. They are not pages in the
/// page editor, but they share the top level with the pages and order with
/// them through `PageManager.sortTopLevel`. Home is *not* here: Home is an
/// ordinary page in the page manager, deletable and reorderable like any
/// other. Reports and History View join only when the operator moved them
/// out of Advanced.
List<MenuItem> builtinTopLevelMenuItems({
  required bool historyAtTopLevel,
  bool reportsAtTopLevel = false,
}) =>
    [
      const MenuItem(label: 'Alarm View', path: AppRoutes.alarmView, icon: Icons.alarm),
      if (reportsAtTopLevel) reportsMenuItem,
      if (historyAtTopLevel) historyViewMenuItem,
    ];

/// Assembles the whole top-level menu in registration order: the pages, the
/// built-ins, then Advanced pinned last. The persisted top-level order is
/// applied afterwards by `PageManager.sortTopLevel` on the registry.
///
/// Every Advanced child is listed unconditionally. `kRaisedRoutes` in
/// `lib/access_routes.dart` and `AccessLockBadge` decide who may open one, so
/// a raised entry stays *visible and locked*, never hidden — a hidden entry
/// is a page nobody knows to ask for, and the lock badge built for these
/// routes would never appear on the station that needs it. That reasoning was
/// first recorded per-entry for the three entries never hidden: commissioning
/// a Windows HMI (pointing it at a PLC) must not require an environment
/// variable; the audit trail surfaces no secret, because no constructor on an
/// audit record takes a password and the trail withholds values on auth rows
/// on purpose; and the access screen is the *commissioning-critical* one —
/// the deployment doc's order is "create roles, then users, then the
/// first-user window closes", which cannot be followed from a station where
/// the entry is invisible — with a user list of username, role, created and
/// last login, `passwordHash` and `salt` never reaching the widget layer. It
/// now governs the whole function. The icons follow from it: Access carries a
/// people glyph rather than a lock or a shield, because a lock is what
/// `AccessLockBadge` draws over an entry the session cannot open.
List<MenuItem> buildTopLevelMenuItems({
  required bool isLinux,
  required List<MenuItem> pageMenuItems,
  bool historyAtTopLevel = false,
  bool reportsAtTopLevel = false,
}) {
  final advancedChildren = <MenuItem>[
    if (isLinux) MenuItem(label: 'IP Settings', path: '/advanced/ip-settings', icon: Icons.settings_ethernet),
    if (isLinux) MenuItem(label: 'About Linux', path: '/advanced/about-linux', icon: Icons.info),
    MenuItem(label: 'Page Editor', path: '/advanced/page-editor', icon: Icons.edit),
    MenuItem(label: 'Preferences', path: '/advanced/preferences', icon: Icons.settings),
    MenuItem(label: 'Alarm Editor', path: '/advanced/alarm-editor', icon: Icons.alarm),
    MenuItem(label: 'Report Editor', path: AppRoutes.reportEditor, icon: Icons.summarize),
    // The two movable operator destinations, in their default home.
    // Both can be promoted to the top level from the page editor.
    // Reports is unraised: reading a shift report is operate-level
    // work. Editing the definitions is the Report Editor above it,
    // which kRaisedRoutes puts at `configure`.
    if (!reportsAtTopLevel) reportsMenuItem,
    // History View's default home (its pre-#154 spot). The operator can
    // promote it to the top level from the page editor.
    if (!historyAtTopLevel) historyViewMenuItem,
    MenuItem(label: 'Server Config', path: '/advanced/server-config', icon: FontAwesomeIcons.server.data),
    MenuItem(label: 'Key Repository', path: '/advanced/key-repository', icon: FontAwesomeIcons.key.data),
    MenuItem(label: 'Audit Trail', path: '/advanced/audit-trail', icon: Icons.receipt_long),
    MenuItem(label: 'Access', path: '/advanced/access', icon: Icons.manage_accounts),
    if (kKnowledgeEnabled)
      MenuItem(label: 'Knowledge Base', path: '/advanced/knowledge-base', icon: Icons.library_books),
  ];

  return [
    ...pageMenuItems,
    ...builtinTopLevelMenuItems(
        historyAtTopLevel: historyAtTopLevel,
        reportsAtTopLevel: reportsAtTopLevel),
    // An Advanced section with nothing in it would just be a dead menu entry.
    if (advancedChildren.isNotEmpty)
      MenuItem(
        label: 'Advanced',
        path: '/advanced',
        icon: Icons.settings,
        children: advancedChildren,
      ),
  ];
}

/// Resolves this station's stored startup URL against the assembled menu.
///
/// The stored path only wins while it is still a routable destination:
/// sections group pages but do not route, and a page that has been deleted
/// or unpublished since the operator picked it must not strand the app on
/// "not found" at boot. Everything else falls back to `/`, which always
/// routes — Home, or the RouteRedirect stub standing in for a deleted Home.
/// Depth-first first path in [items] — where `/` and refused pages fall back
/// to when the Home page itself is gone. Null when no page is reachable at
/// all.
String? firstMenuPath(List<MenuItem> items) {
  for (final item in items) {
    final path = item.path;
    if (path != null && path.isNotEmpty) return path;
    final childPath = firstMenuPath(item.children);
    if (childPath != null) return childPath;
  }
  return null;
}

/// Normalizes the initial route the platform embedder reports, so
/// [BeamerDelegate.initialPath] actually gets its turn.
///
/// Beamer replaces the incoming route with `initialPath` only when that
/// route is exactly `/`. Desktop embedders report `/`, but the eLinux
/// embedder reports an empty string, which sails past that check unchanged
/// and paints Home no matter what startup page the operator picked — the
/// station bug behind #354. Anything that is not an absolute path (empty,
/// or a bare name like `main`) counts as "the platform had no opinion" and
/// becomes `/`; a genuine deep link starting with `/` passes through.
String normalizeInitialPlatformRoute(String defaultRouteName) {
  final name = defaultRouteName.trim();
  if (name.isEmpty || !name.startsWith('/')) return '/';
  return name;
}
