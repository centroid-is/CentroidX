/// The `ConfigStore`'s boot half: what a station serves, and the one-time move
/// of Phase 1's station-scoped `key_mappings` cache into shared rows.
///
/// The re-home is the dangerous part of this phase and these tests are written
/// to be paranoid about it in one specific way. Phase 1 cached the whole
/// `key_mappings` blob at `station:<hostname>` scope; this phase decomposes it
/// into one shared row per key and removes the cache. If a station ever
/// observes a state where the blob is gone and the rows are not there yet, it
/// boots with **no key mappings at all** — every mimic on the floor blank and
/// nothing saying why. So the move happens in one local transaction, and
/// `the move is atomic` below watches the table while it happens and asserts
/// no such state is ever visible.
///
/// Everything here runs against in-memory SQLite. No Postgres, no Docker.
library;

import 'dart:convert';

// `isNull`/`isNotNull` are matchers here, not drift's SQL expressions of the
// same names.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/sqlite_preferences.dart';
import 'package:tfc_dart/core/state_man.dart';

const String kStation = 'test-station';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;

ConfigStore newStore() => ConfigStore(
      local: local,
      stationScope: kStationScope,
      station: kStation,
    );

/// The mappings a save hands over.
KeyMappings mappingsOf(Map<String, String> keysToIdentifiers) =>
    KeyMappings.fromJson(
        jsonDecode(blobOf(keysToIdentifiers)) as Map<String, dynamic>);

/// A `key_mappings` blob holding one OPC UA entry per given key.
String blobOf(Map<String, String> keysToIdentifiers) => jsonEncode({
      'nodes': {
        for (final entry in keysToIdentifiers.entries)
          entry.key: {
            'opcua_node': {
              'namespace': 4,
              'identifier': entry.value,
            },
          },
      },
    });

/// Seeds the Phase-1 cache row **through `SqlitePreferences` itself**, so the
/// payload under test is the shape Phase 1 really writes rather than this
/// test's idea of it.
Future<void> seedPhase1Cache(String blob) =>
    SqlitePreferences(local, scope: kStationScope)
        .setString(kKeyMappingsPrefKey, blob);

/// Writes a shared `key_mapping` row directly — a mirror row as the sync
/// engine would leave it. Into [local] unless [db] says otherwise.
Future<void> seedSharedRow(String key, String identifier,
        {int rev = 3, AppDatabase? db}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
        ConfigItemTableCompanion.insert(
          kind: ConfigKind.keyMapping.wireName,
          id: key,
          scope: ConfigScope.shared.wireName,
          payload: canonicalJson({
            'opcua_node': {'namespace': 4, 'identifier': identifier},
          }),
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedBy: 'somebody',
        ));

/// The same row on both sides — the ordinary state after a boot that reached
/// Postgres.
Future<void> seedBothSides(String key, String identifier, {int rev = 3}) async {
  await seedSharedRow(key, identifier, rev: rev);
  await seedSharedRow(key, identifier, rev: rev, db: remote);
}

Future<List<ConfigItemRow>> remoteMappingRows() => (remote
        .select(remote.configItemTable)
      ..where((t) => t.kind.equals(ConfigKind.keyMapping.wireName)))
    .get();

