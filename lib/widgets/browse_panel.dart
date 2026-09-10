import 'dart:async';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:tfc_dart/core/umas_fb_browse_types.dart';

import '../theme.dart' show SolarizedColors;

// ---------------------------------------------------------------------------
// Protocol-agnostic browse types
// ---------------------------------------------------------------------------

/// The type of a node in the browse tree.
enum BrowseNodeType { folder, variable, method, other }

/// A protocol-agnostic node in the browse tree.
///
/// For OPC UA: [id] is the NodeId string (e.g. "ns=2;s=MyVar").
/// For UMAS: [id] is the variable path.
class BrowseNode {
  final String id;
  final String displayName;
  final BrowseNodeType type;
  final String? dataType;
  final String? description;
  final Map<String, String> metadata;

  const BrowseNode({
    required this.id,
    required this.displayName,
    required this.type,
    this.dataType,
    this.description,
    this.metadata = const {},
  });

  bool get isExpandable =>
      type == BrowseNodeType.folder || type == BrowseNodeType.variable;
  bool get isVariable => type == BrowseNodeType.variable;
  bool get isFolder => type == BrowseNodeType.folder;
}

/// Detail information about a selected node.
class BrowseNodeDetail {
  final String? description;
  final String? value;
  final String? dataType;
  final List<BrowseNode>? structChildren;

  const BrowseNodeDetail({
    this.description,
    this.value,
    this.dataType,
    this.structChildren,
  });
}

/// Protocol-agnostic data source for the browse panel.
///
/// Implement this for each protocol (OPC UA, UMAS, etc.).
abstract class BrowseDataSource {
  Future<List<BrowseNode>> fetchRoots();
  Future<List<BrowseNode>> fetchChildren(BrowseNode parent);
  Future<BrowseNodeDetail> fetchDetail(BrowseNode node);

  /// Resolves the full chain of nodes from root to the node identified by
  /// [targetId], for pre-selection when opening the browse panel with an
  /// already-bound value (e.g. an existing UMAS `variableName` or an OPC-UA
  /// NodeId).
  ///
  /// The returned list MUST be ordered root → … → leaf, with the last entry
  /// being the target node itself. Returns null if the target cannot be
  /// resolved (stale binding) or if the data source does not support
  /// pre-selection.
  ///
  /// The default implementation returns null (no preselection). Subclasses
  /// override this to walk their backing tree / browse hierarchy.
  Future<List<BrowseNode>?> resolvePath(String targetId) async => null;
}

// ---------------------------------------------------------------------------
// Internal tree node (adds depth + parentId tracking)
// ---------------------------------------------------------------------------

/// Internal tree node that decorates [BrowseNode] with depth and parent info.
///
/// This is an implementation detail of [BrowsePanel] and [BrowseNodeTile];
/// external callers should use [BrowseNode] instead.
@visibleForTesting
class BrowseTreeEntry {
  final BrowseNode node;
  final int depth;
  final String parentId;

  const BrowseTreeEntry({
    required this.node,
    required this.depth,
    required this.parentId,
  });

  String get id => node.id;
  String get displayName => node.displayName;
  BrowseNodeType get type => node.type;
  bool get isExpandable => node.isExpandable;
  bool get isVariable => node.isVariable;
}

// ---------------------------------------------------------------------------
// BrowsePanel widget
// ---------------------------------------------------------------------------

/// Error info returned by [BrowseErrorMapper] for user-friendly display.
typedef BrowseErrorInfo = ({String summary, String detail});

/// Maps a caught exception to user-friendly summary + detail text.
/// Return null to fall back to the default `e.toString()` display.
typedef BrowseErrorMapper = BrowseErrorInfo? Function(Object error);

