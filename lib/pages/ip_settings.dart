import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:nm/nm.dart';

import '../core/network_manager_ops.dart';
import '../core/network_settings.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/panes/pane_chrome.dart';
import '../widgets/this_panel_notice.dart';
import '../widgets/panes/standard_dialog.dart';

/// Network configuration for the machine this panel runs on: every
/// ethernet/wifi/bond interface as a card with its live addressing, a
/// per-interface IPv4 dialog, and creation of active-backup bonds for
/// stations with redundant cabling.
///
/// **"the machine this panel runs on", not "the station".** The two are the
/// same computer on a direct station and two computers on a relayed panel,
/// where every card here describes the panel's own NetworkManager and an
/// engineer reconfiguring one is changing the wrong host. [ThisPanelNotice]
/// at the top of the body says so, and says it only where it is true.

class IpSettingsPage extends StatelessWidget {
  final DBusClient dbusClient;

  const IpSettingsPage({super.key, required this.dbusClient});

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: 'IP Settings',
      body: IpSettingsBody(dbusClient: dbusClient),
    );
  }
}

/// The page content, split from [IpSettingsPage] so tests can pump it
/// without [BaseScaffold]'s routing context and with an injected client.
class IpSettingsBody extends StatefulWidget {
  final DBusClient? dbusClient;

  /// Test seam — a fake client bypasses the D-Bus connection entirely.
  @visibleForTesting
  final NetworkManagerClient? client;

  /// Test seam — replaces the TCP probe to [internetProbeHost].
  @visibleForTesting
  final Future<bool> Function()? probe;

  /// Test seam — replaces the DNS lookup of [dnsProbeHostname].
  @visibleForTesting
  final Future<bool> Function()? dnsProbe;

  /// Test seam — replaces [DateTime.now] in the traffic-rate sampling.
  @visibleForTesting
  final DateTime Function()? clock;

  const IpSettingsBody(
      {super.key,
      this.dbusClient,
      this.client,
      this.probe,
      this.dnsProbe,
      this.clock})
      : assert(dbusClient != null || client != null,
            'Either a dbusClient or an injected client is required');

  @override
  IpSettingsBodyState createState() => IpSettingsBodyState();
}

class IpSettingsBodyState extends State<IpSettingsBody> {
  late final NetworkManagerClient client;
  late final bool _ownsClient;
  late final Future<void> _connectFuture;
  final List<StreamSubscription> _subscriptions = [];

  /// null while the first probe is in flight.
  bool? _internetReachable;
  bool? _dnsWorking;
  Timer? _probeTimer;
  bool _probing = false;

