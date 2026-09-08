/// SC-1, SC-2, SC-3 and SC-5 at unit level: pages and assets through
/// [ConfigStore.writeItems], against two in-memory SQLite databases and
/// nothing else.
///
/// No Postgres, no Docker and no Flutter. The store has never looked inside a
/// payload, so the fixtures here are plain maps rather than real pages — what
/// is under test is which rows a gesture writes, and that is decided by
/// [ConfigItem.sameContentAs] over `parentId`, `sortIndex` and the payload
/// bytes, none of which needs a page codec to exercise.
///
/// The properties, in the phase's own words: nudging one asset writes one row
/// and one change entry; reordering does not write a change row per sibling; a
/// move between pages is recorded as a move and is undoable to the exact page
/// *and* position; two stations editing two different pages both keep their
/// work.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/sort_keys.dart';
import 'package:tfc_dart/core/database_drift.dart';

const String kStation = 'test-station';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;

ConfigStore storeOn(AppDatabase mirror, {String station = kStation}) =>
    ConfigStore(
      local: mirror,
      stationScope: ConfigScope.forStation(station),
      station: station,
    );

/// An asset item at [ordinal] — the rank a codec emits, which is what the
/// store reads and never what it stores.
ConfigItem assetItem(String id,
        {required String page, int? ordinal, String colour = 'red'}) =>
    ConfigItem.of(
      kind: ConfigKind.asset,
      id: id,
      value: {'id': id, 'colour': colour},
      parentId: page,
      sortIndex: ordinal,
    );

ConfigItem pageItem(String path) => ConfigItem.of(
      kind: ConfigKind.page,
      id: path,
      value: {
        'menu_item': {'path': path},
      },
    );

/// Writes [item] as a stored row at [key], into every given database.
Future<void> seed(ConfigItem item,
    {required List<AppDatabase> into, int? key, int rev = 1}) async {
  for (final db in into) {
    await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: item.kind.wireName,
          id: item.id,
          scope: item.scope.wireName,
          parentId: Value(item.parentId),
          sortIndex: Value(key ?? item.sortIndex),
          payload: item.payload,
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 1, 1),
          updatedBy: 'migration',
        ));
  }
}

/// A page of [count] assets, already stored at post-migration keys — the
/// state every one of these tests starts from.
Future<void> seedPage(String path, int count,
    {List<AppDatabase>? into, String colour = 'red'}) async {
  final dbs = into ?? [local, remote];
  await seed(pageItem(path), into: dbs);
  for (var i = 0; i < count; i++) {
    await seed(assetItem('$path-a$i', page: path, colour: colour),
        into: dbs, key: (i + 1) * kSortKeyGap);
  }
}

/// The layout the editor hands back: ordinals 0..n-1 in paint order.
List<ConfigItem> layout(String path, List<String> ids,
        {Map<String, String> colours = const {}}) =>
    [
      pageItem(path),
      for (var i = 0; i < ids.length; i++)
        assetItem(ids[i],
            page: path, ordinal: i, colour: colours[ids[i]] ?? 'red'),
    ];

Future<List<ConfigItemRow>> assetRows(AppDatabase db) =>
    (db.select(db.configItemTable)
          ..where((t) => t.kind.equals(ConfigKind.asset.wireName))
          ..orderBy([(t) => OrderingTerm.asc(t.sortIndex)]))
        .get();

