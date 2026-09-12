import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/el9222.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Goldens of the EL9222 overcurrent protection terminal.
///
/// The asset used to be a drawing — six lamps hardcoded to `IOState.low`, no
/// subscription, no tap target — so a tripped breaker looked exactly like a
/// healthy one. These pin what an operator now sees, which is the whole point
/// of the change and the part no widget test can assert:
///
///  * the FACE, where the only question is "which channel is out"; and
///  * the PANE, in the two states that decide what the operator can do — a
///    channel that is out and resettable, and the same channel still inside
///    its cool-down period, where the button is dead and says why.
///
/// The app's own theme is registered rather than a bare `MaterialApp`: without
/// it `HmiStateColors` comes from the fallback, so a golden of the diode
/// colours would be a golden of the wrong colours.

/// Loads real fonts so labels render as letterforms and icons as glyphs
/// rather than the test font's boxes.
Future<void> loadRealFont() async {
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

const _stateKey = 'ST101.ECT.ST101_A1_02';
const _descriptionsKey = 'ST101.ECT.ST101_A1_02.Loads';

DynamicValue _struct(Map<String, bool> bits) {
  final dv = DynamicValue();
  for (final flag in El9222Flag.values) {
    for (final channel in [1, 2]) {
      dv[flag.member(channel)] = bits[flag.member(channel)] ?? false;
    }
  }
  dv['p_cmd_Reset'] = false;
  dv['p_cmd_Switch'] = true;
  dv['p_cmd_Reset_2'] = false;
  dv['p_cmd_Switch_2'] = true;
  return dv;
}

class _El9222StateMan extends Fake implements StateMan {
  _El9222StateMan(this.struct);

  final DynamicValue struct;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => switch (key) {
        _stateKey => Stream<DynamicValue>.value(struct),
        _descriptionsKey => Stream<DynamicValue>.value(
            DynamicValue.fromList(
              const ['CN04 photocells', 'CN05 gate solenoids'],
            ),
          ),
        _ => const Stream<DynamicValue>.empty(),
      };

  @override
  Future<DynamicValue> read(String key) async => struct;

  @override
  Future<void> write(String key, DynamicValue value) async {}
}

void main() {
  // Same reasoning as the conveyor pane goldens — the default tolerance is
  // too tight for text antialiasing drift, while a real regression moves far
  // more than 0.2% of the frame.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('EL9222 golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);

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

    // Solarized light: the app's default scheme, and the one carrying the
    // `HmiStateColors` extension the diodes are painted from.
    final (light, _) = solarized();

    Future<void> pump(WidgetTester tester, Map<String, bool> bits) async {
      final config = BeckhoffEL9222Config(
        nameOrId: 'ST101.A1.02',
        stateKey: _stateKey,
        descriptionsKey: _descriptionsKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider
              .overrideWith((ref) async => _El9222StateMan(_struct(bits))),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 140,
                height: 460,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('face — channel 1 tripped, channel 2 supplying',
        (tester) async {
      await pump(tester, {
        'p_stat_Tripped': true,
        'p_stat_Enabled_2': true,
      });

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/el9222_face_ch1_tripped.png'),
      );
    });

    testWidgets('face — both channels supplying', (tester) async {
      await pump(tester, {
        'p_stat_Enabled': true,
        'p_stat_Enabled_2': true,
      });

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/el9222_face_healthy.png'),
      );
    });

    testWidgets('pane — channel 1 tripped and resettable', (tester) async {
      await pump(tester, {
        'p_stat_Tripped': true,
        'p_stat_Current_Level_Warning': true,
        'p_stat_Enabled_2': true,
      });
      await tester.tap(find.byType(SidePaneOwner));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/el9222_pane_tripped.png'),
      );
    });

    testWidgets('pane — reset refused while cooling down', (tester) async {
      // The regression this holds: a reset the terminal would refuse must not
      // present itself as a live button. The channel is out, but the button
      // is dead and the reason is under it.
      await pump(tester, {
        'p_stat_Tripped': true,
        'p_stat_Cool_Down_Lock': true,
        'p_stat_Enabled_2': true,
      });
      await tester.tap(find.byType(SidePaneOwner));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/el9222_pane_cooling_down.png'),
      );
    });
  });
}
