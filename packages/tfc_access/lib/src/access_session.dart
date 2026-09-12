import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'access_group.dart';
import 'access_role.dart';
import 'authenticated_user.dart';
import 'role_set.dart';

const _setEquality = SetEquality<AccessGroup>();
const _pageEquality = SetEquality<String>();

/// Who is standing at this panel, and what they may do.
///
/// Station-local and never synced: a session is a property of the person at
/// *this* panel, so it lives in Riverpod state plus device-local preferences,
/// never in the shared database (spec §5, §10).
///
/// A value type. Nothing here gates anything — [can] is vocabulary the guards
/// in a later phase consult, and this class has no opinion about what a caller
/// does with the answer.
@immutable
class AccessSession {
  const AccessSession({
    this.user,
    required this.groups,
    this.expiresAt,
    this.allowedPages,
    this.inactivityTimeout,
  });

  /// A session with no user signed in.
  ///
  /// Anonymous **is** the role named [kOperatorRoleName] — by construction, not
  /// through a configurable pointer. Full stop: there is no setting that makes
  /// anonymous resolve to something else, which is what keeps "anonymous is
  /// operator" true without anyone maintaining it.
  ///
  /// [operatorGroups] is passed in rather than hardcoded because those groups
  /// are customer data. The `Operator` row is editable, and editing it changes
  /// what an *unauthenticated* panel may do: ticking `setpoints` on Operator
  /// silently grants it to every panel on the floor with nobody signed in. That
  /// is the one footgun this simplification creates, and the Phase 6 roles
  /// screen has to say so at the point of edit. Read the groups from the
  /// database at the moment you build the session, so an edit takes effect
  /// without a restart.
  ///
  /// [expiresAt] is deliberately absent: anonymous is the state a session times
  /// out *into*, so it never expires itself.
  /// [operatorAllowedPages] is the `Operator` row's page whitelist, resolved
  /// at the same moment and from the same row as [operatorGroups] — anonymous
  /// has no `app_user` row, so there is no personal override to compose and
  /// the role's whitelist *is* the session's. Optional and defaulting to null
  /// (every page) so that a caller which has not been taught about the
  /// whitelist behaves exactly as it did before it existed.
  factory AccessSession.anonymous(
    Set<AccessGroup> operatorGroups, {
    Set<String>? operatorAllowedPages,
  }) =>
      AccessSession(
        groups: operatorGroups,
        allowedPages: operatorAllowedPages,
      );

  /// The signed-in user, or null when nobody is — see [AccessSession.anonymous].
  final AuthenticatedUser? user;

  /// The groups this session holds: the **union** of every role in
  /// [roleNames], resolved at the time the session was built.
  ///
  /// Already composed, exactly as [allowedPages] is, so nothing downstream has
  /// to know how many roles an account holds. See `role_set.dart` for why the
  /// composition is a union and not an intersection.
  ///
  /// Never persisted; see [toJson].
  final Set<AccessGroup> groups;

  /// When inactivity ends this session. Null for anonymous, which never
  /// expires.
  ///
  /// This — not elapsed wall clock — is a session's authority. A controller
  /// that detaches and re-attaches arms its countdown against the time
  /// remaining until this instant, so going away and coming back cannot extend
  /// a session.
  final DateTime? expiresAt;

  /// The pages this session may see, or null when it may see every page.
  ///
  /// The **already-composed** answer: `effectiveAllowedPages(user: …, role: …)`
  /// is applied where the session is built, so nothing downstream has to know
  /// that two levels exist. Resolved from the database at that moment, exactly
  /// like [groups], and deliberately never persisted — see [toJson].
  ///
  /// Null means unrestricted; the empty set means no page at all. Ask
  /// [pageVisible] rather than reading this, so the null case is not
  /// re-implemented per call site.
  final Set<String>? allowedPages;

  /// How long this session may sit idle, or null when it never expires.
  ///
  /// The signed-in account's own value (`app_user.inactivity_timeout_minutes`,
  /// through `resolveInactivityTimeout`), so two people on the same panel each
  /// get their own window. Null for anonymous, for station accounts and for a
  /// resumed panel — the sessions with no [expiresAt] to extend.
  ///
  /// Resolved from the database where the session is built, exactly like
  /// [groups], and deliberately never persisted — see [toJson].
  final Duration? inactivityTimeout;

