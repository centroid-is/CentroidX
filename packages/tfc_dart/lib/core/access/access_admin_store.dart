/// Every write to `app_role` and `app_user`, behind one object and one gate.
///
/// A role decides what a group of people may do; an account decides which
/// person is in that group. Both are the authorization data itself, which is
/// why spec §1 puts them behind `users` rather than `administer` — `administer`
/// is server config, database, network and updates, which is station plumbing,
/// not who may do what.
///
/// This is the closure of the write-path sweep's §3.3 entry, which records
/// `AccessRepository` writing both tables through raw Drift as the one write
/// path deliberately left open, with *"Phase 6 gates it on `users`"* as the
/// closing condition. Plan 06-06 annotates the sweep once this holds.
///
/// ## Why the group is declared here rather than looked up
///
/// The same reasoning `access_template_store.dart` writes at
/// [kAccessTemplateGroup] and `guarded_history_views.dart` at
/// `kHistoryViewDeleteGroup`: neither table is a preference key, this store
/// consults no policy table, and a second source for one answer drifts. If you
/// are here to change what is gated, change [kAccessAdminGroup]; do not add a
/// rule to `kPrefAccessRules`.
///
/// ## The one thing this store must not do
///
/// It offers no delete, no prune and no export over `audit_entry`. The trail is
/// append-only, that property is currently enforced by absence, and this is the
/// file where somebody would first be tempted to break it — "clean up the rows
/// of the account I just deleted" is exactly the wrong instinct.
/// `audit_entry.who` is a denormalised TEXT column with no foreign key so that
/// a deleted account's rows survive it by construction. Do not add a cascade,
/// and do not add a method here that touches the trail.
library;

import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';
import 'access_repository.dart';

/// The `who` recorded when nobody is signed in.
const String _anonymousWho = 'anonymous';

/// The permission every write in this file requires — over **both** tables.
///
/// `users`, per spec §1: a role edit changes what a group of people may do and
/// an account edit changes who is in that group, which is the same concern as
/// templates and the trail, not machine configuration.
///
/// **What changing this line would mean.**
///
/// * Set it to [AccessGroup.configure] and anybody who can edit a page or a key
///   map could grant themselves `users`, and from there every other group. That
///   is the exact confusion the split between `configure` and `users` exists to
///   prevent (`access_group.dart`), and it would make the whole access model
///   decorative in one line. `access_admin_store_test.dart` drives a
///   `configure`-only session into all eight writes so that the line is checked
///   rather than remembered.
/// * Set it to [AccessGroup.administer] and you have reproduced the error in
///   `docs/access-control-deployment.md` §4, which speaks of "screens behind
///   the `administer` group, including the screen that creates users".
///   `administer` is server config, database, network and updates — the station
///   plumbing an integrator holds. It is not the authority to decide who may do
///   what, and the two are held by different people on purpose. Plan 06-05
///   fixes the sentence; this constant is what the code says in the meantime.
const AccessGroup kAccessAdminGroup = AccessGroup.users;

/// Builds this store's audit row for one action.
///
/// [session] is the session the gate read, so the deny row names whoever was
/// refused rather than whoever the session became a moment later. The builder
/// is what lets [AccessAdminStore._requireUsers] be shared across eight writes
/// whose rows are built by eight *different* named constructors: there is no
/// generic row builder in this file, and there must not be one.
typedef _RowBuilder = AuditRecord Function(
  AccessSession session,
  String actionId,
  bool allowed,
);

