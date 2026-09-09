import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:dbus/dbus.dart';
import 'package:nm/nm.dart' as nm;

import '../widgets/base_scaffold.dart';

import '../core/system_clock.dart';
import '../dbus/generated/hostname1.dart' as hostname1;
import '../dbus/generated/login1.dart' as login1;
import '../providers/preferences.dart';
import '../widgets/group_access_guard.dart';
import '../widgets/system_clock_section.dart';

/// What it takes to change this host: the clock, the timezone, the NTP
/// servers, and the two buttons that stop the station.
///
/// `administer` is "server config, database, network, updates" — and it is
/// what IP Settings next door already requires, so one sign-in covers both
/// station-configuration pages rather than making an engineer authenticate
/// twice to finish one job.
///
/// **The route itself stays open**, and that is the whole design here. Reading
/// the hostname, the addresses and whether the clock is synchronised is
/// operator work; a locked page would mean nobody notices a station whose
/// historised samples are timestamped an hour out. `main.dart`'s route table
/// says this page "reads system information and changes nothing", which stopped
/// being true when the clock section landed — so the enforcement is on the
/// controls that write, which is where it now is.
const AccessGroup _hostGroup = AccessGroup.administer;

class AboutLinuxPage extends ConsumerStatefulWidget {
  final DBusClient dbusClient;

  /// Injection points for tests, which have no bus to talk to. Production
  /// leaves these null and the page builds D-Bus-backed ones from
  /// [dbusClient].
  final TimeDateApi? timeDate;
  final TimeSyncApi? timeSync;

  /// Returns to the connection chooser. Present because the page now
  /// auto-connects to the local bus; without it a station that has no saved
  /// credentials could never reach another machine's bus.
  final VoidCallback? onSwitchConnection;

  const AboutLinuxPage({
    super.key,
    required this.dbusClient,
    this.timeDate,
    this.timeSync,
    this.onSwitchConnection,
  });

  @override
  ConsumerState<AboutLinuxPage> createState() => _AboutLinuxPageState();
}

class _AboutLinuxPageState extends ConsumerState<AboutLinuxPage> {
  /// The NTP servers this station is configured to use. Held here because
  /// systemd cannot persist them (see [ntpServersPrefsKey]) — the HMI is what
  /// remembers them across a reboot.
  List<String> _storedNtpServers = const [];

  Future<void> _loadNtpServers() async {
    try {
      final servers = await readNtpServers(ref.read(localPreferencesProvider));
      if (mounted) setState(() => _storedNtpServers = servers);
    } catch (_) {
      // Preferences unavailable — the section still renders live state.
    }
  }

  Future<void> _saveNtpServers(List<String> servers) =>
      writeNtpServers(ref.read(localPreferencesProvider), servers);

  late final hostname1.OrgFreedesktopDBusPeer _hostnamed;
  late final login1.OrgFreedesktopDBusPeer _login1;
  StreamSubscription<hostname1.OrgFreedesktopDBusPeerPropertiesChanged>? _sub;
  Future<_HostInfo>? _infoFuture;

