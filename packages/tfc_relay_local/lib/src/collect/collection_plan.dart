/// Keymappings + config → the list of things to collect, plus the per-entry
/// rejections.
///
/// **This is the whole answer to "where does the collector config come
/// from".** It comes from the keymappings the gateway already loads, because
/// `CollectEntry` is a field on `KeyMappingEntry` and the live file carries
/// one on every collected tag. There is no second file listing keys, and the
/// app's `collector_config` preference (`collector.dart:139`) stays the
/// app's: a per-station preference deciding whether the *gateway* historises
/// would be the device-local-preferences trap in reverse — one station's
/// setting silently deciding what the whole plant records.
///
/// [CollectionPlan.from] is a **pure function** — no IO, no clock, no logger.
/// One bad collect block in 430 costs exactly that key, in the
/// `updateKeyMappings` discipline (08-PATTERNS §2): it classifies, it never
/// throws.
library;

import 'dart:convert' show utf8;

import 'package:tfc_dart/core/boolean_expression.dart' show ExpressionConfig;
import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;

import 'collection_config.dart';

/// One thing the gateway would collect: a key, the table it lands in, and
/// the sampling instructions carried through from the collect block
/// unchanged. This type decides *what*, never *how* — cadence, expressions
/// and member extraction are the runner's job (8b-03).
final class CollectionEntry {
  CollectionEntry({
    required this.key,
    required this.table,
    this.sampleInterval,
    this.sampleExpression,
    this.sampleMembers,
    this.retention,
  });

  /// The plant key whose value stream is sampled.
  final String key;

  /// The table the samples land in: `tablePrefix + (collect.name ?? key)`,
  /// computed **once, here, already validated**.
  ///
  /// Do not re-derive this string anywhere else in the package. The prefix
  /// is the side-by-side guarantee, and a second computation of the same
  /// string is where a guarantee goes to die: the two spellings agree until
  /// the day one of them is edited, and from that day the gateway writes
  /// into a table nothing validated.
  final String table;

  /// Carried through from the collect block unchanged.
  final Duration? sampleInterval;
  final ExpressionConfig? sampleExpression;
  final List<String>? sampleMembers;

  /// The retention to install, or **null for "install no policy"**.
  ///
  /// Null when the stored policy was not usable — the shipped behaviour
  /// (`database.dart:874-885`): a table with no policy keeps everything,
  /// which is the safe direction to fail in. The adjustment is recorded on
  /// [CollectionPlan.adjusted] rather than logged away.
  final RetentionPolicy? retention;
}

/// One key's outcome, in a sentence an operator can act on.
final class CollectionIssue {
  CollectionIssue({required this.key, required this.message});

  /// The keymapping key — what the operator can find in the editor.
  final String key;

  /// Names the key and says what to change. Never a bare code.
  final String message;

  @override
  String toString() => '$key: $message';
}

/// What the gateway would collect, what it refuses to, and what it trimmed.
///
/// **Two issue lists rather than one, because the two outcomes are genuinely
/// different.** A rejection means that key records *nothing*; an adjustment
/// means it records with something dropped. Collapsing them would make
/// "your tag is not being collected" and "your tag is being kept forever"
/// the same log line — two different afternoons for whoever goes looking
/// for the history.
final class CollectionPlan {
  CollectionPlan._(this.entries, this.rejected, this.adjusted);

  /// What will be collected, in keymapping order.
  final List<CollectionEntry> entries;

  /// Keys that record nothing, and why. Per key, never per file.
  final List<CollectionIssue> rejected;

  /// Keys that record with something dropped (today: an unusable retention
  /// replaced by "no policy"), and what was dropped.
  final List<CollectionIssue> adjusted;

  /// Postgres truncates identifiers at NAMEDATALEN-1 bytes and does not
  /// warn — two long names sharing a 63-byte prefix silently become one
  /// table.
  static const int maxTableNameBytes = 63;

