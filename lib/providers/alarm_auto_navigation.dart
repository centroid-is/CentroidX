/// Pulling the operator to the page an alarm just raised on.
///
/// The navigation pulse ([navigationAlarmLevels]) answers "where should I
/// look"; this answers "take me there". Both read the same fact from the same
/// place — the Alarm beacon an operator dropped on a mimic page — so a page
/// that pulses is a page this can navigate to, and one that was deliberately
/// left quiet (`announceInNavigation` off) is never navigated to either.
///
/// Whether it happens at all is the account's: `app_user.alarm_auto_navigate`,
/// off by default and set per account on the Users & roles page. The session
/// on the
/// decides — the signed-in account's value, the reserved anonymous account's
/// when nobody is signed in. See [alarmAutoNavigateLookupProvider].
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:logger/logger.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tfc_access/tfc_access.dart'
    show AccessSession, kAnonymousUsername;
import 'package:tfc_dart/core/alarm.dart';

import '../core/access_authority.dart';
import '../page_creator/assets/alarm_visibility.dart' show AlarmVisibilityConfig;
import '../page_creator/page.dart';
import 'access.dart';
import 'access_admin.dart' show relayedAccountSummary;
import 'alarm.dart';
import 'page_manager.dart';

part 'alarm_auto_navigation.g.dart';

/// The default [AlarmAutoNavigator.settle] window.
///
/// Long enough to cover an OPC UA session coming up and every alarm
/// expression evaluating once, short enough that an operator who watches a
/// machine trip a few seconds after the panel boots still gets taken to it.
const Duration kAlarmAutoNavigateSettle = Duration(seconds: 15);

/// The settle window the app's navigator uses, as a provider so a test can
/// close it.
///
/// A widget test cannot fake its way past [kAlarmAutoNavigateSettle]: the
/// stream events it pumps arrive microseconds after the subscription, and a
/// frozen `Clock` freezes the window open rather than shut. Overriding this
/// with `Duration.zero` is how such a test says "assume the plant has been
/// running for an hour".
final alarmAutoNavigateSettleProvider =
    Provider<Duration>((ref) => kAlarmAutoNavigateSettle);

/// Whether the account [session] answers as wants to be taken to a raising
/// alarm's page: the signed-in account, or the reserved anonymous account when
/// nobody is.
typedef AlarmAutoNavigateLookup = Future<bool> Function(AccessSession session);

/// The [AlarmAutoNavigateLookup] the scaffold asks before it moves. A provider
/// so tests can answer without a database.
///
/// Read at the moment a raise is taken rather than carried on the session, for
/// the reason `homePageLookupProvider` gives: a session is rebuilt on every
/// activity extension, and this is only needed on the rare moment an alarm
/// raises. It also means an administrator's change on another station applies
/// to the very next raise here, with no sign-in in between.
///
/// **An account that cannot be read answers no.** No database, or one that
/// will not answer, is exactly the window in which a panel must not start
/// moving an operator between screens on its own.
final alarmAutoNavigateLookupProvider =
    Provider<AlarmAutoNavigateLookup>((ref) {
  return (session) async {
    // The transport question first, asked of the authority rather than
    // resolved out of a null repository — the rule `guard_wiring_test` states,
    // and the shape `homePageLookupProvider` already has. A gateway panel has
    // no repository by design; it reads the account's row from the gateway's
    // roster (`UserSummary.alarmAutoNavigate`) instead. A session the gateway
    // will not show the roster to — see [relayedAccountSummary] — cannot be
    // read, and answers no.
    try {
      final authority = await ref.read(accessAuthorityProvider.future);
      if (authority == AccessAuthority.relay) {
        final row = await relayedAccountSummary(ref, session);
        return row?.alarmAutoNavigate ?? false;
      }
      final repo = await ref.read(accessRepositoryProvider.future);
      if (repo == null) return false;
      final row = await repo.user(session.user?.username ?? kAnonymousUsername);
      return row?.alarmAutoNavigate ?? false;
    } on Object catch (e) {
      Logger().w('Could not read alarm auto-navigation for $session: $e');
      return false;
    }
  };
});

/// A page an alarm wants on screen, and why.
class AlarmNavigationTarget {
  const AlarmNavigationTarget({
    required this.path,
    required this.level,
    required this.alarmUid,
  });

