/// The Pages block: which pages an audience may see.
///
/// One widget, mounted twice — inside a role's editor on the Access screen,
/// and inside an account's. The two differ only in wording, which is what
/// [AccessPagesLevel] carries. Two copies of a picker would be two places the
/// semantics of "no whitelist" could drift apart, and that distinction is the
/// whole feature (`docs/page-visibility-whitelist-design.md` §1b).
///
/// **Three states, and the widget makes all three reachable:**
///
/// * `null` — no whitelist. On a role that means every page; on an account it
///   means *follow the role*, which is not the same thing and is why the two
///   mounts word the option differently.
/// * empty set — a whitelist naming nothing: sees no pages. The "block all"
///   the feature was asked for by name. Legal, and reachable only by choosing
///   the restricted mode and ticking nothing, never as a side effect.
/// * a populated set — exactly those pages.
///
/// **The list is page-manager pages only.** The Advanced routes answer to
/// groups alone and are not whitelistable, so they are not offered here — see
/// §3 of the design note. Offering them would imply a control that does not
/// exist.
///
/// This widget owns no writes. It is a controlled editor: the mounting tile
/// holds the draft and calls `AccessAdminStore.setRolePages` /
/// `setUserPages` on Save, so ticking boxes is one audit row rather than one
/// per tick, and Cancel can mean it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/menu_item.dart';
import '../providers/page_manager.dart';

/// Which of the two mounts this is. Wording only — the stored shape is
/// identical, and so is everything the widget does.
enum AccessPagesLevel {
  /// Inside a role's editor. `null` means the role sees every page.
  role,

  /// Inside an account's editor. `null` means the account follows its role's
  /// pages, which is emphatically not "every page".
  user,
}

/// The two radio labels, per level.
String kAccessPagesOpenLabel(AccessPagesLevel level) =>
    switch (level) {
      AccessPagesLevel.role => 'Sees every page',
      AccessPagesLevel.user => "Follows this account's role",
    };

String kAccessPagesOpenSubtitle(AccessPagesLevel level) => switch (level) {
      AccessPagesLevel.role =>
        'Every page in the menu, including pages added later.',
      AccessPagesLevel.user =>
        'Whatever the role allows — the usual case, and what every account '
            'starts as.',
    };

const String kAccessPagesRestrictedLabel = 'Only the pages ticked below';

String kAccessPagesRestrictedSubtitle(AccessPagesLevel level) =>
    switch (level) {
      AccessPagesLevel.role =>
        'Everything else is hidden from the menu and refused at the page. '
            'Pages added later are hidden until granted here.',
      AccessPagesLevel.user =>
        'Replaces the role’s list for this account alone. Pages added '
            'later are hidden until granted here.',
    };

/// Shown where the page list would be, when there are no pages to show.
const String kAccessPagesNoPagesNote =
    'This station has no published pages to choose from yet.';

/// The heading over stored paths that name no current page.
const String kAccessPagesStaleNote =
    'No page has this path any more. It may have been renamed or deleted '
    'here, or it may exist on another station that has not synced yet — so '
    'it is kept until you remove it.';

Key kAccessPagesOpenKey(String owner) => Key('access-pages-open-$owner');
Key kAccessPagesRestrictedKey(String owner) =>
    Key('access-pages-restricted-$owner');
Key kAccessPagesRowKey(String owner, String path) =>
    Key('access-pages-row-$owner-$path');
Key kAccessPagesStaleKey(String owner, String path) =>
    Key('access-pages-stale-$owner-$path');
const Key kAccessPagesNoPagesKey = Key('access-pages-none');

/// The Pages block.
///
/// [selection] is the draft: null for "no whitelist", otherwise the set of
/// granted paths. [onChanged] is called with the new draft on every
/// interaction — the mount holds it and saves once.
class AccessPagesEditor extends ConsumerWidget {
  const AccessPagesEditor({
    super.key,
    required this.level,
    required this.owner,
    required this.selection,
    required this.onChanged,
  });

  final AccessPagesLevel level;

  /// The role name or username, used only to key the controls so two open
  /// editors on one screen cannot collide.
  final String owner;

  /// The draft. Null means no whitelist; see the library doc for why null and
  /// the empty set are different.
  final Set<String>? selection;

  final ValueChanged<Set<String>?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final restricted = selection != null;

