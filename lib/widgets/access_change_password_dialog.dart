/// The modal form where somebody changes **their own** password.
///
/// The other half of `access_users_section.dart`'s set-password dialog, and
/// deliberately a different screen rather than a shared one with a flag. That
/// one is an administrator reaching into somebody else's account: it is reached
/// through the `users` gate, it takes a username, and it verifies nothing
/// because an administrator has no current password to present. This one is
/// reached from the app bar by anybody signed in, takes no username at all —
/// the account is whoever is signed in — and its whole point is the
/// current-password field. A single dialog switching on a flag would put the
/// gated and the ungated path one boolean apart, which is the wrong distance
/// between them.
///
/// ## The rule this file inherits
///
/// `access_users_section.dart`'s file-level doc states it for every screen
/// where a password is in hand, and it applies here unchanged: **no exception
/// object is ever rendered**. An `ArgumentError` from the repository can carry
/// the credential in its message, and from a `SnackBar` it would go into a
/// screenshot in a support thread. Every failure shows one of the fixed
/// sentences below and the detail goes to the log. Nothing in this file
/// interpolates a caught error into a string.
///
/// The password also never leaves this widget except downwards — into
/// [AccessSessionController.changeOwnPassword] and no further. It is not
/// logged, not put in a `reason`, and not carried in any audit row: the two
/// `AuditRecord` constructors behind this screen have no parameter that could
/// take one.
///
/// ## No policy
///
/// Blank, and the two fields disagreeing. That is the whole of it. The repo's
/// stance is stated where accounts are created — *"There is no password policy
/// and no expiry"* — and a length floor invented here would apply to one of the
/// three places a password is typed and not the other two, which is not a
/// policy but an inconsistency. A new password identical to the old one is
/// allowed for the same reason: refusing it is a rule nobody wrote down, and
/// the row genuinely changes anyway — fresh salt, current parameters.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/access.dart';
import 'panes/pane_chrome.dart';
import 'panes/standard_dialog.dart';

/// Opens the change-password dialog. The signature the app-bar menu injects,
/// mirroring `AccessSignInOpener` so a widget test can count the taps without
/// standing up a dialog route.
typedef AccessChangePasswordOpener = Future<void> Function(
  BuildContext context,
  WidgetRef ref,
);

/// Keys the tests and any automation address the form by.
const Key kAccessChangePasswordCurrentKey =
    Key('access-change-password-current');
const Key kAccessChangePasswordNewKey = Key('access-change-password-new');
const Key kAccessChangePasswordConfirmKey =
    Key('access-change-password-confirm');
const Key kAccessChangePasswordSubmitKey = Key('access-change-password-submit');
const Key kAccessChangePasswordCancelKey = Key('access-change-password-cancel');

/// The inline note's key. Separate from the text so a test meaning "the form
/// complained" cannot pass on an empty frame.
const Key kAccessChangePasswordNoteKey = Key('access-change-password-note');

/// The dialog's title and its affirmative.
const String kAccessChangePasswordTitle = 'Change your password';
const String kAccessChangePasswordConfirmLabel = 'Change password';

/// One line above the fields, saying what will happen and what will not.
///
/// The second half is the surprising one and is why the sentence exists. A
/// person changing a password on a web application expects to be signed out
/// and to have to sign in again; here nothing of the sort happens, and somebody
/// who expects it will spend the next minute wondering whether the change took.
const String kAccessChangePasswordExplainer =
    'The new password works immediately and the old one stops working. You '
    'stay signed in here.';

/// The current-password field was blank. First of the three checks, in the
/// order the fields are read.
const String kAccessChangePasswordBlankCurrentNote =
    'Enter your current password.';

/// The new-password field was blank. Second.
const String kAccessChangePasswordBlankNewNote = 'Enter a new password.';

/// The two new-password fields disagree. Third. The same sentence
/// `access_users_section.dart` uses, because it is the same mistake.
const String kAccessChangePasswordMismatchNote =
    'The passwords do not match.';

/// The current password did not verify.
///
/// Nothing is hidden by this wording and nothing needs to be: the account is
/// the one already signed in, so there is no username to enumerate and no
/// second thing the message could be confused with. It says plainly which of
/// the three fields was wrong, because that is the only useful thing to say.
const String kAccessChangePasswordWrongCurrentNote =
    'That is not your current password.';

/// The session ended while the form was open.
///
/// Its own sentence rather than the generic failure, because it is the one
/// failure with an obvious next step, and telling somebody to go read a log
/// when their session merely timed out would send them a long way for nothing.
const String kAccessChangePasswordNotSignedInNote =
    'Your session ended. Sign in again to change your password.';

/// Everything else: no database, the provider threw, the account was deleted
/// mid-session, or a station account reached a screen it is not offered.
///
/// One sentence for four causes, and it points at the log rather than guessing
/// between them — the same shape, and very nearly the same words,
/// `access_users_section.dart` uses for a write that failed. It must stay a
/// fixed string: the caught error is exactly the thing that must not be
/// rendered.
const String kAccessChangePasswordFailedNote =
    'The password could not be changed. The log has the details.';

