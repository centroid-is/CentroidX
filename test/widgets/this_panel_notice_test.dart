/// [ThisPanelNotice] — the sentence that names which machine a page acts on.
///
/// The three things worth pinning are that it appears only on a relayed
/// panel, that it names BOTH machines, and that it changes nothing about the
/// page it sits above. The third is the one that would be quietly lost: the
/// obvious "fix" for a page that describes the wrong host is to disable it,
/// and that would break an engineer legitimately configuring the panel's own
/// network.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/widgets/this_panel_notice.dart';

const GatewayConfig _relayed = GatewayConfig(
  mode: TransportMode.gateway,
  url: 'wss://gateway.svn:9443',
  caCertPath: '/etc/tfc/ca.pem',
);

const GatewayConfig _direct = GatewayConfig(mode: TransportMode.direct, url: '');

Future<void> _pump(
  WidgetTester tester, {
  required GatewayConfig gateway,
  String hostname = 'panel-ST101',
  String subject = 'network configuration',
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      gatewayConfigProvider.overrideWith((ref) async => gateway),
      panelHostnameProvider.overrideWithValue(hostname),
    ],
    child: MaterialApp(
      home: Scaffold(body: ThisPanelNotice(subject: subject)),
    ),
  ));
  // Two pumps: the provider is a future, and the first frame renders the
  // direct-mode default before it resolves.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a direct station is told nothing', (tester) async {
    await _pump(tester, gateway: _direct);
    expect(find.byKey(kThisPanelNoticeKey), findsNothing,
        reason: 'on a station the two machines are one computer, and a '
            'sentence about the difference is noise about a distinction that '
            'does not exist');
  });

  testWidgets('a relayed panel is told which machine it is looking at',
      (tester) async {
    await _pump(tester, gateway: _relayed);
    expect(find.byKey(kThisPanelNoticeKey), findsOneWidget);
    // Both machines, by name. Either half alone is still a wrong answer: the
    // panel's name without the station's does not say where the real one is,
    // and the station's without the panel's does not say what the page is
    // about.
    expect(find.textContaining('panel-ST101'), findsOneWidget);
    expect(find.textContaining('wss://gateway.svn:9443'), findsOneWidget);
    expect(find.textContaining('network configuration'), findsOneWidget);
  });

  testWidgets('the subject is the page\'s, not the widget\'s', (tester) async {
    await _pump(tester,
        gateway: _relayed, subject: 'temperatures and clock');
    expect(find.textContaining('temperatures and clock'), findsOneWidget);
  });

  testWidgets('a gateway with no address still says the station is elsewhere',
      (tester) async {
    // The load-bearing half of the sentence is that the station is another
    // machine. A panel whose URL has not been filled in yet must still say
    // it, rather than rendering "at " and trailing off.
    await _pump(tester,
        gateway: const GatewayConfig(mode: TransportMode.gateway, url: '   '));
    expect(find.byKey(kThisPanelNoticeKey), findsOneWidget);
    expect(find.textContaining('not the station serving the plant.'),
        findsOneWidget);
    expect(find.textContaining('That machine is at'), findsNothing,
        reason: 'no address means no sentence about one, not a sentence '
            'that trails off');
    expect(find.textContaining('Nothing here reaches it.'), findsOneWidget);
  });

  testWidgets('a host whose name cannot be read still gets the sentence',
      (tester) async {
    // `panelHostnameProvider` answers `this panel` when `Platform` throws.
    // The notice must read as English with that substitution rather than
    // as a template with a hole in it.
    await _pump(tester, gateway: _relayed, hostname: 'this panel');
    expect(find.textContaining('This is this panel’s network '
        'configuration'), findsOneWidget);
  });
}
