/// The navigation pipeline: the full tree, and the session's view of it.
///
/// The behaviour these tests exist for is the one the menu did not have
/// before: **it changes when the session does.** The menu used to be composed
/// once before `runApp` from a device-local cache into a process-global
/// mutable singleton, so neither signing in nor another station adding a page
/// could change the navigation bar.
///
/// Three traps are pinned here because each was met while building this:
///
///  * `VisibleMenu` equality has to be recursive. Riverpod skips notifying
///    listeners when a rebuilt value compares equal, so an equality that
///    stopped at the top level would report "no change" for a section whose
///    *children* were filtered — and the menu would stay frozen at whatever
///    the boot window resolved.
///  * A section with **no children at all** is kept. An empty section is a
///    real state, nothing was hidden, so nothing should disappear.
///  * With no composer, this provider owns nothing: the registry's contents
///    are the menu and are never overwritten. Defaulting to "the pages alone"
///    silently deleted every entry a harness had registered by hand.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/menu.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;

class _StubRepository extends Fake implements AccessRepository {}

class _NullPrefs implements PreferencesApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

AssetPage _page(String label, String path,
        {List<MenuItem> children = const [], bool published = true}) =>
    AssetPage(
      menuItem: MenuItem(
          label: label, path: path, icon: Icons.home, children: children),
      assets: const [],
      mirroringDisabled: false,
      published: published,
    );

/// A session that resolves to whatever the test needs.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._value);
  final AsyncValue<AccessSession> _value;

  @override
  Future<AccessSession> build() async {
    final value = _value;
    if (value is AsyncData<AccessSession>) return value.value;
    return Completer<AccessSession>().future;
  }

  @override
  Future<AccessSignInResult> signIn(String u, String p) async =>
      AccessSignInResult.ok;
  @override
  Future<void> signOut() async {}
  @override
  void poke() {}
}

AccessSession _sessionWith({
  Set<AccessGroup> groups = const {AccessGroup.operate},
  Set<String>? pages,
}) =>
    AccessSession(groups: groups, allowedPages: pages);

