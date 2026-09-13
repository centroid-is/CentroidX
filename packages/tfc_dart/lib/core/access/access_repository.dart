import 'package:drift/drift.dart';
import 'package:logger/logger.dart';
import 'package:tfc_access/tfc_access.dart';

import '../database_drift.dart';

/// The role the first account is forced into.
///
/// Not a parameter of [AccessRepository.createFirstUser] on purpose — see the
/// comment there. Written once, here, so the two places that need the name
/// cannot drift apart.
const String kFirstUserRoleName = 'Engineering';

/// Thrown when [AccessRepository.createFirstUser] is called after the window
/// has closed.
///
/// An [Error] rather than an [Exception]: the caller is expected to have asked
/// [AccessRepository.isUserTableEmpty] first, so reaching this means either a
/// defect or a genuine race — and in the race case the loser must not be
/// tempted to "handle" it by retrying.
class FirstUserWindowClosedError extends Error {
  FirstUserWindowClosedError();

  @override
  String toString() =>
      'FirstUserWindowClosedError: a user already exists, so no further user '
      'may be created. Users are added by an account holding the users group.';
}

/// Thrown when an operation names a role that is not in `app_role`.
///
/// Exists so a missing role reads as a missing role. Without it, deleting
/// `Engineering` before commissioning would surface as
/// `SqliteException(787): FOREIGN KEY constraint failed` on the first-user
/// screen, which tells the person standing at the panel nothing at all.
class MissingRoleError extends Error {
  MissingRoleError(this.roleName);

  /// The role that was expected and is not there.
  final String roleName;

  @override
  String toString() => 'MissingRoleError: there is no role named "$roleName".';
}

/// A role was not deleted because accounts still hold it.
///
/// **Deliberately not an `AccessDenied`**, for the reason `TemplateInUseException`
/// gives at length: `AccessDenied` means "you may not", and is answered by
/// signing in as somebody who may. This means "not until those accounts are
/// moved", and an Engineering user holding every group gets it too — no sign-in
/// resolves it. Rendering it through the shared locked prompt would send an
/// operator to find somebody who cannot help either.
///
/// [holders] is what lets the roles screen list the accounts in the refusal
/// instead of saying that something, somewhere, is in the way.
class RoleInUseException implements Exception {
  const RoleInUseException(this.roleName, this.holders);

  /// The role that was not deleted.
  final String roleName;

  /// The usernames still holding it, sorted, read at the moment of the attempt.
  ///
  /// Sorted for the same reason `TemplateInUseException.boundKeys` is: an
  /// unsorted list makes the dialog's text change between two reads of the same
  /// state, and a message that moves reads as a message that is guessing.
  final List<String> holders;

  @override
  String toString() => 'RoleInUseException: the role "$roleName" is still held '
      'by ${holders.length} account(s): ${holders.join(', ')}. Move them to '
      'another role first — deleting it would leave every one of them pointing '
      'at a role that is no longer there.';
}

/// A change was refused because it would leave nobody able to manage roles and
/// accounts.
///
/// The invariant is one sentence: **at least one account holds a role granting
/// [AccessGroup.users]**. Four changes can break it — deleting the last holder,
/// moving that holder to a role without `users`, unticking `users` from the
/// only role that grants it, and deleting that role — and the last two never
/// touch `app_user` at all. That is why the rule lives in one method here
/// rather than on the two screens that call it: two copies of a rule is how one
/// copy gets edited alone.
///
/// **There is no override.** No `force`, no `allowLockout`, no typed
/// confirmation. The state this refuses has no recovery inside the application;
/// the only way back is the documented break-glass in
/// `docs/access-control-deployment.md` §4, which the message points at. A
/// parameter that skipped this check would be that escape hatch under another
/// name.
///
/// Like [RoleInUseException] it is not an `AccessDenied`: the account that hits
/// it is, by definition, one that already holds `users`.
class LastUsersHolderException implements Exception {
  const LastUsersHolderException(this.roleName, this.holders);

  /// The role that grants [holders] the `users` group.
  ///
  /// Single-valued rather than a list because a trip implies it: the change is
  /// refused only when no account would hold `users` afterwards, and that can
  /// happen only when every account that holds it today holds this one role.
  final String roleName;

  /// The accounts that would have been the last ones, sorted.
  ///
  /// Named rather than counted, because naming them makes the fix obvious: a
  /// shift that can read who is left knows who to ask.
  final List<String> holders;

  @override
  String toString() =>
      'LastUsersHolderException: refused — this would leave no account able to '
      'manage roles and users. "$roleName" is the only role granting the users '
      'group, and ${holders.join(', ')} '
      '${holders.length == 1 ? 'is the only account holding' : 'are the only accounts holding'}'
      ' it. Grant users to another role, or move another account onto this one, '
      'first. There is no override: recovery from a lockout is the break-glass '
      'procedure in docs/access-control-deployment.md §4.';
}

/// An account with that username already exists.
///
/// An [Exception] rather than an [Error] because the caller is expected to
/// catch it and render it: the create dialog refuses a duplicate before it
/// submits, so reaching this is the race between two people adding the same
/// name, not a defect. It carries [username] so the dialog can say which name
/// is taken rather than stringifying an error into a snackbar.
class UserExistsException implements Exception {
  const UserExistsException(this.username);

  /// The name that is already in `app_user`.
  final String username;

  @override
  String toString() =>
      'UserExistsException: an account named "$username" already exists.';
}

/// No account has that username.
///
/// Thrown rather than succeeding quietly, for the reason
/// `BindingNotFoundException` gives: a silent success would let the caller
/// write an audit row claiming a change that did not happen, and the trail's
/// only value is that its rows are true.
///
/// Case-sensitive, like every other username comparison here — see [user].
class UserNotFoundException implements Exception {
  const UserNotFoundException(this.username);

  /// The name that is not in `app_user`.
  final String username;

  @override
  String toString() =>
      'UserNotFoundException: there is no account named "$username".';
}