  /// Saved profiles, refreshed whenever NetworkManager's connection list
  /// changes. Reading them needs a D-Bus round trip each, so they are resolved
  /// once here rather than in `build`.
  List<SavedConnection> _savedConnections = [];

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.client == null;
    client =
        widget.client ?? NetworkManagerClient(bus: widget.dbusClient);
    _connectFuture = client.connect().then((_) => _subscribe());
    _runProbe();
    _probeTimer = Timer.periodic(
        const Duration(seconds: 10), (_) => _runProbe());
  }

  static Future<bool> _tcpProbe() async {
    try {
      final socket = await Socket.connect(
          internetProbeHost, internetProbePort,
          timeout: const Duration(seconds: 3));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _dnsLookupProbe() async {
    try {
      final addresses = await InternetAddress.lookup(dnsProbeHostname)
          .timeout(const Duration(seconds: 3));
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _runProbe() async {
    if (_probing) return;
    _probing = true;
    try {
      final results = await Future.wait([
        (widget.probe ?? _tcpProbe)(),
        (widget.dnsProbe ?? _dnsLookupProbe)(),
      ]);
      if (mounted &&
          (results[0] != _internetReachable || results[1] != _dnsWorking)) {
        setState(() {
          _internetReachable = results[0];
          _dnsWorking = results[1];
        });
      }
    } finally {
      _probing = false;
    }
  }

  void _subscribe() {
    void refresh(dynamic _) {
      if (mounted) setState(() {});
    }

    for (final device in client.devices) {
      if (_isCardWorthy(device)) {
        _enableTrafficCounters(device);
      }
    }
    _subscriptions.add(client.deviceAdded.where(_isCardWorthy).listen((device) {
      _enableTrafficCounters(device);
      refresh(device);
    }));
    _subscriptions.add(client.deviceRemoved.where(_isCardWorthy).listen(refresh));
    // Primary connection, connectivity, etc.
    _subscriptions.add(client.propertiesChanged.listen(refresh));
    // The `Connections` property fires when a profile is added or deleted.
    _subscriptions
        .add(client.settings.propertiesChanged.listen((_) => _loadSaved()));
    unawaited(_loadSaved());
    if (mounted) setState(() {});
  }

  Future<void> _loadSaved() async {
    List<SavedConnection> saved;
    try {
      saved = await loadSavedConnections(client);
    } catch (_) {
      // Nothing to show; the device cards still work.
      return;
    }
    if (!mounted) return;
    setState(() => _savedConnections = saved);
  }

  /// NM only ticks the RX/TX counters while a refresh rate is set.
  static void _enableTrafficCounters(NetworkManagerDevice device) {
    final statistics = device.statistics;
    if (statistics == null) return;
    unawaited(statistics.setRefreshRateMs(2000).catchError((Object _) {
      // Counters simply stay static.
    }));
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_ownsClient) client.close();
    super.dispose();
  }

  static bool _supportedDeviceType(NetworkManagerDeviceType type) {
    return type == NetworkManagerDeviceType.ethernet ||
        type == NetworkManagerDeviceType.wifi ||
        type == NetworkManagerDeviceType.bond;
  }

  /// Container plumbing (`veth…` pairs from docker/podman) reports as
  /// ethernet, so a station running containers would otherwise bury its real
  /// ports under a dozen cards nobody can act on.
  static bool _isVirtualPort(NetworkManagerDevice device) =>
      device.driver == 'veth';

  static bool _isCardWorthy(NetworkManagerDevice device) =>
      _supportedDeviceType(device.deviceType) && !_isVirtualPort(device);

  static int _typeOrder(NetworkManagerDeviceType type) {
    switch (type) {
      case NetworkManagerDeviceType.bond:
        return 0;
      case NetworkManagerDeviceType.ethernet:
        return 1;
      default:
        return 2;
    }
  }

  List<NetworkManagerDevice> get _relevantDevices {
    final devices = client.devices.where(_isCardWorthy).toList();
    devices.sort((a, b) {
      final order = _typeOrder(a.deviceType) - _typeOrder(b.deviceType);
      return order != 0 ? order : a.interface.compareTo(b.interface);
    });
    return devices;
  }

  /// Ports a bond could actually take: real ethernet, managed by
  /// NetworkManager. An unmanaged port cannot be enslaved, so counting it
  /// would offer a bond that is guaranteed to fail.
  List<NetworkManagerDevice> get _bondableDevices => client.devices
      .where((device) =>
          device.deviceType == NetworkManagerDeviceType.ethernet &&
          !_isVirtualPort(device) &&
          device.managed)
      .toList();

  /// Saved profiles nothing is currently running — the ones nmtui shows and
  /// this page used to hide, so a static address on a port with no carrier
  /// could not be read back or corrected.
  List<SavedConnection> get _inactiveSavedConnections {
    final active = <NetworkManagerSettingsConnection>{};
    for (final device in client.devices) {
      final connection = device.activeConnection?.connection;
      if (connection != null) active.add(connection);
    }
    return _savedConnections
        .where((saved) => !active.contains(saved.connection))
        .toList();
  }

  PaneStatus _internetStatus() {
    switch (_internetReachable) {
      case true:
        return const PaneStatus.running('Internet reachable');
      case false:
        return const PaneStatus.stopped('No internet');
      default:
        return const PaneStatus.unknown('Checking internet…');
    }
  }

  PaneStatus _dnsStatus() {
    switch (_dnsWorking) {
      case true:
        return const PaneStatus.running('DNS server OK');
      case false:
        return const PaneStatus.warning('DNS server failing');
      default:
        return const PaneStatus.unknown('Checking DNS…');
    }
  }

  NetworkManagerDevice? _deviceFor(String interfaceName) {
    if (interfaceName.isEmpty) return null;
    for (final device in client.devices) {
      if (device.interface == interfaceName) return device;
    }
    return null;
  }

  Future<void> _openInterfaceSettings(NetworkManagerDevice device) async {
    await showDialog(
      context: context,
      builder: (context) =>
          InterfaceSettingsDialog(nmClient: client, device: device),
    );
    if (!mounted) return;
    setState(() {});
    await _loadSaved();
  }

  Future<void> _openSavedConnection(SavedConnection saved) async {
    await showDialog(
      context: context,
      builder: (context) => InterfaceSettingsDialog(
        nmClient: client,
        device: _deviceFor(saved.interfaceName),
        connection: saved.connection,
        titleOverride: saved.id,
      ),
    );
    if (!mounted) return;
    setState(() {});
    await _loadSaved();
  }

  /// Whether [device] has a connection profile at all — an active one, or a
  /// saved one bound to its interface.
  bool _hasProfile(NetworkManagerDevice device) =>
      device.activeConnection?.connection != null ||
      _savedConnections.any((c) => c.interfaceName == device.interface);

  /// Renames the profile behind an interface's active connection.
  ///
  /// Reached from the interface card, because the saved-connections list only
  /// shows profiles that are *not* active — and a bond an operator wants to
  /// rename is usually up.
  Future<void> _renameDeviceConnection(NetworkManagerDevice device) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final connection = device.activeConnection?.connection ??
        await findConnectionForInterface(client, device.interface);
    if (connection == null) {
      scaffoldMessenger.showSnackBar(SnackBar(
        content: Text('${device.interface} has no connection profile to rename'),
      ));
      return;
    }

    String id;
    try {
      id = connectionField(await connection.getSettings(), 'id');
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Could not read the profile: $e')),
      );
      return;
    }
    if (!mounted) return;

    await _renameSaved(SavedConnection(
      connection: connection,
      id: id,
      uuid: '',
      type: '',
      interfaceName: device.interface,
      ipv4: const Ipv4Prefill(),
    ));
  }

  /// Renames the saved profile — its label, not the interface it binds to.
  ///
  /// The distinction is the point for a bond: an operator wants "Plant bond"
  /// in the list without detaching the profile from the bond0 device.
  Future<void> _renameSaved(SavedConnection saved) async {
    final others = _savedConnections
        .where((c) => c.uuid != saved.uuid)
        .map((c) => c.id)
        .toList();
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _RenameConnectionDialog(
        currentId: saved.id,
        existingIds: others,
        interfaceName: saved.interfaceName,
      ),
    );
    if (newName == null || !mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await renameConnection(saved.connection, newName);
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Renamed to "$newName"')),
      );
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to rename: $e')),
      );
    }
    if (!mounted) return;
    setState(() {});
    await _loadSaved();
  }

  /// Deletes a saved profile, and — for a bond master — its members too.
  Future<void> _deleteSaved(SavedConnection saved) async {
    final removed = await connectionsRemovedWith(client, saved.connection);
    if (!mounted) return;

    final extra = removed.length - 1;
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete "${saved.id}"?',
      message: extra > 0
          // Naming the count matters: deleting a bond quietly takes its
          // member profiles with it, and the ports go down.
          ? 'This also removes $extra member '
              '${extra == 1 ? 'profile' : 'profiles'} enslaved to it. '
              'Members fall back to their own profiles, if any.'
          : 'The saved connection profile is removed. If it is active, the '
              'interface loses its addressing.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final failed = await deleteConnections(removed);
    scaffoldMessenger.showSnackBar(SnackBar(
      content: Text(failed.isEmpty
          ? 'Deleted "${saved.id}"'
          : 'Deleted, but ${failed.length} profile(s) could not be removed'),
    ));
    if (!mounted) return;
    setState(() {});
    await _loadSaved();
  }

  Future<void> _activateSaved(SavedConnection saved) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final device = _deviceFor(saved.interfaceName);
    if (device == null) {
      scaffoldMessenger.showSnackBar(SnackBar(
          content: Text(
              'No interface named ${saved.interfaceName} on this station')));
      return;
    }
    try {
      await activateConnectionResilient(client,
          device: device, connection: saved.connection);
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to activate ${saved.id}: $e')),
      );
    }
    if (mounted) setState(() {});
  }

  /// Hands an interface to NetworkManager. The reverse is deliberately not
  /// offered: unmanaging a port from here would drop the station's own link
  /// with no way back through this page.
  Future<void> _manageDevice(NetworkManagerDevice device) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await device.setManaged(true);
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
            content: Text('Failed to manage ${device.interface}: $e')),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _openCreateBond() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => CreateBondDialog(nmClient: client),
    );
    if (created == true && mounted) setState(() {});
  }

  Future<void> _disconnectDevice(NetworkManagerDevice device) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await device.disconnect();
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to disconnect: $e')),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _connectDevice(NetworkManagerDevice device) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      await client.activateConnection(device: device);
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to connect: $e')),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _deleteBond(NetworkManagerDevice device) async {
    final bondName = device.interface;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete bond $bondName?'),
        content: const Text(
            'The bond and its member connections are removed. Members fall '
            'back to their own connection profiles, if any.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    try {
      for (final connection in client.settings.connections) {
        final settings = await connection.getSettings();
        final section = settings['connection'] ?? {};
        final interfaceName = section['interface-name']?.asString();
        final master = section['master']?.asString();
        if (interfaceName == bondName || master == bondName) {
          await connection.delete();
        }
      }
    } catch (e) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('Failed to delete bond: $e')),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: _connectFuture,
        builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
          Widget body;
          if (snapshot.hasError) {
            body = Center(
              child: Text(
                'Failed to connect to NetworkManager: ${snapshot.error}',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            );
          } else if (snapshot.connectionState != ConnectionState.done) {
            body = const Center(child: CircularProgressIndicator());
          } else {
            final devices = _relevantDevices;
            final inactive = _inactiveSavedConnections;
            body = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Above the status chips, because it changes what they mean:
                // "Internet" and "DNS" are this panel's reachability, not the
                // plant's.
                const ThisPanelNotice(subject: 'network configuration'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Row(
                    children: [
                      PaneStatusChip(status: _internetStatus()),
                      const SizedBox(width: 8),
                      PaneStatusChip(status: _dnsStatus()),
                      const Spacer(),
                      Tooltip(
                        message: _bondableDevices.length >= 2
                            ? 'Bond two ethernet ports for failover '
                                '(active-backup)'
                            : 'Needs at least two NetworkManager-managed '
                                'ethernet ports',
                        child: FilledButton.tonalIcon(
                          onPressed: _bondableDevices.length >= 2
                              ? _openCreateBond
                              : null,
                          icon: const Icon(Icons.device_hub),
                          label: const Text('Create bond'),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: devices.isEmpty && inactive.isEmpty
                      ? const Center(
                          child: Text('No relevant network devices found.'))
                      : ListView(
                          children: [
                            for (final device in devices)
                              DeviceCard(
                                client: client,
                                device: device,
                                clock: widget.clock ?? DateTime.now,
                                onConfigure: () =>
                                    _openInterfaceSettings(device),
                                onConnect: () => _connectDevice(device),
                                onDisconnect: () => _disconnectDevice(device),
                                onManage: device.managed
                                    ? null
                                    : () => _manageDevice(device),
                                onDeleteBond: device.deviceType ==
                                        NetworkManagerDeviceType.bond
                                    ? () => _deleteBond(device)
                                    : null,
                                // Only when there is a profile to rename:
                                // offering it on a bare port would open a
                                // dialog that can only fail.
                                onRenameConnection: _hasProfile(device)
                                    ? () => _renameDeviceConnection(device)
                                    : null,
                              ),
                            if (inactive.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    20, 20, 20, 4),
                                child: Text(
                                  'Saved connections (not active)',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall,
                                ),
                              ),
                              for (final saved in inactive)
                                SavedConnectionTile(
                                  saved: saved,
                                  onEdit: () => _openSavedConnection(saved),
                                  onActivate:
                                      _deviceFor(saved.interfaceName) == null
                                          ? null
                                          : () => _activateSaved(saved),
                                  onRename: () => _renameSaved(saved),
                                  onDelete: () => _deleteSaved(saved),
                                ),
                            ],
                          ],
                        ),
                ),
              ],
            );
          }
          return body;
        });
  }
}