/// The eight writes that decide who may do what, and the two reads that show
/// it.
///
/// Writes — [createRole], [updateRole], [deleteRole], [renameRole],
/// [createUser], [deleteUser], [setUserRole], [setUserPassword] — all ask for
/// [kAccessAdminGroup] and all leave a row, denials included. Reads — [roles]
/// and [listUsers] — are ungated and unaudited: looking at the roster is not an
/// authorization change, and a row per render would bury the writes that
/// matter. The route the screen sits on is the enforcement for reads.
///
/// **Eight writes, eight itemKeys, and that is the whole list.** If you find
/// yourself adding a ninth, stop: it has no itemKey, which means it has no
/// audit row, which means it is not a write this store may perform. No disable,
/// no export, no bulk anything.
///
/// The itemKeys fall into two prefixes — `role.` and `user.` — which are
/// distinct strings, so a Phase 5 filter for one does not drag in the other.
/// That is the same idea `access_template_store.dart` applies one level down
/// with its `access_template.` / `access_key_binding.` prefixes.
///
/// ## Design decision 1: repository below, store above
///
/// No other file in this tree has both layers, and the split is deliberate
/// rather than incidental. `AccessTemplateStore` owns its Drift queries with
/// nothing beneath it; this store cannot, because `db.transaction` and the
/// last-`users`-holder invariant have to live in `packages/tfc_dart`, which has
/// no notion of an [AccessSession] and no [AuditSink] wiring. So:
///
/// * **The transaction, and every invariant that must be evaluated inside it,
///   live in [AccessRepository].** That is the only reason the repository layer
///   exists here. The lockout rule is not re-implemented in this file — it has
///   one home, and this store surfaces its refusal.
/// * **The permission question, the audit row and the required-group constant
///   live here.** [kAccessAdminGroup] is a store-layer fact: it is the gate
///   *this store* asks.
/// * **This store holds no `AppDatabase` and imports no Drift.** Its reads go
///   through the repository too, which turns "pages never touch Drift" into a
///   greppable property one layer higher — this file's Drift import count is
///   zero, and a test asserts it. A method that needs a `Value()` or a
///   `Companion` belongs in the repository, not here.
/// * **Pages talk to this store and to nothing else.** They never hold an
///   [AccessRepository].
///
/// ## Design decision 2: where the audit row goes, relative to the guard
/// inside the transaction
///
/// `AccessTemplateStore` records the allowed row **before** its statement, on
/// the principle that a delete of a template keys still name changed nothing
/// and must leave no row claiming it did. It can do that because every one of
/// its preconditions is checkable in the store. This store's lockout invariant
/// is exactly the one that is not: it is evaluated inside the repository's
/// transaction, which is precisely the condition this layer cannot pre-check
/// without reintroducing the race it was moved down there to close.
///
/// Three options, and the choice:
///
/// * **(iii) Write the audit row inside the same transaction — rejected.**
///   `DriftAuditSink` has one method and its test greps the source to keep it
///   that way; the Postgres audit role is INSERT-only into `audit_entry`, so a
///   row enlisted in an application transaction that later rolls back is
///   silently discarded — the opposite of what an append-only trail is for. It
///   would also couple every future sink, including a remote one over the relay
///   pipe, to Drift's transaction.
/// * **(ii) Pre-check in the store, guard again in the transaction, and record
///   before the statement — rejected.** A lost race writes a row for a write
///   that was then refused. That is a *false* row, and the whole value of the
///   trail is that every row in it is true.
/// * **(i) Record the permitted row after the repository call returns —
///   chosen.** The one window it leaves is a crash between `COMMIT` and the
///   sink call, which costs one true row. That is the failure mode the sink
///   already has and already logs as `AUDIT ROW LOST`. Given the choice between
///   possibly losing a true row and possibly writing a false one, lose the true
///   one.
///
/// **Denial rows keep the template store's ordering — recorded before the
/// throw** — because a deny row is the only evidence the guard fired and there
/// is nothing written for it to contradict. So the full order of every write in
/// this file is:
///
/// gate → (denied: record the deny row, call `onDenied`, throw) → call the
/// repository → (the repository threw [LastUsersHolderException],
/// [RoleInUseException], [UserExistsException], [UserNotFoundException],
/// [MissingRoleError] or [ProtectedRoleError]: record **nothing**, rethrow) →
/// record the allowed row.
///
/// If you move a `_recordAllowed` call above its repository call, five named
/// tests in `access_admin_store_test.dart` stop passing. They are there because
/// that is the edit somebody will make while tidying.
class AccessAdminStore {
  /// [session] is a **callback, not a value**, for the reason `HistoryViewStore`
  /// gives at its own constructor (`lib/core/guarded_history_views.dart`): this
  /// store is built per operation from providers that outlive any one session,
  /// and a captured [AccessSession] would keep granting whatever the operator
  /// held when it was built, after the inactivity monitor had already dropped
  /// them back to anonymous.
  ///
  /// [onDenied] fires **before** the [AccessDenied] is thrown, so the shared
  /// prompt (`lib/widgets/access_denied_prompt.dart`) appears even at a call
  /// site that swallows the exception.
  AccessAdminStore({
    required AccessRepository repository,
    required AccessSession Function() session,
    required AuditSink audit,
    required String station,
    void Function(AccessDenied denial)? onDenied,
    Logger? logger,
  })  : _repository = repository,
        _session = session,
        _audit = audit,
        _station = station,
        _onDenied = onDenied,
        _logger = logger ?? Logger();

