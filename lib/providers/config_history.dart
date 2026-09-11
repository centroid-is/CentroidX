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
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart'
    show GuardedConfigStore, auditSummaryOf;
import 'package:tfc_dart/core/config/config_store.dart' show ConfigWriteResult;
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_dart/core/config/config_undo.dart';
import 'package:tfc_dart/core/database_drift.dart';

import '../core/audit_trail_grouping.dart';
import '../core/config_change_store.dart';
import 'access.dart' show auditSinkProvider, stationNameProvider;
import 'access_policy.dart'
    show accessPolicyProvider, reportAccessDenial, sessionInForce;
import 'audit_trail.dart';
import 'config_store.dart' show configStoreProvider;
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
    this.oldestId,
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
  /// "Load more" cursor, with [oldestId].
  final DateTime? oldestAt;

  /// The `id` of the oldest row returned — the cursor's tiebreak among rows
  /// written at one instant. See `ConfigChangeQuery.beforeId`.
  final int? oldestId;

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

  final page = await store.changesPage(query);
  final rows = page.rows;
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
    changeRowCount: page.rawCount,
    // Judged on the raw count, not the decoded list: a row this build cannot
    // read is still a row the cap counted, and hiding Load-more over it
    // would hide every row behind it too.
    reachedLimit: page.rawCount >= query.limit,
    // The store orders newest first, so the last row is the oldest one and the
    // cursor the next page starts from.
    oldestAt: page.oldestAt,
    oldestId: page.oldestId,
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

// ---------------------------------------------------------------------------
// Undo
// ---------------------------------------------------------------------------

/// The `who` of a row written with nobody signed in.
///
/// The literal rather than an import: `GuardedConfigStore`'s own constant is
/// private, and this row has to carry the same word or one operator's actions
/// would read as two people's.
const String _anonymousWho = 'anonymous';

/// A hand-made write. The `origin` every operator-initiated row carries.
const String _operatorOrigin = 'operator';

/// What one attempt to undo an action came to.
///
/// A sealed union rather than an exception the page catches: three of these
/// four are ordinary outcomes an operator is entitled to see, and only the
/// fourth involves anything going wrong. Making the page catch
/// [ConfigConflict] to render a refusal would put the store's exception
/// vocabulary into a widget.
sealed class UndoOutcome {
  const UndoOutcome();
}

/// The undo was written. [actionId] is the new action, already in the log.
class UndoDone extends UndoOutcome {
  const UndoDone({required this.actionId, required this.result});

  /// The undo's own `action_id`, shared with the `audit_entry` row written for
  /// it — the same relationship a save has.
  final String actionId;

  /// What the store wrote.
  final ConfigWriteResult result;
}

/// The undo was refused, entity by entity.
///
/// Reached from both ends of the window: a plan that was never ready, and a
/// race lost between the confirmation and the write. In the second case the
/// blockers come from asking [planUndo] again, so the operator gets the same
/// sentences either way rather than a driver error the second time.
class UndoBlocked extends UndoOutcome {
  const UndoBlocked(this.blockers);

  final List<UndoBlocker> blockers;
}

/// The session may not. Already reported to [accessDenialsProvider] and
/// already recorded in the trail.
class UndoDenied extends UndoOutcome {
  const UndoDenied(this.denial);

  final AccessDenied denial;
}

/// The write could not be attempted: no database, the connection died, or the
/// pool is misconfigured. [message] is the store's own sentence, which is
/// written to be shown to an operator.
class UndoUnavailable extends UndoOutcome {
  const UndoUnavailable(this.message);

  final String message;
}

