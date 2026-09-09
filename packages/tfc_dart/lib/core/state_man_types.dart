/// The platform-free half of `state_man.dart`: the configuration the plant is
/// described by, the key mappings, and the [StateMan] interface itself.
///
/// **Why this file exists.** `state_man.dart` is the OPC UA client — it holds
/// sessions, runs `runIterate` loops, and imports `dart:ffi` through
/// `package:open62541`. None of that is meaningful in a browser, where the
/// panel holds no PLC session at all and every value arrives over one
/// WebSocket. But the *types* are meaningful everywhere: an asset that draws a
/// conveyor names [StateMan] to subscribe, and a key mapping is a key mapping
/// whether it was read from a local database or handed down the socket.
///
/// So [StateMan] is declared here as an interface with no implementation.
/// `OpcUaStateMan` in `state_man.dart` is the plant-side implementation;
/// `GatewayStateMan` in the app is the relay-side one; `GuardedStateMan`
/// wraps either. Widgets name only this file and never learn which they hold —
/// which is the whole premise the relay milestone was built on.
///
/// Nothing here may import `package:open62541/open62541.dart` (use
/// `open62541_types.dart`), `drift`, `dart:io`, or `state_man.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart';

import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import 'package:jbtm/src/m2400_fields.dart' show M2400Field;
import 'package:modbus_client/modbus_client.dart'
    show ModbusElementType, ModbusEndianness;

import 'modbus_client_wrapper.dart' show ModbusDataType;
import 'collect_config.dart';
import 'preferences_api.dart';

part 'state_man_types.g.dart';

/// Statistics tracker for runIterate timing
class RunIterateStats {
  final String clientName;
  final Logger _logger = Logger();

  DateTime? _lastCallTime;
  int _callCount = 0;

  // Time between calls (gaps)
  Duration _maxGap = Duration.zero;
  Duration _totalGap = Duration.zero;

  // Execution time
  Duration _maxExecTime = Duration.zero;
  Duration _totalExecTime = Duration.zero;

  // Report interval
  final int _reportInterval = 1000; // Report every N calls

  RunIterateStats(this.clientName);

  void recordCall(Duration execTime) {
    final now = DateTime.now();

    if (_lastCallTime != null) {
      final gap = now.difference(_lastCallTime!);
      _totalGap += gap;
      if (gap > _maxGap) {
        _maxGap = gap;
      }
    }

    _totalExecTime += execTime;
    if (execTime > _maxExecTime) {
      _maxExecTime = execTime;
    }

    _callCount++;
    _lastCallTime = now;

    // Log periodically
    if (_callCount % _reportInterval == 0) {
      _logStats();
    }
  }

  void _logStats() {
    if (_callCount == 0) return;

    final avgGapMs = _callCount > 1
        ? (_totalGap.inMicroseconds / (_callCount - 1) / 1000)
            .toStringAsFixed(2)
        : 'N/A';
    final avgExecMs =
        (_totalExecTime.inMicroseconds / _callCount / 1000).toStringAsFixed(2);

    _logger.i('[$clientName] runIterate stats after $_callCount calls: '
        'gap(avg: ${avgGapMs}ms, max: ${_maxGap.inMilliseconds}ms) '
        'exec(avg: ${avgExecMs}ms, max: ${_maxExecTime.inMilliseconds}ms)');
  }

  void logFinal() {
    _logStats();
  }
}

class Base64Converter implements JsonConverter<Uint8List?, String?> {
  const Base64Converter();

  @override
  Uint8List? fromJson(String? json) {
    if (json == null) return null;
    return base64Decode(json);
  }

  @override
  String? toJson(Uint8List? certificateContents) {
    if (certificateContents == null) return null;
    return base64Encode(certificateContents);
  }
}

/// Common shape of a single server entry inside [StateManConfig].
///
/// Implemented by [OpcUAConfig], [M2400Config] and [ModbusConfig] so
/// [StateManConfig] can reason about "which aliases are switched off"
/// without caring which protocol the entry speaks.
abstract interface class ServerConfigEntry {
  /// When false the server is never connected to, and every key routed
  /// to it fails fast instead of retrying. See [StateManConfig.isServerEnabled].
  bool get enabled;

  /// The alias keys reference in their `server_alias` node field.
  String? get serverAlias;
}

