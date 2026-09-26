/// The plant's configuration rows on a client that holds no mirror of them:
/// pages, assets and key mappings, served over the relay and cached in the
/// device-local store.
///
/// ## What a browser has instead of a mirror
///
/// A station in gateway mode reads pages and key mappings out of its SQLite
/// mirror of the plant's `config_item` rows. A browser has no SQLite, so until
/// this file existed it booted on the built-in default page and subscribed to
/// the alarm set alone. [RelayedConfigItems] is the browser's mirror: the rows
/// fetched over `configItems.items` (one kind per call — the protocol's library
/// doc says why), held in memory, and written to the device-local store so the
/// next boot starts from them before the link is up and before anybody has
/// signed in.
///
/// ## The three rules it keeps
///
/// **The client arrives late.** `stateManProvider` builds the relay client
/// *from* the key mappings, so the rows cannot be fetched before the client
/// exists — the same ring `RelayedPreferences` documents for `key_mappings`.
/// Boot therefore reads the cache, the client is built from that, and
/// [GatewayConfigItemsSlot] is filled once it exists, exactly as
/// `GatewayPreferencesSlot` is. The first fetch happens then; a fresh browser
/// with nothing cached boots on the built-in page and empty mappings and
/// catches up the moment it can read.
///
/// **Reads are refused until somebody signs in**, so the fill's fetch is
/// expected to fail on a fresh session and is logged once rather than
/// surfaced; the sign-in path calls [GatewayConfigItemsSlot.requestRefresh],
/// which is the first moment the read can succeed.
///
/// **Conflate, never queue; snapshot, never replay.** Every trigger — the
/// fill, a sign-in, a `preferences.changed` notification (which the backend
/// fires for every `config_item` row, kinds alike) — schedules *one* refresh.
/// A refresh asks the backend's fingerprint first and fetches only when it
/// moved, so a burst of notifications costs one small round trip. A trigger
/// that lands while a refresh is running marks it dirty and it runs once more
/// afterwards; nothing is queued and nothing is replayed.
///
/// ## It writes, now
///
/// It did not, and the boundary was real while the gateway could not author a
/// `config_item` row at all: a page-editor save on a client with no mirror
/// was refused by name. `configItems.replace` is the gateway's second write
/// door, and [RelayedConfigItems.replace] is this side of it — the caller's
/// own read carries the revisions the gateway compares and swaps against, so
/// a panel that saves against rows somebody else has moved is told, not
/// silently obeyed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart' as codec;
import 'package:tfc_dart/core/preferences_api.dart';
import 'package:tfc_dart/core/state_man_types.dart' show KeyMappings;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

import '../providers/preferences.dart' show localPreferencesProvider;
import 'device_local_preferences.dart' show kConfigItemsCachePrefsKey;

/// The kinds a client with no mirror needs: the pages and their assets, the
/// key mappings the client is built from, and the preference rows the page
/// manager reads its top-level order out of.
const Set<ConfigKind> kRelayedConfigKinds = {
  ConfigKind.page,
  ConfigKind.asset,
  ConfigKind.keyMapping,
  ConfigKind.preference,
};

/// Where the relay client's row reader arrives once the client exists.
///
/// The same shape as `GatewayPreferencesSlot`, for the same reason: the
/// reader lives on a client that `stateManProvider` builds *after* reading the
/// rows the reader would answer, so it has to be handed over afterwards.
final class GatewayConfigItemsSlot {
  rp.ConfigItemsApi? _api;
  StreamSubscription<String>? _upstream;
  final StreamController<void> _triggers = StreamController<void>.broadcast();

  /// The reader, or null while there is no client.
  rp.ConfigItemsApi? get api => _api;

  /// Fires on every fill, on every change notification the client relays,
  /// and on every [requestRefresh]. Each is one reason to refresh; the
  /// listener conflates.
  Stream<void> get triggers => _triggers.stream;

  /// Hands over the client's reader and the notification stream that says
  /// the rows may have moved (`preferences.changed`, which the backend fires
  /// for every `config_item` row).
  void fill(rp.ConfigItemsApi api, Stream<String> changes) {
    _api = api;
    _upstream?.cancel();
    _upstream = changes.listen((_) => _fire(), onError: (Object _) {});
    _fire();
  }

  /// A sign-in happened: the first moment a read can succeed.
  void requestRefresh() => _fire();

