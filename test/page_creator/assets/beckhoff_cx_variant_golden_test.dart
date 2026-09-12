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

/// Goldens of the two CX variants side by side.
///
/// The whole claim of this change is "same asset, different text", and a
/// widget test asserting `painter.name == 'CX5340'` cannot show that the rest
/// of the drawing really is untouched. These can: the CX5010 golden is the
/// control, and if the shared base class moved anything — the rack, the LED
/// stripe, the fit — the control moves with it and the diff says so.
///
/// The drawing is a CX50xx front. A real CX5340 is a wider box with a
/// different port complement, so this is the right label on approximately the
/// right shape. Worth seeing rather than discovering later.

/// Loads real fonts so the model name down the red stripe renders as
/// letterforms rather than the test font's boxes — the label IS the change,
/// so a golden of Ahem boxes would pin nothing.
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

class _FakeStateMan extends Fake implements StateMan {}

void main() {
  useTolerantGoldenComparator();

  group('Beckhoff CX variant golden',
      skip: goldenSkip, () {
    setUpAll(loadRealFont);

    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(1000, 700);
    });

    tearDown(() {
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    final (light, _) = solarized();

    Future<void> pump(WidgetTester tester, Asset config) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          stateManProvider.overrideWith((ref) async => _FakeStateMan()),
        ],
        child: MaterialApp(
          theme: light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 900,
                height: 600,
                child: Builder(builder: (context) => config.build(context)),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('CX5340 with a rack of terminals', (tester) async {
      await pump(
        tester,
        BeckhoffCX5340Config()
          ..size = const RelativeSize(width: 1.0, height: 1.0)
          ..subdevices = [
            BeckhoffEL1008Config(nameOrId: '1'),
            BeckhoffEL2008Config(nameOrId: '2'),
            BeckhoffEL9222Config(nameOrId: '3'),
          ],
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_cx5340_rack.png'),
      );
    });

    // The control. This image must not move; if it does, the shared base
    // class changed the CX5010 and every saved page carrying one.
    testWidgets('CX5010 with the same rack is unchanged', (tester) async {
      await pump(
        tester,
        BeckhoffCX5010Config()
          ..size = const RelativeSize(width: 1.0, height: 1.0)
          ..subdevices = [
            BeckhoffEL1008Config(nameOrId: '1'),
            BeckhoffEL2008Config(nameOrId: '2'),
            BeckhoffEL9222Config(nameOrId: '3'),
          ],
      );

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/beckhoff_cx5010_rack.png'),
      );
    });
  });
}
