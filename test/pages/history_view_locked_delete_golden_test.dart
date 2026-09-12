/// One golden: the history view, open to a session holding nothing, with the
/// delete control **visible and enabled**.
///
/// `history_view_delete_stays_live.png` — the requirement "no control is ever
/// greyed and inert" made visible rather than only asserted. Plan 03-10 gated
/// the two deletes on `configure` at the *store*, not at the widget: the
/// button stays live for an anonymous session, and pressing through the
/// confirmation produces the shared locked prompt. A greyed-out delete would
/// be the failure this milestone forbids outright, and it is a failure an
/// assertion can miss and an eye cannot.
///
/// **The route is not gated and must not become gated.** Reading history is
/// operate-level work; `guarded_history_views_test.dart` asserts
/// `/advanced/history-view` is absent from `kRaisedRoutes`. This image is the
/// other half of that claim — the page opens for anybody.
///
/// **Fonts are loaded here, twice.** `test/pages/` has no
/// `flutter_test_config.dart` of its own, so it uses
/// `test/flutter_test_config.dart`, which registers **no font at all**; and
/// `lib/theme.dart:349` names `'roboto-mono'` as the theme's family. Without
/// both registrations every themed `Text` captures as Ahem rectangles. Same
/// two-family helper as `test/pages/first_user_golden_test.dart`.
///
/// **The muted (ISA-101) palette.** `HmiStateColors` falls back to
/// `solarizedLight` outside a themed app, which would put violet in a picture
/// whose subject is a muted page.
///
/// **Pinned with `withClock`.** `base_scaffold.dart:217` renders `clock.now()`
/// in the header; the period fixture's timestamps are fixed for the same
/// reason. Nothing in this image may depend on when it ran.
///
/// **Every double here is this file's own**, copied from
/// `test/pages/history_view_guard_test.dart` rather than imported: importing
/// another test file executes its top-level state, and a golden that depended
/// on a neighbour's `setUp` would be a baseline nobody can reproduce.
///
/// To update: flutter test test/pages/history_view_locked_delete_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/history_view.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc/widgets/access_denied_prompt.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';
import '../helpers/golden_platform.dart';

/// The saved view the image is opened on.
const int _viewId = 42;
const String _viewName = 'Freezer overnight';

/// The instant everything in this image is frozen at.
final DateTime _frozen = DateTime.utc(2026, 8, 30, 9, 0);

/// Answers the page's reads. Its writes exist only so that a stray one is
/// visible rather than silently swallowed — this image drives none.
class _RecordingDb extends Fake implements AppDatabase {
  final List<String> writes = [];

  @override
  Future<List<HistoryViewData>> selectHistoryViews() async => [
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

  /// Fixed timestamps, never `DateTime.now()`: a period fixture built from the
  /// wall clock is a golden that churns on every run.
  @override
  Future<List<HistoryViewPeriodData>> listHistoryViewPeriods(
          int viewId) async =>
      [
        HistoryViewPeriodData(
          id: 91,
          viewId: _viewId,
          name: 'Night shift',
          startAt: _frozen.subtract(const Duration(hours: 8)),
          endAt: _frozen,
          createdAt: DateTime.utc(2026),
        ),
      ];

  @override
  Future<DateTime?> getGlobalRetentionHorizon() async => null;

  @override
  Future<void> deleteHistoryView(int id) async =>
      writes.add('deleteHistoryView($id)');

  @override
  Future<void> deleteHistoryViewPeriod(int id) async =>
      writes.add('deleteHistoryViewPeriod($id)');
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

class _SilentSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A session that never changes.
///
/// Overriding [build] keeps the captured frame chosen rather than raced: the
/// real controller chain reaches the database, the preferences store and the
/// station keychain, and a frame captured before it settles is `AsyncLoading`.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._session);

  final AccessSession _session;

  @override
  Future<AccessSession> build() async => _session;
}

/// Nothing but `operate` — the seeded operator role, which is what a panel
/// with nobody signed in holds.
AccessSession _anonymous() => AccessSession.anonymous(
      {...kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups},
    );

/// The menu `BaseScaffold` renders its navigation bar from. Two top-level
/// entries plus the Advanced parent is the app's own shape and the smallest
/// one that builds — `NavigationBar` asserts on fewer than two destinations.
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
  required ThemeData theme,
  required _RecordingDb db,
  required AccessSession session,
  required _SilentSink audit,
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
      // Null, not left to resolve. The real `collectorProvider` reads the
      // shared preferences store, which reaches `AppDatabase.flutterPreferences`
      // — a member this file's `Fake` does not implement — and the second pass
      // of this image had "Error: UnimplementedError: flutterPreferences"
      // painted across the graph pane. `null` is a state the product really
      // has (a station not collecting) and renders the pane's own
      // "No collector available", so the picture shows the app rather than the
      // harness.
      collectorProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      auditSinkProvider.overrideWith((ref) async => audit),
      accessSessionProvider.overrideWith(() => _FixedSession(session)),
    ],
    child: BeamerProvider(
      routerDelegate: delegate,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: theme,
        routerDelegate: delegate,
        routeInformationParser: BeamerParser(),
      ),
    ),
  );
}