@JsonSerializable(explicitToJson: true)
class OpcUAConfig implements ServerConfigEntry {
  String endpoint = "opc.tcp://localhost:4840";
  String? username;
  String? password;
  @Base64Converter()
  @JsonKey(name: 'ssl_cert')
  Uint8List? sslCert;
  @Base64Converter()
  @JsonKey(name: 'ssl_key')
  Uint8List? sslKey;
  @JsonKey(name: 'server_alias')
  String? serverAlias;

  /// Whether this server takes part in data acquisition.
  ///
  /// Disabling a server stops the connect/reconnect loop entirely — an
  /// unreachable PLC otherwise emits a connect failure, a channel-state
  /// transition and a subscription retry line every second, which buries
  /// the rest of the log. Defaults to true so existing configs (which have
  /// no `enabled` field) keep working untouched.
  @JsonKey(defaultValue: true)
  bool enabled = true;

  /// Lifetime the client asks for when it opens the SecureChannel, in
  /// milliseconds.
  ///
  /// open62541 renews the channel at 75% of whatever the server grants, so
  /// this is really "how often do we exercise the renew path", and each
  /// renewal rotates the channel's symmetric keys.
  ///
  /// Defaults to open62541's own default of 10 minutes — deliberately NOT
  /// the 60 s that used to be hardcoded in [OpcUaStateMan.create]. That minute
  /// existed to reproduce the frozen-session bug on the bench and made every
  /// station renew 80 times an hour; 10 minutes drops that to 8, which is
  /// already nothing beside a subscription publishing ten times a second.
  /// Going longer still buys no measurable relief and only ages the
  /// symmetric keys on the SIGNANDENCRYPT links.
  ///
  /// This is a *requested* lifetime. The server answers with what it granted
  /// and may cap it well below this; the binding does not surface that
  /// figure, so a long value here is a ceiling, not a promise.
  @JsonKey(name: 'secure_channel_lifetime_ms', defaultValue: 600000)
  int secureChannelLifetimeMs = 600000;

  /// How often the server is asked to publish subscription notifications,
  /// in milliseconds — the rate at which values reach the HMI.
  ///
  /// Applied both as the subscription's requested publishing interval and as
  /// the sampling interval of every monitored item on it, so the one number
  /// governs the update rate end to end. Slowing it down is the cheapest way
  /// to cut load on a PLC that is drowning in monitored items.
  ///
  /// Keep it well under [ClientWrapper.heartbeatStaleAfter]: the heartbeat
  /// rides this same subscription, so an interval near 15 s would make a
  /// perfectly healthy server report `opcuaUnhealthy`. The UI clamps to
  /// [publishingIntervalMaxMs] for that reason.
  @JsonKey(name: 'publishing_interval_ms', defaultValue: 100)
  int publishingIntervalMs = 100;

  /// Smallest accepted [publishingIntervalMs]. Below this the client asks
  /// for more publishes per second than a PLC will honour anyway.
  static const publishingIntervalMinMs = 10;

  /// Largest accepted [publishingIntervalMs]. Bounded by the heartbeat
  /// staleness window — see [publishingIntervalMs].
  static const publishingIntervalMaxMs = 5000;

  /// Smallest accepted [secureChannelLifetimeMs] (10 s).
  static const secureChannelLifetimeMinMs = 10000;

  /// Largest accepted [secureChannelLifetimeMs] (24 h).
  static const secureChannelLifetimeMaxMs = 86400000;

  /// Convenience getter for use with the open62541 Duration APIs.
  Duration get secureChannelLifetime =>
      Duration(milliseconds: secureChannelLifetimeMs);

  /// Convenience getter for use with the open62541 Duration APIs.
  Duration get publishingInterval =>
      Duration(milliseconds: publishingIntervalMs);

  OpcUAConfig();

  @override
  String toString() {
    // The password and private key are never printed — a decoded config gets
    // logged in enough places (and, since 17-10, travels the wire redacted)
    // that a toString carrying the literal was a standing credential leak.
    // Flagged by the 2026-09-07 access-surface audit; closed with 17-10.
    final pw = (password == null || password!.isEmpty) ? 'null' : '<redacted>';
    final key = (sslKey == null || sslKey!.isEmpty) ? 'null' : '<redacted>';
    return 'OpcUAConfig(endpoint: $endpoint, username: $username, password: $pw, sslCert: $sslCert, sslKey: $key, enabled: $enabled, secureChannelLifetimeMs: $secureChannelLifetimeMs, publishingIntervalMs: $publishingIntervalMs)';
  }

