/// The account and role tools: who may do what on this station, and how to
/// propose changing it.
///
/// `list_accounts` and `list_roles` are here; the nine proposal tools are in
/// `registerAccessAccountWriteTools` below. The split follows
/// `access_template_tools.dart`, and so does the toggle boundary: reading the
/// roster is configuration, changing it is authorization and rides the
/// proposal path.
///
/// ## What these tools are for
///
/// `list_access_templates` answers "which keys are gated above the floor";
/// these answer "what *is* the floor, and who stands above it". A person
/// locking a station down needs both, and until now the second half was only
/// visible by walking to the panel. So the reads do not stop at rows: every
/// account is listed with the union of what its roles grant, every role with
/// what its groups mean in words, and the reserved `anonymous` account — the
/// one every logged-out panel answers as — is called out as the floor it is.
///
/// ## Why nothing here is gated on `users`
///
/// The same argument `access_template_tools.dart` makes, unchanged: this
/// package has no session and cannot know who is at the panel, so the gate is
/// at the **approval**. Every write tool returns a proposal and writes
/// nothing; `lib/pages/access_admin_proposals.dart` applies it through
/// `AccessAdminStore`, which asks the live session for `users` and records the
/// answer with `origin: 'mcp'`. Two properties hold that up and both are
/// asserted by tests: nothing in this file or in `AccessAccountService`
/// writes, and no tool takes an argument naming the approver.
///
/// ## Why no tool takes a password
///
/// `ToolRegistry` JSON-encodes every tool's arguments into the MCP audit table
/// before the handler runs, the proposal JSON is rendered on the operator's
/// screen and returned to the agent, and `AuditRecord.toString` withholds
/// values only for auth rows. A password passed as a tool argument would
/// therefore be written to a database table, shown on a panel and echoed to a
/// remote client before anybody could refuse it. So `create_account` and
/// `reset_account_password` carry **no credential at all**: the proposal says
/// *that* an account is to be created or reset, and the person who accepts it
/// types the password at the panel, in the same dialog the accounts screen
/// uses. The credential then travels from that dialog to the store and stops
/// there, which is the rule `access_users_section.dart` already keeps.
///
/// ## The invariants, and where they are decided
///
/// The repository refuses four changes that would leave nobody able to manage
/// accounts, refuses deleting a role somebody holds, and refuses touching the
/// anonymous row's password, station flag or existence. Those decisions are
/// made **inside the repository's transaction at the accept**, and they are
/// not re-decided here. What this file does is *predict* them from the
/// snapshot and say so in the diff — "this will be refused, and here is why" —
/// so the agent can fix the plan before asking a person to approve something
/// that cannot land. A prediction made on a stale read is only a warning; the
/// refusal is the store's.
library;

import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:tfc_access/tfc_access.dart';

import '../safety/risk_gate.dart';
import '../services/access_account_service.dart';
import '../services/proposal_service.dart';
import 'tool_registry.dart';

// ---------------------------------------------------------------------------
// Shared copy
// ---------------------------------------------------------------------------

/// A station whose schema predates the account tables — or whose database
/// will not answer.
const String _kNoTablesNote =
    'This station has no app_user / app_role tables, so it cannot say who '
    'may do what: nobody can sign in here and every panel holds the seeded '
    'floor (operate only). This is "cannot tell you", not "there are none": '
    'the tables arrive with the database schema upgrade that adds access '
    'control. Nothing can be proposed until they do.';

/// Every `AccessGroup` name, in enum order, for rejections.
final String _kGroupList = AccessGroup.values.map((g) => g.name).join(', ');

/// The proposal type the app routes to the access screen for account changes.
const String kAccessAccountProposalType = 'access_account';

/// The proposal type the app routes to the access screen for role changes.
const String kAccessRoleProposalType = 'access_role';

CallToolResult _error(String message) => CallToolResult(
      content: [TextContent(text: message)],
      isError: true,
    );

/// Groups as a short list in enum order, or `(none)`.
String _groups(Set<AccessGroup> groups) => groups.isEmpty
    ? '(none)'
    : AccessGroup.values.where(groups.contains).map((g) => g.name).join(', ');

/// Groups spelled out — name and what it covers — one per line, indented.
///
/// This is the "what can this role actually do" answer, in the same seven
/// sentences the roles screen shows under its checkboxes.
String _explainGroups(Set<AccessGroup> groups, {String indent = '    '}) {
  if (groups.isEmpty) {
    return '${indent}nothing — not even operate; a session holding only this '
        'can look but not touch';
  }
  final buffer = StringBuffer();
  for (final g in AccessGroup.values.where(groups.contains)) {
    buffer.writeln('$indent${g.name} — ${g.description}');
  }
  final missing = AccessGroup.values.where((g) => !groups.contains(g));
  if (missing.isNotEmpty) {
    buffer.writeln(
        '${indent}not granted: ${missing.map((g) => g.name).join(', ')}');
  }
  return buffer.toString().trimRight();
}

/// A stored timestamp, or the word for its absence.
String _when(String? at) => at == null || at.isEmpty ? 'never' : at;

/// A page whitelist as a reader should see it.
String _pages(Set<String>? pages, {required String whenNull}) => pages == null
    ? whenNull
    : pages.isEmpty
        ? 'a whitelist naming no page (sees nothing)'
        : 'only: ${(pages.toList()..sort()).join(', ')}';

