/// The device-local preference store's contract.
///
/// The first three group names are quoted verbatim from the phase's success
/// criteria — "one preference write is one row", "writing the same value again
/// writes nothing", "'7' and 7 are different preferences". They are the proof
/// points the phase exists to establish, not descriptions of the code, so they
/// are named rather than paraphrased.
library;

// `isNull` and `isNotNull` are matchers here, not drift's SQL expressions of
// the same names.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';

/// The station this store belongs to. Every row it writes is scoped to it.
const String kStation = 'test-station';

final ConfigScope kScope = ConfigScope.forStation(kStation);

late AppDatabase db;
late SqlitePreferences prefs;

/// Every `config_item` row in the database, at any scope — the tests that
/// count rows must see rows this store would filter out.
Future<List<ConfigItemRow>> items() => db.select(db.configItemTable).get();

/// Every `config_change` row, oldest first.
Future<List<ConfigChangeRow>> changes() =>
    (db.select(db.configChangeTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// Writes a row directly, bypassing the store — the only way to seed a payload
/// the store itself would never produce.
Future<void> seedRow({
  required String id,
  required String payload,
  ConfigScope? scope,
}) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: ConfigKind.preference.wireName,
          id: id,
          scope: (scope ?? kScope).wireName,
          payload: payload,
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedBy: 'anonymous',
        ));

