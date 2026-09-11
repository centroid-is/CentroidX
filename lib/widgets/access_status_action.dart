/// The app-bar access affordance: a sign-in when nobody is signed in, and who
/// is signed in — in orange — when somebody is.
///
/// Called **Sign in**, never "Login". `lib/pages/dbus_login.dart` already owns
/// "Login" for the *station's* D-Bus credential, and the access-control spec
/// requires the two to read differently in the UI, so an operator standing at
/// the panel meets one prompt rather than two that look alike.
///
/// The elevated state is painted with [HmiStateColors.orange] — the repo's
/// forced/override colour, reused here because it is the same idea: the panel
/// is not in its normal state and somebody should be able to see that from
/// across the room. Nothing in this file reaches for a raw Material colour
/// constant; a grep for one should come back empty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';

import '../providers/access.dart';
import '../theme.dart';
import 'access_change_password_dialog.dart';
import 'access_sign_in_dialog.dart';

/// The width budget for the elevated row.
///
/// `base_scaffold.dart` positions the app bar's centre region with a
/// `right:` margin that reserves room for this cluster; a row wider than the
/// budget pushes the clock and the alarm banner off-centre. A long display
/// name ellipsises inside this instead of growing.
const double kAccessStatusActionMaxWidth = 220;

/// The account menu on the elevated badge, and its one entry.
///
/// The menu hangs off the name-and-role cluster, which was previously inert
/// text. It therefore costs **nothing** against
/// [kAccessStatusActionMaxWidth] — worth knowing before a second entry is
/// added here, because that budget is what keeps the clock and the alarm
/// banner centred.
const Key kAccessAccountMenuKey = Key('access-account-menu');
const Key kAccessAccountMenuChangePasswordKey =
    Key('access-account-menu-change-password');

/// The menu's one entry, and the tooltip on the control that opens it.
const String kAccessAccountMenuChangePasswordLabel = 'Change password…';
const String kAccessAccountMenuTooltip = 'Account';

/// Sign in from the app bar; when elevated, who and their role, and sign out.
class AccessStatusAction extends ConsumerWidget {
  const AccessStatusAction({
    super.key,
    this.openSignIn = showAccessSignInDialog,
    this.openChangePassword = showAccessChangePasswordDialog,
  });

  /// How the sign-in prompt is opened. Injectable so a widget test can count
  /// the taps without standing up a dialog route.
  final AccessSignInOpener openSignIn;

  /// How the change-password prompt is opened. Injectable for the same reason
  /// as [openSignIn], and defaulted the same way.
  final AccessChangePasswordOpener openChangePassword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(accessSessionProvider);
    final value = session.valueOrNull;

    // Still resolving, and nothing to show yet: render nothing rather than a
    // spinner. The app bar rebuilds on every navigation and a spinner there
    // would flicker on each one.
    if (value == null && session.isLoading) return const SizedBox.shrink();

    // A null value that is not loading is an error — no database configured,
    // or one that would not answer. The app bar degrades to the sign-in
    // affordance: a broken access layer must not make the bar unusable, and
    // the attempt itself will report the outage inline.
    if (value == null || !value.isElevated) {
      return IconButton(
        icon: const Icon(Icons.lock_open_outlined),
        tooltip: 'Sign in',
        onPressed: () => openSignIn(context, ref),
      );
    }

    return _ElevatedBadge(
      session: value,
      openChangePassword: openChangePassword,
    );
  }
}

class _ElevatedBadge extends ConsumerWidget {
  const _ElevatedBadge({
    required this.session,
    required this.openChangePassword,
  });

  final AccessSession session;
  final AccessChangePasswordOpener openChangePassword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final orange = HmiStateColors.of(context).orange;
    final user = session.user!;

    final identity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.person_outline, size: 20, color: orange),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                session.roleName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: orange),
              ),
            ],
          ),
        ),
      ],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kAccessStatusActionMaxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The name and role become the account menu, rather than a new
          // control being added beside them: the cluster was inert text, so the
          // menu costs nothing against the width budget, and the thing you
          // press to act on your account is your own name.
          //
          // **Not offered to a station account.** A committed panel resumes its
          // account with nobody having presented a credential
          // (`_resumePanelAccount`), so there is no "your own password" to
          // change — the account is shared, and changing it from one panel
          // silently breaks every other panel committed to it. A station
          // account's password is commissioning material and belongs to the
          // users screen, where an administrator changes it and it records
          // itself as an administrator doing so. `changeOwnPassword` refuses
          // these sessions as well; this is the half that stops the affordance
          // being visible in the first place.
          //
          // **Nor when the signed-in identity has no password here to change.**
          // See [_canChangePassword]: this is the half of the capability
          // interface's promise that lives at the offering site, and without it
          // the promise is only half kept — the menu would still render under
          // an OIDC provider and every use of it would dead-end in a sentence
          // about a log.
          if (user.stationAccount || !_canChangePassword(ref))
            Flexible(child: identity)
          else
            Flexible(
              child: PopupMenuButton<_AccountMenuItem>(
                key: kAccessAccountMenuKey,
                tooltip: kAccessAccountMenuTooltip,
                position: PopupMenuPosition.under,
                onSelected: (item) {
                  switch (item) {
                    case _AccountMenuItem.changePassword:
                      openChangePassword(context, ref);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem<_AccountMenuItem>(
                    key: kAccessAccountMenuChangePasswordKey,
                    value: _AccountMenuItem.changePassword,
                    child: Text(kAccessAccountMenuChangePasswordLabel),
                  ),
                ],
                child: identity,
              ),
            ),
          IconButton(
            icon: Icon(Icons.logout, color: orange),
            tooltip: 'Sign out',
            // Always available while elevated: spec §5 requires logging out to
            // be explicit and one tap from the app bar.
            onPressed: () => ref.read(accessSessionProvider.notifier).signOut(),
          ),
        ],
      ),
    );
  }
}

/// Whether the signed-in identity has a password this application can change.
///
/// The offering half of `PasswordSelfService`'s promise. The interface exists
/// so that a second implementation — OIDC, one day — needs no call site edited;
/// that promise is only kept if the site that *offers* the affordance asks the
/// same question the controller does. Without this, an OIDC station would show
/// a menu whose one entry dead-ends in "the log has the details", and the
/// interface would have bought nothing.
///
/// **Fails closed, and quietly.** Anything other than a resolved provider that
/// implements the capability — still loading, errored, no database, a provider
/// without it — means no menu. A missing menu is a non-event; a menu that
/// cannot work is a support call. The app bar rebuilds on every navigation, so
/// this must not flicker a control in and out: the provider is `keepAlive`, so
/// it resolves once per app run and stays resolved.
///
/// Watched rather than read, so the menu appears if the answer changes — which
/// it does exactly once, when the database connects during boot.
bool _canChangePassword(WidgetRef ref) =>
    ref.watch(authProviderProvider).valueOrNull is PasswordSelfService;

/// The account menu's entries.
///
/// An enum with one value rather than a bare callback on the item, so the
/// `switch` in `onSelected` is exhaustive and a second entry added later cannot
/// be forgotten there — the analyzer names the omission.
enum _AccountMenuItem { changePassword }
