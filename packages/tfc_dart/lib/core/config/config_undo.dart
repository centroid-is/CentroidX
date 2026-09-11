/// Undoing one action: read what it did, prove the world has not moved, build
/// the inverse, and write it back through the one guarded write path.
///
/// ## A restore is itself a write
///
/// `ConfigChange`'s own doc states the rule this file implements: the log is
/// append-only, so a rollback "produces its own actionId and its own change
/// rows, so the history shows that a restore happened rather than quietly
/// looking as though the intervening edits never did". Nothing here deletes or
/// rewrites a change row, and nothing marks a row as undone — the undo is an
/// ordinary save whose `reason` says what it is ([undoReason]). That is also
/// what makes undoing an undo work with no extra machinery: the undo's own
/// rows are an action like any other, and [planUndo] inverts them the same
/// way.
///
/// ## The safety check is not "has `rev` changed"
///
/// `config_change` carries no `rev` column — the log records the entity on
/// both sides, not the counter — so "is the row still at the revision this
/// action left it at" is not a question that can be asked of it. It is also
/// the wrong question: a save of identical bytes bumps `rev` and writes no
/// change row at all, so a revision test would refuse an undo that is
/// perfectly safe.
///
/// The two checks that are both askable and better, applied to every entity
/// the action touched:
///
///   1. **Newest change.** The highest `config_change.id` for
///      `(kind, entity_id, scope)` must be this action's own row. A later row
///      means somebody edited the entity afterwards, and undoing to a state
///      two edits back would silently discard theirs. Served by
///      `idx_config_change_entity`. Newest is the highest id and never the
///      latest `at`, for the reason `config_consistency.dart` sets out: several
///      stations write this log and their clocks disagree.
///   2. **Live content.** The stored row's [ConfigItem.encodeEntity] must still
///      match the action's `new_value`, structurally, through [samePayload].
///      This is what catches a database restored from backup, a writer that
///      skipped the log, and an entity re-created after the delete being
///      undone. The comparison is over the whole entity — payload, `parent_id`
///      and `sort_index` — because position is what a restore has to get
///      right.
///
/// Both are all-or-nothing. One blocked entity refuses the whole undo and the
/// refusal lists **every** blocked entity, which is the same rule
/// `ConfigStore.writeItems` applies to a lost compare-and-swap: skipping the
/// blocked one and writing the rest "would commit the rest of the save and
/// leave the editor believing all of it landed".
///
/// ## What cannot be undone here, and why that is a refusal rather than a gap
///
///   * **Anything at `station:<hostname>` scope.** [ConfigStore]'s snapshot is
///     shared rows only, so this write path has nowhere to put a station's own
///     row back. That is what refuses a station preference — the startup page,
///     the theme, `DatabaseConfig` — while a *shared* preference row is
///     undoable like any other, `preference` having joined
///     `kSharedConfigKinds` in 04-05. The two are one kind and two owners, and
///     the scope column is what tells them apart.
///   * **History-exempt entities** (page images, the `server_config_envelope`
///     ciphertext — `config_history_policy.dart`) write **no change rows at
///     all**. An action that touched only exempt items is therefore not in the
///     log, and [planUndo] answers [UndoPlan.isUnknownAction] — which is a
///     different answer from "that action changed nothing", and the difference
///     is the sentence a page owes an operator. An action that touched an
///     image *and* an asset plans the asset alone: the image is not in the
///     replace set, so undoing the asset cannot delete it. A blob left behind
///     that way is unreferenced rather than lost, which is what the image
///     collector already exists to handle.
///
/// ## The gate is asserted here, not at the page
///
/// [executeUndo] takes the caller's session groups and refuses with the
/// ordinary [AccessDenied] when the strictest group the plan needs is not
/// held. 04-10's pre-dialog check is UX — it stops an operator opening a
/// dialog they cannot finish — and is explicitly **not** the enforcement: a
/// boundary that holds only because one page happens to be the only caller
/// stops holding the moment anything programmatic calls it. The group is the
/// one the original write required, resolved through the same
/// [AccessPolicy.groupForWireSurface] entry point `GuardedConfigStore` uses,
/// so the permission needed to undo a change is exactly the permission that
/// was needed to make it.
///
/// ## No `package:flutter`, and no second write path
///
/// Reads take a [GeneratedDatabase] and drift's builders, the arrangement
/// `page_rows.dart` and `config_consistency.dart` already use, so the same
/// statements run against SQLite and Postgres with no dialect branch. The
/// write is [ConfigStore.writeItems] and nothing else: no third copy of the
/// compare-and-swap, the change-row append or the offline refusal.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';
import 'package:tfc_access/tfc_access.dart';

