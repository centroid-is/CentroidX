import 'package:flutter/material.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';

import '../converter/icon.dart';
import 'panes/pane_chrome.dart';
import 'panes/standard_dialog.dart';

/// One offer in the picker: the glyph and the name it serialises as.
typedef IconEntry = ({IconData icon, String name});

/// The heading a flat, unsearched list falls back to.
const _generalSection = 'General';

/// Opens the icon picker.
///
/// There used to be two of these: a searchable one for the page menu icon and
/// a bare 400-cell grid for assets, where finding a glyph meant scrolling and
/// recognising it. They are the same picker now, and it is grouped as well as
/// searchable — the industrial glyphs are only worth adding if an operator can
/// find them, and `pump` and `motor` are names long before they are shapes.
///
/// [onCleared], when given, adds a "Clear icon" action — for the places that
/// treat "no icon" as a valid answer, such as a conditional state that only
/// overrides the colour.
Future<void> showIconPicker({
  required BuildContext context,
  required ValueChanged<IconData> onSelected,
  String title = 'Select icon',
  IconData? selected,
  VoidCallback? onCleared,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => IconPickerDialog(
      title: title,
      selected: selected,
      onSelected: (icon) {
        onSelected(icon);
        Navigator.pop(context);
      },
      onCleared: onCleared == null
          ? null
          : () {
              onCleared();
              Navigator.pop(context);
            },
    ),
  );
}

/// The sections offered when nothing is typed, in order.
///
/// Built once: [iconList] is a few hundred entries and every one of them costs
/// a name lookup through the converter's if-chain.
final List<(String, List<IconEntry>)> iconPickerSections = _buildSections();

List<(String, List<IconEntry>)> _buildSections() {
  final byName = <String, IconEntry>{};
  final ordered = <IconEntry>[];
  for (final icon in iconList) {
    final name = IconDataConverter.getIconName(icon);
    final entry = (icon: icon, name: name);
    // iconList has a handful of duplicates, and an unregistered glyph comes
    // back as 'help' — neither should show up twice in the grid.
    if (byName.containsKey(name)) continue;
    byName[name] = entry;
    ordered.add(entry);
  }

  final sections = <(String, List<IconEntry>)>[];
  final grouped = <String>{};
  for (final group in industrialIconGroups.entries) {
    final entries = [
      for (final name in group.value)
        if (byName[name] != null) byName[name]!,
    ];
    if (entries.isEmpty) continue;
    grouped.addAll(group.value);
    sections.add((group.key, entries));
  }
  sections.add((
    _generalSection,
    [
      for (final entry in ordered)
        if (!grouped.contains(entry.name)) entry,
    ],
  ));
  return sections;
}

/// Every entry the picker offers, flattened — the corpus the search runs over.
final List<IconEntry> iconPickerEntries = [
  for (final section in iconPickerSections) ...section.$2,
];

class IconPickerDialog extends StatefulWidget {
  final ValueChanged<IconData> onSelected;
  final VoidCallback? onCleared;
  final IconData? selected;
  final String title;

  const IconPickerDialog({
    super.key,
    required this.onSelected,
    this.onCleared,
    this.selected,
    this.title = 'Select icon',
  });

  @override
  State<IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<IconPickerDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Sections to render: the fixed grouping while the search box is empty, and
  /// one ranked list of hits once it is not.
  List<(String, List<IconEntry>)> get _sections {
    if (_query.isEmpty) return iconPickerSections;
    final hits = fuzzyFilter(
      iconPickerEntries,
      _query,
      [(IconEntry entry) => entry.name.replaceAll('_', ' ')],
    );
    return [('${hits.length} match${hits.length == 1 ? '' : 'es'}', hits)];
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    final empty = sections.every((section) => section.$2.isEmpty);
    return StandardDialogFrame(
      title: widget.title,
      icon: Icons.emoji_symbols,
      width: 560,
      height: 560,
      scrollable: false,
      actions: [
        if (widget.onCleared != null)
          PaneAction(
            label: 'Clear icon',
            icon: Icons.format_clear,
            onPressed: widget.onCleared,
          ),
      ],
      child: Column(
        children: [
          // Deliberately not autofocused. On the elinux panels the embedder
          // runs with --onscreen-keyboard, so focusing a field raises weston's
          // input panel over the bottom third of the screen — which is most of
          // the grid. Browsing is the default way into this dialog; typing is
          // one tap away.
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search icons…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
              isDense: true,
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: empty
                ? const Center(child: Text('No icons found'))
                : CustomScrollView(
                    slivers: [
                      for (final (label, entries) in sections) ...[
                        if (entries.isNotEmpty)
                          SliverToBoxAdapter(
                            child: _SectionHeading(label: label),
                          ),
                        SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 6,
                            childAspectRatio: 0.82,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            childCount: entries.length,
                            (context, index) => _IconCell(
                              entry: entries[index],
                              selected: entries[index].icon == widget.selected,
                              onTap: () => widget.onSelected(entries[index].icon),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String label;

  const _SectionHeading({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 0.8,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _IconCell extends StatelessWidget {
  final IconEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _IconCell({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = entry.name.replaceAll('_', ' ');
    return Tooltip(
      message: displayName,
      waitDuration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(entry.icon, size: 28),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    displayName,
                    style: theme.textTheme.labelSmall?.copyWith(fontSize: 9),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
