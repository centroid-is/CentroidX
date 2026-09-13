/// EtherCAT subdevice diagnostics, the way the PLC publishes them.
///
/// The PLC side is per *device*, not per cable: `FB_EcDeviceDiag` fills one
/// `ST_EcSlaveDiag` per subdevice on a master, next to a static `ST_EcSlaveInfo`
/// generated from the same EtherCAT export (`ECT_Diag.Device_<n>_Diag` and
/// `ECT_Diag.Device_<n>_SlaveInfo`, both `ARRAY[1..128]`, index = bus
/// position). Every subdevice has four ports, A to D, and the per-port figures are
/// `[0..3]` arrays on the diag struct.
///
/// A cable is therefore never a thing the PLC reports on. It is the pair of
/// ports at its two ends, and its health is whatever those two ports say. That
/// is what [EcBus.neighbour] and [EcSubDeviceDiag.portHealth] exist to answer.
library;

import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541.dart' show DynamicValue;

part 'ethercat_subdevice.g.dart';

/// Member names on `ST_EcSlaveInfo`.
abstract final class EcInfoFields {
  static const name = 'p_stat_sName';
  static const model = 'p_stat_sModel';
  static const physAddr = 'p_stat_nPhysAddr';
  static const prevPhysAddr = 'p_stat_nPrevPhysAddr';
  static const prevPort = 'p_stat_sPrevPort';
}

/// Member names on `ST_EcSlaveDiag`.
abstract final class EcDiagFields {
  static const deviceState = 'p_stat_nDeviceState';
  static const linkState = 'p_stat_nLinkState';
  static const state = 'p_stat_eState';
  static const error = 'p_stat_bError';
  static const linkDown = 'p_stat_bLinkDown';
  static const crcSum = 'p_stat_nCrcSum';
  static const crcStableSeconds = 'p_stat_nCrcStableS';
  static const crcPort = 'p_stat_aCrcPort';
  static const linkLostPort = 'p_stat_aLinkLostPort';
  static const ok = 'p_stat_bOk';

  /// Handshakes: the HMI writes TRUE, the FB does the work and writes FALSE.
  /// Nothing on this side ever clears them.
  static const resetLinkLost = 'p_cmd_resetLinkLostCounter';
  static const resetCrc = 'p_cmd_resetCrcCounter';
}

/// One of the four ports every EtherCAT subdevice controller has.
///
/// A is where the frame comes in; B, C and D are where it goes on. On a
/// terminal A is the left E-bus contact and B the right one; on a coupler or a
/// drive A and B are the IN and OUT sockets; C and D only exist on junctions.
enum EcPort {
  a,
  b,
  c,
  d;

  /// The letter the PLC and the TwinCAT topology view use.
  String get letter => const ['A', 'B', 'C', 'D'][index];

  /// This port's bit in the high nibble of `linkState`.
  int get linkStateMask => 0x10 << index;

  /// Reads a port name as stored on a cable end or in `p_stat_sPrevPort`.
  ///
  /// `X1`/`X2` are the ports a device offers before it is bound to a subdevice
  /// (see `kImplicitPorts`): in and out, which on an EtherCAT subdevice are A and
  /// B. Accepting them here is what keeps a cable drawn before the binding
  /// existed meaning the same thing after it.
  static EcPort? parse(String? name) => switch (name?.trim().toUpperCase()) {
        'A' || 'X1' => EcPort.a,
        'B' || 'X2' => EcPort.b,
        'C' => EcPort.c,
        'D' => EcPort.d,
        _ => null,
      };
}

/// The EtherCAT state machine, from the low nibble of `deviceState`.
enum EcSubDeviceState {
  unknown(0, '—'),
  init(1, 'INIT'),
  preOp(2, 'PREOP'),
  boot(3, 'BOOT'),
  safeOp(4, 'SAFEOP'),
  op(8, 'OP');

  const EcSubDeviceState(this.raw, this.label);

  final int raw;

  /// Upper case because that is how TwinCAT prints it, and the people reading
  /// this table have spent years reading it there.
  final String label;

  static EcSubDeviceState fromRaw(int raw) {
    for (final s in values) {
      if (s.raw == raw) return s;
    }
    return unknown;
  }
}

/// What the low nibble of `linkState` says is wrong on the flagged ports.
enum EcLinkFault {
  /// 0x01: the subdevice did not answer at all.
  notPresent('Not present'),

  /// 0x02: a link without communication.
  noCommunication('No communication'),

