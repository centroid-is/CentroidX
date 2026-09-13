/// Content-addressed storage for page-editor images.
///
/// Image bytes never live inside the page JSON: the editor re-encodes the
/// whole page tree on every edit, so a multi-megabyte base64 blob inline in an
/// asset would be re-serialized on every drag. Instead each image is stored
/// once, base64-encoded, as a `config_item` row of its own kind
/// ([ConfigKind.pageImage]), and the asset carries only the row's id.
///
/// The id is a prefix of the SHA-256 of the bytes, so storing the same image
/// twice (paste, copy/paste of the asset, re-pick of the same file) dedupes to
/// a single blob, and a given image always gets the same id — which also keeps
/// tests and goldens deterministic.
///
/// ## Where an image's history went
///
/// [ConfigKind.pageImage] is history-exempt (`config_history_policy.dart`): a
/// put and a garbage collection write `config_item` rows and **no**
/// `config_change` rows at all. Nothing an engineer reads is lost by that. The
/// id *is* the sha256 of the bytes, so "the history of one image" is not a
/// question anybody can ask — an edit is a different id. What still records
/// the change is the **asset's** own change rows, which say which image id a
/// mimic referenced at each revision, when it was swapped and by whom. Only
/// the bytes of blobs that have since been collected are unrecoverable, and
/// that is the decision 04-01 took rather than pay C-3: up to about 6.7 MB of
/// base64 written twice, per image, into a table that is never pruned.
///
/// Because the exempt kind is invisible to the change-log notification the
/// other stations run on, [ConfigStore] sends its own reconcile nudge for a
/// commit that touched one — so an image still reaches the other panels in
/// seconds rather than at the next five-minute sweep.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';

/// The raster/vector formats the image asset accepts.
enum PageImageFormat { png, jpeg, bmp, svg }

/// Identifies [bytes] by magic numbers (or leading XML for SVG); null when the
/// bytes are none of the supported formats.
PageImageFormat? sniffImageFormat(Uint8List bytes) {
  if (bytes.length < 4) return null;
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E) {
    return PageImageFormat.png;
  }
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return PageImageFormat.jpeg;
  }
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return PageImageFormat.bmp;
  }
  // SVG is XML text: skip BOM and whitespace, accept `<?xml`, `<!--`/DOCTYPE
  // preambles or a direct `<svg` root.
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  String head;
  try {
    head = utf8.decode(bytes.sublist(start, bytes.length.clamp(0, start + 512)),
        allowMalformed: false);
  } on FormatException {
    return null;
  }
  final trimmed = head.trimLeft();
  if (trimmed.startsWith('<svg') ||
      ((trimmed.startsWith('<?xml') ||
              trimmed.startsWith('<!--') ||
              trimmed.startsWith('<!DOCTYPE')) &&
          head.contains('<svg'))) {
    return PageImageFormat.svg;
  }
  return null;
}

/// Thrown by [PageImageStore.save] for images over [PageImageStore.maxBytes].
class PageImageTooLargeException implements Exception {
  final int size;
  PageImageTooLargeException(this.size);

  @override
  String toString() =>
      'Image is ${(size / (1024 * 1024)).toStringAsFixed(1)} MB; the page '
      'editor stores at most '
      '${PageImageStore.maxBytes ~/ (1024 * 1024)} MB per image.';
}

class PageImageStore {
  /// The one payload field: the bytes, base64-encoded.
  ///
  /// A **map** and not a bare string because `ConfigItem.decode()` casts its
  /// payload to `Map<String, dynamic>` — a scalar payload is a row every
  /// generic path over `config_item` (the history view, the consistency
  /// checker, a restore) would fail to read.
  static const String payloadField = 'b64';

  /// Every image is one shared row in a table the whole plant replicates, so
  /// a hard cap keeps a stray screenshot from ballooning it.
  static const int maxBytes = 5 * 1024 * 1024;

  /// The guarded store. Writes go through it — an image upload is a
  /// `configure` action and belongs in the trail like any other — and reads
  /// come off the snapshot behind it, so a mimic drawing an image touches no
  /// database.
  final GuardedConfigStore store;

  PageImageStore(this.store);

  /// Ids whose bytes appeared, changed or were collected, from this station
  /// or any other.
  ///
  /// The exempt kind reaches this station through the reconcile nudge rather
  /// than through the change log, but it arrives on the same snapshot swap and
  /// therefore on the same feed. `pageImageBytesProvider` listens so that an
  /// asset which lands before its image does not keep showing the hole.
  Stream<String> get imageChanges =>
      store.inner.keyMappingChanges.expand((diff) => [
            for (final item in [
              ...diff.added,
              ...diff.changed,
              ...diff.removed,
            ])
              if (item.kind == ConfigKind.pageImage) item.id,
          ]);

