/// The administration page's roles section — 06-CONTEXT "Roles Screen".
///
/// A list of roles, an editor with one labelled checkbox per group, and two
/// refusals that offer no way past themselves. Composed onto a page beside the
/// users section; this file renders a card and owns no route.
///
/// ## It is `users`-gated, and the gate is not in this file
///
/// Every write goes through [AccessAdminStore], which asks for
/// [kAccessAdminGroup] and records the answer either way. There is no second
/// path and no second gate. What this widget owes is legibility **before** the
/// operator presses anything, in the shape this milestone has used everywhere
/// else: visible, tappable, explained, never greyed. A control is not disabled
/// because the session may not use it — it is pressed, and the shared
/// `AccessDeniedPrompt` says which group to go and get.
///
/// ## The `Operator` row, and the one footgun this model creates
///
/// Anonymous **is** the role named `Operator`, by construction. So editing that
/// row changes what an *unauthenticated* panel may do: ticking a group there
/// grants it to every logged-out panel on the floor. That is allowed — it is
/// the knob a site turns when it wants a permissive line — and
/// `AccessRepository`'s class doc has asked since Phase 1 that "the Phase 6
/// roles screen must say so at the point of edit, not in a help page". The long
/// form of the argument is there; the same words appear in
/// `packages/tfc_access/lib/src/access_role.dart` and in
/// `docs/access-control-deployment.md` §5. This screen does not add a fourth
/// phrasing. It says the short version **twice**, because a banner alone is
/// read once and then ignored:
///
///  1. [kAccessOperatorBannerNote] — a persistent inline banner, rendered the
///     whole time the protected row's editor is open.
///  2. [kAccessOperatorConfirmMessage] — a confirmation on save, naming the
///     groups being added by their labels.
///
/// Both, always. Neither is conditional on the other, and each has its own
/// passing test.
///
/// ## A role write is not finished when the row is written
///
/// `ref.invalidate(accessAdminRolesProvider)` refreshes the *list*. What the
/// running app permits is re-resolved by
/// `AccessSessionController.refreshGroupsFromRoles`, and this section calls it
/// after **all four** role writes — create, update, rename and delete — not
/// only after an `Operator` edit. Deleting or re-scoping the role the signed-in
/// person holds is the same staleness with a different subject.
///
/// **That call goes last, and the ordering is load-bearing.** See [_afterWrite].
///
/// ## Two refusals, one dialog, and no override
///
/// A role delete can be blocked for two independent reasons: accounts still
/// hold it, and deleting it would leave nobody holding `users`. Both are
/// modelled as one state value ([_RoleDeleteBlock]) rather than two booleans,
/// because two booleans can both be true and then the dialog has to choose a
/// wording, which is exactly the drift this avoids. Neither refusal is an
/// `AccessDenied` and no sign-in resolves either, so while one is in force the
/// confirming action is **absent**, not greyed — `_DeleteTemplateDialog`'s
/// doctrine, quoted at [_DeleteRoleDialog].
///
/// There is no typed-confirmation escape, no control that deletes it anyway,
/// and no offer to move the holders elsewhere and then delete. 06-CONTEXT's
/// deferred list rejects the first and the last by name. The override phrasings
/// are deliberately not spelled out here or below: a grep gate reads this file
/// as raw text and cannot tell a prohibition from an implementation.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

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
const String kAccessRolesHeadline = 'Roles';

/// One line under the title. Says what a role is before a list of names
/// arrives, and names the two things a row carries: a set of groups, and the
/// accounts holding it.
const String kAccessRolesSubtitle =
    'A role is a name and the permission groups it grants. Every account holds '
    'exactly one, and a panel with nobody signed in holds "Operator".';

/// The read failed, or the store could not be built.
///
/// Says the list is untrustworthy rather than that there are no roles: the
/// guards on the panel are still resolving against whatever the session already
/// holds, and an empty list here would be a claim about the tables that this
/// station cannot currently make.
const String kAccessRolesUnavailableNote =
    'The roles could not be read. Whatever the panel already resolved is still '
    'in force, but this list may be out of date.';

/// No database — which is **not** "no roles".
///
/// Names no cause, for the reason `kAccessTemplatesNoDatabaseNote` gives: a
/// station that was never configured and one whose Postgres will not answer are
/// the same resolved null from here, and the next step is the same either way.
const String kAccessRolesNoDatabaseNote =
    'Roles live in the database, and this station has no reachable one — so '
    'this is "cannot tell you", not "there are none". The connection is set up '
    'in Server Config.';

/// A database that answered, with nothing in it.
///
/// Deliberately not "no roles yet". The schema-v6 migration seeds four, and
/// `Operator` cannot be deleted, so an empty list is not a state a commissioned
/// station reaches — it means the migration did not run, or something emptied
/// the table underneath.
const String kAccessRolesEmptyNote =
    'No roles at all, which should not be possible: a migrated database is '
    'seeded with four and "Operator" cannot be deleted. Check that the '
    'database this station is pointed at is the one that was migrated.';

/// `n account` / `n accounts`, with the number in the sentence.
///
/// Local rather than shared with `access_admin_notice.dart`'s private helper of
/// the same shape: this one is part of a row's summary, that one is part of a
/// refusal, and a single helper across two files would be one import for one
/// pluralisation.
String _accounts(int n) => '$n account${n == 1 ? '' : 's'}';

