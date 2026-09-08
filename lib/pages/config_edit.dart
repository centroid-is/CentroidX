import 'dart:convert';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dbus/dbus.dart';
import '../dbus/config.dart';

/// Dialog-based config editor that handles JSON schema with anyOf/oneOf, references, etc.
class ConfigEditDialog extends StatefulWidget {
  final DBusClient dbusClient;
  final String serviceName;
  final String objectPath;

  const ConfigEditDialog({
    Key? key,
    required this.dbusClient,
    required this.serviceName,
    required this.objectPath,
  }) : super(key: key);

  @override
  State<ConfigEditDialog> createState() => _ConfigEditDialogState();
}

class _ConfigEditDialogState extends State<ConfigEditDialog> {
  ConfigClient? _configClient;
  bool _isLoading = true;
  String _errorMessage = '';

  /// The root schema for this config
  Map<String, dynamic>? _schema;

  /// The current data (JSON) we are editing
  dynamic _configData;

  /// Form key for validation
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _initConfigClient();
  }

  // 1) REMOVE call to _configClient?.close() so we don't disconnect system bus
  // @override
  // void dispose() {
  //   _configClient?.close(); // <--- remove this to avoid closing the system bus
  //   super.dispose();
  // }

  Future<void> _initConfigClient() async {
    try {
      final client = await ConfigClient.create(
        widget.dbusClient,
        DBusObjectPath(widget.objectPath),
        widget.serviceName,
      );
      _configClient = client;

      final schemaStr = await client.getSchema();
      final config = await client.getValueAsJson();

      setState(() {
        _schema = json.decode(schemaStr) as Map<String, dynamic>?;
        _configData = config;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to initialize config: $e';
        print(_errorMessage);
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    if (_configClient == null) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }
    try {
      await _configClient!.setValueFromJson(_configData);
      if (mounted) {
        Navigator.of(context).pop(); // close the dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Config saved successfully!')),
        );
      }
    } catch (err) {
      if (mounted) {
        print('Failed to save config: $err');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save config: $err')),
        );
      }
    }
  }

  void _cancel() {
    // Just close the dialog - do NOT close the DBus client
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return StandardDialogFrame(
        title: 'Loading config…',
        width: 640,
        showClose: false,
        actions: [PaneAction(label: 'Cancel', onPressed: _cancel)],
        child: const SizedBox(
          width: 600,
          height: 200,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_errorMessage.isNotEmpty) {
      return StandardDialogFrame(
        title: 'Error',
        icon: Icons.error_outline,
        showClose: false,
        actions: [PaneAction(label: 'Close', onPressed: _cancel)],
        child: SelectableText(_errorMessage),
      );
    }

    if (_schema == null) {
      return StandardDialogFrame(
        title: 'No schema',
        icon: Icons.help_outline,
        showClose: false,
        actions: [PaneAction(label: 'Close', onPressed: _cancel)],
        child: const Text('Schema not found or invalid.'),
      );
    }

    // Normal case: show the dynamic form
    return StandardDialogFrame(
      title: 'Configuration editor',
      icon: Icons.settings,
      width: MediaQuery.of(context).size.width * 0.8,
      height: MediaQuery.of(context).size.height * 0.8,
      showClose: false,
      scrollable: false,
      actions: [
        PaneAction(label: 'Cancel', onPressed: _cancel),
        PaneAction.primary(
          label: 'Save',
          icon: Icons.save,
          onPressed: _saveConfig,
        ),
      ],
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.8,
        height:
            MediaQuery.of(context).size.height * 0.8, // 80% of screen height
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            // Make content scrollable
            child: _buildSchemaForm(_schema!, _configData, (updated) {
              setState(() {
                _configData = updated;
              });
            }),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  //                         SCHEMA FORM BUILDING
  // ===========================================================================
  Widget _buildSchemaForm(
    Map<String, dynamic> schema,
    dynamic data,
    ValueChanged<dynamic> onChanged,
  ) {
    final type = _resolveType(schema);
    if (type == 'object') {
      if (data is! Map<String, dynamic>) data = <String, dynamic>{};
      return _buildObjectForm(schema, data, onChanged);
    } else if (type == 'array') {
      if (data is! List) data = <dynamic>[];
      return _buildArrayField('root', schema, data, false, onChanged);
    } else {
      return Text(
        'Root schema must be an object or array (found "$type").',
      );
    }
  }

  Widget _buildObjectForm(
    Map<String, dynamic> schema,
    Map<String, dynamic> data,
    ValueChanged<dynamic> onChanged,
  ) {
    final props = schema['properties'] as Map<String, dynamic>? ?? {};
    final requiredFields =
        (schema['required'] as List<dynamic>? ?? []).cast<String>();
    final description = schema['description']?.toString();

    // Skip rendering if the object is empty and has no properties
    if (data.isEmpty && props.isEmpty) {
      return const SizedBox.shrink();
    }

    final children = <Widget>[];

    // Add description row if present
    if (description != null) {
      children.add(
        Row(
          children: [
            Expanded(child: Text('Object Properties')),
            _buildInfoIcon(context, 'Object', description) ??
                const SizedBox.shrink(),
          ],
        ),
      );
    }

    props.forEach((propName, propSchemaRaw) {
      final propSchema = _resolveRef(propSchemaRaw as Map<String, dynamic>);
      final value = data[propName];
      final isRequired = requiredFields.contains(propName);

      final propertyWidget = _buildPropertyField(
        propName,
        propSchema,
        value,
        isRequired: isRequired,
        onChanged: (newVal) {
          final updatedData = Map<String, dynamic>.from(data);
          updatedData[propName] = newVal;
          onChanged(updatedData);
        },
      );

      // Only wrap object types in a Card
      if (_resolveType(propSchema) == 'object') {
        children.add(Card(
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: propertyWidget,
        ));
      } else {
        children.add(propertyWidget);
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildPropertyField(
    String fieldName,
    Map<String, dynamic> schema,
    dynamic value, {
    required bool isRequired,
    required ValueChanged<dynamic> onChanged,
  }) {
    if (schema.containsKey('oneOf')) {
      final oneOfList = schema['oneOf'] as List<dynamic>;
      return _buildOneOfField(
          fieldName, oneOfList, value, schema, isRequired, onChanged);
    }
    if (schema.containsKey('anyOf')) {
      final anyOfList = schema['anyOf'] as List<dynamic>;
      return _buildAnyOfField(
          fieldName, anyOfList, value, schema, isRequired, onChanged);
    }
    return _buildTypedField(fieldName, schema, value, isRequired, onChanged);
  }

  // -------------- oneOf Handling --------------
  Widget _buildOneOfField(
    String fieldName,
    List<dynamic> oneOfList,
    dynamic value,
    Map<String, dynamic> schema,
    bool isRequired,
    ValueChanged<dynamic> onChanged,
  ) {
    final resolvedSubSchemas = <Map<String, dynamic>>[];
    for (final item in oneOfList) {
      final subMap =
          (item is Map ? Map<String, dynamic>.from(item) : <String, dynamic>{});
      resolvedSubSchemas.add(_resolveRef(subMap));
    }

    final activeIndex = _determineOneOfActiveIndex(resolvedSubSchemas, value);
    final description = schema['description']?.toString();

    // Preserve the structure when changing values
    void wrappedOnChanged(dynamic newVal) {
      if (value is List && value.isNotEmpty && value[0] is Map) {
        final key = value[0].keys.first;
        onChanged([
          {key: newVal}
        ]);
      } else {
        onChanged(newVal);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('$fieldName (oneOf):',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (schema['description'] != null)
              _buildInfoIcon(context, fieldName, description) ??
                  const SizedBox.shrink(),
          ],
        ),
        DropdownButton<int>(
          value: activeIndex >= 0 ? activeIndex : 0,
          isExpanded: true,
          items: List.generate(resolvedSubSchemas.length, (index) {
            final sub = resolvedSubSchemas[index];
            final subDesc = _guessSubSchemaLabel(sub, index);
            return DropdownMenuItem<int>(value: index, child: Text(subDesc));
          }),
          onChanged: (val) {
            if (val != null) {
              final newSchema = resolvedSubSchemas[val];
              final newValue = _createDefaultValueForSchema(newSchema);
              onChanged({
                _guessSubSchemaLabel(resolvedSubSchemas[val], val): newValue
              });
            }
          },
        ),
        if (activeIndex >= 0 && activeIndex < resolvedSubSchemas.length)
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: _buildTypedField(
              fieldName,
              resolvedSubSchemas[activeIndex],
              value is List && value.isNotEmpty && value[0] is Map
                  ? value[0].values.first
                  : value,
              isRequired,
              wrappedOnChanged,
            ),
          ),
      ],
    );
  }

  String _guessSubSchemaLabel(Map<String, dynamic> subSchema, int index) {
    // If it's a reference, resolve it first
    final resolvedSchema = _resolveRef(subSchema);

    // Look for the required property name in the schema
    if (resolvedSchema['required'] is List) {
      final required = resolvedSchema['required'] as List;
      if (required.isNotEmpty) {
        return required.first.toString();
      }
    }

    // Fallback to title or index
    if (resolvedSchema['title'] is String) {
      return resolvedSchema['title'] as String;
    }

    return 'Option #$index';
  }

  int _determineOneOfActiveIndex(
      List<Map<String, dynamic>> subs, dynamic value) {
    if (value is Map) {
      final firstKey = value.keys.isNotEmpty ? value.keys.first : null;
      if (firstKey != null) {
        // Check each sub-schema label
        for (int i = 0; i < subs.length; i++) {
          final label = _guessSubSchemaLabel(subs[i], i);
          if (label == firstKey) return i;
        }
      }
    }
    // If we didn't find a match, default to 0
    return 0;
  }

  // -------------- anyOf Handling --------------
  Widget _buildAnyOfField(
    String fieldName,
    List<dynamic> anyOfList,
    dynamic value,
    Map<String, dynamic> parentSchema,
    bool isRequired,
    ValueChanged<dynamic> onChanged,
  ) {
    final subSchemas = <Map<String, dynamic>>[];
    for (var sub in anyOfList) {
      if (sub is Map<String, dynamic>) {
        subSchemas.add(_resolveRef(sub));
      }
    }

    final matches = _determineAnyOfMatches(subSchemas, value);
    final idx = matches.isEmpty ? 0 : matches.first;
    final description = parentSchema['description']?.toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('$fieldName (anyOf)',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (description != null)
              _buildInfoIcon(context, fieldName, description) ??
                  const SizedBox.shrink(),
          ],
        ),
        if (subSchemas.length > 1)
          DropdownButton<int>(
            value: idx,
            isExpanded: true,
            items: List.generate(subSchemas.length, (i) {
              final label = _guessSubSchemaLabel(subSchemas[i], i);
              return DropdownMenuItem<int>(
                value: i,
                child: Text(label),
              );
            }),
            onChanged: (val) {
              if (val != null) {
                final newSchema = subSchemas[val];
                final newVal = _createDefaultValueForSchema(newSchema);
                onChanged(newVal);
              }
            },
          ),
        Padding(
          padding: const EdgeInsets.only(left: 16.0),
          child: _buildTypedField(
              fieldName, subSchemas[idx], value, isRequired, onChanged),
        ),
      ],
    );
  }

  List<int> _determineAnyOfMatches(
      List<Map<String, dynamic>> subs, dynamic value) {
    final matches = <int>[];
    for (int i = 0; i < subs.length; i++) {
      final t = _resolveType(subs[i]);
      if (t == 'object' && value is Map) {
        matches.add(i);
      } else if (t == 'array' && value is List) {
        matches.add(i);
      } else if (t == 'string' && value is String) {
        matches.add(i);
      } else if ((t == 'integer' || t == 'number') && value is num) {
        matches.add(i);
      } else if (t == 'boolean' && value is bool) {
        matches.add(i);
      } else if (t == 'null' && value == null) {
        matches.add(i);
      }
    }
    return matches;
  }

  // ------------------ Build typed field from a single type ------------------
  Widget _buildTypedField(
    String fieldName,
    Map<String, dynamic> schema,
    dynamic value,
    bool isRequired,
    ValueChanged<dynamic> onChanged,
  ) {
    // Add wrapper to preserve the object structure for oneOf fields
    void wrappedOnChanged(dynamic newVal) {
      if (value is Map && value.containsKey(fieldName)) {
        final updatedValue = Map<String, dynamic>.from(value);
        updatedValue[fieldName] = newVal;
        onChanged(updatedValue);
      } else {
        onChanged(newVal);
      }
    }

    final type = _resolveType(schema);
    final readOnly = schema['readOnly'] == true;

    switch (type) {
      case 'object':
        if (value is! Map<String, dynamic>) value = <String, dynamic>{};
        // Skip the expansion tile for objects, directly show properties
        return _buildObjectForm(schema, value, wrappedOnChanged);
      case 'array':
        if (value is! List) value = <dynamic>[];
        return _buildArrayField(
            fieldName, schema, value, readOnly, wrappedOnChanged);
      case 'string':
        return _buildStringField(
            fieldName, schema, value, isRequired, readOnly, wrappedOnChanged);
      case 'boolean':
        return _buildBooleanField(
            fieldName, schema, value, readOnly, wrappedOnChanged);
      case 'number':
      case 'integer':
        return _buildNumberField(fieldName, schema, value, type, isRequired,
            readOnly, wrappedOnChanged);
      case 'null':
        return ListTile(title: Text(fieldName), subtitle: const Text('(null)'));
      default:
        return Text('$fieldName: Unsupported type "$type"');
    }
  }

  Widget _buildArrayField(
    String fieldName,
    Map<String, dynamic> schema,
    List<dynamic> value,
    bool readOnly,
    ValueChanged<dynamic> onChanged,
  ) {
    final minItems = schema['minItems'] as int? ?? 0;
    final maxItems = schema['maxItems'] as int?;
    final itemsSchema =
        _resolveRef(schema['items'] as Map<String, dynamic>? ?? {});
    final description = schema['description']?.toString();

    Widget buildItem(int index, dynamic itemValue) {
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: _buildPropertyField(
                '', // Remove the index label
                itemsSchema,
                itemValue,
                isRequired: false,
                onChanged: (newVal) {
                  value[index] = newVal;
                  onChanged(value);
                },
              ),
            ),
            if (!readOnly)
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () {
                  if (value.length > minItems) {
                    setState(() {
                      value.removeAt(index);
                    });
                    onChanged(value);
                  }
                },
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (schema['description'] != null)
          Row(
            children: [
              Expanded(child: Text(fieldName)),
              _buildInfoIcon(context, fieldName, description) ??
                  const SizedBox.shrink(),
            ],
          ),
        for (int i = 0; i < value.length; i++) buildItem(i, value[i]),
        if (!readOnly && (maxItems == null || value.length < maxItems))
          TextButton.icon(
            onPressed: () {
              final newItem = _createDefaultValueForSchema(itemsSchema);
              setState(() {
                value.add(newItem);
              });
              onChanged(value);
            },
            icon: const Icon(Icons.add),
            label: const Text('Add Item'),
          ),
      ],
    );
  }

  Widget _buildStringField(
    String fieldName,
    Map<String, dynamic> schema,
    dynamic value,
    bool isRequired,
    bool readOnly,
    ValueChanged<dynamic> onChanged,
  ) {
    final controller = TextEditingController(text: value?.toString() ?? '');
    final maxLength = schema['maxLength'] as int?;
    final minLength = schema['minLength'] as int? ?? 0;
    final pattern = schema['pattern'] as String?;
    final enumList = (schema['enum'] as List<dynamic>?)?.cast<String>();
    final description = schema['description']?.toString() ?? '';

    // If there's an enum, use a dropdown
    if (enumList != null && enumList.isNotEmpty) {
      if (!enumList.contains(value)) {
        value = enumList.first;
        onChanged(value);
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: value as String?,
                decoration: InputDecoration(
                  labelText: fieldName,
                  hintText: description,
                ),
                items: enumList
                    .map((e) => DropdownMenuItem(child: Text(e), value: e))
                    .toList(),
                onChanged: readOnly ? null : (val) => onChanged(val),
                validator: (val) {
                  if (isRequired && (val == null || val.isEmpty)) {
                    return '$fieldName is required';
                  }
                  return null;
                },
              ),
            ),
            if (description != null && description.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () {
                  showStandardDialog<void>(
                    context: context,
                    title: fieldName,
                    icon: Icons.info_outline,
                    builder: (context) => Text(description),
                  );
                },
                tooltip: description,
              ),
          ],
        ),
      );
    }

    // Otherwise, normal text
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        controller: controller,
        enabled: !readOnly,
        maxLength: maxLength,
        decoration:
            InputDecoration(labelText: fieldName, hintText: description),
        validator: (text) {
          if (isRequired && (text == null || text.isEmpty)) {
            return '$fieldName is required';
          }
          final length = text?.length ?? 0;
          if (length < minLength) {
            return 'Minimum length is $minLength';
          }
          if (maxLength != null && length > maxLength) {
            return 'Maximum length is $maxLength';
          }
          if (pattern != null && text != null) {
            final regExp = RegExp(pattern);
            if (!regExp.hasMatch(text)) {
              return 'Does not match pattern "$pattern"';
            }
          }
          return null;
        },
        onChanged: (val) => onChanged(val),
      ),
    );
  }

  Widget _buildBooleanField(
    String fieldName,
    Map<String, dynamic> schema,
    dynamic value,
    bool readOnly,
    ValueChanged<dynamic> onChanged,
  ) {
    final boolVal = value == true;
    final description = schema['description']?.toString();

    return Row(
      children: [
        Expanded(
          child:
              Text('$fieldName${description != null ? " ($description)" : ""}'),
        ),
        if (description != null)
          _buildInfoIcon(context, fieldName, description) ??
              const SizedBox.shrink(),
        Switch(
          value: boolVal,
          onChanged: readOnly ? null : (val) => onChanged(val),
        ),
      ],
    );
  }

  Widget _buildNumberField(
    String fieldName,
    Map<String, dynamic> schema,
    dynamic value,
    String fieldType,
    bool isRequired,
    bool readOnly,
    ValueChanged<dynamic> onChanged,
  ) {
    final description = schema['description']?.toString() ?? '';
    final unit = schema['unit']?.toString(); // Add unit handling

    final minimum = schema['minimum'];
    final maximum = schema['maximum'];
    final exclusiveMin = schema['exclusiveMinimum'] == true;
    final exclusiveMax = schema['exclusiveMaximum'] == true;
    final multipleOf = schema['multipleOf'];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: value?.toString() ?? '',
              enabled: !readOnly,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                // Only allow digits, decimal point, and minus sign
                FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
              ],
              decoration: InputDecoration(
                labelText: fieldName,
                hintText: description,
                suffixText: unit, // Add unit to suffix
              ),
              validator: (text) {
                if (isRequired && (text == null || text.isEmpty)) {
                  return '$fieldName is required';
                }
                if (text == null || text.isEmpty) {
                  return null;
                }

                num? parsed;
                if (fieldType == 'integer') {
                  parsed = int.tryParse(text);
                  if (parsed == null) return 'Invalid integer';
                } else {
                  parsed = double.tryParse(text);
                  if (parsed == null) return 'Invalid number';
                }

                if (minimum is num) {
                  if (exclusiveMin && parsed <= minimum) {
                    return 'Value must be > $minimum';
                  } else if (!exclusiveMin && parsed < minimum) {
                    return 'Value must be >= $minimum';
                  }
                }
                if (maximum is num) {
                  if (exclusiveMax && parsed >= maximum) {
                    return 'Value must be < $maximum';
                  } else if (!exclusiveMax && parsed > maximum) {
                    return 'Value must be <= $maximum';
                  }
                }
                if (multipleOf is num) {
                  final remainder = parsed % multipleOf;
                  if (remainder.abs() > 1e-10) {
                    return 'Value must be multiple of $multipleOf';
                  }
                }
                return null;
              },
              onChanged: (text) {
                if (text.isEmpty) {
                  onChanged(null);
                  return;
                }
                if (fieldType == 'integer') {
                  final p = int.tryParse(text);
                  onChanged(p ?? value);
                } else {
                  final p = double.tryParse(text);
                  onChanged(p ?? value);
                }
              },
            ),
          ),
          _buildInfoIcon(context, fieldName, description) ??
              const SizedBox.shrink(),
        ],
      ),
    );
  }

  // ===========================================================================
  //                           $ref RESOLUTION
  // ===========================================================================
  Map<String, dynamic> _resolveRef(Map<String, dynamic> schema) {
    // Handle allOf by merging schemas
    if (schema.containsKey('allOf')) {
      final allOf = schema['allOf'] as List;
      // Start with the base schema without allOf
      final mergedSchema = Map<String, dynamic>.from(schema)..remove('allOf');

      // Merge each schema in allOf
      for (final subSchema in allOf) {
        if (subSchema is Map<String, dynamic>) {
          // Handle $ref inside allOf
          if (subSchema.containsKey(r'$ref')) {
            final refStr = subSchema[r'$ref'] as String;
            if (refStr.startsWith('#/definitions/')) {
              final key = refStr.substring('#/definitions/'.length);
              final def = _schema?['definitions']?[key];
              if (def is Map<String, dynamic>) {
                // Merge the definition into our schema
                mergedSchema.addAll(def);
              }
            }
          } else {
            // Merge direct schema properties
            mergedSchema.addAll(subSchema);
          }
        }
      }
      return mergedSchema;
    }

    // Handle direct $ref (existing logic)
    if (schema.containsKey(r'$ref')) {
      final refStr = schema[r'$ref'] as String;
      if (refStr.startsWith('#/definitions/')) {
        final key = refStr.substring('#/definitions/'.length);
        final def = _schema?['definitions']?[key];
        if (def is Map<String, dynamic>) {
          // Merge definition with local schema
          return {...def, ...schema}..remove(r'$ref');
        }
      }
    }
    return schema;
  }

  String _resolveType(Map<String, dynamic> schema) {
    final rawType = schema['type'];
    if (rawType is String) {
      return rawType;
    }
    if (rawType is List && rawType.isNotEmpty) {
      return rawType.first;
    }
    if (schema['properties'] != null) return 'object';
    if (schema['items'] != null) return 'array';
    return 'object';
  }

  dynamic _createDefaultValueForSchema(Map<String, dynamic>? schema) {
    if (schema == null) return null;

    // If this schema has oneOf, let's default to the FIRST sub-schema
    if (schema.containsKey('oneOf')) {
      final oneOfList = schema['oneOf'] as List;
      if (oneOfList.isNotEmpty) {
        final firstSubRaw = oneOfList.first;
        if (firstSubRaw is Map<String, dynamic>) {
          final firstSubResolved = _resolveRef(firstSubRaw);
          // 1) We guess a label from the required property or the title
          final label = _guessSubSchemaLabel(firstSubResolved, 0);
          // 2) We create the child's default
          final childVal = _createDefaultValueForSchema(firstSubResolved);

          // So the default is { "NewState": {} }, for instance
          return {label: childVal};
        }
      }
      // If somehow empty, fallback to an object
      return <String, dynamic>{};
    }

    // If this schema has anyOf, you can do similarly if you want.
    if (schema.containsKey('anyOf')) {
      final anyOfList = schema['anyOf'] as List;
      if (anyOfList.isNotEmpty) {
        final firstSubRaw = anyOfList.first;
        if (firstSubRaw is Map<String, dynamic>) {
          final firstSubResolved = _resolveRef(firstSubRaw);
          final label = _guessSubSchemaLabel(firstSubResolved, 0);
          final childVal = _createDefaultValueForSchema(firstSubResolved);
          return {label: childVal};
        }
      }
      return <String, dynamic>{};
    }

    // Otherwise fallback to the original logic
    final type = _resolveType(schema);
    if (schema.containsKey('default')) return schema['default'];

    switch (type) {
      case 'object':
        return <String, dynamic>{};
      case 'array':
        return <dynamic>[];
      case 'string':
        return '';
      case 'boolean':
        return false;
      case 'integer':
      case 'number':
        return 0;
      case 'null':
        return null;
      default:
        return null;
    }
  }

  Widget? _buildInfoIcon(
      BuildContext context, String fieldName, String? description) {
    if (description == null || description.isEmpty) return null;

    return IconButton(
      icon: const Icon(Icons.info_outline),
      onPressed: () {
        showStandardDialog<void>(
          context: context,
          title: fieldName,
          icon: Icons.info_outline,
          builder: (context) => Text(description),
        );
      },
      tooltip: description, // Shows on hover
    );
  }
}
