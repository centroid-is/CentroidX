/// A route table whose `/` entry is served only when `/` is the location.
///
/// Beamer's [RoutesBeamLocation] stacks a page for every route that
/// sub-matches the location, and `/` — zero path segments — sub-matches every
/// path there is. So whatever stands at `/` was mounted at the bottom of the
/// navigator under every page in the app, for the life of the process, with
/// its `State` alive.
///
/// For the stub a station with no Home page keeps there (`RouteRedirect`),
/// that cost a listener and a guard. For a station with a real Home page it
/// cost the Home page: built, and every one of its assets subscribed to OPC UA,
/// underneath whatever the operator was actually looking at. Nobody asked for
/// that, and on a plant where Home carries live equipment it was a permanent
/// extra subscription set per panel — the kind of volume that turned a
/// 48-byte-per-decode leak into a memory problem.
///
/// ## Where the filter has to live
///
/// In [RootRouteLocation.buildPages], not in the location builder. The
/// delegate calls the builder on every navigation, but when the result is the
/// same runtime type as the location it already holds it **updates that one
/// and discards the new object** (`BeamerDelegate._updateBeamingHistory`). One
/// location therefore lives for the whole process, and a routes map handed to
/// a fresh one never takes effect. `buildPages` is called with the current
/// state every time, so that is the one place the decision is honoured.
///
/// Only `/` is treated this way. A section page under its own child
/// (`/halls` under `/halls/packing`) is Beamer's intended nesting and is left
/// as it is.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/widgets.dart';

typedef _RouteBuilder = dynamic Function(BuildContext, BeamState, Object?);

/// Whether [path] is the root location, as Beamer spells it after
/// normalisation (`''` is matched as `/`).
bool _isRoot(String path) => path.isEmpty || path == '/';

class RootRouteLocationBuilder extends RoutesLocationBuilder {
  RootRouteLocationBuilder({required super.routes, super.builder});

  @override
  BeamLocation call(
    RouteInformation routeInformation,
    BeamParameters? beamParameters,
  ) {
    final matched = RoutesBeamLocation.chooseRoutes(routeInformation, routes.keys);
    if (matched.isEmpty) {
      return NotFound(path: routeInformation.uri.toString());
    }
    return RootRouteLocation(
      routeInformation: routeInformation,
      routes: routes,
      navBuilder: builder,
    );
  }
}

/// [RoutesBeamLocation] with `/` left out of the stack for every location
/// but `/` itself.
class RootRouteLocation extends RoutesBeamLocation {
  RootRouteLocation({
    required super.routeInformation,
    required super.routes,
    super.navBuilder,
  });

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) {
    if (_isRoot(state.uri.path) || !routes.containsKey('/')) {
      return super.buildPages(context, state);
    }
    // The same build as `RoutesBeamLocation.buildPages`, over the routes
    // without `/`: choose what sub-matches, shortest pattern at the bottom.
    // Every pattern this app registers is a `String`, which is the one
    // ordering rule reproduced here.
    final candidates = Map<Pattern, _RouteBuilder>.of(routes)..remove('/');
    final matched = RoutesBeamLocation.chooseRoutes(state.routeInformation, candidates.keys);
    final sorted = matched.keys.toList()..sort((a, b) => a.toString().length.compareTo(b.toString().length));
    return [
      for (final route in sorted)
        switch (candidates[route]!(context, state, data)) {
          final BeamPage page => page,
          final Widget child => BeamPage(
              key: ValueKey(matched[route]),
              child: child,
            ),
          final other => throw StateError('route $route built ${other.runtimeType}, not a Widget'),
        },
    ];
  }
}
