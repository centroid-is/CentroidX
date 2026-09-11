/// Binding the devices on a page to their EtherCAT subdevices by name.
///
/// The export and the mimic were drawn from the same drawings, so the names
/// mostly agree: `CVS01.CN01.FD01` on a drive's label is `CVS01.CN01.FD01
/// (ATV320 EtherCAT)` on the PLC. A rack's slices are the exception — they
/// carry `A1.03` where the PLC says `ST101.A1.03`, and several cabinets on a
/// station have an A1.03. So this binds what it can prove, breaks ties only
/// where the page itself decides them, and reports the rest rather than
/// guessing.
library;

import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

import 'common.dart';
import 'ethercat_asset.dart';
import 'ethercat_masters.dart';
import 'ethercat_subdevice.dart';

/// A subdevice on a master, as a candidate for one asset.
typedef EcCandidate = ({EcBusConfig bus, EcSubDevice subdevice});

class EcAutoBindMatch {
  const EcAutoBindMatch({
    required this.asset,
    required this.bus,
    required this.subdevice,
    this.viaPageMaster = false,
  });

  final EtherCatAsset asset;
  final EcBusConfig bus;
  final EcSubDevice subdevice;

  /// Several masters have a subdevice by this name, and this one was picked
  /// because it is the master the rest of the page matched without doubt.
  final bool viaPageMaster;

  EcSubDeviceBinding get binding => EcSubDeviceBinding(
        diagKey: bus.diagKey,
        infoKey: bus.infoKey,
        position: subdevice.position,
        name: subdevice.info?.shortName,
      );
}

class EcAutoBindAmbiguity {
  const EcAutoBindAmbiguity({required this.asset, required this.candidates});

  final EtherCatAsset asset;
  final List<EcCandidate> candidates;
}

class EcAutoBindPlan {
  const EcAutoBindPlan({
    this.matched = const [],
    this.unmatched = const [],
    this.ambiguous = const [],
    this.skipped = const [],
  });

  final List<EcAutoBindMatch> matched;

  /// No subdevice on any master carries the name — or the asset has no name.
  final List<EtherCatAsset> unmatched;
  final List<EcAutoBindAmbiguity> ambiguous;

  /// Already bound, and left alone because the plan was not asked to
  /// overwrite.
  final List<EtherCatAsset> skipped;
}

/// Every EtherCAT device in [assets], slices inside racks included.
Iterable<EtherCatAsset> ecAssetsOn(Iterable<Asset> assets) sync* {
  for (final a in assets) {
    if (a is EtherCatAsset) yield a;
    yield* ecAssetsOn(a.childAssets);
  }
}

/// What binding [page] by name would do, without doing it.
EcAutoBindPlan planEcAutoBind(
  Iterable<Asset> page,
  Map<EcBusConfig, EcBus> buses, {
  bool overwrite = false,
}) {
  final matched = <EcAutoBindMatch>[];
  final unmatched = <EtherCatAsset>[];
  final skipped = <EtherCatAsset>[];
  final pending = <(EtherCatAsset, List<EcCandidate>)>[];

  for (final asset in ecAssetsOn(page)) {
    if (!overwrite && asset.isEcBound) {
      skipped.add(asset);
      continue;
    }
    final hits = _candidates(asset, buses);
    if (hits.isEmpty) {
      unmatched.add(asset);
    } else if (hits.length == 1) {
      matched.add(EcAutoBindMatch(
          asset: asset, bus: hits.single.bus, subdevice: hits.single.subdevice));
    } else {
      pending.add((asset, hits));
    }
  }

  // A page draws one cabinet or one line, so its certain matches say which
  // master it is about. `A1.03` next to thirteen drives that all matched
  // Device 1 is Device 1's A1.03. With no clear winner nothing is inferred.
  final votes = <EcBusConfig, int>{};
  for (final m in matched) {
    votes[m.bus] = (votes[m.bus] ?? 0) + 1;
  }
  EcBusConfig? pageMaster;
  var best = 0;
  var tied = false;
  for (final e in votes.entries) {
    if (e.value > best) {
      best = e.value;
      pageMaster = e.key;
      tied = false;
    } else if (e.value == best) {
      tied = true;
    }
  }
  if (tied) pageMaster = null;

  final ambiguous = <EcAutoBindAmbiguity>[];
  for (final (asset, hits) in pending) {
    final onPage = [
      for (final h in hits)
        if (identical(h.bus, pageMaster)) h,
    ];
    if (onPage.length == 1) {
      matched.add(EcAutoBindMatch(
        asset: asset,
        bus: onPage.single.bus,
        subdevice: onPage.single.subdevice,
        viaPageMaster: true,
      ));
    } else {
      ambiguous.add(EcAutoBindAmbiguity(asset: asset, candidates: hits));
    }
  }

  return EcAutoBindPlan(
    matched: matched,
    unmatched: unmatched,
    ambiguous: ambiguous,
    skipped: skipped,
  );
}

/// Every subdevice [asset]'s name could mean: exact matches if there are any,
/// else those whose name ends in it at a dot — `A1.03` is `ST101.A1.03`, but
/// `1.03` is nothing.
List<EcCandidate> _candidates(
    EtherCatAsset asset, Map<EcBusConfig, EcBus> buses) {
  final name = normaliseEcName(asset.ecName);
  if (name.isEmpty) return const [];
  final exact = <EcCandidate>[];
  final suffix = <EcCandidate>[];
  for (final e in buses.entries) {
    for (final s in e.value.subdevices) {
      final info = s.info;
      if (info == null || info.isEmpty) continue;
      final slaveName = normaliseEcName(info.shortName);
      if (slaveName == name) {
        exact.add((bus: e.key, subdevice: s));
      } else if (slaveName.endsWith('.$name')) {
        suffix.add((bus: e.key, subdevice: s));
      }
    }
  }
  return exact.isNotEmpty ? exact : suffix;
}

/// Writes [plan]'s bindings onto their assets.
void applyEcAutoBind(EcAutoBindPlan plan) {
  for (final m in plan.matched) {
    m.asset.ecSubDevice = m.binding;
  }
}

/// The station's masters with their subdevice names read, for planning.
///
/// Only the info arrays: binding is about names, and a diag array that has
/// not answered yet is no reason not to bind. A master whose info cannot be
/// read comes back empty, and its devices are reported unmatched.
Future<Map<EcBusConfig, EcBus>> loadEcBuses(
  StateMan sm, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final out = <EcBusConfig, EcBus>{};
  for (final m in discoverEcMasters(sm.keyMappings)) {
    DynamicValue? info;
    if (m.infoKey.isNotEmpty) {
      try {
        info = await sm.read(m.infoKey).timeout(timeout);
      } catch (_) {
        info = null;
      }
    }
    out[m] = EcBus.fromValues(m.label, info: info);
  }
  return out;
}
