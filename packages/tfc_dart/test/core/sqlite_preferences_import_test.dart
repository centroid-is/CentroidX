/// The one-shot `shared_preferences` import.
///
/// What is being proved here is not that values survive a round trip — the
/// store's own suite does that — but that the import runs **exactly once** and
/// that a station's own later edits outlive it. The marker row is the whole
/// mechanism, so most of these tests are about the marker.
library;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';

/// The id the app's import uses. Spelled out rather than imported, because a
/// change to it is a change to whether every station re-imports, and this
/// suite is where that has to be noticed.
const String kMarkerId = '_import.shared_preferences_v1';

const String kStation = 'test-station';

final ConfigScope kScope = ConfigScope.forStation(kStation);

late AppDatabase db;
late SqlitePreferences prefs;

/// Every `config_item` row in the database, at any scope.
Future<List<ConfigItemRow>> items() => db.select(db.configItemTable).get();

/// Every `config_change` row, oldest first.
Future<List<ConfigChangeRow>> changes() =>
    (db.select(db.configChangeTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<ConfigItemRow?> itemAt(String id) =>
    (db.select(db.configItemTable)..where((t) => t.id.equals(id)))
        .getSingleOrNull();

void main() {
  setUp(() {
    db = AppDatabase.inMemoryForTest();
    prefs = SqlitePreferences(db, scope: kScope);
  });

  tearDown(() => db.close());

  group('importAll the three keys that must survive', () {
    test('startup_url, access.session and mcp.config land as typed rows',
        () async {
      final imported = await prefs.importAll({
        'startup_url': '/roe',
        'access.session': '{"token":"abc","role":"operator"}',
        'mcp.config': '{"servers":[]}',
      }, markerId: kMarkerId);

      expect(imported, isTrue);
      expect(await prefs.getString('startup_url'), '/roe');
      expect(await prefs.getString('access.session'),
          '{"token":"abc","role":"operator"}');
      expect(await prefs.getString('mcp.config'), '{"servers":[]}');
    });

    test('every type PreferencesApi carries survives the import', () async {
      await prefs.importAll({
        'b': true,
        'i': 7,
        'd': 7.5,
        's': 'seven',
        'l': ['a', 'b'],
      }, markerId: kMarkerId);

      expect(await prefs.getBool('b'), isTrue);
      expect(await prefs.getInt('i'), 7);
      expect(await prefs.getDouble('d'), 7.5);
      expect(await prefs.getString('s'), 'seven');
      expect(await prefs.getStringList('l'), ['a', 'b'],
          reason: 'list order is part of the value');
    });

    test('an import writes the same payload a set* would', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);
      final imported = (await itemAt('startup_url'))!.payload;

      final other = AppDatabase.inMemoryForTest();
      addTearDown(other.close);
      await SqlitePreferences(other, scope: kScope)
          .setString('startup_url', '/roe');
      final written = await (other.select(other.configItemTable)
            ..where((t) => t.id.equals('startup_url')))
          .getSingle();

      expect(imported, written.payload,
          reason: 'if the two encodings differed, the first post-import write '
              'of an unchanged value would read as a change');
    });
  });

  group('importAll is one action', () {
    test('every change row shares one actionId, and every op is insert',
        () async {
      await prefs.importAll({'a': '1', 'b': 2, 'c': true}, markerId: kMarkerId);

      final rows = await changes();
      expect(rows, hasLength(4), reason: 'three keys plus the marker');
      expect(rows.map((c) => c.actionId).toSet(), hasLength(1),
          reason: 'one import is one action, not four unrelated ones');
      expect(rows.map((c) => c.op).toSet(), {'insert'});
    });

    test('the marker row is written with the import, not after it', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);

      expect(await prefs.containsKey(kMarkerId), isTrue);
      final markerChange =
          (await changes()).singleWhere((c) => c.entityId == kMarkerId);
      final valueChange =
          (await changes()).singleWhere((c) => c.entityId == 'startup_url');
      expect(markerChange.actionId, valueChange.actionId,
          reason: 'rows and marker land together or not at all');
    });
  });

  group('importAll is idempotent', () {
    test('a second import returns false and writes nothing', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);
      final itemsBefore = (await items()).length;
      final changesBefore = (await changes()).length;

      final second = await prefs.importAll(
          {'startup_url': '/other', 'new': 'x'},
          markerId: kMarkerId);

      expect(second, isFalse);
      expect((await items()).length, itemsBefore);
      expect((await changes()).length, changesBefore);
      expect(await prefs.getString('startup_url'), '/roe',
          reason: 'the station edit wins; the legacy file is not authoritative '
              'a second time');
      expect(await prefs.containsKey('new'), isFalse);
    });

    test('a key deleted after the import stays deleted', () async {
      await prefs.importAll({'startup_url': '/roe', 'keep': 'me'},
          markerId: kMarkerId);
      await prefs.remove('startup_url');

      await prefs.importAll({'startup_url': '/roe', 'keep': 'me'},
          markerId: kMarkerId);

      expect(await prefs.containsKey('startup_url'), isFalse,
          reason: 'per-key insert-if-absent alone would resurrect it');
      expect(await prefs.getString('keep'), 'me');
    });

    test(
        'an import over rows that already hold those values writes only the '
        'marker', () async {
      await prefs.setString('startup_url', '/roe');
      final changesBefore = (await changes()).length;

      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);

      final added = (await changes()).skip(changesBefore).toList();
      expect(added, hasLength(1));
      expect(added.single.entityId, kMarkerId,
          reason: 'the dedupe in the row writer holds inside the import too');
    });
  });

  group('importAll skips what it cannot store', () {
    test('an unsupported value costs that key and nothing else', () async {
      final imported = await prefs.importAll({
        'good': 'yes',
        'ints': [1, 2],
        'alsoGood': 3,
      }, markerId: kMarkerId);

      expect(imported, isTrue);
      expect(await prefs.getString('good'), 'yes');
      expect(await prefs.getInt('alsoGood'), 3);
      expect(await prefs.containsKey('ints'), isFalse,
          reason: 'PreferencesApi carries List<String>, not List<int>');
    });

    test('a null value is skipped rather than stored as a null row', () async {
      await prefs
          .importAll({'good': 'yes', 'nothing': null}, markerId: kMarkerId);

      expect(await prefs.containsKey('nothing'), isFalse);
      expect(await prefs.getString('good'), 'yes');
    });

    test('a list of strings typed as List<dynamic> still imports', () async {
      // The raw-file fallback in device_local_store decodes JSON, so its lists
      // arrive as List<dynamic> rather than List<String>.
      final raw = <String, Object?>{
        'ntp_servers': <dynamic>['a.pool', 'b.pool'],
      };

      await prefs.importAll(raw, markerId: kMarkerId);

      expect(await prefs.getStringList('ntp_servers'), ['a.pool', 'b.pool']);
    });
  });

  group('the marker is bookkeeping, not a preference', () {
    test('it never appears in getKeys or getAll', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);

      expect(await prefs.getKeys(), {'startup_url'});
      expect(await prefs.getAll(), {'startup_url': '/roe'});
    });

    test('a bare clear() leaves the marker standing', () async {
      await prefs
          .importAll({'startup_url': '/roe', 'b': 2}, markerId: kMarkerId);

      await prefs.clear();

      expect(await prefs.getAll(), isEmpty);
      expect(await prefs.containsKey(kMarkerId), isTrue,
          reason: 'a clear that took the marker would let the next boot '
              're-import stale shared_preferences over newer local edits');
    });

    test('a clear does not re-open the import', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);
      await prefs.clear();

      final second =
          await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);

      expect(second, isFalse);
    });

    test('an explicit remove of the marker does re-open it', () async {
      await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId);
      await prefs.remove(kMarkerId);

      expect(
        await prefs.importAll({'startup_url': '/roe'}, markerId: kMarkerId),
        isTrue,
        reason: 'naming the marker is a deliberate act; clearing is not',
      );
    });
  });

  group('the import writes only at its own scope', () {
    test("another station's marker does not count as ours", () async {
      final foreign = SqlitePreferences(db,
          scope: ConfigScope.forStation('some-other-station'));
      await foreign.importAll({'startup_url': '/theirs'}, markerId: kMarkerId);

      final imported =
          await prefs.importAll({'startup_url': '/ours'}, markerId: kMarkerId);

      expect(imported, isTrue);
      expect(await prefs.getString('startup_url'), '/ours');
      expect(await foreign.getString('startup_url'), '/theirs');
    });
  });
}
