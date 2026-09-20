/// `config_change` over the wire — the configuration history a relayed panel
/// reads instead of the database it has no connection to.
///
/// ## Why this family exists
///
/// The history page reads `configChangeStoreProvider`, which reads
/// `databaseProvider`, which answers **null** on a gateway panel by design.
/// The page's own copy was honest about it — "the history is not reachable
/// over the relay" rather than "no changes" — but honest about a hole is
/// still a hole, and the backend's rows were unreachable from every relayed
/// panel on the plant.
///
/// ## Why the query and the row are the wire's own types
///
/// `ConfigChangeQuery`, `ConfigChange` and `ConfigChangeRecord` live in the
/// app and in `tfc_dart`, which sit **above** this package: it cannot import
/// them and must not try. The same split `AuditQueryParams` is on the other
/// side of, for the same reason and with the same consequence — the mapping
/// is written once at each end and nowhere else.
///
/// `ConfigKind`, `ConfigScope` and `ConfigChangeOp` travel as their
/// `wireName` strings, which is not a second spelling of those enums: the
/// `wireName` IS the stored spelling, the one `config_change.kind` already
/// holds, so the wire carries the column rather than a translation of it. A
/// kind this build has never heard of therefore arrives intact and is decoded
/// — or skipped — by the panel exactly as the station's own reader would skip
/// it.
///
/// ## One bad row costs one row
///
/// [ConfigChangePageResult] carries `rawCount`, `oldestAtUs` and `oldestId`
/// beside the decoded rows, because the page judges "reached the cap" and
/// "where the next page starts" from the RAW read. A mixed-version site where
/// one row is undecodable must not lose the Load-more control, and the rows
/// behind it, on the strength of that row. The direct store makes exactly
/// this distinction; dropping it on the wire would reintroduce the defect
/// this shape exists to prevent.
library;

/// The most rows one page of history carries.
///
/// The same number the direct reader uses (`kConfigChangeRowLimit`), spelled
/// again here because this package cannot see that one and a wire that
/// silently disagreed with the store would cap a page without saying so.
const int kConfigHistoryWireRowLimit = 500;

/// The protocol shape of a `ConfigChangeQuery`.
///
/// Every field is a value the far end validates. There is no statement, no
/// expression and no filter string: a client cannot ask this family for a
/// column that is not already on a change row.
final class ConfigHistoryQueryParams {
  const ConfigHistoryQueryParams({
    this.startMs,
    this.endMs,
    this.beforeUs,
    this.beforeId,
    this.entityPrefix = '',
    this.who,
    this.kindWireNames = const <String>[],
    this.scopeWireNames = const <String>[],
    this.limit = kConfigHistoryWireRowLimit,
  }) : assert((startMs == null) == (endMs == null),
            'a half-open window is not a window: both bounds or neither');

  /// Inclusive lower bound, epoch milliseconds UTC. Null with [endMs] means
  /// **the whole table** — the search escape the history page shares with the
  /// audit trail.
  final int? startMs;

  /// Inclusive upper bound, epoch milliseconds UTC.
  final int? endMs;

  /// The "Load more" cursor's instant, in **microseconds** — not
  /// milliseconds, and that is the whole of what makes paging work.
  ///
  /// `config_change.at` is stamped by `DateTime.now()`, which carries
  /// microseconds, and the store's `(at, id)` cursor has an EQUALITY half:
  /// rows *at* the cursor's instant with a smaller id are included, because
  /// one `writeItems` stamps every row of an action with one `at` and a
  /// strict comparison can never land inside such a group. A cursor rounded
  /// to milliseconds is never equal to the row it came from, so that half is
  /// dead and Load-more returns the same page forever.
  ///
  /// Measured, not feared: with a millisecond cursor, three successive pages
  /// of a six-row log came back as the same two rows.
  final int? beforeUs;

  /// The cursor's other half. With [beforeUs], rows AT that instant with a
  /// smaller id are included too.
  ///
  /// Not decoration, and the reason is in `ConfigChangeQuery.beforeId`: one
  /// `writeItems` stamps every row of an action with one `at`, so a nine-asset
  /// save is nine rows at one instant and a cursor on the instant alone can
  /// never land inside the group.
  final int? beforeId;

