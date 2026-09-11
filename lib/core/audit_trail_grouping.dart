/// The shape the audit trail page renders: one entry per `actionId`, not one
/// per row.
///
/// `guarded_state_man.dart` writes one row per changed member and shares one
/// `actionId` across them (`auditRecordsForChanges`), so a recipe apply is one
/// human action with N rows underneath it. Rendering those as N unrelated lines
/// is the thing Phase 5 exists to stop.
///
/// Everything here is a pure top-level function over value types, the way
/// `alarmHistoryEntries` (`lib/widgets/alarm.dart`) and
/// `dynamic_value_diff.dart` are built. No widget, no provider, no database:
/// nothing here imports Flutter, a grep asserts it, and nothing here may start
/// to — the moment this file needs a `BuildContext` it has stopped being the
/// transform the page is tested through.
library;

import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'config_change_store.dart';

/// The audit surfaces this build knows how to talk about.
///
/// ## What this is for
///
/// It is the one place the surface vocabulary is written down, and it is a
/// **change-detector**. Exactly one assertion in
/// `test/core/audit_trail_grouping_test.dart` pins it. Add a surface and that
/// one test fails, in one file, with a message saying what to do about it.
///
/// ## What this is not for
///
/// It is **not** a whitelist. Nothing filters, drops, gates or branches on
/// membership in this set, and nothing may start to. A row whose `surface` is
/// not listed here flows through [groupAuditRows] untouched and is rendered by
/// the row widget's default branch, because it came from a station running a
/// newer build against the same database and the operator needs to see what
/// that station did. Dropping it would make the page lie by omission, which is
/// the one failure mode an audit trail cannot have.
///
/// ## Why it exists at all
///
/// It worked. Phase 6 added the fifth surface, `admin`, for role and user
/// administration — `itemKey`s `role.create` / `role.update` / `role.delete` /
/// `role.rename` and `user.create` / `user.delete` / `user.role` /
/// `user.password`, all carrying `groupRequired: 'users'` — and the whole cost
/// of that arriving was this one line and the one assertion that pins it. The
/// page-visibility whitelist later added `role.pages` and `user.pages` to the
/// same surface and cost nothing at all here, which is the property this set
/// exists to have.
/// `test/widgets/audit_trail_admin_surface_test.dart` proved beforehand, end to
/// end through the real store and the real reader, that the viewer renders an
/// `admin` row with no change of any kind: no new chip either, because the
/// existing `users` chip already covers rows carrying `groupRequired: 'users'`.
/// Nothing branched on membership then and nothing branches on it now.
///
/// Phase 4 then added the sixth, `config` — the surface a page save, an asset
/// edit or a key-mapping import writes its `audit_entry` header on, with the
/// `config_change` rows of the same `action_id` beneath it. The cost was again
/// this one line and the one assertion that pins it. Nothing branches on
/// membership: a `config` action is found by its `action_id`, never by its
/// surface string.
const Set<String> kKnownAuditSurfaces = {
  'tag',
  'pref',
  'route',
  'auth',
  'admin',
  'config',
};

/// One human action and the rows of it this query could see.
///
/// Built only by [groupAuditRows], which never produces an empty [rows], so
/// [lead] is always safe.
class AuditAction {
  const AuditAction({
    required this.actionId,
    required this.rows,
    required this.totalRowCount,
  });

  /// The correlation id every row in [rows] shares.
  final String actionId;

  /// The rows of this action that survived the filters, in the order the store
  /// returned them — newest-first, and never re-sorted here.
  final List<AuditEntryData> rows;

  /// How many rows this action has in the table, filters aside.
  ///
  /// Supplied by `AuditTrailStore.memberCountsByAction`, a companion
  /// `COUNT(*) GROUP BY action_id` issued outside the filter predicate
  /// precisely so this number can exist. All filtering happens in SQL, so an
  /// action's non-matching siblings are not in the result set and cannot be
  /// counted from [rows].
  ///
  /// When the store did not supply a total this falls back to `rows.length` —
  /// "we did not ask", not "there are no others". A caller that skips the
  /// companion query therefore degrades to a flat, honest list rather than to a
  /// list claiming every action is complete.
  final int totalRowCount;

