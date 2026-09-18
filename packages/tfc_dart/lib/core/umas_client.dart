import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart';
import 'package:modbus_client/modbus_client.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tfc_dart/core/umas_fb_direction.dart';
import 'package:tfc_dart/core/umas_types.dart';
import 'package:tfc_dart/core/umas_var_in_out.dart';

/// A Modbus request carrying a UMAS (FC90) payload.
///
/// PDU structure: FC(0x5A) + PairingKey(1) + SubFunction(1) + Payload(N)
class UmasRequest extends ModbusRequest {
  final int umasSubFunction;
  final int pairingKey;
  final Uint8List umasPayload;

  /// Stores the raw response PDU after [internalSetFromPduResponse].
  Uint8List? responsePdu;

  // CRITICAL: All fields must be initialized via the initializer list
  // BEFORE super() runs, because ModbusRequest's constructor calls
  // protocolDataUnit getter during initialization.
  UmasRequest({
    required this.umasSubFunction,
    this.pairingKey = 0x00,
    Uint8List? payload,
    int? unitId,
    Duration? responseTimeout,
  })  : umasPayload = payload ?? Uint8List(0),
        super(unitId: unitId, responseTimeout: responseTimeout);

  @override
  FunctionCode get functionCode =>
      const ModbusFunctionCode(0x5A, FunctionType.custom);

  @override
  Uint8List get protocolDataUnit {
    final pdu = Uint8List(3 + umasPayload.length);
    pdu[0] = 0x5A; // Function code 90
    pdu[1] = pairingKey;
    pdu[2] = umasSubFunction;
    pdu.setAll(3, umasPayload);
    return pdu;
  }

  /// Variable length -- UMAS responses vary in size.
  @override
  int get responsePduLength => -1;

  @override
  ModbusResponseCode internalSetFromPduResponse(Uint8List pdu) {
    responsePdu = pdu;
    return ModbusResponseCode.requestSucceed;
  }
}

/// Client for UMAS protocol communication with Schneider PLCs via FC90.
///
/// Accepts a send function for dependency injection (use ModbusClientTcp.send
/// in production, or a mock in tests).
class UmasClient {
  /// Maximum allowed variable name length in bytes (defense against malformed responses).
  static const _maxNameLength = 1024;

  /// Maximum number of variables/data types parsed from a single response.
  static const _maxVariables = 10000;

  /// Maximum number of array elements expanded into per-element child nodes
  /// during browse(). Defensive cap against malformed or huge arrays.
  static const _maxArrayElements = 4096;
  final Future<ModbusResponseCode> Function(ModbusRequest request) sendFn;

  /// Optional Modbus unit ID for UMAS requests.
  /// Schneider PLCs typically use 255 (0xFF) or 254 (0xFE).
  final int? unitId;
  int _pairingKey = 0x00;

  /// Current UMAS session pairing key (assigned by the PLC during init/pair).
  /// Exposed for diagnostic/probe tooling that builds raw [UmasRequest]s.
  int get pairingKey => _pairingKey;

  int? maxFrameSize;

  /// Hardware identification value parsed from the PLC ident (sub-function
  /// 0x02) response. On the M580 this is a small board/firmware code
  /// (e.g. `0x60b`) — it is NOT the project-level hardware ID that Data
  /// Dictionary (0x26) requests need. See [_projectHardwareId] for the
  /// value used by ReadVariable / WriteVariable / DD requests.
  ///
  /// Kept for diagnostic logging only. Cleared by [_resetHardwareIdentifiers].
  int? _plcIdHardwareId;

  /// Project-level hardware ID parsed from memory block 0x30 (read during
  /// the init sequence by [_readProjectBlock]). On the M580 this is a
  /// large 32-bit value (e.g. `0x10c3b4e8`). Used by [_build0x26Payload]
  /// for every Data Dictionary (0x26) request — ReadVariable,
  /// WriteVariable, and DD02/DD03 traversal.
  ///
  /// Previously this and [_plcIdHardwareId] were stored in a single
  /// `_hardwareId` field; the two readers (`_readPlcId` and
  /// `_readProjectBlock`) wrote different semantic values to it, which
  /// produced misleading log noise on every re-pair and risked DD
  /// requests using the wrong ID between the two reads.
  int? _projectHardwareId;

  /// Memory block index from the 0x30 project block (or from 0x02 as a
  /// fallback before the project block has been read). Used in 0x26
  /// payloads.
  int? _index;

  /// Block CRC checksums from the last PlcStatus (0x04) response.
  /// Required by ReadVariable (0x22) and WriteVariable (0x23).
  List<int>? _blockCrcs;

  /// Project-level CRC computed from memory block 0x30 hashes
  /// (hash1 + hash2). Per PLC4X reference driver, ReadVariable (0x22) and
  /// WriteVariable (0x23) require this single project CRC, not a per-block
  /// CRC from PlcStatus. Populated by [_readProjectBlock]; null until the
  /// init sequence completes.
  int? _projectCrc;

  /// Project-level CRC for ReadVariable / WriteVariable. See [_projectCrc].
  int? get projectCrc => _projectCrc;

  /// PLC-ident hardware code, as parsed from sub-function 0x02. See
  /// [_plcIdHardwareId]. Exposed for diagnostic tooling and Fix B tests.
  @visibleForTesting
  int? get plcIdHardwareId => _plcIdHardwareId;

  /// Project-level hardware ID, as parsed from memory block 0x30. See
  /// [_projectHardwareId]. Exposed for diagnostic tooling and Fix B tests.
  @visibleForTesting
  int? get projectHardwareId => _projectHardwareId;

  /// CRCs from the previous successful PlcStatus poll, used for change detection.
  /// Null until the first successful readPlcStatus() call.
  List<int>? _previousCrcs;

  /// CRC checksums from the last PlcStatus (0x04) response.
  /// Null until [readPlcStatus] has been called successfully.
  List<int>? get blockCrcs => _blockCrcs;

  /// Maximum number of blocks accepted from PlcStatus response (T-03-02 mitigation).
  static const _maxBlocks = 256;

  /// Logger for session state transitions.
  static final _log = Logger(printer: SimplePrinter(), level: Level.info);

  /// Current session state backing field.
  UmasSessionState _stateValue = UmasSessionState.uninitialized;

  /// BehaviorSubject for reactive session state observation.
  final _stateSubject =
      BehaviorSubject<UmasSessionState>.seeded(UmasSessionState.uninitialized);

  /// Interval between keep-alive (0x12) messages when in PAIRED state.
  final Duration keepAliveInterval;

  /// F-8 (v1.1.x): interval between project-CRC re-reads. Each tick
  /// calls [refreshProjectMetadata], which re-reads memory block 0x30
  /// and emits on [projectCrcChanges] if [_projectCrc] moved. Default
  /// 30 seconds — operator-grade reprogram-while-running events are
  /// rare and a single extra TCP roundtrip every 30s is well below the
  /// noise floor of normal MonitorPlc polling.
  final Duration projectCrcCheckInterval;

  /// Periodic timer for sending keep-alive messages.
  Timer? _keepAliveTimer;

  /// F-8: periodic timer for re-checking the project CRC. Started in
  /// [startKeepAlive] (alongside the keep-alive timer), stopped in
  /// [stopKeepAlive] and [dispose].
  Timer? _projectCrcTimer;

  /// F-8: emits the new project CRC whenever [refreshProjectMetadata]
  /// observes a change. Subscribers (e.g.
  /// [ModbusDeviceClientAdapter]'s MonitorPlc batch) listen here to
  /// know they must rebuild downstream state (registered table,
  /// resolved symbol IDs) — the symbol cache itself is invalidated
  /// before the emit so a re-resolution sees the fresh data dictionary.
  ///
  /// Behaves like a broadcast stream — late subscribers do NOT receive
  /// past CRC values; they only get notified about future changes.
  final _projectCrcSubject = PublishSubject<int>();

  /// Public stream of project-CRC changes (F-8). See [_projectCrcSubject].
  Stream<int> get projectCrcChanges => _projectCrcSubject.stream;

  /// Maximum number of re-init retry attempts before propagating the error.
  static const _maxRetries = 3;

  /// Initial backoff delay for retry attempts.
  static const _initialBackoff = Duration(seconds: 1);

  /// Maximum backoff delay cap.
  static const _maxBackoff = Duration(seconds: 30);

  /// Multiplier for exponential backoff.
  static const _backoffMultiplier = 2.0;

  /// Injectable delay function for backoff (defaults to [Future.delayed]).
  final Future<void> Function(Duration) _delayFn;

  /// Whether the client has detected an M580 PLC (0xA1 error from 0x22)
  /// and should use MonitorPlc (0x50) for variable reads instead.
  ///
  /// TD-009 (v1.1.x): initial value is now constructor-injectable so the
  /// owning [ModbusDeviceClientAdapter] can carry the sticky M580-detected
  /// bit across UmasClient re-creates (each TCP reconnect spawns a fresh
  /// client). Without this, every reconnect re-probes via 0x22 → 0xA1 →
  /// 0x50 fallback, wasting one round-trip per reconnect.
  bool _useMonitorPlc;

  /// Whether this client is using the MonitorPlc (0x50) path for reads.
  /// True after detecting M580 via 0xA1 error from ReadVariable (0x22).
  bool get useMonitorPlc => _useMonitorPlc;

  // TD-022 (v1.1.x): MonitorPlc degraded-circuit breaker. Observed in
  // production on M580 at 192.168.112.159 after ~1 week uptime: every
  // 0x50 started returning 0x82, the per-key fallback in
  // ModbusDeviceClientAdapter cascaded forever because [readVariables]
  // always routes through MonitorPlc when [_useMonitorPlc] is true.
  // When tripped, [readVariables] bypasses the 0x50 branch and uses
  // the legacy 0x22 ReadVariable path. The existing 0xA1A1 catch in
  // [readVariables] still re-flips to MonitorPlc if the PLC insists,
  // so the breaker is safe: at worst one wasted RTT. [_useMonitorPlc]
  // itself is never reset (TD-009 — sticky M580 fingerprint).
  bool _monitorPlcDegraded = false;
  int _monitorPlc0x82Count = 0;
  DateTime? _monitorPlcDegradedSince;
  static const int _monitorPlc0x82TripThreshold = 3;
  static const Duration _monitorPlcDegradedRetryAfter = Duration(seconds: 60);

  /// Whether the MonitorPlc degraded-circuit breaker is currently latched.
  /// Exposed for adapter telemetry and TD-022 tests.
  bool get monitorPlcDegraded => _monitorPlcDegraded;

  /// Injectable clock for TD-022 tests that advance time past
  /// [_monitorPlcDegradedRetryAfter] without real-time delays.
  DateTime Function() _nowFn = DateTime.now;

  @visibleForTesting
  set nowFn(DateTime Function() fn) => _nowFn = fn;

  /// MonitorPlc (0x50) registration table for tracking registered variables.
  final MonitorPlcRegistrationTable _monitorTable =
      MonitorPlcRegistrationTable();

  /// Expose the registration table for inspection/testing.
  MonitorPlcRegistrationTable get monitorRegistrations => _monitorTable;

  // ---------------------------------------------------------------------------
  // Symbol cache (B-3 v1.1.x) — read/write by UMAS variable name.
  // ---------------------------------------------------------------------------

  /// Resolved-symbol cache keyed by full dotted path (e.g.
  /// `B_F1_RC_01_Front` or `M_Elevator.speed`). Populated lazily on first
  /// [lookupSymbol] miss by issuing [browse], or eagerly by callers that
  /// invoke [browse] up front. Invalidated by [_handleSessionError] (PLC
  /// reboot) and by [invalidateSymbolCacheIfProjectChanged].
  final Map<String, ResolvedSymbol> _symbolCache = {};

  /// Cross-call caches re-used by [browse]'s struct/FB and array
  /// resolution. Hoisted to per-client lifetime so consecutive browses
  /// don't re-issue DD02 for the same custom type id (F-3 from v1.1
  /// Phase 2 SUMMARY).
  final Map<int, List<UmasVariable>> _persistentMemberCache = {};
  final Map<int, UmasArrayTypeDefinition?> _persistentArrayCache = {};

  /// Project CRC observed when the symbol cache was last populated. Used
  /// by [invalidateSymbolCacheIfProjectChanged] to flush the cache when
  /// the PLC project is reprogrammed.
  int? _symbolCacheProjectCrc;

  /// True once [browse] has populated the symbol cache for this session.
  bool _symbolCacheBuilt = false;

  /// Synchronous lock so concurrent first-time lookups share one browse.
  Completer<void>? _symbolCacheLock;

  /// Number of cached symbols (for testing / instrumentation).
  int get symbolCacheSize => _symbolCache.length;

  /// True if a symbol cache build has completed for the current session.
  bool get symbolCacheBuilt => _symbolCacheBuilt;

  /// Inject a [ResolvedSymbol] directly into the cache for tests that
  /// need to assert behavior of [readVariableByName] / [writeVariableByName]
  /// without standing up a full browse against the Python stub. Used
  /// e.g. to verify the F-7 VAR_IN_OUT write refusal path with a
  /// readable=false sentinel.
  @visibleForTesting
  void debugInjectSymbol(ResolvedSymbol sym) {
    _symbolCache[sym.path] = sym;
    _symbolCacheBuilt = true;
  }

  /// TD-004 (v1.1.x) test hook: force a session-state transition so
  /// the adapter's [EffectiveDeviceStatus] stream emits without
  /// having to drive a real handshake. Used by tests that need to
  /// verify the unhealthy / paired transitions without relying on
  /// the stub server's pairing flow.
  @visibleForTesting
  void debugSetSessionState(UmasSessionState newState) {
    _setState(newState);
  }

  /// Test hook: override the project CRC used by ReadVariable /
  /// WriteVariable requests. Lets unit tests drive [writeVariable]
  /// (and therefore [writeVariableByName]) without
  /// running the full session-init handshake that normally populates
  /// [_projectCrc] via [_readProjectBlock].
  @visibleForTesting
  void debugSetProjectCrc(int crc) {
    _projectCrc = crc;
  }

  /// Test hook: override the block-CRC list. [writeVariable] guards on
  /// `_blockCrcs != null && _blockCrcs.isNotEmpty` to refuse writes
  /// before the first [readPlcStatus] response; this hook lets unit
  /// tests bypass that guard without driving a real status poll.
  ///
  /// On the wire, [writeVariable] prefers [_projectCrc] over
  /// `blockCrcs[0]` — so for tests that also set [debugSetProjectCrc]
  /// the contents here are only used to clear the guard, not on the
  /// PDU itself.
  @visibleForTesting
  void debugSetBlockCrcs(List<int> crcs) {
    _blockCrcs = List<int>.from(crcs);
  }

  UmasClient({
    required this.sendFn,
    this.unitId,
    this.keepAliveInterval = const Duration(seconds: 10),
    this.projectCrcCheckInterval = const Duration(seconds: 30),
    Future<void> Function(Duration)? backoffDelay,
    bool useMonitorPlc = false,
    this.decodeString,
  })  : _delayFn = backoffDelay ?? ((d) => Future.delayed(d)),
        _useMonitorPlc = useMonitorPlc;

  /// How this PLC's STRING / BYTE_STRING bytes become text.
  ///
  /// **Optional, and its default is what this client always did** — see
  /// [parseVariableValue]'s own `decodeString`, which falls back to
  /// `utf8.decode(bytes, allowMalformed: true)`. It is threaded through
  /// straight to the parser and used nowhere else.
  ///
  /// It exists because the *caller* knows which server the bytes came from and
  /// this class does not. A Saia-over-Modbus device speaking Latin-1 sends
  /// `Þorskflök` as bytes `allowMalformed` silently turns into U+FFFD, under a
  /// good quality, with nothing in any log. The per-alias policy lives in
  /// `packages/tfc_relay_local/lib/src/string_encoding.dart`, which is the one
  /// layer that knows both the alias and the decode.
  final UmasStringDecoder? decodeString;

