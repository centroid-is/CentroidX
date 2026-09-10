import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:meta/meta.dart'; // Add this import at the top
import 'package:logger/logger.dart';
import 'package:open62541/open62541.dart';
import 'package:rxdart/rxdart.dart';
import 'package:collection/collection.dart';

import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import 'package:jbtm/src/m2400_fields.dart' show M2400Field;
import 'package:jbtm/src/m2400_client_wrapper.dart' show M2400ClientWrapper;
import 'package:tfc_dart/core/log_config.dart' show opcuaLogLevelFromEnv;
import 'package:jbtm/src/msocket.dart' as jbtm show ConnectionStatus;

import 'package:modbus_client/modbus_client.dart'
    show ModbusElementType, ModbusEndianness;

import 'collector.dart';
import 'conn_meta.dart';
import 'modbus_client_wrapper.dart' show ModbusDataType;
import 'modbus_device_client.dart'
    show
        ModbusDeviceClientAdapter,
        buildUmasPollGroupsFromKeyMappings,
        buildVariableNamesFromKeyMappings;
import 'preferences.dart';
import 'auto_disposing_stream.dart';
import 'state_man_types.dart';

// The configuration types, the key mappings and the StateMan interface moved to
// state_man_types.dart so that a build with no `dart:ffi` can still name them.
// Re-exported so every existing `import 'state_man.dart'` is unaffected.
export 'state_man_types.dart';

import 'state_man_config_storage.dart';
/// Kept re-exported: `fromPrefs` is called from several places that also
/// build a client, and they should not need two imports.
export 'state_man_config_storage.dart';


class ClientWrapper {
  final ClientApi client;
  final OpcUAConfig config;
  int? subscriptionId;
  final SingleWorker worker = SingleWorker();
  StreamSubscription? _heartbeatSub;
  int _heartbeatGeneration = 0;
  DateTime? _lastHeartbeatTick;
  bool _inactive = false;
  bool sessionLost = false;
  bool resendOnRecovery;
  final Set<AutoDisposingStream> streams = {};
  final Logger _logger = Logger();

  // --- monitored-item accounting (diagnostics only) -----------------------
  //
  // Counts what this client has ASKED the server to create. One logical key
  // is four monitored items: monitor() requests DataType, Value, Description
  // and DisplayName.
  //
  // There is deliberately no matching "deleted" counter. The binding's
  // onCancel is `() { subscription.cancel(); }` -- a block body that discards
  // the inner future -- so a cancel completes locally the moment it is
  // requested, never when the server acknowledges the delete. A counter fed
  // from that would read healthy during exactly the leak it was added to
  // catch. Until the binding surfaces the delete future, the honest figure is
  // the create count and the retry count beside it.
  int monitoredItemsCreated = 0;

  /// One line summarising what this client has asked the server to create.
  String get monitoredItemReport => 'created=$monitoredItemsCreated';

  /// Check if the subscription is dead and needs to be recreated.
  /// Only SubscriptionDeleted (server killed it) and SecureChannelClosed
  /// (connection lost) are fatal — Inactivity is transient and recovers
  /// on its own when the connection stabilises.
  /// Handles both direct type checks AND string representations — the
  /// isolate handler converts errors to strings via error.toString().
  static bool isSubscriptionDead(Object error) {
    if (error is SubscriptionDeleted || error is SecureChannelClosed) {
      return true;
    }
    if (error is String) {
      return error.contains('SubscriptionDeleted') ||
          error.contains('SecureChannelClosed');
    }
    return false;
  }

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  final StreamController<ConnectionStatus> _connectionController =
      StreamController<ConnectionStatus>.broadcast();

  // ---------------------------------------------------------------------------
  // Connection-metadata instrumentation (additive, null-safe)
  // ---------------------------------------------------------------------------

  /// Rolling requests-per-second. Approximates OPC-UA protocol load by
  /// counting monitored-item value emissions (and heartbeat ticks) routed
  /// through StateMan's subscription wiring for this server — the native
  /// publish rate is not exposed through the isolate binding.
  final RollingRate _requestRate = RollingRate();

  /// The most recent raw [ClientState] seen on the state stream.
  ClientState? _lastClientState;

  /// Timestamp of the most recent transition to `connected`.
  DateTime? _connectedSince;
  bool _everConnected = false;
  int _reconnectCount = 0;
  String _lastError = '';

  /// Record one OPC-UA value emission for the requests-per-second rate.
  void recordRequest() => _requestRate.increment();

  /// Capture the last error string surfaced at a heartbeat/channel failure.
  void recordError(String error) => _lastError = error;

  /// Rolling requests-per-second over the recent window.
  double get requestsPerSec => _requestRate.ratePerSec;

  /// Seconds since the last successful connect (0 when not connected).
  double get uptimeSec {
    final since = _connectedSince;
    if (since == null || _connectionStatus != ConnectionStatus.connected) {
      return 0;
    }
    return DateTime.now().difference(since).inMilliseconds / 1000.0;
  }

  int get reconnectCount => _reconnectCount;
  String get lastError => _lastError;

  /// Name of the last-seen secure-channel state (e.g. UA_SECURECHANNELSTATE_*).
  String get channelStateName => _lastClientState?.channelState.name ?? '';

  /// Name of the last-seen session state (e.g. UA_SESSIONSTATE_*).
  String get sessionStateName => _lastClientState?.sessionState.name ?? '';

  /// Last-seen recovery status code.
  int get recoveryStatus => _lastClientState?.recoveryStatus ?? 0;

  /// Seconds since the last heartbeat/data tick, or 0 if none yet.
  double get lastDataAgeSec {
    final tick = _lastHeartbeatTick;
    if (tick == null) return 0;
    return DateTime.now().difference(tick).inMilliseconds / 1000.0;
  }

  ClientWrapper(this.client, this.config, {this.resendOnRecovery = true});

  /// Current connection status (synchronous, always up-to-date).
  ConnectionStatus get connectionStatus => _connectionStatus;

  /// Stream of connection status changes. Subscribe anytime — read
  /// [connectionStatus] for the current value.
  Stream<ConnectionStatus> get connectionStream => _connectionController.stream;

  /// Heartbeat older than this while "connected" → [EffectiveDeviceStatus
  /// .opcuaUnhealthy]. The heartbeat samples the server-time node at the
  /// server's [OpcUAConfig.publishingInterval] on the same subscription as
  /// every data key, so 15 s of silence means the operator has been looking
  /// at frozen values for 15 s. This is why that interval is clamped to
  /// [OpcUAConfig.publishingIntervalMaxMs], well below 15 s.
  static const heartbeatStaleAfter = Duration(seconds: 15);

  /// How long after a connect the heartbeat may take to produce its first
  /// tick before the silence itself is a finding. Covers subscription +
  /// monitored-item setup on a slow server; boot measurements on the plant
  /// boxes put the real figure under 3 s.
  static const heartbeatStartGrace = Duration(seconds: 30);

  Timer? _healthTimer;

  // Staleness is a function of time, not of events — the frozen-session
  // failure emits nothing at all, so only a clock can notice it. The clock
  // only runs while someone is watching: an always-on periodic timer leaks
  // past every widget test that builds a StateMan without draining it
  // ("A Timer is still pending…"), and an unobserved wrapper has nobody to
  // tell anyway — the synchronous [effectiveStatus] getter re-derives on
  // every read, so nothing goes stale while the timer is parked.
  late final BehaviorSubject<EffectiveDeviceStatus> _effectiveStatus$ =
      BehaviorSubject<EffectiveDeviceStatus>.seeded(
    _deriveEffectiveStatus(),
    onListen: _startHealthTimer,
    onCancel: _stopHealthTimer,
  );

  void _startHealthTimer() {
    // The replayed seed may predate this listener — refresh it first.
    _recomputeEffectiveStatus();
    _healthTimer ??= Timer.periodic(
        const Duration(seconds: 2), (_) => _recomputeEffectiveStatus());
  }

  void _stopHealthTimer() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  /// Combined link + data-plane health (analog of the Modbus adapter's
  /// TD-004 stream). Unlike [connectionStatus] this cannot go stale: it is
  /// derived from the heartbeat clock on every read, and pushed to
  /// [effectiveStatusStream] on a 2 s timer while anyone listens, so a
  /// client that dies without emitting a single state event still drops
  /// out of `connected` within seconds.
  EffectiveDeviceStatus get effectiveStatus => _deriveEffectiveStatus();

  Stream<EffectiveDeviceStatus> get effectiveStatusStream =>
      _effectiveStatus$.stream;