  /// The route of the page carrying the beacon.
  final String path;

  /// The level of the rule that raised. What preemption compares.
  final AlarmLevel level;

  /// Which alarm asked. Held so the claim can be released when that alarm
  /// leaves the active set — see [AlarmAutoNavigator.hold].
  final String alarmUid;

  @override
  String toString() =>
      'AlarmNavigationTarget($path, ${level.name}, $alarmUid)';
}

/// The identity a raise is detected on: an alarm uid and the level of the rule
/// that fired.
///
/// The level is part of it because one alarm carries several rules and can be
/// active at two levels at once (`AlarmMan` keys its active set on uid *and*
/// rule). An alarm escalating warning → error is a new raise by this key, and
/// should be able to preempt the jump its own warning caused.
String _raiseKey(AlarmActive a) =>
    '${a.alarm.config.uid}|${a.notification.rule.level.index}';

/// Decides when a raising alarm takes the screen. Pure: no Flutter, no
/// Riverpod, no clock — everything it needs arrives as an argument.
///
/// Split in two on purpose. [onActive] sees the alarms and the pages, which
/// only the alarm stream knows; [take] sees where the operator is standing and
/// what they are allowed to open, which only the widget knows. Neither half
/// can decide alone, and holding the state here rather than in a widget is
/// what lets the hold survive the navigation it causes — a `State` that
/// tracked it would be disposed by its own beam.
class AlarmAutoNavigator {
  AlarmAutoNavigator({this.settle = kAlarmAutoNavigateSettle});

  /// How long after [resettle] a raise is treated as "was already on".
  ///
  /// An alarm that is standing when the station boots does not arrive as a
  /// snapshot saying so. The subscriptions come up one at a time and each
  /// true expression fires `active: true`, so the first seconds of a
  /// connection look exactly like a plant raising every one of its alarms at
  /// once — and an operator who walked up to a panel that was already showing
  /// a fault would be thrown to a page they did not ask for. Time is the only
  /// thing that separates the two.
  final Duration settle;

  /// [_raiseKey]s active as of the last snapshot.
  Set<String> _seen = const {};

  /// Whether a first snapshot has been taken.
  ///
  /// The first one seeds [_seen] and queues nothing even when [settle] is
  /// zero. "The alarm raises" is the event this feature is about, not "the
  /// alarm is on".
  bool _primed = false;

  /// When the current settle window opened. Null until the first snapshot.
  DateTime? _settlingSince;

  /// Reopens the settle window, keeping the hold and what has been seen.
  ///
  /// Called whenever the alarm manager underneath is replaced — saving an
  /// alarm invalidates `alarmManProvider`, and the rebuilt manager re-raises
  /// every standing alarm into a fresh stream. Without this, the first edit an
  /// engineer made in the alarm editor would queue a jump per active alarm in
  /// the plant.
  void resettle() {
    _primed = false;
    _settlingSince = null;
  }

  /// Raises seen since the last [take], newest last.
  ///
  /// A raise carries every page that announces it, not one — which of them is
  /// the destination cannot be decided until [take] knows where the operator
  /// is standing.
  final List<_Raise> _queue = [];

  /// The target whose jump currently owns the screen, or null when nothing
  /// does. A later raise must beat this on level to take over.
  AlarmNavigationTarget? get hold => _hold;
  AlarmNavigationTarget? _hold;

  /// Whether anything is waiting to be [take]n. Cheap enough to poll.
  bool get hasPending => _queue.isNotEmpty;

  /// Feeds a new active-alarm snapshot.
  ///
  /// Returns true when this snapshot queued at least one raise, so a caller
  /// driving a stream can emit only on the snapshots that matter.
  ///
  /// Queues whether or not anybody on this panel wants to be moved: that is a
  /// question about the session, which only [take] is asked in time to answer.
  bool onActive(
    Iterable<AlarmActive> active, {
    required Map<String, AssetPage> pages,
  }) {
    final keys = <String>{};
    final uids = <String>{};
    for (final a in active) {
      keys.add(_raiseKey(a));
      uids.add(a.alarm.config.uid);
    }

    // Release first, so an alarm that clears and immediately raises again in
    // the same snapshot is not blocked by its own stale hold.
    final held = _hold;
    if (held != null && !uids.contains(held.alarmUid)) _hold = null;

    final previous = _seen;
    _seen = keys;
    final now = clock.now();
    final since = _settlingSince ??= now;
    if (!_primed) {
      _primed = true;
      return false;
    }
    if (now.difference(since) < settle) return false;

    var queued = false;
    for (final a in active) {
      if (previous.contains(_raiseKey(a))) continue;
      final paths = _announcingPagesFor(a.alarm.config.uid, pages);
      if (paths.isEmpty) continue;
      _queue.add(_Raise(
        paths: paths,
        level: a.notification.rule.level,
        alarmUid: a.alarm.config.uid,
      ));
      queued = true;
    }
    return queued;
  }

