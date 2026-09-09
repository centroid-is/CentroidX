import 'dart:async';
import 'dart:collection';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:modbus_client/modbus_client.dart' show ModbusEndianness;
import 'package:modbus_client_tcp/modbus_client_tcp.dart' show ModbusClientTcp;
import 'package:rxdart/rxdart.dart' show BehaviorSubject;
import 'package:tfc_dart/core/modbus_client_wrapper.dart';
import 'package:tfc_dart/core/state_man.dart'
    show
        ConnectionStatus,
        DeviceClient,
        EffectiveDeviceStatus,
        KeyMappings,
        ModbusConfig,
        ModbusNodeConfig,
        ModbusPollGroupConfig,
        StateMan;
import 'package:tfc_dart/core/umas_client.dart';
import 'package:tfc_dart/core/umas_types.dart'
    show
        TypedVariableValue,
        UmasException,
        UmasNotScalarException,
        UmasSessionState,
        UmasStringDecoder,
        UmasVariable,
        UmasDataTypeRef;

/// Adapter that wraps [ModbusClientWrapper] as a [DeviceClient] for use in
/// [StateMan].
///
/// Translates between [ModbusClientWrapper]'s `Object?` value streams and the
/// [DynamicValue]-based [DeviceClient] interface. Uses [ModbusRegisterSpec]
/// metadata (not runtime type inference) to assign correct [NodeId] typeIds.
///
/// B-1/B-2 (v1.1.x): when an entry has `variableName != null` and the
/// server has `umasEnabled == true`, reads + writes route through a
/// lazily-created per-adapter [UmasClient] keyed off the symbol name
/// rather than the Modbus address. See [_getUmasClient].
class ModbusDeviceClientAdapter implements DeviceClient {
  /// The underlying Modbus transport wrapper.
  final ModbusClientWrapper wrapper;

  /// Registers the device has refused by name — the wrapper's
  /// [ModbusClientWrapper.refusals], re-exposed unchanged.
  ///
  /// The seam `ModbusUpstreamLink.wrapping` consumes: a refused address must
  /// come out of the pipe as a *quality* an operator reads, and the link is
  /// the layer that mints qualities. Spec keys and gateway keys are the same
  /// strings on this adapter (`buildSpecsFromKeyMappings` keys the specs by
  /// the mapping's own key), so no translation happens here on purpose — a
  /// second vocabulary at this seam is how the two ends drift.
  Stream<ModbusAddressRefusal> get registerRefusals => wrapper.refusals;

  /// Optional alias for display/logging purposes.
  final String? serverAlias;

  /// Register specs keyed by their subscription key.
  final Map<String, ModbusRegisterSpec> _specs;

  /// UMAS variable names per key (null for keys that use classic Modbus
  /// addressing). Populated from `KeyMappingEntry.variableName` at
  /// adapter construction. Mutated by [updateVariableNames] when the
  /// operator edits the key mappings (TD-003 v1.1.x cleanup path).
  Map<String, String?> _variableNames;

  /// How this server's STRING bytes become text, handed to every [UmasClient]
  /// this adapter builds.
  ///
  /// **Optional, and null reproduces exactly what this adapter did before it
  /// existed.** The caller is what knows the server alias and therefore what
  /// encoding was configured for it; see
  /// `packages/tfc_relay_local/lib/src/string_encoding.dart`. Held on the
  /// adapter rather than passed per call because the client is rebuilt on
  /// every reconnect and the encoding is a property of the device, not of the
  /// session.
  final UmasStringDecoder? decodeString;

  /// True when this adapter's server has `umasEnabled == true` in its
  /// [ModbusConfig]. Determines whether variableName-bearing keys can
  /// route by name; when false they surface as errors per B-1.
  final bool umasEnabled;

  /// Last-known typed UMAS reads, mirroring [ModbusClientWrapper]'s
  /// last-cached-value semantics for keys whose data has not yet been
  /// polled. Updated by [read]/[subscribe] when they fire successfully.
  final Map<String, DynamicValue> _umasLastValues = {};

  /// Long-lived per-key broadcast subjects for UMAS-by-name keys (F-1).
  /// [subscribe] hands out the subject's stream and the subject stays
  /// open for the lifetime of the adapter. Every successful
  /// [readUmasVariable] adds the fresh [DynamicValue] so subscribers
  /// see updates without the stream completing. Disposed in [dispose].
  final Map<String, BehaviorSubject<DynamicValue>> _umasSubjects = {};

  /// Lazy UMAS client. Re-created when the underlying
  /// [ModbusClientWrapper.client] changes (reconnect).
  UmasClient? _umasClient;
  ModbusClientTcp? _umasClientFor;

  /// TD-009 (v1.1.x): sticky M580-detected bit, hoisted out of
  /// [UmasClient] so it survives client re-creates on every reconnect.
  /// `false` initially; flips to `true` the first time any UmasClient
  /// owned by this adapter detects M580 via 0xA1 from ReadVariable
  /// (0x22). Seeded into each freshly-constructed UmasClient so the
  /// next reconnect skips the wasted 0x22 → 0xA1 probe round-trip.
  /// Tied to [serverAlias] lifetime; the adapter is rebuilt when key
  /// mappings (and therefore the alias) change.
  bool _useMonitorPlc = false;

  /// B-4 (v1.1.x): per-poll-group state for batched MonitorPlc polling.
  /// All UMAS-by-name keys for this adapter share ONE MonitorPlc table
  /// on the PLC (the protocol only supports one table per session),
  /// but each poll group keeps its own [Timer.periodic] so the cadence
  /// matches the configured group interval. Each tick issues a single
  /// `monitorReadAll` and demuxes the response back into per-key
  /// [_umasSubjects] / [_umasLastValues].
  ///
  /// `_umasPollGroups`: poll-group name -> configured interval.
  /// `_umasKeysByGroup`: poll-group name -> list of UMAS-by-name keys
  ///   that opted into the group (via `KeyMappingEntry.modbusNode.pollGroup`).
  /// `_umasKeyOrder`: list of UMAS-by-name keys in MonitorPlc registration
  ///   order — populated when the table is built on a fresh UmasClient.
  ///   `monitorReadAll` returns values in sorted-index order, so the i-th
  ///   value belongs to `_umasKeyOrder[i]`.
  /// `_umasTimers`: per-group timers. Stopped on disconnect, restarted
  ///   on (re)connect after the table is rebuilt.
  /// `_umasTableBuiltFor`: the ModbusClientTcp identity the current
  ///   table was registered against — when it changes the table must
  ///   be rebuilt against the fresh UmasClient.
  final Map<String, Duration> _umasPollGroups = {};
  final Map<String, List<String>> _umasKeysByGroup = {};
  final List<String> _umasKeyOrder = [];
  final Map<String, Timer> _umasTimers = {};
  ModbusClientTcp? _umasTableBuiltFor;

  /// Phase 7 / D-04 (v1.1.x): retained per-key poll-group mapping from
  /// the constructor's `umasPollGroupByKey` argument. Consulted by
  /// [addUmasKey] (and Plan 02/03 follow-ups) to decide which poll-group
  /// bucket a runtime-registered key lands in.
  ///
  /// If a key is absent from this map at registration time, [addUmasKey]
  /// uses `'default'`. If the mapped group has no entry in
  /// [_umasPollGroups], [addUmasKey] falls back to `'default'` AND logs
  /// a warn.
  ///
  /// Mutable to support [debugSetUmasPollGroupForKey] — a
  /// @visibleForTesting seam; production callers do not change a key's
  /// poll-group at runtime.
  final Map<String, String> _umasPollGroupByKey = {};

  /// Per-server poll-group intervals from [ModbusConfig.pollGroups],
  /// retained past construction so [addUmasKey] can start a key in a
  /// configured group that had no members at adapter build time (e.g. a
  /// key added at runtime via the Key Repository) instead of silently
  /// falling back to 'default' cadence.
  final Map<String, Duration> _configuredGroupIntervals = {};

  /// Guard so we don't kick off two concurrent table-build attempts when
  /// a poll tick races with the connection-state listener.
  bool _umasTableBuildInFlight = false;

  /// Subscription to [ModbusClientWrapper.connectionStream]. Drives
  /// table (re)build + timer lifecycle. Cancelled in [dispose].
  StreamSubscription<ConnectionStatus>? _umasConnectionSub;

  /// F-8 / TD-011: subscription to [UmasClient.projectCrcChanges] for
  /// the currently-active UmasClient instance. Re-subscribed each time
  /// [_getUmasClient] allocates a fresh client (after reconnect). On
  /// emission the adapter forces a MonitorPlc table rebuild so the
  /// cached `(blockNo, offset)` registrations are refreshed against
  /// the new project.
  StreamSubscription<int>? _umasProjectCrcSub;

