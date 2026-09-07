/// Where this machine's own configuration lives, and how the store it replaces
/// is read one last time.
///
/// ## The directory rule
///
/// `config.sqlite` goes in **the same directory `shared_preferences` already
/// writes `shared_preferences.json` to, resolved the same way
/// `shared_preferences` resolves it** — by constructing the `path_provider_*`
/// platform class directly rather than going through `package:path_provider`.
///
/// | Platform | Directory | Resolved by |
/// |---|---|---|
/// | Windows | `%APPDATA%\<Company>\<Product>\` | `PathProviderWindows().getApplicationSupportPath()` |
/// | Linux / eLinux | `$XDG_DATA_HOME/<app-id>/` | `PathProviderLinux().getApplicationSupportPath()` |
/// | macOS (development only) | `~/Library/Application Support/<bundle-id>/` | `getApplicationSupportDirectory()` |
///
/// Two reasons, and the second is the load-bearing one.
///
/// **Because the import in this file has to find that exact file.** A rule that
/// resolves "somewhere sensible" would work everywhere except the one machine
/// whose `shared_preferences.json` is somewhere else, and that machine is a
/// station in a fish factory.
///
/// **Because plugin registration cannot be assumed on flutter-elinux.** Its
/// generated entrypoint only registers plugins that declare an `elinux:`
/// platform key, and neither `path_provider_linux` nor
/// `shared_preferences_linux` declares one — they declare `linux:`. Going
/// through `package:path_provider` therefore depends on a registration that may
/// not have happened; constructing `PathProviderLinux()` ourselves sidesteps
/// the question entirely. It is literally what the `shared_preferences`
/// implementation running on the stations today does
/// (`shared_preferences_linux:159`, `shared_preferences_windows:160`), so it
/// cannot be less reliable than the status quo. See `01-RESEARCH.md` Q1 and
/// contradiction C-2's sibling argument.
///
/// On an eLinux station the resulting path lands inside `/home/centroid/.local/
/// share/`, which `docker-compose.yml` already bind-mounts from `./local-share`
/// and chowns to the app user — so the database is on a persistent host
/// directory with no compose change, and everything outside that mount is
/// ephemeral, which is why writing anywhere else would silently lose the
/// startup page on every image update.
///
/// macOS is the exception and is development-only: preferences live in
/// `NSUserDefaults` there, not in a file, so there is no directory to match and
/// `package:path_provider` is registered anyway.
library;

import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The id of the row that records the one-shot import has run.
///
/// A row and not a file, so a database restored from a backup carries the flag
/// along with the data it describes; underscore-prefixed, so
/// `SqlitePreferences` keeps it out of `getKeys`, `getAll` and `clear`. The
/// `_v1` is not decoration: a future import of some other legacy store gets its
/// own marker rather than reusing this one.
const String sharedPreferencesImportMarkerId = '_import.shared_preferences_v1';

/// The file `shared_preferences` writes on Windows and Linux — a flat JSON
/// object. `shared_preferences_windows:17,52` and its Linux twin both name it
/// `shared_preferences`, for the legacy and the async API alike.
const String legacySharedPreferencesFileName = 'shared_preferences.json';

/// The prefix `SharedPreferences.getInstance()` puts on every key it writes
/// (`shared_preferences_legacy.dart:22`). `SharedPreferencesAsync` does not,
/// and both APIs read and write the same physical store — so the same
/// preference can be spelled two ways in one file.
const String _legacyKeyPrefix = 'flutter.';

/// Only ever used off the happy path.
final Logger _defaultLogger = Logger();

/// The directory this machine's own configuration is stored in, created if it
/// does not exist yet.
///
/// See the library doc for the rule and the reasoning. Throws a [StateError]
/// when the platform cannot name a path: a station that cannot resolve its own
/// data directory must fail loudly at boot rather than quietly write the
/// database beside the executable, where the next image update deletes it.
Future<Directory> deviceLocalStoreDirectory() async {
  final String? path;
  if (Platform.isWindows) {
    path = await PathProviderWindows().getApplicationSupportPath();
  } else if (Platform.isLinux) {
    path = await PathProviderLinux().getApplicationSupportPath();
  } else {
    // macOS in development, and anything else that ever runs this code.
    path = (await path_provider.getApplicationSupportDirectory()).path;
  }
  if (path == null || path.isEmpty) {
    throw StateError(
      'Could not resolve the application support directory on '
      '${Platform.operatingSystem}. The device-local configuration store has '
      'nowhere to live; refusing to guess a path.',
    );
  }
  final directory = Directory(path);
  if (!directory.existsSync()) await directory.create(recursive: true);
  return directory;
}

