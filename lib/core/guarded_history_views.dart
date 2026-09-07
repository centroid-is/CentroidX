/// The history view's write guard — spec §6's fourth bypass, closed at the
/// controls.
///
/// `lib/pages/history_view.dart` reached Drift directly at five places, through
/// two different accessors (`adb` and `dbWrap.db`, which is why a grep for one
/// never found the other). None of them passed `StateMan.write` or
/// `PreferencesApi.set*`, so neither `GuardedStateMan` nor `GuardedPreferences`
/// could ever see them. This is the third surface: a store that holds all five
/// writes, checks the two destructive ones, and records every one.
///
/// ## Why this is not fixed at the route
///
/// `/advanced/history-view` is deliberately absent from `kRaisedRoutes`, and
/// must stay absent. Spec §11 defers read permissions on trends and history on
/// purpose, and reading history is operate-level work — an operator looking at
/// last night's shift is doing their job. The defect Phase 2 found is a
/// *destructive control* on a page that should stay readable, so the fix
/// belongs at the control. `guarded_history_views_test.dart` asserts the route
/// is still not raised, so that claim is checked rather than remembered.
///
/// ## Why the group is looked up rather than declared here
///
/// **This changed in plan 17-01, and the reason is worth having.** Until then
/// the two groups were `const AccessGroup` declarations in this file, on the
/// argument that a `history_view.` entry in `kPrefAccessRules` would be a
/// second source for one answer. The argument was right about the danger and
/// wrong about where the answer belonged: `packages/tfc_relay_server` cannot
/// import the Flutter app, so when the relay had to grade the same five
/// methods it could not read these constants and invented `role == operate`
/// instead — and got a *different* answer in both directions
/// (`docs/access-control-write-path-sweep.md` §3.12). Two guards, two answers,
/// one table.
///
/// So the answer moved down to `tfc_access`, which both processes can reach,
/// and this store asks [AccessPolicy.groupForHistoryView] for it. That is the
/// phase's ruling — one master access-control system, the WebSocket builds on
/// top of it — and the app's split is what won: the two deletes require
/// `configure`, the other three stay open.
///
/// If you are here to change what is gated, change
/// `AccessPolicy.groupForHistoryView`. There is exactly one place, and it is
/// not this file.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// The policy every group answer in this file comes from.
///
/// `const`, and constructed rather than injected, because the two questions
/// this store asks — [AccessPolicy.groupForHistoryView] for five member names
/// — depend on neither tag bindings nor the route table, which are the only
/// two things [AccessPolicy]'s constructor takes. A policy built with those
/// arguments would answer these five identically, so there is nothing for a
/// caller to configure and no seam worth the parameter.
const AccessPolicy _policy = AccessPolicy();

/// The permission the two **destructive** history-view writes require.
///
/// Deleting a saved view or a saved period destroys somebody else's work from
/// a page anyone can open, which is the whole of spec §6's fourth bypass.
/// Changing this to a lower group opens that hole again; changing it to a
/// higher one takes the delete away from the shift leaders who curate these
/// views. `configure` is what the page editor and the key mappings ask for, and
/// a saved view is the same kind of thing: station configuration somebody
/// authored.
///
/// **Not a declaration — a question.** As of plan 17-01 this reads the answer
/// out of [AccessPolicy.groupForHistoryView]; changing the value here is not
/// possible, and changing it there changes it for the relay in the same
/// commit. The name is kept because other files and this milestone's docs
/// refer to it.
AccessGroup? get kHistoryViewDeleteGroup =>
    _policy.groupForHistoryView(AccessPolicy.historyViewDelete);

/// The permission the three **non-destructive** history-view writes require —
/// `null`, meaning open to any session, anonymous included.
///
/// Changing [AccessPolicy.groupForHistoryView] so these three answer a group
/// gates all five writes instead of two, and the "stays open" tests in
/// `guarded_history_views_test.dart` are what will tell you exactly what
/// moved. That is the whole point of the pair: the question
/// `.planning/phases/02-route-gating/deferred-items.md` §4 raised and never
/// got a ruling on is answered in one visible place rather than at five call
/// sites — and, since 17-01, in one visible place for **both** processes
/// rather than one each.
///
/// **Why open, today.** An operator saving a view of the line they run, giving
/// it a name, or bookmarking the eight hours they want to look at again is
/// doing their job. The defect Phase 2 found is a destructive control, not a
/// creative one, and this milestone's posture is that a wrongly-closed operator
/// action becomes a workaround. Every one of the three is recorded anyway
/// ([_guard] audits regardless of the group), so the choice is reviewable from
/// the trail rather than only from this comment: if saved views start
/// appearing and disappearing, the rows say who.
AccessGroup? get kHistoryViewWriteGroup =>
    _policy.groupForHistoryView(AccessPolicy.historyViewCreate);

