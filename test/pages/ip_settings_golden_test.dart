/// Golden images of the IP settings page, for design review and PR
/// descriptions.
///
/// Frames: the device overview (ethernet static, wifi DHCP, a dead port,
/// RX/TX rates, healthy probe chips), the failing-probes header, a bond
/// with its member ports, the interface dialog prefilled with a static
/// config, its inline validation error, and the create-bond dialog. Plus the
/// unmanaged-port/saved-profile page, an empty static form (the examples must
/// read as examples, not as a configured address), the saved-profile dialog
/// and a bond dialog that cannot take one of the ports.
///
/// To update: flutter test test/pages/ip_settings_golden_test.dart --update-goldens --run-skipped
@Tags(['golden'])
library;


import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nm/nm.dart';
import 'package:tfc/pages/ip_settings.dart';

import '../helpers/fake_network_manager.dart';
import '../helpers/golden_fonts.dart';
import '../helpers/test_helpers.dart';

/// Tall enough for four device cards; wide enough for the details wrap to
/// stay on one or two rows per card.
const Size _viewport = Size(900, 720);

Widget _buildPage(
  FakeNetworkManagerClient client, {
  bool internetReachable = true,
  bool dnsWorking = true,
}) {
  // Traffic-rate sampling clock: two seconds per sample, so the driven
  // refresh tick below produces stable, readable rates in the images.
  var tick = DateTime(2026, 8, 25, 12);
  DateTime clock() {
    final now = tick;
    tick = tick.add(const Duration(seconds: 2));
    return now;
  }

  // `ProviderScope`, because the body now renders [ThisPanelNotice] — a
  // `ConsumerWidget` that asks `gatewayConfigProvider` which machine this
  // panel is. With no override it answers the direct-mode default and the
  // notice renders nothing, so every image in this file is unchanged; the
  // relayed look has its own golden in `this_panel_notice_golden_test.dart`.
  return ProviderScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: IpSettingsBody(
          client: client,
          probe: () async => internetReachable,
          dnsProbe: () async => dnsWorking,
          clock: clock,
        ),
      ),
    ),
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  FakeNetworkManagerClient client, {
  bool internetReachable = true,
  bool dnsWorking = true,
}) async {
  await tester.binding.setSurfaceSize(_viewport);
  // 1:1 pixels — these goldens are for reading, not for pixel archaeology.
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await pumpAndLoad(
      tester,
      _buildPage(client,
          internetReachable: internetReachable, dnsWorking: dnsWorking));
}

Future<void> _expectGolden(WidgetTester tester, String name) =>
    expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));

/// Statistics fixtures, kept module-level so the tests can drive a refresh
/// tick and put rates into the frames. Reset per test so the driven tick
/// doesn't leak counter growth into the other frames.
late FakeDeviceStatistics _eth0Stats;
late FakeDeviceStatistics _wlanStats;
late FakeDeviceStatistics _bondStats;

Future<void> _tickTraffic(
    WidgetTester tester, List<FakeDeviceStatistics> stats) async {
  for (final s in stats) {
    s.rxBytes += 8 * 1024 * 1024;
    s.txBytes += 4 * 1024 * 1024;
    s.emit();
  }
  await settle(tester);
}

FakeNetworkManagerDevice _staticEthernet() => FakeNetworkManagerDevice(
      interface: 'eth0',
      hwAddress: '00:0A:95:9D:68:16',
      mtu: 1500,
      wired: FakeDeviceWired(speed: 1000),
      statistics: _eth0Stats,
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
        connection: FakeSettingsConnection(id: 'Wired connection 1', settings: {
          'connection': {'id': const DBusString('Wired connection 1')},
          'ipv4': {'method': const DBusString('manual')},
        }),
      ),
    );

