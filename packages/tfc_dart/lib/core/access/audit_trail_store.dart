/// The first reader of `audit_entry`: one filter value type, the two-mode rule
/// that decides how far back a query reaches, and one store object that turns
/// the result into one bounded newest-first statement.
///
/// Nothing in the tree selected from `audit_entry` before this file. The table
/// has had exactly one writer since Phase 1 — `DriftAuditSink` — and this is
/// its counterpart on the read side.
///
/// ## Why the query is built here rather than as a method on `AppDatabase`
///
/// Pages never touch Drift, and neither does anything else outside a store —
/// that was Phase 3's bypass-4 defect (`history_view.dart:1108`). Putting the
/// query on `AppDatabase` would put a second place to look for it and would
/// spend a `tfc_dart` release on a statement only this page issues. The typed
/// builder compiles to SQLite and Postgres alike, so the in-memory test
/// exercises the real statement rather than a stand-in for it.
///
/// ## Why the reads are ungated and unaudited
///
/// `access_template_store.dart`'s class doc is the binding precedent: *"Reads …
/// are ungated and unaudited: looking at the rules is not an authorization
/// change, and a row per render would bury the writes that matter."* That
/// applies with more force here. A store-level guard on this read would write a
/// row into the trail every time somebody scrolled the trail, and the trail
/// would fill with people looking at it.
///
/// The enforcement is the **route** gate —
/// `kRaisedRoutes['/advanced/audit-trail'] = AccessGroup.users`.
/// [kAuditTrailGroup] exists in this file so that the route and the store name
/// the same word once.
library;

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import '../database_drift.dart';

/// The permission the audit trail route requires.
///
/// `users`, the highest group, and for the **data** the page shows rather than
/// for anything it writes — it writes nothing at all.
///
/// **What lowering this line would mean.** Set it to `AccessGroup.configure`
/// and every setpoint change anybody ever made, with its old and new values,
/// its author and its station, is in front of anyone who can edit a page or
/// import a key map. The trail is a complete history of what the plant was told
/// to do and by whom; spec §2 keeps denials in it precisely because a denied
/// write is how you find a role configured too tightly, which is the same
/// sentence read the other way round — the page is a window on the
/// authorization model, so it sits at the authorization model's own gate.
///
/// **This constant is not the enforcement.** The route gate is: the store below
/// takes no session, holds no `AuditSink` and cannot refuse a caller. This
/// constant is the one word the route is spelled from, and plan 05-07 adds the
/// test that `kRaisedRoutes['/advanced/audit-trail']` and this line agree.
const AccessGroup kAuditTrailGroup = AccessGroup.users;

/// How far back the page reaches when nobody has asked for anything else.
const Duration kAuditTrailDefaultWindow = Duration(days: 7);

/// The most rows any single query returns, in either mode.
///
/// The whole-table search escapes the *time* bound and never this one. A year
/// of rows must not come back in one statement.
const int kAuditTrailRowLimit = 500;

/// The group names selected when the page opens: every group except `operate`,
/// in [AccessGroup] declaration order.
///
/// Derived from `AccessGroup.values` rather than typed out, so an eighth group
/// arrives selected rather than silently missing. The ROADMAP names exactly one
/// exclusion and no others — `operate` is excluded because a jog button pressed
/// four hundred times an hour would be the whole page.
///
/// The exclusion is a **visible control**: 05-05 renders `operate` as a normal
/// chip, deselected, with a one-line note. Hidden behaviour reads as a bug, and
/// the row count would otherwise be inexplicable.
final List<String> kAuditTrailDefaultGroupNames = List.unmodifiable(
  AccessGroup.values
      .where((group) => group != AccessGroup.operate)
      .map((group) => group.name),
);

/// The allow/deny segmented control's three states.
enum AuditOutcomeFilter {
  /// Allowed and denied rows alike — the default.
  any,

  /// Only rows the guard let through.
  allowedOnly,

  /// Only denials. Spec §2: a denied write is the more interesting audit line,
  /// and it is how you find a role configured too tightly.
  deniedOnly,
}

/// A closed time interval over `audit_entry.at`.
///
/// Flutter's `DateTimeRange` is the obvious type and is deliberately not used:
/// there is no `flutter/` import anywhere in `lib/core/`, and one here would
/// make this file unusable from a pure-Dart context and would drag the widget
/// layer's conventions into the query layer. The filter bar in 05-05 converts
/// from `DateTimeRange` at its own boundary.
///
/// Value equality matters more here than it looks. This type is a field on
/// [AuditQuery], which keys a provider family; a window with reference equality
/// would make every rebuild a cache miss and every cache miss a database round
/// trip.
class AuditWindow {
  const AuditWindow({required this.start, required this.end});