/// A role's one-line summary: what it grants, and how many accounts hold it.
///
/// The groups read by [AccessGroupInfo.label] and in [AccessGroup.values]
/// order, so two roles granting the same set read identically. [holders] is
/// null when the roster could not be read — the count is then omitted rather
/// than rendered as zero, because "nobody holds it" is a claim and "cannot
/// tell" is not.
String kAccessRoleSummary(Set<AccessGroup> groups, int? holders) {
  final grants = groups.isEmpty
      ? 'Grants nothing'
      : AccessGroup.values.where(groups.contains).map((g) => g.label).join(' · ');
  if (holders == null) return grants;
  return '$grants — held by ${_accounts(holders)}';
}

/// Rendered immediately after the protected row's name, so the row reads as
/// "Operator (Anonymous)".
///
/// A parenthetical rather than a separate chip: the point is that this role IS
/// the anonymous identity, not that it has a property. "Logged-out panels" said
/// the same thing but read as a label attached to a role, which invited the
/// question this wording forecloses -- which role anonymous points at. It does
/// not point anywhere; it is this row.
const String kAccessRoleAnonymousTag = '(Anonymous)';

/// Shown in the create dialog. A role with no groups grants nothing, and saying
/// so beats somebody moving an account onto it and wondering why every control
/// stayed locked.
const String kAccessRoleNewNote =
    'A new role grants nothing until a group is ticked, and nobody holds it '
    'until an account is moved onto it.';

/// The name was blank, padded, or too long for the column.
const String kAccessRoleInvalidNameNote =
    'Use a name with no leading or trailing spaces, at most 64 characters.';

/// A role of that name is already there. Caught here so the store is never
/// called with a name that cannot succeed.
const String kAccessRoleDuplicateNameNote =
    'A role with that name already exists.';

/// The name is a capitalisation of the protected name.
///
/// Refused here rather than left to the repository, which guards its own delete
/// and rename but lets a *second* row take a case variant of the name. Such a
/// row would render with no Rename and no Delete — [isProtectedRoleName] is
/// case-insensitive — and nothing on this screen could then remove it.
const String kAccessRoleProtectedNameNote =
    '"Operator" is the role a panel with nobody signed in resolves to, so no '
    'other role may take that name in any capitalisation.';

/// **Warning one of two.** The persistent inline banner, rendered the whole
/// time the protected row's editor is open.
///
/// Short on purpose. The full argument is in `access_repository.dart`'s class
/// doc — "Ticking `setpoints` on Operator silently grants it to every panel on
/// the floor with nobody signed in […] the one footgun this simplification
/// creates" — and exists in the same words twice more, in `access_role.dart`
/// and in `docs/access-control-deployment.md` §5. The screen's job is to make
/// the reader stop, not to reproduce the reasoning, so this cites one and adds
/// no fourth phrasing.
const String kAccessOperatorBannerNote =
    'This is the role a panel with nobody signed in resolves to. A group '
    'ticked here is granted to every logged-out panel on the floor.';

/// **Warning two of two.** The confirmation on save, naming what is being
/// added.
///
/// By [AccessGroupInfo.label], never by the persisted identifier: 06-01 exists
/// because `force` and `device` are not self-explanatory, and a confirmation
/// reading "force" undoes that.
String kAccessOperatorConfirmMessage(List<AccessGroup> added) =>
    'Saving this grants ${added.map((g) => g.label).join(', ')} to every panel '
    'on the floor with nobody signed in, immediately and without a sign-in.';

/// The confirmation's title. A question, because it is one.
const String kAccessOperatorConfirmTitle = 'Grant to every logged-out panel?';

/// The confirmation's affirmative. Not "OK": the label says what happens.
const String kAccessOperatorConfirmLabel = 'Grant';

/// While the delete dialog's two questions are in flight.
const String kAccessRoleDeleteCheckingNote = 'Checking who holds this role…';

/// The questions could not be asked. "Cannot tell" must not read as "nobody
/// holds it", so the delete is not offered here either.
const String kAccessRoleDeleteUnknownNote =
    'Could not read who holds this role, so deleting it is not offered — it '
    'might leave accounts pointing at a role that is no longer there.';

/// Nobody holds it and the invariant survives without it, so the delete costs
/// nothing.
String kAccessRoleDeleteFreeNote(String name) =>
    'No account holds "$name", so deleting it changes nothing about what '
    'anybody may do.';

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// The section itself, so a test can tell "rendered nothing" from "rendered an
/// empty list".
const Key kAccessRolesSectionKey = Key('access-roles-section');

/// The could-not-read line.
const Key kAccessRolesUnavailableKey = Key('access-roles-unavailable');

/// The no-database line.
const Key kAccessRolesNoDatabaseKey = Key('access-roles-no-database');

/// The nothing-at-all line, which is a different claim from the one above.
const Key kAccessRolesEmptyKey = Key('access-roles-empty');

/// The create control. Present and enabled for every session that has a table
/// to create into.
const Key kAccessRolesCreateKey = Key('access-roles-create');