    // The published pages, flat, in menu order. Read from the same provider
    // pair the plant page reads, so the picker lists what the menu lists.
    final manager = ref.watch(pageManagerProvider).valueOrNull ??
        ref.watch(bootstrapPageManagerProvider);
    final pages = <_PageRow>[];
    if (manager != null) {
      _flatten(manager.getRootMenuItems(), 0, pages);
    }

    // Stored paths that match no current page. Kept rather than dropped: a
    // path can be stale because another station has not synced its pages yet,
    // and silently discarding it on Save would make Save destructive.
    final known = {for (final row in pages) row.path};
    final stale = [
      for (final path in (selection ?? const <String>{}))
        if (!known.contains(path)) path,
    ]..sort();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Pages', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),

        // One `RadioGroup` around both tiles rather than a `groupValue` on
        // each: the per-tile form is deprecated, and the group is also what
        // makes "restricted or not" a single piece of state with one change
        // handler instead of two that could disagree.
        RadioGroup<bool>(
          groupValue: restricted,
          onChanged: (value) => onChanged(
            // Switching the mode OFF clears the list rather than remembering
            // it. A remembered-but-hidden whitelist would come back the next
            // time somebody flipped the radio, which is a grant nobody can
            // see. Switching it ON starts empty — block all — so that ticking
            // is always a deliberate widening.
            (value ?? false) ? <String>{} : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RadioListTile<bool>(
                key: kAccessPagesOpenKey(owner),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: false,
                title: Text(kAccessPagesOpenLabel(level)),
                subtitle: Text(kAccessPagesOpenSubtitle(level)),
              ),
              RadioListTile<bool>(
                key: kAccessPagesRestrictedKey(owner),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: true,
                title: const Text(kAccessPagesRestrictedLabel),
                subtitle: Text(kAccessPagesRestrictedSubtitle(level)),
              ),
            ],
          ),
        ),

        if (restricted) ...[
          const SizedBox(height: 4),
          if (pages.isEmpty)
            Padding(
              key: kAccessPagesNoPagesKey,
              padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
              child: Text(
                kAccessPagesNoPagesNote,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (final row in pages)
              CheckboxListTile(
                key: kAccessPagesRowKey(owner, row.path),
                dense: true,
                contentPadding: EdgeInsets.only(left: 8.0 + row.depth * 16.0),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(row.label),
                // The path as well as the label: the path is what is stored
                // and the label is renameable, so showing both is what makes a
                // grant checkable against the row that wrote it.
                subtitle: Text(
                  row.path,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                value: selection!.contains(row.path),
                onChanged: (ticked) {
                  final next = {...selection!};
                  if (ticked ?? false) {
                    next.add(row.path);
                  } else {
                    next.remove(row.path);
                  }
                  onChanged(next);
                },
              ),
          if (stale.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                kAccessPagesStaleNote,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            for (final path in stale)
              ListTile(
                key: kAccessPagesStaleKey(owner, path),
                dense: true,
                contentPadding: const EdgeInsets.only(left: 8),
                // `onSurfaceVariant`, not the error colour: a stale grant is
                // hygiene, not a fault, and red is the plant's fault colour.
                leading: Icon(Icons.help_outline,
                    size: 18, color: scheme.onSurfaceVariant),
                title: Text(path, style: theme.textTheme.bodyMedium),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove this path',
                  onPressed: () => onChanged({...selection!}..remove(path)),
                ),
              ),
          ],
        ],
      ],
    );
  }

  /// Flattens the menu into rows, keeping sections as indentation rather than
  /// as tickable entries.
  ///
  /// **Sections are not offered.** They are not routes — nothing resolves a
  /// group for one and nothing navigates to one — so a tick on a section would
  /// have to mean "and its children", which is an inheritance rule evaluated
  /// at check time against a stale copy of the tree shape. Leaf paths are the
  /// stored form, and moving a page between sections therefore does not
  /// invalidate its grant.
  static void _flatten(
      List<MenuItem> items, int depth, List<_PageRow> out) {
    for (final item in items) {
      if (item.isNavigationSection) {
        out.add(_PageRow(
          label: item.label,
          path: item.path ?? '',
          depth: depth,
          isSection: true,
        ));
        _flatten(item.children, depth + 1, out);
        continue;
      }
      final path = item.path;
      if (path == null || path.isEmpty) continue;
      out.add(_PageRow(label: item.label, path: path, depth: depth));
    }
  }
}

class _PageRow {
  const _PageRow({
    required this.label,
    required this.path,
    required this.depth,
    this.isSection = false,
  });

  final String label;
  final String path;
  final int depth;
  final bool isSection;
}
