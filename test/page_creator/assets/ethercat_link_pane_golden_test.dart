import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/ethercat_link_pane.dart';
import 'package:tfc/theme.dart';

import '../../helpers/golden_tolerance.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('ethercat_link_pane');

/// The pane is almost entirely words -- uptimes, counts, the line saying which
/// way the evidence points. Without a real font every glyph renders as a solid
/// Ahem box and the golden proves the layout while saying nothing about what
/// it says.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }
}

EtherCatLinkState _state({
  bool linkUp = true,
  bool degraded = false,
  bool stale = false,
  int connectedMinutes = 0,
  int longestMinutes = 0,
  int connectCount = 1,
  int crcErrors = 0,
  int forwardedErrors = 0,
  int lostLinks = 0,
  int minutesSinceError = 0,
  double availabilityPct = 100,
  int errorsLastHour = 0,
}) =>
    EtherCatLinkState(
      linkUp: linkUp,
      communicating: linkUp,
      degraded: degraded,
      stale: stale,
      connectedMinutes: connectedMinutes,
      longestMinutes: longestMinutes,
      connectCount: connectCount,
      crcErrors: crcErrors,
      forwardedErrors: forwardedErrors,
      lostLinks: lostLinks,
      minutesSinceError: minutesSinceError,
      availabilityPct: availabilityPct,
      errorsLastHour: errorsLastHour,
    );

Widget pane(EtherCatLinkState? state, {bool withReset = true}) {
  final (light, _) = solarized();
  return MaterialApp(
    theme: light,
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: _key,
          child: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: EtherCatLinkPaneBody(
                state: state,
                onResetCounters: withReset ? () async {} : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  useTolerantGoldenComparator();

  group('EtherCAT link pane',
      skip: goldenSkip, () {
    testWidgets('a cable that has held since commissioning', (tester) async {
      // 412 days: past where a 32-bit millisecond TIME would have saturated,
      // which is the whole reason the PLC counts minutes.
      await loadRealFont();
      await tester.pumpWidget(pane(_state(
        connectedMinutes: 412 * 1440 + 7 * 60 + 23,
        longestMinutes: 412 * 1440 + 7 * 60 + 23,
        connectCount: 1,
        minutesSinceError: 412 * 1440,
        availabilityPct: 100,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_healthy.png'));
    });

    testWidgets('a marginal cable, still up and erroring', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_state(
        degraded: true,
        connectedMinutes: 3 * 1440 + 90,
        longestMinutes: 60 * 1440,
        connectCount: 14,
        crcErrors: 3820,
        forwardedErrors: 4,
        lostLinks: 13,
        minutesSinceError: 0,
        availabilityPct: 97.4,
        errorsLastHour: 61,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_degraded.png'));
    });

    testWidgets('a cable that is out', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_state(
        linkUp: false,
        connectCount: 9,
        longestMinutes: 2 * 1440,
        crcErrors: 512,
        availabilityPct: 61.2,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_down.png'));
    });

    testWidgets('errors that arrived already broken exonerate the cable',
        (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_state(
        connectedMinutes: 5000,
        longestMinutes: 5000,
        crcErrors: 900,
        forwardedErrors: 890,
        errorsLastHour: 12,
        availabilityPct: 99.9,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_upstream.png'));
    });

    testWidgets('figures that stopped updating say so', (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(_state(
        stale: true,
        connectedMinutes: 2000,
        longestMinutes: 2000,
        availabilityPct: 100,
      )));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_stale.png'));
    });

    testWidgets('a cable drawn to document wiring, with no key',
        (tester) async {
      await loadRealFont();
      await tester.pumpWidget(pane(null, withReset: false));
      await tester.pumpAndSettle();
      await expectLater(find.byKey(_key),
          matchesGoldenFile('goldens/ethercat_link_pane_unmonitored.png'));
    });
  });
}
