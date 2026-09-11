// The history page's delete controls, from the operator's side.
//
// `history_view_controls_test.dart` is a layout reproduction — it deliberately
// does not build `HistoryViewPage`, because the page needs a live StateMan.
// This file stands the page up against fakes instead, because the properties
// this plan is about are only visible on the real widget: that the delete
// buttons stay **enabled** for an anonymous session, that confirming a delete
// as one produces the shared locked prompt rather than a dead control or an
// error toast, and that the view is still there afterwards.
//
// The page's route is not gated and must not become gated — see
// `guarded_history_views_test.dart` for that assertion. What is asserted here
// is the other half: the page opens for anybody, and the two destructive
// controls on it ask first.

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/history_view.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart' show InMemoryPreferences;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

/// The saved view every test starts with.
const int _viewId = 42;
const String _viewName = 'Freezer overnight';

/// The saved period every period test starts with.
const int _periodId = 91;
const String _periodName = 'Night shift';

/// Answers the page's reads and records the two writes it must refuse.
class _RecordingDb extends Fake implements AppDatabase {
  /// Every history-view write the page reached, in order. Empty is the
  /// assertion that matters: a refused delete must never arrive here.
  final List<String> writes = [];

  bool viewDeleted = false;
  bool periodDeleted = false;

  // -- reads ---------------------------------------------------------------

  @override
  Future<List<HistoryViewData>> selectHistoryViews() async => [
        if (!viewDeleted)
          HistoryViewData(
            id: _viewId,
            name: _viewName,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
      ];

  @override
  Future<List<String>> getHistoryViewKeyNames(int viewId) async => ['a.b'];

  @override
  Future<Map<String, Map<String, dynamic>>> getHistoryViewKeys(
          int viewId) async =>
      {};

  @override
  Future<Map<int, Map<String, dynamic>>> getHistoryViewGraphs(
          int viewId) async =>
      {};

  @override
  Future<List<HistoryViewPeriodData>> listHistoryViewPeriods(
          int viewId) async =>
      [
        if (!periodDeleted)
          HistoryViewPeriodData(
            id: _periodId,
            viewId: _viewId,
            name: _periodName,
            startAt: DateTime.now().subtract(const Duration(hours: 8)),
            endAt: DateTime.now(),
            createdAt: DateTime.utc(2026),
          ),
      ];

  @override
  Future<DateTime?> getGlobalRetentionHorizon() async => null;

  // -- writes --------------------------------------------------------------

  @override
  Future<void> deleteHistoryView(int id) async {
    writes.add('deleteHistoryView($id)');
    viewDeleted = true;
  }

  @override
  Future<void> deleteHistoryViewPeriod(int id) async {
    writes.add('deleteHistoryViewPeriod($id)');
    periodDeleted = true;
  }
}

class _FakeDatabase extends Fake implements Database {
  _FakeDatabase(this.db);

  @override
  final AppDatabase db;

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      <TimeseriesData<dynamic>>[];
}

class _FakeStateMan extends Fake implements StateMan {
  @override
  List<String> get keys => const ['a.b'];

  @override
  KeyMappings get keyMappings => KeyMappings(nodes: {});

  @override
  String resolveKey(String key) => key;
}

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A session that never changes, the `access_lock_badge_test.dart` idiom.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;
}

AccessSession _anonymous() => AccessSession.anonymous(
      {...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups},
    );

AccessSession _withConfigure() => AccessSession(
      user: const AuthenticatedUser(username: 'jon', roleName: 'Engineer'),
      groups: const {AccessGroup.operate, AccessGroup.configure},
    );

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// `BaseScaffold` renders a `NavigationBar`, which asserts on fewer than two
/// destinations. Two top-level entries plus the Advanced parent is the app's
/// own shape and the smallest one that builds.
void _registerAppMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(const MenuItem(
      label: 'Alarm View', path: '/alarm-view', icon: Icons.alarm));
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: 'History',
          path: '/advanced/history-view',
          icon: Icons.timeline),
    ],
  ));
}