  /// TD-004 (v1.1.x): subscription to [UmasClient.sessionStream] for
  /// the currently-active UmasClient. Re-subscribed every time
  /// [_getUmasClient] allocates a fresh client. Drives
  /// [_effectiveStatus$] so the UI chip surfaces broken UMAS sessions
  /// (TCP up + Data Dictionary disabled, refused reservation, pairing-
  /// key drift) as `umasUnhealthy` instead of falsely showing green.
  StreamSubscription<UmasSessionState>? _umasSessionSub;

  /// TD-004: latest cached UMAS session state. `null` when no umas
  /// session has been attempted yet (no UMAS-by-name keys subscribed
  /// and no operator-triggered read/write). Used in
  /// [_recomputeEffectiveStatus] to decide whether `connected` should
  /// be demoted to `umasUnhealthy`.
  UmasSessionState? _lastUmasSessionState;

  /// TD-004: derived health stream. Emits the combined TCP+UMAS
  /// status. Seeded with the current TCP status mapped to its
  /// [EffectiveDeviceStatus] equivalent so first subscribers see a
  /// value immediately. Closed in [dispose].
  late final BehaviorSubject<EffectiveDeviceStatus> _effectiveStatus$ =
      BehaviorSubject<EffectiveDeviceStatus>.seeded(
          _mapTcpStatus(wrapper.connectionStatus));

  static final _log = Logger(printer: SimplePrinter(), level: Level.info);

  /// Default MonitorPlc-poll interval when the operator's key mapping
  /// references a poll group not present in [ModbusConfig.pollGroups].
  /// Conservative 1s default mirrors `ModbusClientWrapper._defaultPollInterval`.
  static const _defaultPollInterval = Duration(seconds: 1);

  ModbusDeviceClientAdapter(
    this.wrapper, {
    required Map<String, ModbusRegisterSpec> specs,
    this.serverAlias,
    Map<String, String?> variableNames = const {},
    this.umasEnabled = false,
    this.decodeString,
    Map<String, String>? umasPollGroupByKey,
    List<ModbusPollGroupConfig>? pollGroups,
  })  : _specs = Map.unmodifiable(specs),
        _variableNames = Map.of(variableNames) {
    _initUmasPollGroups(
      umasPollGroupByKey: umasPollGroupByKey ?? const {},
      pollGroups: pollGroups ?? const [],
    );
    _initUmasLifecycle();
    _initEffectiveStatus();
  }

  /// Build the per-group key lists from the supplied per-key mapping
  /// `(key -> pollGroupName)` and the per-server pollGroup intervals.
  /// Called once at construction; the adapter is otherwise immutable.
  void _initUmasPollGroups({
    required Map<String, String> umasPollGroupByKey,
    required List<ModbusPollGroupConfig> pollGroups,
  }) {
    // Phase 7 / D-04: retain the per-key group mapping so post-
    // construction registrations via [addUmasKey] inherit the same
    // pollGroup the KeyMapping specified.
    _umasPollGroupByKey.addAll(umasPollGroupByKey);
    final groupIntervals = <String, Duration>{};
    for (final pg in pollGroups) {
      groupIntervals[pg.name] = pg.interval;
    }
    _configuredGroupIntervals.addAll(groupIntervals);
    for (final entry in umasPollGroupByKey.entries) {
      final key = entry.key;
      if (_variableNames[key] == null) continue; // only UMAS-by-name
      final group = entry.value;
      _umasKeysByGroup.putIfAbsent(group, () => <String>[]).add(key);
      _umasPollGroups.putIfAbsent(
        group,
        () => groupIntervals[group] ?? _defaultPollInterval,
      );
    }
    // Keys without an explicit pollGroup mapping default to 'default'.
    for (final key in _variableNames.keys) {
      if (_variableNames[key] == null) continue;
      if (umasPollGroupByKey[key] != null) continue;
      _umasKeysByGroup.putIfAbsent('default', () => <String>[]).add(key);
      _umasPollGroups.putIfAbsent(
        'default',
        () => groupIntervals['default'] ?? _defaultPollInterval,
      );
    }
  }

  /// Wire the (re)connect → pair-session → rebuild-table → start-timers
  /// chain. Cheap no-op when [umasEnabled] is false — keeps classic-Modbus
  /// adapters untouched.
  ///
  /// v1.1.x Bug A real fix: this fires for ALL `umasEnabled` adapters,
  /// not just those with at least one UMAS-by-name key. Without it, an
  /// `umasEnabled=true` server whose KeyMappings contain only classic-
  /// Modbus addresses (no `variableName` entries) would never pair the
  /// UMAS session at boot — the only path to session init was a read of
  /// a UMAS-by-name key, which never happened. The
  /// [EffectiveDeviceStatus] chip stayed amber forever, lying to the
  /// operator about a server that's actually fine. We now eagerly pair
  /// the session via [_eagerPairUmasSession] on every `connected`
  /// transition. When UMAS-by-name keys ARE configured, the same
  /// listener also triggers the MonitorPlc table build.
  void _initUmasLifecycle() {
    if (!umasEnabled) return;
    // Helper: fire the appropriate pair/build path for a connected wrapper.
    // Hoisted so we can invoke it both from the stream listener AND, below,
    // synchronously when the wrapper is already in the connected state at
    // the moment this adapter is constructed (hot-reload of the provider
    // graph while the wrapper outlives the adapter; or any future construction
    // order where `connect()` is invoked before the listener attaches).
    void onConnected() {
      if (_umasKeysByGroup.isEmpty) {
        // No MonitorPlc registrations needed — just pair the session
        // so the chip surfaces real UMAS health.
        Future.microtask(_eagerPairUmasSession);
      } else {
        // The table-build path already calls `readPlcStatus` internally,
        // which pairs the session as a side effect. No need to fire
        // both.
        Future.microtask(_buildUmasTableAndStartTimers);
      }
    }

    _umasConnectionSub = wrapper.connectionStream.listen((status) {
      if (status == ConnectionStatus.connected) {
        onConnected();
      } else {
        _stopUmasTimers();
        _umasTableBuiltFor = null;
      }
    });

    // v1.1.x: also fire synchronously when the wrapper is ALREADY connected
    // at adapter-construction time. `connectionStream` is a BehaviorSubject
    // and will replay the current value to the listener above via a
    // microtask, but a replayed `disconnected` followed by a missed
    // `connected` (e.g. the wrapper was already connected before this
    // adapter existed, or a hot-reload rewired the listener after the
    // event) would leave the UMAS session unpaired and `_umasKeysByGroup`'s
    // MonitorPlc table never built. Cheap belt-and-suspenders: if the TCP
    // is already up at this exact moment, kick off the pair/build path
    // directly so the chip and operator widgets see fresh data without
    // waiting for a reconnect.
    if (wrapper.connectionStatus == ConnectionStatus.connected) {
      onConnected();
    }
  }

  /// v1.1.x Bug A real fix: fire `readPlcStatus()` on a freshly-
  /// (re)connected UMAS-enabled adapter so the session pairs without
  /// waiting for an operator-triggered read.
  ///
  /// `readPlcStatus()` runs through [`UmasClient._withSession`] which
  /// drives `readPlcId` + `init` + `_readProjectBlock` on its first
  /// call after a (re)connect, transitioning the session into
  /// [`UmasSessionState.paired`]. The session-state stream emission
  /// flows back into [_recomputeEffectiveStatus] and flips the
  /// [EffectiveDeviceStatus] chip from `connecting` → `connected`
  /// (paired) or `umasUnhealthy` (init failure surfaced in tooltip).
  ///
  /// Errors are logged at info level — a non-Schneider Modbus server on
  /// an UMAS-flagged port should fail loudly via the chip but not crash
  /// the adapter. Re-fires on every reconnect via [_initUmasLifecycle].
  Future<void> _eagerPairUmasSession() async {
    final umas = _getUmasClient();
    if (umas == null) return;
    try {
      await umas.readPlcStatus();
    } catch (e) {
      _log.i('UMAS eager session pairing failed: $e — chip will '
          'reflect umasUnhealthy via session-state stream');
    }
  }

  /// TD-004 (v1.1.x): map a pure TCP [ConnectionStatus] to its
  /// [EffectiveDeviceStatus] equivalent for the case where UMAS is
  /// either disabled or not yet attempted. The mapping is a 1:1
  /// upgrade — the umasUnhealthy state is only reachable when the
  /// adapter has observed a non-paired UmasSessionState.
  EffectiveDeviceStatus _mapTcpStatus(ConnectionStatus s) => switch (s) {
        ConnectionStatus.connected => EffectiveDeviceStatus.connected,
        ConnectionStatus.connecting => EffectiveDeviceStatus.connecting,
        ConnectionStatus.disconnected => EffectiveDeviceStatus.disconnected,
      };

  /// TD-004 (v1.1.x): always-on TCP-status listener that drives the
  /// derived [_effectiveStatus$] stream. Runs independently of the
  /// UMAS-by-name lifecycle (which short-circuits for adapters with
  /// no UMAS-by-name keys). On TCP disconnect the cached session
  /// state is cleared so a stale `paired` doesn't leak across
  /// reconnects.
  StreamSubscription<ConnectionStatus>? _effectiveStatusSub;

