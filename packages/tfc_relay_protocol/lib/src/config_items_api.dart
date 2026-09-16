/// The plant's configuration rows — pages, assets, key mappings — served to a
/// client that holds no mirror of them.
///
/// ## Why a fifth access family
///
/// Main's relational-configuration work (#465) moved the plant's pages and its
/// key mappings out of the preference blobs and into `config_item` rows. A
/// station keeps a SQLite mirror of those rows and reads them locally; the
/// relay never carried them, because until the browser build nothing on the
/// far end of the pipe lacked a mirror. A browser does. Without this family
/// it boots on the built-in default page and subscribes to the alarm set
/// alone — an app shell over a plant it cannot see.
///
/// ## Reads only, and that is a boundary rather than a gap
///
/// [ConfigItemsApi] has no write. A page-editor save from a browser is refused
/// by name on the client (`lib/providers/page_manager.dart`), because a write
/// route needs the merge-and-reconcile discipline `ConfigStore` applies against
/// a mirror, the `configure` gate, and a `config_change` row attributed through
/// the relay's audit — a design of its own, not a method added here. Two
/// methods, both reads, is the whole surface.
///
/// ## One kind per call, and a fingerprint
///
/// [ConfigItemsApi.items] takes **one** kind. The plant this was measured on
/// holds 16 pages, 561 assets and 1375 key mappings — about 750 KB of payload
/// together, of which the largest family is ~400 KB — and the gateway's frame
/// ceiling is 1 MiB (`ServerConfig.maxFrameBytes`). A call that returned every
/// kind at once would ride close to the ceiling on a plant this size and over
/// it on a larger one, and an over-large answer is the one failure the send
/// buffer reports as a *disconnect* (`result_too_large.dart`). Bounding a call
/// to one family is what keeps the largest answer well inside one frame
/// without inventing paging: the client asks for four kinds in four calls.
///
/// [ConfigItemsApi.fingerprint] is how a client stays current without
/// re-reading 750 KB on every change: the rows' count and revision sum over
/// the kinds it holds, a few bytes, compared against what it last fetched.
///
/// ## Freshness rides the notification that already exists
///
/// There is no `configItems.changed` notification, on purpose. The backend's
/// `config_change` channel fires for every `config_item` row — page, asset,
/// key mapping and preference alike — and the gateway already conflates it
/// into `preferences.changed` (`data_handlers.dart`). A second notification
/// over the same trigger would be two messages per save that say one thing.
/// A client that holds these rows listens to `preferences.changed`, asks
/// [fingerprint], and fetches only when the fingerprint moved — a snapshot,
/// never a replay, and conflated by construction because the fingerprint
/// answers once however many keys the notification named.
///
/// ## Kinds are wire names
///
/// This package does not depend on `tfc_dart`, where `ConfigKind` lives, so
/// kinds travel as the strings that enum already persists in the `kind`
/// column ([configItemKinds]). The backend refuses a name it does not know.
library;

/// The kind names a client may ask for, spelled exactly as the `config_item`
/// table stores them (`ConfigKind.wireName`).
const Set<String> configItemKinds = <String>{
  'page',
  'asset',
  'key_mapping',
  'preference',
};

/// The plant's shared configuration rows, read-only.
abstract interface class ConfigItemsApi {
  /// Every shared row of one [kind], ordered by id.
  ///
  /// One kind per call — see the library doc for the size argument. Refused
  /// for a kind not in [configItemKinds].
  ///
  /// `items`, not `list`: the contract kit's fakes implement every access
  /// family on one object, and `AccessTemplateApi.list()` already owns that
  /// name there. The wire name follows the member (`configItems.items`),
  /// because every access name is `family.member` verbatim and the protocol
  /// test holds it to that.
  Future<List<ConfigItemRecord>> items(String kind);

  /// The count and revision sum of every shared row of [kinds] together.
  ///
  /// Cheap enough to ask on every change notification; equal fingerprints
  /// mean [items] would answer what it answered last time.
  Future<ConfigItemsFingerprint> fingerprint(List<String> kinds);
}

/// One `config_item` row as it crosses the wire.
///
/// The same fields `ConfigItem` carries minus the two that are a mirror's
/// business (`scope`, which is always shared here, and `updatedAt`/`updatedBy`,
/// which a read-only client has no use for). [payload] is the row's canonical
/// JSON text, verbatim, so a client reassembles exactly what the store wrote.
final class ConfigItemRecord {
  const ConfigItemRecord({
    required this.kind,
    required this.id,
    required this.payload,
    this.parentId,
    this.sortIndex,
    this.rev = 0,
  });

  final String kind;
  final String id;
  final String? parentId;
  final int? sortIndex;
  final String payload;
  final int rev;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'id': id,
        if (parentId != null) 'parentId': parentId,
        if (sortIndex != null) 'sortIndex': sortIndex,
        'payload': payload,
        'rev': rev,
      };

  factory ConfigItemRecord.fromJson(Map<String, Object?> json) =>
      ConfigItemRecord(
        kind: json['kind'] as String,
        id: json['id'] as String,
        parentId: json['parentId'] as String?,
        sortIndex: (json['sortIndex'] as num?)?.toInt(),
        payload: json['payload'] as String,
        rev: (json['rev'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is ConfigItemRecord &&
      other.kind == kind &&
      other.id == id &&
      other.parentId == parentId &&
      other.sortIndex == sortIndex &&
      other.payload == payload &&
      other.rev == rev;

  @override
  int get hashCode => Object.hash(kind, id, parentId, sortIndex, payload, rev);

  @override
  String toString() => 'ConfigItemRecord($kind:$id@$rev)';
}

/// What a set of rows adds up to: how many, and the sum of their revisions.
///
/// Two numbers rather than a hash of the payloads, because they are what the
/// backend can answer with one aggregate query and they move on every write
/// the store makes (a row's `rev` only ever grows; a deleted row changes the
/// count). Equal fingerprints over the same kinds mean the same rows.
final class ConfigItemsFingerprint {
  const ConfigItemsFingerprint({required this.count, required this.revSum});

  /// Nothing held at all — a client's state before its first fetch.
  static const ConfigItemsFingerprint none =
      ConfigItemsFingerprint(count: 0, revSum: 0);

  final int count;
  final int revSum;

  Map<String, Object?> toJson() => {'count': count, 'revSum': revSum};

  factory ConfigItemsFingerprint.fromJson(Map<String, Object?> json) =>
      ConfigItemsFingerprint(
        count: (json['count'] as num).toInt(),
        revSum: (json['revSum'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is ConfigItemsFingerprint &&
      other.count == count &&
      other.revSum == revSum;

  @override
  int get hashCode => Object.hash(count, revSum);

  @override
  String toString() => 'ConfigItemsFingerprint(count: $count, revSum: $revSum)';
}