  EffectiveDeviceStatus _deriveEffectiveStatus() {
    switch (_connectionStatus) {
      case ConnectionStatus.disconnected:
        return EffectiveDeviceStatus.disconnected;
      case ConnectionStatus.connecting:
        return EffectiveDeviceStatus.connecting;
      case ConnectionStatus.connected:
        break;
    }
    // The event-driven status says connected — verify the data plane
    // agrees before rendering green.
    if (sessionLost || _inactive) return EffectiveDeviceStatus.opcuaUnhealthy;
    final tick = _lastHeartbeatTick;
    if (tick == null) {
      final since = _connectedSince;
      if (since == null ||
          DateTime.now().difference(since) > heartbeatStartGrace) {
        return EffectiveDeviceStatus.opcuaUnhealthy;
      }
      // Subscription + heartbeat still warming up after a fresh connect.
      return EffectiveDeviceStatus.connecting;
    }
    if (DateTime.now().difference(tick) > heartbeatStaleAfter) {
      return EffectiveDeviceStatus.opcuaUnhealthy;
    }
    return EffectiveDeviceStatus.connected;
  }

  void _recomputeEffectiveStatus() {
    if (_effectiveStatus$.isClosed) return;
    final next = _deriveEffectiveStatus();
    if (_effectiveStatus$.valueOrNull == next) return;
    _effectiveStatus$.add(next);
  }

  void updateConnectionStatus(ClientState state) {
    // Capture the raw state even when the derived ConnectionStatus is
    // unchanged — channel/session sub-states shift while the coarse status
    // holds steady, and the metadata getters surface them.
    _lastClientState = state;
    final next = _mapState(state);
    if (next == _connectionStatus) return;
    if (next == ConnectionStatus.connected) {
      if (_everConnected) _reconnectCount++;
      _everConnected = true;
      _connectedSince = DateTime.now();
      // A successful connect supersedes the previous error — a stale
      // message must not stay on the Connection Info card indefinitely.
      _lastError = '';
    } else if (next == ConnectionStatus.disconnected) {
      _connectedSince = null;
    }
    _connectionStatus = next;
    // OpcUaStateMan._() installs a stateStream listener that calls this, and
    // nothing ever cancels it -- not close(), not dispose(). close() disposes
    // the wrapper, which closes this controller, so a state event racing
    // shutdown would otherwise throw out of that listener.
    if (_connectionController.isClosed) return;
    _connectionController.add(next);
    // Push genuine transitions immediately — the health timer only runs
    // while the stream is listened to, and even then this skips its lag.
    _recomputeEffectiveStatus();
  }

  static ConnectionStatus _mapState(ClientState state) {
    if (state.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED) {
      return ConnectionStatus.connected;
    }
    if (state.channelState == SecureChannelState.UA_SECURECHANNELSTATE_OPEN) {
      return ConnectionStatus.connecting;
    }
    return ConnectionStatus.disconnected;
  }

  void startHeartbeat(int subId) {
    _heartbeatSub?.cancel();
    final serverTimeNode = NodeId.fromNumeric(0, 2258);
    // Generation counter: isolate stream cancel() is async and stale
    // callbacks can fire after stopHeartbeat(). Each callback checks
    // its captured generation against the current one.
    final gen = ++_heartbeatGeneration;
    _logger.i('[${config.endpoint}] Starting heartbeat on sub=$subId');
    _heartbeatSub = client.monitoredItems(
      {
        serverTimeNode: [AttributeId.UA_ATTRIBUTEID_VALUE]
      },
      subId,
      samplingInterval: config.publishingInterval,
    ).listen(
      (_) {
        if (gen != _heartbeatGeneration) return;
        _lastHeartbeatTick = DateTime.now();
        recordRequest();
        _recomputeEffectiveStatus();
        if (_inactive) {
          _logger.i('[${config.endpoint}] Heartbeat recovered (sub=$subId)');
          _handleRecovery();
        }
        if (_connectionStatus == ConnectionStatus.disconnected) {
          updateConnectionStatus(ClientState(
            channelState: SecureChannelState.UA_SECURECHANNELSTATE_OPEN,
            sessionState: SessionState.UA_SESSIONSTATE_ACTIVATED,
            recoveryStatus: 0,
          ));
        }
      },
      onError: (error) {
        if (gen != _heartbeatGeneration) return;
        final now = DateTime.now();
        final sinceTick = _lastHeartbeatTick != null
            ? now.difference(_lastHeartbeatTick!).inMilliseconds
            : -1;
        recordError(error.toString());
        _logger.w('[${config.endpoint}] Heartbeat error (sub=$subId, '
            '${now.toUtc().toIso8601String()}, ${sinceTick}ms since last tick): $error');
        if (error is Inactivity || error.toString().contains('Inactivity')) {
          _inactive = true;
          return;
        }
        if (isSubscriptionDead(error)) {
          _logger.e('[${config.endpoint}] Heartbeat lost (sub=$subId): $error');
          sessionLost = true;
          stopHeartbeat();
        }
      },
    );
  }

  void stopHeartbeat() {
    _heartbeatSub?.cancel();
    _heartbeatSub = null;
  }

  void _handleRecovery() {
    _inactive = false;
    if (resendOnRecovery) {
      for (final s in streams) {
        s.resendLastValue();
      }
    }
  }

  /// Mark session as lost — called by stateStream as fallback when
  /// heartbeat didn't catch it (e.g. session drops before heartbeat started).
  void markSessionLost() => sessionLost = true;

  /// Simulate inactivity for testing.
  @visibleForTesting
  void simulateInactivity() => _inactive = true;

  /// Set the last heartbeat tick and re-derive health — lets tests age the
  /// heartbeat without waiting out [heartbeatStaleAfter] in real time.
  @visibleForTesting
  void debugSetLastHeartbeatTick(DateTime tick) {
    _lastHeartbeatTick = tick;
    _recomputeEffectiveStatus();
  }

  /// Re-derive [effectiveStatus] now instead of waiting for the 2 s timer.
  @visibleForTesting
  void debugRecomputeEffectiveStatus() => _recomputeEffectiveStatus();

  /// Simulate a fatal heartbeat error (SubscriptionDeleted/SecureChannelClosed).
  @visibleForTesting
  void simulateFatalHeartbeatError() {
    sessionLost = true;
    stopHeartbeat();
  }

  /// Simulate heartbeat tick for testing (triggers recovery if inactive).
  @visibleForTesting
  void simulateHeartbeatTick() {
    if (_inactive) {
      _handleRecovery();
    }
  }

  void dispose() {
    stopHeartbeat();
    _stopHealthTimer();
    _effectiveStatus$.close();
    _connectionController.close();
  }
}

/// Adapter that wraps [M2400ClientWrapper] from the jbtm package as a
/// [DeviceClient] for use in [StateMan].
///
/// Maps jbtm's [jbtm.ConnectionStatus] to state_man's [ConnectionStatus] and
/// delegates subscribe/connect/dispose to the underlying wrapper.
class M2400DeviceClientAdapter implements DeviceClient {
  /// The underlying M2400ClientWrapper from jbtm.
  final M2400ClientWrapper wrapper;

  /// The server alias for this device (from M2400Config).
  final String? serverAlias;

  static const _validKeys = {'BATCH', 'STAT', 'INTRO', 'LUA'};

  M2400DeviceClientAdapter(this.wrapper, {this.serverAlias});

  @override
  Set<String> get subscribableKeys => _validKeys;

  @override
  bool canSubscribe(String key) => _validKeys.contains(key.split('.').first);

  @override
  Stream<DynamicValue> subscribe(String key) => wrapper.subscribe(key);

  @override
  DynamicValue? read(String key) => wrapper.lastValue(key);

  @override
  ConnectionStatus get connectionStatus => _mapStatus(wrapper.status);

  @override
  Stream<ConnectionStatus> get connectionStream =>
      wrapper.statusStream.map(_mapStatus);

  @override
  Future<void> write(String key, DynamicValue value) {
    throw UnsupportedError('M2400 does not support writes');
  }

  @override
  void connect() => wrapper.connect();

  @override
  void dispose() => wrapper.dispose();

  /// Map jbtm's ConnectionStatus to state_man's ConnectionStatus.
  static ConnectionStatus _mapStatus(jbtm.ConnectionStatus s) {
    switch (s) {
      case jbtm.ConnectionStatus.connected:
        return ConnectionStatus.connected;
      case jbtm.ConnectionStatus.connecting:
        return ConnectionStatus.connecting;
      case jbtm.ConnectionStatus.disconnected:
        return ConnectionStatus.disconnected;
    }
  }
}

/// Create [DeviceClient] instances for each [M2400Config] in the list.
///
/// Each M2400Config produces one [M2400DeviceClientAdapter] wrapping an
/// [M2400ClientWrapper]. The caller is responsible for calling [connect()]
/// and [dispose()] on the returned clients.
///
/// Servers with `enabled == false` are skipped — no wrapper, no socket, no
/// reconnect chatter in the log.
List<DeviceClient> createM2400DeviceClients(List<M2400Config> configs) {
  return configs.where((config) => config.enabled).map((config) {
    final wrapper = M2400ClientWrapper(config.host, config.port);
    return M2400DeviceClientAdapter(wrapper, serverAlias: config.serverAlias);
  }).toList();
}