import 'config_change.dart';
import 'config_item.dart';
import 'config_item_table.dart';
import 'config_store.dart';
import 'config_store_errors.dart';

/// The `reason` every row of an undo carries.
///
/// Nothing in the schema marks a row as an undo, and nothing should: `reason`
/// is where an action says what it was for, it is already shown beside every
/// other action in the history, and a boolean column would have to be
/// maintained by every future writer to stay true.
String undoReason(String originalActionId) => 'undo of $originalActionId';

/// Why one entity blocks the undo it is part of.
enum UndoBlockReason {
  /// Somebody changed the entity after the action being undone.
  newerChange,

  /// The stored row is not what the action left — a different payload, a
  /// different parent, a different position, gone, or back again.
  entityMoved,

  /// A kind [ConfigStore.writeItems] cannot replace.
  ///
  /// No kind is, today — `kSharedConfigKinds` names every value of
  /// [ConfigKind], and `config_undo_test.dart` asserts that it does. This is
  /// the fail-closed answer for the next kind added outside the set: undo must
  /// refuse it by name rather than hand it to a write path that could insert
  /// it and never remove it.
  unsupportedKind,

  /// A station-scoped row of a shared kind. The store's snapshot holds shared
  /// rows only, so this write path has nothing to put it back into.
  unsupportedScope,

  /// A kind this build has never heard of — a row written by a newer station.
  unknownKind,

  /// A bookkeeping row, not a preference anybody set.
  ///
  /// Underscore-prefixed shared ids are the store's own account of itself —
  /// today [kPreferencesMigratedMarkerId], which the sync engine reads to tell
  /// an empty shared store from an unmigrated one. They are shared rows and
  /// they are historised, so nothing else here refuses them: an operator
  /// undoing the preferences migration would delete every migrated row **and**
  /// the marker in one save, and the next empty-remote sweep would then read
  /// as "unmigrated" — the exact confusion the marker exists to prevent. After
  /// the old table is dropped the change rows are the only copy of those
  /// values.
  ///
  /// Restoring bookkeeping is not a thing an operator does. It is refused by
  /// name rather than made history-exempt, because the marker's own history is
  /// worth keeping — it is only worth keeping *unrestorable*.
  internalRow,
}

/// One entity that stops an undo, and enough about it to act on.
@immutable
class UndoBlocker {
  const UndoBlocker({
    required this.reason,
    required this.kindName,
    required this.entityId,
    required this.scopeName,
    required this.summary,
    this.who,
    this.at,
  });

  final UndoBlockReason reason;

  /// The raw `kind` column value. Raw rather than a [ConfigKind] because
  /// [UndoBlockReason.unknownKind] is a real finding about a kind that has no
  /// [ConfigKind] in this build, and it must still be reportable.
  final String kindName;

  final String entityId;
  final String scopeName;

  /// One sentence, written to be shown to an operator verbatim.
  final String summary;

  /// Who moved the entity, when that is known: the author of the newer change
  /// row, or the `updated_by` of the row that diverged.
  final String? who;

  /// When they moved it, from the same source as [who].
  final DateTime? at;

  @override
  String toString() => 'UndoBlocker(${reason.name} $kindName:$entityId)';
}

/// What undoing one entity's part of an action comes to.
@immutable
class UndoStep {
  const UndoStep({
    required this.kind,
    required this.entityId,
    required this.scope,
    required this.originalOp,
    this.item,
    this.observedRev,
  });

  final ConfigKind kind;
  final String entityId;
  final ConfigScope scope;

  /// What the action did to this entity, netted across its rows.
  final ConfigChangeOp originalOp;

  /// What the undo writes back — the action's `old_value` as a whole entity,
  /// position included. Null when undoing means removing the entity, which is
  /// the inverse of an insert.
  final ConfigItem? item;

