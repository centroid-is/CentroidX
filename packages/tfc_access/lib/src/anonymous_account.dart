/// The account a panel with nobody signed in answers as.
///
/// Anonymous used to **be** the role named `Operator`, by construction. That
/// put a property of the panel on a role: every edit to the Operator row was
/// silently an edit to every logged-out panel on the floor, and the role could
/// not be renamed or deleted because a panel resolved to it by name.
///
/// It is now an **account** — a reserved `app_user` row named
/// [kAnonymousUsername] — and holds roles like any other account: a primary,
/// any extras, and optionally a personal page whitelist. What a logged-out
/// panel may do is composed from that row exactly as a signed-in session is
/// composed from its own, through `role_set.dart` and `effectiveAllowedPages`.
/// `Operator` is an ordinary role again; the row is merely seeded onto it, so
/// an upgraded station's logged-out panels can do exactly what they could
/// before.
///
/// The row can never authenticate. Two locks, each sufficient alone:
///
/// * the login path refuses [isAnonymousUsername] before it reads a row;
/// * the row's hash is [kAnonymousPasswordSentinel], an algorithm tag no build
///   implements, so `PasswordHash.tryDecode` answers null and every build —
///   including ones older than this file — refuses the login as undecodable.
library;

import 'package:meta/meta.dart';

import 'access_group.dart';
import 'access_role.dart';
import 'allowed_pages.dart';
import 'role_set.dart';

/// The username of the reserved account.
///
/// Deliberately the same string the audit trail has always written as `who`
/// for a logged-out panel, so a trail row and the account it names agree
/// without a mapping.
const String kAnonymousUsername = 'anonymous';

/// True when [name] would read as the reserved account.
///
/// Case-insensitive and whitespace-tolerant, for creation and for the login
/// refusal: an account a person created as `Anonymous` would sit in the roster
/// looking like the panel while being a person.
bool isAnonymousUsername(String name) =>
    name.trim().toLowerCase() == kAnonymousUsername;

/// The `password_hash` the reserved row carries.
///
/// Not a hash. The prefix names no algorithm any build implements, so decoding
/// it throws and every login against it fails as "could not be decoded".
const String kAnonymousPasswordSentinel = r'none$anonymous';

/// The `salt` the reserved row carries. Empty: there is no credential to salt.
const String kAnonymousSaltSentinel = '';

/// Thrown when something tries to delete the reserved account, give it a
/// password, make it a station account, or give it an inactivity timeout.
///
/// An [Error] rather than an [Exception]: the accounts screen does not offer
/// those controls on the row, so reaching this means a caller skipped the
/// check, which is a defect in the caller rather than a condition to recover
/// from.
class AnonymousAccountError extends Error {
  AnonymousAccountError(this.operation);

  /// What was attempted, for the log line.
  final String operation;

  @override
  String toString() => 'AnonymousAccountError: refused to $operation the '
      '"$kAnonymousUsername" account — it is every panel with nobody signed '
      'in, and it only holds roles and pages.';
}

/// Thrown when an account is created under a name [isAnonymousUsername]
/// matches.
///
/// An [Exception]: the create dialog renders it, like a duplicate username.
class ReservedUsernameException implements Exception {
  const ReservedUsernameException(this.username);

  /// The name that was refused.
  final String username;

  @override
  String toString() => 'ReservedUsernameException: "$username" is reserved '
      'for the account a logged-out panel answers as.';
}

/// The resolved anonymous account: the roles it holds and its personal page
/// whitelist, composed the same way a signed-in account's are.
@immutable
class AnonymousAccount {
  AnonymousAccount({
    required List<AccessRole> roles,
    this.pagesOverride,
  })  : assert(roles.isNotEmpty, 'the anonymous account holds a role'),
        roles = List.unmodifiable(roles);

  /// Every role the account holds, primary first.
  final List<AccessRole> roles;

  /// The account's own `allowed_pages`, or null to inherit its roles'.
  final Set<String>? pagesOverride;

  /// Everything a logged-out panel may do.
  Set<AccessGroup> get groups => unionRoleGroups(roles);

  /// The pages a logged-out panel sees, or null for every page.
  Set<String>? get allowedPages => effectiveAllowedPages(
        user: pagesOverride,
        role: unionRoleAllowedPages(roles),
      );

  /// The role names, primary first — what a badge and a trail row show.
  List<String> get roleNames => List.unmodifiable(roles.map((r) => r.name));

  @override
  String toString() => 'AnonymousAccount(${roleLabelFor(roleNames)}, '
      'pages: ${encodeAllowedPagesColumn(allowedPages) ?? 'all'})';
}
