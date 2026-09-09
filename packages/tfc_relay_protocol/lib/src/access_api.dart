/// The four access families the wire may expose, and the shapes they exchange.
///
/// Templates, roles-and-users, the audit trail and the backend's own
/// configuration: the four things gateway mode could not say before Phase 17.
/// Declarations only — nothing here implements anything, exactly as
/// `state_man_api.dart` declares and implements nothing.
///
/// ## Why these are declared in one place
///
/// `state_man_api.dart`'s own rule governs this file too: *a method that exists
/// is a thing any connected client may invoke, so adding one is an
/// access-control decision, not a convenience*. Twenty-eight such decisions
/// discovered a handler at a time is twenty-eight decisions nobody made. They
/// are here so a reviewer sees the whole surface at once, and
/// `test/access_api_test.dart` plus the contract kit's `api_surface_test.dart`
/// are where the count is written down.
///
/// ## Why this package now depends on `tfc_access`
///
/// `AccessGroup`, `AccessRole`, `AccessTemplate`, `AuthenticatedUser` and
/// `AuditRecord` are declared once, in the master access-control package, and
/// imported here. The alternative was restating the seven group names as this
/// package's own wire strings, which is the duplication Phase 17 exists to
/// delete. See `pubspec.yaml` for the four grounds on which the edge is safe
/// and for the reverse edge that stays forbidden.
///
/// ## The seam a reader will ask about
///
/// `AuditQuery`, `AuditTrailFilters` and `AuditWindow` live in
/// `packages/tfc_dart/lib/core/access/audit_trail_store.dart` — in `tfc_dart`,
/// which carries drift, `logger` and the open62541 FFI and which this package
/// may **not** import. So [AuditQueryParams] is the query's protocol shape,
/// declared here and mapped at both ends, exactly as
/// `backend_data_services.dart` already maps drift's generated row classes onto
/// this package's plain records. The rows travel as [AuditRecord], which is
/// `tfc_access`'s own declaration and is therefore not a third shape.
///
/// ## Two structural decisions, both load-bearing
///
///  * **[AuditApi] is read-only, by construction.** There is no `record`
///    member and no member that returns nothing. The relay writes its own rows
///    through the injected `AuditSink` (D-05), server-side, where the `who`,
///    the `station` and the `roleName` come from an identity the server
///    verified by constant-time digest compare. A wire method a client could
///    write an arbitrary audit row through would be a forgery surface, not an
///    audit trail.
///  * **No member takes a caller-supplied identity** (ACCESS-06, D-11). The
///    subject of an administration is spelled `subject` and the role being
///    granted `newRole` / `grantedRole`, following `AuditRecord`'s own
///    factories, which already spell the actor `who:` and the administered
///    thing `subject:`. `origin` is absent for the same reason as `who`: it is
///    the column that says a row came from the relay rather than from a
///    keyboard, and a client that could set it could dress a wire write up as
///    an operator's. The server sets it to `'relay'`.
///
/// Every write member takes an optional `reason`, which is the operator's own
/// justification and lands in the audit row's `reason` column. That is not an
/// identity: it says *why*, never *who*.
library;

import 'dart:convert';

import 'package:tfc_access/tfc_access.dart';

// -----------------------------------------------------------------------------
// The four families
// -----------------------------------------------------------------------------

/// Access templates and the key bindings that point at them.
///
/// The nine member names are `AccessTemplateStore`'s verbatim
/// (`packages/tfc_dart/lib/core/access/access_template_store.dart`), because
/// that is what lets `AccessMethods.templateMethods` be compared against this
/// interface by reflection in both directions, and because a wire that renamed
/// them would be a third vocabulary for one concept.
///
/// The store's `template(name)` single-row read is **deliberately not here**.
/// The access audit found no caller anywhere — including the store itself,
/// which reads rows through its private `_row()` — so it would have been wire
/// surface nobody uses. A remote implementation that wants one template
/// derives it client-side from [list()]: same snapshot semantics, zero extra
/// wire names.
///
/// Every write requires `AccessGroup.users`
/// (`AccessPolicy.groupForTemplate`) and the check happens **server-side**.
/// Nothing here carries a permission, an answer about a permission, or a
/// session; a client asks and the far end decides.
abstract interface class AccessTemplateApi {
  /// Every template, for the templates section.
  Future<List<AccessTemplate>> list();