/// The name field, shared by the create and rename dialogs.
const Key kAccessRoleNameFieldKey = Key('access-role-name-field');

/// The name dialog's confirming action. One key rather than two: only one of
/// these dialogs is ever on screen.
const Key kAccessRoleNameConfirmKey = Key('access-role-name-confirm');

/// The delete dialog's confirming action, present only when nothing blocks it.
const Key kAccessRoleDeleteConfirmKey = Key('access-role-delete-confirm');

/// The delete dialog's still-asking line.
const Key kAccessRoleDeleteCheckingKey = Key('access-role-delete-checking');

/// The delete dialog's cannot-tell line.
const Key kAccessRoleDeleteUnknownKey = Key('access-role-delete-unknown');

/// The delete dialog's nothing-in-the-way line.
const Key kAccessRoleDeleteFreeKey = Key('access-role-delete-free');

/// The protected row's inline banner.
///
/// Its own key rather than `kAccessAdminWarningKey`, so a test meaning "the
/// Operator banner is up" cannot pass on some other warning.
const Key kAccessOperatorWarningKey = Key('access-role-operator-warning');

/// One role's row.
Key kAccessRoleTileKey(String name) => Key('access-role-tile-$name');

/// One role's rename control. Absent on the protected row.
Key kAccessRoleRenameKey(String name) => Key('access-role-rename-$name');

/// One role's delete control. Absent on the protected row.
Key kAccessRoleDeleteKey(String name) => Key('access-role-delete-$name');

/// The protected row's marker beside its name.
const Key kAccessRoleAnonymousTagKey = Key('access-role-anonymous-tag');

/// One checkbox in one role's editor.
///
/// Keyed by role as well as by group because more than one editor may be open:
/// the tiles keep their own state and nothing here closes a sibling.
Key kAccessRoleGroupKey(String roleName, AccessGroup group) =>
    Key('access-role-group-$roleName-${group.name}');

/// One editor's Save.
Key kAccessRoleSaveKey(String name) => Key('access-role-save-$name');

/// One editor's Cancel.
Key kAccessRoleCancelKey(String name) => Key('access-role-cancel-$name');

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

/// The role list, the create control, and the dialogs that change a role.
///
/// A [ConsumerWidget] with no state of its own: the roles come from
/// `accessAdminRolesProvider`, the holder counts from `accessAdminUsersProvider`
/// and every change goes through [AccessAdminStore] and then invalidates both.
/// The editors keep their own draft, one per row — see [_RoleTile].
///
/// It is deliberately unbounded and unscrolled. There are four roles on a
/// seeded station and a site might add two, so there is no search box, no sort
/// control and no pagination; the page composing this section owns the scroll
/// view.
class AccessRolesSection extends ConsumerWidget {
  const AccessRolesSection({super.key});

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
        child: _note(context, kAccessRolesUnavailableNote,
            key: kAccessRolesUnavailableKey),
      );
    }

    final store = storeAsync.requireValue;
    if (store == null) {
      // No create control, and that is not a permission decision: there is no
      // table to create into. The "never greyed" rule exists so a *permission*
      // refusal is explained rather than hidden — see the note at
      // [_DeleteRoleDialog], which draws the same distinction.
      return _frame(
        context,
        child: _note(context, kAccessRolesNoDatabaseNote,
            key: kAccessRolesNoDatabaseKey),
      );
    }

    final rolesAsync = ref.watch(accessAdminRolesProvider);
    if (!rolesAsync.hasValue && !rolesAsync.hasError) {
      return const SizedBox.shrink();
    }
    if (rolesAsync.hasError && !rolesAsync.hasValue) {
      return _frame(
        context,
        onCreate: () => _create(context, ref, store, const []),
        child: _note(context, kAccessRolesUnavailableNote,
            key: kAccessRolesUnavailableKey),
      );
    }

    final roles = rolesAsync.requireValue;
    final names = [for (final role in roles) role.name];

    // The holder counts, from **one** roster read for the whole section rather
    // than a query per row. `accessAdminUsersProvider` is already loaded for
    // the users section beside this one, so on the composed page this costs
    // nothing at all. Null while it is loading or if it failed: the summary
    // then omits the count, because "nobody holds it" is a claim and "cannot
    // tell" is not.
    final roster = ref.watch(accessAdminUsersProvider).valueOrNull;
    final Map<String, int>? holders = roster == null
        ? null
        : {
            for (final role in roles)
              role.name: roster.where((u) => u.roleName == role.name).length,
          };

    return _frame(
      context,
      onCreate: () => _create(context, ref, store, names),
      child: roles.isEmpty
          ? _note(context, kAccessRolesEmptyNote, key: kAccessRolesEmptyKey)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final role in roles)
                  _RoleTile(
                    // Keyed by name so that an open editor stays open across
                    // the rebuild every write triggers — otherwise saving one
                    // role would collapse the row being edited.
                    key: ValueKey('access-role-${role.name}'),
                    role: role,
                    otherNames: [
                      for (final n in names)
                        if (n != role.name) n,
                    ],
                    holders: holders?[role.name],
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
      key: kAccessRolesSectionKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.badge_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(kAccessRolesHeadline,
                      style: theme.textTheme.titleSmall),
                ),
                if (onCreate != null)
                  OutlinedButton.icon(
                    key: kAccessRolesCreateKey,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New role'),
                    onPressed: onCreate,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            _note(context, kAccessRolesSubtitle),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    AccessAdminStore store,
    List<String> taken,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RoleNameDialog(
        title: 'New role',
        confirmLabel: 'Create',
        initial: '',
        taken: taken.toSet(),
        footnote: kAccessRoleNewNote,
      ),
    );
    if (name == null || !context.mounted) return;
    final wrote = await _write(
      context,
      ref,
      () => store.createRole(AccessRole(name: name, groups: const {})),
    );
    if (wrote) await _afterWrite(ref);
  }
}

