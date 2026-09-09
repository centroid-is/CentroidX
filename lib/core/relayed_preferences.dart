/// The shared configuration store, served over the pipe — the gateway-mode
/// half that `RelayedAuditTrailStore` and `RelayedAccessTemplateStore` already
/// have for their surfaces.
///
/// ## What was wrong
///
/// A gateway panel used to build its shared store as `Preferences.create(db:
/// null, localCache: <device-local store>)`, so every shared configuration
/// read and write landed in a **panel-local mirror**. An operator editing an
/// alarm rule got a successful-looking edit the backend never saw, and two
/// panels held two different rule sets with nothing anywhere reporting it.
/// That is the same "silence is not success" class as the alarm-history bug:
/// the write did not fail, it just did not go anywhere that matters.
///
/// ## The shape
///
/// This is a **router**, not a store. It holds two real backends and decides
/// per call which one answers:
///
/// | Case | Goes to | Why |
/// |---|---|---|
/// | `secret: true` | the inner store's keychain | SEC-01: the wire interface has no `secret` parameter and never may. A credential must not be copied into a replicated table, and the keychain is per-machine by construction. |
/// | a device-local key | the inner store | `device_local_preferences.dart` says which, and why, per key. |
/// | `key_mappings` | see the carve-out below | it is read to *build* the client that would otherwise answer it. |
/// | everything else | the wire | this is the fix. |
///
/// `implements Preferences` for the reason `GuardedPreferences` does: the
/// concrete class is what every call site in the app is typed against, all of
/// its state is private, and this way no screen can tell which transport
/// answered it.
///
/// ## Why the client arrives late, and what happens before it does
///
/// The panel's one relay client is constructed inside `stateManProvider`,
/// which **awaits `preferencesProvider`** before it can start — it reads
/// `state_man_config` and `key_mappings` to build with. And
/// `RemoteStateMan` takes its subscription key set as a constructor argument
/// derived from those key mappings, so the client cannot be built any earlier.
/// A `RelayedPreferences` that resolved its client by awaiting
/// `stateManProvider` — the way `auditTrailStoreProvider` does — would
/// therefore deadlock at boot.
///
/// So the client arrives through a [GatewayPreferencesSlot] that
/// `stateManProvider` fills once it exists, exactly as `GatewayAlarmSlot`
/// delivers the alarm transport for the same reason. Before it is filled a
/// call **parks**. It does not fall back to the local mirror — that is the bug
/// being fixed, and it would also make boot-time config nondeterministic,
/// answering from the mirror or the backend depending on which won the race.
/// It does not refuse either, which would break boot for the same reason.
/// Parking terminates in every case: the slot is filled when the client is
/// built, failed on every error exit of that build, and once filled the call
/// is bounded by the client's own readiness deadline, which surfaces as
/// `LinkDown`. There is no path on which a caller waits forever and none on
/// which it is told something false.
///
/// ## The one carve-out: `key_mappings`
///
/// `key_mappings` is read while the client is being built, so it is the one
/// key that must have an answer with the slot empty. With the slot empty it
/// reads and writes the mirror; with the slot filled it reads and writes the
/// backend **and writes the result through to the mirror**. The write-through
/// is load-bearing rather than an optimisation: a `key_mappings` change
/// triggers `invalidateSelf` on `stateManProvider`, and the rebuild reads this
/// key again with the slot cleared — without the write-through it would read
/// the stale mirror and rebuild its client on the old key set forever.
///
/// The empty-slot **write** exists for exactly one caller: `fetchKeyMappings`
/// seeding a default on a panel whose store is empty. That default must land
/// locally and must never reach the backend — a panel seeding a toy mapping
/// into the plant's routing config because its own mirror was empty would be a
/// plant-level defect.
///
/// [reconcileOnFill] closes the remaining gap: `preferences.changed` fires
/// only when the backend changes *after* this panel connects, so a panel whose
/// mirror went stale while it was switched off would otherwise never learn.
/// On the first fill this reads `key_mappings` once over the wire and, only if
/// it differs, persists it and announces the key — which drives the reload
/// path that already exists in `stateManProvider`.
///
/// **The residual, stated rather than hidden.** A *fresh* panel with an empty
/// mirror boots on the seeded default and is rescued by that reconcile, one
/// reload after its first connection. A panel that boots with the gateway
/// unreachable runs on its mirror's mapping until the link comes up. Both are
/// the posture the panel already had; what is gone is the permanence.
library;

import 'dart:async';

import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

import 'device_local_preferences.dart';

/// The keys that must answer with no client, because they are read in order to
/// build one. See the carve-out section of the library doc.
///
/// A set of one, spelled as a set so the next such key has an obvious home and
/// so the routing code reads as a rule rather than as a special case for a
/// literal.
const Set<String> kBootstrapPreferenceKeys = {'key_mappings'};

