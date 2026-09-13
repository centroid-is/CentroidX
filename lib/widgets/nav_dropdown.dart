import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:beamer/beamer.dart';
import 'package:tfc_dart/core/alarm.dart';
import '../models/menu_item.dart';
import '../providers/nav_alarm.dart' show navigationAlarmLevelFor;
import '../route_registry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'access_lock_badge.dart';
import 'nav_alarm_badge.dart';
import 'leave_guard.dart';

class TopLevelNavIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  /// Level to badge the icon at, or null for quiet. On a section this is the
  /// worst alarm anywhere beneath it — the pages themselves have no icon of
  /// their own until the menu is opened.
  final AlarmLevel? alarmLevel;

  /// Freezes the badge's pulse at a fixed phase. Golden tests only.
  final double? alarmProgressOverride;

  const TopLevelNavIndicator(this.icon, this.label, this.active,
      {super.key, this.alarmLevel, this.alarmProgressOverride});

  @override
  Widget build(BuildContext context) {
    final color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          NavAlarmBadge(
            level: alarmLevel,
            progressOverride: alarmProgressOverride,
            child: Icon(icon, color: color, size: 25),
          ),
          Padding(
              padding: const EdgeInsets.fromLTRB(8.0, 0, 0, 0),
              child:
                  Text(label, style: Theme.of(context).textTheme.labelMedium)),
        ],
      ),
    );
  }
}

class NavDropdown extends ConsumerStatefulWidget {
  static const double itemHeight = 48.0;
  static const double menuWidth = 260.0;

  /// Notifies listeners when any [NavDropdown] popup menu is open.
  /// Used by the app shell to hide overlapping widgets (e.g. chat FAB)
  /// that are rendered above the Navigator's Overlay in the widget tree.
  static final ValueNotifier<bool> isAnyMenuOpen = ValueNotifier<bool>(false);

  final MenuItem menuItem;

  /// Page path -> active alarm level, for the whole app. Supplied by the
  /// navigation bar, which owns the one alarm subscription for the whole bar
  /// rather than one per destination.
  ///
  /// The map, not a single level: the section icon shows the worst alarm
  /// beneath it, and the popup then badges the individual pages, which is the
  /// only place the operator can see *which* page it was.
  final Map<String, AlarmLevel> alarmLevels;

  /// Path currently on screen; it never badges. See [navigationAlarmLevelFor].
  final String? currentPath;

  const NavDropdown({
    super.key,
    required this.menuItem,
    this.alarmLevels = const {},
    this.currentPath,
  });

  @override
  ConsumerState<NavDropdown> createState() => NavDropdownState();
}

class NavDropdownState extends ConsumerState<NavDropdown> {
  /// Guard that prevents [showMenu] from being called while a popup menu is
  /// already open. Without this, rapid tapping can push a second popup route
  /// while the Navigator is still transitioning, throwing
  /// `'!_debugLocked': is not true`.
  bool _isMenuOpen = false;

  /// Whether the popup menu is currently open. Exposed for testing.
  @visibleForTesting
  bool get isMenuOpen => _isMenuOpen;

  // From a given page path. Find the topmost node that holds
  // the ownership path of the node
  MenuItem? findRootNodeOfLeaf(MenuItem node, MenuItem? base, String path) {
    if (node.path != null && node.path! == path) return base ?? node;
    for (final child in node.children) {
      MenuItem? foundBase = findRootNodeOfLeaf(
          child, node != RouteRegistry().root ? base ?? node : null, path);
      if (foundBase != null) return foundBase;
    }
    return null;
  }