// ---------------------------------------------------------------------------
// One row
// ---------------------------------------------------------------------------

/// One role: its name, what it grants, who holds it — and, when it is open, the
/// seven checkboxes.
class _RoleTile extends ConsumerStatefulWidget {
  const _RoleTile({
    super.key,
    required this.role,
    required this.otherNames,
    required this.holders,
    required this.store,
  });

  final AccessRole role;

  /// Every other role's name, for the duplicate check the rename dialog makes
  /// before the store is called.
  final List<String> otherNames;

  /// How many accounts hold this role, or null when the roster is not readable.
  final int? holders;

  final AccessAdminStore store;

  @override
  ConsumerState<_RoleTile> createState() => _RoleTileState();
}

class _RoleTileState extends ConsumerState<_RoleTile> {
  /// The editor's draft, or null while the row is closed.
  ///
  /// A local set, not a write per tick: ticking six boxes must be one audit row
  /// and one `role.update`, not six — and Cancel must be able to mean it.
  Set<AccessGroup>? _draft;

  /// The page whitelist draft, held beside [_draft] and opened with it.
  ///
  /// Null means "no whitelist" — this role sees every page — and the empty set
  /// means a whitelist naming nothing. The two are different roles, so this
  /// cannot be collapsed into an empty-means-none field. `_pagesTouched` is
  /// what tells "the operator left it alone" from "the operator chose null",
  /// which decides whether Save issues the `role.pages` write at all.
  Set<String>? _pagesDraft;
  bool _pagesTouched = false;

  /// The lockout refusal the last save came back with, rendered inline in place
  /// of a snackbar so the operator can see it beside the boxes they left as
  /// they were.
  ///
  /// The rule it reports is **not** re-implemented here. It lives in
  /// `AccessRepository`, inside the transaction that would otherwise perform
  /// the write; this field only holds what that transaction threw.
  LastUsersHolderException? _refusal;

  /// Re-entry guard. Deliberately not rendered as a disabled button: a control
  /// this file draws is never greyed, and a second tap during the round trip is
  /// simply ignored.
  bool _saving = false;

  AccessRole get role => widget.role;
  AccessAdminStore get store => widget.store;

