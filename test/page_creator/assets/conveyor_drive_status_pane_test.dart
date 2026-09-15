import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

/// The conveyor pane used to print the drive's two status words raw, which
/// on a live station reads as `rdY(2)` / `OCF(9)` — or, when the server does
/// not publish enum names, as a bare `2` / `9`. Neither tells an operator
/// standing at a stopped belt what is wrong or what to do.
///
/// These tests pin the decode (`p_stat_State` = `hmis_e`, `p_stat_LastFault`
/// = `lft_e`) and the behaviour around it: the rows say what they are in
/// operator words and keep the drive's own names, HMIS and LFT, in brackets,
/// and say the value as a keypad mnemonic plus words.
///
/// They also pin the live-vs-stored rule. HMIS is the drive's condition now;
/// LFT is a record that outlives the trip it describes. Every real LFT code
/// is a fault by nature, so colouring the row from the LFT's own severity
/// left it permanently red — including on a belt running perfectly well long
/// after a `Fault reset`.

/// Serves one drive struct on the conveyor's `key`.
class _DriveStateMan extends Fake implements StateMan {
  _DriveStateMan({
    required this.driveKey,
    required this.state,
    this.fault = 0,
    this.frequency = 0.0,
  });

  final String driveKey;
  final int state;
  final int fault;
  final double frequency;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key != driveKey) return const Stream<DynamicValue>.empty();
    final dv = DynamicValue();
    dv['p_stat_State'] = state;
    dv['p_stat_LastFault'] = fault;
    dv['p_stat_Frequency'] = frequency;
    dv['p_stat_Current'] = 0.0;
    dv['p_stat_RunMinutes'] = 0;
    dv['p_stat_JogFwd'] = false;
    dv['p_stat_JogBwd'] = false;
    dv['p_stat_ManualStopOnRelease'] = true;
    // The pane's setpoint fields read these directly; a struct without them
    // throws before anything renders.
    dv['p_cfg_ManualFreq'] = 20.0;
    dv['p_cfg_AutoFreq'] = 20.0;
    dv['p_cfg_CleaningFreq'] = 20.0;
    return Stream<DynamicValue>.value(dv);
  }

  @override
  Future<void> write(String key, DynamicValue value) async {}
}

Future<void> _openPane(
  WidgetTester tester, {
  required int state,
  int fault = 0,
  double frequency = 0.0,
}) async {
  const key = 'Line1.Belt2.Drive';
  final config = ConveyorConfig(key: key)
    ..size = const RelativeSize(width: 1.0, height: 1.0);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      // The pane's trend tile resolves the collector, which builds a real
      // Database with periodic timers and leaves them pending past the test.
      // Nothing here is about the trend, so cut it off at the provider.
      collectorProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith(
        (ref) async =>
            _DriveStateMan(
          driveKey: key,
          state: state,
          fault: fault,
          frequency: frequency,
        ),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 400, height: 80, child: Conveyor(config)),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(Conveyor));
  // Not pumpAndSettle: the pane's trend tile spins on a collector that never
  // resolves under a fake StateMan, so the frame never goes quiet. Two pumps
  // past the pane's slide-in is enough for everything under test.
  await _settlePane(tester);
}

/// Text inside a status row, as opposed to the same word in the header chip.
Finder _inRow(String text) => find.descendant(
      of: find.byType(PaneExplainRow),
      matching: find.text(text),
    );