  /// The page to beam to now, or null to stay put. Draining: whatever was
  /// queued is decided here and gone, jumped to or not.
  ///
  /// [canOpen] is the operator's own view of the menu — a page they are not
  /// signed in for is not a page to be dropped on, and a locked page would
  /// swap itself for the locked notice the moment they arrived.
  ///
  /// [enabled] is whether the session's account wants to be moved at all. Off
  /// drains the queue and claims **no** hold: the raise is spent, so somebody
  /// who signs in with the setting on a minute later is not thrown to an alarm
  /// that was news before they arrived, and a hold nobody jumped for must not
  /// block the next raise from moving a person who does want it.
  ///
  /// [suppressed] is the caller's veto for where the operator is standing now.
  /// It still claims the hold: an engineer who spends an hour in the page
  /// editor should not be ambushed by a queued jump the moment they leave, and
  /// a claimed hold means the raise has been dealt with.
  AlarmNavigationTarget? take({
    required String? currentPath,
    required bool Function(String path) canOpen,
    required bool suppressed,
    required bool enabled,
  }) {
    if (_queue.isEmpty) return null;
    final queued = List<_Raise>.of(_queue);
    _queue.clear();
    if (!enabled) return null;

    AlarmNavigationTarget? best;
    for (final raise in queued) {
      final path = raise.destinationFrom(currentPath, canOpen);
      if (path == null) continue;
      final target = AlarmNavigationTarget(
        path: path,
        level: raise.level,
        alarmUid: raise.alarmUid,
      );
      // Strictly greater: two raises in one snapshot keep the earlier of the
      // equals, which is the one the plant saw first.
      if (best == null || target.level.index > best.level.index) best = target;
    }
    if (best == null) return null;

    final held = _hold;
    if (held != null && best.level.index <= held.level.index) return null;

    _hold = best;
    if (suppressed) return null;
    // Already looking at it. The beacon on this page is flashing in front of
    // them; beaming to the page they are on would rebuild it for nothing.
    if (currentPath == best.path) return null;
    return best;
  }
}

/// One raise, and every page that could answer it.
///
/// Plural because nothing stops an operator putting a beacon for the same
/// alarm on two pages, and the navigation pulse lights **both** of their
/// entries. Collapsing to one page at queue time is what made an alarm on
/// `/freezer` and `/packing` drag an operator off `/packing` — a page already
/// flashing the alarm in front of them — onto the other one.
class _Raise {
  _Raise({
    required this.paths,
    required this.level,
    required this.alarmUid,
  });

  /// Pages announcing this alarm: those naming the uid first, in stored page
  /// order, then the catch-all pages. See [_announcingPagesFor].
  final List<String> paths;
  final AlarmLevel level;
  final String alarmUid;

  /// Where this raise should send an operator standing at [currentPath].
  ///
  /// The page they are already on, if it is one of ours — the jump is then
  /// refused later by [AlarmAutoNavigator.take], which is the point: what is
  /// being chosen here is which page the raise is *about*, and answering with
  /// a different page that shows the same alarm is the wrong answer.
  ///
  /// Otherwise the first candidate this session can open. A specific beacon on
  /// a page the operator may not open therefore falls through to a catch-all
  /// page they can, rather than refusing to move at all: being taken to an
  /// overview that shows the alarm beats being taken nowhere.
  String? destinationFrom(String? currentPath, bool Function(String) canOpen) {
    if (currentPath != null && paths.contains(currentPath)) return currentPath;
    for (final path in paths) {
      if (canOpen(path)) return path;
    }
    return null;
  }
}

