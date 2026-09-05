import 'package:beamer/beamer.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/report_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/providers/report.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/tfc_dart.dart' hide KeyMappings, StateMan;

class _Db extends AppDatabase {
  _Db() : super.forTest(DatabaseConfig(), NativeDatabase.memory());
}

class _FakeAlarmMan implements AlarmMan {
  @override
  Stream<Set<AlarmActive>> activeAlarms() => Stream.value(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStateMan implements StateMan {
  /// One collected key, so the key autocomplete has something to offer.
  @override
  final KeyMappings keyMappings = KeyMappings(nodes: {
    'line.throughput': KeyMappingEntry(collect: CollectEntry(key: 'line.throughput')),
    'line.uncollected': KeyMappingEntry(),
  });

  @override
  String resolveKey(String key) => key;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Access
//
// The editor's Save goes through GuardedReportStore, which asks for
// `configure` — so these tests sign in. The refusal path has its own test
// below; guarded_report_store_test.dart covers the guard itself.
// ---------------------------------------------------------------------------

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

class _CollectingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

void main() {
  late _Db db;
  late ReportStore store;

  setUp(() {
    db = _Db();
    store = ReportStore(db, isPostgres: false);
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Reports', path: '/reports', icon: Icons.summarize));
  });

  tearDown(() async {
    RouteRegistry().menuItems.clear();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {AccessSession? session}) async {
    // Tall surface: the section rows must be hittable without scrolling.
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // BaseScaffold asserts on a Beamer in context, so the page cannot be
    // pumped bare inside a plain MaterialApp.
    final delegate = BeamerDelegate(
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Report Editor',
              child: ReportEditorPage(),
            ),
      }).call,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reportStoreProvider.overrideWithValue(store),
        auditSinkProvider.overrideWith((ref) async => _CollectingSink()),
        accessSessionProvider
            .overrideWith(() => _FixedSession(session ?? _withConfigure())),
        alarmManProvider.overrideWith((ref) async => _FakeAlarmMan()),
        stateManProvider.overrideWith((ref) async => _FakeStateMan()),
      ],
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('adding a shift and a report persists through Save',
      (tester) async {
    await pump(tester);
    expect(find.text('Shift calendar'), findsOneWidget);

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shift-0')), findsOneWidget);

    await tester.tap(find.text('Add report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty report'));
    await tester.pumpAndSettle();
    expect(find.text('New report'), findsOneWidget);

    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsNothing);

    final shifts = await store.loadShifts();
    expect(shifts.shifts.single.name, 'Shift 1');
    final reports = await store.loadReports();
    expect(reports.reports.single.name, 'New report');
    // The default new report starts with an empty KPI section.
    expect(reports.reports.single.sections.single, isA<KpiSectionConfig>());
  });

  testWidgets('the shift template seeds the standard section list',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('Add report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Standard shift report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final report = (await store.loadReports()).reports.single;
    expect(report.name, 'Shift report');
    expect(report.sections.map((s) => s.type),
        ['kpi', 'downtime', 'alarm_summary', 'text']);
  });

  testWidgets('sections can be added and reordered with the arrows',
      (tester) async {
    await store.saveReports(ReportManConfig(reports: [
      ReportConfig(id: 'r1', name: 'R', sections: [
        KpiSectionConfig(),
        TextSectionConfig(text: 'notes'),
      ]),
    ]));
    await pump(tester);

    await tester.tap(find.text('R'));
    await tester.pumpAndSettle();

    // Move the text section up past the KPI row.
    await tester.ensureVisible(find.byTooltip('Move up').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move up').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final reports = await store.loadReports();
    expect(reports.reports.single.sections.first, isA<TextSectionConfig>());
  });

  testWidgets('an operator without configure is refused, and keeps the edits',
      (tester) async {
    await pump(tester, session: _anonymous());

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Nothing landed…
    expect((await store.loadShifts()).shifts, isEmpty);
    // …and the operator's work is still in the buffer for somebody who may
    // save it, rather than being thrown away with the refusal.
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.byKey(const ValueKey('shift-0')), findsOneWidget);
  });

  testWidgets(
      'an agent proposal is staged, not applied, until a person saves it',
      (tester) async {
    // What the MCP write tools now return instead of writing.
    const proposalJson = '{"_proposal_type":"report","_op":"create",'
        '"title":"Report \\"Night audit\\"","id":"night","name":"Night audit",'
        '"range":"shift","sections":[{"type":"text","text":"hi"}]}';

    await pump(tester);

    final container = ProviderScope.containerOf(
        tester.element(find.byType(ReportEditorPage)));
    container.read(proposalStateProvider.notifier).addProposal(
        PendingProposal.tryParse(proposalJson)!);
    await tester.pumpAndSettle();

    // Staged into the buffer and offered for review…
    expect(find.text('Night audit'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
    // …but nothing has been written yet.
    expect((await store.loadReports()).reports, isEmpty);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The person's Save is the approval — and it is their session the guard
    // checked and the audit row will name.
    expect((await store.loadReports()).reports.single.id, 'night');
  });
}