  /// The `rev` the entity held **when the verdict was reached**, or null when
  /// it had no row at all.
  ///
  /// This is what closes the window between [planUndo] and [executeUndo], and
  /// it is not the same guard as the store's compare-and-swap. The CAS swaps
  /// on the revision in *this station's snapshot*, and the snapshot is kept
  /// level by a notification-driven pull that lands in milliseconds — while a
  /// confirmation dialog is open for seconds. So the sequence that matters is:
  /// the verdict says nobody has touched the entity; another station edits it;
  /// this station's sync applies that edit; the CAS now matches the *new*
  /// revision and commits straight over it. The refusal
  /// [UndoBlockReason.newerChange] exists for is defeated precisely because
  /// the store caught up.
  ///
  /// Carrying the observed revision makes the check say what it means: not
  /// "does the snapshot agree with itself" but "is the world still what the
  /// verdict was reached against". It refuses in both directions —
  ///
  ///  * **higher, or a row where the plan saw none:** somebody wrote after the
  ///    verdict (F1);
  ///  * **lower, or no row where the plan saw one:** this station's mirror has
  ///    not caught up with the action being undone, which would otherwise make
  ///    the inverse diff to nothing and report a restore that never happened
  ///    (F2).
  ///
  /// Null is a real value here and not "unknown": [planUndo] reads the live
  /// row for every touched entity, so an absent row is an observation.
  final int? observedRev;

  /// True when this step removes the entity rather than writing it.
  bool get isRemoval => item == null;

  /// What the undo does, in the log's own vocabulary.
  ConfigChangeOp get inverseOp => switch (originalOp) {
        ConfigChangeOp.insert => ConfigChangeOp.delete,
        ConfigChangeOp.delete => ConfigChangeOp.insert,
        ConfigChangeOp.update => ConfigChangeOp.update,
      };

  @override
  String toString() =>
      'UndoStep(${inverseOp.wireName} ${kind.wireName}:$entityId@$scope)';
}

/// The verdict on undoing one action: what it would write, or why it may not.
@immutable
class UndoPlan {
  const UndoPlan({
    required this.originalActionId,
    required this.kinds,
    required this.steps,
    required this.blockers,
  });

  /// The answer for an `action_id` the change log has never heard of.
  ///
  /// Not a throw: an operator can reach a stale action id from a history page
  /// that loaded a minute ago, and — more to the point — an action that
  /// touched only history-exempt entities wrote no change rows and is
  /// legitimately absent. Both are "there is nothing here to invert", which is
  /// a verdict rather than an error.
  const UndoPlan.unknown(String actionId)
      : originalActionId = actionId,
        kinds = const {},
        steps = const [],
        blockers = const [];

  /// The action being undone.
  final String originalActionId;

  /// The kinds the undo write replaces — exactly the kinds the action touched.
  ///
  /// This is what bounds the damage: [ConfigStore.writeItems] replaces within
  /// these kinds, so an undo of a page save may not remove a key mapping, and
  /// the wanted set handed to it must be the **complete** stored set of these
  /// kinds with the inverse applied.
  final Set<ConfigKind> kinds;

  /// The inverse, in the order it reads: things put back first, parent before
  /// child; things taken away last, child before parent.
  final List<UndoStep> steps;

  /// Every entity that blocks the undo. Empty on a ready plan.
  final List<UndoBlocker> blockers;

  /// Whether the change log holds no rows for this action at all.
  bool get isUnknownAction => steps.isEmpty && blockers.isEmpty;

  /// Whether this plan may be executed.
  bool get isReady => blockers.isEmpty && steps.isNotEmpty;

  @override
  String toString() => 'UndoPlan($originalActionId, ${steps.length} steps, '
      '${blockers.length} blockers)';
}

/// The prefix that marks a shared row as the store's own bookkeeping.
///
/// A deliberate copy of `shared_row_preferences.dart`'s `_internalIdPrefix`,
/// which is private to that library. `config_undo_test.dart` pins it against
/// [kPreferencesMigratedMarkerId], the one row that qualifies today, so the
/// two cannot drift apart without a test failing.
const String kUndoInternalIdPrefix = '_';

