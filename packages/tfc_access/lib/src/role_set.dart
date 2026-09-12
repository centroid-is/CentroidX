/// The roles one account holds, and how several of them compose into one
/// answer.
///
/// Until schema v9 an account held exactly one role, and "what may this person
/// do" was a field lookup. It now holds one **or more**, and every question the
/// rest of the system asks — which groups, which pages, what to show in the app
/// bar, what to write in the audit row — is answered by composing the set. This
/// file is the only place that composition is written down, for the reason
/// `effectiveAllowedPages` gives about itself: a second copy is how the menu
/// and the route gate start disagreeing about what one person may see.
///
/// Three rules, and each one is a decision rather than the obvious reading:
///
/// * **Groups union.** Holding Maintenance and Shift Leader grants everything
///   either grants. An intersection would make a second role *narrowing*,
///   which is not what anybody means by "also give them Maintenance".
/// * **Page whitelists union, and a role with no whitelist wins.** A role whose
///   `allowedPages` is null sees every page, so a set containing one sees every
///   page. That is the only coherent union — see [unionRoleAllowedPages], which
///   also records why it is less alarming than it first looks.
/// * **Order is identity, not precedence.** The first name is the account's
///   primary role: the one `app_user.role_name` stores, the one a station that
///   never adds a second keeps, and the one a display falls back to. It grants
///   nothing the others do not; nothing here reads the list positionally except
///   [roleLabelFor].
library;

import 'dart:convert';

import 'access_group.dart';
import 'access_role.dart';

/// Separator between role names in [roleLabelFor].
///
/// A plus rather than a comma: an app-bar badge reading `Maintenance +
/// Engineering` reads as one person holding two roles, while
/// `Maintenance, Engineering` reads as a list of two people — which is exactly
/// the wrong impression in a trail row whose neighbouring column is a username.
const String kRoleLabelSeparator = ' + ';

/// The `app_user.additional_roles` TEXT column: a JSON array of role names, or
/// null when the account holds only its primary role.
///
/// Null for an empty list rather than an empty JSON array. The column is
/// nullable and every account carried over from schema v8 holds exactly one
/// role, so "no extra roles" must be the same stored value as "never touched" —
/// otherwise the upgrade would rewrite every row to say something it does not
/// mean.
///
/// Order is preserved rather than sorted, unlike `encodeAllowedPagesColumn`.
/// The order is what the accounts screen was told and what it shows back; a
/// sort here would silently reorder somebody's list under them between a save
/// and a reload.
String? encodeAdditionalRoles(Iterable<String> names) {
  final list = names.toList(growable: false);
  if (list.isEmpty) return null;
  return jsonEncode(list);
}

/// Read an `additional_roles` column back.
///
/// **Forgiving and narrowing**, deliberately the same ruling as
/// [AccessRole.decodeGroups] and deliberately the opposite of
/// `decodeAllowedPagesColumn`. Garbage, a non-list, a null column — anything
/// unreadable — answers the empty list, which costs the account its *extra*
/// roles and nothing else. It keeps its primary role, the column with the
/// foreign key on it, so an unreadable value here narrows what somebody may do
/// and can never widen it. Failing closed is therefore already what this does;
/// there is no safer direction to fail in.
///
/// Non-string entries are dropped for the same reason, and blanks with them: a
/// role name is a primary key in `app_role`, and the empty string is not one.
///
/// Never throws. A corrupt column costs an account a role, never the app its
/// boot.
List<String> decodeAdditionalRoles(String? json) {
  if (json == null || json.isEmpty) return const <String>[];
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const <String>[];
  }
  if (decoded is! List) return const <String>[];
  return decoded
      .whereType<String>()
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// The account's whole role list: [primary] first, then [additional], with
/// blanks and duplicates removed.
///
/// The primary can never be dropped and never moves off the front, so a caller
/// handing in an [additional] that contains the primary — which the accounts
/// screen can, since it edits one list — gets the primary once, at the front,
/// rather than twice.
///
/// Order-preserving beyond that: see the library doc on why the order is
/// identity rather than precedence, and why it must not be sorted.
List<String> normaliseRoleNames({
  required String primary,
  Iterable<String> additional = const <String>[],
}) {
  final seen = <String>{};
  final out = <String>[];
  for (final name in [primary, ...additional]) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    if (!seen.add(trimmed)) continue;
    out.add(trimmed);
  }
  return List.unmodifiable(out);
}

/// Everything [roles] together grant.
///
/// A plain union. Holding two roles grants what either grants, which is what
/// somebody ticking a second role means every time, and it is what makes a role
/// a *bundle of capabilities* rather than a rung on a ladder — the whole reason
/// [AccessGroup] exists separately from [AccessRole].
Set<AccessGroup> unionRoleGroups(Iterable<AccessRole> roles) => <AccessGroup>{
      for (final role in roles) ...role.groups,
    };

/// The pages [roles] together admit, or null when they admit every page.
///
/// **Null dominates.** A role with no whitelist sees every page by definition,
/// so an account holding one sees every page however narrow its other roles
/// are. There is no other reading of a union that is internally consistent: the
/// alternative — letting a narrow role bind a role that was never restricted —
/// is `effectiveAllowedPages`'s rejected intersection wearing a different hat,
/// and it makes adding a role *remove* pages.
///
/// This is less alarming than it first looks, and the reason is
/// [kOperatorRoleName]. Anonymous **is** the Operator role, so whatever the
/// Operator row admits is already on screen at every unattended panel on the
/// floor. Unioning it into somebody's set reveals nothing that walking up to a
/// logged-out panel would not. A site that whitelists at all whitelists
/// Operator first, and once it has, the union binds.
///
/// Answers null for an empty [roles] too — an account resolving to no role at
/// all is refused a session upstream, and a whitelist is not the layer that
/// should be inventing a denial for it.
///
/// Composes only the *role* level. The account's personal override still
/// replaces this wholesale, through `effectiveAllowedPages`, which is
/// unchanged: one account, one personal opinion, however many roles it holds.
Set<String>? unionRoleAllowedPages(Iterable<AccessRole> roles) {
  final union = <String>{};
  var any = false;
  for (final role in roles) {
    final pages = role.allowedPages;
    if (pages == null) return null;
    any = true;
    union.addAll(pages);
  }
  return any ? union : null;
}

/// What to show, and what to write in the audit row's `role` column, for an
/// account holding [roleNames].
///
/// One name for one role — so every single-role station's badges, trail rows
/// and goldens read exactly as they did before this existed — and
/// `A + B` for several, joined in the list's own order.
///
/// The audit column takes this rather than the primary role on purpose. A row
/// saying `Operator` against a configure write, because the account's *second*
/// role was the Engineering one that allowed it, is a trail that misleads
/// precisely where a trail gets read. `audit_entry.role` is a denormalised TEXT
/// column with no foreign key and nothing queries it by equality, so widening
/// what it can say costs nothing and buys an honest answer.
String roleLabelFor(Iterable<String> roleNames) =>
    roleNames.join(kRoleLabelSeparator);
