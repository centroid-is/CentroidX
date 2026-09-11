import 'dart:async';
import 'dart:collection';

import 'package:open62541/open62541_types.dart' show DynamicValue, NodeId;
import 'package:rxdart/rxdart.dart';

import 'state_man.dart' show ClientWrapper, ConnectionStatus, StateManException;
import 'modbus_device_client.dart' show ModbusDeviceClientAdapter;
import 'rolling_rate.dart';

export 'rolling_rate.dart';

/// Per-connection metadata exposed as synthetic, subscribable StateMan keys.
///
/// A meta-key has the shape `@conn/<serverAlias>/<field>`:
///   * The `@` prefix is deliberately NOT `$` — StateMan reserves `$` for
///     variable substitution in [StateMan.resolveKey]. `@conn` never passes
///     through substitution or the `keyMappings` routing table.
///   * `/` is the internal separator so aliases containing dots stay safe.
///
/// These keys let existing display assets (Number / Text / Sensor) bind to
/// live connection state, load, and network info without a dedicated widget.
///
/// Field values are emitted as [DynamicValue] with the scalar the bound
/// asset expects:
///   * String fields (state, lastError, destIp, endpoint, channelState,
///     sessionState) → Text asset.
///   * num fields (destPort, sourcePort, unitId, requestsPerSec, uptimeSec,
///     reconnectCount, subscribedKeys, statusCode, lastDataAgeSec,
///     pollIntervalMs) → Number asset.
///   * bool field (connected) → Sensor asset.

/// The `@conn` namespace prefix for connection-metadata keys.
const String kConnMetaPrefix = '@conn';

// -----------------------------------------------------------------------------
// Field-name catalogue
// -----------------------------------------------------------------------------

/// Fields available for every protocol.
const List<String> kConnMetaCommonFields = [
  'state',
  'connected',
  'destIp',
  'destPort',
  'requestsPerSec',
  'uptimeSec',
  'reconnectCount',
  'lastError',
];

/// Modbus-only fields, appended to [kConnMetaCommonFields].
const List<String> kConnMetaModbusOnlyFields = [
  'unitId',
  'sourcePort',
  'pollIntervalMs',
];

/// OPC-UA-only fields, appended to [kConnMetaCommonFields].
const List<String> kConnMetaOpcuaOnlyFields = [
  'endpoint',
  'channelState',
  'sessionState',
  'statusCode',
  'subscribedKeys',
  'lastDataAgeSec',
];

/// The complete valid field set for a Modbus connection.
final List<String> kConnMetaModbusFields = [
  ...kConnMetaCommonFields,
  ...kConnMetaModbusOnlyFields,
];

/// The complete valid field set for an OPC-UA connection.
final List<String> kConnMetaOpcuaFields = [
  ...kConnMetaCommonFields,
  ...kConnMetaOpcuaOnlyFields,
];

// -----------------------------------------------------------------------------
// Endpoint URL parser
// -----------------------------------------------------------------------------

/// Parse the host and port out of an OPC-UA endpoint URL.
///
/// Accepts the usual `opc.tcp://host:port/path` forms and tolerates a missing
/// port (defaults to 4840, the OPC-UA well-known port) and a missing path.
/// Works for hostnames and IPv4 literals. Returns a record `(host, port)`.
({String host, int port}) parseOpcEndpoint(String endpoint) {
  const defaultPort = 4840;
  final trimmed = endpoint.trim();
  try {
    final uri = Uri.parse(trimmed);
    if (uri.host.isNotEmpty) {
      return (host: uri.host, port: uri.hasPort ? uri.port : defaultPort);
    }
  } catch (_) {
    // Fall through to the manual parse below.
  }
  // Manual fallback: strip the scheme, isolate the authority, split host:port.
  var rest = trimmed;
  final schemeSep = rest.indexOf('://');
  if (schemeSep >= 0) {
    rest = rest.substring(schemeSep + 3);
  }
  // Authority ends at the first '/', '?' or '#'.
  final authorityEnd = rest.indexOf(RegExp(r'[/?#]'));
  final authority = authorityEnd >= 0 ? rest.substring(0, authorityEnd) : rest;
  final colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    final host = authority.substring(0, colon);
    final port = int.tryParse(authority.substring(colon + 1)) ?? defaultPort;
    return (host: host.isEmpty ? 'localhost' : host, port: port);
  }
  return (host: authority.isEmpty ? 'localhost' : authority, port: defaultPort);
}

