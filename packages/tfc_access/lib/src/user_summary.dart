/// The users roster row.
///
/// Declared here, beside [AuthenticatedUser], rather than in the protocol
/// package — this is access vocabulary, and `AccessAdminStore.listUsers`
/// answers it in direct mode where there is no wire at all. Its JSON codecs
/// (`userSummaryToJson` / `userSummaryFromJson`) stay in
/// `tfc_relay_protocol`, which is where encoding belongs.
library;

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

  @override
  String toString() => 'UserSummary($username, role: $roleName, '
      'station: $stationAccount, password: $hasPassword, '
      'created: $createdAt, lastLogin: $lastLoginAt, '
      'pages: $allowedPages)';
}
