import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/timeseries_source.dart';
import '../../../providers/timeseries_source.dart';

/// Calls [onSourceAvailable] whenever [timeseriesSourceProvider] produces a
/// [TimeseriesSource] that is not the one the caller is already using.
///
/// `timeseriesSourceProvider` yields `null` rather than throwing while a
/// **direct** station's Postgres is unreachable, and retries itself in the
/// background until it connects. An asset that grabs it once with `ref.read`
/// in `initState` takes that null, bails, and stays blank for the rest of the
/// session — nothing ever rebuilds it. On a plant-wide power cut Flutter is
/// drawing in a couple of seconds while Postgres is still replaying WAL, so
/// that is the normal outcome, not an edge case.
///
/// **This was `reinitOnDatabaseAvailable`, over `databaseProvider`**, and the
/// rename is the fix rather than a tidy-up. `databaseProvider` answers null on
/// a gateway panel *by design* — the backend is the only process that may
/// touch TimescaleDB — so on those stations the three assets that call this
/// took that null on every rebuild and every trend, BPM and rate readout on
/// the panel stayed blank for the life of the process, with nothing anywhere
/// saying why. The source provider branches on the transport, so null means
/// what it always meant and nothing else.
///
/// Call this from `initState` (or from the async init it kicks off). It is
/// deliberately **not** `ref.watch`: `ConsumerStatefulElement.build` moves
/// `_dependencies` aside, lets the build re-register whatever it watches, and
/// then closes everything left over — so a watch registered in `initState` is
/// silently closed at the end of the first build and never fires again.
/// `listenManual` is the subscription that survives rebuilds and is closed for
/// us when the element unmounts.
///
/// [currentSource] is read at notification time, so a re-emission of the
/// instance the caller already holds costs nothing. A genuinely new instance —
/// a reconnect, a relay client rebuilt behind a gateway panel, or the operator
/// applying new database settings, which invalidates the provider — re-runs
/// [onSourceAvailable].
ProviderSubscription<AsyncValue<TimeseriesSource?>>
    reinitOnTimeseriesSourceAvailable(
  WidgetRef ref, {
  required TimeseriesSource? Function() currentSource,
  required void Function(TimeseriesSource source) onSourceAvailable,
}) {
  return ref.listenManual<AsyncValue<TimeseriesSource?>>(
    timeseriesSourceProvider,
    (previous, next) {
      final source = next.valueOrNull;
      if (source == null) return;
      // `==`, not `identical`: the provider mints a fresh wrapper on every
      // rebuild, and two wrappers over the same handle are the same source.
      // See `DatabaseTimeseriesSource.==` — under reference identity this
      // line let an unrelated invalidate cost every chart a full refetch.
      if (source == currentSource()) return;
      onSourceAvailable(source);
    },
  );
}
