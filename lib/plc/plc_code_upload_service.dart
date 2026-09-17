import 'dart:io';

import 'package:tfc_mcp_server/tfc_mcp_server_data.dart';

/// Thin wrapper around [PlcCodeService] for Flutter UI integration.
///
/// Reads file bytes from a file path and delegates to
/// [PlcCodeService.processUpload]. Exposes [hasExistingIndex] for the
/// upload dialog to prompt before replacing an existing index.
class PlcCodeUploadService {
  /// Creates a [PlcCodeUploadService] backed by the given [PlcCodeService].
  PlcCodeUploadService(this._plcCodeService);

  final PlcCodeService _plcCodeService;

  /// Upload a PLC project file for the given [assetKey].
  ///
  /// Reads the file at [sourceFilePath], extracts and parses its contents,
  /// and indexes the PLC code blocks. Returns an [UploadResult] with counts.
  ///
  /// [vendor] specifies the PLC vendor type. If null, auto-detection is used.
  /// [serverAlias] is the optional StateMan server alias for OPC UA scope.
  Future<UploadResult> uploadProject({
    required String sourceFilePath,
    required String assetKey,
    PlcVendor? vendor,
    String? serverAlias,
  }) async {
    final bytes = await File(sourceFilePath).readAsBytes();
    return _plcCodeService.processUpload(
      assetKey,
      bytes,
      vendor: vendor,
      serverAlias: serverAlias,
    );
  }

  /// Whether any PLC code has already been indexed.
  ///
  /// Used by the upload dialog to show a confirmation before replacing.
  bool get hasExistingIndex => _plcCodeService.hasCode;
}
