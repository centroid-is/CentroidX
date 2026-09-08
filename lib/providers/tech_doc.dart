import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import '../core/guarded_knowledge_stores.dart';
import '../tech_docs/pdfrx_text_extractor.dart';
import '../tech_docs/tech_doc_upload_service.dart';
import 'access.dart' show stationNameProvider;
import 'access_policy.dart'
    show RefAuditSink, reportAccessDenial, sessionInForce;
import 'server_database.dart';

/// Cached [GuardedTechDocIndex] instance to avoid creating new instances on
/// every provider read, which would cascade and re-trigger downstream
/// FutureProviders (dbTechDocsProvider, techDocSectionsProvider, etc.).
GuardedTechDocIndex? _cachedTechDocIndex;
McpDatabase? _techDocIndexDb;

/// Provider for the technical-document index backed by the shared app database.
///
/// Returns null when no database connection is available.
/// Caches the instance to avoid re-triggering downstream FutureProviders.
///
/// **What comes out is a [GuardedTechDocIndex], not a [DriftTechDocIndex].**
/// The five writes — store, update-sections, rename, delete and
/// update-PDF-bytes — ask for `configure` and leave an audit row; the seven
/// reads are untouched. `TechDocUploadService` holds a `TechDocIndex`, so no
/// call site changed.
///
/// The session is a callback and the sink is a [RefAuditSink] rather than an
/// awaited value, both so that this provider never rebuilds: a rebuild here
/// re-triggers the whole document list on every sign-in and again when Postgres
/// opens.
final techDocIndexProvider = Provider<TechDocIndex?>((ref) {
  final db = ref.watch(mcpDatabaseProvider);
  if (db == null) {
    _cachedTechDocIndex = null;
    _techDocIndexDb = null;
    return null;
  }
  // Reuse cached instance when DB hasn't changed.
  if (identical(db, _techDocIndexDb) && _cachedTechDocIndex != null) {
    return _cachedTechDocIndex;
  }
  _techDocIndexDb = db;
  _cachedTechDocIndex = GuardedTechDocIndex(
    inner: DriftTechDocIndex(db),
    session: () => sessionInForce(ref),
    audit: RefAuditSink(ref),
    station: ref.read(stationNameProvider),
    onDenied: (denial) => reportAccessDenial(ref, denial),
  );
  return _cachedTechDocIndex;
});

/// Cached [TechDocUploadService] instance.
TechDocUploadService? _cachedUploadService;
TechDocIndex? _uploadServiceIndex;

/// Provider for the [TechDocUploadService].
///
/// Returns null when no database connection is available.
/// Caches the instance to avoid creating new PdfrxTextExtractor on every read.
final techDocUploadServiceProvider = Provider<TechDocUploadService?>((ref) {
  final index = ref.watch(techDocIndexProvider);
  if (index == null) {
    _cachedUploadService = null;
    _uploadServiceIndex = null;
    return null;
  }
  if (identical(index, _uploadServiceIndex) && _cachedUploadService != null) {
    return _cachedUploadService;
  }
  _uploadServiceIndex = index;
  _cachedUploadService =
      TechDocUploadService(index, pdfTextExtractor: PdfrxTextExtractor());
  return _cachedUploadService;
});

/// Optimistic in-memory docs shown immediately while DB store runs.
final pendingTechDocsProvider =
    StateProvider<List<TechDocSummary>>((ref) => []);

/// Doc IDs being deleted — hidden from the list immediately.
final pendingDeleteIdsProvider = StateProvider<List<int>>((ref) => []);

/// Raw DB query — only invalidated when actual DB changes complete.
/// Does NOT watch optimistic state, so changing pending/deleting
/// providers never triggers a DB re-query.
/// Invalidate this (not techDocListProvider) after DB writes complete.
final dbTechDocsProvider = FutureProvider<List<TechDocSummary>>((ref) async {
  final index = ref.watch(techDocIndexProvider);
  if (index == null) return [];
  return index.getSummary();
});