  factory OpcUAConfig.fromJson(Map<String, dynamic> json) =>
      _$OpcUAConfigFromJson(json);
  Map<String, dynamic> toJson() => _$OpcUAConfigToJson(this);
}

@JsonSerializable(explicitToJson: true)
class M2400Config implements ServerConfigEntry {
  @JsonKey(defaultValue: 'm2400')
  String type;
  String host;
  int port;
  @JsonKey(name: 'server_alias')
  String? serverAlias;

  /// See [OpcUAConfig.enabled].
  @JsonKey(defaultValue: true)
  bool enabled;

  M2400Config(
      {this.type = 'm2400',
      this.host = '',
      this.port = 52211,
      this.enabled = true});

  factory M2400Config.fromJson(Map<String, dynamic> json) =>
      _$M2400ConfigFromJson(json);
  Map<String, dynamic> toJson() => _$M2400ConfigToJson(this);

  @override
  String toString() =>
      'M2400Config(type: $type, host: $host, port: $port, alias: $serverAlias, enabled: $enabled)';
}

@JsonSerializable(explicitToJson: true)
class M2400NodeConfig {
  @JsonKey(name: 'record_type')
  M2400RecordType recordType;
  M2400Field? field;
  @JsonKey(name: 'server_alias')
  String? serverAlias;

  /// Optional WeigherStatus code filter (BATCH only).
  /// When set, only BATCH records whose status field matches this code are emitted.
  @JsonKey(name: 'status_filter')
  int? statusFilter;

  M2400NodeConfig({
    required this.recordType,
    this.field,
    this.serverAlias,
    this.statusFilter,
  });

  factory M2400NodeConfig.fromJson(Map<String, dynamic> json) =>
      _$M2400NodeConfigFromJson(json);
  Map<String, dynamic> toJson() => _$M2400NodeConfigToJson(this);

  @override
  String toString() =>
      'M2400NodeConfig(recordType: $recordType, field: $field, alias: $serverAlias, statusFilter: $statusFilter)';
}

// =============================================================================
// Modbus configuration classes (Phase 8)
// =============================================================================

/// Modbus register type for JSON serialization.
///
/// Maps to [ModbusElementType] at runtime via [toModbusElementType] and
/// [fromModbusElementType]. Kept as a separate enum so json_serializable
/// generates camelCase string serialization without depending on the
/// modbus_client package in the serialization layer.
enum ModbusRegisterType {
  coil,
  discreteInput,
  holdingRegister,
  inputRegister;

  /// Converts to the modbus_client library's [ModbusElementType].
  ModbusElementType toModbusElementType() {
    switch (this) {
      case ModbusRegisterType.coil:
        return ModbusElementType.coil;
      case ModbusRegisterType.discreteInput:
        return ModbusElementType.discreteInput;
      case ModbusRegisterType.holdingRegister:
        return ModbusElementType.holdingRegister;
      case ModbusRegisterType.inputRegister:
        return ModbusElementType.inputRegister;
    }
  }

  /// Creates from the modbus_client library's [ModbusElementType].
  static ModbusRegisterType fromModbusElementType(ModbusElementType type) {
    switch (type) {
      case ModbusElementType.coil:
        return ModbusRegisterType.coil;
      case ModbusElementType.discreteInput:
        return ModbusRegisterType.discreteInput;
      case ModbusElementType.holdingRegister:
        return ModbusRegisterType.holdingRegister;
      case ModbusElementType.inputRegister:
        return ModbusRegisterType.inputRegister;
      default:
        throw ArgumentError('Unsupported ModbusElementType: $type');
    }
  }
}

/// Configuration for a named Modbus poll group.
///
/// Poll groups allow registers to be read at different intervals (e.g. fast
/// control loop vs slow diagnostics).
@JsonSerializable(explicitToJson: true)
class ModbusPollGroupConfig {
  String name;
  @JsonKey(name: 'interval_ms')
  int intervalMs;

  ModbusPollGroupConfig({required this.name, this.intervalMs = 1000});

