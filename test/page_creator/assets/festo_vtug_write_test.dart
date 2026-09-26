import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';
import 'package:tfc/page_creator/assets/common.dart' show RelativeSize;
import 'package:tfc/page_creator/assets/festo.dart';
import 'package:tfc/page_creator/assets/vtug.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The write path, end to end: tap the terminal on a page, act in the pane,
/// and check what actually reaches `StateMan.write`.
///
/// `vtug_test.dart` proves the word arithmetic in isolation. This file
/// proves the arithmetic is what the asset sends — the two are different
/// claims, and the gap between them is where a pane wires a button to the
/// wrong position or writes the value word without the mask.
///
/// The thing being guarded hardest is release. A momentary push that writes
/// its press but drops its release leaves a solenoid energised with nothing
/// on screen holding it, and it does so silently: the drawing would show the
/// coil lit and the operator would read that as the PLC's doing.
void main() {
  const key = 'ST301.ECT.ST303_A1';

  Widget wrap(Widget child, _FakeStateMan stateMan) => ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => stateMan),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: const [HmiStateColors.solarizedLight],
          ),
          home: Scaffold(
            body: SidePaneInset(
              child: Center(child: child),
            ),
          ),
        ),
      );

  /// A terminal whose population the assertions can rely on.
  ///
  /// Spelled out rather than taken from the default, which is the manifold
  /// as ordered — five 5/2s then three 5/3s. These tests are about the word
  /// arithmetic reaching `StateMan`, and a default that changes when
  /// somebody re-reads the parts list should not silently change what they
  /// assert.
  FestoVTUGConfig config({
    VtugValveKind kind = VtugValveKind.valve53Closed,
  }) =>
      FestoVTUGConfig(
        nameOrId: 'ST303.A1',
        stateKey: key,
        slices: [
          for (var i = 0; i < vtugPositionCount; i++)
            VtugSliceConfig(kind: kind),
        ],
      )..size = RelativeSize(width: 0.9, height: 0.4);

  /// Pumps the asset, lets the StateMan future land, pushes one struct, and
  /// opens the pane.
  /// A surface tall enough to hold a full manifold's pane.
  ///
  /// Eight status rows and eight force rows do not fit the 800x600 default,
  /// and a control below that fold is one `tap` lands on the root render
  /// view instead of the button — a failure about the test surface, not
  /// about the asset. The stations this runs on are 1080 tall or better.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> openPane(
    WidgetTester tester,
    FestoVTUGConfig asset,
    _FakeStateMan stateMan, {
    int coils = 0,
    int forceMask = 0,
    int forceValue = 0,
  }) async {
    useTallSurface(tester);
    await tester.pumpWidget(wrap(
      Builder(builder: (context) => asset.build(context)),
      stateMan,
    ));
    await tester.pumpAndSettle();

    stateMan.push(
      key,
      coils: coils,
      forceMask: forceMask,
      forceValue: forceValue,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
  }

  testWidgets('tapping the terminal opens its pane', (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    expect(find.text('ST303.A1'), findsWidgets);
    expect(find.text('VALVES'), findsOneWidget);
    expect(find.text('FORCE'), findsOneWidget);
    addTearDown(closeSidePane);
  });

  testWidgets('Port 4 on position 1 writes both command words',
      (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    addTearDown(closeSidePane);

    await tester.tap(find.text('Port 4').first);
    await tester.pumpAndSettle();

    expect(stateMan.writes, hasLength(1));
    final write = stateMan.writes.single;
    expect(write.key, key);
    // Position 1 is bits 0 and 1: both taken, coil 14 driven.
    expect(write.forceMask, 0x3);
    expect(write.forceValue, 0x1);
  });

  testWidgets('Centre on a 5/3 takes both coils and drives neither',
      (tester) async {
    // The command a 5/3 exists for, and the one that has no equivalent on a
    // 5/2: both coils off, spring centres the valve, both work ports
    // blocked.
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    addTearDown(closeSidePane);

    await tester.tap(find.text('Centre').first);
    await tester.pumpAndSettle();

    final write = stateMan.writes.single;
    expect(write.forceMask, 0x3);
    expect(write.forceValue, 0);
  });

  testWidgets('a monostable offers no Centre at all', (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(
      tester,
      config(kind: VtugValveKind.valve52Mono),
      stateMan,
    );
    addTearDown(closeSidePane);

    expect(find.text('Centre'), findsNothing,
        reason: 'a segment that does nothing when pressed is worse than an '
            'absent one');

    // And port 2 on that valve is its one coil held OFF, not a second coil
    // driven on.
    await tester.tap(find.text('Port 2').first);
    await tester.pumpAndSettle();
    final write = stateMan.writes.single;
    expect(write.forceMask, 0x1);
    expect(write.forceValue, 0);
  });

  testWidgets('a force applies over the words already in effect',
      (tester) async {
    final stateMan = _FakeStateMan();
    // Position 1 already held open when the pane opens.
    await openPane(tester, config(), stateMan,
        forceMask: 0x3, forceValue: 0x1);
    addTearDown(closeSidePane);

    // Drive position 2 to port 2 — bits 2 and 3.
    await tester.tap(find.text('Port 2').at(1));
    await tester.pumpAndSettle();

    final write = stateMan.writes.single;
    expect(write.forceMask, 0x3 | 0xC,
        reason: 'forcing one position must not release another');
    expect(write.forceValue, 0x1 | 0x8);
  });

  testWidgets('a push writes on the way down and releases on the way up',
      (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    addTearDown(closeSidePane);

    final button = find.byType(VtugPushButton).first;
    final gesture = await tester.press(button);
    await tester.pumpAndSettle();

    expect(stateMan.writes, hasLength(1));
    expect(stateMan.writes.last.forceMask, 0x1);
    expect(stateMan.writes.last.forceValue, 0x1);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(stateMan.writes, hasLength(2));
    expect(stateMan.writes.last.forceMask, 0,
        reason: 'a released push must hand the coil back');
    expect(stateMan.writes.last.forceValue, 0);
  });

  testWidgets('a push takes only its own coil, leaving a hold elsewhere '
      'alone', (tester) async {
    final stateMan = _FakeStateMan();
    // Position 1 held open.
    await openPane(tester, config(), stateMan,
        forceMask: 0x3, forceValue: 0x1);
    addTearDown(closeSidePane);

    // The second position's `12` button — bit 3.
    final gesture = await tester.press(find.byType(VtugPushButton).at(3));
    await tester.pumpAndSettle();

    final write = stateMan.writes.single;
    expect(write.forceMask, 0x3 | 0x8);
    expect(write.forceValue, 0x1 | 0x8);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(stateMan.writes.last.forceMask, 0x3,
        reason: 'releasing the push must leave position 1 still held');
    expect(stateMan.writes.last.forceValue, 0x1);
  });

  testWidgets('Release all clears both words', (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan,
        forceMask: 0xF, forceValue: 0x5);
    addTearDown(closeSidePane);

    await tester.tap(find.byKey(const Key('vtug-release-all')));
    await tester.pumpAndSettle();

    final write = stateMan.writes.single;
    expect(write.forceMask, 0);
    expect(write.forceValue, 0);
  });

  testWidgets('Release all is disabled when nothing is held', (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    addTearDown(closeSidePane);

    await tester.tap(find.byKey(const Key('vtug-release-all')));
    await tester.pumpAndSettle();
    expect(stateMan.writes, isEmpty,
        reason: 'writing zeros over zeros teaches an operator that the '
            'button does nothing');
  });

  testWidgets('the write leaves the PLC-owned members of the struct alone',
      (tester) async {
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan, coils: 0x0A);
    addTearDown(closeSidePane);

    await tester.tap(find.text('Port 4').first);
    await tester.pumpAndSettle();

    final sent = stateMan.writes.single.struct;
    expect(sent['p_stat_Coils'].asInt, 0x0A,
        reason: 'the command write must carry the status members back '
            'unchanged, not zero them');
  });

  testWidgets('with no state key nothing is written and the pane says so',
      (tester) async {
    final stateMan = _FakeStateMan();
    final asset = FestoVTUGConfig(nameOrId: 'ST303.A1')
      ..size = RelativeSize(width: 0.9, height: 0.4);

    useTallSurface(tester);
    await tester.pumpWidget(wrap(
      Builder(builder: (context) => asset.build(context)),
      stateMan,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    addTearDown(closeSidePane);

    expect(find.textContaining('No command keys are configured'),
        findsOneWidget);
    expect(stateMan.writes, isEmpty);
  });

  testWidgets('the pane goes when the asset does', (tester) async {
    // A pane left in the root overlay after a page change would keep
    // writing to a terminal that is no longer on screen.
    final stateMan = _FakeStateMan();
    await openPane(tester, config(), stateMan);
    expect(find.text('VALVES'), findsOneWidget);

    await tester.pumpWidget(wrap(const SizedBox.shrink(), stateMan));
    await tester.pumpAndSettle();
    expect(find.text('VALVES'), findsNothing);
  });
}

class _FakeStateMan implements StateMan {
  final Map<String, BehaviorSubject<DynamicValue>> _streams = {};
  final List<_Write> writes = [];

  void push(
    String key, {
    int coils = 0,
    int forceMask = 0,
    int forceValue = 0,
  }) {
    final dv = DynamicValue();
    dv['p_stat_Coils'] = coils;
    dv['p_stat_Forced'] = 0;
    dv['p_cmd_Force'] = forceMask;
    dv['p_cmd_Value'] = forceValue;
    _streams
        .putIfAbsent(key, () => BehaviorSubject<DynamicValue>())
        .add(dv);
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async =>
      _streams.putIfAbsent(key, () => BehaviorSubject<DynamicValue>()).stream;

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add(_Write(key, value));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStateMan: ${invocation.memberName} not implemented in test scope',
    );
  }
}

class _Write {
  _Write(this.key, this.struct);

  final String key;
  final DynamicValue struct;

  int get forceMask => struct['p_cmd_Force'].asInt;
  int get forceValue => struct['p_cmd_Value'].asInt;
}
