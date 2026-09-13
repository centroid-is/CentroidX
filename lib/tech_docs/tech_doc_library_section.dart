import 'dart:async';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart' show AccessDenied;
import 'package:tfc_dart/core/fuzzy_match.dart';
import 'package:tfc_dart/core/config/config_store_errors.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show TechDocIndex, TechDocSummary, PlcAssetSummary;

import '../chat/ai_context_action.dart';
import '../core/feature_flags.dart';
import '../core/guarded_knowledge_stores.dart'
    show PlcCodeIndexExtras, kKnowledgeWriteGroup;
import '../plc/plc_code_upload_dialog.dart';
import '../plc/plc_detail_panel.dart';
import '../providers/access.dart' show accessSessionProvider;
import '../providers/config_store.dart' show configStoreProvider;
import '../providers/plc.dart';
import '../providers/scaffold_messenger_key.dart';
import '../providers/tech_doc.dart';
import 'tech_doc_audit.dart';
import 'tech_doc_section_detail_panel.dart';
import 'tech_doc_upload_service.dart';

/// Builds a structured prompt for the LLM to discuss a tech document.
///
/// The message instructs the AI copilot to retrieve and summarise the
/// document's contents, sections, and any related assets or drawings.
String buildChatAboutDocMessage(String docName) {
  return '''Chat about document: $docName

Please gather all available information about this technical document including:
- Document sections and table of contents (use search_tech_docs to find it, then get_tech_doc_section for key sections)
- Any related assets or equipment mentioned in the document (use list_assets to cross-reference)
- Related electrical drawings if applicable (use search_drawings)
- Related PLC code blocks if applicable (use search_plc_code)
Then provide a summary of what this document covers and how it relates to the system.''';
}

final _logger = Logger(printer: SimplePrinter(printTime: false));

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// Knowledge Base section showing tech docs and PLC code in a unified list.
///
/// Renders as an ExpansionTile with a master-detail layout:
/// - Left: DataTable with sortable columns, text filter, upload, drag-drop
/// - Right: Section detail panel when a document is selected
///
/// All write operations go through [auditTechDocOperation] (locked decision).
/// Write operations (upload, rename, delete, replace) need
/// [kKnowledgeWriteGroup] -- the one place that answer lives.
class TechDocLibrarySection extends ConsumerStatefulWidget {
  const TechDocLibrarySection({super.key, this.embedded = true});

  /// When true (default), renders inside an ExpansionTile for the Preferences page.
  /// When false, renders content directly for use in a standalone page.
  final bool embedded;

  @override
  ConsumerState<TechDocLibrarySection> createState() =>
      _TechDocLibrarySectionState();
}

class _TechDocLibrarySectionState extends ConsumerState<TechDocLibrarySection> {
  String _filter = '';
  String _sortColumn = 'name';
  bool _sortAscending = true;
  int? _editingDocId;
  String? _editingPlcAssetKey;
  late TextEditingController _renameController;

  @override
  void initState() {
    super.initState();
    _renameController = TextEditingController();
  }

  @override
  void dispose() {
    _renameController.dispose();
    super.dispose();
  }

  /// Whether this session may write to the knowledge base.
  ///
  /// Literally the store guard's own predicate -- `guarded_knowledge_stores`
  /// asks `session.can(kKnowledgeWriteGroup)` before every one of its eleven
  /// writes -- so the button and the write it offers cannot disagree.
  ///
  /// `watch`, not `read`: this getter feeds `build`, and the upload affordance
  /// has to appear when somebody signs in and go away when the session times
  /// out, without a restart. `base_scaffold.dart:248` is the precedent; the
  /// `ref.read`-only rule in `access_policy.dart` is about *providers* holding
  /// connections, not about widgets.
  ///
  /// `?? false` while the session loads or errors, rather than resolving
  /// through `sessionInForce`: no narrower, since `kSessionWhileLoading` does
  /// not hold [kKnowledgeWriteGroup] either, and it answers without awaiting a
  /// chain that reaches the database.
  bool get _isWriteEnabled =>
      ref.watch(accessSessionProvider).valueOrNull?.can(kKnowledgeWriteGroup) ??
      false;

