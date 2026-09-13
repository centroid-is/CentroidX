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
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// The Run hours tile is fixed-width, and the counter it shows is unbounded.
/// A belt months past its last reset rendered `224:37`, which no longer fit
/// the tile and ellipsised to `224:…` — the operator saw three digits and a
/// mystery. These tests pin the fix: precision that falls with magnitude, so
/// the string fits the tile at any counter value.
void main() {
  group('formatRunTime', () {
    test('under an hour reads in minutes', () {
      expect(formatRunTime(0), (value: '0', unit: 'min'));
      expect(formatRunTime(59), (value: '59', unit: 'min'));
    });

    test('under a day reads hours and minutes', () {
      expect(formatRunTime(60), (value: '1:00', unit: 'h:m'));
      expect(formatRunTime(61), (value: '1:01', unit: 'h:m'));
      expect(formatRunTime(197), (value: '3:17', unit: 'h:m'));
      expect(formatRunTime(24 * 60 - 1), (value: '23:59', unit: 'h:m'));
    });

    test('a day and beyond reads whole hours, like an hour meter', () {
      expect(formatRunTime(24 * 60), (value: '24', unit: 'h'));
      // The counter that ellipsised in the field.
      expect(formatRunTime(224 * 60 + 37), (value: '224', unit: 'h'));
      // A decade-old belt still fits the tile.
      expect(formatRunTime(87600 * 60), (value: '87600', unit: 'h'));
    });
  });

  group('conveyor run hours golden',
      skip: goldenSkip, () {
    setUpAll(_loadRealFont);

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

    useTolerantGoldenComparator();

    // The regression case: a counter past a hundred hours, on a healthy
    // running belt so the tile is the only thing worth looking at.
    testWidgets('long-running belt shows whole hours, no ellipsis',
        (tester) async {
      await _openPane(
        tester,
        state: 4, // hmis_e.run
        runMode: 'auto',
        frequency: 42.5,
        current: 3.4,
        runMinutes: 224 * 60 + 37,
      );

      expect(find.text('224'), findsOneWidget);
      expect(find.text('h'), findsOneWidget);
      expect(find.textContaining('224:'), findsNothing);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_run_hours_long.png'),
      );
    });
  });
}

/// Loads real fonts so labels render as letterforms and icons as glyphs
/// rather than the test font's boxes — same as the drive status golden.
Future<void> _loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

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

/// The `run_mode_e` values the belt itself is painted from — the mimic reads
/// `p_stat_RunMode` by *name*, so a bare integer leaves the belt violet.
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
    this.runMode = 'stopped',
    this.frequency = 0.0,
    this.current = 0.0,
    this.runMinutes = 0,
  });

  final String driveKey;
  final int state;
  final String runMode;
  final double frequency;
  final double current;
  final int runMinutes;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key != driveKey) return const Stream<DynamicValue>.empty();
    final dv = DynamicValue();
    dv['p_stat_State'] = state;
    dv['p_stat_LastFault'] = 0;
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

Future<void> _openPane(
  WidgetTester tester, {
  required int state,
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
      collectorProvider.overrideWith((ref) async => null),
      stateManProvider.overrideWith(
        (ref) async => _DriveStateMan(
          driveKey: key,
          state: state,
          runMode: runMode,
          frequency: frequency,
          current: current,
          runMinutes: runMinutes,
        ),
      ),
    ],
    child: MaterialApp(
      theme: solarized().$1,
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