  void _initEffectiveStatus() {
    _effectiveStatusSub = wrapper.connectionStream.listen((status) {
      if (status != ConnectionStatus.connected) {
        // TCP down → drop the UMAS session view so a stale paired
        // doesn't survive a reconnect. _getUmasClient will rewire
        // _umasSessionSub against the fresh client on the next read.
        _lastUmasSessionState = null;
      }
      _recomputeEffectiveStatus();
    });
  }

  /// TD-004 (v1.1.x): recompute and emit [EffectiveDeviceStatus]
  /// from the current TCP status + UMAS session state. Idempotent —
  /// only emits when the derived value actually changes.
  ///
  /// Rules:
  ///   - Anything but `connected` on TCP → pass through.
  ///   - `connected` + umasEnabled=false → connected (UMAS not in
  ///     scope for this adapter).
  ///   - `connected` + umasEnabled=true + sessionState in {null,
  ///     uninitialized, identified} → umasUnhealthy. The non-paired
  ///     states indicate the UMAS handshake is not complete; every
  ///     read/write would either probe init (slow) or fail. The chip
  ///     should NOT render green just because TCP is up.
  ///   - `connected` + umasEnabled=true + sessionState == paired →
  ///     connected.
  void _recomputeEffectiveStatus() {
    final tcp = wrapper.connectionStatus;
    EffectiveDeviceStatus next;
    if (tcp != ConnectionStatus.connected) {
      next = _mapTcpStatus(tcp);
    } else if (!umasEnabled) {
      next = EffectiveDeviceStatus.connected;
    } else if (_lastUmasSessionState == UmasSessionState.paired) {
      next = EffectiveDeviceStatus.connected;
    } else if (_lastUmasSessionState == null) {
      // TCP just came up; UMAS hasn't attempted to pair yet. Stay
      // optimistic — render `connecting` so the chip doesn't go red
      // on every cold start before the first MonitorPlc table build.
      // _getUmasClient + the upcoming sessionStream emission will
      // resolve this to either paired (connected) or non-paired
      // (umasUnhealthy) within a round-trip.
      next = EffectiveDeviceStatus.connecting;
    } else {
      next = EffectiveDeviceStatus.umasUnhealthy;
    }
    if (_effectiveStatus$.isClosed) return;
    if (_effectiveStatus$.valueOrNull == next) return;
    _effectiveStatus$.add(next);
  }

  /// Build the MonitorPlc table from `_umasKeysByGroup` and start each
  /// group's [Timer.periodic]. Safe to call repeatedly — bails when the
  /// table is already built against the current UmasClient.
  Future<void> _buildUmasTableAndStartTimers() async {
    if (_umasTableBuildInFlight) return;
    _umasTableBuildInFlight = true;
    try {
      final umas = _getUmasClient();
      if (umas == null) return;
      if (identical(_umasTableBuiltFor, _umasClientFor)) {
        // Same client identity, table is already wired. Restart timers
        // if they're not running (e.g. after a transient stream blip
        // that didn't actually drop the socket).
        _startUmasTimers();
        return;
      }
      // Fresh client — drop any stale ordering and reset the server-side
      // table so we own the index space cleanly.
      _umasKeyOrder.clear();
      try {
        await umas.monitorReset();
      } catch (e) {
        _log.w('UMAS monitorReset before rebuild failed: $e');
        // Continue anyway — registering still allocates fresh indices on
        // the client side, and the PLC will overwrite stale entries.
      }
      // Prime project block / blockCrcs so monitorRegister succeeds.
      try {
        await umas.readPlcStatus();
      } catch (e) {
        _log.w('UMAS readPlcStatus during table build failed: $e');
        return;
      }

      // Resolve every UMAS-by-name key and build the registration list
      // in a deterministic order (groups in insertion order; keys within
      // a group in insertion order). The same ordering is mirrored in
      // [_umasKeyOrder] so `monitorReadAll` results demux correctly.
      final refs = <(UmasVariable, UmasDataTypeRef)>[];
      for (final group in _umasKeysByGroup.keys) {
        for (final key in _umasKeysByGroup[group]!) {
          final symbolPath = _variableNames[key];
          if (symbolPath == null) continue;
          try {
            final sym = await umas.lookupSymbol(symbolPath);
            if (!sym.readable) {
              _log.w('UMAS key "$key" symbol "$symbolPath" is not readable — '
                  'skipping MonitorPlc registration');
              continue;
            }
            refs.add((sym.variable, sym.dataType));
            _umasKeyOrder.add(key);
          } catch (e) {
            _log.w('UMAS lookupSymbol for "$symbolPath" (key "$key") '
                'failed: $e — skipping');
          }
        }
      }

      if (refs.isEmpty) {
        _log.i('UMAS MonitorPlc table build: no resolvable symbols');
        _umasTableBuiltFor = _umasClientFor;
        return;
      }

      // Chunk to fit the 1-byte index limit (255). Each chunk is one
      // monitorRegister TCP roundtrip; the table accumulates server-side.
      const chunkSize = 100;
      for (var i = 0; i < refs.length; i += chunkSize) {
        final chunk = refs.sublist(i, (i + chunkSize).clamp(0, refs.length));
        try {
          await umas.monitorRegister(chunk);
        } catch (e) {
          _log.w(
              'UMAS monitorRegister chunk (size=${chunk.length}) failed: $e');
          // Drop the corresponding key-order entries so demux stays aligned.
          // We registered nothing past this chunk.
          _umasKeyOrder.removeRange(i, _umasKeyOrder.length);
          break;
        }
      }
      _umasTableBuiltFor = _umasClientFor;
      _log.i('UMAS MonitorPlc table built: ${_umasKeyOrder.length} '
          'variable(s) across ${_umasKeysByGroup.length} group(s)');
      _startUmasTimers();
    } finally {
      _umasTableBuildInFlight = false;
    }
  }

  /// Start per-group poll timers. Called after [_buildUmasTableAndStartTimers]
  /// and on transient stream events. Idempotent — replaces any prior timer
  /// for a group so interval edits picked up via adapter re-creation take
  /// effect immediately.
  void _startUmasTimers() {
    for (final group in _umasPollGroups.keys) {
      _umasTimers[group]?.cancel();
      final interval = _umasPollGroups[group]!;
      _umasTimers[group] = Timer.periodic(interval, (_) {
        // Fire-and-forget; errors caught inside _pollUmasGroup.
        unawaited(_pollUmasGroup(group));
      });
    }
  }

  /// Cancel and clear all per-group poll timers.
  void _stopUmasTimers() {
    for (final t in _umasTimers.values) {
      t.cancel();
    }
    _umasTimers.clear();
  }

  /// Single poll tick for a UMAS poll group. Issues one
  /// `monitorReadAll` and demuxes the per-key values into
  /// [_umasLastValues] and [_umasSubjects].
  ///
  /// `monitorReadAll` returns values for ALL registered variables in
  /// sorted-index order — not just the calling group's keys. We could
  /// filter here, but pushing every fresh value into every subscriber's
  /// subject is exactly the semantics callers want: a fresh read on a
  /// faster group's tick benefits slower-group subscribers too. The
  /// poll-group interval only controls how often THIS group fires; it
  /// does not gate which keys receive updates.
  Future<void> _pollUmasGroup(String group) async {
    if (wrapper.connectionStatus != ConnectionStatus.connected) return;
    final umas = _getUmasClient();
    if (umas == null) return;
    if (!identical(_umasTableBuiltFor, _umasClientFor)) {
      // Client changed under us — kick off a rebuild and skip this tick.
      unawaited(_buildUmasTableAndStartTimers());
      return;
    }
    // TD-021 (v1.1.x): when MonitorPlc registration failed for this
    // adapter's keys (e.g. PLC returned 0x82 — wire-format mismatch on
    // real M580 firmware that the stub doesn't reproduce) the global
    // `_umasKeyOrder` ends up empty but `_umasKeysByGroup[group]` still
    // holds the configured keys. Without a fallback, every subscriber to
    // a UMAS-by-name key on a 0x82-rejecting PLC sees a permanently stale
    // BehaviorSubject — the home screen renders grey forever and only
    // wakes up after a Key Repository round-trip (which one-shot reads
    // each key via readUmasVariable). Mirror that recovery path here:
    // when MonitorPlc is unusable, poll the group's keys one-by-one with
    // ReadVariable (0x22). Each readUmasVariable pushes to the per-key
    // BehaviorSubject, so subscribers get live values via the same code
    // path the Key Repository probe already validates against this PLC.
    // Slower than batched MonitorPlc (N TCP RTTs vs 1 per tick) but
    // correctness > throughput; the operator's home screen updates.
    if (_umasKeyOrder.isEmpty) {
      final keys = _umasKeysByGroup[group];
      if (keys == null || keys.isEmpty) return;
      for (final key in keys) {
        try {
          wrapper.recordRequest();
          await readUmasVariable(key);
        } catch (e) {
          _log.w('UMAS fallback poll for key "$key" in group "$group" '
              'failed: $e');
          // Subjects retain their last value (SCADA semantics).
        }
      }
      return;
    }
    try {
      wrapper.recordRequest();
      final values = await umas.monitorReadAll();
      _demuxUmasReadAll(values);
    } catch (e) {
      _log.w('UMAS monitorReadAll for group "$group" failed: $e');
      // Subjects retain their last value (SCADA semantics).
    }
  }

