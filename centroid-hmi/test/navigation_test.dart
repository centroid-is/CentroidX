/// The app's menu shape and route fallbacks:
///  - the Advanced menu lists every entry unconditionally, and the route gate
///    plus `AccessLockBadge` decide who may open one: a raised entry stays
///    visible and locked, never hidden,
///  - History View sits at the top level, not under Advanced,
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
import 'package:tfc_access/tfc_access.dart' show AccessSession;
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

      testWidgets('server config is the only route open while the repository is unavailable', (tester) async {
        // Catches the helper being changed to a per-call-site boolean: the flag
        // is read off every built gate, not off the declaration it came from.
        final lb = createLocationBuilder([_page('Home', '/')]);
        final exempt = <String>[];
        for (final path in kRaisedRoutes.keys) {
          final gate = await buildGate(tester, lb, path);
          if (gate.allowWhenRepositoryUnavailable) exempt.add(path);
        }
        expect(exempt, ['/advanced/server-config']);
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

      testWidgets('about-linux, alarm view, history view and the first-user page are not gates', (tester) async {
        // Reading and commissioning. About Linux changes nothing; the two views
        // read rather than configure, and read permissions are out of scope;
        // gating the first account on a station with no users is an unopenable
        // door.
        final lb = createLocationBuilder([_page('Home', '/')]);
        for (final path in ['/advanced/about-linux', AppRoutes.alarmView, AppRoutes.historyView, AppRoutes.firstUser]) {
          final page = await buildRoute(tester, lb, path);
          expect(page.child, isNot(isA<AccessGate>()), reason: '$path must stay open');
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
        expect(accessGroupForRoute('/chiller').name, 'operate');
        expect(
          resolvePageAccess(
            group: accessGroupForRoute('/chiller'),
            path: '/chiller',
            repository: const AsyncValue<AccessRepository?>.loading(),
            session: const AsyncValue<AccessSession>.loading(),
          ),
          AccessGateState.allowed,
          reason: 'an ordinary page opens before anything has resolved, which '
              'is what keeps a booting panel from blanking its pages',
        );
      });
    });
  });
}
