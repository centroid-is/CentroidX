/// Pressing Accept on a single proposal has to finish the job.
///
/// The banner's Accept used to be a bare
/// `proposalStateProvider.notifier.acceptProposal(id)`: it marked the
/// proposal decided and dropped it from state without applying anything.
/// `_buildAcceptAllButton` had documented that trap for the batch buttons
/// since they were written -- "that marks a proposal accepted ... without
/// ever applying the patch, so the edit is silently lost" -- but the
/// single-proposal row kept calling it.
///
/// Reported on 2026-08-31 against a `delete_alarm` proposal: "When there is
/// one proposed item and I click accept it does not follow through and
/// finish. I have to scroll down and click remove alarm in the last
/// proposal." Accept took the banner away, `AlarmMan` was never asked to
/// remove anything, and the alarm editor was left holding the staged removal
/// with its own "Remove Alarm" button -- the only control on screen that was
/// actually deleting the alarm.
///
/// These tests drive the real banner over the real alarm editor and watch
/// what AlarmMan was asked to do. The sibling
/// `alarm_editor_delete_batch_test.dart` calls the editor's commit callback
/// directly, which is exactly why it stayed green through this bug: it never
/// pressed the button the operator presses.
library;

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
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/proposal_banner.dart';

import '../helpers/test_helpers.dart' show FakeSecureStorage;

/// Records what the editor asked for, and keeps [alarms] consistent so
/// `ListAlarms` has something to render. Same shape as the one in
/// `alarm_editor_delete_batch_test.dart`, and for the same reason: the real
/// AlarmMan has a private constructor and builds an OPC UA evaluation stream
/// per alarm.
class _RecordingAlarmMan implements AlarmMan {
  final List<String> calls = [];

  @override
  final Set<Alarm> alarms = {};

  /// Auto-navigation off, and an empty alarm list.
  ///
  /// Read by the alarm editor's own switch and by
  /// `alarmAutoNavigationProvider`, which any [BaseScaffold] in the tree
  /// subscribes to. Off, so no test in this file navigates itself somewhere
  /// else mid-assertion.
  @override
  final AlarmManConfig config = AlarmManConfig(alarms: []);

  @override
  void setAutoNavigate(bool value) => config.autoNavigate = value;

  /// A plant with nothing wrong with it. `alarmAutoNavigationProvider`
  /// subscribes to this the moment a [BaseScaffold] is in the tree.
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

AlarmConfig _alarm(String uid, String title) => AlarmConfig(
      uid: uid,
      title: title,
      description: 'staged by a test',
      rules: const [],
    );

/// A pending proposal carrying [config], shaped the way `delete_alarm` and
/// `create_alarm` shape theirs: the whole config travels, and only `_op` says
/// what accepting it does.
PendingProposal _proposal(int id, AlarmConfig config, {bool delete = false}) {
  final json = config.toJson();
  json['_proposal_type'] = delete ? 'alarm' : 'alarm_create';
  json['_op'] = delete ? 'delete' : 'create';
  return PendingProposal(
    id: id,
    proposalType: delete ? 'alarm' : 'alarm_create',
    title: config.title,
    proposalJson: jsonEncode(json),
    operatorId: 'test',
    createdAt: DateTime(2026, 8, 31),
  );
}

/// The alarm editor lives inside `BaseScaffold`, which reads the Beamer
/// location and the route registry during build.
class _AlarmEditorLocation extends BeamLocation<BeamState> {
  _AlarmEditorLocation(this.info) : super(info);

  /// The banner beams with `data: proposal.proposalJson`, which rides along
  /// as the route information's state -- the same thing `main.dart` hands to
  /// `AlarmEditorPage(proposalData: ...)`.
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

/// Somewhere that is not the alarm editor, for the "no editor open" case.
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

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    Preferences.clearSecretCache();
    DatabaseConfig.clearPrefsCache();

    // BaseScaffold renders a NavigationBar from the registry, which asserts
    // on fewer than two destinations.
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Advanced', path: '/advanced', icon: Icons.settings));