  /// The same predicate the repository uses — case-insensitive and
  /// whitespace-tolerant. A `==` against the constant here would let a row
  /// stored as `operator` render a Delete the repository would then refuse with
  /// a `ProtectedRoleError`, which is an `Error`: a screen bug, not a
  /// condition.
  bool get _protected => isProtectedRoleName(role.name);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: kAccessRoleTileKey(role.name),
          dense: true,
          contentPadding: EdgeInsets.zero,
          onTap: _toggle,
          leading: Icon(
              draft == null ? Icons.expand_more : Icons.expand_less,
              size: 18),
          title: Row(
            children: [
              Flexible(child: Text(role.name)),
              if (_protected) ...[
                // The parenthetical sits against the name -- the icon moved
                // after it, because an icon between the two broke the phrase
                // the reader is meant to see as one thing.
                const SizedBox(width: 4),
                Text(
                  kAccessRoleAnonymousTag,
                  key: kAccessRoleAnonymousTagKey,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: 6),
                Icon(Icons.no_accounts_outlined,
                    size: 14, color: theme.colorScheme.onSurfaceVariant),
              ],
            ],
          ),
          subtitle: Text(kAccessRoleSummary(role.groups, widget.holders)),
          // Neither control on the protected row: absent, not disabled. See
          // [_protected].
          trailing: _protected
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: kAccessRoleRenameKey(role.name),
                      icon: const Icon(Icons.drive_file_rename_outline,
                          size: 18),
                      tooltip: 'Rename',
                      onPressed: _rename,
                    ),
                    IconButton(
                      key: kAccessRoleDeleteKey(role.name),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete',
                      onPressed: _delete,
                    ),
                  ],
                ),
        ),
        if (draft != null) _editor(context, draft),
      ],
    );
  }

  void _toggle() => setState(() {
        if (_draft == null) {
          _draft = {...role.groups};
          _pagesDraft =
              role.allowedPages == null ? null : {...role.allowedPages!};
          _pagesTouched = false;
        } else {
          _draft = null;
          _pagesDraft = null;
          _pagesTouched = false;
          _refusal = null;
        }
      });

  /// The groups, one checkbox each, plus whichever of the two notices applies.
  ///
  /// The boxes are **generated from [AccessGroup.values]** and never written
  /// out: the enum's declaration order is increasing privilege and
  /// `tfc_access/test/access_group_test.dart` pins it, so an eighth group would
  /// appear here automatically rather than silently not.
  ///
  /// Nothing here is gated. A session without `users` may open this editor and
  /// tick boxes; Save is what asks, and the refusal reaches the shared prompt —
  /// signing in from there and pressing Save again is the intended flow.
  Widget _editor(BuildContext context, Set<AccessGroup> draft) {
    final refusal = _refusal;
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Warning one of two, and it is up the whole time this row is open —
          // not only at the moment of saving. See the library doc.
          if (_protected)
            AccessAdminWarning(
              blockKey: kAccessOperatorWarningKey,
              text: kAccessOperatorBannerNote,
              // Something becoming *less* restricted, matching
              // `_WarningBlock`'s own choice for the rename warning.
              icon: Icons.lock_open_outlined,
            ),
          for (final group in AccessGroup.values)
            CheckboxListTile(
              key: kAccessRoleGroupKey(role.name, group),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              // The label and the description come from 06-01's extension and
              // from nowhere else. Nothing in this file writes a group's
              // display text of its own — the UI and the MCP tools share one
              // wording, sourced from the enum's own doc comments.
              title: Text(group.label),
              subtitle: Text(group.description),
              value: draft.contains(group),
              onChanged: (ticked) => setState(() {
                if (ticked ?? false) {
                  draft.add(group);
                } else {
                  draft.remove(group);
                }
                // The refusal described the *previous* attempt. Clearing it on
                // the next tick keeps it from reading as a verdict on what is
                // on screen now.
                _refusal = null;
              }),
            ),
          // Which pages this role sees. Under the groups because groups say
          // what the role may *do* and this says what it may *reach*, and the
          // second only ever narrows the first.
          AccessPagesEditor(
            level: AccessPagesLevel.role,
            owner: role.name,
            selection: _pagesDraft,
            onChanged: (next) => setState(() {
              _pagesDraft = next;
              _pagesTouched = true;
              _refusal = null;
            }),
          ),
          if (refusal != null) ...[
            const SizedBox(height: 8),
            // The exception goes straight to the shared widget; this file
            // builds no sentence of its own, which is what keeps this
            // section's wording and the users section's identical.
            AccessAdminRefusal.lastUsersHolder(refusal),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: kAccessRoleCancelKey(role.name),
                onPressed: _toggle,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: kAccessRoleSaveKey(role.name),
                onPressed: () => _save(draft),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Writes the draft as one `role.update`, after the second half of the
  /// `Operator` warning.
  ///
  /// The confirmation fires only when the protected row is **gaining** groups.
  /// A save that only removes them still shows the banner and needs no dialog:
  /// narrowing is the safe direction, and a confirmation on every save is a
  /// confirmation nobody reads. That is a judgement, not an omission.
  Future<void> _save(Set<AccessGroup> draft) async {
    if (_saving) return;

    if (_protected) {
      final added = [
        for (final group in AccessGroup.values)
          if (draft.contains(group) && !role.groups.contains(group)) group,
      ];
      if (added.isNotEmpty) {
        // Warning two of two. Not `destructive: true` — nothing is being
        // deleted — so it keeps the default icon.
        final confirmed = await showConfirmDialog(
          context: context,
          title: kAccessOperatorConfirmTitle,
          message: kAccessOperatorConfirmMessage(added),
          confirmLabel: kAccessOperatorConfirmLabel,
        );
        if (!confirmed || !mounted) return;
      }
    }

    _saving = true;

    // Two writes at most, each its own audit row: `role.update` for the
    // groups and `role.pages` for the whitelist. Deliberately not one — they
    // answer different filters in the trail, and `upsertRole` writes groups
    // only precisely so that a stale value object cannot reset a whitelist.
    //
    // The pages write is issued only when the operator actually touched the
    // block. Issuing it unconditionally would write a `role.pages` row on
    // every group edit, with the same value on both sides.
    final pagesChanged = _pagesTouched && !_samePages(_pagesDraft, role.allowedPages);
    final groupsChanged = !const SetEquality<AccessGroup>().equals(draft, role.groups);

    if (!groupsChanged && !pagesChanged) {
      _saving = false;
      if (mounted) setState(() => _draft = null);
      return;
    }

    if (pagesChanged && !groupsChanged) {
      final wrotePages = await _write(
        context,
        ref,
        () => store.setRolePages(role.name, _pagesDraft),
      );
      _saving = false;
      if (!wrotePages) return;
      if (mounted) {
        setState(() {
          _draft = null;
          _pagesTouched = false;
          _refusal = null;
        });
      }
      await _afterWrite(ref);
      return;
    }

    final wrote = await _write(
      context,
      ref,
      () => store.updateRole(
          AccessRole(name: role.name, groups: draft, seeded: role.seeded)),
      onRefused: (refusal) {
        // Inline, in place of a snackbar, with the boxes left as the operator
        // left them so they can see what they tried. This `setState` runs
        // before any refresh — see [_afterWrite] for why that ordering is the
        // rule rather than an accident.
        if (refusal is LastUsersHolderException && mounted) {
          setState(() => _refusal = refusal);
        }
      },
    );
    if (!wrote) {
      _saving = false;
      return;
    }

    // The groups landed; the pages follow, as their own row. If this one is
    // refused the groups edit still stands — which is honest, because it did.
    if (pagesChanged && mounted) {
      await _write(context, ref, () => store.setRolePages(role.name, _pagesDraft));
    }
    _saving = false;

    // Everything that needs this widget happens first…
    if (mounted) {
      setState(() {
        _draft = null;
        _pagesTouched = false;
        _refusal = null;
      });
    }
    // …and the session refresh last, because it can unmount this subtree.
    await _afterWrite(ref);
  }

  /// Null (no whitelist) and the empty set (block all) are different answers
  /// and must not compare equal — the comparison Save uses to decide whether
  /// there is a `role.pages` write to make at all.
  static bool _samePages(Set<String>? a, Set<String>? b) {
    if (a == null || b == null) return a == null && b == null;
    return const SetEquality<String>().equals(a, b);
  }

  Future<void> _rename() async {
    final to = await showDialog<String>(
      context: context,
      builder: (_) => _RoleNameDialog(
        title: 'Rename role',
        confirmLabel: 'Rename',
        initial: role.name,
        taken: widget.otherNames.toSet(),
      ),
    );
    if (to == null || to == role.name || !mounted) return;
    final wrote =
        await _write(context, ref, () => store.renameRole(role.name, to));
    if (wrote) await _afterWrite(ref);
  }

  Future<void> _delete() async {
    final deleted = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteRoleDialog(name: role.name, store: store),
    );
    // The dialog performs the delete itself, because it is the only widget
    // that can re-render with the newer data a losing race hands back. All the
    // caller owes is the refresh — and the invalidate, which the dialog's own
    // path does not run because it holds no `ref`.
    if (deleted != true) return;
    // Everything that needs this widget happens first…
    ref.invalidate(accessAdminRolesProvider);
    ref.invalidate(accessAdminUsersProvider);
    // …and the session refresh last. See [_afterWrite].
    await _afterWrite(ref);
  }
}

