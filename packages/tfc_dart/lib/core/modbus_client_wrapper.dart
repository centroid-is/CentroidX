import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:modbus_client_tcp/modbus_client_tcp.dart';
import 'package:rxdart/rxdart.dart';

import 'rolling_rate.dart' show RollingRate;
import 'state_man_types.dart' show ConnectionStatus;

// =============================================================================
// Data types and configuration classes
// =============================================================================

/// Supported Modbus data type interpretations for register values.
enum ModbusDataType {
  bit,
  int16,
  uint16,
  int32,
  uint32,
  float32,
  int64,
  uint64,
  float64,
}

/// Immutable configuration for a single Modbus register subscription.
///
/// Each spec describes which register to read, how to interpret its bytes,
/// and which poll group controls its read interval.
class ModbusRegisterSpec {
  final String key;
  final ModbusElementType registerType;
  final int address;
  final ModbusDataType dataType;
  final String pollGroup;
  final ModbusEndianness endianness;
  final int addressBase;

  /// Optional bit mask for extracting bits from integer values.
  final int? bitMask;

  /// Bit shift applied after masking (lowest set bit position).
  final int? bitShift;

  const ModbusRegisterSpec({
    required this.key,
    required this.registerType,
    required this.address,
    this.dataType = ModbusDataType.uint16,
    this.pollGroup = 'default',
    this.endianness = ModbusEndianness.ABCD,
    this.addressBase = 0,
    this.bitMask,
    this.bitShift,
  }) : assert(address >= 0 && address <= 65535,
            'Modbus address must be 0-65535, got: $address');
}

// =============================================================================
// Internal subscription and poll group classes
// =============================================================================

/// A Modbus reading together with the instant the round trip that produced it
/// completed.
///
/// **Why the instant travels with the value rather than beside it.** Modbus
/// carries no device timestamp, so the driver's own read instant is the best
/// estimate the protocol admits, and everything downstream — the alarm engine's
/// `ts_source`, the collector, the freshness badge — needs to know *which* read
/// a value came from, not merely that some read happened recently. Reading a
/// "last read at" field off the wrapper at delivery time would be a different
/// number as soon as a second poll lands between the emit and the listener, and
/// that is precisely the class of quiet substitution this milestone exists to
/// end.
final class ModbusSample {
  const ModbusSample({required this.value, required this.readAt});

  /// The parsed reading (bool, int, double, or null).
  final Object? value;

  /// The instant the Modbus round trip that produced [value] completed.
  ///
  /// This is a clock on THIS host, not on the device: Modbus has no source
  /// timestamp to send. It is the moment the answer came off the socket, which
  /// is as close to the wire as the protocol allows anyone to get.
  final DateTime readAt;

  @override
  String toString() => 'ModbusSample($value @ ${readAt.toIso8601String()})';
}

/// The device answered a protocol exception that REFUSES the address space —
/// `IllegalDataAddress` and its two siblings — for one subscribed register.
///
/// **This is affirmative information, not a failure to communicate.** The
/// slave parsed the request and said no: the register map is wrong, and no
/// amount of waiting changes what the device just stated. The 200-server
/// bench measured what dropping this cost — a key at `uncertainNotYetKnown`
/// for the life of the process while the far end was explicitly telling the
/// truth on every poll.
///
/// Emitted on [ModbusClientWrapper.refusals] **once per transition, never per
/// poll tick**: a permanently refused register in a 20 Hz group would
/// otherwise be its own denial of service against the log and every consumer
/// downstream (this repo has been bitten by hot-path logging before). A
/// successful read of the same register clears the latch, so a refusal after
/// a recovery is a new fact and is named again.
final class ModbusAddressRefusal {
  const ModbusAddressRefusal({
    required this.key,
    required this.code,
    required this.at,
  });

  /// The subscription key ([ModbusRegisterSpec.key]) the refused batch served.
  ///
  /// A batch is one coalesced range read, so one exception PDU can refuse
  /// several keys at once — each gets its own event, because each is its own
  /// value on somebody's screen. A healthy register coalesced into a refused
  /// range is genuinely not being served either; that is a true statement
  /// about it, not collateral damage.
  final String key;

  /// Which exception the device answered.
  final ModbusResponseCode code;

  /// When the refusing response came off the socket (host clock — Modbus has
  /// no device timestamp, same as [ModbusSample.readAt]).
  final DateTime at;

  @override
  String toString() => 'ModbusAddressRefusal($key: ${code.name} @ '
      '${at.toIso8601String()})';
}

/// Holds the runtime state for a single subscribed register.
class _RegisterSubscription {
  final ModbusRegisterSpec spec;
  final ModbusElement element;
  final BehaviorSubject<ModbusSample> sample$;

  /// The refusal this register is currently under, or null.
  ///
  /// The transition latch behind [ModbusClientWrapper.refusals]: set when a
  /// batch answer refuses this element with a code it does not already carry,
  /// cleared by the next successful read. The per-tick repetition of a steady
  /// refusal is absorbed here, which is what keeps the stream (and the log)
  /// once-per-key instead of once-per-sample.
  ModbusResponseCode? lastRefusal;

  _RegisterSubscription({
    required this.spec,
    required this.element,
  }) : sample$ = BehaviorSubject<ModbusSample>();

