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
const Set<String> kKnownAuditSurfaces = {'tag', 'pref', 'route', 'auth', 'admin'};

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
  final List<AuditRecord> rows;

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
  AuditRecord get lead => rows.first;

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
  List<AuditRecord> rows, {
  Map<String, int> totalsByActionId = const {},
}) {
  final byAction = <String, List<AuditRecord>>{};
  for (final row in rows) {
    byAction.putIfAbsent(row.actionId, () => <AuditRecord>[]).add(row);
  }

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
/// same predicate on the writer's type, and this function now **delegates to
/// it** rather than restating it. Before the store answered in `AuditRecord`
/// there were two literals to keep in step and a comment here asking a reader
/// to do it by hand; there is one now, and it lives with the type. The name
/// stays because three widgets and the source-grep test below read better for
/// it — what went away is the second definition, not the second spelling.
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
bool isAuthEntry(AuditRecord row) => row.isAuthEvent;
