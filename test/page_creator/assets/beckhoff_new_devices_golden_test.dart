import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart' show Asset, RelativeSize;
import 'package:tfc/page_creator/assets/ep_box.dart' show EPBoxVariant;
import 'package:tfc/page_creator/assets/ps2001.dart'
    show Ps2001Flag, Ps2001PaneBody, Ps2001Status;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Goldens of the six devices added alongside the EL9222.
///
/// Every one of these is a drawing of a real part, and no widget test can say
/// whether the drawing is any good: whether the EL2912 reads as a safety
/// terminal at a glance, whether the CU2508's eight ports fit its 146.5 mm
/// face, whether an EK1110 and an EL6070 line up with the EL terminals they
/// sit between in a rack. These images are how that gets checked.
///
/// They also pin the honest bits. The EP1918's sockets are dark and its pane
/// is a paragraph, not a lamp array; the EL2912's four output lamps never
/// light. Both are deliberate, both would be easy to "fix" by accident, and
/// both would then be lying to an operator.

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

const _el2912Under = 'ST301.ECT.ST301_A1_09_Fieldvoltage_Underrange';
const _el2912Over = 'ST301.ECT.ST301_A1_09_Fieldvoltage_Overrange';
const _ps2001Key = 'ST301.ECT.ST301_T1';
const _epBoxKey = 'ST301.ECT.ST301_RM05';
const _epBoxDescriptions = 'ST301.ECT.ST301_RM05.Sockets';

/// One server for the whole file: each asset asks for its own keys and
/// ignores the rest, which is also how they behave on a real page.
class _BeckhoffStateMan extends Fake implements StateMan {
  _BeckhoffStateMan({
    this.el2912Under = false,
    this.ps2001Flags = const {},
    this.ps2001Voltage = 24.1,
    this.ps2001Current = 3.2,
    this.epInputsHigh = const {},
    this.epOutputsHigh = const {},
  });

  final bool el2912Under;

  /// Always low here. Over- and underrange render the same face — one red
  /// lamp — so a second golden would pin nothing the widget tests do not
  /// already cover; the bit still has to publish, or the combined stream
  /// never emits.
  final bool el2912Over = false;

  final Map<Ps2001Flag, bool> ps2001Flags;
  final double ps2001Voltage;
  final double ps2001Current;
  final Set<int> epInputsHigh;
  final Set<int> epOutputsHigh;

  DynamicValue get _ps2001 {
    final dv = DynamicValue();
    for (final flag in Ps2001Flag.values) {
      dv[flag.member] = ps2001Flags[flag] ?? false;
    }
    dv['p_stat_Output_voltage'] = ps2001Voltage;
    dv['p_stat_Output_current'] = ps2001Current;
    return dv;
  }

  DynamicValue get _epBox {
    final dv = DynamicValue();
    for (int i = 0; i < 8; i++) {
      dv['I$i'] = epInputsHigh.contains(i);
      dv['O$i'] = epOutputsHigh.contains(i);
    }
    return dv;
  }

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => switch (key) {
        _el2912Under =>
          Stream<DynamicValue>.value(DynamicValue(value: el2912Under)),
        _el2912Over =>
          Stream<DynamicValue>.value(DynamicValue(value: el2912Over)),
        _ps2001Key => Stream<DynamicValue>.value(_ps2001),
        _epBoxKey => Stream<DynamicValue>.value(_epBox),
        _epBoxDescriptions => Stream<DynamicValue>.value(
            DynamicValue.fromList(const [
              'Erector jam photocell',
              'Erector ready',
              'Blank feed low',
              'Glue tank level',
              'Erector start',
              'Erector stop lamp',
              'Reject flap',
              'Beacon',
            ]),
          ),
        _ => const Stream<DynamicValue>.empty(),
      };

  @override
  Future<DynamicValue> read(String key) async => DynamicValue();

  @override
  Future<void> write(String key, DynamicValue value) async {}
}

