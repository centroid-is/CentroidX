import 'dart:async';

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';

import 'm2400.dart';
import 'm2400_dynamic_value.dart';
import 'm2400_field_parser.dart';
import 'msocket.dart';

/// M2400 device client wrapper providing subscribe-by-key access to
/// parsed DynamicValue streams.
///
/// Follows the existing ClientWrapper pattern (connect/disconnect/status)
/// and adds M2400-specific stream routing with dot-notation field access.
///
/// Usage:
/// ```dart
/// final client = M2400ClientWrapper('192.168.1.100', 4001);
/// client.connect();
/// client.subscribe('BATCH').listen((dv) => print(dv['weight'].asDouble));
/// client.subscribe('STAT').listen((dv) => print(dv['weight'].asDouble));
/// client.subscribe('BATCH.weight').listen((dv) => print(dv.asDouble));
/// ```
class M2400ClientWrapper {
  /// The host to connect to.
  final String host;

  /// The port to connect to.
  final int port;

  /// Optional factory for creating MSocket instances (enables test injection).
  final MSocket Function(String host, int port) _socketFactory;

  MSocket? _socket;
  StreamSubscription<void>? _pipelineSubscription;
  StreamSubscription<ConnectionStatus>? _statusSubscription;

  /// Wrapper-owned status subject. Lives for the lifetime of the wrapper,
  /// piping MSocket status changes through connect/disconnect cycles.
  final _status =
      BehaviorSubject<ConnectionStatus>.seeded(ConnectionStatus.disconnected);

  // -- Stream routing controllers --

  /// BATCH records: event-only (no replay). Each weighing is a discrete event.
  final _batchController = StreamController<DynamicValue>.broadcast();

  /// STAT records: replay last value. Live weight represents current state.
  final _statSubject = BehaviorSubject<DynamicValue>();

  /// INTRO records: replay last value. Device identity is current state.
  final _introSubject = BehaviorSubject<DynamicValue>();

  /// LUA records: event-only (no replay). Discrete events.
  final _luaController = StreamController<DynamicValue>.broadcast();

  // -- Valid subscribe keys --

  /// Subscribe key for batch (completed weighing) records.
  static const batchKey = 'BATCH';

  /// Subscribe key for stat (live weight) records.
  static const statKey = 'STAT';

  /// Subscribe key for intro (device identity) records.
  static const introKey = 'INTRO';

  /// Subscribe key for LUA records.
  static const luaKey = 'LUA';

  /// Set of valid top-level subscribe keys.
  static const _validKeys = {batchKey, statKey, introKey, luaKey};

  /// How this device's bytes become text.
  ///
  /// **Optional, and its default is exactly what this class always did** —
  /// `parseM2400Frame`'s own `utf8.decode(bytes, allowMalformed: true)`.
  /// Nothing in this package supplies it.
  ///
  /// It exists because the *caller* knows which device the bytes came from and
  /// this class does not: the server alias is not in scope here and should not
  /// be. A weigher that speaks Latin-1 sends `Þorskflök í raspi` as bytes that
  /// `allowMalformed` silently replaces with U+FFFD, under a good quality,
  /// with nothing in any log — and at this plant the weighers are exactly the
  /// Latin-1 devices. See
  /// `packages/tfc_relay_local/lib/src/string_encoding.dart`, which owns the
  /// per-alias policy and passes one of these in.
  final String Function(List<int> bytes)? decodeBytes;

  /// Create a wrapper for an M2400 device at [host]:[port].
  ///
  /// Optionally accepts a [socketFactory] for test injection, and a
  /// [decodeBytes] for a device that does not speak UTF-8.
  M2400ClientWrapper(this.host, this.port,
      {MSocket Function(String, int)? socketFactory, this.decodeBytes})
      : _socketFactory = socketFactory ?? MSocket.new;

  /// Current connection status (synchronous).
  ConnectionStatus get status => _status.value;

  /// Connection status stream with replay of current state.
  /// Lives for the lifetime of the wrapper, surviving connect/disconnect cycles.
  Stream<ConnectionStatus> get statusStream => _status.stream;

  /// Start connecting to the M2400 device.
  ///
  /// Creates an MSocket, wires the full parsing pipeline, and calls
  /// MSocket.connect(). Status transitions are visible via [statusStream].
  void connect() {
    // Clean up previous socket if any, but keep controllers alive
    _cleanupSocket();

    _socket = _socketFactory(host, port);

    // Wire the full pipeline:
    //   MSocket.dataStream
    //     -> M2400FrameParser (STX/ETX framing)
    //     -> parseM2400Frame (tab-separated field extraction)
    //     -> filter nulls
    //     -> parseTypedRecord (typed field parsing)
    //     -> convertRecordToDynamicValue (Phase 6 converter)
    //     -> _route (dispatch to per-type streams)
    _pipelineSubscription = _socket!.dataStream
        .transform(M2400FrameParser())
        .map((frame) => parseM2400Frame(frame, decodeBytes: decodeBytes))
        .where((r) => r != null)
        .map((r) => parseTypedRecord(r!))
        .map(convertRecordToDynamicValue)
        .listen(
      _route,
      onError: (Object e) {
        // Pipeline errors are logged but don't kill the subscription
      },
    );

    // Pipe MSocket's status into the wrapper-owned status subject.
    // When transitioning from connected → disconnected, push an error
    // to all record streams so subscribers know the connection is lost.
    _statusSubscription = _socket!.statusStream.listen((s) {
      final wasConnected = _status.value == ConnectionStatus.connected;
      if (!_status.isClosed) _status.add(s);
      if (wasConnected && s == ConnectionStatus.disconnected) {
        _broadcastDisconnectError();
      }
    });

    _socket!.connect();
  }

