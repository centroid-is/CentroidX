import 'dart:collection';

import 'package:json_annotation/json_annotation.dart';

import 'package:open62541/open62541_types.dart'
    show DynamicValue, NodeId, LocalizedText, EnumField;

// JSON converter for DynamicValue
class DynamicValueConverter implements JsonConverter<DynamicValue, dynamic> {
  const DynamicValueConverter();

  @override
  DynamicValue fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) {
      throw FormatException('Invalid DynamicValue format: $json');
    }
    final type = json['type'] as String;
    final value = json['value'];
    final typeId = json['typeId'] != null
        ? const NodeIdConverter().fromJson(json['typeId'] as String)
        : null;
    final displayName = json['displayName'] != null
        ? const LocalizedTextConverter()
            .fromJson(json['displayName'] as Map<String, dynamic>)
        : null;
    final description = json['description'] != null
        ? const LocalizedTextConverter()
            .fromJson(json['description'] as Map<String, dynamic>)
        : null;
    final enumFields = json['enumFields'] != null
        ? (json['enumFields'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(
              int.parse(k),
              const EnumFieldConverter().fromJson(v as Map<String, dynamic>),
            ),
          )
        : null;

    DynamicValue result;
    switch (type) {
      case 'null':
        result = DynamicValue();
        break;
      case 'object':
        final map = (value as LinkedHashMap<String, dynamic>).map(
          (k, v) => MapEntry(
              k,
              const DynamicValueConverter()
                  .fromJson(v as LinkedHashMap<String, dynamic>)),
        );
        result = DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from(map));
        break;
      case 'array':
        final list = (value as List)
            .map(
              (v) => const DynamicValueConverter()
                  .fromJson(v as Map<String, dynamic>),
            )
            .toList();
        result = DynamicValue.fromList(list);
        break;
      case 'string':
        result = DynamicValue(value: value as String);
        break;
      case 'integer':
        result = DynamicValue(value: value as int);
        break;
      case 'double':
        result = DynamicValue(value: value as double);
        break;
      case 'boolean':
        result = DynamicValue(value: value as bool);
        break;
      default:
        result = DynamicValue(value: value);
    }

    result.typeId = typeId;
    result.displayName = displayName;
    result.description = description;
    result.enumFields = enumFields;
    return result;
  }

  @override
  dynamic toJson(DynamicValue value, {bool slim = false}) {
    dynamic serializedValue;
    String type;

    if (value.isNull) {
      serializedValue = null;
      type = 'null';
    } else if (value.isObject) {
      serializedValue = value.asObject.map((k, v) =>
          MapEntry(k, const DynamicValueConverter().toJson(v, slim: slim)));
      type = 'object';
    } else if (value.isArray) {
      serializedValue = value.asArray
          .map((v) => const DynamicValueConverter().toJson(v, slim: slim))
          .toList();
      type = 'array';
    } else if (value.isString) {
      serializedValue = value.asString;
      type = 'string';
    } else if (value.isInteger) {
      serializedValue = value.asInt;
      type = 'integer';
    } else if (value.isDouble) {
      serializedValue = value.asDouble;
      type = 'double';
    } else if (value.isBoolean) {
      serializedValue = value.asBool;
      type = 'boolean';
    } else {
      serializedValue = value.value.toString();
      type = 'unknown';
    }

    // Slim mode: only return the value
    if (slim) {
      return serializedValue;
    }

    // Full serialization: include metadata and type
    final base = {
      if (value.typeId != null)
        'typeId': const NodeIdConverter().toJson(value.typeId!),
      if (value.displayName != null)
        'displayName':
            const LocalizedTextConverter().toJson(value.displayName!),
      if (value.description != null)
        'description':
            const LocalizedTextConverter().toJson(value.description!),
      if (value.enumFields != null)
        'enumFields': value.enumFields!.map(
          (k, v) =>
              MapEntry(k.toString(), const EnumFieldConverter().toJson(v)),
        ),
    };

    return {...base, 'type': type, 'value': serializedValue};
  }
}

// JSON converter for NodeId
class NodeIdConverter implements JsonConverter<NodeId, String> {
  const NodeIdConverter();

  @override
  NodeId fromJson(String json) {
    // Parse strings like "ns=1;s=SomeString" or "ns=0;i=42"
    final parts = json.split(';');
    if (parts.length != 2) {
      throw FormatException('Invalid NodeId format: $json');
    }

    final nsPart = parts[0];
    final idPart = parts[1];

    if (!nsPart.startsWith('ns=')) {
      throw FormatException('Invalid namespace format: $nsPart');
    }
    final nsIndex = int.parse(nsPart.substring(3));

    if (idPart.startsWith('s=')) {
      return NodeId.fromString(nsIndex, idPart.substring(2));
    } else if (idPart.startsWith('i=')) {
      return NodeId.fromNumeric(nsIndex, int.parse(idPart.substring(2)));
    } else {
      throw FormatException('Invalid identifier format: $idPart');
    }
  }

  @override
  String toJson(NodeId nodeId) => nodeId.toString();
}

// JSON converter for LocalizedText
class LocalizedTextConverter
    implements JsonConverter<LocalizedText, Map<String, dynamic>> {
  const LocalizedTextConverter();

  @override
  LocalizedText fromJson(Map<String, dynamic> json) {
    return LocalizedText(
      json['value'] as String,
      json['locale'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson(LocalizedText text) {
    return {
      'value': text.value,
      'locale': text.locale,
    };
  }
}

// JSON converter for EnumField
class EnumFieldConverter
    implements JsonConverter<EnumField, Map<String, dynamic>> {
  const EnumFieldConverter();

  @override
  EnumField fromJson(Map<String, dynamic> json) {
    return EnumField(
      json['value'] as int,
      json['name'] as String,
      const LocalizedTextConverter()
          .fromJson(json['displayName'] as Map<String, dynamic>),
      const LocalizedTextConverter()
          .fromJson(json['description'] as Map<String, dynamic>),
    );
  }

  @override
  Map<String, dynamic> toJson(EnumField field) {
    return {
      'value': field.value,
      'name': field.name,
      'displayName': const LocalizedTextConverter().toJson(field.displayName),
      'description': const LocalizedTextConverter().toJson(field.description),
    };
  }
}