/// The stored form of a password hash, for `AppUser.passwordHash`.
///
/// Thin wrappers over [PasswordHash.encode] / [PasswordHash.tryDecode], which
/// live in `tfc_access` beside the value type so the relay can read a stored
/// hash without pulling in Drift. They are re-exposed here because this is the
/// layer that reads and writes the column, and a caller should not have to know
/// which package the encoding lives in.
///
/// Two forms: `argon2id$v=19$m=<KiB>,t=<iters>,p=<lanes>$<hash_b64>` for
/// anything written since Argon2id landed, `pbkdf2-sha256$<iterations>$<hash>`
/// for everything before it, with the raw base64 salt in the separate `salt`
/// column either way. The cost parameters travel *with* the hash because the
/// `AppUser` table (spec §2, quoted as final) has no column for them and is not
/// getting one: a later change to [Pbkdf2Kdf.defaultIterations] or to
/// [Argon2idKdf]'s constants would otherwise silently invalidate every password
/// already stored. The form was written to leave room for a second algorithm
/// without another migration, and `argon2id` is that second algorithm.
String encodeStoredHash(PasswordHash hash) => hash.encode();

/// Parse an `AppUser.passwordHash` value, or null if it is unreadable.
///
/// A bare base64 value with no `$` is a legacy hash written before this
/// encoding existed; it decodes at the ambient [Pbkdf2Kdf.iterations] rather
/// than throwing. Null means the column was mangled — by hand in `psql`, most
/// likely — and the login path treats that as a failed credential rather than
/// crashing the login screen.
PasswordHash? decodeStoredHash(String stored, {required String saltB64}) =>
    PasswordHash.tryDecode(stored, saltB64: saltB64);

/// Which of the four writes a [_PendingChange] describes.
enum _PendingChangeKind {
  /// Trip route (a): the last account holding `users` is deleted.
  userDeleted,

  /// Trip route (b): that account's roles are replaced by a set that grants
  /// no `users`.
  userRolesChanged,

  /// Trip route (c): `users` is unticked from the only role that grants it.
  roleGroupsReplaced,

  /// Trip route (d): that role is deleted.
  roleDeleted,
}

/// One write, described before it happens, so
/// [AccessRepository._requireAUsersHolderRemains] can apply it in Dart and look
/// at the result.
///
/// One type with four named constructors rather than four boolean parameters on
/// the guard. A call site cannot then express two changes at once — no write in
/// this class deletes an account *and* replaces a role's groups, and a shape
/// that can say it is a shape somebody eventually says it in.
class _PendingChange {
  const _PendingChange._(
    this.kind, {
    this.username,
    this.roleName,
    this.roleNames,
    this.groups,
  });

  /// [username] is about to be deleted — trip route (a).
  factory _PendingChange.userDeleted(String username) =>
      _PendingChange._(_PendingChangeKind.userDeleted, username: username);

  /// [username]'s roles are about to become [roleNames] — trip route (b).
  ///
  /// The whole set, not the one role it used to be: an account holding
  /// `Operator` and `Engineering` keeps `users` through the second of them, so
  /// a guard that looked only at the primary role would refuse a harmless edit
  /// and allow a locking one.
  factory _PendingChange.userRolesChanged({
    required String username,
    required List<String> roleNames,
  }) =>
      _PendingChange._(
        _PendingChangeKind.userRolesChanged,
        username: username,
        roleNames: roleNames,
      );

  /// [roleName]'s group set is about to become [groups] — trip route (c).
  factory _PendingChange.roleGroupsReplaced({
    required String roleName,
    required Set<AccessGroup> groups,
  }) =>
      _PendingChange._(
        _PendingChangeKind.roleGroupsReplaced,
        roleName: roleName,
        groups: groups,
      );

  /// [roleName] is about to be deleted — trip route (d).
  factory _PendingChange.roleDeleted(String roleName) =>
      _PendingChange._(_PendingChangeKind.roleDeleted, roleName: roleName);

  final _PendingChangeKind kind;
  final String? username;
  final String? roleName;
  final List<String>? roleNames;
  final Set<AccessGroup>? groups;
}

/// Reads and writes for `app_role` and `app_user`.
///
/// Pure data layer: an [AppDatabase] and nothing else. No Riverpod, no Flutter,
/// no policy. Gating is not this class's job and is not this phase's job —
/// Phase 1 records and resolves, Phase 3 enforces.
///
/// ## The anonymous account
///
/// A session with nobody signed in answers as the reserved `app_user` row
/// named [kAnonymousUsername] (`anonymous_account.dart`). It holds roles and a
/// page whitelist like any account, and [anonymousAccount] composes them.
///
/// The row is special in exactly these ways, all enforced here:
///
///  * [deleteUser], [setPassword], [setStationAccount], [setInactivityTimeout]
///    and [rehashPassword] refuse it with [AnonymousAccountError];
///    [createUser] and [createFirstUser] refuse its name with
///    [ReservedUsernameException].
///  * It never counts as an account holding [AccessGroup.users] for
///    [_requireAUsersHolderRemains] — a logged-out panel cannot manage anybody
///    back into the roles screen — and it never counts toward [userCount], so
///    the first-user window of a fresh station stays open.
///  * It **does** count as a holder in [_holdersOf]: a role it holds is refused
///    deletion, with `anonymous` named, like any held role.
///
/// **Editing the roles it holds changes what an *unauthenticated* panel may
/// do.** That is allowed — it is the knob a site turns when it wants a
/// permissive line — and the accounts screen says so at the point of edit.
class AccessRepository {
  AccessRepository(this.db, {Logger? logger}) : _logger = logger ?? Logger();

  final AppDatabase db;
  final Logger _logger;

  /// The groups seeded onto `Operator`, used as the last fallback in
  /// [anonymousAccount].
  static final Set<AccessGroup> _seededOperatorGroups =
      kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups;

  // ---------------------------------------------------------------------
  // Roles
  // ---------------------------------------------------------------------

  /// Every row in `app_role`, in display order.
  ///
  /// A role with a `sort_order` comes first, lowest first. A role nobody has
  /// placed (NULL — every role before the first reorder, and any role created
  /// since) follows: the seed roles in [kSeedRoles] order, then the rest in
  /// the order the select returns them, which is insertion (rowid) order on
  /// SQLite. That fallback is the order the screen listed roles in before the
  /// column existed, when this method did not sort at all.
  ///
  /// Sorted here rather than by `ORDER BY`, because the middle tier is not a
  /// column: it is a position in a Dart constant. The select position is the
  /// last tiebreak explicitly, because `List.sort` is not guaranteed stable.
  Future<List<AccessRole>> roles() async {
    final rows = await db.select(db.appRole).get();
    final selected = {for (var i = 0; i < rows.length; i++) rows[i].name: i};
    rows.sort((a, b) {
      final byOrder = _compareNullsLast(a.sortOrder, b.sortOrder);
      if (byOrder != 0) return byOrder;
      final bySeed = _compareNullsLast(_seedIndex(a.name), _seedIndex(b.name));
      if (bySeed != 0) return bySeed;
      return selected[a.name]!.compareTo(selected[b.name]!);
    });
    return rows.map(_toRole).toList(growable: false);
  }