/// Every write `lib/pages/history_view.dart` makes, behind one object.
///
/// The five members carry the same names, parameters and return types as
/// [AppDatabase]'s, so a call site changes only its receiver. Reads are not
/// here: they stay on `dbWrap.db`, ungated and unaudited, per spec §11.
class HistoryViewStore {
  /// [session] is a **callback, not a value**, for the reason `GuardedStateMan`
  /// gives at its own constructor: the store is built per write from providers
  /// that outlive any one session, and a captured [AccessSession] would keep
  /// granting whatever the operator held when it was built, after the
  /// inactivity monitor had already dropped them back to anonymous.
  ///
  /// [onDenied] fires **before** the [AccessDenied] is thrown, so the shared
  /// prompt (`lib/widgets/access_denied_prompt.dart`) appears even at a call
  /// site that swallows the exception.
  HistoryViewStore({
    required AppDatabase db,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _db = db,
        _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final AppDatabase _db;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;

  /// This store's own diagnostic logger, for the audit-sink failures it
  /// swallows. Nothing else logs here.
  final Logger _logger;

  /// The surface every row carries, by its wire name.
  ///
  /// **This was `AccessSurface.pref` until plan 17-01.** The reasoning then was
  /// that a saved history view is station configuration, so it belonged on the
  /// existing `pref` surface, because spec §2's vocabulary had three write
  /// values and inventing a fourth for one page would make a year of rows read
  /// differently. 17-01 gave the policy a real `history_view` surface — the
  /// relay needs to name it to grade it — so the borrowed name is no longer
  /// the least-bad option.
  ///
  /// **The consequence, named because somebody will hit it.** Rows written
  /// before this deploy carry `surface = 'pref'`; rows written after carry
  /// `surface = 'history_view'`. A trail query filtering on `surface` sees a
  /// discontinuity at the deploy and must ask for both to cover the whole
  /// history. The old rows were not rewritten on purpose: rewriting a year of
  /// audit rows to make a query tidier is a worse trade than a documented
  /// discontinuity, and an audit trail that gets edited for tidiness is not
  /// one. The `history_view.` / `history_view_period.` [_itemKey] prefixes are
  /// unchanged and span the boundary, so they are the safer thing to filter on.
  static final String _surface = AccessSurface.historyView.wireName;

  // ---------------------------------------------------------------------------
  // The five writes
  // ---------------------------------------------------------------------------

  /// Saves a new view. Open to any session — see [kHistoryViewWriteGroup].
  ///
  /// The row's `itemKey` is `history_view.new`, not `history_view.<id>`: the
  /// row is written before the insert (see [_guard]), so there is no id yet.
  /// The name is in `newValue`, and the prefix a reader filters on is intact.
  Future<int> createHistoryView(String name, List<String> keys,
          [Map<String, Map<String, dynamic>>? keyConfigs,
          Map<String, Map<String, dynamic>>? graphConfigs]) =>
      _guardMember(
        itemKey: 'history_view.new',
        member: AccessPolicy.historyViewCreate,
        newValue: name,
        write: () =>
            _db.createHistoryView(name, keys, keyConfigs, graphConfigs),
      );

  /// Renames a view and rewrites its key and graph configuration. Open to any
  /// session — see [kHistoryViewWriteGroup].
  Future<void> updateHistoryView(int id, String name, List<String> keys,
          [Map<String, Map<String, dynamic>>? keyConfigs,
          Map<String, Map<String, dynamic>>? graphConfigs]) =>
      _guardMember(
        itemKey: _itemKey(id),
        member: AccessPolicy.historyViewUpdate,
        newValue: name,
        write: () =>
            _db.updateHistoryView(id, name, keys, keyConfigs, graphConfigs),
      );

  /// Destroys a saved view and everything hanging off it. Requires
  /// [kHistoryViewDeleteGroup].
  Future<void> deleteHistoryView(int id) => _guardMember(
        itemKey: _itemKey(id),
        member: AccessPolicy.historyViewDelete,
        write: () => _db.deleteHistoryView(id),
      );

  /// Bookmarks a time range on a view. Open to any session — see
  /// [kHistoryViewWriteGroup].
  Future<int> addHistoryViewPeriod(
          int viewId, String name, DateTime start, DateTime end) =>
      _guardMember(
        itemKey: 'history_view_period.new',
        member: AccessPolicy.historyViewAddPeriod,
        newValue: name,
        write: () => _db.addHistoryViewPeriod(viewId, name, start, end),
      );

  /// Destroys a saved period. Requires [kHistoryViewDeleteGroup].
  Future<void> deleteHistoryViewPeriod(int id) => _guardMember(
        itemKey: _periodItemKey(id),
        member: AccessPolicy.historyViewDeletePeriod,
        write: () => _db.deleteHistoryViewPeriod(id),
      );

  // ---------------------------------------------------------------------------
  // The one implementation of the rule
  // ---------------------------------------------------------------------------

  /// Ask the policy what [member] requires, then [_guard] with the answer.
  ///
  /// **The one place this store consults [AccessPolicy], and the reason the
  /// group and the audit `reason` cannot disagree**: [member] is both the
  /// name the policy is asked about and the string written into the row's
  /// `reason` column, so a call site cannot grade one member while recording
  /// another. Before plan 17-01 those were two separate arguments at five call
  /// sites — a `group:` constant and a `reason:` string literal — and nothing
  /// held them together.
  Future<T> _guardMember<T>({
    required String itemKey,
    required String member,
    required Future<T> Function() write,
    String? newValue,
  }) =>
      _guard(
        itemKey: itemKey,
        group: _policy.groupForHistoryView(member),
        reason: member,
        newValue: newValue,
        write: write,
      );

  /// Check, record, then write — the ordering `GuardedStateMan` established and
  /// this reuses rather than restates.
  ///
  /// The row comes **before** the Drift call on both paths. On the permitted
  /// path that means a write that then fails at the database leaves a row for
  /// an action that was authorized, which is the lesser loss: spec §2's
  /// reasoning is that an absent audit row is the defect nobody notices. On the
  /// deny path the row is the only evidence the guard fired and must exist even
  /// though the exception is about to be thrown.
  ///
  /// [group] of null means the write is not gated. It is still recorded, with
  /// an empty `groupRequired` — the same convention the auth rows use for "not
  /// gated on a group".
  Future<T> _guard<T>({
    required String itemKey,
    required AccessGroup? group,
    required String reason,
    required Future<T> Function() write,
    String? newValue,
  }) async {
    // One id per call, so a row correlates with the action that made it and two
    // actions never collide.
    final actionId = newActionId();
    final session = _session();

    if (group != null && !session.can(group)) {
      await _record(_row(
        session: session,
        itemKey: itemKey,
        groupRequired: group.name,
        newValue: newValue,
        allowed: false,
        reason: reason,
        actionId: actionId,
      ));

      final denial = AccessDenied(itemKey, group);
      try {
        _onDenied?.call(denial);
      } on Object catch (error, stack) {
        // A listener's bug must not change what the caller sees. The refusal is
        // this store's answer; a broken prompt is cosmetic beside it.
        _logger.e('onDenied listener threw for "$itemKey"',
            error: error, stackTrace: stack);
      }
      throw denial;
    }

    await _record(_row(
      session: session,
      itemKey: itemKey,
      groupRequired: group?.name ?? '',
      newValue: newValue,
      allowed: true,
      reason: reason,
      actionId: actionId,
    ));
    return write();
  }

  AuditRecord _row({
    required AccessSession session,
    required String itemKey,
    required String groupRequired,
    required String? newValue,
    required bool allowed,
    required String reason,
    required String actionId,
  }) =>
      AuditRecord(
        at: DateTime.now(),
        who: session.user?.username ?? _anonymousWho,
        station: _station,
        roleName: session.roleName,
        surface: _surface,
        itemKey: itemKey,
        newValue: newValue,
        groupRequired: groupRequired,
        allowed: allowed,
        // Which of the five it was. A delete carries no old and no new value —
        // the row would otherwise say only that *something* happened to a view.
        reason: reason,
        actionId: actionId,
      );

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// `DriftAuditSink.record` already swallows its own failures, so this is
  /// belt-and-braces there. But [AuditSink] is an interface whose non-throwing
  /// contract lives in a doc comment and nothing enforces it, and the
  /// consequences of trusting it differ by path. On the permitted path an
  /// escaping sink exception would fail a write the session was allowed to
  /// make. On the deny path it would replace [AccessDenied] with something no
  /// caller catches, skip `onDenied`, and leave the operator with a control
  /// that did nothing and no explanation for it. Neither is acceptable, and
  /// this is the same rule in the same words as plans 03-04 and 03-05.
  ///
  /// The price is that a lost row is only a log line, so the line names the row
  /// it lost.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }

  /// The `itemKey` of a saved view. The prefix is what the Phase 5 viewer
  /// filters on.
  static String _itemKey(int id) => 'history_view.$id';

  /// The `itemKey` of a saved period. A distinct prefix from [_itemKey] —
  /// `history_view_period.` does not start with `history_view.` — so filtering
  /// for one does not drag in the other.
  static String _periodItemKey(int id) => 'history_view_period.$id';
}
