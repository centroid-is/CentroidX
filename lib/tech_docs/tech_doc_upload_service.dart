import 'dart:typed_data';

import 'package:tfc_access/tfc_access.dart' show AccessDenied;
import 'package:tfc_dart/core/access/guarded_config_store.dart'
    show GuardedConfigStore;
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart' show TechDocIndex;

import '../page_creator/assets/common.dart' show Asset, BaseAsset;
import '../page_creator/assets/registry.dart' show AssetRegistry;
import 'section_detector.dart';

/// Progress update during a document upload operation.
class TechDocUploadProgress {
  /// Human-readable progress message.
  final String message;

  /// Progress fraction from 0.0 to 1.0.
  final double fraction;

  const TechDocUploadProgress(this.message, this.fraction);
}

/// Result of extracting a PDF — all data needed for display before DB sync.
class ExtractedDocument {
  final String name;
  final Uint8List pdfBytes;
  final int pageCount;
  final int sectionCount;
  final List<ParsedSection> sections;

  const ExtractedDocument({
    required this.name,
    required this.pdfBytes,
    required this.pageCount,
    required this.sectionCount,
    required this.sections,
  });
}

/// Abstraction over PDF text extraction for testability.
///
/// The real implementation uses pdfrx; tests inject a stub.
abstract class PdfTextExtractor {
  /// Get page count without extracting text. Fast — just opens PDF structure.
  Future<int> getPageCount(Uint8List pdfBytes);

  /// Extract text fragments from each page of a PDF.
  Future<List<PdfPageFragments>> extractFragments(Uint8List pdfBytes);
}

/// Fragments extracted from a single PDF page.
class PdfPageFragments {
  /// 1-based page number.
  final int pageNumber;

  /// Text fragments with their bounding box heights.
  final List<SizedFragment> fragments;

  const PdfPageFragments({
    required this.pageNumber,
    required this.fragments,
  });
}

/// Service for uploading, replacing, and managing technical documents.
///
/// Pipeline: PDF bytes -> size check -> text extraction -> SectionDetector
/// -> TechDocIndex.storeDocument.
///
/// Extraction is abstracted behind [PdfTextExtractor] for testability.
/// In production, use [PdfrxTextExtractor] which wraps pdfrx.
class TechDocUploadService {
  final TechDocIndex _techDocIndex;
  final SectionDetector _sectionDetector;
  final PdfTextExtractor _pdfTextExtractor;

  TechDocUploadService(
    this._techDocIndex, {
    SectionDetector? sectionDetector,
    PdfTextExtractor? pdfTextExtractor,
  })  : _sectionDetector = sectionDetector ?? const SectionDetector(),
        _pdfTextExtractor = pdfTextExtractor ?? _NoOpExtractor();

  /// Get page count without extracting text. Fast — opens PDF structure only.
  Future<int> getPageCount(Uint8List pdfBytes) {
    return _pdfTextExtractor.getPageCount(pdfBytes);
  }

  /// Extract sections from a stored document and update in DB.
  ///
  /// This is the slow part (text extraction + section detection + DB write).
  /// Designed to run in background after [storeDocumentShell] returns.
  Future<void> extractAndStoreSections({
    required int docId,
    required Uint8List pdfBytes,
  }) async {
    final pageFragments = await _pdfTextExtractor.extractFragments(pdfBytes);
    final allFragments = pageFragments.expand((p) => p.fragments).toList();
    final sections = _sectionDetector.detectSections(allFragments);
    await _techDocIndex.updateSections(
      docId,
      sections,
      pageCount: pageFragments.length,
    );
  }

  /// Extract text and detect sections — CPU work only, no DB.
  ///
  /// Returns an [ExtractedDocument] with all data needed for display.
  /// Call [storeExtracted] afterwards to persist to database.
  Future<ExtractedDocument> extractDocument({
    required Uint8List pdfBytes,
    required String name,
    int maxFileSizeBytes = 50 * 1024 * 1024,
  }) async {
    if (pdfBytes.length > maxFileSizeBytes) {
      throw ArgumentError(
        'File size ${pdfBytes.length} bytes exceeds limit of $maxFileSizeBytes bytes',
      );
    }

    final pageFragments = await _pdfTextExtractor.extractFragments(pdfBytes);

    final allFragments = <SizedFragment>[];
    for (final page in pageFragments) {
      allFragments.addAll(page.fragments);
    }

    final sections = _sectionDetector.detectSections(allFragments);

    return ExtractedDocument(
      name: name,
      pdfBytes: pdfBytes,
      pageCount: pageFragments.length,
      sectionCount: sections.length,
      sections: sections,
    );
  }

