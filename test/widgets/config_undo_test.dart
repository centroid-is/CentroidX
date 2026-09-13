/// Undo, from the tap to the row it writes.
///
/// The seams are chosen so that as little as possible is a fake. The change
/// log, the config rows, `planUndo` and `ConfigStore.writeItems` are all real,
/// over two in-memory SQLite databases — so what these tests exercise is the
/// production statements, not a mock's idea of them. Three things are
/// substituted, each because it needs something a widget test cannot have:
///
/// * `databaseProvider` — a [Database] wrapper cannot wrap SQLite at all
///   (`config_store.dart`'s library doc), so the wrapper is faked around a real
///   [AppDatabase];
/// * `configStoreProvider` — the same, one level up: the guard is faked around
///   a real [ConfigStore] attached to the same in-memory remote;
/// * `accessSessionProvider` — a session is what these tests vary.
///
/// **The session must be resolved before anything taps.** `sessionInForce`
/// reads the provider and falls back to the operator floor while it is still
/// loading, so a test that taps Undo without awaiting the session first would
/// be refused for a reason it did not intend and would pass for the wrong one.
/// [_pump] awaits it.
library;

import 'package:drift/drift.dart'
    show OrderingTerm, Value, driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_policy.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/widgets/config_undo_dialogs.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/config_undo.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

const String kStation = 'test-station';

/// When the seeded action happened: two days ago, whatever today is. The
/// page's default window is the last seven days from the real clock, so a
/// literal date here is a test that expires a week after it was written.
final DateTime kSeedAt =
    DateTime.now().toUtc().subtract(const Duration(days: 2));

/// A later change by another station, still inside the window.
final DateTime kLaterAt = kSeedAt.add(const Duration(hours: 20));

/// [at] as the dialog's timestamp formatter writes the day: `dd.MM.yy`,
/// local time, so the assertion follows the seed rather than a literal.
String dayOf(DateTime at) {
  final d = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${two(d.year % 100)}';
}
const String kOtherStation = 'other-station';

/// The wrapper, around a real database. See the library doc.
class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;
}

/// The guard, around a real store. Only [inner] is ever reached: undo goes
/// through `executeUndo`, which takes the store and asserts the gate itself.
class _FakeGuardedStore extends Fake implements GuardedConfigStore {
  _FakeGuardedStore(this.inner);

  @override
  final ConfigStore inner;
}

/// A session fixed at construction, as `access_templates_test.dart` fixes one.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;
}

/// Every `audit_entry` the undo wrote, in order.
class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = <AuditRecord>[];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

AccessSession _sessionWith(Set<AccessGroup> groups, {String? username}) =>
    AccessSession(
      groups: groups,
      user: username == null
          ? null
          : AuthenticatedUser(username: username, roleName: 'Engineer'),
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

ConfigItem prefItem(String id, String value) => ConfigItem.of(
      kind: ConfigKind.preference,
      id: id,
      value: {'type': 'String', 'value': value},
    );

Future<void> seedItem(ConfigItem item, List<AppDatabase> into,
    {int rev = 1}) async {
  for (final db in into) {
    await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
          kind: item.kind.wireName,
          id: item.id,
          scope: item.scope.wireName,
          parentId: Value(item.parentId),
          sortIndex: Value(item.sortIndex),
          payload: item.payload,
          rev: Value(rev),
          updatedAt: DateTime.utc(2026, 9, 1),
          updatedBy: 'migration',
        ));
  }
}

Future<void> seedChange(
  AppDatabase db, {
  required String actionId,
  ConfigItem? before,
  ConfigItem? after,
  String who = 'jon',
  String station = kStation,
  DateTime? at,
}) async {
  final change = ConfigChange.of(
    at: at ?? kSeedAt,
    actionId: actionId,
    who: who,
    station: station,
    roleName: 'Engineer',
    before: before,
    after: after,
  );
  await db.into(db.configChangeTable).insert(ConfigChangeTableCompanion.insert(
        at: change.at,
        actionId: change.actionId,
        who: change.who,
        station: change.station,
        roleName: change.roleName,
        kind: change.kind.wireName,
        entityId: change.entityId,
        scope: change.scope.wireName,
        op: change.op.wireName,
        oldValue: Value(change.oldValue),
        newValue: Value(change.newValue),
      ));
}

