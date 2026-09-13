import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'access_group.dart';
import 'allowed_pages.dart';

/// The name of the seeded role the anonymous account starts out holding.
///
/// An ordinary role: it may be edited, renamed or deleted like any other.
/// What a panel with nobody signed in may do is decided by the reserved
/// account in `anonymous_account.dart`, which the seed puts on this role so an
/// upgraded station's logged-out panels keep exactly the groups and pages they
/// had. It is also the floor a panel falls back to when that account cannot be
/// read — see `AccessRepository.anonymousAccount`.
const String kOperatorRoleName = 'Operator';

/// A role: a name and the set of groups it grants.
///
/// Roles are customer data — rows in `AppRole`, created and edited at
/// commissioning. [name] is the primary key rather than a surrogate integer
/// **on purpose**: when OIDC lands, an incoming group claim of `"Shift Leader"`
/// matches the role by name with no mapping table, exactly as Ignition and
/// SIMATIC Logon do it. Do not replace it with an id.
@immutable
class AccessRole {
  const AccessRole({
    required this.name,
    required this.groups,
    this.seeded = false,
    this.allowedPages,
  });

  /// Rebuild a role from its stored `AppRole` columns.
  ///
  /// [groupsJson] is the raw TEXT column; decoding is deliberately forgiving,
  /// see [decodeGroups].
  factory AccessRole.fromDb({
    required String name,
    required String groupsJson,
    required bool seeded,
    String? allowedPagesJson,
  }) =>
      AccessRole(
        name: name,
        groups: decodeGroups(groupsJson),
        seeded: seeded,
        allowedPages: decodeAllowedPagesColumn(allowedPagesJson),
      );

  /// Primary key of the `AppRole` row.
  final String name;

  /// The groups this role grants. Order is not meaningful; see [encodeGroups]
  /// for the stable serialised form.
  final Set<AccessGroup> groups;

  /// The page paths this role may see, or null when it may see every page.
  ///
  /// Null and empty are different claims and both are meaningful: null is "no
  /// whitelist" — today's behaviour, and what every row carried over from
  /// schema v6 holds — while the empty set is a whitelist naming nothing, i.e.
  /// block all. See `docs/page-visibility-whitelist-design.md` §1b.
  ///
  /// **A page path, never a section path**, and never a role or a group: this
  /// is the identity side of the relation pointing at pages, which is the
  /// direction that fails closed when a page is renamed away. The inverse —
  /// pages naming roles — is ruled out by `MenuItem.requiredGroup`'s doc.
  ///
  /// A role's whitelist governs everyone holding it who has no personal
  /// override — the anonymous account included, so a role that account holds
  /// governs every logged-out panel on the floor.
  final Set<String>? allowedPages;

  /// True for the rows written by the schema-v6 seed migration.
  ///
  /// Informational only — a seeded role is an ordinary row afterwards and may
  /// be edited, renamed or deleted like any other.
  final bool seeded;

  /// Whether this role grants [g].
  bool can(AccessGroup g) => groups.contains(g);

  /// The `AppRole.groups` TEXT column: a JSON array of enum names.
  ///
  /// Emitted in [AccessGroup.values] order regardless of insertion order, so
  /// the stored text is stable and a save that changes nothing does not look
  /// like a change.
  String encodeGroups() => jsonEncode(
        AccessGroup.values.where(groups.contains).map((g) => g.name).toList(),
      );

  /// The `AppRole.allowed_pages` TEXT column for this role, or null.
  ///
  /// Delegates to the shared codec so the role and the user levels cannot
  /// serialise the same data two ways.
  String? encodeAllowedPages() => encodeAllowedPagesColumn(allowedPages);

  /// Read an `AppRole.groups` column back into a set.
  ///
  /// Forgiving on purpose. Unknown names are dropped, and malformed, empty or
  /// null input yields an empty set rather than throwing. A station running a
  /// newer build may have written an eighth group name into a shared database;
  /// an older station reading that row must lose the group it does not
  /// understand, not fail to start. The same reasoning covers a corrupt column:
  /// it costs the role its groups, never the app its boot.
  static Set<AccessGroup> decodeGroups(String json) {
    if (json.isEmpty) return <AccessGroup>{};
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return <AccessGroup>{};
    }
    if (decoded is! List) return <AccessGroup>{};
    return decoded
        .whereType<String>()
        .map(AccessGroup.byName)
        .whereType<AccessGroup>()
        .toSet();
  }

  static const SetEquality<AccessGroup> _groupEquality =
      SetEquality<AccessGroup>();

  /// Nullable-aware on purpose: null (no whitelist) and the empty set (block
  /// all) are different roles and must not compare equal, which a bare
  /// `SetEquality` over `{}` would get wrong if either side were defaulted.
  static const SetEquality<String> _pageEquality = SetEquality<String>();

  static bool _samePages(Set<String>? a, Set<String>? b) {
    if (a == null || b == null) return a == null && b == null;
    return _pageEquality.equals(a, b);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccessRole &&
          other.name == name &&
          other.seeded == seeded &&
          _groupEquality.equals(other.groups, groups) &&
          _samePages(other.allowedPages, allowedPages);

  @override
  int get hashCode => Object.hash(
        name,
        seeded,
        _groupEquality.hash(groups),
        allowedPages == null ? null : _pageEquality.hash(allowedPages!),
      );

  @override
  String toString() => 'AccessRole($name, ${encodeGroups()}, seeded: $seeded, '
      'pages: ${encodeAllowedPages() ?? 'all'})';
}

/// The four roles written by the schema-v6 seed migration.
///
/// After seeding these are **ordinary rows** — editable, renamable and
/// deletable like any other (a role the anonymous account holds is refused
/// deletion the way any held role is). They exist so a freshly commissioned
/// station has something sensible to assign, not as a fixed hierarchy.
///
/// `AppRole.name` is the primary key on purpose, so an OIDC group claim of
/// `"Shift Leader"` will one day match by name with no mapping table.
const List<AccessRole> kSeedRoles = [
  AccessRole(
    name: kOperatorRoleName,
    groups: {AccessGroup.operate},
    seeded: true,
  ),
  AccessRole(
    name: 'Shift Leader',
    groups: {AccessGroup.operate, AccessGroup.setpoints},
    seeded: true,
  ),
  // Maintenance **does** get setpoints (decided 2026-08-28): somebody who has
  // just swapped a motor needs to set it running properly, and sending them to
  // find a shift leader to type a number is how workarounds get invented. The
  // decision cost one tick in a table rather than a schema change, which is the
  // point of the group model.
  AccessRole(
    name: 'Maintenance',
    groups: {
      AccessGroup.operate,
      AccessGroup.setpoints,
      AccessGroup.device,
      AccessGroup.force,
    },
    seeded: true,
  ),
  AccessRole(
    name: 'Engineering',
    groups: {
      AccessGroup.operate,
      AccessGroup.setpoints,
      AccessGroup.device,
      AccessGroup.force,
      AccessGroup.configure,
      AccessGroup.administer,
      AccessGroup.users,
    },
    seeded: true,
  ),
];
