/// The page editor's Save, end to end: what reaches the rows, and what the
/// operator is told when nothing does.
///
/// The editor is the only place a person edits the plant's mimic, so this is
/// where SC-1 has to be true through the app rather than at the store: one
/// asset nudged is **one** `config_item` update, **one** `config_change` row
/// naming that asset under its page, and **one** `audit_entry` under
/// `page_editor_data` — not a 145 kB before-and-after image of the whole
/// layout out of which nobody can tell what moved.
///
/// The three refusal arms are here for C-11: a green snackbar over a write
/// that reached nothing is the failure the whole write path was rebuilt to
/// end, and the editor advancing `_savedJson` over it is how the operator's
/// work disappears silently.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/config/page_codec.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessGroup, AccessSession, AuditRecord, AuditSink;
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'package:tfc/widgets/leave_guard.dart';

import '../helpers/page_editor_harness.dart';
import '../helpers/test_helpers.dart'
    show createTestConfigStore, kConfiguringTestSession;

/// A lamp with a name an operator would recognise, which is what the conflict
/// message has to reach for — `ConfigConflict.key` is a 24-hex row id.
LEDConfig editorLed(String text, double x, double y) => LEDConfig(key: 'CN04.Run')
  ..text = text
  ..coordinates = Coordinates(x: x, y: y)
  ..size = const RelativeSize(width: 0.06, height: 0.06);

/// Selects the asset at ([fx], [fy]) and nudges it one canvas pixel — the
/// smallest real edit, and exact, so the diff has exactly one cause.
Future<void> nudgeAsset(WidgetTester tester, double fx, double fy) async {
  await tapAsset(tester, fx, fy);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
  await tester.pumpAndSettle();
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// The editor over a store this test can look behind.
///
/// [withRemote] false is the station that booted with Postgres unreachable —
/// the only way to reach the offline arm.
Future<
    ({
      PageManager manager,
      GuardedConfigStore store,
      _RecordingSink audit,
      AppDatabase? remote,
      FakeEditorPreferences prefs,
    })> _editorOver(
  WidgetTester tester,
  List<Asset> assets, {
  bool withRemote = true,
  AccessSession? session,
  String? pageId,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final audit = _RecordingSink();
  AppDatabase? remote;
  final store = await createTestConfigStore(
    session: session ?? kConfiguringTestSession,
    audit: audit,
    withRemote: withRemote,
    onRemote: (db) => remote = db,
  );
  final prefs = FakeEditorPreferences()..configStore = store.inner;
  final manager = PageManager(
    prefs: prefs,
    store: store.inner,
    pages: {
      '/': AssetPage(
        menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
        assets: assets,
        mirroringDisabled: true,
        navigationPriority: 0,
        id: pageId,
      ),
    },
    writeItems: (wanted, {reason}) => store.write(
      wanted,
      kinds: const {ConfigKind.page, ConfigKind.asset},
      checkKind: ConfigKind.page,
      reason: reason,
    ),
  );
  await tester.pumpWidget(buildEditorUnderTest(manager));
  await tester.pumpAndSettle();
  return (
    manager: manager,
    store: store,
    audit: audit,
    remote: remote,
    prefs: prefs
  );
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.save));
  await tester.pumpAndSettle();
}

