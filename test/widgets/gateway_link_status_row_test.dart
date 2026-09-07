/// The live link status row, rendered — one report, six kinds, no spinner.
///
/// **Why this file exists when plan 15-05 named only two test files.** Its
/// success criterion is "the live status row renders each of the six kinds
/// distinguishably", and neither named file can measure that: the page test
/// drives the card through a provider and the source scan reads text. The
/// distinguishing is done by chrome the widget adds — a colour and a terminal
/// notice — and chrome is only observable with the widget in a tree.
///
/// **What "distinguishably" means here, precisely.** The widget does not
/// re-say the kind: the words come from [GatewayLinkReport.headline] and
/// [GatewayLinkReport.detail], which are `gateway_link_status.dart`'s and are
/// already six different sentences pinned by plan 15-01's arms. What this file
/// pins is that the widget partitions the six into the four state colours the
/// repo's vocabulary allows, that the two terminal kinds carry a *stopped
/// retrying* sentence the four retrying ones do not, and that all six reach the
/// screen with their own headline rather than a paraphrase.
///
/// The pixel half — whether the colour survives the theme into an image — is
/// plan 15-07's, which owns the themed goldens. This is the half that can be
/// measured without one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/gateway_link_status_row.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkState;

/// The six kinds, each built by the real mapper from the real inputs that
/// produce it — not hand-constructed, so a mapping change shows up here too.
final Map<GatewayLinkKind, GatewayLinkReport> _sixKinds = {
  for (final report in <GatewayLinkReport>[
    describeGatewayLink(
      state: LinkState.ready,
      url: Uri.parse('wss://10.50.10.11:9443'),
      elapsed: const Duration(seconds: 30),
    ),
    describeGatewayLink(
      state: LinkState.connecting,
      url: Uri.parse('wss://10.50.10.11:9443'),
      elapsed: const Duration(seconds: 1),
    ),
    describeGatewayLink(
      state: LinkState.connecting,
      url: Uri.parse('wss://10.50.10.11:9443'),
      elapsed: const Duration(seconds: 20),
      lastDownReason: '${GatewayLinkReasons.didNotAnswer}: OS Error: '
          'Connection refused, errno = 61',
    ),
    describeGatewayLink(
      state: LinkState.connecting,
      url: Uri.parse('wss://plc-gw.svn:9444'),
      elapsed: const Duration(seconds: 20),
      lastDownReason: GatewayLinkReasons.certificateNotTrusted,
    ),
    describeGatewayLink(
      state: LinkState.connecting,
      url: Uri.parse('wss://10.50.10.11:9443'),
      elapsed: const Duration(seconds: 20),
      stopReason: GatewayLinkReasons.credentialRefused,
    ),
    describeGatewayLink(
      state: LinkState.connecting,
      url: Uri.parse('wss://10.50.10.11:9443'),
      elapsed: const Duration(seconds: 20),
      stopReason: GatewayLinkReasons.versionRefused,
    ),
  ])
    report.kind: report,
};

Widget _host(GatewayLinkReport report, {bool dark = false}) {
  final (light, night) = solarized();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? night : light,
    home: Scaffold(
      body: Center(child: GatewayLinkStatusRow(report: report)),
    ),
  );
}

Color _markColour(WidgetTester tester) => tester
    .widget<ColoredBox>(find.descendant(
      of: find.byKey(kGatewayLinkStatusMarkKey),
      matching: find.byType(ColoredBox),
    ))
    .color;

