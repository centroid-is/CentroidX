/// The app-bar chip, in the app bar, in both station themes.
///
/// `GatewayLinkChip` is what an operator who never opened Server Config reads
/// — the one thing on a gateway-mode panel that says why the values are grey.
/// Two states are shot, and they are the two that must not be confusable: a
/// live session, and a token the gateway has already refused and will refuse
/// again.
///
/// ## This file is also the geometry guard the four `appbar_clock_*.png` are not
///
/// Plan 15-06 predicted that moving the chip's gap out of the widget and into a
/// sibling `SizedBox(width: 8)` in `base_scaffold.dart` would shift the four
/// existing app-bar goldens by 8 px. **It did not — all four stayed green with
/// the defect in the tree.** The cause was measured: the app bar's RIGHT
/// cluster is an `Align(alignment: centerRight)`, so its right edge is pinned.
/// Empty space inserted to the *left* of the Centroid logo widens the row
/// leftwards, the logo and the theme toggle do not move, and an empty box
/// paints nothing. Those four images guard *content* in the bar and are
/// structurally blind to *empty space* left of the logo.
///
/// A chip is ink, and ink moves. Because these frames are shot through the
/// **whole app bar** rather than against the widget in isolation, the gap
/// living inside `GatewayLinkChip` is a pixel fact here: move it out and the
/// chip slides. That is the deliberate reason this file does not pump a bare
/// `GatewayLinkChip` into `themedGoldenHost` — an isolated chip would be a
/// prettier image and would guard nothing the widget test does not already.
///
/// ## The clock is frozen
///
/// The header renders the date and time, so without `Clock.fixed` every one of
/// these PNGs would churn on every run. Same constant and same reason as
/// `base_scaffold_appbar_golden_test.dart:30`. The goldens compare on macOS CI.
///
/// To update: derive the failing set first, then
/// `flutter test test/widgets/gateway_link_chip_golden_test.dart --update-goldens`.
@Tags(['golden'])
library;

import 'dart:io' show Platform;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc/widgets/gateway_link_chip.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

import '../helpers/themed_golden_host.dart';
import 'alarm_fixture.dart';

/// Frozen, so the header's clock does not churn the PNG every run.
final Clock _goldenClock = Clock.fixed(DateTime(2026, 8, 31, 14, 5, 9));

const _barKey = Key('gateway_link_chip_appbar_golden');

final Uri _gateway = Uri.parse('wss://10.50.10.11:9443');

/// A live session.
final GatewayLinkReport _connected = describeGatewayLink(
  state: LinkState.ready,
  url: _gateway,
  elapsed: const Duration(seconds: 4),
);

/// The retry loop stopped, and it will not restart on its own.
final GatewayLinkReport _refused = describeGatewayLink(
  state: LinkState.down,
  url: _gateway,
  elapsed: const Duration(seconds: 9),
  stopReason: GatewayLinkReasons.credentialRefused,
);

void _registerMenu() {
  // Two, not one: `NavigationBar` asserts `destinations.length >= 2` and brings
  // the whole scaffold down before the app bar is ever laid out.
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
/// `gatewayLinkProvider` is overridden with a constant report and nothing else
/// is faked: no supervisor, no socket, no clock inside the provider. The chip
/// holds no state, so a frame of it is a constant.
Widget _shell(GatewayLinkReport report, {required bool dark}) {
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
      alarmManProvider.overrideWith((ref) async => AlarmFixture()),
      gatewayLinkProvider.overrideWith((ref) => Stream.value(report)),
    ],
    child: RepaintBoundary(
      key: _barKey,
      child: BeamerProvider(
        routerDelegate: delegate,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: themedGoldenTheme(dark: dark),
          routerDelegate: delegate,
          routeInformationParser: BeamerParser(),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadThemedGoldenFonts);
  setUp(_registerMenu);
  tearDown(() => RouteRegistry().menuItems.clear());

  group('gateway link chip goldens',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    Future<void> shoot(
      WidgetTester tester,
      String name,
      GatewayLinkReport report, {
      required bool dark,
    }) async {
      tester.view.physicalSize = const Size(1600, 160);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_shell(report, dark: dark));
      // Not `pumpAndSettle`: the app bar's furniture must never contain an
      // indeterminate indicator, and a harness that could hang on one would
      // hide exactly that defect rather than report it.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Anti-vacuity. `matchesGoldenFile` will happily record an app bar with
      // no chip in it, and the resulting PNG would look entirely reasonable —
      // it is what every direct-mode station renders. Name the pill before
      // recording, so a frame that silently lost its subject fails here rather
      // than becoming the new baseline.
      expect(find.byKey(kGatewayLinkChipKey), findsOneWidget,
          reason: 'this image is only a chip golden if the chip is in it');
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'the app bar rebuilds on every navigation; a spinner in the '
              'furniture would flicker on each one');

      final suffix = dark ? '_dark' : '';
      await expectLater(
        find.byKey(_barKey),
        matchesGoldenFile('goldens/$name$suffix.png'),
      );
    }

    for (final dark in [false, true]) {
      final label = dark ? 'dark' : 'light';

      testWidgets('chip_connected, $label', (tester) async {
        await withClock(_goldenClock, () async {
          await shoot(tester, 'chip_connected', _connected, dark: dark);
        });
      });

      testWidgets('chip_refused, $label', (tester) async {
        await withClock(_goldenClock, () async {
          await shoot(tester, 'chip_refused', _refused, dark: dark);
        });
      });
    }
  });
}