/// Either the decoded groups or a tool error naming what was wrong.
Object _decodeGroups(Object? raw) {
  final groups = <AccessGroup>{};
  if (raw == null) return groups;
  if (raw is! List) return 'groups must be an array of group names.';
  for (final entry in raw) {
    if (entry is! String) {
      return 'Each group must be a string. The seven are: $_kGroupList.';
    }
    final parsed = AccessGroup.byName(entry);
    if (parsed == null) {
      return 'Unknown permission group "$entry". The seven are: '
          '$_kGroupList. They are fixed in code — a customer invents a role, '
          'never a group.';
    }
    groups.add(parsed);
  }
  return groups;
}

/// Either the role names — trimmed, deduplicated, primary first, every one
/// of them existing — or a tool error.
Object _decodeRoleNames(Object? raw, AccessAccountSnapshot snapshot) {
  if (raw is! List || raw.isEmpty) {
    return 'roles must be a non-empty array of role names, primary role '
        'first. Call list_roles to see what exists.';
  }
  final names = <String>[];
  for (final entry in raw) {
    if (entry is! String || entry.trim().isEmpty) {
      return 'Each role must be a non-empty role name. Got: $entry';
    }
    names.add(entry);
  }
  final normalised =
      normaliseRoleNames(primary: names.first, additional: names.skip(1));
  for (final name in normalised) {
    if (snapshot.role(name) == null) {
      return 'No role named "$name" on this station. Call list_roles to see '
          'what exists, or propose it first with create_role. Roles are '
          'matched by exact name.';
    }
  }
  return normalised;
}

/// The change a write tool is about to propose, for [_lockoutNote].
///
/// One shape per trip route of the repository's guard, so the prediction here
/// and the refusal there describe the same four things.
class _Pending {
  const _Pending._(
      {this.deletedAccount, this.movedAccount, this.newRoles, this.role, this.newGroups, this.deletedRole});

  factory _Pending.accountDeleted(String username) =>
      _Pending._(deletedAccount: username);
  factory _Pending.accountMoved(String username, List<String> roles) =>
      _Pending._(movedAccount: username, newRoles: roles);
  factory _Pending.roleGroupsReplaced(String role, Set<AccessGroup> groups) =>
      _Pending._(role: role, newGroups: groups);
  factory _Pending.roleDeleted(String role) => _Pending._(deletedRole: role);

  final String? deletedAccount;
  final String? movedAccount;
  final List<String>? newRoles;
  final String? role;
  final Set<AccessGroup>? newGroups;
  final String? deletedRole;
}

/// A sentence saying the store will refuse [change] because it would leave
/// no account able to manage roles and accounts — or null when it will not.
///
/// The same computation `AccessRepository._requireAUsersHolderRemains` makes,
/// over the snapshot rather than inside the transaction. **It decides
/// nothing.** It is here so a proposal that cannot land says so before a
/// person is asked to approve it, and so the agent learns what to fix — the
/// repository's message says the same, but only after the click.
String? _lockoutNote(AccessAccountSnapshot snapshot, _Pending change) {
  final granting = snapshot.rolesGrantingUsers.toSet();
  final rolesHeld = <String, List<String>>{
    for (final a in snapshot.people) a.username: a.roleNames,
  };
  List<String> holdersAgainst(Set<String> grants) => [
        for (final e in rolesHeld.entries)
          if (e.value.any(grants.contains)) e.key,
      ]..sort();

  final holdersNow = holdersAgainst(granting);
  if (holdersNow.isEmpty) return null;

  final grantingAfter = {...granting};
  if (change.deletedAccount != null) {
    rolesHeld.remove(change.deletedAccount);
  } else if (change.movedAccount != null) {
    if (change.movedAccount != kAnonymousUsername) {
      rolesHeld[change.movedAccount!] = change.newRoles!;
    }
  } else if (change.role != null) {
    if (change.newGroups!.contains(AccessGroup.users)) {
      grantingAfter.add(change.role!);
    } else {
      grantingAfter.remove(change.role!);
    }
  } else if (change.deletedRole != null) {
    grantingAfter.remove(change.deletedRole!);
  }
  if (holdersAgainst(grantingAfter).isNotEmpty) return null;

  return 'REFUSED AT THE ACCEPT: this would leave no account able to manage '
      'roles and accounts. Today ${holdersNow.join(', ')} '
      '${holdersNow.length == 1 ? 'is the only account holding' : 'are the only accounts holding'} '
      'a role that grants users (${granting.toList().join(', ')}). Grant '
      'users to another role, or put another account on one, first. There is '
      'no override.';
}

// ---------------------------------------------------------------------------
// Read tools
// ---------------------------------------------------------------------------

/// Registers `list_accounts` and `list_roles`.
///
/// Read-only: no [RiskGate], no proposal, no write. Registered under the
/// toggle that carries configuration reads, beside `list_access_templates`.
void registerAccessAccountTools({
  required ToolRegistry registry,
  required AccessAccountService service,
}) {
  _registerListAccounts(registry, service);
  _registerListRoles(registry, service);
}

