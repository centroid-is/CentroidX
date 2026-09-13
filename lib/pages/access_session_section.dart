/// The Session card on the access admin page: what ends a session on this
/// panel, and what this panel comes back as.
///
/// A read-out, not a knob. The inactivity timeout used to be a device-local
/// number edited here, with a switch that stopped every session on the panel
/// from expiring. It is per account now — set on the users list, beside the
/// account it governs — because the account knows who walked away with what
/// power and the panel does not. What is left here is the sentence that says
/// so, so an administrator who remembers the old field finds out where it
/// went instead of hunting for it.
///
/// ## Why the panel account is shown here
///
/// A committed panel is the one piece of session state nobody standing at the
/// panel can see. It is device-local, it is not the signed-in identity (a
/// human signed in *over* a committed panel sees their own name in the app
/// bar), and the only way to end it — signing the panel's own account out —
/// is not discoverable from any control. Support asking "what does this panel
/// come back as?" had nowhere to look. It is a read-out, not a knob: the
/// commitment is made at sign-in and ended by a sign-out, and adding a third
/// way to change it here would be a second answer to a question that already
/// has one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access.dart';

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
    'a session opened over it ends or times out. Signing $username out '
    'ends it.';

/// The common case, said plainly rather than by omission: a blank where the
/// account would be reads as "not loaded yet", not as "there is none".
const String kAccessSessionPanelUncommittedNote =
    'This panel is not signed in as an account of its own — it returns to '
    'anonymous when a session ends. Signing in with a station account offers '
    'to change that.';

/// One card: where the timeout is set, and the panel-account read-out.
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

/// The panel-account read-out.
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
class _PanelAccountNote extends StatelessWidget {
  const _PanelAccountNote({required this.panel});

  final AsyncValue<String?> panel;

  @override
  Widget build(BuildContext context) {
    if (!panel.hasValue) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final username = panel.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        _row(theme, username),
      ],
    );
  }

  Widget _row(ThemeData theme, String? username) {
    return Row(
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
            ],
          ),
        ),
      ],
    );
  }
}