  /// Every key→template binding, keyed by key name.
  Future<Map<String, String>> bindings();

  /// The keys bound to [templateName].
  Future<List<String>> keysBoundTo(String templateName);

  /// Stores a new template.
  Future<void> create(AccessTemplate value, {String? reason});

  /// Re-scopes an existing template.
  Future<void> update(AccessTemplate value, {String? reason});

  /// Moves a template's name, carrying its bindings with it.
  Future<void> rename(String from, String to, {String? reason});

  /// Destroys the template named [name] and every binding onto it.
  Future<void> delete(String name, {String? reason});

  /// Points [keyName] at [templateName].
  Future<void> bind(String keyName, String templateName, {String? reason});

  /// Clears [keyName]'s binding — which changes who may write that key just as
  /// much as setting one does.
  Future<void> unbind(String keyName, {String? reason});
}

/// Roles and accounts.
///
/// The eleven member names are `AccessAdminStore`'s verbatim. The two reads are
/// ungated at the store, on that file's own reasoning that a read is not an
/// authorization change; the nine writes require `AccessGroup.users`
/// (`AccessPolicy.groupForAdmin`), server-side.
///
/// **The parameter names deliberately differ from the store's.** The store
/// takes `username` and `roleName`; this interface takes `subject` and
/// `newRole` / `grantedRole`. `AuditRecord` spells the actor `who:` and the
/// administered account `subject:`, and on the wire those two must not share a
/// name — a handler that passed the frame's `roleName` into the row's
/// `roleName` column would look correct at the call site and would be recording
/// the caller's authority as whatever the caller said it was.
/// `test/access_api_test.dart`'s arm 5 is the mechanical half of that.
abstract interface class AccessAdminApi {
  /// Every role, for the roles section.
  Future<List<AccessRole>> roles();

  /// Every account, ordered by username.
  ///
  /// [UserSummary] rather than the database's own row class, and the choice is
  /// a safety property rather than a convenience: that class carries **no
  /// password-specific fields at all**, so no password hash can reach this wire
  /// by somebody forgetting to strip it. There is nowhere to put one.
  ///
  /// It was [AuthenticatedUser] until 17-08's F-1. That type is a *session
  /// identity* — who the far end decided you are — and it has no room for the
  /// two columns the users screen renders, so gateway mode drew `createdAt` as
  /// epoch zero and `lastLoginAt` as "never" for every account. Reusing an
  /// identity as a roster row was the mistake; [UserSummary] is the roster row.
  Future<List<UserSummary>> listUsers();

  /// Creates the role [role].
  Future<void> createRole(AccessRole role, {String? reason});

  /// Replaces [role]'s group set — the most consequential hand-made write in
  /// the product, and the reason the `admin` audit surface exists.
  Future<void> updateRole(AccessRole role, {String? reason});

  /// Destroys the role named [name].
  Future<void> deleteRole(String name, {String? reason});

  /// Renames a role, carrying its holders with it.
  Future<void> renameRole(String from, String to, {String? reason});

  /// Creates an account. See [NewUserParams] for why the password travels in a
  /// params object rather than as a bare argument.
  Future<void> createUser(NewUserParams params);

  /// Deletes the account [subject]. Its audit rows are untouched, and must
  /// stay that way.
  Future<void> deleteUser(String subject, {String? reason});

  /// Moves [subject] onto [newRole].
  Future<void> setUserRole(String subject, String newRole, {String? reason});

  /// Flips [subject]'s station-account flag — whether a signed-in panel ever
  /// signs itself out.
  Future<void> setUserStationAccount(String subject, bool value,
      {String? reason});

  /// Resets [subject]'s password. See [SetUserPasswordParams].
  Future<void> setUserPassword(SetUserPasswordParams params);
}

/// Reads of `audit_entry`, and nothing else.
///
/// The three member names are `AuditTrailStore`'s verbatim, and the store's own
/// doc says what this interface says structurally: *this object cannot deny and
/// cannot record*. There is no `record` member here and there never may be —
/// see the library doc. `test/access_api_test.dart`'s arm 8 asserts it twice
/// over: once by comparing the member set against `AccessMethods.auditMethods`,
/// and once by requiring every member to answer with data rather than with
/// nothing.
abstract interface class AuditApi {
  /// The rows matching [query], newest first.
  Future<List<AuditRecord>> entries(AuditQueryParams query);

