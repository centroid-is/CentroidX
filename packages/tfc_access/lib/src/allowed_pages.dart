/// The page-visibility whitelist codec, shared by [AccessRole] and the
/// `app_user` row, and the rule that composes the two.
///
/// See `docs/page-visibility-whitelist-design.md`. Three points from it are
/// load-bearing here and are restated because this file is where somebody
/// would edit them by accident:
///
/// * **Null and empty are different claims.** `null` is "no whitelist" — on a
///   role, sees every page; on a user, *inherit the role's*. The empty set is
///   a whitelist naming nothing: sees no pages. Collapsing the two would make
///   "block all" unexpressible, which is the state the feature was asked for
///   by name.
/// * **Decoding fails closed.** [decodeAllowedPages] answers `null` only for a
///   `null` column. Garbage, a non-list, a list of non-strings — anything
///   stored that cannot be read as a page list — answers the **empty set**,
///   which denies. This is the deliberate opposite of
///   `AccessRole.decodeGroups`, which is forgiving: an unreadable *group*
///   column costs a role a capability, which is safe, while an unreadable
///   *page* column that failed open would show pages the whitelist exists to
///   hide.
/// * **Entries are page paths, not section paths.** Sections are not routes;
///   see §6 of the design note.
library;

import 'dart:convert';

/// The `allowed_pages` TEXT column: a JSON array of page paths, sorted.
///
/// Sorted for the same reason `AccessRole.encodeGroups` emits enum order: the
/// stored text must be stable, so a save that changes nothing does not look
/// like a change in the trail's old-to-new columns.
///
/// Answers `null` for a `null` set — the column is nullable and "no whitelist"
/// is stored as SQL NULL rather than as a sentinel string.
String? encodeAllowedPagesColumn(Set<String>? pages) {
  if (pages == null) return null;
  final sorted = pages.toList()..sort();
  return jsonEncode(sorted);
}

/// Read an `allowed_pages` column back.
///
/// **Fails closed on anything unreadable.** A `null` column — and only a
/// `null` column — answers `null` ("no whitelist"). Every other unreadable
/// input answers the empty set, which denies every page. See the library doc
/// for why this is the opposite ruling to `AccessRole.decodeGroups`.
///
/// An empty string is treated as unreadable rather than as an empty list. It
/// is not a value this codec ever writes ([encodeAllowedPagesColumn] writes `'[]'`),
/// so encountering one means something other than this codec wrote the column.
///
/// Never throws: a corrupt column costs an audience its pages, never the app
/// its boot.
Set<String>? decodeAllowedPagesColumn(String? json) {
  if (json == null) return null;
  if (json.isEmpty) return <String>{};
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return <String>{};
  }
  if (decoded is! List) return <String>{};
  // Non-string entries are dropped rather than failing the whole column: the
  // same reasoning as an unknown group name, and dropping narrows.
  return decoded.whereType<String>().toSet();
}

/// The pages a session may see, composing the two levels.
///
/// **The user's whitelist replaces the role's when present.** Not a union and
/// not an intersection; §1c of the design note argues all three and records
/// what the rejected two break. In one line each: a union makes the role level
/// unable to bind, and an intersection cannot express granting one account one
/// extra page.
///
/// A `null` [user] means "no personal opinion" and defers to [role]. It never
/// means "sees everything" — that reading would mint a personal exemption for
/// every account carried over from schema v6, where the column does not exist
/// and every row upgrades to NULL.
///
/// Answers `null` when neither level has an opinion: unrestricted.
///
/// This function is the only place the composition is written down. A second
/// copy is how the menu and the route gate start disagreeing about what one
/// person may see.
Set<String>? effectiveAllowedPages({
  required Set<String>? user,
  required Set<String>? role,
}) =>
    user ?? role;