class OpcUaStateMan implements StateMan {
  final logger = Logger();
  final StateManConfig config;
  KeyMappings keyMappings;

  /// Apply bit mask extraction to a raw [DynamicValue].
  ///
  /// Returns the original value unchanged if [bitMask] is null.
  /// Single-bit mask returns bool; multi-bit returns int.
  /// Non-numeric values pass through unchanged.
  ///
  /// **The provenance rides across the mask.** A masked read builds a *fresh*
  /// [DynamicValue], and until this carried them over it silently dropped the
  /// server's `statusCode` and `sourceTimestamp` — so a masked OPC UA key
  /// arrived at the pipe looking like a value no server ever vouched for, and
  /// `translateOpcUaSample` substituted its own arrival instant for a stamp the
  /// PLC had actually sent. Masking selects a bit out of a reading; it does not
  /// make the reading come from somewhere else.
  static DynamicValue applyBitMask(
      DynamicValue value, int? bitMask, int? bitShift) {
    if (bitMask == null) return value;
    final raw = value.value;
    if (raw is! num) return value;
    final intValue = raw.toInt();
    final masked = (intValue & bitMask) >>> (bitShift ?? 0);
    // Single-bit: power of two check (exactly one bit set)
    final isSingle = bitMask != 0 && (bitMask & (bitMask - 1)) == 0;
    if (isSingle) {
      return DynamicValue(value: masked != 0, typeId: NodeId.boolean)
        ..statusCode = value.statusCode
        ..sourceTimestamp = value.sourceTimestamp;
    }
    return DynamicValue(value: masked, typeId: value.typeId)
      ..statusCode = value.statusCode
      ..sourceTimestamp = value.sourceTimestamp;
  }

  final List<ClientWrapper> clients;
  final List<DeviceClient> deviceClients;
  final Map<String, AutoDisposingStream<DynamicValue>> _subscriptions = {};

  /// One live [_monitorLoop] per key: each new loop bumps the key's
  /// generation, and a loop whose generation is no longer current dies at its
  /// next checkpoint instead of acting.
  ///
  /// Without this, nothing serialized the loops. Every session-lost
  /// resubscribe and key-mapping edit started a fresh loop while the previous
  /// ones sat on their 1s/10s/60s/600s ladders; a stale loop waking from
  /// backoff would cancel the raw subscription of the loop that had already
  /// succeeded (deleting the live monitored items on the PLC) and re-create
  /// them. On hmi-pokkun (.81, 2026-08-28) whole 280-key cohorts of stale
  /// loops woke together at 17:22:57 and 17:24:29 and re-created every st101
  /// key against a healthy session; the delete/create storm left orphaned
  /// monitored items on the server (8388 "Could not process a notification
  /// with clienthandle N" over 21h) and froze individual keys forever.
  final Map<String, int> _monitorLoopGeneration = {};
  bool _shouldRun = true;
  final Map<String, String> _substitutions = {};
  final _subsMap$ = BehaviorSubject<Map<String, String>>.seeded(const {});
  String alias;

  /// Constructor requires the server endpoint.
  OpcUaStateMan._({
    required this.config,
    required this.keyMappings,
    required this.clients,
    required this.alias,
    this.deviceClients = const [],
  }) {
    for (final wrapper in clients) {
      if (wrapper.client is Client) {
        // spawn a background task to keep the client active
        () async {
          final clientref = wrapper.client as Client;
          final stats =
              RunIterateStats("${wrapper.config.endpoint} \"$alias\"");
          while (_shouldRun) {
            try {
              clientref.connect(wrapper.config.endpoint).onError(
                  (e, stacktrace) => logger.e(
                      'Failed to connect to ${wrapper.config.endpoint}: $e'));
              while (_shouldRun) {
                final startTime = DateTime.now();
                final continueRunning =
                    clientref.runIterate(const Duration(milliseconds: 10));
                final execTime = DateTime.now().difference(startTime);
                stats.recordCall(execTime);
                if (!continueRunning) break;
                await Future.delayed(const Duration(milliseconds: 10));
              }
              stats.logFinal();
              logger.e('Disconnecting client');
              clientref.disconnect();
            } catch (error) {
              logger.e("Client run iterate error: $error");
              try {
                clientref.disconnect();
              } catch (_) {}
            }
            await Future.delayed(const Duration(milliseconds: 1000));
          }
          logger.e('StateMan background run iterate task exited');
        }();
      }
      if (wrapper.client is ClientIsolate) {
        final clientref = wrapper.client as ClientIsolate;
        () async {
          while (_shouldRun) {
            try {
              clientref.connect(wrapper.config.endpoint).onError(
                  (e, stacktrace) => logger.e(
                      'Failed to connect to ${wrapper.config.endpoint}: $e'));
              await clientref.runIterate();
            } catch (error) {
              logger.e("run iterate error: $error");
              try {
                // try to disconnect
                await clientref.disconnect();
              } catch (_) {}
              // Throttle if often occuring error
              await Future.delayed(const Duration(seconds: 1));
            }
          }
        }();
      }

      SecureChannelState? lastChannelState;
      DateTime? channelOpenedAt;
      final channelLifetimeSec = 60; // 1 minute as configured

      wrapper.client.stateStream.listen((value) {
        wrapper.updateConnectionStatus(value);
        final now = DateTime.now();

        // Log SecureChannel state transitions with timestamps
        if (value.channelState != lastChannelState) {
          final timeSinceOpen = channelOpenedAt != null
              ? now.difference(channelOpenedAt!).inSeconds
              : 0;
          logger.i(
              '[$alias ${wrapper.config.endpoint}] SecureChannel state: ${lastChannelState?.name} -> ${value.channelState.name} '
              '(session: ${value.sessionState.name}, recovery: ${value.recoveryStatus}) '
              '[uptime: ${timeSinceOpen}s]');

          if (value.channelState ==
              SecureChannelState.UA_SECURECHANNELSTATE_OPEN) {
            channelOpenedAt = now;
            logger.i(
                '[$alias ${wrapper.config.endpoint}] Channel opened at $now, renewal expected at ~${channelLifetimeSec * 0.75}s');
          }

          lastChannelState = value.channelState;
        }

        if (value.channelState ==
            SecureChannelState.UA_SECURECHANNELSTATE_CLOSED) {
          final timeSinceOpen = channelOpenedAt != null
              ? now.difference(channelOpenedAt!).inSeconds
              : 0;
          logger.e(
              '[$alias ${wrapper.config.endpoint}] Channel closed after ${timeSinceOpen}s (expected lifetime: ${channelLifetimeSec}s, '
              'renewal window: ${channelLifetimeSec * 0.75}s-${channelLifetimeSec}s)');
          channelOpenedAt = null;
        }
        // Fallback: treat as session loss if wrapper had a subscription
        // (heartbeat may have already set sessionLost via fatal error)
        if (value.sessionState ==
                SessionState.UA_SESSIONSTATE_CREATE_REQUESTED &&
            wrapper.subscriptionId != null) {
          logger.e('[$alias ${wrapper.config.endpoint}] Session lost!');
          wrapper.markSessionLost();
        }
        if (value.sessionState == SessionState.UA_SESSIONSTATE_ACTIVATED) {
          if (wrapper.sessionLost) {
            logger.e(
                '[$alias ${wrapper.config.endpoint}] Session lost, resubscribing (old sub=${wrapper.subscriptionId})');
            wrapper.sessionLost = false;
            wrapper.subscriptionId = null;
            wrapper.stopHeartbeat();
            // Only resubscribe keys belonging to this wrapper
            final lostAlias = wrapper.config.serverAlias;
            final keysToResub = _subscriptions.values
                .where((e) => keyMappings.lookupServerAlias(e.key) == lostAlias)
                .map((e) => e.key)
                .toList();
            logger.i(
                '[$alias ${wrapper.config.endpoint}] Resubscribing ${keysToResub.length} keys');

            // Phase 1: Cancel ALL old raw subscriptions before creating
            // any new ones. This queues all DeleteMonitoredItemsRequests
            // in the native layer synchronously. By doing all cancels
            // first, we prevent cross-key monId collision: after session
            // loss the server assigns fresh monIds (1, 2, 3…) that may
            // collide with OLD monIds captured in other keys' cancel
            // closures, so a stale delete for key A could destroy key B's
            // newly created item if creates and deletes are interleaved.
            for (final key in keysToResub) {
              final ads = _subscriptions[key];
              logger.d('[$alias] resub $key: exists=${ads != null}, '
                  'hasRawSub=${ads?.rawSub != null}');
              if (ads != null && ads.rawSub != null) {
                final oldSub = ads.rawSub;
                ads.rawSub = null;
                oldSub!.cancel(); // fire-and-forget; queues delete via FFI
              }
            }

            // Phase 2: Now create new monitored items. All deletes are
            // already queued and will be sent before any creates because
            // runIterate hasn't had a chance to run yet (no await above).
            for (final key in keysToResub) {
              _monitor(key, resub: true).catchError((e, s) {
                logger.e('[$alias] Failed to resubscribe key "$key": $e\n$s');
                return Stream<DynamicValue>.error(
                    e is Object ? e : StateManException('resubscribe failed'));
              });
            }
          }
        }
      }, onError: (e, s) {
        logger.e('[$alias] Failed to listen to state stream: $e, $s');
      });
    }
  }

