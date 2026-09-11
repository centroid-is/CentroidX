import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/analog_box.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Contract under test — the analog box operator pane (dialog→pane
/// conversion):
///
///   - tap on the box                       → a docked [SidePane] opens, not
///                                            a modal dialog
///   - no range keys / empty ('') range key → NO "Sensor range" section (the
///                                            old dialog's "Advanced" toggle
///                                            showed on `!= null`, so a
///                                            cleared KeyField ('') left a
///                                            toggle with nothing behind it)
///   - a range key bound                    → "Sensor range" section with the
///                                            live value and the editable
///                                            fields folded behind "Adjust"
///   - setpoint keys bound                  → inline editable fields;
///                                            submitting parses and calls
///                                            onWrite with THAT key
void main() {
  Widget wrapPane(Widget pane) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 380, height: 760, child: pane),
        ),
      ),
    );
  }

  AnalogBoxConfig config({
    String? rangeMinKey,
    String? rangeMaxKey,
    String? sp1Key,
    String? sp2Key,
  }) =>
      AnalogBoxConfig(
        analogKey: 'sensors/pressure',
        analogSensorRangeMinKey: rangeMinKey,
        analogSensorRangeMaxKey: rangeMaxKey,
        setpoint1Key: sp1Key,
        setpoint2Key: sp2Key,
        units: 'bar',
      );

  group('sensor range section gating', () {
    testWidgets('no range keys → no Sensor range section', (tester) async {
      await tester.pumpWidget(wrapPane(AnalogBoxPane(
        config: config(),
        value: 4.2,
        onWrite: (_, __) {},
      )));
      expect(find.text('SENSOR RANGE'), findsNothing,
          reason: 'no range keys bound → nothing to adjust, no section');
      expect(find.text('Adjust'), findsNothing);
    });

    testWidgets('empty-string range keys → still no Sensor range section',
        (tester) async {
      // KeyField reports a cleared field as '' — the pane must read that as
      // "not bound", where the old dialog's != null check showed the toggle.
      await tester.pumpWidget(wrapPane(AnalogBoxPane(
        config: config(rangeMinKey: '', rangeMaxKey: ''),
        value: 4.2,
        onWrite: (_, __) {},
      )));
      expect(find.text('SENSOR RANGE'), findsNothing,
          reason: 'cleared ("") keys must not conjure an empty section');
    });

    testWidgets('range key bound → section, live row, fold with field',
        (tester) async {
      final writes = <(String, double)>[];
      await tester.pumpWidget(wrapPane(AnalogBoxPane(
        config: config(rangeMinKey: 'sensors/pressure_min'),
        value: 4.2,
        rangeMin: 0.5,
        onWrite: (key, value) => writes.add((key, value)),
      )));

      expect(find.text('SENSOR RANGE'), findsOneWidget);
      expect(find.text('0.5 bar'), findsOneWidget,
          reason: 'live range value shown read-only up front');
      // Only the bound key gets a row — no max row without a max key.
      expect(find.text('Range max'), findsNothing);

      // The editable field is folded behind Adjust.
      expect(find.byKey(const Key('analog_range_min_field-0.5')),
          findsNothing);
      await tester.tap(find.text('Adjust'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('analog_range_min_field-0.5'));
      expect(field, findsOneWidget);

      await tester.enterText(field, '1.25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes, [('sensors/pressure_min', 1.25)],
          reason: 'submit writes the parsed value to the bound key');
    });
  });

  group('setpoints', () {
    testWidgets('no setpoint keys → no Setpoints section', (tester) async {
      await tester.pumpWidget(wrapPane(AnalogBoxPane(
        config: config(),
        value: 4.2,
        onWrite: (_, __) {},
      )));
      expect(find.text('SETPOINTS'), findsNothing);
    });

    testWidgets('setpoint field submits to its own key', (tester) async {
      final writes = <(String, double)>[];
      await tester.pumpWidget(wrapPane(AnalogBoxPane(
        config: config(sp1Key: 'sensors/pressure_sp1'),
        value: 4.2,
        setpoint1: 3.0,
        onWrite: (key, value) => writes.add((key, value)),
      )));

      expect(find.text('SETPOINTS'), findsOneWidget);
      final field = find.byKey(const Key('analog_sp1_field-3.0'));
      await tester.enterText(field, '3.5');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes, [('sensors/pressure_sp1', 3.5)]);

      // Garbage never reaches the PLC.
      await tester.enterText(field, 'not a number');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(writes.length, 1);
    });
  });

  group('tap opens a side pane', () {
    testWidgets('tap on the box docks a pane instead of a dialog',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('sensors/pressure', 4.2);
      final boxConfig = config();

      await tester.pumpWidget(ProviderScope(
        overrides: [stateManProvider.overrideWith((_) async => fake)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child:
                  SizedBox(width: 80, height: 160, child: boxConfig.build(
                      _DummyContext())),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(SidePaneHost.openId, 'analog_box:${identityHashCode(boxConfig)}');
      expect(find.byType(Dialog), findsNothing,
          reason: 'the detail surface is a docked pane, not a modal dialog');
      expect(find.text('SIGNAL'), findsOneWidget);
      // No range keys on this config — the pane opens without the section.
      expect(find.text('SENSOR RANGE'), findsNothing);

      closeSidePane();
      await tester.pumpAndSettle();
    });
  });
}

/// `AnalogBoxConfig.build` takes a BuildContext it never uses; any object
/// satisfies the signature without pumping a second tree.
class _DummyContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('BuildContext is not used by build()');
}

/// Minimal stand-in for [StateMan]: synchronous numeric pushes per key.
class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};

  void push(String key, double value) {
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(DynamicValue(value: value));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    return _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}
