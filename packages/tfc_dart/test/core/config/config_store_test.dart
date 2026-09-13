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
import 'package:tfc_dart/core/config/config_history_policy.dart';
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
///
/// The payload comes from the codec rather than being written out here, and
/// that is load-bearing: `KeyMappingEntry.toJson()` emits every field
/// including the seven nulls, so a hand-written `{"opcua_node": …}` is a
/// *different* payload structurally and every boot would diff as though the
/// whole plant had been rewired.
Future<void> seedSharedRow(String key, String identifier,
        {int rev = 3, AppDatabase? db}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
        ConfigItemTableCompanion.insert(
          kind: ConfigKind.keyMapping.wireName,
          id: key,
          scope: ConfigScope.shared.wireName,
          payload: keyMappingItems(mappingsOf({key: identifier})).single.payload,
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedBy: 'somebody',
        ));

/// A page item, payload-shaped as `AssetPage.toJson()` leaves it — the two
/// fields the store is asked to carry, not the whole page. These are
/// store-level tests: the codec lives in the app package and cannot be
/// imported here, and the store has never looked inside a payload.
ConfigItem pageItem(String path, {String title = 'Roe'}) => ConfigItem.of(
      kind: ConfigKind.page,
      id: path,
      value: {
        'menu_item': {'path': path, 'label': title},
        'assets': <Object>[],
      },
    );

/// A top-level asset item under [page], at a stored ordering key.
ConfigItem assetItem(String id, {required String page, int? sortIndex}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'type': 'text', 'id': id},
      parentId: page,
      sortIndex: sortIndex,
    );

/// A page image, payload-shaped as 04-03 will leave it: the id is the content
/// hash, so the bytes never change under it. Nothing here depends on that
/// shape — the store has never looked inside a payload — but a fixture that
/// lies about it would read as though images were ordinary mutable rows.
ConfigItem imageItem(String id, {String bytes = 'iVBORw0KGgo'}) =>
    ConfigItem.of(
      kind: ConfigKind.pageImage,
      id: id,
      value: {'mime': 'image/png', 'bytes': bytes},
    );

/// Writes [item] as a stored row — a mirror row as the sync engine would leave
/// it, or a remote row another station wrote.
Future<void> seedItemRow(ConfigItem item,
        {int rev = 3, AppDatabase? db}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: item.kind.wireName,
            id: item.id,
            scope: item.scope.wireName,
            parentId: Value(item.parentId),
            sortIndex: Value(item.sortIndex),
            payload: item.payload,
            rev: Value(rev),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'somebody',
          ),
        );

/// The row a kind's blob→rows migration writes last, which is what tells a
/// plant with legitimately no rows of that kind from one whose migration has
/// not run.
Future<void> seedMigrationMarker(ConfigKind kind, {AppDatabase? db}) =>
    (db ?? local).into((db ?? local).configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: ConfigKind.preference.wireName,
            id: kMigrationMarkerIds[kind]!,
            scope: ConfigScope.shared.wireName,
            payload: '{"type":"String","value":"2026-09-07T00:00:00.000Z"}',
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'migration',
          ),
        );

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

