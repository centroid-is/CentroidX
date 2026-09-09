/// Goldens for the two cards at the head of the About Linux page.
///
/// These replaced four stacked blocks — a 18px-padded hostname banner with the
/// addresses as a second row of chips, then one card each for Kernel,
/// Operating System and Support End. Together they filled most of a panel with
/// four short strings, and pushed the Date & Time section — the part an
/// operator acts on — below the fold. The PNGs are the record of what that
/// costs now: one identity band and one four-row table.
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

/// Wide enough for the switch-machine button beside a real hostname, and no
/// taller than the cards need — the frame is about how little room they take.
const Size _viewport = Size(720, 310);

/// A station's real strings: the hostname convention from the plant, a build
/// string long enough to prove the Build row ellipsizes rather than wrapping
/// to four lines, and two addresses so the identity band is exercised with
/// more than one.
Widget _cards({bool dark = false, bool switchable = true}) {
  final (light, darkTheme) = solarized();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? darkTheme : light,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AboutIdentityCard(
              hostname: 'SVN-NES-OT-CL02',
              activeIPs: const ['10.104.29.10', '10.50.10.11'],
              onSwitchConnection: switchable ? () {} : null,
            ),
            const SizedBox(height: 12),
            const AboutSystemFactsCard(
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
    await _pump(tester, _cards());
    await _expectGolden(tester, 'about_linux_cards_light.png');
  });

  testWidgets('identity and facts, dark', (tester) async {
    await _pump(tester, _cards(dark: true));
    await _expectGolden(tester, 'about_linux_cards_dark.png');
  });

  testWidgets('no switch action on a station with only a local bus',
      (tester) async {
    // `onSwitchConnection` is null when DbusGate has nothing to switch to, and
    // the band must not leave a hole where the button was.
    await _pump(tester, _cards(switchable: false));
    await _expectGolden(tester, 'about_linux_cards_no_switch.png');
  });

  testWidgets('a host that reports almost nothing still renders',
      (tester) async {
    // hostname1 on a minimal image answers GetAll with very little. Every row
    // is conditional, so the card must not become an empty box with padding.
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
                AboutIdentityCard(hostname: '', activeIPs: []),
                SizedBox(height: 12),
                AboutSystemFactsCard(
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
