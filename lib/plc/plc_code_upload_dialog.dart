import 'package:file_picker/file_picker.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:tfc_mcp_server/tfc_mcp_server_data.dart';

import 'plc_code_upload_service.dart';

/// Dialog widget for uploading PLC project files with vendor selection.
///
/// Supports both Beckhoff TwinCAT (.zip) and Schneider Electric
/// Control Expert / Machine Expert (.xef, .xml) project exports.
///
/// Uses [FilePicker] to select the appropriate file type based on vendor,
/// shows a progress indicator during extraction and indexing, and displays
/// a completion summary with block and variable counts from [UploadResult].
///
/// A server alias dropdown is always shown, with a "(default)" option
/// (maps to no specific server alias) followed by any aliases from
/// [serverAliases]. The user must select a server alias before uploading.
///
/// If an existing PLC index exists for the asset, a confirmation dialog is
/// shown before replacing it.
///
/// The asset key used for indexing is derived from the selected server alias,
/// or from the uploaded file name when "(default)" is selected.
class PlcCodeUploadDialog extends StatefulWidget {
  /// Creates a [PlcCodeUploadDialog].
  ///
  /// [uploadService] handles the upload and indexing pipeline.
  /// [serverAliases] is the list of available server aliases from
  /// StateManConfig (OPC UA and JBTM servers). When empty, the server
  /// alias dropdown is hidden.
  const PlcCodeUploadDialog({
    super.key,
    required this.uploadService,
    this.serverAliases = const [],
  });

  /// Service for uploading and indexing PLC code.
  final PlcCodeUploadService uploadService;

  /// Available server aliases from StateManConfig.
  ///
  /// Shown in the server alias dropdown after the "(default)" option.
  /// When empty, only "(default)" is available.
  final List<String> serverAliases;

  @override
  State<PlcCodeUploadDialog> createState() => _PlcCodeUploadDialogState();
}

class _PlcCodeUploadDialogState extends State<PlcCodeUploadDialog> {
  String? _selectedFilePath;
  bool _isUploading = false;
  UploadResult? _uploadResult;
  PlcVendor _selectedVendor = PlcVendor.twincat;
  String? _selectedServerAlias;

  /// Sentinel value for the "(default)" server alias option.
  ///
  /// When selected, no specific server alias is passed to the upload.
  static const _kDefaultAlias = '';

  /// The effective asset key for the upload.
  ///
  /// Uses the selected server alias when it is a real alias (not the
  /// "(default)" sentinel). Otherwise derives a key from the uploaded
  /// file name (base name without extension).
  String? get _effectiveAssetKey {
    if (_selectedServerAlias != null &&
        _selectedServerAlias != _kDefaultAlias) {
      return _selectedServerAlias;
    }
    if (_selectedFilePath != null) {
      return p.basenameWithoutExtension(_selectedFilePath!);
    }
    return null;
  }

  /// Whether the upload button should be enabled.
  ///
  /// Requires a file to be selected, no upload in progress,
  /// and a server alias selection (either "(default)" or a real alias).
  bool get _canUpload =>
      !_isUploading &&
      _selectedFilePath != null &&
      _selectedServerAlias != null;

  /// File extensions accepted for the currently selected vendor.
  List<String> get _allowedExtensions {
    switch (_selectedVendor) {
      case PlcVendor.twincat:
        return ['zip', 'tnzip'];
      case PlcVendor.schneiderControlExpert:
      case PlcVendor.schneiderMachineExpert:
        return ['xef', 'xml', 'zip'];
    }
  }

  /// Dialog title for the file picker based on vendor.
  String get _filePickerTitle {
    switch (_selectedVendor) {
      case PlcVendor.twincat:
        return 'Select TwinCAT Project Archive';
      case PlcVendor.schneiderControlExpert:
        return 'Select Control Expert XEF Export';
      case PlcVendor.schneiderMachineExpert:
        return 'Select Machine Expert XML Export';
    }
  }

  /// Prompt shown on the file picker button when no file is selected.
  String get _filePickerPrompt {
    switch (_selectedVendor) {
      case PlcVendor.twincat:
        return 'Select TwinCAT .tnzip or .zip file...';
      case PlcVendor.schneiderControlExpert:
        return 'Select .xef file...';
      case PlcVendor.schneiderMachineExpert:
        return 'Select .xml file...';
    }
  }

  /// Instruction text shown below the vendor dropdown.
  String get _vendorInstructions {
    switch (_selectedVendor) {
      case PlcVendor.twincat:
        return 'TwinCAT 3 (XAE):\n'
            '1. Open your project in TwinCAT / Visual Studio\n'
            '2. Go to File > Save as Archive...\n'
            '3. Save the .tnzip archive file\n'
            '4. Upload the .tnzip file here\n\n'
            'Alternatively, export as .zip containing .TcPOU, .TcGVL, '
            'and .st files.';
      case PlcVendor.schneiderControlExpert:
        return 'Control Expert (Unity Pro):\n'
            '1. File > Export Project > save as .ZEF file\n'
            '2. Rename .ZEF to .zip, extract to find .XEF file\n'
            '3. Upload the .XEF file';
      case PlcVendor.schneiderMachineExpert:
        return 'Machine Expert (EcoStruxure):\n'
            '1. Project > Export PLCopenXML...\n'
            '2. Select the POUs to export\n'
            '3. Save as .xml file\n'
            '4. Upload the .xml file';
    }
  }