void main() {
  setUp(() {
    db = AppDatabase.inMemoryForTest();
    prefs = SqlitePreferences(db, scope: kScope);
  });

  tearDown(() => db.close());

  group('one preference write is one row', () {
    test('a first write inserts one item row and one insert change row',
        () async {
      await prefs.setString('startup_url', '/roe');

      final rows = await items();
      expect(rows, hasLength(1));
      expect(rows.single.kind, ConfigKind.preference.wireName);
      expect(rows.single.id, 'startup_url');
      expect(rows.single.scope, kScope.wireName);
      expect(rows.single.rev, 1);

      final log = await changes();
      expect(log, hasLength(1));
      expect(log.single.op, 'insert');
      expect(log.single.oldValue, isNull);
      expect(log.single.newValue, isNotNull);
      expect(log.single.entityId, 'startup_url');
      expect(log.single.scope, kScope.wireName);
      expect(log.single.station, kStation);
      expect(log.single.who, 'anonymous');
    });

    test('a second, different write updates the one row and appends one change',
        () async {
      await prefs.setString('startup_url', '/roe');
      await prefs.setString('startup_url', '/baader');

      final rows = await items();
      expect(rows, hasLength(1), reason: 'one preference is one row, always');
      expect(rows.single.rev, 2);

      final log = await changes();
      expect(log, hasLength(2));
      expect(log.last.op, 'update');
      expect(log.last.oldValue, isNotNull,
          reason: 'an update whose old side is unknown cannot be rolled back');
      expect(log.last.newValue, isNotNull);
      expect(log.last.oldValue, isNot(log.last.newValue));

      expect(await prefs.getString('startup_url'), '/baader');
    });

    test('two preferences are two rows', () async {
      await prefs.setString('a', '1');
      await prefs.setInt('b', 2);

      expect(await items(), hasLength(2));
      expect(await changes(), hasLength(2));
    });
  });

  group('writing the same value again writes nothing', () {
    test('no change row, no rev bump, no new timestamp', () async {
      await prefs.setString('startup_url', '/roe');
      final before = (await items()).single;

      await prefs.setString('startup_url', '/roe');

      final after = (await items()).single;
      expect(after.rev, before.rev, reason: 'a no-op write is not a write');
      expect(after.updatedAt, before.updatedAt);
      expect(await changes(), hasLength(1),
          reason: 'C-1: without this, every reconnect logs 1.4 MB of nothing');
    });

    test('holds for every type, including a list', () async {
      await prefs.setBool('b', true);
      await prefs.setInt('i', 7);
      await prefs.setDouble('d', 7.5);
      await prefs.setString('s', 'seven');
      await prefs.setStringList('l', const ['a', 'b']);
      expect(await changes(), hasLength(5));

      await prefs.setBool('b', true);
      await prefs.setInt('i', 7);
      await prefs.setDouble('d', 7.5);
      await prefs.setString('s', 'seven');
      await prefs.setStringList('l', const ['a', 'b']);

      expect(await changes(), hasLength(5));
      expect((await items()).map((r) => r.rev), everyElement(1));
    });

    test('a reordered list IS a change — order is meaning', () async {
      await prefs.setStringList('l', const ['a', 'b']);
      await prefs.setStringList('l', const ['b', 'a']);

      expect((await items()).single.rev, 2);
      expect(await changes(), hasLength(2));
      expect(await prefs.getStringList('l'), ['b', 'a']);
    });
  });

  group("'7' and 7 are different preferences", () {
    test('a string read as an int throws', () async {
      await prefs.setString('k', '7');

      expect(prefs.getInt('k'), throwsA(isA<TypeError>()));
      expect(await prefs.getString('k'), '7');
    });

    test('an int read as a string throws', () async {
      await prefs.setInt('k', 7);

      expect(prefs.getString('k'), throwsA(isA<TypeError>()));
      expect(await prefs.getInt('k'), 7);
    });

    test('setInt over a stored String is a write — the tag changed', () async {
      await prefs.setString('k', '7');
      await prefs.setInt('k', 7);

      expect((await items()).single.rev, 2);
      expect(await changes(), hasLength(2));
      expect(await prefs.getInt('k'), 7);
    });

    test('setInt(1) over a stored double 1.0 is a write, not a skip', () async {
      await prefs.setDouble('k', 1.0);
      await prefs.setInt('k', 1);

      expect((await items()).single.rev, 2,
          reason: "samePayload's DeepCollectionEquality holds 1 == 1.0; the "
              'type tag is the only thing that rescues this write');
      expect(await changes(), hasLength(2));
      expect(await prefs.getInt('k'), 1);
      expect(prefs.getDouble('k'), throwsA(isA<TypeError>()));
    });
  });

  group('the five types round-trip exactly', () {
    test('bool', () async {
      await prefs.setBool('k', false);
      expect(await prefs.getBool('k'), isFalse);
    });

    test('int', () async {
      await prefs.setInt('k', -42);
      expect(await prefs.getInt('k'), -42);
    });

    test('double keeps its type even at an integral value', () async {
      await prefs.setDouble('k', 7.0);
      expect(await prefs.getDouble('k'), 7.0);
      expect(prefs.getInt('k'), throwsA(isA<TypeError>()));
    });

    test('String', () async {
      await prefs.setString('k', 'a\n"quoted" ünicode 値');
      expect(await prefs.getString('k'), 'a\n"quoted" ünicode 値');
    });

    test('List<String> keeps its order', () async {
      await prefs.setStringList('k', const ['z', 'a', 'm']);
      expect(await prefs.getStringList('k'), ['z', 'a', 'm']);
    });

    test('an empty list is a list, not an absence', () async {
      await prefs.setStringList('k', const []);
      expect(await prefs.getStringList('k'), isEmpty);
      expect(await prefs.containsKey('k'), isTrue);
    });

    test('the payload names the type with the wire string Postgres uses',
        () async {
      await prefs.setStringList('k', const ['a']);
      expect((await items()).single.payload, '{"type":"List<String>","value":["a"]}');
    });
  });

  group('a missing or corrupt row costs a default, never the boot', () {
    test('an absent key reads null on every getter', () async {
      expect(await prefs.getBool('nope'), isNull);
      expect(await prefs.getInt('nope'), isNull);
      expect(await prefs.getDouble('nope'), isNull);
      expect(await prefs.getString('nope'), isNull);
      expect(await prefs.getStringList('nope'), isNull);
      expect(await prefs.containsKey('nope'), isFalse);
    });

    test('a row whose payload is not JSON reads as absent', () async {
      await seedRow(id: 'k', payload: 'not json{');

      expect(await prefs.getString('k'), isNull);
    });

    test('a row whose type tag is unrecognised reads as absent', () async {
      await seedRow(id: 'k', payload: '{"type":"Duration","value":7}');

      expect(await prefs.getInt('k'), isNull);
    });

    test('a row whose value contradicts its tag reads as absent', () async {
      await seedRow(id: 'k', payload: '{"type":"int","value":"seven"}');

      expect(await prefs.getInt('k'), isNull);
    });

    test('a bare scalar payload reads as absent, not as a crash', () async {
      await seedRow(id: 'k', payload: '7');

      expect(await prefs.getInt('k'), isNull);
    });
  });

  group('containsKey', () {
    test('is true once written and false once removed', () async {
      expect(await prefs.containsKey('k'), isFalse);
      await prefs.setInt('k', 1);
      expect(await prefs.containsKey('k'), isTrue);
      await prefs.remove('k');
      expect(await prefs.containsKey('k'), isFalse);
    });
  });
}
