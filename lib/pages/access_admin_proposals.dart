/// Where an agent's account and role proposals are approved.
///
/// `packages/tfc_mcp_server`'s account tools emit proposals — `access_account`
/// and `access_role` — and change nothing. This section is where a person
/// applies them, and it is the third instance of the pattern
/// `access_templates_section.dart` set for templates: stage every pending
/// proposal of the type once there is a store to apply it into, hand the
/// banner one Accept for the batch, and apply each through the **same
/// `users`-gated store the page's own controls use**, so that
///
///  * an approver without `users` is refused and the refusal is recorded,
///  * every row carries `origin: 'mcp'`, so an agent's change is never
///    indistinguishable from a hand-made one,
///  * the row's `who` is the approving human, from the live session; the
///    proposal's own `operator_id` is never read.
///
/// ## The password is typed here, and only here
///
/// Two proposals need a credential to land — creating an account and
/// resetting a password — and neither carries one: tool arguments are written
/// to the MCP audit table and the proposal JSON is shown on the banner, so a
/// password in a proposal would be a password in a database and on a screen.
/// So Accept on one of those opens [_ProposalCredentialDialog], which is the
/// accounts screen's own set-password dialog in shape and in rules: the
/// password lives in a controller, goes to the store, and is never logged,
/// rendered or put in a `reason`. A failure there shows a fixed sentence, as
/// `access_users_section.dart`'s file doc requires of any screen with a
/// credential in hand. Cancelling the dialog leaves that proposal pending and
/// applies the rest of the batch.
///
/// ## The refusals are the store's
///
/// The last-`users`-holder rule, the in-use role block and the anonymous
/// account's protections are decided inside the repository's transaction at
/// the accept, exactly as for a hand-made edit. The MCP tools predicted them
/// in the proposal's `warnings`; this section renders what actually happened.
/// A refused proposal stays pending — the sweep is a list of independent
/// changes, and failing four because one is blocked would be the wrong
/// answer to the wrong question.
///
/// ## A user write is not finished when the row is written
///
/// `refreshGroupsFromRoles` is called **last**, after the lists are
/// invalidated and the batch is replaced, because it can drop the approver
/// below the `users` gate — they may have just narrowed their own role — and
/// the gate then swaps this subtree out. Nothing in this file touches `ref`
/// or `context` after awaiting it. See `_afterWrite` in
/// `access_users_section.dart` for the full argument.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';

import '../core/access_admin_store.dart';
import '../providers/access.dart';
import '../providers/access_admin.dart';
import '../providers/proposal_state.dart';
import '../widgets/panes/pane_chrome.dart';
import '../widgets/panes/standard_dialog.dart';
import 'access_users_section.dart'
    show
        kAccessUserBlankPasswordNote,
        kAccessUserCreateFailedNote,
        kAccessUserDuplicateNote,
        kAccessUserMismatchNote,
        kAccessUserSetPasswordFailedNote,
        kAccessUserSetPasswordNoteFor;

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

/// The `AuditRecord.origin` every row applied from an accepted proposal
/// carries. The only thing this file tells the store about provenance.
const String kAccessAdminMcpOrigin = 'mcp';

/// The card's title.
const String kAccessAdminProposalsHeadline = 'Proposed over MCP';

/// One line under the title: what the card is and where the button is.
const String kAccessAdminProposalsSubtitle =
    'An agent proposed these changes. Accept or reject them in the banner; '
    'nothing is applied until you do, and each one is checked against your '
    'session and recorded as yours.';

/// Appended when at least one staged proposal will ask for a password.
const String kAccessAdminProposalsPasswordNote =
    'Creating an account or resetting a password asks you to type the '
    'password here when you accept — it is never part of a proposal.';

/// The proposal could not be applied for a reason that is not a permission
/// refusal — the store threw one of its named exceptions, or the database
/// went away mid-write. The message is the exception's own, which for every
/// exception the store throws names the account or role and never a
/// credential.
String kAccessAdminProposalFailedNote(Object error) =>
    'A proposal could not be applied and is still pending: $error';

/// Accept was pressed for a proposal that needs a password while the access
/// screen was not on screen to ask for one.
const String kAccessAdminProposalNeedsPanelNote =
    'This proposal needs a password typed at the panel. Open the Access '
    'screen and press Accept there.';

/// The credential dialog's title for a create.
String kAccessAdminProposalCreateTitle(String username) =>
    'Password for new account "$username"';

