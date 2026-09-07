/// The invariant `config_item` gave up foreign keys for, made checkable.
///
/// One generic table with a `parent_id` that is deliberately **not** a
/// `REFERENCES` (see [ConfigItem.parentId]) and a change log joined to it by
/// value rather than by constraint (see `ConfigChangeTable.entityId`) buys two
/// things the design needs — an asset that outlives its page during a move,
/// and a delete whose own log entry is storable. What it gives up is the
/// database refusing to store a contradiction. This file is what replaces that
/// refusal: the contradictions are still impossible to *write* through
/// `ConfigStore`, and this is how anyone can tell whether something else did.
///
/// ## The three invariants
///
/// 1. Every `parent_id` resolves to an existing row. Cheap and worth having on
///    its own: it is what a botched undo ordering (children restored before
///    their page) and a page rename that missed its assets both look like.
/// 2. For every row, the newest `config_change` for `(kind, id, scope)` has
///    `op != 'delete'` and its `new_value` **equals that row's
///    [ConfigItem.encodeEntity]**.
/// 3. For every entity whose newest change is a delete, no row exists.
///
/// ## Why invariant 2 is not a payload comparison
///
/// A change row does not store the payload. It stores the *entity* —
/// `{parent_id, sort_index, payload}` — and the two fields wrapped around the
/// payload are the whole reason [ConfigItem.encodeEntity] exists: moving an
/// asset to another page or changing its paint order alters neither the
/// payload nor anything else, so a check that unwrapped to `.payload` before
/// comparing would call a row whose recorded *position* is wrong perfectly
/// clean, and a restore from that history would put the asset back on the
/// wrong page. The comparison here is therefore over the full entity string on
/// both sides. `config_consistency_test.dart` plants a `sort_index`-only and a
/// `parent_id`-only divergence for exactly that reason: they are the two
/// violations the tempting simplification cannot see.
///
/// It is [samePayload] and not `==` that does the comparing, because "the same
/// configuration" is a structural question. [canonicalJson] makes a textual
/// comparison nearly right on the way in, but a row written before it existed
/// encodes the same entity in another key order, and reporting that as
/// corruption would bury the real findings.
///
/// ## Newest means last written, not latest `at`
///
/// Several stations write this log and their clocks disagree — the reason
/// `rev` is a counter rather than a timestamp. So "the newest change" is the
/// highest `config_change.id`: rows are append-only and the id is assigned in
/// arrival order at the database being read. Ordering by `at` instead would
/// let one station's skewed clock invent a violation on another station's
/// write.
///
/// (That is a different question from the one `key_mapping_rows.dart` warns
/// about. A `SERIAL` is unusable as a *watermark* because a transaction can
/// commit after one that took a later id, so a reader advancing past it skips
/// it forever. Here nothing advances: the check reads one committed snapshot
/// and asks which of the rows in it is last. Within a snapshot the id order is
/// the write order.)
///
/// ## History-exempt entities are checked the other way round
///
/// Page images and the `server_config_envelope` write no change rows at all
/// (`config_history_policy.dart`). Invariants 2 and 3 do not apply to them —
/// but their exemption does, and it is asserted rather than assumed: an exempt
/// entity with *any* change row is reported. That is how the rule is known to
/// have held in the plant rather than trusted because the three writers in
/// this package ask before they insert. A base64 blob written into a table
/// nothing prunes cannot be taken back, so the check has to be able to say it
/// did not happen.
///
/// ## Where this runs
///
/// Three places, and the third is the point. A unit suite plants violations; a
/// Postgres integration test drives real writes through `ConfigStore` and
/// asserts silence; and `check_config_consistency` in `tfc_mcp_server` points
/// the same function at the plant's database. The corruption described above
/// happens over months on a live system, so a check that only ever ran in CI
/// would be proving the invariant over data the test itself had just written.
///
/// ## [GeneratedDatabase], and reads only
///
/// Same arrangement as `page_rows.dart` and `key_mapping_rows.dart`: drift's
/// generated table classes take their database as a constructor argument, so
/// both tables attach to whatever database is handed over — `AppDatabase`,
/// which declares them, or `ServerDatabase`, which does not. Ordinary drift
/// builders throughout, so there is no `?`-versus-`$1` branch to keep in step
/// with the two backends. Nothing here writes; a check that repaired what it
/// found would destroy the evidence of how it got there.
library;

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import 'config_change.dart';
import 'config_history_policy.dart';
import 'config_item.dart';
import 'config_item_table.dart';

/// Which rule a [ConfigInconsistency] breaks.
///
/// The wire names appear in MCP output and in test expectations, so they are
/// as stable as the rules they name.
enum ConfigInvariant {
  /// A row names a `parent_id` no row has as its id.
  orphanedParent('orphaned_parent'),

  /// A row the change log has never heard of — the shape a write path that
  /// stored the item and skipped the log leaves behind.
  missingHistory('missing_history'),

  /// The newest change for the entity disagrees with the row: a different
  /// payload, a different parent, or a different position.
  entityDisagrees('entity_disagrees'),

