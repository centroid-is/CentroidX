/// Goldens for the app bar's header: the clock and the alarm banner.
///
/// The clock used to share the centre slot with the alarm banner — whenever an
/// alarm was active the time vanished. It now lives on the left, immediately
/// right of the back arrow, on two lines (date over time) and at a size that
/// reads from across the hall. These PNGs are the record of that layout: both
/// halves visible at once, neither overlapping the logo or the controls.
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_dart/core/alarm.dart';

import 'alarm_fixture.dart';
import '../helpers/golden_platform.dart';

/// Frozen so the ticking header does not churn the PNG every run — the same
/// reason the page-organizer goldens pin it.
final Clock _goldenClock = Clock.fixed(DateTime(2026, 8, 31, 14, 5, 9));

const _barKey = Key('base_scaffold_appbar_golden');

void _registerMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: 'Server Config',
          path: '/advanced/server-config',
          icon: Icons.dns),
    ],
  ));
}

/// The scaffold behind a router, at the window size a plant station runs.
///
/// [alarms] is what the header's alarm stream reports; empty leaves the banner
/// off and only the clock showing.
Widget _shell(AlarmFixture alarms, {bool dark = false}) {
  final (light, darkTheme) = solarized();
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => const BeamPage(
            key: ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: Text('home-body')),
          ),
      '/advanced/server-config': (context, state, data) => const BeamPage(
            key: ValueKey('/advanced/server-config'),
            title: 'Server Config',
            child: BaseScaffold(
                title: 'Server Config', body: Text('server-config-body')),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [alarmManProvider.overrideWith((ref) async => alarms)],
    child: RepaintBoundary(
      key: _barKey,
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          theme: dark ? darkTheme : light,
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ),
  );
}

/// Pumps [_shell] at a station-sized window, optionally beamed one level deep
/// so the back arrow is present and the clock sits to the right of it.
Future<void> _pump(
  WidgetTester tester,
  AlarmFixture alarms, {
  bool dark = false,
  bool deep = false,
}) async {
  tester.view.physicalSize = const Size(1600, 160);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_shell(alarms, dark: dark));
  await tester.pumpAndSettle();
  if (deep) {
    Beamer.of(tester.element(find.text('home-body')))
        .beamToNamed('/advanced/server-config');
    await tester.pumpAndSettle();
  }
}

/// Real glyphs — without this the tests render the block placeholder font.
/// Same pattern as nav_alarm_badge_golden_test.
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
  setUp(_registerMenu);
  tearDown(() => RouteRegistry().menuItems.clear());

  final quiet = AlarmFixture();
  AlarmFixture noisy() => AlarmFixture(active: {
        alarm('Blóðgunarker hitastig',
            level: AlarmLevel.error,
            at: DateTime(2026, 8, 31, 14, 4, 2),
            description: 'Yfir efri mörkum — 4.8 °C, mörk 2.0 °C'),
        alarm('CN07 færiband',
            level: AlarmLevel.warning,
            at: DateTime(2026, 8, 31, 14, 3, 51),
            description: 'Mótor í yfirálagi, straumur yfir mörkum'),
      });

  group('app-bar header goldens',
      skip: goldenSkip, () {
    testWidgets('quiet: clock alone on the left, two lines', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, quiet);
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/appbar_clock_quiet.png'),
        );
      });
    });

    testWidgets('quiet, one level deep: clock sits right of the back arrow',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, quiet, deep: true);
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/appbar_clock_behind_back_arrow.png'),
        );
      });
    });

    testWidgets('alarms active: banner centred, clock still readable',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy());
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/appbar_clock_with_alarms.png'),
        );
      });
    });

    testWidgets('alarms active, dark', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(), dark: true);
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/appbar_clock_with_alarms_dark.png'),
        );
      });
    });
  });

  group('app-bar header behaviour', () {
    testWidgets('the clock stays on screen while an alarm is banner-ed',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy());
        // The regression this guards: the clock used to be the *else* branch
        // of the alarm banner, so an active alarm took the time away.
        expect(find.text('31.08.26'), findsOneWidget);
        expect(find.text('14:05:09'), findsOneWidget);
        expect(
            find.textContaining('Blóðgunarker hitastig', findRichText: true),
            findsOneWidget);
      });
    });

    testWidgets('date and time are separate lines, not one string',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, quiet);
        expect(find.text('31.08.26'), findsOneWidget);
        expect(find.text('14:05:09'), findsOneWidget);
        expect(find.text('31.08.26 14:05:09'), findsNothing);
      });
    });
  });
}