void main() {
  test('the fixture really did produce all six kinds', () {
    // Anti-vacuity: every arm below iterates this map, and a map that lost a
    // member would silently stop testing that kind.
    expect(_sixKinds.keys, containsAll(GatewayLinkKind.values));
    expect(_sixKinds.length, GatewayLinkKind.values.length);
  });

  group('all six kinds reach the screen', () {
    for (final kind in GatewayLinkKind.values) {
      testWidgets('${kind.name}: headline and detail, verbatim',
          (tester) async {
        final report = _sixKinds[kind]!;
        await tester.pumpWidget(_host(report));

        expect(find.text(report.headline), findsOneWidget,
            reason: 'the row renders the report it is given. A widget that '
                'composes its own message is a second place the vocabulary '
                'can drift from the app-bar chip (15-06)');
        expect(find.text(report.detail), findsOneWidget);
        expect(find.byKey(kGatewayLinkStatusRowKey), findsOneWidget);
      });
    }
  });

  group('the colours partition the six', () {
    /// The mark colour for each kind, measured once.
    Future<Map<GatewayLinkKind, Color>> colours(WidgetTester tester) async {
      final out = <GatewayLinkKind, Color>{};
      for (final kind in GatewayLinkKind.values) {
        await tester.pumpWidget(_host(_sixKinds[kind]!));
        out[kind] = _markColour(tester);
      }
      return out;
    }

    testWidgets('green live, blue dialling, yellow retrying, red refused',
        (tester) async {
      final seen = await colours(tester);
      final palette = HmiStateColors.solarizedLight;

      expect(seen[GatewayLinkKind.connected], palette.green);
      expect(seen[GatewayLinkKind.connecting], palette.blue);
      // Yellow, not red: a certificate can be replaced under a running panel
      // and the panel is still retrying. Only fault red may be saturated, and
      // spending it on a condition that fixes itself is how the red that means
      // "stopped" stops being read.
      expect(seen[GatewayLinkKind.unreachable], palette.yellow);
      expect(seen[GatewayLinkKind.untrustedCertificate], palette.yellow);
      expect(seen[GatewayLinkKind.credentialRefused], palette.red);
      expect(seen[GatewayLinkKind.versionRefused], palette.red);
    });

    testWidgets('and the four are pairwise distinct', (tester) async {
      final seen = await colours(tester);
      final distinct = seen.values.toSet();
      expect(distinct.length, 4,
          reason: 'four colours over six kinds is the design; three would mean '
              'two groups had collapsed into one and an operator across the '
              'room could not tell them apart');
    });

    testWidgets('and they are the theme extension\'s, not Solarized\'s '
        'fallback, on dark', (tester) async {
      // `HmiStateColors.of` falls back to solarizedLight/Dark on a bare
      // MaterialApp, which is exactly why an unthemed test cannot catch a
      // colour regression. This one builds the real station theme.
      await tester.pumpWidget(
          _host(_sixKinds[GatewayLinkKind.credentialRefused]!, dark: true));
      final (_, night) = solarized();
      expect(_markColour(tester), night.extension<HmiStateColors>()!.red);
    });
  });

  group('a terminal report reads differently', () {
    for (final kind in GatewayLinkKind.values) {
      final report = _sixKinds[kind]!;
      testWidgets(
          '${kind.name}: the stopped-retrying notice is '
          '${report.terminal ? 'present' : 'absent'}', (tester) async {
        await tester.pumpWidget(_host(report));

        expect(
          find.byKey(kGatewayLinkTerminalNoticeKey),
          report.terminal ? findsOneWidget : findsNothing,
          reason: 'nobody is going to walk away and let a refused credential '
              'fix itself, and nobody should stand and watch a retrying one',
        );
      });
    }
  });

  group('the SAN hint', () {
    testWidgets('shows on a certificate refused for a dial by name',
        (tester) async {
      final report = _sixKinds[GatewayLinkKind.untrustedCertificate]!;
      expect(report.sanHint, isNotNull,
          reason: 'the fixture dials wss://plc-gw.svn — a name');
      await tester.pumpWidget(_host(report));

      expect(find.byKey(kGatewayLinkSanHintKey), findsOneWidget);
      expect(find.text(report.sanHint!), findsOneWidget);
    });

    testWidgets('and not on one refused for a dial by address', (tester) async {
      final byAddress = describeGatewayLink(
        state: LinkState.connecting,
        url: Uri.parse('wss://10.50.10.11:9443'),
        elapsed: const Duration(seconds: 20),
        lastDownReason: GatewayLinkReasons.certificateNotTrusted,
      );
      expect(byAddress.sanHint, isNull);
      await tester.pumpWidget(_host(byAddress));

      expect(find.byKey(kGatewayLinkSanHintKey), findsNothing);
    });
  });

  group('never a spinner, and never the gateway\'s text inline', () {
    for (final kind in GatewayLinkKind.values) {
      testWidgets('${kind.name} renders no CircularProgressIndicator',
          (tester) async {
        await tester.pumpWidget(_host(_sixKinds[kind]!));
        expect(find.byType(CircularProgressIndicator), findsNothing,
            reason: 'criterion 2: the UI stops pretending. Even connecting '
                'says what it is dialling and for how long, in words');
      });
    }

    testWidgets('raw sits behind an affordance rather than on the card',
        (tester) async {
      final report = _sixKinds[GatewayLinkKind.unreachable]!;
      expect(report.raw, contains('errno = 61'),
          reason: 'the fixture carries a real OS Error tail');
      await tester.pumpWidget(_host(report));

      // T-15-24: `raw` is the one field carrying text this app did not write.
      // It must not dominate a card an operator reads across a room — but an
      // integrator must still be able to paste it into a ticket.
      expect(find.textContaining('errno = 61'), findsNothing);
      expect(find.byKey(kGatewayLinkRawKey), findsOneWidget);

      await tester.tap(find.byKey(kGatewayLinkRawKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('errno = 61'), findsOneWidget);
    });

    testWidgets('and a report with no raw offers no affordance at all',
        (tester) async {
      final report = _sixKinds[GatewayLinkKind.connected]!;
      expect(report.raw, isNull);
      await tester.pumpWidget(_host(report));

      expect(find.byKey(kGatewayLinkRawKey), findsNothing);
    });
  });
}
