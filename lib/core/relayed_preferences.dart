/// The shared configuration store, served over the pipe — the gateway-mode
/// half that `RelayedAuditTrailStore` and `RelayedAccessTemplateStore` already
/// have for their surfaces.
///
/// ## What was wrong
///
/// A gateway panel used to build its shared store as `Preferences.create(db:
/// null, localCache: theDeviceLocalStore)`, so every shared configuration
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
/// | a boot key (`key_mappings`) | see the boot-key section below | it is read to *build* the client that would otherwise answer it, and read before anyone can sign in. |
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
/// ## The boot keys, and the deadlock they close
///
/// `stateManProvider` reads exactly two preference keys **in order to build
/// the client**: `state_man_config` and `key_mappings`. Anything that makes
/// either of them depend on the client — or on a session the panel cannot
/// present until it has booted — is a station that never comes up.
///
/// The rig measured that on 2026-09-09. A gateway panel with no station token
/// gets a session (a credential-less hello is admitted), and on that session
/// the backend refuses `preferences.getString`: *`awaiting_sign_in — nobody
/// has signed in on this session, and a session nobody signed in on may do
/// nothing but wait. Sign in first`*. That refusal is **correct** — an
/// unauthenticated session must hold nothing, and the fix is emphatically not
/// to let it read the plant's routing config. But it made boot need
/// preferences, preferences need sign-in and sign-in need a booted panel: the
/// panel tore down and retried forever, five sockets in TIME_WAIT and a screen
/// that looked disconnected.
///
/// So a boot key is answered from **the copy already on this device**
/// whenever the relay cannot answer it, and from the relay — written through
/// to that copy — whenever it can. The device copy is a *bootstrap*, not a
/// second home: the relay is preferred on every single read, and every
/// successful one refreshes the copy, so its staleness is bounded by the last
/// time this panel could read the shared store.
///
/// **The two keys reach that guarantee by different routes, and it matters
/// that the next reader knows which.**
///
///  * `key_mappings` is shared configuration on the wire, so it needs the
///    carve-out below: [kBootstrapPreferenceKeys] names it, and the routing
///    members consult that set.
///  * `state_man_config` needs nothing here. `StateManConfig.fromPrefs` reads
///    and writes it with `secret: true`, and a secret is routed to this
///    machine's keychain by [_isLocal] before any of this is reached — the
///    wire interface has no `secret` parameter and never may (SEC-01). Adding
///    it to [kBootstrapPreferenceKeys] would be worse than redundant: the
///    mirror write below is a plain `setString`, so it would create a second,
///    non-secret home for a key every real reader looks for in the keychain.
///
/// The property both of them are judged on is the same and is stated once, in
/// `gateway_boot_bootstrap_test.dart`: **a gateway boot survives a relay that
/// answers nothing.** Not "asks it for nothing" — the relay is preferred on
/// every read, and asking is how the copy gets refreshed; what boot must never
/// do is *depend* on the answer. The boundary in
/// `device_local_preferences.dart` is untouched — neither key is device-local,
/// and `device_local_preferences_test.dart` still pins both of them to the
/// shared side.
///
/// With the slot empty a boot key reads and writes the mirror; with the slot
/// filled it reads and writes the backend **and writes the result through to
/// the mirror**. The write-through is load-bearing rather than an
/// optimisation: a `key_mappings` change triggers `invalidateSelf` on
/// `stateManProvider`, and the rebuild reads this key again with the slot
/// cleared — without the write-through it would read the stale mirror and
/// rebuild its client on the old key set forever.
///
/// A read the backend **refuses** falls back to the mirror, which is the
/// deadlock fix itself. It is a fallback for reads only: a *write* the backend
/// refused stays refused and propagates, because a write that lands quietly on
/// the panel after the plant said no is the silent-loss class this whole
/// milestone exists to remove.
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
/// This reads `key_mappings` over the wire and, only if it differs, persists it
/// and announces the key — which drives the reload path that already exists in
/// `stateManProvider`.
///
/// It runs on every [GatewayPreferencesSlot.requestReconcile], and the slot
/// fires that on each `fill` **and** on each sign-in. The sign-in trigger is
/// what makes "refreshed from the relay once a session can read them" literal
/// rather than aspirational: between boot and sign-in the reconcile is refused
/// exactly like every other read, so a one-shot attempt at fill would leave the
/// panel on its bootstrap copy for the whole run.
///
/// **The residual, stated rather than hidden.** A panel that boots with the
/// gateway unreachable runs on its mirror's mapping until the link comes up.
/// And a *fresh* panel — one whose mirror has never held `key_mappings` — still
/// cannot boot against a backend that refuses it, because the default seed is
/// a *write*, and writes do not fall back. That is a new panel's first boot
/// before anyone has signed in on it; it is not the deadlock this file closes,
/// and pretending a seeded toy mapping had reached the plant would be worse.
library;

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:tfc_dart/core/database.dart' show Database;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

