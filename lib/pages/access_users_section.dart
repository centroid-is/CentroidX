/// The administration page's users section — 06-CONTEXT "Users Screen".
///
/// A roster of accounts with the four columns `AppUser` actually has, four
/// capabilities and no fifth, and the two lockout routes that run through this
/// table refused where the operator can read why. Composed onto a page beside
/// the roles section; this file renders a card and owns no route.
///
/// ## Four columns, and every one of them a real column
///
/// Username, role, created, last login. Those are the four `AppUser` carries
/// (`database_drift.dart`), and the list shows exactly them. A display name is
/// a schema v7 → v8 migration for cosmetics and 06-CONTEXT declines it; so is a
/// `disabled` flag, which is why there is no disable here either — it would be
/// a migration *plus* a change to the login path. What the screen can do is
/// create an account, change its role, reset its password and delete it.
///
/// ## The one rule this file has that the roles section does not
///
/// `access_templates_section.dart`'s `_showProblem` renders the exception in a
/// snackbar, and that is right almost everywhere. It is not right in the two
/// dialogs here that take a typed password. `lib/pages/first_user.dart` refuses
/// to do it on exactly that screen and says why: an `ArgumentError` raised on a
/// bad credential can carry the credential in its message, and a screen where
/// the password is in hand would then put it into a screenshot of a
/// commissioning session. 06-02 made `AccessRepository` throw a bare
/// `ArgumentError` without the value for that reason, and defence in depth here
/// costs one `catch` clause.
///
/// So, explicitly:
///
///  * **The create dialog and the set-password dialog** follow
///    `first_user.dart`: the failure goes to `Logger().e` with a fixed message
///    and the screen shows a fixed sentence of its own. Neither ever renders an
///    exception object.
///  * **Everywhere else in this file** — the role change and the delete, which
///    never hold a credential — uses `_showProblem`, the shared shape the rest
///    of the milestone uses.
///
/// Nothing in this file reads, passes, logs or renders a stored hash or its
/// salt. The password travels from a controller straight to the store and stops
/// there.
///
/// ## Usernames are compared exactly
///
/// `app_user.username` is a case-sensitive TEXT primary key and
/// `AccessRepository.user` documents why: case-folding means picking a locale,
/// and Turkish dotted I turns a login screen into a support call. Nothing in
/// this file folds a username — the duplicate check in the create dialog
/// compares exactly, so a dialog cannot refuse a name the database would have
/// accepted.
///
/// ## A user write is not finished when the row is written
///
/// `ref.invalidate(accessAdminUsersProvider)` refreshes the *roster*. What the
/// running app permits is re-resolved by
/// `AccessSessionController.refreshGroupsFromRoles`, and this section calls it
/// after **every** `setUserRole` and **every** `deleteUser` — never inside an
/// "is this the signed-in account?" conditional. With two `users` holders the
/// invariant permits an admin to move their own account onto a role without
/// `users`, or to delete it outright, and without the call they keep the groups
/// that account gave them until they sign out. That is privilege retention in
/// the phase whose job is administering privileges (T-06-77).
///
/// `createUser` and `setUserPassword` do **not** get the call: a new account
/// holds no session and a password change alters no privilege, so neither can
/// change the caller's own groups.
///
/// **That call goes last, and the ordering is load-bearing.** See [_afterWrite].
///
/// ## The refusal, and the trail
///
/// Trip routes (a) and (b) — deleting the last `users` holder, and moving them
/// onto a role that does not grant it — are refused by `AccessRepository`
/// inside the transaction that would otherwise perform the write. That rule is
/// **not** re-implemented here; this section renders what the transaction threw,
/// through the shared `AccessAdminRefusal`, so its wording and the roles
/// section's cannot drift. There is no override, and none may be added.
///
/// Deleting an account does not touch its audit rows. `audit_entry.who` is a
/// denormalised TEXT column with no foreign key, so the trail outlives the
/// account by construction — and because the obvious assumption is the
/// opposite, the delete confirmation says so out loud.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppUserData;

import '../core/access_admin_store.dart';
import '../providers/access.dart';
import '../providers/access_admin.dart';
import '../widgets/access_admin_notice.dart';
import '../widgets/access_pages_editor.dart';
import '../widgets/panes/pane_chrome.dart';
import '../widgets/panes/standard_dialog.dart';

// ---------------------------------------------------------------------------
// Copy
//
// Kept at the top of the file, in the `access_gate.dart` /
// `access_templates_section.dart` idiom, so the tests assert against the string
// the widget renders rather than one they supply.
// ---------------------------------------------------------------------------

/// The section's title.
const String kAccessUsersHeadline = 'Accounts';

/// One line under the title. Says what an account is and what holding one
/// means, before a list of names arrives.
const String kAccessUsersSubtitle =
    'An account is a username, a password and exactly one role. What it may do '
    'is whatever that role grants, and changing the role changes it at once.';

/// The read failed, or the store could not be built.
///
/// Says the roster is untrustworthy rather than that there are no accounts:
/// people are still signed in against rows this station currently cannot read,
/// and an empty list here would be a claim about the table it cannot make.
const String kAccessUsersUnavailableNote =
    'The accounts could not be read. Anybody already signed in stays signed in, '
    'but this list may be out of date.';

/// No database — which is **not** "no accounts".
///
/// Names no cause, for the reason `kAccessTemplatesNoDatabaseNote` gives: a
/// station that was never configured and one whose Postgres will not answer are
/// the same resolved null from here, and the next step is the same either way.
const String kAccessUsersNoDatabaseNote =
    'Accounts live in the database, and this station has no reachable one — so '
    'this is "cannot tell you", not "there are none". The connection is set up '
    'in Server Config.';

/// A database that answered, with nothing in `app_user`.
///
/// Deliberately not "no users yet". An empty account table is the state in
/// which the first-user window stands open, and a freshly deployed station is
/// then claimable by whoever reaches it first — which is a far more urgent fact
/// than the absence of a list. `first_user.dart` says the same thing on the
/// screen that acts on it.
const String kAccessUsersEmptyNote =
    'No accounts at all, which means the first-user window is still open: this '
    'station is claimable by whoever reaches the first-account screen first. '
    'Create the first account now, at commissioning.';

/// The four column headings, as constants so a test asserts the heading the
/// screen renders.
const String kAccessUsersColumnUsername = 'Username';
const String kAccessUsersColumnRole = 'Role';
const String kAccessUsersColumnCreated = 'Created';
const String kAccessUsersColumnLastLogin = 'Last login';