  static Future<OpcUaStateMan> create({
    required StateManConfig config,
    required KeyMappings keyMappings,
    bool useIsolate = true,
    String alias = '',
    List<DeviceClient> deviceClients = const [],
    bool resendOnRecovery = true,
  }) async {
    // Example directory: /Users/jonb/Library/Containers/is.centroid.sildarvinnsla.skammtalina/Data/Documents/certs
    List<ClientWrapper> clients = [];
    // Disabled servers get no client at all: no connect loop, no
    // SecureChannel state logging, no subscription retries.
    for (final opcuaConfig in config.enabledOpcua) {
      Uint8List? cert;
      Uint8List? key;
      MessageSecurityMode securityMode =
          MessageSecurityMode.UA_MESSAGESECURITYMODE_NONE;
      if (opcuaConfig.sslCert != null && opcuaConfig.sslKey != null) {
        cert = opcuaConfig.sslCert!;
        key = opcuaConfig.sslKey!;
        securityMode =
            MessageSecurityMode.UA_MESSAGESECURITYMODE_SIGNANDENCRYPT;
      }
      String? username;
      String? password;
      if (opcuaConfig.username != null && opcuaConfig.password != null) {
        username = opcuaConfig.username;
        password = opcuaConfig.password;
      }
      // Per-server now, not a hardcoded minute: the short lifetime was here
      // to reproduce the frozen-session bug, and a station that is not
      // hunting that bug should not be renewing its channel every minute.
      // Recovery from a bad renewal does not depend on this being short —
      // see [ClientWrapper.isSubscriptionDead] and the heartbeat-derived
      // effective status.
      final channelLifetime = opcuaConfig.secureChannelLifetime;
      clients.add(ClientWrapper(
        useIsolate
            ? await ClientIsolate.create(
                username: username,
                password: password,
                certificate: cert,
                privateKey: key,
                securityMode: securityMode,
                logLevel: opcuaLogLevelFromEnv(),
                secureChannelLifeTime: channelLifetime,
              )
            : Client(
                username: username,
                password: password,
                certificate: cert,
                privateKey: key,
                securityMode: securityMode,
                logLevel: opcuaLogLevelFromEnv(),
                secureChannelLifeTime: channelLifetime,
              ),
        opcuaConfig,
        resendOnRecovery: resendOnRecovery,
      ));
    }
    final stateMan = OpcUaStateMan._(
        config: config,
        keyMappings: keyMappings,
        clients: clients,
        alias: alias,
        deviceClients: deviceClients);

    // Connect device clients
    for (final dc in deviceClients) {
      dc.connect();
    }

    return stateMan;
  }

  /// Aliases switched off in [config], resolved once.
  ///
  /// [read]/[write]/[subscribe] consult this on every call, and a
  /// [StateMan]'s config never changes after [create] — only the key
  /// mappings do — so there is nothing to invalidate.
  late final Set<String?> _disabledAliases = config.disabledServerAliases;

  /// Router for `@conn/<alias>/<field>` connection-metadata meta-keys.
  ///
  /// Built once from the live (enabled-only) OPC-UA client wrappers and Modbus
  /// device-client adapters. `subscribedKeys` is derived here from the current
  /// [keyMappings] via a live closure, so key-mapping edits are reflected
  /// without rebuilding the router.
  late final ConnMetaRouter _connMeta = _buildConnMetaRouter();

  ConnMetaRouter _buildConnMetaRouter() {
    // Unnamed servers are first-class here, like everywhere else in
    // StateMan: a server with no alias gets a stable synthetic identity
    // derived from its connection target (host:port), so its meta-keys
    // exist and survive restarts. Duplicate identities get a #2/#3 suffix.
    final taken = <String>{};
    String claim(String candidate) {
      var alias = candidate;
      var n = 2;
      while (!taken.add(alias)) {
        alias = '$candidate#${n++}';
      }
      return alias;
    }

    final sources = <ConnMetaSource>[];
    for (final wrapper in clients) {
      final wAlias = wrapper.config.serverAlias;
      final ep = parseOpcEndpoint(wrapper.config.endpoint);
      final alias = claim(
          StateManConfig.normalizeAlias(wAlias) ?? '${ep.host}:${ep.port}');
      sources.add(OpcUaConnMetaSource(
        wrapper,
        metaAlias: alias,
        subscribedKeysFn: () => keyMappings.nodes.values
            .where((e) => e.opcuaNode?.serverAlias == wAlias)
            .length,
      ));
    }
    for (final dc in deviceClients) {
      if (dc is! ModbusDeviceClientAdapter) continue;
      final cfg = config.modbus
          .firstWhereOrNull((c) => c.serverAlias == dc.serverAlias);
      final minInterval = cfg == null || cfg.pollGroups.isEmpty
          ? null
          : cfg.pollGroups
              .map((g) => g.intervalMs)
              .reduce((a, b) => a < b ? a : b);
      final alias = claim(StateManConfig.normalizeAlias(dc.serverAlias) ??
          '${dc.wrapper.host}:${dc.wrapper.port}');
      sources.add(ModbusConnMetaSource(dc,
          metaAlias: alias, pollIntervalMs: minInterval));
    }
    return ConnMetaRouter(sources);
  }

  bool _isAliasDisabled(String? alias) =>
      _disabledAliases.contains(StateManConfig.normalizeAlias(alias));

  /// Whether [key] is routed to a server the operator switched off.
  bool isKeyDisabled(String key) =>
      _isAliasDisabled(keyMappings.lookupServerAlias(resolveKey(key)));

  /// Throws [ServerDisabledException] if [key] belongs to a disabled server.
  ///
  /// Deliberately silent — the whole point of disabling a server is that its
  /// keys stop talking, including to the log.
  void _throwIfDisabled(String key) {
    final alias = keyMappings.lookupServerAlias(key);
    if (!_isAliasDisabled(alias)) return;
    throw ServerDisabledException(key, alias);
  }

  ClientWrapper _getClientWrapper(String key) {
    final alias = keyMappings.lookupServerAlias(key);
    final wrapper = clients
        .firstWhereOrNull((wrapper) => wrapper.config.serverAlias == alias);
    if (wrapper == null) {
      throw StateManException(
          'No OPC-UA client found for key "$key" (server alias: $alias)');
    }
    return wrapper;
  }

  void setSubstitution(String key, String value) {
    if (_substitutions[key] == value) return;
    _substitutions[key] = value;
    logger.d('Substitution set: $key = $value');
    _subsMap$.add(Map.unmodifiable(_substitutions));
  }

  Stream<Map<String, String>> get substitutionsChanged => _subsMap$.stream;

  /// Returns an unmodifiable view of the current variable substitutions.
  Map<String, String> get substitutions => Map.unmodifiable(_substitutions);

  String? getSubstitution(String key) {
    return _substitutions[key];
  }

  /// Refuses a key that still names a variable nothing has published.
  ///
  /// [resolveKey] returns the key unchanged when it cannot substitute, so
  /// without this the caller subscribes to a node that cannot exist and gets
  /// `null` -- the same thing it would get from a dead tag, a renamed node or
  /// a mapping with no server alias. Four faults with one symptom is how a
  /// templated key stays broken without anyone being able to say why.
  void _throwIfUnresolved(String key) {
    if (!key.contains('\$')) return;
    throw StateManException(unresolvedKeyMessage(key));
  }

  String resolveKey(String key) {
    if (!key.contains('\$')) return key;

    String resolvedKey = key;
    for (final entry in _substitutions.entries) {
      final variablePattern = '\$${entry.key}';
      if (resolvedKey.contains(variablePattern)) {
        resolvedKey = resolvedKey.replaceAll(variablePattern, entry.value);
      }
    }

    if (resolvedKey != key) {
      logger.d('Resolved key: $key -> $resolvedKey');
    }

    if (resolvedKey.contains('\$')) {
      // Callers refuse to act on this (see _throwIfUnresolved), so it is a
      // transient startup condition rather than an error in itself: the
      // readouts subscribe before the OptionVariable that owns the variable
      // has published it.
      logger.w('Key still has unresolved variables: $resolvedKey');
    }

    return resolvedKey;
  }

