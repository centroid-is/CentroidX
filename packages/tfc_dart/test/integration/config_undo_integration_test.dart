// Undo against a real Postgres: the round trip, the append-only log, and the
// refusal when the world moved.
//
// These are the things the cheap lane cannot prove:
//
//   1. the SQL. `planUndo`'s newest-change read is `MAX(id) … GROUP BY` fed
//      into an `id IN (subquery)`, and drift binds an int parameter as
//      `bigint` — the 42883 lesson, where a statement that ran on SQLite met
//      `operator does not exist` on the server. Nothing but this lane
//      executes it against Postgres.
//   2. a real save through `ConfigStore` producing the change rows the undo
//      then inverts, rather than rows a test wrote by hand into the shape it
//      expected.
//   3. another station moving an entity on the same database, on its own
//      connection, between the save and the plan.
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

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_undo.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'docker_compose.dart';

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

void main() {
  // Each station is its own local SQLite file behind its own executor, which
  // is the shape a plant runs in rather than the race the warning is about.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('undo against Postgres', () {
    late Database remote;

    /// A second connection, standing in for another station. Assertions must
    /// not ride the connection under test.
    late pg.Connection other;

    final AccessPolicy policy = AccessPolicy();
    final Set<AccessGroup> allGroups = AccessGroup.values.toSet();

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

    /// A station: its own local SQLite file, its own store, one shared remote.
    ///
    /// Sync is off. Every apply here is one the test asked for, so a refusal
    /// that should have happened cannot be rescued by a reconcile arriving in
    /// the background.
    Future<ConfigStore> newStation() async {
      final name = 'station-${station++}';
      final dir = await Directory.systemTemp.createTemp('config-undo-$name-');
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

    Future<ConfigWriteResult> save(ConfigStore store, List<ConfigItem> wanted,
            {Set<ConfigKind> kinds = const {
              ConfigKind.page,
              ConfigKind.asset
            }}) =>
        store.writeItems(
          kinds: kinds,
          wanted: wanted,
          actionId: 'action-${action++}',
          who: 'tester',
          roleName: 'Engineering',
        );

    /// Every column that is *configuration* — `rev` deliberately excluded.
    ///
    /// A restore is itself a write, so `rev` advances across an undo and does
    /// not come back to what it was. It is a monotonic write counter and the
    /// thing the next compare-and-swap guards on; rewinding it would make an
    /// undone row look untouched to another station holding the old number.
    /// So the content is compared here and the counter is asserted separately,
    /// where its going *up* is the point.
    Future<List<pg.ResultRow>> sharedRows() => other.execute(
        'SELECT kind, id, parent_id, sort_index, payload FROM '
        "config_item WHERE scope = 'shared' ORDER BY kind, id");

    Future<int> revOf(String kind, String id) async {
      final rows = await other.execute(
          pg.Sql.named('SELECT rev FROM config_item WHERE kind = @kind AND '
              "id = @id AND scope = 'shared'"),
          parameters: {'kind': kind, 'id': id});
      return (rows.single.first! as num).toInt();
    }

    Future<List<pg.ResultRow>> changeRows() => other.execute(
        'SELECT id, action_id, kind, entity_id, op, reason FROM config_change '
        'ORDER BY id');

    test('a save, its undo, and a log that holds both', () async {
      final a = await newStation();

      // The plant as it stands: one page, two assets.
      final base = [
        pageItem('p1'),
        assetItem('a1', page: 'p1', ordinal: 0),
        assetItem('a2', page: 'p1', ordinal: 1),
      ];
      await save(a, base);
      final before = await sharedRows();
      expect(before, hasLength(3));

      // The edit an operator regrets: one asset repainted.
      final edit = await save(a, [
        pageItem('p1'),
        assetItem('a1', page: 'p1', ordinal: 0, colour: 'blue'),
        assetItem('a2', page: 'p1', ordinal: 1),
      ]);
      expect(edit.diff.changed, hasLength(1));

      final plan = await planUndo(remote.db, edit.actionId);
      expect(plan.isReady, isTrue,
          reason: plan.blockers.map((b) => b.summary).join(' '));
      expect(plan.kinds, {ConfigKind.asset});

      await executeUndo(
        plan,
        store: a,
        policy: policy,
        sessionGroups: allGroups,
        actionId: 'undo-of-${edit.actionId}',
        who: 'gudrun',
        roleName: 'Engineering',
      );

      // Every column that is configuration, through real rows: the payload,
      // the parent and the position are what they were before the edit.
      expect(await sharedRows(), before);
      // And the one column that must *not* come back. Three writes have
      // touched a1 — the save, the edit, the undo — and the counter says so.
      // A restore that rewound it would leave another station's stale rev
      // matching, which is the collision `rev` exists to catch.
      expect(await revOf('asset', 'a1'), 3);
      expect(await revOf('asset', 'a2'), 1,
          reason: 'the sibling was never written; an undo that bumped it '
              'would be rewriting rows it was not asked to');

      final log = await changeRows();
      expect(log.map((r) => r[1]).toSet(),
          {'action-0', edit.actionId, 'undo-of-${edit.actionId}'},
          reason: 'the log is append-only — the undo adds an action, it does '
              'not remove the one it inverts');
      expect(log.where((r) => r[1] == edit.actionId), hasLength(1));
      expect(log.last[4], 'update');
      expect(log.last[5], 'undo of ${edit.actionId}');
    });

    test('undoing a delete puts the row back with its parent and position',
        () async {
      final a = await newStation();
      await save(a, [
        pageItem('p1'),
        assetItem('a1', page: 'p1', ordinal: 0),
        assetItem('a2', page: 'p1', ordinal: 1),
      ]);
      final before = await sharedRows();

      final removal = await save(a, [
        pageItem('p1'),
        assetItem('a1', page: 'p1', ordinal: 0),
      ]);
      expect(removal.diff.removed.map((i) => i.id), ['a2']);
      expect(await sharedRows(), hasLength(2));

      final plan = await planUndo(remote.db, removal.actionId);
      expect(plan.isReady, isTrue,
          reason: plan.blockers.map((b) => b.summary).join(' '));
      expect(plan.steps.single.item!.parentId, 'p1');

      await executeUndo(
        plan,
        store: a,
        policy: policy,
        sessionGroups: allGroups,
        actionId: 'undo-of-${removal.actionId}',
        who: 'gudrun',
        roleName: 'Engineering',
      );

      expect(await sharedRows(), before,
          reason: 'a restore writes old_value, which is the entity and not '
              'the payload: parent_id and sort_index come back with it');
      expect(await revOf('asset', 'a2'), 1,
          reason: 'the re-insert is an insert, so the row starts its count '
              'again — there is no revision of a deleted row to continue');
    });

    test('an entity another station moved is named in the refusal', () async {
      final a = await newStation();
      final edit = await save(a, [
        pageItem('p1'),
        assetItem('a1', page: 'p1', ordinal: 0),
      ]);

      // Another station edits the same asset on its own connection, the way a
      // second panel would: the row, and the change row that announces it.
      final at = DateTime.now().toUtc().toIso8601String();
      await other.execute(pg.Sql.named(
          'UPDATE config_item SET payload = @payload, rev = rev + 1, '
          "updated_by = 'ingibjorg' WHERE kind = 'asset' AND id = 'a1'"),
          parameters: {'payload': assetItem('a1', page: 'p1').payload});
      await other.execute(
        pg.Sql.named('INSERT INTO config_change (at, action_id, who, station, '
            'role_name, kind, entity_id, scope, op, old_value, new_value) '
            "VALUES (@at, 'their-action', 'ingibjorg', 'other-station', "
            "'Engineering', 'asset', 'a1', 'shared', 'update', @old, @new)"),
        parameters: {
          'at': at,
          'old': assetItem('a1', page: 'p1', ordinal: 1024).encodeEntity(),
          'new': assetItem('a1', page: 'p1', ordinal: 1024, colour: 'green')
              .encodeEntity(),
        },
      );

      // This is the query the cheap lane cannot vouch for: MAX(id) grouped per
      // entity, fed into `id IN (subquery)`.
      final plan = await planUndo(remote.db, edit.actionId);

      expect(plan.isReady, isFalse);
      expect(plan.blockers, hasLength(1));
      expect(plan.blockers.single.reason, UndoBlockReason.newerChange);
      expect(plan.blockers.single.entityId, 'a1');
      expect(plan.blockers.single.who, 'ingibjorg');
      expect(plan.blockers.single.summary, contains('ingibjorg'));

      final logBefore = await changeRows();
      await expectLater(
          executeUndo(
            plan,
            store: a,
            policy: policy,
            sessionGroups: allGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineering',
          ),
          throwsA(isA<ArgumentError>()));
      expect(await changeRows(), logBefore,
          reason: 'a refused plan writes nothing at all');
    });
  });
}