  /// Convenience getter for use with Timer/Duration APIs.
  Duration get interval => Duration(milliseconds: intervalMs);

  factory ModbusPollGroupConfig.fromJson(Map<String, dynamic> json) =>
      _$ModbusPollGroupConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ModbusPollGroupConfigToJson(this);

  @override
  String toString() =>
      'ModbusPollGroupConfig(name: $name, intervalMs: $intervalMs)';
}

/// Top-level configuration for a single Modbus TCP server connection.
///
/// Parallels [M2400Config] and [OpcUAConfig] in the config hierarchy.
@JsonSerializable(explicitToJson: true)
class ModbusConfig implements ServerConfigEntry {
  String host;
  int port;
  @JsonKey(name: 'unit_id')
  int unitId;
  @JsonKey(name: 'server_alias')
  String? serverAlias;

  /// See [OpcUAConfig.enabled].
  @JsonKey(defaultValue: true)
  bool enabled;
  @JsonKey(name: 'poll_groups', defaultValue: [])
  List<ModbusPollGroupConfig> pollGroups;
  @JsonKey(name: 'umas_enabled', defaultValue: false)
  bool umasEnabled;
  @JsonKey(defaultValue: ModbusEndianness.ABCD)
  ModbusEndianness endianness;
  @JsonKey(name: 'address_base', defaultValue: 0)
  int addressBase;

  ModbusConfig({
    this.host = '',
    this.port = 502,
    int unitId = 1,
    this.serverAlias,
    this.pollGroups = const [],
    this.umasEnabled = false,
    this.endianness = ModbusEndianness.ABCD,
    this.addressBase = 0,
    this.enabled = true,
  }) : unitId = unitId.clamp(0, 255);

  factory ModbusConfig.fromJson(Map<String, dynamic> json) =>
      _$ModbusConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ModbusConfigToJson(this);

  @override
  String toString() =>
      'ModbusConfig(host: $host, port: $port, unitId: $unitId, alias: $serverAlias, pollGroups: $pollGroups, enabled: $enabled)';
}

/// Per-key configuration that describes which Modbus register a key maps to.
///
/// Parallels [M2400NodeConfig] and [OpcUANodeConfig] in the keymappings.
@JsonSerializable(explicitToJson: true)
class ModbusNodeConfig {
  @JsonKey(name: 'server_alias')
  String? serverAlias;
  @JsonKey(name: 'register_type')
  ModbusRegisterType registerType;
  int address;
  @JsonKey(name: 'data_type')
  ModbusDataType dataType;
  @JsonKey(name: 'poll_group')
  String pollGroup;

  ModbusNodeConfig({
    this.serverAlias,
    required this.registerType,
    required int address,
    this.dataType = ModbusDataType.uint16,
    this.pollGroup = 'default',
  }) : address = address.clamp(0, 65535);

  factory ModbusNodeConfig.fromJson(Map<String, dynamic> json) =>
      _$ModbusNodeConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ModbusNodeConfigToJson(this);

  @override
  String toString() =>
      'ModbusNodeConfig(alias: $serverAlias, registerType: $registerType, address: $address, dataType: $dataType, pollGroup: $pollGroup)';
}

@JsonSerializable(explicitToJson: true)
class StateManConfig {
  List<OpcUAConfig> opcua;
  @JsonKey(defaultValue: [])
  List<M2400Config> jbtm;
  @JsonKey(defaultValue: [])
  List<ModbusConfig> modbus;

  StateManConfig(
      {required this.opcua, this.jbtm = const [], this.modbus = const []});

  StateManConfig copy() => StateManConfig.fromJson(toJson());

  /// Every configured server, regardless of protocol or enabled state.
  List<ServerConfigEntry> get allServers => [...opcua, ...jbtm, ...modbus];

  /// Only the servers that should actually be connected to.
  List<OpcUAConfig> get enabledOpcua => opcua.where((c) => c.enabled).toList();
  List<M2400Config> get enabledJbtm => jbtm.where((c) => c.enabled).toList();
  List<ModbusConfig> get enabledModbus =>
      modbus.where((c) => c.enabled).toList();

  /// Normalises an alias so a missing alias and an empty one are the same
  /// bucket — the UI writes `null` for a cleared alias field but imported
  /// JSON often carries `""`.
  static String? normalizeAlias(String? alias) =>
      (alias == null || alias.isEmpty) ? null : alias;