  /// Start periodic keep-alive timer. Cancels any existing timer first.
  ///
  /// The timer calls [readPlcStatus] (sub-function 0x04) every
  /// [keepAliveInterval]. If the session is not in PAIRED state, the
  /// tick is skipped. A transport-level failure resets the session via
  /// [_handleSessionError]; a byte-level UMAS error from the PLC is
  /// logged at warning and does NOT reset the session (Fix A).
  ///
  /// **Why plcStatus, not the dedicated KeepAlive (0x12) sub-function?**
  /// UMAS 0x12 is `umas_QueryKeepPLCReservation` — it queries whether
  /// the caller's reservation is still alive. On the M580 firmware
  /// (verified via live byte capture against 192.168.112.159,
  /// 2026-05-20) the PLC rejects every 0x12 from
  /// a non-reserved client with `status=0xFD errorCode=0x81
  /// secondary=0x80`. The HMI is a read-only client and never calls
  /// [takePlcReservation], so 0x12 would generate a continuous warning
  /// log every interval. plc4j's umas.mspec has no 0x12 case for the
  /// same reason — it relies on harmless read traffic as the heartbeat.
  /// `readPlcStatus()` (0x04, public, no reservation required) is the
  /// idiomatic choice and has the side-benefit of refreshing
  /// `_projectCrc` / `_blockCrcs` on every tick.
  ///
  /// F-8 (v1.1.x): also starts the separate [_projectCrcTimer] that
  /// periodically re-reads memory block 0x30 to detect PLC reprograms
  /// without a session-level error. With the timer now driven by 0x04
  /// (which already returns the project CRC list), the CRC timer is
  /// strictly belt-and-suspenders — keep it for now to preserve test
  /// coverage of refreshProjectMetadata.
  void startKeepAlive() {
    stopKeepAlive();
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) async {
      if (_stateValue != UmasSessionState.paired) return;
      try {
        await readPlcStatus();
      } on UmasException catch (e) {
        // Fix A: only invalidate for genuine transport-level failures.
        // A malformed-echo / parse error should not flush the session
        // and trigger a 1082-entry symbol-cache rebuild on the next tick.
        if (_isFatalSessionError(e)) {
          _handleSessionError();
        } else {
          _log.w('UmasClient keep-alive failed (non-fatal): $e');
        }
      } catch (e) {
        // Unknown / non-UmasException — assume the worst (transport
        // imploded). Prevent unhandled exceptions in timer callback.
        _log.w('UmasClient keep-alive threw non-UmasException: $e');
        _handleSessionError();
      }
    });
    _projectCrcTimer = Timer.periodic(projectCrcCheckInterval, (_) async {
      if (_stateValue != UmasSessionState.paired) return;
      try {
        await refreshProjectMetadata();
      } catch (e) {
        // Best-effort: a single failed CRC read should NOT bring down
        // the session. The next tick will retry; if the underlying
        // session is genuinely broken, keep-alive will catch it.
        _log.w('UmasClient projectCrc tick failed: $e');
      }
    });
  }

  /// Stop the keep-alive timer (and the F-8 project-CRC timer).
  void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _projectCrcTimer?.cancel();
    _projectCrcTimer = null;
  }

  /// Release resources (cancels keep-alive timer and closes the session state stream).
  void dispose() {
    stopKeepAlive();
    _stateSubject.close();
    if (!_projectCrcSubject.isClosed) {
      _projectCrcSubject.close();
    }
  }

  /// Current session state.
  UmasSessionState get sessionState => _stateValue;

  /// Stream of session state changes (seeded with current state).
  Stream<UmasSessionState> get sessionStream => _stateSubject.stream;

  /// Transition to a new session state with logging.
  void _setState(UmasSessionState newState) {
    if (_stateValue != newState) {
      _log.i('UmasClient: $_stateValue -> $newState');
      _stateValue = newState;
      if (!_stateSubject.isClosed) {
        _stateSubject.add(newState);
      }
    }
  }

  /// Lock to serialize concurrent session initialization.
  Completer<void>? _initLock;

  /// Ensures the UMAS session is fully initialized (paired) before running
  /// [operation]. Auto-runs readPlcId and/or init as needed. Concurrent
  /// callers wait on the same initialization via a Completer lock.
  ///
  /// If initialization fails, retries with exponential backoff up to
  /// [_maxRetries] times. On success, resets backoff counter and starts
  /// the keep-alive timer.
  Future<T> _withSession<T>(Future<T> Function() operation) async {
    if (_stateValue == UmasSessionState.paired) {
      return operation();
    }
    // Serialize initialization — concurrent callers wait on the same lock
    if (_initLock != null) {
      await _initLock!.future;
      return operation();
    }
    _initLock = Completer<void>();
    // Prevent unhandled async error if no concurrent caller is waiting
    _initLock!.future.ignore();
    try {
      await _initWithRetry();
      _initLock!.complete();
    } catch (e) {
      _initLock!.completeError(e);
      rethrow;
    } finally {
      _initLock = null;
    }
    return operation();
  }

  /// Run the init sequence (readPlcId + init + readProjectBlock) with exponential backoff retry.
  Future<void> _initWithRetry() async {
    Object? lastError;
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        if (_stateValue == UmasSessionState.uninitialized) {
          await readPlcId();
        }
        if (_stateValue == UmasSessionState.identified) {
          await init();
        }
        // Read the real hardwareId/index from memory block 0x30
        // (readPlcId returns PLC ident, NOT the project-level values
        // needed for Data Dictionary requests)
        await _readProjectBlock();
        // Success — start keep-alive
        startKeepAlive();
        return;
      } catch (e) {
        lastError = e;
        // Fix A: do NOT call _handleSessionError on every failed attempt.
        // A single root failure would otherwise produce up to
        // (_maxRetries + 1) "session invalidated" log entries in quick
        // succession. Reset only the state-machine bits so the next
        // attempt re-runs readPlcId / init cleanly; the full invalidate
        // (which nukes the symbol cache) waits until the WHOLE retry
        // loop has been exhausted, below.
        _setState(UmasSessionState.uninitialized);
        _pairingKey = 0x00;
        if (attempt < _maxRetries) {
          final delay = _computeBackoff(attempt);
          await _delayFn(delay);
        }
      }
    }
    // All retries exhausted — only NOW do we nuke the full session +
    // symbol cache. Anything that resumes after this will re-pair from
    // scratch.
    _handleSessionError();
    if (lastError is Exception) {
      throw lastError;
    }
    throw UmasException(
        errorCode: 0, message: 'Init failed after $_maxRetries retries');
  }

  /// Compute backoff delay for a given attempt number.
  Duration _computeBackoff(int attempt) {
    final delayMs = _initialBackoff.inMilliseconds *
        _pow(_backoffMultiplier, attempt);
    final cappedMs = delayMs.clamp(0, _maxBackoff.inMilliseconds);
    return Duration(milliseconds: cappedMs.toInt());
  }

  /// Integer-safe power for backoff multiplier.
  static double _pow(double base, int exp) {
    double result = 1.0;
    for (int i = 0; i < exp; i++) {
      result *= base;
    }
    return result;
  }

  /// UMAS success status byte value.
  static const _statusSuccess = 0xFE;

  /// UMAS error status byte value (followed by error code byte).
  static const _statusError = 0xFD;

  /// Check UMAS response PDU and throw on error.
  ///
  /// Real Schneider PLC response format (3-byte header):
  ///   pdu[0] = FC (0x5A)
  ///   pdu[1] = PairingKey
  ///   pdu[2] = Status (0xFE=success, 0xFD=error, other=error code)
  ///   pdu[3+] = Payload (on success) or error code (on 0xFD error)
  ///
  /// SWEEP-03 (v1.1): always prefixes the [operation] token (e.g.
  /// `"writeVariable"`, `"readDD02(blockNo=0x...)"`) so operator log
  /// greps can isolate failures by sub-function. Every caller passes
  /// a stable operation name — the previous implementation did so
  /// inconsistently; this is now the contract.
  void _checkStatus(Uint8List pdu, String operation) {
    if (pdu.length < 3) {
      throw UmasException(
          errorCode: 0, message: 'UMAS $operation response too short');
    }
    final status = pdu[2];
    if (status == _statusError) {
      final errorCode = pdu.length > 3 ? pdu[3] : 0;
      // TD-017 (v1.1.x): forward the second error byte when present so
      // [readVariables] can require 0xA1A1 (not bare 0xA1) for M580
      // auto-detection.
      final secondaryErrorCode = pdu.length > 4 ? pdu[4] : null;
      throw UmasException(
          errorCode: errorCode,
          secondaryErrorCode: secondaryErrorCode,
          message: 'UMAS $operation error: '
              '0x${errorCode.toRadixString(16)}');
    }
    if (status != _statusSuccess) {
      throw UmasException(
          errorCode: status,
          message: 'UMAS $operation failed with status '
              '0x${status.toRadixString(16)}');
    }
  }

  /// Read PLC identification (sub-function 0x02).
  ///
  /// Extracts hardwareId and memory block index needed for 0x26 requests.
  /// Must be called before readVariableNames/readDataTypes/browse.
  Future<UmasPlcIdent> readPlcId() async {
    final request = UmasRequest(
      umasSubFunction: UmasSubFunction.readId.code,
      pairingKey: _pairingKey,
      unitId: unitId,
    );
    final code = await sendFn(request);

    if (code != ModbusResponseCode.requestSucceed) {
      throw UmasException(
          errorCode: code.code,
          message: 'UMAS readPlcId failed: ${code.name}');
    }

    final pdu = request.responsePdu;
    if (pdu == null || pdu.length < 3) {
      throw UmasException(
          errorCode: 0, message: 'Empty UMAS readPlcId response');
    }

    _checkStatus(pdu, 'readPlcId');

    // Parse payload after the 3-byte header (FC + pairing + status)
    final payload = pdu.sublist(3);
    if (payload.length < 7) {
      throw UmasException(
          errorCode: 0,
          message: 'UMAS readPlcId response too short: ${payload.length}');
    }

    final pd = ByteData.sublistView(payload);
    // range(2) + ident/hardwareId(4 LE) + numberOfMemoryBanks(1) + memBlockEntries
    // Skip range (2 bytes), read hardwareId (4 bytes LE)
    final hardwareId = pd.getUint32(2, Endian.little);

    // numberOfMemoryBanks at offset 6
    final numberOfMemoryBanks = pd.getUint8(6);

    // First memory block entry starts at offset 7:
    //   address(2 LE) + blockType(1) + unknown(2) + memoryLength(4) = 9 bytes
    int index = 0;
    if (numberOfMemoryBanks > 0 && payload.length >= 9) {
      index = pd.getUint16(7, Endian.little);
    }

    // Fix B: store the PLC-ident hardware code in its own field. Data
    // Dictionary requests use [_projectHardwareId] (from memory block
    // 0x30), populated by _readProjectBlock during the init sequence.
    _plcIdHardwareId = hardwareId;
    _index = index;
    _setState(UmasSessionState.identified);

    return UmasPlcIdent(
      hardwareId: hardwareId,
      index: index,
      numberOfMemoryBanks: numberOfMemoryBanks,
    );
  }

  /// Initialize UMAS communication (sub-function 0x01).
  /// Returns max frame size and optionally firmware version.
  ///
  /// Per PLC4X mspec UmasPDUInitCommsRequest, the request body is a single
  /// `subCode` byte (always 0x00 in the reference implementation). Without it
  /// the M580 rejects with status 0x83.
  Future<UmasInitResult> init() async {
    final request = UmasRequest(
        umasSubFunction: UmasSubFunction.init.code,
        pairingKey: _pairingKey,
        payload: Uint8List.fromList([0x00]),
        unitId: unitId);
    final code = await sendFn(request);

    if (code != ModbusResponseCode.requestSucceed) {
      throw UmasException(
          errorCode: code.code, message: 'UMAS init failed: ${code.name}');
    }

    final pdu = request.responsePdu;
    if (pdu == null || pdu.length < 3) {
      throw UmasException(errorCode: 0, message: 'Empty UMAS init response');
    }

    _checkStatus(pdu, 'init');

    // PDU: FC(0x5A) + pairingKey + status + payload
    final responsePairingKey = pdu[1];
    _pairingKey = responsePairingKey;

    // Parse payload after the 3-byte header (FC + pairing + status)
    if (pdu.length >= 5) {
      final payloadView = ByteData.sublistView(pdu, 3);
      maxFrameSize = payloadView.getUint16(0, Endian.little);
    }

    _setState(UmasSessionState.paired);

    return UmasInitResult(maxFrameSize: maxFrameSize ?? 240);
  }

  /// Read project-level hardwareId and index from memory block 0x30.
  ///
  /// PLC4X reads these values from memory — NOT from readPlcId (0x02).
  /// The readPlcId response contains PLC identification fields, but the
  /// hardwareId/index needed for Data Dictionary (0x26) requests come
  /// from the project memory block at address 0x30.
  ///
  /// Format (UmasMemoryBlockBasicInfo from PLC4X mspec):
  ///   range(2 LE) + notSure(2 LE) + index(1) + hardwareId(4 LE)
  Future<void> _readProjectBlock() async {
    final payload = ByteData(9);
    payload.setUint8(0, 0x00); // range
    payload.setUint16(1, 0x0030, Endian.little); // blockNumber
    payload.setUint16(3, 0x0000, Endian.little); // offset
    payload.setUint16(5, 0x0000, Endian.little); // unknownObject1
    payload.setUint16(7, 0x0021, Endian.little); // numberOfBytes (33)

    final request = UmasRequest(
      umasSubFunction: UmasSubFunction.readMemoryBlock.code,
      pairingKey: _pairingKey,
      payload: payload.buffer.asUint8List(),
      unitId: unitId,
    );
    final code = await sendFn(request);

    if (code != ModbusResponseCode.requestSucceed) {
      _log.w('ReadMemoryBlock(0x30) failed: ${code.name} '
          '— using readPlcId values for DD requests');
      return;
    }

    final pdu = request.responsePdu;
    if (pdu == null || pdu.length < 3) return;

    try {
      _checkStatus(pdu, 'readMemoryBlock(0x30)');
    } on UmasException catch (e) {
      _log.w('ReadMemoryBlock(0x30) error: ${e.message} '
          '— using readPlcId values for DD requests');
      return;
    }

    // Response: 3-byte header + range(1) + numberOfBytes(2 LE) + data
    final respPayload = pdu.sublist(3);
    if (respPayload.length < 12) return; // need at least header + 9 bytes

    final respView = ByteData.sublistView(respPayload);
    final numberOfBytes = respView.getUint16(1, Endian.little);
    if (numberOfBytes < 9) return;

    // Parse UmasMemoryBlockBasicInfo at offset 3 (after range + numberOfBytes)
    // range(2 LE) + notSure(2 LE) + index(1) + hardwareId(4 LE) = 9 bytes
    // followed by hash1(4 LE) + hash2(4 LE) (PLC4X discovery from packet
    // captures: projectCrc = (hash1 + hash2) & 0xFFFFFFFF)
    final blockData = ByteData.sublistView(respPayload, 3);
    final projectIndex = blockData.getUint8(4);
    final projectHardwareId = blockData.getUint32(5, Endian.little);

    int? projectCrc;
    if (blockData.lengthInBytes >= 17) {
      final hash1 = blockData.getUint32(9, Endian.little);
      final hash2 = blockData.getUint32(13, Endian.little);
      projectCrc = (hash1 + hash2) & 0xFFFFFFFF;
    }

    // Fix B: log the previous PROJECT hardware ID (not the PLC-ident one)
    // so the "was:" hint actually compares like-for-like. Previously the
    // field was shared, so this line printed the readPlcId value on every
    // re-pair regardless of the real prior project hardware ID.
    _log.i('Project block 0x30: index=$projectIndex, '
        'hardwareId=0x${projectHardwareId.toRadixString(16)}, '
        'projectCrc=${projectCrc == null ? 'n/a' : '0x${projectCrc.toRadixString(16)}'} '
        '(was: index=${_index}, '
        'projectHwId=0x${(_projectHardwareId ?? 0).toRadixString(16)})');

    _index = projectIndex;
    _projectHardwareId = projectHardwareId;
    _projectCrc = projectCrc;
  }

  /// Read project info (sub-function 0x03).
  ///
  /// Returns raw response bytes and a best-effort extracted project name.
  /// The [subcode] parameter selects the type of project info to retrieve
  /// (default 0x00).
  ///
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<ProjectInfoResult> readProjectInfo({int subcode = 0x00}) async {
    return _withSession(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readProjectInfo.code,
        pairingKey: _pairingKey,
        payload: Uint8List.fromList([subcode]),
        unitId: unitId,
      );
      final code = await sendFn(request);

      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'UMAS readProjectInfo failed: ${code.name}');
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty UMAS readProjectInfo response');
      }

      _checkStatus(pdu, 'readProjectInfo');

      // Raw data is everything after the 3-byte UMAS header
      final rawData = pdu.sublist(3);

      // Best-effort project name extraction: find the longest run of
      // printable ASCII bytes (0x20-0x7E).
      final projectName = _extractLongestAsciiRun(rawData);

      return ProjectInfoResult(rawData: rawData, projectName: projectName);
    });
  }

  /// Extract a best-effort human-readable project name from a raw
  /// [readProjectInfo] payload.
  ///
  /// **TD-016 (v1.1.x):** Schneider PLCs in non-Western locales (Kanji,
  /// Cyrillic, accented Latin) embed project names as UTF-8 in the
  /// 0x03 response. The previous implementation hard-coded
  /// `0x20..0x7E` and returned null or garbage for such projects.
  ///
  /// Strategy:
  ///   1. Find every contiguous run of non-control / non-zero bytes
  ///      (skip 0x00 NUL, 0x01..0x1F C0-controls except tab/lf, and
  ///      the C1-range 0x7F..0x9F).
  ///   2. For each candidate run, attempt `utf8.decode(allowMalformed: true)`.
  ///      Score the decoded string by the ratio of alpha-numeric +
  ///      symbol characters to total characters; reject if too many
  ///      replacement characters (U+FFFD) leak through.
  ///   3. Return the highest-scoring run of >=2 characters.
  ///
  /// Falls back to a pure-ASCII run when no UTF-8 run scores well —
  /// matches the previous behavior for the common case of plain-ASCII
  /// names.
  /// Test hook for TD-016: exposes the (now UTF-8-aware) project-name
  /// extraction so the unit test can pin behavior without mocking a
  /// full readProjectInfo round-trip.
  @visibleForTesting
  static String? debugExtractProjectName(Uint8List data) =>
      _extractLongestAsciiRun(data);

  static String? _extractLongestAsciiRun(Uint8List data) {
    // Collect candidate runs (start, end-exclusive).
    final runs = <(int, int)>[];
    int runStart = -1;
    bool isPrintableByte(int b) {
      // Allow any byte that could plausibly be UTF-8: skip C0 controls
      // (0x00..0x1F) and DEL (0x7F). High-bit bytes (>=0x80) stay in
      // because they're UTF-8 continuation or lead bytes.
      return b >= 0x20 && b != 0x7F;
    }

    for (int i = 0; i <= data.length; i++) {
      final inRun = i < data.length && isPrintableByte(data[i]);
      if (inRun) {
        if (runStart < 0) runStart = i;
      } else {
        if (runStart >= 0) {
          runs.add((runStart, i));
          runStart = -1;
        }
      }
    }

    String? bestUtf8;
    int bestUtf8Score = 0;
    String? bestAscii;
    int bestAsciiLen = 0;

    for (final (start, end) in runs) {
      final len = end - start;
      if (len < 2) continue;
      final slice = data.sublist(start, end);

      // Try UTF-8 decode (allowMalformed leaves U+FFFD on bad
      // sequences instead of throwing). Score by the count of
      // characters that aren't the replacement marker so a
      // mostly-binary run with a few accidental valid lead bytes
      // doesn't beat a clean ASCII run.
      try {
        final decoded = utf8.decode(slice, allowMalformed: true);
        var score = 0;
        for (final cp in decoded.runes) {
          if (cp == 0xFFFD) continue; // replacement char
          if (cp < 0x20) continue; // control
          score++;
        }
        // Require at least 50% of the run to decode to valid
        // characters — otherwise we're looking at binary that
        // happened to have a few printable ASCII bytes.
        if (score >= 2 && score * 2 >= decoded.runes.length) {
          if (score > bestUtf8Score) {
            bestUtf8Score = score;
            bestUtf8 = decoded.replaceAll('�', '');
          }
        }
      } catch (_) {
        // utf8.decode shouldn't throw with allowMalformed=true, but
        // belt-and-suspenders.
      }

      // Also track the longest pure-ASCII (0x20..0x7E) sub-run as a
      // conservative fallback. This preserves the previous behavior
      // for the common Western-PLC case where the UTF-8 decode and
      // ASCII match degenerate to the same thing.
      var asciiStart = -1;
      for (int j = start; j <= end; j++) {
        final isAscii =
            j < end && data[j] >= 0x20 && data[j] <= 0x7E;
        if (isAscii) {
          if (asciiStart < 0) asciiStart = j;
        } else if (asciiStart >= 0) {
          final asciiLen = j - asciiStart;
          if (asciiLen > bestAsciiLen) {
            bestAsciiLen = asciiLen;
            bestAscii = String.fromCharCodes(data, asciiStart, j);
          }
          asciiStart = -1;
        }
      }
    }

    if (bestUtf8 != null && bestUtf8Score >= 2) return bestUtf8;
    return bestAsciiLen >= 2 ? bestAscii : null;
  }

  /// Build the full 13-byte payload for 0x26 (ReadDataDictionary) requests.
  ///
  /// Format per PLC4X mspec:
  ///   recordType(2 LE) + index(1) + hardwareId(4 LE) + blockNo(2 LE) +
  ///   offset(2 LE)
  /// DD02 also appends a 2-byte trailing blank field. DD03 does NOT —
  /// sending the extra 2 bytes makes the M580 return error 0xC0.
  Uint8List _build0x26Payload({
    required int recordType,
    required int blockNo,
    required int offset,
  }) {
    final includeBlank = recordType == 0xDD02;
    final bd = ByteData(includeBlank ? 13 : 11);
    bd.setUint16(0, recordType, Endian.little);
    bd.setUint8(2, _index ?? 0);
    // Fix B: Data Dictionary requests need the PROJECT-level hardware ID
    // (from memory block 0x30). The init sequence calls _readProjectBlock
    // so this is normally non-null by the time 0x26 requests fire. Fall
    // back to the readPlcId-level value when block 0x30 was unavailable
    // — this matches the long-standing "using readPlcId values for DD
    // requests" log inside _readProjectBlock and preserves the pre-Fix-B
    // behaviour against PLCs that don't expose block 0x30.
    bd.setUint32(
        3, _projectHardwareId ?? _plcIdHardwareId ?? 0, Endian.little);
    bd.setUint16(7, blockNo, Endian.little);
    bd.setUint16(9, offset, Endian.little);
    if (includeBlank) {
      bd.setUint16(11, 0x0000, Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  /// Read variable names from the data dictionary (0x26 with record type 0xDD02).
  ///
  /// Auto-initializes the session if needed via [_withSession].
  /// Paginates: loops until nextAddress == 0 after first response.
  Future<List<UmasVariable>> readVariableNames() async {
    return _withSessionAndRecovery(_readVariableNamesInner);
  }

  Future<List<UmasVariable>> _readVariableNamesInner() async {
    return _readDD02Block(blockNo: 0xFFFF, isMemberLayout: false);
  }

  /// Read DD02 records for a given blockNo, paginating across nextAddress.
  ///
  /// blockNo=0xFFFF returns the top-level variable list (10-byte record
  /// header per entry). blockNo=<typeId> returns the member layout of
  /// that struct/FB type (8-byte record header per entry, since the
  /// flags+unknown4 bytes are absent for member records).
  ///
  /// [parentClassId] — when this block represents a member layout, the
  /// classIdentifier of the parent type (2=STRUCT/UDT, 7=FB). Direction
  /// classification only runs when parentClassId==7 (FB members). For
  /// non-FB UDTs the direction stays null so the UI renders members
  /// undecorated (F-1 v1.1: fixes the case where the byte-classifier
  /// fired on arbitrary UDT struct fields).
  Future<List<UmasVariable>> _readDD02Block({
    required int blockNo,
    required bool isMemberLayout,
    int? parentClassId,
  }) async {
    final all = <UmasVariable>[];
    int offset = 0x0000;
    bool first = true;

    while (offset != 0x0000 || first) {
      first = false;
      final payload = _build0x26Payload(
        recordType: 0xDD02,
        blockNo: blockNo,
        offset: offset,
      );
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readDataDictionary.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'Data Dictionary read failed: ${code.name}');
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty data dictionary response');
      }
      _checkStatus(pdu, 'readDD02(blockNo=0x${blockNo.toRadixString(16)})');
      final (nextAddress, variables) = _parseVariableRecords(
        pdu.sublist(3),
        isMemberLayout: isMemberLayout,
        parentClassId: parentClassId,
      );
      all.addAll(variables);
      offset = nextAddress;
    }
    return all;
  }

  /// Read the member layout for a struct/FB data type.
  ///
  /// Returns the members; each [UmasVariable]'s `blockNo` is the byte offset
  /// of that member within the parent struct, and `dataTypeId` is the member's
  /// own type id (resolved against [readDataTypes]).
  ///
  /// [parentClassId] — the classIdentifier of the parent type (2 for
  /// STRUCT/UDT, 7 for FB). When omitted, direction classification is
  /// suppressed (safe default) — callers that know the parent is an FB
  /// should pass 7 to get per-member direction in the returned values.
  Future<List<UmasVariable>> readStructMembers(int typeId,
      {int? parentClassId}) async {
    return _withSessionAndRecovery(() => _readDD02Block(
        blockNo: typeId,
        isMemberLayout: true,
        parentClassId: parentClassId));
  }

  /// Read raw DD02 response bytes for [blockNo].
  ///
  /// Returns the response payload after the 3-byte UMAS header. For struct
  /// types this is the standard variable-record list; for array types this
  /// is a [UmasArrayTypeDefinition] (classId(1) + elementTypeId(2) +
  /// numberOfDimensions(1) + dimensions[]) followed by the dictionary
  /// header. Used by [_resolveArrayTypeDefinition] to extract per-element
  /// metadata for arrays.
  Future<Uint8List> readDD02Raw(int blockNo) async {
    return _withSessionAndRecovery(() async {
      final payload = _build0x26Payload(
        recordType: 0xDD02,
        blockNo: blockNo,
        offset: 0x0000,
      );
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readDataDictionary.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'DD02 raw read failed: ${code.name}');
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty DD02 raw response');
      }
      _checkStatus(pdu, 'readDD02Raw(blockNo=0x${blockNo.toRadixString(16)})');
      return pdu.sublist(3);
    });
  }

  /// Parse variable name records from the 0xDD02 response payload.
  ///
  /// Header: range(1) + nextAddress(2 LE) + unknown1(2 LE) + noOfRecords(2 LE)
  /// Per-record (variable-length header followed by null-terminated UTF-8 name):
  ///   dataType(2 LE) + block(2 LE) + offset(4 LE) + flags(1)
  ///   [+ extra(1) when flags != 0]
  ///   + name\0
  ///
  /// The `flags` byte is 0 for plain struct members and non-zero for
  /// top-level variables / FB members where an additional byte follows
  /// before the name.
  ///
  /// The same wire format serves both top-level variable lists and struct
  /// member lists. For struct members, `block` holds the member's byte
  /// offset within the parent struct instead of a memory block number.
  (int nextAddress, List<UmasVariable>) _parseVariableRecords(
    Uint8List data, {
    required bool isMemberLayout,
    int? parentClassId,
  }) {
    if (data.length < 7) return (0, []);

    final hd = ByteData.sublistView(data);
    final nextAddress = hd.getUint16(1, Endian.little);
    final noOfRecords = hd.getUint16(5, Endian.little);

    final variables = <UmasVariable>[];
    int pos = 7;

    // Top-level records have a 10-byte header (dataType + block + offset
    // + flags + unknown4) before the null-terminated name.
    // Member records have an 8-byte header (dataType + block + offset)
    // before the name; flags/unknown4 are absent.
    final headerSize = isMemberLayout ? 8 : 10;

    for (int i = 0; i < noOfRecords && pos + headerSize <= data.length; i++) {
      if (variables.length >= _maxVariables) break;

      final view = ByteData.sublistView(data, pos);
      final dataTypeId = view.getUint16(0, Endian.little);
      final blockNo = view.getUint16(2, Endian.little);
      final offset = view.getUint32(4, Endian.little);

      // Phase 3 / v1.1 calibration: for member-layout records, the two
      // uint16 LE values at bytes 4-5 and 6-7 are plc4j's `unknown5` and
      // `unknown4` fields (see UmasUDTDefinition mspec). Bytes 4-7 are
      // also re-read above as a uint32 `offset` — the two views coexist
      // because Dart's getUint32(LE) is identical to (getUint16(4,LE) |
      // getUint16(6,LE) << 16). Live-PLC calibration on the M580 at
      // 192.168.112.159 (see tools/umas_direction_calibration.dart)
      // showed that only `unknown4` carries direction; `unknown5` is
      // always zero. F-1: only classify when the parent is an FB
      // (classIdentifier==7); non-FB UDT struct members keep
      // direction=null so the UI renders them undecorated.
      UmasFbMemberDirection? direction;
      if (isMemberLayout && parentClassId == 7) {
        final unknown5 = view.getUint16(4, Endian.little);
        final unknown4 = view.getUint16(6, Endian.little);
        direction = classifyFbMemberDirection(unknown5, unknown4);
      }
      pos += headerSize;

      int end = pos;
      while (end < data.length && data[end] != 0x00) {
        end++;
      }
      if (end >= data.length || end - pos > _maxNameLength) {
        break;
      }
      final name = utf8.decode(data.sublist(pos, end), allowMalformed: true);
      pos = end + 1;

      if (name.isEmpty) continue;

      variables.add(UmasVariable(
        name: name,
        blockNo: blockNo,
        offset: offset,
        dataTypeId: dataTypeId,
        direction: direction,
      ));
    }

    return (nextAddress, variables);
  }

  /// Read data type references from the data dictionary (0x26 with record type 0xDD03).
  ///
  /// Auto-initializes the session if needed via [_withSession].
  /// Paginates: loops until nextAddress == 0 after first response.
  Future<List<UmasDataTypeRef>> readDataTypes() async {
    return _withSessionAndRecovery(_readDataTypesInner);
  }

  Future<List<UmasDataTypeRef>> _readDataTypesInner() async {
    final allTypes = <UmasDataTypeRef>[];
    int blockNo = 0x0000;
    bool firstMessage = true;

    while (blockNo != 0x0000 || firstMessage) {
      firstMessage = false;

      final payload = _build0x26Payload(
        recordType: 0xDD03,
        blockNo: blockNo,
        offset: 0x0000,
      );
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readDataDictionary.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);

      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'Data Dictionary type read failed: ${code.name}');
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty data type response');
      }

      _checkStatus(pdu, 'readDataTypes');

      final (nextAddress, types) = _parseDataTypeRecords(pdu.sublist(3));
      allTypes.addAll(types);
      blockNo = nextAddress;
    }

    return allTypes;
  }

  /// Parse data type records from the 0xDD03 response payload.
  ///
  /// Per PLC4X UmasPDUReadDatatypeNamesResponse mspec:
  ///   Header: range(1) + unknown1(4) + noOfRecords(2 LE) = 7 bytes
  ///   Per record (UmasDatatypeReference):
  ///     dataSize(2 LE) + unknown1(2 LE) + classIdentifier(1) + dataType(1)
  ///     + reserved 0x00(1) + null-terminated UTF-8 name
  ///
  /// DD03 does not paginate — the entire type table arrives in a single
  /// response, so the returned nextAddress is always 0.
  (int nextAddress, List<UmasDataTypeRef>) _parseDataTypeRecords(
      Uint8List data) {
    if (data.length < 7) return (0, []);

    final hd = ByteData.sublistView(data);
    final noOfRecords = hd.getUint16(5, Endian.little);

    final types = <UmasDataTypeRef>[];
    int pos = 7;

    for (int i = 0; i < noOfRecords && pos + 7 <= data.length; i++) {
      if (types.length >= _maxVariables) break;

      final view = ByteData.sublistView(data, pos);
      final dataSize = view.getUint16(0, Endian.little);
      final classIdentifier = view.getUint8(4);
      final dataType = view.getUint8(5);
      pos += 7;

      int end = pos;
      while (end < data.length && data[end] != 0x00) {
        end++;
      }
      if (end >= data.length || end - pos > _maxNameLength) {
        break;
      }
      final name = utf8.decode(data.sublist(pos, end), allowMalformed: true);
      pos = end + 1;

      // Use the PLC-assigned `dataType` byte as the lookup id, so that a
      // variable whose DD02 record references dataTypeId=N resolves to the
      // DD03 record whose dataType=N. (Built-in types use the same scheme.)
      types.add(UmasDataTypeRef(
        id: dataType,
        name: name,
        byteSize: dataSize,
        classIdentifier: classIdentifier,
        dataType: dataType,
      ));
    }

    return (0, types);
  }

  /// Build a hierarchical variable tree from a flat list of variables.
  /// Variable names use dot-separated paths (e.g. "App.GVL.temp").
  List<UmasVariableTreeNode> buildVariableTree(
      List<UmasVariable> variables, List<UmasDataTypeRef> dataTypes) {
    // Use a nested map structure for efficient tree construction,
    // then convert to UmasVariableTreeNode at the end.
    final tree = _TreeBuilder();

    for (final v in variables) {
      tree.insert(v, dataTypes);
    }

    return tree.build();
  }

  /// Read PLC status (sub-function 0x04).
  ///
  /// Returns PLC run state and memory block CRC checksums needed for
  /// ReadVariable (0x22). CRCs are also stored on the client instance
  /// via [blockCrcs] for later use.
  ///
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<PlcStatusResult> readPlcStatus() async {
    return _withSession(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.plcStatus.code,
        pairingKey: _pairingKey,
        unitId: unitId,
      );
      final code = await sendFn(request);

      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'UMAS plcStatus failed: ${code.name}');
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty UMAS plcStatus response');
      }

      _checkStatus(pdu, 'plcStatus');

      // Parse payload after 3-byte UMAS header:
      //   pdu[3] = statusByte (1 byte)
      //   pdu[4..5] = notUsed2 (2 bytes, skip)
      //   pdu[6] = numberOfBlocks (1 byte)
      //   pdu[7..] = blocks array: numberOfBlocks * uint32 (4 bytes each, LE)
      //   remaining = additionalData
      if (pdu.length < 7) {
        throw UmasException(
            errorCode: 0,
            message: 'UMAS plcStatus response too short: ${pdu.length}');
      }

      final statusByte = pdu[3];
      var numberOfBlocks = pdu[6];

      // Cap numberOfBlocks to prevent memory exhaustion (T-03-02)
      if (numberOfBlocks > _maxBlocks) {
        numberOfBlocks = _maxBlocks;
      }

      final blockCrcs = <int>[];
      final blockDataStart = 7;
      final availableBlockBytes = pdu.length - blockDataStart;
      final actualBlocks =
          numberOfBlocks.clamp(0, availableBlockBytes ~/ 4);

      if (actualBlocks > 0) {
        final bd = ByteData.sublistView(pdu);
        for (int i = 0; i < actualBlocks; i++) {
          blockCrcs.add(bd.getUint32(blockDataStart + i * 4, Endian.little));
        }
      }

      final additionalDataStart = blockDataStart + actualBlocks * 4;
      final additionalData = additionalDataStart < pdu.length
          ? pdu.sublist(additionalDataStart)
          : Uint8List(0);

      _blockCrcs = List.unmodifiable(blockCrcs);

      // Detect CRC changes by comparing with previous poll (T-03-05: element-wise)
      bool crcChanged = false;
      if (_previousCrcs != null) {
        if (_previousCrcs!.length != blockCrcs.length) {
          crcChanged = true;
        } else {
          for (int i = 0; i < blockCrcs.length; i++) {
            if (_previousCrcs![i] != blockCrcs[i]) {
              crcChanged = true;
              break;
            }
          }
        }
      }
      _previousCrcs = List.from(blockCrcs);

      return PlcStatusResult(
        statusByte: statusByte,
        numberOfBlocks: numberOfBlocks,
        blockCrcs: blockCrcs,
        additionalData: additionalData,
        crcChanged: crcChanged,
      );
    });
  }

  /// Send a KeepAlive (0x12) request. **Diagnostic-only API — not used
  /// by [startKeepAlive].**
  ///
  /// UMAS sub-function 0x12 is `umas_QueryKeepPLCReservation`. It only
  /// makes sense when the client holds an exclusive write reservation
  /// (acquired via [takePlcReservation], 0x10). On the M580 firmware,
  /// 0x12 from a non-reserved client is rejected with `status=0xFD
  /// errorCode=0x81 secondary=0x80` (live byte capture against
  /// 192.168.112.159, 2026-05-20).
  ///
  /// plc4j's umas.mspec defines no 0x12 case; it never sends this
  /// sub-function. The periodic [startKeepAlive] timer uses
  /// [readPlcStatus] (0x04) instead.
  ///
  /// This method is retained for parity / diagnostic tooling that wants
  /// to exercise the 0x12 frame explicitly (e.g. fuzzing or firmware
  /// dialect probing). Production code paths should not call this.
  ///
  /// Uses [_withSession] to auto-initialize if not yet paired.
  /// Returns void on success; throws [UmasException] on error.
  Future<void> sendKeepAlive() async {
    return _withSession(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.keepAlive.code,
        pairingKey: _pairingKey,
        unitId: unitId,
      );
      final code = await sendFn(request);

      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'UMAS keepAlive failed: ${code.name}');
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty UMAS keepAlive response');
      }

      _checkStatus(pdu, 'keepAlive');
    });
  }

  /// Send an Echo/Repeat (0x0A) with [payload] and measure round-trip latency.
  ///
  /// Uses [_withSession] to auto-initialize if not yet paired.
  /// Returns [UmasEchoResult] with the echoed payload and latency duration.
  Future<UmasEchoResult> sendEcho(Uint8List payload) async {
    return _withSession(() async {
      final stopwatch = Stopwatch()..start();

      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.echo.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);

      stopwatch.stop();

      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
            errorCode: code.code,
            message: 'UMAS echo failed: ${code.name}');
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
            errorCode: 0, message: 'Empty UMAS echo response');
      }

      _checkStatus(pdu, 'echo');

      // Extract echoed payload from response PDU after 3-byte header
      final echoedPayload = pdu.sublist(3);

      return UmasEchoResult(
        payload: echoedPayload,
        latency: stopwatch.elapsed,
      );
    });
  }

  /// Whether this client currently holds an exclusive PLC reservation.
  bool _hasReservation = false;

  /// Whether this client currently holds an exclusive PLC reservation.
  bool get hasReservation => _hasReservation;

  /// Acquire exclusive PLC write reservation (sub-function 0x10).
  ///
  /// Sets [hasReservation] to true on success.
  ///
  /// **Exception taxonomy (TD-014, v1.1.x):**
  /// - Transport-level errors (e.g. Modbus exception code, no PDU) →
  ///   plain [UmasException]. These are not reservation conflicts;
  ///   they're network / framing failures and callers should not
  ///   special-case them as "another client holds the lock."
  /// - PLC-side reservation conflict → [UmasReservationException] so the
  ///   UI/operator workflow can present a graceful "wait for the other
  ///   client to release" affordance instead of a generic "something
  ///   failed" red banner. The recognized conflict byte set is:
  ///     * `0x06` — canonical UMAS reservation-conflict code.
  ///     * `0x81` — M580 dialect, observed live on
  ///       192.168.112.159 (see `/tmp/umas-fuzz/fuzz-reservation.md`:
  ///       every acquire attempt while another HMI held the lock
  ///       returned `status=0xFD errorCode=0x81`).
  ///   All other non-success status bytes (`0x83` Data Dictionary
  ///   disabled, `0xC0` access denied, etc.) remain real protocol
  ///   errors and surface as plain [UmasException] — callers MUST NOT
  ///   special-case them as transient reservation conflicts.
  ///
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<void> takePlcReservation() async {
    return _withSession(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.takePlcReservation.code,
        pairingKey: _pairingKey,
        unitId: unitId,
      );
      final code = await sendFn(request);

      if (code != ModbusResponseCode.requestSucceed) {
        // TD-014: transport-level failure is NOT a reservation conflict.
        // Surface as plain UmasException so callers don't false-positive
        // on "another client holds the lock" UX when the network is just
        // down.
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS takePlcReservation transport error: ${code.name}',
        );
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS takePlcReservation response',
        );
      }

      // Check for UMAS-level error. The recognized reservation-conflict
      // byte set is 0x06 (canonical) and 0x81 (M580 dialect observed
      // live on 192.168.112.159 — see
      // `/tmp/umas-fuzz/fuzz-reservation.md`). Both surface as
      // UmasReservationException. Other status errors (e.g. 0x83 Data
      // Dictionary disabled, 0xC0 access denied) are real protocol
      // errors that callers MUST NOT treat as a transient reservation
      // conflict.
      if (pdu[2] == _statusError || pdu[2] != _statusSuccess) {
        final errorCode = pdu.length > 3 ? pdu[3] : 0;
        if (errorCode == 0x06 || errorCode == 0x81) {
          throw UmasReservationException(
            errorCode: errorCode,
            message: 'Another client holds the PLC reservation',
          );
        }
        throw UmasException(
          errorCode: errorCode,
          message: 'UMAS takePlcReservation failed: status=0x'
              '${pdu[2].toRadixString(16).padLeft(2, '0')} '
              'errorCode=0x${errorCode.toRadixString(16).padLeft(2, '0')}',
        );
      }

      _hasReservation = true;
    });
  }

  /// Release PLC write reservation (sub-function 0x11).
  ///
  /// Best-effort: sets [hasReservation] to false even on error,
  /// because a failed release should not leave stale local state.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<void> releasePlcReservation() async {
    try {
      await _withSession(() async {
        final request = UmasRequest(
          umasSubFunction: UmasSubFunction.releasePlcReservation.code,
          pairingKey: _pairingKey,
          unitId: unitId,
        );
        final code = await sendFn(request);

        if (code != ModbusResponseCode.requestSucceed) {
          _log.w('UMAS releasePlcReservation transport error: ${code.name}');
          return;
        }

        final pdu = request.responsePdu;
        if (pdu != null && pdu.length >= 3 && pdu[2] != _statusSuccess) {
          _log.w('UMAS releasePlcReservation status error: '
              '0x${pdu[2].toRadixString(16)}');
        }
      });
    } catch (e) {
      _log.w('UMAS releasePlcReservation failed: $e');
    } finally {
      _hasReservation = false;
    }
  }

  /// Execute [operation] while holding an exclusive PLC reservation.
  ///
  /// Acquires reservation via [takePlcReservation], runs [operation],
  /// and releases via [releasePlcReservation] in a finally block to
  /// prevent orphaned reservations (T-06-02 mitigation).
  Future<T> withReservation<T>(Future<T> Function() operation) async {
    await takePlcReservation();
    try {
      return await operation();
    } finally {
      await releasePlcReservation();
    }
  }

  /// Fix A: Predicate distinguishing fatal session errors (which justify
  /// nuking the pairing key + rebuilding the symbol cache) from
  /// per-operation errors (which do not).
  ///
  /// Without this gate, every benign `UmasException` thrown from
  /// `_withSessionAndRecovery`, the keep-alive timer, or a single init
  /// retry attempt would call [_handleSessionError] and force a full
  /// re-pair + 1082-entry symbol-cache rebuild. In the field this
  /// produced a tight "paired -> uninitialized -> identified -> paired"
  /// log loop on the live HMI; the symbol-cache rebuild also burned
  /// real wall-clock time and disrupted reads.
  ///
  /// **Fatal (session must be invalidated):**
  /// - Transport-level Modbus codes 0xF0..0xF6 + 0xFF
  ///   (timeout, connectionFailed, tx/rx failed, wrong unit id /
  ///   function code / checksum, undefined). These mean the wire was
  ///   unusable; the next operation must re-handshake.
  ///
  /// **NOT fatal (do not invalidate):**
  /// - `errorCode == 0`: client-side parse / empty response / range
  ///   guard / lookup miss. The session is fine; the caller can retry.
  /// - PLC-side UMAS error bytes such as 0x06 (reservation conflict),
  ///   0x83 (Data Dictionary disabled), 0x86 (memory block not found),
  ///   0x94 (not writable), 0xC0 (DD not accessible). These are
  ///   operation-specific and surface via the response status byte —
  ///   they do NOT indicate the pairing key is invalid.
  /// - Standard Modbus exception codes 0x01..0x0B. The PLC accepted
  ///   the modbus frame but rejected the operation; the session is
  ///   intact.
  ///
  /// TODO(session-error-tuning): once we have field data showing the
  /// specific code/message the M580 returns when the engineering tool
  /// steals the session, add it explicitly to the fatal set. Until
  /// then, the conservative policy here is "transport-level only" —
  /// see the test expectations in
  /// `umas_client_session_error_test.dart`.
  bool _isFatalSessionError(UmasException e) {
    final code = e.errorCode;
    // Transport-level failures from ModbusResponseCode. The non-success
    // sentinels live in 0xF0..0xF6 and 0xFF (see ModbusResponseCode).
    if (code == 0xFF) return true;
    if (code >= 0xF0 && code <= 0xF6) return true;
    return false;
  }

  /// Reset all session state when UMAS session is invalidated.
  /// Called when error responses indicate the pairing key is no longer valid
  /// (PLC reboot, engineering tool connection, TCP reconnection).
  ///
  /// SWEEP-04 (v1.1): also clears [_projectCrc] so a PLC reboot
  /// mid-session does not carry a stale project CRC into the
  /// post-reboot session. Without this, after a PLC reprogramming
  /// reboot, the next 0x22 / 0x23 request would send the old
  /// project CRC and either silently match the wrong project or be
  /// rejected with a CRC-mismatch error attributed to the wrong
  /// cause.
  void _handleSessionError() {
    _log.i('UMAS session invalidated, resetting to uninitialized');
    _pairingKey = 0x00;
    _resetHardwareIdentifiers();
    _index = null;
    maxFrameSize = null;
    _previousCrcs = null;
    _projectCrc = null; // SWEEP-04
    _hasReservation = false;
    // TD-009 (v1.1.x): do NOT reset _useMonitorPlc. The M580-detected
    // bit is a hardware fingerprint that does not change across PLC
    // reboots / session resets. Clearing it would cause the next read
    // to re-probe via 0x22 → 0xA1 → 0x50 fallback (one wasted RTT).
    // The adapter wraps this client and reseeds _useMonitorPlc across
    // client re-creates; we only reset when the underlying serverAlias
    // (and therefore the PLC identity) changes.
    _monitorTable.reset();
    // B-3: drop the symbol cache too — a session reset usually means the
    // PLC rebooted or the engineering tool reset the connection, and any
    // cached symbol→(blockNo, offset) mapping may now point at a moved
    // variable in a freshly-downloaded project. Force re-browse next time.
    _clearSymbolCache();
    _setState(UmasSessionState.uninitialized);
  }

  /// Clear the symbol cache + cross-call browse caches. Forces the next
  /// [lookupSymbol] (or [readVariableByName] / [writeVariableByName]) to
  /// re-browse the PLC.
  void _clearSymbolCache() {
    _symbolCache.clear();
    _persistentMemberCache.clear();
    _persistentArrayCache.clear();
    _symbolCacheBuilt = false;
    _symbolCacheProjectCrc = null;
  }

  /// Fix B: Clear both hardware-ID fields. Called from [_handleSessionError]
  /// and any other path that needs to reset the identification cache.
  void _resetHardwareIdentifiers() {
    _plcIdHardwareId = null;
    _projectHardwareId = null;
  }

  /// Public hook for callers that detect a project change (e.g. a poll
  /// loop that calls [readPlcStatus] and observes `crcChanged=true`).
  /// Drops the symbol cache if the project CRC changed since the cache
  /// was built. Safe to call repeatedly — no-op when CRCs match.
  ///
  /// **Precondition (fuzz-browse-stability.md):** has no effect when
  /// the symbol cache hasn't been built yet — the method short-circuits
  /// on `!_symbolCacheBuilt` and never compares CRCs. The cache is
  /// built inside [_ensureSymbolCache] (driven by [lookupSymbol] /
  /// [readVariableByName] / [writeVariableByName]) and by direct
  /// [debugInjectSymbol] in tests; a bare [browse] does NOT flip
  /// `_symbolCacheBuilt`. Idempotent on a not-yet-built cache.
  ///
  /// Practical implications:
  /// - Production flow is fine: the first `readVariableByName` primes
  ///   the cache, after which CRC-watch invalidation fires as expected.
  ///
  /// F-8 (v1.1.x): now invoked from the periodic [_projectCrcTimer]
  /// via [refreshProjectMetadata] so PLC reprograms are detected
  /// without waiting for a session-level error. On a CRC change this
  /// method clears the symbol cache AND emits on [projectCrcChanges];
  /// downstream consumers (the MonitorPlc batched poller in
  /// `ModbusDeviceClientAdapter`) listen on that stream so their own
  /// caches invalidate atomically with the symbol cache.
  void invalidateSymbolCacheIfProjectChanged() {
    if (!_symbolCacheBuilt) return;
    if (_projectCrc != _symbolCacheProjectCrc) {
      _log.i('UMAS symbolCache: project CRC changed '
          '(${_symbolCacheProjectCrc} -> $_projectCrc) — clearing');
      _clearSymbolCache();
    }
  }

  /// F-8: re-read memory block 0x30 to refresh [_projectCrc], then fire
  /// the invalidation chain. The CRC-watch timer drives this every
  /// [projectCrcCheckInterval]; tests can call it directly to assert
  /// deterministic invalidation behaviour.
  ///
  /// On a CRC change this method:
  ///   1. Drops the symbol cache (via [invalidateSymbolCacheIfProjectChanged]
  ///      — no-op if the cache wasn't built yet).
  ///   2. Emits the new CRC on [projectCrcChanges] so external caches
  ///      (e.g. the MonitorPlc batched table in `ModbusDeviceClientAdapter`)
  ///      can drop their state and rebuild against the fresh project.
  ///
  /// Returns true if the project CRC differed from the previous value
  /// (so the caller — typically a test — can assert the watched
  /// transition fired).
  Future<bool> refreshProjectMetadata() async {
    if (_stateValue != UmasSessionState.paired) return false;
    final before = _projectCrc;
    try {
      await _readProjectBlock();
    } catch (e) {
      _log.w('refreshProjectMetadata: _readProjectBlock failed: $e');
      return false;
    }
    final after = _projectCrc;
    if (before == after) return false;
    // Drop symbol cache (no-op if not yet built).
    invalidateSymbolCacheIfProjectChanged();
    // Always notify external listeners — the MonitorPlc table caches
    // `(blockNo, offset)` pairs that move under a fresh project even
    // if no symbol was ever looked up. Don't gate the stream on
    // `_symbolCacheBuilt`.
    if (after != null && !_projectCrcSubject.isClosed) {
      _projectCrcSubject.add(after);
    }
    return true;
  }

  /// Build the symbol cache from a full [browse]. Concurrent first-time
  /// callers wait on the same browse via [_symbolCacheLock] so multiple
  /// keys reading at startup don't fan out into N parallel browses.
  Future<void> _ensureSymbolCache() async {
    if (_symbolCacheBuilt) return;
    if (_symbolCacheLock != null) {
      await _symbolCacheLock!.future;
      return;
    }
    _symbolCacheLock = Completer<void>();
    // Avoid unhandled-async-error if no one awaits the lock.
    _symbolCacheLock!.future.ignore();
    try {
      // Sample the project we are browsing FROM, before the first round trip.
      // A browse is many round trips; the keepalive and the CRC watch both
      // refresh _projectCrc while it runs, so a PLC download landing mid-browse
      // moves it under us. Stamping the post-browse value would compare the new
      // CRC against itself, and a cache built from the OLD data dictionary --
      // symbol paths pointing at variables that have since moved -- would never
      // be invalidated.
      final crcAtBrowseStart = _projectCrc;
      final tree = await browse();
      _symbolCache.clear();
      void walk(UmasVariableTreeNode node) {
        if (node.variable != null && node.dataType != null) {
          _symbolCache[node.path] = ResolvedSymbol(
            path: node.path,
            variable: node.variable!,
            dataType: node.dataType!,
            readable: node.readable,
            unreadableReason: node.unreadableReason,
          );
        }
        for (final c in node.children) {
          walk(c);
        }
      }

      for (final root in tree) {
        walk(root);
      }
      _symbolCacheBuilt = true;
      _symbolCacheProjectCrc = crcAtBrowseStart;
      _log.i('UMAS symbolCache: built ${_symbolCache.length} entries '
          '(projectCrc=${_symbolCacheProjectCrc == null ? 'n/a' : '0x${_symbolCacheProjectCrc!.toRadixString(16)}'})');
      _symbolCacheLock!.complete();
    } catch (e) {
      _symbolCacheLock!.completeError(e);
      rethrow;
    } finally {
      _symbolCacheLock = null;
    }
  }

  /// Resolve a UMAS symbol path (e.g. `B_F1_RC_01_Front` or
  /// `M_Elevator.speed`) to its [ResolvedSymbol]. Triggers a one-time
  /// [browse] if the cache is empty; concurrent first-time callers share
  /// the same browse via [_ensureSymbolCache].
  ///
  /// **Case sensitivity (TD-013, v1.1.x):** Schneider M580 / M340 UMAS
  /// symbols are *case-sensitive on the wire*. Verified against live
  /// PLC at 192.168.112.159: the same byte-for-byte symbol path with
  /// different casing (`B_Elevator_F1_A` vs `b_elevator_f1_a`) returns
  /// "not found" for the lowercase variant. This is the inverse of IEC
  /// 61131-3 source-level case-insensitivity, which is enforced by the
  /// engineering tool (EcoStruxure) rather than the firmware.
  ///
  /// Operators (and LLMs generating symbol paths) frequently get the
  /// case wrong. We do a case-insensitive fallback scan on miss so the
  /// error names the correct casing instead of just "not found":
  ///
  ///   `UMAS symbol not found in data dictionary: "elevator.speed".
  ///    Did you mean "Elevator.speed"? (Schneider symbol paths are
  ///    case-sensitive on the wire.)`
  ///
  /// The fallback is O(N) in the cache size — acceptable because it
  /// only runs on the miss path. On the hit path, the existing O(1)
  /// hash lookup is unchanged.
  ///
  /// Throws [UmasException] when the symbol does not exist in the PLC's
  /// Data Dictionary (with the "did you mean" suggestion when a
  /// case-insensitive match exists).
  Future<ResolvedSymbol> lookupSymbol(String path) async {
    await _ensureSymbolCache();
    final hit = _symbolCache[path];
    if (hit != null) return hit;
    // TD-013: case-insensitive fallback — surface the correct casing
    // in the error message so the operator can fix the typo without
    // re-browsing the data dictionary manually.
    final lower = path.toLowerCase();
    String? caseSuggestion;
    for (final cachedPath in _symbolCache.keys) {
      if (cachedPath.toLowerCase() == lower) {
        caseSuggestion = cachedPath;
        break;
      }
    }
    final suffix = caseSuggestion == null
        ? ''
        : '. Did you mean "$caseSuggestion"? '
            '(Schneider symbol paths are case-sensitive on the wire.)';
    throw UmasException(
      errorCode: 0,
      message: 'UMAS symbol not found in data dictionary: "$path"$suffix',
    );
  }

  /// Read a single UMAS variable by name. Resolves via [lookupSymbol]
  /// then issues [readVariables] for one symbol. Returns the parsed
  /// typed value.
  ///
  /// fuzz #7 (v1.1.x): rejects FB-instance roots up-front with
  /// [UmasNotScalarException]. Before the gate, reading an FB instance by
  /// its root name (e.g. `Elevator`) silently returned an empty
  /// [TypedVariableValue] because the synthesized FB type carries
  /// `byteSize == 0` and the `default:` branch of [parseVariableValue]
  /// just returned a zero-length slice — operators saw a blank in
  /// FB-DynamicValue / Key Repository with no diagnostic. Operators (and
  /// callers like [ModbusDeviceClientAdapter.readUmasVariable]) that need
  /// FB data must address members directly (`Elevator.q_xUp`); the browse
  /// tree enumerates members via its own walk and does not rely on this
  /// path. Array (classIdentifier == 4) and UDT (== 2) roots are
  /// intentionally NOT gated here — the whole-array case is owned by the
  /// parallel bug-droparray fix; nested UDT reads still work today via the
  /// browse-walk path.
  Future<TypedVariableValue> readVariableByName(String path) async {
    final sym = await lookupSymbol(path);
    _guardScalarOrThrow(sym, path);
    final values = await readVariables([(sym.variable, sym.dataType)]);
    if (values.isEmpty) {
      throw UmasException(
          errorCode: 0,
          message: 'UMAS readVariableByName($path) returned empty result');
    }
    return values.first;
  }

  /// Read every readable scalar member of an FB instance rooted at [fbPath].
  ///
  /// Walks the already-built symbol cache for entries whose path starts with
  /// `<fbPath>.` and issues a single batched [readVariables] for the readable
  /// scalar leaves. Returns a map keyed by the member sub-path (the suffix
  /// after the FB root + `.`).
  ///
  /// **Why a dedicated helper, not just N `readVariableByName` calls?**
  /// The MonitorPlc fallback path in [ModbusDeviceClientAdapter] catches
  /// [UmasNotScalarException] when a poll-loop key is bound to an FB
  /// instance. The original silent-blank symptom (commit `8c03c68d`'s
  /// motivation) and the noisy per-tick log this helper replaces both
  /// point to the same root cause: the poll loop never had a way to
  /// realise the binding meant "fan out across members". This helper
  /// does the fan-out in ONE round-trip so the per-tick cost matches a
  /// scalar read closely enough to drop into the existing fallback poll
  /// without a per-key re-architecture.
  ///
  /// **Member naming.** Sub-paths preserve dotted notation for nested
  /// members. For an FB `M_F2_RC_01` with a nested `HMI` sub-instance,
  /// the map carries keys like `HMI.p_Stat_xRunningFwd` — flat (one map
  /// level deep) rather than recursively nested. This matches the shape
  /// the existing FB-DynamicValue widget / Conveyor FB asset already
  /// consume (`fb[memberName]` on a flat `Map<String, DynamicValue>`).
  ///
  /// **Unreadable members.** Members marked `readable == false`
  /// (VAR_IN_OUT, etc.) are silently dropped from the batched read AND
  /// from the returned map. The PLC would reject them with 0x94, and
  /// the rest of the FB members must still get values this tick.
  ///
  /// **Errors.**
  /// - Throws [UmasException] when [fbPath] is unknown to the symbol
  ///   cache (neither the root nor any `<fbPath>.<...>` entries exist).
  /// - Throws [UmasException] when the FB root resolves but has no
  ///   readable members under it (e.g. all members are VAR_IN_OUT, or
  ///   the FB is genuinely empty in the data dictionary).
  ///
  /// Callers MUST have a primed session (paired + block CRCs) — the
  /// same precondition [readVariables] enforces. In production the
  /// adapter's [ModbusDeviceClientAdapter.readUmasVariable] calls
  /// [readPlcStatus] before reaching this method.
  Future<Map<String, TypedVariableValue>> readFbInstanceMembers(
      String fbPath) async {
    // Ensure the symbol cache is populated. If the cache is empty
    // browse() will run and walk the tree; if [fbPath] is genuinely
    // unknown after that, _ensureSymbolCache stays empty for that
    // prefix and we surface the error below.
    await _ensureSymbolCache();

    final prefix = '$fbPath.';
    final orderedPairs = <(UmasVariable, UmasDataTypeRef)>[];
    final orderedSubPaths = <String>[];
    for (final entry in _symbolCache.entries) {
      final p = entry.key;
      if (!p.startsWith(prefix)) continue;
      final sym = entry.value;
      if (!sym.readable) continue;
      // Skip nested-FB roots — they have classIdentifier 7 and
      // byteSize 0; the leaves inside them are already enumerated as
      // separate entries in the symbol cache (the browse walker
      // recurses into FBs in _ensureSymbolCache.walk).
      if (sym.dataType.classIdentifier == 7) continue;
      orderedPairs.add((sym.variable, sym.dataType));
      orderedSubPaths.add(p.substring(prefix.length));
    }

    if (orderedPairs.isEmpty) {
      throw UmasException(
        errorCode: 0,
        message: 'UMAS readFbInstanceMembers("$fbPath"): no readable scalar '
            'members are cached for this FB instance. The FB root may be '
            'unknown to the data dictionary, or every member is VAR_IN_OUT.',
      );
    }

    // Fast path: one batched ReadVariable (0x22). Works for FBs whose
    // members are all fixed-width scalars (BOOL/INT/REAL/etc.).
    try {
      final values = await readVariables(orderedPairs);
      final out = <String, TypedVariableValue>{};
      final n = values.length < orderedSubPaths.length
          ? values.length
          : orderedSubPaths.length;
      for (var i = 0; i < n; i++) {
        out[orderedSubPaths[i]] = values[i];
      }
      // The batched call must produce one value per readable leaf. If
      // it returned fewer (the PLC truncated or the count was off), fall
      // through to per-leaf so the missing members get a fresh chance.
      if (n == orderedPairs.length) return out;
    } on UmasException catch (e) {
      // Live-PLC reality: an FB with a STRING (or any non-fixed-width
      // member) trips parseVariableValues' byteSize accounting on the
      // batched response because STRING leaves advance differently
      // than the bound-check assumes. Fall back to per-leaf reads so
      // every leaf parses against its own response buffer — N RTTs but
      // correct under the live wire format. This mirrors the
      // CLI `read <fb>` command's per-leaf strategy in umas_cli.dart,
      // which has been the workaround on the production M580.
      _log.w('UMAS readFbInstanceMembers("$fbPath"): batched read failed '
          '(${e.message}); falling back to per-leaf reads');
    }

    // Slow path: per-leaf reads. Each leaf gets its own 0x22; per-leaf
    // failures are logged and SKIPPED — the rest of the FB still
    // surfaces values. This matches the SCADA-style "best-effort" the
    // poll loop expects: a single bad member shouldn't black out the
    // whole FB.
    final out = <String, TypedVariableValue>{};
    for (var i = 0; i < orderedPairs.length; i++) {
      final pair = orderedPairs[i];
      try {
        final v = await readVariables([pair]);
        if (v.isNotEmpty) {
          out[orderedSubPaths[i]] = v.first;
        }
      } catch (e) {
        _log.w('UMAS readFbInstanceMembers("$fbPath"): per-leaf read of '
            '"${orderedSubPaths[i]}" failed: $e — skipping this member');
      }
    }
    if (out.isEmpty) {
      throw UmasException(
        errorCode: 0,
        message: 'UMAS readFbInstanceMembers("$fbPath"): every per-leaf '
            'read failed. The FB instance may be unreachable or the PLC '
            'session has degraded.',
      );
    }
    return out;
  }

  /// Write a single UMAS variable by name. Resolves via [lookupSymbol]
  /// then issues [writeVariable] with the value encoded per the
  /// resolved data type. The [value] is encoded by [encodeVariableValue]
  /// (see umas_types.dart).
  ///
  /// F-7: refuses VAR_IN_OUT (and any other [ResolvedSymbol] with
  /// `readable == false`) client-side. The PLC would reject these with
  /// 0x94 anyway; surfacing the precise [ResolvedSymbol.unreadableReason]
  /// gives operators a clearer error than the raw protocol code, and
  /// avoids burning a round-trip on a guaranteed failure.
  ///
  /// fuzz #7 (v1.1.x): also refuses FB-instance roots — symmetric with
  /// [readVariableByName]. Writing to an FB root is meaningless (the
  /// "value" is a struct of members); the gate keeps the error surface
  /// uniform across read / write.
  Future<void> writeVariableByName(String path, dynamic value) async {
    final sym = await lookupSymbol(path);
    _guardScalarOrThrow(sym, path);
    if (!sym.readable) {
      throw UmasException(
        errorCode: 0,
        message: 'Cannot write ${sym.path}: '
            '${sym.unreadableReason ?? "marked as not readable"}',
      );
    }
    final ref = VariableWriteRef.fromVariable(sym.variable, sym.dataType, value);
    await writeVariable([ref]);
  }

  /// fuzz #7 (v1.1.x): throw [UmasNotScalarException] when [sym] resolves
  /// to a Function Block instance (`classIdentifier == 7`).
  ///
  /// `classIdentifier` semantics (see [UmasDataTypeRef.classIdentifier]):
  /// * `2` — UDT/struct (not gated; nested UDT reads still work via the
  ///   browse walk and remain a non-issue for the current FB-only fix)
  /// * `4` — array  (not gated; whole-array reads are owned by a parallel
  ///   bug-droparray fix to avoid stepping on it)
  /// * `7` — FB instance (gated here)
  /// * other — elementary scalar (passes through unchanged)
  ///
  /// The thrown message names the path and suggests the `path.<member>`
  /// notation so operators can recover without re-browsing the data
  /// dictionary.
  void _guardScalarOrThrow(ResolvedSymbol sym, String path) {
    final classId = sym.dataType.classIdentifier;
    if (classId == 7) {
      throw UmasNotScalarException(
        path: path,
        typeKind: 'FB',
      );
    }
  }

  /// Wraps [_withSession] with session recovery: on a FATAL [UmasException]
  /// (see [_isFatalSessionError]), resets session state so the next call
  /// re-initializes. Per-operation errors (parse failures, range guards,
  /// per-symbol 0x83/0x86/0x94/0xC0 codes, etc.) propagate WITHOUT
  /// tearing down the session.
  ///
  /// Fix A: previously this method invalidated on every UmasException.
  /// That made benign errors (e.g. a single parse failure on a malformed
  /// reply, a CRC mismatch from a stale block) trigger a full re-pair
  /// + 1082-entry symbol-cache rebuild, which was the visible "session
  /// re-pair storm" in live HMI logs.
  ///
  /// Does NOT retry automatically — the caller must explicitly retry
  /// to avoid infinite loops.
  Future<T> _withSessionAndRecovery<T>(Future<T> Function() operation) async {
    try {
      return await _withSession(operation);
    } on UmasException catch (e) {
      if (_isFatalSessionError(e)) {
        _handleSessionError();
      }
      rethrow;
    }
  }

  /// Maximum number of variable references per ReadVariable request.
  /// The variableCount field is 1 byte, so max is 255 (T-05-02 mitigation).
  static const _maxReadVariableRefs = 255;

  /// Read variable values from the PLC (sub-function 0x22).
  ///
  /// Sends a ReadVariable request with the given [refs] and returns the
  /// raw concatenated response bytes. Typed parsing is the caller's
  /// responsibility (see Plan 02).
  ///
  /// Requires [readPlcStatus] to have been called first (for block CRCs).
  /// Uses [_withSessionAndRecovery] for automatic session management.
  Future<ReadVariableResult> readVariable(List<VariableReadRef> refs) async {
    return _withSessionAndRecovery(() async {
      if (_blockCrcs == null || _blockCrcs!.isEmpty) {
        throw UmasException(
          errorCode: 0,
          message: 'blockCrcs not available - call readPlcStatus() first',
        );
      }

      // Cap refs to max 255 (variableCount is 1 byte) -- T-05-02 DoS mitigation.
      // SWEEP-05 (v1.1): warn when truncation drops refs so callers see the
      // truncation in operator logs instead of only via a returned-shorter
      // ReadVariableResult.
      final cappedRefs = refs.length > _maxReadVariableRefs
          ? refs.sublist(0, _maxReadVariableRefs)
          : refs;
      if (refs.length > _maxReadVariableRefs) {
        _log.w('UMAS readVariable: truncated request from ${refs.length} to '
            '$_maxReadVariableRefs refs (cap is 1 byte). '
            '${refs.length - _maxReadVariableRefs} refs were NOT read.');
      }

      // Build payload: crc(4 LE) + count(1) + [ref.toBytes()]*
      // Per PLC4X reference driver, the CRC is the project-level CRC from
      // memory block 0x30 (hash1+hash2). Falls back to blockCrcs[0] for
      // legacy stub-server compatibility when the project CRC is absent.
      final buffer = BytesBuilder();
      final crcData = ByteData(4);
      crcData.setUint32(
          0, _projectCrc ?? _blockCrcs![0], Endian.little);
      buffer.add(crcData.buffer.asUint8List());
      buffer.addByte(cappedRefs.length);
      for (final ref in cappedRefs) {
        buffer.add(ref.toBytes());
      }

      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readVariable.code,
        pairingKey: _pairingKey,
        payload: Uint8List.fromList(buffer.toBytes()),
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS readVariable failed: ${code.name}',
        );
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS readVariable response',
        );
      }

      _checkStatus(pdu, 'readVariable');

      return ReadVariableResult(rawBytes: pdu.sublist(3));
    });
  }

  /// Read typed variable values from the PLC.
  ///
  /// Accepts pairs of ([UmasVariable], [UmasDataTypeRef]) from the data
  /// dictionary. Builds [VariableReadRef] instances, sends a single
  /// ReadVariable (0x22) request, and parses the raw response bytes into
  /// typed Dart values using [parseVariableValues].
  ///
  /// Returns a list of [TypedVariableValue] with correctly typed values
  /// (int, double, bool, String) matching the order of the input pairs.
  ///
  /// For array variables (classIdentifier == 4), the [VariableReadRef] is
  /// automatically constructed with isArray=true and the computed arrayLength.
  Future<List<TypedVariableValue>> readVariables(
      List<(UmasVariable, UmasDataTypeRef)> variables) async {
    // If M580 already detected, go directly to MonitorPlc (0x50).
    // Reset registrations first to avoid accumulating stale entries
    // from previous calls with different variable sets.
    //
    // TD-022: when the degraded breaker is tripped (sustained 0x82 from
    // MonitorPlc — observed on M580 after ~1 week uptime), bypass 0x50
    // and run the 0x22 ReadVariable path. The 0xA1A1 catch below will
    // re-flip to MonitorPlc if the PLC still insists; the breaker
    // auto-clears after _monitorPlcDegradedRetryAfter.
    _clearMonitorPlcDegradedIfStale();
    if (_useMonitorPlc && !_monitorPlcDegraded) {
      await monitorReset();
      return monitorRegisterAndRead(variables);
    }

    try {
      // M340 path: use ReadVariable (0x22)
      final refs = <VariableReadRef>[];
      final types = <UmasDataTypeRef>[];
      for (final (variable, dataType) in variables) {
        refs.add(VariableReadRef.fromVariable(variable, dataType));
        types.add(dataType);
      }
      final result = await readVariable(refs);
      return parseVariableValues(result.rawBytes, types,
          decodeString: decodeString);
    } on UmasException catch (e) {
      // TD-017 (v1.1.x): the Schneider M580 marker for "use MonitorPlc
      // instead of ReadVariable" is the 2-byte sequence 0xA1 0xA1 in
      // pdu[3..4]. The single-byte 0xA1 alone could plausibly come from
      // an unrelated firmware path; flipping to MonitorPlc on the
      // weaker signal would silently mask non-M580 protocol errors.
      // Require BOTH bytes to match before switching modes.
      if (e.errorCode == 0xA1 && e.secondaryErrorCode == 0xA1) {
        // M580 detected: 0x22 returns 0xA1A1 error
        _useMonitorPlc = true;
        // TD-022 follow-up: when the degraded breaker is latched, do NOT
        // re-enter MonitorPlc — that would cascade 0x82 within the same
        // call and defeat the bypass. Rethrow so the per-key fallback in
        // ModbusDeviceClientAdapter sees the error; the breaker's
        // auto-clear retries MonitorPlc after the retry window.
        if (_monitorPlcDegraded) rethrow;
        return monitorRegisterAndRead(variables);
      }
      rethrow;
    }
  }

  /// Maximum number of variable references per WriteVariable request.
  /// The variableCount field is 1 byte, so max is 255 (T-06-05 mitigation).
  static const _maxWriteVariableRefs = 255;

  /// Write variable values to the PLC (sub-function 0x23).
  ///
  /// Sends a WriteVariable request with the given [refs]. Each ref contains
  /// the variable address and the data bytes to write.
  ///
  /// Requires [readPlcStatus] to have been called first (for block CRCs).
  /// Uses [_withSessionAndRecovery] for automatic session management.
  Future<void> writeVariable(List<VariableWriteRef> refs) async {
    return _withSessionAndRecovery(() async {
      if (_blockCrcs == null || _blockCrcs!.isEmpty) {
        throw UmasException(
          errorCode: 0,
          message: 'blockCrcs not available - call readPlcStatus() first',
        );
      }

      // Cap refs to max 255 (variableCount is 1 byte) -- T-06-05 DoS mitigation.
      // SWEEP-05 (v1.1): warn when truncation drops refs so callers see the
      // silent data loss in operator logs instead of treating the Future
      // resolution as success-for-all.
      final cappedRefs = refs.length > _maxWriteVariableRefs
          ? refs.sublist(0, _maxWriteVariableRefs)
          : refs;
      if (refs.length > _maxWriteVariableRefs) {
        _log.w('UMAS writeVariable: truncated request from ${refs.length} to '
            '$_maxWriteVariableRefs refs (cap is 1 byte). '
            '${refs.length - _maxWriteVariableRefs} refs were NOT written.');
      }

      // Build payload: crc(4 LE) + count(1) + [ref.toBytes()]*
      // See readVariable for projectCrc rationale.
      final buffer = BytesBuilder();
      final crcData = ByteData(4);
      crcData.setUint32(
          0, _projectCrc ?? _blockCrcs![0], Endian.little);
      buffer.add(crcData.buffer.asUint8List());
      buffer.addByte(cappedRefs.length);
      for (final ref in cappedRefs) {
        buffer.add(ref.toBytes());
      }

      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.writeVariable.code,
        pairingKey: _pairingKey,
        payload: Uint8List.fromList(buffer.toBytes()),
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS writeVariable failed: ${code.name}',
        );
      }

      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS writeVariable response',
        );
      }

      _checkStatus(pdu, 'writeVariable');
    });
  }

  /// Write typed variable values to the PLC.
  ///
  /// Accepts triples of ([UmasVariable], [UmasDataTypeRef], value) from the
  /// data dictionary. Builds [VariableWriteRef] instances and sends a single
  /// WriteVariable (0x23) request.
  Future<void> writeVariables(
      List<(UmasVariable, UmasDataTypeRef, dynamic)> variables) async {
    final refs = <VariableWriteRef>[];
    for (final (variable, dataType, value) in variables) {
      refs.add(VariableWriteRef.fromVariable(variable, dataType, value));
    }
    await writeVariable(refs);
  }

  // ---------------------------------------------------------------------------
  // ReadCoilsRegisters (0x24) / WriteCoilsRegisters (0x25)
  // ---------------------------------------------------------------------------

  /// Read coils or registers directly by address (sub-function 0x24).
  ///
  /// Provides direct %M/%MW/%S/%SW access without the data dictionary.
  /// NOTE: Wire format is best-effort (PLC4X marks as opaque bytes).
  /// If the assumed format is wrong, use [readCoilsRegistersRaw]
  /// with a manually constructed payload.
  Future<CoilsRegistersResult> readCoilsRegisters(RegisterAddress address) async {
    return _withSessionAndRecovery(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readCoilsRegisters.code,
        pairingKey: _pairingKey,
        payload: address.toBytes(),
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS readCoilsRegisters failed: ${code.name}',
        );
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS readCoilsRegisters response',
        );
      }
      _checkStatus(pdu, 'readCoilsRegisters');
      return CoilsRegistersResult(rawBytes: pdu.sublist(3));
    });
  }

  /// Read coils/registers with a raw payload (sub-function 0x24).
  ///
  /// Use this if the assumed RegisterAddress format does not work
  /// with your PLC. Pass the raw UMAS payload bytes directly.
  Future<CoilsRegistersResult> readCoilsRegistersRaw(Uint8List payload) async {
    return _withSessionAndRecovery(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.readCoilsRegisters.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS readCoilsRegistersRaw failed: ${code.name}',
        );
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS readCoilsRegistersRaw response',
        );
      }
      _checkStatus(pdu, 'readCoilsRegistersRaw');
      return CoilsRegistersResult(rawBytes: pdu.sublist(3));
    });
  }

  /// Write coils or registers directly by address (sub-function 0x25).
  ///
  /// IMPORTANT: Assumes write reservation (0x10) is required, same as 0x23.
  /// Call within [withReservation] to ensure proper reservation lifecycle.
  ///
  /// [data] must contain the correct number of bytes for the register
  /// type and quantity (see [RegisterAddress.expectedDataBytes]).
  ///
  /// NOTE: Wire format is best-effort (PLC4X marks as opaque bytes).
  Future<void> writeCoilsRegisters(RegisterAddress address, Uint8List data) async {
    return _withSessionAndRecovery(() async {
      final expectedLen = address.expectedDataBytes;
      if (data.length != expectedLen) {
        throw UmasException(
          errorCode: 0,
          message: 'writeCoilsRegisters: data length ${data.length} '
              'does not match expected $expectedLen bytes for '
              '${address.type.name} x${address.quantity}',
        );
      }
      final payloadBuilder = BytesBuilder();
      payloadBuilder.add(address.toBytes());
      payloadBuilder.add(data);

      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.writeCoilsRegisters.code,
        pairingKey: _pairingKey,
        payload: Uint8List.fromList(payloadBuilder.toBytes()),
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS writeCoilsRegisters failed: ${code.name}',
        );
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS writeCoilsRegisters response',
        );
      }
      _checkStatus(pdu, 'writeCoilsRegisters');
    });
  }

  /// Write coils/registers with a raw payload (sub-function 0x25).
  Future<void> writeCoilsRegistersRaw(Uint8List payload) async {
    return _withSessionAndRecovery(() async {
      final request = UmasRequest(
        umasSubFunction: UmasSubFunction.writeCoilsRegisters.code,
        pairingKey: _pairingKey,
        payload: payload,
        unitId: unitId,
      );
      final code = await sendFn(request);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS writeCoilsRegistersRaw failed: ${code.name}',
        );
      }
      final pdu = request.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS writeCoilsRegistersRaw response',
        );
      }
      _checkStatus(pdu, 'writeCoilsRegistersRaw');
    });
  }

  // ---------------------------------------------------------------------------
  // MonitorPlc (0x50) sub-operations
  // ---------------------------------------------------------------------------

  /// Send a MonitorPlc (0x50) request with the given [payload].
  ///
  /// Returns the response payload bytes (after the 3-byte UMAS header).
  Future<Uint8List> _sendMonitorPlc(Uint8List payload) async {
    final request = UmasRequest(
      umasSubFunction: UmasSubFunction.monitorPlc.code,
      pairingKey: _pairingKey,
      payload: payload,
      unitId: unitId,
    );
    final code = await sendFn(request);
    if (code != ModbusResponseCode.requestSucceed) {
      throw UmasException(
        errorCode: code.code,
        message: 'UMAS monitorPlc failed: ${code.name}',
      );
    }
    final pdu = request.responsePdu;
    if (pdu == null || pdu.length < 3) {
      throw UmasException(
        errorCode: 0,
        message: 'Empty UMAS monitorPlc response',
      );
    }
    // TD-022: track consecutive 0x82 outcomes so the degraded breaker in
    // [readVariables] can flip the read path away from MonitorPlc.
    try {
      _checkStatus(pdu, 'monitorPlc');
    } on UmasException catch (e) {
      if (e.errorCode == 0x82) {
        _monitorPlc0x82Count++;
        if (_monitorPlc0x82Count >= _monitorPlc0x82TripThreshold &&
            !_monitorPlcDegraded) {
          _monitorPlcDegraded = true;
          _monitorPlcDegradedSince = _nowFn();
          _log.w('UMAS MonitorPlc degraded breaker tripped after '
              '$_monitorPlc0x82Count consecutive 0x82 responses; '
              'subsequent reads bypass MonitorPlc until retry window.');
        }
      } else {
        _monitorPlc0x82Count = 0;
      }
      rethrow;
    }
    _monitorPlc0x82Count = 0;
    return pdu.sublist(3);
  }

  /// Register variables for monitoring via MonitorPlc Register (0x05).
  ///
  /// Assigns variable indices sequentially and registers each variable's
  /// data type in the local registration table for response parsing.
  /// Returns the assigned variable indices.
  ///
  /// **Failure semantics (TD-015, v1.1.x):** if `_sendMonitorPlc` throws
  /// mid-batch (e.g. PLC errored on the 50th of 100 refs), the PLC may
  /// have registered SOME subset of the requested variables while the
  /// local `_monitorTable` still has none. A subsequent `monitorReadAll`
  /// (0x07) would then receive bytes for indices the local table can't
  /// parse, silently producing wrong values for every key in the batch.
  ///
  /// On exception we issue `monitorReset` (0x0B) to flush the PLC side
  /// so client and PLC re-converge on the empty state. The caller can
  /// re-issue `monitorRegister` after fixing the root cause. The reset
  /// itself is best-effort — if it also fails, we log and re-raise the
  /// original exception (a stuck-PLC condition is already worse than a
  /// missed reset).
  Future<List<int>> monitorRegister(
      List<(UmasVariable, UmasDataTypeRef)> variables) async {
    return _withSessionAndRecovery(() async {
      final indices = <int>[];
      final buffer = BytesBuilder();
      buffer.addByte(0x05); // subCommand: Register
      buffer.addByte(0x00); // unknown
      buffer.addByte(variables.length & 0xFF); // numberOfSubOps

      for (final (variable, _) in variables) {
        final idx = _monitorTable.allocateIndex();
        indices.add(idx);
        final ref = MonitorPlcRef.fromVariable(idx, variable);
        buffer.add(ref.toRegisterBytes());
      }

      try {
        await _sendMonitorPlc(Uint8List.fromList(buffer.toBytes()));
      } catch (e) {
        // TD-015 (v1.1.x): the PLC may have registered SOME subset of
        // the batch before erroring. The local _monitorTable has no
        // entries yet (we only register on success below). Without a
        // reset, a subsequent monitorReadAll would receive bytes for
        // PLC-registered indices the local table can't parse —
        // silently producing wrong values for every key.
        //
        // Reset semantics: flush PLC-side state via 0x0B and clear
        // the local index allocator so client and PLC re-converge on
        // the empty state. The reset itself is best-effort; if it
        // also fails, the original exception is what the caller cares
        // about — re-raise it. The caller can retry monitorRegister
        // from scratch after fixing the root cause.
        _log.w('monitorRegister failed mid-batch: $e — issuing '
            'monitorReset to re-sync PLC state');
        try {
          await _sendMonitorPlc(Uint8List.fromList([0x0B]));
        } catch (resetErr) {
          _log.w('monitorReset after partial-failure also failed: '
              '$resetErr (state may be out of sync until next session reset)');
        }
        _monitorTable.reset();
        rethrow;
      }

      // On success, register types in local table
      for (int i = 0; i < variables.length; i++) {
        _monitorTable.register(indices[i], variables[i].$2);
      }

      return indices;
    });
  }

  /// Read all registered variable values via MonitorPlc ReadAll (0x07).
  ///
  /// Returns parsed typed values using the registration table.
  /// Returns empty list if no variables are registered.
  Future<List<TypedVariableValue>> monitorReadAll() async {
    return _withSessionAndRecovery(() async {
      if (_monitorTable.isEmpty) return [];

      final responseBytes =
          await _sendMonitorPlc(Uint8List.fromList([0x07]));
      return _monitorTable.parseReadAllResponse(responseBytes,
          decodeString: decodeString);
    });
  }

  /// Register variables and immediately read their values via
  /// MonitorPlc RegisterAndRead (0x09).
  ///
  /// Registers in the local table AND parses the response.
  Future<List<TypedVariableValue>> monitorRegisterAndRead(
      List<(UmasVariable, UmasDataTypeRef)> variables) async {
    return _withSessionAndRecovery(() async {
      final indices = <int>[];
      final types = <UmasDataTypeRef>[];
      final buffer = BytesBuilder();
      buffer.addByte(0x09); // subCommand: RegisterAndRead
      buffer.addByte(0x00); // unknown
      buffer.addByte(variables.length & 0xFF); // numberOfSubOps

      for (final (variable, dataType) in variables) {
        final idx = _monitorTable.allocateIndex();
        indices.add(idx);
        types.add(dataType);
        final ref = MonitorPlcRef.fromVariable(idx, variable);
        buffer.add(ref.toRegisterAndReadBytes());
      }

      final responseBytes =
          await _sendMonitorPlc(Uint8List.fromList(buffer.toBytes()));

      // Register types in local table on success
      for (int i = 0; i < variables.length; i++) {
        _monitorTable.register(indices[i], types[i]);
      }

      // Parse response using the just-registered types
      return _monitorTable.parseReadAllResponse(responseBytes,
          decodeString: decodeString);
    });
  }

  /// Reset all MonitorPlc registrations via MonitorPlc Reset (0x0B).
  ///
  /// Clears both server-side and local registration state.
  Future<void> monitorReset() async {
    return _withSessionAndRecovery(() async {
      await _sendMonitorPlc(Uint8List.fromList([0x0B]));
      _monitorTable.reset();
    });
  }

  /// TD-022: clear the MonitorPlc degraded flag if the retry window
  /// elapsed. Called by [readVariables] on each entry so the next batch
  /// naturally re-probes MonitorPlc.
  void _clearMonitorPlcDegradedIfStale() {
    if (!_monitorPlcDegraded) return;
    final since = _monitorPlcDegradedSince;
    if (since == null) return;
    if (_nowFn().difference(since) < _monitorPlcDegradedRetryAfter) return;
    _monitorPlcDegraded = false;
    _monitorPlcDegradedSince = null;
    _monitorPlc0x82Count = 0;
    _log.i('UMAS MonitorPlc degraded breaker cleared; retrying MonitorPlc.');
  }

  // ---------------------------------------------------------------------------
  // Diagnostic sub-functions (0x06, 0x20, 0x39, 0x58, 0x70, 0x73)
  // ---------------------------------------------------------------------------

  /// Send a diagnostic request with no payload and return raw response bytes.
  ///
  /// Shared helper for simple diagnostic sub-functions that take no input
  /// and return opaque raw bytes (readCardInfo, readEthMasterData, checkPlc,
  /// getStatusModule, readIoObject).
  Future<Uint8List> _sendDiagnostic(UmasSubFunction subFunc) async {
    final request = UmasRequest(
      umasSubFunction: subFunc.code,
      pairingKey: _pairingKey,
      unitId: unitId,
    );
    final code = await sendFn(request);
    if (code != ModbusResponseCode.requestSucceed) {
      throw UmasException(
        errorCode: code.code,
        message: 'UMAS ${subFunc.name} failed: ${code.name}',
      );
    }
    final pdu = request.responsePdu;
    if (pdu == null || pdu.length < 3) {
      throw UmasException(
        errorCode: 0,
        message: 'Empty UMAS ${subFunc.name} response',
      );
    }
    _checkStatus(pdu, subFunc.name);
    return pdu.sublist(3);
  }

  /// Read SD card status (sub-function 0x06).
  ///
  /// Returns raw response bytes containing card presence, capacity, and free space.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<CardInfoResult> readCardInfo() async {
    return _withSession(() async {
      final rawData = await _sendDiagnostic(UmasSubFunction.readCardInfo);
      return CardInfoResult(rawData: rawData);
    });
  }

  /// Read raw memory block (sub-function 0x20).
  ///
  /// Sends a structured [ReadMemoryBlockRequest] and returns a parsed
  /// [ReadMemoryBlockResult] with range, numberOfBytes, and data fields.
  /// Validates response numberOfBytes against available data (T-09-01).
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<ReadMemoryBlockResult> readMemoryBlock(
      ReadMemoryBlockRequest request) async {
    return _withSession(() async {
      final umasRequest = UmasRequest(
        umasSubFunction: UmasSubFunction.readMemoryBlock.code,
        pairingKey: _pairingKey,
        payload: request.toBytes(),
        unitId: unitId,
      );
      final code = await sendFn(umasRequest);
      if (code != ModbusResponseCode.requestSucceed) {
        throw UmasException(
          errorCode: code.code,
          message: 'UMAS readMemoryBlock failed: ${code.name}',
        );
      }
      final pdu = umasRequest.responsePdu;
      if (pdu == null || pdu.length < 3) {
        throw UmasException(
          errorCode: 0,
          message: 'Empty UMAS readMemoryBlock response',
        );
      }
      _checkStatus(pdu, 'readMemoryBlock');
      return ReadMemoryBlockResult.fromPayload(pdu.sublist(3));
    });
  }

  /// Read network topology (sub-function 0x39).
  ///
  /// Returns raw response bytes containing Ethernet master/module data.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<EthMasterDataResult> readEthMasterData() async {
    return _withSession(() async {
      final rawData = await _sendDiagnostic(UmasSubFunction.readEthMasterData);
      return EthMasterDataResult(rawData: rawData);
    });
  }

  /// Verify PLC health (sub-function 0x58).
  ///
  /// Returns raw response bytes indicating PLC health status.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<CheckPlcResult> checkPlc() async {
    return _withSession(() async {
      final rawData = await _sendDiagnostic(UmasSubFunction.checkPlc);
      return CheckPlcResult(rawData: rawData);
    });
  }

  /// Read I/O module data (sub-function 0x70).
  ///
  /// Returns raw response bytes containing I/O object information.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<IoObjectResult> readIoObject() async {
    return _withSession(() async {
      final rawData = await _sendDiagnostic(UmasSubFunction.readIoObject);
      return IoObjectResult(rawData: rawData);
    });
  }

  /// Read per-module status (sub-function 0x73).
  ///
  /// Returns raw response bytes containing module status information.
  /// Uses [_withSession] to auto-initialize if not yet paired.
  Future<StatusModuleResult> getStatusModule() async {
    return _withSession(() async {
      final rawData = await _sendDiagnostic(UmasSubFunction.getStatusModule);
      return StatusModuleResult(rawData: rawData);
    });
  }

  /// Convenience method: ensures session -> readDataTypes -> readVariableNames -> buildVariableTree.
  /// This is the primary entry point for the browse dialog.
  ///
  /// When DD03 (data type table) is available, each top-level variable whose
  /// type is a STRUCT (classId=2) or FB (classId=7) is recursively expanded
  /// into its members, OPC-UA-style. Each leaf [UmasVariable] has its
  /// `blockNo` and `offset` set so that [readVariables] can read it directly.
  ///
  /// Data types (DD03) are optional. If the PLC rejects DD03, top-level
  /// variables are still returned but struct members are not expanded.
  Future<List<UmasVariableTreeNode>> browse({int maxDepth = 6}) async {
    return _withSessionAndRecovery(() async {
      List<UmasDataTypeRef> dataTypes;
      try {
        dataTypes = await _readDataTypesInner();
      } on UmasException catch (e) {
        _log.w('Data dictionary types (DD03) unavailable: ${e.message} '
            '— browsing without struct expansion');
        dataTypes = [];
      }
      final variables = await _readVariableNamesInner();

      if (dataTypes.isEmpty) {
        return buildVariableTree(variables, dataTypes);
      }

      // First, dot-split top-level variable names (CodeSys style: e.g.
      // "Application.GVL.temperature") into folder nodes. Then expand any
      // leaf that resolves to a struct/FB type into its members.
      //
      // B-3 (v1.1.x): the member / array caches are hoisted to per-client
      // lifetime (`_persistentMemberCache`, `_persistentArrayCache`) so
      // back-to-back browses don't reissue DD02 for the same custom
      // type id. Per-browse aliases below preserve the inner-API names.
      final memberCache = _persistentMemberCache;
      final arrayCache = _persistentArrayCache;
      final builder = _TreeBuilder();
      for (final v in variables) {
        builder.insert(v, dataTypes);
      }
      final flatRoots = builder.build();
      return [
        for (final root in flatRoots)
          await _expandTreeNode(
            node: root,
            dataTypes: dataTypes,
            memberCache: memberCache,
            arrayCache: arrayCache,
            depth: 0,
            maxDepth: maxDepth,
          ),
      ];
    });
  }

  /// Walk an existing dot-split tree node and expand any struct/FB leaf into
  /// its members. Folder nodes are recursed into; non-struct leaves are kept
  /// as-is.
  Future<UmasVariableTreeNode> _expandTreeNode({
    required UmasVariableTreeNode node,
    required List<UmasDataTypeRef> dataTypes,
    required Map<int, List<UmasVariable>> memberCache,
    required Map<int, UmasArrayTypeDefinition?> arrayCache,
    required int depth,
    required int maxDepth,
  }) async {
    if (node.children.isNotEmpty) {
      // Folder: recurse into children, leave structure as-is.
      final newChildren = <UmasVariableTreeNode>[];
      for (final child in node.children) {
        newChildren.add(await _expandTreeNode(
          node: child,
          dataTypes: dataTypes,
          memberCache: memberCache,
          arrayCache: arrayCache,
          depth: depth,
          maxDepth: maxDepth,
        ));
      }
      return UmasVariableTreeNode(
        name: node.name,
        path: node.path,
        children: newChildren,
        variable: node.variable,
        dataType: node.dataType,
      );
    }
    if (node.variable == null) return node;
    final expanded = await _expandVariable(
      variable: node.variable!,
      path: node.path,
      dataTypes: dataTypes,
      memberCache: memberCache,
      arrayCache: arrayCache,
      depth: depth,
      maxDepth: maxDepth,
    );
    // Preserve the leaf-only name from the dot-tree builder (e.g. "temperature"
    // rather than the full dotted "Application.GVL.temperature").
    return UmasVariableTreeNode(
      name: node.name,
      path: expanded.path,
      children: expanded.children,
      variable: expanded.variable,
      dataType: expanded.dataType,
    );
  }

  /// Recursively expand a variable into its struct/FB members or array elements.
  ///
  /// plc4j(UmasProtocolLogic.java:1079-1097, 1130-1146): for any custom-type
  /// reference whose `classIdentifier != 0`, plc4j issues a DD02 request keyed
  /// on the type's index (NOT 0xFFFF) and discriminates on the first response
  /// byte. `classId == 0x04` ⇒ UmasArrayTypeDefinition; anything else ⇒
  /// UmasPDUReadUmasUDTDefinitionResponse (member records). We extend this
  /// gate to ALSO fire for variables whose `dataTypeId` did not appear in
  /// DD03 at all — the live M580 at 192.168.112.159 omits FB types from DD03
  /// even though their UDT bodies are accessible via DD02-on-typeIndex. plc4j
  /// strictly gates on the non-zero classIdentifier of a *resolved* DD03
  /// record and would silently drop these FB instances; we resolve
  /// speculatively to surface them. See `.planning/phases/02-fb-visibility-bug-b-core/02-RESEARCH.md`.
  Future<UmasVariableTreeNode> _expandVariable({
    required UmasVariable variable,
    required String path,
    required List<UmasDataTypeRef> dataTypes,
    required Map<int, List<UmasVariable>> memberCache,
    required Map<int, UmasArrayTypeDefinition?> arrayCache,
    required int depth,
    required int maxDepth,
  }) async {
    UmasDataTypeRef? type =
        UmasDataTypes.resolve(variable.dataTypeId, dataTypes);
    bool isStructOrFb = type != null &&
        (type.classIdentifier == 2 || type.classIdentifier == 7);
    bool isArray = type != null && type.classIdentifier == 4;

    // Speculative FB / UDT resolution for variables whose type was not
    // enumerated in DD03 and is not a built-in scalar. Mirrors plc4j
    // `parseCustomTypeBlock`'s classId discriminator (UmasProtocolLogic.java:1130-1146):
    // the first byte of the DD02-on-typeIndex response selects between
    // UmasArrayTypeDefinition (0x04) and UmasPDUReadUmasUDTDefinitionResponse
    // (anything else, including FB instances).
    final isCandidateForSpeculativeResolve = type == null &&
        depth < maxDepth &&
        variable.dataTypeId != 0 &&
        !UmasDataTypes.builtIn.containsKey(variable.dataTypeId);
    if (isCandidateForSpeculativeResolve) {
      // Honour caches before reissuing network I/O. A non-null entry in
      // arrayCache means a previous resolve discovered an array def;
      // a non-empty entry in memberCache means an FB/UDT body.
      final cachedArray = arrayCache[variable.dataTypeId];
      final cachedMembers = memberCache[variable.dataTypeId];
      if (cachedArray != null) {
        isArray = true;
        type = UmasDataTypeRef(
          id: variable.dataTypeId,
          name: '?',
          byteSize: 0,
          classIdentifier: 4,
          dataType: cachedArray.elementTypeId,
        );
      } else if (cachedMembers != null && cachedMembers.isNotEmpty) {
        isStructOrFb = true;
        type = UmasDataTypeRef(
          id: variable.dataTypeId,
          name: 'FB',
          byteSize: 0,
          classIdentifier: 7,
          dataType: variable.dataTypeId,
        );
      } else if (cachedMembers == null && !arrayCache.containsKey(variable.dataTypeId)) {
        // No cache entry either way — fire the speculative DD02 once.
        try {
          final raw = await readDD02Raw(variable.dataTypeId);
          final asArray = UmasArrayTypeDefinition.tryParse(raw);
          if (asArray != null) {
            arrayCache[variable.dataTypeId] = asArray;
            isArray = true;
            // Synthesize a minimal array-class type so the existing
            // array branch can pick it up. byteSize 0 disables the
            // total-bytes / element-count derivation; the array branch
            // will degrade gracefully to a children-less node when
            // byteSize <= 0 (already handled at L1917).
            type = UmasDataTypeRef(
              id: variable.dataTypeId,
              name: '?',
              byteSize: 0,
              classIdentifier: 4,
              dataType: asArray.elementTypeId,
            );
          } else {
            // Reissue via _readDD02Block(isMemberLayout: true) so the
            // response is parsed through the shared
            // _parseVariableRecords code path — same wire layout as
            // plc4j's UmasPDUReadUmasUDTDefinitionResponse / UmasUDTDefinition.
            // Speculative-resolved types that aren't arrays are treated
            // as FBs (classId=7) — see the synthesized type below — so
            // direction classification fires for their members.
            final members = await _readDD02Block(
                blockNo: variable.dataTypeId,
                isMemberLayout: true,
                parentClassId: 7);
            memberCache[variable.dataTypeId] = members;
            if (members.isNotEmpty) {
              isStructOrFb = true;
              type = UmasDataTypeRef(
                id: variable.dataTypeId,
                name: 'FB',
                byteSize: 0,
                classIdentifier: 7,
                dataType: variable.dataTypeId,
              );
            }
            // Empty member list ⇒ leaf (observed on M580 for
            // M_Elevator typeId 0xb6, where the PLC returns a single
            // byte 0x00 — firmware-dependent). The cached empty list
            // prevents per-instance retry.
          }
        } on UmasException catch (e) {
          _log.w('Speculative DD02 resolution failed for type '
              '0x${variable.dataTypeId.toRadixString(16)}: ${e.message}');
          // Cache empty so other instances of this type don't retry.
          memberCache[variable.dataTypeId] = const [];
        }
      }
    }

    if (depth >= maxDepth || (!isStructOrFb && !isArray)) {
      return UmasVariableTreeNode(
        name: variable.name,
        path: path,
        children: const [],
        variable: variable,
        dataType: type,
      );
    }

    // Past the gate, `isStructOrFb || isArray` holds, which is only set
    // when `type` is non-null (either via DD03 resolve or via the
    // speculative DD02 branch above). Pin a local non-null view so the
    // downstream branches keep working without a sea of `!` operators.
    final resolvedType = type!;

    if (isArray) {
      // Fetch the array type definition (PLC4X UmasArrayTypeDefinition) by
      // querying DD02 for the array's data-type id. The DD03 record's
      // `dataType` byte points at the array type itself, not the element,
      // so we need the explicit definition to recover the real elementTypeId
      // and dimension bounds.
      UmasArrayTypeDefinition? arrayDef;
      if (arrayCache.containsKey(variable.dataTypeId)) {
        arrayDef = arrayCache[variable.dataTypeId];
      } else {
        try {
          final raw = await readDD02Raw(variable.dataTypeId);
          arrayDef = UmasArrayTypeDefinition.tryParse(raw);
        } on UmasException catch (e) {
          _log.w('Array DD02 fetch failed for type ${resolvedType.name}: ${e.message}');
          arrayDef = null;
        }
        arrayCache[variable.dataTypeId] = arrayDef;
      }

      final totalElements = arrayDef?.totalElementCount ?? 0;
      if (arrayDef == null ||
          totalElements <= 0 ||
          totalElements > _maxArrayElements) {
        return UmasVariableTreeNode(
          name: variable.name,
          path: path,
          children: const [],
          variable: variable,
          dataType: type,
        );
      }

      // Element size derived from total array byte size (works for arrays of
      // builtin scalars, UDTs, and atypically-sized strings alike).
      //
      // Fix for the speculative-DD02 cardinality mismatch (fuzz,
      // 2026-05-19): when the speculative-DD02 path synthesized the
      // array's type with `byteSize: 0` (because the typeId was absent
      // from DD03 — observed on the live M580 for FB members like
      // `BMEP58_ECPU_EXT.DIO_HEALTH`, `.DIO_CTRL`, `.LS_HEALTH`), the
      // division below yields 0 and the array bails out as a leaf,
      // leaving `lookupSymbol("...DIO_HEALTH[519]")` to throw "symbol
      // not found" even though the cached `arrayDef` describes the
      // elements. When the element type is a known built-in scalar,
      // derive `elementSize` from the built-in directly (using
      // `dim.startIndex` / `upperBound` from the array def), so the
      // symbol cache agrees element-for-element with DD02.
      final builtin = UmasDataTypes.builtIn[arrayDef.elementTypeId];
      final int elementSize;
      if (resolvedType.byteSize > 0) {
        elementSize = resolvedType.byteSize ~/ totalElements;
      } else if (builtin != null && builtin.byteSize > 0) {
        elementSize = builtin.byteSize;
      } else {
        elementSize = 0;
      }
      if (elementSize <= 0) {
        return UmasVariableTreeNode(
          name: variable.name,
          path: path,
          children: const [],
          variable: variable,
          dataType: type,
        );
      }

      final children = <UmasVariableTreeNode>[];
      // Use the element's natural index range from the first dimension when
      // the array is 1D (so e.g. ARRAY[1..100] surfaces [1]..[100], matching
      // the PLC's symbolic addressing). For multi-dim arrays, fall back to a
      // flat zero-based index — operators rarely encounter these and the path
      // notation is unambiguous.
      final useNaturalIndex = arrayDef.dimensions.length == 1;
      final start = useNaturalIndex ? arrayDef.dimensions.first.startIndex : 0;

      // STRING in the built-in table is hardcoded at 256 bytes, but Schneider
      // PLCs store STRING(N) with N typically much smaller (e.g. 16 inside an
      // ARRAY OF STRING(16)). The array layout's per-element size is
      // authoritative — synthesize an element-typed ref whose byteSize matches
      // the actual on-wire size so the read clamp and parser agree.
      // Resolve the element type. Built-ins and DD03 custom types both go
      // through `UmasDataTypes.resolve`. STRING is hardcoded at 256 bytes in
      // the built-in table but Schneider PLCs commonly emit STRING(N) inside
      // arrays — when the layout-derived size disagrees with the built-in,
      // synthesize a ref keyed on the built-in's name with the actual size.
      UmasDataTypeRef? resolvedElementType =
          UmasDataTypes.resolve(arrayDef.elementTypeId, dataTypes);
      if (builtin != null && resolvedElementType?.byteSize != elementSize) {
        resolvedElementType = UmasDataTypeRef(
          id: builtin.id,
          name: builtin.name,
          byteSize: elementSize,
          classIdentifier: builtin.classIdentifier,
          dataType: builtin.dataType,
        );
      }
      resolvedElementType ??= UmasDataTypeRef(
          id: arrayDef.elementTypeId, name: '?', byteSize: elementSize);

      for (int i = 0; i < totalElements; i++) {
        final displayIndex = start + i;
        final elementVar = UmasVariable(
          name: '[$displayIndex]',
          blockNo: variable.blockNo,
          offset: variable.offset + i * elementSize,
          dataTypeId: arrayDef.elementTypeId,
        );
        // For built-in scalar elements with size override (STRING(N), etc.),
        // emit the leaf directly; otherwise recurse so structs/arrays expand.
        final isCustom = builtin == null;
        if (isCustom) {
          children.add(await _expandVariable(
            variable: elementVar,
            path: '$path[$displayIndex]',
            dataTypes: dataTypes,
            memberCache: memberCache,
            arrayCache: arrayCache,
            depth: depth + 1,
            maxDepth: maxDepth,
          ));
        } else {
          children.add(UmasVariableTreeNode(
            name: '[$displayIndex]',
            path: '$path[$displayIndex]',
            children: const [],
            variable: elementVar,
            dataType: resolvedElementType,
          ));
        }
      }

      // Keep the array variable on the parent node so callers can still issue
      // a whole-array read via readVariables; the per-element children expose
      // individual addresses for OPC-UA-style browsing.
      return UmasVariableTreeNode(
        name: variable.name,
        path: path,
        children: children,
        variable: variable,
        dataType: type,
      );
    }

    // Fetch struct member layout (cached per typeId). Forward
    // resolvedType.classIdentifier so the per-member direction
    // classifier only fires for FB members (classId=7) and NOT for
    // arbitrary UDT struct fields (classId=2). F-1 v1.1.
    List<UmasVariable> members;
    try {
      members = memberCache.putIfAbsent(
          variable.dataTypeId, () => <UmasVariable>[]);
      if (members.isEmpty) {
        memberCache[variable.dataTypeId] = members = await _readDD02Block(
            blockNo: variable.dataTypeId,
            isMemberLayout: true,
            parentClassId: resolvedType.classIdentifier);
      }
    } on UmasException catch (e) {
      _log.w('Struct expansion failed for type ${resolvedType.name}: ${e.message}');
      return UmasVariableTreeNode(
        name: variable.name,
        path: path,
        children: const [],
        variable: variable,
        dataType: type,
      );
    }

    final children = <UmasVariableTreeNode>[];
    for (final m in members) {
      // For struct members, the parser puts the byte-offset-within-parent
      // into `blockNo`. Compute the member's absolute address by combining
      // it with the parent's address.
      // Phase 3 (v1.1): forward the member's `direction` so the tree node
      // can render input/output/public/in_out distinctly. `m.direction` is
      // populated by `_parseVariableRecords` when `isMemberLayout == true`
      // (null for non-FB struct members).
      final memberAddr = UmasVariable(
        name: m.name,
        blockNo: variable.blockNo,
        offset: variable.offset + m.blockNo,
        dataTypeId: m.dataTypeId,
        direction: m.direction,
      );
      final childNode = await _expandVariable(
        variable: memberAddr,
        path: '$path.${m.name}',
        dataTypes: dataTypes,
        memberCache: memberCache,
        arrayCache: arrayCache,
        depth: depth + 1,
        maxDepth: maxDepth,
      );
      // Surface direction on the tree node so downstream consumers
      // (browser tree, CLI --show-direction) can read it without
      // peeking into UmasVariable. `_expandVariable` doesn't carry the
      // direction parameter; rebuild the node with the direction attached.
      // F-5 wiring: VAR_IN_OUT members are pointer-backed (PLC returns
      // 0x94 on read); mark them unreadable with a human-readable reason
      // so the UI renders the "not readable" affordance instead of
      // silently dropping them.
      final dir = m.direction;
      final readable = dir == null ? true : isReadableForDirection(dir);
      final unreadableReason =
          dir == null ? null : unreadableReasonForDirection(dir);
      children.add(UmasVariableTreeNode(
        name: childNode.name,
        path: childNode.path,
        children: childNode.children,
        variable: childNode.variable,
        dataType: childNode.dataType,
        direction: dir,
        readable: readable,
        unreadableReason: unreadableReason,
      ));
    }

    return UmasVariableTreeNode(
      name: variable.name,
      path: path,
      children: children,
      variable: variable,
      dataType: type,
    );
  }
}