  /// Disconnect from the device. Does NOT close broadcast controllers --
  /// the wrapper is reusable (can call [connect] again).
  void disconnect() {
    _cleanupSocket();
  }

  /// Terminal disposal. Disconnects AND closes all controllers/subjects.
  /// After calling dispose(), this wrapper cannot be reused.
  void dispose() {
    _cleanupSocket();
    _batchController.close();
    _statSubject.close();
    _introSubject.close();
    _luaController.close();
    _status.close();
  }

  /// Return the last cached value for a key, or null if unavailable.
  ///
  /// STAT and INTRO are stateful (BehaviorSubject) — returns [valueOrNull].
  /// BATCH and LUA are event-only — always returns null.
  DynamicValue? lastValue(String key) {
    final parts = key.split('.');
    final recordKey = parts[0];
    final fieldPath = parts.length > 1 ? parts.sublist(1) : <String>[];

    if (!_validKeys.contains(recordKey)) return null;

    DynamicValue? base;
    switch (recordKey) {
      case statKey:
        base = _statSubject.valueOrNull;
        break;
      case introKey:
        base = _introSubject.valueOrNull;
        break;
      default:
        // BATCH and LUA are event-only, no cached value
        return null;
    }

    if (base == null) return null;
    if (fieldPath.isEmpty) return base;

    // Dot-notation: drill into child fields
    DynamicValue current = base;
    for (final field in fieldPath) {
      current = current[field];
    }
    return current;
  }

  /// Subscribe to a DynamicValue stream by key.
  ///
  /// Top-level keys: 'BATCH', 'STAT', 'INTRO', 'LUA'
  /// Dot-notation: 'BATCH.weight', 'STAT.unit', etc.
  ///
  /// Replay semantics:
  /// - STAT and INTRO replay the last value to new subscribers
  /// - BATCH and LUA are event-only (no replay)
  ///
  /// Throws [ArgumentError] if the root key is not recognized.
  Stream<DynamicValue> subscribe(String key) {
    final parts = key.split('.');
    final recordKey = parts[0];
    final fieldPath = parts.length > 1 ? parts.sublist(1) : <String>[];

    if (!_validKeys.contains(recordKey)) {
      throw ArgumentError.value(
          key, 'key', 'Unknown subscribe key. Valid keys: $_validKeys');
    }

    final baseStream = _streamForKey(recordKey);

    if (fieldPath.isEmpty) {
      return baseStream;
    }

    // Dot-notation: extract child DynamicValue by field name
    return baseStream.map((parent) {
      DynamicValue current = parent;
      for (final field in fieldPath) {
        current = current[field];
      }
      return current;
    });
  }

  /// Get the base stream for a top-level record key.
  Stream<DynamicValue> _streamForKey(String key) {
    switch (key) {
      case batchKey:
        return _batchController.stream;
      case statKey:
        return _statSubject.stream;
      case introKey:
        return _introSubject.stream;
      case luaKey:
        return _luaController.stream;
      default:
        throw StateError('Unreachable: key "$key" passed validation');
    }
  }

  /// Route a converted DynamicValue to the correct stream based on its name
  /// (which is the M2400RecordType.name set by convertRecordToDynamicValue).
  void _route(DynamicValue dv) {
    // The DynamicValue name was set to M2400RecordType.name in the converter
    final name = dv.name;
    switch (name) {
      case 'recBatch':
        if (!_batchController.isClosed) _batchController.add(dv);
        break;
      case 'recStat':
        if (!_statSubject.isClosed) _statSubject.add(dv);
        break;
      case 'recIntro':
        if (!_introSubject.isClosed) _introSubject.add(dv);
        break;
      case 'recLua':
        if (!_luaController.isClosed) _luaController.add(dv);
        break;
      // Unknown record types are silently dropped
    }
  }

  /// Push an error to all record streams when the connection drops.
  /// Subscribers see the error but the streams stay open for reconnection.
  void _broadcastDisconnectError() {
    final error = StateError('M2400 connection lost to $host:$port');
    if (!_batchController.isClosed) _batchController.addError(error);
    if (!_statSubject.isClosed) _statSubject.addError(error);
    if (!_introSubject.isClosed) _introSubject.addError(error);
    if (!_luaController.isClosed) _luaController.addError(error);
  }

  /// Clean up socket and pipeline subscription without closing controllers.
  void _cleanupSocket() {
    _pipelineSubscription?.cancel();
    _pipelineSubscription = null;
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _socket?.dispose();
    _socket = null;
    if (!_status.isClosed) _status.add(ConnectionStatus.disconnected);
  }
}