  /// [name]'s position in [kSeedRoles], or null for a role the seed did not
  /// write.
  static int? _seedIndex(String name) {
    final index = kSeedRoles.indexWhere((r) => r.name == name);
    return index < 0 ? null : index;
  }

  /// Ascending, with null after every value.
  static int _compareNullsLast(int? a, int? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  /// Persist the display order of the roles: `names[i]` is given position i.
  ///
  /// Display order only — no permission rides on it, so there is no lockout
  /// guard. A role [names] leaves out keeps whatever position it had; the
  /// screen sends the whole list.
  ///
  /// One transaction, so a name with no row ([MissingRoleError]) rolls back
  /// every position written before it rather than leaving the list half
  /// reordered. Throws [ArgumentError] when a name appears twice, before
  /// anything is written: the second position would silently win.
  Future<void> setRoleOrder(List<String> names) async {
    _requireDistinct(names, 'names');
    await db.transaction(() async {
      for (var i = 0; i < names.length; i++) {
        final updated = await (db.update(db.appRole)
              ..where((t) => t.name.equals(names[i])))
            .write(AppRoleCompanion(sortOrder: Value(i)));
        if (updated == 0) throw MissingRoleError(names[i]);
      }
    });
  }

  /// Throws [ArgumentError] when [values] holds a string more than once.
  static void _requireDistinct(List<String> values, String argument) {
    final seen = <String>{};
    for (final value in values) {
      if (!seen.add(value)) {
        throw ArgumentError.value(
            values, argument, '"$value" appears more than once');
      }
    }
  }

  /// The role named [name], or null when there is no such row.
  Future<AccessRole?> role(String name) async {
    final row = await (db.select(db.appRole)..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    return row == null ? null : _toRole(row);
  }

  /// Every role named by [primary] and [additional], read from `app_role`,
  /// primary first.
  ///
  /// Null when the **primary** role does not exist: there is no identity to
  /// build a session on. A missing *extra* is dropped with a warning — losing a
  /// role narrows, losing the account's identity does not. Throws when the
  /// database does, which is this layer's convention; callers that must not
  /// fail decide what a throw means for them.
  Future<List<AccessRole>?> resolveRoles({
    required String primary,
    Iterable<String> additional = const <String>[],
  }) async {
    final names = normaliseRoleNames(primary: primary, additional: additional);
    if (names.isEmpty) return null;
    final resolved = <AccessRole>[];
    for (final name in names) {
      final found = await role(name);
      if (found == null) {
        if (resolved.isEmpty) return null;
        _logger.w('The role "$name" no longer exists — dropping it from the '
            'account that holds it as an extra.');
        continue;
      }
      resolved.add(found);
    }
    return resolved;
  }

  /// What a panel with nobody signed in may do and see, as it stands.
  ///
  /// Read from the reserved [kAnonymousUsername] row: every role it holds,
  /// composed through `role_set.dart`, and its personal page whitelist on top.
  /// One read of the row and one read per role, at the moment the session is
  /// built, so an edit takes effect without a restart.
  ///
  /// **Never throws**, and falls back in two steps, because a panel that goes
  /// dead because the database blinked is a stopped line:
  ///
  ///  1. the row is missing, or its primary role no longer exists → the
  ///     [kOperatorRoleName] role alone, with no personal override. That is
  ///     what anonymous resolved to before the account existed, and what the
  ///     seed puts the account on.
  ///  2. that role is missing too, or any read throws → the seeded Operator
  ///     role: `{operate}` and **no whitelist**. Null rather than empty on
  ///     purpose: failing closed here would blank every page on every panel
  ///     during an outage, and visibility is not the surface where that trade
  ///     is worth making (the write guards still refuse). `{operate}` is the
  ///     conservative floor rather than a guess — the narrowest thing a
  ///     logged-out panel has ever held.
  Future<AnonymousAccount> anonymousAccount() async {
    AnonymousAccount seeded() => AnonymousAccount(roles: [
          AccessRole(
            name: kOperatorRoleName,
            groups: {..._seededOperatorGroups},
            seeded: true,
          ),
        ]);
    try {
      final row = await user(kAnonymousUsername);
      if (row != null) {
        final roles = await resolveRoles(
          primary: row.roleName,
          additional: decodeAdditionalRoles(row.additionalRoles),
        );
        if (roles != null) {
          return AnonymousAccount(
            roles: roles,
            pagesOverride: decodeAllowedPagesColumn(row.allowedPages),
          );
        }
        _logger.w(
          'The "$kAnonymousUsername" account holds the role "${row.roleName}", '
          'which no longer exists — falling back to "$kOperatorRoleName".',
        );
      } else {
        _logger.w(
          'No "$kAnonymousUsername" account in app_user — falling back to the '
          '"$kOperatorRoleName" role. The next open of the database re-seeds '
          'it.',
        );
      }
      final operator = await role(kOperatorRoleName);
      if (operator == null) {
        _logger.w(
          'No "$kOperatorRoleName" role in app_role either — falling back to '
          'the seeded anonymous floor.',
        );
        return seeded();
      }
      return AnonymousAccount(roles: [operator]);
    } on Object catch (e) {
      _logger.w(
        'Could not read the "$kAnonymousUsername" account — falling back to '
        'the seeded anonymous floor: $e',
      );
      return seeded();
    }
  }

  /// Replace the page whitelist on the role named [name].
  ///
  /// [pages] null clears it — the role sees every page again; the empty set is
  /// a whitelist naming nothing, i.e. block all. The two are different writes
  /// and both are legal.
  ///
  /// A targeted column update rather than an `upsertRole`, so a caller holding
  /// a stale group set cannot roll groups back as a side effect of changing
  /// pages.
  ///
  /// **No lockout guard, and that is a decision rather than an omission.** A
  /// whitelist cannot remove [AccessGroup.users] from anybody, and the access
  /// screen is exempt from the whitelist half of the route gate, so no
  /// whitelist state can take the roles screen away from the people who hold
  /// the group. The rest of the Advanced surface is whitelistable like any
  /// other destination; `/advanced/access` alone is not.
  Future<void> setRoleAllowedPages(String name, Set<String>? pages) async {
    await db.transaction(() async {
      final existing = await (db.select(db.appRole)
            ..where((t) => t.name.equals(name)))
          .getSingleOrNull();
      if (existing == null) throw MissingRoleError(name);
      await (db.update(db.appRole)..where((t) => t.name.equals(name))).write(
        AppRoleCompanion(allowedPages: Value(encodeAllowedPagesColumn(pages))),
      );
    });
  }

  /// Replace one account's personal page whitelist.
  ///
  /// [pages] null clears the override, putting the account back under its
  /// role's whitelist — which is **not** the same as granting it every page.
  /// The empty set is a personal block-all that outranks whatever the role
  /// allows.
  ///
  /// Throws [UserNotFoundException] when there is no such account, rather than
  /// writing nothing and reporting success.
  Future<void> setUserAllowedPages(String username, Set<String>? pages) async {
    await db.transaction(() async {
      final existing = await (db.select(db.appUser)
            ..where((t) => t.username.equals(username)))
          .getSingleOrNull();
      if (existing == null) throw UserNotFoundException(username);
      await (db.update(db.appUser)..where((t) => t.username.equals(username)))
          .write(
        AppUserCompanion(allowedPages: Value(encodeAllowedPagesColumn(pages))),
      );
    });
  }

  /// Insert [role], or update the groups of an existing row with that name.
  ///
  /// A rename is not expressible here — the name is the primary key, so
  /// changing it is an insert plus a delete, which is [renameRole].
  ///
  /// `seeded` is left as it was on an update. It records where the row came
  /// from, and editing a seeded role does not make it stop having been seeded.
  ///
  /// An update runs [_requireAUsersHolderRemains] first, inside the same
  /// transaction: unticking `users` from the only role that grants it locks the
  /// plant out of the roles screen without touching `app_user` at all.
  Future<void> upsertRole(AccessRole role) async {
    final name = role.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(role.name, 'role.name', 'must not be blank');
    }
    await db.transaction(() async {
      final existing = await (db.select(db.appRole)
            ..where((t) => t.name.equals(name)))
          .getSingleOrNull();
      if (existing == null) {
        await db.into(db.appRole).insert(
              AppRoleCompanion.insert(
                name: name,
                groups: role.encodeGroups(),
                seeded: Value(role.seeded),
                // A create carries whatever the caller built — null for every
                // production caller, since the roles screen creates a role
                // before anybody can choose its pages.
                allowedPages: Value(role.encodeAllowedPages()),
              ),
            );
      } else {
        // The update arm only. Creating a role cannot remove a holder, so the
        // insert above needs no guard; replacing a group set can drop `users`
        // from the only role that grants it, which is trip route (c).
        await _requireAUsersHolderRemains(_PendingChange.roleGroupsReplaced(
          roleName: name,
          groups: role.groups,
        ));
        // **Groups only, deliberately.** The whitelist has its own write
        // ([setRoleAllowedPages]) and its own audit row, and the roles screen
        // can save groups without having loaded a page tree. Widening this to
        // an `AccessRole`-shaped write would let a caller holding a stale
        // value object silently reset a whitelist to null — which fails
        // *open*, showing the role every page.
        await (db.update(db.appRole)..where((t) => t.name.equals(name)))
            .write(AppRoleCompanion(groups: Value(role.encodeGroups())));
      }
    });
  }

  /// Delete the role named [name].
  ///
  /// A role that accounts still hold is refused in application code, with the
  /// holders named — [RoleInUseException] — and the check runs inside the
  /// transaction that would otherwise perform the delete. The anonymous
  /// account is a holder like any other, so a role every logged-out panel
  /// depends on cannot disappear from under them.
  ///
  /// It is **not** left to the foreign key. `app_user.role_name` does reference
  /// `app_role.name`, but SQLite enforces that only on a connection whose
  /// `foreign_keys` pragma is on. The pragma is per-connection, defaults off,
  /// and in this repository it is issued in five test files and in no
  /// production code anywhere. So on the SQLite demo backend the delete would
  /// succeed and silently orphan the holder, whose `role_name` then resolves to
  /// nothing. The header of `access_repository_test.dart` explains why the
  /// pragma is enabled per test file; this comment exists because the sentence
  /// it replaced claimed an enforcement this build does not have.
  ///
  /// Two checks run, in this order: [_requireAUsersHolderRemains] and then the
  /// holders check. Deleting the only `users`-granting role that anybody holds
  /// trips both, and the lockout refusal is the one the operator must be told
  /// about — moving holders off a role is a fix they can perform, and a plant
  /// with nobody able to manage roles has no fix inside the application at all.
  Future<void> deleteRole(String name) async {
    await db.transaction(() async {
      await _requireAUsersHolderRemains(_PendingChange.roleDeleted(name));

      final holders = await _holdersOf(name);
      if (holders.isNotEmpty) throw RoleInUseException(name, holders);

      await (db.delete(db.appRole)..where((t) => t.name.equals(name))).go();
    });
  }

  /// Every role [row] holds, primary first.
  ///
  /// The one place `role_name` and `additional_roles` are read together, so
  /// nothing can answer "which roles does this account hold" by looking at half
  /// of it. Public because the session builder and the accounts screen ask the
  /// same question of the same row.
  static List<String> rolesOf(AppUserData row) => normaliseRoleNames(
        primary: row.roleName,
        additional: decodeAdditionalRoles(row.additionalRoles),
      );

  /// The usernames holding [roleName] — primarily **or** additionally — sorted.
  ///
  /// Read inside the transaction that is about to act on the role, so the list
  /// a refusal names is the list the database held at the moment of the attempt
  /// rather than a moment earlier.
  ///
  /// Filtered in Dart rather than in SQL, because `additional_roles` is a JSON
  /// TEXT column and a `LIKE` over it would match `Shift Leader` from an
  /// account holding `Assistant Shift Leader`. There are a handful of accounts
  /// on a station and this is not a performance question — the same reasoning
  /// [_requireAUsersHolderRemains] gives for computing its invariant in Dart.
  Future<List<String>> _holdersOf(String roleName) async {
    final rows = await db.select(db.appUser).get();
    return rows
        .where((r) => rolesOf(r).contains(roleName))
        .map((r) => r.username)
        .toList()
      ..sort();
  }

  /// Refuse [change] when applying it would leave no account holding a role
  /// that grants [AccessGroup.users].
  ///
  /// **Call this only from inside a `db.transaction` callback**, immediately
  /// before the write it describes. Checking beforehand is a check-then-act
  /// race, exactly as it is for the first-user window — see [createFirstUser],
  /// which argues it at length for the same reason. A rule with a race in it is
  /// a rule that occasionally does not apply, and this is the rule whose
  /// failure has no recovery inside the application.
  ///
  /// There is one of these methods and every write that could remove a holder
  /// calls it: [deleteRole], [upsertRole]'s update arm, [deleteUser] and
  /// [setRole]. Two copies of this rule is how one copy gets edited alone.
  ///
  /// The invariant is computed in Dart, not in SQL. "A role granting `users`"
  /// is `AccessRole.decodeGroups(row.groups).contains(AccessGroup.users)` over
  /// a JSON TEXT column; [anonymousAccount] reads role rows and decodes them in
  /// Dart for the same reason. There are a handful of role rows and this is not
  /// a performance question.
  ///
  /// The anonymous account is left out entirely. Whatever it holds, a
  /// logged-out panel is not somebody who can sign in and manage the next
  /// account, so counting it would let the last real `users` holder be deleted
  /// while this guard reported a holder remaining.
  ///
  /// A user row whose `role_name` names no existing role holds nothing. With
  /// the `foreign_keys` pragma off — which is every connection outside the
  /// tests — that state is reachable, and it must read as "holds nothing"
  /// rather than as an exception.
  ///
  /// The guard refuses changes that *take away* the last holder. When there is
  /// no holder to begin with there is nothing to preserve and it stands aside:
  /// a freshly seeded station has roles but no accounts, its recovery is the
  /// first-user window, and a guard that fired there would make a station
  /// unconfigurable out of the box.
  Future<void> _requireAUsersHolderRemains(_PendingChange change) async {
    final roleRows = await db.select(db.appRole).get();
    final userRows = await db.select(db.appUser).get();

    final granting = <String>{
      for (final r in roleRows)
        if (AccessRole.decodeGroups(r.groups).contains(AccessGroup.users))
          r.name,
    };
    // Every role each account holds, not just its primary one. An account that
    // is `Operator` primarily and `Engineering` additionally holds `users`
    // through the second, and a guard reading only `role_name` would both
    // refuse edits that take nothing away and wave through the one that locks
    // the plant out.
    final rolesHeld = <String, List<String>>{
      for (final u in userRows)
        if (u.username != kAnonymousUsername) u.username: rolesOf(u),
    };
    List<String> holdersAgainst(Set<String> grants) => rolesHeld.entries
        .where((e) => e.value.any(grants.contains))
        .map((e) => e.key)
        .toList()
      ..sort();

    final holdersNow = holdersAgainst(granting);
    if (holdersNow.isEmpty) return;

    // Read before the pending change is applied below, because two of the four
    // routes edit `rolesHeld` out from under it — a refusal must name a role
    // the holders hold *now*, not one they were about to be moved to.
    //
    // "A role that grants it", not "the only one". With several roles per
    // account the holders need not all hold the same granting role, so this
    // names the first granting role of the first holder by username. The
    // message says what to do about it rather than leaning on that name being
    // unique, and [LastUsersHolderException.holders] carries the whole list.
    final lastGrantingRole =
        rolesHeld[holdersNow.first]!.firstWhere(granting.contains);

    final grantingAfter = {...granting};
    switch (change.kind) {
      case _PendingChangeKind.userDeleted:
        rolesHeld.remove(change.username);
      case _PendingChangeKind.userRolesChanged:
        if (change.username != kAnonymousUsername) {
          rolesHeld[change.username!] = change.roleNames!;
        }
      case _PendingChangeKind.roleGroupsReplaced:
        if (change.groups!.contains(AccessGroup.users)) {
          grantingAfter.add(change.roleName!);
        } else {
          grantingAfter.remove(change.roleName!);
        }
      case _PendingChangeKind.roleDeleted:
        grantingAfter.remove(change.roleName!);
    }

    if (holdersAgainst(grantingAfter).isNotEmpty) return;

    throw LastUsersHolderException(lastGrantingRole, holdersNow);
  }

  /// Rename the role [from] to [to], carrying its users with it — the
  /// anonymous account included, so a logged-out panel keeps what it held.
  ///
  /// `app_user.role_name` references `app_role.name` with no `ON UPDATE
  /// CASCADE`, so this is an insert, a repoint and a delete inside one
  /// transaction rather than an `UPDATE app_role SET name = ...`, which the
  /// foreign key would refuse the moment any user held the role.
  Future<void> renameRole(String from, String to) async {
    final target = to.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(to, 'to', 'must not be blank');
    }
    await db.transaction(() async {
      final existing = await (db.select(db.appRole)
            ..where((t) => t.name.equals(from)))
          .getSingleOrNull();
      if (existing == null) throw MissingRoleError(from);

      final collision = await (db.select(db.appRole)
            ..where((t) => t.name.equals(target)))
          .getSingleOrNull();
      if (collision != null) {
        throw ArgumentError.value(
          to,
          'to',
          'a role named "$target" already exists',
        );
      }

      await db.into(db.appRole).insert(
            AppRoleCompanion.insert(
              name: target,
              groups: existing.groups,
              seeded: Value(existing.seeded),
              // Every column of the old row moves, `allowed_pages` included.
              // Dropping it here would be the dangerous direction: the renamed
              // role would come back with NULL, which is "sees every page", so
              // a rename would silently *widen* what an audience sees.
              // `renameRole preserves the whitelist` pins this.
              allowedPages: Value(existing.allowedPages),
              // And its place in the list, so a rename does not drop the role
              // to the bottom of the Access screen.
              sortOrder: Value(existing.sortOrder),
            ),
          );
      await (db.update(db.appUser)..where((t) => t.roleName.equals(from)))
          .write(AppUserCompanion(roleName: Value(target)));
      // And the accounts that hold it as an *extra* role. `additional_roles`
      // is a JSON TEXT column with no foreign key, so nothing carries those
      // along on its own — and leaving them would silently strip the role from
      // everybody who held it secondarily, which is a permission change
      // disguised as a rename.
      //
      // Rewritten row by row in Dart rather than by a string replace over the
      // column, for the reason [_holdersOf] gives: a textual substitution
      // cannot tell `Shift Leader` from `Assistant Shift Leader`.
      final holders = await db.select(db.appUser).get();
      for (final row in holders) {
        final extra = decodeAdditionalRoles(row.additionalRoles);
        if (!extra.contains(from)) continue;
        // `normaliseRoleNames` against the already-repointed primary, so an
        // account that held the role both ways does not come out listing the
        // new name twice.
        final renamed = normaliseRoleNames(
          primary: row.roleName == from ? target : row.roleName,
          additional: [for (final name in extra) name == from ? target : name],
        );
        await (db.update(db.appUser)
              ..where((t) => t.username.equals(row.username)))
            .write(AppUserCompanion(
          additionalRoles: Value(encodeAdditionalRoles(renamed.skip(1))),
        ));
      }
      await (db.delete(db.appRole)..where((t) => t.name.equals(from))).go();
    });
  }

