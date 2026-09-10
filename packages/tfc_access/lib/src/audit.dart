import 'dart:math';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'access_group.dart';
import 'access_role.dart';

/// One row of the audit trail.
///
/// The field list mirrors the `AuditEntry` table in spec §2 **one for one**, in
/// column order. Plan 01-05 maps them straight across into the Drift row with
/// no translation layer, precisely so there is nothing in between to drift out
/// of sync when a column is added.
///
/// ## The auth surface
///
/// Spec §2 enumerates `surface` as `'tag' | 'pref' | 'route'` — the three
/// *write* surfaces. Phase 1 has no writes to audit; its done-condition is that
/// login, logout and failed attempts land in the table. So `'auth'` is a fourth
/// surface value, with its own itemKey vocabulary:
///
///     login | login.failed | logout | session.timeout | session.resume
///
/// and an **empty** [groupRequired], because signing in is not gated on a
/// group.
///
/// `session.resume` is the fifth and the only one no person performs: a panel
/// committed to a station account returns to that account when a human's
/// session over it ends. It is a row precisely *because* nobody did it — the
/// trail would otherwise show a human's `logout` and then writes attributed to
/// an account that never logged in. The named constructors below are what fix that vocabulary, so no
/// consumer has to invent column values and the Phase 5 trail viewer has
/// something exact to filter on.
///
/// ## The admin surface
///
/// Phase 6 adds a fifth surface, `'admin'`, for the writes the roles and users
/// screens make. A role edit that grants somebody `force` and leaves no trace
/// is the widest gap this product could ship with — re-scoping a role is the
/// most consequential hand-made write in it. The itemKey vocabulary is eight
/// strings:
///
///     role.create | role.update | role.delete | role.rename
///     user.create | user.delete | user.role   | user.password
///
/// Three things differ from the auth four, each on purpose:
///
/// 1. [groupRequired] is `AccessGroup.users.name`, not empty. Signing in is not
///    gated; editing a role is. That one field is also what puts these rows
///    behind the trail viewer's existing `users` filter chip with no change to
///    the viewer — a row carrying an empty [groupRequired] would fall outside
///    every group filter instead.
/// 2. [allowed] is a **parameter** on all eight. Each auth constructor *is* an
///    outcome and can hardcode it; an admin action can be refused by the `users`
///    gate, and a refused role edit is a row worth having. Allow-only
///    constructors would leave the store hand-building denial rows, which is the
///    vocabulary drifting on day one.
/// 3. [oldValue] and [newValue] carry group sets encoded the one way this
///    codebase encodes them, `AccessRole.encodeGroups()` — a JSON array in
///    [AccessGroup.values] order — so `["operate"] -> ["operate","force"]` is
///    legible in the viewer's generic old-to-new row.
///
/// **The account or role acted upon goes in [member], never in [itemKey].** The
/// itemKey vocabulary is a closed set of eight strings the viewer filters on;
/// folding the subject in (`user.role.jon`) would make it unbounded, and an
/// unbounded itemKey is an unfilterable one. The viewer already renders
/// [itemKey] with its [member] suffix, so `user.role` on member `jon` reads
/// correctly with no change there.
///
/// `'admin'` is a private literal on this class, **not** a fourth
/// `AccessSurface` value. `AccessSurface` is the type the policy answers
/// questions about, and nothing ever gates on an admin row; adding it there
/// would make `AccessSurface.byWireName` claim a surface the policy never
/// consults. `'auth'` set that precedent and this follows it exactly.
///
/// ## What must not be in here
///
/// No auth constructor takes a password, a hash or a salt, and none ever
/// should. [toString] withholds [oldValue] and [newValue] for auth rows for the
/// same reason — a trail that leaks credentials is worse than no trail.
///
/// That extends to the admin surface, where two constructors are where somebody
/// will be tempted: [AuditRecord.userPassword] and [AuditRecord.userCreate].
/// Neither takes a password, a hash or a salt, and [AuditRecord.userPassword]
/// leaves both value columns null. Note the hazard: [toString]'s withholding is
/// keyed on [isAuthEvent], i.e. `surface == 'auth'`, so an admin row's values
/// are **not** withheld from logs. That is correct for a group set, and it is
/// exactly why those two constructors have no parameter that could carry a
/// credential, rather than relying on callers to pass none.
@immutable
class AuditRecord {
  const AuditRecord({
    required this.at,
    required this.who,
    required this.station,
    required this.roleName,
    required this.surface,
    required this.itemKey,
    this.member,
    this.oldValue,
    this.newValue,
    required this.groupRequired,
    required this.allowed,
    this.origin = 'operator',
    required this.actionId,
    this.reason,
  });

