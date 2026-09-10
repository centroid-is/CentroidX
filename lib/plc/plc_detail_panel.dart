import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:tfc_dart/core/state_man_types.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_mcp_server/tfc_mcp_server.dart'
    show
        CallGraphData,
        PlcCodeBlock,
        PlcCodeService,
        PlcVariable,
        ReferenceKind,
        VariableReference;

import '../chat/ai_context_action.dart';
import '../core/feature_flags.dart';
import '../providers/plc.dart';

/// Builds a structured prompt for the LLM to explain a PLC code block.
///
/// The message instructs the AI copilot to retrieve and explain the given
/// code block, its variables, and how it relates to the system.
String buildChatAboutBlockMessage(
    String blockName, String blockType, String assetKey) {
  return '''Explain the PLC code block '$blockName' ($blockType) from asset '$assetKey'

Please gather all available information about this code block including:
- Retrieve the full block source (use search_plc_code with query "$blockName" and asset filter "$assetKey", then get_plc_code_block for the full code)
- Explain what this $blockType does based on its structured text implementation
- List its input/output variables and their purposes
- Identify any related assets or tags (use list_tags filtered by variable names)
- Cross-reference with technical documentation if available (use search_tech_docs)
Then provide a clear explanation of this code block's purpose and behavior.''';
}

// ---------------------------------------------------------------------------
// Sort order helpers
// ---------------------------------------------------------------------------

/// Sort priority for block types. Lower number = higher in the list.
int _blockTypeSortPriority(PlcCodeBlock block) {
  // MAIN program always first.
  if (block.blockType == 'Program' && block.blockName.toUpperCase() == 'MAIN') {
    return 0;
  }
  switch (block.blockType) {
    case 'Program':
      return 1;
    case 'Action':
      return 2;
    case 'FunctionBlock':
      return 3;
    case 'Function':
      return 4;
    case 'Method':
      return 5;
    case 'GVL':
      return 6;
    default:
      return 7;
  }
}

/// Returns sorted blocks: MAIN first, then Programs, Actions, FBs, GVLs, etc.
List<PlcCodeBlock> sortBlocks(List<PlcCodeBlock> blocks) {
  final sorted = List<PlcCodeBlock>.from(blocks);
  sorted.sort((a, b) {
    final pa = _blockTypeSortPriority(a);
    final pb = _blockTypeSortPriority(b);
    if (pa != pb) return pa.compareTo(pb);
    return a.blockName.compareTo(b.blockName);
  });
  return sorted;
}

/// Top-level block types shown in the initial navigation view.
bool _isTopLevelBlock(PlcCodeBlock block) {
  return block.blockType == 'Program' ||
      block.blockType == 'GVL' ||
      block.blockType == 'Action';
}

// ---------------------------------------------------------------------------
// Cross-reference: find function blocks referenced by a program's variables
// ---------------------------------------------------------------------------