/// Shows an address-space browser in a free-floating [StandardDialog] and
/// returns the selected [BrowseNode], or null if the operator closed it
/// without picking.
///
/// Floating rather than modal because browsing a PLC's address space is not a
/// question to be answered before anything else may happen: the operator
/// reads a live value off the tree, drags the window aside to check the form
/// behind it, and comes back. Nothing is dimmed and the page underneath stays
/// live — including, when Browse was opened from the key-mapping dialog, that
/// dialog itself.
///
/// One window per server. Opening Browse for an alias that already has one
/// replaces it rather than stacking a second copy: a browse window answers
/// exactly one requester, and the superseded one resolves null. Two different
/// servers can be browsed side by side.
///
/// When [initialPath] is non-null, the panel opens with that path
/// pre-selected, the tree expanded down to it, and the detail strip
/// populated. Stale bindings (target no longer resolves) fall back to the
/// default empty-selection state without crashing.
///
/// Callers must re-check `mounted` after the await — navigating away closes
/// every floating dialog, which resolves this future with null while the
/// awaiting widget is being disposed in the same breath.
Future<BrowseNode?> showBrowseDialog({
  required BuildContext context,
  required BrowseDataSource dataSource,
  required String serverAlias,
  BrowseErrorMapper? errorMapper,
  String? initialPath,
}) {
  final id = 'browse:$serverAlias';
  if (FloatingDialogs.isOpen(id)) closeFloatingDialog(id);

  // The `Select` action is the only thing about this window that changes
  // while it is open, so it travels on its own notifier rather than through a
  // rebuild of the dialog. Rebuilding would rebuild [BrowsePanel] with it and
  // cost the loaded tree — on UMAS that means re-walking the symbol cache on
  // every tap. See the umas-fb-freeze-loop note in umas_browse.dart.
  final actions = ValueNotifier<List<PaneAction>>(
    const [PaneAction.primary(label: 'Select')],
  );

  return showFloatingDialog<BrowseNode>(
    context: context,
    id: id,
    title: 'Browse',
    subtitle: serverAlias,
    icon: Icons.account_tree_outlined,
    size: const Size(920, 600),
    // The panel sizes its own tree with an Expanded; a scroll view's
    // unbounded height would break it, and it wants the whole window anyway.
    scrollable: false,
    actionsListenable: actions,
    onClosed: actions.dispose,
    builder: (_) => BrowsePanel(
      dataSource: dataSource,
      errorMapper: errorMapper,
      initialPath: initialPath,
      onSelected: (node) => closeFloatingDialog(id, result: node),
      onSelectionChanged: (node) => actions.value = [
        PaneAction.primary(
          label: 'Select',
          onPressed: node != null && node.isVariable
              ? () => closeFloatingDialog(id, result: node)
              : null,
        ),
      ],
    ),
  );
}

/// Protocol-agnostic browse panel that displays a tree of nodes from a
/// [BrowseDataSource]. This is the panel content -- it does NOT include a
/// Dialog wrapper. Use [showBrowseDialog] for the dialog version, or embed
/// this widget directly.
class BrowsePanel extends StatefulWidget {
  final BrowseDataSource dataSource;

  /// Called when the operator commits to a node — a double tap, or a second
  /// tap on the already-selected variable.
  final ValueChanged<BrowseNode> onSelected;

  /// Called whenever the highlighted node changes, so an enclosing dialog
  /// can enable/disable its own `Select` action.
  final ValueChanged<BrowseNode?>? onSelectionChanged;

  final BrowseErrorMapper? errorMapper;

  /// When non-null, after roots load the panel asks
  /// [BrowseDataSource.resolvePath] for the chain to this target id,
  /// expands every ancestor along it, selects the leaf, and triggers a
  /// detail fetch — so operators who re-open Browse on an existing
  /// binding land on the current selection instead of a collapsed root.
  ///
  /// Stale bindings (path no longer resolves) silently fall back to the
  /// default empty-selection state.
  final String? initialPath;

  const BrowsePanel({
    super.key,
    required this.dataSource,
    required this.onSelected,
    this.onSelectionChanged,
    this.errorMapper,
    this.initialPath,
  });

  @override
  State<BrowsePanel> createState() => BrowsePanelState();
}

@visibleForTesting
class BrowsePanelState extends State<BrowsePanel> {
  List<BrowseTreeEntry> _roots = [];
  final Map<String, List<BrowseTreeEntry>> _children = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  BrowseTreeEntry? _selected;
  bool _rootLoading = true;
  String? _error;
  String? _errorHelp;
  // Surfaced by [_applyInitialPath] when the requested initialPath does
  // not resolve in the freshly-loaded tree (stale binding). Rendered as
  // a subtle hint above the tree so the operator knows why the dialog
  // didn't open on their previous selection.
  String? _staleInitialPath;