/// The credential dialog's affirmative for a create.
const String kAccessAdminProposalCreateLabel = 'Create account';

/// The credential dialog's title for a reset.
String kAccessAdminProposalResetTitle(String username) =>
    'New password for "$username"';

/// The credential dialog's affirmative for a reset.
const String kAccessAdminProposalResetLabel = 'Set password';

/// Above the fields on a create: what the account will hold.
String kAccessAdminProposalCreateNote(List<String> roles, bool station) =>
    'Proposed over MCP: an account holding ${roleLabelFor(roles)}'
    '${station ? ', as a station account whose sessions never expire' : ''}. '
    'Type its password to create it. The password is not in the proposal and '
    'is not recorded anywhere but the account.';

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/// The card, so a test can tell "nothing staged" from "rendered nothing".
const Key kAccessAdminProposalsKey = Key('access-admin-proposals');

/// The credential dialog's two fields and two actions.
const Key kAccessAdminProposalPasswordFieldKey =
    Key('access-admin-proposal-password');
const Key kAccessAdminProposalConfirmFieldKey =
    Key('access-admin-proposal-confirm');
const Key kAccessAdminProposalSubmitKey = Key('access-admin-proposal-submit');
const Key kAccessAdminProposalCancelKey = Key('access-admin-proposal-cancel');

/// The problem line in the credential dialog.
const Key kAccessAdminProposalProblemKey =
    Key('access-admin-proposal-problem');

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

/// The staged batch of account and role proposals, and the Accept that
/// applies it.
///
/// Renders nothing at all when nothing is staged — it is one card on a page
/// somebody came to for something else, and an empty "proposals" card on
/// every station would be noise. When something is staged it lists each
/// change in words, with the tool's own warnings beneath, so the person can
/// read what Accept will do before pressing it in the banner.
class AccessAdminProposalsSection extends ConsumerStatefulWidget {
  const AccessAdminProposalsSection({super.key});

  @override
  ConsumerState<AccessAdminProposalsSection> createState() =>
      _AccessAdminProposalsSectionState();
}