  /// The newest change says the entity was deleted, and yet here is its row.
  deletedButPresent('deleted_but_present'),

  /// A history-exempt entity has change rows, which it must never have.
  exemptHasHistory('exempt_has_history');

  const ConfigInvariant(this.wireName);

  /// The string reported for this rule.
  final String wireName;
}

/// One way the configuration contradicts its own history.
///
/// [kindName] and [scopeName] are the raw column values rather than the parsed
/// [ConfigKind] and [ConfigScope]: a row written by a newer station carries a
/// kind this build has never heard of, and a finding about it must still be
/// reportable rather than unrepresentable.
@immutable
class ConfigInconsistency {
  const ConfigInconsistency({
    required this.invariant,
    required this.kindName,
    required this.entityId,
    required this.scopeName,
    required this.summary,
    this.expected,
    this.found,
  });

  /// The rule that is broken.
  final ConfigInvariant invariant;

  /// `config_item.kind` / `config_change.kind` as stored.
  final String kindName;

  /// The entity's id.
  final String entityId;

  /// The scope as stored — `shared` or `station:<hostname>`.
  final String scopeName;

  /// One line an engineer can act on.
  final String summary;

  /// What the row says, where the finding is a disagreement between two
  /// sides. The entity string, never the bare payload.
  final String? expected;

  /// What the history says — or, for [ConfigInvariant.orphanedParent], the
  /// parent id that does not resolve.
  final String? found;

  /// The finding as JSON, for a tool handing the list on.
  Map<String, Object?> toJson() => {
        'invariant': invariant.wireName,
        'kind': kindName,
        'entity_id': entityId,
        'scope': scopeName,
        'summary': summary,
        'expected': expected,
        'found': found,
      };

  @override
  String toString() =>
      '${invariant.wireName}: $kindName $entityId@$scopeName — $summary';
}

/// Every way [db]'s configuration contradicts its own history, or an empty
/// list.
///
/// See the library header for the invariants and for why the comparison is
/// over the whole entity. Ordered by kind, then id, then scope, then rule, so
/// two runs of this against the same database diff cleanly and a run against
/// the plant can be pasted beside an earlier one.
///
/// Reads four queries and holds one row per entity in memory. The payload
/// column is read only for the kinds invariant 2 applies to — the exempt kinds
/// are the multi-megabyte ones (a page image is up to about 6.7 MB of base64),
/// and pulling every one of them across to check a rule that does not apply to
/// them would make the check unrunnable on the plant's database, which is the
/// one place it most needs to run.
Future<List<ConfigInconsistency>> checkConfigConsistency(
    GeneratedDatabase db) async {
  final found = <ConfigInconsistency>[];
  final items = $ConfigItemTableTable(db);

  // Identity and position of every row, payload excluded.
  final identityQuery = db.selectOnly(items)
    ..addColumns([items.kind, items.id, items.scope, items.parentId]);
  final identities = await identityQuery.get();

  // Invariant 1. Matched on id alone and not on `(id, scope)`: a
  // station-scoped override of an asset on a shared page has a shared parent,
  // and requiring the scopes to agree would report that as an orphan.
  final ids = {for (final row in identities) row.read(items.id)!};
  for (final row in identities) {
    final parentId = row.read(items.parentId);
    if (parentId == null || ids.contains(parentId)) continue;
    final kind = row.read(items.kind)!;
    final id = row.read(items.id)!;
    found.add(ConfigInconsistency(
      invariant: ConfigInvariant.orphanedParent,
      kindName: kind,
      entityId: id,
      scopeName: row.read(items.scope)!,
      summary: '$kind $id names parent "$parentId", which is not a row',
      found: parentId,
    ));
  }

  final newest = await _newestChangePerEntity(db);

  // The exemption interlock, driven from the change log because that is where
  // the evidence of a broken exemption is. Both an exempt row with history and
  // an exempt entity whose only trace is a logged delete are reported.
  final exemptWithHistory = <_EntityKey>{};
  for (final entry in newest.entries) {
    final kind = ConfigKind.byWireName(entry.key.kind);
    if (kind == null || !historyExempt(kind, entry.key.id)) continue;
    exemptWithHistory.add(entry.key);
    found.add(ConfigInconsistency(
      invariant: ConfigInvariant.exemptHasHistory,
      kindName: entry.key.kind,
      entityId: entry.key.id,
      scopeName: entry.key.scope,
      summary: '${entry.key.kind} ${entry.key.id} is exempt from the change '
          'log and yet has change rows',
      found: entry.value.op,
    ));
  }

  // Invariants 2 and 3, over the rows the exempt kinds are excluded from —
  // this is the only query that reads payloads.
  final rows = await _judgeableRows(db, items);
  for (final row in rows) {
    final kind = ConfigKind.byWireName(row.kind);
    // A kind only a newer station knows: this build cannot say whether it is
    // history-exempt, so it cannot say whether the absence of a change row is
    // a violation. Skipped rather than guessed at. Its `parent_id` was
    // checked above regardless, that rule being kind-agnostic.
    if (kind == null) continue;
    if (historyExempt(kind, row.id)) continue;

    final key = _EntityKey(row.kind, row.id, row.scope);
    final change = newest[key];
    if (change == null) {
      found.add(ConfigInconsistency(
        invariant: ConfigInvariant.missingHistory,
        kindName: row.kind,
        entityId: row.id,
        scopeName: row.scope,
        summary: '${row.kind} ${row.id} exists with no change row at all — a '
            'write that skipped the log',
      ));
      continue;
    }
    if (change.op == ConfigChangeOp.delete.wireName) {
      found.add(ConfigInconsistency(
        invariant: ConfigInvariant.deletedButPresent,
        kindName: row.kind,
        entityId: row.id,
        scopeName: row.scope,
        summary: '${row.kind} ${row.id} was deleted according to its newest '
            'change, and yet the row is here',
        found: change.op,
      ));
      continue;
    }
    final entity = _entityOf(row);
    if (entity == null) {
      found.add(ConfigInconsistency(
        invariant: ConfigInvariant.entityDisagrees,
        kindName: row.kind,
        entityId: row.id,
        scopeName: row.scope,
        summary: '${row.kind} ${row.id} holds a payload that is not JSON, so '
            'nothing can be compared against its history',
        expected: row.payload,
        found: change.newValue,
      ));
      continue;
    }
    if (samePayload(change.newValue, entity)) continue;
    found.add(ConfigInconsistency(
      invariant: ConfigInvariant.entityDisagrees,
      kindName: row.kind,
      entityId: row.id,
      scopeName: row.scope,
      summary: '${row.kind} ${row.id} differs from the newest change recorded '
          'for it — payload, parent or position',
      expected: entity,
      found: change.newValue,
    ));
  }

  found.sort((a, b) {
    final byKind = a.kindName.compareTo(b.kindName);
    if (byKind != 0) return byKind;
    final byId = a.entityId.compareTo(b.entityId);
    if (byId != 0) return byId;
    final byScope = a.scopeName.compareTo(b.scopeName);
    if (byScope != 0) return byScope;
    return a.invariant.index.compareTo(b.invariant.index);
  });
  return found;
}

