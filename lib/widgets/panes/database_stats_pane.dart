/// What the database's connection slots are being spent on.
///
/// On 2026-08-21 the Postgres server ran out of connections and refused every
/// write. There was no way to see who was holding them: the slots reserved for
/// the superuser had gone the same way, so psql could not get in to ask. This
/// pane asks from inside the application, which is holding a connection of its
/// own and can therefore still get an answer while the server has none left to
/// give.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/database_connections.dart';

import '../../core/gateway_default.dart';
import '../../providers/database.dart';
import '../../providers/gateway.dart';
import 'pane_chrome.dart';
import 'side_pane.dart';

/// Pane id, so a second tap on the info button closes it again.
const String kDatabaseStatsPaneId = 'database:connections';

/// How often the pane re-counts while it is open.
///
/// Slow on purpose: the count itself takes a connection, and this pane exists
/// for a fault where connections are the thing in short supply.
const Duration kCensusRefreshInterval = Duration(seconds: 10);

/// Opens (or toggles shut) the connection census pane.
bool showDatabaseStatsPane(BuildContext context) => showSidePane(
      context: context,
      id: kDatabaseStatsPaneId,
      builder: (_) => const DatabaseStatsPane(),
    );

/// How the census reads as equipment state.
PaneStatus censusPaneStatus(ConnectionCensus census) => censusIsAlarming(census)
    ? const PaneStatus.warning('Nearly full')
    : const PaneStatus.running('Healthy');

/// The pane: fetches the census on a timer for as long as it is open.
class DatabaseStatsPane extends ConsumerStatefulWidget {
  const DatabaseStatsPane({super.key});

  @override
  ConsumerState<DatabaseStatsPane> createState() => _DatabaseStatsPaneState();
}