/// How the relay client reaches [RelayedPreferences] despite being built after
/// it.
///
/// The `GatewayAlarmSlot` pattern (`lib/providers/state_man.dart`), and a
/// separate slot from that one on purpose: its null-in-direct-mode semantics
/// are load-bearing for `alarmManProvider`, and this one has to distinguish
/// three states rather than two — empty, filled, and *failed*, which is what
/// releases a parked caller when the panel's boot goes wrong.
///
/// It also owns one broadcast relay of the backend's `preferences.changed`
/// notifications, so a listener taken before a reconnect keeps hearing them
/// across a client replacement.
final class GatewayPreferencesSlot {
  rp.PreferencesApi? _api;
  Completer<rp.PreferencesApi>? _waiting;
  Object? _failure;
  StackTrace? _failureStack;
  StreamSubscription<String>? _upstream;

  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  /// The live client, or null while there is none. A **peek** — it never
  /// parks, which is what the bootstrap carve-out needs in order to answer
  /// locally rather than wait for a client that is waiting for it.
  rp.PreferencesApi? get api => _api;

  /// The live client, parking until there is one or until the panel's boot
  /// fails.
  Future<rp.PreferencesApi> get ready {
    final api = _api;
    if (api != null) return Future.value(api);
    final failure = _failure;
    if (failure != null) {
      return Future.error(failure, _failureStack);
    }
    return (_waiting ??= Completer<rp.PreferencesApi>()).future;
  }

  /// The backend's change notifications, across client replacements.
  Stream<String> get onPreferencesChanged => _changes.stream;

  /// Publishes the client. Releases every parked caller and clears any earlier
  /// failure — a panel that reconnects must not stay poisoned by the boot it
  /// failed.
  void fill(rp.PreferencesApi api) {
    _failure = null;
    _failureStack = null;
    _api = api;
    _upstream?.cancel();
    _upstream = api.onPreferencesChanged.listen(
      _changes.add,
      // A change notification is not worth taking the panel down for, and the
      // supervisor already reports the link itself.
      onError: (Object _) {},
    );
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(api);
  }

  /// Reports that no client is coming — the gateway branch of
  /// `stateManProvider` threw. Parked callers get that error rather than
  /// waiting for a client that is not being built.
  void fail(Object error, [StackTrace? stack]) {
    _failure = error;
    _failureStack = stack;
    _api = null;
    _upstream?.cancel();
    _upstream = null;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(error, stack);
    }
  }

  /// Withdraws the client without declaring a failure — the provider is being
  /// disposed and a rebuild will fill this again. Callers park once more
  /// rather than being handed a client whose socket is going down.
  void clear() {
    _api = null;
    _failure = null;
    _failureStack = null;
    _upstream?.cancel();
    _upstream = null;
  }

  Future<void> dispose() async {
    clear();
    await _changes.close();
  }
}

/// The shared preferences surface of a gateway panel.
final class RelayedPreferences implements Preferences {
  RelayedPreferences({
    required Preferences inner,
    required GatewayPreferencesSlot slot,
    bool reconcileOnFill = true,
  })  : _inner = inner,
        _slot = slot {
    // Two `listen`s and not two `addStream`s: a controller accepts only one
    // `addStream` at a time, and the second throws rather than merging.
    _sources.add(_inner.onPreferencesChanged.listen(_emit));
    _sources.add(_slot.onPreferencesChanged.listen(_emit));
    if (reconcileOnFill) {
      // Fire and forget, with a handler attached: an unawaited future that can
      // error is a crash nobody catches, and a gateway that never comes up is
      // a normal thing for this future to end in.
      unawaited(_reconcileBootstrapKeys().catchError((Object _) {}));
    }
  }

  final Preferences _inner;
  final GatewayPreferencesSlot _slot;
  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  final List<StreamSubscription<String>> _sources = [];

  void _emit(String key) {
    if (!_changes.isClosed) _changes.add(key);
  }

  // ---------------------------------------------------------------------------
  // Routing
  // ---------------------------------------------------------------------------

  /// True when [key] must be answered by the inner store for this call.
  bool _isLocal(String key, bool secret) =>
      secret || isDeviceLocalPreferenceKey(key);

  /// Runs the wire half of a call, parking for the client if it is not here.
  Future<T> _wire<T>(Future<T> Function(rp.PreferencesApi api) send) async =>
      send(await _slot.ready);

  /// A read of a bootstrap key: the mirror while there is no client, the
  /// backend once there is — written through so the next boot starts from it.
  Future<T> _bootstrapRead<T>({
    required Future<T> Function() local,
    required Future<T> Function(rp.PreferencesApi api) wire,
    required Future<void> Function(T value) mirror,
  }) async {
    final api = _slot.api;
    if (api == null) return local();
    final value = await wire(api);
    await mirror(value);
    return value;
  }

