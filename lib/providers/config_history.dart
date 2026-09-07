/// The Riverpod layer between `ConfigChangeStore` and the configuration
/// history page.
///
/// `providers/audit_trail.dart` is the shape this mirrors, including the two
/// rulings that matter most:
///
/// | Provider | Lifetime | Answers |
/// |---|---|---|
/// | [configChangeStoreProvider] | `keepAlive` | a store, or **null** when this station has no database |
/// | [configHistoryActionsProvider] | autoDispose family | one query as one [ConfigHistoryResult], or **null** |
/// | [configActionChangesProvider] | autoDispose family | one action's rows, unfiltered — the expander's read |
/// | [ConfigHistoryFilterState] | autoDispose notifier | what the filter bar holds |
///
/// **Refresh is `ref.invalidate`, and this file starts no timer.** That is the
/// audit trail's ruling and it is inherited whole: an always-on
/// `Timer.periodic` in this repo's plumbing has broken unrelated widget tests,
/// and a self-scrolling history is unreadable while you are trying to read a
/// row. If a live update is ever built it must be listener-gated — started in
/// `onListen`, stopped in `onCancel` — and the natural trigger already exists
/// (`kConfigChangeChannel`, the `AFTER INSERT ON config_change` notification
/// the sync already listens to) rather than a poll. The absence is asserted on
/// this file's source text rather than trusted to this paragraph.
///
/// ## What this view can honestly claim
///
/// Everything here reads one database, and `databaseProvider` yields the
/// Postgres handle. Postgres holds `ConfigScope.shared` rows only — a
/// station-scoped change is written to that station's own SQLite and never
/// leaves the machine. So this view shows **shared configuration changes made
/// from any station**, and does not show a station's local-only changes, not
/// even its own. [ConfigHistoryResult.showsStationScopedChanges] is that
/// sentence as a value the page can render, so the limit is stated rather than
/// left for an operator to infer from an empty list.
library;

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../core/audit_trail_grouping.dart';
import '../core/config_change_store.dart';
import 'audit_trail.dart';
import 'database.dart';

part 'config_history.g.dart';

/// Reads of `config_change`, or null when this station has no database.
///
/// Null is a normal state, exactly as it is for [auditTrailStoreProvider] next
/// door: no Postgres configured, and again during the boot window before the
/// connection opens. The two causes are **indistinguishable by design** —
/// `databaseProvider` returns null for both — which is why the page's copy
/// names no cause and says only that the history is unavailable.
///
/// `keepAlive`, for the same reason the audit store is: this holds the handle
/// `databaseProvider` already owns, and the query result is the thing worth
/// releasing.
@Riverpod(keepAlive: true)
Future<ConfigChangeStore?> configChangeStore(Ref ref) async {
  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  // One argument. No session, no sink, no station: this store cannot deny and
  // cannot record. The enforcement is the route gate.
  return ConfigChangeStore(db: db.db);
}

/// One query's worth of history, in the shape the page draws.
///
/// An **empty** [actions] is a real answer — "no changes matched these
/// filters" — and is a different thing from the null
/// [configHistoryActionsProvider] returns when there is no database. The page
/// renders two different terminal states for the two, which is why this type
/// exists rather than the provider answering a bare `List<HistoryAction>?`.
class ConfigHistoryResult {
  const ConfigHistoryResult({
    required this.actions,
    required this.changeRowCount,
    required this.reachedLimit,
    required this.oldestAt,
  });

  /// The grouped actions, newest action first.
  final List<HistoryAction> actions;

  /// How many `config_change` **rows** came back, before grouping.
  ///
  /// The number the `LIMIT` applied to, and not `actions.length`: nine rows of
  /// one page save are one action, and it is the nine that the cap counted.
  final int changeRowCount;

  /// True when this query returned exactly as many rows as it asked for, so
  /// there may be older matching rows it did not return.
  final bool reachedLimit;

  /// The `at` of the oldest row returned, or null when there were none. The
  /// "Load more" cursor.
  final DateTime? oldestAt;

  /// Whether this view can see station-scoped changes. Always false.
  ///
  /// Not a placeholder and not a stub: it is a **fact about the storage
  /// split**, stated as a value so the page has something to render it from.
  /// Station-scoped rows live in each station's own SQLite and are never
  /// pushed to Postgres, so a Postgres-backed history cannot show them — not
  /// another station's, and not this one's. An operator who cannot see a local
  /// preference change in this list needs to be told that, rather than
  /// concluding it never happened.
  bool get showsStationScopedChanges => false;

