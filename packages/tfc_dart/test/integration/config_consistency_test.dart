// The consistency check over a database that was written the way the plant
// writes one.
//
// The unit suite plants violations by hand, which proves the check can see
// them. It cannot prove the thing this file is for: that the *write path*
// leaves a database the check calls clean. Every row here is produced by
// `ConfigStore` against a real Postgres — inserts, updates, a move, a reorder,
// a delete and a mixed batch — and after each one the check must be silent. A
// write path that forgot a change row fails here and nowhere else (T-04-08a).
//
// The other direction is asserted too, and on Postgres rather than SQLite: one
// raw write reaching around the store must be caught, and a raw write that
// moves a row's position while leaving its payload alone must be caught as
// well. That second one is the production shape of the divergence the unit
// suite pins — a check reduced to comparing payloads would call a corrupted
// paint order clean here, against real rows.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time.
@TestOn('vm')
library;

import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'docker_compose.dart';

void main() {
  group('checkConfigConsistency against Postgres', () {
    late Database remote;

    /// A second connection: it plants the bypass writes and it counts. The
    /// check itself runs on the store's connection, which is where a
    /// production run of it would be.
    late pg.Connection other;

    var station = 0;
    var action = 0;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      remote = await connectToDatabase();
      other = await getTestConnection();
    });

    tearDownAll(() async {
      await other.close();
      await remote.close();
      await stopDockerCompose();
    });

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
    });

    Future<ConfigStore> newStation() async {
      final name = 'station-${station++}';
      final dir = await Directory.systemTemp.createTemp('config-check-$name-');
      final local = AppDatabase.createLocal(dir);
      final store = ConfigStore(
        local: local,
        stationScope: ConfigScope.forStation(name),
        station: name,
        sweepInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        await store.syncSettled;
        await store.close();
        await local.close();
        await dir.delete(recursive: true);
      });
      await store.open();
      store.attachRemoteDatabase(remote.db, startSync: false);
      await store.syncSettled;
      return store;
    }

    /// One page and its assets, in the order given.
    List<ConfigItem> layout(String pageId, List<String> assetIds,
            {String title = 'Line 1'}) =>
        [
          ConfigItem.of(
            kind: ConfigKind.page,
            id: pageId,
            value: {
              'title': title,
              'menu_item': {'path': '/$pageId', 'label': title},
            },
          ),
          for (final (index, assetId) in assetIds.indexed)
            ConfigItem.of(
              kind: ConfigKind.asset,
              id: assetId,
              parentId: pageId,
              sortIndex: index,
              value: {'asset_name': 'lamp', 'text': assetId},
            ),
        ];

    Future<void> save(ConfigStore store, List<ConfigItem> wanted) =>
        store.writeItems(
          kinds: {ConfigKind.page, ConfigKind.asset},
          wanted: wanted,
          actionId: 'action-${action++}',
          who: 'tester',
          roleName: 'Engineering',
        );

    /// The check, run over the shared database the same way the MCP tool runs
    /// it: against a `GeneratedDatabase` that already holds the connection.
    Future<List<ConfigInconsistency>> check() =>
        checkConfigConsistency(remote.db);

    test('is silent after every kind of real write', () async {
      final store = await newStation();

      // Insert.
      await save(store, layout('p1', ['a1', 'a2', 'a3']));
      expect(await check(), isEmpty, reason: 'after the first save');

      // Update one asset's payload, leaving position alone.
      final edited = layout('p1', ['a1', 'a2', 'a3'])
        ..removeWhere((item) => item.id == 'a2')
        ..add(ConfigItem.of(
          kind: ConfigKind.asset,
          id: 'a2',
          parentId: 'p1',
          sortIndex: 1,
          value: {'asset_name': 'lamp', 'text': 'edited'},
        ));
      await save(store, edited);
      expect(await check(), isEmpty, reason: 'after an edit');

      // Reorder: nothing inside any payload changes, only paint order.
      await save(store, layout('p1', ['a3', 'a1', 'a2']));
      expect(await check(), isEmpty, reason: 'after a reorder');

      // A move to another page, and a delete, in one batch.
      await save(store, [
        ...layout('p1', ['a3', 'a1']),
        ...layout('p2', ['a2'], title: 'Line 2'),
      ]);
      expect(await check(), isEmpty, reason: 'after a move');

      await save(store, layout('p1', ['a3']));
      expect(await check(), isEmpty, reason: 'after a delete');

      // And the whole configuration removed.
      await save(store, const []);
      expect(await check(), isEmpty, reason: 'after removing everything');
    });

    test('is silent over two stations writing through one database', () async {
      final a = await newStation();
      final b = await newStation();

      await save(a, layout('p1', ['a1', 'a2']));
      await b.pullChanges();
      await save(b, layout('p1', ['a1', 'a2', 'a3']));

      expect(await check(), isEmpty);
    });

    test('catches a write that reached around the store', () async {
      // T-04-08a: the row is there, the log never heard of it. This is what a
      // `psql` session, a migration or a future write path skipping
      // `_appendChange` leaves behind.
      final store = await newStation();
      await save(store, layout('p1', ['a1']));

      await other.execute(
        pg.Sql.named(
            'INSERT INTO config_item (kind, id, scope, parent_id, sort_index, '
            "payload, rev, updated_at, updated_by) VALUES ('asset', 'ghost', "
            "'shared', 'p1', 5, @payload, 1, @at, 'psql')"),
        parameters: {
          'payload': '{"asset_name":"lamp"}',
          'at': DateTime.now().toUtc().toIso8601String(),
        },
      );

      final found = await check();

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.missingHistory);
      expect(found.single.entityId, 'ghost');
    });

    test('catches a position moved behind the log — payload untouched',
        () async {
      // The position pin, on real rows. Only `sort_index` moves here: every
      // payload in the database still matches its history exactly, so a check
      // that unwrapped to the payload before comparing would report nothing.
      final store = await newStation();
      await save(store, layout('p1', ['a1', 'a2']));
      expect(await check(), isEmpty);

      await other.execute("UPDATE config_item SET sort_index = sort_index + 1 "
          "WHERE kind = 'asset' AND id = 'a1'");

      final found = await check();

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.entityDisagrees);
      expect(found.single.entityId, 'a1');
      // Both sides are entity strings, and they differ only in position.
      expect(found.single.expected, contains('"asset_name":"lamp"'));
      expect(found.single.found, contains('"asset_name":"lamp"'));
      expect(found.single.expected, isNot(found.single.found));
    });

    test('catches a page deleted out from under its assets', () async {
      final store = await newStation();
      await save(store, layout('p1', ['a1']));

      await other
          .execute("DELETE FROM config_item WHERE kind = 'page' AND id = 'p1'");

      final found = await check();

      expect(found.map((v) => v.invariant),
          contains(ConfigInvariant.orphanedParent));
      expect(
          found
              .where((v) => v.invariant == ConfigInvariant.orphanedParent)
              .single
              .found,
          'p1');
    });

    test('catches a row that outlived its own delete', () async {
      final store = await newStation();
      await save(store, layout('p1', ['a1']));
      await save(store, layout('p1', const []));

      // The store deleted the row and logged it; something puts it back.
      await other.execute(
        pg.Sql.named(
            'INSERT INTO config_item (kind, id, scope, parent_id, sort_index, '
            "payload, rev, updated_at, updated_by) VALUES ('asset', 'a1', "
            "'shared', 'p1', 1, @payload, 9, @at, 'psql')"),
        parameters: {
          'payload': '{"asset_name":"lamp","text":"a1"}',
          'at': DateTime.now().toUtc().toIso8601String(),
        },
      );

      final found = await check();

      expect(found, hasLength(1));
      expect(found.single.invariant, ConfigInvariant.deletedButPresent);
      expect(found.single.entityId, 'a1');
    });
  });
}