  /// 0x04: a link the configuration expects is missing.
  missingLink('Missing link'),

  /// 0x08: a link the configuration does not expect. Traffic still flows; it
  /// means something has been plugged in that the export does not know about.
  additionalLink('Extra link');

  const EcLinkFault(this.label);
  final String label;

  static EcLinkFault? fromLinkState(int linkState) {
    if (linkState & 0x01 != 0) return notPresent;
    if (linkState & 0x02 != 0) return noCommunication;
    if (linkState & 0x04 != 0) return missingLink;
    if (linkState & 0x08 != 0) return additionalLink;
    return null;
  }
}

/// The four-way answer every row, port and cable reduces to.
///
/// Ordered by precedence: when two things disagree the higher index wins,
/// except that [unknown] only wins when nothing else is known.
enum EcHealth { unknown, unused, ok, warning, fault }

/// Worst of [all], with [EcHealth.unknown] only if nothing better is known.
EcHealth worstHealth(Iterable<EcHealth> all) {
  var worst = EcHealth.unknown;
  for (final h in all) {
    if (h.index > worst.index) worst = h;
  }
  return worst;
}

/// How long a rise in the CRC sum keeps a device flagged.
///
/// The per-port CRC figures are totals since the last reset, so on their own
/// they say what a port has ever done. Forty errors last spring and forty this
/// morning read the same. The PLC's `nCrcStableS` is the only recency the data
/// carries, so a CRC figure only counts against a device while it is fresh.
const Duration kEcCrcFreshWindow = Duration(hours: 1);

/// `ST_EcSlaveInfo`, the static half: what the subdevice is and where it plugs in.
class EcSubDeviceInfo {
  const EcSubDeviceInfo({
    required this.name,
    required this.model,
    required this.physAddr,
    required this.prevPhysAddr,
    required this.prevPort,
  });

  /// The full box name from the export, e.g. `CVS01.CN01.FD01 (ATV320 EtherCAT)`.
  final String name;
  final String model;

  /// Fixed EtherCAT address, 1001 upwards.
  final int physAddr;

  /// The upstream subdevice's [physAddr]; 0 when this subdevice hangs off the master.
  final int prevPhysAddr;

  /// Which port on the upstream subdevice this one plugs into.
  final EcPort? prevPort;

  /// True for the unused tail of the 128-slot array.
  bool get isEmpty => name.isEmpty && physAddr == 0;

  /// The name without the export's trailing `(model)`, which the model column
  /// already says.
  String get shortName {
    final open = name.lastIndexOf(' (');
    if (open > 0 && name.endsWith(')')) return name.substring(0, open);
    return name;
  }

  static EcSubDeviceInfo? tryParse(DynamicValue value) {
    if (!value.isObject) return null;
    if (!value.contains(EcInfoFields.physAddr) &&
        !value.contains(EcInfoFields.name)) {
      return null;
    }
    return EcSubDeviceInfo(
      name: _str(value, EcInfoFields.name),
      model: _str(value, EcInfoFields.model),
      physAddr: _int(value, EcInfoFields.physAddr),
      prevPhysAddr: _int(value, EcInfoFields.prevPhysAddr),
      prevPort: EcPort.parse(_str(value, EcInfoFields.prevPort)),
    );
  }
}

/// `ST_EcSlaveDiag`, the live half.
class EcSubDeviceDiag {
  const EcSubDeviceDiag({
    required this.deviceState,
    required this.linkState,
    required this.crcSum,
    required this.crcStableSeconds,
    required this.crcPort,
    required this.linkLostPort,
    this.plcOk = false,
  });

  /// Raw `deviceState`: state in the low nibble, 0x10 the error flag.
  final int deviceState;

  /// Raw `linkState`: fault kind in the low nibble, the ports it is on in the
  /// high one.
  final int linkState;

  /// CRC errors summed over every port.
  final int crcSum;

  /// Seconds since [crcSum] last went *up*. A counter reset does not restart
  /// it, which is the point: clearing the figures is not the same as the
  /// cable getting better.
  final int crcStableSeconds;

  /// Per-port CRC totals, A to D. Refreshed one subdevice at a time, so on a long
  /// bus a figure can be several seconds behind the sum.
  final List<int> crcPort;

  /// Per-port link losses, A to D, counted by the PLC from `linkState`
  /// transitions. Saturates at 255 and misses drops shorter than its poll.
  final List<int> linkLostPort;

