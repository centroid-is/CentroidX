// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'state_man_types.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

OpcUAConfig _$OpcUAConfigFromJson(Map<String, dynamic> json) => OpcUAConfig()
  ..endpoint = json['endpoint'] as String
  ..username = json['username'] as String?
  ..password = json['password'] as String?
  ..sslCert = const Base64Converter().fromJson(json['ssl_cert'] as String?)
  ..sslKey = const Base64Converter().fromJson(json['ssl_key'] as String?)
  ..serverAlias = json['server_alias'] as String?
  ..enabled = json['enabled'] as bool? ?? true
  ..secureChannelLifetimeMs =
      (json['secure_channel_lifetime_ms'] as num?)?.toInt() ?? 600000
  ..publishingIntervalMs =
      (json['publishing_interval_ms'] as num?)?.toInt() ?? 100;

Map<String, dynamic> _$OpcUAConfigToJson(OpcUAConfig instance) =>
    <String, dynamic>{
      'endpoint': instance.endpoint,
      'username': instance.username,
      'password': instance.password,
      'ssl_cert': const Base64Converter().toJson(instance.sslCert),
      'ssl_key': const Base64Converter().toJson(instance.sslKey),
      'server_alias': instance.serverAlias,
      'enabled': instance.enabled,
      'secure_channel_lifetime_ms': instance.secureChannelLifetimeMs,
      'publishing_interval_ms': instance.publishingIntervalMs,
    };

M2400Config _$M2400ConfigFromJson(Map<String, dynamic> json) => M2400Config(
      type: json['type'] as String? ?? 'm2400',
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 52211,
      enabled: json['enabled'] as bool? ?? true,
    )..serverAlias = json['server_alias'] as String?;

Map<String, dynamic> _$M2400ConfigToJson(M2400Config instance) =>
    <String, dynamic>{
      'type': instance.type,
      'host': instance.host,
      'port': instance.port,
      'server_alias': instance.serverAlias,
      'enabled': instance.enabled,
    };

M2400NodeConfig _$M2400NodeConfigFromJson(Map<String, dynamic> json) =>
    M2400NodeConfig(
      recordType: $enumDecode(_$M2400RecordTypeEnumMap, json['record_type']),
      field: $enumDecodeNullable(_$M2400FieldEnumMap, json['field']),
      serverAlias: json['server_alias'] as String?,
      statusFilter: (json['status_filter'] as num?)?.toInt(),
    );

Map<String, dynamic> _$M2400NodeConfigToJson(M2400NodeConfig instance) =>
    <String, dynamic>{
      'record_type': _$M2400RecordTypeEnumMap[instance.recordType]!,
      'field': _$M2400FieldEnumMap[instance.field],
      'server_alias': instance.serverAlias,
      'status_filter': instance.statusFilter,
    };

const _$M2400RecordTypeEnumMap = {
  M2400RecordType.recWgt: 'recWgt',
  M2400RecordType.recIntro: 'recIntro',
  M2400RecordType.recStat: 'recStat',
  M2400RecordType.recLua: 'recLua',
  M2400RecordType.recBatch: 'recBatch',
  M2400RecordType.unknown: 'unknown',
};

