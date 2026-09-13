import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'role_set.dart';

/// A person who has signed in: a username, the role or roles they hold, and
/// something to show them in the app bar.
///
/// Carries **no password-specific fields** on purpose. This is the type an
/// OIDC implementation would populate from claims without touching a single
/// caller, which is one of the three things spec §3 asks for to keep SSO cheap
/// later. Adding a hash, a salt or a token here is what would make that
/// expensive.
///
/// ## One role or several
///
/// It was one, and the argument for keeping it one was that multi-role brings
/// union semantics and an "effective permissions" inspector. The union
/// semantics turned out to be three lines in `role_set.dart` — roles were
/// already bundles of `AccessGroup`s rather than rungs on a ladder, so
/// composing two is a set union and nothing else — and the inspector is a
/// column the accounts screen already had room for. What the single role cost
/// instead was a combinatorial role table: a plant that wants somebody to be
/// Maintenance *and* Shift Leader had to mint "Maintenance + Shift Leader" and
/// keep it in step with both by hand, forever.
///
/// It also cut against the one thing this type exists for. An OIDC provider
/// returns a *list* of group claims, and `AppRole.name` is the primary key
/// precisely so an incoming claim matches a role by name with no mapping
/// table. A single-role user is the one shape that mapping cannot express.
///
/// [roleName] is still the account's primary role — the one `app_user.role_name`
/// stores and the one every station that never adds a second keeps. It carries
/// no extra authority: [roleNames] is what decides anything, and it is a union.
@immutable
class AuthenticatedUser {
  const AuthenticatedUser({
    required this.username,
    required this.roleName,
    this.additionalRoles = const <String>[],
    String? displayName,
    this.stationAccount = false,
  }) : _displayName = displayName;

  /// The `AppUser` primary key.
  final String username;

  /// The name of this account's primary role — matched against `AppRole.name`,
  /// never against an id.
  ///
  /// The one the foreign key points at, and the whole answer on a station that
  /// never adds a second role. **Not a precedence:** ask [roleNames] or
  /// [roleLabel], never this, when the question is what the account may do or
  /// what to show for it.
  final String roleName;

  /// The extra roles beyond [roleName], in the order they were given.
  ///
  /// What `app_user.additional_roles` stores, verbatim. May contain [roleName]
  /// itself or a blank — it is stored data, and this type does not police it;
  /// [roleNames] is where it is cleaned up, in one place.
  ///
  /// Defaulted so that every caller written when an account held one role
  /// builds the same one-role account it always did, and so this stays a `const`
  /// constructor.
  final List<String> additionalRoles;

  /// Every role this account holds, [roleName] first, deduplicated and trimmed.
  ///
  /// Never empty — [normaliseRoleNames] keeps the primary at the front. This is
  /// the list a session resolves groups and pages from, by union; see
  /// `role_set.dart`. Computed rather than stored so it cannot drift from
  /// [additionalRoles], which is the field that gets written to the column.
  List<String> get roleNames =>
      normaliseRoleNames(primary: roleName, additional: additionalRoles);

  /// True when this account holds more than its primary role.
  bool get hasMultipleRoles => roleNames.length > 1;

  /// What to show, and what the audit row's `role` column records: one name for
  /// one role, `A + B` for several. See [roleLabelFor].
  String get roleLabel => roleLabelFor(roleNames);

  final String? _displayName;

  /// Schema v8: this identity is a panel, not a person, and its sessions
  /// never expire. Set per ACCOUNT so the freezer display's login outlives
  /// every restart while a human on the same panel keeps the inactivity
  /// window. Defaults to false — every account is a person until somebody
  /// says otherwise.
  final bool stationAccount;

  /// What to show the operator. Falls back to [username] when nothing better
  /// is known, so the app bar never renders an empty elevation badge.
  String get displayName =>
      (_displayName == null || _displayName.isEmpty) ? username : _displayName;

  static const ListEquality<String> _roleEquality = ListEquality<String>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthenticatedUser &&
          other.username == username &&
          _roleEquality.equals(other.roleNames, roleNames) &&
          other.displayName == displayName &&
          other.stationAccount == stationAccount;

  @override
  int get hashCode => Object.hash(
        username,
        _roleEquality.hash(roleNames),
        displayName,
        stationAccount,
      );

  @override
  String toString() => 'AuthenticatedUser($username as $roleLabel)';
}
