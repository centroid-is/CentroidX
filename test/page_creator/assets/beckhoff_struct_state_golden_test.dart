import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/ep_box.dart' show EPBoxVariant;
import 'package:tfc/painter/beckhoff/ep_box.dart' show EPBoxWidget;
import 'package:tfc/painter/beckhoff/io8.dart' show IO8Widget;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/side_pane.dart' show closeSidePane;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import '../../helpers/golden_tolerance.dart';

/// Goldens of what the struct decode and the asset-carried channel names put
/// on screen.
///
/// The unit tests beside these pin [beckhoffChannelStates] and
/// [beckhoffChannelDescription] as functions, and the widget tests pin that
/// an [IO8Widget] is handed the right `ledStates`. Neither says what the
/// operator sees. These do:
///
/// * A struct-published terminal used to render every channel dark, because
///   the decode only understood the packed byte. The struct/byte pair below
///   are the same two channels lit two ways — the images must be identical,
///   which is the whole claim of the fallback.
/// * A value in neither shape is unknown to the *decoder*
///   ([beckhoffChannelStates] returns null rather than eight falses), but
///   the face has no unknown lamp: `_ledStates` renders it low, so the image
///   below is the same face an honestly all-low terminal draws. That is the
///   behaviour as shipped, and the image is here to hold it still — if a
///   later change gives unknown its own look, this golden is what says so.
/// * The channel names are text on a face and in a grid. Whether a plant
///   string like `Belt 3 photocell` fits the row it is drawn in, and whether
///   a configured name and a key-delivered one sit at the same place, is a
///   layout question, not a `find.text` question.
///
/// The two pane images are where the descriptions live now. The floating
/// "Channel detail" grid they used to live behind is gone: it was ~900px of
/// force buttons and filter fields around them, and this plant's PLC accepts
/// no override, so it was a control surface for a capability that does not
/// exist. What is left is a name, a description and a lamp per channel, in
/// three fixed columns, all eight visible without opening anything.

/// Loads real fonts so the channel names render as letterforms rather than
/// the test font's boxes — the names ARE the change here, so Ahem boxes
/// would pin nothing about whether they fit.
Future<void> loadRealFont() async {
  Future<void> loadFont(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
}

const _rawKey = 'ST101.ECT.ST101_A1_03';
const _descriptionsKey = 'ST101.ECT.ST101_A1_03_Descriptions';
const _epStateKey = 'ST301.ECT.ST301_RM05';
const _epDescriptionsKey = 'ST301.ECT.ST301_RM05.Sockets';

/// A struct value the way the GVL generator publishes one.
DynamicValue structValue(String prefix, Set<int> high, {int base = 1}) {
  final v = DynamicValue();
  for (var n = base; n < base + 8; n++) {
    v['$prefix$n'] = high.contains(n);
  }
  return v;
}

/// Publishes a fixed value per key; a key absent here never publishes.
class _StubStateMan extends Fake implements StateMan {
  _StubStateMan(this.values);

  final Map<String, DynamicValue> values;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final value = values[key];
    if (value != null) {
      return Stream<DynamicValue>.value(value);
    }
    return const Stream<DynamicValue>.empty();
  }
}

