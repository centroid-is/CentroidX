/// The first reader of `config_change`: the windowed read, the join by
/// `action_id`, and the two counts that keep a partial view honest.
///
/// `audit_trail_store.dart` is the shape this copies, deliberately and almost
/// line for line — the two tables answer the same question about different
/// subjects, and a second set of conventions for the second one would be a
/// second thing to keep in step. What is inherited: the two-mode window rule,
/// the `dartCast` datetime comparison, the LIKE-only-widens prefix, the
/// unfiltered `COUNT(*)` companion, and the fact that the object cannot write.
///
/// ## What this reader can and cannot see
///
/// It reads whatever database it is handed. In practice that is Postgres, and
/// Postgres holds `ConfigScope.shared` rows only: a station-scoped change is
/// written to that station's own SQLite and never leaves the machine
/// (`ConfigScope.isShared`). A history view backed by Postgres therefore shows
/// **shared configuration only**, and must say so rather than implying that
/// nobody has ever changed anything locally. That is C-13 and it is a property
/// of the storage split, not a defect in this file.
///
/// ## The gap this file exists to keep visible
///
/// Some entities write no `config_change` rows at all —
/// `historyExempt(kind, id)`: page images, whose id is the hash of their own
/// bytes, and the `server_config_envelope` ciphertext. For those, an empty
/// result means *the log is silent*, which is not the same statement as
/// *nothing happened*. [EntityHistory] carries the difference so a caller
/// cannot render one as the other by accident; see [EntityHistory.isSilent].
library;

import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_history_policy.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/database_drift.dart';

import 'audit_trail_store.dart';

/// The most rows any single change query returns.
///
/// The same number the audit trail uses, and the same reason: the whole-table
/// search escapes the *time* bound and never this one.
const int kConfigChangeRowLimit = kAuditTrailRowLimit;

/// One decoded `config_change` row, with the surrogate id it was stored under.
///
/// ## Why the id is carried alongside the value type
///
/// [ConfigChange] is the value the writer builds and has no id — it describes
/// a change, not a row. Three things here need the row identity anyway:
/// ordering within an action (the id is the order the rows were written in,
/// which is the order an undo has to reverse), de-duplication when the same
/// row arrives through both the windowed read and the per-action join, and
/// 04-07's undo, which has to name the row it is inverting. Reaching for
/// [ConfigChange]'s value equality instead would silently collapse two
/// genuinely distinct rows that happen to hold the same fields.
@immutable
class ConfigChangeRecord {
  const ConfigChangeRecord({required this.id, required this.change});

  /// `config_change.id`. Per-database and never reconciled across backends —
  /// the SQLite log and the Postgres log are two independent id spaces.
  final int id;

  /// The decoded row.
  final ConfigChange change;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigChangeRecord && other.id == id && other.change == change;

  @override
  int get hashCode => Object.hash(id, change);

  @override
  String toString() => 'ConfigChangeRecord(#$id ${change.toString()})';
}

/// One page of the log, as [ConfigChangeStore.changesPage] reads it.
class ConfigChangePage {
  const ConfigChangePage({
    required this.rows,
    required this.rawCount,
    required this.oldestAt,
    required this.oldestId,
  });

  /// The rows this build could decode, newest first.
  final List<ConfigChangeRecord> rows;

  /// How many rows the `LIMIT` returned, decodable or not.
  final int rawCount;

  /// The `at` of the last raw row, or null when there were none.
  final DateTime? oldestAt;

  /// The `id` of the last raw row, or null when there were none.
  final int? oldestId;
}

