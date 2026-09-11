/// The one map between what a client names and what the database holds.
///
/// [SeriesResolver] asks three questions in three directions — a wire series
/// name to a table, a table to a plant key, a browse node to a plant key —
/// and this is the gateway's only answer to any of them. Three problems share
/// one object on purpose: `_PolicyTimeseries` needs the table→key direction to
/// ask `canSee`, `_PolicyBrowse` needs the node→key direction for the same
/// reason, and [TimescaleReader] needs the series→table direction because it
/// is the only thing standing between a client-supplied string and a `FROM`
/// clause. One map cannot disagree with itself; three would.
///
/// ## The collection prefix, which is invisible to every existing chart
///
/// 8b writes samples into a prefixed table name derived once in
/// `CollectionPlan.from` from the configured prefix and the collect block's
/// `name` (defaulting to the key), and a panel
/// asks for the plant key it has always asked for — `graph.dart:936` passes
/// `_stateMan.resolveKey(series.key)` straight into `queryTimeseriesData` as
/// the table name. Against the gateway's database that name reaches the
/// *application collector's* unprefixed table, which the gateway never wrote,
/// and the chart draws nothing while both halves of the system are working.
/// 8b deferred the mapping to Phase 10 by name; this file is it. **The wire
/// names the plant key; this map supplies the physical table.**
///
/// ## Consumed, never re-derived
///
/// The table name is computed exactly once, in `CollectionPlan.from`, and
/// carried on [CollectionEntry.table] (8b-01's rule, written at the field: "do
/// not re-derive this string anywhere else in the package"). Nothing here
/// spells the prefix, its config field, or a concatenation — a sweep asserts
/// it, and this directory is the one place a reader would expect to find one.
/// A second derivation
/// would agree with the first until the day one of them was edited, and from
/// that day the gateway would read from a table nothing validated while
/// writing into one that was.
///
/// ## The honest limit (research §C.2)
///
/// **This map covers what the *gateway* collects, and nothing else.** A table
/// written by the application's own collector before cutover, or by a third
/// party, has no entry in the collection plan and resolves to `null` — which
/// is correct, because it is what stops a client naming an arbitrary relation,
/// and it is also the first thing that will look like a database fault. A
/// chart pointed at a pre-cutover unprefixed table answers "no such series"
/// until either 8b's one-shot `INSERT INTO <prefixed> SELECT * FROM <table>`
/// migration runs (the procedure is in `collection_config.dart`'s class doc)
/// or the configuration grows a read-side alias. The gateway counts every such
/// query in `RelayServer.seriesTally` rather than saying so on the wire, so
/// the gap is diagnosable without being enumerable.
///
/// ## A snapshot, and the composition root owns re-pointing it
///
/// The three maps are built once, at construction, from the plan and the
/// router. They are not derived per call — a lookup is on the chart refresh
/// path — and they do not follow a live `KeyRouter.applyKeyMappings`. Half a
/// reload (the router's new node ids against the plan's old tables) is worse
/// than none, so a keymapping reload means building a new plan and a new
/// resolver together. Nothing does that yet: the gateway reloads keymappings
/// without rebuilding the collection plan either, which is 8b's own state and
/// is a named follow-up rather than something this file can fix alone.
library;

import 'package:tfc_dart/core/state_man.dart' show KeyMappings;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show ResolvedSeries, SeriesAddress, SeriesResolver;

import '../collect/collection_plan.dart';
import '../key_router.dart';

/// [SeriesResolver] over 8b's [CollectionPlan] and the live [KeyRouter].
final class CollectionPlanResolver implements SeriesResolver {
  /// Builds the three maps from [plan] and [router].
  ///
  /// [router] rather than a bare [KeyMappings] on purpose: `KeyRouter` is what
  /// *refuses* a mapping at ingest (a `PIPE.` squatter, a `$`-substituted
  /// name), and `router.mappings` is the file minus those refusals. A resolver
  /// built from the raw file would offer a browse translation for a key the
  /// gateway will not serve.
  CollectionPlanResolver({
    required CollectionPlan plan,
    required KeyRouter router,
  }) {
    for (final entry in plan.entries) {
      // Consumed, not computed. See the library doc.
      _tableForSeries[entry.key] = entry.table;
      _keyForTable[entry.table] = entry.key;
    }

    // The node→key inverse of `opcua_node.identifier`, which `KeyRouter`
    // already parses and `local_browse.dart:271` already spells the same way:
    // a `BrowseNode.id` is the string NodeId as the PLC spells it.
    //
    // **Only a node the keymappings name gets a key.** A folder, an
    // intermediate struct node, a method or anything else the operator never
    // mapped answers null — and `_PolicyBrowse` reads null as "do not ask
    // canSee, do not drop", which is the correct treatment for a folder and
    // the reason this must not fall back to the id itself. Answering the id
    // would ask the policy about a string it was never written about, and
    // pruning a folder takes every tag under it off the tree.
    final claimed = <String, String?>{};
    for (final entry in router.mappings.nodes.entries) {
      final identifier = entry.value.opcuaNode?.identifier;
      if (identifier == null || identifier.isEmpty) continue;
      // A second claimant makes the id ambiguous forever: the live plant file
      // carries 390 OPC UA nodes on 316 distinct identifiers, because the
      // three SpeedBatchers repeat theirs under different `server_alias`
      // values and `keyForNode` is handed an id with no alias. Picking one is
      // `_getClientWrapper`'s `firstWhereOrNull` mistake (T-08-13) — it would
      // ask `canSee` about the wrong tag whenever the claimants' policies
      // differ. Null is the honest answer, and its cost is recorded below.
      claimed.update(identifier, (_) => null, ifAbsent: () => entry.key);
    }
    for (final entry in claimed.entries) {
      final key = entry.value;
      if (key != null) _keyForNode[entry.key] = key;
    }
  }

  final Map<String, String> _tableForSeries = <String, String>{};
  final Map<String, String> _keyForTable = <String, String>{};
  final Map<String, String> _keyForNode = <String, String>{};

  /// How many series this gateway can serve history for — the plan's entry
  /// count, which is what a startup line should report.
  int get seriesCount => _tableForSeries.length;

  /// How many browse node ids translate to a plant key.
  ///
  /// Smaller than the keymapping's node count whenever identifiers are shared
  /// across server aliases; the difference is the residual documented at the
  /// constructor, and reporting it is what keeps it from being invisible.
  int get nodeCount => _keyForNode.length;

  @override
  ResolvedSeries? resolve(String wireName) {
    // Throws a FormatException on a name that is not a name — "you spelled it
    // wrong" and "there is no such series" are different facts, and 10-03's
    // handler refuses the first while answering the second as nonexistent.
    final address = SeriesAddress.parse(wireName);
    final table = _tableForSeries[address.series];
    if (table == null) return null;
    return ResolvedSeries(
      table: table,
      member: address.member,
      plantKey: address.series,
    );
  }

  @override
  String? keyForTable(String table) => _keyForTable[table];

  @override
  String? keyForNode(String nodeId) => _keyForNode[nodeId];
}
