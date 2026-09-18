/// The Riverpod layer between `AuditTrailStore` and the audit trail page.
///
/// Three providers, and the whole of Phase 2's unavailable-versus-empty ruling
/// lives in the first two:
///
/// | Provider | Lifetime | Answers |
/// |---|---|---|
/// | [auditTrailStoreProvider] | `keepAlive` | a store, or **null** when this station has no database |
/// | [auditTrailEntriesProvider] | autoDispose family | one [AuditQuery] as one [AuditTrailResult], or **null** |
/// | [auditWhoOptionsProvider] | `keepAlive` | the `who` dropdown's options |
///
/// **Refresh is `ref.invalidate`, and this file starts no timer.** That is
/// CONTEXT's ruling and it has a reason: an always-on `Timer.periodic` in this
/// repo's plumbing has broken unrelated widget tests, and a self-scrolling
/// audit list is unreadable while you are trying to read a row. The deferred
/// list already records the live-update design that was offered and not taken
/// (a listener-gated 30s poll showing "N new entries — tap to load"); if it is
/// ever built it must be listener-gated — started in `onListen`, stopped in
/// `onCancel` — and not a bare periodic. `audit_trail_test.dart` asserts the
/// absence on the source text rather than trusting this paragraph.
library;

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../core/audit_trail_grouping.dart';
import '../core/audit_trail_store.dart';
import '../core/config_change_store.dart';
import 'config_history.dart' show configChangeStoreProvider;
import 'database.dart';

part 'audit_trail.g.dart';

/// Reads of `audit_entry`, or null when this station has no database.
///
/// Null is a normal state, exactly as it is for `accessRepositoryProvider` and
/// for `accessTemplateStoreProvider` next door: no Postgres configured, and
/// again during the boot window before the connection opens. The two causes are
/// **indistinguishable by design** — `databaseProvider` returns null for both —
/// which is why the page's copy names no cause and says only that the trail is
/// unavailable.
///
/// `keepAlive`, unlike [auditTrailEntriesProvider] below: this holds the handle
/// `databaseProvider` already owns and rebuilding it on every page visit would
/// be churn for nothing. The query result is the thing worth releasing.
@Riverpod(keepAlive: true)
Future<AuditTrailStore?> auditTrailStore(Ref ref) async {
  final db = await ref.watch(databaseProvider.future);
  if (db == null) return null;
  // One argument, where `accessTemplateStoreProvider` passes five. The four
  // that are missing — session, audit, station, onDenied — are missing because
  // this store cannot deny and cannot record: it has no write method to guard
  // and a guard on the read would put a row in the trail every time somebody
  // scrolled the trail. The enforcement is the route gate,
  // `kRaisedRoutes['/advanced/audit-trail']`, and `kAuditTrailGroup` is the one
  // word it is spelled from.
  return AuditTrailStore(db: db.db);
}

/// One query's worth of trail, in the shape the page draws.
///
/// An **empty** [actions] is a real answer — "no rows matched these filters" —
/// and is a different thing from the null [auditTrailEntriesProvider] returns
/// when there is no database to ask. The page renders two different terminal
/// states for the two, which is why this type exists rather than the provider
/// answering a bare `List<AuditAction>?`: a nullable list has only one empty
/// value and would collapse them.
class AuditTrailResult {
  const AuditTrailResult({
    required this.actions,
    required this.rowCount,
    required this.reachedLimit,
    required this.oldestAt,
    this.configChanges = const {},
  });

  /// The grouped actions, newest action first.
  final List<AuditAction> actions;

  /// The configuration actions among [actions], by action id: how many
  /// `config_change` rows each wrote, by kind.
  ///
  /// **Absent means audit-only**, which is what a sign-in, a denial or a tag
  /// write is. A present entry is what makes the page draw the action as the
  /// configuration view does — field diffs when opened, Undo beside it —
  /// rather than as a bare `page.save` line with a summary capped at a
  /// kilobyte. Keyed by action id and not by `surface`: a configuration save
  /// records its header on `pref`, as a preference write does, and only the
  /// change rows tell the two apart.
  final Map<String, ActionChangeCounts> configChanges;

  /// How many **rows** came back, before grouping.
  ///
  /// The number the `LIMIT` applied to, and not `actions.length`: eight rows of
  /// one struct write are one action, and it is the eight that the cap counted.
  final int rowCount;