  /// How many actions in [actions] are missing their `audit_entry` header.
  ///
  /// Non-zero after a crash between the store's COMMIT and the audit write —
  /// the orphan window, which is accepted rather than eliminated because the
  /// opposite ordering loses the changes. The page shows those actions; this
  /// is how it can also say how many there were.
  int get parentlessActionCount =>
      actions.where((action) => action.isParentless).length;
}

/// One [ConfigChangeQuery], one page of history — or null when this station
/// has no database.
///
/// ## Why the change rows are the primary read
///
/// Three statements, in this order:
///
/// 1. `changes(query)` — the filtered, windowed `config_change` rows. This is
///    the subject of the page, and it is the read that surfaces an action
///    whose `audit_entry` header is missing. Starting from the audit side
///    would never ask about such an action.
/// 2. `entriesByAction` — the headers for the action ids those rows named. An
///    id with no header is a parentless action and renders as one.
/// 3. the two unfiltered `COUNT(*)` companions, which are the only way "1 of 9
///    changes hidden" can exist: the excluded rows are not in the result set.
///
/// ## Null, error and empty are three answers
///
/// Null means the history is **unavailable** — no database. An error means the
/// database was there and the read failed, which must not be swallowed here:
/// "nothing changed" is a claim about the plant's configuration and a failed
/// read is not entitled to make it. A [ConfigHistoryResult] with no actions
/// means the query ran and matched nothing.
@riverpod
Future<ConfigHistoryResult?> configHistoryActions(
    Ref ref, ConfigChangeQuery query) async {
  final store = await ref.watch(configChangeStoreProvider.future);
  if (store == null) return null;

  final rows = await store.changes(query);
  final actionIds = rows.map((row) => row.change.actionId).toSet();

  // The audit store reads the same handle, so it is null only when the change
  // store is. An empty header list is the honest degradation if it ever is
  // not: every action renders parentless rather than the page failing.
  final auditStore = await ref.watch(auditTrailStoreProvider.future);
  final auditRows = auditStore == null
      ? const <AuditEntryData>[]
      : await auditStore.entriesByAction(actionIds);

  final changeTotals = await store.changeCountsByAction(actionIds);
  final auditTotals = auditStore == null
      ? const <String, int>{}
      : await auditStore.memberCountsByAction(actionIds);

  return ConfigHistoryResult(
    actions: groupHistoryRows(
      auditRows: auditRows,
      changes: rows,
      auditTotalsByActionId: auditTotals,
      changeTotalsByActionId: changeTotals,
    ),
    changeRowCount: rows.length,
    reachedLimit: rows.length == query.limit,
    // The store orders newest first, so the last row is the oldest one and the
    // cursor the next page starts from.
    oldestAt: rows.isEmpty ? null : rows.last.change.at,
  );
}

/// One action's `config_change` rows, **unfiltered** — what the expander opens.
///
/// The join [configHistoryActionsProvider] cannot do: its rows passed the
/// filters, and an action whose siblings did not is exactly the one an
/// operator expands. Reading by `action_id` here returns all of them, in the
/// order they were written.
///
/// An action with no rows is absent from `changesByAction`'s map, which this
/// renders as an empty list — and an empty list here is **not** the same claim
/// as "nothing happened": a `historyExempt` kind writes no rows at all. Use
/// `ConfigChangeStore.entityHistory` when the question is about one entity;
/// its `isSilent` carries that distinction properly.
@riverpod
Future<List<ConfigChangeRecord>> configActionChanges(
    Ref ref, String actionId) async {
  final store = await ref.watch(configChangeStoreProvider.future);
  if (store == null) return const [];
  final byAction = await store.changesByAction([actionId]);
  return byAction[actionId] ?? const [];
}

/// What the filter bar holds.
///
/// A notifier rather than a plain state provider so the page mutates it by
/// name — `setEntityPrefix`, `clear` — instead of rebuilding the whole value at
/// six call sites. `ConfigHistoryFilters.copyWith` carries the clear flags that
/// make "set this to null" expressible; see its doc for why a bare nullable
/// parameter cannot.
@riverpod
class ConfigHistoryFilterState extends _$ConfigHistoryFilterState {
  @override
  ConfigHistoryFilters build() => const ConfigHistoryFilters();

  void update(ConfigHistoryFilters filters) => state = filters;

  void clear() => state = state.cleared();
}