  /// Persist an already-extracted document to the database.
  ///
  /// This is the slow part (blob write + section inserts). Designed to
  /// run in the background after [extractDocument] returns display data.
  Future<int> storeExtracted(ExtractedDocument doc) {
    return _techDocIndex.storeDocument(
      name: doc.name,
      pdfBytes: doc.pdfBytes,
      sections: doc.sections,
      pageCount: doc.pageCount,
    );
  }

  /// Upload a PDF document: extract text, detect sections, store.
  ///
  /// Convenience method that runs [extractDocument] + [storeExtracted]
  /// sequentially. For optimistic UI, call them separately instead.
  Future<int> uploadDocument({
    required Uint8List pdfBytes,
    required String name,
    void Function(TechDocUploadProgress)? onProgress,
    int maxFileSizeBytes = 50 * 1024 * 1024,
  }) async {
    onProgress?.call(
        const TechDocUploadProgress('Extracting text...', 0.0));

    final doc = await extractDocument(
      pdfBytes: pdfBytes,
      name: name,
      maxFileSizeBytes: maxFileSizeBytes,
    );

    onProgress?.call(TechDocUploadProgress(
        'Storing ${doc.pageCount} pages, ${doc.sectionCount} sections...',
        0.75));

    final docId = await storeExtracted(doc);

    onProgress?.call(const TechDocUploadProgress('Complete', 1.0));

    return docId;
  }

  /// Replace a document's PDF and sections by re-extracting from new PDF bytes.
  ///
  /// Keeps the same document ID. All asset links are preserved.
  /// Updates both the PDF blob and the extracted sections.
  Future<void> replaceDocument({
    required int docId,
    required Uint8List pdfBytes,
    void Function(TechDocUploadProgress)? onProgress,
    int maxFileSizeBytes = 50 * 1024 * 1024,
  }) async {
    if (pdfBytes.length > maxFileSizeBytes) {
      throw ArgumentError(
        'File size ${pdfBytes.length} bytes exceeds limit of $maxFileSizeBytes bytes',
      );
    }

    onProgress?.call(
        const TechDocUploadProgress('Extracting text from PDF...', 0.0));

    final pageFragments = await _pdfTextExtractor.extractFragments(pdfBytes);
    final allFragments = <SizedFragment>[];
    for (final page in pageFragments) {
      allFragments.addAll(page.fragments);
    }

    onProgress?.call(
        const TechDocUploadProgress('Detecting sections...', 0.5));

    final sections = _sectionDetector.detectSections(allFragments);

    onProgress?.call(
        const TechDocUploadProgress('Updating document...', 0.75));

    // Update PDF blob AND sections — replaceDocument must replace everything.
    await _techDocIndex.updatePdfBytes(docId, pdfBytes);
    await _techDocIndex.updateSections(
      docId,
      sections,
      pageCount: pageFragments.length,
    );

    onProgress?.call(const TechDocUploadProgress('Complete', 1.0));
  }

