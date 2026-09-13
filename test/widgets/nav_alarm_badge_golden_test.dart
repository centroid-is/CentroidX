import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/nav_alarm_badge.dart';
import 'package:tfc/widgets/nav_dropdown.dart' show TopLevelNavIndicator;
import 'package:tfc_dart/core/alarm.dart';
import '../helpers/golden_platform.dart';

const _barKey = Key('nav_alarm_bar_golden');

/// A navigation bar the way an operator sees it, with alarms live on pages
/// they are not looking at.
///
/// Rendered with the app's real Solarized theme so the goldens carry the
/// colours the plant actually shows, and at a frozen animation phase so the
/// PNG is stable — the badge's motion is covered by the beacon's own filmstrip
/// goldens, which draw the same painter.
Widget buildBar({
  required List<(IconData, String, AlarmLevel?)> destinations,
  bool dark = false,
  double progress = 0.35,
}) {
  final (light, darkTheme) = solarized();
  final theme = dark ? darkTheme : light;
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: const SizedBox.shrink(),
      bottomNavigationBar: RepaintBoundary(
        key: _barKey,
        child: NavigationBar(
          selectedIndex: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final (icon, label, level) in destinations)
              NavigationDestination(
                icon: NavAlarmBadge(
                  level: level,
                  progressOverride: level == null ? null : progress,
                  child: Icon(icon),
                ),
                label: label,
              ),
          ],
        ),
      ),
    ),
  );
}

/// The section entry the navigation bar uses for a dropdown, badged.
///
/// Its own widget because it lays the icon out in a Column rather than letting
/// NavigationDestination do it — the badge overhangs the icon's box, so this
/// is where it would get clipped if anywhere.
Widget buildSection({
  required AlarmLevel? level,
  bool active = false,
  double progress = 0.35,
}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: light,
    home: Scaffold(
      backgroundColor: light.colorScheme.surface,
      bottomNavigationBar: RepaintBoundary(
        key: _barKey,
        child: NavigationBar(
          selectedIndex: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            // The InkWell is NavDropdown's — a destination without a tap
            // action trips the semantics assertion, and it is also what the
            // indicator sits inside for real.
            InkWell(
              onTap: () {},
              child: TopLevelNavIndicator(Icons.settings, 'Advanced', active,
                  alarmLevel: level, alarmProgressOverride: progress),
            ),
            const NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          ],
        ),
      ),
      body: const SizedBox.shrink(),
    ),
  );
}

/// A single badged icon, blown up so the badge can be judged on its own.
Widget buildCloseUp({required AlarmLevel level, double progress = 0.35}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: light,
    home: Scaffold(
      backgroundColor: light.colorScheme.surface,
      body: Center(
        child: RepaintBoundary(
          key: _barKey,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: NavAlarmBadge(
              level: level,
              progressOverride: progress,
              child: const Icon(Icons.ac_unit, size: 25),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Real glyphs — without this the tests render the block placeholder font.
/// Same pattern as alarm_visibility_golden_test.
Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    await (FontLoader(family)
          ..addFont(Future.value(ByteData.view(file.readAsBytesSync().buffer))))
        .load();
  }

  await load('Roboto', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');
  await load('roboto-mono', 'lib/fonts/roboto-mono/RobotoMono-Regular.ttf');

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    await load('MaterialIcons',
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  }
}

void main() {
  setUpAll(_loadFonts);

  // Home is the page on screen (selectedIndex 0) and so stays quiet even
  // though a nav-flagged alarm could be bound to it; the rest carry one level
  // each, worst on the right.
  const mixed = <(IconData, String, AlarmLevel?)>[
    (Icons.home, 'Home', null),
    (Icons.thermostat, 'Freezer', AlarmLevel.info),
    (Icons.conveyor_belt, 'Grading', AlarmLevel.warning),
    (Icons.inventory_2, 'Packing', AlarmLevel.error),
  ];

  const quiet = <(IconData, String, AlarmLevel?)>[
    (Icons.home, 'Home', null),
    (Icons.thermostat, 'Freezer', null),
    (Icons.conveyor_belt, 'Grading', null),
    (Icons.inventory_2, 'Packing', null),
  ];

  group('Navigation alarm badge golden tests',
      skip: goldenSkip, () {
    testWidgets('quiet bar is untouched', (tester) async {
      await tester.pumpWidget(buildBar(destinations: quiet));
      await expectLater(
        find.byKey(_barKey),
        matchesGoldenFile('goldens/nav_alarm_bar_quiet.png'),
      );
    });

    testWidgets('one level per destination', (tester) async {
      await tester.pumpWidget(buildBar(destinations: mixed));
      await expectLater(
        find.byKey(_barKey),
        matchesGoldenFile('goldens/nav_alarm_bar_levels.png'),
      );
    });

    testWidgets('one level per destination, dark', (tester) async {
      await tester.pumpWidget(buildBar(destinations: mixed, dark: true));
      await expectLater(
        find.byKey(_barKey),
        matchesGoldenFile('goldens/nav_alarm_bar_levels_dark.png'),
      );
    });

    testWidgets('a section entry badges without clipping', (tester) async {
      await tester.pumpWidget(buildSection(level: AlarmLevel.error));
      await expectLater(
        find.byKey(_barKey),
        matchesGoldenFile('goldens/nav_alarm_section.png'),
      );
    });

    for (final level in AlarmLevel.values) {
      testWidgets('${level.name} badge close-up', (tester) async {
        await tester.pumpWidget(buildCloseUp(level: level));
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/nav_alarm_badge_${level.name}.png'),
        );
      });
    }
  });
}