  /// Translate a user-facing key to M2400 subscribe info via key mappings.
  ///
  /// Returns resolved subscribe key, device client, optional status filter,
  /// and optional field name for post-filter extraction. Null if not M2400.
  ({
    String subscribeKey,
    DeviceClient dc,
    int? statusFilter,
    String? fieldName
  })? _resolveM2400Key(String key) {
    final entry = keyMappings.nodes[key];
    if (entry?.m2400Node == null) return null;
    final node = entry!.m2400Node!;

    String? recordKey;
    switch (node.recordType) {
      case M2400RecordType.recBatch:
        recordKey = 'BATCH';
        break;
      case M2400RecordType.recStat:
        recordKey = 'STAT';
        break;
      case M2400RecordType.recIntro:
        recordKey = 'INTRO';
        break;
      case M2400RecordType.recLua:
        recordKey = 'LUA';
        break;
      default:
        return null;
    }

    // When statusFilter is set, subscribe to the full record so we can
    // check the status field before extracting the target field.
    final hasFilter = node.statusFilter != null;
    final fieldName = node.field?.name;
    final subscribeKey =
        (!hasFilter && fieldName != null) ? '$recordKey.$fieldName' : recordKey;

    final alias = node.serverAlias;
    for (final dc in deviceClients) {
      if (dc is M2400DeviceClientAdapter && dc.serverAlias == alias) {
        return (
          subscribeKey: subscribeKey,
          dc: dc,
          statusFilter: node.statusFilter,
          fieldName: hasFilter ? fieldName : null,
        );
      }
    }
    return null;
  }

  /// Find the Modbus [DeviceClient] that owns [key], or null if not a Modbus key.
  DeviceClient? _resolveModbusDeviceClient(String key) {
    final entry = keyMappings.nodes[key];
    if (entry?.modbusNode == null) return null;
    final alias = entry!.modbusNode!.serverAlias;
    for (final dc in deviceClients) {
      if (dc is ModbusDeviceClientAdapter && dc.serverAlias == alias) {
        if (dc.canSubscribe(key)) return dc;
      }
    }
    return null;
  }

  /// Example: read("myKey")
  Future<DynamicValue> read(String key) async {
    // Connection-metadata meta-keys short-circuit before resolveKey /
    // disabled / routing — they are not in keyMappings.
    if (ConnMetaRouter.isMetaKey(key)) return _connMeta.read(key);

    key = resolveKey(key);
    _throwIfUnresolved(key);
    _throwIfDisabled(key);

    // Check M2400 key mappings first
    final m2400 = _resolveM2400Key(key);
    if (m2400 != null) {
      var value = m2400.dc.read(m2400.subscribeKey);
      if (value == null) {
        throw StateManException(
            'No cached value for key: "$key" — not found yet');
      }
      if (m2400.statusFilter != null) {
        if (value['status'].asInt != m2400.statusFilter) {
          throw StateManException(
              'No cached value for key: "$key" — status not found yet');
        }
      }
      if (m2400.fieldName != null) {
        value = value[m2400.fieldName!];
      }
      return value;
    }

    // Check Modbus key
    final modbusDc = _resolveModbusDeviceClient(key);
    if (modbusDc != null) {
      // B-1 (v1.1.x): UMAS-by-name routing. When the entry has a
      // variableName set, read live via the UmasClient symbol cache
      // rather than the Modbus address space. The adapter throws a
      // UmasException with the operator-facing "umas not enabled"
      // message when the server has umasEnabled=false; let it
      // propagate as StateManException so the key card surfaces an
      // Error badge.
      final entry = keyMappings.nodes[key];
      final variableName = entry?.variableName;
      if (variableName != null && modbusDc is ModbusDeviceClientAdapter) {
        try {
          return await modbusDc.readUmasVariable(key);
        } catch (e) {
          throw StateManException(
              'Failed to read UMAS variable "$variableName" '
              'for key "$key": $e');
        }
      }
      final value = modbusDc.read(key);
      if (value == null) {
        throw StateManException(
            'No cached value for key: "$key" -- not polled yet');
      }
      return value;
    }

    // Fall through to OPC UA
    try {
      final client = _getClientWrapper(key).client;
      final nodeId = _lookupNodeId(key);
      if (nodeId == null) {
        throw StateManException("Key: \"$key\" not found");
      }
      final (id, idx) = nodeId;
      await client.awaitConnect();
      var value = await client.read(id);
      if (idx != null) {
        value = value[idx];
      }
      // Apply bit mask if configured on this key
      final entry = keyMappings.nodes[key];
      return applyBitMask(value, entry?.bitMask, entry?.bitShift);
    } catch (e) {
      throw StateManException('Failed to read key: \"$key\": $e');
    }
  }

  Future<Map<String, DynamicValue>> readMany(List<String> keys) async {
    final results = <String, DynamicValue>{};

    // Separate DeviceClient keys from OPC UA keys
    final opcuaKeys = <String>[];
    for (final keyToResolve in keys) {
      // Connection-metadata meta-keys resolve to a current snapshot.
      if (ConnMetaRouter.isMetaKey(keyToResolve)) {
        results[keyToResolve] = _connMeta.read(keyToResolve);
        continue;
      }

      final key = resolveKey(keyToResolve);

      // A key still naming an unpublished variable is absent from the result
      // rather than fatal to the batch -- same treatment as a disabled
      // server. Throwing here would fail every other key in the request.
      if (key.contains('\$')) continue;

      // Keys on a disabled server are simply absent from the result, the
      // same as a key whose value has not been polled yet.
      if (_isAliasDisabled(keyMappings.lookupServerAlias(key))) continue;

      // Check Modbus
      final modbusDc = _resolveModbusDeviceClient(key);
      if (modbusDc != null) {
        // B-1 (v1.1.x): UMAS-by-name keys read live via the symbol
        // cache. Errors here only skip the failing key (analogous to
        // the existing "no cached value -> skip" semantics of
        // [DeviceClient.read]); the caller surfaces missing keys.
        final entry = keyMappings.nodes[key];
        if (entry?.variableName != null &&
            modbusDc is ModbusDeviceClientAdapter) {
          try {
            results[key] = await modbusDc.readUmasVariable(key);
          } catch (_) {
            // Skip; UI surfaces error badge via single-key read().
          }
          continue;
        }
        final value = modbusDc.read(key);
        if (value != null) results[key] = value;
        continue;
      }

      // Check M2400
      final m2400 = _resolveM2400Key(key);
      if (m2400 != null) {
        final value = m2400.dc.read(m2400.subscribeKey);
        if (value != null) {
          var result = value;
          if (m2400.fieldName != null) result = result[m2400.fieldName!];
          results[key] = result;
        }
        continue;
      }

      opcuaKeys.add(key);
    }

    // Process remaining OPC UA keys
    final parameters = <ClientApi, Map<NodeId, List<AttributeId>>>{};

    for (final key in opcuaKeys) {
      final ClientApi client;
      try {
        client = _getClientWrapper(key).client;
      } catch (e) {
        throw StateManException('No client for key: "$key": $e');
      }
      final nodeId = _lookupNodeId(key);
      if (nodeId == null) {
        throw StateManException("Key: \"$key\" not found");
      }
      final (id, idx) = nodeId;
      // Accumulate: assigning a fresh map here dropped every node but the
      // last one for each client, so readMany returned a single value.
      (parameters[client] ??= {})[id] = [
        AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
        AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        AttributeId.UA_ATTRIBUTEID_DATATYPE,
        AttributeId.UA_ATTRIBUTEID_VALUE,
      ];
    }

    for (final pair in parameters.entries) {
      final client = pair.key;
      final parameters = pair.value;
      await client.awaitConnect();
      final res = await client.readAttribute(parameters);
      results.addAll(res.map((nodeId, value) {
        final key = keyMappings.lookupKey(nodeId);
        if (key == null) {
          throw StateManException("Key: \"$key\" not found");
        }
        // todo refactor this to not be so ugly
        final foo = _lookupNodeId(key);
        if (foo == null) {
          throw StateManException("Weird error:Key: \"$key\" not found");
        }
        final (_, idx) = foo;
        if (idx != null) {
          return MapEntry(key, value[idx]);
        }
        return MapEntry(key, value);
      }));
    }
    return results;
  }

  /// Example: write("myKey", DynamicValue(value: 42, typeId: NodeId.int16))
  Future<void> write(String key, DynamicValue value) async {
    // Connection metadata is read-only; never silently no-op.
    if (ConnMetaRouter.isMetaKey(key)) {
      throw StateManException("connection metadata key '$key' is read-only");
    }

    key = resolveKey(key);
    _throwIfUnresolved(key);
    _throwIfDisabled(key);

    // Check Modbus (and other DeviceClient protocols)
    final modbusDc = _resolveModbusDeviceClient(key);
    if (modbusDc != null) {
      // F-3: wrap UMAS-by-name write errors symmetrically with the
      // read path (state_man.dart:1267-1273) so operator-facing
      // surfaces (key-card Error chip) get a StateManException whose
      // message names both the key and the symbol path.
      final entry = keyMappings.nodes[key];
      final variableName = entry?.variableName;
      if (variableName != null && modbusDc is ModbusDeviceClientAdapter) {
        try {
          await modbusDc.write(key, value);
        } catch (e) {
          throw StateManException(
              'Failed to write UMAS variable "$variableName" '
              'for key "$key": $e');
        }
        return;
      }
      await modbusDc.write(key, value);
      return;
    }

    try {
      final client = _getClientWrapper(key).client;
      final nodeId = _lookupNodeId(key);
      if (nodeId == null) {
        throw StateManException("Key: \"$key\" not found");
      }
      final (id, idx) = nodeId;
      await client.awaitConnect();
      if (idx != null) {
        // a bit special, we need to read to be able to write
        // not sure I like this
        final readValue = await client.read(id);
        readValue[idx] = value;
        await client.write(id, readValue);
        return;
      }
      await client.write(id, value);
    } catch (e) {
      throw StateManException('Failed to write node: \"$key\": $e');
    }
  }

