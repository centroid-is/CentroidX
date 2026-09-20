/// `/advanced/ip-settings` — `administer` — over the relay.
///
/// This page reads and writes NetworkManager over D-Bus on the machine it
/// runs on. Nothing about it crosses the relay, and nothing should: a panel's
/// own IP address is the one thing a backend has no say over. What the relay
/// DOES decide is who may open it — the session's groups come from
/// `session.login` — so that is the property proven here: the gate reads the
/// GATEWAY's answer. The NetworkManager behind the body is the fake the page's
/// own tests use (`test/helpers/fake_network_manager.dart`); a D-Bus daemon
/// is not something a CI runner has, and it is not what this lane is about.
library;

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/ip_settings.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/widgets/access_gate.dart';

import '../../helpers/fake_network_manager.dart';
import '../support/backend_bench.dart';
import '../support/panel.dart';

const String _route = '/advanced/ip-settings';
const String _title = 'IP Settings';

Widget _page() => Scaffold(
      body: IpSettingsBody(
        client: FakeNetworkManagerClient(devices: [
          FakeNetworkManagerDevice(
            interface: 'eth0',
            hwAddress: '00:0A:95:9D:68:16',
            mtu: 1500,
            wired: FakeDeviceWired(speed: 1000),
            ip4Config: FakeIp4Config(
              addressData: [
                {'address': '10.104.29.10', 'prefix': 24},
              ],
              gateway: '10.104.29.1',
              nameserverData: [
                {'address': '10.104.1.1'},
              ],
            ),
            activeConnection: FakeActiveConnection(
              id: 'Wired connection 1',
              connection: FakeSettingsConnection(
                  id: 'Wired connection 1',
                  settings: {
                    'connection': {
                      'id': const DBusString('Wired connection 1')
                    },
                    'ipv4': {'method': const DBusString('manual')},
                  }),
            ),
          ),
        ]),
        probe: () async => true,
        dnsProbe: () async => true,
      ),
    );

void ipSettingsCases(BackendBench Function() bench) {
  group('the IP settings page', () {
    testWidgets('opens for an engineer the gateway verified, and shows the '
        'machine\'s interface', (tester) async {
      await useDesktopSurface(tester, size: const Size(1200, 1600));
      final panel = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kEngineer, kEngineerPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(panel, _route, _title, _page()));
      await untilFound(tester, find.textContaining('eth0'),
          describe: 'the interface row');
      await untilFound(tester, find.textContaining('10.104.29.10'),
          describe: 'its address');
      expect(find.byKey(kAccessLockedBodyKey), findsNothing);
      await dismount(tester);
    });

    testWidgets('locks for a verified operator and for nobody — nothing '
        'about this page is on the wire, and its gate still reads the '
        'gateway\'s session', (tester) async {
      await useDesktopSurface(tester, size: const Size(1200, 1400));
      final op = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        expect(await p.signIn(kOperator, kOperatorPassword),
            AccessSignInResult.ok);
        return p;
      });
      await tester.pumpWidget(hostRoute(op, _route, _title, _page()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.textContaining('eth0'), findsNothing);
      await dismount(tester);

      final nobody = await live(tester, () async {
        final p = await Panel.dial(bench().port);
        await p.ready();
        return p;
      });
      await tester.pumpWidget(hostRoute(nobody, _route, _title, _page()));
      await untilFound(tester, find.byKey(kAccessLockedBodyKey));
      expect(find.textContaining('eth0'), findsNothing);
      await dismount(tester);
    });
  });
}