  /// The row the collapsed line is drawn from.
  AuditEntryData get lead => rows.first;

  /// How many of this action's rows the filters excluded.
  ///
  /// Clamped at zero: a stale or wrong total must never produce
  /// "-2 members hidden" on a parent row.
  int get hiddenCount {
    final hidden = totalRowCount - rows.length;
    return hidden > 0 ? hidden : 0;
  }

  /// True when this view of the action is incomplete, and the parent row must
  /// say so rather than presenting a subset as the whole record.
  bool get isPartial => hiddenCount > 0;

  /// True when the action gets an expander.
  ///
  /// More than one visible row **or** any hidden sibling. A single visible row
  /// with eight hidden ones still expands, because otherwise the
  /// "8 of 9 members hidden by filters" line has nowhere to live.
  bool get isMulti => rows.length > 1 || hiddenCount > 0;

  /// The one permission the parent row names: the strictest across the
  /// children.
  ///
  /// `auditRecordsForChanges` shares one `groupRequired` across the rows of one
  /// call, so usually every child already agrees and this is a no-op. But
  /// `dynamic_value_diff.dart` says in as many words that one human action may
  /// span more than one call — a recipe apply that writes two keys is one
  /// action — and then the strings genuinely differ. Computing the maximum
  /// costs three lines and removes the case where the parent under-reports what
  /// the operator was allowed to do. See [strictestGroupName].
  String get requiredGroupLabel =>
      strictestGroupName(rows.map((row) => row.groupRequired));
}

/// A flat newest-first row list as one entry per `actionId`, in the order the
/// actions first appear.
///
/// ## Why this is map-based and not adjacency-based
///
/// `action_id` has no index, so grouping is client-side. Several SVN stations
/// share one database and rows come back ordered by `at`, so another station's
/// write landing between two members of a local struct write is routine rather
/// than exotic. Adjacency grouping would split that action in two, and neither
/// half would say so — it would render as two complete actions that each
/// under-report what happened.
///
/// ## Ordering
///
/// A plain `Map` is used and its iteration order is relied on: Dart's default
/// `Map` is a `LinkedHashMap` and iterates in key-insertion order. That is not
/// incidental — first-appearance order is the whole output contract. The input
/// is newest-first, so the output is newest-action-first, and no sort happens
/// here: the ordering rule lives in the store's `ORDER BY at DESC` and a second
/// copy of it would be a second thing to keep in step.
///
/// ## What this does not do
///
/// It does not filter. It receives what SQL returned and adds nothing back —
/// the reason [totalsByActionId] is passed in at all is that the excluded rows
/// are not available to be re-included.
List<AuditAction> groupAuditRows(
  List<AuditEntryData> rows, {
  Map<String, int> totalsByActionId = const {},
}) {
  final byAction = _groupByKey<AuditEntryData>(rows, (row) => row.actionId);

  return [
    for (final entry in byAction.entries)
      AuditAction(
        actionId: entry.key,
        rows: List.unmodifiable(entry.value),
        // An absent total means the companion query was not run, so the visible
        // rows are all this can claim. Never zero: zero would be a statement
        // about the action rather than the absence of one.
        totalRowCount: totalsByActionId[entry.key] ?? entry.value.length,
      ),
  ];
}

/// One child of an action: either an `audit_entry` member row or a
/// `config_change` row.
///
/// ## Why a union and not a widened [AuditEntryData]
///
/// The obvious cheap move is to synthesise an [AuditEntryData] for each change
/// row and reuse everything below unchanged. It does not survive contact with
/// the data: `audit_entry` has no `kind` and no `entity_id`, so the flattening
/// would throw away precisely the identity 04-07's undo has to name — *which*
/// asset, in *which* scope — and would replace it with an `item_key` string
/// nothing can parse back. The two child types answer different questions and
/// stay two types.
///
/// Sealed, so a renderer's `switch` is exhaustive and a third child type
/// arriving is a compile error at every site rather than a silently skipped
/// branch.
sealed class ActionChild {
  const ActionChild();

