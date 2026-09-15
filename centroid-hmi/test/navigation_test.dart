/// The app's menu shape and route fallbacks:
///  - the Advanced menu lists every entry unconditionally, and the route gate
///    plus `AccessLockBadge` decide who may open one: a raised entry stays
///    visible and locked, never hidden,
///  - History View and Reports sit under Advanced until the operator
///    promotes them to the top level in the page editor,
///  - a deleted Home leaves `/` redirecting to the first available page,
///  - unpublished (draft) pages refuse direct navigation by redirecting.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show AsyncValue, Consumer;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/access_admin.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/pages/audit_trail.dart';
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/pages/first_user.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/page_editor.dart';
import 'package:tfc/pages/preferences.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/pages/tech_doc_library.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart';
import 'package:tfc/widgets/access_gate.dart';
import 'package:tfc/widgets/page_access_gate.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup, AccessSession;
import 'package:tfc_dart/core/access/access_repository.dart' show AccessRepository;
import 'package:tfc/widgets/dbus_gate.dart';
import 'package:tfc/widgets/route_redirect.dart';

import 'package:centroidx/main.dart';
import 'package:centroidx/navigation.dart';

MenuItem _page(String label, String path) => MenuItem(label: label, path: path, icon: Icons.pageview);

MenuItem? _byPath(List<MenuItem> items, String path) {
  for (final item in items) {
    if (item.path == path) return item;
  }
  return null;
}

/// Every path in the tree, sections and leaves alike.
///
/// [_byPath] only looks one level down; a route that must not appear *anywhere*
/// in the menu needs the whole tree walked.
List<String> _allPaths(List<MenuItem> items) => [
      for (final item in items) ...[
        if (item.path != null) item.path!,
        ..._allPaths(item.children),
      ],
    ];