  /// Aliases that resolve to nothing but disabled servers.
  ///
  /// An alias shared by a disabled and an enabled entry is *not* disabled —
  /// the enabled one still serves its keys. `null` in the returned set means
  /// the unnamed (aliasless) server is off.
  Set<String?> get disabledServerAliases {
    final enabled = <String?>{};
    final disabled = <String?>{};
    for (final server in allServers) {
      final alias = normalizeAlias(server.serverAlias);
      (server.enabled ? enabled : disabled).add(alias);
    }
    return disabled.difference(enabled);
  }

  /// Whether keys pointing at [alias] should be acquired at all.
  bool isServerEnabled(String? alias) =>
      !disabledServerAliases.contains(normalizeAlias(alias));

  @override
  String toString() {
    return 'StateManConfig(opcua: ${opcua.toString()}, jbtm: ${jbtm.toString()}, modbus: ${modbus.toString()})';
  }




  factory StateManConfig.fromJson(Map<String, dynamic> json) =>
      _$StateManConfigFromJson(json);
  Map<String, dynamic> toJson() => _$StateManConfigToJson(this);

  static const String configKey = 'state_man_config';
}

@JsonSerializable(explicitToJson: true)
class OpcUANodeConfig {
  int namespace;
  String identifier;
  // I only want to support one dimension arrays, I dont think it is relevant to support multi-dimensional arrays
  @JsonKey(name: 'array_index')
  int? arrayIndex;
  @JsonKey(name: 'server_alias')
  String? serverAlias;

  OpcUANodeConfig({required this.namespace, required this.identifier});

  (NodeId, int?) toNodeId() {
    if (int.tryParse(identifier) != null) {
      return (NodeId.fromNumeric(namespace, int.parse(identifier)), arrayIndex);
    }
    return (NodeId.fromString(namespace, identifier), arrayIndex);
  }

  factory OpcUANodeConfig.fromJson(Map<String, dynamic> json) =>
      _$OpcUANodeConfigFromJson(json);
  Map<String, dynamic> toJson() => _$OpcUANodeConfigToJson(this);

  @override
  String toString() {
    return 'OpcUANodeConfig(namespace: $namespace, identifier: $identifier)';
  }
}

@JsonSerializable(explicitToJson: true)
class KeyMappingEntry {
  @JsonKey(name: 'opcua_node')
  OpcUANodeConfig? opcuaNode;
  @JsonKey(name: 'm2400_node')
  M2400NodeConfig? m2400Node;
  @JsonKey(name: 'modbus_node')
  ModbusNodeConfig? modbusNode;
  bool? io; // if true, the key is an IO unit
  CollectEntry? collect;

  /// Optional bit mask for extracting bits from integer values.
  /// When set, reads extract (value & bitMask) >>> bitShift.
  /// Single-bit mask produces bool; multi-bit produces int.
  @JsonKey(name: 'bit_mask')
  int? bitMask;

  /// Bit shift applied after masking (position of lowest set bit in mask).
  @JsonKey(name: 'bit_shift')
  int? bitShift;

  /// Optional UMAS symbol path (e.g. `B_F1_RC_01_Front` or
  /// `M_Elevator.i_isAuto`). When set on a key whose server has UMAS
  /// enabled, the polled value is read by UMAS variable name rather than
  /// translated to a Modbus address — Schneider PLCs only expose
  /// `%MW`-located variables on the FC03 register map, so symbolic
  /// variables fail to read via plain Modbus addressing.
  ///
  /// `null` means classic Modbus addressing (the address + bit fields are
  /// the read source). When `variableName != null` but the server has
  /// `umasEnabled == false`, the key is invalid and the UI surfaces an
  /// Error badge — the address-space fallback is intentionally not silent.
  ///
  /// JSON key is `variable_name` for snake_case parity with the other
  /// fields. Existing entries deserialize cleanly because `defaultValue`
  /// is `null` (see `_$KeyMappingEntryFromJson` in `state_man.g.dart`).
  @JsonKey(name: 'variable_name', defaultValue: null)
  String? variableName;

  String? get server =>
      opcuaNode?.serverAlias ??
      m2400Node?.serverAlias ??
      modbusNode?.serverAlias;