  /// The pure derivation. [unroutable] is the set of keys the router's
  /// ingest refused (`KeyMappingApplication.rejected.keys`) — passed in
  /// rather than re-derived, because a second spelling of the routing rules
  /// here would drift from `KeyRouter`'s the day either is edited.
  static CollectionPlan from(
    KeyMappings mappings,
    CollectionConfig config, {
    Set<String> unroutable = const <String>{},
  }) {
    final rejected = <CollectionIssue>[];
    final adjusted = <CollectionIssue>[];

    // First pass: per-key checks, and the table each survivor wants.
    final candidates = <String, String>{};
    for (final entry in mappings.nodes.entries) {
      final collect = entry.value.collect;
      if (collect == null) continue;
      final key = entry.key;

      if (unroutable.contains(key)) {
        rejected.add(CollectionIssue(
            key: key,
            message: 'the router refused this key\'s mapping, so there is '
                'no value stream to sample. Collecting it blind would '
                'historise nothing under a table name that looks alive; '
                'fix the mapping and the key will be collected'));
        continue;
      }

      final table = config.tablePrefix + (collect.name ?? key);

      if (_unsafeIdentifier(table)) {
        rejected.add(CollectionIssue(
            key: key,
            message: 'the table name "$table" carries a quote, semicolon, '
                'backslash or control character. It reaches SQL by '
                'interpolation with the identifier unescaped '
                '(database_drift.dart:687), so this is the only place it '
                'can be stopped; rename the collect block\'s "name"'));
        continue;
      }

      final bytes = utf8.encode(table).length;
      if (bytes > maxTableNameBytes) {
        rejected.add(CollectionIssue(
            key: key,
            message: 'the table name "$table" is $bytes bytes and Postgres '
                'truncates identifiers at $maxTableNameBytes — silently, so '
                'two long names sharing a $maxTableNameBytes-byte prefix '
                'would become one table. Shorten the collect block\'s '
                '"name"'));
        continue;
      }

      candidates[key] = table;
    }

    // Second pass: two keys resolving to the SAME table reject BOTH. One
    // table fed by two differently-shaped values is the schema fight
    // (database.dart:1042-1082) inside our own process, and keeping either
    // one would silently bless whichever was listed first.
    final byTable = <String, List<String>>{};
    for (final entry in candidates.entries) {
      byTable.putIfAbsent(entry.value, () => <String>[]).add(entry.key);
    }
    for (final group in byTable.entries) {
      if (group.value.length < 2) continue;
      for (final key in group.value) {
        rejected.add(CollectionIssue(
            key: key,
            message: 'the keys ${group.value.join(' and ')} all resolve to '
                'the table "${group.key}". One table fed by two '
                'differently-shaped values is a schema fight; give each '
                'collect block its own "name"'));
        candidates.remove(key);
      }
    }

    // Third pass: build the entries, in keymapping order, adjusting an
    // unusable retention to "no policy" rather than rejecting the key.
    final entries = <CollectionEntry>[];
    for (final entry in mappings.nodes.entries) {
      final table = candidates[entry.key];
      if (table == null) continue;
      final collect = entry.value.collect!;

      RetentionPolicy? retention = collect.retention;
      if (!retention.isUsable) {
        adjusted.add(CollectionIssue(
            key: entry.key,
            message: 'the stored retention drops after '
                '${retention.dropAfter}, which is under the one-minute '
                'floor — a unit-conversion artifact, not a choice '
                '(database.dart:287-319). No policy will be installed, so '
                'this table keeps everything until the retention is fixed'));
        retention = null;
      }

      entries.add(CollectionEntry(
        key: entry.key,
        table: table,
        sampleInterval: collect.sampleInterval,
        sampleExpression: collect.sampleExpression,
        sampleMembers: collect.sampleMembers,
        retention: retention,
      ));
    }

    return CollectionPlan._(
      List<CollectionEntry>.unmodifiable(entries),
      List<CollectionIssue>.unmodifiable(rejected),
      List<CollectionIssue>.unmodifiable(adjusted),
    );
  }
}


/// A quote, a semicolon, a backslash or a control character — anything that
/// could carry meaning through the unescaped interpolation at
/// `database_drift.dart:687` / `:907`. The same set
/// `CollectionConfig.tablePrefix` refuses, judged here on the whole name.
bool _unsafeIdentifier(String name) {
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return true;
    if (unit == 0x22 || unit == 0x27 || unit == 0x3b || unit == 0x5c) {
      // " ' ; \
      return true;
    }
  }
  return false;
}
