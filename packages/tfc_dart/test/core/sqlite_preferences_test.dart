/// The device-local preference store's contract.
///
/// The first three group names are quoted verbatim from the phase's success
/// criteria — "one preference write is one row", "writing the same value again
/// writes nothing", "'7' and 7 are different preferences". They are the proof
/// points the phase exists to establish, not descriptions of the code, so they
/// are named rather than paraphrased.
library;

import 'dart:convert';

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

/// Writes a row of some other kind at this scope — the thing [clear] must not
/// touch however wide its reach.
Future<void> seedOtherKind({required String id}) =>
    db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: ConfigKind.page.wireName,
          id: id,
          scope: kScope.wireName,
          payload: '{"title":"Roe"}',
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

  group('getAll and getKeys', () {
    test('every type comes back as its native Dart value', () async {
      await prefs.setBool('b', true);
      await prefs.setInt('i', 7);
      await prefs.setDouble('d', 7.5);
      await prefs.setString('s', 'seven');
      await prefs.setStringList('l', const ['a', 'b']);

      expect(await prefs.getAll(), {
        'b': true,
        'i': 7,
        'd': 7.5,
        's': 'seven',
        'l': ['a', 'b'],
      });
      expect(await prefs.getKeys(), {'b', 'i', 'd', 's', 'l'});
    });

    test('a corrupt row and an unknown tag are silently skipped', () async {
      await prefs.setString('good', 'yes');
      await seedRow(id: 'corrupt', payload: 'not json{');
      await seedRow(id: 'future', payload: '{"type":"Duration","value":7}');

      expect(await prefs.getAll(), {'good': 'yes'});
      expect(await prefs.getKeys(), {'good'},
          reason: 'getKeys and getAll must agree, or a sync that reads one and '
              'writes the other loops forever');
    });

    test('an internal row never surfaces as a preference', () async {
      await prefs.setString('startup_url', '/roe');
      await seedRow(
          id: '_import.shared_preferences_v1',
          payload: '{"type":"bool","value":true}');

      expect(await prefs.getKeys(), {'startup_url'});
      expect(await prefs.getAll(), {'startup_url': '/roe'});
      expect(await prefs.containsKey('_import.shared_preferences_v1'), isTrue,
          reason: 'the import still has to be able to ask whether it has run');
    });

    test('an allowList narrows both to the keys named', () async {
      await prefs.setString('a', '1');
      await prefs.setString('b', '2');
      await prefs.setString('c', '3');

      expect(await prefs.getKeys(allowList: {'a', 'c'}), {'a', 'c'});
      expect(await prefs.getAll(allowList: {'a', 'c'}), {'a': '1', 'c': '3'});
    });

    test('an empty allowList selects nothing rather than everything', () async {
      await prefs.setString('a', '1');

      expect(await prefs.getKeys(allowList: const {}), isEmpty);
      expect(await prefs.getAll(allowList: const {}), isEmpty);
    });
  });

  group('remove', () {
    test('removing a key that was never there writes nothing', () async {
      await prefs.remove('nope');

      expect(await items(), isEmpty);
      expect(await changes(), isEmpty);
    });

    test('removing a key logs one delete holding what was lost', () async {
      await prefs.setString('startup_url', '/roe');
      await prefs.remove('startup_url');

      expect(await items(), isEmpty);
      final log = await changes();
      expect(log, hasLength(2));
      expect(log.last.op, 'delete');
      expect(log.last.newValue, isNull);
      final entity = jsonDecode(log.last.oldValue!) as Map<String, dynamic>;
      expect(entity['payload'], {'type': 'String', 'value': '/roe'},
          reason: 'a delete row that does not say what was there cannot be '
              'undone');
    });
  });

  group('clear', () {
    test('the allowList is a removal list, not a keep-list', () async {
      await prefs.setString('a', '1');
      await prefs.setString('b', '2');

      await prefs.clear(allowList: {'a'});

      expect(await prefs.getKeys(), {'b'},
          reason: 'Pitfall 5: read the other way round, this wipes the store');
      expect(await prefs.getString('b'), '2');
    });

    test('with no allowList it removes every preference at this scope',
        () async {
      await prefs.setString('a', '1');
      await prefs.setInt('b', 2);

      await prefs.clear();

      expect(await items(), isEmpty);
    });

    test('it leaves the store\'s own internal rows standing', () async {
      await prefs.setString('a', '1');
      await seedRow(
          id: '_import.shared_preferences_v1',
          payload: '{"type":"bool","value":true}');

      await prefs.clear();

      final rows = await items();
      expect(rows.map((r) => r.id), ['_import.shared_preferences_v1'],
          reason: 'the import marker is bookkeeping, not a preference: a clear '
              'that took it would let the next boot re-import a stale '
              'shared_preferences file over newer local edits');
      expect(await prefs.getAll(), isEmpty,
          reason: 'and it is still invisible as a preference');
    });

    test('it never reaches another kind at the same scope', () async {
      await prefs.setString('a', '1');
      await seedOtherKind(id: '/roe');

      await prefs.clear();

      final left = await items();
      expect(left, hasLength(1));
      expect(left.single.kind, ConfigKind.page.wireName);
    });

    test('three keys are three delete rows under one actionId', () async {
      await prefs.setString('a', '1');
      await prefs.setString('b', '2');
      await prefs.setString('c', '3');

      await prefs.clear();

      final deletes =
          (await changes()).where((c) => c.op == 'delete').toList();
      expect(deletes, hasLength(3));
      expect(deletes.map((c) => c.actionId).toSet(), hasLength(1),
          reason: 'one operator action is one actionId, however many rows it '
              'touched');
      expect(deletes.map((c) => c.entityId).toSet(), {'a', 'b', 'c'});
    });

    test('clearing an empty store writes nothing', () async {
      await prefs.clear();

      expect(await changes(), isEmpty);
    });
  });

  group("another station's rows are inert", () {
    late ConfigScope foreign;

    setUp(() async {
      foreign = ConfigScope.forStation('svn-nes-ot-cl02');
      await seedRow(
        id: 'startup_url',
        payload: '{"type":"String","value":"/their-page"}',
        scope: foreign,
      );
    });

    test('they are invisible to every read', () async {
      expect(await prefs.getString('startup_url'), isNull);
      expect(await prefs.containsKey('startup_url'), isFalse);
      expect(await prefs.getKeys(), isEmpty);
      expect(await prefs.getAll(), isEmpty);
      expect(await prefs.getKeys(allowList: {'startup_url'}), isEmpty);
    });

    test('writing the same key here leaves theirs alone', () async {
      await prefs.setString('startup_url', '/ours');

      final rows = await items();
      expect(rows, hasLength(2), reason: 'same key, two scopes, two rows');
      expect(
        rows.firstWhere((r) => r.scope == foreign.wireName).payload,
        '{"type":"String","value":"/their-page"}',
      );
      expect(await prefs.getString('startup_url'), '/ours');
    });

    test('a clear with no allowList does not touch them', () async {
      await prefs.setString('startup_url', '/ours');

      await prefs.clear();

      final rows = await items();
      expect(rows, hasLength(1));
      expect(rows.single.scope, foreign.wireName,
          reason: 'a database restored from another machine stays inert, it '
              'is not adopted');
      expect((await changes()).where((c) => c.op == 'delete').length, 1,
          reason: 'only our own row was deleted, so only one delete is logged');
    });

    test('a store at their scope reads their value, not ours', () async {
      await prefs.setString('startup_url', '/ours');

      final theirs = SqlitePreferences(db, scope: foreign);
      expect(await theirs.getString('startup_url'), '/their-page');
    });
  });
}
