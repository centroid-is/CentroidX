/// The one row shape every piece of configuration takes.
///
/// See `docs/relational-config-research.md` §3 for the argument. In short:
/// there are five configuration storage strategies in the tree today
/// (`flutter_preferences` JSON blobs, a `shared_preferences` file, a handful
/// of bespoke relational tables, the OS keychain, and `ReportStore`), of which
/// only one can say who changed something and when. This is the shape that
/// replaces the first three.
///
/// ## Why the payload stays JSON
///
/// The point of the work is write granularity, a readable audit trail and
/// rollback — not queryability. The app materialises the whole configuration
/// at boot and holds it, and every filter the code performs
/// (`KeyMappings.filterByServer`, the history view's collected-key scan) runs
/// against that in-memory snapshot rather than against the database. So no
/// query ever filters config in SQL, which is what makes one generic table
/// viable rather than a compromise: there is nothing to index per kind.
///
/// Decomposing further would mean a column per type across ~60 hand-written
/// `@JsonSerializable` config classes, or EAV — and composites nest their
/// children *inside their own JSON* as typed fields
/// (`BeckhoffCX5010Config.subdevices`) rather than as a generic tree. All of
/// the value is at the granularity of one row per entity; none of it is at one
/// column per field.
///
/// ## Why `scope`
///
/// Device-local preferences exist as an entire parallel store today
/// (`localPreferencesProvider`, `shared_preferences`) for one reason: some
/// settings must not sync between stations. The per-station startup page, the
/// access session, and above all `DatabaseConfig` — which holds a *different*
/// Postgres endpoint on each machine and must never be shared.
///
/// As a column instead, one table serves both: [ConfigScope.shared] rows are
/// owned by Postgres and mirrored into local SQLite, [ConfigScope.station]
/// rows are owned by local SQLite and never leave the machine. The ownership
/// rule is driven by data rather than by which object a caller happened to be
/// handed — and station rows stay readable when Postgres is not, which they
/// must be, because the row saying how to reach Postgres is one of them.
///
/// ## Why `rev`
///
/// Several SVN stations share one Postgres. The blob made every save a
/// last-writer-wins race over the entire configuration; rows reduce that to a
/// race over one entity, and [rev] is what lets a caller detect even that one
/// rather than discovering it later. A monotonic counter and not a timestamp:
/// two stations whose clocks disagree still order correctly against the row
/// they both read.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Canonical JSON encoding for a config payload.
///
/// Every payload written to a row and every payload compared against one goes
/// through here, so "the same configuration" is always the same bytes. Without
/// it, two encodings of one unchanged entity differ by map order alone, and
/// every save would write — and audit — every row.
///
/// Keys are sorted at every level. Lists keep their order: an asset list is
/// paint order and a cable's waypoint list is the shape of the run, so sorting
/// one would change what it means.
///
/// **[value] is encoded and decoded once before being sorted**, and that step
/// is not a nicety. A `toJson()` in this codebase does not necessarily hand
/// back plain maps: `@JsonSerializable()` without `explicitToJson: true`
/// generates `'menu_item': instance.menuItem`, so `AssetPage.toJson()` returns
/// a live `MenuItem` and `jsonEncode` converts it at the very end — *after*
/// any sort, in whatever order that object's own `toJson()` emits. Sorting the
/// tree first and encoding second therefore leaves such a sub-object
/// unsorted, and the payload it lands in is stable only by luck. Normalising
/// through JSON first flattens every one of them to a map before the sort can
/// miss it.
String canonicalJson(Object? value) =>
    jsonEncode(canonicalise(jsonDecode(jsonEncode(value))));

/// [value] with every map key sorted, recursively.
///
/// Expects plain decoded JSON — see [canonicalJson] for why that matters.
/// Exposed for callers that need to compare structures rather than encode
/// them, which is the shape a test comparing two payloads wants.
Object? canonicalise(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: canonicalise(value[k])};
  }
  if (value is List) {
    return value.map(canonicalise).toList();
  }
  return value;
}

/// Whether two config payloads describe the same configuration.
///
/// Compares decoded structure, not text: a value that round-trips through a
/// different map order is not a change, and treating it as one would fill the
/// change log with saves in which nothing happened. [canonicalJson] makes that
/// rare on the way in; comparing structurally anyway means a payload written
/// before the canonical encoding existed does not read as an edit on sight.
bool samePayload(String? a, String? b) {
  if (a == null || b == null) return a == b;
  if (identical(a, b) || a == b) return true;
  try {
    return const DeepCollectionEquality().equals(jsonDecode(a), jsonDecode(b));
  } on FormatException {
    return false;
  }
}

