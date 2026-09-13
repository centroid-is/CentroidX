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
/// **The list is the whole navigation tree**, not the plant's own pages alone:
/// every published page *and* every built-in destination, Advanced included.
/// It was pages-only for one revision, on the reading of §3 of the design note
/// that the built-ins answer to groups alone — but the menu filter
/// (`visibleMenuProvider`) has always asked `resolvePageAccess` about every
/// entry in the tree, so a whitelist already hid the built-ins and this widget
/// offered no way to grant them back. Setting any whitelist dropped the whole
/// Advanced section from that session's menu. Listing them is the half of that
/// fix that lives here; `routeExemptFromPageWhitelist` is the other half.
///
/// **`/advanced/access` is the one entry not offered.** No whitelist state may
/// hide the screen that edits whitelists (§4, layer 1), so there is nothing to
/// grant and a tickable box would imply a control that does nothing.
///
/// **Sections are headings, never tick boxes.** They are not routes — nothing
/// resolves a group for one and nothing navigates to one — so a tick on a
/// section would have to mean "and its children", an inheritance rule
/// evaluated at check time against a stale copy of the tree shape. Leaf paths
/// are the stored form, so moving a page between sections does not invalidate
/// its grant.
///
/// **The group a raised route needs is shown beside it.** The whitelist is a
/// filter and never a grant: ticking Page Editor for a role without
/// `configure` still leaves it shut. Saying so on the row is cheaper than
/// letting somebody discover it on the floor.
///
/// This widget owns no writes. It is a controlled editor: the mounting tile
/// holds the draft and calls `AccessAdminStore.setRolePages` /
/// `setUserPages` on Save, so ticking boxes is one audit row rather than one
/// per tick, and Cancel can mean it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:tfc_access/tfc_access.dart' show AccessGroup, AccessGroupInfo;

import '../access_routes.dart';
import '../models/menu_item.dart';
import '../providers/menu.dart';

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

/// A section heading. Keyed on the label because a section's path is not a
/// route and may be null.
Key kAccessPagesSectionKey(String owner, String label) =>
    Key('access-pages-section-$owner-$label');
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

    // The whole navigation tree, flat, in menu order — pages and built-ins
    // alike. `menuTreeProvider` and never `visibleMenuProvider`: this is the
    // screen that decides what a *different* audience sees, so handing it the
    // editing admin's own filtered view would make a page ungrantable to
    // exactly the people it was being granted to.
    final pages = _flatten(ref.watch(menuTreeProvider), 0);

    // Stored paths that match no current page. Kept rather than dropped: a
    // path can be stale because another station has not synced its pages yet,
    // and silently discarding it on Save would make Save destructive.
    //
    // Sections are not in the known set — they are not grantable, so a stored
    // section path is stale by definition and should surface as such. Nor is
    // the exempt route: nothing can have granted it, because it was never
    // offered.
    final known = {
      for (final row in pages)
        if (!row.isSection) row.path,
    };
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
              if (row.isSection)
                Padding(
                  key: kAccessPagesSectionKey(owner, row.label),
                  padding: EdgeInsets.only(
                      left: 8.0 + row.depth * 16.0, top: 8, bottom: 2),
                  child: Text(
                    row.label,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                CheckboxListTile(
                  key: kAccessPagesRowKey(owner, row.path),
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 8.0 + row.depth * 16.0),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(row.label),
                  // The path as well as the label: the path is what is stored
                  // and the label is renameable, so showing both is what makes
                  // a grant checkable against the row that wrote it. The group
                  // joins it on a raised route, because ticking one of those
                  // for an audience that does not hold the group changes
                  // nothing — the whitelist narrows and never grants.
                  subtitle: Text(
                    row.group == null
                        ? row.path
                        : '${row.path}  ·  needs ${row.group!.label}',
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

  /// Flattens the menu into rows: a heading for each section that still has
  /// something grantable under it, then its leaves, indented.
  ///
  /// **A section whose every descendant was dropped is dropped with them.** The
  /// only thing dropped today is the access screen, so an Advanced section that
  /// held nothing else would otherwise render as a heading over nothing.
  ///
  /// Returns the rows rather than filling an out-parameter, because the
  /// recursion has to *decide* whether to keep the heading, which it cannot do
  /// until its children have been walked.
  static List<_PageRow> _flatten(List<MenuItem> items, int depth) {
    final out = <_PageRow>[];
    for (final item in items) {
      if (item.isNavigationSection) {
        final children = _flatten(item.children, depth + 1);
        if (children.isEmpty) continue;
        out.add(_PageRow(
          label: item.label,
          path: item.path ?? '',
          depth: depth,
          isSection: true,
        ));
        out.addAll(children);
        continue;
      }
      final path = item.path;
      if (path == null || path.isEmpty) continue;
      // Never offered: nothing can hide it, so a tick box would be a control
      // that does nothing. See `routeExemptFromPageWhitelist`.
      if (routeExemptFromPageWhitelist(path)) continue;
      final group = accessGroupForRoute(path);
      out.add(_PageRow(
        label: item.label,
        path: path,
        depth: depth,
        // `operate` is what an undeclared route resolves to, so it says
        // nothing worth taking a line for; only a genuinely raised route
        // carries the note.
        group: group == AccessGroup.operate ? null : group,
      ));
    }
    return out;
  }
}

class _PageRow {
  const _PageRow({
    required this.label,
    required this.path,
    required this.depth,
    this.isSection = false,
    this.group,
  });

  final String label;
  final String path;
  final int depth;
  final bool isSection;

  /// The group this route is raised to, or null when it is unraised — which
  /// is every plant page and most of the built-ins.
  final AccessGroup? group;
}
