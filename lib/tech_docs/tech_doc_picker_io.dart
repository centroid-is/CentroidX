import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';
import 'package:tfc_mcp_server/tfc_mcp_server.dart';

import '../providers/tech_doc.dart';

/// A searchable dropdown widget for selecting a technical document.
///
/// Displays a list of uploaded [TechDocSummary] documents from
/// [techDocListProvider] with type-ahead fuzzy filtering. When no documents
/// are uploaded, the picker is disabled with a "No documents uploaded" hint.
///
/// A "None" option at the top allows clearing the current selection.
class TechDocPicker extends ConsumerStatefulWidget {
  /// The currently selected document ID, or null if none selected.
  final int? selectedDocId;

  /// Called when the user selects a document or clears the selection.
  final ValueChanged<int?> onChanged;

  /// Whether the picker is interactive. When false, taps are ignored.
  final bool enabled;

  const TechDocPicker({
    required this.selectedDocId,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  @override
  ConsumerState<TechDocPicker> createState() => _TechDocPickerState();
}

class _TechDocPickerState extends ConsumerState<TechDocPicker> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  void _toggleDropdown(List<TechDocSummary> docs) {
    if (_overlayEntry != null) {
      _removeOverlay();
      return;
    }
    _showDropdown(docs);
  }

  void _showDropdown(List<TechDocSummary> docs) {
    _removeOverlay();
    _searchQuery = '';
    _searchController.clear();

    _overlayEntry = OverlayEntry(
      builder: (context) => _TechDocDropdownOverlay(
        layerLink: _layerLink,
        docs: docs,
        searchController: _searchController,
        searchQuery: _searchQuery,
        onSearchChanged: (query) {
          _searchQuery = query;
          _overlayEntry?.markNeedsBuild();
        },
        onSelected: (id) {
          widget.onChanged(id);
          _removeOverlay();
        },
        onDismiss: _removeOverlay,
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(techDocListProvider);

    return docsAsync.when(
      loading: () => const InputDecorator(
        decoration: InputDecoration(
          labelText: 'Technical Document',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text('Loading...', style: TextStyle(color: Colors.grey)),
      ),
      error: (_, __) => const InputDecorator(
        decoration: InputDecoration(
          labelText: 'Technical Document',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text('Error loading documents',
            style: TextStyle(color: Colors.red)),
      ),
      data: (docs) {
        if (docs.isEmpty) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'Technical Document',
              enabled: false,
            ),
            child: Text('No documents uploaded',
                style: TextStyle(color: Colors.grey)),
          );
        }

        // Find selected document name
        final selectedDoc = widget.selectedDocId != null
            ? docs
                .where((d) => d.id == widget.selectedDocId)
                .firstOrNull
            : null;
        final displayText = selectedDoc?.name ?? 'Select document...';

        return CompositedTransformTarget(
          link: _layerLink,
          child: GestureDetector(
            onTap: widget.enabled ? () => _toggleDropdown(docs) : null,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: 'Technical Document',
                suffixIcon: const Icon(Icons.arrow_drop_down),
                enabled: widget.enabled,
              ),
              child: Text(
                displayText,
                style: TextStyle(
                  color: selectedDoc != null
                      ? null
                      : Theme.of(context).hintColor,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The overlay dropdown content for TechDocPicker.
class _TechDocDropdownOverlay extends StatelessWidget {
  final LayerLink layerLink;
  final List<TechDocSummary> docs;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<int?> onSelected;
  final VoidCallback onDismiss;

  const _TechDocDropdownOverlay({
    required this.layerLink,
    required this.docs,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onSelected,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = fuzzyFilter<TechDocSummary>(
      docs,
      searchQuery,
      [(d) => d.name],
    );

    return Stack(
      children: [
        // Dismiss tap catcher
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        // Dropdown content
        Positioned(
          width: 350,
          child: CompositedTransformFollower(
            link: layerLink,
            showWhenUnlinked: false,
            offset: const Offset(0, 48),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              // The surface colour lives on the Material rather than the
              // Container below: ListTile paints its ink splashes on the
              // nearest Material ancestor, so a coloured DecoratedBox in
              // between would hide them (asserted by Flutter >= 3.44).
              color: Theme.of(context).colorScheme.surface,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Search field
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextField(
                        controller: searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Search documents...',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          prefixIcon: const Icon(Icons.search, size: 16),
                        ),
                        onChanged: onSearchChanged,
                      ),
                    ),
                    // "None" option
                    if (searchQuery.isEmpty)
                      ListTile(
                        dense: true,
                        title: const Text('None',
                            style: TextStyle(fontStyle: FontStyle.italic)),
                        onTap: () => onSelected(null),
                      ),
                    // Document list
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 250),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final doc = filtered[index];
                          return ListTile(
                            dense: true,
                            title: Text(doc.name),
                            subtitle: Text(
                              '${doc.pageCount} pages, ${doc.sectionCount} sections',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            onTap: () => onSelected(doc.id),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
