/// Two goldens of the Alarm Editor's auto-navigation switch: on in the light
/// theme, off in the dark one.
///
/// **What the images are supposed to show**, so a later reader can check the
/// file rather than a memory:
///
///  * `alarm_auto_navigate_on_light.png` — an open-in-new glyph, the title
///    `Go to the alarm's page when it raises`, the switch thrown to the right,
///    and three lines of subtitle naming the two rules an operator has to know
///    to predict the behaviour: it only goes to a page they can open, and a
///    second alarm only takes over if it is more severe.
///  * `alarm_auto_navigate_off_dark.png` — the same tile, switch to the left,
///    with the one-line off subtitle ending `Navigation entries still pulse.`
///    — because the pulse is the thing this does *not* turn off, and a reader
///    who cannot see that is left thinking the switch silences the nav bar.
///
/// Dark is goldened rather than assumed. Neither scheme sets
/// `colorScheme.outline`, so a divider or a track borrowed from it goes
/// invisible on dark and no light-only image would show it.
///
/// Both themes come from `muted()`, or `HmiStateColors` falls back to
/// `solarizedLight` and the picture is of a theme the plant does not run.
/// Fonts are loaded here, twice, because `lib/theme.dart` names `roboto-mono`
/// as the family and `test/pages/flutter_test_config.dart` registers none.
///
/// To update: flutter test test/pages/alarm_auto_navigate_setting_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/alarm_editor.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/theme.dart' show muted;
import 'package:tfc_dart/core/alarm.dart';

import '../helpers/golden_tolerance.dart';

/// Enough of an [AlarmMan] for a tile that reads one bool off it.
class _FakeAlarmMan implements AlarmMan {
  _FakeAlarmMan({required bool autoNavigate})
      : config = AlarmManConfig(alarms: [], autoNavigate: autoNavigate);

  @override
  final AlarmManConfig config;

  @override
  void setAutoNavigate(bool value) => config.autoNavigate = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadRealFonts() async {
  Future<void> loadFont(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await loadFont('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await loadFont('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

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

void main() {
  final (light, dark) = muted();

  // A frame of prose, not a line drawing: the 0.01% default is tuned for
  // painter goldens and antialiasing on text moves more than that.
  useTolerantGoldenComparator(tolerance: 0.002);

  group('alarm auto-navigate setting golden',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    setUpAll(_loadRealFonts);

    tearDown(() {
      TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!
          .resetPhysicalSize();
    });

    Future<void> pumpTile(
      WidgetTester tester, {
      required bool autoNavigate,
      required ThemeData theme,
    }) async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1.0;
      view.physicalSize = const Size(720, 130);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          alarmManProvider.overrideWith(
              (ref) async => _FakeAlarmMan(autoNavigate: autoNavigate)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: AlarmAutoNavigateSetting(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('on, light', (tester) async {
      await pumpTile(tester, autoNavigate: true, theme: light);

      // Claims an eye cannot make: that the tile is live and reading the
      // stored value rather than a default.
      final tile = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('alarm-editor-auto-navigate')));
      expect(tile.value, isTrue);
      expect(tile.onChanged, isNotNull);
      expect(find.textContaining('more severe'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/alarm_auto_navigate_on_light.png'),
      );
    });

    testWidgets('off, dark', (tester) async {
      await pumpTile(tester, autoNavigate: false, theme: dark);

      final tile = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('alarm-editor-auto-navigate')));
      expect(tile.value, isFalse);
      expect(find.textContaining('Navigation entries still pulse'),
          findsOneWidget);
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/alarm_auto_navigate_off_dark.png'),
      );
    });
  });
}
