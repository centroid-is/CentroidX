/// Reading `key_mappings` out of `config_item`, for the processes that are
/// not the Flutter app.
///
/// The app gets its mappings through the store; the backend and the collector
/// do not have one and do not need one — they read the whole set once at boot
/// and bake it into the isolates they spawn. This file is that read, in one
/// place, so "the shared key mappings" means the same rows to every process
/// that asks for them.
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
    show $ConfigItemTableTable, $FlutterPreferencesTable, ConfigItemRow;
import 'config_item.dart';
import 'key_mapping_codec.dart' show kKeyMappingsPrefKey;

/// The shared `key_mapping` rows, ordered by id.
///
/// Empty while the blob → rows migration has not run, which is a state the
/// callers have to handle rather than a failure: the backend container can
/// restart before any station has run it. So an empty list means "no rows
/// yet", never "no mappings" — the caller falls back to the blob and says so
/// in its log.
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
/// Two integers over the wire, whatever the configuration weighs.
Future<KeyMappingFingerprint> readSharedKeyMappingFingerprint(
    GeneratedDatabase db) async {
  final table = _configItems(db);
  final count = table.id.count();
  final revSum = table.rev.sum();
  final row = await (db.selectOnly(table)
        ..addColumns([count, revSum])
        ..where(table.kind.equals(ConfigKind.keyMapping.wireName) &
            table.scope.equals(ConfigScope.shared.wireName)))
      .getSingle();
  return KeyMappingFingerprint(
    count: row.read(count) ?? 0,
    revSum: row.read(revSum) ?? 0,
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
  const KeyMappingFingerprint({required this.count, required this.revSum});

  /// Shared `key_mapping` rows.
  final int count;

  /// Their `rev` values added together. Zero when there are no rows, which is
  /// also what an un-migrated database reads as.
  final int revSum;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyMappingFingerprint &&
          other.count == count &&
          other.revSum == revSum;

  @override
  int get hashCode => Object.hash(count, revSum);

  @override
  String toString() => 'KeyMappingFingerprint(count: $count, rev: $revSum)';
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

/// The legacy `flutter_preferences.key_mappings` blob, read **straight from the
/// row**.
///
/// Not through `PreferencesApi.getString`. As of v1.2 phase 2 plan 06,
/// `Preferences.loadFromPostgres` deliberately skips this key, so the memory
/// cache answers null for it however full the row is — that is what stops the
/// blob from being a second live copy of the plant's wiring. A process that
/// still needs the blob as a boot fallback therefore has to read the row, and
/// this is that read.
///
/// Null when the row is absent or holds null: the key has never been saved.
Future<String?> readSharedKeyMappingBlob(GeneratedDatabase db) async {
  final prefs = $FlutterPreferencesTable(db);
  final row = await (db.select(prefs)
        ..where((t) => t.key.equals(kKeyMappingsPrefKey))
        ..limit(1))
      .getSingleOrNull();
  return row?.value;
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