  /// The client went away; a rebuild will fill again.
  void clear() {
    _api = null;
    _upstream?.cancel();
    _upstream = null;
  }

  Future<void> dispose() async {
    clear();
    await _triggers.close();
  }

  void _fire() {
    if (!_triggers.isClosed) _triggers.add(null);
  }
}

/// The one [GatewayConfigItemsSlot] for this container.
final gatewayConfigItemsSlotProvider = Provider<GatewayConfigItemsSlot>((ref) {
  final slot = GatewayConfigItemsSlot();
  ref.onDispose(slot.dispose);
  return slot;
});

/// The rows, as this client currently holds them.
final class RelayedConfigItems {
  RelayedConfigItems({
    required PreferencesApi cache,
    required GatewayConfigItemsSlot slot,
    Set<ConfigKind> kinds = kRelayedConfigKinds,
    Logger? logger,
  })  : _cache = cache,
        _slot = slot,
        _kinds = kinds,
        _log = logger ?? Logger() {
    _trigger = slot.triggers.listen((_) => _schedule());
  }

  final PreferencesApi _cache;
  final GatewayConfigItemsSlot _slot;
  final Set<ConfigKind> _kinds;
  final Logger _log;

  List<ConfigItem> _items = const [];
  rp.ConfigItemsFingerprint _fingerprint = rp.ConfigItemsFingerprint.none;

  final StreamController<void> _changed = StreamController<void>.broadcast();
  StreamSubscription<void>? _trigger;
  Future<void>? _running;
  bool _dirty = false;
  bool _reportedRefusal = false;

  /// Fires after every refresh that replaced the rows.
  Stream<void> get changed => _changed.stream;

  /// The rows of [kinds], a fresh list every call.
  List<ConfigItem> itemsOf(Set<ConfigKind> kinds) =>
      [for (final item in _items) if (kinds.contains(item.kind)) item];

  /// Whether any row is held — from the cache or from a fetch.
  bool get isEmpty => _items.isEmpty;

  /// The key mappings, rebuilt from the rows on every call so a caller that
  /// mutates what it is handed cannot reach in here (`ConfigStore.keyMappings`
  /// keeps the same rule, for the same measured reason).
  KeyMappings get keyMappings =>
      codec.keyMappingsOf(itemsOf(const {ConfigKind.keyMapping}));

  /// The fingerprint of what is held, for a test or a status line.
  rp.ConfigItemsFingerprint get fingerprint => _fingerprint;

  /// Loads the cached rows, if any. Called once, before the client exists.
  Future<void> restore() async {
    final raw = await _cache.getString(kConfigItemsCachePrefsKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      _items = [
        for (final entry in decoded['items'] as List)
          _itemOf(rp.ConfigItemRecord.fromJson(
              (entry as Map).cast<String, Object?>())),
      ];
      _fingerprint = rp.ConfigItemsFingerprint.fromJson(
          (decoded['fingerprint'] as Map).cast<String, Object?>());
    } catch (e) {
      // A cache this build cannot read costs the cache, never the boot: the
      // rows are fetched again the moment the link can serve them.
      _log.w('The cached configuration rows could not be read; starting '
          'without them and fetching afresh: $e');
      _items = const [];
      _fingerprint = rp.ConfigItemsFingerprint.none;
    }
  }