  /// How many rows each of [actionIds] produced, for the trail viewer's
  /// grouping.
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds);

  /// Every distinct `who` in the table, for the filter bar's dropdown.
  ///
  /// A read about people, not an attribution of one: this family has no write
  /// member for a `who` to attach to.
  Future<List<String>> distinctWho();
}

/// The backend's own `state_man_config`, read and edited from a panel
/// (ACCESS-04, D-10).
///
/// All five require `AccessGroup.administer`
/// (`AccessPolicy.groupForBackendConfig`), server-side.
///
/// Two hazards are designed for rather than discovered:
///
///  * **A bad config can stop the backend coming back.** [write] round-trips
///    the submitted bytes through the config decoder and refuses rather than
///    writing on any failure; the previous file is kept, and [previous] /
///    [restorePrevious] make it reachable from the same screen. The backend
///    does not restart itself — restart-to-apply, matching the existing
///    config-watch behaviour.
///  * **The `relay` section configures the socket the edit arrives on.** It is
///    readable and not writable: [write] refuses a payload whose `relay`
///    section differs from the live one, by name. Editing sshd_config over ssh
///    is a thing people do and a thing people regret.
abstract interface class BackendConfigApi {
  /// The live configuration, and which of its sections may not be written.
  Future<BackendConfigDocument> read();

  /// Whether [configJson] would be accepted, and what is wrong with it if not.
  ///
  /// Separate from [write] so a screen can grey its Save button out before the
  /// operator has committed to anything.
  Future<ConfigValidation> validate(String configJson);

  /// Replaces the configuration, or refuses. Never partially applied.
  Future<void> write(String configJson, {String? reason});

  /// The configuration as it was before the last successful [write], or null
  /// when nothing has been overwritten yet.
  Future<BackendConfigDocument?> previous();

  /// Puts [previous] back. Refuses when there is nothing to restore.
  Future<void> restorePrevious({String? reason});
}

// -----------------------------------------------------------------------------
// The shapes they exchange
// -----------------------------------------------------------------------------

/// The default row limit for [AuditQueryParams], matching `kAuditTrailRowLimit`
/// in the store this query is mapped onto.
const int kAuditWireRowLimit = 500;

/// The protocol shape of an audit-trail query.
///
/// `AuditQuery` itself lives in `tfc_dart` and cannot be imported here; this is
/// the wire's version of it and the gateway maps one onto the other. Every
/// field is a value the far end validates: there is no statement, no
/// expression, no filter string, and no way to ask for a column that is not
/// already in an [AuditRecord].
///
/// [who] is a **filter**, not an attribution. This family has no write member,
/// so there is nothing here for a name to be recorded against — see the library
/// doc.
final class AuditQueryParams {
  const AuditQueryParams({
    this.startMs,
    this.endMs,
    this.beforeMs,
    this.keyPrefix = '',
    this.who,
    this.groupNames = const <String>[],
    this.includeAuth = false,
    this.allowed,
    this.limit = kAuditWireRowLimit,
  }) : assert((startMs == null) == (endMs == null),
            'a half-open window is not a window: both bounds or neither');

  /// Inclusive lower bound, epoch milliseconds UTC. Null with [endMs] means
  /// **the whole table** — the search escape.
  final int? startMs;

  /// Inclusive upper bound, epoch milliseconds UTC.
  final int? endMs;

  /// The "Load more" cursor: rows strictly older than this. Composes with the
  /// window rather than replacing it.
  final int? beforeMs;

  /// Matched against `item_key` as a prefix. Empty means no key constraint.
  final String keyPrefix;

  /// Exact match on `who`, or null for everybody.
  final String? who;

  /// The selected `group_required` values. Empty means no group constraint at
  /// all — the semantics the operator has already learned from the alarm level
  /// chips, and the reason it is written down at both ends.
  final List<String> groupNames;

  /// Whether `surface = 'auth'` rows are OR'd in.
  final bool includeAuth;

  /// True for allowed rows only, false for refusals only, null for both.
  ///
  /// A nullable bool rather than a third enum: `AuditOutcomeFilter` lives in
  /// `tfc_dart` and re-declaring it here would be a second vocabulary for three
  /// states that a nullable bool already says exactly.
  final bool? allowed;