// ---------------------------------------------------------------------------
// The write path
// ---------------------------------------------------------------------------

/// Runs one store write and refreshes both lists.
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
/// points back to, and a second variant is a second behaviour.
///
/// ## The two refusal arms above `on Object`
///
/// [LastUsersHolderException] and [RoleInUseException] are neither
/// `AccessDenied` nor ordinary failures. No sign-in resolves either — the
/// account that hits the first already holds `users`, and an Engineering user
/// holding every group gets the second — so they must not reach the shared
/// prompt, and a snackbar would put the holders' names in something that
/// disappears while they are being read. [onRefused] hands the exception to
/// whichever widget can render it beside the control that caused it; a caller
/// that has nowhere to put it falls back to [_showProblem], which is still
/// better than silence.
Future<bool> _write(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() write, {
  void Function(Object refusal)? onRefused,
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
  } on RoleInUseException catch (refusal) {
    if (onRefused != null) {
      onRefused(refusal);
    } else if (context.mounted) {
      _showProblem(context, refusal);
    }
    return false;
  } on AccessDenied {
    return false;
  } on Object catch (error) {
    // Not an authorization event — a duplicate name that appeared underneath
    // us, a database that went away mid-write. The operator gets the reason
    // rather than a control that did nothing.
    if (context.mounted) _showProblem(context, error);
    return false;
  }
  // There is no listener over `app_role` and nothing else notices. These two
  // invalidates are the single refresh trigger for both lists.
  ref.invalidate(accessAdminRolesProvider);
  ref.invalidate(accessAdminUsersProvider);
  return true;
}

/// Re-resolves the session in force against the rows that were just written.
///
/// **This is the last thing any write path does, and the ordering is the rule.**
///
/// Invalidate the lists, close whatever dialog is open and finish every
/// `setState` **before** awaiting this; guard anything that must happen after
/// it with `context.mounted`. The reason is that this section can unmount
/// itself mid-await: unticking `users` from the role the signed-in person holds
/// is *permitted* whenever a second granting role still has a holder — only the
/// last-holder case throws — so the refresh drops the caller below the `users`
/// gate while this widget is still inside its own async callback. The page is
/// `users`-gated, so `AccessGate` swaps the subtree out and the section is
/// disposed; a `ref.invalidate`, a `setState` or a `ScaffoldMessenger` call
/// sequenced after this would then run on a disposed element.
///
/// Doing it **last** makes the unmount a non-event: everything that needed the
/// widget has already happened, and the one thing left is the session drop,
/// which is the point of the call. Nothing in this file touches `ref` or
/// `context` after awaiting it.
///
/// It is called after **all four** role writes — the section's create, and the
/// row's save, rename and delete — and is never inside an "is this my own
/// role?" conditional. Such a conditional would make the exception go away by
/// not making the call, and the call is the only thing that stops an admin who
/// has just narrowed their own role from keeping the groups they removed.
///
/// The notifier is read synchronously, before the await, so a caller that is
/// disposed by the refresh never reaches back into `ref`.
Future<void> _afterWrite(WidgetRef ref) {
  final controller = ref.read(accessSessionProvider.notifier);
  return controller.refreshGroupsFromRoles();
}