  /// The PLC's own `bOk`. Kept for reference only — see [health] for why the
  /// HMI does not simply repeat it.
  final bool plcOk;

  EcSubDeviceState get state => EcSubDeviceState.fromRaw(deviceState & 0x0F);
  bool get error => deviceState & 0x10 != 0;

  /// What is wrong on the flagged ports, if anything.
  EcLinkFault? get linkFault => EcLinkFault.fromLinkState(linkState);

  /// The subdevice answered. A subdevice that is not present has no ports worth
  /// judging; everything it would say is missing.
  bool get present => linkState & 0x01 == 0 && state != EcSubDeviceState.unknown;

  bool get crcFresh =>
      crcSum > 0 && crcStableSeconds < kEcCrcFreshWindow.inSeconds;

  int get linkLostSum => linkLostPort.fold(0, (a, b) => a + b);

  /// Whether `linkState` flags [port].
  ///
  /// A fault with no port bits at all (a subdevice that is simply gone) is read as
  /// every port: it has no working link on any of them.
  bool portFlagged(EcPort port) {
    if (linkFault == null) return false;
    if (linkState & 0xF0 == 0) return true;
    return linkState & port.linkStateMask != 0;
  }

  /// One port's health.
  ///
  /// [inUse] is whether the topology puts anything on the other end. A port
  /// nothing is plugged into is unused rather than fine, unless it has figures
  /// of its own, in which case it is not as unused as the export thinks.
  EcHealth portHealth(EcPort port, {required bool inUse}) {
    // A fault that names no port (a subdevice that is simply gone) says nothing
    // about a socket nothing was ever plugged into. Painting those red too
    // would turn one missing drive into four alarms.
    if (portFlagged(port) && (inUse || linkState & 0xF0 != 0)) {
      return linkFault == EcLinkFault.additionalLink
          ? EcHealth.warning
          : EcHealth.fault;
    }
    final crc = crcPort[port.index];
    final lost = linkLostPort[port.index];
    if (lost > 0 || (crc > 0 && crcFresh)) return EcHealth.warning;
    return inUse ? EcHealth.ok : EcHealth.unused;
  }

  /// The row's colour.
  ///
  /// Not the PLC's `bOk`, which goes false for any non-zero `linkState` —
  /// including "extra link", which is a documentation problem and not a
  /// stopped machine. A fault here is what an operator has to go and fix:
  /// out of OP, the error flag, or a link that is actually missing.
  /// Recent CRC errors and link drops since the last reset are a warning.
  EcHealth get health {
    final fault = linkFault;
    if (state != EcSubDeviceState.op || error) return EcHealth.fault;
    if (fault != null && fault != EcLinkFault.additionalLink) {
      return EcHealth.fault;
    }
    if (fault == EcLinkFault.additionalLink || crcFresh || linkLostSum > 0) {
      return EcHealth.warning;
    }
    return EcHealth.ok;
  }

  static EcSubDeviceDiag? tryParse(DynamicValue value) {
    if (!value.isObject) return null;
    if (!value.contains(EcDiagFields.deviceState) &&
        !value.contains(EcDiagFields.state)) {
      return null;
    }
    var deviceState = _int(value, EcDiagFields.deviceState);
    // A PLC revision that only publishes the decoded enum still says what
    // state the subdevice is in.
    if (!value.contains(EcDiagFields.deviceState)) {
      deviceState = _int(value, EcDiagFields.state) |
          (_bool(value, EcDiagFields.error) ? 0x10 : 0);
    }
    return EcSubDeviceDiag(
      deviceState: deviceState,
      linkState: _int(value, EcDiagFields.linkState),
      crcSum: _int(value, EcDiagFields.crcSum),
      crcStableSeconds: _int(value, EcDiagFields.crcStableSeconds),
      crcPort: _ports(value, EcDiagFields.crcPort),
      linkLostPort: _ports(value, EcDiagFields.linkLostPort),
      plcOk: _bool(value, EcDiagFields.ok),
    );
  }

  /// All-zero, which is what an unfilled slot of the array reads as.
  bool get isBlank =>
      deviceState == 0 &&
      linkState == 0 &&
      crcSum == 0 &&
      crcPort.every((c) => c == 0) &&
      linkLostPort.every((c) => c == 0);
}

/// Whatever is on the other end of one port.
class EcNeighbour {
  const EcNeighbour.master() : subdevice = null, port = null;
  const EcNeighbour(EcSubDevice this.subdevice, this.port);