  /// The correlation id this child shares with its siblings.
  String get actionId;

  /// When it happened. The merge key, and the only field both child types are
  /// asked for by name.
  DateTime get at;

  /// Who did it. Present on both tables, which is what lets an action with no
  /// header still be attributable.
  String get who;
}

/// One `audit_entry` row, as a child of its action.
final class AuditMemberChild extends ActionChild {
  const AuditMemberChild(this.row);

  final AuditEntryData row;

  @override
  String get actionId => row.actionId;

  @override
  DateTime get at => row.at;

  @override
  String get who => row.who;
}

/// One `config_change` row, as a child of its action.
///
/// [ConfigChangeRecord] is a value type — an id and a decoded [ConfigChange] —
/// and importing it here does not give this file a database. Everything below
/// is still a pure function over values.
final class ConfigChangeChild extends ActionChild {
  const ConfigChangeChild(this.record);

  final ConfigChangeRecord record;

  @override
  String get actionId => record.change.actionId;

  @override
  DateTime get at => record.change.at;

  @override
  String get who => record.change.who;
}

/// One human action, its `audit_entry` members and its `config_change` rows.
///
/// [AuditAction]'s counterpart for the config history, and deliberately a
/// second type rather than a widened first one: [AuditAction.lead] is
/// non-nullable and three widgets rely on it, while an action here may have no
/// header at all (see [isParentless]).
class HistoryAction {
  const HistoryAction({
    required this.actionId,
    required this.children,
    required this.totalAuditRowCount,
    required this.totalChangeCount,
  });

  /// The correlation id every child shares.
  final String actionId;

  /// Every child of this action that survived the filters, newest first.
  ///
  /// Merged from two newest-first streams on `at`, ties to the audit side.
  /// Neither stream is re-sorted: each arrives in the order its store's
  /// `ORDER BY` produced, and a second copy of that ordering rule here would
  /// be a second thing to keep in step.
  final List<ActionChild> children;

  /// How many `audit_entry` rows this action has in the table, filters aside.
  final int totalAuditRowCount;

  /// How many `config_change` rows it has, filters aside.
  ///
  /// **Zero is a real and ordinary value.** `historyExempt` kinds — a page
  /// image, the `server_config_envelope` ciphertext — write no change rows at
  /// all, so an action that saved one is complete with none. That is why
  /// [hiddenCount] treats an absent total as "not asked" rather than deriving
  /// it: "no history" and "nothing happened" are different statements and this
  /// type must not collapse them.
  final int totalChangeCount;

  /// The `audit_entry` rows among [children], in order.
  List<AuditEntryData> get auditRows =>
      [for (final child in children) if (child is AuditMemberChild) child.row];

  /// The `config_change` rows among [children], in order.
  List<ConfigChangeRecord> get changes => [
        for (final child in children)
          if (child is ConfigChangeChild) child.record
      ];

  /// The row a collapsed line is drawn from, or **null** when this action has
  /// no `audit_entry` row at all.
  ///
  /// See [isParentless]. Nullable where [AuditAction.lead] is not, because
  /// synthesising a header would put a fabricated author and a fabricated
  /// permission on the page.
  AuditEntryData? get lead {
    for (final child in children) {
      if (child is AuditMemberChild) return child.row;
    }
    return null;
  }

  /// True when the action's `audit_entry` row is missing.
  ///
  /// ## The orphan window, which is real and accepted
  ///
  /// The store commits its `config_change` rows and writes the `audit_entry`
  /// row afterwards. A crash between the two leaves change rows on an
  /// `action_id` with no header. The ordering is deliberate: the reverse loses
  /// the changes and keeps a header describing them, which is worse.
  ///
  /// It is also what a station-scoped action looks like to a Postgres-backed
  /// reader whose header lives in another store (C-13).
  ///
  /// Either way the rows exist and say what changed, who changed it and when.
  /// Dropping the action would hide a real write; crashing on it would hide
  /// every other write with it. It renders, flagged.
  bool get isParentless => lead == null;

  /// When the action happened — its newest child.
  DateTime get at => children.first.at;