/// Provider for the list of all uploaded technical documents.
///
/// Derives from the DB query and applies optimistic state synchronously:
/// - Filters out docs being deleted (pendingDeleteIdsProvider)
/// - Appends pending uploads (pendingTechDocsProvider)
///
/// Changing optimistic state rebuilds this provider instantly without
/// hitting the database, eliminating the loading-state flash.
final techDocListProvider = Provider<AsyncValue<List<TechDocSummary>>>((ref) {
  final dbAsync = ref.watch(dbTechDocsProvider);
  final pending = ref.watch(pendingTechDocsProvider);
  final deleting = ref.watch(pendingDeleteIdsProvider);

  return dbAsync.whenData((dbDocs) {
    // Filter out docs being deleted.
    final visible = deleting.isEmpty
        ? dbDocs
        : dbDocs.where((d) => !deleting.contains(d.id)).toList();
    if (pending.isEmpty) return visible;
    // Pending docs use negative IDs; filter out any that now exist in DB.
    final dbNames = visible.map((d) => d.name).toSet();
    final stillPending =
        pending.where((p) => !dbNames.contains(p.name)).toList();
    return [...visible, ...stillPending];
  });
});

/// Provider for current upload progress (null when not uploading).
final techDocUploadProgressProvider =
    StateProvider<TechDocUploadProgress?>((ref) => null);

/// Provider for the currently selected document ID (master-detail).
final selectedTechDocProvider = StateProvider<int?>((ref) => null);

/// Monotonically increasing generation counter for doc selection.
///
/// Incremented on every selection click to ensure that rapid clicks
/// (e.g. doc A → doc B → doc A) always produce a fresh provider
/// evaluation, preventing stale PDF bytes from a previous selection.
final techDocSelectionGenProvider = StateProvider<int>((ref) => 0);

/// PDF bytes for the currently selected document.
///
/// Unlike [techDocPdfBytesProvider] (a family provider that caches per-docId),
/// this provider fetches bytes only for the single currently-selected doc.
/// It watches [techDocSelectionGenProvider] so that every click — even back
/// to the same docId — forces a fresh async evaluation. This eliminates
/// the race condition where cached bytes from a previous selection could
/// appear while a different doc is loading.
///
/// Returns null when no document is selected.
final selectedDocPdfBytesProvider =
    FutureProvider<Uint8List?>((ref) async {
  final docId = ref.watch(selectedTechDocProvider);
  // Watch the generation counter to force re-evaluation on every click.
  ref.watch(techDocSelectionGenProvider);
  if (docId == null) return null;

  // Check local cache first — instant if populated during upload.
  final cached = ref.read(pdfBytesCacheProvider).get(docId);
  if (cached != null) return cached;

  // Fall back to DB fetch.
  final index = ref.watch(techDocIndexProvider);
  if (index == null) return null;

  final bytes = await index.getPdfBytes(docId);

  // Before caching, verify the selection hasn't changed during the await.
  // If it has, the result is stale — return null and let the new
  // provider evaluation handle the current selection.
  if (ref.read(selectedTechDocProvider) != docId) return null;

  // Cache for next access.
  if (bytes != null) {
    ref.read(pdfBytesCacheProvider).put(docId, bytes);
  }
  return bytes;
});

/// In-memory PDF bytes cache — avoids re-fetching 10MB+ blobs from remote DB.
///
/// Populated during upload (bytes already in memory), evicted on delete.
/// Falls through to DB fetch on cache miss (cold start / app restart).
final pdfBytesCacheProvider = Provider<PdfBytesCache>((ref) => PdfBytesCache());

/// Simple in-memory cache for PDF byte arrays.
class PdfBytesCache {
  final _cache = <int, Uint8List>{};

  Uint8List? get(int docId) => _cache[docId];
  void put(int docId, Uint8List bytes) => _cache[docId] = bytes;
  void remove(int docId) => _cache.remove(docId);
}

/// Provider for sections of a specific document.
///
/// Uses family pattern so each document ID gets its own future.
/// Single query: SELECT * FROM tech_doc_section WHERE doc_id = ? ORDER BY sort_order.
final techDocSectionsProvider =
    FutureProvider.family<List<TechDocSection>, int>((ref, docId) async {
  final index = ref.watch(techDocIndexProvider);
  if (index == null) return [];
  return index.getSectionsForDoc(docId);
});

/// Provider for PDF bytes of a specific document.
///
/// Checks in-memory cache first (instant after upload), falls back to DB.
final techDocPdfBytesProvider =
    FutureProvider.family<Uint8List?, int>((ref, docId) async {
  // Check local cache first — instant if populated during upload.
  final cached = ref.read(pdfBytesCacheProvider).get(docId);
  if (cached != null) return cached;

  // Fall back to DB fetch (cold start / app restart).
  final index = ref.watch(techDocIndexProvider);
  if (index == null) return null;
  final bytes = await index.getPdfBytes(docId);

  // Cache for next access.
  if (bytes != null) {
    ref.read(pdfBytesCacheProvider).put(docId, bytes);
  }
  return bytes;
});