  /// Null for the master itself.
  final EcSubDevice? subdevice;

  /// The port on [subdevice] this link lands on.
  final EcPort? port;

  bool get isMaster => subdevice == null;

  String get label =>
      isMaster ? 'Master' : '${subdevice!.label} · ${port?.letter ?? '?'}';
}

/// One subdevice: where it sits, what it is, and what it is doing.
class EcSubDevice {
  EcSubDevice({
    required this.busLabel,
    required this.position,
    this.info,
    this.diag,
  });

  final String busLabel;

  /// 1-based, the PLC array index. Bus position is one less.
  final int position;
  final EcSubDeviceInfo? info;
  final EcSubDeviceDiag? diag;

  String get label {
    final n = info?.shortName;
    return n == null || n.isEmpty ? '#$position' : n;
  }

  EcHealth get health => diag?.health ?? EcHealth.unknown;
}

/// One EtherCAT master's subdevices, joined up.
///
/// Built from the two arrays as delivered. Either may be missing — the info
/// array before its first read arrives, the diag array on a PLC that has not
/// been downloaded yet — and the bus still lists what it can.
class EcBus {
  EcBus(this.label, this.subdevices)
      : _byAddr = {
          for (final s in subdevices)
            if (s.info != null && s.info!.physAddr != 0) s.info!.physAddr: s,
        };

  factory EcBus.fromValues(
    String label, {
    DynamicValue? info,
    DynamicValue? diag,
  }) {
    final infos = _elements(info, EcSubDeviceInfo.tryParse);
    final diags = _elements(diag, EcSubDeviceDiag.tryParse);

    // The info array names every subdevice the export knows; the rest of its 128
    // slots are empty. Without it, the diag array's filled slots are the best
    // available answer to "how many".
    int count;
    if (infos.isNotEmpty) {
      count = 0;
      for (var i = 0; i < infos.length; i++) {
        final e = infos[i];
        if (e != null && !e.isEmpty) count = i + 1;
      }
    } else {
      count = 0;
      for (var i = 0; i < diags.length; i++) {
        final d = diags[i];
        if (d != null && !d.isBlank) count = i + 1;
      }
    }

    return EcBus(label, [
      for (var i = 0; i < count; i++)
        EcSubDevice(
          busLabel: label,
          position: i + 1,
          info: i < infos.length ? infos[i] : null,
          diag: i < diags.length ? diags[i] : null,
        ),
    ]);
  }

  final String label;
  final List<EcSubDevice> subdevices;
  final Map<int, EcSubDevice> _byAddr;

  EcSubDevice? at(int position) =>
      position >= 1 && position <= subdevices.length ? subdevices[position - 1] : null;

  /// What [port] on [subdevice] is plugged into, or null when nothing is.
  ///
  /// The info array only records each subdevice's *upstream* link: port A goes to
  /// `prevPhysAddr` on `prevPort`. Ports B to D are the reverse lookup — the
  /// subdevices that name this one as their upstream on that port. The frame
  /// always enters a subdevice on A, so that is where each of them lands.
  EcNeighbour? neighbour(EcSubDevice subdevice, EcPort port) {
    final info = subdevice.info;
    if (info == null) return null;
    if (port == EcPort.a) {
      if (info.prevPhysAddr == 0) return const EcNeighbour.master();
      final up = _byAddr[info.prevPhysAddr];
      return up == null ? null : EcNeighbour(up, info.prevPort);
    }
    for (final s in subdevices) {
      final si = s.info;
      if (si == null || si.prevPhysAddr != info.physAddr) continue;
      if (si.prevPort == port) return EcNeighbour(s, EcPort.a);
    }
    return null;
  }

  /// [port]'s health on [subdevice], with the topology filled in.
  EcHealth portHealth(EcSubDevice subdevice, EcPort port) {
    final diag = subdevice.diag;
    if (diag == null) return EcHealth.unknown;
    return diag.portHealth(port, inUse: neighbour(subdevice, port) != null);
  }

  int count(EcHealth h) => subdevices.where((s) => s.health == h).length;
}

/// A subdevice or asset name reduced to what two spellings of it share.
///
/// Whitespace goes — the ATV320 labels on the plant pages carry a line break
/// (`CVS01.\nCN01.FD01`) — and case goes, since TwinCAT is case-insensitive
/// and nobody typing a label thinks about it.
String normaliseEcName(String s) =>
    s.replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// Where one device on a page gets its EtherCAT diagnostics from.