  final AccessRepository _repository;
  final AccessSession Function() _session;
  final AuditSink _audit;
  final String _station;
  final void Function(AccessDenied denial)? _onDenied;

  /// This store's own diagnostic logger, for the audit-sink failures it
  /// swallows. Nothing else logs here — and in particular nothing logs a
  /// credential; see [setUserPassword].
  final Logger _logger;

  // ---------------------------------------------------------------------------
  // Reads — ungated, unaudited
  // ---------------------------------------------------------------------------

  /// Every role, for the roles section.
  Future<List<AccessRole>> roles() => _repository.roles();

  /// Every account, ordered by username, for the users section.
  ///
  /// [UserSummary], the same type [roles] answers `AccessRole` in: this
  /// file names no generated row type at all now, so the no-Drift-import
  /// rule it is held to holds plainly rather than through a carve-out.
  Future<List<UserSummary>> listUsers() => _repository.listUsers();

  // ---------------------------------------------------------------------------
  // Role writes
  // ---------------------------------------------------------------------------

  /// Creates the role [role]. Requires [kAccessAdminGroup].
  ///
  /// Throws [ArgumentError] when a role of that name already exists — the same
  /// refusal, in the same words, that [AccessRepository.renameRole] gives for a
  /// name collision. The repository's `upsertRole` would quietly turn this into
  /// an update, and the row would then say `role.create` for something that
  /// created nothing. The check runs **after** the gate, so an unprivileged
  /// caller is told about permission rather than about the name.
  Future<void> createRole(
    AccessRole role, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.roleCreate(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: role.name,
          groups: role.encodeGroups(),
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _roleCreate, row: row);

    if (await _repository.role(role.name) != null) {
      throw ArgumentError.value(
        role.name,
        'role.name',
        'a role named "${role.name}" already exists',
      );
    }
    await _repository.upsertRole(role);
    await _recordAllowed(actionId, row);
  }

  /// Replaces [role]'s group set. Requires [kAccessAdminGroup].
  ///
  /// **This is the most consequential hand-made write in the product**, and the
  /// `admin` surface exists for it: it is the one that can hand somebody
  /// `force` on a running line, and — when the row is `Operator` — hand it to
  /// every logged-out panel on the floor. The roles screen says so at the point
  /// of edit; the row says so afterwards.
  ///
  /// The current group set is read **before** the gate so that `oldValue` is
  /// available for the row. Reading before the gate is correct and already the
  /// convention: a read is not an authorization event, and this store's own
  /// reads are ungated for the same reason.
  ///
  /// Throws [MissingRoleError] when there is no such role — the repository's
  /// `upsertRole` would insert one, and the row would then say `role.update`
  /// for a create. Throws [LastUsersHolderException], from inside the
  /// repository's transaction, when this edit would untick `users` from the
  /// only role granting it; that refusal is trip route (c), it is not a
  /// permission failure, and no sign-in resolves it.
  Future<void> updateRole(
    AccessRole role, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final existing = await _repository.role(role.name);

    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.roleUpdate(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: role.name,
          // Empty when the role is not there — the only path that reaches the
          // row with a null `existing` is the deny path, and a refusal for
          // permission is the honest thing to say about it first.
          oldGroups: existing?.encodeGroups() ?? '',
          newGroups: role.encodeGroups(),
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _roleUpdate, row: row);

    if (existing == null) throw MissingRoleError(role.name);
    await _repository.upsertRole(role);
    await _recordAllowed(actionId, row);
  }

  /// Destroys the role named [name]. Requires [kAccessAdminGroup].
  ///
  /// The groups it granted are read **before** the gate, so the row still says
  /// what was lost after the row it described is gone.
  ///
  /// Three refusals reach the caller from the repository, unchanged and
  /// unrecorded, and none of them is an [AccessDenied]: [ProtectedRoleError]
  /// for `Operator` — an [Error], because reaching it means a screen offered a
  /// Delete it should not have; [LastUsersHolderException] for trip route (d),
  /// deleting the only role granting `users`; and [RoleInUseException] when
  /// accounts still hold it, with the holders named so the dialog can list
  /// them. That last one is blocked in application code rather than by the
  /// foreign key, which this build never enables.
  Future<void> deleteRole(
    String name, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final existing = await _repository.role(name);

    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.roleDelete(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: name,
          groups: existing?.encodeGroups() ?? '',
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _roleDelete, row: row);

    if (existing == null) throw MissingRoleError(name);
    await _repository.deleteRole(name);
    await _recordAllowed(actionId, row);
  }