  final ScrollController _treeScrollController = ScrollController();

  // Detail strip state for selected variable
  String? _detailDescription;
  String? _detailValue;
  String? _detailDataType;
  bool _detailLoading = false;
  String? _detailLoadedFor;

  @visibleForTesting
  BrowseNode? get selected => _selected?.node;
  @visibleForTesting
  List<BrowseNode> get roots => _roots.map((t) => t.node).toList();
  @visibleForTesting
  bool get rootLoading => _rootLoading;
  @visibleForTesting
  String? get error => _error;
  @visibleForTesting
  Set<String> get expandedIds => Set.unmodifiable(_expanded);
  @visibleForTesting
  String? get staleInitialPath => _staleInitialPath;

  static const String _rootParentId = '__root__';

  void _showErrorHelpDialog(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showStandardDialog<void>(
      context: context,
      title: 'Troubleshooting',
      icon: Icons.info_outline,
      width: 460,
      builder: (ctx) => SelectableText(
        _errorHelp!,
        style: TextStyle(color: cs.onSurface, fontSize: 13, height: 1.5),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadRoots();
  }

  @override
  void dispose() {
    _treeScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadRoots() async {
    try {
      final results = await widget.dataSource.fetchRoots();
      if (!mounted) return;
      final roots = results
          .map((node) => BrowseTreeEntry(
                node: node,
                depth: 0,
                parentId: _rootParentId,
              ))
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
      setState(() {
        _roots = roots;
        _rootLoading = false;
      });
      _prefetchChildren(roots);
      if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
        // Fire-and-forget: failure (e.g. stale binding) is captured by
        // `_staleInitialPath` inside the helper and never crashes the
        // dialog.
        unawaited(_applyInitialPath(widget.initialPath!));
      }
    } catch (e) {
      if (!mounted) return;
      final info = widget.errorMapper?.call(e);
      setState(() {
        _error = info?.summary ?? e.toString();
        _errorHelp = info?.detail;
        _rootLoading = false;
      });
    }
  }

  /// Test-only entrypoint that drives [_applyInitialPath] after the panel
  /// is mounted (so tests can exercise the resolution code path without
  /// piping through `showBrowseDialog`).
  @visibleForTesting
  Future<void> applyInitialPathForTest(String targetId) =>
      _applyInitialPath(targetId);

  /// Resolves [targetId] via the data source, expands every ancestor on
  /// the path, selects the leaf entry, and triggers its detail fetch.
  ///
  /// On any failure (unsupported, not found, or thrown exception), records
  /// the requested path in [_staleInitialPath] so the UI can surface a
  /// gentle hint, but never throws or crashes the dialog.
  Future<void> _applyInitialPath(String targetId) async {
    List<BrowseNode>? chain;
    try {
      chain = await widget.dataSource.resolvePath(targetId);
    } catch (_) {
      chain = null;
    }
    if (!mounted) return;
    if (chain == null || chain.isEmpty) {
      setState(() => _staleInitialPath = targetId);
      return;
    }

    // Walk the chain root → leaf. For each non-leaf ancestor:
    //   - Ensure children are loaded (cache miss → fetchChildren).
    //   - Add to _expanded.
    // The leaf gets selected; its detail fetch is fired afterwards.
    //
    // Depth is derived from the chain position rather than parent.depth+1
    // so the synthesized entries match what `_loadChildren` would produce
    // naturally — keeps flattenTree() indentation correct.
    final entries = <BrowseTreeEntry>[];
    var parentId = _rootParentId;
    for (var i = 0; i < chain.length; i++) {
      final node = chain[i];
      final entry = BrowseTreeEntry(
        node: node,
        depth: i,
        parentId: parentId,
      );
      entries.add(entry);
      parentId = node.id;
    }

    // Roots: ensure the resolved root matches one we already have. If
    // not, the chain doesn't belong to this tree — bail out.
    final rootEntry = entries.first;
    final hasMatchingRoot = _roots.any((r) => r.id == rootEntry.id);
    if (!hasMatchingRoot) {
      setState(() => _staleInitialPath = targetId);
      return;
    }

    // For each non-leaf ancestor: hydrate _children with the next entry
    // (which we already have from the chain) plus any siblings the
    // data source returns from fetchChildren, then mark it expanded.
    for (var i = 0; i < entries.length - 1; i++) {
      final ancestor = entries[i];
      if (!_children.containsKey(ancestor.id)) {
        try {
          final kids = await widget.dataSource.fetchChildren(ancestor.node);
          if (!mounted) return;
          _children[ancestor.id] = kids
              .map((n) => BrowseTreeEntry(
                    node: n,
                    depth: ancestor.depth + 1,
                    parentId: ancestor.id,
                  ))
              .toList()
            ..sort((a, b) => a.displayName.compareTo(b.displayName));
        } catch (_) {
          // Children load failed — drop in just the next chain entry so
          // the expansion still renders the path even if siblings are
          // unavailable.
          _children[ancestor.id] = [entries[i + 1]];
        }
      }
    }

    if (!mounted) return;
    setState(() {
      for (final e in entries.take(entries.length - 1)) {
        _expanded.add(e.id);
      }
      _selected = entries.last;
      _staleInitialPath = null;
    });
    widget.onSelectionChanged?.call(entries.last.node);

    // Trigger detail fetch for the leaf so the right-hand strip is
    // populated immediately, matching the post-click behavior.
    if (entries.last.isVariable) {
      unawaited(_loadVariableDetails(entries.last));
    }

    // Scroll the leaf into view on the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_treeScrollController.hasClients) return;
      final flat = flattenTree();
      final leafIndex = flat.indexWhere((e) => e.id == entries.last.id);
      if (leafIndex < 0) return;
      const tileHeight = 36.0;
      final target = leafIndex * tileHeight;
      final maxScroll = _treeScrollController.position.maxScrollExtent;
      _treeScrollController.jumpTo(target.clamp(0.0, maxScroll));
    });
  }