/// The rows invariants 2 and 3 can judge: everything but the exempt kinds.
///
/// Exempt *ids* within a kind that does carry history — the
/// `server_config_envelope` preference — are filtered in Dart instead. There
/// is one of them and it is small; a second `NOT IN` over a column that is not
/// the kind would buy nothing.
Future<List<ConfigItemRow>> _judgeableRows(
  GeneratedDatabase db,
  $ConfigItemTableTable items,
) {
  final exemptKinds = [for (final kind in kHistoryExemptKinds) kind.wireName];
  final select = db.select(items);
  if (exemptKinds.isNotEmpty) {
    select.where((t) => t.kind.isNotIn(exemptKinds));
  }
  return select.get();
}

/// The newest change row for every entity that has one, keyed by
/// `(kind, id, scope)`.
///
/// Two queries rather than one read of the whole log: the log is append-only
/// and never pruned, so on a plant database it is the largest table in the
/// schema and all but one row per entity is irrelevant here. The inner query
/// reduces it to one id per entity, and the outer one fetches only those —
/// and only the three key columns, `op` and `new_value`, so `old_value`, which
/// doubles the bytes and answers nothing, stays in the database.
Future<Map<_EntityKey, _NewestChange>> _newestChangePerEntity(
    GeneratedDatabase db) async {
  final changes = $ConfigChangeTableTable(db);
  final newestIds = db.selectOnly(changes)
    ..addColumns([changes.id.max()])
    ..groupBy([changes.kind, changes.entityId, changes.scope]);

  final rows = await (db.selectOnly(changes)
        ..addColumns([
          changes.kind,
          changes.entityId,
          changes.scope,
          changes.op,
          changes.newValue,
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
        op: row.read(changes.op)!,
        newValue: row.read(changes.newValue),
      ),
  };
}

/// [row] as the entity string a change row would hold, or null when its
/// payload is not JSON and therefore cannot be one.
String? _entityOf(ConfigItemRow row) {
  final item = ConfigItem(
    // Judged rows have a known kind and a parseable scope by the time they
    // reach here; both are re-read from the row so the entity is built from
    // what is stored rather than from what the caller assumed.
    kind: ConfigKind.byWireName(row.kind)!,
    id: row.id,
    scope: ConfigScope.byWireName(row.scope) ?? ConfigScope.shared,
    parentId: row.parentId,
    sortIndex: row.sortIndex,
    payload: row.payload,
  );
  try {
    return item.encodeEntity();
  } on FormatException {
    return null;
  }
}

/// `(kind, id, scope)` — `config_item`'s primary key, as stored.
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

/// What the newest change for an entity says happened, and what it left.
@immutable
class _NewestChange {
  const _NewestChange({required this.op, required this.newValue});

  /// `ConfigChangeOp.wireName`, as stored — an op this build does not know is
  /// still not a delete, which is all invariant 3 asks.
  final String op;

  /// The entity as the log recorded it, null on a delete.
  final String? newValue;
}
