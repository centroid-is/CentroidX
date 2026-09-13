/// Says out loud that the session ended.
///
/// Without this, a session ending is entirely silent. The panel simply stops
/// being signed in, `BaseScaffold._returnToStartupPage` moves the operator to
/// the startup page, and nothing anywhere says why — so the two things an
/// operator most needs to tell apart, "this panel signed itself out" and "this
/// panel has hung", look the same from in front of it. That ambiguity has
/// already cost a day: a genuine OPC UA freeze and a signed-out panel were
/// both reported as "white screen", and nothing on the panel could separate
/// them until a Dart liveness stamp was added to the log.
///
/// **One line, not a dialog.** A modal over a plant view is a modal between an
/// operator and a running line. The app bar's [AccessStatusAction] is already
/// the way back in and it is already on screen; this only makes sure nobody
/// has to notice it changed on their own.
///
/// **No action button, deliberately.** This is mounted in
/// `MaterialApp.builder`, which is *above* the `Navigator` — the same reason
/// the chat FAB in `centroid-hmi/lib/main.dart` carries no tooltip and no
/// hero tag. `showDialog` from here would have no navigator to push onto, so
/// the message names where the control is instead of trying to be it.
///
/// **Elevated-to-anonymous only.** The same transition `BaseScaffold` listens
/// for, so a cold start on an anonymous panel — which is the normal state of
/// most stations most of the time — says nothing at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access.dart';

/// What the operator is told. Names the control and where it is, because the
/// point of the line is that somebody who did not watch the app bar change
/// still knows what happened and what to do.
const String kAccessSessionEndedMessage =
    'Your session has ended — this panel is signed out. '
    'Sign in again from the top bar if you need to make changes.';

/// How long it stays up. Long enough to be read by somebody who looked away
/// while it appeared, short enough not to sit over a mimic.
const Duration kAccessSessionEndedDuration = Duration(seconds: 8);

/// Renders nothing and contributes no render object worth the name; it exists
/// to hold one listener.
///
/// Mounted once, in the app shell. It must not be mounted per page: two of
/// these would post the same line twice for one sign-out.
class AccessSessionEndedNotice extends ConsumerStatefulWidget {
  const AccessSessionEndedNotice({super.key});

  @override
  ConsumerState<AccessSessionEndedNotice> createState() =>
      _AccessSessionEndedNoticeState();
}

class _AccessSessionEndedNoticeState
    extends ConsumerState<AccessSessionEndedNotice> {
  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AccessSession>>(accessSessionProvider,
        (previous, next) {
      final wasElevated = previous?.valueOrNull?.isElevated ?? false;
      final isElevated = next.valueOrNull?.isElevated ?? false;
      if (!wasElevated || isElevated) return;
      // `maybeOf`, not `of`: a harness that mounts this without a messenger
      // should get silence, not a crash. Nothing here is worth taking the app
      // down for.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(kAccessSessionEndedMessage),
          duration: kAccessSessionEndedDuration,
        ),
      );
    });
    return const SizedBox.shrink();
  }
}
