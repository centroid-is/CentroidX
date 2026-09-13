import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import 'panes/side_pane.dart';
import 'panes/standard_dialog.dart';
import 'leave_guard.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:beamer/beamer.dart';
import 'package:logger/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'nav_dropdown.dart';
import 'access_denied_prompt.dart';
import 'access_status_action.dart';
import '../core/startup_url.dart';
import '../models/menu_item.dart';
import '../providers/preferences.dart';
import '../route_registry.dart';
import '../providers/access.dart';
import '../providers/local_gateway_alarm.dart';
import '../providers/theme.dart';
import '../providers/alarm.dart';
import '../providers/nav_alarm.dart';
import '../providers/menu.dart';
import '../providers/alarm_auto_navigation.dart';
import '../access_routes.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup, AccessSession;
import 'package:tfc_dart/core/alarm.dart';
import 'alarm.dart';
import 'nav_alarm_badge.dart';
import '../routes.dart';
// ===================
// Provider Abstraction
// ===================

abstract class GlobalAppBarLeftWidgetProvider with ChangeNotifier {
  /// Build the custom left-side widget.
  Widget buildAppBarLeftWidgets(BuildContext context);
}

final globalAppBarLeftWidgetProvider =
    Provider<GlobalAppBarLeftWidgetProvider?>((ref) => null);

/// The path Beamer is currently showing, or null when the location state isn't
/// a [BeamState] (e.g. before the first route resolves). This is the same
/// current-path source the bottom-nav selected-index logic reads, so the two
/// stay consistent.
String? currentBeamPath(BuildContext context) {
  final state = context.currentBeamLocation.state;
  if (state is! BeamState) return null;
  return state.uri.path;
}

/// Whether [path] is one of the registered top-level destinations.
///
/// Top-level menu items live directly in [RouteRegistry.menuItems]; Advanced
/// sub-pages (`/advanced/...`) are nested children and are therefore NOT
/// top-level. `/` is always treated as top-level so a deleted Home (a
/// RouteRedirect with no menu item) still suppresses the back-arrow instead of
/// throwing. A null path (no [BeamState] yet) counts as top-level so we default
/// to no arrow.
bool isTopLevelDestinationPath(String? path) {
  if (path == null) return true;
  if (path == '/') return true;
  for (final item in RouteRegistry().menuItems) {
    if (item.path == path) return true;
  }
  return false;
}

// ===================
// BaseScaffold Widget
// ===================

String _twoLetter(int value) => value < 10 ? '0$value' : '$value';

/// `dd.MM.yy` -- the local written convention, and two digits of year keep
/// the top-bar clock narrow beside the alarm banner.
String formatDate(DateTime timestamp) =>
    '${_twoLetter(timestamp.day)}.${_twoLetter(timestamp.month)}.${_twoLetter(timestamp.year % 100)}';

/// `HH:mm:ss`.
String formatTimeOfDay(DateTime timestamp) =>
    '${_twoLetter(timestamp.hour)}:${_twoLetter(timestamp.minute)}:${_twoLetter(timestamp.second)}';

String formatTimestamp(DateTime timestamp) =>
    '${formatDate(timestamp)} ${formatTimeOfDay(timestamp)}';

class BaseScaffold extends ConsumerStatefulWidget {
  final Widget body;
  final String title;
  final Widget? floatingActionButton;

  const BaseScaffold({
    super.key,
    required this.body,
    required this.title,
    this.floatingActionButton,
  });

  @override
  ConsumerState<BaseScaffold> createState() => _BaseScaffoldState();
}

/// Width reserved for the app-bar clock.
///
/// roboto-mono advances 0.6em, so the widest line -- the 14pt `dd-MM-yyyy`, 10
/// chars at 8.4px -- is 84px, and the 20pt time is 8 * 12 = 96px. 100 of text
/// plus an 8px gutter on each side makes 116, which is also the centred alarm
/// banner's left inset: one fixed number rather than two that can drift apart.
/// The gutter matters on a top-level page, where there is no back arrow and the
/// time would otherwise sit flush against the window edge.
const double _clockWidth = 116;

/// Breathing room either side of the app-bar access action, so the back arrow,
/// the sign-in control and the clock are not flush against one another.
const double kAccessStatusActionGap = 8;

class _BaseScaffoldState extends ConsumerState<BaseScaffold> {
  // Static, not per-build: `Logger()` constructs a filter, a printer and an
  // output every time (~4.3us), and this rebuilds on every navigation-alarm
  // tick. The scaffold logs one line, from a tap handler.
  static final Logger _logger = Logger();