  /// Matched against `entity_id` as a prefix. Empty means no constraint.
  final String entityPrefix;

  /// Exact match on `who`, or null for everybody.
  final String? who;

  /// Selected `config_change.kind` values, as stored. Empty means no kind
  /// constraint at all — the semantics the audit trail's group chips and
  /// `AlarmLevelFilterChips` already set.
  final List<String> kindWireNames;

  /// Selected `config_change.scope` values, as stored (`shared`,
  /// `station:st101`). Empty means no scope constraint.
  final List<String> scopeWireNames;

  /// Applied after every filter, never instead of one.
  final int limit;

  Map<String, Object?> toJson() => <String, Object?>{
        if (startMs != null) 'startMs': startMs,
        if (endMs != null) 'endMs': endMs,
        if (beforeUs != null) 'beforeUs': beforeUs,
        if (beforeId != null) 'beforeId': beforeId,
        'entityPrefix': entityPrefix,
        if (who != null) 'who': who,
        'kindWireNames': kindWireNames,
        'scopeWireNames': scopeWireNames,
        'limit': limit,
      };

  static ConfigHistoryQueryParams fromJson(Map<String, Object?> json) =>
      ConfigHistoryQueryParams(
        startMs: json['startMs'] as int?,
        endMs: json['endMs'] as int?,
        beforeUs: json['beforeUs'] as int?,
        beforeId: json['beforeId'] as int?,
        entityPrefix: (json['entityPrefix'] as String?) ?? '',
        who: json['who'] as String?,
        kindWireNames: _strings(json['kindWireNames']),
        scopeWireNames: _strings(json['scopeWireNames']),
        limit: (json['limit'] as int?) ?? kConfigHistoryWireRowLimit,
      );

  @override
  String toString() => 'ConfigHistoryQueryParams(window: '
      '${startMs == null ? "whole table" : "$startMs..$endMs"}, '
      'before: $beforeUs/$beforeId, entity: "$entityPrefix", who: $who, '
      'kinds: $kindWireNames, scopes: $scopeWireNames, limit: $limit)';
}

/// One `config_change` row on the wire: the surrogate id, and the columns.
///
/// Flat, and deliberately so. The app's `ConfigChangeRecord` wraps a decoded
/// `ConfigChange`; this carries the columns the row was stored as, so a row
/// whose `kind` or `op` this build does not know still crosses intact and is
/// judged at the end that has the vocabulary to judge it.
final class ConfigHistoryRow {
  const ConfigHistoryRow({
    required this.id,
    required this.atMs,
    required this.actionId,
    required this.who,
    required this.station,
    required this.roleName,
    required this.kind,
    required this.entityId,
    required this.scope,
    required this.op,
    this.oldValue,
    this.newValue,
    this.reason,
  });

  /// `config_change.id` — per-database, never reconciled across backends.
  ///
  /// Carried because three things need the row identity: ordering within an
  /// action (the order an undo must reverse), de-duplication between the
  /// windowed read and the per-action join, and naming the row an undo
  /// inverts.
  final int id;

  final int atMs;
  final String actionId;
  final String who;
  final String station;
  final String roleName;

  /// `ConfigKind.wireName`, as stored.
  final String kind;

  final String entityId;

  /// `ConfigScope`'s wire form, as stored: `shared`, or `station:<name>`.
  final String scope;

  /// `ConfigChangeOp.wireName`, as stored.
  final String op;

  final String? oldValue;
  final String? newValue;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'atMs': atMs,
        'actionId': actionId,
        'who': who,
        'station': station,
        'roleName': roleName,
        'kind': kind,
        'entityId': entityId,
        'scope': scope,
        'op': op,
        if (oldValue != null) 'oldValue': oldValue,
        if (newValue != null) 'newValue': newValue,
        if (reason != null) 'reason': reason,
      };

  static ConfigHistoryRow fromJson(Map<String, Object?> json) =>
      ConfigHistoryRow(
        id: json['id'] as int,
        atMs: json['atMs'] as int,
        actionId: json['actionId'] as String,
        who: json['who'] as String,
        station: json['station'] as String,
        roleName: json['roleName'] as String,
        kind: json['kind'] as String,
        entityId: json['entityId'] as String,
        scope: json['scope'] as String,
        op: json['op'] as String,
        oldValue: json['oldValue'] as String?,
        newValue: json['newValue'] as String?,
        reason: json['reason'] as String?,
      );

  @override
  String toString() => 'ConfigHistoryRow(#$id $op $kind/$entityId by $who)';
}

