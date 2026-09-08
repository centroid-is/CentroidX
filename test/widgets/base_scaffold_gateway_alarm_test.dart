/// The app bar when the gateway is gone: the LOCAL alarm in the ordinary
/// alarm banner, and no pill anywhere.
///
/// The gateway-link chip used to stand in the right cluster saying "Gateway
/// live" — a quiet affordance nobody watched. It is deleted; losing the
/// backend now announces itself the way any other fault does, through the
/// SAME banner the plant's alarms use (a second banner beside the first is
/// how the real one stops being read). These arms drive the full chain —
/// `gatewayLinkProvider` → `localGatewayAlarmProvider` → banner — with the
/// report stream and the clock as the only injection points.
///
/// The goldens include a dark variant per scene, and every instant on screen
/// is injected: the header clock through `withClock`, the alarm stamp through
/// `gatewayLinkClockProvider`.
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import 'alarm_fixture.dart';

/// Frozen so the ticking header does not churn the PNGs — same instant family
/// as base_scaffold_appbar_golden_test.
final Clock _goldenClock = Clock.fixed(DateTime(2026, 9, 8, 7, 15, 30));

/// When the outage is stamped as having begun.
final DateTime _raisedAt = DateTime(2026, 9, 8, 7, 5, 0);

const _barKey = Key('gateway_alarm_appbar_golden');

final Uri _url = Uri.parse('wss://10.50.10.11:9444');

GatewayLinkReport _connected() => describeGatewayLink(
    state: LinkState.ready, url: _url, elapsed: Duration.zero);

GatewayLinkReport _unreachable() => describeGatewayLink(
      state: LinkState.down,
      url: _url,
      elapsed: const Duration(minutes: 10),
      lastDownReason: 'the transport ended by remote close',
    );

GatewayLinkReport _misconfigured() => describeGatewayLinkFailure(
      url: _url,
      failure: const GatewayLinkBuildFailure(
        raw: 'PathNotFoundException: /etc/centroid/ca.pem',
        path: '/etc/centroid/ca.pem',
      ),
    );

void _registerMenu() {
  final registry = RouteRegistry();
  registry.menuItems.clear();
  registry
      .addMenuItem(const MenuItem(label: 'Home', path: '/', icon: Icons.home));
  // NavigationBar asserts destinations.length >= 2.
  registry.addMenuItem(const MenuItem(
      label: 'Alarms', path: '/alarms', icon: Icons.notifications));
}