/// What the operator sees after it worked.
///
/// A `SnackBar` rather than a second dialog: the change is done, there is
/// nothing to decide, and a prompt that only has an OK button is a prompt that
/// teaches people to dismiss prompts.
const String kAccessChangePasswordDoneMessage = 'Password changed.';

/// Shows the dialog. Nothing is returned — the outcome is either the snackbar
/// or an inline note the dialog stayed open to show.
Future<void> showAccessChangePasswordDialog(
  BuildContext context,
  WidgetRef ref,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => const AccessChangePasswordDialog(),
    );

/// The form itself. Public so a widget test can push it directly.
class AccessChangePasswordDialog extends ConsumerStatefulWidget {
  const AccessChangePasswordDialog({super.key});

  @override
  ConsumerState<AccessChangePasswordDialog> createState() =>
      _AccessChangePasswordDialogState();
}

class _AccessChangePasswordDialogState
    extends ConsumerState<AccessChangePasswordDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();

  /// The inline note, or null when there is nothing to say. Cleared the moment
  /// any field is edited — a stale complaint about a value the operator has
  /// already corrected is noise.
  String? _note;

  /// True while an attempt is in flight. Disables the action, so a double tap
  /// cannot fire two changes and write two audit rows.
  ///
  /// It is held for the duration of an Argon2id verify *and* an Argon2id hash —
  /// two derivations, so about twice a sign-in's ~150 ms. That is long enough
  /// on a panel for a second tap to be a real possibility rather than a
  /// theoretical one.
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _clearNote() {
    if (_note == null) return;
    setState(() => _note = null);
  }

  /// The three local checks, in field order.
  ///
  /// Returns the note to show, or null when there is nothing to complain about
  /// locally. Deliberately separate from [_submit] so the order of the checks
  /// is one readable list rather than three early returns interleaved with
  /// state changes.
  String? _localProblem() {
    if (_current.text.isEmpty) return kAccessChangePasswordBlankCurrentNote;
    if (_next.text.isEmpty) return kAccessChangePasswordBlankNewNote;
    if (_next.text != _confirm.text) return kAccessChangePasswordMismatchNote;
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;

    final local = _localProblem();
    if (local != null) {
      setState(() => _note = local);
      return;
    }

    setState(() {
      _busy = true;
      _note = null;
    });

    final result =
        await ref.read(accessSessionProvider.notifier).changeOwnPassword(
              currentPassword: _current.text,
              newPassword: _next.text,
            );

    if (!mounted) return;

    switch (result) {
      case AccessPasswordChangeResult.ok:
        // Pop first, then the snackbar: a `ScaffoldMessenger` lookup has to
        // happen before this context is torn down, and the message belongs to
        // the page underneath rather than to a dialog that is going away.
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).maybePop();
        messenger.showSnackBar(
          const SnackBar(content: Text(kAccessChangePasswordDoneMessage)),
        );

      case AccessPasswordChangeResult.wrongCurrentPassword:
        // The dialog stays open and the two new-password fields keep what was
        // typed into them. Only the current-password field is cleared and
        // refocused: it is the one that was wrong, and it is the one worth
        // retyping. Throwing away a new password somebody has already typed
        // twice, to punish a typo in a different field, is how a form makes
        // somebody give up.
        _current.clear();
        setState(() {
          _busy = false;
          _note = kAccessChangePasswordWrongCurrentNote;
        });

      case AccessPasswordChangeResult.notSignedIn:
        setState(() {
          _busy = false;
          _note = kAccessChangePasswordNotSignedInNote;
        });

      case AccessPasswordChangeResult.unavailable:
        setState(() {
          _busy = false;
          _note = kAccessChangePasswordFailedNote;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StandardDialogFrame(
      title: kAccessChangePasswordTitle,
      icon: Icons.password_outlined,
      showClose: false,
      actions: [
        PaneAction(
          buttonKey: kAccessChangePasswordCancelKey,
          label: 'Cancel',
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        ),
        PaneAction.primary(
          buttonKey: kAccessChangePasswordSubmitKey,
          label: kAccessChangePasswordConfirmLabel,
          onPressed: _busy ? null : _submit,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Above the fields: what the change does, and that it does not sign
          // you out, has to be read before the password is typed rather than
          // discovered afterwards.
          Text(
            kAccessChangePasswordExplainer,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            key: kAccessChangePasswordCurrentKey,
            controller: _current,
            obscureText: true,
            autofocus: true,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Current password'),
            onChanged: (_) => _clearNote(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessChangePasswordNewKey,
            controller: _next,
            obscureText: true,
            enabled: !_busy,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'New password'),
            onChanged: (_) => _clearNote(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessChangePasswordConfirmKey,
            controller: _confirm,
            obscureText: true,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
            ),
            onChanged: (_) => _clearNote(),
            onSubmitted: (_) => _submit(),
          ),
          if (_note != null) ...[
            const SizedBox(height: 12),
            Row(
              key: kAccessChangePasswordNoteKey,
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
                    _note!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