  /// Inclusive lower bound.
  final DateTime start;

  /// Inclusive upper bound.
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'AuditWindow($start .. $end)';
}

/// What the four filter controls hold, as one value.
///
/// The page owns one of these and rebuilds it through [copyWith]; [toQuery] is
/// the only thing that turns it into something the database sees.
class AuditTrailFilters {
  const AuditTrailFilters({
    this.keyPrefix = '',
    this.who,
    List<String>? groupNames,
    this.includeAuth = true,
    this.outcome = AuditOutcomeFilter.any,
    this.range,
  }) : _groupNames = groupNames;

  /// Matched against `item_key` as a prefix. Empty means no key constraint.
  final String keyPrefix;

  /// An exact `who`, chosen from [AuditTrailStore.distinctWho]. Null means
  /// everybody.
  final String? who;

  /// Null means "whatever the page opens with" — see [groupNames].
  final List<String>? _groupNames;

  /// Whether auth rows — sign-ins, sign-outs, failed attempts and timeouts —
  /// are shown.
  ///
  /// Its own flag rather than a group name, because auth rows carry an **empty**
  /// `group_required` and so cannot be named by one.
  final bool includeAuth;

  /// Allowed, denied, or both.
  final AuditOutcomeFilter outcome;

  /// An explicitly chosen window. Null means [toQuery] decides — which is the
  /// whole of the two-mode rule.
  final AuditWindow? range;

  /// The selected `group_required` values.
  ///
  /// **Empty means no group constraint at all**, exactly as
  /// `AlarmLevelFilterChips` behaves (`lib/widgets/alarm.dart:96-101`) — the
  /// semantics the operator has already learned. It reads backwards on first
  /// encounter, and it is the locked decision; see [AuditTrailStore.entries]
  /// for the query-side half and the reason it is written down twice.
  List<String> get groupNames => _groupNames ?? kAuditTrailDefaultGroupNames;

  /// True once the operator has asked a question about a key or a person.
  ///
  /// This is what flips [toQuery] into whole-table mode. A whitespace-only
  /// [keyPrefix] does not count: a stray space in the search field must not
  /// silently drop the seven-day bound.
  bool get isSearching => keyPrefix.trim().isNotEmpty || who != null;

  /// True of the value a freshly opened page holds.
  ///
  /// 05-05's "Clear filters" button is shown when this is false, and the empty
  /// state's copy differs depending on it.
  bool get isDefault =>
      keyPrefix.trim().isEmpty &&
      who == null &&
      range == null &&
      includeAuth &&
      outcome == AuditOutcomeFilter.any &&
      _sameStrings(groupNames, kAuditTrailDefaultGroupNames);

  /// The default filters — the same value a freshly opened page holds.
  AuditTrailFilters cleared() => const AuditTrailFilters();

  /// A copy with only the named fields replaced.
  ///
  /// [who] and [range] are nullable, so a bare parameter cannot say "set this
  /// to null" — passing null is indistinguishable from omitting it. The filter
  /// bar needs both meanings (clearing the `who` dropdown is not the same
  /// gesture as changing the key prefix), so each nullable field gets a
  /// companion [clearWho] / [clearRange] flag.
  AuditTrailFilters copyWith({
    String? keyPrefix,
    String? who,
    bool clearWho = false,
    List<String>? groupNames,
    bool? includeAuth,
    AuditOutcomeFilter? outcome,
    AuditWindow? range,
    bool clearRange = false,
  }) =>
      AuditTrailFilters(
        keyPrefix: keyPrefix ?? this.keyPrefix,
        who: clearWho ? null : (who ?? this.who),
        groupNames: groupNames ?? _groupNames,
        includeAuth: includeAuth ?? this.includeAuth,
        outcome: outcome ?? this.outcome,
        range: clearRange ? null : (range ?? this.range),
      );