Future<List<ConfigItemRow>> remoteImageRows() => (remote
        .select(remote.configItemTable)
      ..where((t) => t.kind.equals(ConfigKind.pageImage.wireName)))
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
    payload: Value(keyMappingItems(mappingsOf({key: identifier})).single.payload),
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
  // Two AppDatabase instances is the design here, not the race drift's warning
  // is about: the local mirror and the remote are two separate files with two
  // separate executors, which is exactly the shape a station runs in.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
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
      await Future<void>.delayed(Duration.zero);
      observed.clear();

      await store.open();
      await Future<void>.delayed(Duration.zero);
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
      await Future<void>.delayed(Duration.zero);
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
      await Future<void>.delayed(Duration.zero);

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
      await Future<void>.delayed(Duration.zero);

      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'old');
      expect((await sharedMappingRows()).single.payload, contains('old'),
          reason: 'the mirror is only written after the remote commits');
      expect(events, isEmpty);
    });

    test('a save queued behind a sweep is diffed against what the sweep '
        'applied, never against the snapshot it overtook', () async {
      // The write runs on the sync engine's serialisation chain. Before it
      // did, a pull that had read the remote before a save inserted a row
      // went on to delete that row from the snapshot and the mirror after
      // the save had swapped it in — the operator's new page vanished from
      // their own editor until the next sweep.
      await seedBothSides('CN04.Belt.Speed', 'old', rev: 3);
      await store.open();
      await otherStationEdits('CN04.Belt.Speed', 'theirs'); // rev 99

      final sweep = store.reconcile();
      final save = store.writeKeyMappings(mappingsOf({'CN04.Belt.Speed': 'mine'}),
          actionId: 'action-11', who: 'jon', roleName: 'engineer');
      await sweep;
      final result = await save;

      expect(result.diff.changed, hasLength(1));
      final row = (await remoteMappingRows()).single;
      expect(row.rev, 100,
          reason: 'the save saw the swept revision 99 and swapped on it; '
              'diffed against the overtaken snapshot it would have swapped '
              'on 3 and lost');
      expect(row.payload, contains('mine'));
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

  group('the snapshot is keyed by kind and id, not by id alone', () {
    // Phase 3 makes this store item-shaped: pages, assets and key mappings in
    // one snapshot, and `config_item`'s primary key is `(kind, id, scope)`. A
    // page whose path happens to equal a mapping key is legal in the table, so
    // an index keyed by id alone would have one of them silently evict the
    // other — and the symptom is a mimic bound to a key that resolves to a
    // page. Scope is deliberately not part of the key: this snapshot holds
    // shared rows only, which is why `config_diff`'s own `_key` needs a third
    // part and this one does not.
    test('a kind is part of the identity, and a scope is not', () {
      expect(configSnapshotKey(ConfigKind.keyMapping, 'CN04.Belt.Speed'),
          isNot(configSnapshotKey(ConfigKind.page, 'CN04.Belt.Speed')));
      expect(configSnapshotKey(ConfigKind.keyMapping, 'a'),
          configSnapshotKey(ConfigKind.keyMapping, 'a'));
      // Non-vacuous: two ids that differ must differ under one kind too, so
      // the assertion above cannot pass by the function ignoring its input.
      expect(configSnapshotKey(ConfigKind.keyMapping, 'a'),
          isNot(configSnapshotKey(ConfigKind.keyMapping, 'b')));
    });

    test(
        'a mapping whose key equals the watermark row\'s id is served, and '
        'does not disturb the watermark', () async {
      // The one id collision across kinds that is constructible today: the
      // watermark is a `preference` row and this is a `key_mapping` row, both
      // in `config_item`, both with the same id string. Every read and every
      // write in the store names its kind, so the two coexist.
      await seedSharedRow(kKeyMappingsWatermarkId, 'gvl.Odd');
      await SqlitePreferences(local, scope: kStationScope)
          .setInt(kKeyMappingsWatermarkId, 41);

      await store.open();

      expect(store.keyMappings.nodes.keys, [kKeyMappingsWatermarkId]);
      expect(
          store.keyMappings.nodes[kKeyMappingsWatermarkId]!.opcuaNode!
              .identifier,
          'gvl.Odd');
      expect(store.watermark, 41);
    });
  });

  group('the store is item-shaped across kinds', () {
    // Phase 3's premise: one snapshot, one write path, three kinds. Everything
    // here is the key-mapping behaviour already pinned above, asked of a kind
    // the store had never heard of until now.

    test('itemsOf returns only the kinds asked for, in canonical order',
        () async {
      await seedSharedRow('CN04.Belt.Speed', 'gvl.Speed');
      await seedItemRow(pageItem('/roe'));
      await seedItemRow(assetItem('b', page: '/roe', sortIndex: 2048));
      await seedItemRow(assetItem('a', page: '/roe', sortIndex: 1024));
      await store.open();

      expect(store.itemsOf({ConfigKind.page, ConfigKind.asset}).map((i) => i.id),
          ['/roe', 'a', 'b'],
          reason: 'kind first, then id — the order config_diff writes in');
      expect(store.itemsOf({ConfigKind.keyMapping}).map((i) => i.id),
          ['CN04.Belt.Speed']);
      expect(store.itemsOf({ConfigKind.keyMapping}),
          store.keyMappingItems,
          reason: 'the mappings getter is now one call to itemsOf');
      expect(store.itemsOf(const {}), isEmpty);
    });

    test('a page and a key mapping with the same id both survive the snapshot',
        () async {
      // The collision the composite key exists for, now constructible for
      // real: `/roe` is a legal mapping key and a legal page path, and an
      // index keyed by id alone would have one silently evict the other.
      await seedSharedRow('/roe', 'gvl.Odd');
      await seedItemRow(pageItem('/roe'));
      await store.open();

      expect(store.itemsOf({ConfigKind.page}), hasLength(1));
      expect(store.itemsOf({ConfigKind.keyMapping}), hasLength(1));
      expect(store.keyMappings.nodes['/roe']!.opcuaNode!.identifier, 'gvl.Odd');
      expect(store.itemsOf({ConfigKind.page}).single.payload,
          contains('menu_item'));
    });

    test('a pages save cannot delete a key mapping row', () async {
      // T-03-01. `kinds` is the replace set, so the rows outside it are not
      // "absent from wanted" — they were never in the comparison.
      await seedBothSides('CN04.Belt.Speed', 'gvl.Speed', rev: 3);
      await seedItemRow(pageItem('/roe'));
      await seedItemRow(pageItem('/roe'), db: remote);
      store.attachRemoteDatabase(remote);
      await store.open();

      final result = await store.writeItems(
        kinds: {ConfigKind.page, ConfigKind.asset},
        wanted: [pageItem('/roe', title: 'Roe line')],
        actionId: 'action-p',
        who: 'jon',
        roleName: 'engineer',
      );

      expect(result.diff.changed.map((i) => i.id), ['/roe']);
      expect(result.diff.removed, isEmpty,
          reason: 'the mapping is outside kinds, so it is not a removal');
      final mappings = await remoteMappingRows();
      expect(mappings, hasLength(1));
      expect(mappings.single.rev, 3, reason: 'untouched, not rewritten');
      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed']);
      final log = await remoteChanges();
      expect(log.map((r) => r.kind), ['page']);
    });

    test('a wanted item outside kinds is a caller error, not a silent insert',
        () async {
      store.attachRemoteDatabase(remote);
      await store.open();

      expect(
          () => store.writeItems(
                kinds: {ConfigKind.page},
                wanted: [pageItem('/roe'), assetItem('a', page: '/roe')],
                actionId: 'action-x',
                who: 'jon',
                roleName: 'engineer',
              ),
          throwsArgumentError);
      expect(await remoteChanges(), isEmpty);
    });

    test('writeItems with an empty diff writes nothing and emits nothing',
        () async {
      await seedItemRow(pageItem('/roe'));
      await seedItemRow(pageItem('/roe'), db: remote);
      store.attachRemoteDatabase(remote);
      await store.open();
      final events = <ConfigDiff>[];
      final sub = store.keyMappingChanges.listen(events.add);

      final result = await store.writeItems(
        kinds: {ConfigKind.page},
        wanted: [pageItem('/roe')],
        actionId: 'action-noop',
        who: 'jon',
        roleName: 'engineer',
      );

      expect(result.diff.isEmpty, isTrue);
      expect(await remoteChanges(), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
    });

    test('offline is refused before the diff, for pages as for mappings',
        () async {
      await seedItemRow(pageItem('/roe'));
      await store.open();

      await expectLater(
        () => store.writeItems(
          kinds: {ConfigKind.page},
          wanted: [pageItem('/roe')],
          actionId: 'action-off',
          who: 'jon',
          roleName: 'engineer',
        ),
        throwsA(isA<ConfigStoreOfflineException>()
            .having((e) => e.attempted, 'attempted', contains('1 page'))),
      );
    });

    test('writeKeyMappings is writeItems, and says so when it refuses',
        () async {
      // The delegation, checked where it would show: the refusal message is
      // built from items now, and it still reads as key mappings.
      await store.open();
      await expectLater(
        () => store.writeKeyMappings(
          mappingsOf({'CN04.Belt.Speed': 'a', 'CN07.Belt.Speed': 'b'}),
          actionId: 'action-off',
          who: 'jon',
          roleName: 'engineer',
        ),
        throwsA(isA<ConfigStoreOfflineException>()
            .having((e) => e.attempted, 'attempted', contains('2 keys'))
            .having((e) => e.attempted, 'attempted',
                contains('CN04.Belt.Speed'))),
      );
    });

    test('the sweep brings page and asset rows into the snapshot and the mirror',
        () async {
      await seedItemRow(pageItem('/roe'), db: remote, rev: 7);
      await seedItemRow(assetItem('a', page: '/roe', sortIndex: 1024),
          db: remote, rev: 2);
      await seedSharedRow('CN04.Belt.Speed', 'gvl.Speed', db: remote);
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      await store.reconcile();

      expect(store.itemsOf({ConfigKind.page}).single.rev, 7);
      expect(store.itemsOf({ConfigKind.asset}).single.parentId, '/roe');
      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed']);
      final mirrored = await local.select(local.configItemTable).get();
      expect(mirrored.map((r) => '${r.kind}:${r.id}').toSet(),
          {'page:/roe', 'asset:a', 'key_mapping:CN04.Belt.Speed'});
      expect(mirrored.firstWhere((r) => r.kind == 'asset').sortIndex, 1024);
    });

    test('a station holding pages the remote has never migrated keeps them',
        () async {
      // The cutover boot, per kind. The remote has key mappings and no pages;
      // reading "no page rows" as "every page was deleted" would empty the
      // mirror and the station would come up blank. Key mappings still
      // reconcile in the same sweep — the refusal is one kind's, not the
      // sweep's.
      await seedItemRow(pageItem('/roe'));
      await seedSharedRow('CN04.Belt.Speed', 'gvl.Old');
      await seedSharedRow('CN04.Belt.Speed', 'gvl.New', db: remote, rev: 9);
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      await store.reconcile();

      expect(store.itemsOf({ConfigKind.page}), hasLength(1),
          reason: 'no page rows and no page migration marker means '
              'not migrated, not empty');
      expect(store.keyMappings.nodes['CN04.Belt.Speed']!.opcuaNode!.identifier,
          'gvl.New',
          reason: 'the kind that did migrate still reconciles');
    });

    test('a remote that has migrated its pages and holds none deletes ours',
        () async {
      await seedItemRow(pageItem('/roe'));
      await seedMigrationMarker(ConfigKind.page, db: remote);
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      await store.reconcile();

      expect(store.itemsOf({ConfigKind.page}), isEmpty,
          reason: 'the remote wins outright once the marker says it is the '
              'truth');
      expect(await local.select(local.configItemTable).get(),
          isNot(contains(predicate((ConfigItemRow r) => r.kind == 'page'))));
    });
  });

  group('a history-exempt item writes no change row', () {
    setUp(() => store.attachRemoteDatabase(remote));

    test('an insert lands in config_item and nowhere else', () async {
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.pageImage},
        wanted: [imageItem('sha256-aaaa')],
        actionId: 'action-image-1',
        who: 'jon',
        roleName: 'engineer',
      );

      final rows = await remoteImageRows();
      expect(rows.single.rev, 1);
      expect(await remoteChanges(), isEmpty,
          reason: 'the bytes are the row; logging both sides of a 6.7 MB '
              'base64 blob into a table that is never pruned is C-3');
    });

    test('an update and a delete are just as silent', () async {
      await seedItemRow(imageItem('sha256-aaaa'), rev: 4);
      await seedItemRow(imageItem('sha256-aaaa'), rev: 4, db: remote);
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.pageImage},
        wanted: [imageItem('sha256-aaaa', bytes: 'Qk0y')],
        actionId: 'action-image-2',
        who: 'jon',
        roleName: 'engineer',
      );
      expect((await remoteImageRows()).single.rev, 5);
      expect(await remoteChanges(), isEmpty);

      await store.writeItems(
        kinds: {ConfigKind.pageImage},
        wanted: const [],
        actionId: 'action-image-3',
        who: 'jon',
        roleName: 'engineer',
      );
      expect(await remoteImageRows(), isEmpty);
      expect(await remoteChanges(), isEmpty,
          reason: 'a garbage-collection pass must not write the whole image '
              'into the log on its way out');
    });

    test('a mixed batch logs the item that carries history and only that one',
        () async {
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.pageImage, ConfigKind.page},
        wanted: [imageItem('sha256-aaaa'), pageItem('/roe')],
        actionId: 'action-mixed',
        who: 'jon',
        roleName: 'engineer',
      );

      final log = await remoteChanges();
      expect(log.map((r) => '${r.kind}:${r.entityId}'), ['page:/roe'],
          reason: 'the exemption is per item, not per transaction');
      final items = await remote.select(remote.configItemTable).get();
      expect(items.map((r) => '${r.kind}:${r.id}').toSet(),
          {'page_image:sha256-aaaa', 'page:/roe'},
          reason: 'both still land, and under one transaction');
    });
  });

  group('an exempt write nudges the other stations itself', () {
    late List<(String, String)> notified;

    setUp(() {
      notified = [];
      store.notifyChannelForTest = (channel, payload) async {
        notified.add((channel, payload));
      };
      store.attachRemoteDatabase(remote);
    });

    test('a commit that touched an exempt item names its kinds on the '
        'config_change channel', () async {
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.pageImage, ConfigKind.page},
        wanted: [imageItem('sha256-aaaa'), pageItem('/roe')],
        actionId: 'action-nudge',
        who: 'jon',
        roleName: 'engineer',
      );

      expect(notified, hasLength(1));
      expect(notified.single.$1, 'config_change');
      expect(decodeReconcileNudge(notified.single.$2), {ConfigKind.pageImage},
          reason: 'exempt kinds only — the page beside it wrote a change row '
              'and reaches the other stations through the trigger, so naming '
              'it here would be a second notification for one save');
    });

    test('a save of nothing but ordinary kinds nudges nobody', () async {
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.page},
        wanted: [pageItem('/roe')],
        actionId: 'action-plain',
        who: 'jon',
        roleName: 'engineer',
      );

      expect(notified, isEmpty,
          reason: 'the AFTER INSERT trigger already fired for that row');
    });

    test('a save refused mid-transaction nudges nobody', () async {
      // Nothing committed, so there is nothing to reconcile — and a nudge
      // fired before the commit would have told the plant to re-read a state
      // that never existed.
      await seedItemRow(imageItem('sha256-aaaa'), rev: 4);
      await seedItemRow(imageItem('sha256-aaaa'), rev: 4, db: remote);
      await store.open();
      await (remote.update(remote.configItemTable)
            ..where((t) => t.kind.equals(ConfigKind.pageImage.wireName)))
          .write(const ConfigItemTableCompanion(rev: Value(99)));

      await expectLater(
        store.writeItems(
          kinds: {ConfigKind.pageImage},
          wanted: [imageItem('sha256-aaaa', bytes: 'Qk0y')],
          actionId: 'action-lost',
          who: 'jon',
          roleName: 'engineer',
        ),
        throwsA(isA<ConfigConflict>()),
      );

      expect(notified, isEmpty);
    });

    test('a notify that fails does not fail the save that already committed',
        () async {
      store.notifyChannelForTest =
          (_, __) async => throw StateError('connection went away');
      await store.open();

      await store.writeItems(
        kinds: {ConfigKind.pageImage},
        wanted: [imageItem('sha256-aaaa')],
        actionId: 'action-notify-died',
        who: 'jon',
        roleName: 'engineer',
      );

      expect((await remoteImageRows()), hasLength(1),
          reason: 'the write is committed before the nudge is sent; a lost '
              'nudge degrades that kind to sweep latency, it does not undo '
              'anything');
    });
  });

  group('the receiving station acts on a nudge', () {
    setUp(() => store.attachRemoteDatabase(remote, startSync: false));

    test('a kind-named payload reconciles that kind without touching the '
        'watermark', () async {
      await store.open();
      await seedItemRow(imageItem('sha256-aaaa'), db: remote, rev: 2);
      final before = store.watermark;

      await store.handleNotificationForTest(
          encodeReconcileNudge({ConfigKind.pageImage}));

      expect(store.itemsOf({ConfigKind.pageImage}).single.id, 'sha256-aaaa',
          reason: 'the image reaches this station now rather than on the '
              'five-minute sweep — there is no change row for the fast path '
              'to have seen');
      expect(store.watermark, before,
          reason: 'an exempt write appends no change row, so there is nothing '
              'to watermark and advancing would skip a row somebody else '
              'committed');
    });

    test('the trigger\'s empty payload still means "consume the log"',
        () async {
      await store.open();
      await seedSharedRow('CN04.Belt.Speed', 'gvl.Speed', db: remote);
      await remote.into(remote.configChangeTable).insert(
            ConfigChangeTableCompanion.insert(
              at: DateTime.utc(2026, 3, 3),
              actionId: 'somebody-else',
              who: 'gudrun',
              station: 'other',
              roleName: 'engineer',
              kind: ConfigKind.keyMapping.wireName,
              entityId: 'CN04.Belt.Speed',
              scope: ConfigScope.shared.wireName,
              op: 'insert',
              newValue: const Value('{}'),
            ),
          );

      await store.handleNotificationForTest('');

      expect(store.keyMappings.nodes.keys, ['CN04.Belt.Speed']);
      expect(store.watermark, greaterThan(0),
          reason: 'the ordinary path is untouched by any of this');
    });
  });

  group('the sweep covers every kind an exempt write can create', () {
    test('page_image is under sync — without it an exempt row would '
        'propagate never, not slowly', () {
      expect(kSharedConfigKinds, contains(ConfigKind.pageImage));
      expect(
        ConfigKind.values.toSet().difference(kSharedConfigKinds),
        isEmpty,
        reason: 'every kind must be in: the rev sweep is the only net under '
            'a kind that writes no change rows, and a kind outside the set '
            'is outside the boot snapshot, which leaves writeItems no rev to '
            'compare and swap against. `preference` joined in 04-05 — what '
            'keeps this station\'s bookkeeping rows out of a sweep is the '
            'scope filter, not this set.',
      );
      expect(kMigrationMarkerIds.keys.toSet(), kSharedConfigKinds,
          reason: 'a kind under sync with no marker cannot tell an empty '
              'remote from an unmigrated one, and _remoteIsMigrated logs that '
              'at error level on every sweep');
    });

    test('the sweep really does pick a page image up', () async {
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();
      await seedItemRow(imageItem('sha256-aaaa'), db: remote, rev: 2);

      await store.reconcile();

      expect(store.itemsOf({ConfigKind.pageImage}).single.rev, 2);
      final mirrored = await local.select(local.configItemTable).get();
      expect(mirrored.map((r) => r.kind), contains('page_image'),
          reason: 'and the mirror keeps it, so the next boot has the image '
              'even with Postgres unreachable');
    });
  });

  group('C-12: an insert onto a row that already exists', () {
    setUp(() => store.attachRemoteDatabase(remote));

    test('raises ConfigConflict naming the entity, not a driver error',
        () async {
      await store.open();
      // The other station created it between this station's read and this
      // save: the snapshot says "new", the table says otherwise.
      await seedItemRow(pageItem('/roe'), db: remote, rev: 6);

      await expectLater(
        store.writeItems(
          kinds: {ConfigKind.page},
          wanted: [pageItem('/roe', title: 'Mine')],
          actionId: 'action-race',
          who: 'jon',
          roleName: 'engineer',
        ),
        throwsA(isA<ConfigConflict>().having((e) => e.key, 'key', '/roe')),
      );
    });

    test('nothing else in the batch commits', () async {
      await store.open();
      await seedItemRow(pageItem('/roe'), db: remote, rev: 6);

      await expectLater(
        store.writeItems(
          kinds: {ConfigKind.page},
          wanted: [pageItem('/roe', title: 'Mine'), pageItem('/whitefish')],
          actionId: 'action-race-2',
          who: 'jon',
          roleName: 'engineer',
        ),
        throwsA(isA<ConfigConflict>()),
      );

      final rows = await (remote.select(remote.configItemTable)
            ..where((t) => t.kind.equals(ConfigKind.page.wireName)))
          .get();
      expect(rows.map((r) => r.id), ['/roe'],
          reason: 'the refusal is the whole transaction\'s, so the sibling '
              'page must not be left behind on its own');
      expect(rows.single.updatedBy, 'somebody',
          reason: 'and the row that was there is untouched');
      expect(await remoteChanges(), isEmpty);
      expect(store.itemsOf({ConfigKind.page}), isEmpty,
          reason: 'the snapshot is not swapped by a save that did not happen');
    });
  });
}