  /// Applied after every filter, never instead of one.
  final int limit;

  Map<String, Object?> toJson() => <String, Object?>{
        if (startMs != null) 'startMs': startMs,
        if (endMs != null) 'endMs': endMs,
        if (beforeMs != null) 'beforeMs': beforeMs,
        'keyPrefix': keyPrefix,
        if (who != null) 'who': who,
        'groupNames': groupNames,
        'includeAuth': includeAuth,
        if (allowed != null) 'allowed': allowed,
        'limit': limit,
      };

  static AuditQueryParams fromJson(Map<String, Object?> json) =>
      AuditQueryParams(
        startMs: json['startMs'] as int?,
        endMs: json['endMs'] as int?,
        beforeMs: json['beforeMs'] as int?,
        keyPrefix: (json['keyPrefix'] as String?) ?? '',
        who: json['who'] as String?,
        groupNames: <String>[
          for (final name in (json['groupNames'] as List<Object?>?) ??
              const <Object?>[])
            if (name is String) name,
        ],
        includeAuth: (json['includeAuth'] as bool?) ?? false,
        allowed: json['allowed'] as bool?,
        limit: (json['limit'] as int?) ?? kAuditWireRowLimit,
      );

  @override
  String toString() => 'AuditQueryParams(window: '
      '${startMs == null ? "whole table" : "$startMs..$endMs"}, '
      'before: $beforeMs, keyPrefix: "$keyPrefix", who: $who, '
      'groups: $groupNames, auth: $includeAuth, allowed: $allowed, '
      'limit: $limit)';
}

/// The arguments of [AccessAdminApi.createUser].
///
/// A params object rather than three bare arguments for one reason: **it
/// carries a credential**, and a class can withhold it from [toString] where a
/// parameter list cannot. The value crosses inside the `wss://` frame and is
/// hashed **server-side** by the existing `PasswordHasher`; no digest is
/// computed on the client, because a client-computed digest *is* the password —
/// it is the thing that would then be sufficient to authenticate.
///
/// The withholding is `TlsConfig`'s "paths, never bytes" discipline applied to
/// the one field here with the same problem: `toString` output reaches log
/// files that live longer and travel further than the database does. It is
/// withheld from [toString] and **only** from [toString]; [toJson] carries it,
/// because the far end has to receive it.
final class NewUserParams {
  const NewUserParams({
    required this.subject,
    required this.password,
    required this.grantedRole,
    this.reason,
  });

  /// The account being created. Named `subject` and not `username` because
  /// `AuditRecord` spells the actor `who:` and the administered thing
  /// `subject:`, and the two must not share a name on the wire.
  final String subject;

  /// The initial credential. Withheld from [toString]; see the class doc.
  final String password;

  /// The role the new account holds. Named `grantedRole` and not `roleName`
  /// because `AuditRecord.roleName` means *the caller's* role.
  final String grantedRole;

  /// The operator's justification, for the audit row. Says why, never who.
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'subject': subject,
        'password': password,
        'grantedRole': grantedRole,
        if (reason != null) 'reason': reason,
      };

  static NewUserParams fromJson(Map<String, Object?> json) => NewUserParams(
        subject: json['subject'] as String,
        password: json['password'] as String,
        grantedRole: json['grantedRole'] as String,
        reason: json['reason'] as String?,
      );

  @override
  String toString() =>
      'NewUserParams(subject: $subject, grantedRole: $grantedRole, '
      'password: <withheld>)';
}

/// The arguments of [AccessAdminApi.setUserPassword].
///
/// Same discipline, same reasons, as [NewUserParams] — see that class.
final class SetUserPasswordParams {
  const SetUserPasswordParams({
    required this.subject,
    required this.password,
    this.reason,
  });

  /// The account whose password is being reset.
  final String subject;

  /// The new credential. Withheld from [toString].
  final String password;

  /// The operator's justification, for the audit row.
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
        'subject': subject,
        'password': password,
        if (reason != null) 'reason': reason,
      };

  static SetUserPasswordParams fromJson(Map<String, Object?> json) =>
      SetUserPasswordParams(
        subject: json['subject'] as String,
        password: json['password'] as String,
        reason: json['reason'] as String?,
      );

  @override
  String toString() =>
      'SetUserPasswordParams(subject: $subject, password: <withheld>)';
}

