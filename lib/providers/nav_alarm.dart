/// Which navigation entries should be pulsing, and at what level.
///
/// An alarm has no page of its own. What ties it to one is the Alarm beacon
/// asset an operator dropped on a mimic page: the beacon names the alarm uids
/// it watches, so "this alarm belongs to that page" is already stated once, in
/// the place the operator stated it. This derives the navigation signal from
/// that, rather than asking for the same fact a second time in the alarm
/// editor.
library;

import 'dart:collection';

import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_dart/core/alarm.dart';

import '../models/menu_item.dart';
import '../page_creator/assets/alarm_visibility.dart'
    show AlarmVisibilityConfig, matchingActiveAlarms;
import '../page_creator/page.dart';
import 'alarm.dart';
import 'page_manager.dart';

part 'nav_alarm.g.dart';

/// Page path -> the highest active alarm level announcing itself there.
///
/// Steady state, not edges: this is what a navigation entry should *be*
/// pulsing at right now. The raise edge — "an alarm just came on, take me
/// there" — is `lib/providers/alarm_auto_navigation.dart`, which reads the
/// same beacons through the same switch so the two can never disagree about
/// which page an alarm belongs to.
///
/// A page is announcing when it holds an Alarm asset with
/// [AlarmVisibilityConfig.announceInNavigation] on — the default — bound to an
/// active alarm. The switch lives on the beacon, not the alarm: an alarm is a
/// plant-wide fact, where it announces is a per-page presentation choice, and
/// the beacon is that choice. A beacon with an empty uid list watches every
/// alarm (see [matchingActiveAlarms]), so such a page announces every active
/// alarm — the same "all alarms" semantics the beacon itself has.
///
/// Alarms waiting on an acknowledgement are included, matching the beacon: the
/// signal ends when the alarm is dealt with, not when the condition clears.
///
/// Pages with no beacon never appear here, so an alarm that was flagged for the
/// navigation bar but never placed on a page stays silent. That is the cost of
/// deriving the link instead of storing it, and it is visible in the editor:
/// there is nothing to see because there is nothing on a page to see it on.
Map<String, AlarmLevel> navigationAlarmLevels({
  required Map<String, AssetPage> pages,
  required Iterable<AlarmActive> active,
}) {
  final announcing = active.toList();
  if (announcing.isEmpty) return const {};

  final levels = <String, AlarmLevel>{};
  for (final entry in pages.entries) {
    AlarmLevel? highest;
    for (final beacon
        in entry.value.assets.whereType<AlarmVisibilityConfig>()) {
      if (!beacon.announceInNavigation) continue;
      for (final alarm in matchingActiveAlarms(announcing, beacon.alarmUids)) {
        final level = alarm.notification.rule.level;
        if (highest == null || level.index > highest.index) highest = level;
      }
    }
    if (highest != null) levels[entry.key] = highest;
  }
  return levels;
}

/// The level a navigation entry should pulse at, or null for quiet.
///
/// Walks [item] and everything under it, so an alarm on a page buried in an
/// Advanced-style section still reaches the one icon the operator can see —
/// the section's.
///
/// [currentPath] is skipped: the page on screen already shows its own alarms,
/// and a nav icon nagging about the screen you are looking at is noise. In a
/// section, only the open child goes quiet; a sibling still lights the section.
AlarmLevel? navigationAlarmLevelFor(
  MenuItem item,
  Map<String, AlarmLevel> levels, {
  String? currentPath,
}) {
  if (levels.isEmpty) return null;

  AlarmLevel? highest;
  // Menu trees are built by resolving paths against a flat page map, which
  // permits a child that points back at an ancestor. This runs on every
  // navigation-bar build, so it does not get to hang on one. Identity, not
  // `==`: MenuItem compares by label/path/icon, and two genuinely distinct
  // entries can match on all three.
  final seen = HashSet<MenuItem>(
      equals: identical, hashCode: identityHashCode, isValidKey: (_) => true);

  void visit(MenuItem node) {
    if (!seen.add(node)) return;
    final path = node.path;
    if (path != null && path != currentPath) {
      final level = levels[path];
      if (level != null && (highest == null || level.index > highest!.index)) {
        highest = level;
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(item);
  return highest;
}

/// Live [navigationAlarmLevels] for the navigation bar.
///
/// Recomputed on every change to the active alarm set. Page contents are read
/// fresh each time rather than watched: the page editor mutates
/// `PageManager.pages` in place, so there is no invalidation to listen to, and
/// a beacon added while alarms are quiet is picked up by the next alarm event —
/// which is the only moment its answer could differ.
@Riverpod(keepAlive: true)
Stream<Map<String, AlarmLevel>> navigationAlarms(Ref ref) async* {
  final pageManager = await ref.watch(pageManagerProvider.future);
  final alarmMan = await ref.watch(alarmManProvider.future);
  yield* alarmMan.activeAlarms().map(
        (active) => navigationAlarmLevels(
          pages: pageManager.pages,
          active: active,
        ),
      );
}