  /// Flattens the menu tree into indented PopupMenuItems.
  /// Sections (flagged as such, or legacy items with children) appear as
  /// disabled headers; leaf pages are clickable.
  ///
  /// Navigation is performed in [PopupMenuItem.onTap] (which fires before
  /// Flutter's internal `Navigator.pop(null)`), so the pop value is always
  /// `void` — compatible with any route type on the root Navigator stack.
  List<PopupMenuEntry<void>> buildFlatMenu(MenuItem root,
      {required BuildContext parentContext, int depth = 0}) {
    final items = <PopupMenuEntry<void>>[];
    for (final child in root.children) {
      final indent = EdgeInsets.only(left: depth * 16.0);
      // Sections carry the worst level from their subtree, leaves their own —
      // both fall out of the same walk.
      final childLevel = navigationAlarmLevelFor(child, widget.alarmLevels,
          currentPath: widget.currentPath);
      if (child.isNavigationSection) {
        // Section header (not clickable)
        items.add(PopupMenuItem<void>(
          enabled: false,
          height: NavDropdown.itemHeight,
          child: Padding(
            padding: indent,
            child: Row(
              children: [
                NavAlarmBadge(
                    level: childLevel, child: Icon(child.icon, size: 20)),
                const SizedBox(width: 12),
                Text(child.label,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ));
        final sub = buildFlatMenu(child,
            parentContext: parentContext, depth: depth + 1);
        // A section whose every page is hidden is a heading over nothing, so
        // it goes too — and its own header, added just above, comes back off.
        if (sub.isEmpty) {
          items.removeLast();
        } else {
          items.addAll(sub);
        }
      } else {
        // **No filtering here any more.** `widget.menuItem` arrives already
        // filtered by `visibleMenuProvider`, which drops the entries this
        // session cannot open and collapses the sections they emptied. This
        // widget used to compute that set itself, during build, because it
        // could not `watch` from `showMenu`'s item builder — one filter in a
        // provider removes both the duplication and the timing problem, and
        // is what lets the bar above change between logins too.
        items.add(PopupMenuItem<void>(
          height: NavDropdown.itemHeight,
          onTap: () => beamSafelyKids(parentContext, child),
          child: Padding(
            padding: indent,
            child: Row(
              children: [
                NavAlarmBadge(
                    level: childLevel, child: Icon(child.icon, size: 20)),
                const SizedBox(width: 12),
                Flexible(
                    child: Text(child.label, overflow: TextOverflow.ellipsis)),
                // A lock when the session cannot open this page, and exactly
                // nothing otherwise — no SizedBox beside it, because the badge
                // brings its own gap and an unlocked row must lay out as it
                // always did. The entry stays enabled and keeps its onTap: the
                // lock is advisory, and the AccessGate on the route is what
                // refuses and offers the sign-in.
                AccessLockBadge(path: child.path),
              ],
            ),
          ),
        ));
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    // Capture the parent context so we can safely navigate after the popup closes
    final parentContext = context;

    final activeRoot = findRootNodeOfLeaf(RouteRegistry().root, null,
        (context.currentBeamLocation.state as BeamState).uri.path);
    if (activeRoot != null) {
      // print('I am here ${activeRoot.label}');
    }
    return Builder(
      builder: (innerContext) {
        return InkWell(
          key: ValueKey<String>('nav-${widget.menuItem.label.toLowerCase()}'),
          onTap: () async {
            // BUG-001 fix: prevent re-entrant showMenu calls during
            // Navigator transitions from rapid tapping.
            if (_isMenuOpen) return;
            _isMenuOpen = true;
            NavDropdown.isAnyMenuOpen.value = true;

            // A tap on the navigation bar takes the pane away, and a section
            // is a tap on the navigation bar. The bar's own
            // onDestinationSelected does this, but it never runs for a
            // section: this InkWell is inside the destination and consumes
            // the tap, so the pane used to sit there through the whole menu
            // -- and stayed put if the operator dismissed it without
            // choosing a page. Closing here makes every destination behave
            // the same way. Config editors write straight into their asset,
            // so nothing is lost by closing early.
            closeSidePane(immediate: true);

            // Sized from the entries that will actually be shown, not from a
            // separate count of the tree.
            //
            // These were two computations of the same number — `_countAllItems`
            // walked the tree and `buildFlatMenu` built the rows — and hiding
            // locked entries made them disagree: the popup was sized and
            // positioned for rows that no longer existed, so it opened floating
            // in the middle of the screen instead of anchored above the button.
            // Building first and measuring the result cannot drift.
            final items = buildFlatMenu(widget.menuItem,
                parentContext: parentContext);
            final menuHeight = items.length * NavDropdown.itemHeight;
            final RenderBox button =
                innerContext.findRenderObject() as RenderBox;
            final RenderBox overlay = Overlay.of(innerContext)
                .context
                .findRenderObject() as RenderBox;
            final buttonPos =
                button.localToGlobal(Offset.zero, ancestor: overlay);
            final overlaySize = overlay.size;

            // Center the popup horizontally over the nav item
            final buttonCenterX = buttonPos.dx + button.size.width / 2;
            final menuLeft = (buttonCenterX - NavDropdown.menuWidth / 2)
                .clamp(0.0, overlaySize.width - NavDropdown.menuWidth);

            // BUG-005 fix: clamp the menu top so it never extends above
            // the screen and cap the height so the popup scrolls when
            // there are too many items.
            const double menuPadding = 8.0; // vertical padding inside popup
            final availableHeight =
                (buttonPos.dy - menuPadding).clamp(0.0, double.infinity);
            final effectiveMenuHeight =
                menuHeight < availableHeight ? menuHeight : availableHeight;
            final menuTop =
                (buttonPos.dy - effectiveMenuHeight).clamp(0.0, buttonPos.dy);

            final position = RelativeRect.fromLTRB(
              menuLeft,
              menuTop,
              overlaySize.width - menuLeft - NavDropdown.menuWidth,
              overlaySize.height - buttonPos.dy,
            );

            try {
              await showMenu<void>(
                context: parentContext,
                position: position,
                // BUG-002 fix: use root navigator so the popup route does not
                // share a HeroController with Beamer's nested Navigator.
                useRootNavigator: true,
                items: items,
                constraints: BoxConstraints(
                  minWidth: NavDropdown.menuWidth,
                  maxWidth: NavDropdown.menuWidth,
                  // BUG-005: cap height so the popup scrolls instead of
                  // extending off-screen when there are many items.
                  maxHeight: effectiveMenuHeight + menuPadding * 2,
                ),
              );
            } finally {
              _isMenuOpen = false;
              NavDropdown.isAnyMenuOpen.value = false;
            }
          },
          child: TopLevelNavIndicator(
            widget.menuItem.icon,
            widget.menuItem.label,
            widget.menuItem == activeRoot,
            alarmLevel: navigationAlarmLevelFor(
              widget.menuItem,
              widget.alarmLevels,
              currentPath: widget.currentPath,
            ),
          ),
        );
      },
    );
  }
}

void beamSafelyKids(BuildContext context, MenuItem item,
    {bool askGuard = true}) {
  // The page may object (the editor with unsaved edits). The nav bar asks
  // before it gets here (it also closes the pane and dialogs between the
  // two), so it passes askGuard: false; menu items come straight here.
  // Synchronous when no guard is set -- see LeaveGuard.then.
  if (!askGuard) {
    _beamKids(context, item);
    return;
  }
  LeaveGuard.then(() {
    if (context.mounted) _beamKids(context, item);
  });
}

void _beamKids(BuildContext context, MenuItem item) {
  if (item.path != null) {
    context.beamToNamed(item.path.toString());
  } else {
    stderr.writeln('Item pressed and navigated does not have a page $item');
    showStandardDialog<void>(
      context: context,
      title: 'Page does not exist',
      icon: Icons.error,
      builder: (context) => Text('No page is registered for $item.'),
    );
  }
}
