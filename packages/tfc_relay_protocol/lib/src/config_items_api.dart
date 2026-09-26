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

/// The **one** kind set a caller may write, and the preference key its
/// grading is taken from.
///
/// Two entries and no more, and that is the whole reason this family has a
/// write member at all instead of a kind-generic one. Preferences are graded
/// per *key*: a generic member would have to grade a preference replace-set
/// at the strictest key in the plant — `server_config_envelope`, which takes
/// `administer` — and would lock a `configure` user out of saving
/// `alarm_man_config`. So `preference` is refused here by name and keeps its
/// own seven-mutator door, and these two sets get the keys the direct path
/// already checks them under.
///
/// The strings are `kConfigWriteKeys`' (`tfc_dart`), duplicated because this
/// package cannot import that one. `config_write_keys_test.dart` in `tfc_dart`
/// pins the two against each other — it can import both, and neither of them
/// can import it.
const Map<String, String> configWriteKeyByKindSet = <String, String>{
  'asset,page': 'page_editor_data',
  'key_mapping': 'key_mappings',
};

/// The preference key [kinds] is graded under, or null when no set matches.
///
/// Sorted and joined, so the caller's order cannot change the answer — and so
/// a set that merely *contains* `page` cannot borrow the page editor's
/// grading for a `key_mapping` smuggled in beside it.
String? configWriteKeyFor(Set<String> kinds) =>
    configWriteKeyByKindSet[(kinds.toList()..sort()).join(',')];

/// What a client asks the gateway to write.
///
/// ## Why the client sends revisions and not the rows it read
///
/// `ConfigStore.writeItems` diffs [wanted] against **the caller's own read**,
/// never against the store's live snapshot — a row that arrived in between is
/// then in neither list and is left alone, rather than being deleted by a
/// diff that never saw it. Over a socket that read is the client's, from an
/// earlier `configItems.items`, and the obvious shape would be to send it
/// back whole.
///
/// It is not sent whole. The plant's key mappings are 518 KiB and the frame
/// ceiling is 1 MiB, so echoing the read alongside the write would put a save
/// over the edge for the one kind that most needs it. [baseRevisions] carries
/// the same information in one integer per row: the gateway re-reads the rows
/// itself and **refuses unless every revision matches what the client saw**,
/// at which point its read and the client's are the same list and the diff is
/// computed against the right one.
///
/// A row the client did not know about, or one that has moved, is a
/// `ConfigConflict` — which is the honest answer for "another panel edited
/// this first", and the same answer the direct path gives.
final class ConfigItemsReplaceRequest {
  const ConfigItemsReplaceRequest({
    required this.kinds,
    required this.wanted,
    required this.baseRevisions,
    this.reason,
  });

  /// The kinds being replaced. Must be a key of [configWriteKeyByKindSet].
  final Set<String> kinds;

  /// The complete configuration of [kinds], as it should stand afterwards.
  final List<ConfigItemRecord> wanted;

  /// `"<kind>/<id>" -> rev`, for every row of [kinds] the client read.
  final Map<String, int> baseRevisions;

  /// Free text for the change row; never a permission and never an identity.
  final String? reason;

  /// The key a row is listed under in [baseRevisions].
  static String revisionKey(String kind, String id) => '$kind/$id';

  Map<String, Object?> toJson() => {
        'kinds': kinds.toList()..sort(),
        'wanted': [for (final item in wanted) item.toJson()],
        'baseRevisions': baseRevisions,
        if (reason != null) 'reason': reason,
      };

  factory ConfigItemsReplaceRequest.fromJson(Map<String, Object?> json) =>
      ConfigItemsReplaceRequest(
        kinds: {for (final k in (json['kinds'] as List? ?? const [])) k as String},
        wanted: [
          for (final row in (json['wanted'] as List? ?? const []))
            ConfigItemRecord.fromJson((row as Map).cast<String, Object?>()),
        ],
        baseRevisions: {
          for (final entry
              in ((json['baseRevisions'] as Map?) ?? const <String, Object?>{})
                  .entries)
            entry.key as String: (entry.value as num).toInt(),
        },
        reason: json['reason'] as String?,
      );

  @override
  String toString() => 'ConfigItemsReplaceRequest(${(kinds.toList()..sort())
      .join(', ')}: ${wanted.length} row(s), ${baseRevisions.length} base rev(s))';
}

/// What one accepted write moved.
final class ConfigItemsReplaceResult {
  const ConfigItemsReplaceResult({
    required this.added,
    required this.changed,
    required this.removed,
    required this.actionId,
  });

  final int added;
  final int changed;
  final int removed;

  /// The action the `config_change` rows and the `audit_entry` row share, so
  /// a client can ask the history what its own save actually moved.
  final String actionId;

  bool get isEmpty => added == 0 && changed == 0 && removed == 0;

  Map<String, Object?> toJson() => {
        'added': added,
        'changed': changed,
        'removed': removed,
        'actionId': actionId,
      };

  factory ConfigItemsReplaceResult.fromJson(Map<String, Object?> json) =>
      ConfigItemsReplaceResult(
        added: (json['added'] as num?)?.toInt() ?? 0,
        changed: (json['changed'] as num?)?.toInt() ?? 0,
        removed: (json['removed'] as num?)?.toInt() ?? 0,
        actionId: json['actionId'] as String? ?? '',
      );

  @override
  String toString() =>
      'ConfigItemsReplaceResult(+$added ~$changed -$removed, action: $actionId)';
}

/// The plant's shared configuration rows: three reads and one write.
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

  /// Replaces the plant's shared rows of `request.kinds`.
  ///
  /// `replace`, not `write`: the contract kit's fakes implement every access
  /// family on one object and `BackendConfigApi.write` already owns that name
  /// there — the same collision that named [items]. It is also the more
  /// honest verb, because this member is a whole-set replace and never an
  /// append.
  ///
  /// The counterpart of the preferences door, for the two kind sets a panel
  /// edits as a whole: a page save (`{page, asset}`) and a key-mapping save
  /// (`{key_mapping}`). `preference` is refused by name — see
  /// [configWriteKeyByKindSet] for why it cannot share this member.
  ///
  /// Replace **within kinds**: a stored row of a kind in `request.kinds` that
  /// is absent from `request.wanted` is a removal. A row of any other kind is
  /// not in the comparison at all, which is what lets a page save be a whole
  /// pages replace without also deleting every key mapping on the plant.
  Future<ConfigItemsReplaceResult> replace(ConfigItemsReplaceRequest request);
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