/// A backend configuration document, as it crosses the wire.
///
/// The configuration travels as **text**, not as a decoded map, and that is
/// deliberate: the operator edits the file, comments and key order included,
/// and a screen that round-tripped it through a decoder would silently rewrite
/// things nobody asked it to rewrite.
final class BackendConfigDocument {
  const BackendConfigDocument({
    required this.configJson,
    this.readOnlySections = const <String>[],
    this.hasPrevious = false,
  });

  /// The document itself.
  final String configJson;

  /// Sections the far end will refuse to write, so the screen can grey them
  /// rather than letting an operator type into a field that cannot be saved.
  ///
  /// `relay` is in here, always: it configures the socket the edit arrives on.
  final List<String> readOnlySections;

  /// Whether a [BackendConfigApi.previous] document exists to restore.
  final bool hasPrevious;

  Map<String, Object?> toJson() => <String, Object?>{
        'configJson': configJson,
        'readOnlySections': readOnlySections,
        'hasPrevious': hasPrevious,
      };

  static BackendConfigDocument fromJson(Map<String, Object?> json) =>
      BackendConfigDocument(
        configJson: json['configJson'] as String,
        readOnlySections: <String>[
          for (final section in (json['readOnlySections'] as List<Object?>?) ??
              const <Object?>[])
            if (section is String) section,
        ],
        hasPrevious: (json['hasPrevious'] as bool?) ?? false,
      );

  @override
  String toString() => 'BackendConfigDocument(${configJson.length} chars, '
      'readOnly: $readOnlySections, hasPrevious: $hasPrevious)';
}

/// What [BackendConfigApi.validate] answers.
///
/// [problems] is a list of sentences an operator can read, not a decoder's
/// exception text: the panel showing them is the last place before a backend
/// that will not come back.
final class ConfigValidation {
  const ConfigValidation({
    required this.ok,
    this.problems = const <String>[],
  });

  /// True when the document would be written as submitted.
  final bool ok;

  /// Why not, when [ok] is false. Empty when it is true.
  final List<String> problems;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'problems': problems,
      };

  static ConfigValidation fromJson(Map<String, Object?> json) =>
      ConfigValidation(
        ok: (json['ok'] as bool?) ?? false,
        problems: <String>[
          for (final problem in (json['problems'] as List<Object?>?) ??
              const <Object?>[])
            if (problem is String) problem,
        ],
      );

  @override
  String toString() => 'ConfigValidation(ok: $ok, problems: $problems)';
}

// -----------------------------------------------------------------------------
// Codecs for the tfc_access types these families exchange
// -----------------------------------------------------------------------------
//
// Free functions rather than methods on those classes, because tfc_access is
// the master vocabulary and knows nothing about a wire. Each one goes through
// that package's own encoders — encodeRules, encodeGroups, AccessGroup.name —
// so no field is spelled a second time here.

/// [AccessTemplate] as a JSON map.
Map<String, Object?> accessTemplateToJson(AccessTemplate value) =>
    <String, Object?>{
      'name': value.name,
      'rules': AccessTemplate.encodeRules(value.rules),
    };

/// The inverse of [accessTemplateToJson].
///
/// Rule decoding is `AccessTemplate.decodeRules`', which is deliberately
/// forgiving: a member graded with a group name this build has never heard of
/// is dropped rather than throwing, so a panel on an older build still renders
/// the templates screen.
AccessTemplate accessTemplateFromJson(Map<String, Object?> json) =>
    AccessTemplate(
      name: json['name'] as String,
      rules: AccessTemplate.decodeRules((json['rules'] as String?) ?? ''),
    );

/// [AccessRole] as a JSON map.
Map<String, Object?> accessRoleToJson(AccessRole value) => <String, Object?>{
      'name': value.name,
      'groups': value.encodeGroups(),
      'seeded': value.seeded,
    };

/// The inverse of [accessRoleToJson], through `AccessRole.fromDb` so the
/// forgiving group decode is the same one the database path uses.
AccessRole accessRoleFromJson(Map<String, Object?> json) => AccessRole.fromDb(
      name: json['name'] as String,
      groupsJson: (json['groups'] as String?) ?? '[]',
      seeded: (json['seeded'] as bool?) ?? false,
    );