/// Advances past the pane animation without waiting for the trend spinner.
Future<void> _settlePane(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The status row under a given label — `Status (HMIS)` or `Last fault
/// (LFT)`.
PaneExplainRow _row(WidgetTester tester, String label) =>
    tester.widgetList<PaneExplainRow>(find.byType(PaneExplainRow)).firstWhere(
          (row) => row.label == label,
        );

void main() {
  // A real station is a 1080p panel, and the default 800x600 test surface is
  // short enough that the pane's pinned action bar sits on top of the status
  // rows — taps aimed at a row land on 'Fault reset' instead.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    view.devicePixelRatio = 1.0;
    view.physicalSize = const Size(1200, 900);
  });

  tearDown(() {
    closeSidePane();
    TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
        .resetPhysicalSize();
  });

  testWidgets('a healthy drive reads in words, not codes', (tester) async {
    await _openPane(tester, state: 2); // hmis_e.rdy

    expect(find.text('RDY · Ready'), findsOneWidget);
    expect(find.text('NOF · No fault'), findsOneWidget);
    // The raw form the pane used to print.
    expect(find.textContaining('rdY('), findsNothing);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('the rows say what they are and keep the keypad names',
      (tester) async {
    await _openPane(tester, state: 2);

    // Operator words first — `Status`, `Last fault` — and the keypad name in
    // brackets: an electrician cross-references the keypad and NVE41295, and
    // those call the two parameters HMIS and LFT. Neither half may go.
    expect(find.text('Status (HMIS)'), findsOneWidget);
    expect(find.text('Last fault (LFT)'), findsOneWidget);
    expect(find.text('HMIS'), findsNothing);
    expect(find.text('LFT'), findsNothing);
  });

  testWidgets('the running state is named', (tester) async {
    await _openPane(tester, state: 4); // hmis_e.run
    expect(find.text('RUN · Running'), findsOneWidget);
  });

  testWidgets(
    'a trip names the fault and opens its explanation unprompted',
    (tester) async {
      // hmis_e.fault + lft_e.ocf — the belt tripped on overcurrent.
      await _openPane(tester, state: 23, fault: 9);

      // 'Faulted' also lands in the header chip, which is the point of the
      // header change — scope to the row.
      expect(_inRow('FLT · Faulted'), findsOneWidget);
      expect(find.text('OCF · Overcurrent'), findsOneWidget);

      // Auto-expanded: the operator should not have to discover the tap.
      expect(find.text('OCF'), findsOneWidget);
      expect(find.textContaining('more current than the drive allows'),
          findsOneWidget);
      // And the first thing it says is to check the belt, not to reset.
      expect(find.textContaining('Check the belt for a jam'), findsOneWidget);
    },
  );

  testWidgets(
    'a fault needing a power cycle says the reset button will not do it',
    (tester) async {
      await _openPane(tester, state: 23, fault: 24); // lft_e.sof — overspeed

      expect(find.text('SOF · Overspeed'), findsOneWidget);
      expect(
        find.textContaining('Fault reset will not clear this'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a resettable fault says so', (tester) async {
    await _openPane(tester, state: 23, fault: 17); // lft_e.olf

    expect(find.text('OLF · Motor overload'), findsOneWidget);
    expect(find.textContaining('Fault reset clears it'), findsOneWidget);
  });

  testWidgets(
    'the drive-state explanation is closed until it is asked for',
    (tester) async {
      await _openPane(tester, state: 3); // hmis_e.nst — freewheel

      expect(find.text('NST · Freewheel stop'), findsOneWidget);
      // The panel behind the row leads with the bare mnemonic and the code.
      expect(find.text('code 3'), findsNothing);

      await tester.tap(find.text('NST · Freewheel stop'));
      await _settlePane(tester);

      expect(find.text('code 3'), findsOneWidget);
      expect(find.textContaining('coasting'), findsOneWidget);
    },
  );

  // --- Live vs stored -------------------------------------------------------
  //
  // The regression this group exists for: every LFT code is intrinsically a
  // fault, so a row coloured from the LFT's own severity is red forever.

  testWidgets('a stored fault on a healthy drive is not painted as live',
      (tester) async {
    // The belt is running; the overcurrent it tripped on was reset hours ago
    // and LFT still remembers it. Nothing is wrong now.
    await _openPane(
      tester,
      state: 4, // hmis_e.run
      fault: 9, // lft_e.ocf
      frequency: 42.0,
    );

    final lft = _row(tester, 'Last fault (LFT)');
    expect(lft.value, 'OCF · Overcurrent');
    expect(lft.valueColor, isNull, reason: 'history must not read as a trip');
    expect(lft.valueNote, 'cleared');

    // And it does not shout for attention on its own.
    expect(lft.initiallyExpanded, isFalse);

    final chip = tester.widget<PaneStatusChip>(find.byType(PaneStatusChip));
    expect(chip.status.label, 'Running');
  });

  testWidgets('a stored fault says it already happened', (tester) async {
    await _openPane(tester, state: 4, fault: 9);

    // By the label: with the `cleared` note the value is a span tree, not a
    // single string.
    await tester.tap(find.text('Last fault (LFT)'));
    await _settlePane(tester);

    expect(
      find.textContaining('the drive is not faulted now'),
      findsOneWidget,
    );
  });

  testWidgets('the same fault is red while the drive is in it', (tester) async {
    await _openPane(tester, state: 23, fault: 9); // hmis_e.fault + lft_e.ocf

    final lft = _row(tester, 'Last fault (LFT)');
    expect(lft.value, 'OCF · Overcurrent');
    expect(lft.valueColor, isNotNull);
    expect(lft.valueNote, isNull);
    expect(lft.initiallyExpanded, isTrue);
  });

  testWidgets('a drive that never tripped carries no marker', (tester) async {
    await _openPane(tester, state: 2); // hmis_e.rdy, LFT = NOF

    final lft = _row(tester, 'Last fault (LFT)');
    expect(lft.valueColor, isNull);
    expect(lft.valueNote, isNull, reason: 'nothing to clear');
  });

  testWidgets('a lost link keeps its paired fault live', (tester) async {
    // hmis_e 99 is FB_ATV320's own substitute, not a drive trip — but it is a
    // fault-severity state and CNF is published with it, so the pair reads as
    // one live condition rather than as a cleared record.
    await _openPane(tester, state: 99, fault: 7);

    final lft = _row(tester, 'Last fault (LFT)');
    expect(lft.valueColor, isNotNull);
    expect(lft.valueNote, isNull);
  });

  testWidgets('a lost EtherCAT link is not blamed on the drive',
      (tester) async {
    // What FB_ATV320 publishes when it cannot reach the slave: the made-up
    // state 99 paired with a CNF last fault.
    await _openPane(tester, state: 99, fault: 7);

    expect(_inRow('LOST · No link to drive'), findsOneWidget);

    // The fault row auto-opens on CNF, and what it says matters: an
    // electrician must not go looking for a fieldbus fault inside a drive
    // the PLC simply cannot see.
    expect(find.textContaining('not a fault inside the drive'), findsOneWidget);

    await tester.tap(_inRow('LOST · No link to drive'));
    await _settlePane(tester);
    expect(find.textContaining('cannot reach this drive over EtherCAT'),
        findsOneWidget);
  });

  testWidgets('a faulted drive does not present itself as merely stopped',
      (tester) async {
    await _openPane(tester, state: 23, fault: 9);

    final chip = tester.widget<PaneStatusChip>(find.byType(PaneStatusChip));
    expect(chip.status.label, 'Faulted');
  });

  testWidgets('STO shows in the header as a safety hold, not a trip',
      (tester) async {
    await _openPane(tester, state: 30);

    final chip = tester.widget<PaneStatusChip>(find.byType(PaneStatusChip));
    expect(chip.status.label, 'Safe Torque Off');
    expect(chip.status.icon, Icons.warning_amber);
  });

  testWidgets('a healthy stopped belt still reads as stopped', (tester) async {
    await _openPane(tester, state: 2);

    final chip = tester.widget<PaneStatusChip>(find.byType(PaneStatusChip));
    expect(chip.status.label, 'Stopped');
  });
}