void _showProblem(BuildContext context, Object error) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(content: Text('$error')));
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/// Create and rename: a name, validated before the store is asked.
///
/// The two share one widget because they differ in exactly two things — the
/// starting text and the title — following `_TemplateNameDialog`'s stated
/// reason: two nearly identical dialogs is how two validation rules start
/// disagreeing.
class _RoleNameDialog extends StatefulWidget {
  const _RoleNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.taken,
    this.footnote,
  });

  final String title;
  final String confirmLabel;
  final String initial;

  /// Names already in use, from the loaded list. The duplicate is refused
  /// **here**, before the store is called: an exception surfaced as a snackbar
  /// after the dialog closed would make the operator retype the whole thing.
  final Set<String> taken;

  final String? footnote;

  @override
  State<_RoleNameDialog> createState() => _RoleNameDialogState();
}

class _RoleNameDialogState extends State<_RoleNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _controller.text;
    // Validation before the gate, for the reason the store checks the name
    // after it: a typo is not an authorization event, and putting a sign-in
    // prompt in front of one would teach the operator to ignore the prompt.
    if (name.trim().isEmpty || name.trim() != name || name.length > 64) {
      setState(() => _error = kAccessRoleInvalidNameNote);
      return;
    }
    if (isProtectedRoleName(name)) {
      setState(() => _error = kAccessRoleProtectedNameNote);
      return;
    }
    if (widget.taken.contains(name)) {
      setState(() => _error = kAccessRoleDuplicateNameNote);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return StandardDialogFrame(
      title: widget.title,
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: widget.confirmLabel,
          buttonKey: kAccessRoleNameConfirmKey,
          onPressed: _confirm,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: kAccessRoleNameFieldKey,
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _error,
              errorMaxLines: 4,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _confirm(),
          ),
          if (widget.footnote != null) ...[
            const SizedBox(height: 12),
            _note(context, widget.footnote!),
          ],
        ],
      ),
    );
  }
}

/// Why a role cannot be deleted, as one value.
///
/// One value rather than two booleans: two booleans can both be true and then
/// the dialog has to choose a wording, which is exactly the drift this avoids.
/// The names are the reasons, not the UI consequence — a value called `blocked`
/// tells the next reader nothing about which sentence to expect.
///
/// [notYetAsked] and [unreadable] are different states and neither of them is
/// [nothingInTheWay]: "the question has not come back" and "the question could
/// not be asked" must never render as "nobody holds it".
enum _RoleDeleteBlock {
  /// The two reads are still in flight.
  notYetAsked,

  /// A read failed, so nothing is known.
  unreadable,

  /// Nobody holds it and the invariant survives without it.
  nothingInTheWay,

  /// Accounts still hold it — `RoleInUseException`'s condition.
  accountsStillHoldIt,

  /// Deleting it would leave nobody able to manage roles and accounts —
  /// `LastUsersHolderException`'s condition, trip route (d).
  wouldLeaveNobodyManagingAccess,
}

/// Delete: who holds it **first**, and no confirming action while anything is
/// in the way.
///
/// ## Why the action is absent rather than present-and-refusing
///
/// This is the one exception in this milestone to "never greyed", and it needs
/// its reason in writing. Quoting `_DeleteTemplateDialog`, whose doc argues it
/// at length: the "never greyed" rule exists so that a **permission** refusal
/// is explained rather than hidden — an operator who cannot do something must
/// still see the control, press it, and be told which permission to go and get.
/// Neither block here is a permission refusal. `RoleInUseException` and
/// `LastUsersHolderException` are separate types from `AccessDenied` for
/// exactly this reason, and an Engineering user holding every group including
/// `users` gets both. No sign-in resolves either, nothing the operator can be
/// told to fetch resolves either, and a control that is present and always
/// refuses teaches the operator to press it twice. So the holders and the
/// instruction take the action's place.
///
/// ## The question, and why it is asked here rather than added to the store
///
/// Both answers come from the store's two existing reads. The holders are the
/// accounts whose role is this one; the lockout is "after this role is gone,
/// does any remaining account still hold a role granting `users`". No new store
/// method: the repository's in-transaction guard is still the authority and
/// this is a **pre-check that can lose a race**, which is what [_delete]'s two
/// refusal arms are for. Adding a store method for it would look like a second
/// copy of the rule, and two copies of a rule is how one copy gets edited
/// alone.
///
/// ## No override, anywhere
///
/// No typed-confirmation field, no control that deletes it regardless, and no
/// offer to move the holders somewhere and then delete. 06-CONTEXT's deferred
/// list rejects the first and the last by name. The dialog says what the state
/// is; the users section is on the same page.
class _DeleteRoleDialog extends StatefulWidget {
  const _DeleteRoleDialog({required this.name, required this.store});

  final String name;
  final AccessAdminStore store;

  @override
  State<_DeleteRoleDialog> createState() => _DeleteRoleDialogState();
}

class _DeleteRoleDialogState extends State<_DeleteRoleDialog> {
  /// The one state value. Starts at "the question has not come back".
  _RoleDeleteBlock _block = _RoleDeleteBlock.notYetAsked;