void main() {
  // Same dense line work as the other Beckhoff goldens — the terminal faces
  // are hairline rules and small text, and antialiasing drift across
  // toolchains eats more than the 0.01% default.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('Beckhoff struct-state golden',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    setUpAll(loadRealFont);

    /// Frames the image around what it is meant to show. A terminal face is
    /// 140px of hairline detail, the channel grid is a dialog with a docked
    /// pane behind it; one canvas size cannot serve both without either
    /// drowning the face in background or cutting the grid off at channel 6.
    Future<void> frame(WidgetTester tester, Size size) async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = size;
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }

    tearDown(() {
      // The grid cases leave a pane docked; a leftover pane would follow the
      // next case into its image.
      closeSidePane();
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    final (light, _) = solarized();

    /// One EL1008 at cabinet scale, fed [raw] on its raw-state key.
    Future<void> pumpTerminal(WidgetTester tester, DynamicValue raw) async {
      await frame(tester, const Size(340, 560));

      final config = BeckhoffEL1008Config(
        nameOrId: 'ST101.A1.03',
        rawStateKey: _rawKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider
              .overrideWith((ref) async => _StubStateMan({_rawKey: raw})),
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
      expect(find.byType(IO8Widget), findsOneWidget);
    }

    // Channels 2 and 7 high, published as the generated struct. Before this
    // change a struct-published terminal drew every channel dark; this image
    // is the face finally lighting off the canonical contract.
    testWidgets('the generated struct lights the terminal face',
        (tester) async {
      await pumpTerminal(tester, structValue('I', {2, 7}));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_el1008_struct_lit.png'),
      );
    });

    // The same two channels as the legacy packed byte (bits 1 and 6). This
    // image must be pixel-for-pixel the one above — that the fallback is
    // invisible to the operator is the point of keeping it.
    testWidgets('the legacy packed byte lights the same face', (tester) async {
      await pumpTerminal(tester, DynamicValue(value: 0x42));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_el1008_byte_lit.png'),
      );
    });

    // A value in neither shape. The decoder calls it unknown; the face draws
    // it as eight unlit channels, indistinguishable from a terminal that is
    // genuinely all-low. Pinned deliberately, not endorsed.
    testWidgets('a value in neither shape leaves the face dark',
        (tester) async {
      await pumpTerminal(tester, DynamicValue(value: 'not a state'));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_el1008_unknown.png'),
      );
    });

    /// The EL1008's pane, one tap in, where the descriptions live now.
    /// [configured] is what the page author set on the asset; the key always
    /// delivers `Key ch1..8` underneath it.
    Future<void> openGrid(
      WidgetTester tester, {
      List<String>? configured,
    }) async {
      // The pane docks to the right at its own width; the canvas only has to
      // be tall enough to hold all eight channel rows without scrolling.
      await frame(tester, const Size(900, 900));

      final config = BeckhoffEL1008Config(
        nameOrId: 'ST101.A1.03',
        rawStateKey: _rawKey,
        descriptionsKey: _descriptionsKey,
        channelDescriptions: configured,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _StubStateMan({
                _rawKey: structValue('I', {2, 7}),
                _descriptionsKey: DynamicValue.fromList(
                    List.generate(8, (i) => 'Key ch${i + 1}')),
              })),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 400,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // One tap. The names are in the pane itself now.
      await tester.tap(find.byType(IO8Widget));
      await tester.pumpAndSettle();
    }

    // Nothing set on the asset: every row wears the key-delivered name. The
    // control for the image below.
    testWidgets('the pane with only key-delivered channel names',
        (tester) async {
      await openGrid(tester, configured: null);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_el1008_pane_key_names.png'),
      );
    });

    // Plant-shaped names on three channels, the rest left to the key: the
    // mixed case a real page produces, and the one that says whether a long
    // string still leaves its lamp somewhere to sit.
    testWidgets('the pane with asset-configured channel names',
        (tester) async {
      await openGrid(tester, configured: const [
        'Kettle high level',
        '',
        'Belt 3 photocell',
        '',
        '',
        'Freezer door',
      ]);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_el1008_pane_asset_names.png'),
      );
    });

    // The EP2338's pane: the case the terminals do not have, where a point
    // carries both directions on one pin. Two lamps per row, round for the
    // input and square for the output, against one description — the port is
    // one physical thing and gets one name.
    testWidgets('the EP2338 pane pairs in and out against one name',
        (tester) async {
      await frame(tester, const Size(900, 900));

      final struct = DynamicValue();
      for (var n = 0; n < 8; n++) {
        struct['I$n'] = n == 1 || n == 5;
        struct['O$n'] = n == 3;
      }

      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
        stateKey: _epStateKey,
        descriptionsKey: _epDescriptionsKey,
        // Two named on the asset, one more off the key, the rest unnamed —
        // the state a real page is actually in.
        channelDescriptions: const ['', 'Erector jam photocell', '', 'Erector clamp'],
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _StubStateMan({
                _epStateKey: struct,
                _epDescriptionsKey: DynamicValue.fromList(
                    const ['', '', 'Erector ready', '', '', 'Pallet present']),
              })),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 340,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(EPBoxWidget));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_ep2338_pane.png'),
      );
    });

    // The combi box, both directions off one struct: inputs on ports 2 and
    // 6, output drive on port 4. One physical pin per port carrying both is
    // the shape the decode has to keep apart, and the face is where you see
    // it kept apart.
    testWidgets('the EP2338 face lights both directions off one struct',
        (tester) async {
      await frame(tester, const Size(320, 460));

      final struct = DynamicValue();
      for (var n = 0; n < 8; n++) {
        struct['I$n'] = n == 1 || n == 5;
        struct['O$n'] = n == 3;
      }

      final config = BeckhoffEPBoxConfig(
        variantModel: EPBoxVariant.ep2338,
        nameOrId: 'RM05',
        stateKey: _epStateKey,
        descriptionsKey: _epDescriptionsKey,
      );

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _StubStateMan({
                _epStateKey: struct,
                _epDescriptionsKey: DynamicValue.fromList(
                    const ['Erector jam photocell', 'Erector ready']),
              })),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 340,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(EPBoxWidget), findsOneWidget);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_ep2338_struct_lit.png'),
      );
    });
  });
}
