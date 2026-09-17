/// Rejecting one row of a staged batch has to take it out of the batch.
///
/// The banner's per-row Reject called `rejectProposal(id)` and trusted "the
/// editor that staged it un-stages its copy off the feedback stream". Only
/// the page editor ever listened to that stream. In the alarm editor, the key
/// repository and the access-templates section the rejected proposal stayed
/// staged, and the next "Accept all" wrote it as if it had been accepted.
///
/// This file deliberately uses nothing but the buttons the operator presses
/// and the batch commit slot that already existed, so it runs -- and fails --
/// against the code as it was.
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

class _RecordingAlarmMan implements AlarmMan {
  final List<String> calls = [];

  @override
  final Set<Alarm> alarms = {};

  @override
  final AlarmManConfig config = AlarmManConfig(alarms: []);

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

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final delegate = BeamerDelegate(
      initialPath: '/advanced/alarm-editor',
      locationBuilder: (routeInformation, _) =>
          _AlarmEditorLocation(routeInformation),
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

  /// The banner's drawer row for [title].
  Finder rowOf(String title) =>
      find.ancestor(of: find.text('Alarm Editor: $title'), matching: find.byType(Row)).first;

  testWidgets(
      'Reject on one row of a staged batch keeps Accept all from writing it',
      (tester) async {
    await pumpApp(tester);

    proposals.addProposal(_proposal(1, 'LINE1_TEMP', 'Line 1 too warm'));
    proposals.addProposal(_proposal(2, 'LINE1_DOOR', 'Line 1 door open'));
    proposals.addProposal(_proposal(3, 'LINE1_AIR', 'Line 1 air low'));
    await tester.pumpAndSettle();
    expect(container.read(proposalCommitProvider), isNotNull,
        reason: 'the open editor stages the batch and publishes its commit');

    // The operator opens the drawer and says no to the first row.
    await tester.tap(find.textContaining('3 AI Proposals'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: rowOf('Line 1 too warm'), matching: find.text('Reject')));
    await tester.pumpAndSettle();
    expect(container.read(proposalStateProvider).proposals.map((p) => p.id),
        [2, 3],
        reason: 'the rejected row leaves the queue');

    // Then accepts what is left.
    await tester.tap(find.textContaining('Accept all'));
    await tester.pumpAndSettle();

    expect(alarmMan.calls, isNot(contains('update:LINE1_TEMP')),
        reason: 'a rejected proposal must not be written by a later Accept '
            'all -- it was still staged in the editor after the banner '
            'dropped it');
    expect(alarmMan.calls, ['update:LINE1_DOOR', 'update:LINE1_AIR']);
    expect(container.read(proposalStateProvider).proposals, isEmpty);
  });
}