  /// A successful sign-in.
  ///
  /// [roleName] is the role resolved for the new session; it is repeated in
  /// [newValue] so the trail reads as a transition without a join.
  factory AuditRecord.login({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    DateTime? at,
    String? reason,
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _authSurface,
        itemKey: 'login',
        newValue: roleName,
        groupRequired: '',
        allowed: true,
        actionId: actionId,
        reason: reason,
      );

  /// A rejected sign-in attempt.
  ///
  /// Denials are recorded, not only successes — a refused attempt is the more
  /// interesting audit line. [who] is whatever was typed into the username
  /// field, so it is untrusted input and is truncated to
  /// [maxAttemptedUsernameLength]; a login form accepts a paste, and a pasted
  /// megabyte must not become a row.
  ///
  /// The role is [kOperatorRoleName] because nobody was signed in: anonymous
  /// resolves to Operator by construction.
  factory AuditRecord.loginFailed({
    required String who,
    required String station,
    required String actionId,
    DateTime? at,
    String? reason,
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who.length > maxAttemptedUsernameLength
            ? who.substring(0, maxAttemptedUsernameLength)
            : who,
        station: station,
        roleName: kOperatorRoleName,
        surface: _authSurface,
        itemKey: 'login.failed',
        groupRequired: '',
        allowed: false,
        actionId: actionId,
        reason: reason,
      );

  /// A deliberate sign-out. [roleName] is the elevated role being left, and is
  /// repeated in [oldValue].
  factory AuditRecord.logout({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    DateTime? at,
    String? reason,
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _authSurface,
        itemKey: 'logout',
        oldValue: roleName,
        groupRequired: '',
        allowed: true,
        actionId: actionId,
        reason: reason,
      );

  /// A session dropped by the inactivity timer.
  ///
  /// `allowed: true` — the session ending is the system working, not a denial.
  /// [reason] carries what tripped it (the configured idle interval), which is
  /// what makes a wall of timeout rows readable a month later.
  factory AuditRecord.sessionTimeout({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    DateTime? at,
    String? reason,
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _authSurface,
        itemKey: 'session.timeout',
        oldValue: roleName,
        groupRequired: '',
        allowed: true,
        actionId: actionId,
        reason: reason,
      );

  /// A committed panel returned to its station account.
  ///
  /// Not a sign-in: nobody typed a password, and no [AuthProvider] was
  /// consulted. The credential was presented once, when the panel was
  /// committed; this row is the panel coming back to the identity it already
  /// held after a human's session over it ended, timed out, or the panel
  /// restarted.
  ///
  /// It is deliberately **not** an [AuditRecord.login]. A `login` row means a
  /// credential was accepted at that instant, and a month later nobody can tell
  /// a real sign-in from a resume if the two share an itemKey — which matters
  /// exactly when somebody is asking whether a person was at the panel.
  ///
  /// [roleName] is the role resolved *at resume*, not the one stored when the
  /// panel was committed: the account's role may have been changed in between,
  /// and the row must say what the panel actually came back holding. It is
  /// repeated in [newValue] so the trail reads as a transition without a join.
  ///
  /// `allowed: true` — the panel returning to its baseline is the system
  /// working, like [sessionTimeout] and unlike [loginFailed].
  factory AuditRecord.sessionResume({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    DateTime? at,
    String? reason,
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _authSurface,
        itemKey: 'session.resume',
        newValue: roleName,
        groupRequired: '',
        allowed: true,
        actionId: actionId,
        reason: reason,
      );

  /// A role was created.
  ///
  /// [subject] is the new role's name and lands in [member]; [roleName] is the
  /// role the editor held at the time, as on every row. [groups] is the new
  /// role's `AccessRole.encodeGroups()` output.
  factory AuditRecord.roleCreate({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String groups,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'role.create',
        member: subject,
        newValue: groups,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// A role's group set was edited — the most consequential hand-made write in
  /// the product, and the one this surface exists for.
  ///
  /// [oldGroups] and [newGroups] are both `AccessRole.encodeGroups()` output, so
  /// the row reads as `["operate"] -> ["operate","force"]` in the trail viewer's
  /// generic old-to-new shape.
  factory AuditRecord.roleUpdate({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String oldGroups,
    required String newGroups,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'role.update',
        member: subject,
        oldValue: oldGroups,
        newValue: newGroups,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// A role was deleted. [groups] is what it granted, so the row still says what
  /// was lost after the row it described is gone.
  factory AuditRecord.roleDelete({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String groups,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'role.delete',
        member: subject,
        oldValue: groups,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// A role was renamed.
  ///
  /// [member] is [oldName] — the role as it was named when the action began,
  /// which is the string the rest of the trail up to this point refers to.
  factory AuditRecord.roleRename({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String oldName,
    required String newName,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'role.rename',
        member: oldName,
        oldValue: oldName,
        newValue: newName,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// An account was created. [subject] is the new username, [grantedRole] the
  /// role it was given.
  ///
  /// **There is no password parameter, and there must never be one.** Creating
  /// an account means typing a password, so this is one of the two places a
  /// credential would be handed to the trail if the signature allowed it. See
  /// the hazard note on [AuditRecord.userPassword].
  factory AuditRecord.userCreate({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String grantedRole,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'user.create',
        member: subject,
        newValue: grantedRole,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// An account was deleted. [heldRole] is the role it held.
  ///
  /// The account's own audit rows survive it: `audit_entry.who` is a
  /// denormalised TEXT column with no foreign key, on purpose.
  factory AuditRecord.userDelete({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String heldRole,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'user.delete',
        member: subject,
        oldValue: heldRole,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// An account was moved to a different role.
  ///
  /// `user.role` with a [member] of `jon` reads correctly in the trail viewer's
  /// generic row, which is why the username is here and not in the itemKey.
  /// A station-account flip: `user.station_account`, subject in `member`,
  /// the booleans in the value columns. Same shape as [AuditRecord.userRole]
  /// because it is the same kind of change — an attribute of an account that
  /// widens or narrows what a panel can do unattended.
  factory AuditRecord.userStationAccount({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required bool oldValue,
    required bool newValue,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'user.station_account',
        member: subject,
        oldValue: oldValue.toString(),
        newValue: newValue.toString(),
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  factory AuditRecord.userRole({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required String oldRole,
    required String newRole,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'user.role',
        member: subject,
        oldValue: oldRole,
        newValue: newRole,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// An account's password was reset by an administrator.
  ///
  /// This records **that** it happened, on which account, by whom — and nothing
  /// else. [oldValue] and [newValue] are null and there is no parameter that
  /// could fill them.
  ///
  /// **The hazard, written here because this is where it will be met.**
  /// [toString]'s withholding of the value columns is keyed on [isAuthEvent],
  /// i.e. `surface == 'auth'`. This is an admin row, so its values are **not**
  /// withheld — they go into log files that live longer and travel further than
  /// the database does. That is correct for a group set, and it is exactly why
  /// this constructor leaves the value fields null by construction rather than
  /// by discipline. Do not add a password, a hash or a salt parameter "just for
  /// debugging": a trail that leaks credentials is worse than no trail.
  factory AuditRecord.userPassword({
    required String who,
    required String station,
    required String roleName,
    required String actionId,
    required String subject,
    required bool allowed,
    DateTime? at,
    String? reason,
    String origin = 'operator',
  }) =>
      AuditRecord(
        at: at ?? clock.now(),
        who: who,
        station: station,
        roleName: roleName,
        surface: _adminSurface,
        itemKey: 'user.password',
        member: subject,
        groupRequired: AccessGroup.users.name,
        allowed: allowed,
        origin: origin,
        actionId: actionId,
        reason: reason,
      );

  /// The `surface` value shared by every auth row.
  static const String _authSurface = 'auth';

  /// The `surface` value shared by every admin row.
  ///
  /// A private literal, deliberately, exactly as [_authSurface] is. `admin` is
  /// **not** an `AccessSurface` value: that enum is what the policy answers
  /// questions about, and the policy never gates on an admin row. Putting it
  /// there would make `AccessSurface.byWireName` claim a surface nothing
  /// consults.
  static const String _adminSurface = 'admin';

  /// The cap applied to the attempted username on a failed login.
  static const int maxAttemptedUsernameLength = 64;

  /// When it happened.
  final DateTime at;

  /// Username, or `'anonymous'`.
  final String who;

  /// Hostname of the station the action came from.
  final String station;

  /// The role in force at the time.
  final String roleName;

  /// `'tag' | 'pref' | 'route' | 'auth' | 'admin'`.
  final String surface;

  /// The tag, preference key, route or auth event.
  final String itemKey;

  /// Dotted path within a struct, for member-level tag writes.
  final String? member;

  /// Value before the write.
  final String? oldValue;

  /// Value after the write.
  final String? newValue;

  /// Name of the `AccessGroup` the action required — empty for auth rows.
  final String groupRequired;

  /// False for a denial. Denials are recorded too; a denied write is how you
  /// find a role configured too tightly.
  final bool allowed;

  /// `'operator'` by default, on purpose — see the class doc and spec §2. An
  /// unmarked machine caller lands in the trail loudly rather than escaping it
  /// silently.
  final String origin;

  /// Correlation id. One human action is one [actionId] with N rows beneath it,
  /// so a recipe apply reads as one action rather than N unrelated rows.
  final String actionId;

  /// Free text captured on `configure` and `administer` writes. Reason is what
  /// turns a log into an audit trail.
  final String? reason;

  /// True when this row describes an authentication event rather than a write.
  bool get isAuthEvent => surface == _authSurface;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditRecord &&
          other.at == at &&
          other.who == who &&
          other.station == station &&
          other.roleName == roleName &&
          other.surface == surface &&
          other.itemKey == itemKey &&
          other.member == member &&
          other.oldValue == oldValue &&
          other.newValue == newValue &&
          other.groupRequired == groupRequired &&
          other.allowed == allowed &&
          other.origin == origin &&
          other.actionId == actionId &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(
        at,
        who,
        station,
        roleName,
        surface,
        itemKey,
        member,
        oldValue,
        newValue,
        groupRequired,
        allowed,
        origin,
        actionId,
        reason,
      );

  /// Diagnostic form.
  ///
  /// [oldValue] and [newValue] are withheld for auth rows. Nothing should ever
  /// put a credential in them, but this string ends up in log files that live
  /// longer and travel further than the database does, and the cost of the
  /// precaution is one branch.
  @override
  String toString() {
    final values = isAuthEvent ? '<withheld>' : '$oldValue -> $newValue';
    return 'AuditRecord($at $who@$station as $roleName, '
        '$surface:$itemKey${member == null ? '' : '.$member'}, '
        '$values, allowed: $allowed, origin: $origin, action: $actionId)';
  }
}

final Random _actionIdRandom = Random.secure();

/// A fresh correlation id: 16 random bytes as 32 lowercase hex characters.
///
/// One human action gets one id, and every row that action produces carries it
/// — so a recipe apply reads as one action with N member rows beneath it rather
/// than N unrelated rows.
///
/// `Random.secure()` rather than a `uuid` dependency: 128 bits is already more
/// than enough to make ids non-colliding and unguessable, and this package
/// stays free of third-party packages that would follow it into the relay.
String newActionId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer
        .write(_actionIdRandom.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Where audit rows go.
///
/// Implementations are **append-only**. Never update, never delete: the trail's
/// only value is that nothing has been removed from it. Retention policies must
/// not touch the audit table — spec §8 asks for that to be asserted in a test,
/// because the collector's `registerRetentionPolicy` would happily sweep it.
///
/// A sink whose write fails **must not take its caller down with it.** The
/// caller is a login flow, and refusing to sign somebody in because the audit
/// database blinked is worse than a gap in the trail. But the failure must be
/// logged loudly, because an absent audit row is the one defect nobody ever
/// notices.
abstract class AuditSink {
  /// Append [entry]. Completes when the row is durable, or when the failure has
  /// been logged — never by throwing at a login flow.
  Future<void> record(AuditRecord entry);
}

/// An [AuditSink] that discards everything.
///
/// Not test-only, so not `@visibleForTesting`: it is the legitimate sink during
/// the boot window before the database is open, and in any build that runs
/// without one. Anything using it is knowingly running with no trail.
class NullAuditSink implements AuditSink {
  const NullAuditSink();

  @override
  Future<void> record(AuditRecord entry) async {}
}
