/// The ten raised routes. This map is the entire blast radius of route
/// gating: a path that is missing from it, or spelled differently from
/// `centroid-hmi/lib/main.dart`, is a route that silently stays open.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_access/tfc_access.dart';

void main() {
  late RouteRegistry registry;

  setUp(() {
    // The registry is a process-wide singleton; the suite must not depend
    // on test order, nor leak declarations into other suites.
    registry = RouteRegistry();
    registry.clearRouteGroups();
  });

  tearDown(() {
    RouteRegistry().clearRouteGroups();
  });

  group('kRaisedRoutes', () {
    test('names exactly the ten routes, each with its group', () {
      // Spelled literally rather than derived, so that a change to the map
      // has to be made twice on purpose.
      expect(kRaisedRoutes, {
        '/advanced/page-editor': AccessGroup.configure,
        '/advanced/alarm-editor': AccessGroup.configure,
        '/advanced/key-repository': AccessGroup.configure,
        '/advanced/knowledge-base': AccessGroup.configure,
        '/advanced/report-editor': AccessGroup.configure,
        '/advanced/server-config': AccessGroup.administer,
        '/advanced/ip-settings': AccessGroup.administer,
        '/advanced/preferences': AccessGroup.administer,
        '/advanced/audit-trail': AccessGroup.users,
        '/advanced/access': AccessGroup.users,
      });
    });

    test('has exactly ten entries', () {
      expect(kRaisedRoutes, hasLength(10));
    });

    test('the three editors need configure', () {
      expect(kRaisedRoutes['/advanced/page-editor'], AccessGroup.configure);
      expect(kRaisedRoutes['/advanced/alarm-editor'], AccessGroup.configure);
      expect(kRaisedRoutes['/advanced/key-repository'], AccessGroup.configure);
    });

    test('the knowledge base needs configure', () {
      // Not a read surface: docs/access-control-write-path-sweep.md §3.1
      // found three raw-Drift index classes behind this page, one of whose
      // callers rewrites `page_editor_data` — the key the configure-gated
      // page editor saves. It takes the same group the page editor takes.
      expect(kRaisedRoutes['/advanced/knowledge-base'], AccessGroup.configure);
    });

    test('the three station-configuration routes need administer', () {
      expect(kRaisedRoutes['/advanced/server-config'], AccessGroup.administer);
      expect(kRaisedRoutes['/advanced/ip-settings'], AccessGroup.administer);
      expect(kRaisedRoutes['/advanced/preferences'], AccessGroup.administer);
    });

    test('the audit trail needs users', () {
      // The only `users` entry, and the only route raised for what it
      // *displays* rather than what it writes. The trail is every setpoint
      // change anybody ever made, with old and new values, its author and its
      // station; lowering it to `configure` would put that in front of anyone
      // who can edit a page or import a key map.
      expect(kRaisedRoutes[kAuditTrailRoute], AccessGroup.users);
      expect(kAuditTrailRoute, '/advanced/audit-trail');
    });

    test('the audit trail route and kAuditTrailGroup are one decision', () {
      // `lib/core/audit_trail_store.dart` names the group and this map spells
      // it, because `lib/core/` and the route table are two files and the
      // store's reads are deliberately ungated — the route gate is the whole
      // enforcement. A drift between these two lines is a page open to the
      // wrong people, with nothing else in the repo to notice.
      expect(kRaisedRoutes[kAuditTrailRoute], kAuditTrailGroup,
          reason: 'the store names the group and the route spells it; a drift '
              'between them is a page open to the wrong people');
    });

    test('the admin screen needs users', () {
      // The second `users` entry, and the one whose route gate is the whole of
      // the enforcement for *reading*: `AccessAdminStore` gates every write,
      // but its reads are deliberately ungated, because a row in the trail
      // every time somebody opened the roles list would bury the writes that
      // matter. So this line is what stops an anonymous panel from reading the
      // account list and every role's group set.
      expect(kRaisedRoutes[kAccessAdminRoute], AccessGroup.users);
      expect(kAccessAdminRoute, '/advanced/access');
    });

    test('the admin route and kAccessAdminGroup are one decision', () {
      expect(kRaisedRoutes[kAccessAdminRoute], kAccessAdminGroup,
          reason: 'the store names the group and the map spells it; a drift '
              'between them is a screen open to the wrong people');
    });

    test('exactly two routes are raised to users', () {
      // The audit trail and the admin screen, in map order. A third arriving
      // without a decision behind it fails here rather than shipping.
      final users = kRaisedRoutes.entries
          .where((e) => e.value == AccessGroup.users)
          .map((e) => e.key);

      expect(users, [kAuditTrailRoute, kAccessAdminRoute]);
    });

    test('no entry is operate', () {
      // A raised route that resolves to `operate` is an open route wearing a
      // lock: anonymous holds `operate`, so the badge would lie.
      expect(kRaisedRoutes.values, isNot(contains(AccessGroup.operate)));
    });

    test('every key is an absolute path', () {
      // A relative path would never match a Beamer path, so the route would
      // stay open while the map claimed otherwise.
      for (final path in kRaisedRoutes.keys) {
        expect(path, startsWith('/'), reason: '$path is not absolute');
      }
    });
  });

  group('routeAllowedWhenRepositoryUnavailable', () {
    test('kServerConfigRoute is itself a raised route', () {
      // The exemption must name a route that is actually raised, or it
      // exempts nothing and the real Server Config route stays gated.
      expect(kRaisedRoutes, contains(kServerConfigRoute));
      expect(kServerConfigRoute, '/advanced/server-config');
    });

    test('answers true for the server config route', () {
      expect(routeAllowedWhenRepositoryUnavailable(kServerConfigRoute), isTrue);
    });

    test('answers false for every other raised route', () {
      for (final path in kRaisedRoutes.keys) {
        if (path == kServerConfigRoute) continue;
        expect(routeAllowedWhenRepositoryUnavailable(path), isFalse,
            reason: '$path must stay denied while the repository is down');
      }
    });

    test('is true for exactly one raised route', () {
      final exempt =
          kRaisedRoutes.keys.where(routeAllowedWhenRepositoryUnavailable);

      expect(exempt, [kServerConfigRoute]);
    });

    test('answers false for the admin screen', () {
      // The page where an exemption would be worst: with no repository there
      // is no role table, so an exempt admin page would edit nothing while
      // looking like it worked.
      expect(routeAllowedWhenRepositoryUnavailable(kAccessAdminRoute), isFalse);
    });

    test('answers false for the audit trail', () {
      // No exemption, and the reason is not symmetry: the trail *is* the
      // database, so "readable while the database is down" would be
      // incoherent as well as unsafe.
      expect(routeAllowedWhenRepositoryUnavailable(kAuditTrailRoute), isFalse);
    });

    test('answers false for an unraised path', () {
      expect(routeAllowedWhenRepositoryUnavailable('/alarm-view'), isFalse);
    });

    test('answers false for null', () {
      expect(routeAllowedWhenRepositoryUnavailable(null), isFalse);
    });
  });

  group('installRaisedRoutes', () {
    test('declares each of the ten into the registry', () {
      installRaisedRoutes();

      kRaisedRoutes.forEach((path, group) {
        expect(registry.groupForRoute(path), group, reason: path);
      });
    });

    test('leaves every other path answering operate', () {
      installRaisedRoutes();

      expect(registry.groupForRoute('/alarm-view'), AccessGroup.operate);
      expect(registry.groupForRoute('/advanced/about-linux'),
          AccessGroup.operate);
      expect(registry.groupForRoute('/advanced'), AccessGroup.operate);
      expect(registry.groupForRoute(null), AccessGroup.operate);
    });

    test('is idempotent', () {
      installRaisedRoutes();
      installRaisedRoutes();

      kRaisedRoutes.forEach((path, group) {
        expect(registry.groupForRoute(path), group, reason: path);
      });
      expect(registry.groupForRoute('/alarm-view'), AccessGroup.operate);
    });

    test('accepts an explicit registry', () {
      // Same singleton today, but the seam keeps the function testable if
      // the registry ever stops being process-wide.
      installRaisedRoutes(registry);

      expect(registry.groupForRoute(kServerConfigRoute),
          AccessGroup.administer);
    });
  });

  group('accessGroupForRoute', () {
    test('agrees with the registry for every path, known or not', () {
      installRaisedRoutes();

      for (final path in [
        ...kRaisedRoutes.keys,
        '/alarm-view',
        '/nobody/declared/this',
        null,
      ]) {
        expect(accessGroupForRoute(path), registry.groupForRoute(path),
            reason: '${path ?? 'null'}');
      }
    });

    test('answers operate before the routes are installed', () {
      expect(accessGroupForRoute(kServerConfigRoute), AccessGroup.operate);
    });

    test('answers the mapped group after they are installed', () {
      installRaisedRoutes();

      expect(accessGroupForRoute('/advanced/page-editor'),
          AccessGroup.configure);
      expect(accessGroupForRoute(kServerConfigRoute), AccessGroup.administer);
    });
  });
}
