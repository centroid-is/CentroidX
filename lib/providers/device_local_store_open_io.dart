import 'dart:io' show Directory;

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/config/config_item.dart' show ConfigScope;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';

import '../core/device_local_store.dart';

/// A station keeps a mirror of the plant's `config_item` rows in
/// `config.sqlite`, so `configStoreProvider` can open one over the database
/// this arm returns.
const bool kHasDeviceLocalMirror = true;

/// What [openDeviceLocalStore] hands back: the preferences view of the store,
/// and the database under it when the platform has one.
typedef DeviceLocalStoreHandle = ({AppDatabase? db, PreferencesApi store});

/// Opens `config.sqlite` in the platform's application-support directory and,
/// once ever, imports whatever `shared_preferences` still holds into it.
///
/// ## One scope, never the hostname
///
/// Every row this store reads and writes is at [scope] — `ConfigScope.local`,
/// which `initDeviceLocalPreferences` passes. The file is this station's local
/// preferences and nothing else writes it, so the hostname has no say in
/// which rows are this station's — it only names the station on change rows
/// ([station]). It used to be the scope, and in a container the hostname is
/// the container id: every image update came up on defaults with the
/// commissioned settings still in the file under the old id (#552).
///
/// Before the import, and once ever, rows an older build wrote under any
/// hostname are adopted into [scope], newest write winning
/// ([SqlitePreferences.adoptStationScopes]). Running first is what carries
/// the old scope's import marker across, so the legacy import does not run a
/// second time. A failed adoption is logged and the open carries on with the
/// store: nothing was moved, and the next boot tries again.
///
/// Throws on anything that goes wrong — an unresolvable directory, a corrupt
/// file, an import that dies halfway. `initDeviceLocalPreferences` is the one
/// caller and owns the fallback: it logs the failure with the exception named
/// and answers an in-memory store, because a panel that boots degraded beats
/// a panel that does not boot. The reasoning, and the threat it answers
/// (T-01-14), are on that function.
///
/// [scope] is the one scope every row is read and written at; [station] is
/// the hostname change rows are stamped with (the caller resolves it, and a
/// test substitutes one). [directoryForTest] replaces the platform directory
/// rule so containment can be proved with a resolver that throws and a
/// directory holding a corrupt `config.sqlite`; production passes nothing.
Future<DeviceLocalStoreHandle> openDeviceLocalStore({
  required ConfigScope scope,
  required String station,
  required Logger logger,
  Future<Directory> Function()? directoryForTest,
}) async {
  final dir = await (directoryForTest ?? deviceLocalStoreDirectory)();
  final db = AppDatabase.createLocal(dir);
  final store = SqlitePreferences(db, scope: scope, station: station);
  await _adoptHostnameScopes(store, dir, logger);
  // One shot, marked by a row inside the same transaction as the values it
  // describes. A station that has already imported does no work here.
  final imported = await store.importAll(
    normalizeLegacyKeys(
      await readLegacySharedPreferences(dir, logger: logger),
      logger: logger,
    ),
    markerId: sharedPreferencesImportMarkerId,
  );
  if (imported) {
    logger.i('Imported the legacy shared_preferences store into '
        '${dir.path}/config.sqlite. This happens once per station.');
  }
  return (db: db, store: store);
}

/// Moves rows an older build wrote under a hostname scope into [store]'s,
/// once, and says so in one line.
///
/// Never throws. The store is usable without it — the station comes up on
/// defaults, which is what it did before this existed — and the move is one
/// transaction, so a failure leaves nothing half-done for the next boot to
/// retry. Falling back to the in-memory store over it would lose more than it
/// protects. A database too broken to read fails the import right after, and
/// that is contained by `initDeviceLocalPreferences` as before.
Future<void> _adoptHostnameScopes(
    SqlitePreferences store, Directory dir, Logger logger) async {
  try {
    final adoption = await store.adoptStationScopes(
      markerId: stationScopeAdoptionMarkerId,
    );
    if (adoption != null && adoption.rowsTaken > 0) {
      logger.i('Adopted hostname-scoped preferences into ${store.scope} in '
          '${dir.path}/config.sqlite: $adoption. This happens once per '
          'station.');
    }
  } catch (e, stack) {
    logger.e(
      'Could not adopt hostname-scoped preferences in '
      '${dir.path}/config.sqlite. This station starts on whatever is already '
      'at ${store.scope}; the adoption is retried on the next boot.',
      error: e,
      stackTrace: stack,
    );
  }
}
