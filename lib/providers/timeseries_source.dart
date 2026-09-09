/// Which timeseries source this station reads history from.
///
/// The transport branch for charts and trend readouts, in one place, written
/// the way `alarmManProvider` and `auditTrailStoreProvider` write theirs.
///
/// A separate file from `timeseries.dart` because the tracker is one consumer
/// of six: `graph.dart`, `bpm.dart`, `rate_value.dart`, `ratio_number.dart`,
/// `history_graph_pane.dart` and `history_table_pane.dart` all reached
/// `databaseProvider` directly and all went blank on a gateway panel for the
/// same reason. See `lib/core/timeseries_source.dart` for the whole of it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';

import '../core/gateway_state_man.dart';
import '../core/timeseries_source.dart';
import 'database.dart';
import 'gateway.dart';
import 'state_man.dart';

/// This station's history source, or **null** when it has no database.
///
/// Null keeps its direct-mode meaning exactly — no Postgres configured, and
/// again during the boot window before the connection opens — and every call
/// site already renders that as "no data yet". What it must never mean again
/// is "this panel is in gateway mode", which is what it silently meant from
/// the commit that made `databaseProvider` branch on the transport.
///
/// In gateway mode this **never** answers null and never falls back to the
/// database. A station that reached gateway mode with no relay client behind
/// its StateMan is a defect in `lib/providers/state_man.dart`, and it is
/// refused by name here rather than papered over with a local route: a route
/// that exists will be taken.
///
/// `ref.watch` on both the config and the StateMan, never `ref.read` — the
/// Phase 14 blocker `alarm.dart:45` records was a stale transport held over a
/// disposed client whose streams *close* rather than error, so nothing
/// reported it.
final timeseriesSourceProvider =
    FutureProvider<TimeseriesSource?>((ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (gateway.isGateway) {
    final stateMan = await ref.watch(stateManProvider.future);
    final remote = stateMan is GuardedStateMan
        ? stateMan.innerAs<GatewayStateMan>()?.remote
        : null;
    if (remote == null) {
      throw UnsupportedError(
          'timeseriesSourceProvider is not available in gateway mode: this '
          'station resolved a StateMan with no relay client behind it. Fix '
          'the gateway branch of lib/providers/state_man.dart — do not fall '
          'back to the database here.');
    }
    return RelayedTimeseriesSource(remote.timeseries);
  }

  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  return DatabaseTimeseriesSource(db);
});