  /// Demux a [monitorReadAll] response into the per-key subjects + cache.
  /// Assumes `values` is in the same order as [_umasKeyOrder].
  void _demuxUmasReadAll(List<TypedVariableValue> values) {
    final n = values.length < _umasKeyOrder.length
        ? values.length
        : _umasKeyOrder.length;
    for (var i = 0; i < n; i++) {
      final key = _umasKeyOrder[i];
      final dv = typedVariableToDynamicValue(values[i]);
      _umasLastValues[key] = dv;
      final subject = _umasSubjects[key];
      if (subject != null && !subject.isClosed) {
        subject.add(dv);
      }
    }
  }

  /// All keys claimed by this adapter — the union of classic-Modbus
  /// specs and UMAS-by-name keys.
  @override
  Set<String> get subscribableKeys => {
        ..._specs.keys,
        ..._variableNames.keys.where((k) => _variableNames[k] != null)
      };

  @override
  bool canSubscribe(String key) =>
      _specs.containsKey(key) || (_variableNames[key] != null);

  /// Returns the UMAS variable name for [key], or null if [key] is not
  /// routed by name.
  String? variableNameFor(String key) => _variableNames[key];

  /// Test-only access to the lazily-constructed UmasClient. Returns
  /// null before the first connect+read primes it. Used to assert
  /// internal cache state (e.g. TD-005: blockCrcs reuse).
  UmasClient? get debugUmasClient => _umasClient;

  /// True when [debugSetUmasClient] has primed the adapter with a
  /// hand-built [UmasClient]. Short-circuits [_getUmasClient] so unit
  /// tests can exercise [readUmasVariable] / [writeUmasVariable]
  /// without driving a real socket through the wrapper.
  bool _umasClientInjectedForTest = false;

  /// Test-only seam: prime the adapter's UmasClient with an externally
  /// built (and pre-primed via `debugInjectSymbol` + `debugSet*Crc` +
  /// `debugSetSessionState`) client. Bypasses [_getUmasClient]'s
  /// wrapper-connection gate so the adapter can be exercised end-to-end
  /// against a mock `sendFn` without a live PLC.
  ///
  /// Used by the FB-DynamicValue poll-loop fall-back tests
  /// (`umas_fb_dynamic_value_poll_test.dart`) to verify the adapter
  /// catches [UmasNotScalarException] and routes through
  /// [UmasClient.readFbInstanceMembers]. Production code must NOT
  /// call this — the lazy [_getUmasClient] path is the only supported
  /// runtime wiring.
  @visibleForTesting
  void debugSetUmasClient(UmasClient client) {
    _umasClient = client;
    _umasClientInjectedForTest = true;
    // Bind the injected client to the wrapper's current socket identity.
    // Without this `_umasClientFor` stays null, `_umasTableBuiltFor` is null
    // too, and the `identical(_umasTableBuiltFor, _umasClientFor)` early
    // return in [_buildUmasTableAndStartTimers] fires on the first tick — so
    // an injected client could only ever exercise the per-key fallback poll,
    // and the MonitorPlc registration + [_demuxUmasReadAll] path (the primary
    // data path on M580) was unreachable from any test.
    _umasClientFor = wrapper.client;
  }

  /// @visibleForTesting (Phase 7): read-only view of the per-group key
  /// registration. Tests assert membership mutations after [addUmasKey]
  /// (Plan 02 will add [removeUmasKey]) without touching private fields.
  @visibleForTesting
  Map<String, List<String>> get debugUmasKeysByGroup => UnmodifiableMapView(
        _umasKeysByGroup
            .map((g, ks) => MapEntry(g, List<String>.unmodifiable(ks))),
      );

  /// @visibleForTesting (Phase 7): current "table is built for which
  /// ModbusClientTcp identity" flag. Null after [addUmasKey] until the
  /// next [_pollUmasGroup] tick rebuilds the table.
  @visibleForTesting
  ModbusClientTcp? get debugUmasTableBuiltFor => _umasTableBuiltFor;

  /// @visibleForTesting (Phase 7): override the retained per-key
  /// poll-group mapping for [key]. Used by tests that exercise the
  /// "wanted group has no timer → fall back to default + warn" branch
  /// of [addUmasKey] without rebuilding the whole adapter. Production
  /// callers MUST NOT call this; the poll-group is part of the immutable
  /// KeyMapping contract.
  @visibleForTesting
  void debugSetUmasPollGroupForKey(String key, String group) {
    _umasPollGroupByKey[key] = group;
  }

  /// @visibleForTesting (Phase 7 / SPEC Acceptance #2): drive one
  /// synthetic poll tick for [group] so tests can assert that
  /// [addUmasKey] actually causes the next tick to pick up the new key.
  /// Delegates directly to the private [_pollUmasGroup] method. Caller
  /// is expected to have already injected a fake UmasClient via
  /// [debugSetUmasClient] (line 599) so the resulting reads / register
  /// calls land on a recorder rather than a real socket. Production
  /// callers MUST NOT use this; the real driver is [_startUmasTimers].
  @visibleForTesting
  Future<void> debugPumpPollTick(String group) => _pollUmasGroup(group);

  /// Public accessor that returns the adapter's shared [UmasClient],
  /// lazy-initializing it against the current TCP socket if the wrapper
  /// is connected. Returns null when the wrapper has no live socket yet.
  ///
  /// UI features that need ad-hoc UMAS access (e.g. the Browse dialog's
  /// FB-instance inspection-layer fan-out read) MUST go through this
  /// accessor rather than instantiate their own `UmasClient(sendFn: ...)`
  /// against the raw `tcpClient.send`. A duplicate client would share
  /// the TCP socket with the adapter's poll-loop client but maintain a
  /// SEPARATE UMAS session (pairing key, hardware id, symbol cache),
  /// and the PLC only supports one paired UMAS session per TCP
  /// connection — the second `pair()` invalidates the first, the next
  /// poll-loop read trips `_handleSessionError`, both clients fight to
  /// re-pair, and the symbol cache rebuild storm freezes the UI.
  ///
  /// See debug session `umas-fb-freeze-loop` (2026-05-19) for the
  /// reproduction that motivated promoting this accessor.
  UmasClient? get umasClient => _getUmasClient();

  /// Phase 7 / SPEC Req #1 (v1.1.x): register a UMAS-by-name [key] for
  /// live MonitorPlc polling AFTER construction. Resolves the poll-group
  /// via the retained [_umasPollGroupByKey] map (or `'default'` when
  /// absent), appends [key] to [_umasKeysByGroup] for that group, and
  /// nulls [_umasTableBuiltFor] so the next [_pollUmasGroup] tick
  /// rebuilds the MonitorPlc table.
  ///
  /// Silent no-op when:
  ///   * [key] is unknown to [_variableNames] or [_variableNames[key]]
  ///     is null (classic Modbus key — UMAS poll set is not the right
  ///     venue).
  ///   * [key] is already present in any [_umasKeysByGroup] list (D-05
  ///     — matches `Set.add` ergonomics).
  ///
  /// When the resolved poll-group has no entry in [_umasPollGroups]
  /// (i.e. no timer would ever fire for it), falls back to `'default'`
  /// AND emits a warn log per D-04.
  ///
  /// W3 (defensive): the no-timer-fallback branch is only reachable
  /// through the [debugSetUmasPollGroupForKey] @visibleForTesting seam
  /// on the public-API path — `_initUmasPollGroups`' `putIfAbsent` (see
  /// modbus_device_client.dart constructor) already seeds a
  /// [_umasPollGroups] entry for every group named in the original
  /// `umasPollGroupByKey`. Kept for defensive symmetry; documented here
  /// so a future cleanup does not delete it as dead code.
  ///
  /// TD-009 / TD-021 / TD-022 are NOT touched (D-10): this method does
  /// not read or write [_useMonitorPlc], the eager-read on [subscribe],
  /// or the MonitorPlc degraded breaker.
  void addUmasKey(String key) {
    if (_variableNames[key] == null) return; // not a UMAS-by-name key
    // Linear scan per D-03 — N is small; no reverse index needed.
    for (final keys in _umasKeysByGroup.values) {
      if (keys.contains(key)) return; // D-05 idempotency
    }
    var group = _umasPollGroupByKey[key] ?? 'default';
    if (!_umasPollGroups.containsKey(group)) {
      final configured = _configuredGroupIntervals[group];
      if (configured != null) {
        // The group exists in the server config but had no members at
        // adapter construction — activate it at its configured cadence
        // so a runtime-added key polls at the interval the operator set.
        _umasPollGroups[group] = configured;
      } else {
        _log.w('UMAS addUmasKey: key "$key" wanted group "$group" but no '
            'timer exists; falling back to default');
        group = 'default';
        // Make sure 'default' has at least the canonical interval so any
        // future _startUmasTimers run schedules a tick for it.
        _umasPollGroups.putIfAbsent('default', () => _defaultPollInterval);
      }
    }
    _umasKeysByGroup.putIfAbsent(group, () => <String>[]).add(key);
    _umasTableBuiltFor = null;
    _log.i('UMAS addUmasKey: registered "$key" in group "$group"');
  }

