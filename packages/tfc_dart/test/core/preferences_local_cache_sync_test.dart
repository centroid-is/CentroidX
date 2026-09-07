/// What `Preferences.syncToLocalCache` costs when nothing has changed.
///
/// The sync copies the whole in-memory cache — including a 530 kB
/// `key_mappings` and a 145 kB `page_editor_data` — into the device-local
/// store on every startup and every database reconnect. It used to guard each
/// write with a "does this differ from what is on disk" check, because the
/// local cache was `shared_preferences`, whose Windows setter re-encodes and
/// rewrites the entire preference file per call (35.5 ms for four keys against
/// a 754,707-byte file). That guard is gone as of milestone v1.2 plan 01-06.
///
/// It is gone because the same guarantee moved into `SqlitePreferences`, and
/// this file is where that is asserted rather than assumed. So the question
/// these tests ask is no longer "how many times did the sync call a setter" —
/// that number is now the key count, by design — but the one that actually
/// matters: **how many rows did the store write.** A second identical sync
/// must produce no `config_change` rows and bump no revision. See
/// `01-RESEARCH.md` C-1.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';

const String kStation = 'test-station';
final ConfigScope kScope = ConfigScope.forStation(kStation);

class _NoSecrets implements MySecureStorage {
  @override
  Future<void> delete({required String key}) async {}
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String value}) async {}
}

Preferences _prefsWith(PreferencesApi localCache) => Preferences(
      database: null,
      secureStorage: _NoSecrets(),
      localCache: localCache,
    );

void main() {
  late AppDatabase db;
  late SqlitePreferences cache;

  setUp(() {
    Preferences.clearSecretCache();
    db = AppDatabase.inMemoryForTest();
    cache = SqlitePreferences(db, scope: kScope);
  });

  tearDown(() => db.close());

  /// Every `config_change` row, oldest first.
  Future<List<ConfigChangeRow>> changes() =>
      (db.select(db.configChangeTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  Future<List<ConfigItemRow>> items() => db.select(db.configItemTable).get();

  /// The revision of every stored preference, keyed by id.
  Future<Map<String, int>> revisions() async =>
      {for (final row in await items()) row.id: row.rev};

  /// Fills the caches with one of each type the sync switches on.
  ///
  /// `Preferences`' setters write through to the local cache, so after this
  /// the two sides agree — which is exactly the state a restart finds, and the
  /// state the reconnect tests below measure from. Where a test needs the two
  /// sides to *disagree* (the divergence `loadFromPostgres` produces, since it
  /// fills the memory cache only) it writes to [cache] directly afterwards.
  Future<Preferences> seededPrefs() async {
    final prefs = _prefsWith(cache);
    await prefs.setString('a_string', 'hello');
    await prefs.setInt('an_int', 7);
    await prefs.setDouble('a_double', 1.5);
    await prefs.setBool('a_bool', true);
    await prefs.setStringList('a_list', ['x', 'y']);
    return prefs;
  }

  group('syncToLocalCache', () {
    test('the first sync writes one row per key', () async {
      final prefs = await seededPrefs();

      await prefs.syncToLocalCache();

      expect(await items(), hasLength(5));
      expect(await changes(), hasLength(5));
      expect(await revisions(), {
        'a_string': 1,
        'an_int': 1,
        'a_double': 1,
        'a_bool': 1,
        'a_list': 1,
      });
    });

    test('a second identical sync writes no rows and bumps no revision',
        () async {
      // The normal restart, and the reconnect this test exists for: Postgres
      // hands back exactly what the store already holds. Without the row
      // writer's dedupe this would append five change rows — about 1.4 MB of
      // them on a real station, where two of the values are a 530 kB
      // key_mappings and a 145 kB page_editor_data.
      final prefs = await seededPrefs();
      await prefs.syncToLocalCache();
      final before = await revisions();
      final changesBefore = (await changes()).length;

      await prefs.syncToLocalCache();

      expect(await changes(), hasLength(changesBefore),
          reason: 'an unchanged reconnect must write zero change rows');
      expect(await revisions(), before,
          reason: 'and must bump no revision');
    });

    test('ten reconnects in a row still write nothing', () async {
      final prefs = await seededPrefs();
      await prefs.syncToLocalCache();
      final changesBefore = (await changes()).length;

      for (var i = 0; i < 10; i++) {
        await prefs.syncToLocalCache();
      }

      expect(await changes(), hasLength(changesBefore));
    });

    test('a diverged value is the only row the sync writes', () async {
      final prefs = await seededPrefs();
      await prefs.syncToLocalCache();
      // The store now holds something the memory cache does not — what a
      // reconnect finds when this station's stored copy is stale.
      await cache.setString('a_string', 'stale');
      final changesBefore = (await changes()).length;

      await prefs.syncToLocalCache();

      final log = await changes();
      expect(log, hasLength(changesBefore + 1),
          reason: 'one diverged key, one row');
      expect(log.last.entityId, 'a_string');
      expect(log.last.op, 'update');
      expect(await cache.getString('a_string'), 'hello');
      expect((await revisions())['an_int'], 1,
          reason: 'the keys that did not diverge must not be rewritten');
    });

    test('a type change counts as a change', () async {
      // '7' and 7 are different preferences even though they stringify the
      // same, and the payload tag is what keeps them apart in the row —
      // `DeepCollectionEquality` alone would call them equal.
      final prefs = _prefsWith(cache);
      await prefs.setInt('k', 7);
      await cache.setString('k', '7');
      final changesBefore = (await changes()).length;

      await prefs.syncToLocalCache();

      expect(await changes(), hasLength(changesBefore + 1));
      expect(await cache.getInt('k'), 7);
    });

    test('writes keys the local store no longer has', () async {
      final prefs = _prefsWith(cache);
      await prefs.setString('brand_new', 'v');
      await cache.remove('brand_new');
      final changesBefore = (await changes()).length;

      await prefs.syncToLocalCache();

      expect(await cache.getString('brand_new'), 'v');
      final log = await changes();
      expect(log, hasLength(changesBefore + 1));
      expect(log.last.op, 'insert');
      expect(log.last.entityId, 'brand_new');
    });

    test('leaves device-local keys the database does not know about alone',
        () async {
      // localPreferencesProvider stores per-station settings in the *same*
      // store. The sync is additive on purpose: pruning keys that Postgres has
      // never heard of would wipe them.
      final prefs = _prefsWith(cache);
      await cache.setString('device_only', 'keep me');
      await prefs.setString('shared', 'v');
      final changesBefore = (await changes()).length;

      await prefs.syncToLocalCache();

      expect(await cache.getString('device_only'), 'keep me');
      expect(await changes(), hasLength(changesBefore),
          reason: 'nothing diverged and nothing is pruned, so no rows at all');
      expect(await cache.getString('shared'), 'v');
    });
  });
}