// -----------------------------------------------------------------------------
// Rolling per-second rate sampler
// -----------------------------------------------------------------------------


// -----------------------------------------------------------------------------
// Snapshot + typing
// -----------------------------------------------------------------------------

/// An immutable point-in-time snapshot of one connection's metadata.
///
/// [toFieldMap] does the DynamicValue typing so the mapping from raw values to
/// asset-renderable scalars is testable without a live client.
class ConnMeta {
  // Common
  final String state;
  final bool connected;
  final String? destIp;
  final int? destPort;
  final double requestsPerSec;
  final double uptimeSec;
  final int reconnectCount;
  final String lastError;

  // Modbus-only
  final int? unitId;
  final int? sourcePort;
  final int? pollIntervalMs;

  // OPC-UA-only
  final String? endpoint;
  final String? channelState;
  final String? sessionState;
  final int? statusCode;
  final int? subscribedKeys;
  final double? lastDataAgeSec;

  /// Which technology this snapshot describes — decides the valid field set.
  final bool isModbus;

  const ConnMeta({
    required this.state,
    required this.connected,
    required this.isModbus,
    this.destIp,
    this.destPort,
    this.requestsPerSec = 0,
    this.uptimeSec = 0,
    this.reconnectCount = 0,
    this.lastError = '',
    this.unitId,
    this.sourcePort,
    this.pollIntervalMs,
    this.endpoint,
    this.channelState,
    this.sessionState,
    this.statusCode,
    this.subscribedKeys,
    this.lastDataAgeSec,
  });

  /// The valid field names for this snapshot's technology.
  List<String> get validFields =>
      isModbus ? kConnMetaModbusFields : kConnMetaOpcuaFields;

  static DynamicValue _str(String? v) =>
      DynamicValue(value: v, typeId: NodeId.uastring);
  static DynamicValue _int(int? v) =>
      DynamicValue(value: v, typeId: NodeId.int64);
  static DynamicValue _dbl(double? v) =>
      DynamicValue(value: v, typeId: NodeId.double);
  static DynamicValue _bool(bool v) =>
      DynamicValue(value: v, typeId: NodeId.boolean);

  /// Build the `field → DynamicValue` map for every valid field of this
  /// technology. Fields the technology does not expose are absent.
  Map<String, DynamicValue> toFieldMap() {
    final map = <String, DynamicValue>{
      'state': _str(state),
      'connected': _bool(connected),
      'destIp': _str(destIp),
      'destPort': _int(destPort),
      'requestsPerSec': _dbl(requestsPerSec),
      'uptimeSec': _dbl(uptimeSec),
      'reconnectCount': _int(reconnectCount),
      'lastError': _str(lastError),
    };
    if (isModbus) {
      map['unitId'] = _int(unitId);
      map['sourcePort'] = _int(sourcePort);
      map['pollIntervalMs'] = _int(pollIntervalMs);
    } else {
      map['endpoint'] = _str(endpoint);
      map['channelState'] = _str(channelState);
      map['sessionState'] = _str(sessionState);
      map['statusCode'] = _int(statusCode);
      map['subscribedKeys'] = _int(subscribedKeys);
      map['lastDataAgeSec'] = _dbl(lastDataAgeSec);
    }
    return map;
  }
}

// -----------------------------------------------------------------------------
// Sources
// -----------------------------------------------------------------------------

/// A source of connection metadata for a single server alias.
///
/// Concrete implementations wrap a live client ([OpcUaConnMetaSource],
/// [ModbusConnMetaSource]); tests can supply a fake to exercise
/// [ConnMetaRouter] in isolation.
abstract class ConnMetaSource {
  /// The server alias this source answers for.
  String get metaAlias;

  /// Whether this source is a Modbus connection (decides the field set
  /// without paying for a [snapshot] — key pickers call this per keystroke).
  bool get isModbus;

  /// A fresh snapshot read from the underlying live client getters.
  ConnMeta snapshot();

  /// Fires (as a `void` tick) whenever the connection state changes, so
  /// subscribers re-read the snapshot promptly rather than only on the 1s
  /// periodic tick.
  Stream<void> get changes;
}

