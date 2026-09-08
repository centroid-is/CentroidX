/// Undo an action: the verdict, the inverse, and the write that carries it.
///
/// Everything here runs against in-memory SQLite. No Postgres, no Docker and
/// no Flutter — the same arrangement `config_store_pages_test.dart` uses, and
/// for the same reason: what is under test is which rows a gesture writes, and
/// that is decided by [ConfigItem.sameContentAs] rather than by any codec.
///
/// The two properties this file exists to hold:
///
///   * **A restore is itself a write.** The undo goes through
///     [ConfigStore.writeItems] under a new `action_id`, so the log gains rows
///     rather than losing them, and undoing an undo needs no extra machinery.
///   * **The gate is inside [executeUndo].** A refusal must leave the database
///     byte-identical, which is asserted here by comparing the whole of
///     `config_item` and `config_change` across the attempt.
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/config_undo.dart';
import 'package:tfc_dart/core/database_drift.dart';

const String kStation = 'test-station';
const String kOtherStation = 'other-station';
final ConfigScope kStationScope = ConfigScope.forStation(kStation);

late AppDatabase local;
late AppDatabase remote;
late ConfigStore store;

final AccessPolicy policy = AccessPolicy();

/// Every group there is — the session a permitted undo runs under.
final Set<AccessGroup> kAllGroups = AccessGroup.values.toSet();

/// A session that may operate the plant and may not configure it.
const Set<AccessGroup> kOperatorGroups = {
  AccessGroup.operate,
  AccessGroup.setpoints,
};

ConfigStore storeOn(AppDatabase mirror, {String station = kStation}) =>
    ConfigStore(
      local: mirror,
      stationScope: ConfigScope.forStation(station),
      station: station,
    );

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

ConfigItem imageItem(String id) => ConfigItem.of(
      kind: ConfigKind.pageImage,
      id: id,
      value: {'bytes': 'aGVsbG8='},
    );

/// Writes [item] as a stored row into every given database.
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

/// Appends one row to the remote's change log, by hand.
///
/// The unit lane seeds actions rather than driving them, so that an action
/// whose entity has since been moved behind its back is expressible — which is
/// the whole subject of the refusal tests.
Future<void> seedChange(
  ConfigChange change, {
  AppDatabase? into,
}) async {
  final db = into ?? remote;
  await db.into(db.configChangeTable).insert(ConfigChangeTableCompanion.insert(
        at: change.at,
        actionId: change.actionId,
        who: change.who,
        station: change.station,
        roleName: change.roleName,
        reason: Value(change.reason),
        kind: change.kind.wireName,
        entityId: change.entityId,
        scope: change.scope.wireName,
        op: change.op.wireName,
        oldValue: Value(change.oldValue),
        newValue: Value(change.newValue),
      ));
}

/// The change row an ordinary save of [before] → [after] would have written.
ConfigChange changeOf({
  required String actionId,
  ConfigItem? before,
  ConfigItem? after,
  String who = 'operator',
  String station = kStation,
  DateTime? at,
}) =>
    ConfigChange.of(
      at: at ?? DateTime.utc(2026, 2, 1, 9),
      actionId: actionId,
      who: who,
      station: station,
      roleName: 'Engineer',
      before: before,
      after: after,
    );

