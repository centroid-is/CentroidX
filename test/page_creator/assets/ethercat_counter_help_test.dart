// The info button in the subdevice pane's header, and the explanation it
// opens.
//
// The two counters the pane leads with — CRC and link loss — measure different
// faults and are easy to read as the same thing, so the pane carries the
// difference in words. These tests pin the affordance itself: that it is in
// the header, that it opens the explanation, and that a keyboard can reach and
// fire it, which is how a panel with no mouse gets at it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_ports.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice.dart';
import 'package:tfc/page_creator/assets/ethercat_subdevice_pane.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';

import 'ethercat_neutral_sample.dart';

Widget _frame(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 380, height: 620, child: child),
        ),
      ),
    );

Widget _pane() {
  final bus = neutralEcBus();
  return EcSubDevicePaneView(
    bus: bus,
    subdevice: bus.at(2),
    position: 2,
    plcLabel: 'PLC 1',
    onReset: (_) async {},
  );
}

/// The button's own focus node, reached through the [Focus] the [InkWell]
/// inside [IconButton] builds.
FocusNode _helpFocusNode(WidgetTester tester) {
  // Read from below the button's own [Focus] rather than off the widget: an
  // [IconButton] given no `focusNode` builds its own internally, so the
  // widget's field is null even though the node exists.
  final glyph = find.descendant(
    of: find.byKey(kEcCounterHelpKey),
    matching: find.byIcon(Icons.info_outline),
  );
  expect(glyph, findsOneWidget);
  final node = Focus.maybeOf(tester.element(glyph));
  expect(node, isNotNull,
      reason: 'the help button must own a focus node to be keyboard-reachable');
  return node!;
}