/// Finds blocks referenced by [source] block's variable type declarations.
///
/// Scans the [source] block's variables for types that match the names of
/// other blocks in [allBlocks]. For example, if MAIN declares
/// `fbPump : FB_Pump`, and there is a block named `FB_Pump`, it is returned.
///
/// For child blocks (Actions, Methods, etc.) that inherit their parent's
/// variable scope per IEC 61131-3, the parent block's variables are also
/// included in the lookup -- but only those variables that are actually
/// **used** in the child's source code. This prevents showing all parent
/// FBs when only a subset is called by the action.
List<PlcCodeBlock> findReferencedBlocks(
    PlcCodeBlock source, List<PlcCodeBlock> allBlocks) {
  // Map from variable type name -> set of variable names with that type.
  // Needed for child blocks to filter by source code usage.
  final typeToVarNames = <String, Set<String>>{};

  // Collect variable types declared in this block.
  final variableTypes = <String>{};
  for (final v in source.variables) {
    variableTypes.add(v.variableType);
    typeToVarNames
        .putIfAbsent(v.variableType.toLowerCase(), () => {})
        .add(v.variableName);
  }

  // If this is a child block (Action, Method, etc.), also include
  // the parent block's variables -- children inherit parent scope.
  // Track parent variable names per type for source-code filtering.
  PlcCodeBlock? parentBlock;
  final parentVarTypes = <String>{};
  if (source.parentBlockId != null) {
    for (final b in allBlocks) {
      if (b.id == source.parentBlockId) {
        parentBlock = b;
        for (final v in b.variables) {
          variableTypes.add(v.variableType);
          parentVarTypes.add(v.variableType);
          typeToVarNames
              .putIfAbsent(v.variableType.toLowerCase(), () => {})
              .add(v.variableName);
        }
        break;
      }
    }
  }

  // Build a lookup of block names (case-insensitive for robustness).
  final blocksByName = <String, PlcCodeBlock>{};
  for (final b in allBlocks) {
    blocksByName[b.blockName.toLowerCase()] = b;
  }

  // Find matches: variable types that are also block names.
  final referenced = <PlcCodeBlock>[];
  // For child blocks, get the source code to filter inherited references.
  final sourceCode = source.fullSource.toLowerCase();

  for (final typeName in variableTypes) {
    final match = blocksByName[typeName.toLowerCase()];
    if (match != null && match.id != source.id) {
      // For inherited (parent) variable types in child blocks, only include
      // the FB if the child's source code actually uses the variable name.
      if (parentBlock != null && parentVarTypes.contains(typeName)) {
        final varNames = typeToVarNames[typeName.toLowerCase()] ?? {};
        final usedInSource = varNames.any(
          (name) => sourceCode.contains(name.toLowerCase()),
        );
        if (!usedInSource) continue;
      }
      referenced.add(match);
    }
  }

  return sortBlocks(referenced);
}

// ---------------------------------------------------------------------------
// Icons and colors for block types
// ---------------------------------------------------------------------------

IconData iconForBlockType(String type) {
  switch (type) {
    case 'FunctionBlock':
      return Icons.widgets_outlined;
    case 'Program':
      return Icons.play_arrow;
    case 'GVL':
      return Icons.public;
    case 'Function':
      return Icons.functions;
    case 'Method':
      return Icons.call_made;
    case 'Action':
      return Icons.flash_on;
    default:
      return Icons.code;
  }
}

Color colorForBlockType(String type) {
  switch (type) {
    case 'FunctionBlock':
      return Colors.blue;
    case 'Program':
      return Colors.green;
    case 'GVL':
      return Colors.orange;
    case 'Function':
      return Colors.purple;
    case 'Method':
      return Colors.teal;
    default:
      return Colors.grey;
  }
}

// ---------------------------------------------------------------------------
// PlcDetailPanel — main widget
// ---------------------------------------------------------------------------

/// Detail side panel shown when a PLC asset is selected in the knowledge base.
///
/// Two tabs:
/// - **Blocks**: drill-down navigation through programs, GVLs, and function
///   blocks (cross-referenced from variable type declarations).
/// - **Key Map**: bottom-up call graph keyed by HMI key mappings. Shows which
///   PLC variables each HMI key maps to, and which code blocks read/write them.
class PlcDetailPanel extends ConsumerWidget {
  const PlcDetailPanel({super.key, required this.assetKey});

