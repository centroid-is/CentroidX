/// Golden images of the one colour-picking surface, for design review.
///
/// Every asset editor now asks for a colour the same way: a [ColorPickerRow]
/// (labelled swatch) that opens [showColorPickerDialog] (full HSV picker in
/// the standard dialog frame). These goldens pin both halves:
///
///   * the row strip — a set colour, and a cleared/inherit colour showing
///     the reset glyph
///   * the dialog itself, open over the rows, light and dark
///
/// To update: flutter test test/widgets/color_picker_golden_test.dart \
///   --update-goldens --run-skipped
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/theme.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import '../helpers/golden_platform.dart';

/// Editor-pane-shaped canvas: the rows live in a ~360px config column, the
/// dialog is 420px wide — 1024×768 shows both with the surrounding page.
const Size _screen = Size(1024, 768);

class _RowStrip extends StatefulWidget {
  const _RowStrip();

  @override
  State<_RowStrip> createState() => _RowStripState();
}

class _RowStripState extends State<_RowStrip> {
  Color _running = Colors.green;
  Color _stopped = Colors.grey;
  Color? _override; // starts cleared → reset glyph

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Colours', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ColorPickerRow(
            label: 'Running Color',
            color: _running,
            onChanged: (c) => setState(() => _running = c),
          ),
          ColorPickerRow(
            label: 'Stopped Color',
            color: _stopped,
            onChanged: (c) => setState(() => _stopped = c),
          ),
          ColorPickerRow(
            label: 'Text Color',
            color: _override,
            onChanged: (c) => setState(() => _override = c),
            onCleared: () => setState(() => _override = null),
          ),
        ],
      ),
    );
  }
}

Widget _app({required ThemeData theme}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: const Scaffold(
      body: Center(child: _RowStrip()),
    ),
  );
}

Future<void> _pump(WidgetTester tester, {required ThemeData theme}) async {
  await tester.binding.setSurfaceSize(_screen);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(theme: theme));
}

void main() {
  final (light, dark) = solarized();

  // Same font plumbing as panes_golden_test.dart: the app themes ask for
  // 'roboto-mono' by family name, and MaterialIcons is not registered in the
  // test environment.
  setUpAll(() async {
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer))))
          .load();
    }

    await loadFont(
        'roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

    final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
        (Platform.resolvedExecutable.contains('flutter')
            ? null
            : File(Platform.resolvedExecutable).parent.path);
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
  });

  group('Colour picker goldens', () {
    setUp(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      RecentColors.resetCache();
      // Two tweaked colours, so the goldens show the Recent strip the
      // operator gets after confirming custom picks.
      await RecentColors.add(const Color(0xFF2A6F97));
      await RecentColors.add(const Color(0xFFB5651D));
    });

    testWidgets('rows — set, grey default, cleared — dark', (tester) async {
      await _pump(tester, theme: dark);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/color_picker_rows_dark.png'),
      );
    });

    testWidgets('dialog open over the rows — dark', (tester) async {
      await _pump(tester, theme: dark);
      await tester.tap(find.text('Stopped Color'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/color_picker_dialog_dark.png'),
      );
    });

    testWidgets('dialog with Clear action — light', (tester) async {
      await _pump(tester, theme: light);
      await tester.tap(find.text('Text Color'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/color_picker_dialog_light.png'),
      );
    });
  }, skip: goldenSkip);
}