/// Every page whose beacon announces [uid], most specific first.
///
/// A beacon naming the uid outright comes before a catch-all (empty
/// `alarmUids`, which watches everything). An overview page carrying one "any
/// alarm" beacon would otherwise swallow every alarm in the plant and the
/// operator would be sent to the overview instead of to the machine that
/// stopped.
///
/// Order inside each class is [pages] iteration order, which is stored page
/// order — arbitrary, but stable, so the same alarm always lands on the same
/// page rather than wherever a rebuild happened to put it. An operator who
/// wants a different one of two pages to win moves it earlier in the page
/// list, the same lever that orders the menu.
///
/// A page appears once however many beacons on it match.
List<String> _announcingPagesFor(String uid, Map<String, AssetPage> pages) {
  final named = <String>[];
  final catchAll = <String>[];
  for (final entry in pages.entries) {
    var isNamed = false;
    var isCatchAll = false;
    for (final beacon in entry.value.assets.whereType<AlarmVisibilityConfig>()) {
      if (!beacon.announceInNavigation) continue;
      if (beacon.alarmUids.contains(uid)) {
        isNamed = true;
        break;
      }
      if (beacon.alarmUids.isEmpty) isCatchAll = true;
    }
    if (isNamed) {
      named.add(entry.key);
    } else if (isCatchAll) {
      catchAll.add(entry.key);
    }
  }
  return [...named, ...catchAll];
}

/// The live navigator, and a signal to look at it.
///
/// The state is a counter, not the target: the target is taken from the
/// navigator by whoever can answer [AlarmAutoNavigator.take]'s questions, and
/// a counter is the smallest thing that makes `ref.listen` fire for a second
/// raise that happens to name the same page as the first.
///
/// Keep-alive, and deliberately not rebuilt by anything: navigation must
/// outlive the page it navigates away from.
@Riverpod(keepAlive: true)
class AlarmAutoNavigation extends _$AlarmAutoNavigation {
  // `late final`, so the settle window is read from the container this
  // notifier belongs to — on the first build, and once only: the navigator
  // must survive every later rebuild or the hold would be forgotten by the
  // rebuild its own alarm edit caused.
  late final AlarmAutoNavigator _navigator =
      AlarmAutoNavigator(settle: ref.read(alarmAutoNavigateSettleProvider));

  /// The policy object, for the widget that drains it.
  AlarmAutoNavigator get navigator => _navigator;

  @override
  int build() {
    // Pages are read fresh on each alarm event rather than watched, for the
    // reason `navigationAlarms` gives: the page editor mutates
    // `PageManager.pages` in place and there is no invalidation to listen to.
    final pagesFuture = ref.watch(pageManagerProvider.future);
    final alarmFuture = ref.watch(alarmManProvider.future);

    // Every rebuild is a new alarm manager and a new stream of standing
    // alarms — see [AlarmAutoNavigator.resettle].
    _navigator.resettle();

    // Registered synchronously, and the flag checked after every await below.
    // `ref` is illegal once the provider is gone, and both futures can still
    // be in flight then — a container torn down at the end of a test is the
    // routine case.
    var disposed = false;
    StreamSubscription<Set<AlarmActive>>? subscription;
    ref.onDispose(() {
      disposed = true;
      subscription?.cancel();
    });

    () async {
      final PageManager pageManager;
      // `AlarmSource`, not `AlarmMan`: a gateway panel is told its active set
      // over the pipe and has a `RelayAlarmSource`. Naming the concrete class
      // here would have made auto-navigation a direct-mode-only feature by
      // a type annotation.
      final AlarmSource alarmMan;
      try {
        pageManager = await pagesFuture;
        alarmMan = await alarmFuture;
      } catch (_) {
        // No alarm service and no pages read as quiet, the same degradation
        // the beacon and the navigation pulse apply. A dropped connection
        // must not start moving an operator between screens.
        return;
      }
      if (disposed) return;
      subscription = alarmMan.activeAlarms().listen(
        (active) {
          if (disposed) return;
          final queued = _navigator.onActive(active, pages: pageManager.pages);
          if (queued) state = state + 1;
        },
        // Same ruling as the beacon: a stream error is not a raise.
        onError: (Object _) {},
      );
      if (disposed) unawaited(subscription!.cancel());
    }();

    return 0;
  }
}