/// [AuthenticatedUser] as a JSON map.
///
/// Four fields, and there is no fifth: this type carries no hash, no salt and
/// no token. It is the **session identity** — what `hello` answers — and not a
/// roster row; [AccessAdminApi.listUsers] answers [UserSummary] instead, for
/// the reasons that class records.
Map<String, Object?> authenticatedUserToJson(AuthenticatedUser value) =>
    <String, Object?>{
      'username': value.username,
      'roleName': value.roleName,
      'displayName': value.displayName,
      'stationAccount': value.stationAccount,
    };

/// The inverse of [authenticatedUserToJson].
AuthenticatedUser authenticatedUserFromJson(Map<String, Object?> json) =>
    AuthenticatedUser(
      username: json['username'] as String,
      roleName: json['roleName'] as String,
      displayName: json['displayName'] as String?,
      stationAccount: (json['stationAccount'] as bool?) ?? false,
    );

/// One row of the users roster, for [AccessAdminApi.listUsers].
///
/// **Not [AuthenticatedUser].** That type answers "who is this session?" — it
/// is minted from a verified sign-in and it is what `hello` hands back. This
/// one answers "what does the roster show?", which is a different question with
/// two extra columns: when the account was made and when it was last used. They
/// were conflated until 17-08's F-1, and the cost was a users screen that drew
/// 1970-01-01 for every account on a gateway station, because the identity type
/// had nowhere to carry a date and the panel filled the hole with epoch zero.
///
/// **There is still no credential field, and there must never be one.** That
/// property is the reason `listUsers` does not simply answer `app_user`'s drift
/// row: a hash cannot reach this wire by somebody forgetting to strip it,
/// because there is nowhere to put one.
///
/// Both timestamps are nullable, and they mean different things:
///
///  * [lastLoginAt] null means **never signed in**, which is a fact about the
///    account and is what the screen renders as "never".
///  * [createdAt] null means **this server did not say** — an older backend
///    that predates this DTO. Every `app_user` row has a `created_at`, so a
///    null here is a statement about the wire, never about the account. The
///    panel renders it as unknown rather than inventing a date.
final class UserSummary {
  const UserSummary({
    required this.username,
    required this.roleName,
    this.displayName,
    this.stationAccount = false,
    this.hasPassword = true,
    this.createdAt,
    this.lastLoginAt,
  });

  /// The account name — `app_user.username`, the primary key.
  final String username;

  /// The single role the account holds.
  final String roleName;

  /// A friendlier name to show instead of [username], when there is one.
  /// `app_user` has no such column today, so this is null from the database
  /// path; it exists because the wire should not need a revision to carry one.
  final String? displayName;

  /// A station account's sessions never expire. See `AppUser.stationAccount`.
  final bool stationAccount;

  /// Whether the account has a password at all.
  ///
  /// False means it signs in on its username alone — anybody standing at the
  /// panel can hold its role. One bit, and **not a credential**: it says that
  /// there is nothing to steal, not what the thing to steal is. The roster is
  /// gated on `users` either way.
  ///
  /// It is carried because the users screen has to mark these accounts. A
  /// roster that draws an open account exactly like a protected one is the
  /// failure mode the whole feature has to avoid.
  ///
  /// Defaults to true, which is what a backend older than this field means:
  /// before passwordless accounts existed, every account had one. Assuming
  /// "protected" for an unknown is the safe direction — it under-claims rather
  /// than telling somebody an account is open when it is not.
  final bool hasPassword;

  /// When the account was created, or null when the server did not say.
  final DateTime? createdAt;

  /// When the account last signed in, or null when it never has.
  final DateTime? lastLoginAt;

  @override
  String toString() => 'UserSummary($username, role: $roleName, '
      'station: $stationAccount, password: $hasPassword, '
      'created: $createdAt, lastLogin: $lastLoginAt)';
}