Future<List<ConfigChangeRow>> remoteChanges() =>
    (remote.select(remote.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

/// Moves a row on the remote behind the store's back — the other station.
Future<void> otherStationEdits(String key, String identifier) async {
  await (remote.update(remote.configItemTable)
        ..where((t) =>
            t.kind.equals(ConfigKind.keyMapping.wireName) &
            t.id.equals(key) &
            t.scope.equals(ConfigScope.shared.wireName)))
      .write(ConfigItemTableCompanion(
    payload: Value(canonicalJson({
      'opcua_node': {'namespace': 4, 'identifier': identifier},
    })),
    rev: const Value(99),
    updatedAt: Value(DateTime.utc(2026, 2, 2)),
    updatedBy: const Value('the-other-station'),
  ));
}

Future<List<ConfigItemRow>> allRows() => local.select(local.configItemTable).get();

Future<List<ConfigItemRow>> sharedMappingRows() => (local
        .select(local.configItemTable)
      ..where((t) =>
          t.kind.equals(ConfigKind.keyMapping.wireName) &
          t.scope.equals(ConfigScope.shared.wireName)))
    .get();

Future<ConfigItemRow?> stationCacheRow() => (local.select(local.configItemTable)
      ..where((t) =>
          t.kind.equals(ConfigKind.preference.wireName) &
          t.id.equals(kKeyMappingsPrefKey) &
          t.scope.equals(kStationScope.wireName)))
    .getSingleOrNull();

Future<List<ConfigChangeRow>> changes() => local.select(local.configChangeTable).get();

void main() {
  setUp(() {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = newStore();
  });

  tearDown(() async {
    await store.close();
    await local.close();
    await remote.close();
  });

  group('a station serves its mappings from the mirror', () {
    test('open() fills the snapshot from shared rows, with no remote at all',
        () async {
      await seedSharedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed');
      await seedSharedRow('CN07.Belt.Speed', 'GVL.Conveyors[7].Speed');

      await store.open();

      expect(store.hasRemote, isFalse);
      expect(store.keyMappings.nodes.keys,
          containsAll(<String>['CN04.Belt.Speed', 'CN07.Belt.Speed']));
      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'GVL.Conveyors[4].Speed');
    });

    test('the stored revision travels with the item', () async {
      await seedSharedRow('CN04.Belt.Speed', 'GVL.Conveyors[4].Speed', rev: 9);

      await store.open();

      expect(store.keyMappingItems.single.rev, 9);
      expect(store.keyMappingItems.single.scope, ConfigScope.shared);
      expect(store.keyMappingItems.single.kind, ConfigKind.keyMapping);
    });

    test('an empty local store serves empty mappings and writes nothing',
        () async {
      await store.open();

      expect(store.keyMappings.nodes, isEmpty);
      expect(store.keyMappingItems, isEmpty);
      expect(await allRows(), isEmpty);
      expect(await changes(), isEmpty);
    });

    test('items come back in canonical key order', () async {
      await seedSharedRow('zz', 'z');
      await seedSharedRow('aa', 'a');
      await seedSharedRow('mm', 'm');

      await store.open();

      expect(store.keyMappingItems.map((i) => i.id), ['aa', 'mm', 'zz']);
    });

    test('the watermark starts at zero when nothing has recorded one',
        () async {
      await store.open();

      expect(store.watermark, 0);
    });

    test('open() restores a watermark the sync engine left behind', () async {
      await local.into(local.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: ConfigKind.preference.wireName,
              id: kKeyMappingsWatermarkId,
              scope: kStationScope.wireName,
              payload: jsonEncode({'type': 'int', 'value': 4711}),
              updatedAt: DateTime.utc(2026, 1, 1),
              updatedBy: 'anonymous',
            ),
          );

      await store.open();

      expect(store.watermark, 4711);
    });
  });

  group('the Phase-1 cache is re-homed, not deleted', () {
    test(
        'the cutover boot with Postgres unreachable still serves the mappings',
        () async {
      await seedPhase1Cache(blobOf({
        'CN04.Belt.Speed': 'GVL.Conveyors[4].Speed',
        'CN07.Belt.Speed': 'GVL.Conveyors[7].Speed',
      }));

      // No remote, ever. This is the boot the whole design is about: the blob
      // is about to be taken away and Postgres cannot supply the rows.
      await store.open();

      expect(store.hasRemote, isFalse);
      expect(store.keyMappings.nodes.keys,
          containsAll(<String>['CN04.Belt.Speed', 'CN07.Belt.Speed']),
          reason: 'a station that loses its cache and gains nothing boots '
              'with every mimic blank');
      expect(await sharedMappingRows(), hasLength(2));
      expect(await stationCacheRow(), isNull);
    });

    test('the decomposed rows start at revision zero', () async {
      await seedPhase1Cache(blobOf({'CN04.Belt.Speed': 'a'}));

      await store.open();

      expect((await sharedMappingRows()).single.rev, 0,
          reason: 'a cached blob carries no revision, so the mirror claims '
              'none — the reconcile is what learns the real one');
    });

    test('the move is atomic: no boot can see the blob gone and no rows yet',
        () async {
      await seedPhase1Cache(blobOf({
        'CN04.Belt.Speed': 'a',
        'CN07.Belt.Speed': 'b',
      }));

      // Drift buffers a transaction's stream updates and dispatches them on
      // commit, so this watcher sees every state the database was *observably*
      // in. If the delete and the inserts were two transactions, one of these
      // snapshots would hold neither the cache nor the rows.
      final observed = <List<ConfigItemRow>>[];
      final sub =
          local.select(local.configItemTable).watch().listen(observed.add);
      await pumpEventQueue();
      observed.clear();

      await store.open();
      await pumpEventQueue();
      await sub.cancel();

      expect(observed, isNotEmpty,
          reason: 'the re-home must actually have written something');
      for (final snapshot in observed) {
        final hasCache = snapshot.any((r) =>
            r.kind == ConfigKind.preference.wireName &&
            r.id == kKeyMappingsPrefKey);
        final sharedRows = snapshot
            .where((r) => r.kind == ConfigKind.keyMapping.wireName)
            .length;
        expect(hasCache || sharedRows > 0, isTrue,
            reason: 'observed a state with no mappings at all: $snapshot');
      }
    });

    test('shared rows already present are not overwritten by the cached blob',
        () async {
      await seedSharedRow('CN04.Belt.Speed', 'the-newer-identifier', rev: 5);
      await seedPhase1Cache(blobOf({'CN04.Belt.Speed': 'the-stale-identifier'}));

      await store.open();

      final rows = await sharedMappingRows();
      expect(rows, hasLength(1));
      expect(rows.single.rev, 5, reason: 'the shared row was not rewritten');
      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'the-newer-identifier',
          reason: 'the mirror may be newer than the blob it replaces');
      expect(await stationCacheRow(), isNull,
          reason: 'the cache still goes — two copies under two scopes is the '
              'bug the re-home exists to prevent');
    });

    test('a re-created cache row is gone again on the next boot', () async {
      await seedPhase1Cache(blobOf({'CN04.Belt.Speed': 'a'}));
      await store.open();
      expect(await stationCacheRow(), isNull);

      // Something mid-phase — a syncToLocalCache that has not been moved off
      // key_mappings yet — puts it back.
      await seedPhase1Cache(blobOf({'CN04.Belt.Speed': 'a'}));
      expect(await stationCacheRow(), isNotNull);

      final second = newStore();
      addTearDown(second.close);
      await second.open();

      expect(await stationCacheRow(), isNull,
          reason: 'the delete is unconditional every boot, so nothing that '
              're-creates the row can outlive one restart');
      expect(second.keyMappings.nodes.keys, contains('CN04.Belt.Speed'));
    });

    test('a boot with nothing to do writes nothing and logs nothing',
        () async {
      await seedSharedRow('CN04.Belt.Speed', 'a');
      final before = await allRows();

      await store.open();

      expect(await allRows(), hasLength(before.length));
      expect(await changes(), isEmpty,
          reason: 'the mirror is a cache; mirroring is not a change');
    });

    test('the re-home writes no local change rows', () async {
      await seedPhase1Cache(blobOf({'CN04.Belt.Speed': 'a'}));
      // The seed itself is a preference write and does log one.
      final seeded = (await changes()).length;

      await store.open();

      expect(await changes(), hasLength(seeded),
          reason: 'moving a cache between scopes is not an edit to the '
              'plant, and a history full of them is a history nobody reads');
    });
  });

  group('a malformed cache is evidence, not a crash', () {
    test('open() completes, serves empty, and leaves the row in place',
        () async {
      await seedPhase1Cache('this is not json at all');

      await store.open();

      expect(store.keyMappings.nodes, isEmpty);
      expect(await sharedMappingRows(), isEmpty);
      expect(await stationCacheRow(), isNotNull,
          reason: 'the unreadable blob is the only evidence of what was lost');
    });

    test('a blob that is JSON but not key mappings is treated the same',
        () async {
      await seedPhase1Cache(jsonEncode({'not_nodes': 42}));

      await store.open();

      expect(store.keyMappings.nodes, isEmpty);
      expect(await stationCacheRow(), isNotNull);
    });
  });

  group('the store never hands out its interior', () {
    test('mutating a returned KeyMappings changes neither the next read nor '
        'the next diff', () async {
      await seedSharedRow('CN04.Belt.Speed', 'a');
      await store.open();

      final handedOut = store.keyMappings;
      handedOut.nodes.remove('CN04.Belt.Speed');
      handedOut.nodes['injected'] = handedOut.nodes.values.firstOrNull ??
          store.keyMappings.nodes['CN04.Belt.Speed']!;

      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed'],
          reason: 'common.dart:834 mutates the live object in place; if the '
              'store handed out its own, the next save would diff to nothing '
              'and report success having written nothing');
      expect(store.keyMappingItems.map((i) => i.id), ['CN04.Belt.Speed']);
    });

    test('the returned list is not the store\'s own', () async {
      await seedSharedRow('CN04.Belt.Speed', 'a');
      await store.open();

      store.keyMappingItems.clear();

      expect(store.keyMappingItems, hasLength(1));
    });

    test('two reads share no entry object', () async {
      await seedSharedRow('CN04.Belt.Speed', 'a');
      await store.open();

      expect(
          identical(store.keyMappings.nodes['CN04.Belt.Speed'],
              store.keyMappings.nodes['CN04.Belt.Speed']),
          isFalse);
    });
  });

  group('editing one key writes one row and one change entry', () {
    setUp(() => store.attachRemoteDatabase(remote));

    test('one edit is one UPDATE at rev+1 and one update change row', () async {
      await seedBothSides('CN04.Belt.Speed', 'old', rev: 3);
      await seedBothSides('CN07.Belt.Speed', 'untouched', rev: 3);
      await store.open();

      final result = await store.writeKeyMappings(
        mappingsOf({
          'CN04.Belt.Speed': 'new',
          'CN07.Belt.Speed': 'untouched',
        }),
        actionId: 'action-1',
        who: 'jon',
        roleName: 'engineer',
        reason: 'rewired the belt',
      );

      expect(result.diff.changed.map((i) => i.id), ['CN04.Belt.Speed']);
      expect(result.diff.added, isEmpty);
      expect(result.diff.removed, isEmpty);
      expect(result.actionId, 'action-1');

      final rows = await remoteMappingRows();
      expect(rows, hasLength(2));
      final edited = rows.firstWhere((r) => r.id == 'CN04.Belt.Speed');
      expect(edited.rev, 4, reason: 'the compare-and-swap bumps by one');
      expect(edited.updatedBy, 'jon');
      expect(edited.payload, contains('new'));
      expect(rows.firstWhere((r) => r.id == 'CN07.Belt.Speed').rev, 3,
          reason: 'the key nobody edited is not rewritten');

      final log = await remoteChanges();
      expect(log, hasLength(1),
          reason: 'one edited key is one change row, not one per key saved');
      expect(log.single.op, 'update');
      expect(log.single.entityId, 'CN04.Belt.Speed');
      expect(log.single.actionId, 'action-1');
      expect(log.single.who, 'jon');
      expect(log.single.station, kStation);
      expect(log.single.roleName, 'engineer');
      expect(log.single.reason, 'rewired the belt');
      expect(log.single.oldValue, contains('old'));
      expect(log.single.newValue, contains('new'));
    });

    test('a new key is an INSERT at rev 1 and an insert change row', () async {
      await store.open();

      await store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'a'}),
          actionId: 'action-2', who: 'jon', roleName: 'engineer');

      final rows = await remoteMappingRows();
      expect(rows, hasLength(1));
      expect(rows.single.rev, 1);
      expect(rows.single.scope, ConfigScope.shared.wireName);

      final log = await remoteChanges();
      expect(log, hasLength(1));
      expect(log.single.op, 'insert');
      expect(log.single.oldValue, isNull);
      expect(log.single.newValue, isNotNull);
    });

    test('a removed key is a DELETE and a delete change row holding what it '
        'held', () async {
      await seedBothSides('CN04.Belt.Speed', 'a', rev: 2);
      await seedBothSides('CN07.Belt.Speed', 'b', rev: 2);
      await store.open();

      await store.writeKeyMappings(mappingsOf({'CN07.Belt.Speed': 'b'}),
          actionId: 'action-3', who: 'jon', roleName: 'engineer');

      expect((await remoteMappingRows()).map((r) => r.id), ['CN07.Belt.Speed']);
      final log = await remoteChanges();
      expect(log, hasLength(1));
      expect(log.single.op, 'delete');
      expect(log.single.entityId, 'CN04.Belt.Speed');
      expect(log.single.oldValue, contains('a'),
          reason: 'the row still says what was lost after the thing it '
              'described no longer exists');
      expect(log.single.newValue, isNull);
    });

    test('saving the same configuration again writes nothing at all',
        () async {
      await seedBothSides('CN04.Belt.Speed', 'a', rev: 2);
      await store.open();
      final events = <ConfigDiff>[];
      final sub = store.keyMappingChanges.listen(events.add);
      addTearDown(sub.cancel);

      final result = await store.writeKeyMappings(
          mappingsOf({'CN04.Belt.Speed': 'a'}),
          actionId: 'action-4',
          who: 'jon',
          roleName: 'engineer');

      expect(result.diff.isEmpty, isTrue);
      expect(await remoteChanges(), isEmpty);
      expect((await remoteMappingRows()).single.rev, 2,
          reason: 'Save pressed twice must not bump a revision');
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'nothing happened, so nothing is said');
    });

    test('a successful save updates the mirror, swaps the snapshot and emits '
        'exactly one diff', () async {
      await seedBothSides('CN04.Belt.Speed', 'old', rev: 3);
      await store.open();
      final events = <ConfigDiff>[];
      final sub = store.keyMappingChanges.listen(events.add);
      addTearDown(sub.cancel);

      await store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'new'}),
          actionId: 'action-5', who: 'jon', roleName: 'engineer');
      await pumpEventQueue();

      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'new');
      expect(store.keyMappingItems.single.rev, 4,
          reason: 'the snapshot carries the revision the next CAS guards with');

      final mirrored = (await sharedMappingRows()).single;
      expect(mirrored.payload, contains('new'));
      expect(mirrored.rev, 4);
      expect(await changes(), isEmpty,
          reason: 'the mirror is a cache; the shared history lives on the '
              'remote and duplicating it locally would be two histories');

      expect(events, hasLength(1));
      expect(events.single.changed.map((i) => i.id), ['CN04.Belt.Speed']);
    });

    test('a removed key leaves the mirror too', () async {
      await seedBothSides('CN04.Belt.Speed', 'a', rev: 2);
      await store.open();

      await store.writeKeyMappings(mappingsOf({}),
          actionId: 'action-6', who: 'jon', roleName: 'engineer');

      expect(await sharedMappingRows(), isEmpty);
      expect(store.keyMappings.nodes, isEmpty);
    });
  });

  group('a lost compare-and-swap rolls the whole save back', () {
    setUp(() => store.attachRemoteDatabase(remote));

    test('ConfigConflict names the key and the revision it expected',
        () async {
      await seedBothSides('CN04.Belt.Speed', 'old', rev: 3);
      await store.open();
      await otherStationEdits('CN04.Belt.Speed', 'theirs');

      await expectLater(
        store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'mine'}),
            actionId: 'action-7', who: 'jon', roleName: 'engineer'),
        throwsA(isA<ConfigConflict>()
            .having((e) => e.key, 'key', 'CN04.Belt.Speed')
            .having((e) => e.expectedRev, 'expectedRev', 3)),
      );
    });

    test('nothing of the losing save survives, not even the keys that won',
        () async {
      await seedBothSides('A.Key', 'a', rev: 3);
      await seedBothSides('Z.Key', 'z', rev: 3);
      await store.open();
      // 'Z.Key' sorts last, so 'A.Key' is written first and is the one a
      // catch-and-continue would leave committed.
      await otherStationEdits('Z.Key', 'theirs');

      await expectLater(
        store.writeKeyMappings(
            mappingsOf({'A.Key': 'mine-a', 'Z.Key': 'mine-z'}),
            actionId: 'action-8',
            who: 'jon',
            roleName: 'engineer'),
        throwsA(isA<ConfigConflict>()),
      );

      final rows = await remoteMappingRows();
      expect(rows.firstWhere((r) => r.id == 'A.Key').payload, contains('a'),
          reason: 'throwing out of the transaction is what makes drift '
              'ROLLBACK; a skipped key would have committed this one');
      expect(rows.firstWhere((r) => r.id == 'A.Key').rev, 3);
      expect(await remoteChanges(), isEmpty,
          reason: 'no change rows from the losing save survive');
    });

    test('the snapshot is not swapped and nothing is emitted', () async {
      await seedBothSides('CN04.Belt.Speed', 'old', rev: 3);
      await store.open();
      await otherStationEdits('CN04.Belt.Speed', 'theirs');
      final events = <ConfigDiff>[];
      final sub = store.keyMappingChanges.listen(events.add);
      addTearDown(sub.cancel);

      await expectLater(
          store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'mine'}),
              actionId: 'action-9', who: 'jon', roleName: 'engineer'),
          throwsA(isA<ConfigConflict>()));
      await pumpEventQueue();

      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'old');
      expect((await sharedMappingRows()).single.payload, contains('old'),
          reason: 'the mirror is only written after the remote commits');
      expect(events, isEmpty);
    });

    test('a delete whose row moved loses the same way', () async {
      await seedBothSides('CN04.Belt.Speed', 'a', rev: 3);
      await store.open();
      await otherStationEdits('CN04.Belt.Speed', 'theirs');

      await expectLater(
          store.writeKeyMappings(mappingsOf({}),
              actionId: 'action-10', who: 'jon', roleName: 'engineer'),
          throwsA(isA<ConfigConflict>()));

      expect(await remoteMappingRows(), hasLength(1),
          reason: 'an unguarded delete would have thrown away an edit made '
              'between this station reading and saving');
    });
  });
}