///
/// Self-contained on purpose: the device reads its master's arrays by key and
/// needs nothing else on the page to find itself. [position] is the join the
/// PLC defines; [name] is the identity that survives a subdevice being inserted
/// upstream, which shifts every position after it.
@JsonSerializable(includeIfNull: false)
class EcSubDeviceBinding {
  EcSubDeviceBinding({
    this.diagKey = '',
    this.infoKey = '',
    this.position = 0,
    this.name,
  });

  /// Key of the master's `ECT_Diag.Device_<n>_Diag` array.
  String diagKey;

  /// Key of the master's `ECT_Diag.Device_<n>_SlaveInfo` array.
  String infoKey;

  /// 1-based array index; 0 when only [name] is known.
  int position;

  /// The subdevice's short name (`p_stat_sName` without its model), when known.
  String? name;

  bool get isBound =>
      diagKey.isNotEmpty && (position >= 1 || (name?.isNotEmpty ?? false));

  bool get isEmpty =>
      diagKey.isEmpty &&
      infoKey.isEmpty &&
      position < 1 &&
      (name?.isEmpty ?? true);

  List<String> get keys => [
        if (diagKey.isNotEmpty) diagKey,
        if (infoKey.isNotEmpty) infoKey,
      ];

  /// The subdevice this binding points at on [bus]: by name when the name is
  /// found, else by position.
  EcSubDevice? resolve(EcBus bus) => _byName(bus) ?? bus.at(position);

  /// True when the name now lives at a different position than stored — a
  /// subdevice was added or removed upstream since this device was bound.
  bool drifted(EcBus bus) {
    final s = _byName(bus);
    return s != null && s.position != position;
  }

  EcSubDevice? _byName(EcBus bus) {
    final n = name;
    if (n == null || n.isEmpty) return null;
    final want = normaliseEcName(n);
    for (final s in bus.subdevices) {
      final info = s.info;
      if (info != null && normaliseEcName(info.shortName) == want) return s;
    }
    return null;
  }

  factory EcSubDeviceBinding.fromJson(Map<String, dynamic> json) =>
      _$EcSubDeviceBindingFromJson(json);
  Map<String, dynamic> toJson() => _$EcSubDeviceBindingToJson(this);
}

/// One master, as the table knows it: a name and the keys of its arrays.
@JsonSerializable(includeIfNull: false)
class EcBusConfig {
  EcBusConfig({
    this.label = '',
    this.diagKey = '',
    this.infoKey = '',
    this.countKey,
  });

  /// What to call this master, e.g. `Device 1` or `Cabinet A1`.
  String label;

  /// Key of `ECT_Diag.Device_<n>_Diag`.
  String diagKey;

  /// Key of `ECT_Diag.Device_<n>_SlaveInfo`.
  String infoKey;

  /// Key of `ECT_Diag.Device_<n>_SlaveCount`, when there is one. Only a
  /// cross-check: a count that disagrees with the info array means the GVL
  /// and the export it was generated from are out of step.
  String? countKey;

  List<String> get keys => [
        if (diagKey.isNotEmpty) diagKey,
        if (infoKey.isNotEmpty) infoKey,
        if (countKey?.isNotEmpty ?? false) countKey!,
      ];

  factory EcBusConfig.fromJson(Map<String, dynamic> json) =>
      _$EcBusConfigFromJson(json);
  Map<String, dynamic> toJson() => _$EcBusConfigToJson(this);
}

List<T?> _elements<T>(DynamicValue? array, T? Function(DynamicValue) parse) {
  if (array == null || !array.isArray) return const [];
  return [for (final e in array.asArray) parse(e)];
}

// `DynamicValue.operator[]` throws on a missing member, so every read is
// guarded: a PLC running an older revision of the DUT must degrade, not take
// the page down.
bool _bool(DynamicValue v, String f) => v.contains(f) ? v[f].asBool : false;
int _int(DynamicValue v, String f) => v.contains(f) ? v[f].asInt : 0;
String _str(DynamicValue v, String f) =>
    v.contains(f) ? v[f].asString.trim() : '';

List<int> _ports(DynamicValue v, String f) {
  final out = List<int>.filled(EcPort.values.length, 0);
  if (!v.contains(f)) return out;
  final a = v[f];
  if (!a.isArray) return out;
  final list = a.asArray;
  for (var i = 0; i < out.length && i < list.length; i++) {
    out[i] = list[i].asInt;
  }
  return out;
}