/// One `audit_entry` header, so the action does not render as parentless.
Future<void> seedAuditHeader(AppDatabase db, String actionId) async {
  await db.into(db.auditEntry).insert(AuditEntryCompanion.insert(
        at: kSeedAt,
        who: 'jon',
        station: kStation,
        roleName: 'Engineer',
        surface: 'pref',
        itemKey: 'page_editor_data',
        groupRequired: 'configure',
        allowed: true,
        origin: const Value('operator'),
        actionId: actionId,
      ));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase remote;
  late AppDatabase local;
  late ConfigStore store;
  late _RecordingSink sink;

  setUp(() {
    remote = AppDatabase.inMemoryForTest();
    local = AppDatabase.inMemoryForTest();
    sink = _RecordingSink();
    store = ConfigStore(
      local: local,
      stationScope: ConfigScope.forStation(kStation),
      station: kStation,
    );
  });

  tearDown(() async {
    await store.close();
    await local.close();
    await remote.close();
  });

  /// The page over the real stores, with [groups] in force.
  ///
  /// Returns the container so a test can read a provider directly — and awaits
  /// the session, which is not optional. See the library doc.
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Set<AccessGroup> groups = const {AccessGroup.configure},
    String? username = 'gudrun',
  }) async {
    store.attachRemoteDatabase(remote, startSync: false);
    await store.open();

    final container = ProviderContainer(overrides: <Override>[
      databaseProvider.overrideWith((ref) async => _FakeDatabase(remote)),
      configStoreProvider.overrideWith((ref) async => _FakeGuardedStore(store)),
      auditSinkProvider.overrideWith((ref) async => sink),
      accessSessionProvider
          .overrideWith(() => _FixedSession(_sessionWith(groups,
              username: username))),
      stationNameProvider.overrideWithValue(kStation),
    ]);
    addTearDown(container.dispose);
    // Without this the first `sessionInForce` answers the boot-window floor.
    await container.read(accessSessionProvider.future);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: ConfigHistoryBody()),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<List<ConfigChangeRow>> changeRows() =>
      (remote.select(remote.configChangeTable)
            ..orderBy([(t) => OrderingTerm(expression: t.id)]))
          .get();

  Future<List<ConfigItemRow>> itemRows() =>
      (remote.select(remote.configItemTable)
            ..orderBy([(t) => OrderingTerm(expression: t.id)]))
          .get();

  group('the Undo control is offered where it can work', () {
    testWidgets('an action with shared change rows offers one', (tester) async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seedItem(asset, [local, remote]);
      await seedChange(remote, actionId: 'act-1', after: asset);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);

      expect(find.byKey(configHistoryUndoKey('act-1')), findsOneWidget);
    });

    testWidgets('a station-scoped action offers none', (tester) async {
      final pref = ConfigItem.of(
        kind: ConfigKind.preference,
        id: 'startup_url',
        value: {'type': 'String', 'value': '/lines'},
        scope: ConfigScope.forStation(kStation),
      );
      await seedChange(remote, actionId: 'act-1', after: pref);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);

      expect(find.byKey(configHistoryUndoKey('act-1')), findsNothing,
          reason: 'this view reads Postgres and a station row is not in it; a '
              'button that could only ever refuse is worse than none');
    });

  });

  group('the happy path', () {
    testWidgets('confirm writes the inverse as a new action and refreshes',
        (tester) async {
      final before = assetItem('a1', page: 'p1', ordinal: 1024);
      final after = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seedItem(after, [local, remote]);
      await seedChange(remote, actionId: 'act-1', before: before, after: after);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);

      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);

      // The confirmation names the write, not the original edit.
      expect(find.byKey(kConfigUndoConfirmKey), findsOneWidget);
      expect(find.byKey(kConfigUndoStepKey), findsOneWidget);
      expect(find.text('Revert asset a1 to its previous version on p1, in '
          'its original order'), findsOneWidget);
      expect(find.byKey(kConfigUndoAuditNoteKey), findsOneWidget);

      await tester.tap(find.byKey(kConfigUndoConfirmButtonKey));
      await settle(tester);

      // The row is back.
      final rows = await itemRows();
      expect(rows.single.payload, before.payload);

      // And the log holds both actions, the undo carrying its own id and the
      // reason that says what it is.
      final log = await changeRows();
      expect(log, hasLength(2));
      expect(log.first.actionId, 'act-1');
      expect(log.last.actionId, isNot('act-1'));
      expect(log.last.reason, 'undo of act-1');
      expect(log.last.who, 'gudrun');

      // The audit parent, with the same action id as the rows beneath it.
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.actionId, log.last.actionId);
      expect(sink.rows.single.allowed, isTrue);
      expect(sink.rows.single.groupRequired, AccessGroup.configure.name);
      expect(sink.rows.single.reason, 'undo of act-1');

      expect(find.text(kConfigHistoryUndoneNote), findsOneWidget);
    });

    testWidgets('cancel writes nothing at all', (tester) async {
      final before = assetItem('a1', page: 'p1', ordinal: 1024);
      final after = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seedItem(after, [local, remote]);
      await seedChange(remote, actionId: 'act-1', before: before, after: after);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);
      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);
      await tester.tap(find.byKey(kConfigUndoCancelButtonKey));
      await settle(tester);

      expect((await changeRows()), hasLength(1));
      expect((await itemRows()).single.payload, after.payload);
      expect(sink.rows, isEmpty);
    });
  });

  group('the gate is on the write, not on the route', () {
    testWidgets(
        'a configure session may read this page and may not undo an '
        'administer action', (tester) async {
      // `collector_config` is `administer` in kPrefAccessRules; the page itself
      // is `configure`. C-14: the two are different questions.
      final pref = prefItem('collector_config', '{}');
      await seedItem(pref, [local, remote]);
      await seedChange(remote, actionId: 'act-1', after: pref);
      await seedAuditHeader(remote, 'act-1');

      final container =
          await pump(tester, groups: const {AccessGroup.configure});
      final denials = <AccessDenied>[];
      final sub = container.read(accessDenialsProvider).listen(denials.add);
      addTearDown(sub.cancel);
      await settle(tester);

      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);

      // No confirmation was ever offered: the refusal happens before the
      // dialog, so the operator is not asked to approve something that cannot
      // happen.
      expect(find.byKey(kConfigUndoConfirmKey), findsNothing);
      expect(denials, hasLength(1));
      expect(denials.single.required, AccessGroup.administer);
      expect(denials.single.itemKey, 'collector_config');

      // Nothing was written to the configuration...
      expect((await changeRows()), hasLength(1));
      expect((await itemRows()).single.payload, pref.payload);
      // ...and the refusal is in the trail, which is the point of recording it.
      expect(sink.rows, hasLength(1));
      expect(sink.rows.single.allowed, isFalse);
      expect(sink.rows.single.groupRequired, AccessGroup.administer.name);
      expect(sink.rows.single.newValue, isNull);
    });

    testWidgets('holding administer, the same undo goes through',
        (tester) async {
      final pref = prefItem('collector_config', '{}');
      await seedItem(pref, [local, remote]);
      await seedChange(remote, actionId: 'act-1', after: pref);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester, groups: const {
        AccessGroup.configure,
        AccessGroup.administer,
      });
      await settle(tester);

      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);
      expect(find.byKey(kConfigUndoConfirmKey), findsOneWidget);
      await tester.tap(find.byKey(kConfigUndoConfirmButtonKey));
      await settle(tester);

      expect(await itemRows(), isEmpty,
          reason: 'the action inserted the row, so undoing it deletes it');
      expect((await changeRows()), hasLength(2));
    });
  });

  group('an action with no audit header is gated the same way', () {
    testWidgets(
        'the required group comes from the change rows, not from the header '
        'the action never got', (tester) async {
      // Both are `administer` under kPrefAccessRules. One has its audit header
      // and one does not — the orphan window, which a half-migrated plant is
      // full of. The permission must not depend on which.
      final withHeader = prefItem('collector_config', '{}');
      final parentless = prefItem('state_man_config', '{}');
      await seedItem(withHeader, [local, remote]);
      await seedItem(parentless, [local, remote]);
      await seedChange(remote, actionId: 'act-header', after: withHeader);
      await seedAuditHeader(remote, 'act-header');
      // No seedAuditHeader for this one. `HistoryAction.requiredGroupLabel`
      // is the empty string for it, and the gate must not read that.
      await seedChange(remote, actionId: 'act-orphan', after: parentless);

      final container =
          await pump(tester, groups: const {AccessGroup.configure});
      final denials = <AccessDenied>[];
      final sub = container.read(accessDenialsProvider).listen(denials.add);
      addTearDown(sub.cancel);
      await settle(tester);

      await tester.tap(find.byKey(configHistoryUndoKey('act-header')));
      await settle(tester);
      await tester.tap(find.byKey(configHistoryUndoKey('act-orphan')));
      await settle(tester);

      expect(denials.map((d) => d.required),
          [AccessGroup.administer, AccessGroup.administer],
          reason: 'an action whose permission was never recorded must not be '
              'easier to undo than one whose permission is known — the gate '
              'resolves it from the change rows kind and key, and planUndo '
              'never reads audit_entry at all');
      expect(denials.map((d) => d.itemKey),
          ['collector_config', 'state_man_config']);

      // Neither fell open and neither threw: no dialog was offered, and the
      // configuration is untouched.
      expect(find.byKey(kConfigUndoConfirmKey), findsNothing);
      expect((await changeRows()), hasLength(2));
      expect(sink.rows.map((r) => r.allowed), [false, false]);
    });

    testWidgets('holding the group, a parentless action undoes normally',
        (tester) async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      await seedItem(asset, [local, remote]);
      await seedChange(remote, actionId: 'act-orphan', after: asset);

      await pump(tester);
      await settle(tester);
      await tester.tap(find.byKey(configHistoryUndoKey('act-orphan')));
      await settle(tester);
      expect(find.byKey(kConfigUndoConfirmKey), findsOneWidget,
          reason: 'a missing header is not a reason to refuse either — it '
              'must neither fall open nor throw');
      await tester.tap(find.byKey(kConfigUndoConfirmButtonKey));
      await settle(tester);

      expect(await itemRows(), isEmpty);
      expect((await changeRows()), hasLength(2));
    });
  });

  group('an undo that writes nothing is never reported as done', () {
    testWidgets('no audit parent, and the refusal dialog instead',
        (tester) async {
      final before = assetItem('a1', page: 'p1', ordinal: 1024);
      final after = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      // A mirror that recorded the revision but not the payload. The rev
      // assert inside executeUndo passes — snapshot and plan agree on the
      // number — and the inverse then diffs to nothing, which is the state
      // that used to be reported as a successful restore with an audit row
      // and zero change rows beneath it.
      await seedItem(after, [remote], rev: 2);
      await seedItem(before, [local], rev: 2);
      await seedChange(remote, actionId: 'act-1', before: before, after: after);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);
      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);
      await tester.tap(find.byKey(kConfigUndoConfirmButtonKey));
      await settle(tester);

      expect(find.byKey(kConfigUndoBlockedKey), findsOneWidget);
      expect(find.text(kConfigHistoryUndoneNote), findsNothing,
          reason: 'nothing was written, so nothing may say it was');
      expect(sink.rows, isEmpty,
          reason: 'an audit_entry claiming a restore that did not happen is '
              'worse than the failed undo — the trail is the thing this '
              'milestone exists to make trustworthy');
      expect((await changeRows()), hasLength(1),
          reason: 'the log holds the original action and nothing else');
    });
  });

  group('a refusal names what moved, who moved it and when', () {
    testWidgets('a plan blocked before the dialog', (tester) async {
      final v1 = assetItem('a1', page: 'p1', ordinal: 1024);
      final v2 = assetItem('a1', page: 'p1', ordinal: 1024, colour: 'blue');
      await seedItem(v2, [local, remote]);
      await seedChange(remote, actionId: 'act-1', after: v1);
      await seedAuditHeader(remote, 'act-1');
      // Somebody else, afterwards.
      await seedChange(remote,
          actionId: 'act-2',
          before: v1,
          after: v2,
          who: 'ingibjorg',
          station: kOtherStation,
          at: kLaterAt);

      await pump(tester);
      await settle(tester);

      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);

      expect(find.byKey(kConfigUndoConfirmKey), findsNothing);
      expect(find.byKey(kConfigUndoBlockedKey), findsOneWidget);
      expect(find.byKey(kConfigUndoBlockedLeadKey), findsOneWidget);
      // The three facts, each asserted: without this the dialog could render an
      // empty list of blockers and still look right.
      expect(find.text('asset a1'), findsOneWidget);
      // On the author line itself, not merely somewhere on screen: the list
      // behind the dialog also names ingibjorg, and a finder that matched it
      // would pass with the dialog saying nothing at all.
      final author =
          tester.widget<Text>(find.byKey(kConfigUndoBlockedAuthorKey));
      expect(author.data, contains('ingibjorg'));
      expect(author.data, contains(dayOf(kLaterAt)));
      expect(find.byKey(kConfigUndoBlockedClauseKey), findsOneWidget);

      expect((await changeRows()), hasLength(2));
      expect(sink.rows, isEmpty,
          reason: 'nothing was attempted, so there is nothing to record');
    });

    testWidgets('a race lost after confirm surfaces the same refusal',
        (tester) async {
      final asset = assetItem('a1', page: 'p1', ordinal: 1024);
      // The action deleted it, so undoing it re-inserts it.
      await seedChange(remote, actionId: 'act-1', before: asset);
      await seedAuditHeader(remote, 'act-1');

      await pump(tester);
      await settle(tester);
      await tester.tap(find.byKey(configHistoryUndoKey('act-1')));
      await settle(tester);
      expect(find.byKey(kConfigUndoConfirmKey), findsOneWidget);

      // Another station re-creates the row while the dialog is open — and logs
      // it, as a real station would.
      await seedItem(asset, [remote]);
      await seedChange(remote,
          actionId: 'act-2',
          after: asset,
          who: 'ingibjorg',
          station: kOtherStation,
          at: kLaterAt);

      await tester.tap(find.byKey(kConfigUndoConfirmButtonKey));
      await settle(tester);

      // The same dialog, with the same three facts — not a stack trace and not
      // a driver error.
      expect(find.byKey(kConfigUndoBlockedKey), findsOneWidget);
      expect(find.text('asset a1'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(kConfigUndoBlockedAuthorKey)).data,
          contains('ingibjorg'));

      // And the row the other station wrote is untouched.
      expect((await itemRows()), hasLength(1));
      expect(
          (await changeRows()).map((r) => r.actionId), ['act-1', 'act-2'],
          reason: 'the undo rolled back, so it wrote no change row');
    });
  });

  group('the copy is a function of the step, not of the original edit', () {
    test('an insert inverts to a sentence saying Delete', () {
      final step = UndoStep(
        kind: ConfigKind.asset,
        entityId: '/roe/CN09',
        scope: ConfigScope.shared,
        originalOp: ConfigChangeOp.insert,
      );
      expect(configUndoStepSentence(step), 'Delete asset /roe/CN09');
      expect(configUndoStepIsDestructive(step), isTrue);
    });

    test('a delete inverts to Restore, naming the page and the order', () {
      final step = UndoStep(
        kind: ConfigKind.asset,
        entityId: '/baader/CN21',
        scope: ConfigScope.shared,
        originalOp: ConfigChangeOp.delete,
        item: assetItem('/baader/CN21', page: '/baader', ordinal: 2048),
      );
      expect(configUndoStepSentence(step),
          'Re-create asset /baader/CN21 on /baader, in its original order');
      expect(configUndoStepIsDestructive(step), isFalse,
          reason: 'undoing a delete writes a row; it does not remove one');
    });

    test('a page has no parent and no order, and the sentence has neither', () {
      final step = UndoStep(
        kind: ConfigKind.page,
        entityId: '/roe',
        scope: ConfigScope.shared,
        originalOp: ConfigChangeOp.delete,
        item: ConfigItem.of(
            kind: ConfigKind.page, id: '/roe', value: const {'menu_item': {}}),
      );
      expect(configUndoStepSentence(step), 'Re-create page /roe');
    });

    test('the three verbs name three different states of the row', () {
      // The complaint this replaced: `Restore` and `Put back as it was` were
      // two phrasings of one idea, and a reader could not tell which line
      // meant the row was absent. Each verb now says what is there now.
      String sentenceFor(ConfigChangeOp originalOp, {ConfigItem? item}) =>
          configUndoStepSentence(UndoStep(
            kind: ConfigKind.asset,
            entityId: 'a1',
            scope: ConfigScope.shared,
            originalOp: originalOp,
            item: item,
          ));

      final verbs = <String>{
        sentenceFor(ConfigChangeOp.insert).split(' ').first,
        sentenceFor(ConfigChangeOp.delete,
            item: assetItem('a1', page: 'p1')).split(' ').first,
        sentenceFor(ConfigChangeOp.update,
            item: assetItem('a1', page: 'p1')).split(' ').first,
      };
      expect(verbs, hasLength(3),
          reason: 'one verb per operation, and the operation is what varies');
      expect(verbs, {'Delete', 'Re-create', 'Revert'});
    });

    test('no author is no line, rather than an invented one', () {
      const blocker = UndoBlocker(
        reason: UndoBlockReason.entityMoved,
        kindName: 'asset',
        entityId: 'a1',
        scopeName: 'shared',
        summary: 'whatever',
      );
      expect(configUndoBlockerAuthorLine(blocker), isNull);
      expect(configUndoBlockerClause(blocker), contains('does not say who'));
    });
  });
}
