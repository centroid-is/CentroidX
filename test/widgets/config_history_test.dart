/// The configuration history page: actions, entities, fields, and the four
/// things an absence can mean.
///
/// The seam is `configChangeStoreProvider` and `auditTrailStoreProvider`, not
/// `configHistoryActionsProvider`: Riverpod 2's generated family carries no
/// family-level `overrideWith`, and overriding by resolved query would mean
/// this file had to reconstruct the query the page issues. Overriding the
/// stores is also stronger — the real provider runs, so the grouping, the
/// header join and the hidden-count arithmetic under test are the production
/// ones.
library;

import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/access_routes.dart';
import 'package:tfc/core/audit_trail_store.dart';
import 'package:tfc/core/config_change_store.dart';
import 'package:tfc/pages/config_history.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/providers/config_history.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/config_change_row.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'config_history_fixture.dart';

/// A store that answers the fixture verbatim.
///
/// `extends Fake` rather than a real [ConfigChangeStore]: the real one needs an
/// `AppDatabase`, and a widget test that stands up Drift to draw five rows is a
/// test of two things at once. The fixture is written as *what the `WHERE`
/// clause returned* — every filter this page has is pushed into SQL, so a fake
/// that re-filtered in Dart would model a code path the page does not have.
class _FakeChangeStore extends Fake implements ConfigChangeStore {
  _FakeChangeStore({
    this.rows = const <ConfigChangeRecord>[],
    this.totals = const <String, int>{},
  });

  final List<ConfigChangeRecord> rows;

  /// What `changeCountsByAction` answers. Empty means every action's true row
  /// count equals its visible one, so nothing is partial.
  final Map<String, int> totals;

  @override
  Future<List<ConfigChangeRecord>> changes(ConfigChangeQuery query) async =>
      rows;

  /// What the provider reads: the same rows, with the raw count and the
  /// cursor the page derives the cap and Load-more from.
  @override
  Future<ConfigChangePage> changesPage(ConfigChangeQuery query) async =>
      ConfigChangePage(
        rows: rows,
        rawCount: rows.length,
        oldestAt: rows.isEmpty ? null : rows.last.change.at,
        oldestId: rows.isEmpty ? null : rows.last.id,
      );

  @override
  Future<Map<String, int>> changeCountsByAction(
      Iterable<String> actionIds) async {
    if (totals.isNotEmpty) return totals;
    final ids = actionIds.toList();
    return {
      for (final id in ids)
        id: rows.where((row) => row.change.actionId == id).length,
    };
  }
}

/// The header side of the same read.
class _FakeAuditStore extends Fake implements AuditTrailStore {
  _FakeAuditStore({this.headers = const <AuditEntryData>[]});

  final List<AuditEntryData> headers;

  @override
  Future<List<AuditEntryData>> entriesByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toSet();
    return headers.where((row) => ids.contains(row.actionId)).toList();
  }

  @override
  Future<Map<String, int>> memberCountsByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toList();
    return {
      for (final id in ids)
        id: headers.where((row) => row.actionId == id).length,
    };
  }
}

/// [ConfigHistoryBody] over the two stores. A **null** change store is the
/// station with no reachable database.
Widget _host({
  required ConfigChangeStore? changeStore,
  AuditTrailStore? auditStore,
}) {
  final (light, _) = muted();
  return ProviderScope(
    overrides: <Override>[
      configChangeStoreProvider.overrideWith((ref) async => changeStore),
      auditTrailStoreProvider.overrideWith((ref) async => auditStore),
    ],
    child: MaterialApp(
      theme: light,
      home: const Scaffold(body: ConfigHistoryBody()),
    ),
  );
}

/// Bounded settle — the search box holds a focus-capable `TextField`, and a
/// blinking caret schedules a frame forever, so `pumpAndSettle` would time out
/// rather than return.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget _populatedHost() => _host(
      changeStore: _FakeChangeStore(rows: configGoldenPopulatedChanges()),
      auditStore: _FakeAuditStore(headers: configGoldenPopulatedHeaders()),
    );

