/// The users roster row.
///
/// Declared here, beside [AuthenticatedUser], rather than in the protocol
/// package — this is access vocabulary, and `AccessAdminStore.listUsers`
/// answers it in direct mode where there is no wire at all. Its JSON codecs
/// (`userSummaryToJson` / `userSummaryFromJson`) stay in
/// `tfc_relay_protocol`, which is where encoding belongs.
library;

import 'role_set.dart';

/// One row of the users roster, for `AccessAdminApi.listUsers`.
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
    this.allowedPages,
    this.additionalRoles = const <String>[],
    this.inactivityTimeoutMinutes,
    this.homePage,
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

  /// The roles this account holds **beyond** [roleName], decoded and in
  /// order — `app_user.additional_roles`.
  ///
  /// Empty is the ordinary case and means "holds only its primary role". The
  /// primary stays in [roleName] rather than being folded into a single list,
  /// because the row's own column does: `normaliseRoleNames` derives the whole
  /// set from the pair, and a DTO that flattened them would have to pick one
  /// back out to write the row.
  ///
  /// Defaults to empty, which is also what a backend older than this field
  /// means: before an account could hold more than one role, every account
  /// held exactly its primary. Under-claiming is the safe direction here, as
  /// it is for [hasPassword].
  final List<String> additionalRoles;

  /// This account's own inactivity window in minutes, or null to use the
  /// station default — `app_user.inactivity_timeout_minutes`.
  ///
  /// Null is "no value of its own", not "never expires": only
  /// [stationAccount] makes a session immortal. `resolveInactivityTimeout`
  /// is the one place the null case and the clamping are decided.
  final int? inactivityTimeoutMinutes;

  /// The page this account's sessions open on (`app_user.home_page`), as a
  /// route path, or null for Home — see `AppUserData.homePage`. Carried here
  /// so the roster can say it wherever the roster is rendered, the gateway
  /// panel included; setting it is `AccessAdminStore.setUserHomePage`.
  final String? homePage;

  /// This account's personal page whitelist, decoded — `app_user.allowed_pages`.
  ///
  /// **Null and empty are different claims**, as everywhere else the whitelist
  /// appears: null is "no personal opinion, follow the role", the empty set is
  /// a personal block-all. `effectiveAllowedPages` is the one place the two
  /// levels are composed; see `allowed_pages.dart`.
  ///
  /// Decoded rather than the raw column, matching [AccessRole.allowedPages] —
  /// the roster type is what the users screen renders and what crosses the
  /// wire, and neither should have to know the storage encoding.
  ///
  /// It is roster data, not a credential: it says what an account may see, and
  /// the roster is gated on `users` either way. The rule keeping hashes out of
  /// this type is about there being nowhere to put one, and that is unchanged.
  final Set<String>? allowedPages;

  /// Every role this account holds, primary first — [roleName] and
  /// [additionalRoles] composed through the one normaliser.
  ///
  /// The DTO's answer to `AccessRepository.rolesOf`, which does the same for a
  /// drift row. Two derivations of "which roles does this account hold" is how
  /// the roster and the session start disagreeing about one person, so the
  /// screens call this rather than reading the two fields.
  List<String> get roles =>
      normaliseRoleNames(primary: roleName, additional: additionalRoles);

  @override
  String toString() => 'UserSummary($username, role: $roleName, '
      'station: $stationAccount, password: $hasPassword, '
      'created: $createdAt, lastLogin: $lastLoginAt, '
      'alsoHolds: $additionalRoles, timeout: $inactivityTimeoutMinutes, '
      'pages: $allowedPages)';
}
