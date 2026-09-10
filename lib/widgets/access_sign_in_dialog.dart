/// The modal sign-in form.
///
/// Called **Sign in**, never "Login". `lib/pages/dbus_login.dart` already owns
/// "Login" for the *station's* D-Bus credential, and the access-control spec
/// requires the two to read differently in the UI so an operator standing at
/// the panel meets one prompt and knows which one it is.
///
/// Nothing here is a security boundary and the dialog says so out loud — see
/// [kAccessSignInHonestyNote]. Signing in records what you change; it does not
/// stop anybody who is standing at the panel.
library;

import 'package:beamer/beamer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/access.dart';
import '../routes.dart';
import 'panes/pane_chrome.dart';
import 'panes/standard_dialog.dart';

/// Opens the sign-in dialog. The signature the app-bar affordance injects.
typedef AccessSignInOpener = Future<void> Function(
  BuildContext context,
  WidgetRef ref,
);

/// Keys the tests and any automation address the form by.
const Key kAccessSignInUsernameKey = Key('access-sign-in-username');
const Key kAccessSignInPasswordKey = Key('access-sign-in-password');
const Key kAccessSignInSubmitKey = Key('access-sign-in-submit');
const Key kAccessSignInCancelKey = Key('access-sign-in-cancel');
const Key kAccessSignInFirstUserKey = Key('access-sign-in-first-user');

/// The honesty line's own key, so a test can assert the widget carrying it is
/// not the single-line ellipsising kind. See [kAccessSignInHonestyNote].
const Key kAccessSignInHonestyKey = Key('access-sign-in-honesty');

/// What a rejected credential says.
///
/// One message for a wrong username and for a wrong password, deliberately:
/// two messages would let anybody standing at the panel enumerate which
/// usernames exist by watching which of the two comes back.
const String kAccessSignInBadCredentialsMessage =
    'Username or password not recognised';

/// What an outage says.
///
/// Different from [kAccessSignInBadCredentialsMessage] on purpose. Telling
/// somebody their password is wrong when the database is unreachable sends
/// them off to reset a password that was never the problem.
const String kAccessSignInUnavailableMessage =
    'Cannot reach the user database — sign-in is unavailable right now.';

/// The commit prompt, shown after a station account signs in.
///
/// **After**, not as a checkbox on the form: whether an account is a station
/// account is a database fact, and nothing knows it until the credential has
/// been accepted. A tick-box on the form would either appear for people it
/// does nothing for, or promise something it cannot yet know it can deliver.
///
/// The wording carries **two** promises, because committing makes two changes
/// and only the first is obvious. "Stays signed in across restarts" is what an
/// administrator expects. That a human can sign in over the panel and hand it
/// back on their way out is the surprising half, and leaving it out is how
/// somebody discovers it by watching a panel they thought they had locked
/// return to an account on its own.
String kAccessSignInCommitTitle(String username) =>
    'Keep this panel signed in as $username?';

String kAccessSignInCommitMessage(String username) =>
    'The panel stays signed in across restarts. People can sign in over it '
    'for their own work; when their session ends or times out, the panel '
    'returns to $username. Signing out of $username ends this.';

/// The confirm labels, named so the tests tap the same words the operator
/// reads — the convention `access_users_section.dart` set.
const String kAccessSignInCommitConfirm = 'Keep signed in';
const String kAccessSignInCommitCancel = 'Just this session';

/// The honesty line, in the operator's own terms.
///
/// Spec §8 requires the UI itself to say what signing in does and does not do.
/// The long version is the admin help text; this is the half that ships with
/// the first sign-in surface.
const String kAccessSignInHonestyNote =
    'Signing in records what you change. It is not a security boundary.';

/// Shows the sign-in dialog, and beams to the first-user screen if the
/// operator took that link instead.
///
/// The dialog pops with a route rather than navigating itself, so the widget
/// needs no router in a test and the destination is a value an assertion can
/// read.
Future<void> showAccessSignInDialog(BuildContext context, WidgetRef ref) async {
  final target = await showDialog<String>(
    context: context,
    builder: (_) => const AccessSignInDialog(),
  );
  if (target == null) return;
  if (!context.mounted) return;
  context.beamToNamed(target);
}

/// The form itself. Public so a widget test can push it directly and read the
/// value it pops with.
class AccessSignInDialog extends ConsumerStatefulWidget {
  const AccessSignInDialog({super.key});

