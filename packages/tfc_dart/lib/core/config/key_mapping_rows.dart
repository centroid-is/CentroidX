/// Reading shared configuration out of `config_item`, for the processes that
/// are not the Flutter app.
///
/// The app gets its configuration through the store; the backend and the
/// collector do not have one and do not need one — they read what they need
/// once at boot and bake it into the isolates they spawn. This file is those
/// reads, in one place, so "the shared key mappings" and "the shared value of
/// this preference" mean the same rows to every process that asks for them.
///
/// [readSharedPreferenceValue] decodes through `preference_payload.dart`, the
/// same codec both preference stores write with. That is deliberately not a
/// third preferences-shaped object: it is the same answer to "what is on
/// disk", read without a store.
///
/// ## Why [GeneratedDatabase] and not `AppDatabase`
///
/// `config_item` is one physical table with two Dart schemas over it:
/// `AppDatabase` declares it, `ServerDatabase` in `tfc_mcp_server` does not,
/// and both open the same Postgres. Taking the base class and attaching the
/// table to whatever database is handed over means the read is written once
/// rather than once per schema — which is the point, because a second
/// spelling of "the shared key mappings" is a second thing to keep in step.
///
/// ## Nothing here writes
///
/// These are reads and only reads. The write path is the store's
/// (`config_store.dart`), which is where the compare-and-swap on `rev` and the
/// change log live. A helper here that wrote a row would bypass both.
library;

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../database_drift.dart'
    show $ConfigChangeTableTable, $ConfigItemTableTable, ConfigItemRow;
import 'config_item.dart';
import 'preference_payload.dart' show decodePreferencePayload;

/// The shared `key_mapping` rows, ordered by id.
///
/// Empty when the blob → rows migration has not run — and since 04-12 dropped
/// the blob reader, that is the only thing empty can mean here that a caller
/// can act on. A backend with no rows has no plant wiring at all, so it says
/// which migration is missing and refuses to boot rather than acquiring from
/// a key set it invented.
///
/// Ordered by id because the order has to come from the query. Rows come back
/// in whatever order the engine chooses otherwise, and a key set whose order
/// depends on which station wrote which key first is a diff that reports
/// changes nobody made.
Future<List<ConfigItem>> readSharedKeyMappingItems(GeneratedDatabase db) async {
  final table = _configItems(db);
  final rows = await (db.select(table)
        ..where((t) =>
            t.kind.equals(ConfigKind.keyMapping.wireName) &
            t.scope.equals(ConfigScope.shared.wireName))
        ..orderBy([(t) => OrderingTerm.asc(t.id)]))
      .get();
  return rows.map(_itemOf).toList(growable: false);
}

/// How many shared `key_mapping` rows there are and what their revisions sum
/// to.
///
/// The safety net under the `config_change` notification, and deliberately
/// **not** a `config_change.id` watermark. That column is a `SERIAL`: values
/// are assigned at `INSERT` and become visible at `COMMIT`, so a transaction
/// that took id 100 and committed after one that took 101 is skipped forever
/// by a reader that has already advanced past 101. A poll built on the same
/// predicate misses it identically, which is what makes a watermark the wrong
/// shape for a net.
///
/// [revSum] moves on an edit to an existing key, which leaves [count] where it
/// was; [count] moves on an added or removed key, which an equal-and-opposite
/// pair of `rev` bumps could otherwise hide. Neither has sequence semantics —
/// both are properties of the rows as they stand right now, so a reader that
/// missed the moment of the change still sees the difference afterwards.
///
/// [KeyMappingFingerprint.latestChangeId] is the third term, and it exists
/// for the write the first two cannot see: a **rename**. Renaming a key is one
/// row deleted and one inserted in the same action, both at `rev` 1, so the
/// count and the sum come out exactly where they were — and a backend keyed
/// on those two alone kept subscribing under the old name forever. Every
/// ordinary write appends change rows, so the log's highest id moves whenever
/// the first two do not. It is *added* to them rather than replacing them
/// because of the `SERIAL` caveat above: a late-committing lower id never
/// moves the maximum, and it is the revisions that catch that one. A
/// history-exempt row (the `server_config_envelope` ciphertext) writes no
/// change row, and its edit is caught by [revSum] — the two nets cover each
/// other's hole.
///
/// Three integers over the wire, whatever the configuration weighs.
Future<KeyMappingFingerprint> readSharedKeyMappingFingerprint(
        GeneratedDatabase db) =>
    readSharedConfigFingerprint(db, const {ConfigKind.keyMapping});