void main() {
  group('the route gate', () {
    test('the history is its own entry at configure', () {
      expect(kRaisedRoutes[kConfigHistoryRoute], AccessGroup.configure);
    });

    test('the audit trail keeps its own, stricter gate', () {
      // The failure this exists to catch is not a wrong value here — it is
      // somebody reaching this page by loosening the entry next door, which
      // would hand every write anybody ever made to anyone who can edit a page.
      expect(kRaisedRoutes[kAuditTrailRoute], AccessGroup.users);
      expect(kConfigHistoryRoute, isNot(kAuditTrailRoute));
    });

    test('the page names no permission of its own', () {
      // A second, weaker check on the page could disagree with the route gate,
      // and the disagreement would be an open page. Comments stripped first, so
      // the paragraphs explaining the ruling do not trip their own test.
      final source = File('lib/pages/config_history.dart').readAsStringSync();
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('///'))
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, isNot(contains('AccessGate')));
      expect(code, isNot(contains('AccessLockedBody')));
      expect(code, isNot(contains('AccessGroup')));
    });

    test('nothing on this page moves on its own', () {
      final source = File('lib/pages/config_history.dart').readAsStringSync();
      final code = source
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('///'))
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, isNot(contains('Timer')));
      expect(code, isNot(contains('ScrollController')));
      expect(code, isNot(contains('addPostFrameCallback')));
    });
  });

  group('actions, not rows', () {
    testWidgets('one save is one line naming what it changed', (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      expect(find.byKey(kConfigHistoryListKey), findsOneWidget);
      // Two actions from five rows: the ordinary save and the orphan.
      expect(find.byType(ConfigActionTile), findsNWidgets(2));
      expect(find.text('jon changed 3 assets'), findsOneWidget);
      expect(find.text('kari changed 2 key mappings'), findsOneWidget);
    });

    testWidgets('the save expands to its three entities', (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      // Shut on arrival: a complete action has nothing the reader needs told.
      expect(find.byType(ConfigChangeTile), findsNWidgets(2),
          reason: 'only the orphan, which arrives open, has entities on screen');

      await tester.tap(find.text('jon changed 3 assets'));
      await _settle(tester);

      expect(find.text('asset:/roe/CN04'), findsOneWidget);
      expect(find.text('asset:/roe/CN05'), findsOneWidget);
      expect(find.text('asset:/roe/CN06'), findsOneWidget);
    });

    testWidgets('an entity expands to the fields that actually moved',
        (tester) async {
      await tester.pumpWidget(_host(
        changeStore: _FakeChangeStore(rows: configGoldenFieldDiffChanges()),
        auditStore: _FakeAuditStore(headers: configGoldenFieldDiffHeaders()),
      ));
      await _settle(tester);

      await tester.tap(find.text('jon changed 2 assets'));
      await _settle(tester);
      await tester.tap(find.text('asset:/baader/CN21'));
      await _settle(tester);

      // A move is three rows, and two of them are outside the payload: the
      // entity encoding carries position, which is why a history of payloads
      // alone would show two identical sides for a move.
      expect(find.text('payload.coordinates.x'), findsOneWidget);
      expect(find.text('parent_id'), findsOneWidget);
      expect(find.text('sort_index'), findsOneWidget);
      expect(find.text('0.31 → 0.42'), findsOneWidget);
      expect(find.text('/roe → /baader'), findsOneWidget);
    });

    testWidgets('an insert and a delete render asymmetrically', (tester) async {
      await tester.pumpWidget(_host(
        changeStore: _FakeChangeStore(rows: configGoldenInsertDeleteChanges()),
        auditStore: _FakeAuditStore(headers: configGoldenInsertDeleteHeaders()),
      ));
      await _settle(tester);

      await tester.tap(find.text('jon changed 2 assets'));
      await _settle(tester);
      await tester.tap(find.text('asset:/roe/CN07'));
      await _settle(tester);
      await tester.tap(find.text('asset:/roe/CN03'));
      await _settle(tester);

      // One whole-entity row each, labelled for which side is missing — and no
      // em dash opposite either, which would read as a value that had been
      // there.
      expect(find.text(kConfigEntityAddedLabel), findsOneWidget);
      expect(find.text(kConfigEntityRemovedLabel), findsOneWidget);
      final fieldRows = tester
          .widgetList<ConfigFieldRow>(find.byType(ConfigFieldRow))
          .toList();
      expect(fieldRows, hasLength(2));
      for (final row in fieldRows) {
        expect(row.value, isNot(contains('→')),
            reason: 'a transition needs two sides; an em dash opposite the one '
                'side there is reads as a value that used to be there');
      }
      expect(find.text('added'), findsOneWidget);
      expect(find.text('removed'), findsOneWidget);
    });
  });

  group('what the view cannot show', () {
    testWidgets('the shared-only banner is on screen with a full list',
        (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      expect(find.byKey(kConfigHistoryListKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsOneWidget);
      expect(find.text(kConfigHistoryScopeNote), findsOneWidget);
    });

    testWidgets('the banner is on the empty screen too', (tester) async {
      await tester.pumpWidget(_host(changeStore: _FakeChangeStore()));
      await _settle(tester);

      // The state where the sentence matters most: an operator who filtered for
      // a local preference change gets an empty list, and the reason it is
      // empty is on screen beside it.
      expect(find.byKey(kConfigHistoryEmptyKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsOneWidget);
    });

    testWidgets('the kinds that keep no history say so, and cannot be filtered',
        (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      expect(find.byKey(kConfigHistorySilentNoteKey), findsOneWidget);
      expect(configHistorySilentNote(), contains('Page images'));
      expect(configHistorySilentNote(), contains('encrypted server settings'));

      // Disabled, not absent. Selecting it could only ever return nothing, and
      // an operator who filtered to page images and saw an empty list would
      // read it as "no page image ever changed".
      final chip = tester.widget<FilterChip>(
        find.byKey(configHistoryKindChipKey(ConfigKind.pageImage)),
      );
      expect(chip.onSelected, isNull);
      expect(chip.selected, isFalse);

      final asset = tester.widget<FilterChip>(
        find.byKey(configHistoryKindChipKey(ConfigKind.asset)),
      );
      expect(asset.onSelected, isNotNull);
      expect(asset.selected, isTrue,
          reason: 'an empty kinds list is no constraint, so every chip is on');
    });
  });

  group('the orphan', () {
    testWidgets('renders flagged and open, not dropped', (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      // Found in the ordinary way, because the view is driven by the change
      // rows. An audit-first query would never have asked about this action.
      expect(find.text('kari changed 2 key mappings'), findsOneWidget);
      expect(find.byKey(kConfigParentlessKey), findsOneWidget);
      expect(find.byKey(kConfigParentlessNoteKey), findsOneWidget);
      // Open on arrival: its rows are the only record of what happened.
      expect(find.text('key_mapping:ST101.CN04.p_par_SpeedRef'), findsOneWidget);
    });

    testWidgets('the ordinary action carries no flag', (tester) async {
      await tester.pumpWidget(_populatedHost());
      await _settle(tester);

      // One flag on the page, not two: a fixture that flagged everything would
      // make the assertion above pass for the wrong reason.
      expect(find.byKey(kConfigParentlessKey), findsOneWidget);
      expect(find.text(kConfigParentlessNote), findsOneWidget);
    });
  });

  group('empty and unavailable are two screens', () {
    testWidgets('the query ran and matched nothing', (tester) async {
      await tester.pumpWidget(_host(changeStore: _FakeChangeStore()));
      await _settle(tester);

      expect(find.byKey(kConfigHistoryEmptyKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryUnavailableKey), findsNothing);
      expect(find.byKey(kConfigHistoryListKey), findsNothing);
      expect(find.text(kConfigHistoryEmptyUnderFilters), findsOneWidget);
      // The controls stay on screen precisely so the operator can undo what
      // excluded everything.
      expect(find.byKey(kConfigHistoryFilterBarKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyClearFiltersKey), findsOneWidget);
    });

    testWidgets('there is no database', (tester) async {
      await tester.pumpWidget(_host(changeStore: null));
      await _settle(tester);

      expect(find.byKey(kConfigHistoryUnavailableKey), findsOneWidget);
      expect(find.byKey(kConfigHistoryEmptyKey), findsNothing);
      expect(find.byKey(kConfigHistoryListKey), findsNothing);
      expect(find.text(kConfigHistoryUnavailable), findsOneWidget);
      // No controls over an unreachable database, and no banner describing a
      // view that is showing nothing — which is also what stops this screen
      // looking like the empty one.
      expect(find.byKey(kConfigHistoryFilterBarKey), findsNothing);
      expect(find.byKey(kConfigHistoryScopeBannerKey), findsNothing);
    });

    testWidgets('the two say different things', (tester) async {
      // The one assertion that fails if the copy is ever unified.
      expect(kConfigHistoryUnavailable, isNot(kConfigHistoryEmptyUnderFilters));
      expect(kConfigHistoryUnavailable, contains('not reachable'));
      expect(kConfigHistoryEmptyUnderFilters, contains('filters'));
    });
  });

  group('a value no row should be able to break the page with', () {
    testWidgets('a huge stored value renders capped and one line high',
        (tester) async {
      final huge = 'x' * 20000;
      await tester.pumpWidget(_host(
        changeStore: _FakeChangeStore(rows: [
          configGoldenChange(
            id: 1,
            entityId: '/roe/CN04',
            oldValue: configGoldenEntity(payload: {'label': 'CN04'}),
            newValue: configGoldenEntity(payload: {'label': huge}),
          ),
        ]),
        auditStore: _FakeAuditStore(headers: configGoldenPopulatedHeaders()),
      ));
      await _settle(tester);

      await tester.tap(find.text('jon changed 1 asset'));
      await _settle(tester);
      await tester.tap(find.text('asset:/roe/CN04'));
      await _settle(tester);

      final row = tester.widget<ConfigFieldRow>(find.byType(ConfigFieldRow));
      // 04-02's 256-character cap, arriving through `renderJsonValue`. The
      // widget adds no cap of its own — one that disagreed with the diff's
      // would be a second rule to keep in step.
      expect(row.value.length, lessThan(600));
      expect(tester.takeException(), isNull);
    });
  });
}
