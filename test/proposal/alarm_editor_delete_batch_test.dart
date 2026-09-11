/// End-to-end coverage for the staged-delete flag surviving no longer than
/// the batch that set it.
///
/// `_proposedDeleteUids` is what tells the commit loop to call
/// [AlarmMan.removeAlarm] instead of [AlarmMan.updateAlarm] for a given uid.
/// It is per-batch state, and clearing the batch has to clear it: an uid left
/// behind marks the *next* batch's alarm of the same uid as a removal, so
/// accepting a perfectly ordinary create or update deletes the alarm instead
/// of writing it.
///
/// The sibling file `alarm_editor_proposal_test.dart` pins this at source
/// level. This one drives the real page: stage a delete, commit it, stage a
/// create for the same uid, commit that, and look at what AlarmMan was asked
/// to do.
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

import '../helpers/test_helpers.dart' show FakeSecureStorage;

/// Records what the editor asked for, and keeps [alarms] consistent so
/// `ListAlarms` has something to render.
///
/// `implements AlarmMan` rather than a subclass: the real one has a private
/// constructor and builds an OPC UA evaluation stream per alarm, which is a
/// lot of machinery to stand up for two method calls. Everything the page
/// does not touch falls through to [noSuchMethod] and would throw loudly if
/// it ever were touched.
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

/// A pending proposal carrying [config]; `_op: delete` when [delete].
PendingProposal _proposal(int id, AlarmConfig config, {bool delete = false}) {
  final json = config.toJson();
  json['_proposal_type'] = delete ? 'alarm' : 'alarm_create';
  if (delete) json['_op'] = 'delete';
  return PendingProposal(
    id: id,
    proposalType: delete ? 'alarm' : 'alarm_create',
    title: config.title,
    proposalJson: jsonEncode(json),
    operatorId: 'test',
    createdAt: DateTime(2026, 8, 21),
  );
}

/// The alarm editor lives inside `BaseScaffold`, which reads the Beamer
/// location and the route registry during build.
class _AlarmEditorLocation extends BeamLocation<BeamState> {
  _AlarmEditorLocation()
      : super(RouteInformation(uri: Uri.parse('/advanced/alarm-editor')));

  @override
  List<BeamPage> buildPages(BuildContext context, BeamState state) => const [
        BeamPage(key: ValueKey('alarm-editor'), child: AlarmEditorPage()),
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

    // BaseScaffold renders a NavigationBar from the registry, which asserts
    // on fewer than two destinations.
    final registry = RouteRegistry();
    registry.menuItems.clear();
    registry.addMenuItem(
        const MenuItem(label: 'Home', path: '/', icon: Icons.home));
    registry.addMenuItem(const MenuItem(
        label: 'Advanced', path: '/advanced', icon: Icons.settings));

    alarmMan = _RecordingAlarmMan();
    // Accepting no longer writes a status anywhere; all the accept loop does
    // is remove the proposal from state, which is what this test watches.
    proposals = ProposalStateNotifier();
  });

  // The notifier is disposed by the ProviderScope that overrode the provider
  // with it, so nothing to tear down here but the registry.
  tearDown(() => RouteRegistry().menuItems.clear());

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final delegate = BeamerDelegate(
      locationBuilder: (routeInformation, _) => _AlarmEditorLocation(),
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
        ),
      ),
    );
    await tester.pumpWidget(scope);
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
        tester.element(find.byType(AlarmEditorPage)),
        listen: false);
  }

  /// Presses the banner's Accept for whatever is staged.
  Future<void> commitFromBanner(WidgetTester tester) async {
    final commit = container.read(proposalCommitProvider);
    expect(commit, isNotNull,
        reason: 'the page publishes commit to the banner once a batch stages');
    await commit!();
    await tester.pumpAndSettle();
  }

  testWidgets('a staged deletion does not carry into the next batch',
      (tester) async {
    await pumpEditor(tester);

    // Batch one: remove FREEZER_HIGH.
    proposals.addProposal(
        _proposal(1, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();
    await commitFromBanner(tester);
    expect(alarmMan.calls, ['remove:FREEZER_HIGH']);

    // Batch two: the AI proposes the same uid back, as an ordinary create.
    // The operator sees "create", so accepting has to write it.
    proposals.addProposal(
        _proposal(2, _alarm('FREEZER_HIGH', 'Freezer too warm (v2)')));
    await tester.pumpAndSettle();
    await commitFromBanner(tester);

    expect(alarmMan.calls, ['remove:FREEZER_HIGH', 'update:FREEZER_HIGH'],
        reason: 'the delete flag belonged to batch one. Left in '
            '_proposedDeleteUids it makes batch two a removal, and the '
            'operator watches an alarm they just accepted disappear.');
    expect(alarmMan.alarms.map((a) => a.config.uid), contains('FREEZER_HIGH'));
  });

  testWidgets('rejecting a batch drops its deletions too', (tester) async {
    await pumpEditor(tester);

    proposals.addProposal(
        _proposal(1, _alarm('FREEZER_HIGH', 'Freezer too warm'), delete: true));
    await tester.pumpAndSettle();

    final discard = container.read(proposalDiscardProvider);
    expect(discard, isNotNull);
    await discard!();
    await tester.pumpAndSettle();
    expect(alarmMan.calls, isEmpty, reason: 'a reject writes nothing');

    proposals.addProposal(
        _proposal(2, _alarm('FREEZER_HIGH', 'Freezer too warm (v2)')));
    await tester.pumpAndSettle();
    await commitFromBanner(tester);

    expect(alarmMan.calls, ['update:FREEZER_HIGH'],
        reason: 'the rejected batch took its delete flag with it');
  });
}