/// Metadata source backed by an OPC-UA [ClientWrapper].
///
/// requestsPerSec here approximates protocol load: the native publish rate is
/// not exposed through the isolate binding, so it counts monitored-item value
/// emissions (and heartbeat ticks) routed through StateMan's OPC-UA
/// subscription wiring for this server, sampled per second by [RollingRate].
class OpcUaConnMetaSource implements ConnMetaSource {
  final ClientWrapper wrapper;

  /// Count of `keyMappings` entries whose OPC-UA server alias == this server.
  /// Derived in StateMan (not from the isolate binding) and passed as a live
  /// closure so it tracks key-mapping edits.
  final int Function() subscribedKeysFn;

  /// The alias this source answers for in `@conn/<alias>/<field>` keys.
  /// For unnamed servers the caller assigns a stable synthetic identity
  /// (host:port) — see `StateMan._buildConnMetaRouter`.
  @override
  final String metaAlias;

  OpcUaConnMetaSource(this.wrapper,
      {required this.subscribedKeysFn, String? metaAlias})
      : metaAlias = metaAlias ?? wrapper.config.serverAlias ?? '';

  @override
  bool get isModbus => false;

  @override
  Stream<void> get changes => wrapper.connectionStream.map((_) {});

  @override
  ConnMeta snapshot() {
    final ep = parseOpcEndpoint(wrapper.config.endpoint);
    final status = wrapper.connectionStatus;
    final age = wrapper.lastDataAgeSec;
    return ConnMeta(
      isModbus: false,
      state: status.name,
      connected: status == ConnectionStatus.connected,
      destIp: ep.host,
      destPort: ep.port,
      requestsPerSec: wrapper.requestsPerSec,
      uptimeSec: wrapper.uptimeSec,
      reconnectCount: wrapper.reconnectCount,
      lastError: wrapper.lastError,
      endpoint: wrapper.config.endpoint,
      channelState: wrapper.channelStateName,
      sessionState: wrapper.sessionStateName,
      statusCode: wrapper.recoveryStatus,
      subscribedKeys: subscribedKeysFn(),
      lastDataAgeSec: age,
    );
  }
}

/// Metadata source backed by a Modbus [ModbusDeviceClientAdapter].
class ModbusConnMetaSource implements ConnMetaSource {
  final ModbusDeviceClientAdapter adapter;

  /// Representative (minimum) poll-group interval in ms, from the server's
  /// configured poll groups. Null when the server declares none.
  final int? pollIntervalMs;

  /// See [OpcUaConnMetaSource.metaAlias].
  @override
  final String metaAlias;

  ModbusConnMetaSource(this.adapter, {this.pollIntervalMs, String? metaAlias})
      : metaAlias = metaAlias ?? adapter.serverAlias ?? '';

  @override
  bool get isModbus => true;

  @override
  Stream<void> get changes => adapter.wrapper.connectionStream.map((_) {});

  @override
  ConnMeta snapshot() {
    final w = adapter.wrapper;
    final status = w.connectionStatus;
    return ConnMeta(
      isModbus: true,
      state: status.name,
      connected: status == ConnectionStatus.connected,
      destIp: w.host,
      destPort: w.port,
      requestsPerSec: w.requestsPerSec,
      uptimeSec: w.uptimeSec,
      reconnectCount: w.reconnectCount,
      lastError: w.lastError,
      unitId: w.unitId,
      sourcePort: w.sourcePort,
      pollIntervalMs: pollIntervalMs,
    );
  }
}

// -----------------------------------------------------------------------------
// Router
// -----------------------------------------------------------------------------

/// Parses and dispatches `@conn/<alias>/<field>` meta-keys to their source.
///
/// Kept independent of [StateMan] so it can be unit-tested with fake sources.
class ConnMetaRouter {
  final Map<String, ConnMetaSource> _byAlias;

  /// The periodic re-sample interval for [subscribe]. 1s in production;
  /// overridable so tests can drive the sampled fields without real waits.
  final Duration tickInterval;

  ConnMetaRouter(List<ConnMetaSource> sources,
      {this.tickInterval = const Duration(seconds: 1)})
      : _byAlias = {for (final s in sources) s.metaAlias: s};