/// The `pref` surface every configuration write is checked on — the same
/// string `GuardedConfigStore` passes to the policy and writes into the audit
/// row, so the group that is checked and the surface that is recorded cannot
/// disagree.
const String kConfigUndoSurface = 'pref';

/// The check key each kind's writes are gated on.
///
/// **A deliberate second copy of `GuardedConfigStore.kConfigWriteKeys`**,
/// spelled as literals. That map's own entry for `key_mapping` reaches
/// `key_mapping_codec.dart`, which imports `state_man.dart`, which imports
/// `package:open62541` — so importing it here would pull `dart:ffi` into the
/// config layer through exactly the chain D-3 arrived by, and
/// `page_rows_test.dart`'s graph walk exists to catch. The copy is pinned
/// against the original by a test, so the two cannot drift apart quietly.
///
/// A kind with no entry is not defaulted here: it falls through to
/// [AccessPolicy.groupForWireSurface] as an unmatched preference key, which
/// answers `administer`. Failing closed is the point — a kind nobody has
/// classified must not be undoable by whoever happens to hold `configure`.
const Map<ConfigKind, String> kUndoCheckKeys = <ConfigKind, String>{
  ConfigKind.keyMapping: 'key_mappings',
  ConfigKind.page: 'page_editor_data',
  ConfigKind.asset: 'page_editor_data',
};

/// The permission one entity's undo needs, and the key it is checked under.
///
/// The group the **original write** required, resolved through the same entry
/// point the guard uses. Undoing a change therefore needs exactly what making
/// it needed: no more, which would leave an operator able to break something
/// they cannot repair, and no less, which would make undo a way around the
/// gate.
({AccessGroup group, String itemKey}) undoGateFor(
  AccessPolicy policy,
  ConfigKind kind,
  String entityId,
) {
  // A preference is keyed by the preference itself — `startup_url` and
  // `database_config` are not one permission — which is why this arm asks
  // about the entity and the others ask about the kind.
  final itemKey =
      kind == ConfigKind.preference ? entityId : kUndoCheckKeys[kind] ?? '';
  return (
    group: policy.groupForWireSurface(kConfigUndoSurface, itemKey),
    itemKey: itemKey,
  );
}

/// The strictest permission [plan] needs, and the entity that needs it.
///
/// Strictest is the highest [AccessGroup] index, the ranking
/// `guarded_state_man.dart` and `strictestGroupName` both use. One plan is one
/// action and gets one check, so a plan spanning two permissions is gated on
/// the harder of them.
///
/// A plan with no steps needs `administer`: there is nothing to authorise, and
/// answering with the most permissive group would make the empty case the way
/// through.
({AccessGroup group, String itemKey}) undoGate(
    AccessPolicy policy, UndoPlan plan) {
  ({AccessGroup group, String itemKey})? strictest;
  for (final step in plan.steps) {
    final gate = undoGateFor(policy, step.kind, step.entityId);
    if (strictest == null || gate.group.index > strictest.group.index) {
      strictest = gate;
    }
  }
  return strictest ?? (group: AccessGroup.administer, itemKey: '');
}