  /// The statement this filter state describes, as of [now].
  ///
  /// ## The two modes, and the user's ruling behind them
  ///
  /// The page must answer two different questions with the same controls.
  /// *"What happened here lately"* is the last seven days, capped at 500 rows.
  /// *"Has anyone **ever** written this key"* is the whole table, capped at 500
  /// rows. The user overrode the original "newest 500, no time bound" proposal
  /// specifically to get both, in these words: searching must answer "has
  /// anyone ever written this key", not "did anyone this week". A search that
  /// silently covered only the default window would be a wrong answer that
  /// looks like a right one.
  ///
  /// ## Precedence, in order
  ///
  /// 1. An explicit [range] wins over everything. The operator asked for that
  ///    window and gets exactly it, search term or not.
  /// 2. Otherwise, [isSearching] drops the time bound entirely — the whole
  ///    table, newest 500 matches. **This is the rule somebody will be tempted
  ///    to "simplify" away**, because confining a search to the loaded window
  ///    is the cheaper implementation and looks identical until the row you
  ///    wanted is eight days old.
  /// 3. Otherwise, [kAuditTrailDefaultWindow] back from [now].
  ///
  /// There is no fourth mode. No "search within the current window" toggle, no
  /// "last 30 days" convenience that quietly becomes the default. Two modes and
  /// one explicit override.
  ///
  /// [before] is the "Load more" cursor and is carried through untouched, so
  /// paging narrows an existing window rather than replacing the rule that
  /// produced it.
  AuditQuery toQuery({required DateTime now, DateTime? before}) {
    final AuditWindow? window;
    if (range != null) {
      window = range;
    } else if (isSearching) {
      window = null;
    } else {
      window = AuditWindow(
        start: now.subtract(kAuditTrailDefaultWindow),
        end: now,
      );
    }

    return AuditQuery(
      window: window,
      before: before,
      keyPrefix: keyPrefix,
      who: who,
      groupNames: groupNames,
      includeAuth: includeAuth,
      outcome: outcome,
      limit: kAuditTrailRowLimit,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditTrailFilters &&
          other.keyPrefix == keyPrefix &&
          other.who == who &&
          other.includeAuth == includeAuth &&
          other.outcome == outcome &&
          other.range == range &&
          _sameStrings(other.groupNames, groupNames);

  @override
  int get hashCode => Object.hash(
        keyPrefix,
        who,
        includeAuth,
        outcome,
        range,
        Object.hashAll(groupNames),
      );

  @override
  String toString() => 'AuditTrailFilters(keyPrefix: "$keyPrefix", who: $who, '
      'groups: $groupNames, auth: $includeAuth, outcome: ${outcome.name}, '
      'range: $range)';
}

/// One resolved query: everything [AuditTrailStore.entries] needs and nothing
/// it has to decide.
///
/// A value type with full equality, because 05-04 keys a provider family on it.
/// A family keyed on a broken `==` re-queries the database on every rebuild.
class AuditQuery {
  AuditQuery({
    this.window,
    this.before,
    String keyPrefix = '',
    this.who,
    Iterable<String> groupNames = const [],
    this.includeAuth = false,
    this.outcome = AuditOutcomeFilter.any,
    this.limit = kAuditTrailRowLimit,
  })  : keyPrefix = keyPrefix.trim(),
        groupNames = List.unmodifiable(groupNames.toSet().toList()..sort());

  /// The time bound, or null for **the whole table** — the search escape.
  final AuditWindow? window;

  /// The "Load more" cursor: rows strictly older than this. Composes with
  /// [window] rather than replacing it.
  final DateTime? before;

  /// Trimmed. Empty means no key constraint.
  final String keyPrefix;

  /// Exact match on `who`, or null.
  final String? who;

  /// Sorted and duplicate-free, so equality does not depend on chip tap order.
  final List<String> groupNames;

  /// Whether `surface = 'auth'` rows are OR'd in.
  ///
  /// Defaults to false here and to true on [AuditTrailFilters], which is not an
  /// inconsistency: a bare `AuditQuery()` names no groups either, and the two
  /// defaults together mean *no group constraint at all* — every row. Defaulting
  /// it to true would make `AuditQuery()` mean "auth rows only", which is a
  /// surprising thing for a query nobody constrained to return.
  final bool includeAuth;

  /// Allowed, denied, or both.
  final AuditOutcomeFilter outcome;

  /// Applied after every `WHERE` clause, never instead of one.
  final int limit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditQuery &&
          other.window == window &&
          other.before == before &&
          other.keyPrefix == keyPrefix &&
          other.who == who &&
          other.includeAuth == includeAuth &&
          other.outcome == outcome &&
          other.limit == limit &&
          _sameStrings(other.groupNames, groupNames);

  @override
  int get hashCode => Object.hash(
        window,
        before,
        keyPrefix,
        who,
        includeAuth,
        outcome,
        limit,
        Object.hashAll(groupNames),
      );

  @override
  String toString() => 'AuditQuery(window: ${window ?? "whole table"}, '
      'before: $before, keyPrefix: "$keyPrefix", who: $who, '
      'groups: $groupNames, auth: $includeAuth, outcome: ${outcome.name}, '
      'limit: $limit)';
}

/// The `surface` value every authentication row carries.
///
/// `AccessSurface` enumerates the three *write* surfaces and has no `auth`
/// member; the value is fixed by the four named constructors on `AuditRecord`,
/// which are the only writers of an auth row. 05-02's `isAuthEntry` keys on the
/// same string, and the auth invariant test seeds all four constructors and
/// checks both columns, so the two cannot drift apart.
const String _auditAuthSurface = 'auth';

/// Reads of `audit_entry`, and nothing else.
///
/// Ungated and unaudited, on the precedent `access_template_store.dart` sets for
/// its own reads: looking at the trail is not an authorization change, and a row
/// per render would bury the writes that matter — here it would bury them under
/// rows recording that somebody looked. The enforcement is the route gate; see
/// [kAuditTrailGroup].
///
/// **This object cannot deny and cannot record.** It takes no session, no sink,
/// no station and no denial callback. It has no `into`, no `update` and no
/// `delete`. The trail's append-only property is enforced by there being nowhere
/// to write it from, and a source-text test in
/// `test/core/audit_trail_store_test.dart` keeps that trivially checkable rather
/// than merely true today.
class AuditTrailStore {
  AuditTrailStore({required AppDatabase db, Logger? logger})
      : _db = db,
        _logger = logger ?? Logger();

  final AppDatabase _db;

  /// This store's own diagnostic logger. Held for symmetry with the other
  /// stores and for the diagnostics a future failure path will want; nothing
  /// here swallows an error, so nothing here logs one yet.
  // ignore: unused_field
  final Logger _logger;

  /// The newest rows matching [query], newest first, at most [AuditQuery.limit]
  /// of them.
  ///
  /// One statement. Every filter is a `WHERE` clause applied **before** the
  /// `LIMIT`, so a count of denials is a count of the table's denials and not of
  /// the loaded page's — filtering the already-loaded rows in memory would show
  /// three denials while the table held three hundred.
  ///
  /// Ties on `at` resolve by `id DESC`. A struct write puts one row per changed
  /// member at the same instant, so without the tiebreak two runs of the same
  /// query could return the same rows in different orders and the page would
  /// reshuffle under the operator.
  ///
  /// ## The group predicate, and why auth rows get their own leg
  ///
  /// Auth rows carry an **empty** `group_required` — signing in is not gated on
  /// a group — so a bare `group_required IN (...)` would drop every sign-in from
  /// the page. CONTEXT rejected a separate auth tab precisely so that
  /// interleaving preserves the question "who signed in right before this
  /// write", which is what makes the extra clause worth having; 05-05 then
  /// renders an explicit auth chip rather than leaving the leg un-controllable.
  ///
  /// The leg keys on `surface = 'auth'` rather than on `group_required = ''`.
  /// 05-02's `isAuthEntry` uses that predicate and three widgets call it; two
  /// definitions of "auth row" that happen to agree today are a defect waiting
  /// for the first row that breaks the coincidence.
  ///
  /// ## Empty selection means no constraint
  ///
  /// With [AuditQuery.groupNames] empty **and** [AuditQuery.includeAuth] false,
  /// no group predicate is emitted at all and every row matches. That is
  /// CONTEXT's locked decision, in its words: *"empty selection = no constraint.
  /// Identical to `AlarmLevelFilterChips`."* It reads backwards on first
  /// encounter — deselecting everything shows everything — which is exactly why
  /// it is written down here rather than left for somebody to "fix".
  ///
  /// The default state is unaffected, because the default is not empty:
  /// [kAuditTrailDefaultGroupNames] names the six non-`operate` groups and the
  /// auth flag is on, so the `operate` exclusion survives the rule intact.
  ///
  /// ## The key prefix and LIKE
  ///
  /// `%` and `_` typed by an operator act as LIKE wildcards. That widens the
  /// match and never narrows it, and it can never reach a row the group filter
  /// excluded, because the prefix clause is `AND`ed with every other one. The
  /// alternative — a hand-rolled `ESCAPE` clause — diverges between SQLite and
  /// Postgres, so this shape was chosen rather than overlooked.
  ///
  /// Every value in every clause reaches the database as a bound variable:
  /// nothing in this file interpolates a value into SQL, so a prefix of
  /// `x' OR 1=1 --` returns rows or no rows and never changes the shape of the
  /// statement.
  /// ## What comes back
  ///
  /// `AuditRecord` — `tfc_access`'s own declaration, the same type
  /// [DriftAuditSink] takes on the write side and the same type the relay
  /// carries — never drift's generated `AuditEntryData`. The store is where the
  /// row stops being a row.
  ///
  /// The generated class carries an `id` and this type does not. That is the
  /// one column deliberately dropped: a row id is a database identity, nothing
  /// above this layer reads one, and the relayed store previously had to invent
  /// an ordinal to fabricate a value for it. The id still does its work inside
  /// the statement below, as the tiebreak in the `ORDER BY`.
  Future<List<AuditRecord>> entries(AuditQuery query) async {
    final statement = _db.select(_db.auditEntry)
      ..where((t) {
        Expression<bool>? predicate;
        void and(Expression<bool> clause) {
          predicate = predicate == null ? clause : predicate! & clause;
        }

        // ## Why these compare as text and not as datetimes
        //
        // The database sets `DriftDatabaseOptions(storeDateTimeAsText: true)`,
        // and drift compares two `Expression<DateTime>` by wrapping both sides
        // in `JULIANDAY(...)` (see `_Comparison.writeInto`) — regardless of
        // dialect. `julianday` is a SQLite function. Postgres does not have it,
        // so the window filter died there with
        //
        //     ERROR: function julianday(text) does not exist
        //
        // and the page reported the trail unavailable on every real station,
        // while every test passed because the tests run on SQLite.
        //
        // `dartCast<String>` changes only the Dart type — drift emits no CAST —
        // so the column is compared as the text it already is, and both engines
        // get a plain `at >= ?`. The bound value is serialised by the database's
        // OWN type mapping rather than a hand-rolled format, so it matches what
        // was written byte for byte.
        //
        // **The constraint this relies on**: ISO-8601 sorts lexicographically
        // only while every row carries the same UTC offset. Drift writes `...Z`
        // for a UTC `DateTime` and `... +hh:mm` for a local one, and those two
        // do not sort against each other. Every row on a station is written by
        // that station, so this holds today; normalising `at` to UTC on write
        // (and migrating existing rows) is what would make it hold by
        // construction rather than by circumstance.
        final atText = t.at.dartCast<String>();
        String asStored(DateTime v) =>
            _db.typeMapping.mapToSqlVariable(v)! as String;

        final window = query.window;
        if (window != null) {
          and(atText.isBiggerOrEqualValue(asStored(window.start)));
          and(atText.isSmallerOrEqualValue(asStored(window.end)));
        }

        final before = query.before;
        if (before != null) {
          and(atText.isSmallerThanValue(asStored(before)));
        }

        if (query.keyPrefix.isNotEmpty) {
          and(t.itemKey.like('${query.keyPrefix}%'));
        }

        final who = query.who;
        if (who != null) {
          and(t.who.equals(who));
        }

        switch (query.outcome) {
          case AuditOutcomeFilter.allowedOnly:
            and(t.allowed.equals(true));
          case AuditOutcomeFilter.deniedOnly:
            and(t.allowed.equals(false));
          case AuditOutcomeFilter.any:
            break;
        }

        final groupLegs = <Expression<bool>>[
          if (query.groupNames.isNotEmpty)
            t.groupRequired.isIn(query.groupNames),
          // ## The ungated leg
          //
          // A write to a key nobody has bound carries an **empty**
          // `group_required` — `GuardedStateMan`'s convention for "not gated
          // on a group" — so it matches no chip's IN clause and, without this
          // leg, is unreachable under every normal chip combination:
          // recorded faithfully and never shown, which reads as "the trail
          // missed it" (hq-skjar, 2026-09-02: a bathroom light toggled all
          // afternoon, five hundred rows, zero on screen).
          //
          // It rides the **operate** chip rather than getting a ninth one,
          // because it is the same volume class the operate exclusion exists
          // for: an unbound light or jog is exactly the four-hundred-rows-an-
          // hour noise the ROADMAP hides by default. The surface clause is
          // what keeps the auth chip meaningful — auth rows also carry an
          // empty `group_required`, and this leg must not resurrect the
          // sign-ins that chip just cleared.
          if (query.groupNames.contains(AccessGroup.operate.name))
            t.groupRequired.equals('') &
                t.surface.equals(_auditAuthSurface).not(),
          if (query.includeAuth) t.surface.equals(_auditAuthSurface),
        ];
        if (groupLegs.isNotEmpty) {
          and(groupLegs.reduce((a, b) => a | b));
        }

        return predicate ?? const Constant(true);
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.at, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(query.limit);

    return (await statement.get()).map(_toRecord).toList();
  }

  /// Drift's generated row onto `tfc_access`'s own record. Every column that
  /// exists on both crosses; nothing is invented and nothing is normalised.
  ///
  /// **The raw constructor, never the named factories.** `AuditRecord.login`
  /// and its siblings mint the surfaces *this* build knows about. A station
  /// running a newer build may have written a surface this one has never heard
  /// of, and it has to come back as it was stored: `groupAuditRows` and
  /// `kKnownAuditSurfaces` both depend on an unfamiliar surface arriving
  /// intact, so that it can be shown as itself rather than quietly folded into
  /// a category that happens to be legible here.
  static AuditRecord _toRecord(AuditEntryData row) => AuditRecord(
        at: row.at,
        who: row.who,
        station: row.station,
        roleName: row.roleName,
        surface: row.surface,
        itemKey: row.itemKey,
        member: row.member,
        oldValue: row.oldValue,
        newValue: row.newValue,
        groupRequired: row.groupRequired,
        allowed: row.allowed,
        origin: row.origin,
        actionId: row.actionId,
        reason: row.reason,
      );

  /// The true number of rows each of [actionIds] produced, counted over the
  /// **whole** table with no filter and no time bound.
  ///
  /// ## Why a second query exists at all
  ///
  /// Filtering happens in SQL, so a group's non-matching siblings are **not in
  /// the result set** — a prefix that matches three of an action's nine rows
  /// returns three rows and no trace of the other six. "3 of 9 members hidden
  /// by filters" therefore cannot be derived from the page, and CONTEXT
  /// requires the page to say it: dropping a parent whose header did not match
  /// silently loses the row the operator filtered for. This is how the number
  /// is obtained.
  ///
  /// ## What it costs
  ///
  /// One extra round trip per page load — not per row — and a scan bounded by
  /// the `IN` list, which is at most [kAuditTrailRowLimit] ids. `action_id` has
  /// no index; that is a deliberate omission recorded in Phase 5's deferred
  /// items, to be revisited only if client-side grouping proves slow.
  ///
  /// The alternative considered and rejected was fetching whole groups for any
  /// action with a matching row. That would blow past the 500-row cap in a way
  /// the operator could not see — the page would silently hold more than it
  /// said it did. Both options are written down so a future reader can reopen
  /// the choice knowing what it was.
  ///
  /// An empty [actionIds] returns an empty map **without issuing a statement**:
  /// Drift's `isIn([])` is not portable, and a page with no rows must not go to
  /// the database to learn it.
  ///
  /// The result names only ids that exist. An unknown id is absent from the map
  /// rather than present with a zero, because zero would be a claim about an
  /// action rather than the absence of one.
  Future<Map<String, int>> memberCountsByAction(Iterable<String> actionIds) async {
    final ids = actionIds.toSet().toList();
    if (ids.isEmpty) return const {};

    final total = _db.auditEntry.id.count();
    final rows = await (_db.selectOnly(_db.auditEntry)
          ..addColumns([_db.auditEntry.actionId, total])
          ..where(_db.auditEntry.actionId.isIn(ids))
          ..groupBy([_db.auditEntry.actionId]))
        .get();

    return {
      for (final row in rows)
        row.read(_db.auditEntry.actionId)!: row.read(total) ?? 0,
    };
  }

  /// Every distinct `who` in the table, sorted ascending, deduplicated.
  ///
  /// **Unbounded on purpose.** The list of people who have ever touched this
  /// station is small, it feeds the `who` dropdown, and a `LIMIT` there would
  /// silently hide the person somebody is looking for — which is the same class
  /// of wrong answer the whole-table search escape exists to prevent.
  ///
  /// The sort is case-sensitive: usernames are identifiers, not prose, and the
  /// column stores what was typed at the login form.
  Future<List<String>> distinctWho() async {
    final rows = await (_db.selectOnly(_db.auditEntry)
          ..addColumns([_db.auditEntry.who])
          ..groupBy([_db.auditEntry.who]))
        .get();

    final names = rows.map((row) => row.read(_db.auditEntry.who)!).toList()
      ..sort();
    return names;
  }
}

/// Element-wise list equality, so the two value types above do not need a
/// `package:collection` import this library otherwise has no use for.
bool _sameStrings(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