/// [UserSummary] as a JSON map.
///
/// Timestamps travel as epoch milliseconds UTC under `createdAtMs` /
/// `lastLoginAtMs`, the spelling [auditRecordToJson] already uses for `atMs`:
/// one integer, no timezone to disagree about, and no ISO-8601 string for two
/// ends to parse differently. Both keys are omitted when null rather than sent
/// as an explicit null — 17-06 recorded what a present-null field costs (every
/// create/update/delete answering `-32602`), so absence is spelled by absence.
Map<String, Object?> userSummaryToJson(UserSummary value) => <String, Object?>{
      'username': value.username,
      'roleName': value.roleName,
      if (value.displayName != null) 'displayName': value.displayName,
      'stationAccount': value.stationAccount,
      'hasPassword': value.hasPassword,
      if (value.createdAt != null)
        'createdAtMs': value.createdAt!.toUtc().millisecondsSinceEpoch,
      if (value.lastLoginAt != null)
        'lastLoginAtMs': value.lastLoginAt!.toUtc().millisecondsSinceEpoch,
    };

/// The inverse of [userSummaryToJson].
///
/// A missing timestamp key decodes to null, which is what lets a panel on this
/// build talk to a backend that predates the DTO without throwing: it renders
/// the created column as unknown instead of failing the whole roster.
UserSummary userSummaryFromJson(Map<String, Object?> json) => UserSummary(
      username: json['username'] as String,
      roleName: json['roleName'] as String,
      displayName: json['displayName'] as String?,
      stationAccount: (json['stationAccount'] as bool?) ?? false,
      hasPassword: (json['hasPassword'] as bool?) ?? true,
      createdAt: _utcFromMs(json['createdAtMs']),
      lastLoginAt: _utcFromMs(json['lastLoginAtMs']),
    );

/// Epoch milliseconds to a UTC [DateTime], or null when the key was absent.
DateTime? _utcFromMs(Object? ms) => ms == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch((ms as num).toInt(), isUtc: true);

/// [AuditRecord] as a JSON map — every column of `audit_entry`, and the
/// instant as epoch milliseconds UTC.
Map<String, Object?> auditRecordToJson(AuditRecord value) => <String, Object?>{
      'atMs': value.at.toUtc().millisecondsSinceEpoch,
      'who': value.who,
      'station': value.station,
      'roleName': value.roleName,
      'surface': value.surface,
      'itemKey': value.itemKey,
      if (value.member != null) 'member': value.member,
      if (value.oldValue != null) 'oldValue': value.oldValue,
      if (value.newValue != null) 'newValue': value.newValue,
      'groupRequired': value.groupRequired,
      'allowed': value.allowed,
      'origin': value.origin,
      'actionId': value.actionId,
      if (value.reason != null) 'reason': value.reason,
    };

/// The inverse of [auditRecordToJson].
///
/// A row read back out of the trail, never a row a client asked to have
/// written: [AuditApi] has no member that takes one of these.
AuditRecord auditRecordFromJson(Map<String, Object?> json) => AuditRecord(
      at: DateTime.fromMillisecondsSinceEpoch(json['atMs'] as int,
          isUtc: true),
      who: json['who'] as String,
      station: json['station'] as String,
      roleName: json['roleName'] as String,
      surface: json['surface'] as String,
      itemKey: json['itemKey'] as String,
      member: json['member'] as String?,
      oldValue: json['oldValue'] as String?,
      newValue: json['newValue'] as String?,
      groupRequired: json['groupRequired'] as String,
      allowed: json['allowed'] as bool,
      origin: (json['origin'] as String?) ?? 'operator',
      actionId: json['actionId'] as String,
      reason: json['reason'] as String?,
    );

/// The wire spelling of an [AccessGroup]: its `name`, and nothing invented.
///
/// The inverse is `AccessGroup.byName`, which returns **null** for a name this
/// build has never heard of rather than throwing — a station running a newer
/// build may have written one, and "not granted" is the safe reading of a group
/// nobody here can evaluate. A throw would be a panel that cannot render the
/// roles screen at all because one row mentions a group it does not know.
String accessGroupToWire(AccessGroup group) => group.name;

/// Decodes a JSON-encoded list of group names, dropping any this build does not
/// know — `AccessRole.decodeGroups`' rule, applied to a bare list.
Set<AccessGroup> accessGroupsFromWire(String json) {
  if (json.isEmpty) return const <AccessGroup>{};
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const <AccessGroup>{};
  }
  if (decoded is! List) return const <AccessGroup>{};
  return <AccessGroup>{
    for (final name in decoded)
      if (name is String && AccessGroup.byName(name) != null)
        AccessGroup.byName(name)!,
  };
}
