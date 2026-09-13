import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/tfc_dart_core.dart' show McpDatabase;

import 'sql_dialect.dart';

/// Read-only access to `app_role` and `app_user`, for the MCP tools.
///
/// The two tables answer the question a person locking a station down is
/// really asking — *who can do what here?* — and until this service existed
/// the MCP server could not answer it at all: it saw templates and bindings
/// (the exceptions) and nothing of the accounts and roles (the rule).
///
/// Everything `AccessTemplateService` says about itself holds here, and the
/// reasons are not repeated: **no write method, public or private**, because
/// the `users` gate lives at the approval in the app and this package cannot
/// know who is at the panel; **raw SQL**, because the tables live in
/// `tfc_dart`'s `AppDatabase` and are absent from `ServerDatabase`; **nothing
/// cached**, because an agent's whole use of this is propose-then-verify and
/// a five-minute-old roster would disagree with the accounts screen at
/// exactly the moment the agent checks its own work.
/// `test/tools/access_account_tools_test.dart` greps this file for write verbs
/// so the first property is enforced rather than asserted.
///
/// ## The one thing this file must never read
///
/// `app_user` carries `password_hash` and `salt`. **Neither column is named
/// anywhere in this file**, and that is the whole design: the SELECT below
/// lists its columns explicitly, [AccessAccountRecord] has no field a hash
/// could land in, and so nothing downstream — no tool, no error message, no
/// diff table — can leak credential material, because nothing downstream is
/// ever handed any. An explicit column list rather than `SELECT *` with a
/// filter afterwards, so that the guarantee is visible in one line and does
/// not depend on a filter being remembered. The test seeds a recognisable
/// hash and salt and asserts they appear in no tool output of any shape,
/// errors included.
///
/// ## Why the columns are the v9 set
///
/// `additional_roles` arrived with schema v9 and `inactivity_timeout_minutes`
/// with v8. This server runs **inside** the app, which migrates the database
/// to the current schema before either of them is opened, so a station whose
/// tables predate a column is not a state this service meets in practice. A
/// station whose tables predate the access model altogether — or whose
/// database will not answer — is, and both read as
/// [AccessAccountSnapshot.tablesPresent] false, the same "cannot tell you"
/// `AccessTemplateService` reports.
class AccessAccountService {
  /// Creates a service reading [db].
  AccessAccountService(this._db) : _isPostgres = isPostgresDb(_db);

  final McpDatabase _db;
  final bool _isPostgres;

  String _sql(String query) => adaptSql(query, isPostgres: _isPostgres);

  /// Both tables in one value, or [AccessAccountSnapshot.missing] when the
  /// schema does not have them.
  ///
  /// Read together on purpose: an account list without the roles cannot say
  /// what anybody may do, and a role list without the accounts cannot say who
  /// holds it — and "who holds `users`" is the one fact every write tool has
  /// to get right.
  Future<AccessAccountSnapshot> snapshot() async {
    final roles = await _roles();
    if (roles == null) return AccessAccountSnapshot.missing;
    final accounts = await _accounts();
    if (accounts == null) return AccessAccountSnapshot.missing;
    return AccessAccountSnapshot(
      roles: roles,
      accounts: accounts,
      tablesPresent: true,
    );
  }

  /// Every row of `app_role`, ordered by name, or null when the table is not
  /// there.
  Future<List<AccessRoleRecord>?> _roles() async {
    try {
      final rows = await _db
          .customSelect(_sql(
              'SELECT name, groups, seeded, allowed_pages FROM app_role '
              'ORDER BY name'))
          .get();
      return [
        for (final row in rows)
          AccessRoleRecord(
            role: AccessRole(
              name: row.data['name'] as String? ?? '',
              // Forgiving, like the app's own reader: a group name written by
              // a newer build costs the role that one group, never the list.
              groups: AccessRole.decodeGroups(
                  row.data['groups'] as String? ?? ''),
              seeded: _bool(row.data['seeded']),
            ),
            allowedPages: decodeAllowedPagesColumn(
                row.data['allowed_pages'] as String?),
          ),
      ];
    } on Object {
      return null;
    }
  }

  /// Every row of `app_user`, ordered by username, or null when the table is
  /// not there.
  ///
  /// The column list is the guarantee — see the class doc. Do not widen it to
  /// `*`.
  Future<List<AccessAccountRecord>?> _accounts() async {
    try {
      final rows = await _db
          .customSelect(_sql(
              'SELECT username, role_name, additional_roles, created_at, '
              'last_login_at, station_account, allowed_pages, '
              'inactivity_timeout_minutes FROM app_user ORDER BY username'))
          .get();
      return [
        for (final row in rows)
          AccessAccountRecord(
            username: row.data['username'] as String? ?? '',
            roleNames: normaliseRoleNames(
              primary: row.data['role_name'] as String? ?? '',
              additional:
                  decodeAdditionalRoles(row.data['additional_roles'] as String?),
            ),
            // Stringified rather than parsed, as `AccessTemplateService` does
            // with `updated_at`: both databases store these as ISO text, and
            // the value is only ever shown to a reader.
            createdAt: row.data['created_at']?.toString(),
            lastLoginAt: row.data['last_login_at']?.toString(),
            stationAccount: _bool(row.data['station_account']),
            allowedPages: decodeAllowedPagesColumn(
                row.data['allowed_pages'] as String?),
            inactivityTimeoutMinutes:
                (row.data['inactivity_timeout_minutes'] as num?)?.toInt(),
          ),
      ];
    } on Object {
      return null;
    }
  }