  Future<void> _pickFile() async {
    final pick = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      dialogTitle: _filePickerTitle,
    );

    if (pick != null && pick.files.single.path != null) {
      setState(() {
        _selectedFilePath = pick.files.single.path!;
      });
    }
  }

  Future<void> _upload() async {
    if (_selectedFilePath == null) return;

    // Confirm before replacing an existing index
    if (widget.uploadService.hasExistingIndex) {
      final confirmed = await showConfirmDialog(
        context: context,
        title: 'Replace existing index?',
        message: 'This asset already has PLC code indexed. '
            'Replace existing index?',
        confirmLabel: 'Replace',
        destructive: true,
      );

      if (!confirmed) return;
    }

    setState(() => _isUploading = true);

    try {
      final effectiveAlias =
          _selectedServerAlias == _kDefaultAlias ? null : _selectedServerAlias;
      final result = await widget.uploadService.uploadProject(
        sourceFilePath: _selectedFilePath!,
        assetKey: _effectiveAssetKey!,
        vendor: _selectedVendor,
        serverAlias: effectiveAlias,
      );

      if (mounted) {
        setState(() {
          _uploadResult = result;
          _isUploading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PLC upload failed: $e')),
        );
        setState(() => _isUploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Completion summary view
    if (_uploadResult != null) {
      return _buildSummaryDialog(context);
    }

    // File selection and upload view
    return StandardDialogFrame(
      title: 'Upload PLC project',
      icon: Icons.upload_file,
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: _isUploading ? null : () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: 'Upload',
          icon: Icons.upload,
          onPressed: _canUpload ? _upload : null,
        ),
      ],
      child: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Vendor dropdown
              const Text('PLC Vendor',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              DropdownButtonFormField<PlcVendor>(
                key: const ValueKey('plc-vendor-dropdown'),
                value: _selectedVendor,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: PlcVendor.twincat,
                    child: Text('Beckhoff (TwinCAT)'),
                  ),
                  DropdownMenuItem(
                    value: PlcVendor.schneiderControlExpert,
                    child: Text('Schneider (Control Expert)'),
                  ),
                  DropdownMenuItem(
                    value: PlcVendor.schneiderMachineExpert,
                    child: Text('Schneider (Machine Expert)'),
                  ),
                ],
                onChanged: _isUploading
                    ? null
                    : (vendor) {
                        if (vendor != null) {
                          setState(() {
                            _selectedVendor = vendor;
                            // Clear file selection when vendor changes
                            _selectedFilePath = null;
                          });
                        }
                      },
              ),
              const SizedBox(height: 8),

              // Vendor-specific instructions
              Text(
                _vendorInstructions,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),

              // Server alias dropdown (always shown)
              const Text('Server Alias',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                key: const ValueKey('plc-server-alias-dropdown'),
                value: _selectedServerAlias,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                  hintText: 'Select server...',
                ),
                items: [
                  const DropdownMenuItem(
                    value: _kDefaultAlias,
                    child: Text('(default)'),
                  ),
                  ...widget.serverAliases.map((alias) => DropdownMenuItem(
                        value: alias,
                        child: Text(alias),
                      )),
                ],
                onChanged: _isUploading
                    ? null
                    : (alias) {
                        setState(() {
                          _selectedServerAlias = alias;
                        });
                      },
              ),
              const SizedBox(height: 12),

              // File picker
              OutlinedButton.icon(
                onPressed: _isUploading ? null : _pickFile,
                icon: const Icon(Icons.file_open),
                label: Text(
                  _selectedFilePath != null
                      ? p.basename(_selectedFilePath!)
                      : _filePickerPrompt,
                ),
              ),
              const SizedBox(height: 8),

              if (_isUploading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                const Center(
                  child: Text('Extracting and indexing PLC code...'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryDialog(BuildContext context) {
    final result = _uploadResult!;

    // Format block type breakdown
    final typeBreakdown = result.blockTypeCounts.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');

    return StandardDialogFrame(
      title: 'Upload complete',
      icon: Icons.check_circle_outline,
      showClose: false,
      actions: [
        PaneAction.primary(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryRow('Blocks', '${result.totalBlocks} ($typeBreakdown)'),
            const SizedBox(height: 8),
            _summaryRow('Variables', '${result.totalVariables}'),
            if (result.skippedFiles > 0) ...[
              const SizedBox(height: 8),
              _summaryRow('Skipped', '${result.skippedFiles} files'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            '$label:',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}