FakeNetworkManagerClient _overviewClient() => FakeNetworkManagerClient(
      devices: [
        _staticEthernet(),
        FakeNetworkManagerDevice(
          interface: 'eth1',
          hwAddress: '00:0A:95:9D:68:17',
          state: NetworkManagerDeviceState.unavailable,
          wired: FakeDeviceWired(),
        ),
        FakeNetworkManagerDevice(
          interface: 'wlan0',
          deviceType: NetworkManagerDeviceType.wifi,
          hwAddress: '48:2A:E3:11:22:33',
          mtu: 1500,
          dhcp4Config: FakeDhcp4Config(),
          ip4Config: FakeIp4Config(
            addressData: [
              {'address': '192.168.1.50', 'prefix': 24},
            ],
            gateway: '192.168.1.1',
            nameserverData: [
              {'address': '192.168.1.1'},
            ],
          ),
          wireless: FakeDeviceWireless(
            activeAccessPoint:
                FakeAccessPoint(ssidText: 'PlantNet', strength: 78),
          ),
          statistics: _wlanStats,
          activeConnection: FakeActiveConnection(id: 'PlantNet'),
        ),
      ],
    );

FakeNetworkManagerClient _bondClient() {
  final bond = FakeNetworkManagerDevice(
    interface: 'bond0',
    deviceType: NetworkManagerDeviceType.bond,
    hwAddress: '00:0A:95:9D:68:16',
    mtu: 1500,
    ip4Config: FakeIp4Config(
      addressData: [
        {'address': '10.104.29.20', 'prefix': 24},
      ],
      gateway: '10.104.29.1',
      nameserverData: [
        {'address': '10.104.1.1'},
      ],
    ),
    statistics: _bondStats,
    activeConnection: FakeActiveConnection(id: 'bond0'),
  );
  FakeNetworkManagerDevice member(String name, String mac) =>
      FakeNetworkManagerDevice(
        interface: name,
        hwAddress: mac,
        wired: FakeDeviceWired(speed: 1000),
        activeConnection:
            FakeActiveConnection(id: 'bond0-$name', master: bond),
      );
  return FakeNetworkManagerClient(devices: [
    bond,
    member('eth0', '00:0A:95:9D:68:16'),
    member('eth1', '00:0A:95:9D:68:17'),
  ]);
}

Map<String, Map<String, DBusValue>> _profile({
  required String id,
  required String interfaceName,
  String method = 'auto',
  String address = '',
  int prefix = 24,
}) =>
    {
      'connection': {
        'id': DBusString(id),
        'uuid': DBusString('uuid-$id'),
        'type': const DBusString('802-3-ethernet'),
        'interface-name': DBusString(interfaceName),
      },
      'ipv4': {
        'method': DBusString(method),
        if (address.isNotEmpty)
          'address-data': DBusArray(DBusSignature('a{sv}'), [
            DBusDict(DBusSignature('s'), DBusSignature('v'), {
              const DBusString('address'): DBusVariant(DBusString(address)),
              const DBusString('prefix'): DBusVariant(DBusUint32(prefix)),
            })
          ]),
      },
    };

/// A station with a port NetworkManager does not own and a saved profile that
/// is not running — the two states the page used to have no answer for.
FakeNetworkManagerClient _unmanagedClient() => FakeNetworkManagerClient(
      devices: [
        _staticEthernet(),
        FakeNetworkManagerDevice(
          interface: 'eno1',
          hwAddress: '00:0A:95:9D:68:18',
          managed: false,
          state: NetworkManagerDeviceState.unmanaged,
          wired: FakeDeviceWired(),
        ),
      ],
      settings: FakeNetworkManagerSettings(connections: [
        FakeSettingsConnection(
          id: 'Wired connection 1',
          settings: _profile(
              id: 'Wired connection 1',
              interfaceName: 'eno1',
              method: 'manual',
              address: '10.50.10.11'),
        ),
      ]),
    );

/// Two ports the bond can take plus one it cannot.
FakeNetworkManagerClient _bondableClient() => FakeNetworkManagerClient(
      devices: [
        _staticEthernet(),
        FakeNetworkManagerDevice(
            interface: 'eth1',
            hwAddress: '00:0A:95:9D:68:17',
            state: NetworkManagerDeviceState.disconnected,
            wired: FakeDeviceWired()),
        FakeNetworkManagerDevice(
          interface: 'eno1',
          hwAddress: '00:0A:95:9D:68:18',
          managed: false,
          state: NetworkManagerDeviceState.unmanaged,
        ),
      ],
    );

