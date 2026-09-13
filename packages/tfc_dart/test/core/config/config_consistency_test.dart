// The consistency check, planted violation by planted violation.
//
// Every test here writes rows straight into the tables rather than through
// `ConfigStore`, which is the point: the check exists to find rows no correct
// write path could have produced, so the tests have to produce them the same
// way the corruption would — behind the store's back.
//
// The integration test is the other half (`test/integration/`): it drives real
// writes through the store against Postgres and asserts the check stays
// silent. A suite that only did that would prove the invariant over data it
// wrote itself; a suite that only did this would never notice the write path
// forgetting a change row.
//
// [ConfigItemSchema] is opened rather than `AppDatabase` for the reason
// `page_rows_test.dart` gives: `AppDatabase` reaches open62541, and the check
// is exported from the barrel that must not.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_item_table.dart';

GeneratedDatabase _schemaDb() => ConfigItemSchema(NativeDatabase.memory());

final DateTime _at = DateTime.utc(2026, 9, 7, 12);

Future<void> _insertItem(
  GeneratedDatabase db, {
  required ConfigKind kind,
  required String id,
  ConfigScope scope = ConfigScope.shared,
  String? parentId,
  int? sortIndex,
  Map<String, dynamic> payload = const {'a': 1},
  String? rawPayload,
}) {
  final table = $ConfigItemTableTable(db);
  return db.into(table).insert(ConfigItemTableCompanion.insert(
        kind: kind.wireName,
        id: id,
        scope: scope.wireName,
        parentId: Value(parentId),
        sortIndex: Value(sortIndex),
        payload: rawPayload ?? canonicalJson(payload),
        updatedAt: _at,
        updatedBy: 'tester',
      ));
}

Future<void> _insertChange(
  GeneratedDatabase db, {
  required ConfigKind kind,
  required String id,
  ConfigScope scope = ConfigScope.shared,
  ConfigChangeOp op = ConfigChangeOp.insert,
  String? newValue,
  DateTime? at,
}) {
  final table = $ConfigChangeTableTable(db);
  return db.into(table).insert(ConfigChangeTableCompanion.insert(
        at: at ?? _at,
        actionId: 'action-1',
        who: 'tester',
        station: 'test-station',
        roleName: 'admin',
        kind: kind.wireName,
        entityId: id,
        scope: scope.wireName,
        op: op.wireName,
        newValue: Value(newValue),
      ));
}

/// The change row a correct write of this item would have left behind.
Future<void> _insertMatchingChange(
  GeneratedDatabase db,
  ConfigItem item, {
  String? overrideNewValue,
}) =>
    _insertChange(
      db,
      kind: item.kind,
      id: item.id,
      scope: item.scope,
      newValue: overrideNewValue ?? item.encodeEntity(),
    );

/// An item and the matching change row: one entity, consistently stored.
Future<ConfigItem> _seedClean(
  GeneratedDatabase db, {
  required ConfigKind kind,
  required String id,
  ConfigScope scope = ConfigScope.shared,
  String? parentId,
  int? sortIndex,
  Map<String, dynamic> payload = const {'a': 1},
}) async {
  final item = ConfigItem.of(
    kind: kind,
    id: id,
    scope: scope,
    parentId: parentId,
    sortIndex: sortIndex,
    value: payload,
  );
  await _insertItem(db,
      kind: kind,
      id: id,
      scope: scope,
      parentId: parentId,
      sortIndex: sortIndex,
      payload: payload);
  await _insertMatchingChange(db, item);
  return item;
}