/// One page of the log, with what the decoded list cannot say.
final class ConfigHistoryPageResult {
  const ConfigHistoryPageResult({
    required this.rows,
    required this.rawCount,
    this.oldestAtUs,
    this.oldestId,
    this.hasMore = false,
  });

  /// The rows, newest first.
  final List<ConfigHistoryRow> rows;

  /// How many rows the `LIMIT` returned **before** anything was decoded.
  ///
  /// The page judges "reached the cap" from this and never from
  /// `rows.length`: one undecodable row would otherwise hide the Load-more
  /// control and everything behind it.
  final int rawCount;

  /// The `at` of the last RAW row, in **microseconds**, or null when there
  /// were none.
  ///
  /// Microseconds for [ConfigHistoryQueryParams.beforeUs]' reason: this value
  /// comes straight back as the next page's cursor, and a rounded instant
  /// cannot be equal to the row that produced it.
  final int? oldestAtUs;

  /// The `id` of the last RAW row, or null when there were none.
  final int? oldestId;

  /// Whether at least one matching row lies beyond this page.
  final bool hasMore;

  Map<String, Object?> toJson() => <String, Object?>{
        'rows': [for (final row in rows) row.toJson()],
        'rawCount': rawCount,
        if (oldestAtUs != null) 'oldestAtUs': oldestAtUs,
        if (oldestId != null) 'oldestId': oldestId,
        'hasMore': hasMore,
      };

  static ConfigHistoryPageResult fromJson(Map<String, Object?> json) =>
      ConfigHistoryPageResult(
        rows: <ConfigHistoryRow>[
          for (final row in (json['rows'] as List<Object?>? ?? const []))
            ConfigHistoryRow.fromJson((row as Map).cast<String, Object?>()),
        ],
        rawCount: (json['rawCount'] as int?) ?? 0,
        oldestAtUs: json['oldestAtUs'] as int?,
        oldestId: json['oldestId'] as int?,
        hasMore: (json['hasMore'] as bool?) ?? false,
      );
}

/// Reads of `config_change`. **No write member exists here, deliberately.**
///
/// The log is written by whoever changed the configuration, through
/// `ConfigStore`; a client-supplied history row would be a forgery surface of
/// exactly the kind [AuditApi] refuses for the same reason. Undo is not an
/// exception to that rule — it writes new configuration, and new rows follow
/// from the write, so it belongs to the config-store family rather than here.
abstract interface class ConfigHistoryApi {
  /// One page of the log matching [query], newest first.
  Future<ConfigHistoryPageResult> changesPage(ConfigHistoryQueryParams query);

  /// The rows of each of [actionIds], keyed by action, **ascending by id
  /// within an action**.
  ///
  /// Two different orders in one family and both are deliberate: the actions
  /// are newest-first because that is how they are read, and the rows inside
  /// one are in the order they were written because that is the order an undo
  /// has to reverse.
  ///
  /// An action nobody wrote is **absent** from the map rather than present
  /// with an empty list — an empty list would be a claim about the action
  /// rather than the absence of one.
  Future<Map<String, List<ConfigHistoryRow>>> changesByAction(
      List<String> actionIds);

  /// How many rows each of [actionIds] produced, counted **unfiltered**.
  ///
  /// The companion that keeps a partial view honest: the rows a filter
  /// excluded are not in the page at all, so "3 of 9 changes hidden" cannot
  /// be derived from what came back. This is where the 9 comes from.
  Future<Map<String, int>> changeCountsByAction(List<String> actionIds);
}

List<String> _strings(Object? value) => <String>[
      for (final item in (value as List<Object?>? ?? const <Object?>[]))
        if (item is String) item,
    ];
