/// Which of a subdevice's four ports physically exist.
///
/// The PLC publishes four port slots for every subdevice whatever it is: an
/// ATV320 reads zero on C and D because they are not there, which looks
/// exactly like two clean, unplugged sockets. The device classes already know
/// better — each [EtherCatAsset] declares its real sockets in
/// [EtherCatAsset.networkPorts] and the PLC model strings it stands for in
/// [EtherCatAsset.ecModels] — so the table and the panes ask here and never
/// draw a port the hardware does not have.
library;

import 'common.dart' show Asset;
import 'ethercat_asset.dart';
import 'ethercat_subdevice.dart';
import 'registry.dart';

Map<String, List<EcPort>>? _byModel;

String _normaliseModel(String m) => m.replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// The ports a subdevice of [model] has, in A–D order, or null when no device
/// class claims the model.
///
/// Built once, on first use, from the registry's prototypes: the registry
/// imports the table that calls this, so building it eagerly at import time
/// would be building it in the middle of that cycle.
List<EcPort>? ecPhysicalPorts(String? model) {
  if (model == null || model.trim().isEmpty) return null;
  return (_byModel ??= _build())[_normaliseModel(model)];
}

Map<String, List<EcPort>> _build() {
  final out = <String, List<EcPort>>{};
  for (final make in AssetRegistry.defaultFactories.values) {
    final Asset asset;
    try {
      asset = make();
    } catch (_) {
      continue;
    }
    if (asset is! EtherCatAsset) continue;
    final ids = {for (final p in asset.networkPorts) p.id};
    final ports = [
      for (final p in EcPort.values)
        if (ids.contains(p.letter)) p,
    ];
    for (final m in asset.ecModels) {
      out[_normaliseModel(m)] = ports;
    }
  }
  return out;
}

/// The ports worth drawing for [subdevice] on [bus].
///
/// The physical ones when the model is known. When it is not — a device no
/// class draws yet — the in-port, plus whatever the topology puts on a port or
/// the counters say happened there: a port with neither is one this HMI has
/// no evidence exists.
List<EcPort> ecShownPorts(EcBus bus, EcSubDevice subdevice) {
  final known = ecPhysicalPorts(subdevice.info?.model);
  if (known != null) return known;
  final d = subdevice.diag;
  return [
    for (final p in EcPort.values)
      if (p == EcPort.a ||
          bus.neighbour(subdevice, p) != null ||
          (d != null &&
              (d.crcPort[p.index] > 0 ||
                  d.linkLostPort[p.index] > 0 ||
                  d.portFlagged(p))))
        p,
  ];
}

/// Forgets the lookup, for a test that registers a different set of assets.
void debugResetEcPhysicalPorts() => _byModel = null;