void main() {
  group('buildTopLevelMenuItems', () {
    List<MenuItem> build() {
      return buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('Home', '/')],
      );
    }

    test(
        'every Advanced entry is listed unconditionally — a raised entry stays '
        'visible and locked, never hidden', () {
      // No golden test accompanies this one, and that is deliberate.
      // `centroid-hmi/test/` has no golden infrastructure at all: no
      // `goldens/` directory and no `@Tags(['golden'])` file. This change
      // touches no widget, and the entries that used to be hidden take the
      // identical RouteGate/`AccessLockBadge` path the page editor already
      // took when locked — the assertion further down that a locked page
      // editor's gate still carries its page title is what pins that. The
      // deployment-visible consequence is *which entries are in the list*,
      // and a list assertion proves exactly that. Standing up golden
      // scaffolding to photograph an unchanged widget appearing in a list
      // buys nothing and adds font-rasterisation flake.
      final advanced = _byPath(build(), '/advanced');
      final paths = advanced?.children.map((c) => c.path).toList() ?? [];
      // The reasoning that used to be recorded per-entry for the audit trail
      // and the access screen now covers all of these. Neither surfaces a
      // secret, both are commissioning-critical, and a hidden entry is a page
      // nobody knows to ask for — so nothing here is hidden. `kRaisedRoutes`
      // in `lib/access_routes.dart` plus the lock badge is the access
      // control; the menu is not, and never was.
      expect(paths, contains('/advanced/server-config'));
      expect(paths, contains('/advanced/key-repository'));
      expect(paths, contains('/advanced/page-editor'));
      expect(paths, contains('/advanced/preferences'));
      expect(paths, contains('/advanced/alarm-editor'));
      expect(paths, contains('/advanced/audit-trail'));
      expect(paths, contains('/advanced/access'));
    });

    test('History View defaults under Advanced, like before', () {
      final items = build();
      expect(_byPath(items, '/history-view'), isNull, reason: 'not top-level until the operator moves it');
      final advanced = _byPath(items, '/advanced')!;
      expect(advanced.children.map((c) => c.path), contains('/history-view'));
    });

    test('a promoted History View moves to the top level and out of Advanced', () {
      final items = buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('Home', '/')],
        historyAtTopLevel: true,
      );
      expect(_byPath(items, '/history-view'), isNotNull);
      final advanced = _byPath(items, '/advanced')!;
      expect(advanced.children.map((c) => c.path), isNot(contains('/history-view')));
    });

    test('historyViewIsTopLevel is membership in the stored order', () {
      expect(historyViewIsTopLevel(const []), isFalse);
      expect(historyViewIsTopLevel(const ['/', '/alarm-view']), isFalse);
      expect(historyViewIsTopLevel(const ['/history-view']), isTrue);
    });

    test('Reports defaults under Advanced, and the editor sits beside it', () {
      final items = build();
      expect(_byPath(items, '/reports'), isNull,
          reason: 'not top-level until the operator moves it');
      final advanced = _byPath(items, '/advanced')!;
      final paths = advanced.children.map((c) => c.path);
      // Both are listed; the route gate, not the menu, decides who may open
      // the editor — kRaisedRoutes puts it at `configure` and leaves the
      // viewer unraised, which access_routes_test asserts.
      expect(paths, contains('/reports'));
      expect(paths, contains('/advanced/report-editor'));
    });

    test('a promoted Reports moves to the top level and out of Advanced', () {
      final items = buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('Home', '/')],
        reportsAtTopLevel: true,
      );
      expect(_byPath(items, '/reports'), isNotNull);
      final advanced = _byPath(items, '/advanced')!;
      expect(advanced.children.map((c) => c.path), isNot(contains('/reports')));
    });

    test('reportsIsTopLevel is membership in the stored order', () {
      expect(reportsIsTopLevel(const []), isFalse);
      expect(reportsIsTopLevel(const ['/', '/alarm-view']), isFalse);
      expect(reportsIsTopLevel(const ['/reports']), isTrue);
    });

    test('the two movable built-ins are independent of each other', () {
      final onlyReports = buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('Home', '/')],
        reportsAtTopLevel: true,
      );
      expect(_byPath(onlyReports, '/reports'), isNotNull);
      expect(_byPath(onlyReports, '/history-view'), isNull);
      expect(_byPath(onlyReports, '/advanced')!.children.map((c) => c.path),
          contains('/history-view'));
    });

    test('Alarm View is a top-level entry', () {
      expect(_byPath(build(), '/alarm-view'), isNotNull);
    });

    test('Home is not pinned: it appears only when the page manager has it', () {
      final items = buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('First', '/first')],
      );
      expect(_byPath(items, '/'), isNull);
      expect(_byPath(items, '/first'), isNotNull);
    });

    test(
        'pages come first in registration order, built-ins after, Advanced '
        'pinned last (the persisted order is applied later by '
        'PageManager.sortTopLevel on the registry)', () {
      final items = buildTopLevelMenuItems(
        isLinux: false,
        pageMenuItems: [_page('Home', '/'), _page('Chiller', '/chiller')],
        historyAtTopLevel: true,
        reportsAtTopLevel: true,
      );
      expect(items.map((m) => m.path).take(5),
          ['/', '/chiller', '/alarm-view', '/reports', '/history-view']);
      expect(items.last.path, '/advanced', reason: 'Advanced stays pinned last, outside the ordering');
    });
  });

  group('resolveStartupPath', () {
    final menu = buildTopLevelMenuItems(
      isLinux: false,
      pageMenuItems: [
        _page('Home', '/'),
        MenuItem(label: 'Lines', path: '/lines', icon: Icons.folder, children: [
          _page('Line 1', '/lines/one'),
        ]),
      ],
    );

    test('the default stays the default', () {
      expect(resolveStartupPath('/', menuItems: menu), '/');
    });

    test('a routable page wins, nested pages included', () {
      expect(resolveStartupPath('/lines/one', menuItems: menu), '/lines/one');
    });

    test('a built-in destination wins', () {
      expect(resolveStartupPath('/alarm-view', menuItems: menu), '/alarm-view');
    });

    test('a deleted or unpublished page falls back to /', () {
      expect(resolveStartupPath('/gone', menuItems: menu), '/');
    });

    test('a section groups but does not route, so it falls back to /', () {
      expect(resolveStartupPath('/lines', menuItems: menu), '/');
      expect(resolveStartupPath('/advanced', menuItems: menu), '/');
    });
  });

  group('firstMenuPath', () {
    test('finds the first path depth-first', () {
      expect(
        firstMenuPath([
          const MenuItem(label: 'Section', icon: Icons.folder, children: [
            MenuItem(label: 'Leaf', path: '/leaf', icon: Icons.pageview),
          ]),
          _page('Other', '/other'),
        ]),
        '/leaf',
      );
    });

    test('is null when nothing is reachable', () {
      expect(firstMenuPath(const []), isNull);
    });
  });

  group('createLocationBuilder', () {
    /// Builds the BeamPage a route would produce, with a real BuildContext.
    Future<BeamPage> buildRoute(WidgetTester tester, RoutesLocationBuilder lb, String path) async {
      late BuildContext context;
      await tester.pumpWidget(Builder(builder: (c) {
        context = c;
        return const SizedBox.shrink();
      }));
      final builder = lb.routes[path];
      expect(builder, isNotNull, reason: 'expected a route for $path');
      return builder!(context, BeamState(), null) as BeamPage;
    }

    testWidgets('with a Home page, / is served normally', (tester) async {
      final lb = createLocationBuilder(
        [_page('Home', '/')],
        pagePaths: const ['/'],
      );
      final page = await buildRoute(tester, lb, '/');
      expect(page.child, isNot(isA<RouteRedirect>()));
    });

    testWidgets('with Home deleted, / redirects to the first available page', (tester) async {
      final lb = createLocationBuilder(
        [_page('Chiller', '/chiller'), _page('Freezer', '/freezer')],
        pagePaths: const ['/chiller', '/freezer'],
      );
      final page = await buildRoute(tester, lb, '/');
      expect(page.child, isA<RouteRedirect>());
      expect((page.child as RouteRedirect).target, '/chiller');
    });

    testWidgets('an unpublished page redirects instead of dead-ending', (tester) async {
      // The draft is in pagePaths (the manager knows it) but not in the
      // menu items (getRootMenuItems dropped it).
      final lb = createLocationBuilder(
        [_page('Home', '/')],
        pagePaths: const ['/', '/draft'],
      );
      final page = await buildRoute(tester, lb, '/draft');
      expect(page.child, isA<RouteRedirect>());
      expect((page.child as RouteRedirect).target, '/');
    });

    testWidgets('History View is routable at both old and new addresses', (tester) async {
      final lb = createLocationBuilder([_page('Home', '/')]);
      expect(lb.routes.containsKey('/history-view'), isTrue);
      expect(lb.routes.containsKey('/advanced/history-view'), isTrue);
    });

    testWidgets('the first-user page is routable by path', (tester) async {
      // Always registered, never conditional: the window check lives in the
      // page body, so the address resolves even before the database is up.
      final lb = createLocationBuilder([_page('Home', '/')]);
      final page = await buildRoute(tester, lb, AppRoutes.firstUser);
      expect(page.child, isA<FirstUserPage>());
    });

    testWidgets('the first-user page is registered even with no pages at all', (tester) async {
      // The commissioning case: a station whose page manager knows nothing yet.
      final lb = createLocationBuilder(const []);
      expect(lb.routes.containsKey(AppRoutes.firstUser), isTrue);
    });

    test('the first-user page has no menu entry', () {
      // A permanent entry advertising the commissioning window would be dead
      // on every station but a fresh one, and misleading on all of them.
      final items = buildTopLevelMenuItems(isLinux: false, pageMenuItems: [_page('Home', '/')]);
      expect(_allPaths(items), isNot(contains(AppRoutes.firstUser)));
    });

    testWidgets('no reachable pages at all leaves no bogus redirect', (tester) async {
      // Every page a draft: nowhere to send anyone. `/` stays unrouted and
      // beamer's not-found page takes it, rather than a redirect loop.
      final lb = createLocationBuilder(const [], pagePaths: const ['/draft']);
      expect(lb.routes.containsKey('/'), isFalse);
      expect(lb.routes.containsKey('/draft'), isFalse);
    });

    /// The nine raised routes, proven one at a time.
    ///
    /// These are the tests that keep `kRaisedRoutes` and the route table
    /// spelling the same nine strings: a path mistyped in either place is a
    /// route that silently stays open, and nothing else in the repo would
    /// notice. Each group is asserted by its literal path rather than in a
    /// loop over the map, because a loop passes just as happily when the map
    /// itself is wrong.
    ///
    /// The group is compared by `.name`, not by the enum: `centroid-hmi` does
    /// not depend on `tfc_access` and must not start to — `kRaisedRoutes[path]!`
    /// is a value, not a type, so the app package never names `AccessGroup`.
    ///
    /// Nothing here pumps a route child. `buildRoute` gets a `BuildContext`
    /// from a `SizedBox.shrink()` and calls the builder; pumping `PageEditor`
    /// or `ServerConfigPage` would drag in the database, the OPC UA client and
    /// `BaseScaffold`'s session watch.
    group('raised routes', () {
      // RouteRegistry is process-wide and outlives a test file, so the
      // "menu and route table agree" assertion below could otherwise pass on
      // declarations some earlier suite left behind.
      setUp(() => RouteRegistry().clearRouteGroups());
      tearDown(() => RouteRegistry().clearRouteGroups());

      Future<AccessGate> buildGate(WidgetTester tester, RoutesLocationBuilder lb, String path) async {
        final page = await buildRoute(tester, lb, path);
        expect(page.child, isA<AccessGate>(), reason: '$path must be gated');
        final gate = page.child as AccessGate;
        // The gate renders the app bar while the page behind it is locked, so
        // a locked Page Editor must still say "Page Editor".
        expect(gate.title, page.title, reason: '$path gate title must match the BeamPage title');
        return gate;
      }

      testWidgets('the page editor needs configure', (tester) async {
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/page-editor');
        expect(gate.group.name, 'configure');
        expect(gate.child, isA<PageEditor>());
      });

      testWidgets('the alarm editor needs configure', (tester) async {
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/alarm-editor');
        expect(gate.group.name, 'configure');
        expect(gate.child, isA<AlarmEditorPage>());
      });

      testWidgets('the key repository needs configure', (tester) async {
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/key-repository');
        expect(gate.group.name, 'configure');
        expect(gate.child, isA<KeyRepositoryPage>());
      });

      testWidgets('the knowledge base needs configure', (tester) async {
        // Not a read surface. docs/access-control-write-path-sweep.md §3.1
        // found three raw-Drift index classes behind this page, and a caller
        // that rewrites `page_editor_data` — routing around the page editor's
        // own gate. The accepted cost is that an anonymous operator can no
        // longer read a technical document or browse PLC code at the panel;
        // the drawings overlay on ordinary pages is a different surface and
        // is unaffected.
        //
        // Registered inside `if (kKnowledgeEnabled)`, which defaults to true,
        // so the route exists here; the gate wraps the child inside that `if`
        // rather than outside it, so a flag-off build still tree-shakes
        // TechDocLibraryPage.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/knowledge-base');
        expect(gate.group.name, 'configure');
        expect(gate.allowWhenRepositoryUnavailable, isFalse,
            reason: 'a document library is not the page that configures the database');
        expect(gate.child, isA<TechDocLibraryPage>());
      });

      testWidgets('server config needs administer', (tester) async {
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/server-config');
        expect(gate.group.name, 'administer');
        expect(gate.child, isA<ServerConfigPage>());
      });

      testWidgets('IP settings needs administer, and the D-Bus login behind it is untouched', (tester) async {
        // The gate wraps the D-Bus login from the outside, and the two are
        // different questions asked in order: may this session open the page
        // at all, and then has the station logged in to D-Bus. This phase
        // gates the route, not the station credential.
        //
        // The inner widget was an inline Consumer until #440 extracted it
        // into [DbusGate]; what this asserts is the nesting, so it moved with
        // the extraction rather than pinning a shape upstream had refactored.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/ip-settings');
        expect(gate.group.name, 'administer');
        expect(gate.child, isA<DbusGate>());
        // ...but it opens during an outage, which is the one thing that makes
        // a freshly commissioned station recoverable: the database is reached
        // over the network, so the page that gives the machine an address
        // cannot be gated behind a group only a working database can grant.
        // Asserted on the BUILT gate, not on the declaration, because that is
        // what the router actually honours.
        expect(gate.allowWhenRepositoryUnavailable, isTrue,
            reason: 'a new station reaches its database over the network; '
                'gating this page behind the database is a loop with no entry');
      });

      testWidgets('preferences needs administer', (tester) async {
        // The 2026-08-29 amendment. PreferencesPage renders DatabaseConfigWidget
        // and a raw list/edit/delete editor over every preference key — the data
        // behind all three configure routes — so an ungated Preferences would
        // make the page editor's and alarm editor's gates decorative.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/preferences');
        expect(gate.group.name, 'administer');
        expect(gate.child, isA<PreferencesPage>());
      });

      testWidgets('audit trail needs users', (tester) async {
        // The whole of the enforcement for the audit trail page. Its store
        // takes no session and cannot refuse a caller — the reads are ungated
        // on purpose, because a guarded read would put a row in the trail
        // every time somebody scrolled the trail. If this gate is wrong, the
        // page is every write anybody ever made, open to an anonymous panel.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/audit-trail');
        expect(gate.group.name, 'users');
        expect(gate.allowWhenRepositoryUnavailable, isFalse,
            reason: 'the trail is the database; there is nothing to read while it is down');
        expect(gate.child, isA<AuditTrailPage>());
      });

      testWidgets('config history needs configure, and not users',
          (tester) async {
        // Its own entry rather than a widened audit-trail one. Two failures
        // this catches: the page riding the `users` gate, which would put the
        // history out of reach of the engineer who made the edits; and the
        // audit trail being lowered to `configure` to let this page in, which
        // would hand every write anybody ever made to anyone who can edit a
        // page (T-04-06a).
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/config-history');
        expect(gate.group.name, 'configure');
        expect(gate.allowWhenRepositoryUnavailable, isFalse,
            reason: 'the history is the database; there is nothing to read '
                'while it is down');
        expect(gate.child, isA<ConfigHistoryPage>());
      });

      testWidgets('access needs users', (tester) async {
        // The whole of the enforcement for *reading* the admin screen.
        // AccessAdminStore gates every write and audits every denial, but its
        // reads are ungated on purpose — a row in the trail every time somebody
        // opened the roles list would bury the writes that matter. If this gate
        // is wrong, the account list and every role's group set are open to an
        // anonymous panel.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final gate = await buildGate(tester, lb, '/advanced/access');
        expect(gate.group.name, 'users');
        expect(gate.allowWhenRepositoryUnavailable, isFalse,
            reason: 'with no repository there is no role table, so an exempt '
                'admin page would edit nothing while looking like it worked');
        expect(gate.child, isA<AccessAdminPage>());
      });

      testWidgets('exactly two routes stay open while the repository is unavailable', (tester) async {
        // Catches the helper being changed to a per-call-site boolean: the flag
        // is read off every built gate, not off the declaration it came from.
        //
        // The pair is what makes a new station recoverable -- IP Settings gives
        // the machine an address, Server Config points it at a database, and
        // only then can the repository grant anybody a group. Pinned as a set,
        // because this list is the blast radius of "reachable with no access
        // control at all" and should only grow by someone editing this line.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final exempt = <String>[];
        for (final path in kRaisedRoutes.keys) {
          final gate = await buildGate(tester, lb, path);
          if (gate.allowWhenRepositoryUnavailable) exempt.add(path);
        }
        expect(exempt,
            unorderedEquals(['/advanced/server-config', '/advanced/ip-settings']));
      });

      testWidgets('every declared path is a real route', (tester) async {
        // Iterates the map rather than repeating the nine, so a typo in
        // kRaisedRoutes fails here instead of leaving a route quietly open.
        final lb = createLocationBuilder([_page('Home', '/')]);
        for (final path in kRaisedRoutes.keys) {
          expect(lb.routes.containsKey(path), isTrue, reason: 'kRaisedRoutes declares $path, which is not a route');
        }
      });

      testWidgets('the menu and the route table agree about every raised route', (tester) async {
        // Route groups are declared by `RouteRegistry.replaceMenu`, which the
        // boot sequence calls before `createLocationBuilder` and which
        // `menuTreeProvider` calls again on every recomposition. They used to
        // be declared as a side effect of `createLocationBuilder`; moving them
        // is what lets a group *removed* in the page editor stop being
        // declared without a restart. The menu badge and the route gate read
        // the same registry either way, which is what this test is for.
        expect(accessGroupForRoute('/advanced/page-editor').name, 'operate', reason: 'registry must start clear');

        final menu = [_page('Chiller', '/chiller')];
        RouteRegistry().replaceMenu(menu, declareGroups: () {
          installRaisedRoutes();
          declareMenuRouteGroups(menu);
        });

        final lb = createLocationBuilder(menu, pagePaths: const ['/chiller']);
        expect(lb.routes.containsKey('/chiller'), isTrue);
        expect(accessGroupForRoute('/advanced/page-editor').name, 'configure');
        expect(accessGroupForRoute('/advanced/alarm-editor').name, 'configure');
        expect(accessGroupForRoute('/advanced/key-repository').name, 'configure');
        expect(accessGroupForRoute('/advanced/knowledge-base').name, 'configure');
        expect(accessGroupForRoute('/advanced/server-config').name, 'administer');
        expect(accessGroupForRoute('/advanced/ip-settings').name, 'administer');
        expect(accessGroupForRoute('/advanced/preferences').name, 'administer');
        expect(accessGroupForRoute('/advanced/audit-trail').name, 'users');
        expect(accessGroupForRoute('/advanced/access').name, 'users');
        // A page-manager page is the plant's own page: operate, like everything
        // else on the floor.
        expect(accessGroupForRoute('/chiller').name, 'operate');
      });

      testWidgets('the first-user page is not a gate of either kind', (tester) async {
        // Commissioning. Gating the first account on a station that has no
        // users yet is the deadlock the first-user design exists to avoid, and
        // `pageVisible` fails closed, so a whitelist gate here would be a door
        // that locks itself. It is the only route left carrying neither gate.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final page = await buildRoute(tester, lb, AppRoutes.firstUser);
        expect(page.child, isNot(isA<AccessGate>()));
        expect(page.child, isNot(isA<PageAccessGate>()));
      });

      testWidgets('the five read surfaces wear the whitelist gate, and all stay operate', (tester) async {
        // The hole this closes: the page whitelist could drop any of these from
        // the menu and the address still opened it, because none of these
        // routes carried a gate at all — hiding was the whole of the
        // enforcement, which is the failure mode `docs/access-control-spec.md`
        // §6 names. The top bar made Alarm View a one-tap version of it rather
        // than a typed-URL one, which is how it was found.
        //
        // Both halves are asserted for each, because the fix is only correct if
        // the second one holds: these gates are the *whitelist*, never a
        // permission. Raising any of these groups would take a read surface
        // away from every anonymous panel on the floor, which is not what this
        // does.
        final lb = createLocationBuilder([_page('Home', '/')]);
        for (final path in [
          AppRoutes.alarmView,
          AppRoutes.historyView,
          AppRoutes.reports,
          '/advanced/about-linux',
        ]) {
          final page = await buildRoute(tester, lb, path);
          expect(page.child, isA<PageAccessGate>(), reason: '$path must ask the whitelist');
          expect(page.child, isNot(isA<AccessGate>()), reason: '$path must not need a group');
          expect((page.child as PageAccessGate).path, path);
          expect(accessGroupForRoute(path).name, 'operate', reason: '$path must stay operate');
        }
      });

      testWidgets('the history-view alias is gated on the canonical path', (tester) async {
        // `/advanced/history-view` is a bookmark-compatible alias, not a menu
        // destination, so it can never appear in a whitelist. A gate keyed on
        // its own spelling would ask about a page nobody can tick, and
        // `pageVisible` matches stored paths exactly and fails closed — so it
        // would refuse every bookmark on any station that configured a
        // whitelist at all. Keying it on the canonical path is also what stops
        // the alias being the way around a whitelist that hides History View.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final page = await buildRoute(tester, lb, '/advanced/history-view');
        expect(page.child, isA<PageAccessGate>());
        expect((page.child as PageAccessGate).path, AppRoutes.historyView,
            reason: 'the alias must ask about the page the whitelist can name');
      });

      testWidgets('a commissioning station is not locked out by any of them', (tester) async {
        // The objection this answers: gating more routes must not be a way to
        // strand somebody pointing a fresh station at its network and database.
        //
        // It cannot be, and the reason is structural rather than lucky — a
        // whitelist only exists where a database exists. With no repository the
        // anonymous session carries no `allowedPages`, so every one of these
        // asks the whitelist and is admitted. Asserted against a resolved
        // no-database session, which is what a station being commissioned
        // actually has.
        final commissioning = AsyncValue<AccessSession>.data(
            AccessSession.anonymous(const {AccessGroup.operate}));
        const noRepository = AsyncValue<AccessRepository?>.data(null);

        for (final path in [
          AppRoutes.alarmView,
          AppRoutes.historyView,
          AppRoutes.reports,
          '/advanced/about-linux',
        ]) {
          expect(
            resolvePageAccess(
              group: accessGroupForRoute(path),
              path: path,
              repository: noRepository,
              session: commissioning,
            ),
            AccessGateState.allowed,
            reason: '$path must open on a station with no database',
          );
        }

        // And the two that must survive the *group* half as well, because they
        // are `administer` and are how the station gets a database at all.
        // Different mechanism — `routeAllowedWhenRepositoryUnavailable`, not
        // the whitelist — and untouched by this change, asserted here so that
        // widening the whitelist gating can never quietly cost it.
        for (final path in [kServerConfigRoute, kIpSettingsRoute]) {
          expect(
            resolvePageAccess(
              group: accessGroupForRoute(path),
              path: path,
              repository: noRepository,
              session: commissioning,
            ),
            AccessGateState.allowed,
            reason: '$path must open on a station with no database',
          );
        }
      });

      testWidgets('a page-manager page wears the page gate', (tester) async {
        // This assertion used to read "a page-manager page is not a gate",
        // which carried the access milestone's "nothing on the floor changes"
        // boundary. It also described a hole: a page raised above `operate` in
        // the page editor vanished from the menu and still opened to anyone
        // who typed its URL, because hiding was the whole of the enforcement.
        //
        // `PageAccessGate` closes it, and asks the page-visibility whitelist
        // at the same time. It is NOT an `AccessGate`: that one takes a group
        // literal at the call site, this one takes the path, because a page's
        // group lives in the registry and the whitelist is keyed on the path.
        final lb = createLocationBuilder([_page('Chiller', '/chiller')], pagePaths: const ['/chiller']);
        final page = await buildRoute(tester, lb, '/chiller');
        expect(page.child, isA<PageAccessGate>());
        expect(page.child, isNot(isA<AccessGate>()));
        expect((page.child as PageAccessGate).path, '/chiller');
      });

      testWidgets('the behaviour that boundary protected still holds', (tester) async {
        // The gate is free on an unrestricted station: an undeclared page
        // short-circuits on `operate` and a session with no whitelist admits
        // every path, so the gate returns its child with nothing added around
        // it. That — not the absence of a wrapper — is what "nothing on the
        // floor changes" actually meant.
        //
        // Asserted against a **resolved** session, which is the change from
        // how this read before. It used to hand the gate two `AsyncLoading`s
        // and expect `allowed`, on the reasoning that an ordinary page must
        // open before anything has resolved. That reasoning turned out to
        // describe the startup glitch rather than the boundary: on a station
        // that restricts what anonymous may see, it rendered the plant page
        // for the length of the Postgres connect and then took it away. The
        // boot window waits now — see `resolvePageAccess` — and what this test
        // is actually for is that an unrestricted station is unaffected once
        // that window closes.
        expect(accessGroupForRoute('/chiller').name, 'operate');
        expect(
          resolvePageAccess(
            group: accessGroupForRoute('/chiller'),
            path: '/chiller',
            repository: const AsyncValue<AccessRepository?>.loading(),
            session: AsyncValue<AccessSession>.data(
                AccessSession.anonymous(const {AccessGroup.operate})),
          ),
          AccessGateState.allowed,
          reason: 'an ordinary page on a station with no whitelist opens with '
              'nothing added around it',
        );
      });
    });
  });
}