  /// The refusal the block would produce, built by the pre-check or handed over
  /// by a losing race. Rendering it through [AccessAdminRefusal] rather than
  /// building a sentence here is what keeps this section's wording and the
  /// users section's identical.
  RoleInUseException? _inUse;
  LastUsersHolderException? _lockout;

  /// Re-entry guard. Deliberately not rendered as a disabled button: a control
  /// this file draws is never greyed, and a second tap during the round trip is
  /// simply ignored.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Asks both questions together and lands on exactly one state.
  ///
  /// Awaited together rather than one after the other, so a half-answered
  /// dialog cannot render as unblocked; a failure of either lands on
  /// [_RoleDeleteBlock.unreadable].
  Future<void> _load() async {
    try {
      final roles = await widget.store.roles();
      final users = await widget.store.listUsers();
      if (!mounted) return;
      setState(() => _decide(roles, [
            for (final user in users) (user.username, user.roleName),
          ]));
    } on Object {
      // "Cannot tell" must not read as "nobody holds it".
      if (mounted) setState(() => _block = _RoleDeleteBlock.unreadable);
    }
  }

  /// The pre-check, in the repository's own order.
  ///
  /// 06-02 documents it: the lockout check runs **before** the holders check,
  /// because moving holders off a role is a fix the operator can perform and a
  /// plant with nobody able to manage roles has no fix inside the application
  /// at all. Both reasons can be true at once; this order decides which
  /// sentence the operator reads, and it is the sentence the repository would
  /// have produced.
  void _decide(List<AccessRole> roles, List<(String, String)> users) {
    final granting = {
      for (final role in roles)
        if (role.groups.contains(AccessGroup.users)) role.name,
    };
    final roleOf = {for (final user in users) user.$1: user.$2};

    final holdersOfUsers = [
      for (final entry in roleOf.entries)
        if (granting.contains(entry.value)) entry.key,
    ]..sort();

    // The guard stands aside when there is no holder to begin with: a freshly
    // seeded station has roles and no accounts, and a rule that fired there
    // would make a station unconfigurable out of the box.
    if (holdersOfUsers.isNotEmpty) {
      final after = {...granting}..remove(widget.name);
      if (!roleOf.values.any(after.contains)) {
        _lockout = LastUsersHolderException(
          roleOf[holdersOfUsers.first]!,
          holdersOfUsers,
        );
        _block = _RoleDeleteBlock.wouldLeaveNobodyManagingAccess;
        return;
      }
    }

    final holders = [
      for (final entry in roleOf.entries)
        if (entry.value == widget.name) entry.key,
    ]..sort();
    if (holders.isNotEmpty) {
      _inUse = RoleInUseException(widget.name, holders);
      _block = _RoleDeleteBlock.accountsStillHoldIt;
      return;
    }

    _block = _RoleDeleteBlock.nothingInTheWay;
  }

  Future<void> _delete() async {
    if (_busy) return;
    _busy = true;
    try {
      await widget.store.deleteRole(widget.name);
      if (mounted) Navigator.of(context).pop(true);
    } on LastUsersHolderException catch (refusal) {
      // The losing race. Something changed between the question and the
      // statement, and the repository has just proved a truer answer — so the
      // same dialog re-renders with it rather than raising an error about a
      // failed operation.
      if (mounted) {
        setState(() {
          _lockout = refusal;
          _block = _RoleDeleteBlock.wouldLeaveNobodyManagingAccess;
        });
      }
    } on RoleInUseException catch (refusal) {
      if (mounted) {
        setState(() {
          _inUse = refusal;
          _block = _RoleDeleteBlock.accountsStillHoldIt;
        });
      }
    } on AccessDenied {
      // See the note at [_write]. The dialog stays open on purpose: the
      // operator can sign in from the shared prompt and press Delete again.
    } on Object catch (error) {
      if (mounted) _showProblem(context, error);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _block != _RoleDeleteBlock.nothingInTheWay;
    return StandardDialogFrame(
      title: 'Delete "${widget.name}"',
      icon: Icons.warning_amber,
      showClose: false,
      actions: [
        PaneAction(
          label: blocked ? 'Close' : 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        // Absent, not greyed. See the class doc.
        if (!blocked)
          PaneAction.destructive(
            label: 'Delete',
            buttonKey: kAccessRoleDeleteConfirmKey,
            onPressed: _delete,
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    switch (_block) {
      case _RoleDeleteBlock.notYetAsked:
        return _note(context, kAccessRoleDeleteCheckingNote,
            key: kAccessRoleDeleteCheckingKey);
      case _RoleDeleteBlock.unreadable:
        return _note(context, kAccessRoleDeleteUnknownNote,
            key: kAccessRoleDeleteUnknownKey);
      case _RoleDeleteBlock.nothingInTheWay:
        return _note(context, kAccessRoleDeleteFreeNote(widget.name),
            key: kAccessRoleDeleteFreeKey);
      // The exception goes straight to the shared widget; this dialog builds no
      // sentence of its own, which is what keeps the two sections identical.
      case _RoleDeleteBlock.accountsStillHoldIt:
        return AccessAdminRefusal.roleInUse(_inUse!);
      case _RoleDeleteBlock.wouldLeaveNobodyManagingAccess:
        return AccessAdminRefusal.lastUsersHolder(_lockout!);
    }
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
