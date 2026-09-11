/// End-to-end wiring of the navigation alarm pulse: a real [BaseScaffold]
/// watching the real [navigationAlarmsProvider], fed by a page manager whose
/// nested page carries an Alarm beacon, and an alarm manager with one active
/// nav-flagged alarm. The unit tests in test/providers/nav_alarm_test.dart
/// prove the derivation; this proves the chain the app actually runs —
/// provider → RouteRegistry menu → NavDropdown badge — because that chain is
/// where a plant report said the pulse never appeared.
library;

import 'dart:async';

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/assets/alarm_visibility.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/nav_alarm_badge.dart';
import 'package:tfc/widgets/nav_dropdown.dart';
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

/// The active-alarm stream is the only thing the navigation chain reads.
class _FakeAlarmMan implements AlarmMan {
  final subject = BehaviorSubject<Set<AlarmActive>>.seeded({});

  /// Auto-navigation off. This file is about the *pulse*; with the jump on,
  /// the alarm it fires would beam the scaffold to /baader/overview and the
  /// badge under test would be the one page the bar deliberately leaves
  /// quiet. See `test/widgets/alarm_auto_navigation_end_to_end_test.dart`.
  @override
  final AlarmManConfig config = AlarmManConfig(alarms: []);

  @override
  Stream<Set<AlarmActive>> activeAlarms() => subject.stream;

  @override
  Stream<List<AlarmActive?>> history() => Stream.value(const []);

  @override
  List<AlarmActive> filterAlarms(List<AlarmActive> alarms, String query) =>
      alarms;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AssetPage _page(String path, String label,
    {List<String> childPaths = const [], AlarmVisibilityConfig? beacon}) {
  return AssetPage(
    menuItem: MenuItem(
      label: label,
      path: path,
      icon: Icons.factory,
      children: [
        for (final p in childPaths) MenuItem(label: p, path: p, icon: Icons.abc)
      ],
    ),
    assets: [if (beacon != null) beacon],
    mirroringDisabled: false,
  );
}

void main() {
  tearDown(() => RouteRegistry().menuItems.clear());

  testWidgets(
      'an alarm on a page nested in a section pulses the section icon',
      (tester) async {
    // The user's real shape: mimic pages live under sections, never at the
    // top level. The beacon sits on /baader/overview.
    final pages = <String, AssetPage>{
      '/': _page('/', 'Home'),
      '/baader': _page('/baader', 'Baader',
          childPaths: ['/baader/overview', '/baader/details']),
      '/baader/overview': _page('/baader/overview', 'Overview',
          beacon: AlarmVisibilityConfig(alarmUids: ['a1'])),
      '/baader/details': _page('/baader/details', 'Details'),
    };
    final manager =
        PageManager(pages: pages, prefs: FakeEditorPreferences());

    // Register the menu exactly the way centroid-hmi main.dart does: the
    // resolved root menu items from the page manager.
    final registry = RouteRegistry();
    registry.menuItems.clear();
    for (final item in manager.getRootMenuItems()) {
      registry.addMenuItem(item);
    }

    final alarmMan = _FakeAlarmMan();

    final delegate = BeamerDelegate(
      locationBuilder: RoutesLocationBuilder(routes: {
        '/': (context, state, data) => const BeamPage(
              key: ValueKey('/'),
              title: 'Home',
              child: BaseScaffold(title: 'Home', body: Text('home-body')),
            ),
      }).call,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pageManagerProvider.overrideWith((ref) async => manager),
          alarmManProvider.overrideWith((ref) async => alarmMan),
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

    // Quiet bar first: the section is there, unbadged.
    final sectionIndicator = find.byWidgetPredicate(
        (w) => w is TopLevelNavIndicator && w.label == 'Baader');
    expect(sectionIndicator, findsOneWidget,
        reason: 'the Baader section should be in the navigation bar');
    expect(
        tester.widget<TopLevelNavIndicator>(sectionIndicator).alarmLevel,
        isNull);

    // The alarm fires.
    alarmMan.subject.add({_active('a1')});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
        tester.widget<TopLevelNavIndicator>(sectionIndicator).alarmLevel,
        AlarmLevel.error,
        reason: 'the beacon on /baader/overview is bound to active alarm a1 '
            'with the navigation indicator on, so the Baader section icon '
            'must pulse');

    // And the badge itself is actually in the tree drawing something.
    final badge = find.descendant(
        of: sectionIndicator, matching: find.byType(NavAlarmBadge));
    expect(tester.widget<NavAlarmBadge>(badge).level, AlarmLevel.error);

    alarmMan.subject.close();
  });
}