import 'device_local_preferences.dart';

/// The keys that must answer with no client **and with nobody signed in**,
/// because they are read in order to build one. See the boot-key section of
/// the library doc.
///
/// A set of one, spelled as a set so the next such key has an obvious home and
/// so the routing code reads as a rule rather than as a special case for a
/// literal. The other boot key, `state_man_config`, is deliberately **not**
/// here — it is read with `secret: true` and so never reaches the wire at all;
/// the library doc says why naming it here would be actively wrong.
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

  final StreamController<void> _reconcile = StreamController<void>.broadcast();

  /// The live client, or null while there is none. A **peek** — it never
  /// parks, which is what the bootstrap carve-out needs in order to answer
  /// locally rather than wait for a client that is waiting for it.
  rp.PreferencesApi? get api => _api;

  /// Fires when the bootstrap copy on this device is worth re-checking against
  /// the backend: a client arrived, or somebody signed in.
  ///
  /// A stream on the slot rather than a method on [RelayedPreferences] because
  /// the slot is the seam those two already share, and it is reachable from a
  /// `ref` — `preferencesProvider` hands out a `GuardedPreferences` whose inner
  /// object is private, so a caller holding it has no way to name the router.
  Stream<void> get onReconcileNeeded => _reconcile.stream;

  /// Asks whoever is listening to re-check the bootstrap copy.
  ///
  /// Called by [fill], and by the sign-in path — the first moment a panel that
  /// booted on its own copy is allowed to read the shared store, and therefore
  /// the first moment that copy can be refreshed. Fire-and-forget: this is a
  /// hint, and everything it drives is idempotent.
  void requestReconcile() {
    if (!_reconcile.isClosed) _reconcile.add(null);
  }

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
    requestReconcile();
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
    await _reconcile.close();
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
      // Every fill and every sign-in, not just the first one. Between boot and
      // sign-in the reconcile is refused exactly like every other read, so a
      // one-shot attempt would leave the panel on its bootstrap copy for the
      // whole run.
      _sources.add(_slot.onReconcileNeeded.listen((_) => _armReconcile()));
      // And once now, for a slot that was already filled when this was built.
      _armReconcile();
    }
  }

  final Preferences _inner;
  final GatewayPreferencesSlot _slot;
  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  final List<StreamSubscription<void>> _sources = [];

  /// Reconciles are serialized through this, so two triggers arriving together
  /// — a fill and the sign-in that follows it — cannot interleave their reads
  /// and land the older answer last.
  Future<void> _pendingReconcile = Future<void>.value();

  /// The bootstrap keys this panel has already reported it could not refresh,
  /// so a refusal is said once per run rather than once per read.
  final Set<String> _reportedUnrefreshed = {};

  void _armReconcile() {
    // Fire and forget, with a handler attached: an unawaited future that can
    // error is a crash nobody catches, and a gateway that never comes up is a
    // normal thing for this future to end in.
    _pendingReconcile = _pendingReconcile
        .then((_) => _reconcileBootstrapKeys())
        .catchError((Object _) {});
    unawaited(_pendingReconcile);
  }

  /// Says, once per key per run, that this panel is running on the copy in its
  /// own cache because the backend would not answer.
  ///
  /// Out loud rather than swallowed: a bootstrap copy that silently passed as
  /// the plant's current configuration is the failure mode this whole fallback
  /// could otherwise introduce. Once per key because the alternative is a line
  /// per read on a panel nobody has signed in on, which is every read it makes.
  void _bootstrapUnrefreshed(String key, Object error) {
    if (!_reportedUnrefreshed.add(key)) return;
    // `Logger`, not `stderr`: this class is the gateway-mode half, and
    // gateway mode is what a web build would run. `dart:io` here would be the
    // one import that made this file uncompilable there.
    Logger().w('$key: the gateway would not serve it, so this panel is '
        'running on the copy in its own cache — it will be refreshed on the '
        'next connection or sign-in that can read it ($error)');
  }

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

  /// A read of a bootstrap key: the mirror while the backend cannot answer,
  /// the backend once it can — written through so the next boot starts from it.
  ///
  /// The backend "cannot answer" in two ways, and both must land on the mirror
  /// or the panel does not boot. There is no client yet — the case the slot
  /// was built for — **or** there is one and it refuses, which is what a
  /// session nobody has signed in on gets, and what the rig measured.
  ///
  /// The refusal is caught rather than distinguished by its marker on purpose:
  /// `awaiting_sign_in` is the one seen today, but a boot key that cannot be
  /// read is a boot key that cannot be read, and a panel that came up on its
  /// own copy is strictly better than one that did not come up. What must not
  /// be swallowed is the *fact* of it, which [_bootstrapUnrefreshed] says.
  Future<T> _bootstrapRead<T>({
    required String key,
    required Future<T> Function() local,
    required Future<T> Function(rp.PreferencesApi api) wire,
    required Future<void> Function(T value) mirror,
  }) async {
    final api = _slot.api;
    if (api == null) return local();
    final T value;
    try {
      value = await wire(api);
    } on Object catch (error) {
      _bootstrapUnrefreshed(key, error);
      return local();
    }
    _reportedUnrefreshed.remove(key);
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

  /// The catch-up described in the library doc, re-run on every fill and every
  /// sign-in.
  Future<void> _reconcileBootstrapKeys() async {
    final api = _slot.api;
    // A peek, not `ready`: this is armed by the slot's own trigger, so a null
    // here means the client went away again between the trigger and this run.
    // Parking for the next one would queue a second reconcile behind the fill
    // that is about to fire its own.
    if (api == null) return;
    for (final key in kBootstrapPreferenceKeys) {
      final String? backend;
      try {
        backend = await api.getString(key);
      } on Object catch (error) {
        // The refusal this whole fallback exists for. Not a fault and not a
        // reason to stop: the next fill or sign-in tries again.
        _bootstrapUnrefreshed(key, error);
        continue;
      }
      _reportedUnrefreshed.remove(key);
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
        key: key,
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
        key: key,
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
        key: key,
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
        key: key,
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
        key: key,
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
      // Through the same path as every other bootstrap read, so a refusal
      // falls back here too. `fetchKeyMappings` does not call this, but the
      // preferences editor does, and a boot key that answered on `getString`
      // and threw on `containsKey` would be a second rule to get wrong.
      return _bootstrapRead(
        key: key,
        local: () => _inner.containsKey(key),
        wire: (api) => api.containsKey(key),
        // Nothing to write through: a presence answer is not a value.
        mirror: (_) async {},
      );
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

  /// Null, and it must be: this router holds no database handle of its own, so
  /// a caller reaching through this getter for raw Drift — which
  /// `GuardedPreferences` documents as a real hole in its own guard — finds
  /// nothing here to reach through. It is deliberately not forwarded to the
  /// inner store: a handle reached this way would write `flutter_preferences`
  /// on whatever database this station can see, which on this transport is not
  /// where the shared configuration lives.
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
