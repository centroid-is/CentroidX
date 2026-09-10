/// The backend's three access families: templates, roles-and-users and the
/// audit trail, served over the **same store classes the panel calls** in
/// direct mode (17-02 moved them here so this file could exist).
///
/// ## This file maps and delegates, and decides nothing
///
/// The `users` gate, the deny-row-before-throw ordering, the last-`users`-
/// holder invariant `AccessRepository` evaluates inside its own transaction,
/// the named `AuditRecord` constructors that fix the itemKey vocabulary in one
/// place — all of that is written, tested and shipping in
/// `../access/access_template_store.dart`, `../access/access_admin_store.dart`
/// and `../access/access_repository.dart`. This file holds a database handle,
/// constructs those stores with the session the relay resolved, and maps
/// types. `backend_access_test.dart`'s arm 10 greps this source, comments
/// stripped, for the two permission-check tokens and requires zero: a correct
/// check added here would be a second gate, and a second gate is what the
/// phase's constitution forbids.
///
/// ## Where Phase 13's `…Source` seam went
///
/// `backend_data_services.dart` puts a `…Source` interface between drift and
/// the protocol because `AppDatabase`'s generated methods are not an interface
/// and cannot be faked. The access stores are that seam already: they are
/// constructible over an in-memory `AppDatabase` (the store tests do exactly
/// that), they declare the exact member sets the wire mirrors, and they return
/// `tfc_access`'s own types, which the protocol imports rather than restates.
/// A `…Source` interface here would re-declare twenty-odd members with no
/// consumer — a third spelling of one vocabulary, in the phase whose whole
/// point is deleting the second one.
///
/// ## One store per family object, built at construction
///
/// Cached per identity rather than built per call: each `Backend…` is
/// constructed for one relay identity, whose station and username are fixed
/// for the life of the connection. The **session stays a callback** —
/// `AccessSession Function()`, the shape every other construction site of
/// these stores uses — because on the panel the inactivity monitor drops an
/// operator back to anonymous mid-life, and the one construction site with a
/// captured value would be the one a later reader has to explain. Per-call
/// construction would buy nothing over that callback and cost an allocation
/// per request.
///
/// ## `origin` is `'relay'`
///
/// D-05: a trail reader must be able to tell a wire write from a panel write.
/// The stores already take `origin` on every write, defaulting to
/// `'operator'`; this file passes [kRelayOrigin] on each one, deny rows
/// included. No store was edited.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../access/access_admin_store.dart';
import '../access/access_repository.dart';
import '../access/access_template_store.dart';
import '../access/audit_trail_store.dart';
import '../database_drift.dart';

/// The `origin` every row written through this file carries.
///
/// The fourth value beside `operator` and `mcp` (and `auth`'s own rows): it
/// says the action arrived over the WebSocket, attributed to a station account
/// the server verified — never to a name a client supplied (D-11).
const String kRelayOrigin = 'relay';

/// The refusal every family below mints when it was composed without a
/// database.
///
/// The shape is `backend_alarm_history.dart:450`'s `_require`, and the
/// reasoning is P-12's: three things, always, in this order — the member as it
/// is spelled on the interface, the collaborator that is missing, and one
/// sentence saying what to change. Deliberately not "not implemented" and
/// never an empty answer: a data service that answered "no templates" because
/// nobody wired a database is indistinguishable, from every screen, from a
/// plant that has no templates.
Never _missingDatabase(String qualifiedMember, String consequence) =>
    throw UnsupportedError('$qualifiedMember is not available: this family '
        'was composed without the backend\'s AppDatabase, so $consequence '
        'Hand the database to the access families where the relay identity is '
        'minted (bin/main.dart\'s relay block).');

// ============================================================ template family

/// `AccessTemplateApi` over [AccessTemplateStore] — the same class, the same
/// gate, the same audit rows as a panel in direct mode.
final class BackendAccessTemplates implements relay.AccessTemplateApi {
  /// [database] nullable on purpose: a backend composed without one still
  /// answers, by refusing every member by name. [session] is the relay
  /// identity's session, kept as a callback — see the library doc. [station]
  /// and the session's username are what every row this family writes is
  /// attributed to.
  BackendAccessTemplates({
    required AppDatabase? database,
    required AccessSession Function() session,
    required String station,
    required AuditSink audit,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  }) : _store = database == null
            ? null
            : AccessTemplateStore(
                db: database,
                session: session,
                audit: audit,
                station: station,
                onDenied: onDenied,
                logger: logger,
              );

