import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/beckhoff.dart';
import 'package:tfc/page_creator/assets/common.dart' show Asset, RelativeSize;
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc/theme.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

/// Goldens of the passive Beckhoff devices carrying operator-set names.
///
/// The name lands on a marker tag over the terminal-marker band, exactly
/// where an EL1008 beside them has always worn its id, and the model name
/// stays printed at the foot. A widget test can assert both strings; only an
/// image can say whether the tag reads at rack scale, whether `ST301 A1` fits
/// a band sized for `1`, and whether the EK1110's lamps still have somewhere
/// to sit once the tag takes the top of its face.
///
/// The unnamed row is the control: no name set, no tag drawn, which is what
/// every page saved before this field existed renders as. If that image ever
/// moves, a saved page moved with it.

/// Loads real fonts so the names render as letterforms rather than the test
/// font's boxes — the label IS the change, so Ahem boxes would pin nothing.
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
}

class _FakeStateMan extends Fake implements StateMan {}

void main() {
  useTolerantGoldenComparator();

  group('Beckhoff name-or-ID golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);

    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(1200, 600);
    });

    tearDown(() {
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    final (light, _) = solarized();

    /// The four terminal-width devices in a row, each sized as it would sit
    /// on a cabinet page. `names` is applied in order; an empty entry leaves
    /// the device unnamed so it falls back to its model.
    Future<void> pumpRow(WidgetTester tester, List<String> names) async {
      final devices = <Asset>[
        BeckhoffEK1100Config()
          ..size = const RelativeSize(width: 0.12, height: 0.75)
          ..nameOrId = names[0],
        BeckhoffEL9187Config()..nameOrId = names[1],
        BeckhoffEL6070Config()..nameOrId = names[2],
        BeckhoffEK1110Config()..nameOrId = names[3],
      ];

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _FakeStateMan()),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 1100,
                height: 500,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (final device in devices)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: SizedBox(
                          width: 130,
                          height: 420,
                          child: Builder(
                              builder: (context) => device.build(context)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // The control: nothing named, so every face shows its model name. This is
    // exactly what a page saved before the field existed renders as.
    testWidgets('unnamed devices fall back to their model names',
        (tester) async {
      await pumpRow(tester, const ['', '', '', '']);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_devices_unnamed.png'),
      );
    });

    // Plant-shaped names: an ST301 cabinet's block letters, longer than every
    // model string they replace.
    testWidgets('named devices print the operator name on the face',
        (tester) async {
      await pumpRow(tester, const [
        'ST301 A1',
        'A1 0V',
        'LICENCE',
        'TO A2',
      ]);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_devices_named.png'),
      );
    });

    /// The CX on its own, large enough to read. Its tag rides the block's own
    /// I/O slice — the narrowest band any of these names has to fit — while
    /// `CX5010` stays down the red stripe.
    Future<void> pumpCx(WidgetTester tester, String nameOrId) async {
      final cx = BeckhoffCX5010Config()
        ..size = const RelativeSize(width: 1.0, height: 1.0)
        ..nameOrId = nameOrId;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _FakeStateMan()),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 460,
                child: Builder(builder: (context) => cx.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('an unnamed CX prints CX5010 and wears no tag',
        (tester) async {
      await pumpCx(tester, '');

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_cx5010_unnamed.png'),
      );
    });

    testWidgets('a named CX wears the tag and keeps CX5010', (tester) async {
      await pumpCx(tester, 'ST301');

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_cx5010_named.png'),
      );
    });
  });
}