  /// Who made it. Taken from the header when there is one and from the change
  /// rows when there is not: both tables carry `who`, so a parentless action is
  /// still fully attributable.
  String get who => children.first.who;

  /// How many of this action's rows the filters excluded, across both tables.
  ///
  /// Clamped per side at zero: a stale or wrong total must never render
  /// "-2 changes hidden".
  int get hiddenCount {
    final hiddenAudit = totalAuditRowCount - auditRows.length;
    final hiddenChanges = totalChangeCount - changes.length;
    return (hiddenAudit > 0 ? hiddenAudit : 0) +
        (hiddenChanges > 0 ? hiddenChanges : 0);
  }

  /// True when this view of the action is incomplete.
  bool get isPartial => hiddenCount > 0;

  /// True when the action gets an expander.
  bool get isMulti => children.length > 1 || hiddenCount > 0;

  /// The strictest permission across the audit children, or the empty string.
  ///
  /// `group_required` lives on `audit_entry` only, so a parentless action
  /// yields the empty string. That is the honest answer: naming a group the
  /// rows do not carry would be an invention, and defaulting an unknown
  /// permission downward is the failure `AccessGroup.byName`'s null return
  /// exists to prevent. See [strictestGroupName].
  String get requiredGroupLabel =>
      strictestGroupName(auditRows.map((row) => row.groupRequired));
}

/// `audit_entry` rows and `config_change` rows as one list of actions, newest
/// action first.
///
/// The config history's entry point, sharing [groupAuditRows]'s core rather
/// than forking it: the same map-based grouping, the same first-appearance
/// ordering contract, the same "an absent total means we did not ask" rule.
/// [groupAuditRows] is unchanged and its callers are untouched.
///
/// ## Why both streams are inputs
///
/// Driving from the audit side alone would never ask about an action whose
/// header is missing, so an orphaned save would be invisible — and an orphaned
/// save is exactly what a reader most needs to see. Driving from the change
/// side alone would lose an action that legitimately wrote no change rows,
/// which is what every `historyExempt` kind does. Both streams are read and
/// both are grouped.
///
/// ## Ordering
///
/// The two inputs are each newest-first and are **merged** on `at`, ties to the
/// audit side; neither is sorted. A plain `Map` then collects the children, and
/// its key-insertion iteration order is the output contract — first-appearance
/// order, which over a newest-first merge is newest-action-first.
///
/// Concatenating the streams instead would put every action with a header above
/// every action without one and call the result chronological.
///
/// ## What this does not do
///
/// It does not filter. It receives what SQL returned and adds nothing back,
/// which is why the two totals are passed in: the excluded rows are not
/// available to be re-included.
List<HistoryAction> groupHistoryRows({
  required List<AuditEntryData> auditRows,
  required List<ConfigChangeRecord> changes,
  Map<String, int> auditTotalsByActionId = const {},
  Map<String, int> changeTotalsByActionId = const {},
}) {
  final merged = _mergeNewestFirst(
    [for (final row in auditRows) AuditMemberChild(row)],
    [for (final record in changes) ConfigChangeChild(record)],
  );

  final byAction = _groupByKey<ActionChild>(merged, (child) => child.actionId);

  return [
    for (final entry in byAction.entries)
      HistoryAction(
        actionId: entry.key,
        children: List.unmodifiable(entry.value),
        // An absent total means the companion query was not run, so the
        // visible rows are all this can claim. Never zero: zero would be a
        // statement about the action rather than the absence of one — and for
        // the change side a genuine zero is also what an exempt kind produces,
        // so the two cases must not be conflated.
        totalAuditRowCount: auditTotalsByActionId[entry.key] ??
            entry.value.whereType<AuditMemberChild>().length,
        totalChangeCount: changeTotalsByActionId[entry.key] ??
            entry.value.whereType<ConfigChangeChild>().length,
      ),
  ];
}