void main() {
  testWidgets('the pane header carries the info button', (tester) async {
    await tester.pumpWidget(_frame(_pane()));
    await tester.pumpAndSettle();

    expect(find.byKey(kEcCounterHelpKey), findsOneWidget);
    // In the header, not buried in the body.
    expect(
      find.descendant(
        of: find.byType(PaneHeader),
        matching: find.byKey(kEcCounterHelpKey),
      ),
      findsOneWidget,
    );
    // Above the first tile, and left of the close button: both are in the
    // header row, and the close button stays the rightmost thing in it.
    final help = tester.getRect(find.byKey(kEcCounterHelpKey));
    final close = tester.getRect(find.byIcon(Icons.close));
    final firstTile = tester.getRect(find.text('State').first);
    expect(help.right, lessThanOrEqualTo(close.left + 0.5));
    expect(help.bottom, lessThan(firstTile.top));
    // And it does not sit on top of the title or the subtitle.
    final title = tester.getRect(find.text('Drive 1'));
    expect(title.right, lessThanOrEqualTo(help.left + 0.5));

    // Nothing is shown until it is asked for.
    expect(find.byKey(kEcCounterHelpBodyKey), findsNothing);
  });

  testWidgets('tapping it explains both counters', (tester) async {
    await tester.pumpWidget(_frame(_pane()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kEcCounterHelpKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kEcCounterHelpBodyKey), findsOneWidget);
    expect(find.text('CRC and link loss'), findsOneWidget);
    // The substance: what each counter is, and what each one means on the
    // floor. Matched on the distinguishing clause rather than the whole
    // paragraph, so rewording the prose does not break the test.
    expect(find.textContaining('still up'), findsOneWidget);
    expect(find.textContaining('went down and came back'), findsOneWidget);
    expect(find.textContaining('loose or dirty connector'), findsOneWidget);
    expect(find.textContaining('not rates'), findsOneWidget);
    expect(find.textContaining('255'), findsOneWidget);
  });

  testWidgets('a keyboard can reach it and fire it', (tester) async {
    await tester.pumpWidget(_frame(_pane()));
    await tester.pumpAndSettle();

    final node = _helpFocusNode(tester);
    expect(node.canRequestFocus, isTrue);
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasPrimaryFocus, isTrue,
        reason: 'the button must take focus, not just accept taps');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(kEcCounterHelpBodyKey), findsOneWidget);
  });

  testWidgets('Tab traversal lands on it', (tester) async {
    await tester.pumpWidget(_frame(_pane()));
    await tester.pumpAndSettle();

    final node = _helpFocusNode(tester);
    // Ten is well past the handful of focusables a pane has; the point is that
    // ordinary traversal reaches it at all, not where in the order it sits.
    var reached = false;
    for (var i = 0; i < 10 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      reached = node.hasPrimaryFocus;
    }
    expect(reached, isTrue, reason: 'Tab must reach the help button');
  });

  testWidgets('the explanation renders in a dark theme too', (tester) async {
    await tester.pumpWidget(
        _frame(_pane(), theme: ThemeData.dark(useMaterial3: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(kEcCounterHelpKey));
    await tester.pumpAndSettle();

    expect(find.byKey(kEcCounterHelpBodyKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a subdevice that has gone still gets the explanation',
      (tester) async {
    final bus = neutralEcBus();
    await tester.pumpWidget(_frame(EcSubDevicePaneView(
      bus: bus,
      subdevice: null,
      position: 9,
      plcLabel: 'PLC 1',
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(kEcCounterHelpKey), findsOneWidget);
    await tester.tap(find.byKey(kEcCounterHelpKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kEcCounterHelpBodyKey), findsOneWidget);
  });

  // The pane the operator actually gets is an entry in the ROOT overlay, not a
  // widget in the page's own tree. A dialog pushed from there has to find a
  // Navigator or the button does nothing on the panel while every test above
  // still passes.
  testWidgets('it opens from a pane shown the way the app shows one',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        }),
      ),
    ));
    addTearDown(() => closeSidePane(immediate: true));

    showSidePane(
      context: ctx,
      id: 'ethercat-subdevice-test',
      builder: (_) => _pane(),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(kEcCounterHelpKey), findsOneWidget);

    await tester.tap(find.byKey(kEcCounterHelpKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kEcCounterHelpBodyKey), findsOneWidget);
    expect(find.text('CRC and link loss'), findsOneWidget);

    // And it closes again without taking the pane with it.
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    expect(find.byKey(kEcCounterHelpBodyKey), findsNothing);
    expect(find.byKey(kEcCounterHelpKey), findsOneWidget);
  });

  group('wording', () {
    test('the pane summary says link loss, not drops', () {
      const diag = EcSubDeviceDiag(
        deviceState: 8,
        linkState: 0,
        crcSum: 0,
        crcStableSeconds: 0,
        crcPort: [0, 0, 0, 0],
        linkLostPort: [2, 0, 0, 0],
      );
      final summary = ecSubDeviceSummary(diag);
      expect(summary, contains('been lost 2 times'));
      expect(summary.toLowerCase(), isNot(contains('drop')));
    });

    test('one loss is singular', () {
      const diag = EcSubDeviceDiag(
        deviceState: 8,
        linkState: 0,
        crcSum: 0,
        crcStableSeconds: 0,
        crcPort: [0, 0, 0, 0],
        linkLostPort: [1, 0, 0, 0],
      );
      expect(ecSubDeviceSummary(diag), contains('been lost 1 time since'));
    });

    testWidgets('the pane labels the tile and the reset button', (tester) async {
      await tester.pumpWidget(_frame(_pane()));
      await tester.pumpAndSettle();

      expect(find.text('Link loss'), findsOneWidget);
      expect(find.text('Clear link loss'), findsOneWidget);
      expect(find.textContaining('Drops'), findsNothing);
      expect(find.textContaining('drops'), findsNothing);
    });

    testWidgets('the port rows read "link loss"', (tester) async {
      await tester.pumpWidget(_frame(_pane()));
      await tester.pumpAndSettle();

      expect(find.textContaining('link loss'), findsWidgets);
    });
  });

  test('ecShownPorts still answers for the neutral sample', () {
    final bus = neutralEcBus();
    expect(ecShownPorts(bus, bus.at(2)!), contains(EcPort.a));
  });
}