// ---------------------------------------------------------------------------
// Device card
// ---------------------------------------------------------------------------

/// One network interface: identity, live status chip, and the addressing an
/// operator actually asks about (IP, gateway, DNS, MAC, link speed, SSID),
/// plus RX/TX traffic with rates once two statistics samples are in.
class DeviceCard extends StatefulWidget {
  final NetworkManagerClient client;
  final NetworkManagerDevice device;
  final VoidCallback onConfigure;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  /// Non-null only while the port is unmanaged; taking ownership is offered,
  /// giving it up is not.
  final VoidCallback? onManage;
  final VoidCallback? onDeleteBond;

  /// Renames the profile behind the active connection. Null when the
  /// interface has none — there is no label to change.
  final VoidCallback? onRenameConnection;

  final DateTime Function() clock;

  const DeviceCard({
    super.key,
    required this.client,
    required this.device,
    required this.onConfigure,
    required this.onConnect,
    required this.onDisconnect,
    this.onManage,
    this.onDeleteBond,
    this.onRenameConnection,
    this.clock = DateTime.now,
  });

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  final _tracker = TrafficRateTracker();
  NetworkManagerDeviceStatistics? _statistics;
  StreamSubscription? _statisticsSubscription;

  @override
  void initState() {
    super.initState();
    _attachStatistics();
  }