  /// Subscribe to data changes on a specific node with type safety.
  /// Returns a Stream that can be cancelled to stop the subscription.
  ///
  /// Routes to [DeviceClient] instances first (e.g., M2400), falling through
  /// to OPC UA [_monitor] if no device client claims the key.
  ///
  /// Example: subscribe("myIntKey") or subscribe("BATCH.weight")
  Future<Stream<DynamicValue>> subscribe(String key) async {
    // Connection-metadata meta-keys return a live snapshot stream that emits
    // on connection-state changes and on a 1s periodic tick.
    if (ConnMetaRouter.isMetaKey(key)) return _connMeta.subscribe(key);

    key = resolveKey(key);
    _throwIfUnresolved(key);
    _throwIfDisabled(key);

    // Check M2400 key mappings first
    final m2400 = _resolveM2400Key(key);
    if (m2400 != null) {
      Stream<DynamicValue> stream = m2400.dc.subscribe(m2400.subscribeKey);
      if (m2400.statusFilter != null) {
        stream = stream.where((dv) => dv['status'].asInt == m2400.statusFilter);
      }
      if (m2400.fieldName != null) {
        stream = stream.map((dv) => dv[m2400.fieldName!]);
      }
      return stream;
    }

    // Check Modbus key
    final modbusDc = _resolveModbusDeviceClient(key);
    if (modbusDc != null) {
      return modbusDc.subscribe(key);
    }

    // Fall through to OPC UA
    return _monitor(key);
  }

  KeyMappingsUpdateResult updateKeyMappings(KeyMappings newKeyMappings) {
    final old = keyMappings;
    final added = <String>{};
    final removed = <String>{};
    final changed = <String>{};
    for (final key in newKeyMappings.nodes.keys) {
      if (!old.nodes.containsKey(key)) added.add(key);
    }
    for (final entry in old.nodes.entries) {
      final newEntry = newKeyMappings.nodes[entry.key];
      if (newEntry == null) {
        removed.add(entry.key);
      } else if (jsonEncode(newEntry.toJson()) !=
          jsonEncode(entry.value.toJson())) {
        changed.add(entry.key);
      }
    }

    // Routing (read/write/subscribe, M2400 extraction, Modbus alias lookup,
    // disabled-server checks) all consult [keyMappings] at call time, so the
    // swap alone makes added keys and edited routes live for every FUTURE
    // subscribe. The per-key work below re-points streams that already exist.
    keyMappings = newKeyMappings;

    // TD-003 (v1.1.x): propagate the new variableName mapping to every
    // Modbus adapter so per-key UMAS state (BehaviorSubject + cached
    // last value + MonitorPlc table) is released for keys that were
    // removed or renamed. Without this hook, deleting a UMAS-by-name
    // key from the operator's mappings would leak the subject + cached
    // DynamicValue for the lifetime of the StateMan.
    for (final dc in deviceClients) {
      if (dc is ModbusDeviceClientAdapter) {
        final newNames =
            buildVariableNamesFromKeyMappings(newKeyMappings, dc.serverAlias);
        // Preserve the null entries for non-UMAS keys the adapter knows
        // about so the merged map's "renamed" detection works (it
        // compares old non-null name vs new entry — missing entry =
        // removed, so we don't need to inject null placeholders).
        dc.updateVariableNames(
          Map<String, String?>.from(newNames),
          umasPollGroupByKey:
              buildUmasPollGroupsFromKeyMappings(newKeyMappings, dc.serverAlias),
        );
      }
    }

    // Removed keys with a live OPC UA monitor: tear down the monitored item
    // and complete the stream, so widgets see a clean onDone (mirrors the
    // UMAS removeUmasKey semantics) instead of silently streaming forever.
    for (final key in removed) {
      final ads = _subscriptions.remove(key);
      if (ads == null) continue;
      logger.i('[$alias] key mapping removed, closing live stream: $key');
      ads.idleTimer?.cancel();
      ads.rawSub?.cancel();
      ads.rawSub = null;
      if (!ads.subject.isClosed) ads.subject.close();
      _unregisterStream(ads);
    }

    // Changed keys with a live OPC UA monitor: re-point the monitored item
    // in place. The AutoDisposingStream subject survives, so widgets keep
    // their stream and just start receiving values from the new node.
    final resubscribed = <String>{};
    for (final key in changed) {
      final ads = _subscriptions[key];
      if (ads == null) continue;
      ads.rawSub?.cancel();
      ads.rawSub = null;
      if (newKeyMappings.nodes[key]?.opcuaNode == null) {
        // The key switched protocols; the old OPC UA stream cannot carry
        // the new routing, so complete it like a removal. Fresh subscribes
        // route through the new protocol.
        _subscriptions.remove(key);
        ads.idleTimer?.cancel();
        if (!ads.subject.isClosed) ads.subject.close();
        _unregisterStream(ads);
        continue;
      }
      logger.i('[$alias] key mapping changed, resubscribing live: $key');
      resubscribed.add(key);
      _monitor(key, resub: true).catchError((e, s) {
        logger.e('[$alias] Failed to resubscribe changed key "$key": $e\n$s');
        return Stream<DynamicValue>.error(
            e is Object ? e : StateManException('resubscribe failed'));
      });
    }

    // What could NOT be applied in place. Classic-Modbus register specs are
    // frozen into the adapter at construction, and M2400 field extraction is
    // captured per widget stream at subscribe time — edits there still need
    // the caller to rebuild the StateMan. Everything else went live above.
    bool isClassicModbus(KeyMappingEntry? e) =>
        e?.modbusNode != null &&
        (e?.variableName == null || e!.variableName!.isEmpty);
    bool bitsChanged(KeyMappingEntry? a, KeyMappingEntry? b) =>
        a?.bitMask != b?.bitMask || a?.bitShift != b?.bitShift;
    String? modbusJson(KeyMappingEntry? e) =>
        e?.modbusNode == null ? null : jsonEncode(e!.modbusNode!.toJson());
    String? m2400Json(KeyMappingEntry? e) =>
        e?.m2400Node == null ? null : jsonEncode(e!.m2400Node!.toJson());

    final reloadReasons = <String>[];
    for (final key in added) {
      if (isClassicModbus(newKeyMappings.nodes[key])) {
        reloadReasons.add('added Modbus register key "$key"');
      }
    }
    for (final key in changed) {
      final oldE = old.nodes[key];
      final newE = newKeyMappings.nodes[key];
      final modbusDelta = modbusJson(oldE) != modbusJson(newE) ||
          oldE?.variableName != newE?.variableName ||
          ((oldE?.modbusNode != null || newE?.modbusNode != null) &&
              bitsChanged(oldE, newE));
      if (modbusDelta) {
        reloadReasons.add('changed Modbus key "$key"');
      } else if (m2400Json(oldE) != m2400Json(newE)) {
        reloadReasons.add('changed M2400 key "$key"');
      }
    }
    for (final key in removed) {
      final oldE = old.nodes[key];
      if (isClassicModbus(oldE)) {
        reloadReasons.add('removed Modbus register key "$key"');
      } else if (oldE?.m2400Node != null) {
        reloadReasons.add('removed M2400 key "$key"');
      }
    }

    return KeyMappingsUpdateResult(
      added: added,
      removed: removed,
      changed: changed,
      resubscribed: resubscribed,
      reloadReasons: reloadReasons,
    );
  }

  List<String> get keys => [...keyMappings.keys, ..._connMeta.metaKeys];

  /// The connection aliases the `@conn` meta-key router answers for, with
  /// their protocol (unnamed servers appear under their synthetic host:port
  /// identity). This is what editor UIs should offer as suggestions.
  List<({String alias, bool isModbus})> get connMetaAliases =>
      _connMeta.aliases;

  /// All `@conn` fields for [alias] as one stream — a single timer and one
  /// snapshot per tick, unlike per-field [subscribe] calls. Throws
  /// [StateManException] for an unknown alias.
  Stream<Map<String, DynamicValue>> subscribeConnMeta(String alias) =>
      _connMeta.subscribeAll(alias);

