/// Puts the operator back on the page they were on after an engine rebuild.
///
/// The Windows runner rebuilds the Flutter engine to recover a lost render
/// context (see `windows/runner/flutter_window.cpp`). A rebuild is a new Dart
/// isolate and a fresh `main()`, so Beamer starts over at the station's
/// configured startup page: an operator who was three levels into the page
/// editor comes back on Home with no explanation.
///
/// The router's location is recorded here on every change, and consulted at
/// boot **only when the runner says this isolate is a rebuild** -- engine
/// epoch 2 or later. A process start (a reboot, an update, a crash restart)
/// is epoch 1 and opens the configured startup page exactly as before; the
/// stored route is then overwritten by the first navigation and never used.
/// Platforms without the runner (Linux, macOS, tests) report no epoch and
/// never resume.
///
/// The route is device-local, like the startup page: it describes what one
/// panel was showing.
///
/// Nothing here throws. A route that cannot be read or written costs the
/// resume, not the start.
library;

import 'package:tfc_dart/core/preferences.dart';

import 'runner_liveness.dart' show EngineEpoch;

/// The device-local preferences key holding the last router location.
const String lastRoutePrefsKey = 'last_route';

/// Whether [epoch] describes an engine the runner rebuilt inside a running
/// process, as opposed to the first engine of a process.
bool isEngineRebuild(EngineEpoch epoch) => epoch.isKnown && epoch.epoch > 1;

/// Reads the recorded location, or null when there is none or it cannot be
/// read.
Future<String?> readLastRoute(PreferencesApi prefs) async {
  try {
    final stored = await prefs.getString(lastRoutePrefsKey);
    if (stored == null || !stored.startsWith('/')) return null;
    return stored;
  } catch (_) {
    return null;
  }
}

/// Records [location] -- the router's full location, query included -- for
/// the next rebuild. Anything that is not an absolute path is ignored.
Future<void> writeLastRoute(PreferencesApi prefs, String location) async {
  if (!location.startsWith('/')) return;
  try {
    await prefs.setString(lastRoutePrefsKey, location);
  } catch (_) {
    // Best effort: a route that is not recorded costs the resume, nothing
    // else, and a preferences store that cannot be written has already been
    // reported by whatever tried first.
  }
}

/// Where the app should open: [lastRoute] when this is a rebuilt engine and
/// the route still leads somewhere, [startupPath] otherwise.
///
/// [isRoutable] is asked with the route's path (query stripped) so a page
/// deleted or unpublished between the rebuild and the last visit falls back
/// rather than landing on "not found". The full location, query included, is
/// what gets restored.
String resolveResumePath({
  required EngineEpoch epoch,
  required String? lastRoute,
  required String startupPath,
  required bool Function(String path) isRoutable,
}) {
  if (!isEngineRebuild(epoch)) return startupPath;
  if (lastRoute == null || !lastRoute.startsWith('/')) return startupPath;
  final path = Uri.tryParse(lastRoute)?.path;
  if (path == null || path.isEmpty || !isRoutable(path)) return startupPath;
  return lastRoute;
}