  /// Who a write is attributed to: the signed-in username, or [_anonymousWho].
  ///
  /// This used to read a process environment variable and fall back to a fixed
  /// placeholder, so an unattended panel signed its audit rows with a name
  /// nobody holds -- the sharpest instance of the defect this milestone
  /// removes. The session is the only identity in this system, so it is the
  /// only thing that may sign a row.
  ///
  /// [_anonymousWho] when nobody is signed in, because that is what every guard
  /// in this repo already records for an unattended station -- allowed and
  /// denied, reads and writes alike (`guarded_knowledge_stores.dart:254` puts
  /// it on every row it builds, and six other files declare the same const).
  /// "Nobody was signed in" is a true and useful thing to record; refusing here
  /// instead would record nothing at all.
  ///
  /// That case is reachable, not theoretical. `AccessSession.anonymous`
  /// (`packages/tfc_access/lib/src/access_session.dart`) builds its groups from
  /// the customer-editable `Operator` role, so an admin who ticks `configure`
  /// on that row hands [kKnowledgeWriteGroup] to every panel on the floor with
  /// nobody signed in. On such a station the affordances render and the writes
  /// the configured policy permits must go through. [_isWriteEnabled] still
  /// gates them, so an anonymous session *without* `configure` never reaches
  /// this getter.
  ///
  /// `read`, not `watch`: this answers "who is signing this write" once, at the
  /// instant of the write. Only [_isWriteEnabled] has to stay live.
  String get _writeUser =>
      ref.read(accessSessionProvider).valueOrNull?.user?.username ??
      _anonymousWho;

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: _buildContent(context),
      );
    }

    return ExpansionTile(
      title: const Text('Knowledge Base'),
      leading: const Icon(Icons.library_books),
      initiallyExpanded: false,
      children: [
        SizedBox(
          height: 500,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final docsAsync = ref.watch(techDocListProvider);
    final plcAsync = ref.watch(plcAssetSummaryProvider);
    final selectedDocId = ref.watch(selectedTechDocProvider);
    final selectedPlcAsset = ref.watch(selectedPlcAssetProvider);

    // Use hasValue check to keep showing previous data during reloads,
    // preventing the full-screen spinner flash on invalidate.
    if (docsAsync.isLoading && !docsAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    if (docsAsync.hasError && !docsAsync.hasValue) {
      return Center(child: Text('Error loading documents: ${docsAsync.error}'));
    }
    final docs = docsAsync.valueOrNull ?? [];
    final plcSummaries = plcAsync.valueOrNull ?? [];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left: master table
        Expanded(
            flex: 3, child: _buildMasterTable(context, docs, plcSummaries)),
        // Right: detail panel (when a tech doc or PLC asset is selected)
        if (selectedDocId != null) ...[
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: TechDocSectionDetailPanel(docId: selectedDocId),
          ),
        ] else if (selectedPlcAsset != null) ...[
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: PlcDetailPanel(assetKey: selectedPlcAsset),
          ),
        ],
      ],
    );
  }

  Widget _buildMasterTable(BuildContext context, List<TechDocSummary> docs,
      List<PlcAssetSummary> plcSummaries) {
    final uploadProgress = ref.watch(techDocUploadProgressProvider);

    // While a search is active, order by match relevance instead of the
    // chosen sort column.
    var filtered = fuzzyFilter<TechDocSummary>(docs, _filter, [(d) => d.name]);
    if (_filter.isEmpty) filtered = _sortDocs(filtered.toList());

    final filteredPlc =
        fuzzyFilter<PlcAssetSummary>(plcSummaries, _filter, [(p) => p.assetKey]);

    final totalItems = filtered.length + filteredPlc.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filter bar
        TextField(
          decoration: const InputDecoration(
            hintText: 'Filter resources...',
            prefixIcon: Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: 8),

        // Upload buttons + progress (kKnowledgeWriteGroup only)
        if (_isWriteEnabled) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload PDF'),
                onPressed:
                    uploadProgress != null ? null : () => _pickAndUpload(),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.code),
                label: const Text('Upload PLC Project'),
                onPressed: uploadProgress != null
                    ? null
                    : () => _showPlcUploadDialog(),
              ),
              if (uploadProgress != null) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                Text(
                  uploadProgress.message,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'or drag PDFs here',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 8),
        ],

        // Sticky header row
        _buildHeaderRow(context),
        const Divider(height: 1),

        // Scrollable data rows
        Expanded(
          child: totalItems == 0
              ? const Center(
                  child: Text('No resources found',
                      style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  itemCount: totalItems,
                  itemBuilder: (ctx, i) {
                    if (i < filtered.length) {
                      return _buildRow(ctx, filtered[i]);
                    }
                    return _buildPlcRow(
                        ctx, filteredPlc[i - filtered.length]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildHeaderRow(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.bold,
        );

    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          _buildSortableHeader('Name', 'name', style, flex: 3),
          _buildSortableHeader('Pages', 'pages', style),
          _buildSortableHeader('Sections', 'sections', style),
          _buildSortableHeader('Upload Date', 'uploadDate', style, flex: 2),
        ],
      ),
    );
  }

  Widget _buildSortableHeader(String label, String column, TextStyle? style,
      {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: () {
          setState(() {
            if (_sortColumn == column) {
              _sortAscending = !_sortAscending;
            } else {
              _sortColumn = column;
              _sortAscending = true;
            }
          });
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, style: style, overflow: TextOverflow.ellipsis),
            ),
            if (_sortColumn == column)
              Icon(
                _sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, TechDocSummary doc) {
    final selectedId = ref.watch(selectedTechDocProvider);
    final isSelected = selectedId == doc.id;
    final isPending = doc.id < 0;
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');

    return Opacity(
      opacity: isPending ? 0.45 : 1.0,
      child: InkWell(
        onTap: isPending
            ? null
            : () {
                // Mutually exclusive with PLC asset selection.
                ref.read(selectedPlcAssetProvider.notifier).state = null;
                ref.read(selectedTechDocProvider.notifier).state =
                    isSelected ? null : doc.id;
              },
        onSecondaryTapUp: isPending
            ? null
            : (details) => _showContextMenu(context, details, doc),
        child: Container(
          color: isSelected
              ? Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.3)
              : null,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          child: Row(
            children: [
              // Name column (editable if kKnowledgeWriteGroup and editing)
              Expanded(
                flex: 3,
                child: _editingDocId == doc.id
                    ? TextField(
                        controller: _renameController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (newName) =>
                            _performRename(doc.id, newName),
                        onEditingComplete: () =>
                            setState(() => _editingDocId = null),
                      )
                    : GestureDetector(
                        onDoubleTap: _isWriteEnabled && !isPending
                            ? () {
                                setState(() {
                                  _editingDocId = doc.id;
                                  _renameController.text = doc.name;
                                });
                              }
                            : null,
                        child: Row(
                          children: [
                            const Icon(Icons.picture_as_pdf,
                                size: 16, color: Colors.red),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(doc.name,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            if (isPending) ...[
                              const SizedBox(width: 8),
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child:
                                    CircularProgressIndicator(strokeWidth: 1.5),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
              // Pages — '...' only while extracting (count still 0).
              Expanded(
                child: Text(
                  isPending && doc.pageCount == 0 ? '...' : '${doc.pageCount}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Sections
              Expanded(
                child: Text(
                  isPending && doc.sectionCount == 0
                      ? '...'
                      : '${doc.sectionCount}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Upload Date
              Expanded(
                flex: 2,
                child: Text(
                  dateFormat.format(doc.uploadedAt),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
    BuildContext context,
    TapUpDetails details,
    TechDocSummary doc,
  ) async {
    final items = <PopupMenuEntry<String>>[];

    // "Chat about this" — only when MCP chat is available.
    if (kChatEnabled) {
      items.add(const PopupMenuItem(
        value: 'chat',
        child: ListTile(
          leading: Icon(Icons.chat),
          title: Text('Chat about this'),
          dense: true,
        ),
      ));
    }

    if (_isWriteEnabled) {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      items.addAll([
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.edit),
            title: Text('Rename'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: 'replace',
          child: ListTile(
            leading: Icon(Icons.upload),
            title: Text('Replace PDF'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete),
            title: Text('Delete'),
            dense: true,
          ),
        ),
      ]);
    }

    // Nothing to show (no MCP, no write access).
    if (items.isEmpty) return;

    final value = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: items,
    );

    if (value == null || !mounted) return;
    switch (value) {
      case 'chat':
        if (kChatEnabled) _chatAboutDocument(doc);
      case 'rename':
        setState(() {
          _editingDocId = doc.id;
          _renameController.text = doc.name;
        });
      case 'replace':
        _replaceDocument(doc);
      case 'delete':
        _confirmDelete(context, doc);
    }
  }

  /// Opens the chat overlay and sends a message asking the LLM about [doc].
  ///
  /// Uses [AiContextAction.openChatAndSend] to properly create a new
  /// conversation before sending the structured prompt.
  void _chatAboutDocument(TechDocSummary doc) {
    final message = buildChatAboutDocMessage(doc.name);
    AiContextAction.openChatAndSend(ref: ref, message: message);
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = await io.File(file.path!).readAsBytes();
    final defaultName = file.name.replaceAll('.pdf', '');

    if (!mounted) return;

    // Show name dialog
    final name = await _showNameDialog(defaultName);
    if (name == null || name.isEmpty) return;

    await _performUpload(bytes, name);
  }

  Future<void> _performUpload(List<int> bytes, String name) async {
    final service = ref.read(techDocUploadServiceProvider);
    if (service == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Upload unavailable — database not connected'),
          ),
        );
      }
      return;
    }

    final index = ref.read(techDocIndexProvider);
    if (index == null) return;

    final pdfBytes = bytes is! Uint8List ? Uint8List.fromList(bytes) : bytes;

    // Size check — same 50MB limit as the service.
    const maxSize = 50 * 1024 * 1024;
    if (pdfBytes.length > maxSize) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'File too large (${(pdfBytes.length / 1024 / 1024).toStringAsFixed(1)} MB). Max 50 MB.'),
          ),
        );
      }
      return;
    }

    // Disable the upload button while this upload is in progress.
    ref.read(techDocUploadProgressProvider.notifier).state =
        TechDocUploadProgress('Uploading $name...', 0.0);

    // Show pending row instantly — no async work before this point.
    ref.read(pendingTechDocsProvider.notifier).state = [
      ...ref.read(pendingTechDocsProvider),
      TechDocSummary(
        id: -1,
        name: name,
        pageCount: 0,
        sectionCount: 0,
        uploadedAt: DateTime.now(),
      ),
    ];

    // Everything else runs in background — UI is already updated.
    _storeAndExtract(service, index, pdfBytes, name);
  }

  /// Background: store blob → swap pending for real row → extract sections.
  ///
  /// Fully guarded — no exception can escape to crash the render pipeline.
  Future<void> _storeAndExtract(
    TechDocUploadService service,
    TechDocIndex index,
    Uint8List pdfBytes,
    String name,
  ) async {
    try {
      // Phase 1: Store blob + name in DB.
      final docId = await auditTechDocOperation<int>(
        action: TechDocAuditAction.upload,
        user: _writeUser,
        docId: null,
        docName: name,
        operation: () => index.storeDocument(
          name: name,
          pdfBytes: pdfBytes,
          sections: [],
          pageCount: 0,
        ),
        logger: _logger,
      );

      // Cache PDF bytes locally — viewing is instant without DB round-trip.
      if (!mounted) return;
      ref.read(pdfBytesCacheProvider).put(docId, pdfBytes);

      // Blob stored → swap pending row for real DB row.
      _removePending(name);
      ref.read(techDocUploadProgressProvider.notifier).state = null;
      ref.invalidate(dbTechDocsProvider);

      // Phase 2: Extract sections in background.
      // This takes ~10s (pdfrx text extraction) then writes to DB.
      // The DB connection may have gone idle during extraction,
      // so SocketException is expected and non-fatal.
      try {
        await service.extractAndStoreSections(docId: docId, pdfBytes: pdfBytes);
        if (mounted) ref.invalidate(dbTechDocsProvider);
      } catch (e) {
        _logger.w('Section extraction failed for $name: $e');
        // Doc exists with 0 sections — acceptable degradation.
        // User can replace the doc to retry extraction.
      }
    } on AccessDenied {
      // A refusal is not a failed upload. Undo the optimistic row and clear the
      // progress indicator, but leave the message to `AccessDeniedPrompt` — an
      // "Upload failed: AccessDenied" snackbar reads like a fault.
      if (!mounted) return;
      _removePending(name);
      ref.read(techDocUploadProgressProvider.notifier).state = null;
    } catch (e) {
      // Blob store failed.
      _logger.e('Upload failed for $name: $e');
      if (!mounted) return;
      _removePending(name);
      ref.read(techDocUploadProgressProvider.notifier).state = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    }
  }

  void _removePending(String name) {
    ref.read(pendingTechDocsProvider.notifier).state =
        ref.read(pendingTechDocsProvider).where((p) => p.name != name).toList();
  }

  Future<void> _performRename(int docId, String newName) async {
    setState(() => _editingDocId = null);
    if (newName.isEmpty) return;

    final index = ref.read(techDocIndexProvider);
    if (index == null) return;

    try {
      await auditTechDocOperation<void>(
        action: TechDocAuditAction.rename,
        user: _writeUser,
        docId: docId,
        docName: newName,
        operation: () => index.renameDocument(docId, newName),
        logger: _logger,
      );
    } on AccessDenied {
      // The guard has already published the refusal; `AccessDeniedPrompt` is
      // what says what is missing. Without this arm the exception escapes an
      // async callback and shows up as an unhandled error instead.
      return;
    }

    ref.invalidate(dbTechDocsProvider);
  }

  Future<void> _performPlcRename(String oldAssetKey, String newName) async {
    setState(() => _editingPlcAssetKey = null);
    if (newName.isEmpty || newName == oldAssetKey) return;

    final index = ref.read(plcCodeIndexProvider);
    if (index == null) return;

    try {
      await index.renameAsset(oldAssetKey, newName);
    } on AccessDenied {
      // See `_performRename`. Everything below is the page reacting to a
      // rename that did not happen.
      return;
    }

    // Update selection if this asset was selected.
    if (ref.read(selectedPlcAssetProvider) == oldAssetKey) {
      ref.read(selectedPlcAssetProvider.notifier).state = newName;
    }

    ref.invalidate(plcAssetSummaryProvider);
    ref.invalidate(plcBlockListProvider(oldAssetKey));
  }

  Future<void> _replaceDocument(TechDocSummary doc) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = await io.File(file.path!).readAsBytes();

    final service = ref.read(techDocUploadServiceProvider);
    if (service == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Replace unavailable — database not connected'),
          ),
        );
      }
      return;
    }

    try {
      await auditTechDocOperation<void>(
        action: TechDocAuditAction.replace,
        user: _writeUser,
        docId: doc.id,
        docName: doc.name,
        operation: () => service.replaceDocument(
          docId: doc.id,
          pdfBytes: bytes,
          onProgress: (p) {
            if (mounted) {
              ref.read(techDocUploadProgressProvider.notifier).state = p;
            }
          },
        ),
        logger: _logger,
      );
    } on AccessDenied {
      // Clear the progress indicator the replace started, or it spins for ever
      // on a refusal. `AccessDeniedPrompt` is what explains the refusal.
      ref.read(techDocUploadProgressProvider.notifier).state = null;
      return;
    }

    // Update PDF cache with new bytes so viewing is instant.
    ref.read(pdfBytesCacheProvider).put(doc.id, bytes);
    ref.read(techDocUploadProgressProvider.notifier).state = null;
    ref.invalidate(dbTechDocsProvider);
  }

  Future<void> _confirmDelete(BuildContext context, TechDocSummary doc) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete document',
      message: 'Delete "${doc.name}"?\n\n'
          'Any assets linked to this document will be unlinked.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (!confirmed) return;

    final service = ref.read(techDocUploadServiceProvider);
    if (service == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Delete unavailable — database not connected'),
          ),
        );
      }
      return;
    }

    // The guarded configuration store: the cleanup strips `techDocId` from
    // the shared layout rows, which asks for `configure` on
    // `page_editor_data` exactly as the preference write it replaced did.
    final configStore = await ref.read(configStoreProvider.future);

    // Evict from local PDF cache.
    ref.read(pdfBytesCacheProvider).remove(doc.id);

    // Optimistic removal — hide row immediately, delete in background.
    if (ref.read(selectedTechDocProvider) == doc.id) {
      ref.read(selectedTechDocProvider.notifier).state = null;
    }
    ref.read(pendingDeleteIdsProvider.notifier).state = [
      ...ref.read(pendingDeleteIdsProvider),
      doc.id,
    ];
    // No invalidate needed — pendingDeleteIdsProvider is watched by
    // techDocListProvider, so the list rebuilds automatically.

    try {
      await auditTechDocOperation<void>(
        action: TechDocAuditAction.delete,
        user: _writeUser,
        docId: doc.id,
        docName: doc.name,
        operation: () => service.deleteAndCleanAssets(
          docId: doc.id,
          configStore: configStore,
        ),
        logger: _logger,
      );
    } on AccessDenied {
      // The row was hidden optimistically for a delete that was refused. Put
      // it back, or the document stays invisible until the page is rebuilt.
      // The guard has already published the refusal, so `AccessDeniedPrompt`
      // is what says why — a snackbar here would be a second message.
      _unhide(doc.id);
      return;
    } on ConfigStoreOfflineException {
      _unhide(doc.id);
      _sayCleanupFailed(context, 'the shared database is unreachable');
      return;
    } on ConfigStoreUnsafePoolException {
      _unhide(doc.id);
      _sayCleanupFailed(context, 'the shared database pool is wider than one');
      return;
    } on ConfigConflict {
      _unhide(doc.id);
      _sayCleanupFailed(context, 'another station changed the layout first');
      return;
    }

    // DB delete done — refresh from DB, then clear pending flag.
    // Order matters: invalidate first so the DB re-query runs while
    // the pending filter still hides the deleted doc. Only clear the
    // pending flag after the fresh data arrives, preventing a brief
    // flash where the old cached DB list (still containing the deleted
    // doc) is shown unfiltered — which shifts PLC rows down then back up.
    ref.invalidate(dbTechDocsProvider);
    if (mounted) {
      try {
        await ref.read(dbTechDocsProvider.future);
      } catch (_) {
        // DB refresh failed — clear pending flag anyway so the row
        // doesn't stay hidden forever.
      }
      if (!mounted) return;
      ref.read(pendingDeleteIdsProvider.notifier).state = ref
          .read(pendingDeleteIdsProvider)
          .where((id) => id != doc.id)
          .toList();
    }
  }

  /// Puts an optimistically hidden row back.
  void _unhide(int docId) {
    if (!mounted) return;
    ref.read(pendingDeleteIdsProvider.notifier).state = ref
        .read(pendingDeleteIdsProvider)
        .where((id) => id != docId)
        .toList();
  }

  /// The three arms the layout write can fail on, said out loud.
  ///
  /// Nothing was deleted — the cleanup runs before the document does, so a
  /// failed layout write leaves both the document and its links intact. That
  /// has to be visible: a silent failure here reads as a delete that worked.
  void _sayCleanupFailed(BuildContext context, String because) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Delete cancelled — the linked assets could not be '
            'unlinked because $because.'),
      ),
    );
  }

  Future<String?> _showNameDialog(String defaultName) async {
    final controller = TextEditingController(text: defaultName);
    return showStandardDialog<String>(
      context: context,
      title: 'Document name',
      icon: Icons.edit,
      builder: (ctx) => TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Enter document name',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actionsBuilder: (ctx) => [
        PaneAction.primary(
          label: 'OK',
          onPressed: () => Navigator.pop(ctx, controller.text),
        ),
      ],
    );
  }

  /// Build a row for a PLC asset summary entry.
  Widget _buildPlcRow(BuildContext context, PlcAssetSummary plc) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    final selectedPlcAsset = ref.watch(selectedPlcAssetProvider);
    final isSelected = selectedPlcAsset == plc.assetKey;

    return InkWell(
      onTap: () {
        // Mutually exclusive with tech doc selection.
        ref.read(selectedTechDocProvider.notifier).state = null;
        ref.read(selectedPlcAssetProvider.notifier).state =
            isSelected ? null : plc.assetKey;
      },
      onSecondaryTapUp: (details) => _showPlcContextMenu(context, details, plc),
      child: Container(
        color: isSelected
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.3)
            : null,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            // Name column with code icon (editable if kKnowledgeWriteGroup
            // and editing)
            Expanded(
              flex: 3,
              child: _editingPlcAssetKey == plc.assetKey
                  ? TextField(
                      controller: _renameController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (newName) =>
                          _performPlcRename(plc.assetKey, newName),
                      onEditingComplete: () =>
                          setState(() => _editingPlcAssetKey = null),
                    )
                  : GestureDetector(
                      onDoubleTap: _isWriteEnabled
                          ? () {
                              setState(() {
                                _editingPlcAssetKey = plc.assetKey;
                                _renameController.text = plc.assetKey;
                              });
                            }
                          : null,
                      child: Row(
                        children: [
                          const Icon(Icons.code, size: 16, color: Colors.blue),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'PLC: ${plc.assetKey}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            // Blocks count (in place of pages column)
            Expanded(
              child: Text(
                '${plc.blockCount} blocks',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Variables count (in place of sections column)
            Expanded(
              child: Text(
                '${plc.variableCount} vars',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Indexed date
            Expanded(
              flex: 2,
              child: Text(
                dateFormat.format(plc.lastIndexedAt),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Show context menu for a PLC asset row.
  Future<void> _showPlcContextMenu(
    BuildContext context,
    TapUpDetails details,
    PlcAssetSummary plc,
  ) async {
    final items = <PopupMenuEntry<String>>[];

    // "Chat about this" — only when MCP chat is available.
    if (kChatEnabled) {
      items.add(const PopupMenuItem(
        value: 'chat',
        child: ListTile(
          leading: Icon(Icons.chat),
          title: Text('Chat about this'),
          dense: true,
        ),
      ));
    }

    if (_isWriteEnabled) {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      items.addAll([
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(Icons.edit),
            title: Text('Rename'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: 'reindex',
          child: ListTile(
            leading: Icon(Icons.refresh),
            title: Text('Re-index'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete),
            title: Text('Delete'),
            dense: true,
          ),
        ),
      ]);
    }

    if (items.isEmpty) return;

    final value = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: items,
    );

    if (value == null || !mounted) return;
    switch (value) {
      case 'chat':
        if (kChatEnabled) _chatAboutPlcAsset(plc);
      case 'rename':
        setState(() {
          _editingPlcAssetKey = plc.assetKey;
          _renameController.text = plc.assetKey;
        });
      case 'reindex':
        _reindexPlcAsset(plc);
      case 'delete':
        _confirmDeletePlcAsset(context, plc);
    }
  }

  /// Opens the chat overlay and sends a message asking the LLM about a PLC asset.
  void _chatAboutPlcAsset(PlcAssetSummary plc) {
    final message = '''Chat about PLC code: ${plc.assetKey}

Please gather all available information about this PLC project including:
- List the code blocks and their types (use search_plc_code with asset filter "${plc.assetKey}")
- Summarize the main program structure and function blocks
- Identify key variables and their purposes
- Any related assets or equipment (use list_assets to cross-reference)
- Related electrical drawings if applicable (use search_drawings)
Then provide a summary of what this PLC code controls and how it is structured.''';
    AiContextAction.openChatAndSend(ref: ref, message: message);
  }

  /// Re-indexes a PLC asset by re-parsing the stored source code.
  ///
  /// Fire-and-forget: captures all needed values up front so the operation
  /// completes even if the user navigates away. Uses the global scaffold
  /// messenger key for snackbar feedback.
  void _reindexPlcAsset(PlcAssetSummary plc) {
    final index = ref.read(plcCodeIndexProvider);
    if (index == null) {
      globalScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Re-index unavailable — database not connected'),
        ),
      );
      return;
    }
    // `PlcCodeIndexExtras`, not the concrete `DriftPlcCodeIndex`:
    // `plcCodeIndexProvider` returns the guard, and the old check would have
    // reported a database fault this station does not have. Unreachable while
    // the provider returns the guard, which is the only implementer —
    // `knowledge_guard_wiring_test.dart` asserts that.
    if (index is! PlcCodeIndexExtras) {
      globalScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Re-index unavailable — this index cannot re-index'),
        ),
      );
      return;
    }

    // Capture ref-dependent state before going async.
    final progressNotifier = ref.read(techDocUploadProgressProvider.notifier);
    final assetKey = plc.assetKey;

    // Show progress indicator.
    progressNotifier.state =
        TechDocUploadProgress('Re-indexing $assetKey...', 0.0);

    // Fire and forget — no await, no mounted checks.
    unawaited(_doReindex(index, assetKey, progressNotifier));
  }

  /// Performs the actual reindex work. Lifecycle-independent.
  Future<void> _doReindex(
    PlcCodeIndexExtras index,
    String assetKey,
    StateController<TechDocUploadProgress?> progressNotifier,
  ) async {
    try {
      final blockCount = await index.reindexAsset(assetKey);

      progressNotifier.state = null;
      ref.invalidate(plcAssetSummaryProvider);
      ref.invalidate(plcBlockListProvider(assetKey));

      globalScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Re-indexed $assetKey: $blockCount blocks refreshed',
          ),
        ),
      );
    } on AccessDenied {
      // The guard has already published the refusal to
      // `accessDenialsProvider`, so `AccessDeniedPrompt` (mounted in
      // `BaseScaffold`) is what tells the operator what is missing. A
      // "Re-index failed: AccessDenied" snackbar would be a second message for
      // one action, and a worse one — it reads like a fault.
      progressNotifier.state = null;
    } catch (e) {
      _logger.e('Re-index failed for $assetKey: $e');

      progressNotifier.state = null;

      globalScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Re-index failed: $e')),
      );
    }
  }

  /// Confirm and delete a PLC asset index.
  Future<void> _confirmDeletePlcAsset(
    BuildContext context,
    PlcAssetSummary plc,
  ) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Delete PLC index',
      message: 'Delete all indexed PLC code for "${plc.assetKey}"?\n\n'
          '${plc.blockCount} blocks and ${plc.variableCount} variables '
          'will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );

    if (!confirmed) return;

    final index = ref.read(plcCodeIndexProvider);
    if (index == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Delete unavailable — database not connected'),
          ),
        );
      }
      return;
    }

    // Clear selection if this asset is selected.
    if (ref.read(selectedPlcAssetProvider) == plc.assetKey) {
      ref.read(selectedPlcAssetProvider.notifier).state = null;
    }

    try {
      await index.deleteAssetIndex(plc.assetKey);
    } on AccessDenied {
      // The guard has already published the refusal, so `AccessDeniedPrompt`
      // is what tells the operator what is missing. Everything below this is
      // the page reacting to a deletion that did not happen — including a
      // snackbar claiming the index was deleted.
      return;
    }
    ref.invalidate(plcAssetSummaryProvider);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted PLC index for "${plc.assetKey}"')),
      );
    }
  }

  /// Show the PLC project upload dialog.
  ///
  /// Prompts for an asset key, then opens the [PlcCodeUploadDialog].
  /// After successful upload, invalidates the PLC summary provider.
  void _showPlcUploadDialog() {
    final uploadService = ref.read(plcCodeUploadServiceProvider);
    if (uploadService == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PLC upload not available (no database connection)'),
        ),
      );
      return;
    }

    final serverAliases = ref.read(serverAliasesProvider).valueOrNull ?? [];
    showDialog(
      context: context,
      builder: (ctx) => PlcCodeUploadDialog(
        uploadService: uploadService,
        serverAliases: serverAliases,
      ),
    ).then((_) {
      // Refresh PLC list after dialog closes.
      if (mounted) ref.invalidate(plcAssetSummaryProvider);
    });
  }

  List<TechDocSummary> _sortDocs(List<TechDocSummary> docs) {
    docs.sort((a, b) {
      int cmp;
      switch (_sortColumn) {
        case 'name':
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'pages':
          cmp = a.pageCount.compareTo(b.pageCount);
        case 'sections':
          cmp = a.sectionCount.compareTo(b.sectionCount);
        case 'uploadDate':
          cmp = a.uploadedAt.compareTo(b.uploadedAt);
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    });
    return docs;
  }
}