Widget _shell({
  required AlarmFixture alarms,
  required GatewayLinkReport? report,
  bool dark = false,
  bool brokenAlarmSource = false,
}) {
  final (light, darkTheme) = solarized();
  final delegate = BeamerDelegate(
    locationBuilder: RoutesLocationBuilder(routes: {
      '/': (context, state, data) => const BeamPage(
            key: ValueKey('/'),
            title: 'Home',
            child: BaseScaffold(title: 'Home', body: Text('home-body')),
          ),
    }).call,
  );

  return ProviderScope(
    overrides: [
      // A broken alarm source is exactly the condition the local alarm is
      // FOR: in gateway mode alarmManProvider needs the relay transport, so
      // a panel that cannot reach its gateway can be a panel with no plant
      // alarm stream at all — and the banner must still say why.
      if (brokenAlarmSource)
        alarmManProvider.overrideWith(
            (ref) async => throw StateError('no transport, no alarm source'))
      else
        alarmManProvider.overrideWith((ref) async => alarms),
      gatewayLinkProvider.overrideWith((ref) => Stream.value(report)),
      gatewayLinkClockProvider.overrideWithValue(() => _raisedAt),
    ],
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

Future<void> _pump(
  WidgetTester tester, {
  required GatewayLinkReport? report,
  AlarmFixture? alarms,
  bool dark = false,
  bool brokenAlarmSource = false,
}) async {
  tester.view.physicalSize = const Size(1600, 160);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_shell(
    alarms: alarms ?? AlarmFixture(),
    report: report,
    dark: dark,
    brokenAlarmSource: brokenAlarmSource,
  ));
  await tester.pumpAndSettle();
}

/// Real glyphs — same loader as base_scaffold_appbar_golden_test.
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

  group('behaviour', () {
    testWidgets('direct mode: no alarm, no pill, nothing', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: null);
        expect(find.textContaining('Gateway', findRichText: true),
            findsNothing,
            reason: 'a direct station has no gateway, so there must be no '
                'such alarm — an alarm that is always on for half the fleet '
                'is how alarm surfaces get ignored');
      });
    });

    testWidgets('a healthy gateway link says NOTHING — the pill is gone and '
        'no alarm replaces it', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _connected());
        // The rendered-absence proof the appbar_clock goldens cannot give
        // (their right cluster is Align(centerRight), so a missing chip may
        // move no pixel): the words the chip used to render are nowhere in
        // the tree.
        expect(find.text('Gateway live'), findsNothing);
        expect(find.textContaining('Gateway', findRichText: true),
            findsNothing);
      });
    });

    testWidgets('gateway unreachable: the ordinary alarm banner carries it',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _unreachable());
        expect(
            find.textContaining('Gateway unreachable', findRichText: true),
            findsOneWidget);
        // One banner, not a second surface beside it: the row is inside the
        // same GestureDetector column every plant alarm uses.
        expect(find.text('Gateway unreachable'), findsNothing,
            reason: 'the title reaches the screen as a banner RichText '
                'span, not as a standalone widget of its own');
      });
    });

    testWidgets('panel misconfigured (notBuilt): a DIFFERENT alarm, naming '
        'the station as the fault', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _misconfigured());
        expect(
            find.textContaining('Panel misconfigured', findRichText: true),
            findsOneWidget,
            reason: 'the transport that could not even be BUILT must not '
                'read as a cable fault — 15-08 closed this gap once on the '
                'chip and deleting the chip must not re-open it');
      });
    });

    testWidgets('the local alarm shows even when the alarm SOURCE is broken',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester,
            report: _unreachable(), brokenAlarmSource: true);
        expect(
            find.textContaining('Gateway unreachable', findRichText: true),
            findsOneWidget,
            reason: 'in gateway mode the alarm stream itself rides the '
                'transport — the banner must not need a working alarm '
                'source to say the transport is gone');
      });
    });

    testWidgets('beside plant alarms: local first, then the worst of the '
        'plant', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(
          tester,
          report: _unreachable(),
          alarms: AlarmFixture(active: {
            alarm('Blóðgunarker hitastig',
                level: AlarmLevel.error,
                at: DateTime(2026, 9, 8, 7, 10, 2),
                description: 'Yfir efri mörkum — 4.8 °C, mörk 2.0 °C'),
          }),
        );
        expect(
            find.textContaining('Gateway unreachable', findRichText: true),
            findsOneWidget);
        expect(
            find.textContaining('Blóðgunarker hitastig', findRichText: true),
            findsOneWidget,
            reason: 'the plant alarm keeps its row — the local alarm joins '
                'the banner, it does not take it over');
      });
    });

    testWidgets('recovery: the banner empties when the link returns',
        (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _connected());
        expect(find.textContaining('Gateway', findRichText: true),
            findsNothing);
      });
    });
  });

  group('goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    testWidgets('gateway unreachable', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _unreachable());
        await expectLater(find.byKey(_barKey),
            matchesGoldenFile('goldens/appbar_gateway_alarm_unreachable.png'));
      });
    });

    testWidgets('gateway unreachable, dark', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _unreachable(), dark: true);
        await expectLater(
            find.byKey(_barKey),
            matchesGoldenFile(
                'goldens/appbar_gateway_alarm_unreachable_dark.png'));
      });
    });

    testWidgets('panel misconfigured', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _misconfigured());
        await expectLater(
            find.byKey(_barKey),
            matchesGoldenFile(
                'goldens/appbar_gateway_alarm_misconfigured.png'));
      });
    });

    testWidgets('panel misconfigured, dark', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(tester, report: _misconfigured(), dark: true);
        await expectLater(
            find.byKey(_barKey),
            matchesGoldenFile(
                'goldens/appbar_gateway_alarm_misconfigured_dark.png'));
      });
    });

    testWidgets('beside a plant alarm', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(
          tester,
          report: _unreachable(),
          alarms: AlarmFixture(active: {
            alarm('Blóðgunarker hitastig',
                level: AlarmLevel.error,
                at: DateTime(2026, 9, 8, 7, 10, 2),
                description: 'Yfir efri mörkum — 4.8 °C, mörk 2.0 °C'),
          }),
        );
        await expectLater(
            find.byKey(_barKey),
            matchesGoldenFile(
                'goldens/appbar_gateway_alarm_with_plant.png'));
      });
    });

    testWidgets('beside a plant alarm, dark', (tester) async {
      await withClock(_goldenClock, () async {
        await _pump(
          tester,
          report: _unreachable(),
          dark: true,
          alarms: AlarmFixture(active: {
            alarm('Blóðgunarker hitastig',
                level: AlarmLevel.error,
                at: DateTime(2026, 9, 8, 7, 10, 2),
                description: 'Yfir efri mörkum — 4.8 °C, mörk 2.0 °C'),
          }),
        );
        await expectLater(
            find.byKey(_barKey),
            matchesGoldenFile(
                'goldens/appbar_gateway_alarm_with_plant_dark.png'));
      });
    });
  });
}