  /// Renames the role [from] to [to], carrying its holders with it. Requires
  /// [kAccessAdminGroup].
  ///
  /// The row's `member` is [from] — the string the rest of the trail up to this
  /// point refers to.
  ///
  /// A rename cannot trip the lockout invariant: the role keeps its groups and
  /// its holders. It can still throw [ProtectedRoleError] at either end,
  /// [MissingRoleError] for an absent source and [ArgumentError] for a name
  /// collision, all from the repository and all recorded as nothing.
  Future<void> renameRole(
    String from,
    String to, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.roleRename(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          oldName: from,
          newName: to,
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _roleRename, row: row);

    await _repository.renameRole(from, to);
    await _recordAllowed(actionId, row);
  }

  // ---------------------------------------------------------------------------
  // User writes
  // ---------------------------------------------------------------------------

  /// Creates the account [username] in [roleName]. Requires
  /// [kAccessAdminGroup].
  ///
  /// [password] is taken only to hand it straight to the repository, which
  /// derives the hash. It is never logged, never interpolated into a
  /// string and never reaches the row: [AuditRecord.userCreate] has no
  /// parameter that could carry it, which is the point of the constructor.
  ///
  /// Throws [UserExistsException] for a name already taken and
  /// [MissingRoleError] for a role that is not there, both from inside the
  /// repository's transaction and both recorded as nothing.
  Future<void> createUser({
    required String username,
    required String password,
    required String roleName,
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.userCreate(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: username,
          grantedRole: roleName,
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _userCreate, row: row);

    await _repository.createUser(
      username: username,
      password: password,
      roleName: roleName,
    );
    await _recordAllowed(actionId, row);
  }

  /// Deletes the account [username]. Requires [kAccessAdminGroup].
  ///
  /// The role held is read **before** the gate so the row says what the account
  /// could do, after the account is gone.
  ///
  /// The account's own audit rows are untouched, and must stay that way:
  /// `audit_entry.who` is a denormalised TEXT column with no foreign key
  /// precisely so the trail survives this by construction.
  ///
  /// Throws [UserNotFoundException] for an account that is not there — a silent
  /// success would put a row in the trail claiming a deletion that did not
  /// happen — and [LastUsersHolderException] for trip route (a), deleting the
  /// last account that holds `users`.
  Future<void> deleteUser(
    String username, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final existing = await _repository.user(username);

    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.userDelete(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: username,
          heldRole: existing?.roleName ?? '',
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _userDelete, row: row);

    if (existing == null) throw UserNotFoundException(username);
    await _repository.deleteUser(username);
    await _recordAllowed(actionId, row);
  }

  /// Moves [username] onto [roleName]. Requires [kAccessAdminGroup].
  ///
  /// The role currently held is read **before** the gate, for the row's
  /// `oldValue`.
  ///
  /// Throws [UserNotFoundException], [MissingRoleError] for a target role that
  /// does not exist, and [LastUsersHolderException] for trip route (b) — moving
  /// the last `users` holder onto a role that does not grant it.
  Future<void> setUserRole(
    String username,
    String roleName, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final existing = await _repository.user(username);

    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.userRole(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: username,
          oldRole: existing?.roleName ?? '',
          newRole: roleName,
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _userRole, row: row);

    if (existing == null) throw UserNotFoundException(username);
    await _repository.setRole(username, roleName);
    await _recordAllowed(actionId, row);
  }

  /// Flips [username]'s station-account flag. Requires [kAccessAdminGroup].
  ///
  /// The v8 attribute: a station account's sessions never expire. Not a
  /// permission, so no lockout guard — but very much a trail matter, since
  /// it decides whether a signed-in panel ever signs itself out.
  Future<void> setUserStationAccount(
    String username,
    bool value, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    final existing = await _repository.user(username);

    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.userStationAccount(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: username,
          oldValue: existing?.stationAccount ?? false,
          newValue: value,
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _userStationAccount, row: row);

    if (existing == null) throw UserNotFoundException(username);
    await _repository.setStationAccount(username, value);
    await _recordAllowed(actionId, row);
  }

  /// Resets [username]'s password to [password]. Requires [kAccessAdminGroup].
  ///
  /// **The credential goes to the repository and nowhere else.** It is not
  /// logged, not put in the `reason`, not interpolated into any string in this
  /// method, and it cannot reach the row: [AuditRecord.userPassword] leaves
  /// both value columns null and has no parameter that could fill them. That
  /// matters more here than anywhere else in this file, because an admin row is
  /// not an auth row — `AuditRecord.toString` withholds the value columns only
  /// for `surface == 'auth'`, so these values do reach log files that live
  /// longer and travel further than the database does.
  ///
  /// No lockout guard: a password is not a permission, so no password can take
  /// the last holder away. Throws [UserNotFoundException] from the repository.
  Future<void> setUserPassword(
    String username,
    String password, {
    String origin = _operatorOrigin,
    String? reason,
  }) async {
    AuditRecord row(AccessSession session, String actionId, bool allowed) =>
        AuditRecord.userPassword(
          who: _who(session),
          station: _station,
          roleName: session.roleName,
          actionId: actionId,
          subject: username,
          allowed: allowed,
          reason: reason,
          origin: origin,
        );

    final actionId = await _requireUsers(itemKey: _userPassword, row: row);

    await _repository.setPassword(username, password);
    await _recordAllowed(actionId, row);
  }

  // ---------------------------------------------------------------------------
  // The one implementation of the rule
  // ---------------------------------------------------------------------------

  /// Check, record, throw — the ordering `GuardedStateMan` established,
  /// `guarded_history_views.dart` reuses and `access_template_store.dart`
  /// documents.
  ///
  /// Returns the `actionId` the caller must carry into its allowed row, so one
  /// human action produces one correlation id however many rows it writes.
  ///
  /// On the deny path the row comes **before** the throw, because it is the
  /// only evidence the guard fired. On the permitted path the caller records
  /// after the repository call has returned — see design decision 2 on the
  /// class.
  Future<String> _requireUsers({
    required String itemKey,
    required _RowBuilder row,
  }) async {
    final actionId = newActionId();
    final session = _session();
    if (session.can(kAccessAdminGroup)) return actionId;

    await _record(row(session, actionId, false));

    final denial = AccessDenied(itemKey, kAccessAdminGroup);
    try {
      _onDenied?.call(denial);
    } on Object catch (error, stack) {
      // A listener's bug must not change what the caller sees. The refusal is
      // this store's answer; a broken prompt is cosmetic beside it.
      _logger.e('onDenied listener threw for "$itemKey"',
          error: error, stackTrace: stack);
    }
    throw denial;
  }

  /// The allowed row, built by the same builder the deny path would have used.
  Future<void> _recordAllowed(String actionId, _RowBuilder row) =>
      _record(row(_session(), actionId, true));

  /// Append [row], and never let the sink's failure become the caller's.
  ///
  /// The same rule, in the same words, as plans 03-04, 03-05, 03-10 and 04-06.
  /// On the permitted path an escaping sink exception would fail a write the
  /// session was allowed to make — and here that write has already committed,
  /// so the caller would be told a lie. On the deny path it would replace
  /// [AccessDenied] with something no caller catches, skip `onDenied`, and
  /// leave the operator with a control that did nothing and no explanation for
  /// it. The price is that a lost row is only a log line, so the line names the
  /// row it lost.
  Future<void> _record(AuditRecord row) async {
    try {
      await _audit.record(row);
    } on Object catch (error, stack) {
      _logger.e(
        'AUDIT ROW LOST: action ${row.actionId}, ${row.who} on '
        '${row.surface}:${row.itemKey}, allowed: ${row.allowed}',
        error: error,
        stackTrace: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  /// The default [AuditRecord.origin] — a person standing at the panel.
  static const String _operatorOrigin = 'operator';

  /// `who` comes from the session and from nowhere else. [AuditRecord.origin]
  /// is the only field a caller of this store can set, and that asymmetry is
  /// the point: there is no parameter through which a caller could name
  /// somebody else as the author of a role edit.
  static String _who(AccessSession session) =>
      session.user?.username ?? _anonymousWho;

  // The itemKeys, restated here for the [AccessDenied] each gate throws. Each
  // one is the same string its named constructor writes into the row, and a
  // named test per write asserts the refusal and the row agree — the two
  // spellings are checked against each other rather than trusted.
  static const String _roleCreate = 'role.create';
  static const String _roleUpdate = 'role.update';
  static const String _roleDelete = 'role.delete';
  static const String _roleRename = 'role.rename';
  static const String _userCreate = 'user.create';
  static const String _userDelete = 'user.delete';
  static const String _userRole = 'user.role';
  static const String _userPassword = 'user.password';
  static const String _userStationAccount = 'user.station_account';
}