  Future<void> _loadChildren(
      String nodeId, BrowseNode browseNode, int parentDepth) async {
    if (_loading.contains(nodeId)) return;
    setState(() => _loading.add(nodeId));
    try {
      final results = await widget.dataSource.fetchChildren(browseNode);
      if (!mounted) return;
      final nodes = results
          .map((node) => BrowseTreeEntry(
                node: node,
                depth: parentDepth + 1,
                parentId: nodeId,
              ))
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
      setState(() {
        _children[nodeId] = nodes;
        _expanded.add(nodeId);
        _loading.remove(nodeId);
      });
      _prefetchChildren(nodes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading.remove(nodeId);
        _children[nodeId] = [];
      });
    }
  }

  void _prefetchChildren(List<BrowseTreeEntry> nodes) {
    for (final node in nodes) {
      if (node.isExpandable && !_children.containsKey(node.id)) {
        _prefetchSingle(node);
      }
    }
  }

  Future<void> _prefetchSingle(BrowseTreeEntry treeNode) async {
    if (_children.containsKey(treeNode.id)) return;
    try {
      final results = await widget.dataSource.fetchChildren(treeNode.node);
      if (!mounted) return;
      if (_children.containsKey(treeNode.id)) return;
      setState(() {
        _children[treeNode.id] = results
            .map((node) => BrowseTreeEntry(
                  node: node,
                  depth: treeNode.depth + 1,
                  parentId: treeNode.id,
                ))
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));
      });
    } catch (_) {}
  }

  Future<void> _loadVariableDetails(BrowseTreeEntry treeNode) async {
    final nodeId = treeNode.id;
    if (_detailLoadedFor == nodeId) return;
    setState(() {
      _detailLoading = true;
      _detailDescription = null;
      _detailValue = null;
      _detailDataType = null;
      _detailLoadedFor = nodeId;
    });
    try {
      final detail = await widget.dataSource.fetchDetail(treeNode.node);
      if (!mounted || _detailLoadedFor != nodeId) return;
      setState(() {
        _detailValue = detail.value;
        _detailDescription = detail.description;
        _detailDataType = detail.dataType;
        _detailLoading = false;

        // Synthesize children from struct fields when the data source provides
        // them and the browse tree has no children yet.
        if (detail.structChildren != null &&
            detail.structChildren!.isNotEmpty &&
            (!_children.containsKey(nodeId) || _children[nodeId]!.isEmpty)) {
          final depth = treeNode.depth;
          _children[nodeId] = detail.structChildren!
              .map((child) => BrowseTreeEntry(
                    node: child,
                    depth: depth + 1,
                    parentId: nodeId,
                  ))
              .toList();
          _expanded.add(nodeId);
        }
      });
    } catch (e) {
      if (!mounted || _detailLoadedFor != nodeId) return;
      setState(() {
        _detailValue = 'Error: $e';
        _detailLoading = false;
      });
    }
  }

  void _toggleExpand(BrowseTreeEntry treeNode) {
    if (!treeNode.isExpandable) return;
    final nodeId = treeNode.id;
    if (_expanded.contains(nodeId)) {
      setState(() => _expanded.remove(nodeId));
    } else if (_children.containsKey(nodeId)) {
      setState(() => _expanded.add(nodeId));
    } else {
      _loadChildren(nodeId, treeNode.node, treeNode.depth);
    }
  }

  void _onTapNode(BrowseTreeEntry treeNode) {
    if (treeNode.isVariable) {
      if (_selected?.id == treeNode.id) {
        widget.onSelected(treeNode.node);
      } else {
        setState(() => _selected = treeNode);
        widget.onSelectionChanged?.call(treeNode.node);
        _loadVariableDetails(treeNode);
      }
    } else if (treeNode.isExpandable) {
      _toggleExpand(treeNode);
    }
  }

  void _onDoubleTapNode(BrowseTreeEntry treeNode) {
    if (treeNode.isVariable) {
      widget.onSelected(treeNode.node);
    }
  }

  @visibleForTesting
  List<BrowseTreeEntry> flattenTree() {
    final flat = <BrowseTreeEntry>[];
    void walk(List<BrowseTreeEntry> nodes) {
      for (final node in nodes) {
        flat.add(node);
        if (node.isExpandable &&
            _expanded.contains(node.id) &&
            _children.containsKey(node.id)) {
          walk(_children[node.id]!);
        }
      }
    }

    walk(_roots);
    return flat;
  }

  List<String> _buildBreadcrumb() {
    if (_selected == null) return ['Root'];
    final path = <String>['Root'];
    BrowseTreeEntry? current = _selected;
    final segments = <String>[];
    while (current != null) {
      segments.insert(0, current.displayName);
      final parentId = current.parentId;
      if (parentId == _rootParentId) break;
      BrowseTreeEntry? parent;
      for (final root in _roots) {
        parent = _findNode(root, parentId);
        if (parent != null) break;
      }
      current = parent;
    }
    path.addAll(segments);
    return path;
  }

  BrowseTreeEntry? _findNode(BrowseTreeEntry node, String targetId) {
    if (node.id == targetId) return node;
    final kids = _children[node.id];
    if (kids == null) return null;
    for (final child in kids) {
      final found = _findNode(child, targetId);
      if (found != null) return found;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final flatNodes = flattenTree();
    final breadcrumb = _buildBreadcrumb();
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Breadcrumb
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: cs.surface,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < breadcrumb.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.chevron_right,
                          size: 14, color: cs.secondary),
                    ),
                  Text(
                    breadcrumb[i],
                    style: TextStyle(
                      color: i == breadcrumb.length - 1
                          ? cs.onSurface
                          : cs.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: cs.surfaceContainerLow),
        // Stale initial-path hint: surfaces when an initialPath was
        // supplied but the data source could not resolve it. Kept
        // unobtrusive (single muted row) so a stale binding doesn't feel
        // like an error.
        if (_staleInitialPath != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: cs.surface,
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 12, color: cs.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Original value "${_staleInitialPath!}" no longer found',
                    style: TextStyle(color: cs.secondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (_staleInitialPath != null)
          Divider(height: 1, color: cs.surfaceContainerLow),
        // Tree
        Expanded(
          child: _rootLoading
              ? Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: SolarizedColors.cyan,
                    ),
                  ),
                )
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                color: cs.error, size: 32),
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              style:
                                  TextStyle(color: cs.onSurface, fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                            if (_errorHelp != null) ...[
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: () => _showErrorHelpDialog(context),
                                icon: const Icon(Icons.info_outline, size: 16),
                                label: const Text('How to fix this'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : flatNodes.isEmpty
                      ? Center(
                          child: Text(
                            'No nodes found',
                            style: TextStyle(color: cs.secondary, fontSize: 12),
                          ),
                        )
                      : ListView.builder(
                          controller: _treeScrollController,
                          itemCount: flatNodes.length,
                          itemBuilder: (context, index) {
                            final treeNode = flatNodes[index];
                            final kids = _children[treeNode.id];
                            return BrowseNodeTile(
                              node: treeNode,
                              isSelected: _selected?.id == treeNode.id,
                              isExpanded: _expanded.contains(treeNode.id),
                              isLoading: _loading.contains(treeNode.id),
                              hasChildren: kids != null && kids.isNotEmpty,
                              onTap: () => _onTapNode(treeNode),
                              onDoubleTap: () => _onDoubleTapNode(treeNode),
                              onToggleExpand: () => _toggleExpand(treeNode),
                            );
                          },
                        ),
        ),
        if (_selected != null && _selected!.isVariable)
          VariableDetailStrip(
            displayName: _selected!.displayName,
            nodeId: _selected!.id,
            description: _detailDescription,
            value: _detailValue,
            dataType: _detailDataType,
            isLoading: _detailLoading,
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// BrowseNodeTile
// ---------------------------------------------------------------------------

class BrowseNodeTile extends StatelessWidget {
  final BrowseTreeEntry node;
  final bool isSelected;
  final bool isExpanded;
  final bool isLoading;
  final bool hasChildren;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onToggleExpand;

  const BrowseNodeTile({
    super.key,
    required this.node,
    required this.isSelected,
    required this.isExpanded,
    required this.isLoading,
    required this.hasChildren,
    required this.onTap,
    required this.onDoubleTap,
    required this.onToggleExpand,
  });

  Widget _buildIcon(ColorScheme cs) {
    // Phase 4 (UI-01, UI-02): FB-member affordances. Variable-type nodes with
    // FB metadata get a direction-specific icon (input / output / inOut) or a
    // "not readable" block icon. Non-FB variables fall through to the
    // existing FA tag icon. See umas_fb_browse_types.dart for the metadata
    // key contract.
    if (node.type == BrowseNodeType.variable) {
      final meta = node.node.metadata;
      // Inaccessible members always take priority over direction icons.
      if (!UmasFbMember.readableFromMetadata(meta)) {
        return const Icon(Icons.block, size: 14, color: SolarizedColors.red);
      }
      switch (UmasFbMember.directionFromMetadata(meta)) {
        case UmasFbMemberDirection.input:
          return const Icon(Icons.login, size: 14, color: SolarizedColors.blue);
        case UmasFbMemberDirection.output:
          return const Icon(Icons.logout,
              size: 14, color: SolarizedColors.orange);
        case UmasFbMemberDirection.inOut:
          return const Icon(Icons.swap_horiz,
              size: 14, color: SolarizedColors.violet);
        case UmasFbMemberDirection.publicVar:
        case UmasFbMemberDirection.unknown:
          // Fall through to existing variable rendering below.
          break;
      }
    }
    switch (node.type) {
      case BrowseNodeType.folder:
        return const Icon(Icons.folder_outlined,
            size: 16, color: SolarizedColors.yellow);
      case BrowseNodeType.variable:
        return const FaIcon(FontAwesomeIcons.tag,
            size: 12, color: SolarizedColors.green);
      case BrowseNodeType.method:
        return Icon(Icons.play_arrow,
            size: 16, color: cs.primary.withAlpha(120));
      case BrowseNodeType.other:
        return Icon(Icons.circle, size: 8, color: cs.secondary);
    }
  }

  Widget _buildExpandWidget(ColorScheme cs) {
    if (!node.isExpandable || (node.isVariable && !hasChildren)) {
      return const SizedBox(width: 18);
    }
    if (isLoading) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: Padding(
          padding: EdgeInsets.all(3),
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: SolarizedColors.cyan),
        ),
      );
    }
    return GestureDetector(
      onTap: onToggleExpand,
      child: SizedBox(
        width: 18,
        child: AnimatedRotation(
          turns: isExpanded ? 0.25 : 0,
          duration: Duration.zero,
          child: Icon(Icons.chevron_right, size: 16, color: cs.secondary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMethod = node.type == BrowseNodeType.method;
    // Phase 4: FB-member affordance state (UI-01, UI-02).
    final meta = node.node.metadata;
    final fbDirection = node.type == BrowseNodeType.variable
        ? UmasFbMember.directionFromMetadata(meta)
        : UmasFbMemberDirection.unknown;
    final isUnreadable = node.type == BrowseNodeType.variable &&
        !UmasFbMember.readableFromMetadata(meta);
    final unreadableReason = isUnreadable
        ? (UmasFbMember.unreadableReasonFromMetadata(meta) ?? 'Not readable')
        : null;

    final baseTextColor = isMethod ? cs.secondary : cs.onSurface;
    final textColor =
        isUnreadable ? baseTextColor.withAlpha(120) : baseTextColor;

    final directionSuffix = _directionSuffix(fbDirection);
    final directionTint = _directionTint(fbDirection);

    final row = GestureDetector(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: Container(
        height: 36,
        padding: EdgeInsets.only(left: node.depth * 20.0 + 4, right: 8),
        color: isSelected
            ? SolarizedColors.cyan.withAlpha(25)
            : Colors.transparent,
        child: Row(
          children: [
            _buildExpandWidget(cs),
            const SizedBox(width: 4),
            _buildIcon(cs),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.displayName,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight:
                      node.isVariable ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (directionSuffix != null) ...[
              const SizedBox(width: 6),
              Text(
                directionSuffix,
                style: TextStyle(
                  color: directionTint ?? cs.secondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (isUnreadable) ...[
              const SizedBox(width: 6),
              const Text(
                '[not readable]',
                style: TextStyle(
                  color: SolarizedColors.red,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(width: 8),
            Text(
              node.id,
              style: TextStyle(
                color: cs.secondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );

    if (unreadableReason != null) {
      return Tooltip(message: unreadableReason, child: row);
    }
    return row;
  }

  static String? _directionSuffix(UmasFbMemberDirection d) {
    switch (d) {
      case UmasFbMemberDirection.input:
        return '(IN)';
      case UmasFbMemberDirection.output:
        return '(OUT)';
      case UmasFbMemberDirection.inOut:
        return '(IN/OUT)';
      case UmasFbMemberDirection.publicVar:
      case UmasFbMemberDirection.unknown:
        return null;
    }
  }

  static Color? _directionTint(UmasFbMemberDirection d) {
    switch (d) {
      case UmasFbMemberDirection.input:
        return SolarizedColors.blue;
      case UmasFbMemberDirection.output:
        return SolarizedColors.orange;
      case UmasFbMemberDirection.inOut:
        return SolarizedColors.violet;
      case UmasFbMemberDirection.publicVar:
      case UmasFbMemberDirection.unknown:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------
// VariableDetailStrip
// ---------------------------------------------------------------------------

class VariableDetailStrip extends StatelessWidget {
  final String displayName;
  final String nodeId;
  final String? description;
  final String? value;
  final String? dataType;
  final bool isLoading;

  const VariableDetailStrip({
    super.key,
    required this.displayName,
    required this.nodeId,
    this.description,
    this.value,
    this.dataType,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border:
            Border(top: BorderSide(color: SolarizedColors.cyan.withAlpha(40))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              FaIcon(FontAwesomeIcons.tag,
                  size: 10, color: SolarizedColors.green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  nodeId,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dataType != null) ...[
                const SizedBox(width: 12),
                Text(
                  dataType!,
                  style: TextStyle(color: cs.secondary, fontSize: 10),
                ),
              ],
              if (isLoading) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: SolarizedColors.cyan,
                  ),
                ),
              ],
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: TextStyle(color: cs.secondary, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (value != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('val ',
                    style: TextStyle(color: cs.secondary, fontSize: 10)),
                Expanded(
                  child: Text(
                    value!,
                    style: TextStyle(
                      color: SolarizedColors.cyan,
                      fontSize: 11,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