Future<List<ConfigChangeRow>> changesOn(AppDatabase db) =>
    (db.select(db.configChangeTable)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<ConfigWriteResult> save(ConfigStore s, List<ConfigItem> wanted,
        {String actionId = 'action-1'}) =>
    s.writeItems(
      kinds: const {ConfigKind.page, ConfigKind.asset},
      wanted: wanted,
      actionId: actionId,
      who: 'jon',
      roleName: 'engineer',
    );

const Set<ConfigKind> kPages = {ConfigKind.page, ConfigKind.asset};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() async {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = storeOn(local);
    store.attachRemoteDatabase(remote, startSync: false);
  });
  tearDown(() async {
    await store.close();
    await local.close();
    await remote.close();
  });

  group('one nudge is one row', () {
    test('changing one asset of twenty writes one row and one change entry',
        () async {
      await seedPage('/roe', 20);
      await store.open();
      final ids = [for (var i = 0; i < 20; i++) '/roe-a$i'];

      final result = await save(
          store, layout('/roe', ids, colours: {'/roe-a7': 'blue'}));

      expect(result.diff.changed.map((i) => i.id), ['/roe-a7']);
      expect(result.diff.added, isEmpty);
      expect(result.diff.removed, isEmpty);

      final log = await changesOn(remote);
      expect(log, hasLength(1),
          reason: 'nineteen siblings and the page itself did not move');
      expect(log.single.entityId, '/roe-a7');
      expect(log.single.kind, 'asset');
      expect(log.single.op, 'update');
      // The entity, not the payload: `parent_id` is what makes the trail say
      // which page the asset was on.
      final after = jsonDecode(log.single.newValue!) as Map<String, dynamic>;
      expect(after['parent_id'], '/roe');
      expect(after['sort_index'], 8 * kSortKeyGap);

      final rows = await assetRows(remote);
      expect(rows.where((r) => r.rev != 1).map((r) => r.id), ['/roe-a7']);
    });
  });

  group('a reorder is not a page rewrite', () {
    test('bringing one of twenty to the front changes one item', () async {
      await seedPage('/roe', 20);
      await store.open();
      final before = {
        for (final row in await assetRows(remote)) row.id: row.sortIndex,
      };
      final ids = [for (var i = 0; i < 20; i++) '/roe-a$i'];

      final result =
          await save(store, layout('/roe', [ids.last, ...ids.take(19)]));

      expect(result.diff.changed.map((i) => i.id), ['/roe-a19'],
          reason: 'the moved asset only — the other nineteen keep the exact '
              'key they had, so they are not a change at all');
      expect(await changesOn(remote), hasLength(1));

      final after = {
        for (final row in await assetRows(remote)) row.id: row.sortIndex,
      };
      for (final id in ids.take(19)) {
        expect(after[id], before[id], reason: '$id must be byte-identical');
      }
      expect(after['/roe-a19'], lessThan(after['/roe-a0']!));
      expect(after['/roe-a19'], greaterThan(0));
    });
  });

  group('a move between pages is undoable to where it came from', () {
    test('the change row\'s old side decodes to the original page and position',
        () async {
      await seedPage('/roe', 3);
      await seedPage('/eviscerator', 2);
      await store.open();

      final result = await save(store, [
        ...layout('/roe', ['/roe-a0', '/roe-a2']),
        ...layout('/eviscerator',
            ['/eviscerator-a0', '/roe-a1', '/eviscerator-a1']),
      ]);

      expect(result.diff.changed.map((i) => i.id), ['/roe-a1']);
      expect(result.diff.removed, isEmpty,
          reason: 'a move is not a delete and re-insert — the asset keeps its '
              'identity, which is what keeps its history in one piece');

      final log = await changesOn(remote);
      expect(log, hasLength(1));
      final old = ConfigItem.fromEntityJson(
        jsonDecode(log.single.oldValue!) as Map<String, dynamic>,
        kind: ConfigKind.asset,
        id: log.single.entityId,
        scope: ConfigScope.shared,
      );
      // SC-3: writing this item back is the whole undo. It carries the page
      // it was on *and* the position it held there.
      expect(old.parentId, '/roe');
      expect(old.sortIndex, 2 * kSortKeyGap);

      final moved =
          (await assetRows(remote)).firstWhere((r) => r.id == '/roe-a1');
      expect(moved.parentId, '/eviscerator');
    });
  });

  group('two stations', () {
    late AppDatabase otherLocal;
    late ConfigStore other;

    setUp(() async {
      otherLocal = AppDatabase.inMemoryForTest();
      other = storeOn(otherLocal, station: 'other-station');
      other.attachRemoteDatabase(remote, startSync: false);
    });
    tearDown(() async {
      await other.close();
      await otherLocal.close();
    });

    test('editing two different pages both commit and both converge',
        () async {
      await seedPage('/roe', 3, into: [local, otherLocal, remote]);
      await seedPage('/eviscerator', 3, into: [local, otherLocal, remote]);
      await store.open();
      await other.open();

      // Both hand over the **whole** map, which is what `PageManager` does and
      // what replace-within-kinds requires: a save carrying one page would
      // read as "every other page was deleted". Each station's copy of the
      // page it is not editing is unchanged, so it produces no rows — which is
      // exactly why the two saves do not collide.
      final roe = ['/roe-a0', '/roe-a1', '/roe-a2'];
      final ev = ['/eviscerator-a0', '/eviscerator-a1', '/eviscerator-a2'];
      await save(
          store,
          [
            ...layout('/roe', ['/roe-a1', '/roe-a0', '/roe-a2']),
            ...layout('/eviscerator', ev),
          ],
          actionId: 'action-a');
      await save(
          other,
          [
            ...layout('/roe', roe),
            ...layout('/eviscerator', ev,
                colours: {'/eviscerator-a1': 'green'}),
          ],
          actionId: 'action-b');

      expect(await changesOn(remote), hasLength(2),
          reason: 'both saves landed, one row each');

      await store.reconcile();
      await other.reconcile();

      Map<String, String> viewOf(ConfigStore s) => {
            for (final item in s.itemsOf(kPages))
              item.id: '${item.parentId}#${item.sortIndex}:${item.payload}',
          };
      expect(viewOf(store), viewOf(other));
    });

    test('a same-asset race throws ConfigConflict and leaves nothing behind',
        () async {
      await seedPage('/roe', 3, into: [local, otherLocal, remote]);
      await store.open();
      await other.open();

      await save(store, layout('/roe', ['/roe-a0', '/roe-a1', '/roe-a2'],
              colours: {'/roe-a1': 'blue'}),
          actionId: 'action-winner');

      // The loser read before that landed and still believes rev 1.
      await expectLater(
        save(
            other,
            layout('/roe', ['/roe-a0', '/roe-a1', '/roe-a2'],
                colours: {'/roe-a1': 'green', '/roe-a2': 'green'}),
            actionId: 'action-loser'),
        throwsA(isA<ConfigConflict>()),
      );

      final log = await changesOn(remote);
      expect(log.map((r) => r.actionId), ['action-winner'],
          reason: 'the losing save is rolled back whole — not even the asset '
              'it would have won');
      final rows = await assetRows(remote);
      expect(rows.firstWhere((r) => r.id == '/roe-a1').payload,
          contains('blue'));
      expect(rows.firstWhere((r) => r.id == '/roe-a2').payload,
          contains('red'));
    });
  });

  group('post-migration idempotence', () {
    test('the same layout resubmitted as fresh ordinals writes nothing',
        () async {
      // P3's warning sign, inverted into a pin. The migration stores keys
      // 1024, 2048, …; the editor hands back 0, 1, 2. If the store took those
      // ordinals literally, the first save after the cutover would rewrite
      // every asset on every page — 196 rows for pressing Save.
      await seedPage('/roe', 20);
      await store.open();
      final ids = [for (var i = 0; i < 20; i++) '/roe-a$i'];

      final result = await save(store, layout('/roe', ids));

      expect(result.diff.isEmpty, isTrue);
      expect(await changesOn(remote), isEmpty);
      expect((await assetRows(remote)).every((r) => r.rev == 1), isTrue);
    });
  });
  group('what may not be handed to a write', () {
    setUp(() => store.attachRemoteDatabase(remote, startSync: false));

    test('a station-scoped item is refused, whatever its kind', () async {
      await store.open();

      // The snapshot is keyed by (kind, id) and holds shared rows only, while
      // the diff keys by (kind, id, scope). A station row reaching the diff
      // would be inserted *and* would make its shared namesake read as
      // removed: one save that writes a `station:` row into Postgres and
      // deletes the shared one. `preference` is the first kind that
      // legitimately exists at both scopes, so this is now reachable by
      // accident rather than only by misuse.
      final stationRow = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'startup_url',
        value: {'type': 'String', 'value': '/lines'},
        scope: ConfigScope.forStation(kStation),
      );

      await expectLater(
        store.writeItems(
          kinds: const {ConfigKind.preference},
          wanted: [stationRow],
          actionId: 'act-1',
          who: 'tester',
          roleName: 'Engineer',
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(await remote.select(remote.configItemTable).get(), isEmpty,
          reason: 'refused before anything is written');
    });
  });

}