/// What undoing [actionId] would do, or why it may not be done.
///
/// [db] is the database holding the action — the remote for a shared action.
/// Reads only: nothing here writes, so a plan may be built and shown without
/// committing to anything.
///
/// See the library doc for the two safety checks and for what this path
/// refuses outright.
Future<UndoPlan> planUndo(GeneratedDatabase db, String actionId) async {
  final changes = $ConfigChangeTableTable(db);

  // Ordered by id — the order the rows were written, which is the order the
  // action happened in and the order its inverse is derived from.
  final rows = await (db.select(changes)
        ..where((t) => t.actionId.equals(actionId))
        ..orderBy([(t) => OrderingTerm(expression: t.id)]))
      .get();
  if (rows.isEmpty) return UndoPlan.unknown(actionId);

  // One action may hold several rows for one entity only if a caller reused
  // an action id across saves; within one `writeItems` an entity appears once.
  // Netting them is still the right reading: the inverse of "created then
  // edited" is a removal, not an edit back to a state that never shipped.
  final byEntity = <_EntityKey, List<ConfigChangeRow>>{};
  for (final row in rows) {
    byEntity
        .putIfAbsent(_EntityKey(row.kind, row.entityId, row.scope), () => [])
        .add(row);
  }

  final newest = await _newestChangePerEntity(db, changes, byEntity.keys);
  final live = await _liveRows(db, byEntity.keys);

  final steps = <UndoStep>[];
  final blockers = <UndoBlocker>[];

  for (final entry in byEntity.entries) {
    final key = entry.key;
    final first = entry.value.first;
    final last = entry.value.last;

    final kind = ConfigKind.byWireName(key.kind);
    if (kind == null) {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.unknownKind,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        summary: '"${key.id}" is a ${key.kind}, which this station does not '
            'know how to write — undo it from a station running the build '
            'that made the change.',
      ));
      continue;
    }
    if (!kSharedConfigKinds.contains(kind)) {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.unsupportedKind,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        summary: 'A ${key.kind} is not written through the shared '
            'configuration path, so "${key.id}" cannot be restored from here.',
      ));
      continue;
    }
    if (kind == ConfigKind.preference &&
        key.id.startsWith(kUndoInternalIdPrefix)) {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.internalRow,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        summary: '"${key.id}" is bookkeeping the configuration store keeps '
            'about itself, not a setting anybody chose. Restoring it would '
            'change what this plant believes about its own migration.',
      ));
      continue;
    }
    final scope = ConfigScope.byWireName(key.scope);
    if (scope == null || !scope.isShared) {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.unsupportedScope,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        summary: '"${key.id}" was changed at ${key.scope} scope. Only the '
            'station that owns that row can write it, so it has to be put '
            'back there.',
      ));
      continue;
    }

    // Check 1: nobody has touched the entity since.
    final newestRow = newest[key];
    if (newestRow != null && newestRow.id != last.id) {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.newerChange,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        who: newestRow.who,
        at: newestRow.at,
        summary: '"${key.id}" was changed again by ${newestRow.who} on '
            '${newestRow.station} at ${newestRow.at.toLocal()}. Undoing this '
            'action would discard that.',
      ));
      continue;
    }

    // Check 2: the entity is still what this action left.
    final stored = live[key];
    final recorded = last.newValue;
    final blocked = _contentBlocker(key, stored, recorded);
    if (blocked != null) {
      blockers.add(blocked);
      continue;
    }

    // The side the undo would write. Decoded here, guarded, for the same
    // reason `_contentBlocker` guards the stored side: a change row is data
    // written by another build, and a row this one cannot read must come
    // back as a refusal an operator can see rather than a `FormatException`
    // out of a button handler with nothing on screen.
    final ConfigItem? item;
    try {
      item = first.oldValue == null
          ? null
          : ConfigItem.fromEntityJson(
              _decodeEntity(first.oldValue!),
              kind: kind,
              id: key.id,
              scope: scope,
            );
    } on Object {
      blockers.add(UndoBlocker(
        reason: UndoBlockReason.entityMoved,
        kindName: key.kind,
        entityId: key.id,
        scopeName: key.scope,
        summary: '"${key.id}" has a history row this station cannot read, '
            'so what it held before this action cannot be put back.',
      ));
      continue;
    }

    steps.add(UndoStep(
      kind: kind,
      entityId: key.id,
      scope: scope,
      originalOp: _netOp(first.oldValue, recorded),
      // What the world looked like at the moment the verdict was reached.
      // `stored` is the live row this check just compared against, so this is
      // an observation and not a guess. See [UndoStep.observedRev].
      observedRev: stored?.rev,
      item: item,
    ));
  }

  blockers.sort(_blockersInReadingOrder);
  steps.sort(_stepsInWriteOrder);

  return UndoPlan(
    originalActionId: actionId,
    kinds: {for (final step in steps) step.kind},
    steps: steps,
    blockers: blockers,
  );
}

