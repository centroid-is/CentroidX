import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Widget tests for the gate force pane, which offers a different control
/// per variant.
///
/// A diverter or slider is *held* in a position, so it keeps the tri-state
/// Open / None / Close selector. A pusher runs a stroke and returns by
/// itself, so it gets a single press-and-hold button instead.
///
/// Contract under test — selector (diverter / slider):
///   - tap on the gate opens the SidePane with the three force segments
///   - 'None' writes false to BOTH force keys (the unforce path — the old
///     two-button pane could only ever write true)
///   - 'Open' clears force-close BEFORE setting force-open (and vice versa)
///     so the PLC never sees both force commands high at once
///   - segment selection tracks the feedback keys; without feedback keys no
///     segment is highlighted
///   - a segment whose write key is unconfigured is disabled, and 'None'
///     only writes the keys that exist
///
/// Contract under test — hold button (pusher):
///   - no selector at all; one button that writes TRUE down, FALSE up
///   - releasing must be unconditional: tap-cancel (a drag off the button)
///     and dispose (the pane closing mid-press) both write FALSE, because
///     either one otherwise strands the pusher driven out
///   - the header reads Out / In, not Open / Closed, and never claims a
///     held force — the pusher's command bit is momentary
void main() {
  Widget wrap({
    required Widget child,
    List<Override> overrides = const [],
  }) {
    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Future<void> openPane(WidgetTester tester) async {
    await tester.tap(find.byType(ConveyorGate));
    await tester.pumpAndSettle();
  }

  Finder forceSegmented() => find.byWidgetPredicate(
        (w) => w is SegmentedButton && w.segments.length == 3,
      );

  // The pane chrome has its own 'Close' text, so segment lookups must be
  // scoped to the SegmentedButton.
  Finder segmentText(String label) => find.descendant(
        of: forceSegmented(),
        matching: find.text(label),
      );

  tearDown(closeSidePane);

  ConveyorGateConfig gateConfig({
    GateVariant variant = GateVariant.pneumatic,
    String stateKey = '',
    String openKey = 'gate/force_open',
    String closeKey = 'gate/force_close',
    String openFbKey = '',
    String closeFbKey = '',
  }) {
    return ConveyorGateConfig(
      gateVariant: variant,
      stateKey: stateKey,
      forceOpenKey: openKey,
      forceCloseKey: closeKey,
      forceOpenFeedbackKey: openFbKey,
      forceCloseFeedbackKey: closeFbKey,
    );
  }

  /// The selector belongs to the held variants; a pusher has the hold button.
  ConveyorGateConfig diverterConfig({
    String stateKey = '',
    String openKey = 'gate/force_open',
    String closeKey = 'gate/force_close',
    String openFbKey = '',
    String closeFbKey = '',
  }) =>
      gateConfig(
        variant: GateVariant.pneumatic,
        stateKey: stateKey,
        openKey: openKey,
        closeKey: closeKey,
        openFbKey: openFbKey,
        closeFbKey: closeFbKey,
      );

  ConveyorGateConfig pusherConfig({
    String stateKey = '',
    String openKey = 'gate/force_open',
    String closeKey = 'gate/force_close',
    String openFbKey = '',
    String closeFbKey = '',
  }) =>
      gateConfig(
        variant: GateVariant.pusher,
        stateKey: stateKey,
        openKey: openKey,
        closeKey: closeKey,
        openFbKey: openFbKey,
        closeFbKey: closeFbKey,
      );

  Widget gate(ConveyorGateConfig config, _FakeStateMan fake) {
    return wrap(
      overrides: [stateManProvider.overrideWith((_) async => fake)],
      child: SizedBox(
        width: 100,
        height: 100,
        child: ConveyorGate(config: config),
      ),
    );
  }

  group('force pane segments', () {
    testWidgets('tap on gate opens pane with Open / None / Close',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(), fake));
      await openPane(tester);

      expect(find.byType(SidePane), findsOneWidget);
      expect(forceSegmented(), findsOneWidget);
      expect(segmentText('Open'), findsOneWidget);
      expect(segmentText('None'), findsOneWidget);
      expect(segmentText('Close'), findsOneWidget);
    });

    testWidgets('None writes false to both force keys (unforce)',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(), fake));
      await openPane(tester);

      await tester.tap(segmentText('None'));
      await tester.pump();

      expect(
        fake.writes.map((w) => (w.key, w.value)),
        containsAll([
          ('gate/force_open', false),
          ('gate/force_close', false),
        ]),
      );
      expect(fake.writes.any((w) => w.value), isFalse,
          reason: 'None must never assert a force');
    });

    testWidgets('Open clears force-close before asserting force-open',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(), fake));
      await openPane(tester);

      await tester.tap(segmentText('Open'));
      await tester.pump();

      expect(
        fake.writes.map((w) => (w.key, w.value)).toList(),
        [
          ('gate/force_close', false),
          ('gate/force_open', true),
        ],
      );
    });

    testWidgets('Close clears force-open before asserting force-close',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(), fake));
      await openPane(tester);

      await tester.tap(segmentText('Close'));
      await tester.pump();

      expect(
        fake.writes.map((w) => (w.key, w.value)).toList(),
        [
          ('gate/force_open', false),
          ('gate/force_close', true),
        ],
      );
    });
  });

  group('feedback-driven selection', () {
    testWidgets('open feedback highlights the Open segment', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/fo_fb', true);
      fake.push('gate/fc_fb', false);
      await tester.pumpWidget(gate(
        diverterConfig(openFbKey: 'gate/fo_fb', closeFbKey: 'gate/fc_fb'),
        fake,
      ));
      await openPane(tester);

      final seg = tester.widget<SegmentedButton>(forceSegmented());
      expect(seg.selected.length, 1);
      expect(seg.selected.first.toString(), endsWith('.open'));
    });

    testWidgets('no feedback active highlights None', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/fo_fb', false);
      fake.push('gate/fc_fb', false);
      await tester.pumpWidget(gate(
        diverterConfig(openFbKey: 'gate/fo_fb', closeFbKey: 'gate/fc_fb'),
        fake,
      ));
      await openPane(tester);

      final seg = tester.widget<SegmentedButton>(forceSegmented());
      expect(seg.selected.length, 1);
      expect(seg.selected.first.toString(), endsWith('.none'));
    });

    testWidgets('without feedback keys no segment is highlighted',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(), fake));
      await openPane(tester);

      final seg = tester.widget<SegmentedButton>(forceSegmented());
      expect(seg.selected, isEmpty,
          reason: 'force state is unknown without feedback keys — '
              'the selector must not claim None');
    });
  });

  group('partial key configuration', () {
    testWidgets('missing close key disables Close; None writes only open key',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(diverterConfig(closeKey: ''), fake));
      await openPane(tester);

      final seg = tester.widget<SegmentedButton>(forceSegmented());
      expect(seg.segments[2].enabled, isFalse,
          reason: 'Close segment must be disabled without a close key');

      await tester.tap(segmentText('None'));
      await tester.pump();

      expect(
        fake.writes.map((w) => (w.key, w.value)).toList(),
        [('gate/force_open', false)],
        reason: 'unforce must skip unconfigured keys',
      );
    });
  });

  group('pusher hold-to-push button', () {
    Finder holdButton() => find.text('Press to push');

    testWidgets('a pusher gets one hold button, not the three segments',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(pusherConfig(), fake));
      await openPane(tester);

      expect(find.byType(SidePane), findsOneWidget);
      expect(holdButton(), findsOneWidget);
      expect(forceSegmented(), findsNothing,
          reason: 'a pusher has no position to hold, so the Open / None / '
              'Close selector must not be offered for it');
    });

    testWidgets('held writes true, released writes false', (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(pusherConfig(), fake));
      await openPane(tester);

      final press = await tester.startGesture(tester.getCenter(holdButton()));
      await tester.pump();
      expect(fake.writes.map((w) => (w.key, w.value)).toList(),
          [('gate/force_open', true)],
          reason: 'the bit must go high on the press, not on the release');
      expect(find.text('Pushing'), findsOneWidget,
          reason: 'the label must show the operator the pusher is driven');

      await press.up();
      await tester.pump();
      expect(fake.writes.map((w) => (w.key, w.value)).toList(), [
        ('gate/force_open', true),
        ('gate/force_open', false),
      ]);
      expect(find.text('Press to push'), findsOneWidget);
    });

    testWidgets('dragging off the button releases it', (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(pusherConfig(), fake));
      await openPane(tester);

      final press = await tester.startGesture(tester.getCenter(holdButton()));
      await tester.pump();

      // Far enough to take the tap out of the arena, which is what a finger
      // sliding off the button does. Cancel must release, or the pusher is
      // stranded out with the UI showing it idle.
      await press.moveBy(const Offset(0, 400));
      await tester.pump();
      await press.up();
      await tester.pump();

      expect(fake.writes.map((w) => (w.key, w.value)).toList(), [
        ('gate/force_open', true),
        ('gate/force_open', false),
      ]);
      expect(find.text('Press to push'), findsOneWidget);
    });

    testWidgets('closing the pane mid-press releases the pusher',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(pusherConfig(), fake));
      await openPane(tester);

      final press = await tester.startGesture(tester.getCenter(holdButton()));
      await tester.pump();
      expect(fake.writes.last.value, isTrue);

      // The operator closes the pane without lifting their finger. Nothing
      // left in the tree could write the bit back down, so dispose has to.
      closeSidePane();
      await tester.pumpAndSettle();

      expect(fake.writes.map((w) => (w.key, w.value)).toList(), [
        ('gate/force_open', true),
        ('gate/force_open', false),
      ]);

      await press.up();
    });

    testWidgets('without a force-open key the button writes nothing',
        (tester) async {
      final fake = _FakeStateMan();
      await tester.pumpWidget(gate(pusherConfig(openKey: ''), fake));
      await openPane(tester);

      final press = await tester.startGesture(tester.getCenter(holdButton()));
      await tester.pump();
      await press.up();
      await tester.pump();

      expect(fake.writes, isEmpty,
          reason: 'an unconfigured force key must disable the button, '
              'not write to the empty key');
      expect(find.text('Pushing'), findsNothing);
    });
  });

  group('pane header', () {
    testWidgets('active open force shows a Forced open chip', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', true);
      fake.push('gate/fo_fb', true);
      fake.push('gate/fc_fb', false);
      await tester.pumpWidget(gate(
        diverterConfig(
          stateKey: 'gate/state',
          openFbKey: 'gate/fo_fb',
          closeFbKey: 'gate/fc_fb',
        ),
        fake,
      ));
      await openPane(tester);

      expect(
        find.descendant(
          of: find.byType(PaneStatusChip),
          matching: find.text('Forced open'),
        ),
        findsOneWidget,
        reason: 'an active force must be visible in the header, '
            'not only as a segment highlight',
      );
    });

    testWidgets('plain open state shows an Open chip', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', true);
      fake.push('gate/fo_fb', false);
      fake.push('gate/fc_fb', false);
      await tester.pumpWidget(gate(
        diverterConfig(
          stateKey: 'gate/state',
          openFbKey: 'gate/fo_fb',
          closeFbKey: 'gate/fc_fb',
        ),
        fake,
      ));
      await openPane(tester);

      expect(
        find.descendant(
          of: find.byType(PaneStatusChip),
          matching: find.text('Open'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a pusher reads Out / In, not Open / Closed', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', true);
      await tester.pumpWidget(
          gate(pusherConfig(stateKey: 'gate/state'), fake));
      await openPane(tester);

      Finder chip(String label) => find.descendant(
            of: find.byType(PaneStatusChip),
            matching: find.text(label),
          );
      expect(chip('Out'), findsOneWidget,
          reason: 'a pusher strokes out and back; Open/Closed describes a '
              'gate that is held in a position');
      expect(chip('Open'), findsNothing);
    });

    testWidgets('a pusher never claims a held force in the header',
        (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', false);
      fake.push('gate/fo_fb', true);
      fake.push('gate/fc_fb', false);
      await tester.pumpWidget(gate(
        pusherConfig(
          stateKey: 'gate/state',
          openFbKey: 'gate/fo_fb',
          closeFbKey: 'gate/fc_fb',
        ),
        fake,
      ));
      await openPane(tester);

      expect(
        find.descendant(
          of: find.byType(PaneStatusChip),
          matching: find.text('Forced open'),
        ),
        findsNothing,
        reason: "the pusher's command bit is momentary — a Forced open chip "
            'would flash for one PLC cycle and then lie',
      );
      expect(
        find.descendant(
          of: find.byType(PaneStatusChip),
          matching: find.text('In'),
        ),
        findsOneWidget,
        reason: 'the state key is the only honest thing to show',
      );
    });

    testWidgets('subtitle is the variant, never the raw key', (tester) async {
      final fake = _FakeStateMan();
      fake.push('gate/state', false);
      await tester.pumpWidget(gate(
        pusherConfig(stateKey: 'gate/state'),
        fake,
      ));
      await openPane(tester);

      expect(find.text('Pusher gate'), findsOneWidget);
      expect(find.text('gate/state'), findsNothing,
          reason: 'panes show values, not wiring — '
              'no raw OPC UA key names in the pane');
    });
  });
}

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<_Write> writes = [];

  void push(String key, bool value) {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    s.add(DynamicValue(value: value, typeId: NodeId.boolean));
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final s = _streams.putIfAbsent(
      key,
      () => BehaviorSubject<DynamicValue>(),
    );
    return s.stream;
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add(_Write(key, value.asBool));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}

class _Write {
  final String key;
  final bool value;
  _Write(this.key, this.value);
}