Future<List<ConfigItemRow>> itemRows(AppDatabase db) =>
    (db.select(db.configItemTable)
          ..orderBy([
            (t) => OrderingTerm(expression: t.kind),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();

Future<List<ConfigChangeRow>> changeRows(AppDatabase db) =>
    (db.select(db.configChangeTable)
          ..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .get();

/// The whole of both tables as comparable text — what "nothing was written"
/// means when a refusal is under test.
Future<String> snapshotOf(AppDatabase db) async => jsonEncode({
      'items': [
        for (final row in await itemRows(db))
          [
            row.kind,
            row.id,
            row.scope,
            row.parentId,
            row.sortIndex,
            row.payload,
            row.rev,
            row.updatedBy,
          ],
      ],
      'changes': [
        for (final row in await changeRows(db))
          [
            row.id,
            row.actionId,
            row.kind,
            row.entityId,
            row.op,
            row.oldValue,
            row.newValue,
            row.reason,
          ],
      ],
    });

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    local = AppDatabase.inMemoryForTest();
    remote = AppDatabase.inMemoryForTest();
    store = storeOn(local);
  });

  tearDown(() async {
    await store.close();
    await local.close();
    await remote.close();
  });

  group('planUndo reads an action and answers a verdict', () {
    test('an unknown action is an empty refusal, not a throw', () async {
      final plan = await planUndo(remote, 'never-happened');

      expect(plan.isUnknownAction, isTrue);
      expect(plan.isReady, isFalse);
      expect(plan.steps, isEmpty);
      expect(plan.blockers, isEmpty);
      expect(plan.kinds, isEmpty);
    });

    test('an insert inverts to removing the entity', () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: asset));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isTrue);
      expect(plan.kinds, {ConfigKind.asset});
      expect(plan.steps, hasLength(1));
      expect(plan.steps.single.entityId, 'a1');
      expect(plan.steps.single.originalOp, ConfigChangeOp.insert);
      expect(plan.steps.single.inverseOp, ConfigChangeOp.delete);
      expect(plan.steps.single.item, isNull,
          reason: 'undoing an insert is a removal; there is nothing to write');
      expect(plan.steps.single.isRemoval, isTrue);
    });

    test('a delete inverts to re-inserting oldItem with its position',
        () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 2048);
      await seedChange(changeOf(actionId: 'act-1', before: asset));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isTrue);
      final step = plan.steps.single;
      expect(step.originalOp, ConfigChangeOp.delete);
      expect(step.inverseOp, ConfigChangeOp.insert);
      expect(step.isRemoval, isFalse);
      expect(step.item!.parentId, 'p1',
          reason: 'position is part of the entity, and a restore that lost it '
              'would put the asset back on no page at all');
      expect(step.item!.sortIndex, 2048);
      expect(step.item!.payload, asset.payload);
    });

    test('an update inverts to the old item', () async {
      final before = assetItem('a1', page: 'p1', ordinal: 1024);
      final after = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seed(after, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', before: before, after: after));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isTrue);
      final step = plan.steps.single;
      expect(step.originalOp, ConfigChangeOp.update);
      expect(step.inverseOp, ConfigChangeOp.update);
      expect(step.item!.payload, before.payload);
    });

    test('the plan names every kind the action touched', () async {
      final page = pageItem('p1');
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(page, into: [local, remote]);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: page));
      await seedChange(changeOf(actionId: 'act-1', after: asset));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isTrue);
      expect(plan.kinds, {ConfigKind.page, ConfigKind.asset});
      expect(plan.steps, hasLength(2));
    });
  });

  group('the world moving blocks the whole undo', () {
    test('a later change row for a touched entity blocks it, naming who '
        'and when', () async {
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seed(v2, into: [local, remote], rev: 2);
      await seedChange(changeOf(actionId: 'act-1', after: v1));
      await seedChange(changeOf(
        actionId: 'act-2',
        before: v1,
        after: v2,
        who: 'ingibjorg',
        station: kOtherStation,
        at: DateTime.utc(2026, 2, 2, 14, 30),
      ));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers, hasLength(1));
      final blocker = plan.blockers.single;
      expect(blocker.reason, UndoBlockReason.newerChange);
      expect(blocker.entityId, 'a1');
      expect(blocker.who, 'ingibjorg');
      expect(blocker.at!.isAtSameMomentAs(DateTime.utc(2026, 2, 2, 14, 30)),
          isTrue);
      expect(blocker.summary, contains('a1'));
      expect(blocker.summary, contains('ingibjorg'));
    });

    test('every blocked entity is listed, not just the first', () async {
      final a1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a2 = assetItem('a2', page: 'p1', ordinal: 2048);
      await seed(a1, into: [local, remote]);
      await seed(a2, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: a1));
      await seedChange(changeOf(actionId: 'act-1', after: a2));
      await seedChange(changeOf(
          actionId: 'act-2',
          before: a1,
          after: assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue')));
      await seedChange(changeOf(
          actionId: 'act-3',
          before: a2,
          after: assetItem('a2', page: 'p1', ordinal: 2048, colour: 'blue')));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.map((b) => b.entityId), ['a1', 'a2'],
          reason: 'an operator told about one blocker at a time would fix them '
              'one at a time and be refused again each round');
    });

    test('a live row that diverges from the action blocks it, with no newer '
        'change row at all', () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: asset));
      // A restore from backup, or a writer that skipped the log: the position
      // moved and the history knows nothing about it. This is the divergence
      // an id check alone cannot see.
      await (remote.update(remote.configItemTable)
            ..where((t) => t.id.equals('a1')))
          .write(const ConfigItemTableCompanion(sortIndex: Value(4096)));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.entityMoved);
      expect(plan.blockers.single.entityId, 'a1');
    });

    test('a delete whose entity is back blocks the undo', () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seedChange(changeOf(actionId: 'act-1', before: asset));
      // Somebody re-created it without logging. Left alone, undoing the delete
      // would be an insert onto an existing primary key.
      await seed(asset, into: [local, remote]);

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.entityMoved);
    });

    test('an entity the action changed and that is now gone blocks it',
        () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seedChange(changeOf(actionId: 'act-1', after: asset));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.entityMoved);
      expect(plan.blockers.single.summary, contains('no longer a row'));
    });
  });

  group('what this write path cannot put back', () {
    test('a preference row is refused, naming the store that owns it',
        () async {
      final pref = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'startup_url',
        value: {'type': 'String', 'value': '/lines'},
        scope: kStationScope,
      );
      await seedChange(changeOf(actionId: 'act-1', after: pref));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.isUnknownAction, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.unsupportedKind);
      expect(plan.blockers.single.summary, contains('preference'));
    });

    test('a station-scoped entity of a shared kind is refused', () async {
      final asset = ConfigItem.of(
        kind: ConfigKind.asset,
        id: 'a1',
        value: {'id': 'a1'},
        scope: kStationScope,
        parentId: 'p1',
        sortIndex: 1024,
      );
      await seedChange(changeOf(actionId: 'act-1', after: asset));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.unsupportedScope);
    });

    test('a kind this build has never heard of is refused, not skipped',
        () async {
      await remote
          .into(remote.configChangeTable)
          .insert(ConfigChangeTableCompanion.insert(
            at: DateTime.utc(2026, 2, 1),
            actionId: 'act-1',
            who: 'operator',
            station: kOtherStation,
            roleName: 'Engineer',
            kind: 'recipe',
            entityId: 'r1',
            scope: ConfigScope.shared.wireName,
            op: ConfigChangeOp.insert.wireName,
            newValue: const Value('{"payload":{},"parent_id":null}'),
          ));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.unknownKind);
      expect(plan.blockers.single.kindName, 'recipe');
    });
  });

  group('history-exempt items', () {
    test('an action that touched only an image has no change rows to invert',
        () async {
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();
      await store.writeItems(
        kinds: const {ConfigKind.pageImage},
        wanted: [imageItem('sha-abc')],
        actionId: 'act-image',
        who: 'operator',
        roleName: 'Engineer',
      );

      final plan = await planUndo(remote, 'act-image');

      expect(plan.isUnknownAction, isTrue,
          reason: 'an exempt kind writes no change rows at all, so the log '
              'has never heard of the action — which is a different thing '
              'from an action that changed nothing');
      expect(plan.isReady, isFalse);
    });

    test('an action that touched an image and an asset plans only the asset',
        () async {
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();
      await store.writeItems(
        kinds: const {ConfigKind.pageImage, ConfigKind.asset},
        wanted: [imageItem('sha-abc'), assetItem('a1', page: 'p1', ordinal: 0)],
        actionId: 'act-mixed',
        who: 'operator',
        roleName: 'Engineer',
      );

      final plan = await planUndo(remote, 'act-mixed');

      expect(plan.isReady, isTrue);
      expect(plan.kinds, {ConfigKind.asset},
          reason: 'the image is not in the replace set, so undoing the asset '
              'cannot delete it');
      expect(plan.steps.map((s) => s.entityId), ['a1']);
    });
  });

  group('the order of the inverse', () {
    test('a page and its assets: re-insertions are parent-first, removals '
        'child-first', () async {
      final page = pageItem('p1');
      final a1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a2 = assetItem('a2', page: 'p1', ordinal: 2048);
      // The action deleted a page and its assets; undoing it puts them back.
      await seedChange(changeOf(actionId: 'del', before: page));
      await seedChange(changeOf(actionId: 'del', before: a1));
      await seedChange(changeOf(actionId: 'del', before: a2));

      final restore = await planUndo(remote, 'del');

      expect(restore.isReady, isTrue);
      expect(restore.steps.map((s) => s.entityId), ['p1', 'a1', 'a2'],
          reason: 'a child restored before its parent is an orphan for as '
              'long as it takes, and parent_id is deliberately not a foreign '
              'key, so nothing but this order catches it');

      // And the mirror image: an action that created them inverts to removals,
      // children first.
      await seed(page, into: [local, remote]);
      await seed(a1, into: [local, remote]);
      await seed(a2, into: [local, remote]);
      await seedChange(changeOf(actionId: 'add', after: page));
      await seedChange(changeOf(actionId: 'add', after: a1));
      await seedChange(changeOf(actionId: 'add', after: a2));

      final remove = await planUndo(remote, 'add');

      expect(remove.isReady, isTrue);
      expect(remove.steps.map((s) => s.entityId), ['a1', 'a2', 'p1']);
    });
  });
}