  ModbusSample? get currentSample => sample$.valueOrNull;
  Object? get currentValue => sample$.valueOrNull?.value;
  Stream<ModbusSample> get sampleStream => sample$.stream;
  Stream<Object?> get stream => sample$.stream.map((s) => s.value);
}

/// A named group of register subscriptions polled at a common interval.
class _PollGroup {
  final String name;
  final Duration interval;
  final Duration? responseTimeout;
  Timer? _timer;
  final List<_RegisterSubscription> _subscriptions = [];
  bool _pollInProgress = false;

  /// When true, the coalesced groups must be recalculated on the next tick.
  /// Starts dirty so the first tick builds the groups.
  bool _dirty = true;

  /// Cached coalesced [ModbusElementsGroup] instances, rebuilt when [_dirty].
  List<ModbusElementsGroup> _cachedGroups = [];

  _PollGroup({
    required this.name,
    required this.interval,
    this.responseTimeout,
  });

  void start(Future<void> Function() pollCallback) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) async {
      await pollCallback();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

// =============================================================================
// ModbusClientWrapper
// =============================================================================

/// Wraps [ModbusClientTcp] with persistent connection lifecycle management:
/// auto-reconnect with exponential backoff, BehaviorSubject status streaming,
/// connect/disconnect/dispose lifecycle, and factory injection for testability.
///
/// Phase 5 extension: poll-based reading of all four Modbus register types
/// (coils FC01, discrete inputs FC02, holding registers FC03, input registers
/// FC04) with configurable data types, named poll groups, and BehaviorSubject
/// value streams.
///
/// Follows the MSocket connection loop pattern from jbtm.
class ModbusClientWrapper {
  final String host;
  final int port;
  final int unitId;
  final ModbusClientTcp Function(String host, int port, int unitId)
      _clientFactory;

  final _status =
      BehaviorSubject<ConnectionStatus>.seeded(ConnectionStatus.disconnected);

  ModbusClientTcp? _client;

  /// When true the connection loop exits at the next check point.
  bool _stopped = true;

  /// Terminal flag -- once disposed, the wrapper cannot be reused.
  bool _disposed = false;

  static const _initialBackoff = Duration(milliseconds: 500);
  static const _maxBackoff = Duration(seconds: 5);
  Duration _backoff = _initialBackoff;

  // ---------------------------------------------------------------------------
  // Connection-metadata instrumentation (additive, null-safe)
  // ---------------------------------------------------------------------------

  /// Rolling requests-per-second, incremented at each poll/UMAS send.
  final RollingRate _requestRate = RollingRate();

  /// Timestamp of the most recent transition to `connected`.
  DateTime? _connectedSince;

  /// Whether a first connection has ever succeeded (so the initial connect is
  /// not counted as a reconnect).
  bool _everConnected = false;

  /// Number of times the connection has been re-established after the first.
  int _reconnectCount = 0;

  /// Last error string captured at a connection/poll failure site ('' = none).
  String _lastError = '';

  /// Records one Modbus request for the requests-per-second rate. Called at
  /// each classic poll send and each UMAS poll read.
  void recordRequest() => _requestRate.increment();

  /// Rolling requests-per-second over the recent window.
  double get requestsPerSec => _requestRate.ratePerSec;

  /// Seconds since the last successful connect (0 when not connected).
  double get uptimeSec {
    final since = _connectedSince;
    if (since == null || connectionStatus != ConnectionStatus.connected) {
      return 0;
    }
    return DateTime.now().difference(since).inMilliseconds / 1000.0;
  }

  /// Number of reconnects since the first successful connect.
  int get reconnectCount => _reconnectCount;

  /// Last captured error string ('' when none).
  String get lastError => _lastError;

  /// The local TCP source port, or null when disconnected.
  int? get sourcePort => _client?.localPort;

  static final _log = Logger(
    printer: SimplePrinter(),
    level: Level.info,
  );

  // ---------------------------------------------------------------------------
  // Batch coalescing constants (Phase 5, Plan 02)
  // ---------------------------------------------------------------------------

  /// Maximum gap (in register addresses) before splitting into separate batches.
  /// Reading 10 extra registers wastes only 20 bytes vs saving a TCP round-trip.
  static const _registerGapThreshold = 10;

  /// Maximum gap (in coil addresses) before splitting into separate batches.
  /// Reading 100 extra coils wastes only ~13 bytes vs saving a TCP round-trip.
  static const _coilGapThreshold = 100;

  // ---------------------------------------------------------------------------
  // Poll infrastructure (Phase 5)
  // ---------------------------------------------------------------------------

  /// All active register subscriptions, keyed by spec.key.
  final Map<String, _RegisterSubscription> _subscriptions = {};

  /// Named poll groups with their own intervals and subscription lists.
  final Map<String, _PollGroup> _pollGroups = {};

  /// Subscription to connectionStream that drives poll start/stop.
  StreamSubscription<ConnectionStatus>? _pollLifecycleSubscription;

  /// Default poll interval when no explicit interval is configured.
  static const _defaultPollInterval = Duration(seconds: 1);

  // ---------------------------------------------------------------------------
  // Idle heartbeat (keeps connection alive when no subscriptions are polling)
  // ---------------------------------------------------------------------------

  Timer? _heartbeatTimer;
  final Duration _heartbeatInterval;

  // ---------------------------------------------------------------------------
  // Half-open detection
  // ---------------------------------------------------------------------------

  /// Consecutive failed poll reads since the last successful one.
  int _consecutiveReadFailures = 0;

  /// After this many consecutive failures the socket is treated as dead even
  /// though the OS still calls it connected. A peer that accepts the TCP
  /// connection and then answers nothing -- a wedged gateway, a firewall that
  /// silently drops, a PLC mid-reboot holding the listen queue -- otherwise
  /// leaves the wrapper reporting `connected` forever, because
  /// [_awaitDisconnect] only ever looks at the socket flag.
  static const _failuresBeforeReconnect = 3;

  /// Whether [code] means "nothing came back", as opposed to the device
  /// answering with a protocol exception.
  static bool _isTransportFailure(ModbusResponseCode code) =>
      code == ModbusResponseCode.requestTimeout ||
      code == ModbusResponseCode.connectionFailed ||
      code == ModbusResponseCode.requestTxFailed ||
      code == ModbusResponseCode.requestRxFailed;

  /// Whether [code] is the device REFUSING the request's shape — an answer
  /// about the configuration, not about the moment.
  ///
  /// The three standard exceptions where the slave parsed the request and
  /// declined it by construction: the function is not supported, the address
  /// range does not exist, the quantity/value field is malformed. Waiting
  /// changes none of them; somebody must fix the register map. Everything
  /// else the device can answer (`deviceBusy`, `acknowledge`,
  /// `deviceFailure`, the gateway codes) is a statement about *now* and keeps
  /// the existing skip-and-wait behaviour — grading a busy device as a config
  /// error would tell an operator to stop waiting for a register that is
  /// seconds from coming back.
  static bool _isAffirmativeRefusal(ModbusResponseCode code) =>
      code == ModbusResponseCode.illegalFunction ||
      code == ModbusResponseCode.illegalDataAddress ||
      code == ModbusResponseCode.illegalDataValue;

  /// Registers the device has refused by name — see [ModbusAddressRefusal].
  ///
  /// One event per key per transition; a steady refusal repeats nothing here.
  Stream<ModbusAddressRefusal> get refusals => _refusals.stream;
  final StreamController<ModbusAddressRefusal> _refusals =
      StreamController<ModbusAddressRefusal>.broadcast();

  /// Drops the current socket so [_connectionLoop] reconnects.
  void _forceReconnect(String why) {
    _consecutiveReadFailures = 0;
    _lastError = why;
    _log.w('ModbusClientWrapper($host:$port) forcing reconnect: $why');
    unawaited(_cleanupClientInstance());
  }

  /// Creates a wrapper for a Modbus device at [host]:[port] with [unitId].
  ///
  /// Provide [clientFactory] to inject a custom/mock ModbusClientTcp for
  /// testing. The default factory creates a real ModbusClientTcp with
  /// [ModbusConnectionMode.doNotConnect] so the wrapper owns the connection
  /// loop.
  ModbusClientWrapper(
    this.host,
    this.port,
    this.unitId, {
    ModbusClientTcp Function(String, int, int)? clientFactory,
    Duration heartbeatInterval = const Duration(seconds: 10),
    this.heartbeatAddress = 0,
    DateTime Function()? clock,
  })  : _clientFactory = clientFactory ?? _defaultFactory,
        _heartbeatInterval = heartbeatInterval,
        _clock = clock ?? DateTime.timestamp;

  /// The clock read to stamp [ModbusSample.readAt], injected so a test can
  /// pin the *site* of the reading rather than merely its presence.
  ///
  /// Defaults to `DateTime.timestamp` (UTC): the stamp travels into
  /// `alarm_history` and a local-zone instant there is a different bug.
  final DateTime Function() _clock;

  /// The holding register address to read during idle heartbeat probes.
  /// Defaults to 0 for backward compatibility. Override for devices where
  /// register 0 has undesired side-effects.
  final int heartbeatAddress;

  static ModbusClientTcp _defaultFactory(String host, int port, int unitId) {
    return ModbusClientTcp(
      host,
      serverPort: port,
      unitId: unitId,
      connectionMode: ModbusConnectionMode.doNotConnect,
      connectionTimeout: const Duration(seconds: 3),
    );
  }

  // ---------------------------------------------------------------------------
  // Public API -- Connection
  // ---------------------------------------------------------------------------

  /// Current connection status (synchronous).
  ConnectionStatus get connectionStatus => _status.value;

  /// Connection status stream with replay of current value to new subscribers.
  Stream<ConnectionStatus> get connectionStream => _status.stream;

  /// The underlying Modbus client, if connected. Null when disconnected.
  ModbusClientTcp? get client => _client;

  /// Starts the connection loop (fire-and-forget). The loop runs until
  /// [disconnect] or [dispose] is called. Status changes are emitted via
  /// [connectionStream].
  void connect() {
    if (_disposed) return;
    _stopped = false;
    // One loop per wrapper, ever. Without this a second connect() -- two
    // presses of Reconnect, a rebuilt widget, a disconnect()/connect() pair
    // from a config save -- starts a second _connectionLoop that races the
    // first for _client. The loser's socket is never disconnected.
    if (_loopRunning) return;
    _loopRunning = true;
    unawaited(_connectionLoop().whenComplete(() {
      _loopRunning = false;
      // A connect() that arrived while the previous loop was winding down
      // returned early above; honour it now rather than leaving the wrapper
      // permanently disconnected.
      if (!_stopped && !_disposed) connect();
    }));
  }

  /// True while [_connectionLoop] is executing.
  bool _loopRunning = false;

  /// Stops the reconnect loop and disconnects the client. The wrapper can be
  /// reconnected by calling [connect] again. Streams remain open.
  void disconnect() {
    _stopped = true;
    unawaited(_cleanupClient());
  }

  /// Terminal shutdown -- stops reconnect, disconnects, and closes all streams.
  /// The wrapper cannot be reused after dispose.
  void dispose() {
    _stopped = true;
    _disposed = true;
    // Emit disconnected synchronously before closing the stream, so
    // listeners see the final status before done. _cleanupClient is async
    // but its status-add is guarded by isClosed, so it will be a no-op.
    if (!_status.isClosed && _status.value != ConnectionStatus.disconnected) {
      _status.add(ConnectionStatus.disconnected);
    }
    unawaited(_cleanupClient());
    _stopHeartbeat();
    _stopAllPolling();
    _pollLifecycleSubscription?.cancel();
    _pollLifecycleSubscription = null;
    // Close all subscription BehaviorSubjects
    for (final sub in _subscriptions.values) {
      if (!sub.sample$.isClosed) {
        sub.sample$.close();
      }
    }
    if (!_status.isClosed) {
      _status.close();
    }
    if (!_refusals.isClosed) {
      _refusals.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Public API -- Reading (Phase 5)
  // ---------------------------------------------------------------------------

  /// Creates or updates a named poll group with the given [interval].
  ///
  /// If a group with [name] already exists, its interval is NOT changed --
  /// call before subscribing registers to set the desired interval.
  void addPollGroup(String name, Duration interval,
      {Duration? responseTimeout}) {
    _pollGroups.putIfAbsent(
      name,
      () => _PollGroup(
        name: name,
        interval: interval,
        responseTimeout: responseTimeout,
      ),
    );
  }

  /// Subscribes to a Modbus register described by [spec].
  ///
  /// Returns a `Stream<Object?>` that emits parsed values (bool, int, or
  /// double) on each successful poll read. The stream is backed by a
  /// BehaviorSubject, so new listeners receive the last-known value
  /// immediately.
  ///
  /// If the spec's poll group does not exist, it is lazily created with the
  /// default 1-second interval.
  ///
  /// The value alone. Callers that need to know WHEN the reading was taken —
  /// which is everything feeding the alarm engine — want [subscribeSamples].
  Stream<Object?> subscribe(ModbusRegisterSpec spec) =>
      subscribeSamples(spec).map((s) => s.value);

  /// [subscribe], but each event carries the instant its read completed.
  ///
  /// Registration is identical; this is the same subject with the provenance
  /// left on.
  Stream<ModbusSample> subscribeSamples(ModbusRegisterSpec spec) {
    // Return existing subscription if already subscribed (prevents duplicate
    // accumulation in poll group on repeated calls from widget rebuilds).
    final existing = _subscriptions[spec.key];
    if (existing != null) {
      // Verify the existing subscription spec matches — if not, tear down the
      // stale subscription so we recreate with the updated parameters.
      if (_specMatches(existing.spec, spec)) {
        return existing.sampleStream;
      }
      unsubscribe(spec.key);
    }

    // Create element for this spec
    final element = _createElement(spec);
    final subscription = _RegisterSubscription(spec: spec, element: element);
    _subscriptions[spec.key] = subscription;

    // Ensure the poll group exists
    final group = _pollGroups.putIfAbsent(
      spec.pollGroup,
      () => _PollGroup(
        name: spec.pollGroup,
        interval: _defaultPollInterval,
      ),
    );
    group._subscriptions.add(subscription);
    group._dirty = true; // trigger coalescing recalculation on next tick

    // Initialize poll lifecycle listener if not already active
    _initPollLifecycle();

    // If already connected, restart polling to pick up new subscription
    if (connectionStatus == ConnectionStatus.connected) {
      _stopAllPolling();
      _startAllPolling();
    }

    return subscription.sampleStream;
  }

  /// Returns the last-known cached value for [key], or null if not subscribed
  /// or not yet polled.
  Object? read(String key) {
    return _subscriptions[key]?.currentValue;
  }

  /// [read], but with the instant the read that produced the cached value
  /// completed.
  ///
  /// The instant is the CACHED one, not "now": a value sitting in the subject
  /// is exactly as old as the round trip that fetched it, and re-stamping it on
  /// the way out would make a stale reading look fresh — the same substitution
  /// one layer down.
  ModbusSample? readSample(String key) => _subscriptions[key]?.currentSample;

  /// Removes the subscription for [key] from its poll group.
  void unsubscribe(String key) {
    final sub = _subscriptions.remove(key);
    if (sub == null) return;

    // Remove from its poll group
    final group = _pollGroups[sub.spec.pollGroup];
    if (group != null) {
      group._subscriptions.remove(sub);
      group._dirty = true; // trigger coalescing recalculation on next tick
    }

    if (!sub.sample$.isClosed) {
      sub.sample$.close();
    }

    // Resume heartbeat if no subscriptions remain and still connected
    if (_subscriptions.isEmpty &&
        connectionStatus == ConnectionStatus.connected) {
      _startHeartbeat();
    }
  }

  /// Returns true if two specs describe the same register configuration.
  static bool _specMatches(ModbusRegisterSpec a, ModbusRegisterSpec b) {
    return a.registerType == b.registerType &&
        a.address == b.address &&
        a.dataType == b.dataType &&
        a.pollGroup == b.pollGroup &&
        a.endianness == b.endianness &&
        a.addressBase == b.addressBase &&
        a.bitMask == b.bitMask &&
        a.bitShift == b.bitShift;
  }

  // ---------------------------------------------------------------------------
  // Public API -- Writing (Phase 6)
  // ---------------------------------------------------------------------------

  /// Writes a single value to the Modbus device register described by [spec].
  ///
  /// For coils (FC05): [value] should be `bool`.
  /// For holding registers (FC06): [value] should be `num` (int or double).
  /// For multi-register types (int32, float32, etc.): the library automatically
  /// uses FC16 when byteCount > 2.
  ///
  /// Throws [StateError] if disconnected or disposed (SCADA safety: writes are
  /// never queued). Throws [ArgumentError] for read-only register types
  /// (discrete inputs, input registers). Throws [StateError] with the response
  /// code name if the device rejects the write.
  ///
  /// If the key has an active subscription, the BehaviorSubject is
  /// optimistically updated with [value] after a successful write.
  Future<void> write(ModbusRegisterSpec spec, Object? value) async {
    _validateWriteAccess(spec);

    final element = _createElement(spec);
    final request = element.getWriteRequest(value);
    final result = await _client!.send(request);
    // The device acknowledged. Same class of instant as a read: a clock on this
    // host, taken the moment the wire answered.
    final ackedAt = _clock();

    if (result != ModbusResponseCode.requestSucceed) {
      throw StateError(
          'Write failed: ${result.name} (0x${result.code.toRadixString(16).padLeft(2, '0')}) -- ${_describeException(result)}');
    }

    // Optimistic update: push written value into BehaviorSubject if subscribed
    final sub = _subscriptions[spec.key];
    if (sub != null && !sub.sample$.isClosed) {
      sub.sample$.add(ModbusSample(value: value, readAt: ackedAt));
    }
  }

  /// Writes multiple coils or registers in a single Modbus transaction.
  ///
  /// For coils (FC15): pass packed [bytes] and explicit [quantity] (coil count).
  /// For holding registers (FC16): pass raw [bytes] (2 bytes per register).
  ///
  /// Same error semantics as [write]: throws on disconnect, dispose, read-only
  /// types, and failed sends.
  Future<void> writeMultiple(ModbusRegisterSpec spec, Uint8List bytes,
      {int? quantity}) async {
    _validateWriteAccess(spec);

    final element = _createElement(spec);
    final request = element.getMultipleWriteRequest(bytes, quantity: quantity);
    final result = await _client!.send(request);

    if (result != ModbusResponseCode.requestSucceed) {
      throw StateError(
          'Write multiple failed: ${result.name} (0x${result.code.toRadixString(16).padLeft(2, '0')}) -- ${_describeException(result)}');
    }
  }

  /// Shared validation for [write] and [writeMultiple].
  ///
  /// Checks disposed state, connection status, and rejects read-only types.
  void _validateWriteAccess(ModbusRegisterSpec spec) {
    if (_disposed) {
      throw StateError('ModbusClientWrapper has been disposed');
    }
    if (connectionStatus != ConnectionStatus.connected || _client == null) {
      throw StateError('Not connected -- cannot write (writes are not queued)');
    }

    final type = spec.registerType;
    if (type == ModbusElementType.discreteInput ||
        type == ModbusElementType.inputRegister) {
      final typeName = type == ModbusElementType.discreteInput
          ? 'discrete input'
          : 'input register';
      throw ArgumentError(
          'Cannot write to $typeName -- read-only register type');
    }
  }

  // ---------------------------------------------------------------------------
  // Connection loop (follows MSocket._connectionLoop pattern)
  // ---------------------------------------------------------------------------

  Future<void> _connectionLoop() async {
    while (!_stopped) {
      _log.i('ModbusClientWrapper($host:$port) connecting...');
      if (!_status.isClosed) {
        _status.add(ConnectionStatus.connecting);
      }

      try {
        _client = _clientFactory(host, port, unitId);
        final connected = await _client!.connect();

        if (_stopped) {
          await _cleanupClientInstance();
          break;
        }

        if (!connected) {
          throw StateError('connect() returned false');
        }

        // Connected successfully
        _log.i('ModbusClientWrapper($host:$port) connected');
        if (_everConnected) {
          _reconnectCount++;
        }
        _everConnected = true;
        _connectedSince = DateTime.now();
        // A successful connect supersedes whatever went wrong before it —
        // without this, one transient timeout stays on the Connection Info
        // card as a red Error row forever.
        _lastError = '';
        if (!_status.isClosed) {
          _status.add(ConnectionStatus.connected);
        }
        _backoff = _initialBackoff;

        // Start idle heartbeat if no subscriptions are generating traffic
        if (_subscriptions.isEmpty) {
          _startHeartbeat();
        }

        // Block until connection drops or stopped
        await _awaitDisconnect();
        _log.i('ModbusClientWrapper($host:$port) connection lost');
      } catch (e) {
        _lastError = e.toString();
        _log.i('ModbusClientWrapper($host:$port) connection error: $e');
      }

      // Socket is gone -- clean up
      _stopHeartbeat();
      _connectedSince = null;
      await _cleanupClientInstance();
      if (!_stopped && !_status.isClosed) {
        _status.add(ConnectionStatus.disconnected);
      }
      if (_stopped) break;

      // Exponential backoff delay
      await Future.delayed(_backoff);
      if (_stopped) break;
      _backoff = _clampDuration(_backoff * 2, Duration.zero, _maxBackoff);
    }
  }

  /// Polls [_client.isConnected] until the connection drops or [_stopped] is
  /// set. Returns when disconnect is detected.
  Future<void> _awaitDisconnect() async {
    while (!_stopped && _client != null && _client!.isConnected) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  // ---------------------------------------------------------------------------
  // Poll lifecycle (Phase 5)
  // ---------------------------------------------------------------------------

  /// Initializes the connection-lifecycle-tied poll management.
  /// Called lazily on first subscribe(). Listens to connectionStream to
  /// start/stop all poll timers.
  void _initPollLifecycle() {
    if (_pollLifecycleSubscription != null) return;
    _pollLifecycleSubscription = connectionStream.listen((status) {
      if (status == ConnectionStatus.connected) {
        _startAllPolling();
      } else {
        _stopAllPolling();
        _stopHeartbeat();
      }
    });
  }

  /// Starts Timer.periodic for each poll group that has subscriptions.
  void _startAllPolling() {
    final hasActiveSubscriptions = _subscriptions.isNotEmpty;
    for (final group in _pollGroups.values) {
      if (group._subscriptions.isNotEmpty) {
        group.start(() => _onPollTick(group));
      }
    }
    // Heartbeat runs only when no subscriptions are generating traffic
    if (hasActiveSubscriptions) {
      _stopHeartbeat();
    } else {
      _startHeartbeat();
    }
  }

  /// Cancels all poll timers.
  void _stopAllPolling() {
    for (final group in _pollGroups.values) {
      group.stop();
    }
  }

  // ---------------------------------------------------------------------------
  // Idle heartbeat
  // ---------------------------------------------------------------------------

  /// Starts a periodic read of holding register 0 to keep the TCP connection
  /// alive when no subscriptions are generating Modbus traffic.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      if (_disposed || connectionStatus != ConnectionStatus.connected) return;
      if (_client == null) return;
      try {
        final element = ModbusUint16Register(
          name: '_heartbeat',
          address: heartbeatAddress,
          type: ModbusElementType.holdingRegister,
        );
        final request = element.getReadRequest();
        await _client!.send(request);
      } catch (e) {
        _log.w('ModbusClientWrapper($host:$port) heartbeat error: $e');
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Executes a single poll tick for a group: reads coalesced batch groups
  /// and pipes values into their BehaviorSubjects.
  ///
  /// Guarded by [_pollInProgress] to prevent concurrent sends if a tick
  /// takes longer than the poll interval.
  Future<void> _onPollTick(_PollGroup group) async {
    if (_disposed || connectionStatus != ConnectionStatus.connected) return;
    if (group._pollInProgress) return; // skip if previous tick still running
    if (group._subscriptions.isEmpty) return;
    group._pollInProgress = true;

    try {
      // Rebuild coalesced groups if subscriptions changed
      if (group._dirty) {
        group._cachedGroups = _buildCoalescedGroups(group._subscriptions);
        group._dirty = false;
      }

      // Elements whose batch actually came back this tick, and WHEN it came
      // back. Only these may be published: the element objects hold their
      // PREVIOUS reading when a read fails, so publishing unconditionally
      // re-emits the last good value at the poll rate and a dead device looks
      // like a steady one.
      //
      // The instant is recorded per BATCH, immediately after the send returns,
      // not once per tick and not at publish time below. A tick reads several
      // batches in sequence; stamping them all with one instant would date the
      // first batch by however long the last one took, and stamping at publish
      // time would date every reading by the whole tick.
      final freshlyRead = Map<ModbusElement, DateTime>.identity();

      // Elements whose batch the device REFUSED this tick (an affirmative
      // exception answer, never a transport failure), with when. Kept apart
      // from [freshlyRead] because they are opposite facts: one is "a
      // reading exists", the other is "the device said this reading can
      // never exist as asked".
      final refused =
          Map<ModbusElement, ({ModbusResponseCode code, DateTime at})>
              .identity();

      for (final elemGroup in group._cachedGroups) {
        if (_disposed || connectionStatus != ConnectionStatus.connected) break;

        try {
          final request = elemGroup.getReadRequest(
            responseTimeout: group.responseTimeout,
          );
          recordRequest();
          final result = await _client!.send(request);
          // Read the clock here, on the line after the wire answered, and
          // nowhere later. This is the whole claim the stamp makes.
          final readAt = _clock();

          if (result != ModbusResponseCode.requestSucceed) {
            _lastError = 'Poll group "${group.name}": ${result.name}';
            if (_isAffirmativeRefusal(result)) {
              // The device answered: the request's shape is refused. Named
              // per subscription below, ONCE per transition — the log line
              // moves there too, because a refused register in a fast group
              // logging every tick is the hot-path failure this repo has
              // already paid for once.
              for (final element in elemGroup) {
                refused[element] = (code: result, at: readAt);
              }
            } else {
              _log.w(
                  'Poll group "${group.name}" batch read failed: ${result.name}');
              // Only transport failures count toward half-open detection. A
              // protocol exception (deviceBusy, deviceFailure, ...) is
              // proof the peer is alive and answering; it means the moment
              // is wrong, not the socket.
              if (_isTransportFailure(result)) _consecutiveReadFailures++;
              // Last-known values remain in BehaviorSubjects (SCADA behavior)
            }
          } else {
            _consecutiveReadFailures = 0;
            for (final element in elemGroup) {
              freshlyRead[element] = readAt;
            }
          }
        } catch (e) {
          _lastError = e.toString();
          _log.w('Poll group "${group.name}" batch read error: $e');
          _consecutiveReadFailures++;
          // Continue to next group
        }

        if (_consecutiveReadFailures >= _failuresBeforeReconnect) {
          _forceReconnect('$_consecutiveReadFailures consecutive failed '
              'reads on a socket the OS still calls connected');
          break;
        }
      }

      // Pipe subscription values after all groups have been read.
      // Elements are shared references -- batch reads populated them in-place.
      // The modbus_client library returns double for all numeric types (due to
      // multiplier/offset arithmetic). Coerce back to int for integer types.
      //
      // A subscription whose batch failed is SKIPPED, not republished: its
      // BehaviorSubject keeps the last good value for new listeners (the SCADA
      // behaviour), but no new event is emitted, so nothing downstream --
      // above all the collector -- records a reading that never happened.
      //
      // A subscription whose batch was REFUSED is different in kind: the
      // device affirmatively said no, and that is named on [refusals] — once
      // per transition, with the tick-rate repetition absorbed by the
      // per-subscription latch. A successful read clears the latch, so a
      // refusal returning after a recovery is a new fact and is named again.
      for (final sub in group._subscriptions) {
        final refusal = refused[sub.element];
        if (refusal != null) {
          if (sub.lastRefusal != refusal.code) {
            sub.lastRefusal = refusal.code;
            _log.w('Register "${sub.spec.key}" (address ${sub.spec.address}) '
                'refused by the device: ${refusal.code.name} — the register '
                'map is wrong, waiting will not fix it (logged once per '
                'transition)');
            if (!_refusals.isClosed) {
              _refusals.add(ModbusAddressRefusal(
                key: sub.spec.key,
                code: refusal.code,
                at: refusal.at,
              ));
            }
          }
          continue;
        }
        final readAt = freshlyRead[sub.element];
        if (readAt == null) continue;
        sub.lastRefusal = null;
        if (!sub.sample$.isClosed) {
          sub.sample$.add(ModbusSample(
            value: _coerceValue(sub.element.value, sub.spec.dataType),
            readAt: readAt,
          ));
        }
      }
    } catch (e, st) {
      // Last line of defence. _onPollTick runs from an async Timer.periodic
      // callback whose Future is discarded, and the data-acquisition isolate
      // is spawned with errorsAreFatal, so ANY throw that escapes this method
      // kills acquisition for the whole server and sends the supervisor into
      // a respawn loop. A poll tick failing must never be able to do that.
      _lastError = e.toString();
      _log.e('Poll group "${group.name}" tick failed: $e\n$st');
    } finally {
      group._pollInProgress = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Batch coalescing (Phase 5, Plan 02)
  // ---------------------------------------------------------------------------

  /// Builds coalesced [ModbusElementsGroup] instances from a list of
  /// subscriptions. Contiguous same-type elements within the gap threshold
  /// are merged into single batch reads. Oversized batches are automatically
  /// split at Modbus limits (125 registers / 2000 coils).
  List<ModbusElementsGroup> _buildCoalescedGroups(
      List<_RegisterSubscription> subs) {
    if (subs.isEmpty) return [];

    // Group subscriptions by element type
    final byType = <ModbusElementType, List<_RegisterSubscription>>{};
    for (final sub in subs) {
      byType.putIfAbsent(sub.element.type, () => []).add(sub);
    }

    final groups = <ModbusElementsGroup>[];

    for (final typeSubs in byType.values) {
      // Sort by address
      typeSubs.sort((a, b) => a.element.address - b.element.address);

      final isRegister = typeSubs.first.element.type.isRegister;
      final maxRange = isRegister
          ? ModbusElementsGroup.maxRegistersRange // 125
          : ModbusElementsGroup.maxCoilsRange; // 2000
      final gapThreshold =
          isRegister ? _registerGapThreshold : _coilGapThreshold;

      var currentBatch = <_RegisterSubscription>[typeSubs.first];

      for (var i = 1; i < typeSubs.length; i++) {
        final prev = currentBatch.last;
        final curr = typeSubs[i];

        // Calculate the end address of the previous element
        final prevEnd = prev.element.address +
            (isRegister ? prev.element.byteCount ~/ 2 : 1);
        final gap = curr.element.address - prevEnd;

        // Calculate the batch range if we add the current element
        final currEnd = curr.element.address +
            (isRegister ? curr.element.byteCount ~/ 2 : 1);
        final batchRange = currEnd - currentBatch.first.element.address;

        // Start new batch if the gap is too large, the address span would
        // exceed the Modbus limit, or the batch would hold more ELEMENTS than
        // ModbusElementsGroup accepts.
        //
        // Span and count are not the same number: several keys may share one
        // register address (a status word with one key per bit is the normal
        // case), so a batch spanning 8 registers can hold 128 elements.
        // ModbusElementsGroup checks both against the same limit and throws
        // "Too many elements!" on the count — from inside the poll timer,
        // where nothing catches it.
        if (gap > gapThreshold ||
            batchRange > maxRange ||
            currentBatch.length >= maxRange) {
          groups.add(ModbusElementsGroup(currentBatch.map((s) => s.element)));
          currentBatch = [curr];
        } else {
          currentBatch.add(curr);
        }
      }

      // Flush the final batch
      if (currentBatch.isNotEmpty) {
        groups.add(ModbusElementsGroup(currentBatch.map((s) => s.element)));
      }
    }

    return groups;
  }

  // ---------------------------------------------------------------------------
  // Element factory (Phase 5)
  // ---------------------------------------------------------------------------

  /// Creates the correct [ModbusElement] subclass from a [ModbusRegisterSpec].
  ///
  /// Bit types (coil, discreteInput) always return a [ModbusBitElement]
  /// subclass regardless of [spec.dataType]. Register types use [spec.dataType]
  /// to select the correct numeric element class.
  ModbusElement _createElement(ModbusRegisterSpec spec) {
    final type = spec.registerType;
    final address = spec.address - spec.addressBase;
    assert(
        address >= 0,
        'Wire address must be >= 0 after applying addressBase offset: '
        'spec.address=${spec.address}, addressBase=${spec.addressBase}');
    final name = spec.key;

    // Bit types (coils and discrete inputs)
    if (type == ModbusElementType.coil) {
      return ModbusCoil(name: name, address: address);
    }
    if (type == ModbusElementType.discreteInput) {
      return ModbusDiscreteInput(name: name, address: address);
    }

    // Register types -- select by dataType
    // Multi-register types (32-bit, 64-bit) pass endianness for byte/word
    // ordering. Single-register types (16-bit) and bit types are unaffected.
    switch (spec.dataType) {
      case ModbusDataType.int16:
        return ModbusInt16Register(name: name, address: address, type: type);
      case ModbusDataType.uint16:
        return ModbusUint16Register(name: name, address: address, type: type);
      case ModbusDataType.int32:
        return ModbusInt32Register(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.uint32:
        return ModbusUint32Register(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.float32:
        return ModbusFloatRegister(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.int64:
        return ModbusInt64Register(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.uint64:
        return ModbusUint64Register(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.float64:
        return ModbusDoubleRegister(
            name: name,
            address: address,
            type: type,
            endianness: spec.endianness);
      case ModbusDataType.bit:
        // bit for register type defaults to uint16
        return ModbusUint16Register(name: name, address: address, type: type);
    }
  }

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  /// Disconnects and nulls out the current client instance.
  Future<void> _cleanupClientInstance() async {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.disconnect();
      } catch (_) {
        // Ignore errors during cleanup
      }
    }
  }

  /// Stops the client and emits disconnected status if appropriate.
  Future<void> _cleanupClient() async {
    await _cleanupClientInstance();
    if (!_status.isClosed && _status.value != ConnectionStatus.disconnected) {
      _status.add(ConnectionStatus.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Coerces a raw modbus_client value to the correct Dart type.
  ///
  /// The modbus_client library's [ModbusNumRegister.setValueFromBytes] applies
  /// `(rawInt * multiplier) + offset` where multiplier/offset are doubles,
  /// promoting all results to double — even for int16/uint16 registers.
  /// This method converts back to int for integer data types.
  static Object? _coerceValue(Object? value, ModbusDataType dataType) {
    if (value == null) return null;
    switch (dataType) {
      case ModbusDataType.bit:
      case ModbusDataType.float32:
      case ModbusDataType.float64:
        return value; // already correct type (bool or double)
      case ModbusDataType.int16:
      case ModbusDataType.uint16:
      case ModbusDataType.int32:
      case ModbusDataType.uint32:
      case ModbusDataType.int64:
      case ModbusDataType.uint64:
        return value is num ? value.toInt() : value;
    }
  }

  static Duration _clampDuration(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  /// Returns a human-readable description for a Modbus exception code.
  ///
  /// Covers the standard Modbus exception codes (0x01-0x0B) plus common
  /// library-internal transport errors. Used in write error messages to give
  /// operators actionable information.
  static String _describeException(ModbusResponseCode code) {
    switch (code) {
      case ModbusResponseCode.illegalFunction:
        return 'Function code not supported by device';
      case ModbusResponseCode.illegalDataAddress:
        return 'Register address does not exist on device';
      case ModbusResponseCode.illegalDataValue:
        return 'Value out of range for this register';
      case ModbusResponseCode.deviceFailure:
        return 'Device internal error';
      case ModbusResponseCode.acknowledge:
        return 'Request accepted but processing not complete';
      case ModbusResponseCode.deviceBusy:
        return 'Device busy, retry later';
      case ModbusResponseCode.negativeAcknowledgment:
        return 'Device cannot perform the programming request';
      case ModbusResponseCode.memoryParityError:
        return 'Memory parity error during extended memory read';
      case ModbusResponseCode.gatewayPathUnavailable:
        return 'Gateway path unavailable';
      case ModbusResponseCode.gatewayTargetDeviceFailedToRespond:
        return 'Gateway target device not responding';
      case ModbusResponseCode.requestTimeout:
        return 'Request timed out';
      case ModbusResponseCode.connectionFailed:
        return 'Connection failed';
      case ModbusResponseCode.requestTxFailed:
        return 'Request transmission failed';
      case ModbusResponseCode.requestRxFailed:
        return 'Response reception failed';
      default:
        return 'Unexpected error';
    }
  }
}
