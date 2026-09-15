/// Goldens for the app bar's header: the clock and the alarm banner.
///
/// The clock used to share the centre slot with the alarm banner — whenever an
/// alarm was active the time vanished. It now lives on the left, immediately
/// right of the back arrow, on two lines (date over time) and at a size that
/// reads from across the hall. These PNGs are the record of that layout: both
/// halves visible at once, neither overlapping the logo or the controls.
///
/// The banner also answers to the page whitelist, and the second group of
/// tests here is what pins that. The banner renders alarm titles and
/// descriptions and beams to `/alarm-view` on a tap, so leaving it
/// unconditional meant a panel whitelisted down to nothing still read out the
/// plant's alarms in its top bar and still had a one-tap route into the page
/// the whitelist had taken away.
library;

import 'dart:io' show File, Platform;
import 'dart:typed_data' show ByteData;

import 'dart:async' show Completer;

import 'package:beamer/beamer.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart' show AppRoutes;
import 'package:tfc/theme.dart' show solarized;
import 'package:tfc/widgets/base_scaffold.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
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

/// A session whose whitelist is whatever a test hands it.
///
/// `allowedPages` null is the unrestricted station — the state every station
/// that never configured a whitelist is in, and the one the banner must keep
/// behaving exactly as before in.
class _FixedSession extends AccessSessionController {
  _FixedSession(this._pages, {this.resolve = true});

  final Set<String>? _pages;
  final bool resolve;

  @override
  Future<AccessSession> build() async {
    if (!resolve) return Completer<AccessSession>().future;
    return AccessSession(
      groups: const {AccessGroup.operate},
      allowedPages: _pages,
    );
  }

  @override
  Future<AccessSignInResult> signIn(String username, String password) async =>
      AccessSignInResult.ok;

  @override
  Future<void> signOut() async {}

  /// Re-resolves the session in place, the way signing in or out does. The
  /// widget tree is not rebuilt from scratch, which is the whole point when
  /// what is under test is a `State` field surviving the change.
  void setPages(Set<String>? pages) => state = AsyncData(AccessSession(
        groups: const {AccessGroup.operate},
        allowedPages: pages,
      ));
}

class _StubRepository extends Fake implements AccessRepository {}

