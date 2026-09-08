import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import 'database.dart';

/// Provider for the [AppDatabase] as [McpDatabase] for MCP services.
///
/// Reuses the existing app database connection pool -- no separate
/// ServerDatabase or pg.Pool created. Returns null if database is
/// not connected.
final mcpDatabaseProvider = Provider<McpDatabase?>((ref) {
  final dbAsync = ref.watch(databaseProvider);
  return dbAsync.valueOrNull?.db;
});

/// Cached instance for [driftTechDocIndexProvider].
DriftTechDocIndex? _cachedDriftTechDocIndex;
McpDatabase? _driftTechDocIndexDb;

/// Provider for a [DriftTechDocIndex] backed by the app database.
///
/// Returns null if no database connection is available.
/// Caches the instance to avoid re-triggering downstream providers.
final driftTechDocIndexProvider = Provider<DriftTechDocIndex?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) {
    _cachedDriftTechDocIndex = null;
    _driftTechDocIndexDb = null;
    return null;
  }
  if (identical(db, _driftTechDocIndexDb) && _cachedDriftTechDocIndex != null) {
    return _cachedDriftTechDocIndex;
  }
  _driftTechDocIndexDb = db;
  _cachedDriftTechDocIndex = DriftTechDocIndex(db);
  return _cachedDriftTechDocIndex;
});