  /// Whether this session holds [g]. Vocabulary only in Phase 1: nothing calls
  /// this to deny anything yet.
  bool can(AccessGroup g) => groups.contains(g);

  /// Whether this session's whitelist admits [path].
  ///
  /// True whenever there is no whitelist, which is what keeps a station that
  /// has never configured one behaving exactly as before.
  ///
  /// **Says nothing about groups.** A page can be admitted here and still be
  /// refused by its `requiredGroup`; the two questions are ANDed by
  /// `resolvePageAccess`, and this half must never be mistaken for the whole
  /// decision.
  ///
  /// Matches the stored path exactly — no prefix matching, no normalisation. A
  /// stored path naming no current page therefore admits nothing, which is the
  /// fail-closed direction a renamed or deleted page must take.
  bool pageVisible(String path) =>
      allowedPages == null || allowedPages!.contains(path);

  /// True when somebody is signed in. The app bar shows who, and offers logout.
  bool get isElevated => user != null;

  /// The **primary** role this session answers as — the user's, or
  /// [kOperatorRoleName] when nobody is signed in.
  ///
  /// Identity, not authority. An account can hold several roles and this is
  /// only the first of them; [groups] is already the union and is what decides
  /// anything. Ask [roleNames] when the question is which roles, and
  /// [roleLabel] when the answer is going on a screen or into a trail row.
  String get roleName => user?.roleName ?? kOperatorRoleName;

  /// Every role this session holds, primary first.
  ///
  /// `[kOperatorRoleName]` for anonymous, by construction rather than through a
  /// configurable pointer — see [AccessSession.anonymous].
  List<String> get roleNames =>
      user?.roleNames ?? const <String>[kOperatorRoleName];

  /// What a badge shows and what the audit row's `role` column records: one
  /// name for one role, `A + B` for several. See [roleLabelFor].
  String get roleLabel => roleLabelFor(roleNames);

  /// True when [expiresAt] is strictly before [now]. Equal is not yet expired,
  /// and a null [expiresAt] never is.
  bool isExpiredAt(DateTime now) {
    final at = expiresAt;
    return at != null && at.isBefore(now);
  }