/// Writes [plan]'s inverse as a new action, and answers what it wrote.
///
/// ## The gate, asserted here
///
/// [sessionGroups] is the caller's session — `AccessSession.groups` — and it
/// is a required parameter because there is no defensible default for it. The
/// strictest group [plan] needs is computed by [undoGate] and checked before
/// anything is read or written; a caller that does not hold it gets the
/// ordinary [AccessDenied] and the databases are untouched. 04-10's check
/// before it opens its dialog is UX and does not replace this one.
///
/// This function performs **no access check on the store's behalf beyond that
/// one, and writes no `audit_entry` row**, exactly as [ConfigStore.writeItems]
/// does not: the audit parent carrying this same [actionId] is the app layer's
/// to write, as it already is for a save. The two must share an id or the
/// undo reads in the history as an action with no author.
///
/// ## Why the whole stored set is handed over
///
/// [ConfigStore.writeItems] replaces within kinds. [wanted] here is
/// `store.itemsOf(plan.kinds)` — every stored item of those kinds — with the
/// inverse applied to the entities the action touched. Handing over the
/// touched entities alone would delete every one of their siblings, which for
/// an undo of a one-asset edit is the whole plant's page layout. The tests
/// pin it for assets and for shared preferences, the two kinds where a partial
/// set is the tempting mistake.
///
/// ## What re-checks the verdict
///
/// **The compare-and-swap is not enough, and believing it was is the defect
/// this paragraph replaces.** The CAS swaps on the revision in this station's
/// *snapshot*; a notification-driven pull keeps that snapshot level within
/// milliseconds, while the dialog above it is open for seconds. So an edit
/// that arrives and is applied between the verdict and the write leaves the
/// CAS matching — and the undo commits over it, which is exactly what
/// [UndoBlockReason.newerChange] refuses when the same edit arrives a moment
/// later. The mirror lagging is the same bug in the quiet direction: the
/// inverse diffs to nothing, writes nothing, and reports a restore.
///
/// So the verdict is re-asserted here against what [planUndo] actually
/// observed — [UndoStep.observedRev] per entity, presence included — before
/// anything is built, and any disagreement is a [ConfigConflict]. The store's
/// own guards stay underneath as the last line: the CAS for an update or a
/// delete, and 04-01's insert guard for a re-creation.
///
/// The assert and the write run **on the sync engine's serialisation chain**
/// ([ConfigStore.serialiseWrite]), so an apply cannot land between them. The
/// chain is idle between notifications, so this costs nothing in the ordinary
/// case and closes the last machine-scale gap in the unusual one.
///
/// Throws [ArgumentError] for a plan that is not ready — a refusal the caller
/// was given in full and chose to ignore is a programming error, not an
/// operator's problem — and everything [ConfigStore.writeItems] throws,
/// unwrapped.
///
/// `async` so that both refusals reach the caller the same way the store's do
/// — as a failed future. A gate that threw synchronously would escape a
/// `catch` written around an `await` and land as an unhandled error in a
/// button handler.
Future<ConfigWriteResult> executeUndo(
  UndoPlan plan, {
  required ConfigStore store,
  required AccessPolicy policy,
  required Set<AccessGroup> sessionGroups,
  required String actionId,
  required String who,
  required String roleName,
}) async {
  if (!plan.isReady) {
    throw ArgumentError.value(
        plan,
        'plan',
        plan.isUnknownAction
            ? 'is for an action the change log does not hold, so there is '
                'nothing to invert'
            : 'was refused: ${plan.blockers.map((b) => b.summary).join(' ')}');
  }

  final gate = undoGate(policy, plan);
  if (!sessionGroups.contains(gate.group)) {
    throw AccessDenied(gate.itemKey, gate.group);
  }

  return store.serialiseWrite(() {
    final stored = <String, ConfigItem>{
      for (final item in store.itemsOf(plan.kinds))
        configSnapshotKey(item.kind, item.id): item,
    };

    // The verdict, re-asserted against what it was reached against. Before
    // anything is built, so a refusal costs nothing and writes nothing.
    for (final step in plan.steps) {
      final key = configSnapshotKey(step.kind, step.entityId);
      final now = stored[key];
      if (now?.rev == step.observedRev) continue;
      throw step.observedRev == null
          // The plan saw no row and there is one: somebody created it after
          // the verdict, which is the case `ConfigConflict.created` words.
          ? ConfigConflict.created(step.entityId)
          : ConfigConflict(step.entityId, expectedRev: step.observedRev!);
    }

    final wanted = Map<String, ConfigItem>.of(stored);
    for (final step in plan.steps) {
      final key = configSnapshotKey(step.kind, step.entityId);
      if (step.item case final item?) {
        wanted[key] = item;
      } else {
        wanted.remove(key);
      }
    }

    return store.writeItems(
      kinds: plan.kinds,
      wanted: wanted.values.toList(),
      actionId: actionId,
      who: who,
      roleName: roleName,
      reason: undoReason(plan.originalActionId),
    );
  });
}

