/// Routing the app's `Logger` to the browser console in a release build.
///
/// `package:logger`'s default filter is `DevelopmentFilter`, which prints
/// nothing when `kReleaseMode` is set — the right default for a station,
/// where a log file exists and the console is nobody's. A release web build
/// has no file and the console is the only place a message can go, and
/// measured on 2026-09-16 that meant an asset registry that could not match
/// a single name said so through `Logger` and was heard by nobody: every
/// page rendered empty and nothing explained it. `debugPrint` on that one
/// path made the failure visible; this makes the rest of the app's logging
/// visible the same way, once, at boot.
///
/// Info and above, deliberately: `Logger.level` defaults to `trace`, and the
/// relay client alone traces every frame. What an operator or a developer
/// opening the console on a plant tablet needs is what went wrong and what
/// changed, not the update lane.
library;

import 'package:logger/logger.dart';

/// Makes every `Logger()` in the app print to the console at [Level.info]
/// and above, release build or not. Call once, before anything logs.
void routeLoggerToConsole({Level level = Level.info}) {
  Logger.level = level;
  Logger.defaultFilter = () => ProductionFilter();
}