  /// Close the connection to the server.
  Future<void> close() async {
    _shouldRun = false;
    logger.d('Closing connection');

    // Dispose device clients (M2400, etc.)
    for (final dc in deviceClients) {
      dc.dispose();
    }

    for (final wrapper in clients) {
      try {
        if (wrapper.client is ClientIsolate) {
          await (wrapper.client as ClientIsolate).disconnect();
        } else {
          (wrapper.client as Client).disconnect();
        }
      } catch (_) {}
      await wrapper.client.delete();
      wrapper.dispose();
    }
    // Clean up subscriptions
    for (final entry in _subscriptions.values) {
      entry.rawSub?.cancel();
      entry.subject.close();
    }
    _subscriptions.clear();

    _subsMap$.close();
  }

  (NodeId, int?)? _lookupNodeId(String key) {
    return keyMappings.lookupNodeId(key);
  }

  /// Drop [ads] from every wrapper's resend set.
  ///
  /// [ClientWrapper.streams] is what [ClientWrapper._handleRecovery] walks
  /// after an inactivity blip. An entry left behind once its subject is closed
  /// is retained for the lifetime of the process, and every path that retires a
  /// subscription must come through here -- there are three (idle timeout, raw
  /// stream done, and key-mapping edits), and only the first two went through
  /// the dispose callback.
  void _unregisterStream(AutoDisposingStream ads) {
    for (final w in clients) {
      w.streams.remove(ads);
    }
  }

  @visibleForTesting
  void addSubscription({
    required String key,
    required Stream<DynamicValue> subscription,
    required DynamicValue? firstValue,
  }) {
    _subscriptions[key] = AutoDisposingStream(key, (key) {
      _subscriptions.remove(key);
      logger.d('Unsubscribed from $key');
    });
    _subscriptions[key]!.subscribe(subscription, firstValue);
  }

  Future<Stream<DynamicValue>> _monitor(String key,
      {bool resub = false}) async {
    final existing = _subscriptions[key];
    if (existing != null && !resub) {
      // Belt and braces with the _onDispose in AutoDisposingStream.onDone: a
      // spent entry can never deliver again, so reusing it silently costs the
      // caller its data. Drop it and monitor afresh.
      if (!existing.isSpent) return existing.stream;
      logger.w('[$key] cached subscription is spent — re-monitoring');
      _subscriptions.remove(key);
    }

    // Guard the retry loop below: without a client wrapper it would spin
    // once a second forever, which is exactly the log flood a disabled
    // server is supposed to prevent.
    _throwIfDisabled(key);

    logger.d(
        '[$alias] _monitor($key, resub=$resub) hasExisting=${_subscriptions.containsKey(key)}');

    // Register entry synchronously before any await so concurrent
    // callers for the same key hit the early return above.
    if (!_subscriptions.containsKey(key)) {
      late final AutoDisposingStream<DynamicValue> ads;
      ads = AutoDisposingStream<DynamicValue>(key, (key) {
        _subscriptions.remove(key);
        // Remove from wrapper's stream set on disposal. Captured, not looked
        // up: reading _subscriptions[key] here is always null -- the line
        // above just removed it -- so this used to remove nothing at all.
        _unregisterStream(ads);
        logger.d('Unsubscribed from $key');
      });
      _subscriptions[key] = ads;
      try {
        _getClientWrapper(key).streams.add(ads);
      } catch (_) {
        // No wrapper for this key (e.g. addSubscription path)
      }
    }

    final ads = _subscriptions[key]!;

    // Can this key be pointed at a node *right now*?
    //
    // Resolution used to happen here, once: a key with no client wrapper (or
    // no mapping at all) got a `Stream.error` handed back and the entry
    // registered above was left in `_subscriptions` — an entry that can never
    // deliver, and that every later subscribe for this key was then given.
    //
    // That is what made an accepted key mapping read null until the app was
    // restarted (2026-08-22). A page widget or an alarm binds the key while it
    // is still only an AI proposal; the operator accepts; the save reaches
    // StateMan and the routing is correct from that moment on — but the caller
    // was already holding a dead stream and nothing ever resolved the key
    // again. The log blamed a null server alias, which is only what
    // [KeyMappings.lookupServerAlias] returns for a key that has no entry at
    // all; the alias itself was never dropped.
    //
    // So an unroutable key is now transient, like every other failure in the
    // loop below: the caller gets its live stream and the loop keeps
    // re-resolving on the 1s/10s/60s/600s ladder until the mapping shows up.
    // Deliberately not awaited — a caller must not block for a mapping that
    // may be minutes away, and handing back the stream is what lets it start
    // flowing the moment [updateKeyMappings] swaps the mapping in.
    if (!_isRoutable(key)) {
      logger.w('[$alias] $key cannot be routed yet (server alias: '
          '${keyMappings.lookupServerAlias(key)}) — holding its stream open '
          'and retrying until a mapping for it arrives');
      unawaited(_monitorLoop(key).then<void>((_) {}, onError: (Object e) {
        // The loop only ends when StateMan closes; nothing is waiting on it.
        logger.d('[$alias] monitor loop for "$key" ended: $e');
      }));
      return ads.stream;
    }
    return _monitorLoop(key);
  }

  /// Whether [key] can be pointed at an OPC UA node right now.
  ///
  /// Both halves are read out of [keyMappings], which [updateKeyMappings]
  /// replaces wholesale, so the answer changes the instant a mapping is saved.
  bool _isRoutable(String key) {
    if (_lookupNodeId(key) == null) return false;
    try {
      _getClientWrapper(key);
      return true;
    } on StateManException {
      return false;
    }
  }