/// What kind of thing a row describes.
///
/// The wire values are stored in `config_item.kind` and `config_change.kind`
/// and are therefore permanent: a change row must still be readable years
/// after the code that wrote it. Add values; never rename one.
enum ConfigKind {
  /// One navigable page. Id is a minted handle, not the page's path — the
  /// path is edited, and a path-named row would lose the page's history and
  /// restamp every asset on it at every rename. The path lives in the
  /// payload's `menu_item`.
  page('page'),

  /// One top-level asset on a page. Id is [Asset.id]; parent is the page's
  /// id.
  asset('asset'),

  /// One entry of `KeyMappings.nodes`. Id is the subscription key.
  keyMapping('key_mapping'),

  /// One scalar preference — what `flutter_preferences` holds today for
  /// everything that is not one of the two big blobs.
  preference('preference'),

  /// One image a page displays, content-addressed: the id is the sha256
  /// prefix of the bytes, so the bytes never change under an id and an "edit"
  /// is a different row.
  ///
  /// The one kind that writes no `config_change` rows at all — see
  /// `config_history_policy.dart` for why, and for the notification that
  /// keeps it propagating between stations anyway.
  pageImage('page_image');

  const ConfigKind(this.wireName);

  /// The string stored in the database.
  final String wireName;

  /// The kind [wireName] names, or null if nothing does.
  ///
  /// Nullable rather than throwing: a row written by a newer station against
  /// the shared database must be skippable by an older one, not fatal to the
  /// whole read.
  static ConfigKind? byWireName(String wireName) =>
      values.firstWhereOrNull((k) => k.wireName == wireName);
}

/// Who owns a row, and whether it is allowed to leave the machine.
///
/// [station] carries the hostname in its wire form (`station:svn-nes-ot-cl02`)
/// so several stations' rows coexist in one local database — which is what
/// makes a local store restorable from a backup taken on another machine
/// without silently adopting its identity.
@immutable
class ConfigScope {
  const ConfigScope._(this.wireName, this.station);

  /// Owned by Postgres, mirrored into local SQLite, the same on every station.
  static const ConfigScope shared = ConfigScope._('shared', null);

  /// Owned by this machine's SQLite, never written to Postgres.
  factory ConfigScope.forStation(String hostname) =>
      ConfigScope._('station:$hostname', hostname);

  /// The scope [wireName] names, or null if it is malformed.
  static ConfigScope? byWireName(String wireName) {
    if (wireName == shared.wireName) return shared;
    const prefix = 'station:';
    if (wireName.startsWith(prefix) && wireName.length > prefix.length) {
      return ConfigScope._(wireName, wireName.substring(prefix.length));
    }
    return null;
  }

  /// The string stored in the database.
  final String wireName;

  /// The hostname, for a station scope; null for [shared].
  final String? station;

  /// Whether Postgres owns rows in this scope. False means local-only, and a
  /// row that is local-only must never be included in a push to Postgres.
  bool get isShared => station == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigScope && other.wireName == wireName;

  @override
  int get hashCode => wireName.hashCode;

  @override
  String toString() => wireName;
}

/// One row of configuration.
@immutable
class ConfigItem {
  const ConfigItem({
    required this.kind,
    required this.id,
    required this.payload,
    this.scope = ConfigScope.shared,
    this.parentId,
    this.sortIndex,
    this.rev = 0,
    this.updatedAt,
    this.updatedBy,
  });

  /// An item whose payload is [value], canonically encoded.
  factory ConfigItem.of({
    required ConfigKind kind,
    required String id,
    required Object? value,
    ConfigScope scope = ConfigScope.shared,
    String? parentId,
    int? sortIndex,
  }) =>
      ConfigItem(
        kind: kind,
        id: id,
        payload: canonicalJson(value),
        scope: scope,
        parentId: parentId,
        sortIndex: sortIndex,
      );

  /// What this row describes.
  final ConfigKind kind;

  /// The entity's identity within its [kind]: an `AssetPage.id`, an
  /// `Asset.id`, a mapping key, a preference key.
  final String id;

  /// Who owns the row.
  final ConfigScope scope;

  /// The entity this one belongs to — an asset's page id — or null when the
  /// kind has no parent.
  ///
  /// Deliberately not a foreign key. Assets outlive the page they were on
  /// during a move, and a constraint would turn a reorder into a delete and
  /// re-insert, which the change log would then report as the asset having
  /// been destroyed and recreated.
  final String? parentId;