/// What stands in for a null `lastLoginAt`.
///
/// A word rather than an empty cell. An account that has never been used is a
/// fact worth seeing — a stale commissioning account nobody signs into is
/// exactly what a roster is read to find — and a blank cell reads as a
/// rendering bug.
const String kAccessUserNever = 'never';

/// A timestamp as this repo already renders one.
///
/// `yyyy-MM-dd HH:mm` through `intl`, the pattern `plc_detail_panel.dart` and
/// `tech_doc_library_section.dart` already use; no new dependency and no fourth
/// spelling of a date. Local time, because the person reading it is standing in
/// front of the panel.
String kAccessUserWhen(DateTime? at) => at == null
    ? kAccessUserNever
    : DateFormat('yyyy-MM-dd HH:mm').format(at.toLocal());

/// The change-role dialog's title.
String kAccessUserRoleDialogTitle(String username) =>
    'Move "$username" to another role';

/// The change-role dialog's affirmative. Says what happens rather than "OK".
const String kAccessUserRoleConfirmLabel = 'Move';

/// One line in the change-role dialog. States the consequence, which is
/// immediate and is the whole reason this screen is gated.
const String kAccessUserRoleDialogNote =
    'The account holds exactly one role. Moving it changes what that person may '
    'do the moment it is saved, without them signing out and back in.';

/// The picker had nothing to offer. Should not be reachable — the migration
/// seeds four roles — so it says that rather than pretending it is normal.
const String kAccessUserRoleDialogEmptyNote =
    'No roles could be read, so there is nothing to move this account onto. '
    'The roles section above says why.';

/// What a role grants, by [AccessGroupInfo.label] and in [AccessGroup.values]
/// order, so two roles granting the same set read identically.
String kAccessUserRoleGrants(Set<AccessGroup> groups) => groups.isEmpty
    ? 'Grants nothing'
    : AccessGroup.values.where(groups.contains).map((g) => g.label).join(' · ');

/// The delete confirmation's title.
String kAccessUserDeleteTitle(String username) => 'Delete "$username"?';

/// The delete confirmation's body.
///
/// It states that the audit history is **not** deleted with the account,
/// because the obvious assumption is the opposite and the property is worth
/// telling the operator: `audit_entry.who` is denormalised TEXT with no foreign
/// key, so the trail survives by construction and no cascade may ever be added.
String kAccessUserDeleteMessage(String username) =>
    'The account "$username" is removed and signing in as "$username" stops '
    'working immediately. Everything it did stays in the audit trail — deleting '
    'an account does not delete its history.';

/// The delete confirmation's affirmative.
const String kAccessUserDeleteConfirmLabel = 'Delete account';

/// The roster was stale: somebody else removed the account between this list
/// being read and the write being attempted.
///
/// A fixed sentence rather than the exception, and it names the account so the
/// operator knows which row went away under them.
String kAccessUserVanishedNote(String username) =>
    'There is no account named "$username" any more — somebody else removed it. '
    'The list has been refreshed.';

// ---- The two dialogs where a password is in hand --------------------------
//
// The validation sentences are `first_user.dart`'s, in `first_user.dart`'s
// order and register: one sentence per branch, each of them something the
// operator can act on. A single "invalid input" covering three different
// mistakes is a support call.

/// The create dialog's title and affirmative.
const String kAccessUserCreateTitle = 'New account';
const String kAccessUserCreateConfirmLabel = 'Create account';

/// One line above the create form. Says what holding a role means before the
/// picker asks the operator to choose one.
const String kAccessUserCreateNote =
    'The account can be used the moment it is created, and it may do whatever '
    'the role picked below grants. There is no password policy and no expiry.';

/// The set-password dialog's title and affirmative.
String kAccessUserSetPasswordTitle(String username) =>
    'Set a new password for "$username"';
const String kAccessUserSetPasswordConfirmLabel = 'Set password';

/// One line above the set-password form.
///
/// Says the three things the administrator would otherwise have to guess: the
/// old password stops working at once, the account is not signed out, and
/// nothing forces the person to change it again afterwards.
///
/// That last clause is a statement about **policy**, not about plumbing, and it
/// stayed true when self-service arrived. The person can now change this
/// password themselves from the app bar's account menu
/// (`access_change_password_dialog.dart`), so the administrator has somewhere
/// to point them — but there is deliberately no must-change-at-next-login flag
/// to set, for the same reason there is no length floor and no expiry: this
/// screen has no password policy, and a forced change is one.
///
/// **Two sentences, because the promise is not true of every row.** A station
/// account is not offered the account menu and `changeOwnPassword` refuses it,
/// so telling an administrator resetting `freezer` that "the person can change
/// it themselves" would send them to a control that does not exist for that
/// account — and the administrator resetting a panel account is precisely the
/// person who must not be told that. [kAccessUserSetPasswordNoteFor] picks.
const String kAccessUserSetPasswordNote =
    'The new password works immediately and the old one stops working. The '
    'account is not signed out and is not asked to change it again — but the '
    'person can change it themselves from the app bar once signed in.';

/// The same note for a station account, with the self-service half replaced by
/// what is true instead.
///
/// It names this screen as the way it changes, because it is the only one: a
/// panel account's password is commissioning material, shared across every
/// panel committed to it, and there is nobody whose "own" password it is.
const String kAccessUserSetPasswordStationNote =
    'The new password works immediately and the old one stops working. The '
    'account is not signed out. This is a station account, so it is not '
    'offered the app bar\'s change-password menu — this screen is where its '
    'password changes.';

/// Which of the two notes a row gets.
String kAccessUserSetPasswordNoteFor({required bool stationAccount}) =>
    stationAccount
        ? kAccessUserSetPasswordStationNote
        : kAccessUserSetPasswordNote;

/// The username field was blank. First of the three checks.
const String kAccessUserBlankUsernameNote = 'Enter a username.';

/// The password field was blank. Second of the three checks.
const String kAccessUserBlankPasswordNote = 'Enter a password.';

/// The two password fields disagree. Third of the three checks.
const String kAccessUserMismatchNote = 'The passwords do not match.';

/// The name is taken.
///
/// Refused inside the dialog, before the store is asked, for the reason
/// `_TemplateNameDialog`'s `taken` field gives: an exception surfaced as a
/// snackbar after the dialog closed would make the operator retype everything.
/// The same sentence covers the race, when another station took the name
/// between the loaded roster and the transaction.
String kAccessUserDuplicateNote(String username) =>
    'An account named "$username" already exists.';