/// The control this image is about, found by its tooltip so the finder does
/// not depend on the page's layout.
Finder _deleteViewButton() => find
    .byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Delete view');

/// Selects the saved view in the dropdown, which is what makes the delete
/// control appear at all.
Future<void> _selectSavedView(WidgetTester tester) async {
  await tester.tap(find.byType(DropdownButton<int>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_viewName).last);
  await tester.pumpAndSettle();
}

void main() {
  final (light, _) = muted();

  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
          .load();
    }

    // Both families, deliberately. `test/flutter_test_config.dart` registers
    // neither; `lib/theme.dart:349` asks for the second.
    await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    for (final candidate in <String>[
      if (flutterRoot != null)
        '$flutterRoot/bin/cache/artifacts/material_fonts/'
            'MaterialIcons-Regular.otf',
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]) {
      if (File(candidate).existsSync()) {
        await loadFont('MaterialIcons', candidate);
        break;
      }
    }
  });

  setUp(() {
    // Without these the graph pane's own preferences read throws, and the
    // first pass of this image had "Error: Bad state: The
    // SharedPreferencesAsyncPlatform instance must be set." painted across
    // the middle of it — a picture that teaches a reader the history view
    // shows an error when it does not.
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() => RouteRegistry().menuItems.clear());

  group('history view locked-delete golden',
      skip: goldenSkip, () {
    testWidgets('the history view, anonymous, with a live delete control',
        (tester) async {
      await withClock(Clock.fixed(_frozen), () async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        _registerAppMenu();
        final db = _RecordingDb();
        final audit = _SilentSink();

        await tester.pumpWidget(
            _shell(theme: light, db: db, session: _anonymous(), audit: audit));
        await tester.pumpAndSettle();
        await _selectSavedView(tester);

        // The claims this image exists to make, asserted before the pixels are
        // compared — an eye can see that a button is there, but not that its
        // `onPressed` is non-null.
        expect(find.byType(HistoryViewPage), findsOneWidget);
        expect(_deleteViewButton(), findsOneWidget,
            reason: 'the control is visible, not hidden from a session that '
                'lacks the permission');
        expect(tester.widget<IconButton>(_deleteViewButton()).onPressed,
            isNotNull,
            reason: 'a locked control is tappable and explains itself; a greyed '
                'one tells the operator the app is broken');

        // Merely opening the page denies nothing, so no prompt is in the frame
        // and no audit row was written.
        expect(find.byKey(kAccessDeniedBodyKey), findsNothing);
        expect(audit.rows, isEmpty);
        expect(db.writes, isEmpty);

        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/history_view_delete_stays_live.png'),
        );
      });
    });
  });
}
