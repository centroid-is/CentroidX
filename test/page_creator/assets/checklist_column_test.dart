// One line of the Checklists dialog.
//
// A line is a list of LEDs, each bound to a PLC bool. The column now says how
// far along the line is (done / total and a thin bar), numbers the steps, and
// lets a done step stand back with a check beside it -- all read from the same
// key streams the LED asset reads, with a key the PLC will not serve leaving
// the rest of the column working.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:tfc/page_creator/assets/checklists.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// Serves a fixed value per key; anything else is refused the way a PLC
/// refuses a node it does not have.
class _FakeStateMan extends Fake implements StateMan {
  _FakeStateMan(this.values);
  final Map<String, bool> values;
  final Map<String, int> subscribes = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    subscribes[key] = (subscribes[key] ?? 0) + 1;
    final value = values[key];
    if (value == null) throw StateError('BadNodeIdUnknown: $key');
    return Stream<DynamicValue>.value(
            DynamicValue(value: value, typeId: NodeId.boolean))
        .asBroadcastStream();
  }
}

Future<_FakeStateMan> _pump(
  WidgetTester tester,
  List<LEDConfig> steps, {
  Map<String, bool> served = const {},
  ThemeData? theme,
}) async {
  final stateMan = _FakeStateMan(served);
  await tester.pumpWidget(ProviderScope(
    overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
    child: MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: ChecklistColumn(title: 'Line 1', steps: steps),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return stateMan;
}

LEDConfig _step(String key, String text) => LEDConfig(key: key)..text = text;

void main() {
  testWidgets('counts the done steps and fills the bar to match',
      (tester) async {
    await _pump(
      tester,
      [
        _step('A', 'Wash down'),
        _step('B', 'Check guards'),
        _step('C', 'Belt on')
      ],
      served: {'A': true, 'B': true, 'C': false},
    );

    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(2 / 3, 1e-9));
    // A done step gets a check; the open one does not.
    expect(find.byIcon(Icons.check), findsNWidgets(2));
  });

  testWidgets('numbers the steps in order', (tester) async {
    await _pump(
      tester,
      [_step('A', 'one'), _step('B', 'two'), _step('C', 'three')],
      served: {'A': false, 'B': false, 'C': false},
    );
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('0 / 3'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('a done step steps back; an open one keeps the text colour',
      (tester) async {
    final theme = solarized().$2;
    await _pump(
      tester,
      [_step('A', 'done step'), _step('B', 'open step')],
      served: {'A': true, 'B': false},
      theme: theme,
    );
    final done = tester.widget<Text>(find.text('done step'));
    final open = tester.widget<Text>(find.text('open step'));
    final onSurface = theme.colorScheme.onSurface;
    // Muted is the same hue at lower alpha -- theme-derived, not a literal.
    expect(done.style!.color!.a, lessThan(1.0));
    expect(done.style!.color!.withValues(alpha: 1.0), onSurface);
    expect(open.style!.color, anyOf(isNull, onSurface));
  });

  testWidgets('a key the PLC refuses leaves the rest of the line working',
      (tester) async {
    await _pump(
      tester,
      [
        _step('A', 'served'),
        _step('Nope', 'unserved'),
        _step('B', 'served too')
      ],
      served: {'A': true, 'B': true},
    );
    // The refused step is unknown, not done; the others still count.
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNWidgets(2));
    expect(find.text('unserved'), findsOneWidget);
  });

  testWidgets('each key is read once, through the shared stream',
      (tester) async {
    final stateMan = await _pump(
      tester,
      [_step('A', 'a'), _step('B', 'b')],
      served: {'A': true, 'B': false},
    );
    // The LED is painted from the column's value, not subscribed again by
    // each row.
    expect(stateMan.subscribes, {'A': 1, 'B': 1});
  });

  testWidgets('a preview step is lit, an unbound one is unknown',
      (tester) async {
    await _pump(tester, [LEDConfig.preview()..text = 'p', _step('', 'blank')]);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('an empty line says so instead of showing nothing',
      (tester) async {
    await _pump(tester, const []);
    expect(find.text('No steps configured'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a complete line shows its count in the done colour',
      (tester) async {
    final theme = muted().$1;
    await _pump(
      tester,
      [_step('A', 'a'), _step('B', 'b')],
      served: {'A': true, 'B': true},
      theme: theme,
    );
    final count = tester.widget<Text>(find.text('2 / 2'));
    expect(count.style!.color, HmiStateColors.mutedLight.green);
  });

  testWidgets('the dialog shows all three lines, each with its own count',
      (tester) async {
    final stateMan = _FakeStateMan({'A': true, 'B': false});
    final config = ChecklistsConfig(
      line1: [_step('A', 'a'), _step('B', 'b')],
      line2: [_step('A', 'a')],
      line3: const [],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
                width: 200, height: 80, child: Checklists(config: config)),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(Checklists));
    await tester.pumpAndSettle();
    addTearDown(() {
      for (final id in FloatingDialogs.openIds) {
        closeFloatingDialog(id);
      }
    });

    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('Line 2'), findsOneWidget);
    expect(find.text('Line 3'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('No steps configured'), findsOneWidget);
    // Two lines read key A; it is one subscription, shared.
    expect(stateMan.subscribes['A'], 1);
  });
}