  /// Whether [key] is in the `@conn` namespace at all (cheap prefix test).
  static bool isMetaKey(String key) =>
      key == kConnMetaPrefix || key.startsWith('$kConnMetaPrefix/');

  /// The synthetic meta-keys for every source, for the key picker.
  ///
  /// Derived from the protocol alone — no [ConnMetaSource.snapshot] — since
  /// key pickers call this on every keystroke.
  List<String> get metaKeys {
    final out = <String>[];
    for (final source in _byAlias.values) {
      final fields =
          source.isModbus ? kConnMetaModbusFields : kConnMetaOpcuaFields;
      for (final field in fields) {
        out.add('$kConnMetaPrefix/${source.metaAlias}/$field');
      }
    }
    return out;
  }

  /// Split a meta-key into `(alias, field)`, validating arity.
  ({String alias, String field}) parse(String key) {
    final parts = key.split('/');
    if (parts.length != 3 || parts[0] != kConnMetaPrefix) {
      throw StateManException(
          "invalid connection metadata key '$key' — expected the form "
          "'$kConnMetaPrefix/<serverAlias>/<field>'");
    }
    return (alias: parts[1], field: parts[2]);
  }

  ConnMetaSource _sourceFor(String key, String alias) {
    final source = _byAlias[alias];
    if (source == null) {
      final known = _byAlias.keys.map((a) => "'$a'").join(', ');
      throw StateManException(
          "connection metadata key '$key' names unknown server alias "
          "'$alias' — known aliases: ${known.isEmpty ? '<none>' : known}");
    }
    return source;
  }

  DynamicValue _field(String key, ConnMeta meta, String field) {
    final map = meta.toFieldMap();
    final value = map[field];
    if (value == null) {
      final valid = meta.validFields.map((f) => "'$f'").join(', ');
      throw StateManException(
          "connection metadata key '$key' names unknown field '$field' — "
          "valid fields: $valid");
    }
    return value;
  }

  /// Current-snapshot value for a meta-key. Used by read/readMany.
  DynamicValue read(String key) {
    final (alias: alias, field: field) = parse(key);
    final source = _sourceFor(key, alias);
    return _field(key, source.snapshot(), field);
  }

  /// A live stream for a meta-key. Emits the current value immediately, then
  /// on every connection-state change and on a 1s periodic tick (so
  /// time/load-derived fields such as uptimeSec and requestsPerSec advance).
  ///
  /// The periodic tick is a single-subscription [Stream.periodic]; cancelling
  /// the returned subscription cancels its timer, so nothing leaks.
  Stream<DynamicValue> subscribe(String key) {
    final (alias: alias, field: field) = parse(key);
    final source = _sourceFor(key, alias);
    // Validate the field once up front so a bad field errors at subscribe
    // time rather than silently never emitting.
    _field(key, source.snapshot(), field);
    DynamicValue current() => _field(key, source.snapshot(), field);
    return Rx.merge<void>([
      source.changes,
      Stream<void>.periodic(tickInterval, (_) {}),
    ]).map((_) => current()).startWith(current());
  }

  /// A live stream of ALL fields for [alias] from a single subscription:
  /// one timer, one snapshot and one [ConnMeta.toFieldMap] per tick.
  ///
  /// This is what widgets that render a whole connection card should use —
  /// per-field [subscribe] calls each run their own timer and take their own
  /// snapshot, so a 14-field card would otherwise pay 14 snapshots per
  /// second and rebuild up to 14 times a second.
  Stream<Map<String, DynamicValue>> subscribeAll(String alias) {
    final source = _sourceFor('$kConnMetaPrefix/$alias/*', alias);
    Map<String, DynamicValue> current() => source.snapshot().toFieldMap();
    return Rx.merge<void>([
      source.changes,
      Stream<void>.periodic(tickInterval, (_) {}),
    ]).map((_) => current()).startWith(current());
  }

  /// The aliases this router can answer for with their protocol — what an
  /// editor UI should offer as suggestions (unnamed servers appear under
  /// their synthetic host:port identity).
  List<({String alias, bool isModbus})> get aliases => [
        for (final s in _byAlias.values)
          (alias: s.metaAlias, isModbus: s.isModbus),
      ];
}