/// The create failed for a reason this dialog will not repeat.
///
/// **The exception is not in it.** See the library doc: this is the screen
/// where a password is in hand, and an `ArgumentError` raised on a bad
/// credential can carry the credential in its message.
const String kAccessUserCreateFailedNote =
    'The account could not be created. The log has the details.';

/// The password change failed. Same rule, same reason.
const String kAccessUserSetPasswordFailedNote =
    'The password could not be changed. The log has the details.';

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// The section itself, so a test can tell "rendered nothing" from "rendered an
/// empty roster".
const Key kAccessUsersSectionKey = Key('access-users-section');

/// The could-not-read line.
const Key kAccessUsersUnavailableKey = Key('access-users-unavailable');

/// The no-database line.
const Key kAccessUsersNoDatabaseKey = Key('access-users-no-database');

/// The nothing-at-all line, which is a different claim from the one above.
const Key kAccessUsersEmptyKey = Key('access-users-empty');

/// The column headings row.
const Key kAccessUsersHeaderKey = Key('access-users-header');

/// One account's row.
Key kAccessUserRowKey(String username) => Key('access-user-row-$username');

/// The station-account toggle on a user row.
/// The Pages control on an account's row.
Key kAccessUserPagesKey(String username) => Key('access-user-pages-$username');

/// Save and Cancel inside an account's open Pages block.
Key kAccessUserPagesSaveKey(String username) =>
    Key('access-user-pages-save-$username');
Key kAccessUserPagesCancelKey(String username) =>
    Key('access-user-pages-cancel-$username');

/// The marker beside the role of an account that overrides its role's pages.
Key kAccessUserPagesOverrideKey(String username) =>
    Key('access-user-pages-override-$username');

/// Said beside the role, because that is where somebody moving the account to
/// another role is looking — a personal page list survives the move, and this
/// is what keeps that from being a surprise.
const String kAccessUserPagesOverrideTag = 'own pages';

const String kAccessUserPagesTooltip = 'Which pages this account sees';

Key kAccessUserStationAccountKey(String username) =>
    Key('access-user-station-$username');

/// The two tooltips are the two states, and the ON one carries the way back.
const String kAccessUserStationAccountOffTooltip =
    'Make station account — sessions never expire';
const String kAccessUserStationAccountOnTooltip =
    'Station account — sessions never expire. Tap to make it a person again.';

/// The confirm labels, named so the tests tap the same words the operator
/// reads.
const String kAccessUserStationAccountConfirmMake = 'Make station account';
const String kAccessUserStationAccountConfirmRevert = 'Make it a person';

String kAccessUserStationAccountTitle(String username, bool making) => making
    ? 'Make "$username" a station account?'
    : 'Make "$username" a person again?';

String kAccessUserStationAccountMessage(bool making) => making
    ? 'Its sessions will never expire on inactivity. Signing in as it on a '
        'panel then offers to keep that panel signed in across restarts. The '
        'change is recorded.'
    : 'Its sessions will expire on inactivity again, like any person\'s. Any '
        'panel committed to it returns to anonymous. The change is recorded.';

/// The four cells, one key each, so a test asserts the *column* rather than
/// some text that happens to be on screen.
Key kAccessUserNameKey(String username) => Key('access-user-name-$username');
Key kAccessUserRoleKey(String username) => Key('access-user-role-$username');
Key kAccessUserCreatedKey(String username) =>
    Key('access-user-created-$username');
Key kAccessUserLastLoginKey(String username) =>
    Key('access-user-last-login-$username');

/// One account's change-role control.
Key kAccessUserChangeRoleKey(String username) =>
    Key('access-user-change-role-$username');

/// One account's reset-password control.
Key kAccessUserSetPasswordKey(String username) =>
    Key('access-user-set-password-$username');

/// One account's delete control.
Key kAccessUserDeleteKey(String username) =>
    Key('access-user-delete-$username');

/// The create control. Present whenever there is a table to create into.
const Key kAccessUsersCreateKey = Key('access-users-create');

/// The create dialog's three fields, and the set-password dialog's two.
///
/// One key per field rather than two sets: only one of these dialogs is ever on
/// screen, and the set-password dialog has no username field at all — which a
/// test asserts.
const Key kAccessUserUsernameFieldKey = Key('access-user-username-field');
const Key kAccessUserPasswordFieldKey = Key('access-user-password-field');
const Key kAccessUserConfirmFieldKey = Key('access-user-confirm-field');

/// The two confirming actions. Separate keys, because "the create is disabled
/// while its write is in flight" and "the password reset is" are two claims.
const Key kAccessUserCreateConfirmKey = Key('access-user-create-confirm');
const Key kAccessUserPasswordConfirmKey = Key('access-user-password-confirm');

/// One key per validation branch, so a test asserting "the blank-username
/// sentence" cannot pass on the mismatch sentence.
const Key kAccessUserBlankUsernameKey = Key('access-user-blank-username');
const Key kAccessUserBlankPasswordKey = Key('access-user-blank-password');
const Key kAccessUserMismatchKey = Key('access-user-mismatch');
const Key kAccessUserDuplicateKey = Key('access-user-duplicate');
const Key kAccessUserNoRoleKey = Key('access-user-no-role');
const Key kAccessUserFailedKey = Key('access-user-failed');

/// One role in the picker. A function of the role name, following
/// `access_templates_section.dart`'s discipline: a test asserts that *this*
/// role was offered, not that some row at some index was.
Key kAccessUserRoleChoiceKey(String roleName) =>
    Key('access-user-role-choice-$roleName');

/// The change-role dialog's confirming action.
const Key kAccessUserRoleConfirmKey = Key('access-user-role-confirm');

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

/// The account roster and the controls that change one.
///
/// A [ConsumerWidget] with no state of its own: the accounts come from
/// `accessAdminUsersProvider`, the roles the picker offers from
/// `accessAdminRolesProvider`, and every change goes through
/// [AccessAdminStore] and then invalidates the roster. A row keeps its own
/// refusal — see [_UserTile].
///
/// It is deliberately unbounded and unscrolled, and there is no search field
/// and no sort control: a station has a handful of accounts, and the page
/// composing this section owns the scroll view.
class AccessUsersSection extends ConsumerWidget {
  const AccessUsersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storeAsync = ref.watch(accessAdminStoreProvider);

    // Nothing while the store handle resolves. Not a spinner: this is one
    // section on a page that owns its own loading affordance, and a spinner
    // that appears for a frame on every station is the flash `AccessLockBadge`
    // and `AccessStatusAction` both refuse to draw.
    if (!storeAsync.hasValue && !storeAsync.hasError) {
      return const SizedBox.shrink();
    }