  final String assetKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocksAsync = ref.watch(plcBlockListProvider(assetKey));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.code, size: 20, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  assetKey,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () {
                  ref.read(selectedPlcAssetProvider.notifier).state = null;
                },
                tooltip: 'Close panel',
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Content
        Expanded(
          child: blocksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error loading blocks: $e')),
            data: (blocks) {
              if (blocks.isEmpty) {
                return const Center(
                  child: Text(
                    'No code blocks found',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }
              return _TabbedDetailView(blocks: blocks, assetKey: assetKey);
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tabbed wrapper — Blocks vs Key Map tabs
// ---------------------------------------------------------------------------

/// Wraps the existing [_PlcNavigationView] and the new [_CallGraphView]
/// in a [DefaultTabController] with two tabs.
class _TabbedDetailView extends StatelessWidget {
  const _TabbedDetailView({required this.blocks, required this.assetKey});

  final List<PlcCodeBlock> blocks;
  final String assetKey;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Blocks'),
              Tab(text: 'Key Map'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _PlcNavigationView(blocks: blocks, assetKey: assetKey),
                _CallGraphView(blocks: blocks, assetKey: assetKey),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Navigation view — manages drill-down stack
// ---------------------------------------------------------------------------

/// Stateful navigation view that manages a drill-down stack.
///
/// At the top level shows sorted programs/GVLs. Tapping a block drills into
/// its detail view showing source code and referenced function blocks.
class _PlcNavigationView extends StatefulWidget {
  const _PlcNavigationView({required this.blocks, required this.assetKey});

  final List<PlcCodeBlock> blocks;
  final String assetKey;

  @override
  State<_PlcNavigationView> createState() => _PlcNavigationViewState();
}

class _PlcNavigationViewState extends State<_PlcNavigationView> {
  /// Stack of block names the user has drilled into.
  /// Empty = top-level view.
  final List<String> _navigationStack = [];

  void _drillInto(String blockName) {
    setState(() {
      _navigationStack.add(blockName);
    });
  }

  void _goBack() {
    setState(() {
      if (_navigationStack.isNotEmpty) {
        _navigationStack.removeLast();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_navigationStack.isEmpty) {
      return _TopLevelView(
        blocks: widget.blocks,
        assetKey: widget.assetKey,
        onDrillInto: _drillInto,
      );
    }

    final selectedName = _navigationStack.last;
    final selectedBlock = widget.blocks.firstWhere(
      (b) => b.blockName == selectedName,
      orElse: () => widget.blocks.first,
    );

    return _DrillDownView(
      block: selectedBlock,
      allBlocks: widget.blocks,
      assetKey: widget.assetKey,
      onBack: _goBack,
      onDrillInto: _drillInto,
    );
  }
}

// ---------------------------------------------------------------------------
// Top-level view — sorted list of programs and GVLs
// ---------------------------------------------------------------------------

class _TopLevelView extends StatelessWidget {
  const _TopLevelView({
    required this.blocks,
    required this.assetKey,
    required this.onDrillInto,
  });

  final List<PlcCodeBlock> blocks;
  final String assetKey;
  final ValueChanged<String> onDrillInto;

  @override
  Widget build(BuildContext context) {
    final firstBlock = blocks.first;
    final vendorType = firstBlock.vendorType ?? 'unknown';
    final serverAlias = firstBlock.serverAlias ?? '-';
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');
    final indexedDate = dateFormat.format(firstBlock.indexedAt);

    // Filter to top-level blocks and sort.
    final topLevel = sortBlocks(blocks.where(_isTopLevelBlock).toList());

    // Also collect non-top-level blocks to show a count.
    final otherBlocks = blocks.where((b) => !_isTopLevelBlock(b)).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Metadata card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metadataRow('Vendor', vendorType),
                const SizedBox(height: 4),
                _metadataRow('Server Alias', serverAlias),
                const SizedBox(height: 4),
                _metadataRow('Blocks', '${blocks.length} blocks'),
                const SizedBox(height: 4),
                _metadataRow('Indexed', indexedDate),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Top-level block tiles
        for (final block in topLevel)
          _TopLevelBlockTile(
            block: block,
            allBlocks: blocks,
            assetKey: assetKey,
            onTap: () => onDrillInto(block.blockName),
          ),

        // Summary of other blocks if any
        if (otherBlocks.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${otherBlocks.length} other blocks '
              '(function blocks, functions, methods)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _metadataRow(String label, String value) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    );
  }
}

/// A tile in the top-level view representing a program or GVL.
///
/// Shows the block name, type, and a count of referenced function blocks.
/// Tapping navigates into the drill-down view.
class _TopLevelBlockTile extends ConsumerWidget {
  const _TopLevelBlockTile({
    required this.block,
    required this.allBlocks,
    required this.assetKey,
    required this.onTap,
  });

  final PlcCodeBlock block;
  final List<PlcCodeBlock> allBlocks;
  final String assetKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chatAvailable = kChatEnabled;

    // Count referenced function blocks.
    final referencedCount = findReferencedBlocks(block, allBlocks).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        leading: Icon(
          iconForBlockType(block.blockType),
          size: 18,
          color: colorForBlockType(block.blockType),
        ),
        title: Text(
          block.blockName,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          referencedCount > 0
              ? '${block.blockType} \u00b7 $referencedCount referenced blocks'
              : block.blockType,
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kChatEnabled && chatAvailable)
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                tooltip: 'Chat about this block',
                onPressed: () => _chatAboutBlock(ref),
              ),
            const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  void _chatAboutBlock(WidgetRef ref) {
    AiContextAction.openChatAndSend(
      ref: ref,
      message: buildChatAboutBlockMessage(
          block.blockName, block.blockType, assetKey),
    );
  }
}

// ---------------------------------------------------------------------------
// Drill-down view — block detail + referenced function blocks
// ---------------------------------------------------------------------------

/// Detail view shown when a user drills into a specific block.
///
/// Shows:
/// - A back button to return to the previous level
/// - The block's source code (in a collapsible section)
/// - The block's variables (in a collapsible section)
/// - A list of function blocks referenced by this block's variable types
class _DrillDownView extends StatelessWidget {
  const _DrillDownView({
    required this.block,
    required this.allBlocks,
    required this.assetKey,
    required this.onBack,
    required this.onDrillInto,
  });

  final PlcCodeBlock block;
  final List<PlcCodeBlock> allBlocks;
  final String assetKey;
  final VoidCallback onBack;
  final ValueChanged<String> onDrillInto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final referencedBlocks = findReferencedBlocks(block, allBlocks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Back button header
        InkWell(
          onTap: onBack,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.arrow_back, size: 18),
                const SizedBox(width: 8),
                Icon(
                  iconForBlockType(block.blockType),
                  size: 18,
                  color: colorForBlockType(block.blockType),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    block.blockName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  block.blockType,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),

        // Scrollable content
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // Source code (collapsible)
              _CollapsibleSection(
                title: 'Source Code',
                initiallyExpanded: false,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    block.fullSource,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),

              // Variables (collapsible)
              if (block.variables.isNotEmpty) ...[
                const SizedBox(height: 8),
                _CollapsibleSection(
                  title: 'Variables (${block.variables.length})',
                  initiallyExpanded: false,
                  child: _VariablesList(variables: block.variables),
                ),
              ],

              // Referenced function blocks
              if (referencedBlocks.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Referenced Blocks (${referencedBlocks.length})',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                for (final ref in referencedBlocks)
                  _ReferencedBlockTile(
                    block: ref,
                    assetKey: assetKey,
                    onTap: () => onDrillInto(ref.blockName),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Referenced block tile in drill-down view
// ---------------------------------------------------------------------------

/// Tile for a function block referenced by the current program.
///
/// Shows the block name, type, and variable count. Tapping drills deeper
/// into that block. An expansion tile lets the user peek at the source code
/// inline without navigating.
class _ReferencedBlockTile extends ConsumerWidget {
  const _ReferencedBlockTile({
    required this.block,
    required this.assetKey,
    required this.onTap,
  });

  final PlcCodeBlock block;
  final String assetKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chatAvailable = kChatEnabled;

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
        leading: Icon(
          iconForBlockType(block.blockType),
          size: 18,
          color: colorForBlockType(block.blockType),
        ),
        title: Text(
          block.blockName,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          '${block.blockType} \u00b7 ${block.variables.length} vars',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (kChatEnabled && chatAvailable)
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                tooltip: 'Chat about this block',
                onPressed: () => _chatAboutBlock(ref),
              ),
            const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
          ],
        ),
        children: [
          // Inline source code preview
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    block.fullSource,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
                if (block.variables.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _VariablesList(variables: block.variables),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _chatAboutBlock(WidgetRef ref) {
    AiContextAction.openChatAndSend(
      ref: ref,
      message: buildChatAboutBlockMessage(
          block.blockName, block.blockType, assetKey),
    );
  }
}

// ---------------------------------------------------------------------------
// Collapsible section
// ---------------------------------------------------------------------------

/// A section with a header that can be expanded/collapsed.
class _CollapsibleSection extends StatefulWidget {
  const _CollapsibleSection({
    required this.title,
    required this.child,
    this.initiallyExpanded = true,
  });

  final String title;
  final Widget child;
  final bool initiallyExpanded;

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          widget.child,
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Variables list (shared between top-level and drill-down views)
// ---------------------------------------------------------------------------

/// Variables list grouped by VAR section (VAR_INPUT, VAR_OUTPUT, etc.).
class _VariablesList extends StatelessWidget {
  const _VariablesList({required this.variables});

  final List<PlcVariable> variables;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Group by section.
    final grouped = <String, List<PlcVariable>>{};
    for (final v in variables) {
      grouped.putIfAbsent(v.section, () => []).add(v);
    }

    // Sort sections in a logical order.
    final sectionOrder = [
      'VAR_INPUT',
      'VAR_OUTPUT',
      'VAR_IN_OUT',
      'VAR',
      'VAR_GLOBAL',
      'VAR_TEMP',
      'VAR_STAT',
    ];
    final sortedSections = grouped.keys.toList()
      ..sort((a, b) {
        final ai = sectionOrder.indexOf(a);
        final bi = sectionOrder.indexOf(b);
        final sa = ai >= 0 ? ai : sectionOrder.length;
        final sb = bi >= 0 ? bi : sectionOrder.length;
        return sa.compareTo(sb);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sortedSections) ...[
          Text(
            section,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 2),
          for (final v in grouped[section]!) _variableRow(v, theme),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _variableRow(PlcVariable v, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 1, bottom: 1),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              v.variableName,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v.variableType,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.blue[700],
              ),
            ),
          ),
          if (v.comment != null)
            Expanded(
              flex: 2,
              child: Text(
                '// ${v.comment}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.green[700],
                  fontStyle: FontStyle.italic,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Key Map view — flat selectable list of HMI keys with bottom-up trace
// ---------------------------------------------------------------------------

/// A data class representing one HMI key and its optional call graph trace.
class _KeyCallChain {
  const _KeyCallChain({
    required this.keyName,
    required this.variablePath,
    required this.variableType,
    required this.references,
    required this.callerChains,
  });

  /// The HMI key name (e.g. "pump3.speed").
  final String keyName;

  /// The PLC variable path extracted from the OPC-UA identifier.
  final String? variablePath;

  /// The variable type from the declaring block (e.g. "REAL", "BOOL").
  final String? variableType;

  /// Direct variable references (readers/writers) from the call graph.
  final List<VariableReference> references;

  /// For each referencing block, the chain of callers up to entry points.
  /// Map key = blockName, value = list of caller block names.
  final Map<String, List<String>> callerChains;
}

/// Key Map tab view: shows HMI keys as a flat selectable list.
///
/// Keys are filtered by the server alias of the PLC code blocks. When the
/// user selects a key, the bottom-up call graph trace is shown below the
/// key list. Call graph data is optional -- keys are displayed regardless
/// of whether PLC code has been indexed.
class _CallGraphView extends ConsumerWidget {
  const _CallGraphView({required this.blocks, required this.assetKey});

  final List<PlcCodeBlock> blocks;
  final String assetKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keyMappingsAsync = ref.watch(keyMappingsProvider);
    // Call graph data is optional — null when no PLC code is indexed.
    final callGraphAsync = ref.watch(callGraphDataProvider(assetKey));

    return keyMappingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error loading key mappings: $e')),
      data: (keyMappings) {
        if (keyMappings == null) {
          return const Center(
            child: Text(
              'Key mappings not available',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        return callGraphAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error building call graph: $e')),
          data: (callGraph) {
            // callGraph may be null if no PLC code is indexed — that's OK.
            return _KeyMapContent(
              blocks: blocks,
              keyMappings: keyMappings,
              callGraph: callGraph,
            );
          },
        );
      },
    );
  }
}

/// Stateful content widget for the Key Map tab.
///
/// Shows a flat list of HMI keys. When a key is selected, its bottom-up
/// call graph trace is displayed below the list.
class _KeyMapContent extends StatefulWidget {
  const _KeyMapContent({
    required this.blocks,
    required this.keyMappings,
    required this.callGraph,
  });

  final List<PlcCodeBlock> blocks;
  final KeyMappings keyMappings;
  final CallGraphData? callGraph;

  @override
  State<_KeyMapContent> createState() => _KeyMapContentState();
}

class _KeyMapContentState extends State<_KeyMapContent> {
  String? _selectedKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serverAlias =
        widget.blocks.isNotEmpty ? widget.blocks.first.serverAlias : null;
    final filtered = widget.keyMappings.filterByServer(serverAlias);

    if (filtered.nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            serverAlias != null
                ? 'No key mappings found for server "$serverAlias"'
                : 'No key mappings found (no server alias on blocks)',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Sort keys alphabetically.
    final sortedKeys = filtered.nodes.keys.toList()..sort();

    // Build the selected key's call chain if one is selected.
    _KeyCallChain? selectedChain;
    if (_selectedKey != null && filtered.nodes.containsKey(_selectedKey)) {
      selectedChain = _buildKeyCallChain(
        _selectedKey!,
        filtered.nodes[_selectedKey!]!,
        widget.callGraph,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header with key count
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            '${sortedKeys.length} keys for '
            '${serverAlias ?? "this PLC"}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // Key list (scrollable, takes available space or shares with detail)
        Expanded(
          child: _selectedKey == null
              ? _buildKeyList(theme, sortedKeys, filtered)
              : _buildSelectedKeyView(theme, selectedChain!),
        ),
      ],
    );
  }

  Widget _buildKeyList(
    ThemeData theme,
    List<String> sortedKeys,
    KeyMappings filtered,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final keyName = sortedKeys[index];
        final mapping = filtered.nodes[keyName]!;
        final identifier = mapping.opcuaNode?.identifier ?? '';
        final variablePath = PlcCodeService.extractPlcVariablePath(identifier);

        return _KeyListTile(
          keyName: keyName,
          variablePath: variablePath,
          isSelected: _selectedKey == keyName,
          onTap: () => setState(() => _selectedKey = keyName),
        );
      },
    );
  }

  Widget _buildSelectedKeyView(ThemeData theme, _KeyCallChain chain) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Back button + selected key header
        InkWell(
          onTap: () => setState(() => _selectedKey = null),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.arrow_back, size: 18),
                const SizedBox(width: 8),
                Icon(
                  chain.variablePath != null
                      ? Icons.vpn_key
                      : Icons.vpn_key_off,
                  size: 16,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chain.keyName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),

        // Call graph trace detail
        Expanded(
          child: _KeyTraceDetail(
            chain: chain,
            hasPlcCode: widget.blocks.isNotEmpty,
          ),
        ),
      ],
    );
  }

  /// Build a call chain for a single key.
  _KeyCallChain _buildKeyCallChain(
    String keyName,
    KeyMappingEntry mapping,
    CallGraphData? callGraph,
  ) {
    final identifier = mapping.opcuaNode?.identifier ?? '';
    final variablePath = PlcCodeService.extractPlcVariablePath(identifier);

    if (variablePath == null) {
      return _KeyCallChain(
        keyName: keyName,
        variablePath: null,
        variableType: null,
        references: const [],
        callerChains: const {},
      );
    }

    if (callGraph == null) {
      // No PLC code indexed — return the key with variable path but no refs.
      return _KeyCallChain(
        keyName: keyName,
        variablePath: variablePath,
        variableType: null,
        references: const [],
        callerChains: const {},
      );
    }

    // Get variable references (readers/writers).
    final refs = callGraph.getReferences(variablePath);

    // Get variable context for type info.
    final varCtx = callGraph.getVariableContext(variablePath);
    final variableType = varCtx?['variableType'] as String?;

    // Build a lookup of block names to blocks for caller resolution.
    final blocksByName = <String, PlcCodeBlock>{};
    for (final b in widget.blocks) {
      blocksByName[b.blockName] = b;
    }

    // For each referencing block, find its callers.
    final callerChains = <String, List<String>>{};
    final seenBlocks = <String>{};
    for (final ref in refs) {
      if (seenBlocks.add(ref.blockName)) {
        callerChains[ref.blockName] = _findCallers(
          ref.blockName,
          blocksByName,
          callGraph,
        );
      }
    }

    return _KeyCallChain(
      keyName: keyName,
      variablePath: variablePath,
      variableType: variableType,
      references: refs,
      callerChains: callerChains,
    );
  }

  /// Trace callers of [blockName] upward to entry points.
  List<String> _findCallers(
    String blockName,
    Map<String, PlcCodeBlock> blocksByName,
    CallGraphData callGraph,
  ) {
    final callers = <String>[];
    final visited = <String>{blockName};
    final allRefs = callGraph.references;

    void traceUp(String name) {
      for (final ref in allRefs) {
        if (ref.kind == ReferenceKind.call) {
          final instances = callGraph.getInstances(name);
          for (final inst in instances) {
            final callPath = '${inst.declaringBlock}.${inst.instanceName}';
            if (ref.variablePath == callPath &&
                !visited.contains(ref.blockName)) {
              visited.add(ref.blockName);
              callers.add(ref.blockName);
              traceUp(ref.blockName);
            }
          }
        }
      }

      for (final ref in allRefs) {
        if (ref.kind == ReferenceKind.call &&
            ref.variablePath.endsWith('.$name') &&
            !visited.contains(ref.blockName)) {
          visited.add(ref.blockName);
          callers.add(ref.blockName);
          traceUp(ref.blockName);
        }
      }
    }

    traceUp(blockName);
    return callers;
  }
}

// ---------------------------------------------------------------------------
// Key list tile — one row per HMI key in the flat list
// ---------------------------------------------------------------------------

/// A single row in the key list. Tapping selects the key and shows its trace.
class _KeyListTile extends StatelessWidget {
  const _KeyListTile({
    required this.keyName,
    required this.variablePath,
    required this.isSelected,
    required this.onTap,
  });

  final String keyName;
  final String? variablePath;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 2),
      color: isSelected ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        dense: true,
        leading: Icon(
          variablePath != null ? Icons.vpn_key : Icons.vpn_key_off,
          size: 16,
          color: variablePath != null ? Colors.blue : Colors.grey,
        ),
        title: Text(
          keyName,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
        subtitle: variablePath != null
            ? Text(
                variablePath!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[600],
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              )
            : null,
        trailing: const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
        onTap: onTap,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Key trace detail — bottom-up call graph trace for selected key
// ---------------------------------------------------------------------------

/// Shows the bottom-up call graph trace for a selected key.
///
/// Handles three states:
/// - No PLC code indexed: shows informational message
/// - PLC code indexed but no references found: shows "no references" message
/// - References found: shows the full trace tree
class _KeyTraceDetail extends StatelessWidget {
  const _KeyTraceDetail({
    required this.chain,
    required this.hasPlcCode,
  });

  final _KeyCallChain chain;
  final bool hasPlcCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasVarPath = chain.variablePath != null;
    final hasRefs = chain.references.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Variable path display
        if (hasVarPath) ...[
          Text(
            'PLC Variable',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            chain.variablePath!,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (chain.variableType != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    chain.variableType!,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Colors.blue[700],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
        ],

        // Trace content — depends on state
        if (!hasVarPath)
          _infoCard(
            context,
            Icons.info_outline,
            'This key uses a numeric OPC-UA identifier that cannot be '
            'mapped to a PLC variable name.',
          )
        else if (!hasPlcCode)
          _infoCard(
            context,
            Icons.upload_file,
            'No PLC code indexed \u2014 upload PLC project to see '
            'call graph traces.',
          )
        else if (!hasRefs)
          _infoCard(
            context,
            Icons.search_off,
            'No PLC references found for this key.\n\n'
            'Variable ${chain.variablePath} was not found in any code block '
            'implementation. It may be a GVL variable that is not '
            'referenced in the indexed code.',
          )
        else
          _VariableReferenceTree(chain: chain),
      ],
    );
  }

  Widget _infoCard(BuildContext context, IconData icon, String message) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Variable reference tree — readers/writers with caller chains
// ---------------------------------------------------------------------------

/// Displays the reference tree for a variable: type info, readers, writers,
/// and their caller chains.
class _VariableReferenceTree extends StatelessWidget {
  const _VariableReferenceTree({required this.chain});

  final _KeyCallChain chain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Group references by kind (write, read, call).
    final writers =
        chain.references.where((r) => r.kind == ReferenceKind.write).toList();
    final readers =
        chain.references.where((r) => r.kind == ReferenceKind.read).toList();

    // Deduplicate references that have identical block name AND no
    // distinguishing source info (both lineNumber and sourceLine are null).
    // When source lines differ, keep each one visible.
    final dedupedWriters = _deduplicateRefs(writers);
    final dedupedReaders = _deduplicateRefs(readers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Writers
        if (dedupedWriters.isNotEmpty) ...[
          _sectionLabel(theme, 'Written by', Icons.edit, Colors.orange),
          for (final entry in dedupedWriters)
            _ReferenceRow(
              ref: entry.ref,
              callers: chain.callerChains[entry.ref.blockName],
              duplicateCount: entry.count,
            ),
        ],

        // Readers
        if (dedupedReaders.isNotEmpty) ...[
          if (dedupedWriters.isNotEmpty) const SizedBox(height: 6),
          _sectionLabel(theme, 'Read by', Icons.visibility, Colors.green),
          for (final entry in dedupedReaders)
            _ReferenceRow(
              ref: entry.ref,
              callers: chain.callerChains[entry.ref.blockName],
              duplicateCount: entry.count,
            ),
        ],
      ],
    );
  }

  /// Deduplicate references that share the same block name and have
  /// no distinguishing source information (null lineNumber and sourceLine).
  /// References with different line numbers or source lines are kept separate.
  static List<_DeduplicatedRef> _deduplicateRefs(List<VariableReference> refs) {
    final result = <_DeduplicatedRef>[];
    final nullSourceCounts = <String, int>{}; // blockName -> count
    final nullSourceRep =
        <String, VariableReference>{}; // blockName -> first ref

    for (final ref in refs) {
      if (ref.lineNumber == null && ref.sourceLine == null) {
        // No source info — group by block name.
        final count = (nullSourceCounts[ref.blockName] ?? 0) + 1;
        nullSourceCounts[ref.blockName] = count;
        nullSourceRep.putIfAbsent(ref.blockName, () => ref);
      } else {
        // Has source info — keep individual.
        result.add(_DeduplicatedRef(ref: ref, count: 1));
      }
    }

    // Add the deduplicated null-source entries.
    for (final entry in nullSourceRep.entries) {
      result.add(_DeduplicatedRef(
        ref: entry.value,
        count: nullSourceCounts[entry.key]!,
      ));
    }

    return result;
  }

  Widget _sectionLabel(
      ThemeData theme, String label, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A reference with an optional duplicate count for deduplication display.
class _DeduplicatedRef {
  const _DeduplicatedRef({required this.ref, required this.count});
  final VariableReference ref;
  final int count;
}

/// A single variable reference row with optional caller chain.
class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({
    required this.ref,
    this.callers,
    this.duplicateCount = 1,
  });

  final VariableReference ref;
  final List<String>? callers;
  final int duplicateCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Block name + line number + duplicate count badge
          Row(
            children: [
              Icon(
                iconForBlockType(ref.blockType),
                size: 14,
                color: colorForBlockType(ref.blockType),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: ref.blockName,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (ref.lineNumber != null)
                        TextSpan(
                          text: ' (line ${ref.lineNumber})',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      if (duplicateCount > 1)
                        TextSpan(
                          text: '  x$duplicateCount',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange[700],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // Source line preview
          if (ref.sourceLine != null)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 1),
              child: Text(
                ref.sourceLine!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.grey[600],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          // Caller chain
          if (callers != null && callers!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < callers!.length; i++)
                    Padding(
                      padding: EdgeInsets.only(left: 12.0 * i),
                      child: Row(
                        children: [
                          Icon(
                            Icons.subdirectory_arrow_right,
                            size: 12,
                            color: Colors.grey[500],
                          ),
                          const SizedBox(width: 2),
                          Text(
                            'Called by ${callers![i]}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
