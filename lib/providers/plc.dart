import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/state_man_types.dart' show KeyMappings;
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import '../core/guarded_knowledge_stores.dart';
import '../plc/plc_code_upload_service.dart';
import 'access.dart' show stationNameProvider;
import 'access_policy.dart'
    show RefAuditSink, reportAccessDenial, sessionInForce;
import 'server_database.dart';
import 'state_man.dart';

export '../core/guarded_knowledge_stores.dart' show PlcCodeIndexExtras;

export 'package:tfc_mcp_server/tfc_mcp_server.dart' show PlcContextService, PlcContext;

/// Cached [GuardedPlcCodeIndex] instance.
///
/// Avoids creating a new instance on every provider read, which would cause
/// downstream FutureProviders (plcAssetSummaryProvider) to re-query the DB.
GuardedPlcCodeIndex? _cachedPlcCodeIndex;
McpDatabase? _plcCodeIndexDb;

/// Cached [PlcCodeUploadService] instance.
PlcCodeUploadService? _cachedUploadService;
McpDatabase? _uploadServiceDb;

/// Provider for the [PlcCodeUploadService].
///
/// Wired with the shared [plcCodeIndexProvider] instance and [ConfigService]
/// (as [KeyMappingLookup]) from the shared [mcpDatabaseProvider]. Returns null
/// when database is not available (upload FAB shows error).
///
/// Uses the same [DriftPlcCodeIndex] as the MCP server so uploads update the
/// isEmpty cache that the server's search tools observe.
final plcCodeUploadServiceProvider = Provider<PlcCodeUploadService?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  final index = ref.watch(plcCodeIndexProvider);
  if (db == null || index == null) {
    _cachedUploadService = null;
    _uploadServiceDb = null;
    return null;
  }
  // Reuse cached instance when DB hasn't changed.
  if (identical(db, _uploadServiceDb) && _cachedUploadService != null) {
    return _cachedUploadService;
  }
  _uploadServiceDb = db;
  final configService = ConfigService(db);
  final plcCodeService = PlcCodeService(index, configService);
  _cachedUploadService = PlcCodeUploadService(plcCodeService);
  return _cachedUploadService;
});

/// Provider for the PLC code index backed by the shared app database.
///
/// Returns null when no database connection is available.
/// Caches the instance to avoid re-triggering downstream FutureProviders.
///
/// **What comes out is a [GuardedPlcCodeIndex], not a [DriftPlcCodeIndex].**
/// The four writes — `indexAsset`, `deleteAssetIndex`, `renameAsset` and
/// `reindexAsset` — ask for `configure` and leave an audit row; the reads are
/// untouched. Anything type-testing what this provider returns must test
/// [PlcCodeIndexExtras], never the concrete Drift class: see that interface's
/// doc comment for the four read providers below that this broke.
///
/// The session is a callback and the sink is a [RefAuditSink] rather than an
/// awaited value, both so that this provider never rebuilds. A rebuild here
/// re-triggers every downstream `FutureProvider` on the Knowledge Base page —
/// on every sign-in, and again when Postgres finally opens.
final plcCodeIndexProvider = Provider<PlcCodeIndex?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) {
    _cachedPlcCodeIndex = null;
    _plcCodeIndexDb = null;
    return null;
  }
  // Reuse cached instance when DB hasn't changed.
  if (identical(db, _plcCodeIndexDb) && _cachedPlcCodeIndex != null) {
    return _cachedPlcCodeIndex;
  }
  _plcCodeIndexDb = db;
  _cachedPlcCodeIndex = GuardedPlcCodeIndex(
    inner: DriftPlcCodeIndex(db),
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.read(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );
  return _cachedPlcCodeIndex;
});

/// Provider for PLC asset summaries (one entry per asset with indexed code).
///
/// Invalidated after PLC upload to refresh the list.
final plcAssetSummaryProvider =
    FutureProvider<List<PlcAssetSummary>>((ref) async {
  final index = ref.watch(plcCodeIndexProvider);
  if (index == null) return [];
  return index.getIndexSummary();
});

/// Currently selected PLC asset key for the detail panel.
///
/// Mutually exclusive with [selectedTechDocProvider] — setting one clears
/// the other in the UI layer (tech_doc_library_section.dart).
final selectedPlcAssetProvider = StateProvider<String?>((ref) => null);

/// Provider for all PLC code blocks belonging to a specific asset.
///
/// Uses the [PlcCodeIndex.getBlocksForAsset] method to fetch full block
/// details including variables. Used by [PlcDetailPanel] to render the
/// expandable code block list.
final plcBlockListProvider =
    FutureProvider.family<List<PlcCodeBlock>, String>((ref, assetKey) async {
  final index = ref.watch(plcCodeIndexProvider);
  if (index == null) return [];
  return index.getBlocksForAsset(assetKey);
});

/// Cached [PlcContextService] instance.
PlcContextService? _cachedPlcContextService;
McpDatabase? _plcContextServiceDb;
List<String>? _plcContextServiceAliases;

/// Adapter that provides server aliases from StateMan's OPC-UA config.
class _StateManServerAliasProvider implements ServerAliasProvider {
  _StateManServerAliasProvider(this._aliases);
  final List<String> _aliases;

  @override
  List<String> get serverAliases => _aliases;
}