    if (storeAsync.hasError) {
      return _frame(
        context,
        child: _note(context, kAccessUsersUnavailableNote,
            key: kAccessUsersUnavailableKey),
      );
    }

    final store = storeAsync.requireValue;
    if (store == null) {
      // No create control, and that is not a permission decision: there is no
      // table to create into. The "never greyed" rule exists so a *permission*
      // refusal is explained rather than hidden.
      return _frame(
        context,
        child: _note(context, kAccessUsersNoDatabaseNote,
            key: kAccessUsersNoDatabaseKey),
      );
    }

    final usersAsync = ref.watch(accessAdminUsersProvider);
    if (!usersAsync.hasValue && !usersAsync.hasError) {
      return const SizedBox.shrink();
    }

    // The roles the picker may offer. Read once for the whole section rather
    // than per row, and empty rather than null when the roster of roles cannot
    // be read — the picker then says so instead of offering nothing without
    // explanation.
    final roles =
        ref.watch(accessAdminRolesProvider).valueOrNull ?? const <AccessRole>[];

    if (usersAsync.hasError && !usersAsync.hasValue) {
      return _frame(
        context,
        onCreate: () => _create(context, ref, store, const [], roles),
        child: _note(context, kAccessUsersUnavailableNote,
            key: kAccessUsersUnavailableKey),
      );
    }

    final users = usersAsync.requireValue;

    return _frame(
      context,
      onCreate: () => _create(
        context,
        ref,
        store,
        [for (final user in users) user.username],
        roles,
      ),
      child: users.isEmpty
          ? _note(context, kAccessUsersEmptyNote, key: kAccessUsersEmptyKey)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                for (final user in users)
                  _UserTile(
                    // Keyed by username so a row keeps its inline refusal
                    // across the rebuild every write triggers.
                    key: ValueKey('access-user-${user.username}'),
                    user: user,
                    roles: roles,
                    store: store,
                  ),
              ],
            ),
    );
  }

  /// The card, its header and the create control.
  Widget _frame(
    BuildContext context, {
    required Widget child,
    VoidCallback? onCreate,
  }) {
    final theme = Theme.of(context);
    return Card(
      key: kAccessUsersSectionKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.people_outline,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(kAccessUsersHeadline,
                      style: theme.textTheme.titleSmall),
                ),
                if (onCreate != null)
                  OutlinedButton.icon(
                    key: kAccessUsersCreateKey,
                    icon: const Icon(Icons.person_add_alt, size: 16),
                    label: const Text('New account'),
                    onPressed: onCreate,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            _note(context, kAccessUsersSubtitle),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  /// The four column headings, in the order the cells render them.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      key: kAccessUsersHeaderKey,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
              flex: _kNameFlex,
              child: Text(kAccessUsersColumnUsername, style: style)),
          Expanded(
              flex: _kRoleFlex,
              child: Text(kAccessUsersColumnRole, style: style)),
          Expanded(
              flex: _kWhenFlex,
              child: Text(kAccessUsersColumnCreated, style: style)),
          Expanded(
              flex: _kWhenFlex,
              child: Text(kAccessUsersColumnLastLogin, style: style)),
          const SizedBox(width: _kActionsWidth),
        ],
      ),
    );
  }

  /// Creates an account, from the dialog that holds the typed password.
  ///
  /// **No `refreshGroupsFromRoles` here, deliberately.** A new account holds no
  /// session, so this cannot change the caller's own groups; making the call
  /// anyway would be one unnecessary re-resolution per created account for
  /// something it cannot affect. The two writes that *can* change them are in
  /// [_UserTileState], and both make it unconditionally.
  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    AccessAdminStore store,
    List<String> taken,
    List<AccessRole> roles,
  ) async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _CreateUserDialog(
        store: store,
        taken: taken.toSet(),
        roles: roles,
      ),
    );
    if (created != true || !context.mounted) return;
    ref.invalidate(accessAdminUsersProvider);
  }
}

/// The column widths, declared once so the headings and the cells cannot drift
/// apart.
const int _kNameFlex = 3;
const int _kRoleFlex = 3;
const int _kWhenFlex = 3;
/// Five 48 px icon buttons: pages, station account, role, password, delete.
/// Widened from 192 when the Pages control joined them — a fixed width with
/// one more button than it was sized for overflows the row rather than
/// wrapping, which is how this number earns a comment.
const double _kActionsWidth = 240;

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

/// One account: four cells, the controls that change it, and the refusal the
/// last attempt came back with.
class _UserTile extends ConsumerStatefulWidget {
  const _UserTile({
    super.key,
    required this.user,
    required this.roles,
    required this.store,
  });

  final AppUserData user;

  /// Every role the picker may offer, from `accessAdminRolesProvider`, so it
  /// cannot offer one that does not exist.
  final List<AccessRole> roles;

  final AccessAdminStore store;