const _$M2400FieldEnumMap = {
  M2400Field.weight: 'weight',
  M2400Field.unit: 'unit',
  M2400Field.siWeight: 'siWeight',
  M2400Field.output: 'output',
  M2400Field.material: 'material',
  M2400Field.wQuality: 'wQuality',
  M2400Field.wCount: 'wCount',
  M2400Field.length: 'length',
  M2400Field.batchId: 'batchId',
  M2400Field.status: 'status',
  M2400Field.pieces: 'pieces',
  M2400Field.msgId: 'msgId',
  M2400Field.regCmd: 'regCmd',
  M2400Field.key: 'key',
  M2400Field.devId: 'devId',
  M2400Field.devType: 'devType',
  M2400Field.devProg: 'devProg',
  M2400Field.exId: 'exId',
  M2400Field.position: 'position',
  M2400Field.errText: 'errText',
  M2400Field.buttonId: 'buttonId',
  M2400Field.idFamily: 'idFamily',
  M2400Field.tare: 'tare',
  M2400Field.barcode: 'barcode',
  M2400Field.saddles: 'saddles',
  M2400Field.nominal: 'nominal',
  M2400Field.target: 'target',
  M2400Field.fGiveaway: 'fGiveaway',
  M2400Field.vGiveaway: 'vGiveaway',
  M2400Field.tareType: 'tareType',
  M2400Field.serialNumber: 'serialNumber',
  M2400Field.stdDevA: 'stdDevA',
  M2400Field.resultCode: 'resultCode',
  M2400Field.date: 'date',
  M2400Field.time: 'time',
  M2400Field.timeMs: 'timeMs',
  M2400Field.scaleRange: 'scaleRange',
  M2400Field.weighingStatus: 'weighingStatus',
  M2400Field.programId: 'programId',
  M2400Field.programName: 'programName',
  M2400Field.minWeight: 'minWeight',
  M2400Field.maxWeight: 'maxWeight',
  M2400Field.alibi: 'alibi',
  M2400Field.division: 'division',
  M2400Field.recordId: 'recordId',
  M2400Field.rejectReason: 'rejectReason',
  M2400Field.originLabel: 'originLabel',
  M2400Field.tareDevice: 'tareDevice',
  M2400Field.tareAlibi: 'tareAlibi',
  M2400Field.packId: 'packId',
  M2400Field.checksum: 'checksum',
  M2400Field.alibiText: 'alibiText',
};

ModbusPollGroupConfig _$ModbusPollGroupConfigFromJson(
        Map<String, dynamic> json) =>
    ModbusPollGroupConfig(
      name: json['name'] as String,
      intervalMs: (json['interval_ms'] as num?)?.toInt() ?? 1000,
    );

Map<String, dynamic> _$ModbusPollGroupConfigToJson(
        ModbusPollGroupConfig instance) =>
    <String, dynamic>{
      'name': instance.name,
      'interval_ms': instance.intervalMs,
    };

