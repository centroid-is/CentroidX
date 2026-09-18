import 'package:flutter/material.dart';
import 'package:tfc_dart/core/alarm.dart';

import 'alarm.dart' show alarmLevelColors;
import 'alarm_pulse.dart';
import 'hmi_motion.dart';

/// A navigation icon that pulses when an alarm is active on the page behind
/// it.
///
/// The same expanding rings the Alarm beacon asset draws, shrunk to a badge in
/// the icon's top-right corner — so an alarm firing on a page nobody is
/// looking at reads as the same thing whether the operator is on that page or
/// three pages away. Colour comes from the alarm level, through the same
/// [alarmLevelColors] every other alarm surface uses.
///
/// Subtle on purpose. The alarm list and the app-bar banner are where an alarm
/// is read; this only says which way to walk, so it is a 14 px badge and not a
/// tinted icon or a flashing bar. [level] null means quiet, and then this is
/// [child] and nothing else — no animation ticking behind a nav bar that has
/// nothing to report.
class NavAlarmBadge extends StatefulWidget {
  /// The icon to badge.
  final Widget child;

  /// Level to pulse at, or null for quiet.
  final AlarmLevel? level;

  /// Fixed animation phase in [0, 1). Set by golden tests to freeze the rings;
  /// null runs the animation.
  final double? progressOverride;

  const NavAlarmBadge({
    super.key,
    required this.child,
    required this.level,
    this.progressOverride,
  });

  /// Diameter of the badge, and of the ring expansion inside it.
  static const double size = 14.0;

  /// One full ring cycle. Matches the beacon asset — two pulses of the same
  /// alarm beating out of step would read as two different alarms.
  static const Duration period = Duration(milliseconds: 1800);

  @override
  State<NavAlarmBadge> createState() => _NavAlarmBadgeState();
}

class _NavAlarmBadgeState extends State<NavAlarmBadge>
    with SingleTickerProviderStateMixin {
  // Built in initState rather than lazily: a `late final` whose first touch
  // could be `dispose()` would construct a ticker during teardown, where the
  // vsync's TickerMode lookup is illegal. Same reason as the beacon asset.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      animationBehavior: kHmiAnimationBehavior,
      duration: NavAlarmBadge.period,
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(NavAlarmBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.level != oldWidget.level ||
        widget.progressOverride != oldWidget.progressOverride) {
      _syncAnimation();
    }
  }

  /// Runs the ticker only while there is something to say. A repeating
  /// controller per navigation destination would otherwise schedule frames for
  /// the life of the app on an HMI that is idle most of its shift.
  void _syncAnimation() {
    if (widget.level != null && widget.progressOverride == null) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level;
    if (level == null) return widget.child;

    final (color, _) = alarmLevelColors(context, level);
    // Outlined in the bar's own surface, not the alarm's foreground colour:
    // the dot sits on top of an icon, and it has to separate from the icon
    // rather than from an alarm card.
    final outline = Theme.of(context).colorScheme.surfaceContainer;

    return Stack(
      // The badge deliberately overhangs the icon's box — a NavigationDestination
      // sizes its icon tightly, so an inset badge would sit on the glyph.
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned(
          top: -NavAlarmBadge.size / 3,
          right: -NavAlarmBadge.size / 3,
          child: SizedBox(
            width: NavAlarmBadge.size,
            height: NavAlarmBadge.size,
            // The boundary is what keeps this animation affordable. The badge
            // sits in the Scaffold's navigation bar, where the nearest repaint
            // boundary above it is the window root -- so without one HERE,
            // every pulse tick marked the whole window dirty and a station
            // repainted its entire page (65 asset subtrees on the one
            // measured, 2026-09-01, at ~22 fps) to animate a 24 px dot. With
            // it, a tick repaints exactly this SizedBox.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: AlarmPulsePainter(
                    color: color,
                    dotOutlineColor: outline,
                    progress: widget.progressOverride ?? _controller.value,
                    // Two rings, not the beacon's three: at badge size three
                    // rings land on top of each other and read as a smudge.
                    rings: 2,
                    // A fatter dot and a thinner outline than the beacon's. At
                    // this size the beacon's proportions leave a ~1 px dot
                    // inside a 2 px outline — a hollow ring, not an alarm.
                    dotRadiusFactor: 0.42,
                    dotOutlineWidth: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
