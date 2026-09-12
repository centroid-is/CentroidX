/// The Session card on the access admin page: what ends a session on this
/// panel, what this panel comes back as, and how to stop it coming back.
///
/// A read-out, not a knob, for the timeout. The inactivity timeout used to be
/// a device-local number edited here, with a switch that stopped every session
/// on the panel from expiring. It is per account now — set on the users list,
/// beside the account it governs — because the account knows who walked away
/// with what power and the panel does not. What is left here is the sentence
/// that says so, so an administrator who remembers the old field finds out
/// where it went instead of hunting for it.
///
/// ## Why the panel account is shown here
///
/// A committed panel is the one piece of session state nobody standing at the
/// panel can see. It is device-local, it is not the signed-in identity (a
/// human signed in *over* a committed panel sees their own name in the app
/// bar), and support asking "what does this panel come back as?" had nowhere
/// to look.
///
/// ## Why releasing the panel lives here too
///
/// It used to be a pure read-out, because the commitment was ended by signing
/// the panel's account out and a second way would have been a second answer.
/// That sign-out is gone: anybody walking past could press it, and a panel
/// whose raised pages are hidden could not be put back without the station
/// account's password. Ending a panel's identity is decommissioning, so it
/// moved to the one screen that is gated on `users`, is exempt from page
/// whitelists (so it cannot be hidden by the setting that caused the problem),
/// and already names the account being released. It is not in the app bar,
/// where it would be one tap from anybody.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access.dart';
import '../widgets/panes/standard_dialog.dart';

/// The card, for tests to find.
const Key kAccessSessionSectionKey = Key('access-session-section');

/// The card's title.
const String kAccessSessionTitle = 'Session';

/// Where the timeout lives now, what an account without one gets, and the
/// one kind of session that never ends on its own.
final String kAccessSessionExplainer =
    'Signed-in sessions end after each account\'s own inactivity timeout, set '
    'on the users list. Accounts without one use '
    '${kDefaultInactivityTimeout.inMinutes} minutes. Station accounts never '
    'time out.';

/// The panel-account read-out, for tests and for support to point at.
const Key kAccessSessionPanelAccountKey = Key('access-session-panel-account');

/// Its sub-heading. "Panel account" rather than "Commitment": it is the
/// vocabulary the sign-in prompt already uses with the operator.
const String kAccessSessionPanelHeading = 'Panel account';

/// What a committed panel returns to, and the only way out — the same two
/// promises the commit prompt makes, in the past tense.
String kAccessSessionPanelCommittedNote(String username) =>
    'This panel stays signed in as $username — across restarts, and whenever '
    'a session opened over it ends or times out. $username has no sign-out of '
    'its own; releasing the panel here is what ends this.';

/// The common case, said plainly rather than by omission: a blank where the
/// account would be reads as "not loaded yet", not as "there is none".
const String kAccessSessionPanelUncommittedNote =
    'This panel is not signed in as an account of its own — it returns to '
    'anonymous when a session ends. Signing in with a station account offers '
    'to change that.';

/// The release control and its confirmation.
const Key kAccessSessionReleasePanelKey = Key('access-session-release-panel');
const String kAccessSessionReleasePanelLabel = 'Release panel';

String kAccessSessionReleaseTitle(String username) =>
    'Stop keeping this panel signed in as $username?';

/// Says the two things a release does that are easy to miss: a live panel
/// session ends on the spot, and the way back is the ordinary sign-in.
String kAccessSessionReleaseMessage(String username) =>
    'The panel will no longer return to $username when a session ends, and '
    'starts anonymous after a restart. If $username is signed in right now, '
    'that session ends. Signing in as $username again offers to keep the '
    'panel signed in.';

/// What a refused or failed release says. One sentence for both: the card is
/// only reachable with `users`, so a refusal here means the session changed
/// under the dialog, and the log has which.
const Key kAccessSessionReleaseFailedKey = Key('access-session-release-failed');
const String kAccessSessionReleaseFailedNote =
    'Could not release this panel — the log has the details.';

/// One card: where the timeout is set, and the panel account.
class AccessSessionSection extends ConsumerWidget {
  const AccessSessionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final panel = ref.watch(panelAccountProvider);

    return Card(
      key: kAccessSessionSectionKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kAccessSessionTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(kAccessSessionExplainer, style: theme.textTheme.bodySmall),
            _PanelAccountNote(panel: panel),
          ],
        ),
      ),
    );
  }
}

/// The panel-account read-out, and the release control under it.
///
/// Renders nothing until the store has answered. The two sentences are
/// opposites, so showing either one early is a claim, and a card that briefly
/// says a committed panel is uncommitted is worse than a card that says
/// nothing for one frame.
///
/// **The divider belongs to the note**, not to the card body. A store that
/// never answers — a fake in a test, a device-local read that throws — would
/// otherwise leave a rule across the card with nothing under it, which reads
/// as a section that failed to load rather than as one that is not there.
class _PanelAccountNote extends ConsumerStatefulWidget {
  const _PanelAccountNote({required this.panel});

  final AsyncValue<String?> panel;

  @override
  ConsumerState<_PanelAccountNote> createState() => _PanelAccountNoteState();
}

class _PanelAccountNoteState extends ConsumerState<_PanelAccountNote> {
  /// True while a release is in flight, so a double tap cannot write two rows.
  bool _busy = false;

  /// True after a release came back false. Cleared on the next attempt.
  bool _failed = false;

  Future<void> _release(String username) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: kAccessSessionReleaseTitle(username),
      message: kAccessSessionReleaseMessage(username),
      confirmLabel: kAccessSessionReleasePanelLabel,
      destructive: true,
      icon: Icons.desktop_windows_outlined,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _failed = false;
    });
    final released =
        await ref.read(accessSessionProvider.notifier).releasePanelAccount();
    if (!mounted) return;
    // On success the controller invalidates `panelAccountProvider`, and the
    // card flips to the uncommitted sentence on its own.
    setState(() {
      _busy = false;
      _failed = !released;
    });
  }

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    if (!panel.hasValue) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final username = panel.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Row(
          key: kAccessSessionPanelAccountKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.desktop_windows_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(kAccessSessionPanelHeading,
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    username == null
                        ? kAccessSessionPanelUncommittedNote
                        : kAccessSessionPanelCommittedNote(username),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (username != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: kAccessSessionReleasePanelKey,
                      onPressed: _busy ? null : () => _release(username),
                      icon: const Icon(Icons.link_off, size: 18),
                      label: const Text(kAccessSessionReleasePanelLabel),
                    ),
                  ],
                  if (_failed) ...[
                    const SizedBox(height: 8),
                    Text(
                      kAccessSessionReleaseFailedNote,
                      key: kAccessSessionReleaseFailedKey,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