/// The same two integers over any set of kinds.
///
/// Generalised in 04-11, when the backend gained a second thing to watch. The
/// acquisition isolates bake in `key_mappings` **and** `alarm_man_config`, and
/// once the alarms moved out of `flutter_preferences` onto a `preference` row
/// the digest watcher over the old table could only ever report that the row
/// nobody writes any more had not changed. Both are `config_item` rows now, so
/// both are watched the same way.
///
/// [kinds] is what the caller consumes and nothing else. A backend that
/// restarted on a `page` write would be restarting to boot into exactly the
/// state it was already in — and a **`page_image` write must not move this
/// number at all**, which is what keeps an operator pasting a picture from
/// bouncing the acquisition backend.
///
/// An empty [kinds] answers a zero fingerprint rather than the whole table:
/// "watch nothing" has to mean nothing, or a caller that computed its kind set
/// and got none would silently start watching everything.
Future<KeyMappingFingerprint> readSharedConfigFingerprint(
    GeneratedDatabase db, Set<ConfigKind> kinds) async {
  if (kinds.isEmpty) return const KeyMappingFingerprint(count: 0, revSum: 0);
  final wireNames = [for (final kind in kinds) kind.wireName];
  final table = _configItems(db);
  final count = table.id.count();
  final revSum = table.rev.sum();
  final row = await (db.selectOnly(table)
        ..addColumns([count, revSum])
        ..where(table.kind.isIn(wireNames) &
            table.scope.equals(ConfigScope.shared.wireName)))
      .getSingle();
  final changes = $ConfigChangeTableTable(db);
  final latest = changes.id.max();
  final logRow = await (db.selectOnly(changes)
        ..addColumns([latest])
        ..where(changes.kind.isIn(wireNames) &
            changes.scope.equals(ConfigScope.shared.wireName)))
      .getSingle();
  return KeyMappingFingerprint(
    count: row.read(count) ?? 0,
    revSum: row.read(revSum) ?? 0,
    latestChangeId: logRow.read(latest) ?? 0,
  );
}

/// The result of [readSharedKeyMappingFingerprint]: what the shared key
/// mappings look like from a distance.
///
/// A value type rather than a record so the two ints cannot be compared in the
/// wrong order by a caller that mixed them up, and so the equality a poll
/// depends on is spelled out here rather than assumed.
@immutable
class KeyMappingFingerprint {
  const KeyMappingFingerprint({
    required this.count,
    required this.revSum,
    this.latestChangeId = 0,
  });

  /// Shared `key_mapping` rows.
  final int count;

  /// Their `rev` values added together. Zero when there are no rows, which is
  /// also what an un-migrated database reads as.
  final int revSum;

  /// The highest `config_change.id` written for the watched kinds, or zero
  /// when the log holds none. See [readSharedKeyMappingFingerprint].
  final int latestChangeId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyMappingFingerprint &&
          other.count == count &&
          other.revSum == revSum &&
          other.latestChangeId == latestChangeId;

  @override
  int get hashCode => Object.hash(count, revSum, latestChangeId);

  @override
  String toString() => 'KeyMappingFingerprint(count: $count, rev: $revSum, '
      'latest change: $latestChangeId)';
}

/// `config_item` attached to [db].
///
/// Drift's generated table classes take their database as a constructor
/// argument — the same mechanism `createAlias` uses — so the table can be
/// pointed at a `GeneratedDatabase` that does not declare it. The queries
/// above are ordinary drift builders from there: no raw SQL and therefore no
/// placeholder dialect to get wrong, and no `?`-versus-`$1` branch to keep in
/// step with the two backends.
$ConfigItemTableTable _configItems(GeneratedDatabase db) =>
    $ConfigItemTableTable(db);

/// The value of one shared `preference` row, decoded, or null when there is
/// none this build can read.
///
/// For a process that has no [ConfigStore] and needs one setting: the
/// acquisition backend's `alarm_man_config`, read once at boot and baked into
/// what it builds. A store would bring a snapshot, a reconcile, a change feed
/// and a write path, none of which a one-shot boot read has any use for — and
/// the write path is the part that must not exist here, because a process
/// with no snapshot cannot tell "this setting is empty" from "the migration
/// has not run" and so must never conclude "empty, therefore write the
/// default".
///
/// Decoded through `preference_payload.dart` — the one codec both preference
/// stores write with — so the tag that separates `7` from `'7'` survives the
/// trip. **Null covers absent and unreadable alike**, which is the codec's
/// documented contract: a row nobody can parse costs the caller a default,
/// never the boot. A caller that must tell an empty plant from an unmigrated
/// one asks the migration marker, which exists for exactly that question.
///
/// Shared scope only. `preference` is the first kind that legitimately lives
/// at both scopes, so a read that did not filter could hand a backend one
/// station's local row and run the plant on it.
Future<Object?> readSharedPreferenceValue(
    GeneratedDatabase db, String key) async {
  final table = _configItems(db);
  final row = await (db.select(table)
        ..where((t) =>
            t.kind.equals(ConfigKind.preference.wireName) &
            t.id.equals(key) &
            t.scope.equals(ConfigScope.shared.wireName))
        ..limit(1))
      .getSingleOrNull();
  if (row == null) return null;
  return decodePreferencePayload(row.payload);
}

/// One row as the value type the rest of the code uses.
///
/// `scope` is [ConfigScope.shared] by construction: it is what the query
/// filtered on, so re-parsing the column would only introduce a way for the
/// two to disagree.
ConfigItem _itemOf(ConfigItemRow row) => ConfigItem(
      kind: ConfigKind.keyMapping,
      id: row.id,
      scope: ConfigScope.shared,
      parentId: row.parentId,
      sortIndex: row.sortIndex,
      payload: row.payload,
      rev: row.rev,
      updatedAt: row.updatedAt,
      updatedBy: row.updatedBy,
    );