  /// Every stored image, keyed by id.
  Map<String, ConfigItem> _rows() => {
        for (final item in store.inner.itemsOf(const {ConfigKind.pageImage}))
          item.id: item,
      };

  /// Stores [bytes] and returns the content-derived image id. Idempotent for
  /// identical bytes.
  ///
  /// The cap is enforced **before** the encode, so an oversized image costs
  /// neither the base64 nor the round trip to Postgres (T-04-09a).
  Future<String> save(Uint8List bytes) async {
    if (bytes.length > maxBytes) {
      throw PageImageTooLargeException(bytes.length);
    }
    final id = await imageIdFor(bytes);
    final stored = _rows();
    final item = ConfigItem.of(
      kind: ConfigKind.pageImage,
      id: id,
      value: {payloadField: base64Encode(bytes)},
    );
    final existing = stored[id];
    // Content addressing means the usual case is a re-put of bytes already
    // stored. Returning here rather than letting the store's empty diff catch
    // it matters: a shared write is refused when Postgres is unreachable
    // *before* it is diffed, so a station that pastes a picture it already
    // holds would otherwise be told its save failed.
    if (existing != null && samePayload(existing.payload, item.payload)) {
      return id;
    }
    // The full set with this one added, because `writeItems` replaces within
    // the kind: passing the one row would delete every other image in the
    // plant.
    await store.save(
      [
        for (final entry in stored.entries)
          if (entry.key != id) entry.value,
        item,
      ],
      kind: ConfigKind.pageImage,
    );
    return id;
  }

  /// The bytes stored under [id], or null when no such image exists (e.g. it
  /// was garbage-collected while an undo snapshot still referenced it) or the
  /// row holds something this build cannot decode.
  Future<Uint8List?> load(String id) async {
    final item = _rows()[id];
    if (item == null) return null;
    final Object? encoded;
    try {
      encoded = item.decode()[payloadField];
    } on Object {
      // A payload that is not a JSON object at all. One unreadable image must
      // cost that image and never the page it is on.
      return null;
    }
    if (encoded is! String || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } on FormatException {
      return null;
    }
  }

  /// Ids of every stored image.
  Future<Set<String>> storedIds() async => _rows().keys.toSet();

  /// Deletes every stored image whose id is not in [referenced]; returns how
  /// many were removed. The caller decides what counts as referenced — the
  /// editor includes its undo history and copy buffer, not just saved pages.
  ///
  /// One guarded save of the wanted set, which is the referenced rows and
  /// nothing else: replace-within-kind does the deleting. The set is built
  /// from what is *kept* rather than from what is dropped, so an id the caller
  /// named survives even if this store has never heard of it (T-04-09c).
  ///
  /// [keepNewerThan], when given, also keeps every row written after that
  /// moment whether or not anything references it: an image is stored when it
  /// is picked and referenced when its page is saved, on whichever station
  /// picked it, and a collector on another station running in that window
  /// would otherwise take it.
  Future<int> removeUnreferenced(Set<String> referenced,
      {DateTime? keepNewerThan}) async {
    final stored = _rows();
    bool recent(ConfigItem item) {
      final at = item.updatedAt;
      return keepNewerThan != null && at != null && at.isAfter(keepNewerThan);
    }

    final keep = [
      for (final entry in stored.entries)
        if (referenced.contains(entry.key) || recent(entry.value)) entry.value,
    ];
    final removed = stored.length - keep.length;
    // Nothing to collect is not a write. Said here and not left to the
    // store's empty diff for the reason [save] gives: the offline refusal
    // comes first, and a cleanup that reports failure on every save of a
    // station with no Postgres is worse than one that quietly finds nothing.
    if (removed == 0) return 0;
    await store.save(keep, kind: ConfigKind.pageImage);
    return removed;
  }

  /// The content-derived id [save] would assign to [bytes].
  static Future<String> imageIdFor(Uint8List bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .take(12)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Every image id referenced anywhere in [jsonTree] (decoded page/asset
  /// JSON). Keys off the `image_id` field rather than the asset type, so it
  /// also finds references inside undo snapshots and copied-asset JSON.
  static Set<String> referencedImageIds(Object? jsonTree) {
    final ids = <String>{};
    void crawl(Object? node) {
      if (node is Map) {
        final id = node['image_id'];
        if (id is String && id.isNotEmpty) ids.add(id);
        node.values.forEach(crawl);
      } else if (node is List) {
        node.forEach(crawl);
      }
    }

    crawl(jsonTree);
    return ids;
  }
}