  @override
  ConsumerState<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends ConsumerState<_UserTile> {
  /// The lockout refusal the last write came back with, rendered inline in
  /// place of a snackbar so the operator can read the holders' names without
  /// racing something that disappears.
  ///
  /// The rule it reports is **not** re-implemented here. It lives in
  /// `AccessRepository`, inside the transaction that would otherwise perform
  /// the write; this field only holds what that transaction threw.
  LastUsersHolderException? _refusal;

  /// Re-entry guard. Deliberately not rendered as a disabled button: a control
  /// this file draws is never greyed for lack of a permission, and a second tap
  /// during the round trip is simply ignored.
  bool _busy = false;

  /// The page-whitelist draft, or null while the block is closed.
  ///
  /// Two nullables, because the value being edited is itself nullable and the
  /// two nulls mean different things: [_pagesOpen] says whether the block is
  /// showing at all, and [_pagesDraft] null then means "this account follows
  /// its role's pages". Collapsing them would make a closed row
  /// indistinguishable from an open one set to inherit.
  bool _pagesOpen = false;
  Set<String>? _pagesDraft;

  AppUserData get user => widget.user;

  /// Whether this account overrides its role's pages right now.
  bool get _overridesPages => user.allowedPages != null;

  @override
  Widget build(BuildContext context) {
    final refusal = _refusal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          key: kAccessUserRowKey(user.username),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                flex: _kNameFlex,
                child: Text(user.username, key: kAccessUserNameKey(user.username)),
              ),
              Expanded(
                flex: _kRoleFlex,
                // The tag sits against the role on purpose: a personal page
                // list survives a move to another role, so the place somebody
                // needs to be told is the place they change the role.
                child: Row(
                  children: [
                    Flexible(
                      child: Text(user.roleName,
                          key: kAccessUserRoleKey(user.username)),
                    ),
                    if (_overridesPages) ...[
                      const SizedBox(width: 6),
                      Text(
                        kAccessUserPagesOverrideTag,
                        key: kAccessUserPagesOverrideKey(user.username),
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                flex: _kWhenFlex,
                child: Text(kAccessUserWhen(user.createdAt),
                    key: kAccessUserCreatedKey(user.username)),
              ),
              Expanded(
                flex: _kWhenFlex,
                // Never blank: a null renders as [kAccessUserNever].
                child: Text(kAccessUserWhen(user.lastLoginAt),
                    key: kAccessUserLastLoginKey(user.username)),
              ),
              SizedBox(
                width: _kActionsWidth,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: kAccessUserStationAccountKey(user.username),
                      icon: Icon(
                          user.stationAccount
                              ? Icons.desktop_windows
                              : Icons.desktop_windows_outlined,
                          size: 18),
                      tooltip: user.stationAccount
                          ? kAccessUserStationAccountOnTooltip
                          : kAccessUserStationAccountOffTooltip,
                      onPressed: _toggleStationAccount,
                    ),
                    IconButton(
                      key: kAccessUserPagesKey(user.username),
                      icon: Icon(
                          _overridesPages
                              ? Icons.layers
                              : Icons.layers_outlined,
                          size: 18),
                      tooltip: kAccessUserPagesTooltip,
                      onPressed: _togglePages,
                    ),
                    IconButton(
                      key: kAccessUserChangeRoleKey(user.username),
                      icon: const Icon(Icons.badge_outlined, size: 18),
                      tooltip: 'Change role',
                      onPressed: _changeRole,
                    ),
                    IconButton(
                      key: kAccessUserSetPasswordKey(user.username),
                      icon: const Icon(Icons.password_outlined, size: 18),
                      tooltip: 'Set password',
                      onPressed: _setPassword,
                    ),
                    IconButton(
                      key: kAccessUserDeleteKey(user.username),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete account',
                      onPressed: _delete,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_pagesOpen)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The same widget the roles section mounts, told which level
                // it is on so the "no whitelist" option reads as *follows the
                // role* here and as *sees every page* there.
                AccessPagesEditor(
                  level: AccessPagesLevel.user,
                  owner: user.username,
                  selection: _pagesDraft,
                  onChanged: (next) => setState(() => _pagesDraft = next),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: kAccessUserPagesCancelKey(user.username),
                      onPressed: _togglePages,
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: kAccessUserPagesSaveKey(user.username),
                      onPressed: _savePages,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (refusal != null) ...[
          const SizedBox(height: 4),
          // The exception goes straight to the shared widget; this file builds
          // no sentence of its own, which is what keeps this section's wording
          // and the roles section's identical.
          AccessAdminRefusal.lastUsersHolder(refusal),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// Opens or closes the Pages block, seeding the draft from the stored
  /// column each time it opens so a cancelled edit really is discarded.
  void _togglePages() => setState(() {
        if (_pagesOpen) {
          _pagesOpen = false;
          _pagesDraft = null;
          return;
        }
        _pagesOpen = true;
        _pagesDraft = decodeAllowedPagesColumn(user.allowedPages);
      });

  /// Writes the draft as one `user.pages` row.
  ///
  /// Nothing here is gated. A session without `users` may open this block and
  /// tick boxes; Save is what asks, and the refusal reaches the shared prompt
  /// — signing in from there and pressing Save again is the intended flow,
  /// the same as everywhere else on this screen.
  Future<void> _savePages() async {
    if (_busy) return;
    _busy = true;
    final wrote = await _write(
      context,
      ref,
      () => widget.store.setUserPages(user.username, _pagesDraft),
      onRefused: _showRefusal,
      vanished: user.username,
    );
    _busy = false;
    if (!wrote) return;
    if (mounted) {
      setState(() {
        _pagesOpen = false;
        _pagesDraft = null;
        _refusal = null;
      });
    }
    // The session refresh last, because it can unmount this subtree — and it
    // is what makes the menu on this panel follow an edit to the account that
    // is signed in on it.
    await _afterWrite(ref);
  }

  /// Moves the account onto another role.
  ///
  /// The ordering below is the rule, not an accident — see [_afterWrite].
  Future<void> _changeRole() async {
    if (_busy) return;
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => _RolePickerDialog(
        username: user.username,
        current: user.roleName,
        roles: widget.roles,
      ),
    );
    // Choosing the role already held writes nothing: a no-op move would still
    // leave an audit row claiming a change that did not happen.
    if (chosen == null || chosen == user.roleName || !mounted) return;

    _busy = true;
    final wrote = await _write(
      context,
      ref,
      () => widget.store.setUserRole(user.username, chosen),
      onRefused: _showRefusal,
      vanished: user.username,
    );
    _busy = false;
    if (!wrote) return;

    // Everything that needs this widget happens first…
    if (mounted) setState(() => _refusal = null);
    // …and the session refresh last, because it can unmount this subtree. It is
    // called for **every** move, not only the caller's own: a call site
    // conditional on "is this me?" is a call site that gets the comparison
    // wrong once and then holds a stale privilege forever (T-06-77).
    await _afterWrite(ref);
  }

  /// Flips the station-account flag, after a confirmation that states the
  /// consequence in one breath. No `refreshGroupsFromRoles`: the flag is not
  /// a permission, and the sessions it affects re-read it at their next
  /// sign-in, not mid-flight.
  Future<void> _toggleStationAccount() async {
    if (_busy) return;
    final making = !user.stationAccount;
    final confirmed = await showConfirmDialog(
      context: context,
      title: kAccessUserStationAccountTitle(user.username, making),
      message: kAccessUserStationAccountMessage(making),
      confirmLabel: making
          ? kAccessUserStationAccountConfirmMake
          : kAccessUserStationAccountConfirmRevert,
    );
    if (!confirmed || !mounted) return;

    _busy = true;
    final wrote = await _write(
      context,
      ref,
      () => widget.store.setUserStationAccount(user.username, making),
      onRefused: _showRefusal,
      vanished: user.username,
    );
    _busy = false;
    if (!wrote) return;
    if (mounted) setState(() => _refusal = null);
  }

  /// Deletes the account, after a confirmation that says the trail survives.
  Future<void> _delete() async {
    if (_busy) return;
    final confirmed = await showConfirmDialog(
      context: context,
      title: kAccessUserDeleteTitle(user.username),
      message: kAccessUserDeleteMessage(user.username),
      confirmLabel: kAccessUserDeleteConfirmLabel,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    _busy = true;
    final wrote = await _write(
      context,
      ref,
      () => widget.store.deleteUser(user.username),
      onRefused: _showRefusal,
      vanished: user.username,
    );
    _busy = false;
    if (!wrote) return;

    // Nothing else needs this widget: `_write` has already invalidated the
    // roster and `showConfirmDialog` popped itself before the write began…
    //
    // …so the session refresh is all that is left, and it goes last. A
    // self-delete drops the session to anonymous while this callback is still
    // running, and the page above is `users`-gated — the section is unmounted
    // mid-await, which is a non-event precisely because nothing follows.
    // Unconditional, for the same reason as in [_changeRole] (T-06-77).
    await _afterWrite(ref);
  }

  /// Resets the account's password, from the dialog that holds the typed one.
  ///
  /// **No `refreshGroupsFromRoles` here, deliberately.** A password is not a
  /// permission, so this alters no privilege and cannot change the caller's own
  /// groups — the repository's own `setPassword` doc makes the same point, and
  /// carries no lockout guard for the same reason.
  Future<void> _setPassword() async {
    if (_busy) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _SetPasswordDialog(
        username: user.username,
        store: widget.store,
        stationAccount: user.stationAccount,
      ),
    );
    if (changed != true || !mounted) return;
    ref.invalidate(accessAdminUsersProvider);
  }

  /// Renders the transaction's refusal beside the row that caused it.
  void _showRefusal(Object refusal) {
    if (refusal is LastUsersHolderException && mounted) {
      setState(() => _refusal = refusal);
    }
  }
}

// ---------------------------------------------------------------------------
// The write path
// ---------------------------------------------------------------------------

/// Runs one store write and refreshes the roster.
///
/// ## The `AccessDenied` arm — read this once, it is referenced by the rest
///
/// A refusal is **not handled here**, on purpose. [AccessAdminStore] calls
/// `onDenied` before it throws, which publishes onto `accessDenialsProvider`,
/// which is what `AccessDeniedPrompt` is already listening to — so by the time
/// this catch runs, the prompt naming the `users` group is on screen. A message
/// of this file's own would be two things saying one thing, and they would
/// drift the first time the wording changed. So: swallow, change nothing, and
/// do not refresh — nothing moved.
///
/// Copied from `access_templates_section.dart` with its doc, rather than
/// rewritten "better": that file is the reference the rest of the milestone
/// points back to, and a second variant is a second behaviour. The roles
/// section holds its own copy for the same reason; hoisting the two into a
/// shared file is not this plan's to do.
///
/// ## The two arms above `on Object`
///
/// [LastUsersHolderException] is neither an `AccessDenied` nor an ordinary
/// failure. No sign-in resolves it — the account that hits it already holds
/// `users` — so it must not reach the shared prompt, and a snackbar would put
/// the holders' names in something that disappears while they are being read.
/// [onRefused] hands it to the row that caused it.
///
/// [UserNotFoundException] means the roster was stale: somebody else removed
/// the account between this list being read and the write being attempted. The
/// list is refreshed and a **fixed sentence** naming the account is shown —
/// never the exception, which is a habit worth keeping in a file where two
/// other paths hold a credential.
Future<bool> _write(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() write, {
  void Function(Object refusal)? onRefused,
  String? vanished,
}) async {
  try {
    await write();
  } on LastUsersHolderException catch (refusal) {
    if (onRefused != null) {
      onRefused(refusal);
    } else if (context.mounted) {
      _showProblem(context, refusal);
    }
    return false;
  } on UserNotFoundException {
    ref.invalidate(accessAdminUsersProvider);
    if (context.mounted && vanished != null) {
      _showMessage(context, kAccessUserVanishedNote(vanished));
    }
    return false;
  } on AccessDenied {
    return false;
  } on Object catch (error) {
    // Not an authorization event and not a credential path — a role that went
    // away underneath us, a database that stopped answering mid-write. The
    // operator gets the reason rather than a control that did nothing.
    if (context.mounted) _showProblem(context, error);
    return false;
  }
  // There is no listener over `app_user` and nothing else notices. This
  // invalidate is the single refresh trigger for the roster.
  ref.invalidate(accessAdminUsersProvider);
  return true;
}

/// Re-resolves the session in force against the rows that were just written.
///
/// **This is the last thing any write path does, and the ordering is the rule.**
///
/// Invalidate the roster, close whatever dialog is open and finish every
/// `setState` **before** awaiting this; guard anything that must happen after
/// it with `context.mounted`. The reason is that this section can unmount
/// itself mid-await. Deleting the caller's own account, or moving it onto a
/// role without `users`, is *permitted* whenever a second holder remains — only
/// the last-holder case throws — so the refresh drops the caller below the
/// `users` gate while this widget is still inside its own async callback. The
/// page is `users`-gated, so `AccessGate` swaps the subtree out and the section
/// is disposed; a `ref.invalidate`, a `setState` or a `ScaffoldMessenger` call
/// sequenced after this would then run on a disposed element.
///
/// Doing it **last** makes the unmount a non-event: everything that needed the
/// widget has already happened, and the one thing left is the session drop,
/// which is the point of the call. Nothing in this file touches `ref` or
/// `context` after awaiting it.
///
/// It is called after **every** `setUserRole` and **every** `deleteUser`, and
/// never inside an "is this the signed-in account?" conditional. Such a
/// conditional would make a lifecycle exception go away by not making the call,
/// and the call is the only thing that stops an admin who has just demoted
/// themselves from keeping the groups they removed — T-06-77, which fails open.
///
/// The other half of the fix is in `refreshGroupsFromRoles` itself: its
/// elevated arm re-reads the `app_user` row, so a changed `role_name` is
/// observed and a vanished row drops the session to anonymous. The call here is
/// useless without that, and 06-04 specifies it.
///
/// The notifier is read synchronously, before the await, so a caller that is
/// disposed by the refresh never reaches back into `ref`.
Future<void> _afterWrite(WidgetRef ref) {
  final controller = ref.read(accessSessionProvider.notifier);
  return controller.refreshGroupsFromRoles();
}

/// A snackbar carrying the failure.
///
/// **This is the everywhere-else arm of the rule in the library doc.** It is
/// used by the role change and the delete, neither of which ever holds a
/// credential. The create and set-password dialogs must not reach it — see
/// their own docs.
void _showProblem(BuildContext context, Object error) {
  _showMessage(context, '$error');
}

/// A snackbar carrying a sentence this file wrote.
void _showMessage(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/// Pick the role an account holds.
///
/// The choices are the roles the store returned and nothing else: a picker that
/// could offer a role that does not exist would produce an account pointing at
/// a missing row, which the repository refuses anyway — but refusing it after a
/// dialog closed is worse than not offering it (T-06-76).
///
/// It returns the chosen name and performs no write. The row does that, so the
/// refusal it can come back with is rendered beside the row rather than in
/// something that closes.
class _RolePickerDialog extends StatefulWidget {
  const _RolePickerDialog({
    required this.username,
    required this.current,
    required this.roles,
  });

  final String username;
  final String current;
  final List<AccessRole> roles;

  @override
  State<_RolePickerDialog> createState() => _RolePickerDialogState();
}

class _RolePickerDialogState extends State<_RolePickerDialog> {
  late String _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: kAccessUserRoleDialogTitle(widget.username),
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: kAccessUserRoleConfirmLabel,
          buttonKey: kAccessUserRoleConfirmKey,
          onPressed: () => Navigator.of(context).pop(_selected),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _note(context, kAccessUserRoleDialogNote),
          const SizedBox(height: 8),
          if (widget.roles.isEmpty)
            _note(context, kAccessUserRoleDialogEmptyNote),
          for (final role in widget.roles)
            ListTile(
              key: kAccessUserRoleChoiceKey(role.name),
              dense: true,
              contentPadding: EdgeInsets.zero,
              selected: role.name == _selected,
              leading: Icon(
                role.name == _selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
              ),
              title: Text(role.name),
              // What the role grants, by label rather than by the persisted
              // identifier: 06-01 exists because two of the seven group names
              // tell a commissioning engineer nothing on their own.
              subtitle: Text(kAccessUserRoleGrants(role.groups)),
              onTap: () => setState(() => _selected = role.name),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The two dialogs where a password is in hand
// ---------------------------------------------------------------------------

/// What is wrong with what was typed, as one value.
///
/// One enum shared by both dialogs rather than a validation rule each, for
/// `_TemplateNameDialog`'s stated reason: two nearly identical dialogs is how
/// two validation rules start disagreeing. The set-password dialog simply never
/// reaches [blankUsername], [duplicate] or [noRole].
///
/// The values are named after the mistake, not after the sentence, and there is
/// no `unknown`: [failed] is the one arm that covers something this file did
/// not anticipate, and it is also the one that must never say what it was.
enum _CredentialProblem {
  /// The username field was blank. First of the three checks.
  blankUsername,

  /// The password field was blank. Second.
  blankPassword,

  /// The two password fields disagree. Third.
  mismatch,

  /// The name is already in the loaded roster, or the transaction said so.
  duplicate,

  /// No role could be read, so there is nothing to create the account into.
  noRole,

  /// The write threw. **What it threw does not appear on screen.**
  failed,
}

/// The inline sentence for [problem], in the error colour, keyed by branch.
///
/// [failureNote] is the dialog's own fixed failure sentence — fixed, because
/// this is the one screen in the milestone where a credential is in hand and an
/// exception raised on a bad one can carry it in its message. See the library
/// doc; `first_user.dart` argues it at length.
Widget _problemLine(
  BuildContext context,
  _CredentialProblem problem, {
  required String subject,
  required String failureNote,
}) {
  final theme = Theme.of(context);
  final (Key key, String text) = switch (problem) {
    _CredentialProblem.blankUsername => (
        kAccessUserBlankUsernameKey,
        kAccessUserBlankUsernameNote,
      ),
    _CredentialProblem.blankPassword => (
        kAccessUserBlankPasswordKey,
        kAccessUserBlankPasswordNote,
      ),
    _CredentialProblem.mismatch => (
        kAccessUserMismatchKey,
        kAccessUserMismatchNote,
      ),
    _CredentialProblem.duplicate => (
        kAccessUserDuplicateKey,
        kAccessUserDuplicateNote(subject),
      ),
    _CredentialProblem.noRole => (
        kAccessUserNoRoleKey,
        kAccessUserRoleDialogEmptyNote,
      ),
    _CredentialProblem.failed => (kAccessUserFailedKey, failureNote),
  };
  return Text(
    text,
    key: key,
    maxLines: null,
    overflow: TextOverflow.visible,
    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
  );
}

/// Create an account: a username, a password typed twice, and a role.
///
/// ## The password never leaves this widget except downwards
///
/// It lives in a [TextEditingController] for the life of the dialog and is
/// handed to [AccessAdminStore.createUser], which hands it to the repository,
/// which derives the hash. It is never put into a provider, a field on the
/// section, a `reason`, a log line or an audit row — `AuditRecord.userCreate`
/// has no parameter that could carry it, which is the point of the constructor.
///
/// ## Nothing here renders an exception
///
/// `_showProblem` is right for the role change and the delete and wrong here,
/// and the difference is the credential in hand. A failure goes to `Logger().e`
/// with a fixed message and the screen shows [kAccessUserCreateFailedNote].
/// There is no snackbar on this path at all.
///
/// ## The busy state is not the never-greyed rule
///
/// The confirming action is disabled **while a write is in flight**, and that
/// is a different thing from greying a control because the session may not use
/// it. The milestone's rule is about *refusing*: a permission refusal must be
/// pressed and then explained, never hidden. This is about a second tap racing
/// the first across a key derivation that takes the better part of a second at
/// `Pbkdf2Kdf.defaultIterations`. `first_user.dart` draws the same distinction
/// on the same grounds.
class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog({
    required this.store,
    required this.taken,
    required this.roles,
  });

  final AccessAdminStore store;

  /// The usernames already in the loaded roster.
  ///
  /// The duplicate is refused **here**, before the store is called, and
  /// compared **exactly**: `app_user.username` is a case-sensitive primary key,
  /// so a dialog that refused a capitalisation of an existing name would be
  /// refusing something the database would have accepted.
  final Set<String> taken;

  /// Every role the picker may offer, so it cannot offer one that is not there.
  final List<AccessRole> roles;

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// The role the new account will hold.
  ///
  /// Defaults to the **first** role the store returned rather than to anything
  /// this file names. On a seeded database that is `Operator`, the narrowest
  /// one there is, which is the right default for a control that hands out
  /// privilege: widening it is a deliberate act by the person creating the
  /// account.
  late String? _role = widget.roles.isEmpty ? null : widget.roles.first.name;

  /// What is wrong with what was typed, or null.
  _CredentialProblem? _problem;

  /// The name the duplicate sentence is about — the typed one for the
  /// pre-check, the exception's for the race.
  String _subject = '';

  /// True while a `createUser` call is outstanding. See the class doc.
  bool _submitting = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final username = _username.text.trim();
    final password = _password.text;

    // `first_user.dart`'s order, and its wording: three checks means three
    // sentences the operator can act on.
    if (username.isEmpty) {
      setState(() => _problem = _CredentialProblem.blankUsername);
      return;
    }
    if (password.isEmpty) {
      setState(() => _problem = _CredentialProblem.blankPassword);
      return;
    }
    if (password != _confirm.text) {
      setState(() => _problem = _CredentialProblem.mismatch);
      return;
    }
    if (widget.taken.contains(username)) {
      setState(() {
        _subject = username;
        _problem = _CredentialProblem.duplicate;
      });
      return;
    }
    final role = _role;
    if (role == null) {
      setState(() => _problem = _CredentialProblem.noRole);
      return;
    }

    setState(() {
      _problem = null;
      _submitting = true;
    });

    try {
      await widget.store.createUser(
        username: username,
        password: password,
        roleName: role,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on UserExistsException catch (taken) {
      // The race the pre-check cannot win: another station inserted the name
      // between the roster this dialog was given and this transaction. The
      // dialog re-renders holding what was typed rather than closing.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _subject = taken.username;
        _problem = _CredentialProblem.duplicate;
      });
    } on AccessDenied {
      // See the note at [_write]: the shared prompt naming the `users` group is
      // already on screen. The dialog stays open, so signing in from there and
      // pressing Create again is the intended flow.
      if (mounted) setState(() => _submitting = false);
    } on Object catch (thrown, stack) {
      // The exception goes to the log, never to the screen — the library doc
      // and `first_user.dart` both say why.
      Logger().e('createUser failed', error: thrown, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _problem = _CredentialProblem.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return StandardDialogFrame(
      title: kAccessUserCreateTitle,
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: kAccessUserCreateConfirmLabel,
          buttonKey: kAccessUserCreateConfirmKey,
          onPressed: _submitting ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _note(context, kAccessUserCreateNote),
          const SizedBox(height: 12),
          TextField(
            key: kAccessUserUsernameFieldKey,
            controller: _username,
            autofocus: true,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessUserPasswordFieldKey,
            controller: _password,
            obscureText: true,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessUserConfirmFieldKey,
            controller: _confirm,
            obscureText: true,
            enabled: !_submitting,
            onSubmitted: _submitting ? null : (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (widget.roles.isEmpty)
            _note(context, kAccessUserRoleDialogEmptyNote)
          else
            for (final role in widget.roles)
              ListTile(
                key: kAccessUserRoleChoiceKey(role.name),
                dense: true,
                contentPadding: EdgeInsets.zero,
                enabled: !_submitting,
                selected: role.name == _role,
                leading: Icon(
                  role.name == _role
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: Text(role.name),
                subtitle: Text(kAccessUserRoleGrants(role.groups)),
                onTap: () => setState(() => _role = role.name),
              ),
          if (problem != null) ...[
            const SizedBox(height: 12),
            _problemLine(
              context,
              problem,
              subject: _subject,
              failureNote: kAccessUserCreateFailedNote,
            ),
          ],
        ],
      ),
    );
  }
}

/// Reset an account's password: the new one, typed twice.
///
/// No username field and no current-password field. The username is the row the
/// control was pressed on, and there is no current password for an administrator
/// to present — they are resetting somebody else's credential, not proving they
/// hold it. 06-CONTEXT fixes this at "an admin types the new password directly",
/// and there is no "force a change on next login" either, because a forced
/// change is a policy and this screen has none.
///
/// A verify-current flow does now exist — `AccessChangePasswordDialog`, off the
/// app bar's account menu — and it is deliberately **not** this dialog with a
/// flag. That one is ungated and self-service, reached by anybody signed in and
/// acting only on their own account; this one is behind the `users` group and
/// acts on somebody else's. One boolean is the wrong distance between a gated
/// path and an ungated one.
///
/// Every rule in [_CreateUserDialog]'s doc applies here unchanged: the password
/// goes to the store and nowhere else, no exception is ever rendered, and the
/// confirming action is disabled for the duration of the derivation rather than
/// for lack of a permission.
class _SetPasswordDialog extends StatefulWidget {
  const _SetPasswordDialog({
    required this.username,
    required this.store,
    required this.stationAccount,
  });

  final String username;
  final AccessAdminStore store;

  /// Whether this row is a panel account. Only the note varies on it — the
  /// write is identical, because an administrator resetting a station account
  /// is exactly as legitimate as resetting anybody else's.
  final bool stationAccount;

  @override
  State<_SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends State<_SetPasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  _CredentialProblem? _problem;
  bool _submitting = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final password = _password.text;

    if (password.isEmpty) {
      setState(() => _problem = _CredentialProblem.blankPassword);
      return;
    }
    if (password != _confirm.text) {
      setState(() => _problem = _CredentialProblem.mismatch);
      return;
    }

    setState(() {
      _problem = null;
      _submitting = true;
    });

    try {
      await widget.store.setUserPassword(widget.username, password);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AccessDenied {
      if (mounted) setState(() => _submitting = false);
    } on Object catch (thrown, stack) {
      // The exception goes to the log, never to the screen.
      Logger().e('setUserPassword failed', error: thrown, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _problem = _CredentialProblem.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return StandardDialogFrame(
      title: kAccessUserSetPasswordTitle(widget.username),
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: kAccessUserSetPasswordConfirmLabel,
          buttonKey: kAccessUserPasswordConfirmKey,
          onPressed: _submitting ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _note(
            context,
            kAccessUserSetPasswordNoteFor(
                stationAccount: widget.stationAccount),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessUserPasswordFieldKey,
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: 'New password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessUserConfirmFieldKey,
            controller: _confirm,
            obscureText: true,
            enabled: !_submitting,
            onSubmitted: _submitting ? null : (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
              border: OutlineInputBorder(),
            ),
          ),
          if (problem != null) ...[
            const SizedBox(height: 12),
            _problemLine(
              context,
              problem,
              subject: widget.username,
              failureNote: kAccessUserSetPasswordFailedNote,
            ),
          ],
        ],
      ),
    );
  }
}

/// A secondary line, never ellipsised. Every explanatory sentence in this file
/// goes through here so none of them can quietly become one clipped line —
/// `find.text` passing is not the same as the operator being able to read it.
Widget _note(BuildContext context, String text, {Key? key}) {
  final theme = Theme.of(context);
  return Text(
    text,
    key: key,
    maxLines: null,
    overflow: TextOverflow.visible,
    style: theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}