void main() {
  group('a database nothing is wrong with', () {
    test('reports nothing', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');
      await _seedClean(db,
          kind: ConfigKind.asset, id: 'a1', parentId: 'p1', sortIndex: 0);
      await _seedClean(db,
          kind: ConfigKind.asset, id: 'a2', parentId: 'p1', sortIndex: 1);
      await _seedClean(db, kind: ConfigKind.keyMapping, id: 'CN01.RUN');
      await _seedClean(db,
          kind: ConfigKind.preference,
          id: 'startup_page',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'));

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('is silent on an empty database', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('does not mind an entity whose newest change is a delete and whose '
        'row is gone', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');
      // A deleted asset: its history survives, its row does not.
      await _insertChange(db,
          kind: ConfigKind.asset, id: 'gone', op: ConfigChangeOp.insert);
      await _insertChange(db,
          kind: ConfigKind.asset, id: 'gone', op: ConfigChangeOp.delete);

      expect(await checkConfigConsistency(db), isEmpty);
    });
  });

  group('invariant 1: parent_id resolves', () {
    test('reports a child whose parent is not there, naming both', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db,
          kind: ConfigKind.asset, id: 'a1', parentId: 'p-vanished');

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.orphanedParent);
      expect(found.single.entityId, 'a1');
      expect(found.single.kindName, ConfigKind.asset.wireName);
      expect(found.single.found, 'p-vanished');
      expect(found.single.summary, contains('p-vanished'));
      expect(found.single.summary, contains('a1'));
    });

    test('a parent in another scope still resolves', () async {
      // A station-scoped child of a shared page is not an orphan: the parent
      // row exists, and matching on scope too would report a violation where
      // there is none.
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');
      await _seedClean(db,
          kind: ConfigKind.asset,
          id: 'a1',
          scope: ConfigScope.forStation('svn-nes-ot-cl02'),
          parentId: 'p1');

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('a null parent_id is not an orphan', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');

      expect(await checkConfigConsistency(db), isEmpty);
    });
  });

  group('invariant 2: the newest change is this item', () {
    test('reports an item whose newest change disagrees only in sort_index',
        () async {
      // THE POSITION PIN. A check that compared payloads would call this
      // clean: nothing inside the payload moved. What moved is paint order,
      // which is exactly what `encodeEntity` folds position in to protect.
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');
      await _insertItem(db,
          kind: ConfigKind.asset,
          id: 'a1',
          parentId: 'p1',
          sortIndex: 3,
          payload: {'asset_name': 'lamp'});
      // The log says it is still at position 0.
      await _insertChange(db,
          kind: ConfigKind.asset,
          id: 'a1',
          newValue: ConfigItem.of(
            kind: ConfigKind.asset,
            id: 'a1',
            parentId: 'p1',
            sortIndex: 0,
            value: {'asset_name': 'lamp'},
          ).encodeEntity());

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.entityDisagrees);
      expect(found.single.entityId, 'a1');
      expect(found.single.expected, contains('"sort_index":3'));
      expect(found.single.found, contains('"sort_index":0'));
    });

    test('reports an item whose newest change disagrees only in parent_id',
        () async {
      // The other half of position: a move changes nothing inside the payload
      // either, and a restore from a log that missed it puts the asset back on
      // the wrong page.
      final db = _schemaDb();
      addTearDown(db.close);

      await _seedClean(db, kind: ConfigKind.page, id: 'p1');
      await _seedClean(db, kind: ConfigKind.page, id: 'p2');
      await _insertItem(db,
          kind: ConfigKind.asset,
          id: 'a1',
          parentId: 'p2',
          payload: {'asset_name': 'lamp'});
      await _insertChange(db,
          kind: ConfigKind.asset,
          id: 'a1',
          newValue: ConfigItem.of(
            kind: ConfigKind.asset,
            id: 'a1',
            parentId: 'p1',
            value: {'asset_name': 'lamp'},
          ).encodeEntity());

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.entityDisagrees);
      expect(found.single.expected, contains('"parent_id":"p2"'));
      expect(found.single.found, contains('"parent_id":"p1"'));
    });

    test('reports an item whose payload disagrees', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.keyMapping, id: 'CN01.RUN', payload: {'ns': 4});
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          newValue: ConfigItem.of(
            kind: ConfigKind.keyMapping,
            id: 'CN01.RUN',
            value: {'ns': 2},
          ).encodeEntity());

      final found = await checkConfigConsistency(db);

      expect(found.map((v) => v.invariant), [ConfigInvariant.entityDisagrees]);
    });

    test('reports an item the change log has never heard of', () async {
      // T-04-08a: a write path that stored the row and forgot the log.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db, kind: ConfigKind.keyMapping, id: 'CN01.RUN');

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.missingHistory);
      expect(found.single.entityId, 'CN01.RUN');
      expect(found.single.found, isNull);
    });

    test('a divergence of map order alone is not a violation', () async {
      // A row written before `canonicalJson` existed encodes the same
      // configuration in another key order. samePayload does the comparing, so
      // this reads as what it is: nothing happened.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          rawPayload: '{"ns":4,"identifier":"x"}');
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          newValue: '{"payload":{"identifier":"x","ns":4},"sort_index":null,'
              '"parent_id":null}');

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('newest means last written, not latest `at`', () async {
      // Several stations write this log and their clocks disagree — the
      // reason `rev` is a counter rather than a timestamp. The row that
      // disagrees here carries an `at` a day in the future and was written
      // first; the matching row was written after it. A check that ordered by
      // `at` would report a violation that a skewed clock invented.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.keyMapping, id: 'CN01.RUN', payload: {'ns': 4});
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          newValue: '{"parent_id":null,"payload":{"ns":1},"sort_index":null}',
          at: _at.add(const Duration(days: 1)));
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          newValue: ConfigItem.of(
            kind: ConfigKind.keyMapping,
            id: 'CN01.RUN',
            value: {'ns': 4},
          ).encodeEntity());

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('the same id in two scopes is two entities', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      final station = ConfigScope.forStation('svn-nes-ot-cl02');
      await _seedClean(db,
          kind: ConfigKind.preference, id: 'theme', payload: {'v': 'dark'});
      await _insertItem(db,
          kind: ConfigKind.preference,
          id: 'theme',
          scope: station,
          payload: {'v': 'light'});

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.missingHistory);
      expect(found.single.scopeName, station.wireName);
    });
  });

  group('invariant 3: a deleted entity has no row', () {
    test('reports an item whose newest change is a delete', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db, kind: ConfigKind.keyMapping, id: 'CN01.RUN');
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          newValue: '{"parent_id":null,"payload":{"a":1},"sort_index":null}');
      await _insertChange(db,
          kind: ConfigKind.keyMapping,
          id: 'CN01.RUN',
          op: ConfigChangeOp.delete);

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.deletedButPresent);
      expect(found.single.entityId, 'CN01.RUN');
    });
  });

  group('the exemption interlock', () {
    test('reports an exempt kind that has a change row', () async {
      // The exemption is checked the other way round: page images must have no
      // history at all, and the way to know the rule held in production is to
      // look rather than to trust the writers.
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.pageImage, id: 'ab12cd', payload: {'b': 'AAAA'});
      await _insertChange(db,
          kind: ConfigKind.pageImage,
          id: 'ab12cd',
          newValue: '{"parent_id":null,"payload":{"b":"AAAA"},'
              '"sort_index":null}');

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.exemptHasHistory);
      expect(found.single.kindName, ConfigKind.pageImage.wireName);
    });

    test('an exempt kind with no history is clean', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.pageImage, id: 'ab12cd', payload: {'b': 'AAAA'});

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('an exempt preference id is exempt; its siblings are not', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.preference,
          id: 'server_config_envelope',
          payload: {'ciphertext': 'x'});
      await _insertItem(db, kind: ConfigKind.preference, id: 'theme');

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(1));
      expect(found.single.entityId, 'theme');
      expect(found.single.invariant, ConfigInvariant.missingHistory);
    });

    test('the exempt envelope with a change row is reported', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db,
          kind: ConfigKind.preference,
          id: 'server_config_envelope',
          payload: {'ciphertext': 'x'});
      await _insertChange(db,
          kind: ConfigKind.preference,
          id: 'server_config_envelope',
          newValue: '{"parent_id":null,"payload":{"ciphertext":"x"},'
              '"sort_index":null}');

      final found = await checkConfigConsistency(db);

      expect(found.map((v) => v.invariant), [ConfigInvariant.exemptHasHistory]);
    });

    test('an exempt entity with only a delete row is still reported',
        () async {
      // Page-image garbage collection is a plain delete and writes nothing.
      // A delete row means a collector that logged, which is the leak the
      // exemption exists to prevent (C-3).
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertChange(db,
          kind: ConfigKind.pageImage,
          id: 'ab12cd',
          op: ConfigChangeOp.delete);

      final found = await checkConfigConsistency(db);

      expect(found.map((v) => v.invariant), [ConfigInvariant.exemptHasHistory]);
    });
  });

  group('rows this build cannot judge', () {
    test('a kind from a newer station is skipped, not reported', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await db.into($ConfigItemTableTable(db)).insert(
            ConfigItemTableCompanion.insert(
              kind: 'recipe_from_the_future',
              id: 'r1',
              scope: ConfigScope.shared.wireName,
              payload: '{}',
              updatedAt: _at,
              updatedBy: 'tester',
            ),
          );

      expect(await checkConfigConsistency(db), isEmpty);
    });

    test('but its parent_id is still checked', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await db.into($ConfigItemTableTable(db)).insert(
            ConfigItemTableCompanion.insert(
              kind: 'recipe_from_the_future',
              id: 'r1',
              scope: ConfigScope.shared.wireName,
              parentId: const Value('nowhere'),
              payload: '{}',
              updatedAt: _at,
              updatedBy: 'tester',
            ),
          );

      final found = await checkConfigConsistency(db);

      expect(found.map((v) => v.invariant), [ConfigInvariant.orphanedParent]);
    });
  });

  group('several violations at once', () {
    test('are all reported, ordered so a diff of two runs reads', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db, kind: ConfigKind.asset, id: 'a2', parentId: 'gone');
      await _insertItem(db, kind: ConfigKind.keyMapping, id: 'CN01.RUN');

      final found = await checkConfigConsistency(db);

      expect(found, hasLength(3));
      // Two for the asset (orphan, and no history), one for the mapping.
      expect(found.map((v) => v.entityId).toSet(), {'a2', 'CN01.RUN'});
      // Stable order: kind, then id, then scope, then invariant.
      final keys = found.map((v) => '${v.kindName}/${v.entityId}').toList();
      expect(keys, List<String>.from(keys)..sort());
    });
  });

  group('ConfigInconsistency', () {
    test('renders as one readable line naming the invariant', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db, kind: ConfigKind.asset, id: 'a1', parentId: 'gone');

      final line = (await checkConfigConsistency(db)).first.toString();

      expect(line, contains('orphaned_parent'));
      expect(line, contains('asset'));
      expect(line, contains('a1'));
    });

    test('is JSON so a tool can hand the list on', () async {
      final db = _schemaDb();
      addTearDown(db.close);

      await _insertItem(db, kind: ConfigKind.asset, id: 'a1', parentId: 'gone');

      final json = (await checkConfigConsistency(db)).first.toJson();

      expect(jsonDecode(jsonEncode(json)), {
        'invariant': 'orphaned_parent',
        'kind': 'asset',
        'entity_id': 'a1',
        'scope': 'shared',
        'summary': anything,
        'expected': null,
        'found': 'gone',
      });
    });
  });
}