  /// A BOOLEAN column as either driver hands it back: a real bool on
  /// Postgres, an integer on SQLite.
  static bool _bool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    return false;
  }
}

/// One `app_role` row.
class AccessRoleRecord {
  const AccessRoleRecord({required this.role, this.allowedPages});

  final AccessRole role;

  /// The role's page whitelist, or null for "every page".
  final Set<String>? allowedPages;

  String get name => role.name;
}

/// One `app_user` row, **minus its credential columns** — by construction,
/// not by omission. There is no field here a hash or a salt could occupy.
class AccessAccountRecord {
  const AccessAccountRecord({
    required this.username,
    required this.roleNames,
    this.createdAt,
    this.lastLoginAt,
    this.stationAccount = false,
    this.allowedPages,
    this.inactivityTimeoutMinutes,
  });

  final String username;

  /// Every role the account holds, primary first, deduplicated and trimmed.
  final List<String> roleNames;

  /// As stored. See [AccessAccountService._accounts].
  final String? createdAt;

  /// As stored, or null for an account that has never signed in.
  final String? lastLoginAt;

  /// A panel, not a person: its sessions never expire.
  final bool stationAccount;

  /// The account's own page whitelist, or null to follow its roles'.
  final Set<String>? allowedPages;

  /// The account's own idle window in minutes, or null for the default.
  final int? inactivityTimeoutMinutes;

  /// The reserved row every logged-out panel answers as.
  bool get isAnonymous => username == kAnonymousUsername;
}

/// Both authorization tables as of one read, with the questions the tools ask
/// answered in one place so the two front ends cannot drift.
class AccessAccountSnapshot {
  const AccessAccountSnapshot({
    required this.roles,
    required this.accounts,
    required this.tablesPresent,
  });

  /// A station whose schema predates the access tables — or one whose
  /// database would not answer.
  static const AccessAccountSnapshot missing = AccessAccountSnapshot(
    roles: <AccessRoleRecord>[],
    accounts: <AccessAccountRecord>[],
    tablesPresent: false,
  );

  final List<AccessRoleRecord> roles;
  final List<AccessAccountRecord> accounts;
  final bool tablesPresent;

  /// The role named [name], or null.
  AccessRoleRecord? role(String name) {
    for (final record in roles) {
      if (record.name == name) return record;
    }
    return null;
  }

  /// The account named [username], or null. Case-sensitive, like the column.
  AccessAccountRecord? account(String username) {
    for (final record in accounts) {
      if (record.username == username) return record;
    }
    return null;
  }

  /// The reserved anonymous row, or null when the seed has not run.
  AccessAccountRecord? get anonymous => account(kAnonymousUsername);

  /// Every account that is a person or a panel — everything but the
  /// reserved row.
  List<AccessAccountRecord> get people =>
      [for (final a in accounts) if (!a.isAnonymous) a];

  /// The usernames holding [roleName] — as primary or as an extra — sorted.
  ///
  /// The anonymous row counts: it holds a role like any other account, and
  /// the repository's own in-use check counts it too, so a delete the agent
  /// is told is free must be free at the accept.
  List<String> holdersOf(String roleName) => [
        for (final a in accounts)
          if (a.roleNames.contains(roleName)) a.username,
      ]..sort();

  /// The roles [account] holds that no longer exist. Each grants nothing.
  List<String> missingRolesOf(AccessAccountRecord account) => [
        for (final name in account.roleNames)
          if (role(name) == null) name,
      ];

  /// Everything [account] may do: the union of every role it holds that
  /// exists. A named role with no row grants nothing, which is the
  /// fail-closed direction the app's own resolver takes.
  Set<AccessGroup> effectiveGroups(AccessAccountRecord account) =>
      unionRoleGroups([
        for (final name in account.roleNames)
          if (role(name) case final r?) r.role,
      ]);

  /// The groups a logged-out panel holds right now.
  ///
  /// Read from the anonymous row's roles, like the app does. When the row is
  /// missing the app falls back to the `Operator` role, and then to the seeded
  /// `{operate}`; the same two steps here, so the floor this reports is the
  /// floor the panel enforces.
  Set<AccessGroup> get anonymousGroups {
    final row = anonymous;
    if (row != null && effectiveGroupsResolvable(row)) {
      return effectiveGroups(row);
    }
    final operator = role(kOperatorRoleName);
    if (operator != null) return operator.role.groups;
    return kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups;
  }

  /// Whether [account]'s **primary** role exists. Without it the app builds
  /// no session on the row at all — a missing extra merely grants nothing.
  bool effectiveGroupsResolvable(AccessAccountRecord account) =>
      account.roleNames.isNotEmpty && role(account.roleNames.first) != null;

  /// The names of every role that grants [AccessGroup.users], sorted.
  List<String> get rolesGrantingUsers => [
        for (final r in roles)
          if (r.role.can(AccessGroup.users)) r.name,
      ]..sort();

  /// The accounts able to manage roles and accounts — every person or panel
  /// holding at least one role that grants `users`. The anonymous row is
  /// excluded, exactly as the repository's lockout guard excludes it: a
  /// logged-out panel holding `users` is not somebody who can be asked to
  /// fix a lockout.
  List<String> get usersHolders => [
        for (final a in people)
          if (effectiveGroups(a).contains(AccessGroup.users)) a.username,
      ]..sort();

  /// Whether the first-user window is open: no person has an account, so
  /// whoever reaches the station first can create the Engineering one.
  bool get firstUserWindowOpen => people.isEmpty;
}
