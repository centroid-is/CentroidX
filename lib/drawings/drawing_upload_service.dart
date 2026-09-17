import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart';

/// Service for uploading and managing electrical drawing PDFs.
///
/// Handles PDF text extraction via pdfrx, copies files to app storage,
/// and delegates indexing to [DrawingIndex].
class DrawingUploadService {
  /// Creates a [DrawingUploadService] backed by the given [DrawingIndex].
  DrawingUploadService(this._drawingIndex);

  final DrawingIndex _drawingIndex;

  /// Extract text from each page of a PDF file.
  Future<List<DrawingPageText>> extractPageTexts(String filePath) async {
    final document = await PdfDocument.openFile(filePath);
    final pageTexts = <DrawingPageText>[];
    for (int i = 0; i < document.pages.length; i++) {
      final page = document.pages[i];
      final text = await page.loadText();
      pageTexts.add(DrawingPageText(
        pageNumber: i + 1,
        fullText: text?.fullText ?? '',
      ));
    }
    return pageTexts;
  }

  /// Upload a PDF drawing: copy to app storage, extract text, index.
  Future<void> uploadDrawing({
    required String sourceFilePath,
    required String assetKey,
    required String drawingName,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final drawingsDir = Directory(p.join(appDir.path, 'drawings'));
    await drawingsDir.create(recursive: true);
    final destPath = p.join(drawingsDir.path, p.basename(sourceFilePath));
    await File(sourceFilePath).copy(destPath);

    final pageTexts = await extractPageTexts(destPath);
    await _drawingIndex.storeDrawing(
      assetKey: assetKey,
      drawingName: drawingName,
      filePath: destPath,
      pageTexts: pageTexts,
    );
  }

  /// Upload with pre-extracted page texts (for testing without pdfrx).
  Future<void> uploadDrawingWithTexts({
    required String assetKey,
    required String drawingName,
    required String filePath,
    required List<DrawingPageText> pageTexts,
  }) async {
    await _drawingIndex.storeDrawing(
      assetKey: assetKey,
      drawingName: drawingName,
      filePath: filePath,
      pageTexts: pageTexts,
    );
  }

  /// Get a list of all stored drawings.
  Future<List<DrawingSummary>> getDrawings() =>
      _drawingIndex.getDrawingSummary();

  /// Delete a drawing by name.
  Future<void> deleteDrawing(String name) =>
      _drawingIndex.deleteDrawing(name);
}
