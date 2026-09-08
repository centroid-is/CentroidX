import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import '../core/guarded_knowledge_stores.dart';
import '../drawings/drawing_upload_service.dart';
import 'access.dart' show stationNameProvider;
import 'access_policy.dart'
    show RefAuditSink, reportAccessDenial, sessionInForce;
import 'server_database.dart';

/// The drawing index behind the knowledge-base guard.
///
/// Both providers below wrap at construction rather than sharing one cached
/// instance, which is the shape they already had. `storeDrawing` and
/// `deleteDrawing` ask for `configure` and leave an audit row; `search`,
/// `isEmpty` and `getDrawingSummary` are untouched.
///
/// The session is a callback and the sink is a [RefAuditSink] rather than an
/// awaited value, so neither provider rebuilds when a session changes or when
/// Postgres opens.
GuardedDrawingIndex _guarded(Ref ref, McpDatabase db) => GuardedDrawingIndex(
      inner: DriftDrawingIndex(db),
      session: () => sessionInForce(ref),
      audit: RefAuditSink(ref),
      station: ref.read(stationNameProvider),
      onDenied: (denial) => reportAccessDenial(ref, denial),
    );

/// Provider for the [DrawingUploadService].
///
/// Wired with the guarded drawing index from the shared [mcpDatabaseProvider].
/// Returns null when database is not available (upload FAB shows error).
///
/// `DrawingUploadDialog` has no caller in the tree today, so these writes are
/// reachable in principle and unwired in fact — guarded anyway, so the day
/// somebody mounts that dialog the guard is already in front of it.
final drawingUploadServiceProvider = Provider<DrawingUploadService?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) return null;
  return DrawingUploadService(_guarded(ref, db));
});

/// Provider for the [DrawingIndex] interface.
///
/// Returns null when the database is not available.
/// Used by the debug asset pipeline to pre-fetch relevant electrical drawings.
final drawingIndexProvider = Provider<DrawingIndex?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) return null;
  return _guarded(ref, db);
});

/// Provider for the list of uploaded drawings.
final drawingListProvider = FutureProvider<List<DrawingSummary>>((ref) async {
  final service = ref.watch(drawingUploadServiceProvider);
  if (service == null) return [];
  return service.getDrawings();
});