  @override
  void didUpdateWidget(DeviceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attachStatistics();
  }

  void _attachStatistics() {
    final statistics = widget.device.statistics;
    if (statistics == _statistics) return;
    _statisticsSubscription?.cancel();
    _statistics = statistics;
    if (statistics == null) return;
    _sample(statistics);
    _statisticsSubscription = statistics.propertiesChanged.listen((_) {
      _sample(statistics);
      if (mounted) setState(() {});
    });
  }

  void _sample(NetworkManagerDeviceStatistics statistics) {
    _tracker.update(
        widget.clock(), statistics.rxBytes, statistics.txBytes);
  }

  @override
  void dispose() {
    _statisticsSubscription?.cancel();
    super.dispose();
  }

  List<PopupMenuItem<String>> _menuItems(NetworkManagerDevice device) {
    return [
      if (widget.onManage != null)
        const PopupMenuItem(
            value: 'manage', child: Text('Manage with NetworkManager')),
      if (device.state == NetworkManagerDeviceState.activated)
        const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
      if (device.state == NetworkManagerDeviceState.disconnected)
        const PopupMenuItem(value: 'connect', child: Text('Connect')),
      if (widget.onRenameConnection != null)
        const PopupMenuItem(
            value: 'rename', child: Text('Rename connection…')),
      if (widget.onDeleteBond != null)
        const PopupMenuItem(value: 'delete', child: Text('Delete bond')),
    ];
  }

  static IconData _iconFromType(NetworkManagerDeviceType type) {
    switch (type) {
      case NetworkManagerDeviceType.ethernet:
        return Icons.settings_ethernet;
      case NetworkManagerDeviceType.wifi:
        return Icons.wifi;
      case NetworkManagerDeviceType.bond:
        return Icons.device_hub;
      default:
        return Icons.question_mark;
    }
  }

  static PaneStatus _statusFor(NetworkManagerDevice device) {
    switch (device.state) {
      case NetworkManagerDeviceState.activated:
        return const PaneStatus.running('Connected');
      case NetworkManagerDeviceState.disconnected:
        return const PaneStatus.stopped('Disconnected');
      case NetworkManagerDeviceState.unavailable:
        return const PaneStatus(
            label: 'No link', color: Colors.amber, icon: Icons.link_off);
      case NetworkManagerDeviceState.failed:
        return const PaneStatus.fault('Failed');
      case NetworkManagerDeviceState.deactivating:
        return const PaneStatus.stopped('Disconnecting…');
      case NetworkManagerDeviceState.unmanaged:
        return const PaneStatus.unknown('Unmanaged');
      case NetworkManagerDeviceState.unknown:
        return const PaneStatus.unknown();
      default:
        return const PaneStatus.warning('Connecting…');
    }
  }