class _DatabaseStatsPaneState extends ConsumerState<DatabaseStatsPane> {
  Timer? _timer;
  ConnectionCensus? _census;
  Map<String, dynamic>? _writeStats;
  Object? _error;
  bool _postgres = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(kCensusRefreshInterval, (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final db = await ref.read(databaseProvider.future);
      if (db == null || db.db.config.postgres == null) {
        if (!mounted) return;
        setState(() {
          _postgres = false;
          _loading = false;
        });
        return;
      }
      // Read before the query: getStats() is a local field read and cannot
      // fail, so the write counters stay visible even when the census — which
      // needs a connection, the very thing that runs out — does not.
      final writeStats = db.getStats();
      final rows = await db.db.customSelect(connectionCensusSql).get();
      final census = parseConnectionCensus(rows.map((r) => r.data));
      if (!mounted) return;
      setState(() {
        _census = census;
        _writeStats = writeStats;
        _error = null;
        _postgres = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Whether the process showing this pane is the one writing samples.
  ///
  /// It is not. `collectorProvider` (lib/providers/collector.dart) builds its
  /// Collector with `collect: false` — "do not collect data in main isolate" —
  /// and the collecting Collector lives in the backend service, a separate
  /// process entirely. Written as a constant with its reasoning rather than
  /// inlined, so that if the topology ever changes this is the one place to
  /// look.
  static const bool _collectsInThisProcess = false;

  /// Whether this panel reads the plant through a relay rather than holding
  /// its own pool.
  ///
  /// `valueOrNull` with the direct-mode default, never a spinner: this decides
  /// one sentence inside a pane that is already drawn, and the honest failure
  /// while the preference is still loading is the old sentence — which is
  /// right on a station and is the case this pane was written for.
  bool get _relayed =>
      (ref.watch(gatewayConfigProvider).valueOrNull ?? defaultGatewayConfig())
          .isGateway;

  @override
  Widget build(BuildContext context) {
    final census = _census;
    return SidePane(
      title: 'DB connections',
      subtitle: 'Refreshed every ${kCensusRefreshInterval.inSeconds} s',
      icon: Icons.storage,
      status: census == null ? const PaneStatus.unknown() : censusPaneStatus(census),
      child: !_postgres
          // Two different facts wear the same `_postgres == false`, and
          // saying the wrong one is how this pane lied on every relayed
          // panel. `databaseProvider` answers **null** in gateway mode
          // (`lib/providers/database.dart:50-52`) — deliberately, because the
          // panel is not supposed to hold a second connection to the plant's
          // Postgres — and a null database took the local-storage branch.
          // "This database is local storage, not a Postgres server" is then
          // false twice over: the plant's database is a Postgres, and the
          // reason there is nothing to count here is that this panel is not
          // the machine holding the connections.
          ? PaneSection(
              child: Text(_relayed
                  ? 'This panel is relayed, so it opens no database '
                      'connection of its own. The plant\'s Postgres is '
                      'behind the gateway, and its connections are counted '
                      'on the machine that holds them.'
                  : 'This database is local storage, not a Postgres '
                      'server, so there are no connections to count.'),
            )
          : census != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DatabaseCensusView(census: census, staleError: _error),
                    if (_writeStats != null)
                      DatabaseWriteQueueView(
                        stats: _writeStats!,
                        collectsHere: _collectsInThisProcess,
                      ),
                  ],
                )
              : _loading
                  ? const PaneSection(
                      child: Center(child: CircularProgressIndicator()))
                  : PaneSection(child: _CensusError(error: _error)),
    );
  }
}

/// What this process's write pipeline has thrown away, and how close it is to
/// throwing away more.
///
/// Built from [Database.getStats]. Rows can be discarded for two unrelated
/// reasons and they are shown apart, because the remedies are different:
///
///   * *Discarded* — a queue filled up while the database was unreachable. The
///     remedy is to shorten the outage, or to raise [kMaxQueuedRowsPerTable].
///   * *Rejected* — the server refused the values themselves and always will,
///     almost always a counter that has outgrown an `INTEGER` column. The
///     remedy is to widen the column.
///
/// Both were previously invisible: `getStats()` reported only writes and waits,
/// and this pane showed neither. A thirty-second outage could take two thirds
/// of a tag's samples with nothing anywhere to say so.
class DatabaseWriteQueueView extends StatelessWidget {
  final Map<String, dynamic> stats;

  /// Whether this process actually collects data.
  ///
  /// On a normal HMI station it does not — collection runs in the backend
  /// service, in its own process — so these counters are this application's own
  /// writes and will read zero. Saying so is the point: a permanent zero that
  /// looks like a health indicator is worse than no indicator, because it reads
  /// as "no data has been lost" when it means "this process was never the one
  /// writing".
  final bool collectsHere;

  const DatabaseWriteQueueView({
    super.key,
    required this.stats,
    required this.collectsHere,
  });

  int _int(String key) => (stats[key] as int?) ?? 0;

  Map<String, int> _byTable(String key) =>
      (stats[key] as Map?)?.cast<String, int>() ?? const {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dropped = _int('dropped_rows');
    final poisoned = _int('poisoned_rows');
    final queued = _int('queued_rows');
    final lost = dropped + poisoned;
    final perTableCap = _int('max_queued_rows_per_table');

    final byTable = <String, ({int dropped, int poisoned})>{};
    for (final e in _byTable('dropped_rows_by_table').entries) {
      byTable[e.key] = (dropped: e.value, poisoned: 0);
    }
    for (final e in _byTable('poisoned_rows_by_table').entries) {
      final prev = byTable[e.key];
      byTable[e.key] =
          (dropped: prev?.dropped ?? 0, poisoned: e.value);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneSection(
          title: 'Rows never stored',
          child: PaneTileRow(
            children: [
              PaneMetricTile(
                label: 'Discarded',
                value: '$dropped',
                valueColor: dropped > 0 ? theme.colorScheme.error : null,
              ),
              PaneMetricTile(
                label: 'Rejected',
                value: '$poisoned',
                valueColor: poisoned > 0 ? theme.colorScheme.error : null,
              ),
              PaneMetricTile(
                label: 'Waiting',
                value: '$queued',
              ),
            ],
          ),
        ),
        if (byTable.isNotEmpty)
          PaneSection(
            title: 'By tag',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final e in byTable.entries)
                  PaneDetailRow(
                    label: e.key,
                    value: [
                      if (e.value.dropped > 0) '${e.value.dropped} discarded',
                      if (e.value.poisoned > 0) '${e.value.poisoned} rejected',
                    ].join(' · '),
                  ),
              ],
            ),
          ),
        PaneSection(
          child: Text(
            !collectsHere
                ? 'This application does not collect data — collection runs in '
                    'the backend service, in a separate process, so these '
                    'counters cover only this application\'s own writes. They '
                    'are expected to be zero here; the collector\'s own figures '
                    'are in its log.'
                : lost > 0
                    ? 'Discarded rows filled a queue during an outage and are '
                        'gone for good; the buffer holds $perTableCap rows per '
                        'tag. Rejected rows were refused by the server on their '
                        'contents — usually a counter that has outgrown an '
                        'INTEGER column, which needs widening to BIGINT.'
                    : 'Nothing has been discarded. "Waiting" is what is buffered '
                        'right now; it only grows while the database is '
                        'unreachable, and rows are only lost once it reaches '
                        '$perTableCap for a tag.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// The census itself, given numbers.
///
/// Split out from the fetching so it can be rendered from fabricated data: the
/// goldens must not carry the plant's real addresses into a public repository.
class DatabaseCensusView extends StatelessWidget {
  final ConnectionCensus census;

  /// A refresh that failed after a census had already been shown. The old
  /// numbers stay up — stale counts beat an empty pane when the reason the
  /// refresh failed is very likely the thing being counted.
  final Object? staleError;

  const DatabaseCensusView({super.key, required this.census, this.staleError});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alarming = censusIsAlarming(census);
    final peers = census.peersByShare;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PaneSection(
          child: PaneTileRow(
            children: [
              PaneMetricTile(
                label: 'In use',
                value: '${census.total}',
                valueColor: alarming ? theme.colorScheme.error : null,
              ),
              PaneMetricTile(label: 'Limit', value: '${census.max}'),
              PaneMetricTile(
                label: 'Used',
                value: '${census.percentUsed}',
                unit: '%',
                valueColor: alarming ? theme.colorScheme.error : null,
              ),
            ],
          ),
        ),
        PaneSection(
          title: 'Connections by client',
          child: peers.isEmpty
              ? Text('The server reported no clients.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in peers)
                      PaneDetailRow(
                        label: p.app == '-' || p.app.isEmpty
                            ? p.peer
                            : '${p.peer} · ${p.app}',
                        value: '${p.count}',
                      ),
                  ],
                ),
        ),
        PaneSection(
          child: Text(
            // Kept in step with `resolvePoolSize`, whose default pool is one
            // connection: that is the "1 per client" figure below.
            'Expect one connection for each HMI client, and fewer than ten for '
            'the collector — roughly one per OPC UA server, with the weighers '
            'sharing one between them. Much more than that means a client is '
            'pooling connections it does not need, or is not handing them back. '
            'On 21 August 2026 two clients held 13 and 12, and the collector '
            'held 75, which filled a 100-connection server.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if (staleError != null)
          PaneSection(
            child: Text(
              'Last refresh failed, showing the previous count: $staleError',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _CensusError extends StatelessWidget {
  final Object? error;

  const _CensusError({this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Could not count connections.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error)),
        const SizedBox(height: 6),
        Text('$error',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