  /// Phase 7 / SPEC Req #3 (v1.1.x): drop a UMAS-by-name [key] from the
  /// live poll set.
  ///
  /// State changes (in order, per D-08):
  ///   1. Close the cached [BehaviorSubject] (if any) and remove it from
  ///      [_umasSubjects] so any active subscriber sees `onDone` exactly
  ///      once (clean closure) rather than the subject staying open and
  ///      never updating.
  ///   2. Drop the cached typed last-value in [_umasLastValues] so a
  ///      future [subscribe] re-runs the TD-021 seed path against a
  ///      fresh symbol read (SPEC Constraints §"Symbol/cache
  ///      invalidation contract").
  ///   3. Remove [key] from every [_umasKeysByGroup] group's key list.
  ///   4. Remove [key] from [_umasKeyOrder] (the registered-this-cycle
  ///      sequence).
  ///   5. Null [_umasTableBuiltFor] so the next [_pollUmasGroup] tick
  ///      triggers [_buildUmasTableAndStartTimers] and re-registers
  ///      the MonitorPlc table without the dropped entry.
  ///
  /// Silent no-op when [key] is not in any [_umasKeysByGroup] list AND
  /// not in [_umasSubjects] (D-05 idempotency — matches `Set.remove`
  /// ergonomics: no log, no `_umasTableBuiltFor` mutation).
  ///
  /// W4 / Option B2: kept as a separate sibling method from the
  /// pre-existing [unsubscribeUmas]. [unsubscribeUmas] remains the
  /// TD-003 [updateVariableNames] caller with its (no-log) behavior so
  /// operators do not see new INFO log noise from the existing key-edit
  /// path. Collapsing the two methods (Option B1) is a possible
  /// follow-up cleanup only — see 07-02-PLAN.md Step B for the
  /// equivalence-test requirement that consolidation would need.
  ///
  /// TD-009 / TD-021 / TD-022 are NOT touched (D-10): this method does
  /// not read or write [_useMonitorPlc], the eager-read on [subscribe],
  /// or the MonitorPlc degraded breaker.
  void removeUmasKey(String key) {
    // Idempotency probe: was this key ever registered? (D-05)
    var wasRegistered = false;
    for (final keys in _umasKeysByGroup.values) {
      if (keys.contains(key)) {
        wasRegistered = true;
        break;
      }
    }
    if (!wasRegistered && !_umasSubjects.containsKey(key)) return;

    // D-08: close the subject BEFORE removing the map entry so any
    // active subscriber sees onDone exactly once (clean closure).
    final subject = _umasSubjects[key];
    if (subject != null && !subject.isClosed) {
      subject.close();
    }
    _umasSubjects.remove(key);
    _umasLastValues.remove(key);
    String? droppedFrom;
    for (final entry in _umasKeysByGroup.entries) {
      if (entry.value.remove(key)) {
        droppedFrom = entry.key;
        // Continue: defensive — duplicate-add is already guarded by
        // addUmasKey, but the linear scan handles legacy callers that
        // may have populated the same key into multiple groups.
      }
    }
    _umasKeyOrder.remove(key);
    _umasTableBuiltFor = null;
    _log.i('UMAS removeUmasKey: dropped "$key"'
        '${droppedFrom != null ? ' from group "$droppedFrom"' : ''}');
  }

  /// TD-003 (v1.1.x): release every per-key resource the adapter
  /// allocates for a UMAS-by-name [key]. Called from
  /// [updateVariableNames] when the operator removes or renames a
  /// key; also exposed for direct callers that need to drop a key
  /// (e.g. UI tear-down paths).
  ///
  /// Closes and removes the long-lived BehaviorSubject, drops the
  /// cached typed value, evicts the key from poll-group ordering,
  /// and dirties the MonitorPlc table so it re-registers without
  /// the stale entry on the next (re)connect.
  ///
  /// No-op when [key] is unknown.
  void unsubscribeUmas(String key) {
    final subject = _umasSubjects.remove(key);
    if (subject != null && !subject.isClosed) {
      subject.close();
    }
    _umasLastValues.remove(key);
    // Drop from group ordering. The order list is rebuilt on the next
    // table build, but defensive removal here keeps the cached state
    // consistent even when no rebuild happens (e.g. UMAS disabled).
    for (final keys in _umasKeysByGroup.values) {
      keys.remove(key);
    }
    // Removing from _umasKeyOrder here would desynchronise it from the PLC's
    // registration, and _demuxUmasReadAll pairs the two BY POSITION — a
    // shifted response would silently show every later key its neighbour's
    // tag. What makes it safe is that _pollUmasGroup re-checks
    // `_umasTableBuiltFor` on EVERY tick, so the tick after this rebuilds and
    // re-registers instead of reading; no shifted response is ever demuxed.
    // (An older comment here claimed the order list was left unchanged. It is
    // not — the line below changes it. The dirty flag is the real guard.)
    // Pinned by test/core/umas_demux_ordering_test.dart.
    _umasKeyOrder.remove(key);
    _umasTableBuiltFor = null;
  }

  /// TD-003 (v1.1.x): refresh `_variableNames` after a KeyMappings edit
  /// and tear down per-key state for any key that was removed or had
  /// its [variableName] changed.
  ///
  /// Without this hook, `StateMan.updateKeyMappings` would only swap
  /// the top-level KeyMappings reference and the adapter would
  /// permanently leak the BehaviorSubject + last-value entry for every
  /// deleted UMAS-by-name key. On a long-running HMI where operators
  /// iterate key configs, the leak is unbounded.
  ///
  /// New mappings are merged in place — adds and updates are absorbed;
  /// removals trigger [unsubscribeUmas].
  ///
  /// [umasPollGroupByKey] (optional) refreshes the per-key poll-group
  /// mapping alongside the names, so a key added at runtime lands in the
  /// poll group the operator configured rather than 'default'. Keys
  /// already registered in a group keep their membership — the mapping is
  /// only consulted by [addUmasKey] at registration time.
  void updateVariableNames(Map<String, String?> newVariableNames,
      {Map<String, String>? umasPollGroupByKey}) {
    if (umasPollGroupByKey != null) {
      _umasPollGroupByKey
        ..clear()
        ..addAll(umasPollGroupByKey);
    }
    // Find removed keys (in old, missing from new or now null).
    final removed = <String>[];
    for (final key in _variableNames.keys) {
      final oldName = _variableNames[key];
      if (oldName == null) continue; // wasn't UMAS-by-name to begin with
      final newName = newVariableNames[key];
      if (newName == null || newName != oldName) {
        // Renamed or removed — drop the cached subject so a fresh
        // subscription against the new symbol path starts clean.
        removed.add(key);
      }
    }
    for (final key in removed) {
      unsubscribeUmas(key);
    }
    // Swap the variableNames map. Adds are absorbed automatically —
    // a fresh [subscribe] call will materialize a new subject on first
    // use via [_umasSubjectFor].
    _variableNames = Map.of(newVariableNames);
  }