  final AccessTemplateStore? _store;

  AccessTemplateStore _require(String member) =>
      _store ??
      _missingDatabase(
          'BackendAccessTemplates.$member',
          'there are no templates and no key bindings to serve — and "no '
              'templates configured" and "nobody wired a database" must not '
              'look the same from a screen.');

  @override
  Future<List<AccessTemplate>> list() async => _require('list').list();

  /// **Cut from the wire** (17-06 live correction): the protocol loses
  /// `accessTemplates.template`, and a remote needing one template derives it
  /// from [list]. This member exists only until the interface deletion lands
  /// and dies with it; it deliberately does not delegate to the store, so the
  /// backend cannot quietly keep serving a surface the wire no longer has.
  @override
  Future<AccessTemplate?> template(String name) async =>
      throw UnsupportedError('BackendAccessTemplates.template is not served: '
          'accessTemplates.template is cut from the wire; derive one template '
          'from list() instead.');

  @override
  Future<Map<String, String>> bindings() async =>
      _require('bindings').bindings();

  @override
  Future<List<String>> keysBoundTo(String templateName) async =>
      _require('keysBoundTo').keysBoundTo(templateName);

  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      _require('create')
          .create(value, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      _require('update')
          .update(value, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      _require('rename')
          .rename(from, to, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> delete(String name, {String? reason}) async =>
      _require('delete')
          .delete(name, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> bind(String keyName, String templateName, {String? reason}) async =>
      _require('bind')
          .bind(keyName, templateName, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> unbind(String keyName, {String? reason}) async =>
      _require('unbind')
          .unbind(keyName, origin: kRelayOrigin, reason: reason);
}

// =============================================================== admin family

/// `AccessAdminApi` over [AccessAdminStore], which wraps [AccessRepository] —
/// deliberately not the repository directly: the store owns the gate, the
/// deny-row ordering and the named row constructors, and the repository owns
/// `db.transaction` and the last-`users`-holder invariant. Reaching past the
/// store would remove every guarantee the plant has about role editing, which
/// is threat T-17-06a by name.
///
/// The wire's `subject` / `newRole` / `grantedRole` vocabulary maps onto the
/// store's `username` / `roleName` parameters here, at the one seam where the
/// two spellings meet — `AuditRecord` spells the actor `who:` and the
/// administered thing `subject:`, and the two must not share a name on the
/// wire (17-03's vocabulary ruling).
final class BackendAccessAdmin implements relay.AccessAdminApi {
  BackendAccessAdmin({
    required AppDatabase? database,
    required AccessSession Function() session,
    required String station,
    required AuditSink audit,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  }) : _store = database == null
            ? null
            : AccessAdminStore(
                repository: AccessRepository(database),
                session: session,
                audit: audit,
                station: station,
                onDenied: onDenied,
                logger: logger,
              );

  final AccessAdminStore? _store;

  AccessAdminStore _require(String member) =>
      _store ??
      _missingDatabase(
          'BackendAccessAdmin.$member',
          'there are no roles and no accounts to serve — and this is the '
              'family that can hand somebody force on a running line, so it '
              'says nothing at all rather than something incomplete.');

  @override
  Future<List<AccessRole>> roles() async => _require('roles').roles();

  /// Answered as [relay.UserSummary] — the type with **no password-specific
  /// fields at all**, so no hash can reach this wire by somebody forgetting to
  /// strip it.
  ///
  /// It answered [AuthenticatedUser] until 17-08's F-1 closed the wire gap that
  /// left with: a session identity has nowhere to put `created_at` or
  /// `last_login_at`, so a gateway station's users screen drew epoch zero in
  /// the created column for every account. Both columns are now carried, and
  /// `passwordHash` / `salt` still are not — there is nowhere to put them.
  ///
  /// `displayName` is null because `app_user` has no such column.
  @override
  Future<List<relay.UserSummary>> listUsers() async {
    final rows = await _require('listUsers').listUsers();
    return [
      for (final row in rows)
        relay.UserSummary(
          username: row.username,
          roleName: row.roleName,
          stationAccount: row.stationAccount,
          // One bit, not a credential: whether there is anything to verify.
          // The users screen marks accounts that sign in on a username alone,
          // and it cannot mark what it is not told.
          hasPassword: !isPasswordless(row.passwordHash),
          createdAt: row.createdAt,
          lastLoginAt: row.lastLoginAt,
        ),
    ];
  }

  @override
  Future<void> createRole(AccessRole role, {String? reason}) async =>
      _require('createRole')
          .createRole(role, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async =>
      _require('updateRole')
          .updateRole(role, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> deleteRole(String name, {String? reason}) async =>
      _require('deleteRole')
          .deleteRole(name, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> renameRole(String from, String to, {String? reason}) async =>
      _require('renameRole')
          .renameRole(from, to, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> createUser(relay.NewUserParams params) async =>
      _require('createUser').createUser(
        username: params.subject,
        password: params.password,
        roleName: params.grantedRole,
        origin: kRelayOrigin,
        reason: params.reason,
      );

  @override
  Future<void> deleteUser(String subject, {String? reason}) async =>
      _require('deleteUser')
          .deleteUser(subject, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> setUserRole(String subject, String newRole, {String? reason}) async =>
      _require('setUserRole')
          .setUserRole(subject, newRole, origin: kRelayOrigin, reason: reason);

  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) async =>
      _require('setUserStationAccount').setUserStationAccount(subject, value,
          origin: kRelayOrigin, reason: reason);

  @override
  Future<void> setUserPassword(relay.SetUserPasswordParams params) async =>
      _require('setUserPassword').setUserPassword(
        params.subject,
        params.password,
        origin: kRelayOrigin,
        reason: params.reason,
      );
}

// =============================================================== audit family

/// `AuditApi` over [AuditTrailStore] — read-only, exactly as the store is.
///
/// **The relay's own rows are written by the injected `AuditSink` (D-05,
/// 17-09), never through any wire method.** This class has no `record`
/// member and must not grow one: a wire method that let a client write an
/// audit row would be a forgery surface, not an audit trail — the row's `who`
/// and `station` come from an identity the server verified, and a
/// client-supplied row could name anybody.
///
/// The store is ungated by design (its enforcement in the app is the route
/// gate), and this class adds no gate of its own: wire-side grading of
/// `audit.*` is `PolicyStateMan`'s and lands in 17-07. Asserting a guard that
/// is not there is the decorative outcome 17-02 already corrected once.
final class BackendAudit implements relay.AuditApi {
  BackendAudit({required AppDatabase? database, Logger? logger})
      : _store = database == null
            ? null
            : AuditTrailStore(db: database, logger: logger);

  final AuditTrailStore? _store;

  AuditTrailStore _require(String member) =>
      _store ??
      _missingDatabase(
          'BackendAudit.$member',
          'there is no trail to read — and an empty audit trail is '
              'indistinguishable from a clean one, which is the one wrong '
              'answer a read-only family can give.');

  @override
  // A pass-through: the store already answers in `AuditRecord`. The
  // row-to-record mapping this method used to perform now lives on the store,
  // which is the only place that ever holds a drift row.
  //
  // `async` is load-bearing and not decoration. `_require` throws when no
  // database is wired, and every member of this family owes that refusal as a
  // **rejected future** rather than a synchronous throw — the arms in
  // `backend_access_test.dart` call each member inside `expectLater`, where a
  // synchronous throw escapes the matcher entirely. Dropping it here to make
  // the body an expression turned the refusal into a different kind of failure
  // and reddened arm 6.
  Future<List<AuditRecord>> entries(relay.AuditQueryParams query) async =>
      _require('entries').entries(_toQuery(query));

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async =>
      _require('memberCountsByAction').memberCountsByAction(actionIds);

  @override
  Future<List<String>> distinctWho() async =>
      _require('distinctWho').distinctWho();

  /// The wire's query onto the store's. Field for field; the only judgement
  /// call is `allowed` — the wire's nullable bool onto the store's
  /// three-state [AuditOutcomeFilter], which is the same three states with a
  /// name.
  static AuditQuery _toQuery(relay.AuditQueryParams params) {
    final startMs = params.startMs;
    final endMs = params.endMs;
    final beforeMs = params.beforeMs;
    return AuditQuery(
      window: startMs == null || endMs == null
          ? null
          : AuditWindow(
              start: DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true),
              end: DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true),
            ),
      before: beforeMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(beforeMs, isUtc: true),
      keyPrefix: params.keyPrefix,
      who: params.who,
      groupNames: params.groupNames,
      includeAuth: params.includeAuth,
      outcome: switch (params.allowed) {
        null => AuditOutcomeFilter.any,
        true => AuditOutcomeFilter.allowedOnly,
        false => AuditOutcomeFilter.deniedOnly,
      },
      limit: params.limit,
    );
  }

}