  /// Position among siblings, for kinds where order is meaning.
  ///
  /// Assets need it: a page's asset list is paint order, so losing it changes
  /// what is drawn on top. Null for kinds that are a set rather than a list.
  final int? sortIndex;

  /// The entity's own JSON, canonically encoded — exactly what its existing
  /// `toJson()` produces, with keys sorted.
  final String payload;

  /// Monotonic write counter. Zero for an item that has not been stored yet.
  final int rev;

  /// When the row was last written. Null for an item not yet stored.
  final DateTime? updatedAt;

  /// Username of whoever last wrote it, or `'anonymous'`. Null for an item not
  /// yet stored.
  final String? updatedBy;

  /// The decoded payload.
  Map<String, dynamic> decode() => jsonDecode(payload) as Map<String, dynamic>;

  /// The **complete entity**, position included — what a change row stores and
  /// what a restore writes back.
  ///
  /// [payload] alone is not the entity. Moving an asset to another page or
  /// changing its paint order alters [parentId] or [sortIndex] and nothing
  /// else, so a history that recorded payloads only would write a row whose
  /// two sides are *identical* and whose restore puts the asset back on the
  /// wrong page in the wrong order. That defeats the argument the whole
  /// history design rests on — "a restore is writing `old_value`, with nothing
  /// to reconstruct".
  ///
  /// Position is folded in **here** rather than into [payload] because
  /// [payload] has to stay exactly what the entity's own `toJson()` produces:
  /// it is what the codecs round-trip and what the compatibility view hands
  /// back to `tfc_mcp_server` and the `tools/svn_*.py` scripts. Synthetic
  /// fields inside it would leak into all of that.
  ///
  /// [kind], [id] and [scope] are the primary key and are columns on the
  /// change row already, so they are not repeated.
  Map<String, dynamic> toEntityJson() => {
        'parent_id': parentId,
        'sort_index': sortIndex,
        'payload': jsonDecode(payload),
      };

  /// The entity, canonically encoded. This is the string a change row holds.
  String encodeEntity() => canonicalJson(toEntityJson());

  /// The item [entity] describes, under the given primary key.
  ///
  /// The inverse of [toEntityJson], and the one way a restore turns a stored
  /// change row back into something writable.
  static ConfigItem fromEntityJson(
    Map<String, dynamic> entity, {
    required ConfigKind kind,
    required String id,
    required ConfigScope scope,
  }) =>
      ConfigItem(
        kind: kind,
        id: id,
        scope: scope,
        parentId: entity['parent_id'] as String?,
        sortIndex: entity['sort_index'] as int?,
        payload: canonicalJson(entity['payload']),
      );

  /// A copy with the storage-managed fields replaced. Used when a read hands
  /// back what the database recorded for an item built in memory.
  ConfigItem stored({
    required int rev,
    required DateTime updatedAt,
    required String updatedBy,
  }) =>
      ConfigItem(
        kind: kind,
        id: id,
        payload: payload,
        scope: scope,
        parentId: parentId,
        sortIndex: sortIndex,
        rev: rev,
        updatedAt: updatedAt,
        updatedBy: updatedBy,
      );

  /// Whether [other] is the same entity — same primary key — regardless of
  /// what either holds.
  bool sameEntityAs(ConfigItem other) =>
      other.kind == kind && other.id == id && other.scope == scope;

  /// Whether [other] holds the same configuration as this one.
  ///
  /// Compares the payload structurally and the two fields that are content
  /// rather than bookkeeping — [parentId] and [sortIndex] both change what the
  /// app renders. [rev], [updatedAt] and [updatedBy] are excluded on purpose:
  /// they describe the write, not the configuration, and including them would
  /// make every re-read look like a change.
  bool sameContentAs(ConfigItem other) =>
      other.parentId == parentId &&
      other.sortIndex == sortIndex &&
      samePayload(other.payload, payload);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConfigItem &&
          other.kind == kind &&
          other.id == id &&
          other.scope == scope &&
          other.parentId == parentId &&
          other.sortIndex == sortIndex &&
          other.payload == payload &&
          other.rev == rev &&
          other.updatedAt == updatedAt &&
          other.updatedBy == updatedBy;

  @override
  int get hashCode => Object.hash(
      kind, id, scope, parentId, sortIndex, payload, rev, updatedAt, updatedBy);

  @override
  String toString() => 'ConfigItem(${kind.wireName}:$id@$scope'
      '${parentId == null ? '' : ' under $parentId'}'
      '${sortIndex == null ? '' : ' #$sortIndex'}, rev $rev)';
}