/// The net effect of an action on one entity, from the first row's old side
/// and the last row's new side.
ConfigChangeOp _netOp(String? oldValue, String? newValue) {
  if (oldValue == null) return ConfigChangeOp.insert;
  if (newValue == null) return ConfigChangeOp.delete;
  return ConfigChangeOp.update;
}

/// Whether the stored row still matches what the action left, and the blocker
/// when it does not.
///
/// Four states, and each says something different to an operator: the row is
/// gone, the row is back, the row disagrees, or the row is unreadable.
UndoBlocker? _contentBlocker(
    _EntityKey key, ConfigItemRow? stored, String? recorded) {
  if (recorded == null) {
    // The action deleted the entity. Undoing that is an insert, so the row has
    // to still be absent — `ConfigStore`'s insert arm would otherwise refuse
    // with `ConfigConflict.created`, and refusing here says why instead.
    if (stored == null) return null;
    return UndoBlocker(
      reason: UndoBlockReason.entityMoved,
      kindName: key.kind,
      entityId: key.id,
      scopeName: key.scope,
      who: stored.updatedBy,
      at: stored.updatedAt,
      summary: '"${key.id}" was deleted by this action and exists again, '
          'written by ${stored.updatedBy}. Restoring it now would overwrite '
          'that.',
    );
  }
  if (stored == null) {
    return UndoBlocker(
      reason: UndoBlockReason.entityMoved,
      kindName: key.kind,
      entityId: key.id,
      scopeName: key.scope,
      summary: '"${key.id}" is no longer a row, and the change log does not '
          'say who removed it. Nothing can be safely put back on top of that.',
    );
  }
  final entity = _entityOf(stored);
  if (entity == null) {
    return UndoBlocker(
      reason: UndoBlockReason.entityMoved,
      kindName: key.kind,
      entityId: key.id,
      scopeName: key.scope,
      who: stored.updatedBy,
      at: stored.updatedAt,
      summary: '"${key.id}" holds a payload that is not readable JSON, so it '
          'cannot be compared against what this action wrote.',
    );
  }
  if (samePayload(recorded, entity)) return null;
  return UndoBlocker(
    reason: UndoBlockReason.entityMoved,
    kindName: key.kind,
    entityId: key.id,
    scopeName: key.scope,
    who: stored.updatedBy,
    at: stored.updatedAt,
    summary: '"${key.id}" is not what this action left — its payload, its '
        'parent or its position has been changed since, by ${stored.updatedBy}'
        ', without a change row. Undoing would discard that.',
  );
}

/// Re-insertions first and parent before child, then the edits, then the
/// removals with child before parent.
///
/// The order is the plan's, not the transaction's: the write is one
/// [ConfigStore.writeItems] call in one transaction, `parent_id` is
/// deliberately not a foreign key, and no reader can observe a row order
/// inside a committed transaction. What it is for is the two places the order
/// is real — the plan a person reads before approving it, and any future
/// writer that applies these steps one at a time. The invariant underneath it
/// is checked rather than assumed: `checkConfigConsistency` reports an
/// orphaned `parent_id`, and the undo tests run it after the write.
int _stepsInWriteOrder(UndoStep a, UndoStep b) {
  int phase(UndoStep s) => switch (s.inverseOp) {
        ConfigChangeOp.insert => 0,
        ConfigChangeOp.update => 1,
        ConfigChangeOp.delete => 2,
      };
  final byPhase = phase(a).compareTo(phase(b));
  if (byPhase != 0) return byPhase;
  // Kind order is parent-to-child: `page` is declared before `asset`. A
  // removal walks it backwards so a page outlives the assets on it.
  final byKind = phase(a) == 2
      ? b.kind.index.compareTo(a.kind.index)
      : a.kind.index.compareTo(b.kind.index);
  return byKind != 0 ? byKind : a.entityId.compareTo(b.entityId);
}

