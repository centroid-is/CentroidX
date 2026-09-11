/// Goldens for the card at the head of the About Linux page.
///
/// It replaced four stacked blocks — a 18px-padded hostname banner with the
/// addresses as a second row of chips, then one card each for Kernel,
/// Operating System and Support End — which were then two cards, an identity
/// band and a facts table with a gap between them. They are now one card:
/// tinted header band for the hostname and its addresses, label/value rows
/// under it for what the machine is running. The PNGs are the record of what
/// that costs — and of the band no longer carrying a Switch machine action.
///
/// Both themes, because `colorScheme.outline` is unset in either scheme and a
/// card that reads fine on light can lose its edge entirely on dark.
///
/// To update: flutter test test/pages/about_linux_cards_golden_test.dart --update-goldens
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/about_linux.dart';
import 'package:tfc/theme.dart' show solarized;

import '../helpers/golden_fonts.dart';

/// A panel's width, and no taller than the card needs — the frame is about
/// how little room it takes.
const Size _viewport = Size(720, 280);

/// A station's real strings: the hostname convention from the plant, a build
/// string long enough to prove the Build row ellipsizes rather than wrapping
/// to four lines, and two addresses so the header band is exercised with more
/// than one.
Widget _card({bool dark = false}) {
  final (light, darkTheme) = solarized();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? darkTheme : light,
    home: const Scaffold(
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AboutSystemCard(
              hostname: 'SVN-NES-OT-CL02',
              activeIPs: ['10.104.29.10', '10.50.10.11'],
              osPretty: 'Debian GNU/Linux 12 (bookworm)',
              kernel: 'Linux 6.1.0-18-amd64',
              kernelVersion:
                  '#1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2026-02-01)',
              supportEnd: '2028-06-30 00:00:00',
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these are for reading, not pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

void main() {
  setUpAll(loadGoldenFonts);

  testWidgets('identity and facts, light', (tester) async {
    await _pump(tester, _card());
    await _expectGolden(tester, 'about_linux_cards_light.png');
  });

  testWidgets('identity and facts, dark', (tester) async {
    await _pump(tester, _card(dark: true));
    await _expectGolden(tester, 'about_linux_cards_dark.png');
  });

  testWidgets('the header band carries no switch-machine action',
      (tester) async {
    // The page auto-connects to the local bus and no longer offers to point
    // itself at another station's, so the band is identity only. Asserted
    // rather than left to the eye: a stray action here is the one thing the
    // PNG diff is least likely to make anyone look twice at.
    await _pump(tester, _card());
    expect(find.text('Switch machine'), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('a host that reports almost nothing still renders',
      (tester) async {
    // hostname1 on a minimal image answers GetAll with very little. Every row
    // is conditional, so the body must collapse away rather than becoming an
    // empty box with padding under the band.
    await _pump(
      tester,
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: solarized().$1,
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AboutSystemCard(
                  hostname: '',
                  activeIPs: [],
                  osPretty: '',
                  kernel: 'Linux 6.1.0-18-amd64',
                  kernelVersion: '',
                  supportEnd: '',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _expectGolden(tester, 'about_linux_cards_sparse.png');
  });
}