  @override
  void initState() {
    super.initState();
    _hostnamed = hostname1.OrgFreedesktopDBusPeer(
      widget.dbusClient,
      'org.freedesktop.hostname1',
      DBusObjectPath('/org/freedesktop/hostname1'),
    );

    _login1 = login1.OrgFreedesktopDBusPeer(
      widget.dbusClient,
      'org.freedesktop.login1',
      DBusObjectPath('/org/freedesktop/login1'),
    );

    // initial load
    _infoFuture = _load();
    unawaited(_loadNtpServers());

    // react to live property changes (hostname, kernel, etc.)
    _sub = _hostnamed.customPropertiesChanged.listen((_) {
      setState(() {
        _infoFuture = _load();
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<_HostInfo> _load() async {
    // 1) Pull everything in a single roundtrip
    Map<String, DBusValue> props = {};
    try {
      props = await _hostnamed.callGetAll('org.freedesktop.hostname1');
    } catch (_) {
      // Fallbacks below still rely on specific getters, but keep it quiet on systems that restrict GetAll.
    }

    // Helpers to read typed values (works for both direct & DBusVariant)
    String? _str(String key) {
      final v = props[key];
      if (v is DBusString) return v.value;
      if (v is DBusVariant && v.value is DBusString) {
        return (v.value as DBusString).value;
      }
      return null;
    }

    int? _u64(String key) {
      final v = props[key];
      if (v is DBusUint64) return v.value;
      if (v is DBusVariant && v.value is DBusUint64) {
        return (v.value as DBusUint64).value;
      }
      return null;
    }

    // 2) Best-effort Describe() — your generator says it returns a string
    String? describe;
    try {
      final d = await _hostnamed.callDescribe();
      if (d.trim().isNotEmpty) describe = d.trim();
    } catch (_) {}

    // 3) Optionally discover the host's IPv4s via NetworkManager (quietly skip if absent)
    List<String> activeIPs = [];
    try {
      final client = nm.NetworkManagerClient(bus: widget.dbusClient);
      await client.connect();
      final primary = client.primaryConnection;
      activeIPs = selectHostIps([
        if (primary != null)
          HostIpCandidate(
            isPrimary: true,
            isActivated: primary.state ==
                nm.NetworkManagerActiveConnectionState.activated,
            addresses: _ip4Addresses(primary.ip4Config),
          ),
        for (final dev in client.devices)
          HostIpCandidate(
            deviceType: dev.deviceType,
            isActivated: dev.activeConnection?.state ==
                nm.NetworkManagerActiveConnectionState.activated,
            addresses: _ip4Addresses(dev.ip4Config),
          ),
      ]);
      await client.close();
    } catch (_) {
      // ignore
    }

    // 4) Prefer PrettyHostname → Hostname → StaticHostname, use getters as fallback if GetAll wasn’t allowed.
    String hostname = _str('PrettyHostname') ??
        _str('Hostname') ??
        _str('StaticHostname') ??
        '';

    if (hostname.isEmpty) {
      try {
        final pretty = await _hostnamed.getPrettyHostname();
        if (pretty.isNotEmpty) hostname = pretty;
      } catch (_) {}
    }
    if (hostname.isEmpty) {
      try {
        final runtime = await _hostnamed.getHostname();
        if (runtime.isNotEmpty) hostname = runtime;
      } catch (_) {}
    }
    if (hostname.isEmpty) {
      try {
        final stat = await _hostnamed.getStaticHostname();
        if (stat.isNotEmpty) hostname = stat;
      } catch (_) {}
    }

    // Kernel & OS strings, with per-property fallbacks
    Future<String?> _fallbackStr(
      String current,
      Future<String> Function() getter,
    ) async {
      if (current.isNotEmpty) return current;
      try {
        final v = await getter();
        return v.isNotEmpty ? v : null;
      } catch (_) {
        return null;
      }
    }

    final kernelName = await _fallbackStr(
            _str('KernelName') ?? '', _hostnamed.getKernelName) ??
        '';
    final kernelRelease = await _fallbackStr(
            _str('KernelRelease') ?? '', _hostnamed.getKernelRelease) ??
        '';
    final kernelVersion = await _fallbackStr(
            _str('KernelVersion') ?? '', _hostnamed.getKernelVersion) ??
        '';
    final osPretty = await _fallbackStr(_str('OperatingSystemPrettyName') ?? '',
            _hostnamed.getOperatingSystemPrettyName) ??
        '';

    // Support end (uint64 microseconds since epoch in systemd)
    DateTime? osSupportEnd;
    final t = _u64('OperatingSystemSupportEnd');
    if (t != null && t > 0) {
      try {
        osSupportEnd =
            DateTime.fromMicrosecondsSinceEpoch(t, isUtc: true).toLocal();
      } catch (_) {
        // fallback if units differ on some impls
        osSupportEnd =
            DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true)
                .toLocal();
      }
    } else {
      // last-ditch single property read
      try {
        final v = await _hostnamed.getOperatingSystemSupportEnd();
        if (v > 0) {
          osSupportEnd =
              DateTime.fromMicrosecondsSinceEpoch(v, isUtc: true).toLocal();
        }
      } catch (_) {}
    }

    return _HostInfo(
      hostname: hostname,
      kernelName: kernelName,
      kernelRelease: kernelRelease,
      kernelVersion: kernelVersion,
      osPretty: osPretty,
      osSupportEnd: osSupportEnd,
      activeIPs: activeIPs,
      describe: describe,
    );
  }

  // Add this method for showing confirmation dialog
  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required IconData icon,
    required Color iconColor,
  }) async {
    // Powering off / rebooting a running line: destructive by definition.
    return showConfirmDialog(
      context: context,
      title: title,
      message: message,
      icon: icon,
      destructive: true,
    );
  }

  // Add this method for poweroff
  Future<void> _handlePowerOff() async {
    // Access before the confirm dialog: "are you sure?" then "no you may not"
    // is two dialogs to say one thing, and the second is the one that matters.
    if (!await guardGroupAction(ref, _hostGroup,
        itemKey: 'system.power.poweroff')) {
      return;
    }
    if (!mounted) return;

    final confirmed = await _showConfirmDialog(
      title: 'Power Off',
      message: 'Are you sure you want to power off the system?',
      icon: FontAwesomeIcons.powerOff.data,
      iconColor: Colors.red,
    );

    if (!confirmed) return;

    try {
      await _login1.callPowerOff(false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to power off: $e')),
        );
      }
    }
  }

  // Add this method for reboot
  Future<void> _handleReboot() async {
    if (!await guardGroupAction(ref, _hostGroup,
        itemKey: 'system.power.reboot')) {
      return;
    }
    if (!mounted) return;

    final confirmed = await _showConfirmDialog(
      title: 'Reboot',
      message: 'Are you sure you want to reboot the system?',
      icon: FontAwesomeIcons.arrowsRotate.data,
      iconColor: Colors.orange,
    );

    if (!confirmed) return;

    try {
      await _login1.callReboot(false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reboot: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: 'About Linux',
      body: FutureBuilder<_HostInfo>(
        future: _infoFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData) {
            return Center(
              child: Text(
                'Could not fetch system information.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          }

          final info = snap.data!;

          // Watched once for the whole page, so the clock section's lock and
          // the power buttons' cannot disagree, and all of them clear the
          // instant an operator signs in.
          final hostActionsAllowed = groupAllowed(ref, _hostGroup);

          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                // Which machine this page is showing: hostname, its addresses,
                // and the way to point the page somewhere else. One band, so
                // the answer to "where am I" costs one line rather than four.
                AboutIdentityCard(
                  hostname: info.hostname,
                  activeIPs: info.activeIPs,
                  onSwitchConnection: widget.onSwitchConnection,
                ),

                const SizedBox(height: 12),

                // Kernel, OS and support end as rows in one card. They were
                // three stacked cards, which pushed the clock — the part an
                // operator actually acts on — below the fold on a panel.
                AboutSystemFactsCard(
                  osPretty: info.osPretty,
                  kernel: [
                    if (info.kernelName.isNotEmpty) info.kernelName,
                    if (info.kernelRelease.isNotEmpty) info.kernelRelease,
                  ].join(' ').trim(),
                  kernelVersion: info.kernelVersion,
                  supportEnd: info.osSupportEnd == null
                      ? ''
                      : _fmtDate(info.osSupportEnd!),
                ),

                const SizedBox(height: 8),
                const Divider(),

                // Host clock. Reads need no privileges, so this renders for
                // anyone who opens the page; only the setters hit polkit.
                SystemClockSection(
                  timeDate: widget.timeDate ?? DBusTimeDate(widget.dbusClient),
                  timeSync: widget.timeSync ?? DBusTimeSync(widget.dbusClient),
                  storedServers: _storedNtpServers,
                  onServersChanged: _saveNtpServers,
                  settingsAllowed: hostActionsAllowed,
                  onBeforeChange: () => guardGroupAction(ref, _hostGroup,
                      itemKey: 'system.clock'),
                ),

                const SizedBox(height: 24),

                // Power control buttons at the bottom
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _handleReboot,
                        icon: const FaIcon(FontAwesomeIcons.arrowsRotate,
                            size: 18),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Reboot'),
                            if (!hostActionsAllowed)
                              const GroupLockBadge(group: _hostGroup),
                          ],
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _handlePowerOff,
                        icon: const FaIcon(FontAwesomeIcons.powerOff, size: 18),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Power Off'),
                            if (!hostActionsAllowed)
                              const GroupLockBadge(group: _hostGroup),
                          ],
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}

/// Which machine this page is reading — hostname, addresses, and the way to
/// point it at a different bus.
///
/// The switch action lives here rather than at the foot of the page, where it
/// sat directly under the Date & Time section and read as one of the clock's
/// controls. It is neither: it re-opens [DbusGate]'s connection form so the
/// page can be pointed at another station's system bus over SSH. Beside the
/// hostname it is switching, that is legible without a caption.
@visibleForTesting
class AboutIdentityCard extends StatelessWidget {
  final String hostname;
  final List<String> activeIPs;
  final VoidCallback? onSwitchConnection;

  const AboutIdentityCard({
    super.key,
    required this.hostname,
    required this.activeIPs,
    this.onSwitchConnection,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onContainer = theme.colorScheme.onPrimaryContainer;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 10),
      child: Row(
        children: [
          FaIcon(FontAwesomeIcons.linux, size: 22, color: onContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  hostname.isEmpty ? '—' : hostname,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700, color: onContainer),
                  overflow: TextOverflow.ellipsis,
                ),
                if (activeIPs.isNotEmpty)
                  // Addresses as one line of text rather than a Wrap of Chips:
                  // the chips were a second row of 32px-tall widgets for two
                  // short strings, and this is the same information.
                  Row(
                    children: [
                      Icon(Icons.public, size: 14, color: onContainer),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          activeIPs.join('  ·  '),
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: onContainer),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (onSwitchConnection != null)
            TextButton.icon(
              onPressed: onSwitchConnection,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text('Switch machine'),
              style: TextButton.styleFrom(foregroundColor: onContainer),
            ),
        ],
      ),
    );
  }
}

/// Kernel, OS and support end in one card.
///
/// These were three stacked cards, each with its own icon, label line, value
/// line and 12px of padding — about 220px of panel for three short strings
/// nobody reads twice. As label/value rows they are a third of that, and the
/// Date & Time section below them is on screen without scrolling.
@visibleForTesting
class AboutSystemFactsCard extends StatelessWidget {
  final String osPretty;
  final String kernel;
  final String kernelVersion;

  /// Already formatted; empty when hostname1 reports no support end.
  final String supportEnd;

  const AboutSystemFactsCard({
    super.key,
    required this.osPretty,
    required this.kernel,
    required this.kernelVersion,
    required this.supportEnd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      // "OS", not "Operating system", which wraps the 120px gutter onto two
      // lines and makes the first row taller than the three below it. The
      // value beside it says "Debian GNU/Linux 12"; nothing is lost.
      if (osPretty.isNotEmpty) ('OS', osPretty),
      if (kernel.isNotEmpty) ('Kernel', kernel),
      // The full uname build string. Long, occasionally the thing you need,
      // never the thing you came for — so it is a row like the others and is
      // allowed to ellipsize rather than wrapping to four lines.
      if (kernelVersion.isNotEmpty) ('Build', kernelVersion),
      if (supportEnd.isNotEmpty) ('Support end', supportEnd),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  // Same 120px label gutter as the Time sync rows below, so
                  // the two blocks read as one table down the page.
                  SizedBox(
                    width: 120,
                    child: Text(row.$1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

List<String> _ip4Addresses(nm.NetworkManagerIP4Config? cfg) {
  if (cfg == null) return const [];
  return [
    for (final data in cfg.addressData)
      if (data['address'] is String && (data['address'] as String).isNotEmpty)
        data['address'] as String,
  ];
}

/// One network interface reduced from NetworkManager state, so the IP
/// selection logic stays testable without a DBus connection.
@visibleForTesting
class HostIpCandidate {
  /// Null for the primary-connection candidate, which has no single device.
  final nm.NetworkManagerDeviceType? deviceType;

  /// Whether this candidate backs NetworkManager's primary connection —
  /// the one holding the default route.
  final bool isPrimary;
  final bool isActivated;
  final List<String> addresses;

  const HostIpCandidate({
    this.deviceType,
    this.isPrimary = false,
    required this.isActivated,
    required this.addresses,
  });
}

/// Picks the host's real IPv4 addresses. Device enumeration order from
/// NetworkManager is arbitrary, so virtual interfaces (docker bridges,
/// veths, tunnels) must never win over the interface that actually routes
/// traffic: prefer the primary (default-route) connection, then physical
/// ethernet/wifi devices, then anything else that is activated.
@visibleForTesting
List<String> selectHostIps(List<HostIpCandidate> candidates) {
  bool isLoopback(String addr) => addr.startsWith('127.');

  List<String> collect(bool Function(HostIpCandidate) where) {
    final ips = <String>{};
    for (final c in candidates) {
      if (!c.isActivated || !where(c)) continue;
      ips.addAll(c.addresses.where((a) => !isLoopback(a)));
    }
    return ips.toList();
  }

  const physical = {
    nm.NetworkManagerDeviceType.ethernet,
    nm.NetworkManagerDeviceType.wifi,
  };
  const virtual = {
    nm.NetworkManagerDeviceType.bridge,
    nm.NetworkManagerDeviceType.veth,
    nm.NetworkManagerDeviceType.tun,
    nm.NetworkManagerDeviceType.dummy,
  };

  final primary = collect((c) => c.isPrimary);
  if (primary.isNotEmpty) return primary;
  final wired = collect((c) => physical.contains(c.deviceType));
  if (wired.isNotEmpty) return wired;
  return collect((c) => !c.isPrimary && !virtual.contains(c.deviceType));
}

class _HostInfo {
  final String hostname;
  final String kernelName;
  final String kernelRelease;
  final String kernelVersion;
  final String osPretty;
  final DateTime? osSupportEnd;
  final List<String> activeIPs;
  final String? describe;

  const _HostInfo({
    required this.hostname,
    required this.kernelName,
    required this.kernelRelease,
    required this.kernelVersion,
    required this.osPretty,
    required this.osSupportEnd,
    required this.activeIPs,
    required this.describe,
  });
}