void _registerListAccounts(ToolRegistry registry, AccessAccountService service) {
  registry.registerTool(
    name: 'list_accounts',
    description:
        'List every account on this station: username, the roles it holds, '
        'everything those roles together let it do, whether it is a station '
        'account (a panel whose sessions never expire) or a person, when it '
        'was created and when it last signed in. The reserved "anonymous" '
        'account is listed too — it is what every logged-out panel answers '
        'as, so its permissions are the floor of the whole station. Also '
        'says who can manage accounts (the lockout guard) and whether the '
        'first-user window is still open. Never returns password hashes, '
        'salts or any credential. There is no disabled or locked state in '
        'this model: an account exists or it does not — to take access away, '
        'move it to a narrower role with set_account_roles or delete it.',
    inputSchema: JsonSchema.object(properties: {}),
    handler: (arguments, extra) async {
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) {
        return CallToolResult(content: [TextContent(text: _kNoTablesNote)]);
      }

      final people = snapshot.people;
      final stations = people.where((a) => a.stationAccount).length;
      final buffer = StringBuffer();
      buffer.writeln('${people.length} account(s) on this station '
          '(${people.length - stations} people, $stations station '
          'account(s)), plus the reserved "$kAnonymousUsername" account.');
      buffer.writeln();

      if (snapshot.firstUserWindowOpen) {
        buffer.writeln('THE FIRST-USER WINDOW IS OPEN: no person has an '
            'account, so whoever reaches this station first can create the '
            'Engineering account and hold every group. Nothing can be proposed '
            'into an empty roster from here — the first account is created at '
            'the panel, and the door closes behind it.');
        buffer.writeln();
      }

      buffer.writeln('Floor — what a logged-out panel may do: '
          '${_groups(snapshot.anonymousGroups)}. Change it with '
          'set_account_roles on "$kAnonymousUsername".');
      final holders = snapshot.usersHolders;
      buffer.writeln(holders.isEmpty
          ? 'Lockout guard: NO account holds a role granting users, so nobody '
              'can manage roles or accounts from the panel. Recovery is the '
              'break-glass procedure, not a proposal.'
          : 'Lockout guard: ${holders.length} account(s) can manage roles and '
              'accounts — ${holders.join(', ')}. Any change that would leave '
              'none is refused at the accept, with no override.');
      buffer.writeln();

      for (final account in snapshot.accounts) {
        final groups = snapshot.effectiveGroups(account);
        final missing = snapshot.missingRolesOf(account);
        buffer.writeln('${account.username} — '
            '${account.isAnonymous ? 'every logged-out panel; ' : account.stationAccount ? 'station account; ' : ''}'
            'roles: ${roleLabelFor(account.roleNames)}');
        if (missing.isNotEmpty) {
          buffer.writeln('  names ${missing.length} role(s) that no longer '
              'exist (${missing.join(', ')}) — each grants nothing'
              '${!snapshot.effectiveGroupsResolvable(account) ? ', and the primary is one of them, so this account cannot sign in at all' : ''}');
        }
        buffer.writeln('  may: ${_groups(groups)}'
            '${groups.contains(AccessGroup.users) ? ' (can manage roles and accounts)' : ''}');
        if (!account.isAnonymous) {
          buffer.writeln('  created: ${_when(account.createdAt)}; '
              'last login: ${_when(account.lastLoginAt)}');
          buffer.writeln(account.stationAccount
              ? '  sessions: never expire (station account)'
              : '  sessions: expire after '
                  '${account.inactivityTimeoutMinutes == null ? 'the default idle window' : '${account.inactivityTimeoutMinutes} idle minute(s)'}');
        }
        buffer.writeln(
            '  pages: ${_pages(account.allowedPages, whenNull: 'whatever its roles allow')}');
        buffer.writeln();
      }
      return CallToolResult(
        content: [TextContent(text: buffer.toString().trimRight())],
      );
    },
  );
}