  List<(String, String)> _details() {
    final device = widget.device;
    final details = <(String, String)>[];
    final ip4 = device.ip4Config;

    final addresses = ip4?.addressData
            .map((data) => '${data['address']}/${data['prefix']}')
            .join(', ') ??
        '';
    if (addresses.isNotEmpty) {
      details.add(('IPv4', addresses));
      details.add(
          ('Method', device.dhcp4Config != null ? 'DHCP' : 'Static'));
    }
    final gateway = ip4?.gateway ?? '';
    if (gateway.isNotEmpty) details.add(('Gateway', gateway));
    final dns =
        ip4?.nameserverData.map((data) => data['address']).join(', ') ?? '';
    if (dns.isNotEmpty) details.add(('DNS', dns));

    if (device.hwAddress.isNotEmpty) details.add(('MAC', device.hwAddress));

    final wired = device.wired;
    if (wired != null && wired.speed > 0) {
      details.add(('Speed', '${wired.speed} Mb/s'));
    }
    if (device.mtu > 0) details.add(('MTU', '${device.mtu}'));

    final statistics = device.statistics;
    if (statistics != null) {
      final rates = _tracker.rates;
      details.add((
        'RX',
        rates == null
            ? formatBytes(statistics.rxBytes)
            : '${formatRate(rates.rxPerSecond)} · '
                '${formatBytes(statistics.rxBytes)}',
      ));
      details.add((
        'TX',
        rates == null
            ? formatBytes(statistics.txBytes)
            : '${formatRate(rates.txPerSecond)} · '
                '${formatBytes(statistics.txBytes)}',
      ));
    }

    final accessPoint = device.wireless?.activeAccessPoint;
    if (accessPoint != null) {
      final ssid = utf8.decode(accessPoint.ssid, allowMalformed: true);
      if (ssid.isNotEmpty) details.add(('SSID', ssid));
      details.add(('Signal', '${accessPoint.strength}%'));
    }

    if (device.deviceType == NetworkManagerDeviceType.bond) {
      final members = widget.client.devices
          .where((d) =>
              d.activeConnection?.master?.interface == device.interface)
          .map((d) => d.interface)
          .toList()
        ..sort();
      details.add((
        'Members',
        members.isEmpty ? 'none' : members.join(', '),
      ));
      details.add(('Mode', 'active-backup'));
    }
    return details;
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final onConfigure = widget.onConfigure;
    final onDeleteBond = widget.onDeleteBond;
    return StreamBuilder<Object>(
        stream: device.propertiesChanged,
        builder: (context, snapshot) {
          final theme = Theme.of(context);
          final status = _statusFor(device);
          final connectionId = device.activeConnection?.id ?? '';
          final subtitle = connectionId.isEmpty
              ? device.deviceType.name
              : '${device.deviceType.name} · $connectionId';
          return Card(
            margin:
                const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: InkWell(
              borderRadius: BorderRadius.circular(12.0),
              onTap: onConfigure,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_iconFromType(device.deviceType),
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(device.interface,
                                  style: theme.textTheme.titleLarge),
                              Text(subtitle,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme
                                          .colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        PaneStatusChip(status: status),
                        IconButton(
                          icon: const Icon(Icons.settings),
                          tooltip: 'Configure IPv4',
                          onPressed: onConfigure,
                        ),
                        if (_menuItems(device).isNotEmpty)
                          PopupMenuButton<String>(
                            tooltip: 'Interface actions',
                            onSelected: (value) {
                              switch (value) {
                                case 'disconnect':
                                  widget.onDisconnect();
                                case 'connect':
                                  widget.onConnect();
                                case 'manage':
                                  widget.onManage?.call();
                                case 'rename':
                                  widget.onRenameConnection?.call();
                                case 'delete':
                                  onDeleteBond?.call();
                              }
                            },
                            itemBuilder: (context) => _menuItems(device),
                          ),
                      ],
                    ),
                    if (!device.managed) ...[
                      const SizedBox(height: 8),
                      Text(
                        'NetworkManager is not controlling this port. Take '
                        'ownership from the menu to configure it.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                    if (_details().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 24,
                        runSpacing: 8,
                        children: [
                          for (final (label, value) in _details())
                            _InfoItem(label: label, value: value),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        });
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;

  const _InfoItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// IPv4 form fields (shared by the interface dialog and the bond dialog)
// ---------------------------------------------------------------------------

class Ipv4FormControllers {
  final ip = TextEditingController();
  final netmask = TextEditingController();
  final gateway = TextEditingController();
  final dns = TextEditingController();

  void dispose() {
    ip.dispose();
    netmask.dispose();
    gateway.dispose();
    dns.dispose();
  }

  /// Fills the fields from a saved profile's addressing.
  void applyPrefill(Ipv4Prefill prefill) {
    ip.text = prefill.address;
    netmask.text = prefill.netmask;
    gateway.text = prefill.gateway;
    dns.text = prefill.dns;
  }

  /// Builds the `ipv4` settings section from the current field state. Only
  /// valid after the enclosing [Form] validated.
  Map<String, DBusValue> toSection({required bool isDhcp}) {
    if (isDhcp) return ipv4AutoSection();
    return ipv4ManualSection(
      address: ip.text.trim(),
      prefix: parsePrefixOrNetmask(netmask.text)!,
      gateway: gateway.text.trim(),
      dnsServers: splitDnsServers(dns.text),
    );
  }
}

class Ipv4MethodFields extends StatelessWidget {
  final bool isDhcp;
  final ValueChanged<bool> onMethodChanged;
  final Ipv4FormControllers controllers;

  const Ipv4MethodFields({
    super.key,
    required this.isDhcp,
    required this.onMethodChanged,
    required this.controllers,
  });

  static String? _validateIp(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Required';
    if (!isValidIpv4(text)) return 'Enter a valid IPv4 address';
    return null;
  }

  static String? _validateNetmask(String? value) {
    if ((value ?? '').trim().isEmpty) return 'Required';
    final prefix = parsePrefixOrNetmask(value ?? '');
    if (prefix == null || prefix < 1 || prefix > 32) {
      return 'Enter a netmask (255.255.0.0) or prefix (/16)';
    }
    return null;
  }

  static String? _validateGateway(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (!isValidIpv4(text)) return 'Enter a valid IPv4 address';
    return null;
  }

  static String? _validateDns(String? value) {
    for (final server in splitDnsServers(value ?? '')) {
      if (!isValidIpv4(server)) return 'Invalid DNS server: $server';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          title: const Text('Use DHCP'),
          subtitle:
              const Text('Obtain address automatically from the network'),
          value: isDhcp,
          onChanged: onMethodChanged,
        ),
        // The example addresses live in `helperText`, below the field, not in
        // `hintText` inside it: a greyed-out 192.0.2.10 sitting where the
        // value goes reads as a configured address, and an operator cannot
        // tell an empty field from a filled one.
        if (!isDhcp) ...[
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'IP Address',
              helperText: 'Example: 192.0.2.10',
            ),
            controller: controllers.ip,
            // The on-screen keyboard on the stations switches to its keypad
            // (digits plus `.`) for a number field, which is the whole of an
            // IPv4 address — far fewer taps than the letter layout.
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: _validateIp,
            autovalidateMode: AutovalidateMode.onUserInteraction,
          ),
          const SizedBox(height: 10),
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'Netmask or prefix',
              helperText: 'Example: 255.255.255.0 or 24',
            ),
            controller: controllers.netmask,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: _validateNetmask,
            autovalidateMode: AutovalidateMode.onUserInteraction,
          ),
          const SizedBox(height: 10),
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'Gateway (optional)',
              helperText: 'Example: 192.0.2.1 — leave empty for none',
            ),
            controller: controllers.gateway,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: _validateGateway,
            autovalidateMode: AutovalidateMode.onUserInteraction,
          ),
          const SizedBox(height: 10),
          // Deliberately left on the letter keyboard: the station keypad has
          // no comma and no space, so a numeric field here would make a
          // second DNS server impossible to type.
          TextFormField(
            decoration: const InputDecoration(
              labelText: 'DNS servers (comma separated)',
              helperText: 'Example: 192.0.2.53, 8.8.8.8',
            ),
            controller: controllers.dns,
            validator: _validateDns,
            autovalidateMode: AutovalidateMode.onUserInteraction,
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Interface settings dialog
// ---------------------------------------------------------------------------

class InterfaceSettingsDialog extends StatefulWidget {
  final NetworkManagerClient nmClient;

  /// The interface being configured. Null when a saved profile is edited that
  /// currently has no device on this station.
  final NetworkManagerDevice? device;

  /// The profile to edit. When null it is resolved from the device: its
  /// active connection first, then a saved profile bound to the interface
  /// name, and only then a new profile is created on save.
  final NetworkManagerSettingsConnection? connection;

  /// Heading for the dialog; defaults to the interface name.
  final String? titleOverride;

  const InterfaceSettingsDialog({
    super.key,
    required this.nmClient,
    this.device,
    this.connection,
    this.titleOverride,
  }) : assert(device != null || connection != null,
            'Either a device or a connection is required');

  @override
  State<InterfaceSettingsDialog> createState() =>
      _InterfaceSettingsDialogState();
}

class _InterfaceSettingsDialogState extends State<InterfaceSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = Ipv4FormControllers();

  NetworkManagerActiveConnection? _activeConnection;

  /// The profile the form edits, once resolved. Null means "save creates one".
  NetworkManagerSettingsConnection? _connection;

  /// Set when the profile was found saved-but-inactive, so the dialog can say
  /// the change lands on the next activation instead of pretending it is live.
  bool _editingInactive = false;
  String _connectionId = '';

  bool _isDhcp = true;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadConnectionSettings();
  }

  @override
  void dispose() {
    _controllers.dispose();
    super.dispose();
  }

  String get _title =>
      widget.titleOverride ?? widget.device?.interface ?? _connectionId;

  Future<void> _loadConnectionSettings() async {
    try {
      final device = widget.device;
      _activeConnection = device?.activeConnection;
      var connection = widget.connection ?? _activeConnection?.connection;
      if (connection == null && device != null) {
        // An inactive port usually still has its profile saved; editing that
        // is what nmtui does, and it stops every save from adding one more
        // duplicate profile for the same interface.
        connection = await findConnectionForInterface(
            widget.nmClient, device.interface);
        _editingInactive = connection != null;
      } else {
        _editingInactive = _activeConnection == null && connection != null;
      }
      _connection = connection;

      // Prefill from the live lease/config so a DHCP → static switch starts
      // from the address the device already has.
      final ip4Config = _activeConnection?.ip4Config ?? device?.ip4Config;
      if (ip4Config != null) {
        if (ip4Config.addressData.isNotEmpty) {
          final first = ip4Config.addressData.first;
          _controllers.ip.text = '${first['address']}';
          _controllers.netmask.text =
              prefixToNetmask(first['prefix'] as int);
        }
        _controllers.gateway.text = ip4Config.gateway;
        _controllers.dns.text =
            ip4Config.nameserverData.map((e) => e['address']).join(', ');
      }

      // The configured method comes from the connection profile — presence
      // of a DHCP lease is only a fallback (a static profile on a network
      // with a rogue DHCP server must still read as static).
      // A port without any connection yet starts from DHCP.
      var isDhcp = connection == null || device?.dhcp4Config != null;
      if (connection != null) {
        final settings = await connection.getSettings();
        _connectionId = connectionField(settings, 'id');
        final prefill = ipv4PrefillFromSettings(settings);
        isDhcp = prefill.isDhcp;
        // The profile's own addressing wins over the live lease: it is what
        // the operator set, and for an inactive profile there is no lease.
        if (!prefill.isDhcp && prefill.hasAddress) {
          _controllers.applyPrefill(prefill);
        }
      }

      if (!mounted) return;
      setState(() {
        _isDhcp = isDhcp;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load connection settings: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    if (!_isDhcp && !(_formKey.currentState?.validate() ?? false)) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final ipv4Section = _controllers.toSection(isDhcp: _isDhcp);
      final device = widget.device;
      final activeConnection = _activeConnection;
      final connection = _connection;
      var message = 'Settings saved successfully';

      if (connection != null) {
        final updatedSettings = await connection.getSettings();
        updatedSettings['ipv4'] = ipv4Section;
        await connection.update(updatedSettings);

        if (activeConnection != null && device != null) {
          // Bounce the connection so the new addressing takes effect.
          await widget.nmClient.deactivateConnection(activeConnection);
          await activateConnectionResilient(widget.nmClient,
              device: device, connection: connection);
        } else {
          message = 'Saved — applies when this connection is activated';
        }
      } else if (device != null &&
          device.deviceType == NetworkManagerDeviceType.ethernet) {
        // Port has no connection profile yet — create one.
        await widget.nmClient.addAndActivateConnection(
          device: device,
          connection: {
            'connection': {
              'id': DBusString(device.interface),
              'uuid': DBusString(generateUuid()),
              'type': const DBusString('802-3-ethernet'),
              'interface-name': DBusString(device.interface),
              'autoconnect': const DBusBoolean(true),
            },
            'ipv4': ipv4Section,
          },
        );
      } else {
        throw Exception('No connection profile for $_title');
      }

      scaffoldMessenger.showSnackBar(SnackBar(content: Text(message)));
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to save settings: $e';
      });
    }
  }

  /// The note above the form explaining what saving will actually do.
  String? get _notice {
    if (_connection == null) {
      return 'This interface has no active connection. Saving creates a new '
          'connection profile.';
    }
    if (_editingInactive) {
      final name = _connectionId.isEmpty ? 'this profile' : '"$_connectionId"';
      return 'Editing the saved profile $name, which is not active. The '
          'change applies the next time it is brought up.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget content;
    if (_isLoading) {
      content = const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    } else {
      final notice = _notice;
      content = SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Settings — $_title',
                    style: theme.textTheme.titleLarge),
                if (notice != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    notice,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 8),
                Ipv4MethodFields(
                  isDhcp: _isDhcp,
                  onMethodChanged: (value) =>
                      setState(() => _isDhcp = value),
                  controllers: _controllers,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed:
                          _isSaving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _isSaving ? null : _saveSettings,
                      child: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(16.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: content,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bond creation dialog
// ---------------------------------------------------------------------------

/// Creates an active-backup (mode 1) bond from two or more ethernet ports.
/// One member carries traffic; on link loss NetworkManager fails over to a
/// backup within `miimon` (100 ms) — no switch-side LACP needed.
class CreateBondDialog extends StatefulWidget {
  final NetworkManagerClient nmClient;

  const CreateBondDialog({super.key, required this.nmClient});

  @override
  State<CreateBondDialog> createState() => _CreateBondDialogState();
}

class _CreateBondDialogState extends State<CreateBondDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController(text: 'bond0');
  final _controllers = Ipv4FormControllers();
  final Set<String> _selectedMembers = {};
  String? _primaryMember;
  bool _isDhcp = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _controllers.dispose();
    super.dispose();
  }

  /// Real ethernet ports, managed or not. Unmanaged ones are still listed so
  /// the operator can see why the port they expected is missing, but they
  /// cannot be ticked — NetworkManager refuses to enslave a port it does not
  /// own, and the activation would fail after the bond was already created.
  List<NetworkManagerDevice> get _ethernetDevices => widget.nmClient.devices
      .where((device) =>
          device.deviceType == NetworkManagerDeviceType.ethernet &&
          device.driver != 'veth')
      .toList()
    ..sort((a, b) => a.interface.compareTo(b.interface));

  String? _validateBondName(String? value) {
    final text = value?.trim() ?? '';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,14}$').hasMatch(text)) {
      return 'Interface name, e.g. bond0';
    }
    if (widget.nmClient.devices.any((d) => d.interface == text)) {
      return 'An interface named $text already exists';
    }
    return null;
  }

  Future<void> _create() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_selectedMembers.length < 2) {
      setState(() => _errorMessage =
          'Select at least two member ports (active + backup)');
      return;
    }

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    final bondName = _nameController.text.trim();
    try {
      await addConnectionResilient(
          widget.nmClient,
          bondMasterSettings(
            bondName: bondName,
            uuid: generateUuid(),
            primaryMember: _primaryMember,
            ipv4Section: _controllers.toSection(isDhcp: _isDhcp),
          ));

      // Activating a member pulls the bond master up with it, so no
      // device-less master activation (which D-Bus cannot express) needed.
      final members = _ethernetDevices
          .where((device) => _selectedMembers.contains(device.interface));
      // A member that will not come up right now (no carrier, for instance)
      // must not undo a bond that is otherwise built: its profile is saved
      // and autoconnect brings it in when the link appears.
      final notActivated = <String>[];
      for (final member in members) {
        final memberConnection = await addConnectionResilient(
            widget.nmClient,
            bondMemberSettings(
              memberInterface: member.interface,
              bondName: bondName,
              uuid: generateUuid(),
            ));
        try {
          await activateConnectionResilient(widget.nmClient,
              device: member, connection: memberConnection);
        } catch (_) {
          notActivated.add(member.interface);
        }
      }

      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(notActivated.isEmpty
              ? 'Bond $bondName created'
              : 'Bond $bondName created; '
                  '${notActivated.join(', ')} did not come up yet'),
        ),
      );
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = 'Failed to create bond: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _ethernetDevices;
    return Dialog(
      insetPadding: const EdgeInsets.all(16.0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Create bond', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Active-backup (mode 1): one port carries traffic, the '
                    'others take over when its link drops.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    decoration:
                        const InputDecoration(labelText: 'Bond name'),
                    controller: _nameController,
                    validator: _validateBondName,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                  ),
                  const SizedBox(height: 12),
                  Text('Member ports', style: theme.textTheme.titleSmall),
                  for (final device in devices)
                    CheckboxListTile(
                      dense: true,
                      title: Text(device.interface),
                      subtitle: Text(device.managed
                          ? device.hwAddress
                          : 'Unmanaged — take ownership from the interface '
                              'menu first'),
                      value: _selectedMembers.contains(device.interface),
                      onChanged: device.managed
                          ? (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedMembers.add(device.interface);
                                } else {
                                  _selectedMembers.remove(device.interface);
                                  if (_primaryMember == device.interface) {
                                    _primaryMember = null;
                                  }
                                }
                              });
                            }
                          : null,
                    ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    // The member set defines the item list; rebuilding on a
                    // membership change drops a primary that was unchecked
                    // (a stale selection here is a hard assert).
                    key: ValueKey((_selectedMembers.toList()..sort()).join()),
                    initialValue: _primaryMember,
                    decoration: const InputDecoration(
                      labelText: 'Primary port',
                      helperText:
                          'Preferred active port; automatic when unset',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Automatic')),
                      for (final member in _selectedMembers.toList()..sort())
                        DropdownMenuItem<String?>(
                            value: member, child: Text(member)),
                    ],
                    onChanged: (value) =>
                        setState(() => _primaryMember = value),
                  ),
                  const SizedBox(height: 8),
                  Ipv4MethodFields(
                    isDhcp: _isDhcp,
                    onMethodChanged: (value) =>
                        setState(() => _isDhcp = value),
                    controllers: _controllers,
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _isSaving
                            ? null
                            : () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _isSaving ? null : _create,
                        child: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Text('Create'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saved connection tile
// ---------------------------------------------------------------------------

/// One saved-but-inactive profile: what it is called, which interface it is
/// bound to and the address it will take when it comes up. Tapping edits it,
/// which is the only way to correct a static address on a port that is down.
class SavedConnectionTile extends StatelessWidget {
  final SavedConnection saved;
  final VoidCallback onEdit;

  /// Null when no interface of that name exists on this station, so there is
  /// nothing to activate it on.
  final VoidCallback? onActivate;

  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const SavedConnectionTile({
    super.key,
    required this.saved,
    required this.onEdit,
    this.onActivate,
    this.onRename,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final interfaceName =
        saved.interfaceName.isEmpty ? 'any port' : saved.interfaceName;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: ListTile(
        leading: Icon(Icons.bookmark_border,
            color: theme.colorScheme.onSurfaceVariant),
        title: Text(saved.id),
        subtitle: Text(
          '${saved.typeLabel} · $interfaceName · ${saved.ipv4.summary}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        onTap: onEdit,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Configure IPv4',
              onPressed: onEdit,
            ),
            TextButton(
              onPressed: onActivate,
              child: const Text('Activate'),
            ),
            if (onRename != null || onDelete != null)
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (value) {
                  if (value == 'rename') onRename?.call();
                  if (value == 'delete') onDelete?.call();
                },
                itemBuilder: (context) => [
                  if (onRename != null)
                    const PopupMenuItem(
                        value: 'rename', child: Text('Rename…')),
                  if (onDelete != null)
                    const PopupMenuItem(
                        value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a new connection name, refusing one that collides with another
/// profile before anything is written.
class _RenameConnectionDialog extends StatefulWidget {
  final String currentId;
  final List<String> existingIds;
  final String interfaceName;

  const _RenameConnectionDialog({
    required this.currentId,
    required this.existingIds,
    required this.interfaceName,
  });

  @override
  State<_RenameConnectionDialog> createState() =>
      _RenameConnectionDialogState();
}

class _RenameConnectionDialogState extends State<_RenameConnectionDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentId);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateConnectionName(
      _controller.text,
      currentId: widget.currentId,
      existingIds: widget.existingIds,
    );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: 'Rename connection',
      icon: Icons.drive_file_rename_outline,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(label: 'Rename', onPressed: _submit),
      ],
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Connection name',
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Text(
              widget.interfaceName.isEmpty
                  ? 'This is the profile\'s name only.'
                  // Say it plainly: operators reasonably expect renaming a
                  // connection called "bond0" to rename the interface.
                  : 'This renames the connection profile only. It stays bound '
                      'to the ${widget.interfaceName} interface.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