/// Internal helper for building the variable tree from flat paths.
class _TreeBuilderNode {
  final String name;
  final String path;
  final Map<String, _TreeBuilderNode> children = {};
  UmasVariable? variable;
  UmasDataTypeRef? dataType;

  _TreeBuilderNode(this.name, this.path);

  UmasVariableTreeNode toTreeNode() {
    return UmasVariableTreeNode(
      name: name,
      path: path,
      children: children.values.map((c) => c.toTreeNode()).toList(),
      variable: variable,
      dataType: dataType,
    );
  }
}

class _TreeBuilder {
  final Map<String, _TreeBuilderNode> roots = {};

  void insert(UmasVariable v, List<UmasDataTypeRef> dataTypes) {
    final parts = v.name.split('.');
    var currentLevel = roots;
    var pathSoFar = '';

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      pathSoFar = pathSoFar.isEmpty ? part : '$pathSoFar.$part';
      final isLeaf = (i == parts.length - 1);

      currentLevel.putIfAbsent(part, () => _TreeBuilderNode(part, pathSoFar));
      final node = currentLevel[part]!;

      if (isLeaf) {
        node.variable = v;
        node.dataType = UmasDataTypes.resolve(v.dataTypeId, dataTypes);
      } else {
        currentLevel = node.children;
      }
    }
  }

  List<UmasVariableTreeNode> build() {
    return roots.values.map((n) => n.toTreeNode()).toList();
  }
}