/// One entity's history, and whether the log is entitled to have one.
///
/// ## The distinction this type exists for
///
/// An empty [rows] has two causes that a bare `List<ConfigChangeRecord>`
/// cannot tell apart:
///
/// - **Nothing happened.** The entity exists and has never been changed since
///   the log started. [historyKept] is true, [isSilent] is false.
/// - **The log is silent about it.** `historyExempt` says this kind or id
///   writes no rows at all, so the log holds no opinion. [historyKept] is
///   false, [isSilent] is true.
///
/// Rendering the second as "no changes" would tell an operator that a page
/// image has never been replaced, which is precisely what the log does not
/// know. Every near-miss in this milestone has been some version of that
/// sentence, which is why the answer is a type rather than a convention.
@immutable
class EntityHistory {
  const EntityHistory({
    required this.kind,
    required this.entityId,
    required this.scope,
    required this.rows,
    required this.historyKept,
  });

  /// The entity asked about.
  final ConfigKind kind;
  final String entityId;
  final ConfigScope scope;

  /// The rows found, newest first. Always empty when [historyKept] is false.
  final List<ConfigChangeRecord> rows;

  /// Whether this entity writes change rows at all.
  final bool historyKept;

  /// True when the absence of rows is the log's silence rather than a fact
  /// about the entity.
  bool get isSilent => !historyKept;
}

/// What the history view's filter controls hold, as one value.
///
/// A near-copy of [AuditTrailFilters], with the fields the two tables do not
/// share swapped: `item_key` becomes `entity_id`, the group chips become kind
/// chips, and a scope selection is added because the same preference name
/// exists once per station and once shared.
@immutable
class ConfigHistoryFilters {
  const ConfigHistoryFilters({
    this.entityPrefix = '',
    this.who,
    this.kinds = const [],
    this.scopeWireNames = const [],
    this.range,
  });

  /// Matched against `entity_id` as a prefix. Empty means no constraint.
  final String entityPrefix;

  /// An exact `who`. Null means everybody.
  final String? who;

  /// The selected kinds.
  ///
  /// **Empty means no kind constraint at all**, exactly as the audit trail's
  /// group chips behave and as `AlarmLevelFilterChips` behaves. It reads
  /// backwards on first encounter, and it is the settled convention on this
  /// page's neighbours.
  ///
  /// Nothing here consults `kSharedConfigKinds`. That set says what the
  /// **sync** propagates between stations; `ConfigKind.preference` is
  /// deliberately outside it, so a read scoped by intersecting with it would
  /// return nothing at all for every preference change anybody ever made —
  /// silently, and only for the one kind an operator is most likely to ask
  /// about.
  final List<ConfigKind> kinds;

  /// The selected scopes, in wire form (`shared`, `station:st101`). Empty
  /// means no scope constraint.
  final List<String> scopeWireNames;

  /// An explicitly chosen window. Null means [toQuery] decides.
  final AuditWindow? range;

  /// True once the operator has asked a question about an entity or a person.
  ///
  /// What flips [toQuery] into whole-table mode. A whitespace-only
  /// [entityPrefix] does not count.
  bool get isSearching => entityPrefix.trim().isNotEmpty || who != null;

  /// True of the value a freshly opened page holds.
  bool get isDefault =>
      entityPrefix.trim().isEmpty &&
      who == null &&
      kinds.isEmpty &&
      scopeWireNames.isEmpty &&
      range == null;

  /// The default filters.
  ConfigHistoryFilters cleared() => const ConfigHistoryFilters();

  /// A copy with only the named fields replaced. [who] and [range] get
  /// companion clear flags, because passing null cannot be told from omitting
  /// the argument.
  ConfigHistoryFilters copyWith({
    String? entityPrefix,
    String? who,
    bool clearWho = false,
    List<ConfigKind>? kinds,
    List<String>? scopeWireNames,
    AuditWindow? range,
    bool clearRange = false,
  }) =>
      ConfigHistoryFilters(
        entityPrefix: entityPrefix ?? this.entityPrefix,
        who: clearWho ? null : (who ?? this.who),
        kinds: kinds ?? this.kinds,
        scopeWireNames: scopeWireNames ?? this.scopeWireNames,
        range: clearRange ? null : (range ?? this.range),
      );