void main() {
  setUp(setUpEditorEnvironment);

  group('the save reaches the rows', () {
    testWidgets('a nudged asset is one row, one change row, one audit row',
        (tester) async {
      final w = await _editorOver(tester, [
        editorLed('CN04.Run', 0.2, 0.2),
        editorLed('CN05.Run', 0.6, 0.2),
        editorLed('CN06.Run', 0.6, 0.6),
      ]);
      // The layout as it stands, so the nudge below is the only edit in the
      // diff rather than the first save's worth of inserts.
      await _save(tester);
      final seeded = {
        for (final item in w.store.inner.itemsOf(const {ConfigKind.asset}))
          item.id: item.rev,
      };
      expect(seeded, hasLength(3));
      w.audit.rows.clear();
      final changesBefore =
          (await w.remote!.select(w.remote!.configChangeTable).get()).length;

      await nudgeAsset(tester, 0.2, 0.2);
      await _save(tester);

      final after = {
        for (final item in w.store.inner.itemsOf(const {ConfigKind.asset}))
          item.id: item.rev,
      };
      expect(after.keys.toSet(), seeded.keys.toSet(),
          reason: 'a move is not a new identity — every id survives');
      final moved = [
        for (final entry in after.entries)
          if (seeded[entry.key] != entry.value) entry.key,
      ];
      expect(moved, hasLength(1), reason: 'SC-1: one asset moved, one row');

      final changes =
          (await w.remote!.select(w.remote!.configChangeTable).get())
              .skip(changesBefore)
              .toList();
      expect(changes, hasLength(1));
      expect(changes.single.entityId, moved.single);
      expect(changes.single.kind, ConfigKind.asset.wireName);
      final page = w.store.inner.itemsOf(const {ConfigKind.page}).single;
      expect(
          w.store.inner
              .itemsOf(const {ConfigKind.asset})
              .firstWhere((item) => item.id == moved.single)
              .parentId,
          page.id,
          reason: 'the change names the asset, and the asset names its page');

      expect(w.audit.rows, hasLength(1));
      expect(w.audit.rows.single.itemKey, 'page_editor_data',
          reason: '02-05 C-8: a new surface or a per-entity item key falls '
              'closed to administer and locks the operators out');
    });

    testWidgets('a page another station added while the editor was open '
        'survives the save', (tester) async {
      // The editor hands over the layout it was shown. Before the merge, a
      // page added behind it was deleted on the next Ctrl+S — cleanly, the
      // compare-and-swap matching because the snapshot had reconciled it.
      final w = await _editorOver(tester, [
        editorLed('CN04.Run', 0.2, 0.2),
        editorLed('CN05.Run', 0.6, 0.2),
      ]);
      await _save(tester);

      // Another station's page, written straight into the store behind the
      // editor: the full page/asset set plus one page, as a save would.
      final stored =
          w.store.inner.itemsOf(const {ConfigKind.page, ConfigKind.asset});
      await w.store.inner.writeItems(
        kinds: const {ConfigKind.page, ConfigKind.asset},
        wanted: [
          ...stored,
          ConfigItem.of(
            kind: ConfigKind.page,
            id: 'p-other-station',
            value: {
              'id': 'p-other-station',
              'menu_item': {'label': 'Roe', 'path': '/roe', 'icon': 'home'},
              'mirroring_disabled': false,
            },
          ),
        ],
        actionId: 'other-station',
        who: 'olafur',
        roleName: 'engineer',
      );

      await nudgeAsset(tester, 0.2, 0.2);
      await _save(tester);

      final pages = w.store.inner.itemsOf(const {ConfigKind.page});
      expect(pages.map((p) => p.id), contains('p-other-station'),
          reason: 'a page this editor never saw is not this editor\'s to '
              'delete');
      expect(pages, hasLength(2));
    });

    testWidgets('an asset added in the editor keeps its row across saves',
        (tester) async {
      // With the page already carrying an id, the rollout-day adoption does
      // not run, so the ids a save mints have to come back onto the editor's
      // own pages — or every save deletes the row the last one inserted.
      final w = await _editorOver(
        tester,
        [editorLed('CN04.Run', 0.2, 0.2), editorLed('CN05.Run', 0.6, 0.2)],
        pageId: 'p-home',
      );
      await _save(tester);
      final first = w.store.inner
          .itemsOf(const {ConfigKind.asset})
          .map((i) => i.id)
          .toSet();
      expect(first, hasLength(2));

      await nudgeAsset(tester, 0.2, 0.2);
      await _save(tester);

      final second = w.store.inner
          .itemsOf(const {ConfigKind.asset})
          .map((i) => i.id)
          .toSet();
      expect(second, first,
          reason: 'the same two rows, not two deletes and two inserts');
    });

    testWidgets('the page blob is never written beside the rows',
        (tester) async {
      final w = await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)]);
      await _save(tester);

      expect(await w.prefs.getString(PageManager.storageKey), isNull);
      expect(w.store.inner.itemsOf(const {ConfigKind.page}), hasLength(1));
    });
  });

  group('what the operator is told when the save does not land', () {
    testWidgets('offline names the work that was not written, and no green',
        (tester) async {
      final w = await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)],
          withRemote: false);

      await _save(tester);

      expect(find.textContaining('the database is unreachable'), findsOneWidget);
      expect(find.textContaining('Nothing was written'), findsOneWidget);
      expect(find.textContaining('saved successfully'), findsNothing);
      expect(w.store.inner.itemsOf(const {ConfigKind.page}), isEmpty);
    });

    testWidgets('a conflict names the asset and its page, and offers Reload',
        (tester) async {
      final w = await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)]);
      await _save(tester);
      final asset = w.store.inner.itemsOf(const {ConfigKind.asset}).single;

      // Another station's edit, made behind this station's back: the row is at
      // a higher rev than the snapshot this editor is holding.
      await w.remote!.customStatement(
        'UPDATE config_item SET rev = rev + 1 WHERE id = ?',
        [asset.id],
      );

      await nudgeAsset(tester, 0.2, 0.2);
      await _save(tester);

      expect(find.textContaining('was changed on another station'),
          findsOneWidget);
      expect(find.textContaining('"CN04.Run" on the page "Home"'), findsOneWidget,
          reason: 'a 24-hex row id means nothing at a panel — the message '
              'names what is on screen');
      expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);
      expect(find.textContaining('saved successfully'), findsNothing);
    });

    testWidgets('a failed save leaves the editor dirty, work still on screen',
        (tester) async {
      // The other half of C-11, and the one that costs the operator their
      // afternoon: if `_savedJson` advanced over a write that reached nothing,
      // the editor would go quiet, the leave guard would let them walk away,
      // and the edit would be gone with no message anywhere.
      await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)],
          withRemote: false);
      await nudgeAsset(tester, 0.2, 0.2);

      await _save(tester);

      final may = LeaveGuard.mayLeave();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget,
          reason: 'the guard asked, so the editor still knows it is dirty');
      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();
      expect(await may, isFalse);
    });

    testWidgets('Reload takes the other station\'s layout and goes clean',
        (tester) async {
      final w = await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)]);
      await _save(tester);

      // Another station adds a page and a lamp, through the same store.
      final theirs = pagesOf(
          w.store.inner.itemsOf(const {ConfigKind.page, ConfigKind.asset}));
      theirs['/roe'] = AssetPage(
        menuItem: const MenuItem(label: 'Roe', path: '/roe', icon: Icons.egg),
        assets: [editorLed('CN09.Fault', 0.5, 0.5)],
        mirroringDisabled: true,
        navigationPriority: 1,
      );
      await w.store.inner.writeItems(
        kinds: const {ConfigKind.page, ConfigKind.asset},
        wanted: pageItems(theirs),
        actionId: 'other-station',
        who: 'other',
        roleName: 'configure',
      );
      // And one more edit this station never saw: a second station's write
      // between this station's snapshot and its save is what a conflict IS,
      // and one store serving both cannot produce it any other way.
      await w.remote!.customStatement(
        'UPDATE config_item SET rev = rev + 1 WHERE kind = ?',
        [ConfigKind.asset.wireName],
      );

      // This operator has an unsaved nudge, and saves into the conflict.
      await nudgeAsset(tester, 0.2, 0.2);
      await _save(tester);
      expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);

      await tester.tap(find.widgetWithText(SnackBarAction, 'Reload'));
      await tester.pumpAndSettle();

      final may = LeaveGuard.mayLeave();
      await tester.pumpAndSettle();
      expect(await may, isTrue,
          reason: 'Reload discards this session\'s edits, so there is nothing '
              'left to warn about');
      expect(find.text('Unsaved changes'), findsNothing);
    });

    testWidgets('a denial is reported and nothing is written', (tester) async {
      final w = await _editorOver(tester, [editorLed('CN04.Run', 0.2, 0.2)],
          session: AccessSession.anonymous(const {AccessGroup.operate}));

      await _save(tester);

      expect(find.textContaining('Failed to save the pages'), findsOneWidget);
      expect(w.store.inner.itemsOf(const {ConfigKind.page}), isEmpty);
    });
  });
}
