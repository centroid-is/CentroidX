import 'dart:convert';
import 'package:logger/logger.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/preferences.dart';

import 'gateway.dart';
import 'preferences.dart';
import 'state_man.dart';
import 'database.dart';
import 'timeseries_source.dart';

part 'collector.g.dart';

@Riverpod(keepAlive: true)
Future<Collector?> collector(Ref ref) async {
  final stateMan = await ref.watch(stateManProvider.future);

  // A gateway panel has no database by design, and this used to answer null
  // for it — so every trend that reads through the collector (conveyor,
  // sensor, analog box, box erector, the history panes) drew "No collector
  // available" on a plant that had been recording all along. The backend
  // collects; this panel only reads, over the relay's timeseries family,
  // which the gateway's policy gates per series. Nothing is read from the
  // shared store either: the collector config only says whether to collect,
  // and a gateway panel never does.
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (gateway.isGateway) {
    final source = await ref.watch(timeseriesSourceProvider.future);
    return Collector.readOnly(
      config: CollectorConfig(collect: false),
      stateMan: stateMan,
      history: source!,
    );
  }

  final database = await ref.watch(databaseProvider.future);
  if (database == null) {
    Logger().e('Cannot create collector: Database is not connected');
    return null;
  }
  // The injected, guarded store — never a preferences store this provider
  // newed up for itself, which is what spec §6's second bypass was. That entry
  // is closed by taking the shared store the rest of the app writes
  // configuration through, not by moving `collector_config` to
  // `localPreferencesProvider`: that would be the easier change and the wrong
  // one, because it is plant configuration and that would put it back outside
  // the guard. `03-11`'s gate greps this file for a constructed store, so the
  // name of the thing not to construct is deliberately not written here.
  final config = await resolveCollectorConfig(
    shared: await ref.watch(preferencesProvider.future),
    systemWrites: await ref.watch(systemPreferencesProvider.future),
    local: ref.watch(localPreferencesProvider),
  );

  return Collector(
    config:
        config.copyWith(collect: false), // do not collect data in main isolate
    stateMan: stateMan,
    database: database,
  );
}

/// The collector's configuration, read from [shared] and carried onto it if it
/// is still only on the device.
///
/// **Why the carry-over exists.** Until this provider took the injected
/// preferences, `collector_config` was written straight to the device's own
/// preferences file. [shared] is the database-backed store, and its
/// in-memory cache is seeded by `loadFromPostgres()` — never by
/// `_loadFromLocalCache()` — whenever the database is up, which is the only
/// case this function is called in. So a station whose config is only in the
/// device file reads `null` here, and without the carry-over would be handed a
/// **default**: a collector station silently demoted to one that records
/// nothing. `collector_config_migration_test.dart`'s first group proves that
/// premise rather than assuming it.
///
/// The order is the one `migrateMcpConfigToDeviceLocal` established: read the
/// device blob **first**, then the shared one, then write. The two stores share
/// a physical file — the device store is the shared store's local cache — so a
/// write to [shared] mirrors into [local], and reading [local] afterwards would
/// be reading back what was just written.
///
/// [systemWrites] is the unchecked path, and both writes here take it: they run
/// at boot with nobody signed in, and `collector_config` requires `administer`.
/// It skips the denial, not the audit — each write still lands in the trail
/// marked `origin: 'system'`.
Future<CollectorConfig> resolveCollectorConfig({
  required PreferencesApi shared,
  required PreferencesApi systemWrites,
  required PreferencesApi local,
}) async {
  final localJson = await local.getString(Collector.configLocation);

  final sharedJson = await shared.getString(Collector.configLocation);
  if (sharedJson != null) {
    return CollectorConfig.fromJson(
        jsonDecode(sharedJson) as Map<String, dynamic>);
  }

  final carried = _decodeOrNull(localJson);
  final config = carried ?? CollectorConfig();
  await systemWrites.setString(
      Collector.configLocation, jsonEncode(config.toJson()));
  return config;
}

/// A [CollectorConfig] from [json], or null when there is nothing usable there.
///
/// Tolerant only on the carry-over source: a corrupt blob left in the device
/// file by an older build is nothing worth migrating, and it must not stop the
/// collector from starting. The shared-store read above is deliberately left
/// strict, exactly as it was before this plan.
CollectorConfig? _decodeOrNull(String? json) {
  if (json == null) return null;
  try {
    return CollectorConfig.fromJson(jsonDecode(json) as Map<String, dynamic>);
  } on Object {
    return null;
  }
}