  /// A write of a bootstrap key: local-only while there is no client (the boot
  /// seed, which must not reach the plant), otherwise the backend and then the
  /// mirror.
  Future<void> _bootstrapWrite({
    required Future<void> Function() local,
    required Future<void> Function(rp.PreferencesApi api) wire,
  }) async {
    final api = _slot.api;
    if (api == null) return local();
    await wire(api);
    await local();
  }

  /// The one-shot catch-up described in the library doc.
  Future<void> _reconcileBootstrapKeys() async {
    final api = await _slot.ready;
    for (final key in kBootstrapPreferenceKeys) {
      final backend = await api.getString(key);
      final mine = await _inner.getString(key);
      if (backend == mine) continue;
      if (backend == null) {
        await _inner.remove(key);
      } else {
        await _inner.setString(key, backend);
      }
      // Announced on this store's own stream, which is what
      // `stateManProvider`'s `key_mappings` listener is subscribed to.
      _emit(key);
    }
  }

  /// The refusal for a write the wire cannot honestly carry.
  ///
  /// `saveToDb: false` means "put this in the caches but not in the shared
  /// database". There is no wire call with that meaning, and neither
  /// alternative is honest: sending it anyway contradicts the caller, and
  /// keeping it local creates a key that reads back differently than it was
  /// written, because the plain read goes to the backend and misses it. Every
  /// real caller in the tree passes `secret: true` alongside it and is routed
  /// to the keychain before reaching here.
  /// Returned as a failed future rather than thrown synchronously: every other
  /// failure on this surface reaches the caller through the future it awaited,
  /// and a member that sometimes throws before returning one is a second error
  /// path for a call site to get wrong.
  UnsupportedError _unsharedWrite(String key) => UnsupportedError(
      'setting "$key" with saveToDb: false is not available in gateway mode: '
      'the shared store is the backend, and a value written locally would not '
      'be read back by the very next read of the same key. Pass secret: true '
      'if this belongs in the keychain, or write it through '
      'localPreferencesProvider if it belongs to this station.');

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// The backend's key set, and deliberately not a union with the local store.
  ///
  /// The shared surface **is** the backend. The local file holds device-local
  /// keys, which belong to `localPreferencesProvider` and were never part of
  /// this enumeration, and the dead direct-mode mirror, whose resurrection is
  /// the stale-value bug this class removes.
  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) =>
      _wire((api) => api.getKeys(allowList: allowList));

  @override
  Future<Map<String, Object?>> getAll({Set<String>? allowList}) =>
      _wire((api) => api.getAll(allowList: allowList));

  @override
  Future<bool?> getBool(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.getBool(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapRead(
        local: () => _inner.getBool(key),
        wire: (api) => api.getBool(key),
        mirror: (value) =>
            value == null ? _inner.remove(key) : _inner.setBool(key, value),
      );
    }
    return _wire((api) => api.getBool(key));
  }

  @override
  Future<int?> getInt(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.getInt(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapRead(
        local: () => _inner.getInt(key),
        wire: (api) => api.getInt(key),
        mirror: (value) =>
            value == null ? _inner.remove(key) : _inner.setInt(key, value),
      );
    }
    return _wire((api) => api.getInt(key));
  }

  @override
  Future<double?> getDouble(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.getDouble(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapRead(
        local: () => _inner.getDouble(key),
        wire: (api) => api.getDouble(key),
        mirror: (value) =>
            value == null ? _inner.remove(key) : _inner.setDouble(key, value),
      );
    }
    return _wire((api) => api.getDouble(key));
  }

  @override
  Future<String?> getString(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.getString(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapRead(
        local: () => _inner.getString(key),
        wire: (api) => api.getString(key),
        mirror: (value) =>
            value == null ? _inner.remove(key) : _inner.setString(key, value),
      );
    }
    return _wire((api) => api.getString(key));
  }

  @override
  Future<List<String>?> getStringList(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.getStringList(key, secret: secret);
    }
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapRead(
        local: () => _inner.getStringList(key),
        wire: (api) => api.getStringList(key),
        mirror: (value) => value == null
            ? _inner.remove(key)
            : _inner.setStringList(key, value),
      );
    }
    return _wire((api) => api.getStringList(key));
  }

  @override
  Future<bool> containsKey(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.containsKey(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      final api = _slot.api;
      if (api == null) return _inner.containsKey(key);
      return api.containsKey(key);
    }
    return _wire((api) => api.containsKey(key));
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  @override
  Future<void> setBool(String key, bool value,
      {bool saveToDb = true, bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.setBool(key, value, saveToDb: saveToDb, secret: secret);
    }
    if (!saveToDb) return Future.error(_unsharedWrite(key));
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.setBool(key, value),
        wire: (api) => api.setBool(key, value),
      );
    }
    return _wire((api) => api.setBool(key, value));
  }

  @override
  Future<void> setInt(String key, int value,
      {bool saveToDb = true, bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.setInt(key, value, saveToDb: saveToDb, secret: secret);
    }
    if (!saveToDb) return Future.error(_unsharedWrite(key));
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.setInt(key, value),
        wire: (api) => api.setInt(key, value),
      );
    }
    return _wire((api) => api.setInt(key, value));
  }

  @override
  Future<void> setDouble(String key, double value,
      {bool saveToDb = true, bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.setDouble(key, value, saveToDb: saveToDb, secret: secret);
    }
    if (!saveToDb) return Future.error(_unsharedWrite(key));
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.setDouble(key, value),
        wire: (api) => api.setDouble(key, value),
      );
    }
    return _wire((api) => api.setDouble(key, value));
  }

  @override
  Future<void> setString(String key, String value,
      {bool saveToDb = true, bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.setString(key, value, saveToDb: saveToDb, secret: secret);
    }
    if (!saveToDb) return Future.error(_unsharedWrite(key));
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.setString(key, value),
        wire: (api) => api.setString(key, value),
      );
    }
    return _wire((api) => api.setString(key, value));
  }

  @override
  Future<void> setStringList(String key, List<String> value,
      {bool saveToDb = true, bool secret = false}) {
    if (_isLocal(key, secret)) {
      return _inner.setStringList(key, value,
          saveToDb: saveToDb, secret: secret);
    }
    if (!saveToDb) return Future.error(_unsharedWrite(key));
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.setStringList(key, value),
        wire: (api) => api.setStringList(key, value),
      );
    }
    return _wire((api) => api.setStringList(key, value));
  }

  @override
  Future<void> remove(String key, {bool secret = false}) {
    if (_isLocal(key, secret)) return _inner.remove(key, secret: secret);
    if (kBootstrapPreferenceKeys.contains(key)) {
      return _bootstrapWrite(
        local: () => _inner.remove(key),
        wire: (api) => api.remove(key),
      );
    }
    return _wire((api) => api.remove(key));
  }

  /// Forwarded to the backend untouched, and never applied to the local store.
  ///
  /// The server's semantics are already the right ones — a bare `clear()` is
  /// refused there, and an allow-listed one is graded per named key — and
  /// re-implementing them panel-side would be a second copy of a rule that
  /// only the backend is entitled to enforce. It must not touch the local
  /// store because that store is where this station's own settings live, and
  /// clearing the shared surface is not licence to wipe them.
  @override
  Future<void> clear({Set<String>? allowList}) =>
      _wire((api) => api.clear(allowList: allowList));

  // ---------------------------------------------------------------------------
  // The rest of the Preferences surface
  // ---------------------------------------------------------------------------

  /// Null, and it must be: a gateway panel opens no Postgres pool, so a caller
  /// reaching through this getter for raw Drift — which
  /// `GuardedPreferences` documents as a real hole — finds nothing to reach
  /// through here.
  @override
  Database? get database => null;

  @override
  KeyCache get keyCache => _inner.keyCache;

  @override
  MySecureStorage get secureStorage => _inner.secureStorage;

  @override
  PreferencesApi? get localCache => _inner.localCache;

  /// The two halves merged, because one store answers both and a listener
  /// cannot be asked to know which half its key came from.
  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  /// Whether the **backend** holds this key.
  ///
  /// Answered over the wire rather than left as the inner store's `false`.
  /// The raw preferences editor picks which store to write a key back to from
  /// this answer, so a blanket `false` would send every edit of a shared key
  /// to the local store — silently reintroducing, in the one screen that can
  /// reach any key by name, the divergence this class removes.
  @override
  Future<bool> isKeyInDatabase(String key) async {
    if (isDeviceLocalPreferenceKey(key)) return false;
    return _wire((api) => api.containsKey(key));
  }

  /// Both are no-ops with a reason rather than forwards.
  ///
  /// They are the direct path's Postgres plumbing: `loadFromPostgres` fills a
  /// memory cache this router does not read from, and `syncToLocalCache`
  /// copies database rows over the local store — which is precisely the
  /// mechanism that made device-local keys need defending in the first place,
  /// and which must never run on a transport whose shared store is remote.
  @override
  Future<void> syncToLocalCache() async {}

  @override
  Future<void> loadFromPostgres() async {}

  Future<void> dispose() async {
    for (final source in _sources) {
      await source.cancel();
    }
    _sources.clear();
    await _changes.close();
  }
}
