/// `SeriesResolver` over the backend's key mappings — and nothing else.
///
/// `RelayServer`'s constructor requires a resolver and takes no default, for a
/// reason `series_address.dart:150-158` states in full: *"a permissive default
/// is a production hole with a test's name on it"*. This is the backend's
/// resolver, and it is built from the one thing main already holds — the key
/// mappings — so it needs no database round trip and no upstream call to exist.
///
/// ## Fail closed
///
/// Three lookups, one direction each, and **null always means refuse**. There
/// is no identity fallback and no guess-the-table-from-the-key branch anywhere
/// below. A key with no `collect` entry has no history, so it has no table, and
/// saying so is the whole answer. 10-CONTEXT amendment 6: an unmappable table
/// is not served until it is mapped.
///
/// A **malformed** name is different and is not a refusal: it throws a
/// [FormatException] out of [relay.SeriesAddress.parse]. "You spelled it wrong"
/// and "there is no such series" are two different facts and the caller acts on
/// them differently.
///
/// ## Agreement with the writer
///
/// The table this resolver names is the table the collector inserts into,
/// because both call [collectTableName]. That is not tidiness: a second
/// spelling of the same rule compiles, keeps every suite green, and serves a
/// year of history out of a table nothing writes.
///
/// ## Two keys, one table
///
/// The live SVN mapping has **fourteen** tables claimed by two keys each — two
/// checkweigher heads recording one accepted/rejected stream, and the batcher
/// weight pairs. That is deliberate configuration, so the forward direction
/// still answers: a client that named `SB1.CheckWeigher.Accepted.1` named a key
/// and gets that key back as its own [relay.ResolvedSeries.plantKey].
///
/// The **reverse** direction cannot answer. "Which key does this table record?"
/// has two answers, and picking one is `keyForNode`'s own T-08-13 mistake
/// (`collection_plan_resolver.dart:104-111`): it would ask `canSee` about the
/// wrong tag whenever the two claimants' policies differ, which is one head's
/// history served under the other head's name. So [keyForTable] refuses an
/// ambiguous table, once, forever, and the collision is logged loudly at
/// construction — one line for the whole mapping, because fourteen collisions
/// must not be fourteen startup lines.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'package:logger/logger.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../collector.dart' show collectTableName;
import '../state_man.dart' show KeyMappings;

/// [relay.SeriesResolver] built once from a [KeyMappings].
final class KeyMappingSeriesResolver implements relay.SeriesResolver {
  /// Builds the three lookups now, so no call later touches the mapping.
  ///
  /// [logger] is injectable so a test can read the collision warning back; it
  /// is only ever written to here, at construction, and never on a lookup path.
  KeyMappingSeriesResolver({
    required KeyMappings keyMappings,
    Logger? logger,
  }) {
    final claimants = <String, List<String>>{};
    for (final entry in keyMappings.nodes.entries) {
      // Every mapped key is a browse node id, collected or not: keyForNode is
      // about who a tag IS, not about whether its history is kept.
      _nodes.add(entry.key);
      final collect = entry.value.collect;
      if (collect == null) continue;
      final table = collectTableName(collect);
      _tableForKey[entry.key] = table;
      claimants.putIfAbsent(table, () => <String>[]).add(entry.key);
    }

    for (final claim in claimants.entries) {
      if (claim.value.length == 1) {
        _keyForTable[claim.key] = claim.value.single;
      } else {
        _ambiguousTables.add(claim.key);
      }
    }

    if (_ambiguousTables.isNotEmpty) {
      final detail = <String>[
        for (final table in _ambiguousTables)
          '$table <- ${claimants[table]!.join(', ')}'
      ].join('; ');
      // methodCount 0: a configuration collision has no interesting call
      // stack — it is always this constructor — and two frames of one turn a
      // boot line an integrator must read into a box they scroll past.
      (logger ?? Logger(printer: PrettyPrinter(methodCount: 0)))
          .w('[series-resolver] '
          '${_ambiguousTables.length} table(s) are claimed by more than one '
          'collected key, so history cannot be read back by table for them '
          'and keyForTable refuses: $detail');
    }
  }

  final Map<String, String> _tableForKey = <String, String>{};
  final Map<String, String> _keyForTable = <String, String>{};
  final Set<String> _nodes = <String>{};
  final Set<String> _ambiguousTables = <String>{};

  /// How many series this backend can serve history for.
  ///
  /// The number a startup line should report: it is smaller than the key count
  /// by exactly the tags nobody chose to record, and an integrator who expected
  /// otherwise finds out at boot rather than from an empty chart.
  int get seriesCount => _tableForKey.length;

  /// The tables more than one collected key writes into.
  ///
  /// Exposed rather than only logged: the count is a property of the mapping a
  /// caller may want to assert, and a warning nothing can read back is a
  /// warning that quietly stops being emitted.
  Set<String> get ambiguousTables => Set<String>.unmodifiable(_ambiguousTables);

  /// The table, member and plant key behind [wireName], or null to refuse.
  ///
  /// The member is carried through from the address without being checked
  /// against `sample_members`. A member selects a field of the stored row, not
  /// a table, so an unlisted one reads as an absent column rather than as a
  /// different series — and validating it here would refuse a member a chart
  /// legitimately picks out of a whole-value collection, which has no
  /// `sample_members` at all.
  @override
  relay.ResolvedSeries? resolve(String wireName) {
    final address = relay.SeriesAddress.parse(wireName);
    final table = _tableForKey[address.series];
    if (table == null) return null;
    return relay.ResolvedSeries(
      table: table,
      member: address.member,
      plantKey: address.series,
    );
  }

  /// The plant key [table] records, or null to refuse.
  ///
  /// Null for a table nothing writes, and null for a table two keys write —
  /// see the library doc.
  @override
  String? keyForTable(String table) => _keyForTable[table];

  /// The plant key [nodeId] is, or null to refuse.
  ///
  /// `BackendBrowse` spells a node id as the dotted plant key, so this is the
  /// identity translation — **but only for an id the mappings actually name**.
  /// A folder, a station, or an id from some other address space answers null,
  /// which the policy layer reads as "do not ask canSee, do not drop"; falling
  /// back to the id itself would ask the policy about a string it was never
  /// written about, and pruning a folder takes every tag under it off the tree.
  @override
  String? keyForNode(String nodeId) => _nodes.contains(nodeId) ? nodeId : null;
}
