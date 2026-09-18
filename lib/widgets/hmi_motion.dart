import 'package:flutter/animation.dart';

/// How the HMI's own animations answer the platform's "reduce motion"
/// request: they run in real time regardless.
///
/// Flutter runs an [AnimationController] at 5% of its duration when the
/// platform asks for fewer animations. A browser asks whenever the operating
/// system has animation effects off, and Windows turns them off by default in
/// every Remote Desktop session. So a browser on an RDP'd workstation drew the
/// side pane's slide and every pusher's stroke twenty times faster than the
/// same build on the station, which does not pass the setting through.
///
/// The motion here is not decoration. A gate or pusher animates over its
/// configured stroke time so the drawing moves the way the machine does, and
/// the side pane's slide is the cue for where the detail came from. Flutter's
/// own transitions (dialogs, routes, menus) still honour the request.
///
/// Every `AnimationController` under `lib/` passes this;
/// `test/widgets/hmi_motion_test.dart` sweeps for one that does not.
const AnimationBehavior kHmiAnimationBehavior = AnimationBehavior.preserve;