    alarmMan = _RecordingAlarmMan();
    proposals = ProposalStateNotifier();
  });

  tearDown(() => RouteRegistry().menuItems.clear());

  /// Pumps the app with the black banner over whatever page [initialPath]
  /// names -- the banner lives in the `MaterialApp.builder` Stack in
  /// `main.dart`, above the Navigator, so that is where it goes here too.
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
    final scope = ProviderScope(
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
    );
    await tester.pumpWidget(scope);
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
        tester.element(find.byType(ProposalBanner)),
        listen: false);
  }

  /// What the operator does: press Accept on the banner. Nothing else.
  Future<void> pressAccept(WidgetTester tester) async {
    expect(find.text('Accept'), findsOneWidget,
        reason: 'a single pending proposal shows exactly one Accept');
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
  }

  testWidgets('Accept on a single delete proposal removes the alarm',
      (tester) async {
    await pumpApp(tester);

    proposals.addProposal(
        _proposal(1, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();
    expect(container.read(proposalCommitProvider), isNotNull,
        reason: 'the open editor stages the proposal and publishes its commit');

    await pressAccept(tester);

    expect(alarmMan.calls, ['remove:FREEZER_HIGH'],
        reason: 'Accept alone has to delete the alarm. Before this fix it '
            'marked the proposal accepted and applied nothing, and the '
            'operator had to scroll down to the editor\'s own "Remove Alarm" '
            'button to make the deletion happen.');
    expect(alarmMan.alarms.map((a) => a.config.uid),
        isNot(contains('FREEZER_HIGH')));
    expect(container.read(proposalStateProvider).proposals, isEmpty,
        reason: 'and the proposal is decided, so the banner comes down');
    expect(find.text('Remove Alarm'), findsNothing,
        reason: 'no second interaction is left over for the operator');
  });

  testWidgets('Accept on a single create proposal writes the alarm',
      (tester) async {
    // The operator only noticed this on deletes, but the broken Accept was
    // never delete-specific: creates went the same way whenever the accept
    // came from the banner rather than the editor form's own button.
    await pumpApp(tester);

    proposals.addProposal(_proposal(1, _alarm('AIR_LOW', 'Air pressure low')));
    await tester.pumpAndSettle();

    await pressAccept(tester);

    expect(alarmMan.calls, ['update:AIR_LOW'],
        reason: 'updateAlarm handles create and update alike');
    expect(alarmMan.alarms.map((a) => a.config.uid), contains('AIR_LOW'));
    expect(container.read(proposalStateProvider).proposals, isEmpty);
  });

  testWidgets('Accept with no editor open opens it and still finishes',
      (tester) async {
    // Nothing has staged the proposal, so there is no commit to fire yet.
    // Accept beams to the editor that owns the proposal and commits the
    // moment that editor publishes -- one press, whatever page the operator
    // happened to be standing on.
    await pumpApp(tester, initialPath: '/');
    expect(find.byType(AlarmEditorPage), findsNothing);

    proposals.addProposal(
        _proposal(1, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();
    expect(container.read(proposalCommitProvider), isNull);

    await pressAccept(tester);

    expect(find.byType(AlarmEditorPage), findsOneWidget,
        reason: 'Accept opens the editor that owns the proposal');
    expect(alarmMan.calls, ['remove:FREEZER_HIGH']);
    expect(container.read(proposalStateProvider).proposals, isEmpty);
  });

  testWidgets('a proposal that arrives mid-flight is not accepted too',
      (tester) async {
    // The editors stage and commit a whole batch. If a second proposal lands
    // between the press and the editor publishing, committing would save it
    // as well -- on an Accept the operator never pressed on it.
    await pumpApp(tester, initialPath: '/');

    proposals.addProposal(
        _proposal(1, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    // Before the editor has had its post-frame callback, so before the armed
    // commit can fire.
    proposals.addProposal(_proposal(2, _alarm('AIR_LOW', 'Air pressure low')));
    await tester.pumpAndSettle();

    expect(alarmMan.calls, isEmpty,
        reason: 'the queue is no longer the one proposal that was accepted');
    expect(container.read(proposalStateProvider).proposals, hasLength(2),
        reason: 'both stay pending for the operator to review as a batch');
  });

  testWidgets('Accept never marks a proposal accepted without applying it',
      (tester) async {
    // The failure mode in one assertion: whatever path Accept takes, a
    // proposal that leaves state has been written first. Watching the
    // feedback stream is how the AI learns the same thing.
    await pumpApp(tester);

    proposals.addProposal(
        _proposal(7, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();
    await pressAccept(tester);

    expect(container.read(proposalStateProvider).proposals, isEmpty);
    expect(alarmMan.calls, isNotEmpty,
        reason: 'accepted and applied, or neither');
  });
}