  // ---------------------------------------------------------------------
  // Users
  // ---------------------------------------------------------------------

  /// Whether the first-user window is still open.
  ///
  /// A convenience for the login surface, and **not** the guard. The real check
  /// is the one inside [createFirstUser]'s transaction; this one is what the UI
  /// asks in order to decide which screen to show.
  Future<bool> get isUserTableEmpty async => await userCount() == 0;

  /// The number of accounts in `app_user` that a person could sign in to.
  ///
  /// The reserved anonymous account is not counted. The seed writes it on the
  /// first open of every database, so counting it would close a fresh
  /// station's first-user window before anybody had created an account.
  Future<int> userCount() async {
    final count = db.appUser.username.count();
    final row = await (db.selectOnly(db.appUser)
          ..addColumns([count])
          ..where(db.appUser.username.equals(kAnonymousUsername).not()))
        .getSingle();
    return row.read(count) ?? 0;
  }

  /// The row for [username], or null.
  ///
  /// Case-sensitive, because `app_user.username` is a case-sensitive TEXT
  /// primary key. `user('JON')` does not find `jon`. That is a decision rather
  /// than an accident: case-folding usernames means picking a locale to fold
  /// in, and `İ` in Turkish is exactly the sort of thing that turns a login
  /// screen into a support call.
  Future<AppUserData?> user(String username) =>
      (db.select(db.appUser)..where((t) => t.username.equals(username)))
          .getSingleOrNull();

