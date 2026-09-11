/// Drawing a page's cables from the PLC's own topology.
///
/// Once the devices on a page are bound, the wiring is not a drawing decision
/// any more: `ST_EcSlaveInfo` says which subdevice each one plugs into and on
/// which port, so every cable between two drawn devices can be derived. That
/// is the difference between wiring `/+ST101` by hand — thirty runs, each one
/// a chance to draw a cable the plant does not have — and reviewing thirty
/// proposals that came out of the export.
///
/// Only between devices that are both on the page and both bound: a cable to
/// something nobody drew has no second end to attach to.
library;

import 'common.dart';
import 'ethercat_asset.dart';
import 'ethercat_autobind.dart' show ecAssetsOn;
import 'ethercat_link.dart';
import 'ethercat_ports.dart';
import 'ethercat_subdevice.dart';
import 'link_anchors.dart';
import 'link_geometry.dart';

/// One cable the topology says exists and the page does not draw yet.
class EcCableProposal {
  const EcCableProposal({
    required this.from,
    required this.fromPort,
    required this.to,
    required this.toPort,
    required this.busLabel,
  });

  /// The upstream device, and the port the frame leaves it by.
  final Asset from;
  final EcPort fromPort;

  /// The downstream device. A frame always enters on A, so [toPort] is A for
  /// every subdevice-to-subdevice run.
  final Asset to;
  final EcPort toPort;

  final String busLabel;

  /// What the review dialog shows: `ST101.A1.15 · B → ST101.PSU · A`.
  String get label => '${_name(from)} · ${fromPort.letter}'
      ' → ${_name(to)} · ${toPort.letter}';

  static String _name(Asset a) {
    if (a is EtherCatAsset && a.ecName.isNotEmpty) {
      return a.ecName.replaceAll(RegExp(r'\s+'), ' ');
    }
    final t = a.text;
    return t == null || t.isEmpty ? a.displayName : t;
  }

  /// The cable asset itself, with both ends plugged in.
  ///
  /// No key: a cable between two bound devices takes its colour from their
  /// ports, and the legacy `ST_EtherCATLink_HMI` struct is not something this
  /// plant has.
  EtherCatLinkConfig build() {
    return EtherCatLinkConfig(
      run: LinkRun(
        from: LinkEnd(assetId: from.ensureId(), port: fromPort.letter),
        to: LinkEnd(assetId: to.ensureId(), port: toPort.letter),
      ),
    )..text = label;
  }
}

/// What drawing [page]'s cables from [buses] would add, without adding it.
class EcAutoCablePlan {
  const EcAutoCablePlan({this.cables = const [], this.notes = const []});

  final List<EcCableProposal> cables;

  /// Plain-words remarks for the review dialog: a neighbour nobody drew, a
  /// run already on the page.
  final List<String> notes;

  bool get isEmpty => cables.isEmpty;
}

/// The cables the topology puts between the bound devices on [page].
///
/// Walks each bound device's outgoing ports — B, C and D; A is where the
/// frame arrives, and that cable belongs to the device upstream — and pairs it
/// with whatever the PLC says is on the other end.
EcAutoCablePlan planEcAutoCables(
  Iterable<Asset> page,
  Map<EcBusConfig, EcBus> buses,
) {
  final assets = ecAssetsOn(page).toList();
  final existing = _existingEnds(page);
  final cables = <EcCableProposal>[];
  final notes = <String>{};

  // Which asset stands for which subdevice, per master.
  final byPosition = <EcBusConfig, Map<int, EtherCatAsset>>{};
  for (final asset in assets) {
    final binding = asset.ecSubDevice;
    if (binding == null || !binding.isBound) continue;
    for (final entry in buses.entries) {
      if (entry.key.diagKey != binding.diagKey) continue;
      final s = binding.resolve(entry.value);
      if (s != null) byPosition.putIfAbsent(entry.key, () => {})[s.position] = asset;
    }
  }

  for (final entry in byPosition.entries) {
    final bus = buses[entry.key]!;
    for (final position in entry.value.keys.toList()..sort()) {
      final asset = entry.value[position]!;
      final subdevice = bus.at(position);
      if (subdevice == null) continue;

      for (final port in _outgoingPorts(asset, bus, subdevice)) {
        final neighbour = bus.neighbour(subdevice, port);
        if (neighbour == null || neighbour.isMaster) continue;
        final other = entry.value[neighbour.subdevice!.position];
        if (other == null) {
          notes.add('${EcCableProposal._name(asset)} · ${port.letter} goes to '
              '${neighbour.subdevice!.label}, which is not on this page.');
          continue;
        }
        final toPort = neighbour.port ?? EcPort.a;
        if (_alreadyDrawn(existing, asset, port, other, toPort)) {
          notes.add('${EcCableProposal._name(asset)} · ${port.letter} is '
              'already drawn.');
          continue;
        }
        cables.add(EcCableProposal(
          from: asset,
          fromPort: port,
          to: other,
          toPort: toPort,
          busLabel: bus.label,
        ));
        existing.add(_endKey(asset, port));
        existing.add(_endKey(other, toPort));
      }
    }
  }

  return EcAutoCablePlan(cables: cables, notes: notes.toList());
}

/// The ports a cable can leave [asset] by: its own sockets minus A, narrowed
/// to what the hardware has when the model is known.
Iterable<EcPort> _outgoingPorts(
    EtherCatAsset asset, EcBus bus, EcSubDevice subdevice) {
  final physical = ecPhysicalPorts(subdevice.info?.model);
  return [
    for (final p in asset.networkPorts)
      if (EcPort.parse(p.id) case final port?)
        if (port != EcPort.a && (physical == null || physical.contains(port)))
          port,
  ];
}

String _endKey(Asset asset, EcPort port) => '${asset.ensureId()}${port.letter}';

/// Every (asset, port) a cable on [page] already occupies, with legacy X1/X2
/// ends resolved to the letter they mean on that device.
Set<String> _existingEnds(Iterable<Asset> page) {
  final byId = {
    for (final a in ecAssetsOn(page))
      if (a.id != null) a.id!: a,
  };
  final out = <String>{};
  for (final a in page) {
    if (a is! EtherCatLinkConfig) continue;
    for (final end in [a.run.from, a.run.to]) {
      final id = end.assetId;
      if (id == null) continue;
      final target = byId[id];
      final resolved =
          target == null ? end.port : findPort(portsOf(target), end.port)?.id;
      if (resolved != null) out.add('$id$resolved');
    }
  }
  return out;
}

bool _alreadyDrawn(Set<String> existing, Asset from, EcPort fromPort, Asset to,
        EcPort toPort) =>
    existing.contains(_endKey(from, fromPort)) ||
    existing.contains(_endKey(to, toPort));

/// Writes [plan]'s cables onto the page, and returns them.
///
/// Appended at the end, so they paint over the devices they run between the
/// way a hand-drawn cable does.
List<EtherCatLinkConfig> applyEcAutoCables(
    List<Asset> page, EcAutoCablePlan plan) {
  final made = [for (final c in plan.cables) c.build()];
  page.addAll(made);
  return made;
}
