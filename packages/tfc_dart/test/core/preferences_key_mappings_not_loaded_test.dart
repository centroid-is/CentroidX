// `key_mappings` is a row in `flutter_preferences` and stays one — as rollback
// insurance until Phase 4 — but as of v1.2 phase 2 plan 06 it is NOT loaded.
//
// This is C-5's exclusion, and the reason it has to be the *memory cache* and
// not merely `syncToLocalCache`: while the blob is in the cache,
// `getString('key_mappings')` answers with it, and any call site this phase
// missed goes on quietly serving a plant's wiring from a copy nobody writes.
// With the exclusion in place a missed call site sees null, which is a test
// failure rather than stale wiring.

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';

/// The keychain, in memory: this suite never touches a secret.
class _InMemorySecureStorage implements MySecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async =>
      _store[key] = value;

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> delete({required String key}) async => _store.remove(key);
}

Future<void> _writePref(AppDatabase db, String key, String value) =>
    db.into(db.flutterPreferences).insert(FlutterPreferencesCompanion.insert(
          key: key,
          value: Value(value),
          type: 'String',
        ));

void main() {
  late AppDatabase appDb;
  late Database database;
  late Preferences prefs;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    Preferences.clearSecretCache();
    appDb = AppDatabase.inMemoryForTest();
    database = Database(appDb);
    prefs = Preferences(database: database, secureStorage: _InMemorySecureStorage());
  });

  tearDown(() async {
    await database.close();
  });

  test('loadFromPostgres leaves key_mappings out of the memory cache',
      () async {
    final blob = jsonEncode({
      'nodes': {
        'CN04.Belt.Speed': {
          'opcua_node': {'namespace': 2, 'identifier': 'Speed'},
        },
      },
    });
    await _writePref(appDb, 'key_mappings', blob);
    await _writePref(appDb, 'alarm_man_config', '{"alarms":[]}');

    await prefs.loadFromPostgres();

    // The row is there — this is not a test of an empty database.
    final row = await (appDb.select(appDb.flutterPreferences)
          ..where((t) => t.key.equals('key_mappings')))
        .getSingleOrNull();
    expect(row?.value, blob,
        reason: 'the blob stays in the table as Phase 4 rollback insurance');

    expect(await prefs.getString('key_mappings'), null,
        reason: 'a call site this phase missed must find null and fail, not '
            'serve a second live copy of the plant wiring');

    // Every other key still loads: this is one exclusion, not a broken loader.
    expect(await prefs.getString('alarm_man_config'), '{"alarms":[]}');
  });
}
