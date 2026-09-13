/// Accepting one of several pending proposals has to leave the others
/// pending -- and acceptable.
///
/// Reported 2026-09-13: an operator shown five proposals (four templates and
/// a binding sweep) wanted three of them. The banner's per-row Accept could
/// only open the editor, whose one commit saved the whole batch; the safe
/// move the screen offered was Reject all, so that is what happened, and
/// real work was thrown away.
///
/// The seam that fixes it is [proposalItemActionsProvider]: an editor offers
/// a commit and a discard per staged proposal id, and the banner's row
/// buttons take that seam. These tests drive the real banner over the real
/// alarm editor -- the buttons the operator presses, then what AlarmMan was
/// asked to do and what the feedback stream told the MCP client.
library;

import 'dart:async';
import 'dart:convert';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/proposal.dart' show describeProposalFeedback;
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/proposal_banner.dart';

import '../helpers/test_helpers.dart' show FakeSecureStorage;

class _RecordingAlarmMan implements AlarmMan {
  final List<String> calls = [];

  @override
  final Set<Alarm> alarms = {};

  @override
  final AlarmManConfig config = AlarmManConfig(alarms: []);

  @override
  void setAutoNavigate(bool value) => config.autoNavigate = value;

  @override
  Stream<Set<AlarmActive>> activeAlarms() =>
      const Stream<Set<AlarmActive>>.empty();

  @override
  void updateAlarm(AlarmConfig alarm) {
    calls.add('update:${alarm.uid}');
    alarms.removeWhere((e) => e.config.uid == alarm.uid);
    alarms.add(Alarm(config: alarm));
  }

  @override
  void removeAlarm(AlarmConfig alarm) {
    calls.add('remove:${alarm.uid}');
    alarms.removeWhere((e) => e.config.uid == alarm.uid);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PendingProposal _proposal(int id, String uid, String title) {
  final json = AlarmConfig(
    uid: uid,
    title: title,
    description: 'staged by a test',
    rules: const [],
  ).toJson();
  json['_proposal_type'] = 'alarm_create';
  json['_op'] = 'create';
  return PendingProposal(
    id: id,
    proposalType: 'alarm_create',
    title: title,
    proposalJson: jsonEncode(json),
    operatorId: 'test',
    createdAt: DateTime(2026, 9, 13),
  );
}

class _AlarmEditorLocation extends BeamLocation<BeamState> {
  _AlarmEditorLocation(this.info) : super(info);

  final RouteInformation info;

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => [
        BeamPage(
          key: const ValueKey('alarm-editor'),
          child: AlarmEditorPage(
            proposalData: info.state is String ? info.state as String : null,
          ),
        ),
      ];

  @override
  List<Pattern> get pathPatterns => ['/advanced/alarm-editor'];
}

class _HomeLocation extends BeamLocation<BeamState> {
  _HomeLocation(super.info);

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => const [
        BeamPage(
          key: ValueKey('home'),
          child: Scaffold(body: Center(child: Text('home'))),
        ),
      ];

  @override
  List<Pattern> get pathPatterns => ['/'];
}

void main() {
  late _RecordingAlarmMan alarmMan;
  late ProposalStateNotifier proposals;
  late ProviderContainer container;
  late StreamController<ProposalFeedback> feedback;
  late List<ProposalFeedback> decisions;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    Preferences.clearSecretCache();
    DatabaseConfig.clearPrefsCache();

    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Advanced', path: '/advanced', icon: Icons.settings));

    alarmMan = _RecordingAlarmMan();
    // Wired to a feedback stream, exactly as `proposalStateProvider` builds
    // it: what the MCP client is told is half of what these tests check.
    feedback = StreamController<ProposalFeedback>.broadcast();
    decisions = [];
    feedback.stream.listen(decisions.add);
    proposals = ProposalStateNotifier(feedback: feedback);
  });

  tearDown(() async {
    RouteRegistry().menuItems.clear();
    await feedback.close();
  });