  /// Delete a document, having first cleared `techDocId` from every asset
  /// that linked to it (TD-12).
  ///
  /// The layout is the **shared** one — one `config_item` row per top-level
  /// asset — and the strip goes through [GuardedConfigStore]: gated on
  /// `configure`, one audit row, and one `config_change` row per asset that
  /// actually moved. An asset that never referenced the document is not
  /// rewritten, and a document nothing references writes nothing at all.
  ///
  /// ## This is a behaviour change, and it is the point
  ///
  /// Until milestone v1.2 plan 03-05 this method removed nothing. It tested
  /// `assets is! Map<String, dynamic>` and skipped the page when that failed,
  /// but `AssetPage` serialises its assets as a **List**, so every real page
  /// was skipped; and it read and wrote the **device-local** `page_editor_data`
  /// while the layout the plant sees lives in the shared rows. Two independent
  /// no-ops, and the fixture it was tested against built `assets` as a map —
  /// a shape production cannot produce — which is why both survived review.
  /// See `docs/relational-config-deferred-defects.md` D-4.
  ///
  /// ## Top-level assets only
  ///
  /// A composite's subdevices live inside its own payload rather than in rows
  /// of their own (see `core/config/page_codec.dart`), so a document linked
  /// from one slice of a rack rewrites the **whole parent row**. That is the
  /// documented consequence of the row shape, not an oversight.
  Future<void> deleteAndCleanAssets({
    required int docId,
    required GuardedConfigStore configStore,
  }) async {
    // The layout first and the document second, and every store failure
    // below aborts before the delete: a document removed while its references
    // survived is exactly the dangling link this method exists to prevent.
    try {
      final stored = configStore.inner.itemsOf(const {ConfigKind.asset});
      final wanted = <ConfigItem>[];
      var touched = false;
      for (final item in stored) {
        final stripped = _withoutTechDoc(item, docId);
        touched = touched || stripped != null;
        wanted.add(stripped ?? item);
      }
      // Nothing referenced it: no row, no change row, no audit row. The
      // whole asset set is handed over because the write is a replace within
      // `{asset}` — a partial set would delete every asset left out of it.
      if (touched) {
        await configStore.save(wanted, kind: ConfigKind.asset,
            reason: 'tech doc $docId deleted');
      }
    } on AccessDenied {
      // A refused write is not a malformed layout. Without this arm the
      // blanket catch below swallows the guard's refusal and the delete
      // carries on as though the cleanup had succeeded — which is the one
      // failure mode a guard must never have.
      rethrow;
    } on ConfigStoreOfflineException {
      rethrow;
    } on ConfigStoreUnsafePoolException {
      rethrow;
    } on ConfigConflict {
      // The same reasoning as the arm above, one layer down: offline, an
      // unsafe pool and a losing CAS all mean the layout was not cleaned, so
      // the document must not be deleted either. These are the editor's three
      // catch arms, and they must not be reachable by the blanket catch.
      rethrow;
    } catch (_) {
      // An asset row whose payload will not decode is not a reason to keep a
      // document the operator deleted. Skip the cleanup.
    }

    await _techDocIndex.deleteDocument(docId);
  }
}

/// [item] with [docId] cleared wherever it appears, or null if it never did.
ConfigItem? _withoutTechDoc(ConfigItem item, int docId) {
  final json = item.decode();
  if (!_referencesDoc(json, docId)) return null;

  // Through the model, never `json.remove('techDocId')`: the field is emitted
  // explicitly by some assets and omitted when null by others, and only the
  // generated `toJson` produces the canonical form. A hand-edited payload
  // would diff as an edit against whatever the next real save writes.
  final parsed = AssetRegistry.parse(<String, dynamic>{
    'assets': <dynamic>[json]
  });
  if (parsed.length != 1) {
    // An asset type this build cannot construct: `AssetRegistry.parse` drops
    // what it cannot parse rather than throwing, so re-encoding here would
    // write an emptied row over somebody's equipment. Leave the row exactly
    // as it stands — a dangling id is the smaller harm, and a visible one.
    return null;
  }

  final asset = parsed.single;
  for (final node in _selfAndDescendants(asset)) {
    if (node is BaseAsset && node.techDocId == docId) {
      node.techDocId = null;
    }
  }
  return ConfigItem.of(
    kind: item.kind,
    id: item.id,
    value: asset.toJson(),
    scope: item.scope,
    parentId: item.parentId,
    sortIndex: item.sortIndex,
  );
}

/// Whether [json] names [docId] as a `techDocId` at **any** depth.
///
/// The subdevice tree included, deliberately: a composite carries its children
/// inside its own payload, so the reference may be several levels down while
/// the row that has to be rewritten is still the top-level parent's.
bool _referencesDoc(Object? json, int docId) {
  if (json is Map) {
    if (json['techDocId'] == docId) return true;
    return json.values.any((value) => _referencesDoc(value, docId));
  }
  if (json is List) {
    return json.any((value) => _referencesDoc(value, docId));
  }
  return false;
}

/// [asset] and everything drawn inside it, depth-first.
Iterable<Asset> _selfAndDescendants(Asset asset) sync* {
  yield asset;
  for (final child in asset.childAssets) {
    yield* _selfAndDescendants(child);
  }
}

/// No-op extractor for when no real PDF extraction is available.
class _NoOpExtractor implements PdfTextExtractor {
  @override
  Future<int> getPageCount(Uint8List pdfBytes) async => 0;

  @override
  Future<List<PdfPageFragments>> extractFragments(Uint8List pdfBytes) async =>
      [];
}