/// Undo, from the page's point of view: plan it, ask whether this session may,
/// do it, and write the audit parent.
///
/// ## Why a plain [Provider] and not `@riverpod`
///
/// Adding a generated provider means running `build_runner` over `lib/`, which
/// rewrites every `.g.dart` in the app — including ones another plan is editing
/// in this worktree. `access_policy.dart` already mixes hand-written providers
/// beside generated ones for its own reasons; this is the same call made for a
/// different one.
///
/// ## The enforcement is not here
///
/// [mayUndo] exists so the page can refuse before it opens a dialog the
/// operator cannot finish. It is **UX**. The gate that matters is inside
/// `executeUndo`, which takes the session's groups and throws; this class calls
/// it that way and would be refused by it even if [mayUndo] were deleted. A
/// boundary enforced by the only caller remembering to ask stops being a
/// boundary the moment there are two callers.
class ConfigUndoController {
  const ConfigUndoController(this._ref);

  final Ref _ref;

  /// What undoing [actionId] would do, or null when this station has no
  /// database — the same null the rest of this file uses for that.
  Future<UndoPlan?> plan(String actionId) async {
    final db = await _ref.read(databaseProvider.future);
    if (db == null) return null;
    return planUndo(db.db, actionId);
  }

  /// The permission [plan] needs, and the key it is checked under.
  ({AccessGroup group, String itemKey}) gate(UndoPlan plan) =>
      undoGate(_ref.read(accessPolicyProvider), plan);

  /// Whether the session in force may execute [plan]. Advisory — see the class
  /// doc.
  bool mayUndo(UndoPlan plan) => sessionInForce(_ref).can(gate(plan).group);

  /// Refuse [plan] at the tap: prompt the operator, and record the refusal.
  ///
  /// Called instead of [execute], never before it. A refusal that leaves no row
  /// is the repudiation the trail exists to prevent, so the row is written here
  /// exactly as `GuardedConfigStore` writes one on its own deny path — and
  /// nothing is issued to the store, which is what `writeTag`'s tap-time check
  /// established for the plant side.
  Future<AccessDenied> refuse(UndoPlan plan) async {
    final gate = this.gate(plan);
    final denial = AccessDenied(gate.itemKey, gate.group);
    await _recordParent(
      plan: plan,
      gate: gate,
      actionId: newActionId(),
      allowed: false,
      newValue: null,
    );
    reportAccessDenial(_ref, denial);
    return denial;
  }

  /// Write [plan]'s inverse, and the `audit_entry` parent over it.
  ///
  /// The audit row is this layer's job and carries the **same** `actionId` as
  /// the `config_change` rows beneath it, exactly as a save does — the store
  /// has no session to ask and writes no audit row of its own. It is written
  /// after the store returns, which is `GuardedConfigStore`'s ordering and for
  /// its reason: this write can be refused outright, and a row written first
  /// would claim an undo that never happened.
  Future<UndoOutcome> execute(UndoPlan plan) async {
    final policy = _ref.read(accessPolicyProvider);
    final session = sessionInForce(_ref);
    final gate = undoGate(policy, plan);
    final actionId = newActionId();

    final GuardedConfigStore guarded;
    try {
      guarded = await _ref.read(configStoreProvider.future);
    } on Object catch (e) {
      return UndoUnavailable('$e');
    }

    try {
      final result = await executeUndo(
        plan,
        store: guarded.inner,
        policy: policy,
        sessionGroups: session.groups,
        actionId: actionId,
        who: session.user?.username ?? _anonymousWho,
        roleName: session.roleName,
      );
      // **A ready plan that writes nothing is a contradiction, not a
      // success.** The guard skips the audit row on an empty diff because a
      // save of identical bytes is genuinely a no-op; an undo is not. Its plan
      // named entities to change and `executeUndo` asserted the world still
      // matched the verdict, so an empty diff means the two disagree anyway —
      // and reporting it as done would write an `audit_entry` claiming a
      // restore, with zero change rows beneath it. An audit row for a restore
      // that did not happen is worse than the failed undo.
      if (result.diff.isEmpty) {
        return UndoBlocked(await _blockersFor(plan));
      }
      await _recordParent(
        plan: plan,
        gate: gate,
        actionId: actionId,
        allowed: true,
        // The guard's own summariser: key names, never values, capped. An undo
        // is a save and its parent row has to be the same size as one.
        newValue: auditSummaryOf(result.diff),
      );
      return UndoDone(actionId: actionId, result: result);
    } on AccessDenied catch (denial) {
      // Reachable even after [mayUndo] answered true: a session can expire
      // between the confirmation and the write. The gate inside `executeUndo`
      // is what catches it, which is the whole reason it is in there.
      await _recordParent(
        plan: plan,
        gate: gate,
        actionId: actionId,
        allowed: false,
        newValue: null,
      );
      reportAccessDenial(_ref, denial);
      return UndoDenied(denial);
    } on ConfigConflict catch (conflict) {
      // The race the compare-and-swap caught. Nothing was committed, so this
      // is a refusal and not a failure — and it is answered by asking the same
      // question again, which now sees the newer change row and can say who
      // wrote it.
      return UndoBlocked(await _blockersFor(plan, entityId: conflict.key,
          fallback: '$conflict'));
    } on ConfigStoreOfflineException catch (e) {
      return UndoUnavailable('$e');
    } on ConfigStoreUnsafePoolException catch (e) {
      return UndoUnavailable('$e');
    }
  }