  /// The statement these filters describe, as of [now].
  ///
  /// The two-mode rule, unchanged from [AuditTrailFilters.toQuery] and for the
  /// same user ruling: an explicit [range] wins; otherwise a search drops the
  /// time bound entirely, because "has anyone **ever** changed this asset" is
  /// a different question from "did anyone this week" and a search confined to
  /// the loaded window is a wrong answer that looks like a right one;
  /// otherwise seven days back from [now].
  ConfigChangeQuery toQuery(
      {required DateTime now, DateTime? before, int? beforeId}) {
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

    return ConfigChangeQuery(
      window: window,
      before: before,
      beforeId: beforeId,
      entityPrefix: entityPrefix,
      who: who,
      kinds: kinds,
      scopeWireNames: scopeWireNames,
      limit: kConfigChangeRowLimit,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigHistoryFilters &&
          other.entityPrefix == entityPrefix &&
          other.who == who &&
          other.range == range &&
          _sameStrings(other.scopeWireNames, scopeWireNames) &&
          _sameKinds(other.kinds, kinds);

  @override
  int get hashCode => Object.hash(entityPrefix, who, range,
      Object.hashAll(scopeWireNames), Object.hashAll(kinds));

  @override
  String toString() => 'ConfigHistoryFilters(entity: "$entityPrefix", '
      'who: $who, kinds: ${kinds.map((k) => k.wireName)}, '
      'scopes: $scopeWireNames, range: $range)';
}

/// One resolved query: everything [ConfigChangeStore.changes] needs and
/// nothing it has to decide.
///
/// A value type with full equality, because the providers key a family on it.
/// A family keyed on a broken `==` re-queries the database on every rebuild.
@immutable
class ConfigChangeQuery {
  ConfigChangeQuery({
    this.window,
    this.before,
    this.beforeId,
    String entityPrefix = '',
    this.who,
    Iterable<ConfigKind> kinds = const [],
    Iterable<String> scopeWireNames = const [],
    this.limit = kConfigChangeRowLimit,
  })  : entityPrefix = entityPrefix.trim(),
        kinds = List.unmodifiable(
            kinds.toSet().toList()..sort((a, b) => a.index.compareTo(b.index))),
        scopeWireNames =
            List.unmodifiable(scopeWireNames.toSet().toList()..sort());

  /// The time bound, or null for **the whole table** — the search escape.
  final AuditWindow? window;

  /// The "Load more" cursor: rows older than this — strictly, unless
  /// [beforeId] is given.
  final DateTime? before;

  /// The other half of the cursor: with [before], rows *at* that instant with
  /// a smaller id are included too.
  ///
  /// One `ConfigStore.writeItems` stamps every change row of an action with
  /// one `at`, so a nine-asset save is nine rows at one instant. A cursor on
  /// `at` alone, strict, cannot land inside such a group: the rows past the
  /// cap that share the cap row's `at` are excluded by the strict comparison
  /// on every page after, and can never be reached — while the action still
  /// renders with a "hidden by filters" note that blames the wrong thing.
  /// `(at, id)` is a total order over the log, so the cursor can stand
  /// anywhere in it.
  final int? beforeId;

  /// Trimmed. Empty means no entity constraint.
  final String entityPrefix;

  /// Exact match on `who`, or null.
  final String? who;

  /// Sorted by declaration order and duplicate-free, so equality does not
  /// depend on chip tap order. Empty means no kind constraint.
  final List<ConfigKind> kinds;

  /// Sorted and duplicate-free. Empty means no scope constraint.
  final List<String> scopeWireNames;

  /// Applied after every `WHERE` clause, never instead of one.
  final int limit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigChangeQuery &&
          other.window == window &&
          other.before == before &&
          other.beforeId == beforeId &&
          other.entityPrefix == entityPrefix &&
          other.who == who &&
          other.limit == limit &&
          _sameKinds(other.kinds, kinds) &&
          _sameStrings(other.scopeWireNames, scopeWireNames);

  @override
  int get hashCode => Object.hash(window, before, beforeId, entityPrefix, who,
      limit, Object.hashAll(kinds), Object.hashAll(scopeWireNames));

  @override
  String toString() => 'ConfigChangeQuery(window: ${window ?? "whole table"}, '
      'before: $before/$beforeId, entity: "$entityPrefix", who: $who, '
      'kinds: ${kinds.map((k) => k.wireName)}, scopes: $scopeWireNames, '
      'limit: $limit)';
}

/// Reads of `config_change`, and nothing else.
///
/// Ungated and unaudited, on the same precedent [AuditTrailStore] states for
/// its own reads: looking at the history is not a configuration change, and a
/// row per render would bury the writes that matter under rows recording that
/// somebody looked. The enforcement is the route gate.
///
/// **This object cannot write.** It takes no session, no sink and no station.
/// It has no insert, no modify and no remove. The log's append-only property
/// is enforced by there being nowhere to write it from, and a source-text test
/// in `test/core/config_change_store_test.dart` keeps that trivially checkable
/// rather than merely true today. That matters more here than it does for the
/// audit trail: `config_change` is on `kRetentionExemptTables`, so a bad row
/// written through this object would never be swept.
class ConfigChangeStore {
  ConfigChangeStore({required AppDatabase db, Logger? logger})
      : _db = db,
        _logger = logger ?? Logger();

  final AppDatabase _db;

  /// Held for the diagnostics a future failure path will want; nothing here
  /// swallows an error, so nothing here logs one yet.
  // ignore: unused_field
  final Logger _logger;

  /// The change rows of each of [actionIds], keyed by action, ordered by `id`
  /// ascending within an action.
  ///
  /// ## Why ascending, when everything else here is newest-first
  ///
  /// Within one action the id order is the order the writer produced the rows
  /// in, and an undo has to reverse them in that order. The *actions* are
  /// newest-first; the rows *inside* one are in the order they happened. Two
  /// different questions, two different orders, both deliberate.
  ///
  /// Uses `idx_config_change_action`. An empty [actionIds] returns an empty
  /// map **without issuing a statement**: drift's `isIn([])` is not portable,
  /// and a page with no rows must not go to the database to learn it.
  ///
  /// An action nobody wrote is absent from the map rather than present with an
  /// empty list — an empty list would be a claim about the action rather than
  /// the absence of one.
  ///
  /// A row this build cannot decode is skipped rather than fatal, so an action
  /// is still readable on a station running an older build than the one that
  /// wrote it; [changeCountsByAction] still counts it, so it reads as a hidden
  /// sibling instead of vanishing.
  Future<Map<String, List<ConfigChangeRecord>>> changesByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toSet().toList();
    if (ids.isEmpty) return const {};

    final statement = _db.select(_db.configChangeTable)
      ..where((t) => t.actionId.isIn(ids))
      ..orderBy([(t) => OrderingTerm(expression: t.id)]);

    final byAction = <String, List<ConfigChangeRecord>>{};
    for (final row in await statement.get()) {
      final record = _decode(row);
      if (record == null) continue;
      byAction
          .putIfAbsent(row.actionId, () => <ConfigChangeRecord>[])
          .add(record);
    }
    return byAction;
  }

  /// The newest rows matching [query], newest first, at most
  /// [ConfigChangeQuery.limit] of them.
  ///
  /// One statement. Every filter is a `WHERE` clause applied **before** the
  /// `LIMIT`, so a count is a count of the table's rows and not of the loaded
  /// page's.
  ///
  /// Ties on `at` resolve by `id DESC`. A page save writes one row per changed
  /// entity at the same instant, so without the tiebreak two runs of the same
  /// query could return them in different orders and the page would reshuffle
  /// under the operator.
  ///
  /// ## Why this read exists beside [changesByAction]
  ///
  /// It is what surfaces an action whose `audit_entry` row is missing. The
  /// store commits its rows and writes the audit row afterwards, so a crash
  /// between the two leaves change rows on an `action_id` with no header. A
  /// view driven from the audit side would never ask about that action and
  /// would show nothing at all for the thing a reader most needs to see.
  ///
  /// ## The entity prefix and LIKE
  ///
  /// `%` and `_` typed by an operator act as LIKE wildcards. That widens the
  /// match and never narrows it, and it can never reach a row another filter
  /// excluded, because the prefix clause is `AND`ed with every other one. The
  /// alternative — a hand-rolled `ESCAPE` clause — diverges between SQLite and
  /// Postgres, so this shape was chosen rather than overlooked. Every value in
  /// every clause reaches the database as a bound variable.
  Future<List<ConfigChangeRecord>> changes(ConfigChangeQuery query) async =>
      (await changesPage(query)).rows;

  /// [changes], with what the page needs and the decoded list cannot say.
  ///
  /// [ConfigChangePage.rawCount] is how many rows the `LIMIT` returned
  /// **before** decoding, and [ConfigChangePage.oldestAt] /
  /// [ConfigChangePage.oldestId] name the last raw row. Both matter on a
  /// mixed-version site: a row written by a newer build is skipped by
  /// [_decode], and a page that judged "reached the cap" or "the cursor" by
  /// the decoded list would hide the Load-more control, and the rows behind
  /// it, on the strength of one row it could not read.
  Future<ConfigChangePage> changesPage(ConfigChangeQuery query) async {
    final statement = _db.select(_db.configChangeTable)
      ..where((t) {
        Expression<bool>? predicate;
        void and(Expression<bool> clause) {
          predicate = predicate == null ? clause : predicate! & clause;
        }

        // ## Why these compare as text and not as datetimes
        //
        // `DriftDatabaseOptions(storeDateTimeAsText: true)` is set, and drift
        // compares two `Expression<DateTime>` by wrapping both sides in
        // `JULIANDAY(...)` regardless of dialect. `julianday` is a SQLite
        // function; Postgres does not have it, and the audit trail's window
        // filter died there with `function julianday(text) does not exist`
        // while every test passed, because the tests run on SQLite.
        //
        // `dartCast<String>` changes only the Dart type — drift emits no CAST
        // — so the column is compared as the text it already is. The bound
        // value is serialised by the database's OWN type mapping rather than
        // a hand-rolled format, so it matches what was written byte for byte.
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
          final beforeId = query.beforeId;
          final olderInstant = atText.isSmallerThanValue(asStored(before));
          // The `(at, id)` total order: strictly older instants, plus the
          // rows at the cursor's own instant that were written before it.
          and(beforeId == null
              ? olderInstant
              : olderInstant |
                  (atText.equals(asStored(before)) &
                      t.id.isSmallerThanValue(beforeId)));
        }

        if (query.entityPrefix.isNotEmpty) {
          and(t.entityId.like('${query.entityPrefix}%'));
        }

        final who = query.who;
        if (who != null) {
          and(t.who.equals(who));
        }

        if (query.kinds.isNotEmpty) {
          and(t.kind.isIn([for (final kind in query.kinds) kind.wireName]));
        }

        if (query.scopeWireNames.isNotEmpty) {
          and(t.scope.isIn(query.scopeWireNames));
        }

        return predicate ?? const Constant(true);
      })
      ..orderBy([
        (t) => OrderingTerm(expression: t.at, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(query.limit);

    final raw = await statement.get();
    return ConfigChangePage(
      rows: [
        for (final row in raw)
          if (_decode(row) case final record?) record,
      ],
      rawCount: raw.length,
      oldestAt: raw.isEmpty ? null : raw.last.at,
      oldestId: raw.isEmpty ? null : raw.last.id,
    );
  }

  /// The true number of rows each of [actionIds] produced, counted over the
  /// **whole** table with no filter and no time bound.
  ///
  /// ## Why a second query exists at all
  ///
  /// Filtering happens in SQL, so an action's non-matching rows are **not in
  /// the result set** — a prefix that matches one of a page save's nine rows
  /// returns one row and no trace of the other eight. "1 of 9 changes hidden
  /// by filters" therefore cannot be derived from the page, and presenting the
  /// one as the whole save would be a partial view claiming to be complete.
  ///
  /// It also counts rows this build could not decode, which is the point: an
  /// undecodable row must read as a hidden sibling rather than disappear.
  ///
  /// An empty [actionIds] returns an empty map without issuing a statement.
  /// An unknown id is absent from the map rather than present with a zero.
  Future<Map<String, int>> changeCountsByAction(
      Iterable<String> actionIds) async {
    final ids = actionIds.toSet().toList();
    if (ids.isEmpty) return const {};

    final total = _db.configChangeTable.id.count();
    final rows = await (_db.selectOnly(_db.configChangeTable)
          ..addColumns([_db.configChangeTable.actionId, total])
          ..where(_db.configChangeTable.actionId.isIn(ids))
          ..groupBy([_db.configChangeTable.actionId]))
        .get();

    return {
      for (final row in rows)
        row.read(_db.configChangeTable.actionId)!: row.read(total) ?? 0,
    };
  }

  /// One entity's own history, newest first, and whether the log keeps one.
  ///
  /// Uses `idx_config_change_entity` — `(kind, entity_id, scope, id)`, which
  /// is this query in column order. Scope is part of the identity, so a
  /// station's own `theme` and the shared one of the same name are two
  /// histories rather than one interleaved and unreadable one.
  ///
  /// **The exempt case does not go to the database.** `historyExempt` already
  /// knows the answer is empty, and issuing the statement anyway would produce
  /// the same empty list with none of the reason attached. See
  /// [EntityHistory.isSilent].
  Future<EntityHistory> entityHistory({
    required ConfigKind kind,
    required String entityId,
    required ConfigScope scope,
    int limit = kConfigChangeRowLimit,
  }) async {
    if (historyExempt(kind, entityId)) {
      return EntityHistory(
        kind: kind,
        entityId: entityId,
        scope: scope,
        rows: const [],
        historyKept: false,
      );
    }

    final statement = _db.select(_db.configChangeTable)
      ..where((t) =>
          t.kind.equals(kind.wireName) &
          t.entityId.equals(entityId) &
          t.scope.equals(scope.wireName))
      ..orderBy([
        (t) => OrderingTerm(expression: t.at, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
      ])
      ..limit(limit);

    return EntityHistory(
      kind: kind,
      entityId: entityId,
      scope: scope,
      rows: [
        for (final row in await statement.get())
          if (_decode(row) case final record?) record,
      ],
      historyKept: true,
    );
  }

  /// One stored row as a [ConfigChangeRecord], or null when this build cannot
  /// read it.
  ///
  /// Three wire names have to resolve — kind, scope and op — and each of the
  /// three answers null for a value this build has never heard of. That is the
  /// documented forward-compatibility rule on all three: several stations
  /// share one database, and a station running an older build must be able to
  /// skip a newer one's row rather than fail the whole read on it.
  ///
  /// Skipping is a real cost — the row exists and is not shown — which is why
  /// [changeCountsByAction] counts it anyway. The row is reported as hidden,
  /// which is a true statement, rather than omitted, which would be a false
  /// one.
  ConfigChangeRecord? _decode(ConfigChangeRow row) {
    final kind = ConfigKind.byWireName(row.kind);
    final scope = ConfigScope.byWireName(row.scope);
    final op = ConfigChangeOp.byWireName(row.op);
    if (kind == null || scope == null || op == null) return null;

    return ConfigChangeRecord(
      id: row.id,
      change: ConfigChange(
        at: row.at,
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
}

/// Element-wise list equality for the two value types above.
bool _sameStrings(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameKinds(List<ConfigKind> a, List<ConfigKind> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