// ---------------------------------------------------------------------------
// Fonts — see server_config_reorder_golden_test.dart for the why.
// ---------------------------------------------------------------------------

void main() {
  setUpAll(loadGoldenFonts);

  setUp(() {
    _eth0Stats = FakeDeviceStatistics(
        rxBytes: 1610612736, txBytes: 100 * 1024 * 1024);
    _wlanStats = FakeDeviceStatistics(
        rxBytes: 200 * 1024 * 1024, txBytes: 48 * 1024 * 1024);
    _bondStats = FakeDeviceStatistics(
        rxBytes: 3 * 1024 * 1024 * 1024, txBytes: 512 * 1024 * 1024);
  });

  testWidgets('overview — ethernet static, dead port, wifi DHCP',
      (tester) async {
    await _pumpPage(tester, _overviewClient());
    await _tickTraffic(tester, [_eth0Stats, _wlanStats]);
    await _expectGolden(tester, 'ip_settings_overview.png');
  });

  testWidgets('probes failing — no internet, DNS failing', (tester) async {
    await _pumpPage(tester, _overviewClient(),
        internetReachable: false, dnsWorking: false);
    await _expectGolden(tester, 'ip_settings_probes_failing.png');
  });

  testWidgets('interface actions — card menu with disconnect',
      (tester) async {
    await _pumpPage(tester, _overviewClient());
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_card_menu.png');
  });

  testWidgets('bond — master card with member ports', (tester) async {
    await _pumpPage(tester, _bondClient());
    await _tickTraffic(tester, [_bondStats]);
    await _expectGolden(tester, 'ip_settings_bond.png');
  });

  testWidgets('interface dialog — static config prefilled', (tester) async {
    await _pumpPage(tester, _overviewClient());
    await tester.tap(find.text('eth0'));
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_dialog_static.png');
  });

  testWidgets('interface dialog — inline netmask error', (tester) async {
    await _pumpPage(tester, _overviewClient());
    await tester.tap(find.text('eth0'));
    await settle(tester);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Netmask or prefix'),
        '255.0.255.0');
    await tester.tap(find.text('Save'));
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_dialog_error.png');
  });

  testWidgets('create-bond dialog — two members, primary chosen',
      (tester) async {
    await _pumpPage(tester, _overviewClient());
    await tester.tap(find.text('Create bond'));
    await settle(tester);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth1'));
    await settle(tester);
    await tester.tap(find.text('Automatic'));
    await settle(tester);
    await tester.tap(find.text('eth0').last);
    await settle(tester);

    await _expectGolden(tester, 'ip_settings_bond_dialog.png');
  });

  testWidgets('unmanaged port and a saved profile that is not running',
      (tester) async {
    await _pumpPage(tester, _unmanagedClient());
    await _expectGolden(tester, 'ip_settings_unmanaged.png');
  });

  testWidgets('interface actions — taking ownership of an unmanaged port',
      (tester) async {
    await _pumpPage(tester, _unmanagedClient());
    // eno1 sorts first, so its menu is the first one.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_manage_menu.png');
  });

  testWidgets('interface dialog — empty static form reads as empty',
      (tester) async {
    await _pumpPage(tester, _overviewClient());
    await tester.tap(find.text('eth1'));
    await settle(tester);
    await tester.tap(find.byType(SwitchListTile));
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_dialog_empty.png');
  });

  testWidgets('interface dialog — editing a saved, inactive profile',
      (tester) async {
    await _pumpPage(tester, _unmanagedClient());
    await tester.tap(find.text('Wired connection 1'));
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_dialog_saved.png');
  });

  testWidgets('create-bond dialog — a port it cannot enslave', (tester) async {
    await _pumpPage(tester, _bondableClient());
    await tester.tap(find.text('Create bond'));
    await settle(tester);
    await _expectGolden(tester, 'ip_settings_bond_dialog_unmanaged.png');
  });
}