class _AccessAdminProposalsSectionState
    extends ConsumerState<AccessAdminProposalsSection> {
  /// The staged proposals, decoded, and their ids, in step.
  final List<Map<String, dynamic>> _proposed = [];
  final List<int> _proposalIds = [];

  /// The banner's callback slots, captured when publishing. Held rather than
  /// re-read: riverpod forbids `ref` inside `dispose()`.
  StateController<Future<void> Function()?>? _commitSlot;
  StateController<Future<void> Function()?>? _discardSlot;

  /// The container, taken while this section is alive, so each press reads
  /// today's store and today's session rather than the ones current when the
  /// proposal was staged — the session is what the gate reads.
  ProviderContainer? _container;

  /// Context-derived handles, for a path that may outlive the page.
  ScaffoldMessengerState? _messengerHandle;
  Color? _errorColourHandle;

  /// Where the credential dialog opens. Null, or unmounted, means the page is
  /// gone and a proposal that needs a password has to wait for it.
  NavigatorState? _navigatorHandle;

  ScaffoldMessengerState? get _messenger =>
      _messengerHandle ?? (mounted ? ScaffoldMessenger.maybeOf(context) : null);

  Color? get _errorColour =>
      _errorColourHandle ??
      (mounted ? Theme.of(context).colorScheme.error : null);

  void _report(String message, {bool error = true}) {
    _messenger?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? _errorColour : null,
    ));
  }

  @override
  void dispose() {
    final commitSlot = _commitSlot;
    final discardSlot = _discardSlot;
    final commit = _commitProposals;
    final discard = _discardProposals;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (commitSlot != null &&
          commitSlot.mounted &&
          commitSlot.state == commit) {
        commitSlot.state = null;
      }
      if (discardSlot != null &&
          discardSlot.mounted &&
          discardSlot.state == discard) {
        discardSlot.state = null;
      }
    });
    super.dispose();
  }

  /// Stages every pending account or role proposal, once there is a store to
  /// apply them into. Safe to re-enter; returns how many were newly staged.
  int _stageProposals(AccessAdminStore? store) {
    if (store == null) return 0;
    var added = 0;
    try {
      final state = ref.read(proposalStateProvider);
      for (final p in state.proposals) {
        if (p.proposalType != 'access_account' &&
            p.proposalType != 'access_role') {
          continue;
        }
        if (_proposalIds.contains(p.id)) continue;
        final decoded = _decodeProposal(p.proposalJson);
        if (decoded == null) continue;
        _proposed.add(decoded);
        _proposalIds.add(p.id);
        added++;
      }
    } on Object {
      return added;
    }
    if (added > 0) _publishProposalCallbacks();
    return added;
  }

  /// The proposal JSON, or null when it is not one this section can apply.
  /// Ignored rather than reported: one bad entry must not take the batch.
  static Map<String, dynamic>? _decodeProposal(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final type = decoded['_proposal_type'];
      final op = decoded['_op'];
      if (type == 'access_account') {
        if (decoded['username'] is! String) return null;
        return switch (op) {
          'create' => decoded['roles'] is List ? decoded : null,
          'delete' => decoded,
          'update' => switch (decoded['field']) {
              'roles' => decoded['roles'] is List ? decoded : null,
              'station_account' =>
                decoded['station_account'] is bool ? decoded : null,
              'password' => decoded,
              _ => null,
            },
          _ => null,
        };
      }
      if (type == 'access_role') {
        if (decoded['name'] is! String) return null;
        return switch (op) {
          'create' || 'update' => decoded['groups'] is List ? decoded : null,
          'rename' => decoded['new_name'] is String ? decoded : null,
          'delete' => decoded,
          _ => null,
        };
      }
      return null;
    } on Object {
      return null;
    }
  }

  void _publishProposalCallbacks() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final commitSlot = ref.read(proposalCommitProvider.notifier);
      commitSlot.state = _commitProposals;
      _commitSlot = commitSlot;
      final discardSlot = ref.read(proposalDiscardProvider.notifier);
      discardSlot.state = _discardProposals;
      _discardSlot = discardSlot;
      _container = ProviderScope.containerOf(context, listen: false);
      _messengerHandle = ScaffoldMessenger.maybeOf(context);
      _errorColourHandle = Theme.of(context).colorScheme.error;
      _navigatorHandle = Navigator.maybeOf(context);
    });
  }

  /// Applies the staged batch through the store, then marks what landed.
  ///
  /// Each proposal keeps its own fate: a refusal leaves **that** one pending
  /// and lets the rest through.
  Future<void> _commitProposals() async {
    final container = _container;
    if (container == null || _proposed.isEmpty) return;

    final AccessAdminStore? store;
    try {
      store = await container.read(accessAdminStoreProvider.future);
    } on Object catch (error) {
      _report(kAccessAdminProposalFailedNote(error));
      return;
    }
    if (store == null) {
      _report(kAccessAdminProposalFailedNote('this station has no database'));
      return;
    }

    final applied = <int>[];
    final keptProposals = <Map<String, dynamic>>[];
    final keptIds = <int>[];
    for (var i = 0; i < _proposed.length; i++) {
      try {
        if (await _applyProposal(store, _proposed[i])) {
          applied.add(_proposalIds[i]);
          continue;
        }
        // Cancelled at the credential dialog, or nowhere to open it: the
        // person decided, or has to come back — either way it stays pending
        // and nothing needs saying twice.
      } on AccessDenied {
        // The store's `onDenied` has already put the shared prompt naming
        // `users` on screen; a message of this file's own would be two
        // things saying one thing.
      } on Object catch (error) {
        // Every exception the store throws — LastUsersHolderException,
        // RoleInUseException, UserExistsException, UserNotFoundException,
        // MissingRoleError, AnonymousAccountError, ReservedUsernameException,
        // the repository's ArgumentErrors — names its subject and carries no
        // credential; the two writes that hold one never reach here, because
        // their dialog renders a fixed sentence and swallows the throw.
        _report(kAccessAdminProposalFailedNote(error));
      }
      keptProposals.add(_proposed[i]);
      keptIds.add(_proposalIds[i]);
    }

    if (applied.isNotEmpty) {
      container.invalidate(accessAdminRolesProvider);
      container.invalidate(accessAdminUsersProvider);
    }

    // Only after the writes have landed: marking a proposal accepted drops it
    // from the queue, so doing it first would lose one whose write failed.
    final notifier = container.read(proposalStateProvider.notifier);
    var unmarked = 0;
    for (final id in applied) {
      try {
        await notifier.acceptProposal(id);
      } on Object {
        unmarked++;
      }
    }
    if (unmarked > 0) {
      _report('$unmarked change(s) were applied but could not be marked '
          'accepted. They are done; the banner may still list them.');
    }

    _replaceBatch(keptProposals, keptIds);

    // Last, and nothing after it — see the library doc.
    if (applied.isNotEmpty) {
      final session = container.read(accessSessionProvider.notifier);
      await session.refreshGroupsFromRoles();
    }
  }

  /// Drops the whole batch without touching either table.
  Future<void> _discardProposals() async {
    final container = _container;
    if (container == null) return;
    final notifier = container.read(proposalStateProvider.notifier);
    var failed = 0;
    for (final id in _proposalIds) {
      try {
        await notifier.rejectProposal(id);
      } on Object {
        failed++;
      }
    }
    if (failed > 0) {
      _report('$failed of ${_proposalIds.length} proposals could not be '
          'marked rejected. Press Reject again.');
    }
    _replaceBatch(const [], const []);
  }

  void _replaceBatch(List<Map<String, dynamic>> proposals, List<int> ids) {
    _proposed
      ..clear()
      ..addAll(proposals);
    _proposalIds
      ..clear()
      ..addAll(ids);
    if (_proposed.isEmpty) {
      _commitSlot?.state = null;
      _discardSlot?.state = null;
    }
    if (mounted) setState(() {});
  }

  /// One proposal, through the one store, with `origin: 'mcp'`.
  ///
  /// Returns false when the proposal was not applied and nothing needs
  /// reporting: the person cancelled the credential dialog, or there was no
  /// panel to open it on. Throws whatever the store throws otherwise.
  Future<bool> _applyProposal(
      AccessAdminStore store, Map<String, dynamic> proposal) async {
    final reason =
        proposal['reason'] is String ? proposal['reason'] as String : null;
    final type = proposal['_proposal_type'];
    final op = proposal['_op'];

    if (type == 'access_account') {
      final username = proposal['username'] as String;
      switch (op) {
        case 'create':
          final roles = _strings(proposal['roles']);
          final station = proposal['station_account'] == true;
          final created = await _withCredential(_CredentialRequest.create(
            username: username,
            roles: roles,
            station: station,
            store: store,
            reason: reason,
          ));
          if (!created) return false;
          if (station) {
            await store.setUserStationAccount(username, true,
                origin: kAccessAdminMcpOrigin, reason: reason);
          }
          return true;
        case 'delete':
          await store.deleteUser(username,
              origin: kAccessAdminMcpOrigin, reason: reason);
          return true;
        case 'update':
          switch (proposal['field']) {
            case 'roles':
              await store.setUserRoles(username, _strings(proposal['roles']),
                  origin: kAccessAdminMcpOrigin, reason: reason);
              return true;
            case 'station_account':
              await store.setUserStationAccount(
                  username, proposal['station_account'] as bool,
                  origin: kAccessAdminMcpOrigin, reason: reason);
              return true;
            case 'password':
              return _withCredential(_CredentialRequest.reset(
                username: username,
                store: store,
                reason: reason,
                stationAccount:
                    await _isStationAccount(store, username),
              ));
          }
      }
    } else if (type == 'access_role') {
      final name = proposal['name'] as String;
      switch (op) {
        case 'create':
          await store.createRole(
              AccessRole(name: name, groups: _groups(proposal['groups'])),
              origin: kAccessAdminMcpOrigin,
              reason: reason);
          return true;
        case 'update':
          await store.updateRole(
              AccessRole(name: name, groups: _groups(proposal['groups'])),
              origin: kAccessAdminMcpOrigin,
              reason: reason);
          return true;
        case 'rename':
          await store.renameRole(name, proposal['new_name'] as String,
              origin: kAccessAdminMcpOrigin, reason: reason);
          return true;
        case 'delete':
          await store.deleteRole(name,
              origin: kAccessAdminMcpOrigin, reason: reason);
          return true;
      }
    }
    // Unreachable: `_decodeProposal` refuses anything else.
    return false;
  }

  /// Whether [username] is a panel account, for the reset dialog's note.
  /// A read, unaudited; false when the roster cannot be read.
  static Future<bool> _isStationAccount(
      AccessAdminStore store, String username) async {
    try {
      final rows = await store.listUsers();
      for (final row in rows) {
        if (row.username == username) return row.stationAccount;
      }
    } on Object {
      // The write itself will say what is wrong; the note is cosmetic.
    }
    return false;
  }

  /// Opens the credential dialog for [request] and returns whether the write
  /// landed. False for cancel, and for a page that is not there to ask on.
  Future<bool> _withCredential(_CredentialRequest request) async {
    final navigator = _navigatorHandle;
    if (navigator == null || !navigator.mounted) {
      _report(kAccessAdminProposalNeedsPanelNote);
      return false;
    }
    final result = await showDialog<bool>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => _ProposalCredentialDialog(request: request),
    );
    return result == true;
  }

  static List<String> _strings(Object? raw) =>
      [for (final e in (raw as List? ?? const [])) if (e is String) e];

  /// Decoded the forgiving way the store reads rows: a name this build does
  /// not know costs that group, not the proposal.
  static Set<AccessGroup> _groups(Object? raw) =>
      AccessRole.decodeGroups(jsonEncode(_strings(raw)));

  /// One staged proposal, in words.
  static String describe(Map<String, dynamic> p) {
    final type = p['_proposal_type'];
    final op = p['_op'];
    if (type == 'access_account') {
      final u = p['username'];
      switch (op) {
        case 'create':
          return 'Create account "$u" holding '
              '${roleLabelFor(_strings(p['roles']))}'
              '${p['station_account'] == true ? ', as a station account' : ''}'
              '. You will be asked to type its password.';
        case 'delete':
          return 'Delete account "$u".';
        case 'update':
          switch (p['field']) {
            case 'roles':
              return 'Set the roles of "$u" to '
                  '${roleLabelFor(_strings(p['roles']))}'
                  '${u == kAnonymousUsername ? ' — this is every logged-out panel' : ''}.';
            case 'station_account':
              return p['station_account'] == true
                  ? 'Make "$u" a station account whose sessions never expire.'
                  : 'Make "$u" a person again, whose sessions expire.';
            case 'password':
              return 'Reset the password of "$u". You will be asked to type '
                  'the new one.';
          }
      }
    } else if (type == 'access_role') {
      final n = p['name'];
      switch (op) {
        case 'create':
          return 'Create role "$n" granting ${_strings(p['groups']).join(', ')}.';
        case 'update':
          return 'Set the groups of "$n" to '
              '${_strings(p['groups']).join(', ')}.';
        case 'rename':
          return 'Rename role "$n" to "${p['new_name']}".';
        case 'delete':
          return 'Delete role "$n".';
      }
    }
    return 'A proposal this build cannot describe.';
  }

  /// Whether [p] will open the credential dialog on Accept.
  static bool asksForPassword(Map<String, dynamic> p) =>
      p['_proposal_type'] == 'access_account' &&
      (p['_op'] == 'create' ||
          (p['_op'] == 'update' && p['field'] == 'password'));

  @override
  Widget build(BuildContext context) {
    final storeAsync = ref.watch(accessAdminStoreProvider);

    // A proposal arriving while this page is open joins the batch.
    ref.listen<ProposalState>(proposalStateProvider, (previous, next) {
      if (_stageProposals(storeAsync.valueOrNull) > 0) setState(() {});
    });
    // From build rather than initState: there is nothing to apply into until
    // the store has resolved, a frame or more after this section appears.
    _stageProposals(storeAsync.valueOrNull);

    if (_proposed.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final wantsPassword = _proposed.any(asksForPassword);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: kAccessAdminProposalsKey,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(kAccessAdminProposalsHeadline,
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                kAccessAdminProposalsSubtitle,
                maxLines: null,
                overflow: TextOverflow.visible,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (wantsPassword) ...[
                const SizedBox(height: 4),
                Text(
                  kAccessAdminProposalsPasswordNote,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              for (final p in _proposed) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch (p['_op']) {
                        'create' => Icons.add,
                        'delete' => Icons.delete_outline,
                        _ => Icons.edit_outlined,
                      },
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(describe(p),
                          maxLines: null, overflow: TextOverflow.visible),
                    ),
                  ],
                ),
                for (final warning in _strings(p['warnings']))
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text(
                      warning,
                      maxLines: null,
                      overflow: TextOverflow.visible,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The credential dialog
// ---------------------------------------------------------------------------

/// What the credential dialog is being asked to do. Carries everything but
/// the password, which is typed into the dialog and goes to the store from
/// there.
class _CredentialRequest {
  const _CredentialRequest._({
    required this.username,
    required this.store,
    required this.reason,
    required this.stationAccount,
    this.roles,
  });

  factory _CredentialRequest.create({
    required String username,
    required List<String> roles,
    required bool station,
    required AccessAdminStore store,
    required String? reason,
  }) =>
      _CredentialRequest._(
        username: username,
        store: store,
        reason: reason,
        stationAccount: station,
        roles: roles,
      );

  factory _CredentialRequest.reset({
    required String username,
    required AccessAdminStore store,
    required String? reason,
    required bool stationAccount,
  }) =>
      _CredentialRequest._(
        username: username,
        store: store,
        reason: reason,
        stationAccount: stationAccount,
      );

  final String username;
  final AccessAdminStore store;
  final String? reason;
  final bool stationAccount;

  /// Non-null for a create: the roles the account will hold, primary first.
  final List<String>? roles;

  bool get isCreate => roles != null;
}

enum _Problem { blank, mismatch, duplicate, failed, missingRole }

/// A password typed twice, for an account an agent proposed.
///
/// The accounts screen's own set-password dialog in every rule that matters:
/// the password lives in a controller and goes to the store; nothing here
/// logs, renders or forwards it; a failure is a fixed sentence and the
/// exception goes to `Logger().e`. Pops `true` when the write landed, and
/// nothing on Cancel.
class _ProposalCredentialDialog extends StatefulWidget {
  const _ProposalCredentialDialog({required this.request});

  final _CredentialRequest request;

  @override
  State<_ProposalCredentialDialog> createState() =>
      _ProposalCredentialDialogState();
}

class _ProposalCredentialDialogState extends State<_ProposalCredentialDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  _Problem? _problem;
  String _missingRole = '';
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
      setState(() => _problem = _Problem.blank);
      return;
    }
    if (password != _confirm.text) {
      setState(() => _problem = _Problem.mismatch);
      return;
    }
    setState(() {
      _problem = null;
      _submitting = true;
    });

    final request = widget.request;
    try {
      if (request.isCreate) {
        final roles = request.roles!;
        await request.store.createUser(
          username: request.username,
          password: password,
          roleName: roles.first,
          additionalRoles: roles.skip(1).toList(),
          origin: kAccessAdminMcpOrigin,
          reason: request.reason,
        );
      } else {
        await request.store.setUserPassword(request.username, password,
            origin: kAccessAdminMcpOrigin, reason: request.reason);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AccessDenied {
      // The shared prompt naming `users` is already on screen. The dialog
      // stays open, so signing in from there and pressing again is the flow.
      if (mounted) setState(() => _submitting = false);
    } on UserExistsException {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _problem = _Problem.duplicate;
      });
    } on MissingRoleError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _missingRole = error.roleName;
        _problem = _Problem.missingRole;
      });
    } on Object catch (thrown, stack) {
      // To the log, never to the screen: a credential is in hand.
      Logger().e('proposed account write failed',
          error: thrown, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _problem = _Problem.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final problem = _problem;
    final problemText = switch (problem) {
      null => null,
      _Problem.blank => kAccessUserBlankPasswordNote,
      _Problem.mismatch => kAccessUserMismatchNote,
      _Problem.duplicate => kAccessUserDuplicateNote(request.username),
      _Problem.missingRole =>
        'There is no role named "$_missingRole" on this station any more.',
      _Problem.failed => request.isCreate
          ? kAccessUserCreateFailedNote
          : kAccessUserSetPasswordFailedNote,
    };
    return StandardDialogFrame(
      title: request.isCreate
          ? kAccessAdminProposalCreateTitle(request.username)
          : kAccessAdminProposalResetTitle(request.username),
      showClose: false,
      actions: [
        PaneAction(
          label: 'Cancel',
          buttonKey: kAccessAdminProposalCancelKey,
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        ),
        PaneAction.primary(
          label: request.isCreate
              ? kAccessAdminProposalCreateLabel
              : kAccessAdminProposalResetLabel,
          buttonKey: kAccessAdminProposalSubmitKey,
          onPressed: _submitting ? null : _submit,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            request.isCreate
                ? kAccessAdminProposalCreateNote(
                    request.roles!, request.stationAccount)
                : kAccessUserSetPasswordNoteFor(
                    stationAccount: request.stationAccount),
            maxLines: null,
            overflow: TextOverflow.visible,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessAdminProposalPasswordFieldKey,
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: kAccessAdminProposalConfirmFieldKey,
            controller: _confirm,
            obscureText: true,
            enabled: !_submitting,
            onSubmitted: _submitting ? null : (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              border: OutlineInputBorder(),
            ),
          ),
          if (problemText != null) ...[
            const SizedBox(height: 12),
            Text(
              problemText,
              key: kAccessAdminProposalProblemKey,
              maxLines: null,
              overflow: TextOverflow.visible,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
