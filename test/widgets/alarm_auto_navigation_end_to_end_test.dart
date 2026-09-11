/// The chain the app actually runs: a real [BaseScaffold] under a real Beamer,
/// watching the real [alarmAutoNavigationProvider], fed by a page manager
/// whose pages carry Alarm beacons and an alarm manager whose active set the
/// test drives.
///
/// `test/providers/alarm_auto_navigation_test.dart` proves the policy. What is
/// proven here is the wiring either side of it — that a raise reaches the
/// scaffold, that the scaffold beams, and that the two vetoes only the widget
/// can apply (where the operator is standing, and the route's access group)
/// are actually applied.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/alarm_auto_navigation.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup;
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

import '../helpers/page_editor_harness.dart' show FakeEditorPreferences;

AlarmActive _active(String uid, {AlarmLevel level = AlarmLevel.error}) {
  final rule = AlarmRule(
    level: level,
    expression: ExpressionConfig(value: Expression(formula: 'x')),
    acknowledgeRequired: false,
  );
  return AlarmActive(
    alarm: Alarm(
      config: AlarmConfig(
        uid: uid,
        title: 'Alarm $uid',
        description: 'desc',
        rules: [rule],
      ),
    ),
    notification: AlarmNotification(
      uid: uid,
      active: true,
      expression: 'x',
      rule: rule,
      timestamp: DateTime(2026, 1, 1),
    ),
  );
}

/// The active-alarm stream and the auto-navigate flag: everything the chain
/// reads off an [AlarmMan].
class _FakeAlarmMan implements AlarmMan {
  _FakeAlarmMan({bool autoNavigate = true})
      : config = AlarmManConfig(alarms: [], autoNavigate: autoNavigate);

  @override
  final AlarmManConfig config;

  final subject = BehaviorSubject<Set<AlarmActive>>.seeded({});

  @override
  Stream<Set<AlarmActive>> activeAlarms() => subject.stream;

  @override
  Stream<List<AlarmActive?>> history() => Stream.value(const []);

  @override
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String query) =>
      alarms;

  @override
  void setAutoNavigate(bool value) => config.autoNavigate = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AssetPage _page(String path, {AlarmVisibilityConfig? beacon}) => AssetPage(
      menuItem: MenuItem(label: path, path: path, icon: Icons.factory),
      assets: [if (beacon != null) beacon],
      mirroringDisabled: false,
    );

/// Home, a freezer page with a beacon on `a1`, and a packing page on `a2`.
PageManager _manager() => PageManager(
      pages: {
        '/': _page('/'),
        '/freezer': _page('/freezer',
            beacon: AlarmVisibilityConfig(alarmUids: ['a1'])),
        '/packing': _page('/packing',
            beacon: AlarmVisibilityConfig(alarmUids: ['a2'])),
        '/advanced/page-editor': _page('/advanced/page-editor'),
      },
      prefs: FakeEditorPreferences(),
    );

BeamerDelegate _delegate({String initialPath = '/'}) => BeamerDelegate(
      initialPath: initialPath,
      locationBuilder: RoutesLocationBuilder(routes: {
        for (final path in const [
          '/',
          '/freezer',
          '/packing',
          '/advanced/page-editor',
        ])
          path: (context, state, data) => BeamPage(
                key: ValueKey(path),
                title: path,
                child: BaseScaffold(title: path, body: Text('body $path')),
              ),
      }).call,
    );

Future<void> _pumpApp(
  WidgetTester tester, {
  required PageManager manager,
  required _FakeAlarmMan alarmMan,
  required BeamerDelegate delegate,
}) async {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  for (final item in manager.getRootMenuItems()) {
    registry.addMenuItem(item);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pageManagerProvider.overrideWith((ref) async => manager),
        alarmManProvider.overrideWith((ref) async => alarmMan),
        // The plant has been running a while.
        alarmAutoNavigateSettleProvider.overrideWithValue(Duration.zero),
      ],
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

String _location(BeamerDelegate delegate) => delegate.configuration.uri.path;

/// Enough frames for the stream event to reach the scaffold and for the beam
/// it causes to rebuild the route.
///
/// Not `pumpAndSettle`: an active alarm puts a pulsing beacon and a pulsing
/// banner on screen, and neither ever stops — settling is exactly what this
/// feature's own output prevents.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() {
    RouteRegistry().menuItems.clear();
    RouteRegistry().clearRouteGroups();
  });

  testWidgets('a raising alarm takes the screen to its beacon page',
      (tester) async {
    final alarmMan = _FakeAlarmMan();
    final delegate = _delegate();
    await _pumpApp(
        tester,
        manager: _manager(),
        alarmMan: alarmMan,
        delegate: delegate);

    expect(_location(delegate), '/');

    alarmMan.subject.add({_active('a1')});
    await _settle(tester);

    expect(_location(delegate), '/freezer',
        reason: 'the beacon bound to a1 sits on /freezer');

    await alarmMan.subject.close();
  });

  testWidgets('the flag off leaves the screen where it is', (tester) async {
    final alarmMan = _FakeAlarmMan(autoNavigate: false);
    final delegate = _delegate();
    await _pumpApp(
        tester,
        manager: _manager(),
        alarmMan: alarmMan,
        delegate: delegate);

    alarmMan.subject.add({_active('a1')});
    await _settle(tester);

    expect(_location(delegate), '/');

    await alarmMan.subject.close();
  });

  testWidgets('a second, more severe alarm moves the screen again',
      (tester) async {
    final alarmMan = _FakeAlarmMan();
    final delegate = _delegate();
    await _pumpApp(
        tester,
        manager: _manager(),
        alarmMan: alarmMan,
        delegate: delegate);

    alarmMan.subject.add({_active('a1', level: AlarmLevel.warning)});
    await _settle(tester);
    expect(_location(delegate), '/freezer');

    alarmMan.subject.add({
      _active('a1', level: AlarmLevel.warning),
      _active('a2', level: AlarmLevel.error),
    });
    await _settle(tester);
    expect(_location(delegate), '/packing');

    await alarmMan.subject.close();
  });

  testWidgets('a second, equally severe alarm does not', (tester) async {
    final alarmMan = _FakeAlarmMan();
    final delegate = _delegate();
    await _pumpApp(
        tester,
        manager: _manager(),
        alarmMan: alarmMan,
        delegate: delegate);

    alarmMan.subject.add({_active('a1', level: AlarmLevel.error)});
    await _settle(tester);
    expect(_location(delegate), '/freezer');

    alarmMan.subject.add({
      _active('a1', level: AlarmLevel.error),
      _active('a2', level: AlarmLevel.error),
    });
    await _settle(tester);
    expect(_location(delegate), '/freezer',
        reason: 'error does not outrank error');

    await alarmMan.subject.close();
  });

  testWidgets('nothing drags an engineer out of the page editor',
      (tester) async {
    // The one veto only the widget can apply: the route the operator is on is
    // raised, so somebody signed in to configure the plant is standing there.
    RouteRegistry()
        .declareRouteGroup('/advanced/page-editor', AccessGroup.configure);

    final alarmMan = _FakeAlarmMan();
    final delegate = _delegate(initialPath: '/advanced/page-editor');
    await _pumpApp(
        tester,
        manager: _manager(),
        alarmMan: alarmMan,
        delegate: delegate);
    expect(_location(delegate), '/advanced/page-editor');

    alarmMan.subject.add({_active('a1')});
    await _settle(tester);
    expect(_location(delegate), '/advanced/page-editor');

    await alarmMan.subject.close();
  });
}