  bool _isFullscreen = false;

  /// The top bar's alarm stream, subscribed once. Built inline it was a new
  /// stream on every scaffold rebuild -- every navigation, every pane inset
  /// change -- and the banner blinked back to the clock for a frame each
  /// time while the new StreamBuilder waited for its first value.
  late final Stream<(AlarmSource, List<AlarmActive>)> _alarmStream =
      Stream.fromFuture(ref.read(alarmManProvider.future)).asyncExpand(
          (alarmMan) => alarmMan
              .activeAlarms()
              .map((activeAlarms) => (alarmMan, activeAlarms.toList())));

  @override
  void initState() {
    super.initState();
    // A raise that lands in the gap between one page's scaffold going and the
    // next one's arriving would have nobody listening. The queue survives it --
    // it lives on the keep-alive navigator, not here -- so the newly mounted
    // scaffold drains it instead. After the first frame, because this reads
    // the route the scaffold is being built for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _takeAlarmNavigation();
    });
  }

  /// Beams to the page an alarm just raised on, if there is one and if this is
  /// a moment to move.
  ///
  /// Everything about *which* page is the navigator's call; what is decided
  /// here is the pair of facts only a mounted scaffold holds -- where the
  /// operator is standing, and what their session may open.
  void _takeAlarmNavigation() {
    final navigator = ref.read(alarmAutoNavigationProvider.notifier).navigator;
    if (!navigator.hasPending) return;

    final currentPath = currentBeamPath(context);

    // Never off a raised page. `/advanced/page-editor`, the alarm editor and
    // server config are all pages somebody had to sign in to open, and they
    // are where unsaved work lives; an alarm that yanks an engineer out of a
    // half-drawn mimic costs more than the jump is worth. Read off the route
    // declaration rather than a list of paths, so a page published for
    // `configure` in the page editor is covered the day it is created.
    final suppressed =
        accessGroupForRoute(currentPath) != AccessGroup.operate;

    // The operator's own view of the menu, asked of the provider that builds
    // it rather than of the group gate alone.
    //
    // The intent here is unchanged -- a page they cannot open would swap
    // itself for the refusal notice the moment they landed on it, which is a
    // worse answer than staying put. What changed is that "cannot open" grew a
    // second half: since the page-visibility whitelist, a page can be refused
    // for the audience it was published to as well as for the group it needs,
    // and `accessRouteLocked` deliberately answers only the group half (it is
    // the menu *badge's* question, and making it ask the session about every
    // ordinary row would cost every row a subscription).
    //
    // `visibleMenu` is the composed answer and is what the navigation bar
    // renders, so an alarm can only ever jump to somewhere the operator can
    // actually see. `read`, not `watch`: this runs from a listener and a
    // post-frame callback, never during build.
    final visible = ref.read(visibleMenuProvider);
    final target = navigator.take(
      currentPath: currentPath,
      canOpen: (path) => visible.indexOfPath(path) != null,
      suppressed: suppressed,
    );
    if (target == null) return;

    _logger.i('Alarm ${target.alarmUid} (${target.level.name}) '
        'navigating to ${target.path}');
    Beamer.of(context).beamToNamed(target.path);
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
  }

  int? findTopLevelIndexForBeamer(MenuItem node, int? base, String path) {
    if (node.path != null) {
      if (node.path! == path) {
        return base ?? RouteRegistry().getNodeIndex(node);
      }
    }
    final int? myBase = base ?? RouteRegistry().getNodeIndex(node);
    for (final child in node.children) {
      final int? index = findTopLevelIndexForBeamer(child, myBase, path);
      if (index != null) return index;
    }
    return null;
  }

  /// Attempt to get a global left widget provider.
  GlobalAppBarLeftWidgetProvider? _tryGetGlobalAppBarLeftWidgetProvider(
    BuildContext context,
  ) {
    try {
      final container = ProviderScope.containerOf(context);
      return container.read(globalAppBarLeftWidgetProvider);
    } catch (e) {
      return null;
    }
  }

  /// The date over the time, on the left of the bar.
  ///
  /// Two lines rather than one: a 14pt date over a 20pt time. The time is what
  /// an operator reads from across the packing hall, so it is the half that
  /// grows over the 14pt single line this replaces; the date stays where it was
  /// rather than the pair dominating the 56px toolbar. Explicit sizes rather
  /// than text-theme ones for that reason: the clock is sized against the bar,
  /// not against body copy.
  ///
  /// It also no longer shares a slot with the alarm banner. The clock used to
  /// be the banner's `else` branch, so an active alarm took the time away.
  Widget _buildClock(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return StreamBuilder(
      stream: Stream.periodic(const Duration(seconds: 1)),
      builder: (context, snapshot) {
        // clock.now(), not DateTime.now(): a golden that renders the
        // scaffold otherwise churns every run on the ticking header
        // clock. Tests pin it with withClock(); in the app this is
        // DateTime.now().
        final currentTime = clock.now();
        // scaleDown, and both lines unwrappable: the sizes below are picked
        // for roboto-mono in a 56px toolbar, but a wider fallback font or an
        // operator's text scaling would otherwise wrap `dd.MM.yy` onto two
        // lines and overflow the bar. Shrinking to fit is the graceful
        // failure; a yellow-and-black overflow stripe is not.
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                formatDate(currentTime),
                maxLines: 1,
                softWrap: false,
                style:
                    textTheme.titleMedium?.copyWith(fontSize: 14, height: 1.1),
              ),
              Text(
                formatTimeOfDay(currentTime),
                maxLines: 1,
                softWrap: false,
                style: textTheme.titleLarge?.copyWith(
                    fontSize: 20, height: 1.1, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAlarmBanner(BuildContext context, WidgetRef ref) {
    // The panel's OWN alarm — the gateway link is gone, or the transport
    // could not even be built — merged into the one banner rather than given
    // a second surface beside it: two banners competing for the row is how
    // the real alarm stops being read (the argument that once justified the
    // gateway-link chip, now spent on retiring it). It is read OUTSIDE the
    // StreamBuilder because in gateway mode the plant's alarm stream itself
    // rides the transport, so the very fault this alarm reports can leave
    // `_alarmStream` errored or silent — and the banner must not need a
    // working alarm source to say the alarm source's transport is gone.
    // Null on every direct station and on a healthy link, so this costs the
    // fleet nothing. Why it is local-only and never in TimescaleDB:
    // lib/core/local_gateway_alarm.dart.
    final localAlarm = ref.watch(localGatewayAlarmProvider);
    return StreamBuilder<(AlarmSource, List<AlarmActive>)>(
        stream: _alarmStream,
        builder: (context, snapshot) {
          final hasPlant = !snapshot.hasError && snapshot.hasData;
          final plantAlarms = hasPlant
              ? snapshot.data!.$1.filterAlarms(snapshot.data!.$2, '')
              : const <AlarmActive>[];
          // Local first, not severity-sorted in: while the gateway is down
          // every plant row below may be stale, so the row that says so
          // leads. The plant's own ordering is untouched behind it.
          final filteredAlarms = [
            if (localAlarm != null) localAlarm,
            ...plantAlarms,
          ];
          if (filteredAlarms.isNotEmpty) {
            final highestPriorAlarms =
                filteredAlarms.sublist(0, math.min(2, filteredAlarms.length));

            return GestureDetector(
              onTap: () => context.beamToNamed(AppRoutes.alarmView),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: highestPriorAlarms.map((e) {
                  final (backgroundColor, textColor) =
                      e.notification.getColors(context);
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    decoration: BoxDecoration(
                      color: backgroundColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: RichText(
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      text: TextSpan(
                        // bodyLarge, not a bare TextStyle: RichText does not
                        // read the ambient DefaultTextStyle, so a hand-rolled
                        // style left the banner in the Material default font
                        // while the rest of the HMI is roboto-mono. Taking the
                        // theme style also takes its 16pt -- the old 12pt
                        // bodySmall was too small to read at a glance.
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge!
                            .copyWith(color: textColor),
                        children: [
                          TextSpan(
                            text:
                                '${formatTimestamp(e.notification.timestamp)}: ',
                          ),
                          TextSpan(
                            text: '${e.alarm.config.title}: ',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          TextSpan(
                            text: (() {
                              final description = e.alarm.config.description
                                  .replaceAll('\n', ' ')
                                  .trim();
                              return description.length > 100
                                  ? description.substring(0, 97) + '...'
                                  : description;
                            })(),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            );
          }
          return const SizedBox.shrink();
        });
  }

  /// Beams back to the station's startup page — the sign-out return.
  ///
  /// An anonymous session must not be left staring at a raised page it
  /// cannot reach from its own menu; the kiosk answer is the boot answer,
  /// resolved by the same [resolveStartupPath] validation `main.dart` runs,
  /// so a startup page deleted since it was picked falls back to `/` here
  /// exactly as it does at boot.
  ///
  /// Reading the device-local store is an await; the scaffold can unmount
  /// (this very beam unmounts it) and the session can re-elevate during it,
  /// so both are re-checked after.
  Future<void> _returnToStartupPage() async {
    final stored = await readStartupUrl(ref.read(localPreferencesProvider));
    if (!mounted) return;
    if (ref.read(accessSessionProvider).valueOrNull?.isElevated ?? false) {
      return;
    }
    // The full tree, deliberately, not `visibleMenu`. `resolveStartupPath`
    // answers "is this path routable"; whether *this* person may open it is
    // the route gate's question, and it answers with an honest refusal page.
    // Resolving against the filtered view instead would silently re-target
    // somebody's startup page to a different one.
    final target =
        resolveStartupPath(stored, menuItems: ref.read(menuTreeProvider));
    final beamer = Beamer.of(context);
    if (beamer.configuration.uri.path == target) return;
    beamer.beamToNamed(target);
  }

  @override
  Widget build(BuildContext context) {
    // The sign-out return, and the inactivity expiry's too: both paths end at
    // the same elevated-to-anonymous transition, so one listener covers the
    // app-bar button and the timer alike. Registered in build — riverpod
    // re-registers it per rebuild and removes it on unmount.
    ref.listen<AsyncValue<AccessSession>>(accessSessionProvider,
        (previous, next) {
      final wasElevated = previous?.valueOrNull?.isElevated ?? false;
      final isElevated = next.valueOrNull?.isElevated ?? false;
      if (wasElevated && !isElevated) unawaited(_returnToStartupPage());
    });

    // A raising alarm asking for the screen. The counter is the signal; the
    // target is taken from the navigator inside, because only this widget can
    // answer where the operator is and what they may open. Registered in
    // build for the same reason the listener above is: riverpod re-registers
    // per rebuild and drops it on unmount.
    ref.listen<int>(alarmAutoNavigationProvider, (_, __) {
      _takeAlarmNavigation();
    });

    // Retrieve the provider (if any)
    final globalLeftProvider = _tryGetGlobalAppBarLeftWidgetProvider(context);

    // Which navigation entries are pulsing. Watched once here and handed down,
    // so the bar holds one alarm subscription rather than one per destination.
    //
    // No alarm service — the page-editor harness, tests, a dropped connection —
    // reads as quiet, the same way the beacon asset treats a stream error as
    // idle. A broken alarm connection must not light up the navigation bar.
    final navAlarmLevels =
        ref.watch(navigationAlarmsProvider).valueOrNull ?? const {};
    final navCurrentPath = currentBeamPath(context);

    // The menu this session may see. Watched — so signing in or out rebuilds
    // the bar with the destinations that identity has, which is the whole
    // point of the provider. It is derived from the pages and the session and
    // nothing else; nothing on the plant-connection side is on this path.
    final visibleMenu = ref.watch(visibleMenuProvider);

    // How much of the bar the right-hand cluster needs — see the centre
    // region's margin comment below. Read off the session rather than fixed,
    // so an anonymous panel keeps the centre width it had before the sign-in
    // affordance existed. A loading or errored session reads as anonymous,
    // the same degradation AccessStatusAction itself applies.
    final accessElevated =
        ref.watch(accessSessionProvider).valueOrNull?.isElevated ?? false;
    // The access action sits in the left cluster, between the back arrow and
    // the clock, so it widens the left margin rather than the right. Its width
    // is what moves: ~48px for the sign-in icon button while anonymous, up to
    // kAccessStatusActionMaxWidth once somebody is signed in. The clock rides
    // that change -- it is the cost of grouping identity with the navigation
    // controls, and it is deliberate.
    final appBarLeftMargin = 48.0 +
        (accessElevated ? kAccessStatusActionMaxWidth : 48.0) +
        (kAccessStatusActionGap * 2) +
        _clockWidth;
    // The gateway-link chip that used to sit left of the logo is gone — a
    // lost or unbuildable gateway link now reports through the alarm banner
    // (see _buildAlarmBanner), so the right cluster is back to the logo and
    // the theme toggle and reserves nothing extra.
    const appBarRightMargin = 280.0;

    return Scaffold(
      appBar: _isFullscreen
          ? null
          : AppBar(
              // Disable default leading so we can build our own.
              automaticallyImplyLeading: false,
              backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
              flexibleSpace: SafeArea(
                child: Stack(
                  children: [
                    // CENTER: Constrained so alarm text cannot overlap the
                    // right-aligned logo or left-side controls.
                    // Right margin calculation: SVG logo rendered at height:50
                    // with aspect ratio ~4.2 => ~210px wide, plus 16px right
                    // padding, plus ~48px theme toggle IconButton = ~274px.
                    // Use 280 for a small safety buffer.
                    // Left margin: the back arrow, the access action and the
                    // clock -- see appBarLeftMargin above, which is the one
                    // that changes with the session.
                    Positioned.fill(
                      left: appBarLeftMargin,
                      right: appBarRightMargin,
                      child: Align(
                        alignment: Alignment.center,
                        child: _buildAlarmBanner(context, ref),
                      ),
                    ),
                    // LEFT SIDE: Back arrow (if available) + injected custom widget + fullscreen button.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // The back-arrow is gated on route depth, not on
                          // beaming history: history accumulates and stays
                          // non-empty after landing back on a top-level page,
                          // which used to leave a stale arrow on Home. On a
                          // top-level destination there is nothing to go back
                          // to, so hide it there and only show it deeper in.
                          if (!isTopLevelDestinationPath(
                                  currentBeamPath(context)) &&
                              context.canBeamBack)
                            IconButton(
                              icon: const Icon(Icons.arrow_back),
                              // The page may object (the editor with
                              // unsaved edits); ask before anything moves.
                              // LeaveGuard.then runs the body synchronously
                              // when no guard is set -- see its comment.
                              onPressed: () => LeaveGuard.then(() {
                                if (!context.mounted) return;
                                // Same reason as the navigation bar below:
                                // take the pane away the moment the operator
                                // asks to leave, rather than a few frames
                                // later when the router listener notices.
                                closeSidePane(immediate: true);
                                closeAllFloatingDialogs();
                                context.beamBack();
                              }),
                            ),
                          // Sign in when nobody is; who is signed in, in
                          // orange, when somebody is. Between the back arrow
                          // and the clock, so identity reads with the
                          // navigation controls rather than beside the logo.
                          //
                          // The padding is what separates three controls that
                          // would otherwise sit flush against each other and
                          // the screen edge; the clock carries the same 8px
                          // inside its own SizedBox. kAccessStatusActionGap
                          // is counted into appBarLeftMargin above, so the
                          // centre banner keeps clear of it.
                          const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: kAccessStatusActionGap),
                            child: AccessStatusAction(),
                          ),
                          SizedBox(
                            width: _clockWidth,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: _buildClock(context),
                            ),
                          ),
                          globalLeftProvider?.buildAppBarLeftWidgets(context) ??
                              const SizedBox.shrink(),
                          if (Platform.isAndroid || Platform.isIOS)
                            IconButton(
                              icon: const Icon(Icons.fullscreen),
                              onPressed: _toggleFullscreen,
                              tooltip: 'Toggle Fullscreen',
                            ),
                        ],
                      ),
                    ),
                    // RIGHT SIDE: access status, SVG icon and theme toggle.
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // The gateway-link chip lived here until 2026-09.
                          // A lost (or never-buildable) gateway link is a
                          // fault, and it now reports as one — through the
                          // alarm banner in the centre, via
                          // localGatewayAlarmProvider — instead of as a pill
                          // nobody watched beside the logo.
                          // Only show SVG if not in mobile portrait mode
                          if (!(MediaQuery.of(context).orientation ==
                                  Orientation.portrait &&
                              MediaQuery.of(context).size.width < 600))
                            Padding(
                              padding: const EdgeInsets.only(right: 16.0),
                              child: GestureDetector(
                                onDoubleTap: () {
                                  exit(0);
                                },
                                child: SvgPicture.asset(
                                  'assets/centroid.svg',
                                  height: 50,
                                  package: 'tfc',
                                  colorFilter: ColorFilter.mode(
                                    Theme.of(context).colorScheme.onSurface,
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                          Consumer(
                            builder: (context, ref, child) {
                              final notifier =
                                  ref.read(themeNotifierProvider.notifier);
                              return FutureBuilder(
                                future: ref.watch(themeNotifierProvider.future),
                                builder: (context, snapshot) {
                                  if (snapshot.hasData) {
                                    final currentTheme = snapshot.data!;
                                    return IconButton(
                                      icon: const Icon(Icons.brightness_6),
                                      onPressed: () {
                                        if (currentTheme == ThemeMode.light) {
                                          notifier.setTheme(ThemeMode.dark);
                                        } else {
                                          notifier.setTheme(ThemeMode.light);
                                        }
                                      },
                                    );
                                  }
                                  return const SizedBox();
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
      // Pointer-down feeds the inactivity monitor: touching the panel keeps an
      // elevated session alive. Translucent so the listener observes without
      // consuming — a Listener that swallowed pointers would break every asset
      // on the page. `poke()` is a no-op while anonymous and is guarded
      // against a pointer arriving before the session has resolved, so an
      // unauthenticated panel and a cold start both pay nothing.
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) =>
            ref.read(accessSessionProvider.notifier).poke(),
        // The denial prompt, mounted in the one place every page passes
        // through. It passes the body straight back and contributes NO render
        // object of its own -- not a Stack child, which would re-constrain the
        // body that Scaffold hands `_BodyBoxConstraints`, and not a zero-size
        // sibling either. The pixel budget here is zero: this file is in four
        // Phase 2 goldens and several Phase 1 ones.
        child: AccessDeniedPrompt(child: widget.body),
      ),
      floatingActionButton: _isFullscreen
          ? FloatingActionButton(
              mini: true,
              onPressed: _toggleFullscreen,
              child: const Icon(Icons.fullscreen_exit),
            )
          : widget.floatingActionButton,
      floatingActionButtonLocation:
          _isFullscreen ? FloatingActionButtonLocation.startFloat : null,
      // Built from `visibleMenu`, never from `RouteRegistry().menuItems`.
      //
      // Three things index into one list here — the destinations, the selected
      // index and the tap handler — and they must be the *same* list. A
      // filtered render list beside an unfiltered tap list sends a tap to the
      // wrong page, which is the defect class the popup's "sized from the
      // entries that will actually be shown" comment records one widget down.
      // `VisibleMenu` owns the mapping so there is nowhere for the two to
      // disagree.
      //
      // No bar below two destinations: Material's NavigationBar asserts it,
      // and a session whitelisted down to one page is a real state now. The
      // app bar — with its sign-in control — is still there, so this is not a
      // dead end; fullscreen mode has always rendered a bar-less scaffold.
      bottomNavigationBar: _isFullscreen || !visibleMenu.showsBar
          ? null
          : NavigationBar(
              // Same null-safe path source as the back-arrow gate: an
              // unguarded `as BeamState` here would defeat currentBeamPath's
              // guard — both run in the same build pass, so the scaffold
              // would fail to build anyway if this threw.
              //
              // Null — the current page is not one this session can see, which
              // happens on sign-out — selects nothing rather than the wrong
              // thing. Index 0 would highlight whatever happens to be first.
              selectedIndex:
                  visibleMenu.indexOfPath(currentBeamPath(context) ?? '/') ?? 0,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                ...visibleMenu.topLevel.map<Widget>((item) {
                  if (item.children.isEmpty) {
                    return NavigationDestination(
                        icon: NavAlarmBadge(
                          level: navigationAlarmLevelFor(item, navAlarmLevels,
                              currentPath: navCurrentPath),
                          child: Icon(item.icon),
                        ),
                        label: item.label);
                  }
                  return NavDropdown(
                    menuItem: item,
                    alarmLevels: navAlarmLevels,
                    currentPath: navCurrentPath,
                  );
                }),
              ],
              onDestinationSelected: (int index) => LeaveGuard.then(() {
                _logger.d('Item tapped: $index');
                // The page may object (the editor with unsaved edits); the
                // guard is asked once, here, synchronously when none is set.
                // beamSafelyKids is told not to ask again.
                if (!context.mounted) return;
                // Closed on the tap, not left to the router listener in
                // MyApp. That listener is the guarantee -- it catches the back
                // button, beamBack, deep links and the route guards -- but it
                // fires once the new location has been resolved, so the pane
                // lingers for those frames. Closing here as well takes it away
                // the moment the operator asks to leave. close() is a no-op
                // when nothing is open, so the two never fight.
                closeSidePane(immediate: true);
                closeAllFloatingDialogs();
                // The same filtered list the destinations were built from.
                if (index < 0 || index >= visibleMenu.topLevel.length) return;
                final item = visibleMenu.topLevel[index];
                beamSafelyKids(context, item, askGuard: false);
              }),
            ),
    );
  }
}