  /// Replaces the plant's rows of [kinds] over the relay.
  ///
  /// The write half of this route, and the reason the library header's "it
  /// writes nothing to the plant" no longer holds: `configItems.replace` is
  /// the gateway's second write door, and a client with no mirror is exactly
  /// who it was built for.
  ///
  /// [derivedFrom] is the caller's own read — the rows [wanted] was built
  /// against — and its revisions become the compare-and-swap the gateway
  /// checks. It is **required and not defaulted to [_items]**: this object
  /// refreshes itself behind the caller, so a default would quietly re-base a
  /// save onto rows the operator never saw, which is the lost write the
  /// revisions exist to refuse. A screen that has no baseline has no business
  /// saving.
  ///
  /// Throws whatever the wire throws — a refusal, or the conflict another
  /// panel's edit produces. A refreshed copy is fetched afterwards so the
  /// screen that saved sees what actually landed, including the revisions its
  /// next save will need.
  Future<rp.ConfigItemsReplaceResult> replace({
    required Set<ConfigKind> kinds,
    required List<ConfigItem> wanted,
    required List<ConfigItem> derivedFrom,
    String? reason,
  }) async {
    final api = _slot.api;
    if (api == null) {
      throw StateError(
          "The plant's configuration cannot be written: this client has no "
          'link to the gateway yet. Nothing was saved.');
    }
    final result = await api.replace(rp.ConfigItemsReplaceRequest(
      kinds: {for (final kind in kinds) kind.wireName},
      wanted: [
        for (final item in wanted)
          rp.ConfigItemRecord(
            kind: item.kind.wireName,
            id: item.id,
            parentId: item.parentId,
            sortIndex: item.sortIndex,
            payload: item.payload,
            rev: item.rev,
          ),
      ],
      baseRevisions: {
        for (final item in derivedFrom)
          if (kinds.contains(item.kind))
            rp.ConfigItemsReplaceRequest.revisionKey(
                item.kind.wireName, item.id): item.rev,
      },
      reason: reason,
    ));
    // Not `_fire()`: that conflates, and a save has to be followed by a read
    // that definitely ran — the screen's next save needs the revisions this
    // one produced, and a conflated refresh could be the one already in
    // flight against the rows from before.
    _fingerprint = rp.ConfigItemsFingerprint.none;
    await refresh();
    return result;
  }

  /// Fetches the rows if the backend's fingerprint says they moved.
  ///
  /// Returns true when the rows were replaced. Never throws: a refusal — the
  /// expected answer before sign-in — is logged once and answered false.
  Future<bool> refresh() async {
    final api = _slot.api;
    if (api == null) return false;
    try {
      final remote =
          await api.fingerprint([for (final kind in _kinds) kind.wireName]);
      if (remote == _fingerprint && _items.isNotEmpty) return false;
      final fetched = <ConfigItem>[];
      for (final kind in _kinds) {
        for (final record in await api.items(kind.wireName)) {
          fetched.add(_itemOf(record));
        }
      }
      _items = fetched;
      _fingerprint = remote;
      _reportedRefusal = false;
      await _persist();
      if (!_changed.isClosed) _changed.add(null);
      return true;
    } catch (e) {
      // Once per silence, not once per trigger: before sign-in every attempt
      // is refused, and a line per notification would bury the one that
      // matters.
      if (!_reportedRefusal) {
        _reportedRefusal = true;
        _log.i('The plant\'s configuration rows could not be read over the '
            'relay yet (this is the expected answer until somebody signs '
            'in): $e');
      }
      return false;
    }
  }

  Future<void> dispose() async {
    await _trigger?.cancel();
    _trigger = null;
    await _changed.close();
  }

  void _schedule() {
    if (_running != null) {
      _dirty = true;
      return;
    }
    _running = refresh().whenComplete(() {
      _running = null;
      if (_dirty) {
        _dirty = false;
        _schedule();
      }
    });
  }

  Future<void> _persist() async {
    try {
      await _cache.setString(
          kConfigItemsCachePrefsKey,
          jsonEncode({
            'fingerprint': _fingerprint.toJson(),
            'items': [for (final item in _items) _recordOf(item).toJson()],
          }));
    } catch (e) {
      // The rows are in memory and in use; a cache that could not be written
      // costs the next boot its head start and nothing else.
      _log.w('The configuration rows could not be cached: $e');
    }
  }

  static ConfigItem _itemOf(rp.ConfigItemRecord record) => ConfigItem(
        kind: ConfigKind.byWireName(record.kind) ??
            (throw FormatException(
                'unknown configuration kind "${record.kind}"')),
        id: record.id,
        payload: record.payload,
        parentId: record.parentId,
        sortIndex: record.sortIndex,
        rev: record.rev,
      );

  static rp.ConfigItemRecord _recordOf(ConfigItem item) => rp.ConfigItemRecord(
        kind: item.kind.wireName,
        id: item.id,
        payload: item.payload,
        parentId: item.parentId,
        sortIndex: item.sortIndex,
        rev: item.rev,
      );
}

/// The rows on this client, restored from the cache before anything reads
/// them. Built once per container; `stateManProvider` and
/// `pageManagerProvider` both read it on a platform with no mirror.
final relayedConfigItemsProvider =
    FutureProvider<RelayedConfigItems>((ref) async {
  final items = RelayedConfigItems(
    cache: ref.watch(localPreferencesProvider),
    slot: ref.watch(gatewayConfigItemsSlotProvider),
  );
  ref.onDispose(items.dispose);
  await items.restore();
  return items;
});