void main() {
  // Same reasoning as the EL9222 goldens: the default tolerance is too tight
  // for text antialiasing drift, while a real regression moves far more than
  // 0.2% of the frame.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('Beckhoff new devices golden',
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
    // `HmiStateColors` extension the pane diodes are painted from.
    final (light, _) = solarized();

    Future<void> pump(
      WidgetTester tester,
      Asset config, {
      required Size box,
      _BeckhoffStateMan? stateMan,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider
              .overrideWith((ref) async => stateMan ?? _BeckhoffStateMan()),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: box,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) => expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/$name.png'),
        );

    // ----- EL2912 -------------------------------------------------------

    testWidgets('EL2912 face — field voltage in range', (tester) async {
      await pump(
        tester,
        BeckhoffEL2912Config(
          nameOrId: 'ST301.A1.09',
          underrangeKey: _el2912Under,
          overrangeKey: _el2912Over,
        ),
        box: const Size(140, 460),
      );

      await shot('el2912_face_in_range');
    });

    testWidgets('EL2912 face — field voltage below range', (tester) async {
      await pump(
        tester,
        BeckhoffEL2912Config(
          nameOrId: 'ST301.A1.09',
          underrangeKey: _el2912Under,
          overrangeKey: _el2912Over,
        ),
        box: const Size(140, 460),
        stateMan: _BeckhoffStateMan(el2912Under: true),
      );

      await shot('el2912_face_underrange');
    });

    testWidgets('EL2912 pane — the fault, and the limits of what it knows',
        (tester) async {
      await pump(
        tester,
        BeckhoffEL2912Config(
          nameOrId: 'ST301.A1.09',
          underrangeKey: _el2912Under,
          overrangeKey: _el2912Over,
        ),
        box: const Size(140, 460),
        stateMan: _BeckhoffStateMan(el2912Under: true),
      );
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      await shot('el2912_pane_underrange');
    });

    // ----- PS2001 -------------------------------------------------------

    testWidgets('PS2001 face — supplying', (tester) async {
      await pump(
        tester,
        BeckhoffPS2001Config(nameOrId: 'ST301.T1', stateKey: _ps2001Key),
        box: const Size(200, 500),
        stateMan: _BeckhoffStateMan(ps2001Flags: {Ps2001Flag.dcOk: true}),
      );

      await shot('ps2001_face_supplying');
    });

    testWidgets('PS2001 face — faulted', (tester) async {
      await pump(
        tester,
        BeckhoffPS2001Config(nameOrId: 'ST301.T1', stateKey: _ps2001Key),
        box: const Size(200, 500),
        stateMan: _BeckhoffStateMan(
          ps2001Flags: {Ps2001Flag.error: true},
          ps2001Voltage: 11.4,
          ps2001Current: 0.0,
        ),
      );

      await shot('ps2001_face_faulted');
    });

    testWidgets('PS2001 pane — the figures, with headroom', (tester) async {
      await pump(
        tester,
        BeckhoffPS2001Config(nameOrId: 'ST301.T1', stateKey: _ps2001Key),
        box: const Size(200, 500),
        stateMan: _BeckhoffStateMan(
          ps2001Flags: {Ps2001Flag.dcOk: true, Ps2001Flag.warning: true},
          ps2001Voltage: 23.8,
          ps2001Current: 9.1,
        ),
      );
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      await shot('ps2001_pane_strained');
    });

    // The trend block, with a canned preview in place of the real chart —
    // the collector is not running under `flutter test`, and this golden is
    // about where the section sits and how the two tiles read, not about
    // cristalyse's line rendering.
    testWidgets('PS2001 pane — the trend section', (tester) async {
      Widget sparkline(Color color) => CustomPaint(
            painter: _SparklinePainter(color),
            child: const SizedBox.expand(),
          );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _BeckhoffStateMan()),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Ps2001PaneBody(
                  status: Ps2001Status.read(_stubStruct()),
                  description: 'Cabinet A1 24 V rail',
                  trendTile: PaneTileRow(
                    children: [
                      PaneGraphTile(
                        label: 'Output V',
                        height: 90,
                        preview: sparkline(Colors.teal),
                        expandedBuilder: (_) => const SizedBox(),
                      ),
                      PaneGraphTile(
                        label: 'Draw A',
                        height: 90,
                        preview: sparkline(Colors.orange),
                        expandedBuilder: (_) => const SizedBox(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await shot('ps2001_pane_trend');
    });

    // ----- EtherCAT Box -------------------------------------------------

    testWidgets('EP2338 face — four sockets carrying', (tester) async {
      await pump(
        tester,
        BeckhoffEPBoxConfig(
          variantModel: EPBoxVariant.ep2338,
          nameOrId: 'ST301.RM05',
          stateKey: _epBoxKey,
        ),
        box: const Size(160, 560),
        stateMan: _BeckhoffStateMan(
          epInputsHigh: const {0, 2},
          epOutputsHigh: const {5},
        ),
      );

      await shot('ep2338_face_live');
    });

    testWidgets('EP1918 face — yellow, dark, and not marked broken',
        (tester) async {
      await pump(
        tester,
        BeckhoffEPBoxConfig(
          variantModel: EPBoxVariant.ep1918,
          nameOrId: 'ST301.EM01',
        ),
        box: const Size(160, 560),
      );

      await shot('ep1918_face');
    });

    testWidgets('EP2338 pane — sockets named, not numbered', (tester) async {
      await pump(
        tester,
        BeckhoffEPBoxConfig(
          variantModel: EPBoxVariant.ep2338,
          nameOrId: 'ST301.RM05',
          stateKey: _epBoxKey,
          descriptionsKey: _epBoxDescriptions,
        ),
        box: const Size(160, 560),
        stateMan: _BeckhoffStateMan(
          epInputsHigh: const {0, 2},
          epOutputsHigh: const {5},
        ),
      );
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      await shot('ep2338_pane');
    });

    // ----- The parts with nothing to say --------------------------------

    testWidgets('CU2508 — one uplink and eight segments', (tester) async {
      await pump(
        tester,
        BeckhoffCU2508Config(nameOrId: 'CU2508 roe')
          ..size = const RelativeSize(width: 1.0, height: 1.0),
        box: const Size(640, 440),
      );

      await shot('cu2508_face');
    });

    // The rack is the real test of the two 12 mm drawings: an EK1110 or an
    // EL6070 whose body, label height or lamp row does not match the EL
    // terminals beside it looks like a mistake in the cabinet rather than a
    // mistake in the mimic.
    testWidgets('a rack — EL2912, EL6070 and EK1110 among EL terminals',
        (tester) async {
      await pump(
        tester,
        BeckhoffEK1100Config()
          ..size = const RelativeSize(width: 1.0, height: 1.0)
          ..subdevices = [
            BeckhoffEL1008Config(nameOrId: '1'),
            BeckhoffEL2912Config(
              nameOrId: '2',
              underrangeKey: _el2912Under,
              overrangeKey: _el2912Over,
            ),
            BeckhoffEL9222Config(nameOrId: '3'),
            BeckhoffEL6070Config(),
            BeckhoffEK1110Config(),
          ],
        box: const Size(900, 560),
      );

      await shot('beckhoff_rack_with_new_terminals');
    });
  });
}

/// A healthy supply, for the trend golden.
DynamicValue _stubStruct() {
  final dv = DynamicValue();
  for (final flag in Ps2001Flag.values) {
    dv[flag.member] = flag == Ps2001Flag.dcOk;
  }
  dv['p_stat_Output_voltage'] = 24.1;
  dv['p_stat_Output_current'] = 3.2;
  return dv;
}

/// A fixed squiggle. Deterministic on purpose — a golden of live chart data
/// would churn on every run.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter(this.color);

  final Color color;

  static const _points = [
    0.55, 0.52, 0.58, 0.61, 0.49, 0.44, 0.52, 0.66, 0.71, 0.63,
    0.58, 0.55, 0.6, 0.68, 0.62,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (int i = 0; i < _points.length; i++) {
      final x = size.width * i / (_points.length - 1);
      final y = size.height * (1 - _points[i]);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) => old.color != color;
}
