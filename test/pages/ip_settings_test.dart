import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nm/nm.dart';
import 'package:tfc/pages/ip_settings.dart';

import '../helpers/fake_network_manager.dart';
import '../helpers/test_helpers.dart';

Widget _buildPage(
  FakeNetworkManagerClient client, {
  bool internetReachable = true,
  bool dnsWorking = true,
  DateTime Function()? clock,
}) {
  // `ProviderScope`, because the body now renders [ThisPanelNotice] — a
  // `ConsumerWidget` that asks `gatewayConfigProvider` which machine this
  // panel is. With no override it answers the direct-mode default and the
  // notice renders nothing, which is what every case in this file is about.
  return ProviderScope(
    child: MaterialApp(
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

FakeNetworkManagerDevice _staticEthernet({
  FakeSettingsConnection? connection,
}) {
  return FakeNetworkManagerDevice(
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
      connection: connection ??
          FakeSettingsConnection(id: 'Wired connection 1', settings: {
            'connection': {'id': const DBusString('Wired connection 1')},
            'ipv4': {'method': const DBusString('manual')},
          }),
    ),
  );
}

Object? _nothing() => null;

/// `nm` 0.5.0 force-unwraps the object path NetworkManager returns against a
/// cache filled asynchronously, so a fast reply throws this *after* the change
/// has been committed.
Object get _nmCacheRace {
  try {
    return _nothing()!;
  } catch (e) {
    return e;
  }
}

Map<String, Map<String, DBusValue>> _profile({
  required String id,
  String interfaceName = 'eth0',
  String method = 'auto',
  String address = '',
  int prefix = 24,
}) {
  return {
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
}

void main() {
  testWidgets('device card shows live addressing details', (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('eth0'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('10.104.29.10/24'), findsOneWidget);
    expect(find.text('Static'), findsOneWidget);
    expect(find.text('10.104.29.1'), findsOneWidget);
    expect(find.text('10.104.1.1'), findsOneWidget);
    expect(find.text('00:0A:95:9D:68:16'), findsOneWidget);
    expect(find.text('1000 Mb/s'), findsOneWidget);
    expect(find.textContaining('Wired connection 1'), findsOneWidget);
  });

  testWidgets('internet and DNS probes drive the header chips',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester,
        _buildPage(client, internetReachable: false, dnsWorking: false));
    expect(find.text('No internet'), findsOneWidget);
    expect(find.text('DNS server failing'), findsOneWidget);
  });

  testWidgets('healthy probes show green chips', (tester) async {
    final client = FakeNetworkManagerClient(devices: []);
    await pumpAndLoad(tester, _buildPage(client));
    expect(find.text('Internet reachable'), findsOneWidget);
    expect(find.text('DNS server OK'), findsOneWidget);
  });

  testWidgets('RX/TX shows totals, then rates after a refresh tick',
      (tester) async {
    final stats = FakeDeviceStatistics(
        rxBytes: 1610612736, txBytes: 100 * 1024 * 1024);
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0', statistics: stats),
    ]);
    var t = DateTime(2026, 1, 1, 12);
    DateTime clock() {
      final now = t;
      t = t.add(const Duration(seconds: 2));
      return now;
    }

    await pumpAndLoad(tester, _buildPage(client, clock: clock));

    expect(stats.refreshRates, contains(2000),
        reason: 'NM only ticks counters while a refresh rate is set');
    expect(find.text('1.5 GB'), findsOneWidget);
    expect(find.text('100 MB'), findsOneWidget);

    stats.rxBytes += 4 * 1024 * 1024;
    stats.txBytes += 2 * 1024 * 1024;
    stats.emit();
    await settle(tester);

    expect(find.textContaining('2.0 MB/s'), findsOneWidget);
    expect(find.textContaining('1.0 MB/s'), findsOneWidget);
  });

  testWidgets('wifi card shows SSID, signal and DHCP method', (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(
        interface: 'wlan0',
        deviceType: NetworkManagerDeviceType.wifi,
        dhcp4Config: FakeDhcp4Config(),
        ip4Config: FakeIp4Config(addressData: [
          {'address': '192.168.1.50', 'prefix': 24},
        ]),
        wireless: FakeDeviceWireless(
          activeAccessPoint: FakeAccessPoint(ssidText: 'PlantNet', strength: 78),
        ),
        statistics: FakeDeviceStatistics(rxBytes: 1024, txBytes: 2048),
      ),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('PlantNet'), findsOneWidget);
    expect(find.text('78%'), findsOneWidget);
    expect(find.text('DHCP'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget,
        reason: 'RX/TX renders on wifi too, not just ethernet');
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  testWidgets('disconnected and no-link devices read as such', (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(
          interface: 'eth1',
          state: NetworkManagerDeviceState.disconnected),
      FakeNetworkManagerDevice(
          interface: 'eth2',
          state: NetworkManagerDeviceState.unavailable),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('No link'), findsOneWidget);
  });

  testWidgets('bond card lists its member ports', (tester) async {
    final bond = FakeNetworkManagerDevice(
      interface: 'bond0',
      deviceType: NetworkManagerDeviceType.bond,
      ip4Config: FakeIp4Config(addressData: [
        {'address': '10.104.29.20', 'prefix': 24},
      ]),
    );
    final client = FakeNetworkManagerClient(devices: [
      bond,
      FakeNetworkManagerDevice(
          interface: 'eth0',
          activeConnection: FakeActiveConnection(master: bond)),
      FakeNetworkManagerDevice(
          interface: 'eth1',
          activeConnection: FakeActiveConnection(master: bond)),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('eth0, eth1'), findsOneWidget);
    expect(find.text('active-backup'), findsOneWidget);
  });

  testWidgets('create-bond button needs two ethernet ports', (tester) async {
    final client = FakeNetworkManagerClient(
        devices: [FakeNetworkManagerDevice(interface: 'eth0')]);
    await pumpAndLoad(tester, _buildPage(client));

    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create bond'));
    expect(button.onPressed, isNull);
  });

  testWidgets('interface dialog prefills the static config', (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    expect(find.text('Settings — eth0'), findsOneWidget);
    final dhcpSwitch =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(dhcpSwitch.value, isFalse, reason: 'profile method is manual');
    expect(find.widgetWithText(TextFormField, '10.104.29.10'), findsOneWidget);
    expect(
        find.widgetWithText(TextFormField, '255.255.255.0'), findsOneWidget);
  });

  testWidgets('an invalid netmask blocks saving with an inline error',
      (tester) async {
    final connection = FakeSettingsConnection(id: 'Wired connection 1',
        settings: {
          'ipv4': {'method': const DBusString('manual')},
        });
    final client = FakeNetworkManagerClient(
        devices: [_staticEthernet(connection: connection)]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    // The old page accepted only 255.255.255.x masks; the new field takes
    // any contiguous mask but must still reject a non-contiguous one.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Netmask or prefix'),
        '255.0.255.0');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.textContaining('Enter a netmask'), findsOneWidget);
    expect(connection.updates, isEmpty);
  });

  testWidgets('saving static settings updates and bounces the connection',
      (tester) async {
    final connection = FakeSettingsConnection(id: 'Wired connection 1',
        settings: {
          'connection': {'id': const DBusString('Wired connection 1')},
          'ipv4': {'method': const DBusString('manual')},
        });
    final client = FakeNetworkManagerClient(
        devices: [_staticEthernet(connection: connection)]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Netmask or prefix'), '/16');
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Settings — eth0'), findsNothing,
        reason: 'dialog closes on success');
    final ipv4 = connection.updates.single['ipv4']!;
    expect(ipv4['method'], const DBusString('manual'));
    final entry =
        (ipv4['address-data'] as DBusArray).children.single as DBusDict;
    expect(entry.children[const DBusString('prefix')],
        const DBusVariant(DBusUint32(16)));
    expect(
        connection.updates.single['connection']?['id']?.asString(),
        'Wired connection 1',
        reason: 'non-ipv4 sections survive the update');
    expect(client.deactivations, hasLength(1));
    expect(client.activations, [('eth0', 'Wired connection 1')]);
  });

  testWidgets('a port with no connection profile creates one on save',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(
          interface: 'eth3',
          state: NetworkManagerDeviceState.disconnected),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth3'));
    await settle(tester);

    expect(find.textContaining('no active connection'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await settle(tester);

    final added = client.addAndActivated.single;
    expect(added['connection']?['interface-name'], const DBusString('eth3'));
    expect(added['ipv4']?['method'], const DBusString('auto'));
  });

  testWidgets('an interface can be taken down and brought back up',
      (tester) async {
    final upDevice = FakeNetworkManagerDevice(interface: 'eth0');
    final downDevice = FakeNetworkManagerDevice(
        interface: 'eth1', state: NetworkManagerDeviceState.disconnected);
    final client =
        FakeNetworkManagerClient(devices: [upDevice, downDevice]);
    await pumpAndLoad(tester, _buildPage(client));

    // Connected card offers Disconnect.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await settle(tester);
    expect(find.text('Connect'), findsNothing);
    await tester.tap(find.text('Disconnect'));
    await settle(tester);
    expect(upDevice.disconnectCalled, isTrue);

    // Disconnected card offers Connect, which activates the device.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await settle(tester);
    await tester.tap(find.text('Connect'));
    await settle(tester);
    expect(client.activations, [('eth1', null)]);
  });

  testWidgets('bond creation adds master plus members and activates them',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0'),
      FakeNetworkManagerDevice(interface: 'eth1'),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('Create bond'));
    await settle(tester);

    // Fewer than two members is refused.
    final createButton = find.widgetWithText(FilledButton, 'Create');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await settle(tester);
    expect(find.textContaining('at least two member ports'), findsOneWidget);
    expect(client.fakeSettings.addedConnections, isEmpty);

    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth1'));
    await settle(tester);
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await settle(tester);

    final added = client.fakeSettings.addedConnections;
    expect(added, hasLength(3));
    final master = added.first;
    expect(master['connection']?['type'], const DBusString('bond'));
    final options = master['bond']?['options'] as DBusDict;
    expect(options.children[const DBusString('mode')],
        const DBusString('active-backup'));
    for (final member in added.skip(1)) {
      expect(member['connection']?['master'], const DBusString('bond0'));
      expect(member['connection']?['slave-type'], const DBusString('bond'));
    }
    expect(client.activations, [('eth0', 'bond0-eth0'), ('eth1', 'bond0-eth1')]);
  });

  testWidgets('deleting a bond removes its master and member profiles',
      (tester) async {
    final bondConnection = FakeSettingsConnection(id: 'bond0', settings: {
      'connection': {'interface-name': const DBusString('bond0')},
    });
    final memberConnection =
        FakeSettingsConnection(id: 'bond0-eth0', settings: {
      'connection': {
        'interface-name': const DBusString('eth0'),
        'master': const DBusString('bond0'),
      },
    });
    final unrelatedConnection =
        FakeSettingsConnection(id: 'wifi', settings: {
      'connection': {'interface-name': const DBusString('wlan0')},
    });
    final client = FakeNetworkManagerClient(
      devices: [
        FakeNetworkManagerDevice(
            interface: 'bond0',
            deviceType: NetworkManagerDeviceType.bond),
        FakeNetworkManagerDevice(interface: 'eth0'),
        FakeNetworkManagerDevice(interface: 'eth1'),
      ],
      settings: FakeNetworkManagerSettings(connections: [
        bondConnection,
        memberConnection,
        unrelatedConnection,
      ]),
    );
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await settle(tester);
    await tester.tap(find.text('Delete bond'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);

    expect(bondConnection.deleted, isTrue);
    expect(memberConnection.deleted, isTrue);
    expect(unrelatedConnection.deleted, isFalse);
  });

  testWidgets('container veth ports stay out of the interface list',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'enp2s0', driver: 'igc'),
      FakeNetworkManagerDevice(
          interface: 'veth21a0bd9', driver: 'veth', managed: false),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('enp2s0'), findsOneWidget);
    expect(find.text('veth21a0bd9'), findsNothing,
        reason: 'docker plumbing is not an operator concern');
  });

  testWidgets('an unmanaged port explains itself and can be taken over',
      (tester) async {
    final device = FakeNetworkManagerDevice(
      interface: 'eno1',
      managed: false,
      state: NetworkManagerDeviceState.unmanaged,
    );
    final client = FakeNetworkManagerClient(devices: [device]);
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('Unmanaged'), findsOneWidget);
    expect(find.textContaining('NetworkManager is not controlling'),
        findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await settle(tester);
    await tester.tap(find.text('Manage with NetworkManager'));
    await settle(tester);

    expect(device.managedCalls, [true]);
  });

  testWidgets('an unmanaged port is never offered as unmanageable again',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0'),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.byIcon(Icons.more_vert));
    await settle(tester);
    expect(find.textContaining('Manage'), findsNothing,
        reason: 'a managed port offers no ownership action at all');
  });

  testWidgets('an unmanaged port cannot be bonded', (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0'),
      FakeNetworkManagerDevice(interface: 'eno1', managed: false),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create bond'));
    expect(button.onPressed, isNull,
        reason: 'only one port NetworkManager actually owns');
  });

  testWidgets('the bond dialog greys out the ports it cannot enslave',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0'),
      FakeNetworkManagerDevice(interface: 'eth1'),
      FakeNetworkManagerDevice(interface: 'eno1', managed: false),
    ]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('Create bond'));
    await settle(tester);

    final unmanaged = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, 'eno1'));
    expect(unmanaged.onChanged, isNull);
    expect(find.textContaining('take ownership'), findsOneWidget);
  });

  testWidgets('inactive saved connections are listed with their address',
      (tester) async {
    final active = FakeSettingsConnection(
        id: 'Wired connection 2', settings: _profile(id: 'Wired connection 2'));
    final inactive = FakeSettingsConnection(
      id: 'Wired connection 1',
      settings: _profile(
          id: 'Wired connection 1',
          interfaceName: 'eno1',
          method: 'manual',
          address: '10.50.10.11'),
    );
    final client = FakeNetworkManagerClient(
      devices: [
        FakeNetworkManagerDevice(
            interface: 'eth0',
            activeConnection: FakeActiveConnection(connection: active)),
      ],
      settings: FakeNetworkManagerSettings(connections: [active, inactive]),
    );
    await pumpAndLoad(tester, _buildPage(client));

    expect(find.text('Saved connections (not active)'), findsOneWidget);
    expect(find.text('Wired connection 1'), findsOneWidget);
    expect(find.text('ethernet · eno1 · 10.50.10.11/24'), findsOneWidget);
    expect(find.text('Wired connection 2'), findsNothing,
        reason: 'the active profile is already on its device card');
  });

  testWidgets('an inactive saved connection can be edited and activated',
      (tester) async {
    final inactive = FakeSettingsConnection(
      id: 'Wired connection 1',
      settings: _profile(
          id: 'Wired connection 1',
          interfaceName: 'eno1',
          method: 'manual',
          address: '10.50.10.11'),
    );
    final client = FakeNetworkManagerClient(
      devices: [
        FakeNetworkManagerDevice(
            interface: 'eno1',
            state: NetworkManagerDeviceState.unavailable),
      ],
      settings: FakeNetworkManagerSettings(connections: [inactive]),
    );
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('Wired connection 1'));
    await settle(tester);

    expect(find.text('Settings — Wired connection 1'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '10.50.10.11'), findsOneWidget,
        reason: 'the profile address, not a live lease');
    expect(find.textContaining('Editing the saved profile'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'IP Address'), '10.50.10.12');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await settle(tester);

    final entry = (inactive.updates.single['ipv4']!['address-data']
            as DBusArray)
        .children
        .single as DBusDict;
    expect(entry.children[const DBusString('address')],
        const DBusVariant(DBusString('10.50.10.12')));
    expect(client.activations, isEmpty,
        reason: 'nothing was active, so nothing gets bounced');

    await tester.tap(find.text('Activate'));
    await settle(tester);
    expect(client.activations, [('eno1', 'Wired connection 1')]);
  });

  testWidgets('a down port edits its saved profile, not a second copy',
      (tester) async {
    final saved = FakeSettingsConnection(
      id: 'Wired connection 1',
      settings: _profile(
          id: 'Wired connection 1',
          interfaceName: 'eno1',
          method: 'manual',
          address: '10.50.10.11'),
    );
    final client = FakeNetworkManagerClient(
      devices: [
        FakeNetworkManagerDevice(
            interface: 'eno1',
            state: NetworkManagerDeviceState.disconnected),
      ],
      settings: FakeNetworkManagerSettings(connections: [saved]),
    );
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eno1'));
    await settle(tester);

    expect(find.textContaining('Editing the saved profile'), findsOneWidget);
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(saved.updates, hasLength(1));
    expect(client.addAndActivated, isEmpty,
        reason: 'a duplicate profile per save was the old behaviour');
  });

  testWidgets('static fields show examples below, not as fake values',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.decoration?.hintText, isNull,
          reason: 'a greyed address inside the box reads as a real value');
    }
    expect(find.text('Example: 192.0.2.10'), findsOneWidget);
    expect(find.text('Example: 255.255.255.0 or 24'), findsOneWidget);
  });

  testWidgets('address fields ask for the keypad, the DNS list does not',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    TextInputType? keyboardOf(String label) => tester
        .widget<TextField>(find.descendant(
            of: find.widgetWithText(TextFormField, label),
            matching: find.byType(TextField)))
        .keyboardType;

    // The station's on-screen keypad carries digits and `.` — the whole of an
    // IPv4 address, and a bare prefix for the netmask.
    for (final label in [
      'IP Address',
      'Netmask or prefix',
      'Gateway (optional)',
    ]) {
      expect(keyboardOf(label),
          const TextInputType.numberWithOptions(decimal: true),
          reason: '$label is dotted digits, so it wants the keypad');
    }

    // That keypad has no comma and no space, so pinning DNS to it would make
    // a second server impossible to enter.
    expect(keyboardOf('DNS servers (comma separated)'), TextInputType.text);
  });

  testWidgets('an empty address field says it is required', (tester) async {
    final client = FakeNetworkManagerClient(devices: [_staticEthernet()]);
    await pumpAndLoad(tester, _buildPage(client));

    await tester.tap(find.text('eth0'));
    await settle(tester);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'IP Address'), '');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await settle(tester);

    expect(find.text('Required'), findsOneWidget);
  });

  testWidgets('bond creation survives the nm object-cache race',
      (tester) async {
    final client = FakeNetworkManagerClient(devices: [
      FakeNetworkManagerDevice(interface: 'eth0'),
      FakeNetworkManagerDevice(interface: 'eth1'),
    ]);
    // Every add throws the way nm does once NetworkManager has already
    // written the profile — the failure the operator saw on a bond that the
    // journal showed as created.
    client.fakeSettings.addConnectionError = _nmCacheRace;

    await pumpAndLoad(tester, _buildPage(client));
    await tester.tap(find.text('Create bond'));
    await settle(tester);
    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth1'));
    await settle(tester);
    final createButton = find.widgetWithText(FilledButton, 'Create');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await settle(tester);

    expect(find.textContaining('Failed to create bond'), findsNothing);
    expect(find.text('Bond bond0 created'), findsOneWidget);
    expect(client.fakeSettings.addedConnections, hasLength(3));
    expect(client.activations,
        [('eth0', 'bond0-eth0'), ('eth1', 'bond0-eth1')],
        reason: 'the members must still be activated');
  });

  testWidgets('a member that will not come up does not fail the bond',
      (tester) async {
    final client = FakeNetworkManagerClient(
      devices: [
        FakeNetworkManagerDevice(interface: 'eth0'),
        FakeNetworkManagerDevice(interface: 'eth1'),
      ],
      activateError: Exception('no carrier'),
    );

    await pumpAndLoad(tester, _buildPage(client));
    await tester.tap(find.text('Create bond'));
    await settle(tester);
    await tester.ensureVisible(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth0'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'eth1'));
    await settle(tester);
    final createButton = find.widgetWithText(FilledButton, 'Create');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await settle(tester);

    expect(find.text('Bond bond0 created; eth0, eth1 did not come up yet'),
        findsOneWidget);
    expect(client.fakeSettings.addedConnections, hasLength(3),
        reason: 'the profiles stay, autoconnect picks them up on link');
  });

  group('renaming a connection profile', () {
    FakeNetworkManagerDevice bondDevice(FakeSettingsConnection connection) =>
        FakeNetworkManagerDevice(
          interface: 'bond0',
          deviceType: NetworkManagerDeviceType.bond,
          activeConnection:
              FakeActiveConnection(id: 'bond0', connection: connection),
        );

    testWidgets('an active bond is renameable from its interface card',
        (tester) async {
      // The saved-connections list only shows profiles that are NOT active,
      // and the bond an operator wants to rename is normally up — so the
      // rename has to be reachable from the card.
      final connection = FakeSettingsConnection(id: 'bond0', settings: {
        'connection': {
          'id': const DBusString('bond0'),
          'uuid': const DBusString('b1'),
          'type': const DBusString('bond'),
          'interface-name': const DBusString('bond0'),
        },
      });
      final client = FakeNetworkManagerClient(
        devices: [bondDevice(connection)],
        settings: FakeNetworkManagerSettings(connections: [connection]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Interface actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename connection…'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Plant bond');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      final written = connection.updates.single;
      expect(written['connection']!['id']!.asString(), 'Plant bond');
      expect(written['connection']!['interface-name']!.asString(), 'bond0',
          reason: 'the profile stays bound to the bond0 device');
    });

    testWidgets('the dialog says the interface is not being renamed',
        (tester) async {
      // Operators reasonably expect renaming a connection called "bond0" to
      // rename the interface; say plainly that it does not.
      final connection = FakeSettingsConnection(id: 'bond0', settings: {
        'connection': {
          'id': const DBusString('bond0'),
          'interface-name': const DBusString('bond0'),
        },
      });
      final client = FakeNetworkManagerClient(
        devices: [bondDevice(connection)],
        settings: FakeNetworkManagerSettings(connections: [connection]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Interface actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename connection…'));
      await tester.pumpAndSettle();

      expect(find.textContaining('stays bound to the bond0 interface'),
          findsOneWidget);
    });

    testWidgets('a name already in use is refused before anything is written',
        (tester) async {
      final bond = FakeSettingsConnection(id: 'bond0', settings: {
        'connection': {
          'id': const DBusString('bond0'),
          'uuid': const DBusString('b1'),
          'interface-name': const DBusString('bond0'),
        },
      });
      final other = FakeSettingsConnection(id: 'eno1', settings: {
        'connection': {
          'id': const DBusString('eno1'),
          'uuid': const DBusString('e1'),
          'type': const DBusString('802-3-ethernet'),
          'interface-name': const DBusString('eno1'),
        },
      });
      final client = FakeNetworkManagerClient(
        devices: [bondDevice(bond)],
        settings: FakeNetworkManagerSettings(connections: [bond, other]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Interface actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename connection…'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'eno1');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already called'), findsOneWidget);
      expect(bond.updates, isEmpty);
    });
  });

  group('deleting a saved connection', () {
    FakeSettingsConnection savedEthernet({String id = 'spare'}) =>
        FakeSettingsConnection(id: id, settings: {
          'connection': {
            'id': DBusString(id),
            'uuid': DBusString('u-$id'),
            'type': const DBusString('802-3-ethernet'),
            'interface-name': const DBusString('eth9'),
          },
          'ipv4': {'method': const DBusString('auto')},
        });

    testWidgets('a plain saved profile can be deleted', (tester) async {
      // Previously only bonds were deletable, so a stale ethernet profile was
      // stuck in the list for good.
      final spare = savedEthernet();
      final client = FakeNetworkManagerClient(
        devices: [_staticEthernet()],
        settings: FakeNetworkManagerSettings(connections: [spare]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Delete').hitTestable());
      await tester.pumpAndSettle();

      expect(spare.deleted, isTrue);
    });

    testWidgets('the confirmation can be declined', (tester) async {
      final spare = savedEthernet();
      final client = FakeNetworkManagerClient(
        devices: [_staticEthernet()],
        settings: FakeNetworkManagerSettings(connections: [spare]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(spare.deleted, isFalse);
    });

    testWidgets('a saved profile can be renamed from its tile', (tester) async {
      final spare = savedEthernet();
      final client = FakeNetworkManagerClient(
        devices: [_staticEthernet()],
        settings: FakeNetworkManagerSettings(connections: [spare]),
      );

      await tester.pumpWidget(_buildPage(client));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename…'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Cold store spare');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(spare.updates.single['connection']!['id']!.asString(),
          'Cold store spare');
    });
  });
}