  /// Record that [username] signed in at [at].
  Future<void> touchLastLogin(String username, DateTime at) async {
    await (db.update(db.appUser)..where((t) => t.username.equals(username)))
        .write(AppUserCompanion(lastLoginAt: Value(at)));
  }

  /// Create the first account, but only while `app_user` is empty.
  ///
  /// Roles are seeded, users are not, so without this the login screen would
  /// ship with nobody able to pass it. The first person to open a freshly
  /// commissioned station creates the first account and **the door closes
  /// behind them** — no default password to forget to change, no bootstrap flag
  /// to leave switched on.
  ///
  /// There is deliberately **no role parameter**. The first account is
  /// Engineering ([kFirstUserRoleName]); a caller cannot ask for something
  /// else, so there is no way to commission a station whose only account cannot
  /// create the next one.
  ///
  /// The emptiness check runs **inside** the transaction, immediately before
  /// the insert. Checking beforehand is a check-then-act race, and while two
  /// people commissioning the same station in the same instant is unlikely,
  /// this is the one window in the design that must not have a hole in it —
  /// "the door closes behind them" is the whole rule, and a rule with a race in
  /// it is a rule that occasionally does not apply.
  ///
  /// The hash is derived before the transaction opens. A key derivation at
  /// production parameters is a substantial fraction of a second, and holding a
  /// write
  /// transaction open across it would block every other writer on the shared
  /// Postgres server for that whole time. Nothing is decided by the derivation,
  /// so nothing is lost by doing it early — the loser of a race simply throws
  /// away a hash it computed.
  Future<void> createFirstUser({
    required String username,
    required String password,
  }) async {
    final name = username.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(username, 'username', 'must not be blank');
    }
    if (isAnonymousUsername(name)) throw ReservedUsernameException(name);
    if (password.isEmpty) {
      // Deliberately not `ArgumentError.value(password, ...)`: that puts the
      // credential into the message, and from there into whatever logs it.
      throw ArgumentError('password must not be empty');
    }

