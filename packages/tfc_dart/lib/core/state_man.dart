import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:meta/meta.dart'; // Add this import at the top
import 'package:logger/logger.dart';
import 'package:json_annotation/json_annotation.dart';
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

part 'state_man.g.dart';

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
  /// the 60 s that used to be hardcoded in [StateMan.create]. That minute
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
    return 'OpcUAConfig(endpoint: $endpoint, username: $username, password: $password, sslCert: $sslCert, sslKey: $sslKey, enabled: $enabled, secureChannelLifetimeMs: $secureChannelLifetimeMs, publishingIntervalMs: $publishingIntervalMs)';
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

  static Future<StateManConfig> fromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Config file not found: $path');
    }
    final contents = await file.readAsString();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(contents) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw Exception('Invalid JSON in config file: $path - ${e.message}');
    }
    return StateManConfig.fromJson(json);
  }

  static Future<StateManConfig> fromPrefs(Preferences prefs) async {
    var configJson = await prefs.getString(configKey, secret: true);
    if (configJson == null) {
      configJson = jsonEncode(StateManConfig(opcua: [OpcUAConfig()]).toJson());
      await prefs.setString(configKey, configJson,
          secret: true, saveToDb: false);
    }
    return StateManConfig.fromJson(jsonDecode(configJson));
  }

  Future<void> toPrefs(Preferences prefs) async {
    final configJson = jsonEncode(toJson());
    await prefs.setString(configKey, configJson, secret: true, saveToDb: false);
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
    final direct = nodes[key]?.opcuaNode?.toNodeId();
    if (direct != null) return direct;
    final derived = _derive(key);
    if (derived == null) return null;
    final (node, suffix) = derived;
    return (NodeId.fromString(node.namespace, node.identifier + suffix), null);
  }

  String? lookupServerAlias(String key) {
    final entry = nodes[key];
    if (entry != null) {
      return entry.opcuaNode?.serverAlias ??
          entry.m2400Node?.serverAlias ??
          entry.modbusNode?.serverAlias;
    }
    return _derive(key)?.$1.serverAlias;
  }

  /// What may follow a mapped key to name one of its children: an element
  /// index first, then any mix of further indices and `.member` steps.
  static final RegExp _derivedSuffix =
      RegExp(r'^\[\d+\](?:\[\d+\]|\.[A-Za-z_][A-Za-z0-9_]*)*$');

  /// [key] read as a mapped array node plus a path into it, or null.
  ///
  /// `ECT.Diag[17].p_cmd_reset`, with `ECT.Diag` mapped to the string node
  /// `ECT_Diag.Device_1_Diag`, names `ECT_Diag.Device_1_Diag[17].p_cmd_reset`
  /// on the same server. That is how TwinCAT spells the child nodes it
  /// publishes, so a single BOOL deep in a 128-element array can be written
  /// without a key mapping of its own — and without writing the whole array
  /// back to change one bit of it.
  ///
  /// Deliberately narrow. The suffix must start with an element index, so a
  /// misspelt dotted key (`SPB01.CN01.FD01` when only `SPB01.CN01` exists)
  /// still reads as unmapped rather than as a child nobody meant. Only string
  /// identifiers qualify — a numeric node id has no path to append to — and
  /// only a mapping without an `array_index`, which already names one element.
  /// The longest mapped prefix wins. Nothing here is persisted: a derived key
  /// is a way of naming a child, not a mapping.
  (OpcUANodeConfig, String)? _derive(String key) {
    for (var i = key.lastIndexOf('['); i > 0; i = key.lastIndexOf('[', i - 1)) {
      final node = nodes[key.substring(0, i)]?.opcuaNode;
      if (node == null) continue;
      final suffix = key.substring(i);
      if (node.arrayIndex != null ||
          int.tryParse(node.identifier) != null ||
          !_derivedSuffix.hasMatch(suffix)) {
        return null;
      }
      return (node, suffix);
    }
    return null;
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

class ClientWrapper {
  final ClientApi client;
  final OpcUAConfig config;
  int? subscriptionId;
  final SingleWorker worker = SingleWorker();
  StreamSubscription? _heartbeatSub;
  int _heartbeatGeneration = 0;
  DateTime? _lastHeartbeatTick;
  Timer? _heartbeatRetryTimer;
  bool _startingHeartbeat = false;
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
    // No clock is watching this client, so "connected" is an assertion
    // nothing can ever contradict. Unhealthy immediately rather than after
    // [heartbeatStartGrace]: the grace exists for a heartbeat that is still
    // warming up, and this one is not coming.
    if (heartbeatUnavailable != null) {
      return EffectiveDeviceStatus.opcuaUnhealthy;
    }
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
    // StateMan._() installs a stateStream listener that calls this, and
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

  /// Whether a clock is currently watching this client.
  bool get hasHeartbeat => _heartbeatSub != null;

  /// Whether this client's heartbeat question has been answered either way:
  /// it has a clock, or it has reported why it cannot have one.
  ///
  /// This is what "startup has finished" means for an OPC UA client, and it
  /// is what [StateMan.connectionsSettled] waits on.
  bool get heartbeatSettled => hasHeartbeat || heartbeatUnavailable != null;

  /// Why this client has no clock watching it, or null when it has one.
  ///
  /// A client with no heartbeat is a client whose frozen session nobody can
  /// notice — see [heartbeatStaleAfter] and the note above
  /// [EffectiveDeviceStatus.opcuaUnhealthy]. That state used to be both
  /// silent and invisible; now it is neither.
  String? heartbeatUnavailable;

  /// How long to wait before trying again after a failed [ensureHeartbeat].
  ///
  /// A server that cannot give out a subscription is usually not going to
  /// manage it a second later either, and a per-client retry storm across
  /// seven endpoints is its own incident. Long enough to be cheap, short
  /// enough that a server which comes good is watched again within a minute.
  static const heartbeatRetryDelay = Duration(seconds: 30);

  /// Give this client a heartbeat, creating a subscription for it if nothing
  /// else has.
  ///
  /// # Why this is not just [startHeartbeat]
  ///
  /// Heartbeats used to start in exactly one place: the lazy path that
  /// creates a subscription the first time some *key* is monitored on this
  /// server (see StateMan's `_subscribeKey`). A client that no page happens
  /// to read from therefore never got a subscription, and so never got a
  /// heartbeat, and so had no clock watching it at all.
  ///
  /// Measured on the station that froze on 2026-09-10: seven OPC UA clients,
  /// and exactly ONE "Starting heartbeat" line in the whole run — seventeen
  /// minutes in, and only after the second engine rebuild. Six of seven
  /// clients could have been in the frozen-session state (TCP established,
  /// channel formally open, no state event ever emitted again) for the entire
  /// incident and nothing in the process would have said so, because that
  /// failure emits nothing and only a clock can notice it.
  ///
  /// So every connected client gets one, whether or not any key routes to it.
  /// The cost is one subscription and one monitored item (server time) per
  /// otherwise idle endpoint.
  Future<void> ensureHeartbeat() async {
    if (_heartbeatSub != null || _startingHeartbeat) return;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;

    final existing = subscriptionId;
    if (existing != null) {
      startHeartbeat(existing);
      return;
    }

    _startingHeartbeat = true;
    try {
      if (!await worker.doTheWork()) {
        // Subscription creation is already in flight elsewhere; that path
        // starts the heartbeat itself. If it fails, the next connect — or
        // the retry below, armed by whichever caller does fail — comes back
        // here.
        return;
      }
      try {
        // Re-checked under the worker: the key path sets subscriptionId while
        // holding it, so a subscription may have appeared while we queued.
        final created = subscriptionId ??
            await client
                .subscriptionCreate(
                  requestedPublishingInterval: config.publishingInterval,
                  requestedMaxKeepAliveCount: 30,
                )
                .timeout(const Duration(seconds: 10));
        subscriptionId = created;
        heartbeatUnavailable = null;
        startHeartbeat(created);
      } catch (e) {
        // Loud, because the consequence is invisible: this client will read
        // "connected" forever if its data plane dies, and nothing will
        // contradict it.
        heartbeatUnavailable = '$e';
        recordError('$e');
        _logger.e('[${config.endpoint}] NO HEARTBEAT: could not create a '
            'subscription to watch this client with ($e). Its session is now '
            'unmonitored — a frozen session on this server will not be '
            'detected. Retrying in ${heartbeatRetryDelay.inSeconds}s.');
        _recomputeEffectiveStatus();
        _armHeartbeatRetry();
      } finally {
        worker.complete();
      }
    } finally {
      _startingHeartbeat = false;
    }
  }

  void _armHeartbeatRetry() {
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = Timer(heartbeatRetryDelay, () {
      _heartbeatRetryTimer = null;
      if (_connectionStatus == ConnectionStatus.disconnected) return;
      unawaited(ensureHeartbeat());
    });
  }

  void startHeartbeat(int subId) {
    _heartbeatSub?.cancel();
    final serverTimeNode = NodeId.fromNumeric(0, 2258);
    // Generation counter: isolate stream cancel() is async and stale
    // callbacks can fire after stopHeartbeat(). Each callback checks
    // its captured generation against the current one.
    final gen = ++_heartbeatGeneration;
    // Clearing this changes the derived status, so push it rather than
    // leaving a client that has just been given a clock reading unhealthy
    // until the next 2 s health tick.
    final wasUnavailable = heartbeatUnavailable != null;
    heartbeatUnavailable = null;
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    if (wasUnavailable) _recomputeEffectiveStatus();
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
    _heartbeatRetryTimer?.cancel();
    _heartbeatRetryTimer = null;
    _stopHealthTimer();
    _effectiveStatus$.close();
    _connectionController.close();
  }
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

class StateMan {
  final logger = Logger();
  final StateManConfig config;
  KeyMappings keyMappings;

  /// Apply bit mask extraction to a raw [DynamicValue].
  ///
  /// Returns the original value unchanged if [bitMask] is null.
  /// Single-bit mask returns bool; multi-bit returns int.
  /// Non-numeric values pass through unchanged.
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
      return DynamicValue(value: masked != 0, typeId: NodeId.boolean);
    }
    return DynamicValue(value: masked, typeId: value.typeId);
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
  StateMan._({
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
                  'hasRawSub=${ads?._rawSub != null}');
              if (ads != null && ads._rawSub != null) {
                final oldSub = ads._rawSub;
                ads._rawSub = null;
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

          // Every connected client gets a clock, not only the ones some page
          // happens to read a key from.
          //
          // Heartbeats used to start in exactly one place: the lazy path that
          // creates a subscription the first time a KEY is monitored on this
          // server. A client no page reads from therefore never got a
          // subscription, never got a heartbeat, and had nothing watching it
          // at all. The station that froze on 2026-09-10 had seven clients
          // and produced exactly ONE "Starting heartbeat" line in the whole
          // run -- seventeen minutes in, and only after the second engine
          // rebuild. Six of seven could have sat in the frozen-session state
          // for the entire incident with nothing able to say so, because that
          // failure emits nothing at all and only a clock can notice it.
          //
          // Deliberately placed AFTER the session-loss branch above, which
          // stops the heartbeat and rebuilds it from the keys routed to this
          // server. A server with no keys has none to rebuild from, so
          // without this it would come back from a session loss permanently
          // unwatched -- the same hole, reached by a different road.
          //
          // Unawaited: this listener is synchronous, and ensureHeartbeat is
          // idempotent and guarded by the wrapper's SingleWorker against the
          // key path racing it.
          unawaited(wrapper.ensureHeartbeat());
        }
      }, onError: (e, s) {
        logger.e('[$alias] Failed to listen to state stream: $e, $s');
      });
    }
  }

  static Future<StateMan> create({
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
    final stateMan = StateMan._(
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
      ads._idleTimer?.cancel();
      ads._rawSub?.cancel();
      ads._rawSub = null;
      if (!ads._subject.isClosed) ads._subject.close();
      _unregisterStream(ads);
    }

    // Changed keys with a live OPC UA monitor: re-point the monitored item
    // in place. The AutoDisposingStream subject survives, so widgets keep
    // their stream and just start receiving values from the new node.
    final resubscribed = <String>{};
    for (final key in changed) {
      final ads = _subscriptions[key];
      if (ads == null) continue;
      ads._rawSub?.cancel();
      ads._rawSub = null;
      if (newKeyMappings.nodes[key]?.opcuaNode == null) {
        // The key switched protocols; the old OPC UA stream cannot carry
        // the new routing, so complete it like a removal. Fresh subscribes
        // route through the new protocol.
        _subscriptions.remove(key);
        ads._idleTimer?.cancel();
        if (!ads._subject.isClosed) ads._subject.close();
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
  Completer<void>? _settledCompleter;
  Timer? _settledTimer;

  /// Completes once every OPC UA client has either got a clock watching it or
  /// said why it cannot have one — that is, once this isolate has stopped
  /// bringing its connections up.
  ///
  /// The app reports this to the Windows runner as "startup complete", and
  /// the runner refuses to rebuild the engine before it. That matters because
  /// an engine rebuild destroys this isolate outright: on 2026-09-10 a
  /// teardown landed 35 s into a bring-up that was still on
  /// "ST101.PSU attempt 2", and the half-open clients it abandoned were
  /// measured afterwards as 7 sockets stuck in CLOSE_WAIT with no worker
  /// thread left alive to close them.
  ///
  /// [cap] bounds the wait: a server that never answers must delay a rebuild,
  /// but not forever. Idempotent — every caller gets the same future.
  Future<void> connectionsSettled(
      {Duration cap = const Duration(seconds: 120)}) {
    final existing = _settledCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<void>();
    _settledCompleter = completer;
    final deadline = DateTime.now().add(cap);

    void finish(String why) {
      _settledTimer?.cancel();
      _settledTimer = null;
      if (completer.isCompleted) return;
      logger.i('Connections settled: $why');
      completer.complete();
    }

    void check() {
      if (completer.isCompleted) return;
      final unsettled =
          clients.where((wrapper) => !wrapper.heartbeatSettled).toList();
      if (unsettled.isEmpty) {
        finish('${clients.length} OPC UA client(s), all with a heartbeat or a '
            'stated reason they have none');
        return;
      }
      if (!DateTime.now().isBefore(deadline)) {
        finish('gave up waiting after ${cap.inSeconds}s; still unsettled: '
            '${unsettled.map((w) => w.config.endpoint).join(', ')}');
      }
    }

    check();
    if (!completer.isCompleted) {
      _settledTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => check());
    }
    return completer.future;
  }

  Future<void> close() async {
    _shouldRun = false;
    _settledTimer?.cancel();
    _settledTimer = null;
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
      entry._rawSub?.cancel();
      entry._subject.close();
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
        _subscriptions[key]?._rawSub?.cancel();
        _subscriptions[key]?._rawSub = null;

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
        final hadPrevious = ads._rawSub != null;

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
        _subscriptions[key]?._lastRawError = null;
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
            final last = _subscriptions[key]?._lastRawError;
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

class AutoDisposingStream<T> {
  final String key;
  final ReplaySubject<T> _subject;
  final Logger _logger = Logger();
  int _listenerCount = 0;
  Timer? _idleTimer;
  StreamSubscription<T>? _rawSub;
  final Function(String key) _onDispose;
  T? _lastValue;

  /// Set once a permanent (BadNodeIdUnknown) error has been reported for this
  /// key, so the same dead mapping is not reprinted on every retry.
  bool _loggedPermanentError = false;

  /// Last error the raw stream reported, so a first-value timeout can name
  /// the server's actual complaint instead of just saying it timed out.
  String? _lastRawError;

  final Duration idleTimeout;
  AutoDisposingStream(this.key, this._onDispose,
      {this.idleTimeout = const Duration(minutes: 10)})
      : _subject = ReplaySubject<T>(maxSize: 1) {
    // Count UI listeners for idle shutdown:
    _subject
      ..onListen = _handleListen
      ..onCancel = _handleCancel;
  }

  Stream<T> get stream => _subject.stream;

  /// True once the subject is closed and this entry can never deliver again.
  ///
  /// A closed subject hands a new listener the replay buffer and then `done`,
  /// which looks to a widget exactly like a key that has stopped updating.
  /// [StateMan._monitor] checks this before reusing a cached entry.
  bool get isSpent => _subject.isClosed;

  void subscribe(Stream<T> raw, T? firstValue) {
    _logger.d('[$key] subscribe() called: '
        'subjectClosed=${_subject.isClosed}, '
        'listeners=$_listenerCount, '
        'hadRawSub=${_rawSub != null}, '
        'hasFirstValue=${firstValue != null}');
    _rawSub?.cancel();
    // wire raw → subject
    _rawSub = raw.listen(
      (value) {
        if (_subject.isClosed) {
          _logger.e(
              '[$key] RAW STREAM emitted value but subject is CLOSED — data lost!');
          return;
        }
        _lastValue = value;
        _subject.add(value);
      },
      onError: (error, stackTrace) {
        // BadNodeIdUnknown is the server's final answer: that node does not
        // exist in its address space, so every retry will get the same reply.
        // Log it once at error level and then stay quiet, rather than
        // reprinting the same dead mapping on every reconnect and burying the
        // faults that are actually actionable.
        _lastRawError = '$error';
        final permanent = '$error'.contains('BadNodeIdUnknown');
        if (permanent && _loggedPermanentError) {
          // already reported; swallow the repeat
        } else {
          _logger.e('[$key] raw stream error: $error'
              '${permanent ? " (node does not exist -- fix or remove this key "
                  "mapping; further repeats suppressed)" : ""}');
          if (permanent) _loggedPermanentError = true;
        }
        if (!_subject.isClosed) {
          _subject.addError(error, stackTrace);
        }
      },
      onDone: () {
        _logger.w('[$key] raw stream DONE — '
            'subject will close! listeners=$_listenerCount, '
            'subjectClosed=${_subject.isClosed}');
        // A spent entry must not leave an idle timer armed. _onDispose
        // removes BY KEY, so a timer surviving into the next subscription for
        // this key would evict the live entry that replaced this one, and the
        // subscriber after that would ask the PLC for four more monitored
        // items while the displaced entry kept streaming.
        _idleTimer?.cancel();
        _idleTimer = null;
        _subject.close();
        // Retire the entry as well. The idle path already does both -- it
        // calls _onDispose before closing -- but this one used to close and
        // leave the entry in StateMan._subscriptions, so the next subscriber
        // for this key was handed a closed subject and saw nothing. That is
        // what made a readout stay blank on returning to a page while
        // selecting a different key worked: the different key had no cached
        // entry to inherit.
        _onDispose(key);
      },
    );
    _lastValue = firstValue;
    if (firstValue != null) {
      if (_subject.isClosed) {
        _logger.e('[$key] subject is CLOSED, cannot add firstValue!');
      } else {
        _subject.add(firstValue);
        _logger.d('[$key] firstValue pushed to subject');
      }
    }
  }

  void _handleListen() {
    _listenerCount++;
    _idleTimer?.cancel();
    _logger.d('[$key] listener added (count=$_listenerCount)');
  }

  void _handleCancel() {
    _listenerCount--;
    _logger.d('[$key] listener removed (count=$_listenerCount)');
    // Nothing left to retire, and nothing that may outlive this entry.
    if (_subject.isClosed) return;
    if (_listenerCount == 0) {
      _logger.w(
          '[$key] no listeners left, starting ${idleTimeout.inSeconds}s idle timer');
      _idleTimer = Timer(idleTimeout, () {
        _logger.w('[$key] idle timer fired — disposing');
        _rawSub?.cancel(); // tear down the OPC-UA monitoredItem
        _onDispose(key); // remove from StateMan._subscriptions
        _subject.close(); // close the replay buffer
      });
    }
  }

  void resendLastValue() {
    // A spent entry can still be reachable from ClientWrapper.streams; adding
    // to its closed subject throws StateError, which would abort the recovery
    // loop and leave every later key on that server unrefreshed.
    if (_subject.isClosed) return;
    if (_lastValue != null) {
      _subject.add(_lastValue!);
    }
  }
}