  KeyMappingEntry({
    this.opcuaNode,
    this.m2400Node,
    this.modbusNode,
    this.collect,
    this.bitMask,
    this.bitShift,
    this.variableName,
  });

  KeyMappingEntry copyWith({
    OpcUANodeConfig? opcuaNode,
    M2400NodeConfig? m2400Node,
    ModbusNodeConfig? modbusNode,
    CollectEntry? collect,
    int? bitMask,
    int? bitShift,
    bool clearBitMask = false,
    String? variableName,
    bool clearVariableName = false,
  }) {
    return KeyMappingEntry(
      opcuaNode: opcuaNode ?? this.opcuaNode,
      m2400Node: m2400Node ?? this.m2400Node,
      modbusNode: modbusNode ?? this.modbusNode,
      collect: collect ?? this.collect,
      bitMask: clearBitMask ? null : (bitMask ?? this.bitMask),
      bitShift: clearBitMask ? null : (bitShift ?? this.bitShift),
      variableName:
          clearVariableName ? null : (variableName ?? this.variableName),
    )..io = io;
  }

  factory KeyMappingEntry.fromJson(Map<String, dynamic> json) =>
      _$KeyMappingEntryFromJson(json);
  Map<String, dynamic> toJson() => _$KeyMappingEntryToJson(this);

  @override
  String toString() {
    return 'KeyMappingEntry(opcuaNode: ${opcuaNode?.toString()}, m2400Node: ${m2400Node?.toString()}, modbusNode: ${modbusNode?.toString()}, collect: $collect, io: $io'
        '${variableName != null ? ', variableName: $variableName' : ''})';
  }
}

@JsonSerializable(explicitToJson: true)
class KeyMappings {
  Map<String, KeyMappingEntry> nodes;

  KeyMappings({required this.nodes});

  (NodeId, int?)? lookupNodeId(String key) {
    return nodes[key]?.opcuaNode?.toNodeId();
  }

  String? lookupServerAlias(String key) {
    final entry = nodes[key];
    return entry?.opcuaNode?.serverAlias ??
        entry?.m2400Node?.serverAlias ??
        entry?.modbusNode?.serverAlias;
  }

  String? lookupKey(NodeId nodeId) {
    return nodes.entries.firstWhereOrNull((entry) {
      final result = entry.value.opcuaNode?.toNodeId();
      if (result == null) return false;
      final (entryNodeId, _) = result;
      return entryNodeId == nodeId;
    })?.key;
  }

  Iterable<String> get keys => nodes.keys;

  /// Filter key mappings to only include entries for a specific server alias.
  KeyMappings filterByServer(String? serverAlias) {
    final filtered = Map.fromEntries(
      nodes.entries.where((e) => e.value.server == serverAlias),
    );
    return KeyMappings(nodes: filtered);
  }

  static Future<KeyMappings> fromPrefs(PreferencesApi prefs,
      {bool createDefault = true}) async {
    var keyMappingsJson = await prefs.getString('key_mappings');
    if (keyMappingsJson == null) {
      if (!createDefault) {
        throw Exception(
            'key_mappings not found in preferences and createDefault is false');
      }
      final defaultKeyMappings = KeyMappings(nodes: {
        "exampleKey": KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 42, identifier: "identifier"))
      });
      keyMappingsJson = jsonEncode(defaultKeyMappings.toJson());
      await prefs.setString('key_mappings', keyMappingsJson);
    }
    return KeyMappings.fromJson(jsonDecode(keyMappingsJson));
  }

  factory KeyMappings.fromJson(Map<String, dynamic> json) =>
      _$KeyMappingsFromJson(json);
  Map<String, dynamic> toJson() => _$KeyMappingsToJson(this);
}

/// What [StateMan.updateKeyMappings] applied in place, and whether the
/// caller still needs to rebuild the whole StateMan.
///
/// The apply is incremental by design: unchanged keys are untouched (no
/// reconnects, no resubscriptions), OPC UA edits are re-pointed live, and
/// UMAS-by-name edits propagate through the adapter hooks. Only edits whose
/// state is frozen at construction time (classic-Modbus register specs,
/// M2400 extraction captured per widget stream) ask for a reload.
class KeyMappingsUpdateResult {
  /// Keys present in the new mappings but not the old.
  final Set<String> added;

  /// Keys present in the old mappings but not the new.
  final Set<String> removed;