/// Everything the legacy `shared_preferences` store holds, keys spelled exactly
/// as they are stored.
///
/// The tested path is `SharedPreferencesAsync().getAll()` with no allowList,
/// which returns the whole store — legacy-written keys included — with its
/// values already typed, on every platform this app runs on, `NSUserDefaults`
/// included (`01-RESEARCH.md` Q7).
///
/// **On any throw it falls back to reading [legacySharedPreferencesFileName]
/// out of [dir] directly.** The residual eLinux risk is that no platform
/// implementation is registered, in which case the constructor itself throws a
/// `StateError` before a single key has been read; the file is a flat JSON
/// object of exactly the same keys, so the fallback turns "the station lost its
/// startup page" into "the station imported anyway". On macOS there is no such
/// file — preferences are in `NSUserDefaults` — so the fallback finds nothing
/// and returns an empty map, which is the right answer there and needs no
/// platform branch to produce.
///
/// A missing, corrupt, or wrongly-shaped file is an **empty store, never an
/// exception** (T-01-11): this runs before `runApp`, and an import that cannot
/// read its source must cost the import and not the boot. Every such case is
/// logged, because a station that silently imported nothing looks identical to
/// one that had nothing to import.
Future<Map<String, Object?>> readLegacySharedPreferences(
  Directory dir, {
  Logger? logger,
}) async {
  final log = logger ?? _defaultLogger;
  try {
    return await SharedPreferencesAsync().getAll();
  } catch (e) {
    log.w('shared_preferences is not readable through its plugin ($e); '
        'falling back to $legacySharedPreferencesFileName in ${dir.path}');
    return _readLegacyFile(dir, log);
  }
}

Map<String, Object?> _readLegacyFile(Directory dir, Logger log) {
  final file = File(p.join(dir.path, legacySharedPreferencesFileName));
  if (!file.existsSync()) {
    log.i('No $legacySharedPreferencesFileName in ${dir.path}: there is '
        'nothing to import.');
    return const {};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (e) {
    log.w('$legacySharedPreferencesFileName in ${dir.path} could not be '
        'parsed ($e); importing nothing.');
    return const {};
  }
  if (decoded is! Map) {
    log.w('$legacySharedPreferencesFileName in ${dir.path} is a '
        '${decoded.runtimeType}, not the flat object shared_preferences '
        'writes; importing nothing.');
    return const {};
  }
  return {
    for (final entry in decoded.entries) '${entry.key}': entry.value,
  };
}

/// [raw] with the legacy `flutter.` prefix stripped from the keys that carry
/// it.
///
/// Pure, and the whole reason it exists is that one physical store is written
/// through two APIs that spell keys differently:
/// `SharedPreferences.getInstance()` prefixes (`theme_mode`, `color_scheme`
/// and the five `dbus_login` keys), `SharedPreferencesAsync` does not
/// (everything else). Importing verbatim would give a station a `theme_mode`
/// nothing ever reads.
///
/// **On a collision the unprefixed value wins** — it is the one the app has
/// been reading through `PreferencesApi` — and the collision is logged. The two
/// key sets are disjoint today (`01-RESEARCH.md` Q7 enumerates both), so this
/// should never fire; if it does, somebody renamed a key and the log line is
/// how that gets noticed rather than silently resolved.
Map<String, Object?> normalizeLegacyKeys(
  Map<String, Object?> raw, {
  Logger? logger,
}) {
  final log = logger ?? _defaultLogger;
  final normalized = <String, Object?>{};
  // Unprefixed first, so a prefixed key can never overwrite one and the
  // outcome does not depend on iteration order.
  for (final entry in raw.entries) {
    if (!entry.key.startsWith(_legacyKeyPrefix)) {
      normalized[entry.key] = entry.value;
    }
  }
  for (final entry in raw.entries) {
    if (!entry.key.startsWith(_legacyKeyPrefix)) continue;
    final stripped = entry.key.substring(_legacyKeyPrefix.length);
    // A key that is exactly 'flutter.' strips to nothing; it is not a prefixed
    // spelling of anything, so it stays as it is.
    if (stripped.isEmpty) {
      normalized[entry.key] = entry.value;
      continue;
    }
    if (raw.containsKey(stripped)) {
      log.w('Legacy preference "${entry.key}" collides with "$stripped"; '
          'keeping the unprefixed value, which is the one the app reads. The '
          'two key sets are meant to be disjoint — check whether a key was '
          'renamed.');
      continue;
    }
    normalized[stripped] = entry.value;
  }
  return normalized;
}