    final hash = await PasswordHasher.hash(password);

    await db.transaction(() async {
      final existing = await userCount();
      if (existing != 0) throw FirstUserWindowClosedError();

      final role = await (db.select(db.appRole)
            ..where((t) => t.name.equals(kFirstUserRoleName)))
          .getSingleOrNull();
      if (role == null) throw MissingRoleError(kFirstUserRoleName);

      await db.into(db.appUser).insert(
            AppUserCompanion.insert(
              username: name,
              roleName: kFirstUserRoleName,
              passwordHash: encodeStoredHash(hash),
              salt: hash.saltB64,
              createdAt: DateTime.now().toUtc(),
            ),
          );
    });

    _logger.i('First user "$name" created as $kFirstUserRoleName — the '
        'first-user window is now closed.');
  }

  /// Every row in `app_user`, in display order: accounts with a `sort_order`
  /// first, lowest first, then the unplaced ones (NULL) by username. On a
  /// database nobody has reordered that is plain username order.
  ///
  /// Sorted here rather than by `ORDER BY`, as [roles] is, so the two lists
  /// share one nulls-last rule on both backends.
  ///
  /// Returns the raw drift row, as [user] already does. A domain type here
  /// would be a fifth shape of the same four columns, and the users screen
  /// renders exactly those columns — username, role, created, last login.
  ///
  /// Unguarded and unaudited: it is a read, and the screen that calls it is
  /// gated on [AccessGroup.users] before it gets here.
  Future<List<AppUserData>> listUsers() async {
    final rows = await db.select(db.appUser).get();
    rows.sort((a, b) {
      final byOrder = _compareNullsLast(a.sortOrder, b.sortOrder);
      return byOrder != 0 ? byOrder : a.username.compareTo(b.username);
    });
    return rows;
  }

  /// Persist the display order of the accounts: the i-th account in
  /// [usernames] is given position i.
  ///
  /// [kAnonymousUsername] is skipped without complaint and without taking a
  /// position: the screen pins it apart from the list, so it has no place in
  /// the order to keep. An account [usernames] leaves out keeps whatever
  /// position it had.
  ///
  /// One transaction; an account with no row ([UserNotFoundException]) rolls
  /// back the whole write. Throws [ArgumentError] when a name appears twice,
  /// before anything is written. No lockout guard — the order is not a
  /// permission.
  Future<void> setUserOrder(List<String> usernames) async {
    _requireDistinct(usernames, 'usernames');
    final placed = [
      for (final username in usernames)
        if (username != kAnonymousUsername) username,
    ];
    await db.transaction(() async {
      for (var i = 0; i < placed.length; i++) {
        final updated = await (db.update(db.appUser)
              ..where((t) => t.username.equals(placed[i])))
            .write(AppUserCompanion(sortOrder: Value(i)));
        if (updated == 0) throw UserNotFoundException(placed[i]);
      }
    });
  }

  /// Create an account in [roleName].
  ///
  /// **This is not [createFirstUser].** It neither opens nor closes the
  /// first-user window and never consults it: it is reachable only from a
  /// screen gated on [AccessGroup.users], so an account already exists by
  /// construction. It takes the role as a parameter rather than forcing
  /// [kFirstUserRoleName], because the whole point of the users screen is
  /// choosing one. The two must not be merged.
  ///
  /// It does **not** call [_requireAUsersHolderRemains]: creating an account
  /// cannot take a holder away.
  ///
  /// The hash is derived before the transaction opens and the checks run
  /// inside it — one decision, in two halves, for the reasons [createFirstUser]
  /// sets out: a key derivation at production parameters is a substantial
  /// fraction of a second and holding a write transaction across it would block
  /// every other
  /// writer on the shared Postgres server, while checking beforehand would be a
  /// check-then-act race. The loser of a race throws a hash away, which costs
  /// nothing.
  ///
  /// [username] is trimmed and nothing else. It is not case-folded — the
  /// primary key is case-sensitive TEXT, see [user] — with one exception:
  /// any casing of [kAnonymousUsername] is refused with
  /// [ReservedUsernameException], so no person's account can read as the
  /// logged-out panel.
  Future<void> createUser({
    required String username,
    required String password,
    required String roleName,
    List<String> additionalRoles = const <String>[],
  }) async {
    final name = username.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(username, 'username', 'must not be blank');
    }
    if (isAnonymousUsername(name)) throw ReservedUsernameException(name);
    if (password.isEmpty) {
      // Deliberately not `ArgumentError.value(password, ...)`: that puts the
      // credential into the message, and from there into whatever logs it.
      throw ArgumentError('password must not be empty');
    }

    final hash = await PasswordHasher.hash(password);

    await db.transaction(() async {
      final clash = await (db.select(db.appUser)
            ..where((t) => t.username.equals(name)))
          .getSingleOrNull();
      if (clash != null) throw UserExistsException(name);

      final roles =
          normaliseRoleNames(primary: roleName, additional: additionalRoles);
      // Every named role must exist, the extras included. A missing extra
      // could have been dropped silently — it grants nothing either way — but
      // the caller asked for something this station cannot give it, and
      // finding that out at the dialog beats finding it out when somebody
      // cannot open a page a month later.
      for (final wanted in roles) {
        final role = await (db.select(db.appRole)
              ..where((t) => t.name.equals(wanted)))
            .getSingleOrNull();
        if (role == null) throw MissingRoleError(wanted);
      }

      await db.into(db.appUser).insert(
            AppUserCompanion.insert(
              username: name,
              roleName: roles.first,
              additionalRoles: Value(encodeAdditionalRoles(roles.skip(1))),
              passwordHash: encodeStoredHash(hash),
              salt: hash.saltB64,
              createdAt: DateTime.now().toUtc(),
            ),
          );
    });
  }

  /// Delete the account named [username].
  ///
  /// Refuses trip route (a) — the last account holding a role that grants
  /// [AccessGroup.users] — via [_requireAUsersHolderRemains], inside the same
  /// transaction as the delete.
  ///
  /// It does **not** touch `audit_entry`. `audit_entry.who` is a denormalised
  /// TEXT column with no foreign key, precisely so the trail survives a deleted
  /// account by construction rather than by anybody remembering. That is a
  /// property to preserve: **no cascade may ever be added here**, and no admin
  /// screen may offer a delete, prune or export path over the trail.
  ///
  /// Throws [AnonymousAccountError] for the anonymous account.
  Future<void> deleteUser(String username) async {
    if (username == kAnonymousUsername) throw AnonymousAccountError('delete');
    await db.transaction(() async {
      final existing = await (db.select(db.appUser)
            ..where((t) => t.username.equals(username)))
          .getSingleOrNull();
      if (existing == null) throw UserNotFoundException(username);

      await _requireAUsersHolderRemains(_PendingChange.userDeleted(username));

      await (db.delete(db.appUser)..where((t) => t.username.equals(username)))
          .go();
    });
  }

  /// Move [username] onto [roleName].
  ///
  /// Refuses trip route (b) — moving the last `users` holder onto a role that
  /// does not grant it — via [_requireAUsersHolderRemains], after checking that
  /// the target role exists and inside the same transaction as the write.
  /// Flips the v8 station-account flag. Throws [UserNotFoundException].
  ///
  /// No lockout guard, deliberately: the flag is not a permission — it only
  /// changes whether the account's sessions expire — so no flip can take the
  /// last `users` holder away. Throws [AnonymousAccountError] for the
  /// anonymous account, which never has a session to keep alive.
  Future<void> setStationAccount(String username, bool value) async {
    if (username == kAnonymousUsername) {
      throw AnonymousAccountError('make a station account of');
    }
    final updated = await (db.update(db.appUser)
          ..where((t) => t.username.equals(username)))
        .write(AppUserCompanion(stationAccount: Value(value)));
    if (updated == 0) throw UserNotFoundException(username);
  }

  /// Sets [username]'s inactivity timeout in minutes, or clears it with null
  /// so the account uses the default.
  ///
  /// Throws [ArgumentError] outside `isValidInactivityTimeoutMinutes` rather
  /// than clamping: the caller can still ask for a better number, and a
  /// silently different value is a surprise in the audit trail. Throws
  /// [UserNotFoundException] when there is no such account.
  ///
  /// No lockout guard, for the reason [setStationAccount] gives: a timeout is
  /// not a permission. Throws [AnonymousAccountError] for the anonymous
  /// account: anonymous is what a session times out *into*.
  Future<void> setInactivityTimeout(String username, int? minutes) async {
    if (username == kAnonymousUsername) {
      throw AnonymousAccountError('set an inactivity timeout on');
    }
    if (minutes != null && !isValidInactivityTimeoutMinutes(minutes)) {
      throw ArgumentError.value(minutes, 'minutes',
          'must be ${kMinInactivityTimeout.inMinutes}..'
          '${kMaxInactivityTimeout.inMinutes}');
    }
    final updated = await (db.update(db.appUser)
          ..where((t) => t.username.equals(username)))
        .write(AppUserCompanion(inactivityTimeoutMinutes: Value(minutes)));
    if (updated == 0) throw UserNotFoundException(username);
  }

  /// Replace [username]'s roles with [roleNames], the first becoming the
  /// account's primary role.
  ///
  /// **A replacement, not an addition.** The accounts screen edits the whole
  /// list in one dialog and saves it in one write, so there is no add/remove
  /// pair to get out of step with each other, and no way to express "add this
  /// role" against a list somebody else changed in the meantime.
  ///
  /// Every name must exist in `app_role`; the whole call is refused with
  /// [MissingRoleError] otherwise, exactly as the single-role write was.
  /// Duplicates and blanks are removed by [normaliseRoleNames] rather than
  /// refused — they are the same request written untidily.
  ///
  /// Refuses trip route (b) — leaving the last `users` holder with no role that
  /// grants it — via [_requireAUsersHolderRemains], after checking that the
  /// target roles exist and inside the same transaction as the write. Throws
  /// [UserNotFoundException], and [ArgumentError] for an empty list: an account
  /// holding no role at all resolves to nothing and could not sign in.
  Future<void> setRoles(String username, List<String> roleNames) async {
    final roles = roleNames.isEmpty
        ? const <String>[]
        : normaliseRoleNames(
            primary: roleNames.first,
            additional: roleNames.skip(1),
          );
    if (roles.isEmpty) {
      throw ArgumentError.value(
          roleNames, 'roleNames', 'an account must hold at least one role');
    }
    await db.transaction(() async {
      final existing = await (db.select(db.appUser)
            ..where((t) => t.username.equals(username)))
          .getSingleOrNull();
      if (existing == null) throw UserNotFoundException(username);

      for (final wanted in roles) {
        final role = await (db.select(db.appRole)
              ..where((t) => t.name.equals(wanted)))
            .getSingleOrNull();
        if (role == null) throw MissingRoleError(wanted);
      }

      await _requireAUsersHolderRemains(_PendingChange.userRolesChanged(
        username: username,
        roleNames: roles,
      ));

      await (db.update(db.appUser)..where((t) => t.username.equals(username)))
          .write(AppUserCompanion(
        roleName: Value(roles.first),
        additionalRoles: Value(encodeAdditionalRoles(roles.skip(1))),
      ));
    });
  }

  /// Put [username] on [roleName] and nothing else.
  ///
  /// The single-role write this class has always had, kept because that is
  /// still what most calls mean — and it says so plainly: it **replaces**
  /// whatever set the account held, so an account holding two roles comes out
  /// of this holding one. Reach for [setRoles] to keep any.
  Future<void> setRole(String username, String roleName) =>
      setRoles(username, [roleName]);

  /// Replace [username]'s password.
  ///
  /// Hashed before the transaction opens, checked inside it — the same single
  /// decision [createUser] and [createFirstUser] document.
  ///
  /// Writes `password_hash` and `salt` and nothing else: it does not touch
  /// `last_login_at` and it does not sign anybody out, because there is no
  /// session state in this layer to invalidate. It never logs, echoes or
  /// returns the password or the hash, and the empty-password refusal carries
  /// no value for the same reason.
  ///
  /// No lockout guard: a password is not a permission, so no password can
  /// remove the last holder. Throws [AnonymousAccountError] for the anonymous
  /// account, which must never be signed in to.
  Future<void> setPassword(String username, String password) async {
    if (username == kAnonymousUsername) {
      throw AnonymousAccountError('set a password on');
    }
    if (password.isEmpty) {
      // Deliberately not `ArgumentError.value(password, ...)`: that puts the
      // credential into the message, and from there into whatever logs it.
      throw ArgumentError('password must not be empty');
    }

    final hash = await PasswordHasher.hash(password);

    await db.transaction(() async {
      final existing = await (db.select(db.appUser)
            ..where((t) => t.username.equals(username)))
          .getSingleOrNull();
      if (existing == null) throw UserNotFoundException(username);

      await (db.update(db.appUser)..where((t) => t.username.equals(username)))
          .write(AppUserCompanion(
        passwordHash: Value(encodeStoredHash(hash)),
        salt: Value(hash.saltB64),
      ));
    });
  }

  /// Rewrite [username]'s stored hash as [hash], returning the number of rows
  /// updated.
  ///
  /// The migration write-back: a user on a `pbkdf2-sha256` row is carried onto
  /// Argon2id on their next successful login, because that is the one moment
  /// the password is in hand. `LocalAuthProvider` is the only caller, and it
  /// asks [PasswordHasher.needsRehash] first.
  ///
  /// Four things this deliberately does not do. Each looks like an omission
  /// and none of them is:
  ///
  /// * **No derivation.** It takes an already-derived [PasswordHash]. The
  ///   derive-before-transaction discipline the three other writers keep by
  ///   convention is structural here, and it is also what lets the caller
  ///   decide *whether* a rewrite is due before paying for one.
  /// * **No transaction.** A single `UPDATE` is atomic on its own. The other
  ///   writers open one only to check a precondition first; opening one here
  ///   would put a round trip on every migrating login for nothing.
  /// * **No existence check.** The caller read this row moments ago on the
  ///   login path, so a zero-row result means the account was deleted in
  ///   between — a legitimate outcome, not an error. Hence the count rather
  ///   than the [UserNotFoundException] [setPassword] correctly throws, whose
  ///   caller has no such guarantee.
  /// * **Not a password change.** It rewrites the stored form of a password the
  ///   user already has, so it must not grow [setPassword]'s validation: there
  ///   is no new password here to validate.
  Future<int> rehashPassword(String username, PasswordHash hash) async {
    if (username == kAnonymousUsername) {
      throw AnonymousAccountError('rehash the password of');
    }
    final updated =
        await (db.update(db.appUser)..where((t) => t.username.equals(username)))
            .write(AppUserCompanion(
      passwordHash: Value(encodeStoredHash(hash)),
      salt: Value(hash.saltB64),
    ));
    return updated;
  }

  AccessRole _toRole(AppRoleData row) => AccessRole.fromDb(
        name: row.name,
        groupsJson: row.groups,
        seeded: row.seeded,
        allowedPagesJson: row.allowedPages,
      );
}
