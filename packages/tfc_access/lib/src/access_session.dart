import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'access_group.dart';
import 'access_role.dart';
import 'authenticated_user.dart';

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

  /// The groups resolved from [roleName]'s role at the time this session was
  /// built. Never persisted; see [toJson].
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

  /// The role this session answers as — the user's role, or [kOperatorRoleName]
  /// when nobody is signed in.
  String get roleName => user?.roleName ?? kOperatorRoleName;

  /// True when [expiresAt] is strictly before [now]. Equal is not yet expired,
  /// and a null [expiresAt] never is.
  bool isExpiredAt(DateTime now) {
    final at = expiresAt;
    return at != null && at.isBefore(now);
  }

  /// Device-local persistence: enough to re-resolve, not the resolved answer.
  ///
  /// [groups] are deliberately **not** serialized, and neither is
  /// [allowedPages]. Only the role *name* survives a restart; both resolved
  /// sets are re-read from the database on restore. Persisting them would let
  /// a role edited on another station stay stale on this one until the next
  /// login — and would let anyone with write access to the preferences file
  /// grant themselves a group the role does not have, or widen their own page
  /// whitelist, by editing a plain file on a panel anybody can walk up to.
  ///
  /// No password, hash, salt or token appears here, and none may be added:
  /// this payload is a plain file on a station anybody can walk up to.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'username': user?.username,
        'roleName': roleName,
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
    return PersistedSession(
      username: username,
      roleName: roleName,
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
        _setEquality.hash(groups),
        allowedPages == null ? null : _pageEquality.hash(allowedPages!),
      );

  @override
  String toString() => isElevated
      ? 'AccessSession(${user!.username} as $roleName until $expiresAt)'
      : 'AccessSession(anonymous as $roleName)';
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
    this.displayName,
    required this.expiresAt,
  });

  /// The `AppUser` primary key that was signed in.
  final String username;

  /// The name of the role that user held. Re-resolved to a group set on
  /// restore; a name that no longer matches a row means anonymous.
  final String roleName;

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
          other.roleName == roleName &&
          other.displayName == displayName &&
          other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(username, roleName, displayName, expiresAt);

  @override
  String toString() => 'PersistedSession($username as $roleName '
      'until $expiresAt)';
}