void _registerListRoles(ToolRegistry registry, AccessAccountService service) {
  registry.registerTool(
    name: 'list_roles',
    description:
        'List every role on this station with the permission groups it '
        'grants, what each of those groups actually lets a person do, which '
        'accounts hold it, and whether the logged-out panel holds it — in '
        'which case the role IS the floor, and widening it widens every panel '
        'with nobody signed in. A role is a bundle of the seven fixed groups; '
        'an account may do the union of everything its roles grant. Groups '
        'decide every write on the panel except keys bound to an access '
        'template, where the template names the group each member needs '
        '(list_access_templates). Read this before create_role, update_role, '
        'rename_role or delete_role: update_role replaces a role\'s groups '
        'wholesale, and delete_role is refused while anybody holds the role.',
    inputSchema: JsonSchema.object(properties: {}),
    handler: (arguments, extra) async {
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) {
        return CallToolResult(content: [TextContent(text: _kNoTablesNote)]);
      }
      if (snapshot.roles.isEmpty) {
        return CallToolResult(content: [
          TextContent(
              text: 'No roles exist on this station, which is not the shipped '
                  'state — the schema seeds four. Nobody can be given a role '
                  'until one exists; propose one with create_role.')
        ]);
      }

      final anonymousRoles = snapshot.anonymous?.roleNames ?? const <String>[];
      final buffer = StringBuffer();
      buffer.writeln('${snapshot.roles.length} role(s) on this station.');
      buffer.writeln();
      buffer.writeln('The seven groups, which are fixed in code:');
      buffer.writeln(_explainGroups(AccessGroup.values.toSet(), indent: '  '));
      buffer.writeln();
      buffer.writeln('Floor — a logged-out panel holds '
          '${anonymousRoles.isEmpty ? 'no account row and falls back to "$kOperatorRoleName"' : roleLabelFor(anonymousRoles)}'
          ', so it may: ${_groups(snapshot.anonymousGroups)}.');
      final grantingUsers = snapshot.rolesGrantingUsers;
      final holders = snapshot.usersHolders;
      buffer.writeln('Roles granting users: '
          '${grantingUsers.isEmpty ? '(none)' : grantingUsers.join(', ')}; '
          'accounts holding one: '
          '${holders.isEmpty ? '(none)' : holders.join(', ')}. Deleting or '
          'narrowing the last of these is refused at the accept.');
      buffer.writeln();

      for (final record in snapshot.roles) {
        final role = record.role;
        final held = snapshot.holdersOf(role.name);
        buffer.writeln('${role.name}${role.seeded ? ' (seeded)' : ''} — '
            'held by ${held.isEmpty ? 'nobody' : '${held.length}: ${held.join(', ')}'}');
        buffer.writeln('  grants: ${_groups(role.groups)}'
            '${role.groups.length == AccessGroup.values.length ? ' (all seven)' : ''}');
        buffer.writeln(_explainGroups(role.groups));
        if (anonymousRoles.contains(role.name)) {
          buffer.writeln('  THIS IS THE FLOOR: the "$kAnonymousUsername" '
              'account holds it, so every logged-out panel can do the above. '
              'Adding a group here grants it to every panel with nobody '
              'signed in.');
        }
        buffer.writeln(
            '  pages: ${_pages(record.allowedPages, whenNull: 'every page')}');
        buffer.writeln();
      }
      return CallToolResult(
        content: [TextContent(text: buffer.toString().trimRight())],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Write tools — every one of them a proposal, and nothing else
// ---------------------------------------------------------------------------

/// Registers the nine proposal tools over accounts and roles.
///
/// None of them touches the database. Each validates its arguments against
/// the current snapshot, predicts the repository's refusals, formats a diff,
/// elicits confirmation through [RiskGate], and returns a wrapped proposal
/// with `_op` stamped. The application happens in the app, at the accept,
/// through the `users`-gated store.
///
/// Registered under `toggles.proposalsEnabled && toggles.configEnabled`, the
/// pairing the access-template writes use.
void registerAccessAccountWriteTools({
  required ToolRegistry registry,
  required AccessAccountService service,
  required RiskGate riskGate,
  required ProposalService proposalService,
}) {
  _registerCreateAccount(registry, service, riskGate, proposalService);
  _registerDeleteAccount(registry, service, riskGate, proposalService);
  _registerSetAccountRoles(registry, service, riskGate, proposalService);
  _registerSetStationAccount(registry, service, riskGate, proposalService);
  _registerResetAccountPassword(registry, service, riskGate, proposalService);
  _registerCreateRole(registry, service, riskGate, proposalService);
  _registerUpdateRole(registry, service, riskGate, proposalService);
  _registerRenameRole(registry, service, riskGate, proposalService);
  _registerDeleteRole(registry, service, riskGate, proposalService);
}

/// The `roles` argument, shared by create_account and set_account_roles.
JsonSchema _rolesSchema(String description) => JsonSchema.array(
      description: description,
      items: JsonSchema.string(description: 'A role name, exactly as '
          'list_roles spells it.'),
    );

/// The `groups` argument, shared by create_role and update_role.
JsonSchema _groupsSchema(String description) => JsonSchema.array(
      description: description,
      items: JsonSchema.string(
        description: 'One of the seven permission groups.',
        enumValues: [for (final g in AccessGroup.values) g.name],
      ),
    );

JsonSchema _reasonSchema(String what) => JsonSchema.string(
      description: 'Why $what. Recorded on the audit row when the change is '
          'approved.',
    );

/// The reason argument, if one was given.
Map<String, dynamic> _reason(Map<String, dynamic> arguments) =>
    arguments['reason'] is String ? {'reason': arguments['reason']} : const {};

void _registerCreateAccount(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'create_account',
    description:
        'Propose a new account holding the given roles. Takes NO password, '
        'deliberately: a password given here would be written to the audit '
        'table and shown on screen. The person who accepts the proposal '
        'types the new account\'s password at the panel, and it goes nowhere '
        'else. Returns proposal JSON for a person holding "users" to approve; '
        'it does not write to the database. The first account on a fresh '
        'station cannot be proposed — it is created at the panel.',
    inputSchema: JsonSchema.object(
      properties: {
        'username': JsonSchema.string(
          description: 'The new username. Case-sensitive, trimmed, and it '
              'must not already exist. "anonymous" is reserved.',
        ),
        'roles': _rolesSchema('The roles the account holds, primary first. '
            'Every one must exist. What the account may do is the union of '
            'all of them.'),
        'station_account': JsonSchema.boolean(
          description: 'True for a panel that signs in once and stays signed '
              'in — its sessions never expire. False (the default) for a '
              'person, whose session ends after the idle window.',
          defaultValue: false,
        ),
        'reason': _reasonSchema('this account is needed'),
      },
      required: ['username', 'roles'],
    ),
    handler: (arguments, extra) async {
      final username = (arguments['username'] as String).trim();
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      if (username.isEmpty) return _error('username must not be blank.');
      if (isAnonymousUsername(username)) {
        return _error('"$username" is reserved for the account every '
            'logged-out panel answers as. It already exists; change what it '
            'may do with set_account_roles on "$kAnonymousUsername".');
      }
      if (snapshot.account(username) != null) {
        return _error('An account named "$username" already exists. Use '
            'set_account_roles to change what it holds — this tool would '
            'produce a proposal that fails when somebody tries to approve it.');
      }
      if (snapshot.firstUserWindowOpen) {
        return _error('The first-user window is open: no person has an '
            'account yet, and the first one is created at the panel, not '
            'proposed. It becomes Engineering and closes the window; '
            'accounts can be proposed after that.');
      }
      final decoded = _decodeRoleNames(arguments['roles'], snapshot);
      if (decoded is String) return _error(decoded);
      final roles = decoded as List<String>;
      final station = arguments['station_account'] == true;

      final groups = unionRoleGroups([
        for (final name in roles) snapshot.role(name)!.role,
      ]);
      final diff = proposalService.formatCreateDiff('Account', username, {
        'roles': roleLabelFor(roles),
        'may': _groups(groups),
        'station account': station ? 'yes — sessions never expire' : 'no',
        'password': 'typed by the approver at the panel; not in this proposal',
        'applied by': 'a person holding "users", on the access screen',
      });
      // High when the new account could manage accounts itself: that is a
      // second administrator being minted, which is the change to stop on.
      await riskGate.requestConfirmation(
        description: 'Create account: $username as ${roleLabelFor(roles)}',
        level: groups.contains(AccessGroup.users)
            ? RiskLevel.high
            : RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessAccountProposalType,
        <String, dynamic>{
          'title': 'Account "$username"',
          'username': username,
          'roles': roles,
          'station_account': station,
          ..._reason(arguments),
        },
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerDeleteAccount(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'delete_account',
    description:
        'Propose removing an account. Its audit rows survive it. The reserved '
        '"anonymous" account cannot be deleted, and deleting the last account '
        'able to manage accounts is refused at the accept — the proposal says '
        'so if that is what it would do. Returns proposal JSON; it does not '
        'write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'username': JsonSchema.string(
          description: 'The account to remove. It must exist.',
        ),
        'reason': _reasonSchema('it is being removed'),
      },
      required: ['username'],
    ),
    handler: (arguments, extra) async {
      final username = arguments['username'] as String;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      if (isAnonymousUsername(username)) {
        return _error('"$kAnonymousUsername" is every panel with nobody '
            'signed in and cannot be deleted. To narrow what a logged-out '
            'panel may do, use set_account_roles on it.');
      }
      final existing = snapshot.account(username);
      if (existing == null) {
        return _error('No account named "$username" on this station. Call '
            'list_accounts to see what exists (names are case-sensitive).');
      }

      final lockout =
          _lockoutNote(snapshot, _Pending.accountDeleted(username));
      final diff = proposalService.formatUpdateDiff('Account', username, {
        'account': '${roleLabelFor(existing.roleNames)} -> (deleted)',
        'audit rows': 'kept -> kept (the trail outlives the account)',
        if (lockout != null) 'lockout guard': 'holds users -> $lockout',
      });
      await riskGate.requestConfirmation(
        description: lockout == null
            ? 'Delete account: $username'
            : 'Delete account: $username — the last one able to manage '
                'accounts, which the store refuses',
        level: RiskLevel.high,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessAccountProposalType,
        <String, dynamic>{
          'title': 'Account "$username"',
          'username': username,
          'roles': existing.roleNames,
          if (lockout != null) 'warnings': [lockout],
          ..._reason(arguments),
        },
        op: 'delete',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerSetAccountRoles(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'set_account_roles',
    description:
        'Propose replacing the roles an account holds. The list given here '
        'REPLACES the whole set — send back the ones to keep. On the reserved '
        '"anonymous" account this changes what every logged-out panel may do, '
        'and the proposal says so. Moving the last account able to manage '
        'accounts onto roles that cannot is refused at the accept. Returns '
        'proposal JSON; it does not write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'username': JsonSchema.string(
          description: 'The account to change. It must exist.',
        ),
        'roles': _rolesSchema('The roles the account will hold afterwards, '
            'primary first. Every one must exist.'),
        'reason': _reasonSchema('the roles are changing'),
      },
      required: ['username', 'roles'],
    ),
    handler: (arguments, extra) async {
      final username = arguments['username'] as String;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      final existing = snapshot.account(username);
      if (existing == null) {
        return _error('No account named "$username" on this station. Call '
            'list_accounts to see what exists (names are case-sensitive).');
      }
      final decoded = _decodeRoleNames(arguments['roles'], snapshot);
      if (decoded is String) return _error(decoded);
      final roles = decoded as List<String>;
      if (roles.join(' ') == existing.roleNames.join(' ')) {
        return _error('"$username" already holds exactly '
            '${roleLabelFor(roles)}. Nothing to change.');
      }

      final before = snapshot.effectiveGroups(existing);
      final after = unionRoleGroups([
        for (final name in roles) snapshot.role(name)!.role,
      ]);
      final widened = after.difference(before);
      final lockout =
          _lockoutNote(snapshot, _Pending.accountMoved(username, roles));
      final diff = proposalService.formatUpdateDiff('Account', username, {
        'roles': '${roleLabelFor(existing.roleNames)} -> ${roleLabelFor(roles)}',
        'may': '${_groups(before)} -> ${_groups(after)}',
        if (existing.isAnonymous)
          'floor': 'this is every logged-out panel -> every panel with nobody '
              'signed in will be able to: ${_groups(after)}',
        if (lockout != null) 'lockout guard': 'holds users -> $lockout',
      });
      // High whenever a group is added, and always on the anonymous row: a
      // wider account is the change worth stopping on, and a wider floor is
      // that change for every panel at once.
      await riskGate.requestConfirmation(
        description: existing.isAnonymous
            ? 'Change what every logged-out panel may do: '
                '${roleLabelFor(roles)}'
            : 'Set roles: $username -> ${roleLabelFor(roles)}',
        level: widened.isNotEmpty || existing.isAnonymous
            ? RiskLevel.high
            : RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessAccountProposalType,
        <String, dynamic>{
          'title': 'Account "$username"',
          'username': username,
          'field': 'roles',
          'roles': roles,
          if (existing.isAnonymous)
            'warnings': [
              'This is the "$kAnonymousUsername" account: every panel with '
                  'nobody signed in will be able to: ${_groups(after)}.',
              if (lockout != null) lockout,
            ]
          else if (lockout != null)
            'warnings': [lockout],
          ..._reason(arguments),
        },
        op: 'update',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerSetStationAccount(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'set_station_account',
    description:
        'Propose flipping an account\'s station-account flag. A station '
        'account is a panel, not a person: it signs in once and its sessions '
        'never expire, so whatever its roles grant stays granted on that '
        'panel around the clock. Not a permission — it cannot trip the '
        'lockout guard — but it decides whether a signed-in panel ever signs '
        'itself out. The "anonymous" account cannot be one. Returns proposal '
        'JSON; it does not write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'username': JsonSchema.string(
          description: 'The account to change. It must exist.',
        ),
        'station_account': JsonSchema.boolean(
          description: 'True to make it a panel account whose sessions never '
              'expire; false to make it a person again.',
        ),
        'reason': _reasonSchema('the flag is changing'),
      },
      required: ['username', 'station_account'],
    ),
    handler: (arguments, extra) async {
      final username = arguments['username'] as String;
      final value = arguments['station_account'] == true;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      if (isAnonymousUsername(username)) {
        return _error('"$kAnonymousUsername" is every panel with nobody '
            'signed in; it has no sessions to keep alive and cannot be a '
            'station account.');
      }
      final existing = snapshot.account(username);
      if (existing == null) {
        return _error('No account named "$username" on this station. Call '
            'list_accounts to see what exists (names are case-sensitive).');
      }
      if (existing.stationAccount == value) {
        return _error('"$username" is already '
            '${value ? 'a station account' : 'a person'}. Nothing to change.');
      }

      final diff = proposalService.formatUpdateDiff('Account', username, {
        'station account': '${existing.stationAccount ? 'yes' : 'no'} -> '
            '${value ? 'yes' : 'no'}',
        'sessions': value
            ? 'expire after the idle window -> never expire'
            : 'never expire -> expire after the idle window',
        'may (unchanged)': _groups(snapshot.effectiveGroups(existing)),
      });
      await riskGate.requestConfirmation(
        description: value
            ? 'Make $username a station account (sessions never expire)'
            : 'Make $username a person again (sessions expire)',
        level: value ? RiskLevel.high : RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessAccountProposalType,
        <String, dynamic>{
          'title': 'Account "$username"',
          'username': username,
          'field': 'station_account',
          'station_account': value,
          ..._reason(arguments),
        },
        op: 'update',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerResetAccountPassword(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'reset_account_password',
    description:
        'Propose resetting an account\'s password. Takes NO password and '
        'carries none: the person who accepts types the new one at the '
        'panel, in the same dialog the accounts screen uses, and it goes from '
        'there to the store and nowhere else. This tool exists so an agent '
        'can put "reset this account" in front of an administrator without a '
        'credential ever crossing MCP, the audit table or the screen. The '
        '"anonymous" account has no password. Returns proposal JSON; it does '
        'not write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'username': JsonSchema.string(
          description: 'The account whose password is to be reset. It must '
              'exist.',
        ),
        'reason': _reasonSchema('the password is being reset'),
      },
      required: ['username'],
    ),
    handler: (arguments, extra) async {
      final username = arguments['username'] as String;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      if (isAnonymousUsername(username)) {
        return _error('"$kAnonymousUsername" is every panel with nobody '
            'signed in. It has no password and can never sign in.');
      }
      final existing = snapshot.account(username);
      if (existing == null) {
        return _error('No account named "$username" on this station. Call '
            'list_accounts to see what exists (names are case-sensitive).');
      }

      final diff = proposalService.formatUpdateDiff('Account', username, {
        'password': '(current) -> typed by the approver at the panel',
        'roles (unchanged)': roleLabelFor(existing.roleNames),
      });
      await riskGate.requestConfirmation(
        description: 'Reset password: $username (typed at the panel on accept)',
        level: RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessAccountProposalType,
        <String, dynamic>{
          'title': 'Account "$username"',
          'username': username,
          'field': 'password',
          ..._reason(arguments),
        },
        op: 'update',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerCreateRole(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'create_role',
    description:
        'Propose a new role — a named bundle of permission groups that '
        'accounts can then hold. Creating one grants nothing on its own: '
        'put accounts on it with set_account_roles or create_account '
        'afterwards. Returns proposal JSON for a person holding "users" to '
        'approve; it does not write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(
          description: 'Role name, trimmed, and it must not already exist. '
              'It is the identity accounts name, so pick what the people '
              'are, not what the rule is.',
        ),
        'groups': _groupsSchema('The groups the role grants. A group not '
            'listed is not granted. An empty list is a role that can look '
            'but not touch.'),
        'reason': _reasonSchema('this role is needed'),
      },
      required: ['name', 'groups'],
    ),
    handler: (arguments, extra) async {
      final name = (arguments['name'] as String).trim();
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      if (name.isEmpty) return _error('name must not be blank.');
      if (snapshot.role(name) != null) {
        return _error('A role named "$name" already exists. Use update_role '
            'to change its groups — this tool would produce a proposal that '
            'fails when somebody tries to approve it.');
      }
      final decoded = _decodeGroups(arguments['groups']);
      if (decoded is String) return _error(decoded);
      final groups = decoded as Set<AccessGroup>;

      final diff = proposalService.formatCreateDiff('Role', name, {
        'grants': _groups(groups),
        'which means': _explainGroups(groups, indent: '').replaceAll('\n', '; '),
        'held by': 'nobody yet — assign it with set_account_roles',
        'applied by': 'a person holding "users", on the access screen',
      });
      await riskGate.requestConfirmation(
        description: 'Create role: $name (${_groups(groups)})',
        level: groups.contains(AccessGroup.users)
            ? RiskLevel.high
            : RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessRoleProposalType,
        <String, dynamic>{
          'title': 'Role "$name"',
          'name': name,
          'groups': [
            for (final g in AccessGroup.values.where(groups.contains)) g.name,
          ],
          ..._reason(arguments),
        },
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerUpdateRole(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'update_role',
    description:
        'Propose replacing a role\'s permission groups. The groups given '
        'here REPLACE the role\'s whole set — a group you leave out is taken '
        'away from every account holding the role. Call list_roles first and '
        'send back the ones to keep. If the logged-out panel holds this role, '
        'adding a group grants it to every panel with nobody signed in, and '
        'the proposal says so. Removing users from the only role that grants '
        'it is refused at the accept. Returns proposal JSON; it does not '
        'write to the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(
          description: 'The role to change. It must already exist.',
        ),
        'groups': _groupsSchema('The groups the role grants afterwards. A '
            'group not listed is not granted.'),
        'reason': _reasonSchema('the groups are changing'),
      },
      required: ['name', 'groups'],
    ),
    handler: (arguments, extra) async {
      final name = arguments['name'] as String;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      final existing = snapshot.role(name);
      if (existing == null) {
        return _error('No role named "$name" on this station. Call '
            'list_roles to see what exists, or create_role to propose a new '
            'one.');
      }
      final decoded = _decodeGroups(arguments['groups']);
      if (decoded is String) return _error(decoded);
      final groups = decoded as Set<AccessGroup>;
      if (groups.length == existing.role.groups.length &&
          groups.containsAll(existing.role.groups)) {
        return _error('"$name" already grants exactly ${_groups(groups)}. '
            'Nothing to change.');
      }

      final added = groups.difference(existing.role.groups);
      final removed = existing.role.groups.difference(groups);
      final held = snapshot.holdersOf(name);
      final isFloor = snapshot.anonymous?.roleNames.contains(name) ?? false;
      final lockout =
          _lockoutNote(snapshot, _Pending.roleGroupsReplaced(name, groups));
      final diff = proposalService.formatUpdateDiff('Role', name, {
        'grants': '${_groups(existing.role.groups)} -> ${_groups(groups)}',
        if (added.isNotEmpty) 'added': '(none) -> ${_groups(added)}',
        if (removed.isNotEmpty) 'taken away': '${_groups(removed)} -> (none)',
        'accounts affected':
            '${held.length} -> ${held.isEmpty ? 'none' : held.join(', ')}',
        if (isFloor && added.isNotEmpty)
          'floor': 'this role is what a logged-out panel holds -> every panel '
              'with nobody signed in gains ${_groups(added)}',
        if (lockout != null) 'lockout guard': 'grants users -> $lockout',
      });
      await riskGate.requestConfirmation(
        description: isFloor && added.isNotEmpty
            ? 'Widen the floor: every logged-out panel gains ${_groups(added)}'
            : 'Change role: $name (${held.length} account(s) affected)',
        level: added.isNotEmpty ? RiskLevel.high : RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessRoleProposalType,
        <String, dynamic>{
          'title': 'Role "$name"',
          'name': name,
          'field': 'groups',
          'groups': [
            for (final g in AccessGroup.values.where(groups.contains)) g.name,
          ],
          'holders': held,
          if (isFloor && added.isNotEmpty || lockout != null)
            'warnings': [
              if (isFloor && added.isNotEmpty)
                'This role is what a logged-out panel holds: every panel '
                    'with nobody signed in gains ${_groups(added)}.',
              if (lockout != null) lockout,
            ],
          ..._reason(arguments),
        },
        op: 'update',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerRenameRole(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'rename_role',
    description:
        'Propose renaming a role. Every account holding it is carried across '
        'and keeps exactly what it may do; nothing widens or narrows. The new '
        'name must not exist yet. Returns proposal JSON; it does not write to '
        'the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(
          description: 'The role as it is named now. It must exist.',
        ),
        'new_name': JsonSchema.string(
          description: 'The name it will have. Trimmed; must not already '
              'exist.',
        ),
        'reason': _reasonSchema('it is being renamed'),
      },
      required: ['name', 'new_name'],
    ),
    handler: (arguments, extra) async {
      final from = arguments['name'] as String;
      final to = (arguments['new_name'] as String).trim();
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      final existing = snapshot.role(from);
      if (existing == null) {
        return _error('No role named "$from" on this station. Call '
            'list_roles to see what exists.');
      }
      if (to.isEmpty) return _error('new_name must not be blank.');
      if (to == from) return _error('"$from" already has that name.');
      if (snapshot.role(to) != null) {
        return _error('A role named "$to" already exists, so "$from" cannot '
            'be renamed onto it. Move its holders with set_account_roles and '
            'delete_role it instead, if merging is what you want.');
      }

      final held = snapshot.holdersOf(from);
      final diff = proposalService.formatUpdateDiff('Role', from, {
        'name': '$from -> $to',
        'grants (unchanged)': _groups(existing.role.groups),
        'accounts carried across':
            '${held.length} -> ${held.isEmpty ? 'none' : held.join(', ')}',
      });
      await riskGate.requestConfirmation(
        description: 'Rename role: $from -> $to',
        level: RiskLevel.medium,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessRoleProposalType,
        <String, dynamic>{
          'title': 'Role "$from"',
          'name': from,
          'new_name': to,
          'holders': held,
          ..._reason(arguments),
        },
        op: 'rename',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}

void _registerDeleteRole(
  ToolRegistry registry,
  AccessAccountService service,
  RiskGate riskGate,
  ProposalService proposalService,
) {
  registry.registerTool(
    name: 'delete_role',
    description:
        'Propose removing a role. A role that any account still holds — the '
        '"anonymous" account included — CANNOT be deleted: the store refuses '
        'it at the accept, because deleting it would leave those accounts '
        'pointing at nothing. The proposal names the holders so the approver '
        'sees the cost; move them first with set_account_roles if the delete '
        'is what you want. Deleting the only role granting users that anybody '
        'holds is refused too. Returns proposal JSON; it does not write to '
        'the database.',
    inputSchema: JsonSchema.object(
      properties: {
        'name': JsonSchema.string(
          description: 'The role to remove. It must exist.',
        ),
        'reason': _reasonSchema('it is being removed'),
      },
      required: ['name'],
    ),
    handler: (arguments, extra) async {
      final name = arguments['name'] as String;
      final snapshot = await service.snapshot();
      if (!snapshot.tablesPresent) return _error(_kNoTablesNote);

      final existing = snapshot.role(name);
      if (existing == null) {
        return _error('No role named "$name" on this station. Call '
            'list_roles to see what exists.');
      }

      // Reported, not decided: the block belongs to the store, which reads
      // the holders again at the accept. An account moved onto this role
      // between this call and the approval must still stop the delete.
      final held = snapshot.holdersOf(name);
      final lockout = _lockoutNote(snapshot, _Pending.roleDeleted(name));
      final diff = proposalService.formatUpdateDiff('Role', name, {
        'role': '${_groups(existing.role.groups)} -> (deleted)',
        'still held by': held.isEmpty
            ? 'nobody -> the delete is free'
            : '${held.join(', ')} -> the delete is BLOCKED while they hold it',
        if (lockout != null) 'lockout guard': 'grants users -> $lockout',
      });
      await riskGate.requestConfirmation(
        description: held.isEmpty
            ? 'Delete role: $name'
            : 'Delete role: $name — ${held.length} account(s) still hold it, '
                'which blocks it',
        level: RiskLevel.high,
        details: {'diff': diff},
      );

      final wrapped = await proposalService.wrapProposal(
        kAccessRoleProposalType,
        <String, dynamic>{
          'title': 'Role "$name"',
          'name': name,
          'groups': [
            for (final g
                in AccessGroup.values.where(existing.role.groups.contains))
              g.name,
          ],
          'holders': held,
          if (held.isNotEmpty || lockout != null)
            'warnings': [
              if (held.isNotEmpty)
                'BLOCKED at the accept while ${held.join(', ')} still '
                    'hold it. Move them with set_account_roles first.',
              if (lockout != null) lockout,
            ],
          ..._reason(arguments),
        },
        op: 'delete',
      );
      return CallToolResult(content: [TextContent(text: jsonEncode(wrapped))]);
    },
  );
}