  @override
  ConsumerState<AccessSignInDialog> createState() => _AccessSignInDialogState();
}

class _AccessSignInDialogState extends ConsumerState<AccessSignInDialog> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// The inline error, or null when there is nothing to say. Cleared the
  /// moment either field is edited — a stale complaint about credentials the
  /// operator has already changed is noise.
  String? _error;

  /// True while an attempt is in flight. Disables the action, so a double tap
  /// cannot fire two attempts and write two audit rows.
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_error == null) return;
    setState(() => _error = null);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await ref
        .read(accessSessionProvider.notifier)
        .signIn(_username.text, _password.text);

    if (!mounted) return;
    switch (result) {
      case AccessSignInResult.ok:
        await _offerPanelCommit();
        if (!mounted) return;
        Navigator.of(context).maybePop();
      case AccessSignInResult.badCredentials:
        setState(() {
          _busy = false;
          _error = kAccessSignInBadCredentialsMessage;
        });
      case AccessSignInResult.unavailable:
        setState(() {
          _busy = false;
          _error = kAccessSignInUnavailableMessage;
        });
    }
  }

  /// Offer to commit this panel, when the account that just signed in is a
  /// station account and the panel is not already committed to it.
  ///
  /// Silent in every other case, which is the common one. A person signing in
  /// sees exactly the dialog they saw before this feature existed.
  ///
  /// Declining is a real answer, not a deferral: the session stands and behaves
  /// like any other, and the panel is left uncommitted. That is what makes it
  /// safe to sign in as `freezer` on a workstation to check something without
  /// commissioning the workstation.
  Future<void> _offerPanelCommit() async {
    final notifier = ref.read(accessSessionProvider.notifier);
    final user = ref.read(accessSessionProvider).valueOrNull?.user;
    if (user == null || !user.stationAccount) return;

    // Already committed to this account: there is nothing to ask. Asking again
    // on every sign-in would train the operator to dismiss the prompt without
    // reading it, which is how the second promise in the message stops being
    // read at all.
    if (await notifier.panelAccount() == user.username) return;
    if (!mounted) return;

    final confirmed = await showConfirmDialog(
      context: context,
      title: kAccessSignInCommitTitle(user.username),
      message: kAccessSignInCommitMessage(user.username),
      confirmLabel: kAccessSignInCommitConfirm,
      cancelLabel: kAccessSignInCommitCancel,
      icon: Icons.desktop_windows_outlined,
    );
    if (!confirmed) return;

    await notifier.commitPanelAccount();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A closed window and an unreachable database read the same here: no link.
    // `firstUserWindowOpenProvider` already answers false for an outage.
    final windowOpen =
        ref.watch(firstUserWindowOpenProvider).valueOrNull ?? false;

    return StandardDialogFrame(
      title: 'Sign in',
      // The honesty line is NOT the header subtitle. `PaneHeader` renders its
      // subtitle on one line with `TextOverflow.ellipsis` — it is built for
      // short fixed wording like "Conveyor" — and at the dialog's 520px width
      // this sentence came out as "…It is not a security bo…" on screen. A
      // `find.text` assertion still passed, because the `Text` widget carries
      // the whole string whether or not any of it is legible; the golden in
      // `test/widgets/access_golden_test.dart` is what showed it. Spec §8
      // requires the operator to be able to *read* it, so it lives in the
      // body below, where it wraps.
      icon: Icons.lock_open_outlined,
      showClose: false,
      actions: [
        PaneAction(
          buttonKey: kAccessSignInCancelKey,
          label: 'Cancel',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        PaneAction.primary(
          buttonKey: kAccessSignInSubmitKey,
          label: 'Sign in',
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Above the fields, not below the buttons: what signing in does and
          // does not do has to be read before the credential is typed, not
          // after.
          Text(
            kAccessSignInHonestyNote,
            key: kAccessSignInHonestyKey,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            key: kAccessSignInUsernameKey,
            controller: _username,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username'),
            onChanged: (_) => _clearError(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessSignInPasswordKey,
            controller: _password,
            obscureText: true,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Password'),
            onChanged: (_) => _clearError(),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
          // No "forgot password": password reset is out of scope for this
          // phase, and an affordance that goes nowhere is worse than none.
          if (windowOpen) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: kAccessSignInFirstUserKey,
                onPressed: () =>
                    Navigator.of(context).maybePop(AppRoutes.firstUser),
                child: const Text('Create the first account'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