int _blockersInReadingOrder(UndoBlocker a, UndoBlocker b) {
  final byKind = a.kindName.compareTo(b.kindName);
  if (byKind != 0) return byKind;
  return a.entityId.compareTo(b.entityId);
}

/// The newest change row for each of [keys] that has one.
///
/// Narrowed by kind and entity id so the index serves it — the log is the
/// largest table in the schema on a plant database and this runs while an
/// operator waits. The scope is not in the inner filter: it is part of the
/// grouping, so a station-scoped namesake produces its own row rather than
/// being conflated with the shared one.
Future<Map<_EntityKey, _NewestChange>> _newestChangePerEntity(
  GeneratedDatabase db,
  $ConfigChangeTableTable changes,
  Iterable<_EntityKey> keys,
) async {
  final kindNames = {for (final key in keys) key.kind}.toList();
  final entityIds = {for (final key in keys) key.id}.toList();

  final newestIds = db.selectOnly(changes)
    ..addColumns([changes.id.max()])
    ..where(changes.kind.isIn(kindNames) & changes.entityId.isIn(entityIds))
    ..groupBy([changes.kind, changes.entityId, changes.scope]);

  final rows = await (db.selectOnly(changes)
        ..addColumns([
          changes.id,
          changes.kind,
          changes.entityId,
          changes.scope,
          changes.who,
          changes.station,
          changes.at,
        ])
        ..where(changes.id.isInQuery(newestIds)))
      .get();

  return {
    for (final row in rows)
      _EntityKey(
        row.read(changes.kind)!,
        row.read(changes.entityId)!,
        row.read(changes.scope)!,
      ): _NewestChange(
        id: row.read(changes.id)!,
        who: row.read(changes.who)!,
        station: row.read(changes.station)!,
        at: row.read(changes.at)!,
      ),
  };
}

/// The stored rows for [keys], keyed the same way. Absent means no row.
Future<Map<_EntityKey, ConfigItemRow>> _liveRows(
  GeneratedDatabase db,
  Iterable<_EntityKey> keys,
) async {
  final items = $ConfigItemTableTable(db);
  final kindNames = {for (final key in keys) key.kind}.toList();
  final entityIds = {for (final key in keys) key.id}.toList();

  final rows = await (db.select(items)
        ..where((t) => t.kind.isIn(kindNames) & t.id.isIn(entityIds)))
      .get();

  return {
    for (final row in rows) _EntityKey(row.kind, row.id, row.scope): row,
  };
}

/// [row] as the entity string a change row holds, or null when its payload is
/// not JSON and therefore cannot be one.
String? _entityOf(ConfigItemRow row) {
  final kind = ConfigKind.byWireName(row.kind);
  if (kind == null) return null;
  try {
    return ConfigItem(
      kind: kind,
      id: row.id,
      scope: ConfigScope.byWireName(row.scope) ?? ConfigScope.shared,
      parentId: row.parentId,
      sortIndex: row.sortIndex,
      payload: row.payload,
    ).encodeEntity();
  } on FormatException {
    return null;
  }
}

/// The `{parent_id, sort_index, payload}` map a change row's side holds.
///
/// [ConfigItem.fromEntityJson] canonicalises the payload on the way back in,
/// so what comes out of here is written exactly as the store would write it.
Map<String, dynamic> _decodeEntity(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

/// `_EntityKey` — `config_item`'s primary key as stored, raw strings so a kind
/// this build does not know is still expressible.
@immutable
class _EntityKey {
  const _EntityKey(this.kind, this.id, this.scope);

  final String kind;
  final String id;
  final String scope;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _EntityKey &&
          other.kind == kind &&
          other.id == id &&
          other.scope == scope;

  @override
  int get hashCode => Object.hash(kind, id, scope);

  @override
  String toString() => '$kind:$id@$scope';
}

/// The newest change row for an entity: which row it is, and who wrote it.
@immutable
class _NewestChange {
  const _NewestChange({
    required this.id,
    required this.who,
    required this.station,
    required this.at,
  });

  final int id;
  final String who;
  final String station;
  final DateTime at;
}
