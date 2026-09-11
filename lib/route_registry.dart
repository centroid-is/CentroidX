import 'package:flutter/material.dart';
import 'package:tfc_access/tfc_access.dart';
import 'models/menu_item.dart';

class RouteRegistry {
  static final RouteRegistry _instance = RouteRegistry._internal();
  final Map<String, WidgetBuilder> _routes = {};
  final Map<String, AccessGroup> _routeGroups = {};
  final List<MenuItem> menuItems = [];

  RouteRegistry._internal();

  factory RouteRegistry() {
    return _instance;
  }

  /// Registers a builder, and optionally the access group the route needs.
  ///
  /// [group] is optional and named so that every existing two-argument call
  /// keeps compiling untouched. A null [group] leaves any existing
  /// declaration alone: it neither writes `operate` nor erases a group
  /// declared earlier, so registering a builder can never silently unlock a
  /// route somebody else raised.
  void registerRoute(String path, WidgetBuilder builder, {AccessGroup? group}) {
    _routes[path] = builder;
    if (group != null) {
      declareRouteGroup(path, group);
    }
  }

  /// Declares the group a path needs without registering a builder for it.
  ///
  /// The single write path for [_routeGroups]; [registerRoute] delegates
  /// here. This exists because the nine routes this app raises live in
  /// Beamer's table rather than in this registry — see [groupForRoute].
  void declareRouteGroup(String path, AccessGroup group) {
    _routeGroups[path] = group;
  }

  /// The group a path needs. A path nobody declared answers
  /// [AccessGroup.operate].
  ///
  /// **Why the default is `operate` and not something stricter.** `operate`
  /// is exactly what an anonymous session holds, so a route that declares
  /// nothing behaves precisely as it did before route gating existed. That is
  /// what makes gating shippable with no cutover: only the routes that name a
  /// group change at all. It is the deliberate opposite of the config-key
  /// default in `docs/access-control-spec.md` §7, which fails *closed* on
  /// `administer` — a wrongly-open route is a nuisance, a wrongly-open config
  /// write is a broken plant. Both defaults are choices, not oversights.
  ///
  /// Never returns null and never throws, including for an unknown or null
  /// path, so callers can ask about any path they hold.
  ///
  /// **The live route table is not this registry.** The app routes through
  /// Beamer's `RoutesLocationBuilder` in `centroid-hmi/lib/main.dart`;
  /// `registerRoute` currently has no call sites anywhere in the repo. The
  /// `group:` parameter exists because the spec puts the declaration on
  /// `registerRoute` and because pages registered through the registry later
  /// need somewhere to say it. The nine routes raised today are declared
  /// through [declareRouteGroup] from `lib/access_routes.dart`.
  AccessGroup groupForRoute(String? path) {
    return _routeGroups[path] ?? AccessGroup.operate;
  }

  /// Drops every group declaration, the way `menuItems.clear()` drops the
  /// menu — the singleton outlives a test, so a test needs a known state.
  @visibleForTesting
  void clearRouteGroups() {
    _routeGroups.clear();
  }

  /// Replace the whole menu with [items], and redeclare every route group
  /// from scratch.
  ///
  /// **The one writer.** `menuItems` is a mutable list on a process-global
  /// singleton, and it used to be filled once before `runApp` from a
  /// device-local cache — which is why the navigation bar could not change
  /// when the pages did, or when somebody signed in. It is now a *mirror* of
  /// `menuTreeProvider`, written here and nowhere else;
  /// `test/providers/menu_test.dart` asserts from source that no other file
  /// mutates it. Read the provider, not this list.
  ///
  /// [declareGroups] runs inside the same call so the layering cannot be
  /// assembled wrong at a call site: clear, then the built-in raised routes,
  /// then the groups the operator published pages for. Declaring is
  /// last-writer-wins and idempotent, so the order is what decides, and a
  /// customer page must be able to raise its own path while a page that
  /// declares nothing leaves a built-in route's group alone.
  ///
  /// Clearing first is what fixes a staleness the boot-time-once call had:
  /// `declareMenuRouteGroups` writes nothing for a page with no group, so a
  /// `requiredGroup` *removed* in the page editor stayed declared until the
  /// next restart. Redeclaring from empty unraises it on the next rebuild.
  void replaceMenu(
    List<MenuItem> items, {
    required void Function() declareGroups,
  }) {
    menuItems
      ..clear()
      ..addAll(items);
    _routeGroups.clear();
    declareGroups();
  }

  WidgetBuilder? getBuilder(String path) {
    return _routes[path];
  }

  Map<String, WidgetBuilder> get routes => _routes;

  MenuItem get root {
    return MenuItem(
        label: 'ROOT, SHOULD NEVER BE SEEN',
        icon: Icons.abc,
        children: menuItems);
  }

  void addMenuItem(MenuItem menuItem) {
    _mergeMenuItemRecursive(menuItems, menuItem);
  }

  void _mergeMenuItemRecursive(List<MenuItem> targetList, MenuItem newItem) {
    // Check if item with same path already exists
    for (var i = 0; i < targetList.length; i++) {
      final existingItem = targetList[i];
      if (existingItem.path == newItem.path) {
        // If it exists, merge its children recursively. Merge into a copy:
        // MenuItems are routinely const-constructed, and adding to a const
        // children list throws.
        if (newItem.children.isNotEmpty) {
          final mergedChildren = List<MenuItem>.of(existingItem.children);
          for (var child in newItem.children) {
            _mergeMenuItemRecursive(mergedChildren, child);
          }
          targetList[i] = existingItem.copyWith(children: mergedChildren);
        }
        return;
      }
    }

    // If not found, add it
    targetList.add(newItem);
  }

  int? getNodeIndex(MenuItem nodeItem) {
    final index = menuItems.indexOf(nodeItem);
    if (index != -1) return index;
    return null;
  }

  // Method to retrieve all registered paths
  List<String> getAllPaths() {
    List<String> paths = [];
    for (var dropdown in menuItems) {
      if (dropdown.path != null) {
        paths.add(dropdown.path!);
      }
      if (dropdown.children.isNotEmpty) {
        for (var child in dropdown.children) {
          if (child.path != null) {
            paths.add(child.path!);
          }
        }
      }
    }
    return paths;
  }
}
