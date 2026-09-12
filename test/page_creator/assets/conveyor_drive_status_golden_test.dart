import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart'
    show DynamicValue, EnumField, LocalizedText;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Goldens of the conveyor pane's HMIS and LFT rows — the keypad mnemonic and
/// the words behind it, and the explanation panel behind those.
///
/// Three scenarios, because the design has three halves to get wrong:
///
///  * a live trip — LFT red, opened unprompted, with a reset class and a
///    remedy;
///  * a stored trip on a belt that is running fine — the same fault code, but
///    history: no alarm ink, marked `cleared`, closed;
///  * a healthy-but-puzzling state — closed until asked, nothing red.
///
/// The middle one is the regression these goldens exist to hold: every LFT
/// code is a fault by nature, so a row coloured from the LFT's own severity
/// was red permanently.
///
/// The app's own theme is registered rather than a bare `MaterialApp`. Without
/// it the pane renders in Flutter's default Material palette and
/// `HmiStateColors` comes from the fallback, so a golden of a colour change
/// would be a golden of the wrong colours.

/// Loads real fonts so labels render as letterforms and icons as glyphs
/// rather than the test font's boxes — same as the gate force pane golden.
Future<void> loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

  // Under the app theme the family is asked for by name; a bare MaterialApp
  // asks for Roboto. Register both so the golden never falls back to the test
  // font's boxes.
  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont(
      'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  for (final candidate in <String>[
    if (flutterRoot != null)
      '$flutterRoot/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
  ]) {
    if (File(candidate).existsSync()) {
      await loadFont('MaterialIcons', candidate);
      break;
    }
  }
}

/// The `run_mode_e` values the belt itself is painted from, as an OPC UA enum
/// — the mimic reads `p_stat_RunMode` by *name*, so a bare integer leaves the
/// belt violet ("nothing known about this drive") no matter what HMIS says.
DynamicValue _runMode(String name) {
  const names = ['stopped', 'auto', 'manual', 'clean', 'fault'];
  final dv = DynamicValue(value: names.indexOf(name));
  dv.enumFields = {
    for (var i = 0; i < names.length; i++)
      i: EnumField(i, names[i], LocalizedText(names[i], 'en'),
          LocalizedText('', 'en')),
  };
  return dv;
}

class _DriveStateMan extends Fake implements StateMan {
  _DriveStateMan({
    required this.driveKey,
    required this.state,
    this.fault = 0,
    this.runMode = 'stopped',
    this.frequency = 0.0,
    this.current = 0.0,
    this.runMinutes = 0,
  });

  final String driveKey;
  final int state;
  final int fault;
  final String runMode;
  final double frequency;
  final double current;
  final int runMinutes;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key != driveKey) return const Stream<DynamicValue>.empty();
    final dv = DynamicValue();
    dv['p_stat_State'] = state;
    dv['p_stat_LastFault'] = fault;
    dv['p_stat_RunMode'] = _runMode(runMode);
    dv['p_stat_Frequency'] = frequency;
    dv['p_stat_Current'] = current;
    dv['p_stat_RunMinutes'] = runMinutes;
    dv['p_stat_JogFwd'] = false;
    dv['p_stat_JogBwd'] = false;
    dv['p_stat_ManualStopOnRelease'] = true;
    dv['p_cfg_ManualFreq'] = 20.0;
    dv['p_cfg_AutoFreq'] = 20.0;
    dv['p_cfg_CleaningFreq'] = 20.0;
    return Stream<DynamicValue>.value(dv);
  }

  @override
  Future<void> write(String key, DynamicValue value) async {}
}

void main() {
  // Full app surface with real text; same reasoning as the gate force pane
  // golden — the default tolerance is too tight for text antialiasing drift,
  // while a real regression moves far more than 0.2% of the frame.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('conveyor drive status golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);

    setUp(() {
      // A station panel, not the 800x600 default: the pinned action bar
      // otherwise sits on top of the very rows being goldened.
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

    // Solarized light: the app's default scheme, and the one that carries the
    // `HmiStateColors` extension the status rows and the belt are painted
    // from.
    final (light, _) = solarized();

    Future<void> openPane(
      WidgetTester tester, {
      required int state,
      int fault = 0,
      String runMode = 'stopped',
      double frequency = 0.0,
      double current = 0.0,
      int runMinutes = 0,
    }) async {
      const key = 'CN04.Belt.Drive';
      final config = ConveyorConfig(key: key)
        ..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          // The pane's trend tile resolves the collector, which builds a real
          // Database with periodic timers and leaves them pending past the test.
          // Nothing here is about the trend, so cut it off at the provider.
          collectorProvider.overrideWith((ref) async => null),
          stateManProvider.overrideWith(
            (ref) async => _DriveStateMan(
              driveKey: key,
              state: state,
              fault: fault,
              runMode: runMode,
              frequency: frequency,
              current: current,
              runMinutes: runMinutes,
            ),
          ),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 80, child: Conveyor(config)),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Conveyor));
      // Not pumpAndSettle — the trend tile spins forever on a fake StateMan.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('tripped on overcurrent, explanation open', (tester) async {
      await openPane(
        tester,
        state: 23, // hmis_e.fault
        fault: 9, // lft_e.ocf
        runMode: 'fault',
        runMinutes: 197,
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_drive_status_fault.png'),
      );
    });

    // The complaint this branch answers: same OCF(9), belt running, nothing
    // wrong. The LFT row must read as a record of what happened, not as a
    // trip in progress.
    testWidgets('running with a fault already cleared', (tester) async {
      await openPane(
        tester,
        state: 4, // hmis_e.run
        fault: 9, // lft_e.ocf — reset hours ago, still remembered
        runMode: 'auto',
        frequency: 42.5,
        current: 3.4,
        runMinutes: 197,
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_drive_status_cleared.png'),
      );
    });

    testWidgets('freewheel stop, explanation opened by the operator',
        (tester) async {
      await openPane(tester, state: 3); // hmis_e.nst

      await tester.tap(find.descendant(
        of: find.byType(PaneExplainRow),
        matching: find.text('NST · Freewheel stop'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Let the tap's ink highlight fade, so the golden shows the row at
      // rest rather than mid-splash.
      await tester.pump(const Duration(seconds: 1));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_drive_status_freewheel.png'),
      );
    });
  });
}