  Future<void> pumpApp(WidgetTester tester,
      {String initialPath = '/advanced/alarm-editor'}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final delegate = BeamerDelegate(
      initialPath: initialPath,
      locationBuilder: (routeInformation, _) =>
          routeInformation.uri.path == '/advanced/alarm-editor'
              ? _AlarmEditorLocation(routeInformation)
              : _HomeLocation(routeInformation),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        alarmManProvider.overrideWith((ref) async => alarmMan),
        proposalStateProvider.overrideWith((ref) => proposals),
        databaseProvider.overrideWith((ref) async => null),
      ],
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
          builder: (context, child) => Stack(
            children: [
              if (child != null) child,
              const ProposalBanner(),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
        tester.element(find.byType(ProposalBanner)),
        listen: false);
  }

  List<int> pendingIds() =>
      container.read(proposalStateProvider).proposals.map((p) => p.id).toList();

  Iterable<int> offeredIds() => container.read(proposalItemActionsProvider).keys;

  /// Opens the banner's drawer.
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.textContaining('AI Proposals'));
    await tester.pumpAndSettle();
  }

  /// The banner's drawer row for [title].
  Finder rowOf(String title) =>
      find.ancestor(of: find.text('Alarm Editor: $title'), matching: find.byType(Row)).first;

  Future<void> pressOnRow(WidgetTester tester, String title, String button) async {
    await tester.tap(find.descendant(of: rowOf(title), matching: find.text(button)));
    await tester.pumpAndSettle();
  }

  void stageThree() {
    proposals.addProposal(_proposal(1, 'LINE1_TEMP', 'Line 1 too warm'));
    proposals.addProposal(_proposal(2, 'LINE1_DOOR', 'Line 1 door open'));
    proposals.addProposal(_proposal(3, 'LINE1_AIR', 'Line 1 air low'));
  }

  testWidgets(
      'Accept on one row saves that alarm and leaves the rest pending and '
      'acceptable', (tester) async {
    await pumpApp(tester);
    stageThree();
    await tester.pumpAndSettle();
    expect(offeredIds(), unorderedEquals([1, 2, 3]),
        reason: 'the open editor offers each staged row on its own');

    await expand(tester);
    await pressOnRow(tester, 'Line 1 door open', 'Accept');

    expect(alarmMan.calls, ['update:LINE1_DOOR'],
        reason: 'exactly the row that was accepted is written');
    expect(pendingIds(), [1, 3],
        reason: 'the others are neither dropped nor accepted');
    expect(offeredIds(), unorderedEquals([1, 3]),
        reason: 'and they are still staged, one row each');
    expect(container.read(proposalCommitProvider), isNotNull,
        reason: 'the batch commit is still up for what is left');

    // Still acceptable: Accept all takes exactly the two that remain.
    await tester.tap(find.textContaining('Accept all'));
    await tester.pumpAndSettle();
    expect(alarmMan.calls,
        ['update:LINE1_DOOR', 'update:LINE1_TEMP', 'update:LINE1_AIR']);
    expect(pendingIds(), isEmpty);
    expect(offeredIds(), isEmpty);
  });

  testWidgets('Reject on one row drops that one and keeps the rest staged',
      (tester) async {
    await pumpApp(tester);
    stageThree();
    await tester.pumpAndSettle();

    await expand(tester);
    await pressOnRow(tester, 'Line 1 too warm', 'Reject');

    expect(alarmMan.calls, isEmpty, reason: 'a reject writes nothing');
    expect(pendingIds(), [2, 3]);
    expect(offeredIds(), unorderedEquals([2, 3]));

    await pressOnRow(tester, 'Line 1 air low', 'Accept');
    expect(alarmMan.calls, ['update:LINE1_AIR']);
    expect(pendingIds(), [2]);

    // The last one is the single-proposal banner now; its Accept goes
    // through the same per-row seam.
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(alarmMan.calls, ['update:LINE1_AIR', 'update:LINE1_DOOR']);
    expect(alarmMan.calls, isNot(contains('update:LINE1_TEMP')),
        reason: 'the rejected row was never written');
    expect(pendingIds(), isEmpty);
  });

  testWidgets('the MCP client is told exactly which rows were decided',
      (tester) async {
    await pumpApp(tester);
    stageThree();
    proposals.addProposal(_proposal(4, 'LINE2_TEMP', 'Line 2 too warm'));
    proposals.addProposal(_proposal(5, 'LINE2_DOOR', 'Line 2 door open'));
    await tester.pumpAndSettle();

    await expand(tester);
    await pressOnRow(tester, 'Line 1 too warm', 'Accept');
    await pressOnRow(tester, 'Line 1 air low', 'Accept');
    await pressOnRow(tester, 'Line 2 door open', 'Accept');
    await pressOnRow(tester, 'Line 2 too warm', 'Reject');

    final accepted = decisions.where((d) => d.action == 'accepted').toList();
    expect(accepted.map((d) => d.proposals.map((p) => p.title).toList()), [
      ['Line 1 too warm'],
      ['Line 1 air low'],
      ['Line 2 door open'],
    ], reason: 'one decision per press, naming exactly that proposal');
    expect(
        describeProposalFeedback('accepted', accepted.first.proposals),
        'Accepted the alarm proposal "Line 1 too warm".');
    final rejected = decisions.where((d) => d.action == 'rejected').toList();
    expect(rejected.map((d) => d.proposals.map((p) => p.title).toList()), [
      ['Line 2 too warm'],
    ]);
    expect(pendingIds(), [2], reason: 'the undecided one is still pending');
    expect(alarmMan.calls,
        ['update:LINE1_TEMP', 'update:LINE1_AIR', 'update:LINE2_DOOR']);
  });

  testWidgets(
      'Accept on a row while the editor is still opening saves that row and '
      'nothing that arrived meanwhile', (tester) async {
    // The race the whole-queue guard exists for: a proposal landing between
    // the press and the editor publishing must not be written by an Accept
    // the operator never pressed on it. The per-row commit is scoped to its
    // id, so the armed Accept saves exactly the pressed row.
    await pumpApp(tester, initialPath: '/');
    expect(find.byType(AlarmEditorPage), findsNothing);
    proposals.addProposal(_proposal(1, 'LINE1_TEMP', 'Line 1 too warm'));
    proposals.addProposal(_proposal(2, 'LINE1_DOOR', 'Line 1 door open'));
    await tester.pumpAndSettle();
    expect(offeredIds(), isEmpty, reason: 'no editor is open to offer any');

    await expand(tester);
    await tester.tap(find.descendant(
        of: rowOf('Line 1 too warm'), matching: find.text('Accept')));
    // Before the editor has had its post-frame callback.
    proposals.addProposal(_proposal(3, 'LINE1_AIR', 'Line 1 air low'));
    await tester.pumpAndSettle();

    expect(find.byType(AlarmEditorPage), findsOneWidget,
        reason: 'Accept opened the editor that owns the proposal');
    expect(alarmMan.calls, ['update:LINE1_TEMP'],
        reason: 'the pressed row, and only the pressed row');
    expect(pendingIds(), [2, 3],
        reason: 'neither the sibling nor the arrival was decided');
    expect(offeredIds(), unorderedEquals([2, 3]),
        reason: 'both are staged and acceptable one at a time');
  });

  testWidgets('a row rejected straight from the queue is un-staged too',
      (tester) async {
    // The chat batch card and an MCP-side dismiss reach the notifier
    // directly. The editor reconciles its batch against the queue, so what
    // it commits is exactly what is still pending.
    await pumpApp(tester);
    stageThree();
    await tester.pumpAndSettle();

    await proposals.rejectProposal(1);
    await proposals.dismissProposal(3);
    await tester.pumpAndSettle();
    expect(offeredIds(), [2]);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(alarmMan.calls, ['update:LINE1_DOOR']);
    expect(pendingIds(), isEmpty);
  });
}
