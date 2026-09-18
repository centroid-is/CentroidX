/// One diagnostic line, on whatever this build actually has.
///
/// The app writes these with `stderr.writeln` because [print] is swallowed by
/// a windowed MSIX build with no console, and because a station's launcher
/// captures stderr into the log file support reads months later.
///
/// In a browser `dart:io` exists as a stub whose members **throw**
/// `UnsupportedError` — so every one of these lines, all of which sit inside a
/// `catch`, turned a handled failure into an unhandled one. That is the worst
/// shape a diagnostic can have: the report of the problem becomes a second,
/// louder problem, and the original is lost.
///
/// [kIsWeb] is a compile-time constant, so dart2js drops the `stderr` branch
/// entirely and a station's code path is unchanged.
library;

import 'dart:io' as io;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

void logDiagnostic(String message) {
  if (kIsWeb) {
    // The browser console is the only place a line can go, and it is the
    // place a Playwright run reads.
    debugPrint(message);
    return;
  }
  io.stderr.writeln(message);
}