ModbusConfig _$ModbusConfigFromJson(Map<String, dynamic> json) => ModbusConfig(
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 502,
      unitId: (json['unit_id'] as num?)?.toInt() ?? 1,
      serverAlias: json['server_alias'] as String?,
      pollGroups: (json['poll_groups'] as List<dynamic>?)
              ?.map((e) =>
                  ModbusPollGroupConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      umasEnabled: json['umas_enabled'] as bool? ?? false,
      endianness:
          $enumDecodeNullable(_$ModbusEndiannessEnumMap, json['endianness']) ??
              ModbusEndianness.ABCD,
      addressBase: (json['address_base'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
    );

Map<String, dynamic> _$ModbusConfigToJson(ModbusConfig instance) =>
    <String, dynamic>{
      'host': instance.host,
      'port': instance.port,
      'unit_id': instance.unitId,
      'server_alias': instance.serverAlias,
      'enabled': instance.enabled,
      'poll_groups': instance.pollGroups.map((e) => e.toJson()).toList(),
      'umas_enabled': instance.umasEnabled,
      'endianness': _$ModbusEndiannessEnumMap[instance.endianness]!,
      'address_base': instance.addressBase,
    };

const _$ModbusEndiannessEnumMap = {
  ModbusEndianness.ABCD: 'ABCD',
  ModbusEndianness.CDAB: 'CDAB',
  ModbusEndianness.BADC: 'BADC',
  ModbusEndianness.DCBA: 'DCBA',
};

ModbusNodeConfig _$ModbusNodeConfigFromJson(Map<String, dynamic> json) =>
    ModbusNodeConfig(
      serverAlias: json['server_alias'] as String?,
      registerType:
          $enumDecode(_$ModbusRegisterTypeEnumMap, json['register_type']),
      address: (json['address'] as num).toInt(),
      dataType:
          $enumDecodeNullable(_$ModbusDataTypeEnumMap, json['data_type']) ??
              ModbusDataType.uint16,
      pollGroup: json['poll_group'] as String? ?? 'default',
    );

Map<String, dynamic> _$ModbusNodeConfigToJson(ModbusNodeConfig instance) =>
    <String, dynamic>{
      'server_alias': instance.serverAlias,
      'register_type': _$ModbusRegisterTypeEnumMap[instance.registerType]!,
      'address': instance.address,
      'data_type': _$ModbusDataTypeEnumMap[instance.dataType]!,
      'poll_group': instance.pollGroup,
    };

const _$ModbusRegisterTypeEnumMap = {
  ModbusRegisterType.coil: 'coil',
  ModbusRegisterType.discreteInput: 'discreteInput',
  ModbusRegisterType.holdingRegister: 'holdingRegister',
  ModbusRegisterType.inputRegister: 'inputRegister',
};

const _$ModbusDataTypeEnumMap = {
  ModbusDataType.bit: 'bit',
  ModbusDataType.int16: 'int16',
  ModbusDataType.uint16: 'uint16',
  ModbusDataType.int32: 'int32',
  ModbusDataType.uint32: 'uint32',
  ModbusDataType.float32: 'float32',
  ModbusDataType.int64: 'int64',
  ModbusDataType.uint64: 'uint64',
  ModbusDataType.float64: 'float64',
};

StateManConfig _$StateManConfigFromJson(Map<String, dynamic> json) =>
    StateManConfig(
      opcua: (json['opcua'] as List<dynamic>)
          .map((e) => OpcUAConfig.fromJson(e as Map<String, dynamic>))
          .toList(),
      jbtm: (json['jbtm'] as List<dynamic>?)
              ?.map((e) => M2400Config.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      modbus: (json['modbus'] as List<dynamic>?)
              ?.map((e) => ModbusConfig.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );

Map<String, dynamic> _$StateManConfigToJson(StateManConfig instance) =>
    <String, dynamic>{
      'opcua': instance.opcua.map((e) => e.toJson()).toList(),
      'jbtm': instance.jbtm.map((e) => e.toJson()).toList(),
      'modbus': instance.modbus.map((e) => e.toJson()).toList(),
    };

OpcUANodeConfig _$OpcUANodeConfigFromJson(Map<String, dynamic> json) =>
    OpcUANodeConfig(
      namespace: (json['namespace'] as num).toInt(),
      identifier: json['identifier'] as String,
    )
      ..arrayIndex = (json['array_index'] as num?)?.toInt()
      ..serverAlias = json['server_alias'] as String?;

Map<String, dynamic> _$OpcUANodeConfigToJson(OpcUANodeConfig instance) =>
    <String, dynamic>{
      'namespace': instance.namespace,
      'identifier': instance.identifier,
      'array_index': instance.arrayIndex,
      'server_alias': instance.serverAlias,
    };

KeyMappingEntry _$KeyMappingEntryFromJson(Map<String, dynamic> json) =>
    KeyMappingEntry(
      opcuaNode: json['opcua_node'] == null
          ? null
          : OpcUANodeConfig.fromJson(
              json['opcua_node'] as Map<String, dynamic>),
      m2400Node: json['m2400_node'] == null
          ? null
          : M2400NodeConfig.fromJson(
              json['m2400_node'] as Map<String, dynamic>),
      modbusNode: json['modbus_node'] == null
          ? null
          : ModbusNodeConfig.fromJson(
              json['modbus_node'] as Map<String, dynamic>),
      collect: json['collect'] == null
          ? null
          : CollectEntry.fromJson(json['collect'] as Map<String, dynamic>),
      bitMask: (json['bit_mask'] as num?)?.toInt(),
      bitShift: (json['bit_shift'] as num?)?.toInt(),
      variableName: json['variable_name'] as String?,
    )..io = json['io'] as bool?;

Map<String, dynamic> _$KeyMappingEntryToJson(KeyMappingEntry instance) =>
    <String, dynamic>{
      'opcua_node': instance.opcuaNode?.toJson(),
      'm2400_node': instance.m2400Node?.toJson(),
      'modbus_node': instance.modbusNode?.toJson(),
      'io': instance.io,
      'collect': instance.collect?.toJson(),
      'bit_mask': instance.bitMask,
      'bit_shift': instance.bitShift,
      'variable_name': instance.variableName,
    };

KeyMappings _$KeyMappingsFromJson(Map<String, dynamic> json) => KeyMappings(
      nodes: (json['nodes'] as Map<String, dynamic>).map(
        (k, e) =>
            MapEntry(k, KeyMappingEntry.fromJson(e as Map<String, dynamic>)),
      ),
    );

Map<String, dynamic> _$KeyMappingsToJson(KeyMappings instance) =>
    <String, dynamic>{
      'nodes': instance.nodes.map((k, e) => MapEntry(k, e.toJson())),
    };
