/// The layer every EtherCAT subdevice's asset sits on.
///
/// A terminal, a coupler and a drive draw nothing alike, but on the bus they
/// are the same thing: one subdevice with up to four ports that the PLC reports
/// on. That is a fact about a family of hardware, not about every asset — a
/// button is never an EtherCAT subdevice — so it lives here rather than on
/// [BaseAsset], and an asset joins the family by extending this instead.
library;

import 'package:json_annotation/json_annotation.dart';

import 'common.dart';
import 'ethercat_subdevice.dart';
import 'link_anchors.dart';

// A subclass's generated `fromJson` names the binding's type, and generated
// code only sees what its library imports. Re-exporting it here means
// extending [EtherCatAsset] is the whole of joining the family.
export 'ethercat_subdevice.dart' show EcSubDeviceBinding;

part 'ethercat_asset.g.dart';

@JsonSerializable(createFactory: false, explicitToJson: true)
abstract class EtherCatAsset extends BaseAsset implements NetworkPorted {
  EtherCatAsset();

  /// Where this device's subdevice record lives, or null for a device that is
  /// only drawn. `includeIfNull: false` keeps it additive: a page saved
  /// before bindings existed round-trips exactly as it was.
  @JsonKey(name: 'ecSubDevice', includeIfNull: false)
  EcSubDeviceBinding? ecSubDevice;

  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get isEcBound => ecSubDevice?.isBound ?? false;

  /// The name the EtherCAT export knows this box by — `ST101.A1.03`,
  /// `CVS01.CN01.FD01` — or as much of it as the page carries. What
  /// bind-by-name matches against the PLC's subdevice names.
  @JsonKey(includeFromJson: false, includeToJson: false)
  String get ecName;

  /// The generic subdevice: in on the left, out on the right, branches below and
  /// above. Devices with a real socket layout override it.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<NetworkPort> get networkPorts => kEcSubDevicePorts;

  /// The `p_stat_sModel` strings the PLC uses for the hardware this asset
  /// draws — `'EL1008'`, `'ATV320 EtherCAT'`.
  ///
  /// [networkPorts] is this part's real socket layout, and the PLC publishes
  /// four port slots for every subdevice whether they exist or not. Naming the
  /// models here is what lets a table row look up its own hardware's sockets
  /// and stop drawing the two an ATV320 has never had. Empty means the class
  /// stands for no particular part, and rows fall back to what the topology
  /// and the counters show.
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get ecModels => const [];

  /// The binding's keys sit one level down, where the introspection in
  /// `BaseAsset.allKeys` cannot see them.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get allKeys =>
      {...super.allKeys, ...?ecSubDevice?.keys}.toList();

  // No bulk rows here, deliberately. The master's arrays are tag keys, and
  // `TextBulkProperty` does not carry key fields: pointing a selection at one
  // signal is the mistake that rule exists to prevent, and
  // `bulk_property_test` holds the line. Shared-by-design or not, a master is
  // set per device in the binding editor, or on a whole page at once by
  // matching names — where every match is shown before it is applied.
}

/// [EtherCatAsset.ecName] for the assets that carry a `nameOrId` — every
/// Beckhoff part and the Festo terminal — falling back to the label.
mixin EcNamedByNameOrId on EtherCatAsset {
  String get nameOrId;

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  String get ecName => nameOrId.isNotEmpty ? nameOrId : (text ?? '');
}

// The socket layouts, in the PLC's A–D terms. The aliases are the implicit
// X1/X2 a cable could have been drawn against before the device joined this
// family; they are never rewritten on a stored cable, only resolved.

/// A terminal on the E-bus: in on the left contacts, out on the right. No C
/// or D — a terminal is never a junction.
const List<NetworkPort> kEcTerminalPorts = [
  NetworkPort('A', PortSide.left, description: 'E-bus in', aliases: ['X1']),
  NetworkPort('B', PortSide.right, description: 'E-bus out', aliases: ['X2']),
];

/// A device with an in socket and an out socket on opposite faces.
const List<NetworkPort> kEcInOutPorts = [
  NetworkPort('A', PortSide.left, description: 'EtherCAT in', aliases: ['X1']),
  NetworkPort('B', PortSide.right,
      description: 'EtherCAT out', aliases: ['X2']),
];

/// EK1100: X1 IN and X2 OUT are both RJ45 on the left; B is the E-bus into
/// the terminals on its right. Which is why a legacy `X2` lands on C, not B —
/// X2 OUT is the socket a branch leaves by.
const List<NetworkPort> kEk1100Ports = [
  NetworkPort('A', PortSide.left, at: 0.3, description: 'X1 in', aliases: ['X1']),
  NetworkPort('C', PortSide.left,
      at: 0.7, description: 'X2 out', aliases: ['X2']),
  NetworkPort('B', PortSide.right, description: 'E-bus'),
];

/// EK1110: the E-bus comes in on the left, the RJ45 carries it on.
const List<NetworkPort> kEk1110Ports = [
  NetworkPort('A', PortSide.left, description: 'E-bus', aliases: ['X1']),
  NetworkPort('B', PortSide.right, description: 'X1 out', aliases: ['X2']),
];

/// CU2508: the uplink in, and the segment the next device hangs off.
const List<NetworkPort> kCu2508Ports = [
  NetworkPort('A', PortSide.left, description: 'Uplink', aliases: ['X1']),
  NetworkPort('B', PortSide.right, description: 'Down', aliases: ['X2']),
];

/// EP box: both M8 sockets on the top face.
const List<NetworkPort> kEpBoxPorts = [
  NetworkPort('A', PortSide.top, at: 0.3, description: 'In', aliases: ['X1']),
  NetworkPort('B', PortSide.top, at: 0.7, description: 'Out', aliases: ['X2']),
];

/// ATV320: the EtherCAT option card's two sockets, underneath.
const List<NetworkPort> kAtv320Ports = [
  NetworkPort('A', PortSide.bottom,
      at: 0.35, description: 'In', aliases: ['X1']),
  NetworkPort('B', PortSide.bottom,
      at: 0.65, description: 'Out', aliases: ['X2']),
];
