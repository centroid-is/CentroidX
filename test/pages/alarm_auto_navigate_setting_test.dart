/// The switch in the Alarm Editor that turns plant-wide auto-navigation on.
///
/// What it writes is proven in
/// `packages/tfc_dart/test/core/alarm_auto_navigate_flag_test.dart`; what is
/// proven here is that the tile reflects the stored value, writes through on a
/// tap, and renders nothing at all while there is no alarm manager to write to.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc_dart/core/alarm.dart';

class _FakeAlarmMan implements AlarmMan {
  _FakeAlarmMan({bool autoNavigate = false})
      : config = AlarmManConfig(alarms: [], autoNavigate: autoNavigate);

  @override
  final AlarmManConfig config;

  int writes = 0;

  @override
  void setAutoNavigate(bool value) {
    writes++;
    config.autoNavigate = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      home: Scaffold(body: AlarmAutoNavigateSetting()),
    ),
  ));
  await tester.pump();
}

const _tile = ValueKey('alarm-editor-auto-navigate');

void main() {
  testWidgets('off by default, and the subtitle says what that means',
      (tester) async {
    final man = _FakeAlarmMan();
    await _pump(tester,
        [alarmManProvider.overrideWith((ref) async => man)]);

    expect(tester.widget<SwitchListTile>(find.byKey(_tile)).value, isFalse);
    expect(find.textContaining('stays where it is'), findsOneWidget);
  });

  testWidgets('a tap turns it on and writes it through', (tester) async {
    final man = _FakeAlarmMan();
    await _pump(tester,
        [alarmManProvider.overrideWith((ref) async => man)]);

    await tester.tap(find.byKey(_tile));
    await tester.pump();

    expect(man.writes, 1);
    expect(man.config.autoNavigate, isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(_tile)).value, isTrue);
    expect(find.textContaining('more severe'), findsOneWidget,
        reason: 'the preemption rule is stated where it is turned on, not '
            'left for an operator to discover from the screen moving');
  });

  testWidgets('a stored-on flag comes up on', (tester) async {
    final man = _FakeAlarmMan(autoNavigate: true);
    await _pump(tester,
        [alarmManProvider.overrideWith((ref) async => man)]);

    expect(tester.widget<SwitchListTile>(find.byKey(_tile)).value, isTrue);

    await tester.tap(find.byKey(_tile));
    await tester.pump();
    expect(man.config.autoNavigate, isFalse);
  });

  testWidgets('no tile at all while there is no alarm manager',
      (tester) async {
    // A tile rendered enabled-but-inert would be flipped and would not stick.
    await _pump(tester, [
      alarmManProvider.overrideWith((ref) => Completer<AlarmMan>().future),
    ]);

    expect(find.byKey(_tile), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });
}