  /// Subscribes [key] on its server and keeps trying until it succeeds, or
  /// until StateMan closes. Assumes `_subscriptions[key]` is already
  /// registered by [_monitor].
  Future<Stream<DynamicValue>> _monitorLoop(String key) async {
    // Claim the key: any loop started earlier for it is superseded from this
    // point on and must not touch the raw subscription again.
    final gen = (_monitorLoopGeneration[key] ?? 0) + 1;
    _monitorLoopGeneration[key] = gen;
    // A superseded loop hands its caller the shared stream (the newer loop
    // feeds it) and dies without side effects.
    Stream<DynamicValue> handOver() {
      logger.d('[$alias] monitor loop for "$key" superseded — handing over');
      final ads = _subscriptions[key];
      if (ads != null && !ads.isSpent) return ads.stream;
      throw StateManException(
          'monitor loop for "$key" superseded and its entry is gone');
    }

    int retries = 0;
    // Attempt counter and start time, so a stuck key reports how long it has
    // been stuck rather than just that it failed again.
    var attempt = 0;
    final startedAt = DateTime.now();
    // First few attempts, then every tenth: enough to see a key spinning
    // without a line per second per key forever.
    bool shouldLog() => attempt <= 3 || attempt % 10 == 0;
    while (_shouldRun) {
      // Checkpoint 1 (protects the teardown below — no awaits in between): a
      // stale loop waking from its backoff ladder must die here, not cancel
      // whatever raw subscription the current loop wired up.
      if (_monitorLoopGeneration[key] != gen) return handOver();
      attempt++;
      try {
        // Resolved per attempt rather than captured once before the loop: a
        // key becomes routable when its mapping is saved, and the client it
        // routes to can be replaced under it.
        final wrapper = _getClientWrapper(key);
        final client = wrapper.client;
        final lookup = _lookupNodeId(key);
        if (lookup == null) {
          throw StateManException('Key: "$key" not found');
        }
        final (id, idx) = lookup;
        // Recovery resends the last value to every stream the wrapper knows
        // about. A key that only became routable now was not on that list
        // when its entry was registered, so put it there.
        final registered = _subscriptions[key];
        if (registered != null) wrapper.streams.add(registered);
        // The per-server alias, not StateMan's own `alias` -- the latter is
        // usually empty, which made every one of these lines start with "[]"
        // and gave no clue which PLC was involved.
        final srv = wrapper.config.serverAlias ?? wrapper.config.endpoint;
        // Cancel any leftover subscription from a previous failed attempt
        // so we don't leak monitored items while retrying.
        //
        // NOTE: deliberately still not awaited -- this is instrumentation,
        // not a fix. We only attach observers so the log can say whether the
        // server ever acknowledges the delete before we create its
        // replacement. If deleteAcked stops tracking deleteRequested, the
        // items are accumulating on the PLC.
        _subscriptions[key]?.rawSub?.cancel();
        _subscriptions[key]?.rawSub = null;

        await client.awaitConnect();

        final needsSubscription = wrapper.subscriptionId == null;
        final gotWorker = needsSubscription && await wrapper.worker.doTheWork();
        if (needsSubscription && !gotWorker && shouldLog()) {
          // Another call owns subscription creation. If that one never
          // finishes, every key on this server waits here.
          logger.w('[$srv] $key: subscription being created elsewhere '
              '(worker busy), attempt=$attempt');
        }

        if (needsSubscription && gotWorker) {
          try {
            // keepAliveCount=30 → inactivity after (interval×30)+5s, ≈8s at
            // the default 100 ms interval. Tolerates intermittent packet loss
            // on unstable connections.
            // Bounded: a server that accepts the channel and then never
            // answers CreateSubscription would otherwise hold the worker
            // forever, and with it every key routed to this server -- not on
            // the retry ladder, on a bare await. The timeout drops through to
            // the catch, the `finally` releases the worker, and the normal
            // ladder takes over.
            wrapper.subscriptionId = await client
                .subscriptionCreate(
                  requestedPublishingInterval: wrapper.config.publishingInterval,
                  requestedMaxKeepAliveCount: 30,
                )
                .timeout(const Duration(seconds: 10));
            logger.i(
                '[$alias ${wrapper.config.endpoint}] Created subscription ${wrapper.subscriptionId}');
            wrapper.startHeartbeat(wrapper.subscriptionId!);
          } catch (e, st) {
            logger.e('[$srv ${wrapper.config.endpoint}] Failed to create '
                'subscription (attempt=$attempt): $e');
            logger.e('[$srv] subscriptionCreate stack: $st');
          } finally {
            wrapper.worker.complete();
          }
        }
        if (wrapper.subscriptionId == null) {
          // This was a silent `continue` on a tight loop: the one path that
          // starves an entire server logged nothing at all, so a PLC that
          // could not give us a subscription span here invisibly, at full
          // speed, blocking every key queued behind it.
          if (shouldLog()) {
            final stuckFor = DateTime.now().difference(startedAt).inSeconds;
            logger.e('[$srv ${wrapper.config.endpoint}] $key: still no '
                'subscription id after $attempt attempt(s) over ${stuckFor}s. '
                'Every key on this server is blocked behind this one.');
          }
          // Same ladder as the first-value path below. A station that refuses
          // to hand out a subscription fails here instead, and this is
          // per-key: on a flat interval ~140 keys retry once a second each,
          // which is the storm all over again by another route.
          retries++;
          await Future<void>.delayed(_backoffFor(retries));
          continue;
        }

        // Checkpoint 2 (protects the subscribe below — no awaits in between):
        // the waits above (awaitConnect, worker, subscriptionCreate) are
        // exactly where a newer loop can start and wire up its own raw
        // subscription; ads.subscribe() would cancel it — the steal that
        // deletes live monitored items on the PLC.
        if (_monitorLoopGeneration[key] != gen) return handOver();
        final ads = _subscriptions[key]!;
        final hadPrevious = ads.rawSub != null;

        // Trace, not debug: this fired 13,013 times in one run. The default
        // level used to be trace when CENTROID_LOG_LEVEL was unset, so this
        // line was formatted and printed 13,013 times on every page load and
        // every reconnect -- ~300ms of PrettyPrinter plus ~250ms of stdout.
        // The default is now info (see log_config.dart), so it costs the
        // string interpolation and a rejected filter call unless somebody
        // asks for trace.
        logger.t(
            '[$srv] Creating monitored items for $key on sub=${wrapper.subscriptionId}');

        // One monitor() call == 4 monitored items on the server.
        wrapper.monitoredItemsCreated += 4;
        // Report the gauge often enough to see it climb, rarely enough not to
        // become the noise it is meant to expose.
        if (wrapper.monitoredItemsCreated % 40 == 0) {
          logger.w('[$srv] monitored items: ${wrapper.monitoredItemReport}');
        }

        // Sampled at the same rate the subscription publishes: sampling
        // faster than we publish only fills a queue of size 1 that then
        // discards everything but the last value.
        var stream = client.monitor(id, wrapper.subscriptionId!,
            samplingInterval: wrapper.config.publishingInterval);
        // Count each monitored-item emission toward this server's
        // requests-per-second load figure (see [ClientWrapper.requestsPerSec]).
        stream = stream.map((value) {
          wrapper.recordRequest();
          return value;
        });
        if (idx != null) {
          stream = stream.map((value) => value[idx]);
        }
        // Apply bit mask if configured on this key
        final entry = keyMappings.nodes[key];
        if (entry?.bitMask != null) {
          stream = stream.map(
              (value) => applyBitMask(value, entry!.bitMask, entry.bitShift));
        }

        // Wait for monitor to deliver first value. No asBroadcastStream()
        // needed — subscribe() holds _rawSub, and cancel propagates
        // properly to delete monitored items on retry.
        // Cleared per attempt: otherwise a timeout reports the previous
        // attempt's error as the reason this one failed.
        _subscriptions[key]?.lastRawError = null;
        final firstEmission = Completer<void>();
        final wrappedStream = stream.map((value) {
          if (!firstEmission.isCompleted) firstEmission.complete();
          return value;
        });
        ads.subscribe(wrappedStream, null);
        // Record the last error the raw stream reported, so a first-value
        // timeout can say whether the server actively refused (e.g.
        // BadDeviceFailure) or simply stayed silent. "Timed out" alone does
        // not distinguish those, and they have different causes.
        await firstEmission.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () {
            // Two very different things end up here, because `firstEmission`
            // only completes on a *value*: a server that stayed silent, and
            // one that answered with an error. They need opposite responses.
            final last = _subscriptions[key]?.lastRawError;
            if (last != null) {
              // The server gave a hard answer (BadNodeIdUnknown,
              // BadDeviceFailure, ...). That is a subscription which will not
              // start working on its own, so it is worth tearing down and
              // rebuilding -- on the backoff ladder, which walks a key that
              // keeps failing out to one attempt per 10 minutes.
              throw TimeoutException(
                  'no first value for "$key" within 8s '
                  '(raw stream error: $last)');
            }
            // Silence is NOT a dead subscription. Do not throw/re-subscribe:
            // re-subscribing cancels + recreates the monitored items, and
            // doing that across hundreds of keys under the startup flood
            // churns the worker/server and STARVES the heavily-loaded servers
            // (lines 1/3) so their initial values never settle. Keep the
            // existing subscription -- the value arrives on the stream once
            // the flood clears, and the key comes online then.
            logger.w('[$srv] $key: no first value within 8s '
                '(server silent, no stream error); '
                'keeping subscription, awaiting value');
          },
        );
        logger.i('[$srv] Subscribed $key (replaced previous: $hadPrevious)');

        return ads.stream;
      } catch (e) {
        retries++;
        // BadNodeIdUnknown is the server's final answer for as long as its
        // address space stays the way it is, but the address space can change
        // (a task starts, a symbol file reloads), so this backs off rather
        // than gives up -- it just does so all the way to the 600s step.
        final backoff = _backoffFor(retries);
        // Log the first few attempts and then only occasionally: a storm must
        // not be able to amplify itself through the log sink, which flushes
        // per event.
        if (retries <= kSubscribeBackoffSeconds.length || retries % 10 == 0) {
          logger.w('Failed to get initial value for $key '
              '(attempt $retries, next retry in ${backoff.inSeconds}s): $e');
        }
        await Future.delayed(backoff);
        continue;
      }
    }
    throw StateManException('StateMan closed while monitoring "$key"');
  }
}

/// Backoff ladder for a key whose subscribe keeps failing: 1s, then 10s, then
/// 60s, then 600s for as long as it keeps failing.
///
/// A flat retry interval is what froze the HMI. Each attempt costs an 8s
/// first-value timeout, four fresh monitored items on the server, a
/// fire-and-forget delete and several log lines -- and nothing ever gave up.
/// One run measured 13,013 subscribe attempts against 122 successes, with a
/// single dead key asked for 248 times; at ~11 attempts/second the isolate
/// never got a clear window and Flutter stopped painting frames.
///
/// The first step stays short so a genuine blip (a PLC that is mid-restart,
/// a channel that just dropped) still recovers in about a second. Past that
/// the interval grows fast, so a key that cannot succeed costs six attempts
/// an hour instead of six hundred -- visible in the log, invisible in the
/// frame budget. There is no give-up step: a node can come back when its PLC
/// task is started again, and 600s is cheap enough to keep asking forever.
const List<int> kSubscribeBackoffSeconds = <int>[1, 10, 60, 600];

/// The ladder step for the nth consecutive failure, clamped at the last rung.
Duration _backoffFor(int retries) => Duration(
    seconds: kSubscribeBackoffSeconds[
        retries <= kSubscribeBackoffSeconds.length
            ? retries - 1
            : kSubscribeBackoffSeconds.length - 1]);

/// The variable names still unresolved in [key], e.g. `{sb_line_stats_period}`
/// for `Line1.$sb_line_stats_period`.
///
/// A key is templated when an `OptionVariable` asset supplies part of it.
/// Until that asset has published its value, there is nothing to substitute
/// and the key names a node that cannot exist.
Set<String> unresolvedVariables(String key) => RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)')
    .allMatches(key)
    .map((m) => m.group(1)!)
    .toSet();

/// Message for a key that still names variables nothing has provided.
String unresolvedKeyMessage(String key) {
  final missing = unresolvedVariables(key).map((v) => '\$$v').join(', ');
  return 'key "$key" is waiting on $missing -- no value has been published '
      'for it yet. Templated keys resolve once the OptionVariable that owns '
      'the variable has loaded.';
}