  /// True when this query returned exactly as many rows as it asked for.
  ///
  /// Which means there may be older matching rows it did not return, and the
  /// page offers "Load more". CONTEXT ruled that paging further back is an
  /// explicit action rather than infinite scroll, so this is a flag the page
  /// renders a button from and never a trigger for a second query.
  final bool reachedLimit;

  /// The `at` of the oldest row returned, or null when there were none.
  ///
  /// The "Load more" cursor: the next page is `before: oldestAt`, which narrows
  /// the window the filters produced rather than replacing the rule that
  /// produced it.
  final DateTime? oldestAt;
}

/// One [AuditQuery], one statement, one set of grouped actions — or null when
/// this station has no database.
///
/// ## Why this one is autoDispose where its neighbours are not
///
/// `access_templates.dart`'s two `keepAlive` providers are keepAlive for a
/// stated reason: they feed the plant-connection policy, and rebuilding them
/// would rebuild the database handle — and with it every OPC UA subscription on
/// the panel — on every sign-in. Nothing of the sort is true here. This feeds
/// one page and nothing else, so holding a query result after the page is gone
/// is a cache nobody reads and a handle held on behalf of nobody.
/// `tagAccessProvider` in that same file is the plain `@riverpod` shape this
/// copies; the family argument is the only thing this one adds.
///
/// ## Null, error and empty are three answers
///
/// Null means the trail is **unavailable** — no database. An error means the
/// database was there and the read failed, which the page also renders as
/// unavailable, and which must not be swallowed here: "nothing matched" is a
/// claim about the plant's history and a failed read is not entitled to make
/// it. An [AuditTrailResult] with no actions means the query ran and matched
/// nothing.
///
/// ## Refresh
///
/// `ref.invalidate(auditTrailEntriesProvider)`, from the page's refresh action.
/// Nothing here polls; see the library doc for why, and for what a future
/// live-update hook would have to look like instead.
@riverpod
Future<AuditTrailResult?> auditTrailEntries(Ref ref, AuditQuery query) async {
  final store = await ref.watch(auditTrailStoreProvider.future);
  if (store == null) return null;

  final rows = await store.entries(query);
  // The companion count, outside the filter predicate. The rows the filters
  // excluded are not in `rows` at all, so "6 of 9 members hidden by filters"
  // cannot be derived from what came back — this is where the 9 comes from.
  final totals = await store.memberCountsByAction(rows.map((row) => row.actionId));

  // Which of these actions changed configuration, counted by kind. One grouped
  // statement over the page's action ids, and not the rows themselves — see
  // `DeferredConfigActionTile` for why those wait until an action is opened.
  // The change store reads the same handle as this one, so it is null only
  // when this is; an empty map is the honest degradation if it ever is not:
  // every action draws as the audit line it is.
  //
  // A failed count is left to throw, as a failed trail read is. Swallowing it
  // would draw every configuration action as audit-only, which is a claim about
  // the history this page could not check.
  final changeStore = rows.isEmpty
      ? null
      : await ref.watch(configChangeStoreProvider.future);
  final configChanges = changeStore == null
      ? const <String, ActionChangeCounts>{}
      : await changeStore
          .changeKindCountsByAction(rows.map((row) => row.actionId));

  return AuditTrailResult(
    actions: groupAuditRows(rows, totalsByActionId: totals),
    configChanges: configChanges,
    rowCount: rows.length,
    reachedLimit: rows.length == query.limit,
    // The store orders newest first, so the last row is the oldest one and the
    // cursor the next page starts from.
    oldestAt: rows.isEmpty ? null : rows.last.at,
  );
}

/// Every distinct `who` in the table, for the filter bar's dropdown.
///
/// Answers an **empty list** — not null and not an error — when the store is
/// null. A `who` dropdown with no options on an unreachable database is
/// correct; an exception here would take the whole filter bar down with it, and
/// the page already says "unavailable" once, from [auditTrailEntriesProvider].
/// Saying it twice, in two shapes, is not more honest.
///
/// `keepAlive`: `distinctWho` groups the whole table, and on an autoDispose
/// provider it ran again, in series with the page's own queries, on every visit.
/// The page's refresh action invalidates it, which is when a newly seen name
/// can reasonably be expected to appear.
@Riverpod(keepAlive: true)
Future<List<String>> auditWhoOptions(Ref ref) async {
  final store = await ref.watch(auditTrailStoreProvider.future);
  if (store == null) return const [];
  return store.distinctWho();
}