Widget _shell({
  required _RecordingDb db,
  required AccessSession session,
  required _RecordingSink audit,
}) {
  final delegate = BeamerDelegate(
    initialPath: '/advanced/history-view',
    locationBuilder: RoutesLocationBuilder(routes: {
      '/advanced/history-view': (context, state, data) => const BeamPage(
            key: ValueKey('/advanced/history-view'),
            title: 'History',
            child: HistoryViewPage(),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [
      databaseProvider.overrideWith((ref) async => _FakeDatabase(db)),
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),  // the transport row; empty == direct mode
      stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      auditSinkProvider.overrideWith((ref) async => audit),
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// A control found by its tooltip, so the finder does not depend on the page's
/// layout.
Finder _buttonWithTooltip(String tooltip) =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

/// Selects the saved view in the dropdown, which is what makes both delete
/// controls appear.
Future<void> _selectSavedView(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButton<int>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_viewName).last);
  await tester.pumpAndSettle();
}

/// Switches to Historical and selects the saved period, which is the flow an
/// operator takes to look at a bookmarked range — and the only one that makes
/// the delete-period control appear. The periods section renders only when the
/// page is out of realtime (`history_view.dart:891-895`).
Future<void> _selectSavedPeriod(WidgetTester tester) async {
  await tester.tap(find.text('Historical'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButton<SavedPeriod?>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_periodName).last);
  await tester.pumpAndSettle();
}

Future<void> _confirmYes(WidgetTester tester) async {
  await tester.tap(find.text('Yes'));
  await tester.pumpAndSettle();
}

void main() {
  late _RecordingDb db;
  late _RecordingSink audit;

  setUp(() {
    _registerAppMenu();
    db = _RecordingDb();
    audit = _RecordingSink();
  });

  tearDown(() => RouteRegistry().menuItems.clear());

  group('the page stays open, and the controls stay alive', () {
    testWidgets('the page renders for an anonymous session with no elevation',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();

      expect(find.byType(HistoryViewPage), findsOneWidget);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing,
          reason: 'merely opening the page denies nothing');
    });

    testWidgets('the delete-view button is enabled for an anonymous session',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      final button =
          tester.widget<IconButton>(_buttonWithTooltip('Delete view'));
      expect(button.onPressed, isNotNull,
          reason: 'a locked control is tappable and explains itself; '
              'a greyed one tells the operator the app is broken');
    });

    testWidgets('the delete-period button is enabled for an anonymous session',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);
      await _selectSavedPeriod(tester);

      final button = tester
          .widget<IconButton>(_buttonWithTooltip('Delete selected period'));
      expect(button.onPressed, isNotNull);
    });
  });

  group('a refused delete', () {
    testWidgets(
        'shows the locked prompt and leaves the saved view in place',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      await tester.tap(_buttonWithTooltip('Delete view'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget,
          reason: 'the shared prompt, not a dead control');
      expect(db.writes, isEmpty,
          reason: 'the Drift delete must never be reached');
      expect(db.viewDeleted, isFalse);
    });

    testWidgets('does not raise the page\'s own toast', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      await tester.tap(_buttonWithTooltip('Delete view'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(find.byType(SnackBar), findsNothing,
          reason: '_toast is for outcomes, and a refusal is not one; a second '
              'message would be two prompts for one action');
      expect(find.text('Deleted'), findsNothing);
    });

    testWidgets('leaves the active view selected — the page must not clear '
        'its selection for a delete that did not happen', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      await tester.tap(_buttonWithTooltip('Delete view'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);
      await tester.tap(find.byKey(kAccessDeniedDismissKey));
      await tester.pumpAndSettle();

      // The delete button only renders while `_activeView != null`, so its
      // presence is the observable form of "_activeView survived".
      expect(_buttonWithTooltip('Delete view'), findsOneWidget);
      expect(find.text(_viewName), findsWidgets);
    });

    testWidgets('refuses the period delete too — the second accessor was the '
        'one first discovery missed', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);
      await _selectSavedPeriod(tester);

      await tester.tap(_buttonWithTooltip('Delete selected period'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(find.byKey(kAccessDeniedBodyKey), findsOneWidget);
      expect(db.writes, isEmpty);
      expect(db.periodDeleted, isFalse);
      expect(audit.rows.single.itemKey, 'history_view_period.$_periodId');
      expect(audit.rows.single.allowed, isFalse);
    });

    testWidgets('leaves the selected period in place', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);
      await _selectSavedPeriod(tester);

      await tester.tap(_buttonWithTooltip('Delete selected period'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);
      await tester.tap(find.byKey(kAccessDeniedDismissKey));
      await tester.pumpAndSettle();

      // The control only renders while `_activePeriod != null`.
      expect(_buttonWithTooltip('Delete selected period'), findsOneWidget);
    });

    testWidgets('is recorded, with allowed false', (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _anonymous(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      await tester.tap(_buttonWithTooltip('Delete view'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(audit.rows, hasLength(1));
      expect(audit.rows.single.allowed, isFalse);
      expect(audit.rows.single.itemKey, 'history_view.$_viewId');
      expect(audit.rows.single.groupRequired, 'configure');
    });
  });

  group('a permitted delete', () {
    testWidgets('a session holding configure deletes the view as before',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _withConfigure(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);

      await tester.tap(_buttonWithTooltip('Delete view'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(db.writes, ['deleteHistoryView($_viewId)']);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
      expect(audit.rows.single.allowed, isTrue);
    });

    testWidgets('a session holding configure deletes the period as before',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          _shell(db: db, session: _withConfigure(), audit: audit));
      await tester.pumpAndSettle();
      await _selectSavedView(tester);
      await _selectSavedPeriod(tester);

      await tester.tap(_buttonWithTooltip('Delete selected period'));
      await tester.pumpAndSettle();
      await _confirmYes(tester);

      expect(db.writes, ['deleteHistoryViewPeriod($_periodId)']);
      expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
      expect(audit.rows.single.allowed, isTrue);
    });
  });
}