  /// Get or lazily construct a UmasClient bound to the wrapper's current
  /// TCP client. Returns null if the wrapper is disconnected (no
  /// underlying ModbusClientTcp yet).
  UmasClient? _getUmasClient() {
    // Test seam — when [debugSetUmasClient] has primed an injected
    // client, return it unconditionally regardless of wrapper state.
    // The injected client owns its own (mock) sendFn and session state.
    if (_umasClientInjectedForTest) {
      return _umasClient;
    }
    final tcp = wrapper.client;
    if (tcp == null) {
      // Connection torn down — drop the stale client so the next
      // successful reconnect rebuilds it against the fresh socket.
      // TD-009: capture the M580-detected bit before disposing.
      if (_umasClient != null && _umasClient!.useMonitorPlc) {
        _useMonitorPlc = true;
      }
      _umasProjectCrcSub?.cancel();
      _umasProjectCrcSub = null;
      _umasSessionSub?.cancel();
      _umasSessionSub = null;
      _lastUmasSessionState = null;
      _umasClient?.dispose();
      _umasClient = null;
      _umasClientFor = null;
      return null;
    }
    if (_umasClient != null && identical(_umasClientFor, tcp)) {
      return _umasClient;
    }
    // TD-009 (v1.1.x): capture the sticky M580-detected bit from the
    // outgoing client before disposing so the next reconnect doesn't
    // re-probe via 0x22.
    if (_umasClient != null && _umasClient!.useMonitorPlc) {
      _useMonitorPlc = true;
    }
    _umasProjectCrcSub?.cancel();
    _umasProjectCrcSub = null;
    _umasSessionSub?.cancel();
    _umasSessionSub = null;
    _lastUmasSessionState = null;
    _umasClient?.dispose();
    _umasClient = UmasClient(
      sendFn: tcp.send,
      unitId: wrapper.unitId,
      useMonitorPlc: _useMonitorPlc,
      // Re-supplied on every rebuild: the client is recreated on each
      // reconnect and the encoding is a property of the device, so a decoder
      // wired only into the first session would produce mojibake after the
      // first cable pull and nowhere else.
      decodeString: decodeString,
    );
    _umasClientFor = tcp;
    // F-8 / TD-011: when the UMAS-side CRC watch detects a project
    // change, the symbol cache is already cleared by the time this
    // emit lands. Force a MonitorPlc table rebuild on the next tick so
    // the registered `(blockNo, offset)` pairs are re-resolved against
    // the new project — block numbers may have moved.
    _umasProjectCrcSub = _umasClient!.projectCrcChanges.listen((_) {
      _log.i('UMAS project CRC changed — rebuilding MonitorPlc table');
      _umasTableBuiltFor = null;
      _umasKeyOrder.clear();
      unawaited(_buildUmasTableAndStartTimers());
    });
    // TD-004 (v1.1.x): forward UMAS session-state transitions into
    // the derived effective-status stream. `sessionStream` is seeded
    // with the current state so first listen lands an event
    // immediately — paired here means handshake completed; any other
    // value means TCP is up but UMAS is NOT healthy and the chip
    // should reflect that with `umasUnhealthy`.
    _umasSessionSub = _umasClient!.sessionStream.listen((state) {
      _lastUmasSessionState = state;
      _recomputeEffectiveStatus();
    });
    return _umasClient;
  }

  @override
  Stream<DynamicValue> subscribe(String key) {
    // UMAS-by-name routing (F-1): return a long-lived BehaviorSubject
    // per key so subscribers don't see `onDone` after a single emit.
    // The subject is seeded with the most-recent cached value (if any)
    // and stays open for the adapter's lifetime. Every successful
    // [readUmasVariable] pushes the fresh DynamicValue. MonitorPlc-
    // driven streaming polling is a v1.2 follow-up; see B-4 TODO at
    // the bottom of this file.
    final variableName = _variableNames[key];
    if (variableName != null) {
      final subject = _umasSubjectFor(key);
      // Phase 7 / SPEC Req #2 (v1.1.x): auto-register this key for live
      // MonitorPlc polling if it isn't already in the poll set. Without
      // this, a UMAS-by-name key bound after adapter construction (e.g.
      // via Key Repository or a fresh page asset) gets the TD-021 eager
      // seed below but never receives subsequent updates — the home
      // screen widget renders the seed value forever.
      //
      // addUmasKey is idempotent (D-05): if `key` is already in any
      // _umasKeysByGroup[*] list (e.g. it was registered at construction
      // or via an earlier subscribe), this call is a silent no-op.
      // We call it unconditionally rather than precheck because the
      // membership probe is identical inside addUmasKey itself; saves
      // a duplicate linear scan (per D-03 the planner-suggested shape
      // was an explicit precheck — equivalent behavior, less code).
      addUmasKey(key);

      // TD-021 (v1.1.x): subscribers should see a live value within ~1
      // poll-cycle of mounting, not "stale until somebody else triggers
      // a read". When MonitorPlc registration succeeded the next tick of
      // the group timer fills the subject; when MonitorPlc failed (0x82
      // on real M580) the fallback in [_pollUmasGroup] does the same.
      // Either way, the FIRST emission can lag a full poll interval —
      // and operators perceive the home-screen sensor as broken during
      // that window. Kick off a one-shot read here so the subject has a
      // value ASAP without waiting for the timer.
      //
      // Fire-and-forget: readUmasVariable handles its own errors (logs
      // + leaves subject seeded with cached or empty); we just need the
      // round-trip to start. Skip if there's already a cached value
      // (subject is already seeded) to avoid hammering the PLC on every
      // route change.
      if (umasEnabled && _umasLastValues[key] == null) {
        unawaited(readUmasVariable(key).then<void>((_) {}).catchError(
          (Object e) {
            _log.w('UMAS eager subscribe-read for "$key" failed: $e');
          },
        ));
      }
      return subject.stream;
    }
    final spec = _specs[key];
    if (spec == null) throw ArgumentError('Unknown Modbus key: $key');
    // subscribeSamples, not subscribe: [ModbusSample] is the seam that keeps
    // the read instant available to callers who want the fact, even though no
    // instant enters the value — see [_toDynamicValue] for why it may not.
    return wrapper
        .subscribeSamples(spec)
        .map((s) => _toDynamicValue(s.value, spec));
  }

  /// Get-or-create the long-lived [BehaviorSubject] for a UMAS-by-name
  /// [key]. Seeded with the cached last value when present (so a fresh
  /// subscriber sees the most-recent typed read), otherwise unseeded.
  /// Reused across subscribe/unsubscribe cycles for the same key.
  BehaviorSubject<DynamicValue> _umasSubjectFor(String key) {
    final existing = _umasSubjects[key];
    if (existing != null && !existing.isClosed) return existing;
    final cached = _umasLastValues[key];
    final subject = cached != null
        ? BehaviorSubject<DynamicValue>.seeded(cached)
        : BehaviorSubject<DynamicValue>();
    _umasSubjects[key] = subject;
    return subject;
  }

  @override
  DynamicValue? read(String key) {
    final variableName = _variableNames[key];
    if (variableName != null) {
      // Synchronous reads return the last cached typed value; live
      // reads happen via [readUmasVariable] (await). The async fetch
      // is wired from StateMan.read() which already awaits and so can
      // call the typed path; this synchronous fallback exists for
      // [readMany] which only consults the cache.
      return _umasLastValues[key];
    }
    final spec = _specs[key];
    if (spec == null) return null;
    final sample = wrapper.readSample(key);
    if (sample == null || sample.value == null) return null;
    return _toDynamicValue(sample.value, spec);
  }

  /// Read a single UMAS-by-name key. Throws [StateError] if [key] is
  /// not routed by name. Throws [UmasException] when the server has
  /// `umasEnabled == false` (B-1 contract) or when the underlying
  /// PLC read fails. Caches the typed result for the next [read].
  Future<DynamicValue> readUmasVariable(String key) async {
    final variableName = _variableNames[key];
    if (variableName == null) {
      throw StateError('readUmasVariable: key "$key" is not UMAS-by-name');
    }
    if (!umasEnabled) {
      throw UmasException(
        errorCode: 0,
        message: "Server '${serverAlias ?? '<unknown>'}' does not have UMAS "
            "enabled — variable name '$variableName' cannot be read",
      );
    }
    final umas = _getUmasClient();
    if (umas == null) {
      throw StateError(
          'readUmasVariable: server "${serverAlias ?? '<unknown>'}" not connected');
    }
    // TD-005 (v1.1.x): only prime blockCrcs on the FIRST call after a
    // session (re)establish. The periodic project-CRC watch (F-8) already
    // invalidates the symbol cache + MonitorPlc table when the CRC moves,
    // so the eager pre-call `readPlcStatus()` was adding one extra TCP
    // round-trip per read with no incremental safety. With 30 UMAS keys
    // polled at 1Hz that's 30 wasted RTTs/sec.
    if (umas.blockCrcs == null) {
      await umas.readPlcStatus();
    }
    DynamicValue dv;
    try {
      final typed = await umas.readVariableByName(variableName);
      dv = typedVariableToDynamicValue(typed);
    } on UmasNotScalarException {
      // FB-instance binding: the operator (or LLM-generated key
      // mapping) pointed a single key at an FB instance root rather
      // than a scalar member. Fall back to a batched fan-out read so
      // the subject emits a struct DynamicValue (`{member: value}`)
      // that the FB-DynamicValue widget / Conveyor FB asset render
      // directly — matching the OPC-UA struct-value contract.
      //
      // Pre-fix this throw bubbled out of every poll tick as
      // "UMAS fallback poll for key … failed: UmasNotScalarException".
      // See commit 8c03c68d for the exception's introduction and the
      // umas-fb-dynamic-value branch for this fall-back's rationale.
      final members = await umas.readFbInstanceMembers(variableName);
      dv = fbMembersToDynamicValue(members);
    }
    _umasLastValues[key] = dv;
    // F-1: push the fresh value to any active subscribers so
    // StreamBuilder / StreamProvider keep updating across reads. Only
    // forward when a subject already exists — don't materialize one on
    // every read.
    final subject = _umasSubjects[key];
    if (subject != null && !subject.isClosed) {
      subject.add(dv);
    }
    return dv;
  }

