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
/// Throws on anything that goes wrong — an unresolvable directory, a corrupt
/// file, an import that dies halfway. `initDeviceLocalPreferences` is the one
/// caller and owns the fallback: it logs the failure with the exception named
/// and answers an in-memory store, because a panel that boots degraded beats
/// a panel that does not boot. The reasoning, and the threat it answers
/// (T-01-14), are on that function.
///
/// [scope] is the station scope every row is written at. [directoryForTest]
/// replaces the platform directory rule so containment can be proved with a
/// resolver that throws and a directory holding a corrupt `config.sqlite`;
/// production passes nothing.
Future<DeviceLocalStoreHandle> openDeviceLocalStore({
  required ConfigScope scope,
  required Logger logger,
  Future<Directory> Function()? directoryForTest,
}) async {
  final dir = await (directoryForTest ?? deviceLocalStoreDirectory)();
  final db = AppDatabase.createLocal(dir);
  final store = SqlitePreferences(db, scope: scope);
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
