/// The staged-proposal chrome has to clear when the form accepts, whichever
/// way the proposal was staged.
///
/// [AlarmEditorPage] stages proposals two ways: from `proposalStateProvider`
/// (each carrying an id) and from the JSON the route hands it, which carries
/// none -- the chat batch card calls `acceptAllOfType()` first, so the
/// proposals are already out of state by the time it beams here.
///
/// The form's "Accept Proposal" writes the alarm either way, but only the
/// first way used to drop it from `_proposedAlarms`. Staged by route, the
/// batch stayed non-empty forever: the amber "AI proposal" strip and the
/// highlighted row stayed on screen with the alarm already saved, and the
/// right pane kept offering to accept it again.
library;

import 'dart:convert';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';

import 'package:tfc/models/menu_item.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/proposal_state.dart';
import 'package:tfc/route_registry.dart';

import '../helpers/test_helpers.dart' show FakeSecureStorage;

/// Records what the editor asked for; see the sibling delete-batch test.
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

/// A config the form will accept: the submit button stays disabled while an
/// alarm has no rule, or a rule whose expression does not parse.
AlarmConfig _alarm(String uid, String title) => AlarmConfig(
      uid: uid,
      title: title,
      description: 'staged by a test',
      rules: [
        AlarmRule(
          level: AlarmLevel.error,
          expression: ExpressionConfig(value: Expression(formula: 'x')),
          acknowledgeRequired: false,
        ),
      ],
    );

/// The JSON a route carries: the proposal map, with no id anywhere.
String _routedJson(AlarmConfig config) {
  final json = config.toJson();
  json['_proposal_type'] = 'alarm_create';
  return jsonEncode(json);
}

class _AlarmEditorLocation extends BeamLocation<BeamState> {
  _AlarmEditorLocation(this.proposalData)
      : super(RouteInformation(uri: Uri.parse('/advanced/alarm-editor')));

  final String? proposalData;

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => [
        BeamPage(
          key: const ValueKey('alarm-editor'),
          child: AlarmEditorPage(proposalData: proposalData),
        ),
      ];

  @override
  List<Pattern> get pathPatterns => ['/advanced/alarm-editor'];
}

/// The amber strip at the top of the page — the visible "a proposal is
/// staged" marker, and the thing that used to outlive the accept.
Finder get stagedStrip => find.textContaining('AI proposal');

void main() {
  late _RecordingAlarmMan alarmMan;
  late ProposalStateNotifier proposals;

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

  Future<void> pumpEditor(WidgetTester tester, {String? proposalData}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final delegate = BeamerDelegate(
      locationBuilder: (routeInformation, _) =>
          _AlarmEditorLocation(proposalData),
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
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('accepting a routed proposal clears the staged batch',
      (tester) async {
    await pumpEditor(tester,
        proposalData: _routedJson(_alarm('FREEZER_HIGH', 'Freezer too warm')));

    expect(stagedStrip, findsWidgets,
        reason: 'the route carried a proposal, so the page stages it');

    final accept = find.widgetWithText(ElevatedButton, 'Accept Proposal');
    expect(accept, findsOneWidget);
    expect(tester.widget<ElevatedButton>(accept).onPressed, isNotNull,
        reason: 'the staged alarm has a valid rule, so submit is enabled');

    // The form scrolls; the submit button sits below a 1000 px viewport.
    await tester.ensureVisible(accept);
    await tester.pumpAndSettle();
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(alarmMan.calls, ['update:FREEZER_HIGH']);
    expect(stagedStrip, findsNothing,
        reason: 'the alarm is saved, so nothing is staged any more — a strip '
            'left up says an accepted proposal is still pending, and the '
            'right pane keeps offering to accept it again');
    expect(find.widgetWithText(ElevatedButton, 'Accept Proposal'), findsNothing);
  });

  testWidgets('accepting a state-staged proposal still clears the batch',
      (tester) async {
    await pumpEditor(tester);
    proposals.addProposal(PendingProposal(
      id: 7,
      proposalType: 'alarm_create',
      title: 'Freezer too warm',
      proposalJson: _routedJson(_alarm('FREEZER_HIGH', 'Freezer too warm')),
      operatorId: 'test',
      createdAt: DateTime(2026, 8, 26),
    ));
    await tester.pumpAndSettle();

    expect(stagedStrip, findsWidgets);
    final accept = find.widgetWithText(ElevatedButton, 'Accept Proposal');
    await tester.ensureVisible(accept);
    await tester.pumpAndSettle();
    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(alarmMan.calls, ['update:FREEZER_HIGH']);
    expect(stagedStrip, findsNothing);
  });
}