  /// Build a struct [DynamicValue] from a flat `{memberSubPath: TypedVariableValue}`
  /// map returned by [UmasClient.readFbInstanceMembers].
  ///
  /// The result mirrors the shape an OPC-UA struct read produces:
  /// `value` is a [LinkedHashMap<String, DynamicValue>] so
  /// `DynamicValue.isObject` returns `true` and `asObject` exposes the
  /// member map. Each leaf carries the correct [NodeId] typeId so
  /// `asBool` / `asDouble` / `asInt` on the leaves preserves UMAS
  /// type semantics.
  ///
  /// Nested-FB members appear as dotted keys (e.g.
  /// `HMI.p_Stat_xRunningFwd`) rather than nested sub-maps. The
  /// existing FB-DynamicValue consumers (`Conveyor FB`,
  /// `StartStopButton`) use `fb[memberName]` lookups against the
  /// flat string-keyed map; keeping the keys dotted matches that
  /// contract without a second-level walk.
  ///
  /// No read instant is stamped on the parent or on any member — see
  /// [_toDynamicValue] for the whole argument.
  @visibleForTesting
  static DynamicValue fbMembersToDynamicValue(
      Map<String, TypedVariableValue> members) {
    final map = LinkedHashMap<String, DynamicValue>();
    for (final entry in members.entries) {
      map[entry.key] = typedVariableToDynamicValue(entry.value);
    }
    return DynamicValue(value: map);
  }

  /// Write a single UMAS-by-name key. Same UX contract as
  /// [readUmasVariable]: throws [UmasException] when the server has
  /// `umasEnabled == false`, [StateError] when the key is not routed by
  /// name or when the server is disconnected.
  Future<void> writeUmasVariable(String key, DynamicValue value) async {
    final variableName = _variableNames[key];
    if (variableName == null) {
      throw StateError('writeUmasVariable: key "$key" is not UMAS-by-name');
    }
    if (!umasEnabled) {
      throw UmasException(
        errorCode: 0,
        message: "Server '${serverAlias ?? '<unknown>'}' does not have UMAS "
            "enabled — variable name '$variableName' cannot be written",
      );
    }
    final umas = _getUmasClient();
    if (umas == null) {
      throw StateError(
          'writeUmasVariable: server "${serverAlias ?? '<unknown>'}" not connected');
    }
    // TD-005 (v1.1.x): mirror the read path — only prime blockCrcs on
    // the first call. F-8's periodic project-CRC watch handles cache
    // invalidation between writes.
    if (umas.blockCrcs == null) {
      await umas.readPlcStatus();
    }
    // Encode via the resolved symbol so the byte layout matches the
    // PLC's declared type. `writeVariableByName` runs the encode via
    // `VariableWriteRef.fromVariable` -> `encodeVariableValue`.
    await umas.writeVariableByName(variableName, value.value);
  }

  /// Convert a TypedVariableValue from UMAS to a DynamicValue with the
  /// correct [NodeId] type id. Best-effort mapping — STRING / BYTE
  /// strings preserve their parsed Dart value. Unknown UMAS type names
  /// fall back to `NodeId.byte` because [DynamicValue] requires a
  /// non-null typeId; the raw value stays untouched so the consumer
  /// can still inspect it.
  ///
  /// No source timestamp is stamped: UMAS carries no device instant, and a
  /// clock on this host in that field is read downstream as a plant instant.
  /// See [_toDynamicValue].
  @visibleForTesting
  static DynamicValue typedVariableToDynamicValue(TypedVariableValue t) {
    final upper = t.typeName.toUpperCase();
    final typeId = switch (upper) {
      'BOOL' || 'EBOOL' => NodeId.boolean,
      'INT' => NodeId.int16,
      'UINT' || 'WORD' => NodeId.uint16,
      'DINT' || 'TIME' => NodeId.int32,
      'UDINT' || 'DWORD' => NodeId.uint32,
      'REAL' => NodeId.float,
      'LREAL' => NodeId.double,
      'LINT' => NodeId.int64,
      'ULINT' => NodeId.uint64,
      'BYTE' => NodeId.byte,
      'STRING' || 'WSTRING' || 'BYTE_STRING' => NodeId.uastring,
      _ => NodeId.byte,
    };
    return DynamicValue(value: t.value, typeId: typeId);
  }

  @override
  Future<void> write(String key, DynamicValue value) async {
    // UMAS-by-name routing takes precedence.
    if (_variableNames[key] != null) {
      await writeUmasVariable(key, value);
      return;
    }
    final spec = _specs[key];
    if (spec == null) throw ArgumentError('Unknown Modbus key: $key');

    if (spec.bitMask != null) {
      // Read-modify-write: preserve unmasked bits.
      // Note: reads the last-polled cached value, not a fresh device read.
      // A concurrent write between the last poll and this write could be
      // overwritten. Modbus has no atomic bit-set instruction, so this is
      // inherent to the protocol. The race window is bounded by poll interval.
      final current = wrapper.read(key);
      final currentInt = (current is num) ? current.toInt() : 0;
      final shift = spec.bitShift ?? 0;
      final isSingle =
          spec.bitMask! != 0 && (spec.bitMask! & (spec.bitMask! - 1)) == 0;
      int newValue;
      if (isSingle) {
        final boolVal = value.value == true || value.value == 1;
        if (boolVal) {
          newValue = currentInt | spec.bitMask!;
        } else {
          newValue = currentInt & ~spec.bitMask!;
        }
      } else {
        final writeInt =
            (value.value is num) ? (value.value as num).toInt() : 0;
        newValue = (currentInt & ~spec.bitMask!) |
            ((writeInt << shift) & spec.bitMask!);
      }
      await wrapper.write(spec, newValue);
    } else {
      await wrapper.write(spec, value.value);
    }
  }

  @override
  ConnectionStatus get connectionStatus => wrapper.connectionStatus;

  @override
  Stream<ConnectionStatus> get connectionStream => wrapper.connectionStream;

  /// TD-004 (v1.1.x): the combined TCP + UMAS health status. UI chip
  /// should prefer this over the raw [connectionStatus] when the
  /// server has `umasEnabled == true`, otherwise a PLC with Data
  /// Dictionary disabled renders as green "Connected" while every
  /// UMAS key card shows a red error badge.
  EffectiveDeviceStatus get effectiveStatus =>
      _effectiveStatus$.valueOrNull ?? _mapTcpStatus(wrapper.connectionStatus);

  /// TD-004 (v1.1.x): broadcast stream of [EffectiveDeviceStatus]
  /// changes. Seeded with the current value via [BehaviorSubject].
  Stream<EffectiveDeviceStatus> get effectiveStatusStream =>
      _effectiveStatus$.stream;

  @override
  void connect() => wrapper.connect();

