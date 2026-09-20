/// `ConfigChangeStore` over the relay: the configuration history a gateway
/// panel reads, from the backend that holds the table.
///
/// ## What this closes
///
/// `configChangeStoreProvider` reads `databaseProvider`, which answers
/// **null** on a gateway panel by design — the panel must not hold a second
/// connection to the plant's Postgres. The history page was honest about the
/// consequence ("the history is not reachable over the relay", never "no
/// changes"), and honest about a hole is still a hole: every relayed panel on
/// the plant could see that configuration had been changed by nobody, ever.
///
/// ## Why it implements the store rather than replacing it
///
/// The page, the two providers and the undo planner all speak
/// `ConfigChangeStore`. Implementing it means the transport is chosen in one
/// place — the provider — and nothing downstream learns there are two. The
/// shape `RelayedAuditTrailStore` established next door.
///
/// ## Where the decoding happens, and why here
///
/// The wire carries the **columns**, not a decoded `ConfigChange`: `kind`,
/// `scope` and `op` travel as the `wireName` they are stored as. This file
/// turns them back into the app's value type and **drops a row it cannot
/// read**, which is exactly what `ConfigChangeStore._decode` does with a row
/// from a newer build. Doing it here rather than at the backend keeps that
/// bargain per-row on the transport too: one unreadable row costs one row,
/// and `rawCount` — which the page judges "reached the cap" by — still counts
/// it.
library;

import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_change_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import 'relayed_access_stores.dart' show relayedAccessErrors;

/// The wire's query, from the store's.
///
/// `kinds` go out as the `wireName` they are stored as, so the backend filters
/// on the column rather than on a translation of it.
relay.ConfigHistoryQueryParams configHistoryParamsFor(
        ConfigChangeQuery query) =>
    relay.ConfigHistoryQueryParams(
      startMs: query.window?.start.toUtc().millisecondsSinceEpoch,
      endMs: query.window?.end.toUtc().millisecondsSinceEpoch,
      // Microseconds. The store's `(at, id)` cursor has an equality half —
      // rows AT the cursor's instant with a smaller id — and a millisecond
      // cursor is never equal to the microsecond-stamped row it came from,
      // so Load-more returns the same page forever. Measured.
      beforeUs: query.before?.microsecondsSinceEpoch,
      beforeId: query.beforeId,
      entityPrefix: query.entityPrefix,
      who: query.who,
      kindWireNames: [for (final kind in query.kinds) kind.wireName],
      scopeWireNames: query.scopeWireNames,
      limit: query.limit,
    );

/// One wire row as the app's record, or **null** when this build cannot read
/// it.
///
/// Null rather than a throw, and rather than a placeholder row: a `kind`,
/// `scope` or `op` this build has never heard of is a row written by a newer
/// station, and the direct reader's answer to one of those is to skip it. A
/// placeholder would render as a change that nobody made; a throw would take
/// the page down over one row.
ConfigChangeRecord? configChangeRecordFrom(relay.ConfigHistoryRow row) {
  final kind = ConfigKind.byWireName(row.kind);
  if (kind == null) return null;
  final scope = ConfigScope.byWireName(row.scope);
  if (scope == null) return null;
  final op = ConfigChangeOp.byWireName(row.op);
  if (op == null) return null;
  return ConfigChangeRecord(
    id: row.id,
    change: ConfigChange(
      // Local. A station reads `at` back from drift as a local instant and
      // `formatTimeOfDay` prints `.hour` raw, so a UTC-flagged instant here
      // put a relayed panel's clock hours away from the station beside it,
      // for the same row.
      at: DateTime.fromMillisecondsSinceEpoch(row.atMs),
      actionId: row.actionId,
      who: row.who,
      station: row.station,
      roleName: row.roleName,
      kind: kind,
      entityId: row.entityId,
      scope: scope,
      op: op,
      oldValue: row.oldValue,
      newValue: row.newValue,
      reason: row.reason,
    ),
  );
}

final class RelayedConfigChangeStore implements ConfigChangeStore {
  RelayedConfigChangeStore({required relay.ConfigHistoryApi api}) : _api = api;

  final relay.ConfigHistoryApi _api;

  @override
  Future<ConfigChangePage> changesPage(ConfigChangeQuery query) =>
      relayedAccessErrors(() async {
        final page = await _api.changesPage(configHistoryParamsFor(query));
        return ConfigChangePage(
          rows: [
            for (final row in page.rows)
              if (configChangeRecordFrom(row) case final record?) record,
          ],
          // **From the wire's raw count, never from the decoded list.** A
          // page that judged the cap by what it could read would hide the
          // Load-more control, and every row behind it, on the strength of
          // one row written by a newer build.
          rawCount: page.rawCount,
          // Local, not UTC. The panel hands this straight back as the next
          // page's cursor and the backend renders it for a text comparison
          // against rows drift wrote in local form; a UTC-flagged instant
          // renders `…Z` where the rows render `… +hh:mm`, and the two do
          // not sort against each other. It is also what the page DISPLAYS,
          // and `formatTimeOfDay` prints `.hour` raw — so a UTC instant here
          // showed a relayed panel a different time for the same row than
          // the station beside it.
          oldestAt: page.oldestAtUs == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(page.oldestAtUs!),
          oldestId: page.oldestId,
          hasMore: page.hasMore,
        );
      });

  @override
  Future<List<ConfigChangeRecord>> changes(ConfigChangeQuery query) async =>
      (await changesPage(query)).rows;

  @override
  Future<Map<String, List<ConfigChangeRecord>>> changesByAction(
          Iterable<String> actionIds) =>
      relayedAccessErrors(() async {
        final byAction = await _api.changesByAction(actionIds.toList());
        return <String, List<ConfigChangeRecord>>{
          // An action the backend did not mention stays absent. An empty list
          // here would say "that action changed nothing", which is a claim
          // about an action rather than the absence of one.
          for (final entry in byAction.entries)
            entry.key: [
              for (final row in entry.value)
                if (configChangeRecordFrom(row) case final record?) record,
            ],
        };
      });

  @override
  Future<Map<String, int>> changeCountsByAction(Iterable<String> actionIds) =>
      relayedAccessErrors(() => _api.changeCountsByAction(actionIds.toList()));

  /// One entity's history — **not on the wire, and the refusal says so.**
  ///
  /// [EntityHistory] carries `historyKept`, the difference between "nothing
  /// happened" and "the log is silent about this kind". Answering it from a
  /// transport that cannot ask would mean guessing which of the two, and both
  /// guesses are a sentence an engineer would act on. Nothing under `lib/`
  /// calls this today; the throw is here so that the first caller finds out
  /// at the call site rather than from a screen.
  @override
  Future<EntityHistory> entityHistory({
    required ConfigKind kind,
    required String entityId,
    required ConfigScope scope,
    int limit = kConfigChangeRowLimit,
  }) =>
      throw UnsupportedError(
          'ConfigChangeStore.entityHistory is not available in gateway mode: '
          'the relay carries the log as pages and per-action joins, and this '
          'member answers a fourth question — whether the log keeps a history '
          'for this entity at all. Add configHistory.entityHistory to '
          'ConfigHistoryApi rather than deriving it here: a derived answer '
          'would have to guess between "nothing happened" and "the log is '
          'silent", and EntityHistory exists precisely because those are not '
          'the same statement.');
}