  /// Device-local persistence: enough to re-resolve, not the resolved answer.
  ///
  /// [groups] are deliberately **not** serialized, and neither is
  /// [allowedPages] nor [inactivityTimeout]. Only the role *name* survives a
  /// restart; all three are re-read from the database on restore — a
  /// hand-edited timeout in this file would otherwise be a way to widen the
  /// window an administrator set. Persisting them would let
  /// a role edited on another station stay stale on this one until the next
  /// login — and would let anyone with write access to the preferences file
  /// grant themselves a group the role does not have, or widen their own page
  /// whitelist, by editing a plain file on a panel anybody can walk up to.
  ///
  /// No password, hash, salt or token appears here, and none may be added:
  /// this payload is a plain file on a station anybody can walk up to.
  /// `additionalRoles` is omitted when there are none, so an account holding
  /// one role writes exactly the payload this file has always written and a
  /// station downgraded to an older build reads it back unchanged.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'username': user?.username,
        'roleName': roleName,
        if (roleNames.length > 1) 'additionalRoles': roleNames.skip(1).toList(),
        'displayName': user?.displayName,
        'expiresAt': expiresAt?.toIso8601String(),
      };

  /// Read back what [toJson] wrote, or null if it is not readable.
  ///
  /// Returns a [PersistedSession] rather than an `AccessSession` on purpose:
  /// what came off disk is unvalidated, its role may since have been edited or
  /// deleted, and it may already have expired. Resolving it into a live session
  /// is the caller's job, and giving that step its own type is what stops
  /// stored data being treated as a live session by accident.
  ///
  /// Never throws. Garbage in the preferences file costs the operator a login
  /// prompt, never the app its boot — the same reasoning as
  /// [AccessRole.decodeGroups].
  static PersistedSession? parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    final username = decoded['username'];
    final roleName = decoded['roleName'];
    final expiresAt = decoded['expiresAt'];
    if (username is! String || username.isEmpty) return null;
    if (roleName is! String || roleName.isEmpty) return null;
    if (expiresAt is! String) return null;

    final at = DateTime.tryParse(expiresAt);
    if (at == null) return null;

    final displayName = decoded['displayName'];
    // Absent on every payload written before schema v9, and on every
    // single-role payload written since. Whatever is not a list of non-blank
    // strings reads as "no extra roles", which narrows — the same ruling, for
    // the same reason, as [decodeAdditionalRoles] makes about the column.
    final extra = decoded['additionalRoles'];
    return PersistedSession(
      username: username,
      roleName: roleName,
      additionalRoles: extra is List
          ? extra
              .whereType<String>()
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(growable: false)
          : const <String>[],
      displayName: displayName is String ? displayName : null,
      expiresAt: at,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccessSession &&
          other.user == user &&
          other.expiresAt == expiresAt &&
          other.inactivityTimeout == inactivityTimeout &&
          _setEquality.equals(other.groups, groups) &&
          _samePages(other.allowedPages, allowedPages);

  /// Null (no whitelist) and the empty set (no pages) are different sessions
  /// and must not compare equal.
  static bool _samePages(Set<String>? a, Set<String>? b) {
    if (a == null || b == null) return a == null && b == null;
    return _pageEquality.equals(a, b);
  }

  @override
  int get hashCode => Object.hash(
        user,
        expiresAt,
        inactivityTimeout,
        _setEquality.hash(groups),
        allowedPages == null ? null : _pageEquality.hash(allowedPages!),
      );

  @override
  String toString() => isElevated
      ? 'AccessSession(${user!.username} as $roleLabel until $expiresAt)'
      : 'AccessSession(anonymous as $roleLabel)';
}

/// What survives a restart: enough to re-resolve, not the resolved answer.
///
/// This is device-local preference data as it came off disk, *before* it has
/// been checked against the database. Its role may have been edited, renamed or
/// deleted since, and it may have expired while the station was off — an
/// expired payload must resolve to anonymous rather than to its user, which is
/// what [isExpiredAt] is for.
@immutable
class PersistedSession {
  const PersistedSession({
    required this.username,
    required this.roleName,
    this.additionalRoles = const <String>[],
    this.displayName,
    required this.expiresAt,
  });

  /// The `AppUser` primary key that was signed in.
  final String username;

  /// The name of the **primary** role that user held. Re-resolved to a group
  /// set on restore; a name that no longer matches a row means anonymous.
  final String roleName;

  /// The extra roles the payload named, in order.
  ///
  /// Re-resolved on restore exactly like [roleName], and with one difference
  /// that is the whole point of keeping them apart: a primary role that no
  /// longer exists drops the session to anonymous, while an *extra* role that
  /// no longer exists is simply dropped. Losing a role narrows; losing the
  /// account's identity does not.
  final List<String> additionalRoles;

  /// Every role the payload named, primary first, deduplicated.
  List<String> get roleNames =>
      normaliseRoleNames(primary: roleName, additional: additionalRoles);

  final String? displayName;

  /// When the stored session ended. Always present — a payload without one is
  /// not restorable and [AccessSession.parse] returns null for it.
  final DateTime expiresAt;

  /// True when [expiresAt] is strictly before [now]. Equal is not yet expired.
  bool isExpiredAt(DateTime now) => expiresAt.isBefore(now);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistedSession &&
          other.username == username &&
          _roleEquality.equals(other.roleNames, roleNames) &&
          other.displayName == displayName &&
          other.expiresAt == expiresAt;

  static const ListEquality<String> _roleEquality = ListEquality<String>();

  @override
  int get hashCode => Object.hash(
        username,
        _roleEquality.hash(roleNames),
        displayName,
        expiresAt,
      );

  @override
  String toString() => 'PersistedSession($username as '
      '${roleLabelFor(roleNames)} until $expiresAt)';
}