  @override
  void dispose() {
    _stopUmasTimers();
    _umasConnectionSub?.cancel();
    _umasConnectionSub = null;
    _umasProjectCrcSub?.cancel();
    _umasProjectCrcSub = null;
    _umasSessionSub?.cancel();
    _umasSessionSub = null;
    _effectiveStatusSub?.cancel();
    _effectiveStatusSub = null;
    if (!_effectiveStatus$.isClosed) {
      _effectiveStatus$.close();
    }
    _umasClient?.dispose();
    _umasClient = null;
    _umasClientFor = null;
    _umasTableBuiltFor = null;
    _umasKeyOrder.clear();
    // F-1: close every long-lived UMAS-by-name subject so subscribers
    // see `onDone` exactly once at adapter teardown rather than after
    // a single read.
    for (final subject in _umasSubjects.values) {
      if (!subject.isClosed) subject.close();
    }
    _umasSubjects.clear();
    wrapper.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Wraps a raw Modbus value in a [DynamicValue] with the correct [typeId]
  /// derived from the register spec's declared data type and applies optional
  /// bit masking.
  ///
  /// **Modbus offers no `sourceTimestamp`, and that is the honest answer.**
  /// Nothing in the protocol says when the PLC produced the number. The read
  /// instant — when this driver's round trip completed — is a clock on *this
  /// host*, and `package:open62541` documents the field it would go in as *"the
  /// instant the SOURCE (the PLC, not this process) says the value was
  /// produced"*, with null meaning *"a consumer that needs an instant must
  /// substitute its own arrival time knowingly, and record that it did"*.
  ///
  /// It was briefly stamped here (2026-09-07, morning) and the measured result
  /// was that `alarm_history.ts_source` then said `plant` over a backend clock
  /// for the whole Modbus fleet — in direct mode as well as through the pipe,
  /// because `AlarmMan.onChange` reads this field straight off the value. A
  /// bare `DateTime` has no room to say which clock it came from, so the only
  /// way to stop the claim being made is not to make it. No converter takes
  /// the instant at all now; [ModbusSample] remains the seam that exposes the
  /// read instant to callers who want the fact.
  ///
  /// `applyBitMask` carries `statusCode` and `sourceTimestamp` across the fresh
  /// [DynamicValue] it builds. That stays load-bearing for masked **OPC UA**
  /// keys, which do have a real server stamp to lose; here there is nothing for
  /// it to carry.
  static DynamicValue _toDynamicValue(Object? value, ModbusRegisterSpec spec) {
    final dv =
        DynamicValue(value: value, typeId: _typeIdFromDataType(spec.dataType));
    return StateMan.applyBitMask(dv, spec.bitMask, spec.bitShift);
  }

  /// Maps [ModbusDataType] to the corresponding OPC UA [NodeId] type identifier.
  static NodeId _typeIdFromDataType(ModbusDataType dataType) {
    switch (dataType) {
      case ModbusDataType.bit:
        return NodeId.boolean;
      case ModbusDataType.int16:
        return NodeId.int16;
      case ModbusDataType.uint16:
        return NodeId.uint16;
      case ModbusDataType.int32:
        return NodeId.int32;
      case ModbusDataType.uint32:
        return NodeId.uint32;
      case ModbusDataType.float32:
        return NodeId.float;
      case ModbusDataType.int64:
        return NodeId.int64;
      case ModbusDataType.uint64:
        return NodeId.uint64;
      case ModbusDataType.float64:
        return NodeId.double;
    }
  }
}

// ---------------------------------------------------------------------------
// Config-to-spec helpers (Phase 9)
// ---------------------------------------------------------------------------

/// Converts [KeyMappings] entries with a [ModbusNodeConfig] into a map of
/// [ModbusRegisterSpec] instances, filtered by [serverAlias].
///
/// Entries without a `modbusNode`, or whose `modbusNode.serverAlias` does not
/// match [serverAlias], are skipped.
///
/// The [endianness] parameter is the per-device byte order from
/// [ModbusConfig.endianness]. All specs for a given device share the same
/// endianness since byte order is a device-level property.
Map<String, ModbusRegisterSpec> buildSpecsFromKeyMappings(
  KeyMappings keyMappings,
  String? serverAlias, {
  ModbusEndianness endianness = ModbusEndianness.ABCD,
  int addressBase = 0,
}) {
  final specs = <String, ModbusRegisterSpec>{};
  for (final entry in keyMappings.nodes.entries) {
    final modbusNode = entry.value.modbusNode;
    if (modbusNode == null) continue;
    if (modbusNode.serverAlias != serverAlias) continue;
    // UMAS-by-name keys still carry a modbusNode for serverAlias/registerType
    // metadata but route through the symbol cache at runtime — the
    // ModbusRegisterSpec is built defensively so a misconfigured key
    // (umasEnabled flipped off post-pick) still has an address-space
    // fallback, but adapter routing prefers the variableName path.
    specs[entry.key] = ModbusRegisterSpec(
      key: entry.key,
      registerType: modbusNode.registerType.toModbusElementType(),
      address: modbusNode.address,
      dataType: modbusNode.dataType,
      pollGroup: modbusNode.pollGroup,
      endianness: endianness,
      addressBase: addressBase,
      bitMask: entry.value.bitMask,
      bitShift: entry.value.bitShift,
    );
  }
  return specs;
}

/// Extract `KeyMappingEntry.variableName` for every entry whose
/// `modbusNode.serverAlias` matches [serverAlias]. Returns a map of
/// `key → variableName` (only entries with a non-null variableName are
/// present). Used by [ModbusDeviceClientAdapter] to route reads/writes
/// by name when the server has UMAS enabled.
Map<String, String> buildVariableNamesFromKeyMappings(
  KeyMappings keyMappings,
  String? serverAlias,
) {
  final out = <String, String>{};
  for (final entry in keyMappings.nodes.entries) {
    final modbusNode = entry.value.modbusNode;
    if (modbusNode == null) continue;
    if (modbusNode.serverAlias != serverAlias) continue;
    final vn = entry.value.variableName;
    if (vn != null && vn.isNotEmpty) out[entry.key] = vn;
  }
  return out;
}

/// Extract `KeyMappingEntry.modbusNode.pollGroup` for every UMAS-by-name
/// key whose server alias matches [serverAlias]. Used by
/// [ModbusDeviceClientAdapter]'s B-4 batched MonitorPlc poll loop to
/// place each key into its configured group cadence.
Map<String, String> buildUmasPollGroupsFromKeyMappings(
  KeyMappings keyMappings,
  String? serverAlias,
) {
  final out = <String, String>{};
  for (final entry in keyMappings.nodes.entries) {
    final modbusNode = entry.value.modbusNode;
    if (modbusNode == null) continue;
    if (modbusNode.serverAlias != serverAlias) continue;
    final vn = entry.value.variableName;
    if (vn == null || vn.isEmpty) continue;
    out[entry.key] = modbusNode.pollGroup;
  }
  return out;
}

/// Builds Modbus [DeviceClient] instances from config and key mappings.
///
/// For each [ModbusConfig], translates key mappings into [ModbusRegisterSpec]s
/// via [buildSpecsFromKeyMappings], pre-configures poll groups from
/// [ModbusConfig.pollGroups], and creates the adapter.
///
/// This is the primary entry point for both data_acquisition_isolate and
/// the Flutter UI provider.
///
/// Servers with `enabled == false` are skipped entirely — no wrapper, no
/// poll timers, no per-cycle read failures in the log while the PLC is down.
/// [decodeStringFor] supplies the per-server string decoder, by alias.
///
/// Null — the default — reproduces exactly what this factory did before it
/// existed. It takes a function rather than a decoder because one call builds
/// every configured server and each may speak a different encoding: one
/// Latin-1 weigher does not make the TwinCAT PLC beside it Latin-1.
List<DeviceClient> buildModbusDeviceClients(
  List<ModbusConfig> modbusConfigs,
  KeyMappings keyMappings, {
  UmasStringDecoder? Function(String? serverAlias)? decodeStringFor,
}) {
  return modbusConfigs.where((config) => config.enabled).map((config) {
    final specs = buildSpecsFromKeyMappings(
      keyMappings,
      config.serverAlias,
      endianness: config.endianness,
      addressBase: config.addressBase,
    );
    final variableNames =
        buildVariableNamesFromKeyMappings(keyMappings, config.serverAlias);
    final umasPollGroups =
        buildUmasPollGroupsFromKeyMappings(keyMappings, config.serverAlias);
    final wrapper = ModbusClientWrapper(
      config.host,
      config.port,
      config.unitId,
    );
    // Pre-configure poll groups from config BEFORE adapter creation
    for (final pg in config.pollGroups) {
      wrapper.addPollGroup(pg.name, pg.interval);
    }
    return ModbusDeviceClientAdapter(
      wrapper,
      specs: specs,
      serverAlias: config.serverAlias,
      variableNames: variableNames,
      umasEnabled: config.umasEnabled,
      decodeString: decodeStringFor?.call(config.serverAlias),
      umasPollGroupByKey: umasPollGroups,
      pollGroups: config.pollGroups,
    );
  }).toList();
}

// B-4 (v1.1.x): batched MonitorPlc polling for UMAS-by-name keys SHIPPED.
//
// `ModbusDeviceClientAdapter` now wires a `connectionStream` listener that,
// on every successful (re)connect, calls `monitorReset()` to clear any
// stale server-side state and then `monitorRegister(refs)` for the union
// of all UMAS-by-name keys configured for the adapter's server. A per-
// poll-group `Timer.periodic` then issues ONE `monitorReadAll()` per
// tick and demuxes the response back into the matching per-key
// `BehaviorSubject` / `_umasLastValues` entry. The MonitorPlc table is
// SHARED across all poll groups for the adapter's server (the UMAS
// protocol exposes a single registration table per session), so a faster
// group's tick incidentally refreshes all keys; the group cadence still
// controls how often each timer fires.
//
// Lifecycle:
//   - Built on the first ConnectionStatus.connected emission after the
//     UmasClient identity changes (covers cold start + every reconnect).
//   - Reset + rebuilt on UmasClient re-creation (TCP reconnect → fresh
//     ModbusClientTcp → `_getUmasClient` allocates a new UmasClient
//     against the new socket, so the server-side table is gone too).
//   - Disposed in `dispose()`.
//
// Still v1.2:
//   - F-10 (cache survival across reconnect): the symbol cache is dropped
//     on every UmasClient teardown. Would save one browse round-trip per
//     reconnect.
//   - In-place table mutation on Key Repository save: the adapter is
//     re-created only when the save actually touches a Modbus key —
//     `StateMan.updateKeyMappings` reports `requiresReload` and the
//     stateManProvider listener invalidates. Saves that only touch
//     OPC UA / M2400 / UMAS-name-add mappings are applied live without
//     rebuilding this adapter. Mutating the live table for register-spec
//     edits without a full adapter rebuild remains a possible
//     optimisation but is not required for correctness.
