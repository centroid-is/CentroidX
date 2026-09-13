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
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
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
    test('a shared preference plans like any other row', () async {
      final pref = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'alarm_man_config',
        value: {'type': 'String', 'value': '{}'},
      );
      await seed(pref, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: pref));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isTrue,
          reason: 'a shared preference is a shared row like any other since '
              '04-05, and writeItems can replace it');
      expect(plan.kinds, {ConfigKind.preference});
      expect(plan.steps.single.isRemoval, isTrue);
    });

    test('a station-scoped preference is refused — another store owns it',
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
      expect(plan.blockers.single.reason, UndoBlockReason.unsupportedScope);
      expect(plan.blockers.single.summary, contains('startup_url'));
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

    test('a bookkeeping row is refused by name', () async {
      final marker = ConfigItem.of(
        kind: ConfigKind.preference,
        id: kPreferencesMigratedMarkerId,
        value: {'type': 'bool', 'value': true},
      );
      await seed(marker, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: marker));

      final plan = await planUndo(remote, 'act-1');

      expect(plan.isReady, isFalse);
      expect(plan.blockers.single.reason, UndoBlockReason.internalRow);
    });

    test('the marker really is one of the ids that refusal catches', () {
      // The pin under the literal prefix. `_internalIdPrefix` is private to
      // shared_row_preferences.dart, so undo carries its own copy; this is
      // what stops the copy drifting away from the row it exists to protect.
      expect(kPreferencesMigratedMarkerId.startsWith(kUndoInternalIdPrefix),
          isTrue);
      expect(kKeyMappingsWatermarkId.startsWith(kUndoInternalIdPrefix), isTrue);
    });

    test('a migration that wrote its marker and its values under one action '
        'cannot be undone at all', () async {
      // The 04-11 shape, and the reason this refusal is not merely tidy: one
      // administer click would otherwise delete every migrated preference row
      // *and* the marker, and after the old table is dropped the change rows
      // are the only copy.
      final marker = ConfigItem.of(
        kind: ConfigKind.preference,
        id: kPreferencesMigratedMarkerId,
        value: {'type': 'bool', 'value': true},
      );
      final value = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'alarm_man_config',
        value: {'type': 'String', 'value': '{}'},
      );
      await seed(marker, into: [local, remote]);
      await seed(value, into: [local, remote]);
      await seedChange(changeOf(actionId: 'migrate', after: marker));
      await seedChange(changeOf(actionId: 'migrate', after: value));

      final plan = await planUndo(remote, 'migrate');

      expect(plan.isReady, isFalse,
          reason: 'all-or-nothing: the marker blocks the whole action, so the '
              'values it migrated cannot be deleted either');
      expect(plan.blockers.map((b) => b.reason),
          [UndoBlockReason.internalRow]);
    });

    test('every kind this build knows is one writeItems can replace', () {
      // Which is why `UndoBlockReason.unsupportedKind` has no test that
      // reaches it: there is no such kind today. The arm stays as the
      // fail-closed answer for the next kind somebody adds outside the set,
      // and this assertion is what makes adding one a decision rather than a
      // silent change of what undo will attempt to write.
      expect(ConfigKind.values.toSet().difference(kSharedConfigKinds), isEmpty);
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

  group('executing an undo is an ordinary save', () {
    /// A store attached to [remote] with its snapshot filled.
    Future<void> openStore() async {
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();
    }

    Future<ConfigWriteResult> undo(UndoPlan plan,
            {Set<AccessGroup>? groups, String actionId = 'undo-1'}) =>
        executeUndo(
          plan,
          store: store,
          policy: policy,
          sessionGroups: groups ?? kAllGroups,
          actionId: actionId,
          who: 'gudrun',
          roleName: 'Engineer',
        );

    test('the inverse goes through writeItems and nowhere else', () {
      // The source, with whole-line comments stripped so the paragraph above
      // `writeItems` cannot be what makes this pass — and so a commented-out
      // second write cannot be what makes it fail.
      final source = File('lib/core/config/config_undo.dart')
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      expect('writeItems('.allMatches(source), hasLength(1),
          reason: 'a second write path would be a second copy of the '
              'compare-and-swap, the change-row append and the offline '
              'refusal, and the two would drift');
      expect(source, isNot(contains('ConfigItemTableCompanion')));
      expect(source, isNot(contains('ConfigChangeTableCompanion')));
      expect(source, isNot(contains('.delete(')));
    });

    test('undoing an insert removes it and leaves its siblings alone',
        () async {
      final a1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a2 = assetItem('a2', page: 'p1', ordinal: 2048);
      final a3 = assetItem('a3', page: 'p1', ordinal: 3072);
      await seed(a1, into: [local, remote]);
      await seed(a2, into: [local, remote]);
      await seed(a3, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: a3));
      await openStore();

      final result = await undo(await planUndo(remote, 'act-1'));

      expect(result.diff.removed.map((i) => i.id), ['a3']);
      expect(
          (await itemRows(remote)).map((r) => r.id), ['a1', 'a2'],
          reason: 'writeItems replaces within kinds, so handing it a partial '
              'set would have deleted every asset on the plant');
      expect(store.itemsOf(const {ConfigKind.asset}).map((i) => i.id),
          ['a1', 'a2']);
    });

    test('undoing a shared preference leaves the other preferences alone',
        () async {
      final alarms = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          value: {'type': 'String', 'value': '{"a":1}'});
      final edited = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          value: {'type': 'String', 'value': '{"a":2}'});
      final other = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'page_editor_top_level_order',
          value: {'type': 'String', 'value': '[]'});
      await seed(edited, into: [local, remote]);
      await seed(other, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', before: alarms, after: edited));
      await openStore();

      await undo(await planUndo(remote, 'act-1'));

      final rows = {
        for (final row in await itemRows(remote)) row.id: row.payload,
      };
      expect(rows.keys, containsAll(['alarm_man_config',
        'page_editor_top_level_order']));
      expect(rows['alarm_man_config'], alarms.payload);
      expect(rows['page_editor_top_level_order'], other.payload);
    });

    test('the undo is a new action whose rows say what they are', () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: asset));
      await openStore();

      await undo(await planUndo(remote, 'act-1'), actionId: 'undo-of-act-1');

      final rows = await changeRows(remote);
      expect(rows, hasLength(2), reason: 'the log is append-only: the undo '
          'adds a row, it does not remove the one it inverts');
      expect(rows.first.actionId, 'act-1');
      expect(rows.last.actionId, 'undo-of-act-1');
      expect(rows.last.op, ConfigChangeOp.delete.wireName);
      expect(rows.last.reason, 'undo of act-1');
      expect(rows.last.who, 'gudrun');
    });

    test('undoing the undo puts it back, with no extra machinery', () async {
      final before = assetItem('a1', page: 'p1', ordinal: 1024);
      final after = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seed(after, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', before: before, after: after));
      await openStore();

      await undo(await planUndo(remote, 'act-1'), actionId: 'undo-1');
      expect(store.itemsOf(const {ConfigKind.asset}).single.payload,
          before.payload);

      // The undo is an action like any other, so it inverts the same way.
      final second = await planUndo(remote, 'undo-1');
      expect(second.isReady, isTrue);
      await undo(second, actionId: 'undo-2');

      expect(store.itemsOf(const {ConfigKind.asset}).single.payload,
          after.payload);
      expect((await changeRows(remote)).map((r) => r.actionId),
          ['act-1', 'undo-1', 'undo-2']);
    });

    test('a restored page and its assets leave no orphan behind', () async {
      final page = pageItem('p1');
      final a1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a2 = assetItem('a2', page: 'p1', ordinal: 2048);
      await seedChange(changeOf(actionId: 'act-1', before: page));
      await seedChange(changeOf(actionId: 'act-1', before: a1));
      await seedChange(changeOf(actionId: 'act-1', before: a2));
      await openStore();

      await undo(await planUndo(remote, 'act-1'));

      expect((await itemRows(remote)).map((r) => r.id), ['a1', 'a2', 'p1']);
      // The invariant the step order is about, checked rather than assumed:
      // `parent_id` is not a foreign key, so nothing but this says the
      // children came back onto a page that exists.
      expect(await checkConfigConsistency(remote), isEmpty);
    });

    test('a reorder is undone to the original order', () async {
      final a1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a2 = assetItem('a2', page: 'p1', ordinal: 2048);
      // The action moved a2 in front of a1.
      final movedA2 = assetItem('a2', page: 'p1', ordinal: 512);
      await seed(a1, into: [local, remote], key: 1024);
      await seed(movedA2, into: [local, remote], key: 512);
      await seedChange(changeOf(actionId: 'act-1', before: a2, after: movedA2));
      await openStore();

      await undo(await planUndo(remote, 'act-1'));

      final order = store.itemsOf(const {ConfigKind.asset}).toList()
        ..sort((x, y) => x.sortIndex!.compareTo(y.sortIndex!));
      expect(order.map((i) => i.id), ['a1', 'a2'],
          reason: "the change row's stored key is what puts it back, and "
              'assignSortKeys reads it as the rank it already is');
    });

    test('a delete-undo racing a re-creation surfaces ConfigConflict',
        () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seedChange(changeOf(actionId: 'act-1', before: asset));
      await openStore();

      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isTrue);

      // Another station re-creates it in the window between the verdict and
      // the write. Nothing this store knows about — which is the point.
      await seed(asset, into: [remote]);

      await expectLater(undo(plan), throwsA(isA<ConfigConflict>()));
      expect((await changeRows(remote)).map((r) => r.actionId), ['act-1'],
          reason: 'the transaction rolled back, so the undo wrote no change '
              'row of its own');
      expect(await itemRows(remote), hasLength(1),
          reason: "the other station's row is intact");
    });
  });

  group('the verdict has to still be true when the write runs', () {
    /// A store whose snapshot is level with the remote, sync attached but
    /// driven by hand.
    ///
    /// `startSync: false` is not a convenience here: these tests own the
    /// moment the snapshot moves, and a background reconcile would close the
    /// window they exist to open — or open one they did not ask for.
    Future<void> levelled() async {
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();
    }

    /// Another station's edit, landing on the remote the way one really does:
    /// the row and the change row that announces it.
    Future<void> foreignEdit(ConfigItem next, {required int fromRev}) async {
      await (remote.update(remote.configItemTable)
            ..where((t) =>
                t.kind.equals(next.kind.wireName) &
                t.id.equals(next.id) &
                t.scope.equals(next.scope.wireName)))
          .write(ConfigItemTableCompanion(
        payload: Value(next.payload),
        parentId: Value(next.parentId),
        sortIndex: Value(next.sortIndex),
        rev: Value(fromRev + 1),
        updatedAt: Value(DateTime.utc(2026, 9, 4, 8, 15)),
        updatedBy: const Value('ingibjorg'),
      ));
    }

    test('F1: an edit that sync has already applied refuses, rather than '
        'being written over', () async {
      final v0 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'green');
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seed(v1, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', before: v0, after: v1));
      await levelled();

      // The verdict, taken while the world still agrees with it.
      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isTrue);

      // Station B edits the entity and this station hears about it — which is
      // the ordinary case, not the exotic one: the notification lands in
      // milliseconds and the confirm dialog is open for seconds.
      await foreignEdit(v2, fromRev: 1);
      await seedChange(changeOf(
          actionId: 'act-2',
          before: v1,
          after: v2,
          who: 'ingibjorg',
          station: kOtherStation));
      await store.pullChanges();
      expect(store.itemsOf(const {ConfigKind.asset}).single.payload,
          v2.payload,
          reason: "the snapshot has taken B's edit, so the CAS will match it "
              'and cannot be what refuses this undo');

      // The refusal `UndoBlockReason.newerChange` exists for. Without the
      // plan-time rev, this commits v0 straight over B's v2.
      await expectLater(
        executeUndo(plan,
            store: store,
            policy: policy,
            sessionGroups: kAllGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer'),
        throwsA(isA<ConfigConflict>()),
      );

      final rows = await remote.select(remote.configItemTable).get();
      expect(rows.single.payload, v2.payload,
          reason: "B's edit must still be there");
      expect((await remote.select(remote.configChangeTable).get())
          .map((r) => r.actionId), ['act-1', 'act-2'],
          reason: 'and the undo wrote no change row');
    });

    test('F1b: undoing an insert deletes the row another station has since '
        'edited — the same window, one step worse', () async {
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      // This time the action *created* the entity, so its inverse is a
      // removal: B's edit is not overwritten but destroyed, and the delete arm
      // is CAS'd on the snapshot's rev, which the pull has just made current.
      await seed(v1, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: v1));
      await levelled();

      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isTrue);

      await foreignEdit(v2, fromRev: 1);
      await seedChange(changeOf(
          actionId: 'act-2',
          before: v1,
          after: v2,
          who: 'ingibjorg',
          station: kOtherStation));
      await store.pullChanges();

      await expectLater(
        executeUndo(plan,
            store: store,
            policy: policy,
            sessionGroups: kAllGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer'),
        throwsA(isA<ConfigConflict>()),
      );

      expect(await remote.select(remote.configItemTable).get(), hasLength(1),
          reason: "B's row must not have been deleted out from under it");
    });

    test('F2: a snapshot that has not caught up refuses, rather than writing '
        'nothing and reporting success', () async {
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      // The remote holds the action's result; this station's mirror is still
      // at the value before it — a fresh mirror, or a notification lost inside
      // the sweep window.
      await seed(v2, into: [remote], rev: 2);
      await seed(v1, into: [local]);
      await seedChange(changeOf(actionId: 'act-1', before: v1, after: v2));
      await levelled();
      expect(store.itemsOf(const {ConfigKind.asset}).single.payload,
          v1.payload,
          reason: 'the snapshot is behind the action being undone, which is '
              'what makes the inverse look like a no-op');

      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isTrue,
          reason: 'the remote agrees with the action, so the verdict is ready '
              '— the disagreement is between the remote and this snapshot');

      await expectLater(
        executeUndo(plan,
            store: store,
            policy: policy,
            sessionGroups: kAllGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer'),
        throwsA(isA<ConfigConflict>()),
      );

      expect((await remote.select(remote.configItemTable).get()).single.payload,
          v2.payload,
          reason: 'the remote is untouched: the undo neither wrote nor '
              'pretended to');
    });

    test('F2b: a half-synced multi-entity action refuses whole, rather than '
        'committing the half it can see', () async {
      final a1v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final a1v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      final a2v1 = assetItem('a2', page: 'p1', ordinal: 2048);
      final a2v2 = assetItem('a2', page: 'p1', ordinal: 2048, colour: 'blue');
      // The remote holds both halves of the action; the mirror has caught up
      // with a1 and not with a2.
      await seed(a1v2, into: [remote], rev: 2);
      await seed(a2v2, into: [remote], rev: 2);
      await seed(a1v2, into: [local], rev: 2);
      await seed(a2v1, into: [local]);
      await seedChange(changeOf(actionId: 'act-1', before: a1v1, after: a1v2));
      await seedChange(changeOf(actionId: 'act-1', before: a2v1, after: a2v2));
      await levelled();

      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isTrue);

      await expectLater(
        executeUndo(plan,
            store: store,
            policy: policy,
            sessionGroups: kAllGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer'),
        throwsA(isA<ConfigConflict>()),
      );

      // All or nothing: the entity the snapshot *could* have restored must not
      // have been restored on its own.
      final rows = {
        for (final row in await remote.select(remote.configItemTable).get())
          row.id: row.payload,
      };
      expect(rows['a1'], a1v2.payload);
      expect(rows['a2'], a2v2.payload);
    });

    test('a plan whose world has not moved still writes', () async {
      // The control. Without it the three refusals above could be passing
      // because nothing can ever execute.
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seed(v2, into: [local, remote], rev: 2);
      await seedChange(changeOf(actionId: 'act-1', before: v1, after: v2));
      await levelled();

      final plan = await planUndo(remote, 'act-1');
      final result = await executeUndo(plan,
          store: store,
          policy: policy,
          sessionGroups: kAllGroups,
          actionId: 'undo-1',
          who: 'gudrun',
          roleName: 'Engineer');

      expect(result.diff.changed, hasLength(1));
      expect((await remote.select(remote.configItemTable).get()).single.payload,
          v1.payload);
    });
  });

  group('the gate is inside execute, not at the page', () {
    test('the group is the one the original write required', () {
      expect(undoGateFor(policy, ConfigKind.asset, 'a1').group,
          AccessGroup.configure);
      expect(undoGateFor(policy, ConfigKind.page, 'p1').group,
          AccessGroup.configure);
      expect(undoGateFor(policy, ConfigKind.keyMapping, 'CN04.Belt').group,
          AccessGroup.configure);
      // A preference is gated per key, as `GuardedConfigStore.writePreference`
      // is: two preference rows are not one permission.
      expect(undoGateFor(policy, ConfigKind.preference, 'alarm_man_config')
          .group, AccessGroup.configure);
      expect(undoGateFor(policy, ConfigKind.preference, 'collector_config')
          .group, AccessGroup.administer);
      // A kind nobody classified falls to the policy's closed default.
      expect(undoGateFor(policy, ConfigKind.pageImage, 'sha-abc').group,
          AccessGroup.administer);
    });

    test('the check keys are the guard\'s own, spelled out', () {
      // Value agreement, entry by entry. A copy that drifted would gate an
      // undo on a different permission from the write it inverts.
      for (final entry in kUndoCheckKeys.entries) {
        expect(kConfigWriteKeys[entry.key], entry.value,
            reason: 'this map is a deliberate copy, made because the guard\'s '
                'own reaches open62541 through the key-mapping codec');
      }
    });

    test('every kind an undo plan can hold has a check key', () {
      // **Coverage, not set equality.** The two maps answer different
      // questions and 04-09 is what made the difference visible: it added
      // `pageImage` to the guard's map, because an image *write* is gated
      // there. An image can never appear in an undo plan — it writes no
      // change rows at all — so undo's map does not carry it, and the
      // `administer` fail-closed answer above stays the one an unmapped kind
      // gets. Asserting the two maps were identical was asserting something
      // that happened to be true rather than something that had to be.
      final undoable = kSharedConfigKinds
          .difference(kHistoryExemptKinds)
          // A preference is keyed per key, not per kind — the same ruling
          // `GuardedConfigStore.writePreference` is built on.
          .difference({ConfigKind.preference});
      expect(kUndoCheckKeys.keys.toSet(), undoable,
          reason: 'a kind that can be planned and has no check key would fall '
              'to the policy default and lock an operator out of undoing '
              'something they were allowed to do');
    });

    test('a plan spanning two permissions is gated on the stricter', () async {
      final alarms = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'alarm_man_config',
          value: {'type': 'String', 'value': '{}'});
      final collector = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'collector_config',
          value: {'type': 'String', 'value': '{}'});
      await seed(alarms, into: [local, remote]);
      await seed(collector, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: alarms));
      await seedChange(changeOf(actionId: 'act-1', after: collector));

      final plan = await planUndo(remote, 'act-1');

      expect(undoGate(policy, plan).group, AccessGroup.administer);
      expect(undoGate(policy, plan).itemKey, 'collector_config');
    });

    test('a session without the group is refused, and nothing is written',
        () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: asset));
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      final plan = await planUndo(remote, 'act-1');
      final before = await snapshotOf(remote);
      final beforeLocal = await snapshotOf(local);

      await expectLater(
          executeUndo(
            plan,
            store: store,
            policy: policy,
            sessionGroups: kOperatorGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Operator',
          ),
          throwsA(isA<AccessDenied>()
              .having((d) => d.required, 'required', AccessGroup.configure)
              .having((d) => d.itemKey, 'itemKey', 'page_editor_data')));

      expect(await snapshotOf(remote), before,
          reason: 'a gate that throws after writing is not a gate');
      expect(await snapshotOf(local), beforeLocal);
      expect(store.itemsOf(const {ConfigKind.asset}).single.payload,
          asset.payload);
    });

    test('a configure session may not undo an administer write', () async {
      final collector = ConfigItem.of(
          kind: ConfigKind.preference,
          id: 'collector_config',
          value: {'type': 'String', 'value': '{}'});
      await seed(collector, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: collector));
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      final plan = await planUndo(remote, 'act-1');
      final before = await snapshotOf(remote);

      await expectLater(
          executeUndo(
            plan,
            store: store,
            policy: policy,
            sessionGroups: const {AccessGroup.operate, AccessGroup.configure},
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer',
          ),
          throwsA(isA<AccessDenied>()
              .having((d) => d.required, 'required', AccessGroup.administer)));

      expect(await snapshotOf(remote), before);
    });

    test('a plan that is not ready cannot be executed at all', () async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seed(asset, into: [local, remote]);
      await seedChange(changeOf(actionId: 'act-1', after: asset));
      await seedChange(changeOf(
          actionId: 'act-2',
          before: asset,
          after: assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue')));
      store.attachRemoteDatabase(remote, startSync: false);
      await store.open();

      final plan = await planUndo(remote, 'act-1');
      expect(plan.isReady, isFalse);
      final before = await snapshotOf(remote);

      await expectLater(
          executeUndo(
            plan,
            store: store,
            policy: policy,
            sessionGroups: kAllGroups,
            actionId: 'undo-1',
            who: 'gudrun',
            roleName: 'Engineer',
          ),
          throwsA(isA<ArgumentError>()));

      expect(await snapshotOf(remote), before);
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