ProviderContainer _container({
  required List<MenuItem> registry,
  AccessSession? session,
  PageManager? manager,
  MenuComposer? composer,
}) {
  RouteRegistry().menuItems
    ..clear()
    ..addAll(registry);
  RouteRegistry().clearRouteGroups();
  installRaisedRoutes();

  final container = ProviderContainer(overrides: [
    accessSessionProvider.overrideWith(
        () => _FixedSession(AsyncValue.data(session ?? _sessionWith()))),
    accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
    bootstrapPageManagerProvider.overrideWithValue(manager),
    if (composer != null) menuComposerProvider.overrideWithValue(composer),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Settles the session future so the filter is answering on a real session
/// rather than on the boot-window floor.
Future<void> _settle(ProviderContainer container) =>
    container.read(accessSessionProvider.future);

void main() {
  const home = MenuItem(label: 'Home', path: '/', icon: Icons.home);
  const fillet =
      MenuItem(label: 'Filleting', path: '/fillet', icon: Icons.cut);
  const packing =
      MenuItem(label: 'Packing', path: '/packing', icon: Icons.inventory);

  group('menuTree without a composer', () {
    test('reads the registry and never overwrites it', () async {
      final container = _container(registry: [home, fillet]);
      expect(container.read(menuTreeProvider).map((i) => i.path),
          ['/', '/fillet']);
      // The entries a harness registered are still there: nothing composed
      // them away.
      expect(RouteRegistry().menuItems, hasLength(2));
    });
  });

  group('menuTree with a composer', () {
    test('composes from the page manager and owns the registry', () async {
      final manager = PageManager(
        pages: {'/': _page('Home', '/'), '/fillet': _page('Filleting', '/fillet')},
        prefs: _NullPrefs(),
      );
      final container = _container(
        registry: const [MenuItem(label: 'Stale', path: '/stale', icon: Icons.abc)],
        manager: manager,
        composer: (m) => m.getRootMenuItems(),
      );

      final tree = container.read(menuTreeProvider);
      expect(tree.map((i) => i.path), containsAll(['/', '/fillet']));
      expect(tree.map((i) => i.path), isNot(contains('/stale')),
          reason: 'the composer owns the menu once one is supplied');
      expect(RouteRegistry().menuItems.map((i) => i.path),
          isNot(contains('/stale')),
          reason: 'the registry is the mirror and is rewritten with it');
    });

    test('redeclares route groups, so a removed group is unraised', () async {
      // The staleness the boot-time-once call had: declaring writes nothing
      // for a page with no group, so a `requiredGroup` removed in the page
      // editor stayed declared until the next restart.
      final raised = PageManager(
        pages: {
          '/': _page('Home', '/'),
          '/fillet': AssetPage(
            menuItem: const MenuItem(
                label: 'Filleting',
                path: '/fillet',
                icon: Icons.cut,
                requiredGroup: AccessGroup.configure),
            assets: const [],
            mirroringDisabled: false,
          ),
        },
        prefs: _NullPrefs(),
      );
      final container = _container(
        registry: const [],
        manager: raised,
        composer: (m) => m.getRootMenuItems(),
      );
      container.read(menuTreeProvider);
      expect(accessGroupForRoute('/fillet'), AccessGroup.configure);

      // The group is taken off the page and the tree recomposed.
      final unraised = PageManager(
        pages: {'/': _page('Home', '/'), '/fillet': _page('Filleting', '/fillet')},
        prefs: _NullPrefs(),
      );
      RouteRegistry().replaceMenu(
        unraised.getRootMenuItems(),
        declareGroups: () {
          installRaisedRoutes();
          declareMenuRouteGroups(unraised.getRootMenuItems());
        },
      );
      expect(accessGroupForRoute('/fillet'), AccessGroup.operate);
      // And the built-ins are still declared: clearing must be followed by
      // reinstalling them, in that order.
      expect(accessGroupForRoute('/advanced/access'), AccessGroup.users);
    });
  });

  group('visibleMenu filtering', () {
    test('no whitelist keeps every entry, in tree order', () async {
      final container = _container(registry: [home, fillet, packing]);
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/', '/fillet', '/packing']);
    });

    test('a whitelist drops the pages it does not name', () async {
      final container = _container(
        registry: [home, fillet, packing],
        session: _sessionWith(pages: const {'/', '/packing'}),
      );
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/', '/packing']);
    });

    test('filtering never reorders what survives', () async {
      // Ordering is `page_editor_top_level_order`'s business and visibility is
      // this provider's; the two must not negotiate.
      final container = _container(
        registry: [packing, home, fillet],
        session: _sessionWith(pages: const {'/fillet', '/packing'}),
      );
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/packing', '/fillet']);
    });

    test('a section whose every page is hidden goes too', () async {
      const section = MenuItem(
        label: 'Processing',
        path: '/processing',
        icon: Icons.factory,
        isSection: true,
        children: [fillet, packing],
      );
      final container = _container(
        registry: [home, section],
        session: _sessionWith(pages: const {'/'}),
      );
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.label),
          ['Home']);
    });

    test('a section keeps the children that survive', () async {
      const section = MenuItem(
        label: 'Processing',
        path: '/processing',
        icon: Icons.factory,
        isSection: true,
        children: [fillet, packing],
      );
      final container = _container(
        registry: [home, section],
        session: _sessionWith(pages: const {'/', '/fillet'}),
      );
      await _settle(container);
      final visible = container.read(visibleMenuProvider).topLevel;
      expect(visible.map((i) => i.label), ['Home', 'Processing']);
      expect(visible.last.children.map((i) => i.path), ['/fillet']);
    });

    test('a whitelist can grant a built-in, and hides the ones it omits',
        () async {
      // The picker offers the built-ins now, so the filter has to honour them
      // both ways. Before this, no whitelist could name one: they were hidden
      // from any restricted session and ungrantable.
      const advanced = MenuItem(
        label: 'Advanced',
        path: '/advanced',
        icon: Icons.settings,
        isSection: true,
        children: [
          MenuItem(
              label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm),
          MenuItem(
              label: 'History View',
              path: '/advanced/history-view',
              icon: Icons.history),
        ],
      );
      final container = _container(
        registry: [home, advanced],
        session: _sessionWith(pages: const {'/', '/alarm-view'}),
      );
      await container.read(accessRepositoryProvider.future);
      await _settle(container);

      final visible = container.read(visibleMenuProvider).topLevel;
      expect(visible.map((i) => i.label), ['Home', 'Advanced']);
      expect(visible.last.children.map((i) => i.path), ['/alarm-view']);
    });

    test('no whitelist can hide the access screen', () async {
      // Layer 1 of the no-lockout argument. It was prose in the design note
      // and nothing enforced it: this filter asks `resolvePageAccess` about
      // every entry in the tree, so setting any whitelist used to drop the
      // whole Advanced section — the screen that edits whitelists with it.
      const advanced = MenuItem(
        label: 'Advanced',
        path: '/advanced',
        icon: Icons.settings,
        isSection: true,
        children: [
          MenuItem(
              label: 'Page Editor',
              path: '/advanced/page-editor',
              icon: Icons.edit),
          MenuItem(
              label: 'Access',
              path: kAccessAdminRoute,
              icon: Icons.manage_accounts),
        ],
      );
      final container = _container(
        registry: [home, advanced],
        // Block all, and every group held: the state an admin can reach in
        // two clicks and could not previously get back out of from the menu.
        session: _sessionWith(
          groups: AccessGroup.values.toSet(),
          pages: const <String>{},
        ),
      );
      await container.read(accessRepositoryProvider.future);
      await _settle(container);

      final visible = container.read(visibleMenuProvider).topLevel;
      expect(visible.map((i) => i.label), ['Advanced']);
      expect(visible.single.children.map((i) => i.path), [kAccessAdminRoute]);
    });

    test('a section with no children at all is kept', () async {
      // An empty section is a real state — the page editor creates one before
      // anything is put in it — and nothing was hidden, so nothing should
      // disappear.
      const empty = MenuItem(
          label: 'Advanced',
          path: '/advanced',
          icon: Icons.settings,
          isSection: true);
      final container = _container(registry: [home, empty]);
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.label),
          ['Home', 'Advanced']);
    });
  });

  group('VisibleMenu', () {
    test('indexOfPath resolves a page inside a section to the section',
        () async {
      const section = MenuItem(
        label: 'Processing',
        path: '/processing',
        icon: Icons.factory,
        isSection: true,
        children: [fillet],
      );
      final container = _container(registry: [home, section]);
      await _settle(container);
      final visible = container.read(visibleMenuProvider);

      expect(visible.indexOfPath('/'), 0);
      expect(visible.indexOfPath('/fillet'), 1);
      // A path this session cannot see selects nothing rather than the wrong
      // thing — index 0 would highlight whatever happens to be first.
      expect(visible.indexOfPath('/nowhere'), isNull);
      expect(visible.indexOfPath(null), isNull);
    });

    test('showsBar is false below two destinations', () async {
      // Material's NavigationBar asserts it, and a session whitelisted down to
      // one page is a real state now.
      final one = _container(
        registry: [home, fillet],
        session: _sessionWith(pages: const {'/'}),
      );
      await _settle(one);
      expect(one.read(visibleMenuProvider).showsBar, isFalse);

      final two = _container(registry: [home, fillet]);
      await _settle(two);
      expect(two.read(visibleMenuProvider).showsBar, isTrue);
    });

    test('equality is recursive, so a filtered child counts as a change', () {
      // The trap: Riverpod suppresses the update when the new value compares
      // equal, so a shallow equality would freeze the menu at whatever the
      // boot window resolved.
      const both = MenuItem(
        label: 'Processing',
        path: '/processing',
        icon: Icons.factory,
        isSection: true,
        children: [fillet, packing],
      );
      const one = MenuItem(
        label: 'Processing',
        path: '/processing',
        icon: Icons.factory,
        isSection: true,
        children: [fillet],
      );
      expect(const VisibleMenu([both]) == const VisibleMenu([one]), isFalse);
      expect(const VisibleMenu([both]) == const VisibleMenu([both]), isTrue);
    });
  });

  group('the menu never outruns the route table', () {
    test('a page the router cannot serve is not offered', () async {
      // The mismatch the live menu makes possible: the route table is built
      // once at boot from the pages cached locally, and the menu recomposes
      // when the database's copy arrives. A page created on another station
      // would otherwise appear here with nothing behind it.
      RouteRegistry().menuItems
        ..clear()
        ..addAll([home, fillet, packing]);
      RouteRegistry().clearRouteGroups();
      installRaisedRoutes();

      final container = ProviderContainer(overrides: [
        accessSessionProvider.overrideWith(
            () => _FixedSession(AsyncValue.data(_sessionWith()))),
        accessRepositoryProvider
            .overrideWith((ref) async => _StubRepository()),
        bootstrapPageManagerProvider.overrideWithValue(null),
        routablePathsProvider.overrideWithValue(const {'/', '/fillet'}),
      ]);
      addTearDown(container.dispose);
      await container.read(accessSessionProvider.future);

      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/', '/fillet'],
          reason: '/packing has no route, so offering it would be a tap that '
              'lands on "not found"');
    });

    test('null means do not filter, which is what every harness gets',
        () async {
      final container = _container(registry: [home, fillet, packing]);
      await _settle(container);
      expect(container.read(visibleMenuProvider).topLevel, hasLength(3));
    });
  });

  group('the menu changes between logins — the whole point', () {
    test('signing in adds the destinations that identity has', () async {
      // The behaviour the old pipeline could not have: the menu was composed
      // once before `runApp` from a device-local cache, so nothing about
      // signing in could change it. Here the session resolves to a whitelist
      // of one page and is then replaced, and the bar follows.
      RouteRegistry().menuItems
        ..clear()
        ..addAll([home, fillet, packing]);
      RouteRegistry().clearRouteGroups();
      installRaisedRoutes();

      final controller = _SwappableSession(_sessionWith(pages: const {'/'}));
      final container = ProviderContainer(overrides: [
        accessSessionProvider.overrideWith(() => controller),
        accessRepositoryProvider
            .overrideWith((ref) async => _StubRepository()),
        bootstrapPageManagerProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);

      await container.read(accessSessionProvider.future);
      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/'],
          reason: 'the floor identity sees one page');

      // Somebody signs in as an account with no whitelist.
      controller.swap(_sessionWith(pages: null));
      await container.pump();

      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/', '/fillet', '/packing'],
          reason: 'the bar must follow the sign-in without a restart');
    });

    test('signing out takes them away again', () async {
      RouteRegistry().menuItems
        ..clear()
        ..addAll([home, fillet, packing]);
      RouteRegistry().clearRouteGroups();
      installRaisedRoutes();

      final controller = _SwappableSession(_sessionWith(pages: null));
      final container = ProviderContainer(overrides: [
        accessSessionProvider.overrideWith(() => controller),
        accessRepositoryProvider
            .overrideWith((ref) async => _StubRepository()),
        bootstrapPageManagerProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);

      await container.read(accessSessionProvider.future);
      expect(container.read(visibleMenuProvider).topLevel, hasLength(3));

      controller.swap(_sessionWith(pages: const {'/'}));
      await container.pump();

      expect(container.read(visibleMenuProvider).topLevel.map((i) => i.path),
          ['/']);
    });
  });

  group('the registry mirror has one writer', () {
    test('nothing outside the menu provider and the boot path mutates it', () {
      // `menuItems` is a mutable list on a process-global singleton. It is the
      // mirror of `menuTreeProvider` now; a second writer is how the menu and
      // the bar start disagreeing again.
      // `route_registry.dart` declares the list and owns `replaceMenu`;
      // everywhere else in lib/ must go through that one method.
      const owner = 'route_registry.dart';
      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith(owner))) {
        for (final line in file.readAsLinesSync()) {
          final code = line.trim();
          // Comments name these on purpose — this very reasoning is written
          // down in `replaceMenu`'s doc — so only real code counts.
          if (code.startsWith('//') || code.startsWith('///')) continue;
          if (code.contains('menuItems.clear') ||
              code.contains('menuItems.add') ||
              code.contains('addMenuItem(')) {
            offenders.add('${file.path}: $code');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'mutate the menu through RouteRegistry.replaceMenu, which '
              'redeclares the route groups with it — a second writer is how '
              'the menu and the route table start disagreeing again');
    });
  });
}


/// A session controller whose value can be replaced mid-test, which is what
/// signing in and out look like from the menu's side.
class _SwappableSession extends AccessSessionController {
  _SwappableSession(this._initial);

  final AccessSession _initial;

  @override
  Future<AccessSession> build() async => _initial;

  void swap(AccessSession next) => state = AsyncValue.data(next);

  @override
  Future<AccessSignInResult> signIn(String u, String p) async =>
      AccessSignInResult.ok;
  @override
  Future<void> signOut() async {}
  @override
  void poke() {}
}