/// The scaffold behind a router, at the window size a plant station runs.
///
/// [alarms] is what the header's alarm stream reports; empty leaves the banner
/// off and only the clock showing.
///
/// [allowedPages] is the session's whitelist: null — the default — is the
/// unrestricted station, and a set that omits [AppRoutes.alarmView] is the
/// panel this banner must stay quiet on. [sessionResolves] false holds the
/// session in its boot window.
Widget _shell(
  AlarmFixture alarms, {
  bool dark = false,
  Set<String>? allowedPages,
  bool sessionResolves = true,
  _FixedSession? sessionController,
}) {
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
    overrides: [
      alarmManProvider.overrideWith((ref) async => alarms),
      accessSessionProvider.overrideWith(() =>
          sessionController ??
          _FixedSession(allowedPages, resolve: sessionResolves)),
      accessRepositoryProvider.overrideWith((ref) async => _StubRepository()),
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

/// Pumps [_shell] at a station-sized window, optionally beamed one level deep
/// so the back arrow is present and the clock sits to the right of it.
Future<void> _pump(
  WidgetTester tester,
  AlarmFixture alarms, {
  bool dark = false,
  bool deep = false,
  Set<String>? allowedPages,
  bool sessionResolves = true,
}) async {
  tester.view.physicalSize = const Size(1600, 160);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_shell(alarms,
      dark: dark,
      allowedPages: allowedPages,
      sessionResolves: sessionResolves));
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

    testWidgets('whitelisted away from the alarm view: alarms active, bar quiet',
        (tester) async {
      // The same two alarms as the banner golden above, on a panel whose
      // whitelist does not include `/alarm-view`. A golden rather than only a
      // `findsNothing`, because what has to be true is not merely that the
      // text is gone but that the bar is *unchanged* — the clock in its place
      // on the left, the logo in its place on the right, nothing reflowed into
      // the space the banner used to hold and no gap where it was.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(), allowedPages: const {'/'});
        await expectLater(
          find.byKey(_barKey),
          matchesGoldenFile('goldens/appbar_alarms_hidden_by_whitelist.png'),
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

  group('the banner answers to the page whitelist', () {
    /// Whether any part of an alarm reached the screen.
    ///
    /// Both halves are checked because the banner renders both, and a leak of
    /// either is the leak: the title names the equipment, the description says
    /// what is wrong with it.
    void expectAlarmTextVisible({required bool visible}) {
      final matcher = visible ? findsOneWidget : findsNothing;
      expect(find.textContaining('Blóðgunarker hitastig', findRichText: true),
          matcher);
      expect(find.textContaining('Yfir efri mörkum', findRichText: true),
          matcher);
    }

    testWidgets('no whitelist: the banner is exactly what it was',
        (tester) async {
      // The station that configures nothing, which is most of them. This is
      // the regression that matters most — the fix must cost an unrestricted
      // panel nothing at all.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy());
        expectAlarmTextVisible(visible: true);
        expect(find.byType(GestureDetector), findsWidgets);
      });
    });

    testWidgets('whitelist that includes the alarm view: banner shown',
        (tester) async {
      // A whitelist is a filter, not a grant, and it is keyed on exact paths.
      // A panel that was given the alarm view keeps its banner.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(),
            allowedPages: const {'/', AppRoutes.alarmView});
        expectAlarmTextVisible(visible: true);
      });
    });

    testWidgets('whitelist without the alarm view: no alarm text, no tap',
        (tester) async {
      // The report this was written for: signed out as anonymous, anonymous
      // whitelisted to a page that is not the alarm view, and the top bar
      // still read out the plant's alarms and still beamed to the alarm view
      // when tapped.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(), allowedPages: const {'/'});
        expectAlarmTextVisible(visible: false);

        // And the clock is untouched: hiding the banner must not take the
        // time away, which is the defect the clock was moved out of the
        // banner's slot to fix in the first place.
        expect(find.text('31.08.26'), findsOneWidget);
        expect(find.text('14:05:09'), findsOneWidget);
      });
    });

    testWidgets('an empty whitelist hides it too', (tester) async {
      // "Sees no pages" is a real, distinct state from "no whitelist" — the
      // one the report was filed from — and the empty set must not be read as
      // unrestricted anywhere on this path.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(), allowedPages: const {});
        expectAlarmTextVisible(visible: false);
      });
    });

    testWidgets('the boot window shows nothing rather than guessing',
        (tester) async {
      // Until the session resolves, which whitelist this panel has is not
      // known. Fail-closed is the only direction that does not put alarm text
      // on a panel that may turn out not to be allowed it, and it costs the
      // length of the database connect — the same window `PageAccessGate`
      // already spends on `AccessCheckingBody`.
      await withClock(_goldenClock, () async {
        await _pump(tester, noisy(), sessionResolves: false);
        expectAlarmTextVisible(visible: false);
      });
    });

    testWidgets('the banner comes back when the session does, with no stream '
        'error', (tester) async {
      // `_alarmStream` is single-subscription, which is why the whitelist is
      // asked *inside* the StreamBuilder rather than in front of it. A gate
      // that removed the StreamBuilder from the tree would have it listen a
      // second time when the session re-resolved, and throw `Bad state: Stream
      // has already been listened to` — an alarm banner that works once per
      // sign-in and is a red error box after that.
      //
      // Driven through the controller rather than by pumping a second shell,
      // so the scaffold's `State` — and the one subscription it holds — is the
      // same object across the change, which is what signing in actually does.
      await withClock(_goldenClock, () async {
        final session = _FixedSession(const {'/'});
        tester.view.physicalSize = const Size(1600, 160);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_shell(noisy(), sessionController: session));
        await tester.pumpAndSettle();
        expectAlarmTextVisible(visible: false);

        session.setPages(const {'/', AppRoutes.alarmView});
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectAlarmTextVisible(visible: true);

        // And back, because a sign-out has to be survivable too.
        session.setPages(const {'/'});
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectAlarmTextVisible(visible: false);
      });
    });
  });
}