  /// Keys present in both whose entry differs.
  final Set<String> changed;

  /// Changed keys whose live OPC UA monitor was re-pointed in place.
  final Set<String> resubscribed;

  /// Human-readable reasons a full StateMan rebuild is still required.
  /// Empty when the whole edit was applied live.
  final List<String> reloadReasons;

  bool get requiresReload => reloadReasons.isNotEmpty;

  const KeyMappingsUpdateResult({
    required this.added,
    required this.removed,
    required this.changed,
    required this.resubscribed,
    required this.reloadReasons,
  });

  @override
  String toString() =>
      'KeyMappingsUpdateResult(added: ${added.length}, removed: '
      '${removed.length}, changed: ${changed.length}, resubscribed: '
      '${resubscribed.length}, requiresReload: $requiresReload'
      '${requiresReload ? ', reasons: ${reloadReasons.join('; ')}' : ''})';
}

class StateManException implements Exception {
  final String message;
  StateManException(this.message);
  @override
  String toString() => 'StateManException: $message';
}

/// Thrown when a key is routed to a server the operator switched off.
///
/// Distinct from a plain [StateManException] so callers can tell "this key
/// is parked on purpose" from "this key is broken" — the key repository
/// renders it as a grey Disabled badge rather than a red Error one. Raised
/// without logging: an offline PLC with hundreds of keys would otherwise
/// reproduce the very log flood disabling it is meant to stop.
class ServerDisabledException extends StateManException {
  /// The alias that is switched off (`null` for the unnamed server).
  final String? serverAlias;

  ServerDisabledException(String key, this.serverAlias)
      : super('Key "$key" belongs to disabled server '
            '"${serverAlias ?? '<unnamed>'}"');

  @override
  String toString() => 'ServerDisabledException: $message';
}

class SingleWorker {
  List<Completer<bool>> waiters = [];

  /// How long a waiter blocks before giving up on the current owner.
  ///
  /// The owner only calls [complete] from the `finally` of its own work, so a
  /// PLC (or isolate) that never answers means that `finally` never runs. An
  /// unbounded wait here then parks every other key on the server with no
  /// retry and no log. Giving up returns `false`, which puts the caller back
  /// on its normal retry ladder -- it re-checks whether the work is still
  /// needed before trying again, so this can never create duplicate work.
  final Duration waitTimeout;

  SingleWorker({this.waitTimeout = const Duration(seconds: 5)});

  Future<bool> doTheWork() async {
    final completer = Completer<bool>();
    waiters.add(completer);
    if (waiters.length == 1) {
      completer.complete(true);
      return completer.future;
    }

    return completer.future.timeout(waitTimeout, onTimeout: () {
      waiters.remove(completer);
      return false;
    });
  }

  void complete() {
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(false);
      }
    }
    waiters.clear();
  }
}

enum ConnectionStatus { connected, connecting, disconnected }

/// TD-004 (v1.1.x): a derived health status that combines TCP socket
/// state with protocol-layer state (UMAS session). Surfaces the case
/// where TCP is up but every UMAS read/write fails because the PLC's
/// Data Dictionary is disabled or the session refuses to pair —
/// previously rendered as a green "Connected" chip while every key
/// card on the page showed an error badge.
///
/// Mapping:
///   - [disconnected] / [connecting] / [connected]: same as the pure
///     TCP states for adapters where UMAS is OFF or no operation has
///     attempted to pair yet.
///   - [umasUnhealthy]: TCP is connected, `umasEnabled == true`, but
///     the UMAS session is not `paired` (init failed, identification
///     failed, or the session was reset by a recent protocol error).
///   - [opcuaUnhealthy]: the OPC UA client's last known state says
///     connected, but the data plane is dead: the heartbeat monitored
///     item (server time, same subscription as every data key) has not
///     ticked within [ClientWrapper.heartbeatStaleAfter], or the
///     session/subscription is known lost. This is the frozen-session
///     shape from docs/opcua-frozen-session-repro.md — TCP Established,
///     channel formally open, no state event ever emitted again — which
///     a purely event-driven status can never catch.
enum EffectiveDeviceStatus {
  disconnected,
  connecting,
  connected,
  umasUnhealthy,
  opcuaUnhealthy,
}

