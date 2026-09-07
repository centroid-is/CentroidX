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