/// Two newest-first lists as one, ties going to [a].
///
/// A merge and not a sort: each input's internal order is preserved exactly,
/// including the `id DESC` tiebreak its store applied to rows sharing an
/// instant. Re-sorting here would discard that and reshuffle a page save under
/// the operator.
List<ActionChild> _mergeNewestFirst(
    List<AuditMemberChild> a, List<ConfigChangeChild> b) {
  final merged = <ActionChild>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    merged.add(b[j].at.isAfter(a[i].at) ? b[j++] : a[i++]);
  }
  while (i < a.length) {
    merged.add(a[i++]);
  }
  while (j < b.length) {
    merged.add(b[j++]);
  }
  return merged;
}

/// [items] bucketed by [key], in key-insertion order.
///
/// The core both group functions share. A plain `Map` is used and its iteration
/// order relied on: Dart's default `Map` is a `LinkedHashMap` and iterates in
/// key-insertion order, which is the whole output contract of both callers.
Map<String, List<T>> _groupByKey<T>(
    Iterable<T> items, String Function(T) key) {
  final byKey = <String, List<T>>{};
  for (final item in items) {
    byKey.putIfAbsent(key(item), () => <T>[]).add(item);
  }
  return byKey;
}

/// The strictest of [names], or the empty string when there is nothing to rank.
///
/// ## Where the ranking comes from
///
/// `AccessGroup`'s declaration index, which is declared in increasing privilege
/// and is the single ranking in this codebase. This is
/// `guarded_state_man.dart`'s private `_strictest`, copied deliberately rather
/// than exposed by widening that file's API: it is three lines, and a second
/// ranking *table* would be a second thing to keep in step — which is the
/// defect that function's own comment warns about.
///
/// ## Why an unrecognised name is a real state and not a defensive flourish
///
/// The trail stores `group_required` as a **string**, and `AccessGroup.byName`
/// answers null for anything this build does not know. Its own doc says why: a
/// station running a newer build may have written a group name this one has
/// never heard of. Several SVN stations share one database, so on a
/// mixed-version site that is a row that exists.
///
/// So an unrecognised name loses to any recognised one, and when *every* name
/// is unrecognised the first is returned verbatim — the operator sees the
/// string the database actually holds, and the row is neither dropped nor
/// fatal.
///
/// There is deliberately no accessor here that turns an unknown name into
/// `operate`. Defaulting an unrecognised permission downward is exactly the
/// failure `byName`'s null return exists to prevent.
///
/// The empty string is not a group and never wins over one. An all-auth action
/// therefore yields the empty string: auth rows carry an empty `groupRequired`
/// because signing in is not gated on a group, and reporting `operate` for one
/// would be an invention.
String strictestGroupName(Iterable<String> names) {
  AccessGroup? strictest;
  String? firstUnknown;

  for (final name in names) {
    if (name.isEmpty) continue;
    final group = AccessGroup.byName(name);
    if (group == null) {
      firstUnknown ??= name;
      continue;
    }
    if (strictest == null || group.index > strictest.index) strictest = group;
  }

  if (strictest != null) return strictest.name;
  return firstUnknown ?? '';
}

/// True when [row] records an authentication event rather than a write.
///
/// ## Why this is a named predicate rather than a literal
///
/// `surface == 'auth'` is about to be asked in the row widget, the filter bar
/// and the golden fixture. Three copies of a string literal is three places to
/// typo it, and a typo here renders a login as a write with an empty
/// `old → new` instead of failing loudly.
///
/// `AuditRecord.isAuthEvent` (`packages/tfc_access/lib/src/audit.dart`) is the
/// same predicate on the writer's type. The two must stay in step.
///
/// ## Why it keys on `surface` and not on an empty `group_required`
///
/// 05-01's store selects its auth leg with `surface = 'auth'` and this function
/// recognises them with `surface == 'auth'` — the same column, the same value,
/// aligned on purpose. An earlier draft had the store keying on an empty
/// `group_required` while this keyed on `surface`. Those agree on every row in
/// the table today, which is precisely why nothing would have caught them
/// diverging: the row that breaks it is an unbound tag write, which carries an
/// empty `group_required` too (`guarded_state_man.dart` writes
/// `strictestRequired?.name ?? ''`).
bool isAuthEntry(AuditEntryData row) => row.surface == 'auth';