/// Protocol-agnostic device client interface.
///
/// Abstracts the subscribe/status pattern shared by different device protocols
/// (OPC UA via [ClientWrapper], M2400 via M2400ClientWrapper, etc.).
///
/// Implementations define [subscribableKeys] and [canSubscribe] to declare
/// which keys they handle. [StateMan.subscribe] checks device clients first,
/// falling through to OPC UA if no device client claims the key.
abstract class DeviceClient {
  /// The set of top-level keys this device client can handle.
  Set<String> get subscribableKeys;

  /// Whether this client can handle a subscribe request for [key].
  ///
  /// Should return true for both top-level keys (e.g., 'BATCH') and
  /// dot-notation keys (e.g., 'BATCH.weight') if the root is subscribable.
  bool canSubscribe(String key);

  /// Subscribe to a DynamicValue stream by key.
  Stream<DynamicValue> subscribe(String key);

  /// Read the last known value for [key], or null if unavailable.
  DynamicValue? read(String key);

  /// Current connection status (synchronous).
  ConnectionStatus get connectionStatus;

  /// Stream of connection status changes.
  Stream<ConnectionStatus> get connectionStream;

  /// Start connecting to the device.
  void connect();

  /// Write a value to the device by key.
  Future<void> write(String key, DynamicValue value);

  /// Dispose resources.
  void dispose();
}

/// What every widget in this application is allowed to ask of the plant.
///
/// Three classes implement this: `OpcUaStateMan` (a real OPC UA session, in
/// `state_man.dart`), `GatewayStateMan` (the same thing over one WebSocket, in
/// the app), and `GuardedStateMan` (either of those, with access control in
/// front). A widget must never test which it has.
///
/// **`clients` is deliberately absent.** A `List<ClientWrapper>` is a list of
/// live OPC UA sessions; a panel in gateway mode has none, and a browser
/// cannot have one. The handful of browse and diagnostic widgets that need
/// real sessions name `OpcUaStateMan` directly and say what they do without
/// one — which is better than an interface member that is empty half the time
/// and whose emptiness reads as "no servers configured".
abstract interface class StateMan {
  /// The plant description this instance was built from.
  StateManConfig get config;

  /// The key-to-node mapping in force. Settable: an edit re-points live
  /// subscriptions rather than requiring a restart.
  KeyMappings get keyMappings;
  set keyMappings(KeyMappings value);

  /// Which configuration this instance belongs to, for logs and diagnostics.
  String get alias;
  set alias(String value);

  Logger get logger;

  /// Device clients (M2400, Modbus/UMAS) that claim keys before OPC UA does.
  /// Empty in gateway mode, where the gateway owns every device session.
  List<DeviceClient> get deviceClients;

  /// Every key this instance can serve, including connection-meta keys.
  List<String> get keys;

  /// Whether [key] resolves to a server that configuration has switched off.
  bool isKeyDisabled(String key);

  /// `$variable` substitution — resolved locally on both transports, on
  /// purpose: a template is a property of the page, not of the plant.
  void setSubstitution(String key, String value);
  String? getSubstitution(String key);
  Map<String, String> get substitutions;
  Stream<Map<String, String>> get substitutionsChanged;

  /// [key] with every `$variable` replaced. Throws if one is unresolved.
  String resolveKey(String key);

  Future<DynamicValue> read(String key);
  Future<Map<String, DynamicValue>> readMany(List<String> keys);
  Future<void> write(String key, DynamicValue value);
  Future<Stream<DynamicValue>> subscribe(String key);

  /// Apply an edited mapping in place, re-pointing what is already live.
  KeyMappingsUpdateResult updateKeyMappings(KeyMappings newKeyMappings);

  /// Connection metadata for [alias] — the aliases available are
  /// [connMetaAliases]. `isModbus` says which health vocabulary the alias
  /// speaks, because a Modbus link and an OPC UA session do not fail alike.
  Stream<Map<String, DynamicValue>> subscribeConnMeta(String alias);
  List<({String alias, bool isModbus})> get connMetaAliases;

  /// Inject a stream for [key], used by simulation and by tests. [firstValue]
  /// seeds the replay so a late subscriber is not left with nothing to draw.
  void addSubscription({
    required String key,
    required Stream<DynamicValue> subscription,
    required DynamicValue? firstValue,
  });

  Future<void> close();
}