/// Provider for the [PlcContextService].
///
/// Wired with the shared [PlcCodeService] and [ConfigService] (as
/// [KeyMappingLookup]) from the shared [mcpDatabaseProvider]. Returns null
/// when database or PLC code index is not available.
///
/// When StateMan is available, extracts OPC-UA server aliases and passes
/// them as a [ServerAliasProvider] so that keys without an explicit
/// `server_alias` in their mapping get the real server name instead of
/// "unknown" (when there is exactly one active server).
final plcContextServiceProvider = Provider<PlcContextService?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  final index = ref.watch(plcCodeIndexProvider);
  if (db == null || index == null) {
    _cachedPlcContextService = null;
    _plcContextServiceDb = null;
    _plcContextServiceAliases = null;
    return null;
  }

  // Get current server aliases (may be empty if StateMan not ready).
  final aliases = ref.watch(serverAliasesProvider).valueOrNull ?? [];

  if (identical(db, _plcContextServiceDb) &&
      _cachedPlcContextService != null &&
      _listEquals(aliases, _plcContextServiceAliases)) {
    return _cachedPlcContextService;
  }
  _plcContextServiceDb = db;
  _plcContextServiceAliases = aliases;
  final configService = ConfigService(db);
  final plcCodeService = PlcCodeService(index, configService);
  _cachedPlcContextService = PlcContextService(
    plcCodeService,
    configService,
    serverAliasProvider: aliases.isNotEmpty
        ? _StateManServerAliasProvider(aliases)
        : null,
  );
  return _cachedPlcContextService;
});

/// Shallow list equality check for cache invalidation.
bool _listEquals(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Provider for available StateMan server aliases.
///
/// Extracts server aliases from OPC UA, JBTM, and Modbus configurations.
/// Returns an empty list when StateMan is not yet initialized.
/// Used by [PlcCodeUploadDialog] to populate the server alias dropdown.
final serverAliasesProvider = FutureProvider<List<String>>((ref) async {
  try {
    final stateMan = await ref.watch(stateManProvider.future);
    final aliases = <String>[];

    // Extract OPC UA server aliases
    for (final opcua in stateMan.config.opcua) {
      if (opcua.serverAlias != null && opcua.serverAlias!.isNotEmpty) {
        aliases.add(opcua.serverAlias!);
      }
    }

    // Extract JBTM server aliases
    for (final jbtm in stateMan.config.jbtm) {
      if (jbtm.serverAlias != null && jbtm.serverAlias!.isNotEmpty) {
        aliases.add(jbtm.serverAlias!);
      }
    }

    // Extract Modbus server aliases
    for (final modbus in stateMan.config.modbus) {
      if (modbus.serverAlias != null && modbus.serverAlias!.isNotEmpty) {
        aliases.add(modbus.serverAlias!);
      }
    }

    return aliases;
  } catch (_) {
    return [];
  }
});

// ---------------------------------------------------------------------------
// Call graph providers
// ---------------------------------------------------------------------------

/// Provider for variable references for a specific block.
final plcVarRefsForBlockProvider =
    FutureProvider.family<List<PlcVarRefTableData>, int>((ref, blockId) async {
  final index = ref.watch(plcCodeIndexProvider);
  // `PlcCodeIndexExtras`, not `DriftPlcCodeIndex`: `plcCodeIndexProvider`
  // returns the guard, and a concrete-type test here answers `[]` silently.
  if (index is! PlcCodeIndexExtras) return [];
  return index.getVarRefsForBlock(blockId);
});

/// Provider for FB instances from the call graph tables.
final plcFbInstancesProvider =
    FutureProvider.family<List<PlcFbInstanceTableData>, String>(
        (ref, assetKey) async {
  final index = ref.watch(plcCodeIndexProvider);
  // `PlcCodeIndexExtras`, not `DriftPlcCodeIndex`: `plcCodeIndexProvider`
  // returns the guard, and a concrete-type test here answers `[]` silently.
  if (index is! PlcCodeIndexExtras) return [];
  return index.getFbInstances();
});

/// Provider for block call edges for a specific block.
final plcBlockCallsProvider =
    FutureProvider.family<List<PlcBlockCallTableData>, int>(
        (ref, blockId) async {
  final index = ref.watch(plcCodeIndexProvider);
  // `PlcCodeIndexExtras`, not `DriftPlcCodeIndex`: `plcCodeIndexProvider`
  // returns the guard, and a concrete-type test here answers `[]` silently.
  if (index is! PlcCodeIndexExtras) return [];
  return index.getBlockCalls(blockId);
});

/// Provider for variable references matching a path pattern.
final plcVarRefsProvider =
    FutureProvider.family<List<PlcVarRefTableData>, String>(
        (ref, variablePath) async {
  final index = ref.watch(plcCodeIndexProvider);
  // `PlcCodeIndexExtras`, not `DriftPlcCodeIndex`: `plcCodeIndexProvider`
  // returns the guard, and a concrete-type test here answers `[]` silently.
  if (index is! PlcCodeIndexExtras) return [];
  return index.getVarRefs(variablePath);
});

/// Provider for [KeyMappings] from [StateMan].
///
/// Used by [PlcDetailPanel] to correlate HMI keys with PLC variables.
/// Returns null when StateMan is not yet initialized.
final keyMappingsProvider = FutureProvider<KeyMappings?>((ref) async {
  try {
    final stateMan = await ref.watch(stateManProvider.future);
    return stateMan.keyMappings;
  } catch (_) {
    return null;
  }
});

/// Provider for in-memory [CallGraphData] built from PLC code blocks.
///
/// Uses [CallGraphBuilder] to parse implementation bodies and extract
/// variable references, FB instances, and call chains. Keyed by asset key.
final callGraphDataProvider =
    FutureProvider.family<CallGraphData?, String>((ref, assetKey) async {
  final blocks = await ref.watch(plcBlockListProvider(assetKey).future);
  if (blocks.isEmpty) return null;
  final builder = CallGraphBuilder();
  return builder.build(blocks);
});
