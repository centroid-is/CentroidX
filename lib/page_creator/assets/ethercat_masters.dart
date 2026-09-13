/// Finding the EtherCAT masters a station has, from its key mappings.
///
/// `ECT_Diag` is generated, so every master's arrays are called the same
/// thing on every station: `Device_<n>_Diag`, `Device_<n>_SlaveInfo`,
/// `Device_<n>_SlaveCount`. Matching on the mapped identifier rather than on
/// the key name means the key repository can call them whatever it likes, and
/// setting up a station is mapping those twelve nodes — not configuring the
/// table, and not touching the 95 devices on them.
library;

import 'package:tfc_dart/core/state_man.dart' show KeyMappings;

import 'ethercat_subdevice.dart';

final RegExp _masterArray = RegExp(r'Device_(\d+)_(Diag|SlaveInfo|SlaveCount)$');

/// Every master [mappings] has a diag array for, in server then master order,
/// with the servers any of the arrays came from.
({Set<String> servers, List<(String, int, EcBusConfig)> masters}) _collect(
    KeyMappings mappings) {
  final found = <(String, int), EcBusConfig>{};
  for (final entry in mappings.nodes.entries) {
    final node = entry.value.opcuaNode;
    // An `array_index` mapping is one subdevice, not a master's whole array.
    if (node != null && node.arrayIndex != null) continue;
    final match = _masterArray.firstMatch(node?.identifier ?? entry.key) ??
        _masterArray.firstMatch(entry.key);
    if (match == null) continue;
    final server = node?.serverAlias ?? '';
    final n = int.parse(match.group(1)!);
    final bus = found.putIfAbsent((server, n), () => EcBusConfig());
    switch (match.group(2)) {
      case 'Diag':
        bus.diagKey = entry.key;
      case 'SlaveInfo':
        bus.infoKey = entry.key;
      case 'SlaveCount':
        bus.countKey = entry.key;
    }
  }

  final keys = found.keys.where((k) => found[k]!.diagKey.isNotEmpty).toList()
    ..sort((a, b) {
      final s = a.$1.compareTo(b.$1);
      return s != 0 ? s : a.$2.compareTo(b.$2);
    });
  return (
    servers: {for (final k in found.keys) k.$1},
    masters: [for (final k in keys) (k.$1, k.$2, found[k]!)],
  );
}

/// The masters [mappings] has arrays for, in server then master order.
///
/// Labelled `Device <n>` — what TwinCAT calls them — prefixed with the server
/// alias when the mappings span more than one server, since two stations
/// both have a Device 1. A master is listed once its diag array is mapped;
/// the info and count arrays are optional.
List<EcBusConfig> discoverEcMasters(KeyMappings mappings) {
  final (:servers, :masters) = _collect(mappings);
  return [
    for (final (server, n, bus) in masters)
      bus
        ..label = servers.length > 1 && server.isNotEmpty
            ? '$server · Device $n'
            : 'Device $n',
  ];
}

/// The PLCs [mappings] has masters for — one per OPC UA server, in server
/// order — each with its masters in master order.
///
/// One server makes one unnamed PLC, which the devices table draws as a plain
/// list of masters. With several, each PLC is named for its server alias and
/// its masters are a plain `Device <n>`: the PLC row already says whose.
List<EcPlcConfig> discoverEcPlcs(KeyMappings mappings) {
  final (:servers, :masters) = _collect(mappings);
  final plcs = <String, EcPlcConfig>{};
  for (final (server, n, bus) in masters) {
    plcs
        .putIfAbsent(
            server, () => EcPlcConfig(label: servers.length > 1 ? server : ''))
        .masters
        .add(bus..label = 'Device $n');
  }
  return plcs.values.toList();
}