  /// Why the write did not happen, in the same words a refused plan uses.
  ///
  /// Asks [planUndo] again: by the time this runs the log holds whatever the
  /// other station wrote, so the re-plan can name who moved what and when —
  /// which the store's exception cannot. Used from both places a permitted
  /// undo can still fail: a lost compare-and-swap, and a ready plan whose
  /// write came out empty.
  ///
  /// Falls back to one synthesised blocker when the re-plan comes back ready —
  /// the row that moved was put back in between, or the disagreement was
  /// between the remote and this station's mirror rather than in the log.
  /// Naming the entity with no author is honest; claiming the undo is fine
  /// when it has just failed would not be.
  Future<List<UndoBlocker>> _blockersFor(
    UndoPlan plan, {
    String? entityId,
    String? fallback,
  }) async {
    final replanned = await this.plan(plan.originalActionId);
    if (replanned != null && replanned.blockers.isNotEmpty) {
      return replanned.blockers;
    }
    final step = plan.steps
        .where((step) => entityId == null || step.entityId == entityId)
        .firstOrNull;
    return <UndoBlocker>[
      UndoBlocker(
        reason: UndoBlockReason.entityMoved,
        kindName: step?.kind.wireName ?? '',
        entityId: entityId ?? step?.entityId ?? '',
        scopeName: step?.scope.wireName ?? '',
        summary: fallback ??
            'This station and the shared database disagree about what this '
            'action left, so nothing was written.',
      ),
    ];
  }

  /// One `audit_entry` over the undo, permitted or refused.
  ///
  /// Never lets the sink's failure become the caller's: on the permitted path
  /// the write has already committed, so an escaping exception would report a
  /// successful undo as failed and have the operator do it twice.
  Future<void> _recordParent({
    required UndoPlan plan,
    required ({AccessGroup group, String itemKey}) gate,
    required String actionId,
    required bool allowed,
    required String? newValue,
  }) async {
    final session = sessionInForce(_ref);
    final row = AuditRecord(
      at: DateTime.now(),
      who: session.user?.username ?? _anonymousWho,
      station: _ref.read(stationNameProvider),
      roleName: session.roleName,
      surface: kConfigUndoSurface,
      itemKey: gate.itemKey,
      oldValue: null,
      newValue: newValue,
      groupRequired: gate.group.name,
      allowed: allowed,
      origin: _operatorOrigin,
      actionId: actionId,
      reason: undoReason(plan.originalActionId),
    );
    try {
      final sink = await _ref.read(auditSinkProvider.future);
      await sink.record(row);
    } on Object catch (_) {
      // The same swallow `GuardedConfigStore._record` performs, for the same
      // reason. The undo either happened or did not; the trail's failure must
      // not change which the operator is told.
    }
  }
}

/// Undo, as one object the page holds.
final configUndoControllerProvider = Provider<ConfigUndoController>(
  ConfigUndoController.new,
);
