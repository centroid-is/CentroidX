import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:tfc_dart/core/state_man_types.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;
import 'package:tfc_dart/core/umas_types.dart' show mapUmasDataTypeToModbus;
// `CollectEntry` only — see the note in `page_creator/assets/common.dart`.
import 'package:tfc_dart/core/collect_config.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:jbtm/src/m2400.dart' show M2400RecordType;
import 'package:jbtm/src/m2400_fields.dart'
    show M2400Field, WeigherStatus, expectedFields;
import 'package:tfc_access/tfc_access.dart' show AccessDenied;
import '../core/access_template_store.dart';
import '../providers/access_templates.dart';
import '../providers/state_man.dart';
import '../pages/key_repository.dart' show ModbusConfigListExt;
import 'opcua_array_index_field.dart';
// Narrow seam: the dialog is FFI, the NodeId it yields is not.
import 'live_browse.dart';
import 'duration_field.dart';

// ===================== OPC UA Config Section =====================

class OpcUaConfigSection extends ConsumerStatefulWidget {
  final OpcUANodeConfig config;
  final List<String> serverAliases;
  final Function(OpcUANodeConfig) onChanged;

  const OpcUaConfigSection({
    super.key,
    required this.config,
    required this.serverAliases,
    required this.onChanged,
  });

  @override
  ConsumerState<OpcUaConfigSection> createState() => _OpcUaConfigSectionState();
}

class _OpcUaConfigSectionState extends ConsumerState<OpcUaConfigSection> {
  late TextEditingController _namespaceController;
  late TextEditingController _identifierController;
  String? _selectedAlias;
  int? _selectedArrayIndex;

  @override
  void initState() {
    super.initState();
    _namespaceController =
        TextEditingController(text: widget.config.namespace.toString());
    _identifierController =
        TextEditingController(text: widget.config.identifier);
    _selectedAlias = widget.config.serverAlias;
    _selectedArrayIndex = widget.config.arrayIndex;
  }

  @override
  void dispose() {
    _namespaceController.dispose();
    _identifierController.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    final config = OpcUANodeConfig(
      namespace: int.tryParse(_namespaceController.text) ?? 0,
      identifier: _identifierController.text,
    )
      ..arrayIndex = _selectedArrayIndex
      ..serverAlias = (_selectedAlias != null && _selectedAlias!.isNotEmpty)
          ? _selectedAlias
          : null;
    widget.onChanged(config);
  }

  /// Called when namespace or identifier changes — clears the stale array index.
  void _onNodeIdentityChanged() {
    _selectedArrayIndex = null;
    _notifyChanged();
  }

  Future<void> _openBrowseDialog(BuildContext context) async {
    final stateManAsync = ref.read(stateManProvider);
    final stateMan = stateManAsync.valueOrNull;
    if (stateMan == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server connections not ready yet')),
      );
      return;
    }

    // Pre-select the currently-bound node so re-opening Browse on an
    // existing key lands on its value, not the collapsed root.
    final ns = int.tryParse(_namespaceController.text);
    final idText = _identifierController.text.trim();
    String? initialNodeId;
    if (ns != null && idText.isNotEmpty) {
      // OPC-UA NodeIds: numeric identifiers parse as `i=N`, anything else
      // is treated as a string identifier (`s=...`). The full NodeId
      // string is what `OpcUaBrowseDataSource` uses as the canonical id.
      final asInt = int.tryParse(idText);
      initialNodeId =
          asInt != null ? 'ns=$ns;i=$asInt' : 'ns=$ns;s=$idText';
    }

    final result = await browseOpcUaNode(
      context: context,
      stateMan: stateMan,
      serverAlias: _selectedAlias,
      initialNodeId: initialNodeId,
    );

    if (result != null) {
      final nodeId = result;
      setState(() {
        _namespaceController.text = nodeId.namespace.toString();
        _identifierController.text =
            nodeId.isString() ? nodeId.string : nodeId.numeric.toString();
      });
      _notifyChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.server, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('OPC UA Node Configuration',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () => _openBrowseDialog(context),
                  icon: const FaIcon(FontAwesomeIcons.sitemap, size: 14),
                  label: const Text('Browse'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Server alias dropdown
            DropdownButtonFormField<String>(
              initialValue: _selectedAlias,
              decoration: const InputDecoration(
                labelText: 'Server Alias',
                prefixIcon: FaIcon(FontAwesomeIcons.server, size: 16),
              ),
              items: [
                const DropdownMenuItem<String>(
                    value: null, child: Text('(none)')),
                ...widget.serverAliases.map((alias) =>
                    DropdownMenuItem(value: alias, child: Text(alias))),
              ],
              onChanged: (value) {
                setState(() => _selectedAlias = value);
                _notifyChanged();
              },
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 400;
                if (isNarrow) {
                  return Column(
                    children: [
                      TextField(
                        controller: _namespaceController,
                        decoration: const InputDecoration(
                          labelText: 'Namespace',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _onNodeIdentityChanged(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _identifierController,
                        decoration: const InputDecoration(
                          labelText: 'Identifier',
                        ),
                        onChanged: (_) => _onNodeIdentityChanged(),
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: _namespaceController,
                        decoration: const InputDecoration(
                          labelText: 'Namespace',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => _onNodeIdentityChanged(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _identifierController,
                        decoration: const InputDecoration(
                          labelText: 'Identifier',
                        ),
                        onChanged: (_) => _onNodeIdentityChanged(),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            OpcUaArrayIndexField(
              namespace: int.tryParse(_namespaceController.text) ?? 0,
              identifier: _identifierController.text,
              serverAlias: _selectedAlias,
              value: _selectedArrayIndex,
              onChanged: (v) {
                setState(() => _selectedArrayIndex = v);
                _notifyChanged();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== M2400 Config Section =====================

class M2400ConfigSection extends StatefulWidget {
  final M2400NodeConfig config;
  final List<String> jbtmServerAliases;
  final Function(M2400NodeConfig) onChanged;

  const M2400ConfigSection({
    super.key,
    required this.config,
    required this.jbtmServerAliases,
    required this.onChanged,
  });

  @override
  State<M2400ConfigSection> createState() => _M2400ConfigSectionState();
}

class _M2400ConfigSectionState extends State<M2400ConfigSection> {
  String? _selectedAlias;
  M2400RecordType? _selectedRecordType;
  M2400Field? _selectedField;
  int? _selectedStatusFilter;

  @override
  void initState() {
    super.initState();
    _selectedAlias = widget.config.serverAlias;
    _selectedRecordType = widget.config.recordType;
    _selectedField = widget.config.field;
    _selectedStatusFilter = widget.config.statusFilter;
  }

  void _notifyChanged() {
    final config = M2400NodeConfig(
      recordType: _selectedRecordType ?? M2400RecordType.recBatch,
      field: _selectedField,
      serverAlias: (_selectedAlias != null && _selectedAlias!.isNotEmpty)
          ? _selectedAlias
          : null,
      statusFilter: _selectedStatusFilter,
    );
    widget.onChanged(config);
  }

  List<M2400Field> _getExpectedFields(M2400RecordType? recType) {
    if (recType == null) return [];
    final expected = expectedFields[recType];
    if (expected != null) return expected.toList();
    return [];
  }

  List<M2400Field> _getOtherFields(M2400RecordType? recType) {
    if (recType == null) return M2400Field.values.toList();
    final expected = expectedFields[recType];
    if (expected == null) return M2400Field.values.toList();
    return M2400Field.values.where((f) => !expected.contains(f)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.scaleBalanced, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('M2400 Key Configuration',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Server alias dropdown (JBTM servers only)
            DropdownButtonFormField<String>(
              initialValue: _selectedAlias,
              decoration: const InputDecoration(
                labelText: 'M2400 Server',
                prefixIcon: FaIcon(FontAwesomeIcons.scaleBalanced, size: 16),
              ),
              items: [
                const DropdownMenuItem<String>(
                    value: null, child: Text('(none)')),
                ...widget.jbtmServerAliases.map((alias) =>
                    DropdownMenuItem(value: alias, child: Text(alias))),
              ],
              onChanged: (value) {
                setState(() => _selectedAlias = value);
                _notifyChanged();
              },
            ),
            const SizedBox(height: 12),
            // REC type dropdown (REQUIRED)
            DropdownButtonFormField<M2400RecordType>(
              initialValue: _selectedRecordType,
              decoration: const InputDecoration(
                labelText: 'Record Type (REC)',
                prefixIcon: FaIcon(FontAwesomeIcons.layerGroup, size: 16),
              ),
              items: M2400RecordType.values
                  .where((t) => t != M2400RecordType.unknown)
                  .map((recType) => DropdownMenuItem(
                        value: recType,
                        child: Text('${recType.name} (${recType.id})'),
                      ))
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _selectedRecordType = value;
                  // Reset field if it's not in the expected set for the new REC type
                  if (_selectedField != null && value != null) {
                    final expected = expectedFields[value];
                    if (expected != null && !expected.contains(_selectedField)) {
                      _selectedField = null;
                    }
                  }
                  // Clear status filter when switching away from BATCH
                  if (value != M2400RecordType.recBatch) {
                    _selectedStatusFilter = null;
                  }
                });
                _notifyChanged();
              },
            ),
            const SizedBox(height: 12),
            // FLD dropdown (OPTIONAL -- null means subscribe to full record)
            DropdownButtonFormField<M2400Field?>(
              key: ValueKey(_selectedField),
              initialValue: _selectedField,
              decoration: const InputDecoration(
                labelText: 'Field (FLD) -- optional',
                prefixIcon: FaIcon(FontAwesomeIcons.hashtag, size: 16),
              ),
              isExpanded: true,
              items: [
                const DropdownMenuItem<M2400Field?>(
                    value: null,
                    child: Text('(Full record -- all fields)')),
                // Expected fields for this REC type (shown first)
                ..._getExpectedFields(_selectedRecordType).map((field) =>
                    DropdownMenuItem(
                      value: field,
                      child: Text('${field.displayName} (${field.id})'),
                    )),
                // Other fields
                ..._getOtherFields(_selectedRecordType).map((field) =>
                    DropdownMenuItem(
                      value: field,
                      child: Text('${field.displayName} (${field.id})'),
                    )),
              ],
              onChanged: (value) {
                setState(() => _selectedField = value);
                _notifyChanged();
              },
            ),
            // Status filter dropdown (BATCH only)
            if (_selectedRecordType == M2400RecordType.recBatch) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                key: ValueKey(_selectedStatusFilter),
                initialValue: _selectedStatusFilter,
                decoration: const InputDecoration(
                  labelText: 'Status Filter (optional)',
                  prefixIcon: FaIcon(FontAwesomeIcons.filter, size: 16),
                ),
                isExpanded: true,
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('(No filter -- all records)')),
                  ...WeigherStatus.values
                      .where((s) => s != WeigherStatus.unknown)
                      .map((s) => DropdownMenuItem<int?>(
                            value: s.code,
                            child: Text('${s.displayName} (${s.code})'),
                          )),
                ],
                onChanged: (value) {
                  setState(() => _selectedStatusFilter = value);
                  _notifyChanged();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ===================== Key Mapping Modbus Section (TD-010) =====================

/// Thin wrapper around [ModbusConfigSection] that owns the
/// `(modbusNode, variableName)` half of a [KeyMappingEntry] and reports
/// changes back through a single [onEntryChanged] callback.
///
/// Both the Key Repository row (`lib/pages/key_repository.dart`) and the
/// Page Editor key-mapping dialog (`lib/page_creator/assets/common.dart`)
/// embed the same Modbus section with the same boilerplate:
///
///   - `onChanged: (cfg) => entry.copyWith(modbusNode: cfg)`
///   - `onPickedVariableName: (n) => n == null ? entry.copyWith(clearVariableName: true) : entry.copyWith(variableName: n)`
///
/// TD-010 (v1.1.x): hoist that wiring into one shared widget so the two
/// call sites can't drift (e.g. one site forgets to clear the variable
/// name on null, or stops propagating modbusNode edits). Both sites now
/// pass the [KeyMappingEntry] directly and absorb either kind of edit
/// via [onEntryChanged].
class KeyMappingModbusSection extends StatelessWidget {
  /// Current entry. Only its `modbusNode` and `variableName` fields are
  /// inspected/mutated by this widget — other fields pass through
  /// unchanged on every copyWith.
  final KeyMappingEntry entry;

  /// Modbus server aliases available for selection (drives the alias
  /// dropdown inside [ModbusConfigSection]).
  final List<String> modbusServerAliases;

  /// Full Modbus server configs (needed by [ModbusConfigSection] to
  /// resolve `umasEnabled` per alias and gate the picker affordance).
  final List<ModbusConfig> modbusConfigs;

  /// Fired with a fresh [KeyMappingEntry] whenever the user edits the
  /// Modbus node config OR picks/clears a UMAS variable name.
  final ValueChanged<KeyMappingEntry> onEntryChanged;

  /// Default [ModbusNodeConfig] used when the entry has no
  /// `modbusNode` yet (the Page Editor seeds entries lazily, so the
  /// wrapper must produce a sensible starting config when the user
  /// switches the protocol to Modbus).
  final ModbusNodeConfig Function() defaultNodeConfigBuilder;

  /// Optional explicit key (passed straight to [ModbusConfigSection]).
  final Key? sectionKey;

  const KeyMappingModbusSection({
    super.key,
    required this.entry,
    required this.modbusServerAliases,
    required this.modbusConfigs,
    required this.onEntryChanged,
    required this.defaultNodeConfigBuilder,
    this.sectionKey,
  });

  @override
  Widget build(BuildContext context) {
    return ModbusConfigSection(
      key: sectionKey,
      config: entry.modbusNode ?? defaultNodeConfigBuilder(),
      modbusServerAliases: modbusServerAliases,
      modbusConfigs: modbusConfigs,
      onChanged: (nodeConfig) {
        onEntryChanged(entry.copyWith(modbusNode: nodeConfig));
      },
      variableName: entry.variableName,
      onPickedVariableName: (variableName) {
        if (variableName == null || variableName.isEmpty) {
          onEntryChanged(entry.copyWith(clearVariableName: true));
        } else {
          onEntryChanged(entry.copyWith(variableName: variableName));
        }
      },
    );
  }
}

// ===================== Modbus Config Section =====================

class ModbusConfigSection extends ConsumerStatefulWidget {
  final ModbusNodeConfig config;
  final List<String> modbusServerAliases;
  final List<ModbusConfig> modbusConfigs;
  final Function(ModbusNodeConfig) onChanged;

  /// Optional: fired when the user picks a UMAS symbol from the browse
  /// dialog. The argument is the full dotted path (e.g.
  /// `B_F1_RC_01_Front` or `M_Elevator.speed`); pass null to clear a
  /// previously-picked name. Address/register/dataType continue to be
  /// updated via [onChanged] (kept for display + classic-Modbus
  /// fallback). When the picker is wired through, the runtime read
  /// path uses [variableName] instead of the address.
  final void Function(String? variableName)? onPickedVariableName;

  /// Optional: currently-selected UMAS symbol path, surfaced as a chip
  /// in the section header for transparency.
  final String? variableName;

  const ModbusConfigSection({
    super.key,
    required this.config,
    required this.modbusServerAliases,
    required this.modbusConfigs,
    required this.onChanged,
    this.onPickedVariableName,
    this.variableName,
  });

  @override
  ConsumerState<ModbusConfigSection> createState() => _ModbusConfigSectionState();
}

class _ModbusConfigSectionState extends ConsumerState<ModbusConfigSection> {
  String? _selectedAlias;
  late ModbusRegisterType _selectedRegisterType;
  late TextEditingController _addressController;
  late ModbusDataType _selectedDataType;
  late String _selectedPollGroup;

  bool get _isBooleanRegisterType =>
      _selectedRegisterType == ModbusRegisterType.coil ||
      _selectedRegisterType == ModbusRegisterType.discreteInput;

  bool get _isUmasEnabled {
    if (_selectedAlias == null) return false;
    final config = widget.modbusConfigs.findByAlias(_selectedAlias);
    return config?.umasEnabled ?? false;
  }

  /// F-5 (v1.1.x): true when the operator has bound this key to a UMAS
  /// symbol path via the Browse picker. While set, the runtime read path
  /// routes by name and ignores `address` / `registerType` / `dataType`
  /// / bitMask — so the form disables those fields with a tooltip that
  /// points the operator at the clear-X on the symbol chip. Picking
  /// `variableName == null` (chip cleared) re-enables them.
  bool get _isLockedByVariableName =>
      widget.variableName != null && widget.variableName!.isNotEmpty;

  /// Tooltip body for every disabled field — points the operator at the
  /// chip's clear-X so the field is reversibly editable.
  static const _lockedTooltip =
      'Variable name is set — runtime reads route by name and ignore '
      'this field. Clear the UMAS symbol chip (×) above to edit '
      'address-based mapping directly.';

  Future<void> _openUmasBrowseDialog(BuildContext context) async {
    final stateManAsync = ref.read(stateManProvider);
    final stateMan = stateManAsync.valueOrNull;
    if (stateMan == null) return;

    // Pre-select the bound UMAS symbol so re-opening Browse on an existing
    // key lands on its variable, not the collapsed root.
    final result = await browseUmasNode(
      context: context,
      stateMan: stateMan,
      serverAlias: _selectedAlias,
      initialPath: widget.variableName,
    );

    if (result != null) {
      final blockNo = int.tryParse(result.metadata['blockNo'] ?? '') ?? 0;
      final offset = int.tryParse(result.metadata['offset'] ?? '') ?? 0;
      final address = blockNo + offset;
      final dataTypeName = result.metadata['dataTypeName'] ?? '';
      final byteSize = int.tryParse(result.metadata['byteSize'] ?? '') ?? 2;
      // Picked symbol path (e.g. `B_F1_RC_01_Front`,
      // `M_Elevator.speed`). The runtime read path uses this when
      // umasEnabled=true; the address/register/dataType below are
      // kept as a %MW display + non-UMAS fallback.
      final pickedPath = result.metadata['path'] ?? result.id;

      setState(() {
        _addressController.text = address.toString();
        _selectedRegisterType = ModbusRegisterType.holdingRegister;
        _selectedDataType = mapUmasDataTypeToModbus(dataTypeName, byteSize);
      });
      _notifyChanged();
      // B-5 (v1.1.x): propagate the picked variableName to the parent
      // so KeyMappingEntry.variableName is set. With this in place the
      // runtime read path routes by name (B-1) — no more "verify the
      // PLC's Modbus mapping" caveat.
      if (pickedPath.isNotEmpty) {
        widget.onPickedVariableName?.call(pickedPath);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedAlias = widget.config.serverAlias;
    _selectedRegisterType = widget.config.registerType;
    _addressController =
        TextEditingController(text: widget.config.address.toString());
    _selectedDataType = widget.config.dataType;
    _selectedPollGroup = widget.config.pollGroup;
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  List<ModbusPollGroupConfig> _getAvailablePollGroups() {
    if (_selectedAlias == null) {
      return [ModbusPollGroupConfig(name: 'default', intervalMs: 1000)];
    }
    final serverConfig = widget.modbusConfigs.findByAlias(_selectedAlias);
    if (serverConfig != null && serverConfig.pollGroups.isNotEmpty) {
      return serverConfig.pollGroups;
    }
    return [ModbusPollGroupConfig(name: 'default', intervalMs: 1000)];
  }

  void _notifyChanged() {
    final config = ModbusNodeConfig(
      serverAlias: _selectedAlias,
      registerType: _selectedRegisterType,
      address: (int.tryParse(_addressController.text) ?? 0).clamp(0, 65535),
      dataType: _selectedDataType,
      pollGroup: _selectedPollGroup,
    );
    widget.onChanged(config);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.networkWired, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Modbus Key Configuration',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (_isUmasEnabled)
                  TextButton.icon(
                    onPressed: () => _openUmasBrowseDialog(context),
                    icon: const FaIcon(FontAwesomeIcons.sitemap, size: 14),
                    label: const Text('Browse'),
                  ),
              ],
            ),
            // B-5 (v1.1.x): show the picked UMAS symbol path + a clear
            // routing hint. With variableName set the runtime read path
            // ignores address/register/bit — keep them visible for
            // operator transparency / %MW fallback only.
            if (widget.variableName != null && widget.variableName!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  children: [
                    Icon(
                      Icons.label_important_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message:
                            'Picked UMAS symbol: ${widget.variableName} — will be read by name at runtime',
                        child: Text(
                          'UMAS: ${widget.variableName}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ),
                    if (widget.onPickedVariableName != null)
                      IconButton(
                        icon: const Icon(Icons.close, size: 14),
                        tooltip: 'Clear UMAS symbol (use address mapping)',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: () =>
                            widget.onPickedVariableName!(null),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // Server alias dropdown
            DropdownButtonFormField<String>(
              initialValue: _selectedAlias,
              decoration: const InputDecoration(
                labelText: 'Server Alias',
                prefixIcon: FaIcon(FontAwesomeIcons.server, size: 16),
              ),
              items: [
                const DropdownMenuItem<String>(
                    value: null, child: Text('(none)')),
                ...widget.modbusServerAliases.map((alias) =>
                    DropdownMenuItem(value: alias, child: Text(alias))),
              ],
              onChanged: (value) {
                setState(() {
                  _selectedAlias = value;
                  _selectedPollGroup = 'default';
                });
                _notifyChanged();
              },
            ),
            const SizedBox(height: 12),
            // Register type dropdown — F-5: disabled while a UMAS symbol
            // is bound (variableName != null). The runtime read path
            // ignores this field; greying it out prevents silently
            // stranded operator edits.
            Tooltip(
              message: _isLockedByVariableName ? _lockedTooltip : '',
              child: DropdownButtonFormField<ModbusRegisterType>(
                key: ValueKey(_selectedRegisterType),
                initialValue: _selectedRegisterType,
                decoration: InputDecoration(
                  labelText: _isLockedByVariableName
                      ? 'Register Type (UMAS bound)'
                      : 'Register Type',
                  prefixIcon: const FaIcon(FontAwesomeIcons.layerGroup, size: 16),
                ),
                items: ModbusRegisterType.values
                    .map((rt) => DropdownMenuItem(
                          value: rt,
                          child: Text(rt.name),
                        ))
                    .toList(),
                onChanged: _isLockedByVariableName
                    ? null
                    : (ModbusRegisterType? value) {
                        if (value == null) return;
                        setState(() {
                          _selectedRegisterType = value;
                          // Auto-lock data type for boolean register types
                          if (value == ModbusRegisterType.coil ||
                              value == ModbusRegisterType.discreteInput) {
                            _selectedDataType = ModbusDataType.bit;
                          } else if (_selectedDataType == ModbusDataType.bit) {
                            // Switching away from boolean type -- reset to default
                            _selectedDataType = ModbusDataType.uint16;
                          }
                        });
                        _notifyChanged();
                      },
              ),
            ),
            const SizedBox(height: 12),
            // Address field — F-5: disabled while a UMAS symbol is bound.
            Tooltip(
              message: _isLockedByVariableName ? _lockedTooltip : '',
              child: TextField(
                controller: _addressController,
                enabled: !_isLockedByVariableName,
                decoration: InputDecoration(
                  labelText: _isLockedByVariableName
                      ? 'Address (UMAS bound)'
                      : 'Address',
                  prefixIcon:
                      const FaIcon(FontAwesomeIcons.locationDot, size: 16),
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => _notifyChanged(),
              ),
            ),
            const SizedBox(height: 12),
            // Data type dropdown — F-5: disabled while a UMAS symbol is
            // bound; also disabled for coil/discrete input (auto-bit).
            Tooltip(
              message: _isLockedByVariableName ? _lockedTooltip : '',
              child: DropdownButtonFormField<ModbusDataType>(
                key: ValueKey(_selectedDataType),
                initialValue: _selectedDataType,
                decoration: InputDecoration(
                  labelText: _isLockedByVariableName
                      ? 'Data Type (UMAS bound)'
                      : (_isBooleanRegisterType
                          ? 'Data Type (auto)'
                          : 'Data Type'),
                  prefixIcon:
                      const FaIcon(FontAwesomeIcons.hashtag, size: 16),
                ),
                items: _isBooleanRegisterType
                    ? [
                        const DropdownMenuItem(
                            value: ModbusDataType.bit, child: Text('bit'))
                      ]
                    : ModbusDataType.values
                        .map((dt) =>
                            DropdownMenuItem(value: dt, child: Text(dt.name)))
                        .toList(),
                onChanged: (_isBooleanRegisterType || _isLockedByVariableName)
                    ? null // null disables the dropdown
                    : (value) {
                        if (value == null) return;
                        setState(() => _selectedDataType = value);
                        _notifyChanged();
                      },
              ),
            ),
            const SizedBox(height: 12),
            // Poll group dropdown
            DropdownButtonFormField<String>(
              key: ValueKey(_selectedPollGroup),
              initialValue: _selectedPollGroup,
              decoration: const InputDecoration(
                labelText: 'Poll Group',
                prefixIcon:
                    FaIcon(FontAwesomeIcons.clockRotateLeft, size: 16),
              ),
              items: _getAvailablePollGroups()
                  .map((pg) => DropdownMenuItem(
                        value: pg.name,
                        child: Text('${pg.name} (${pg.intervalMs}ms)'),
                      ))
                  .toList(),
              onChanged: _selectedAlias == null
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _selectedPollGroup = value);
                      _notifyChanged();
                    },
            ),
          ],
        ),
      ),
    );
  }
}

// ===================== Collection Config Section =====================

class CollectionConfigSection extends StatefulWidget {
  final bool enabled;
  final CollectEntry? collect;
  final String keyName;
  final Function(bool) onToggle;
  final Function(CollectEntry) onChanged;

  const CollectionConfigSection({
    super.key,
    required this.enabled,
    required this.collect,
    required this.keyName,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  State<CollectionConfigSection> createState() =>
      _CollectionConfigSectionState();
}

class _CollectionConfigSectionState extends State<CollectionConfigSection> {
  late TextEditingController _collectionNameController;
  late TextEditingController _retentionDaysController;
  late TextEditingController _sampleMembersController;

  /// Held as values, not controllers: [DurationField] owns its own text and
  /// only reports back a duration it has already parsed and clamped. Null =
  /// the collector's default cadence / no scheduled job.
  Duration? _sampleInterval;
  Duration? _scheduleInterval;

  @override
  void initState() {
    super.initState();
    final collect = widget.collect;
    _collectionNameController =
        TextEditingController(text: collect?.name ?? '');
    _sampleInterval = collect?.sampleInterval;
    _retentionDaysController = TextEditingController(
        text: collect?.retention.dropAfter.inDays.toString() ?? '365');
    _scheduleInterval = collect?.retention.scheduleInterval;
    _sampleMembersController =
        TextEditingController(text: collect?.sampleMembers?.join(', ') ?? '');
  }

  @override
  void didUpdateWidget(CollectionConfigSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reinitialize controllers when collection is toggled on with new data
    if (widget.enabled && !oldWidget.enabled) {
      final collect = widget.collect;
      _collectionNameController.text = collect?.name ?? '';
      _sampleInterval = collect?.sampleInterval;
      _retentionDaysController.text =
          collect?.retention.dropAfter.inDays.toString() ?? '365';
      _scheduleInterval = collect?.retention.scheduleInterval;
      _sampleMembersController.text = collect?.sampleMembers?.join(', ') ?? '';
    }
  }

  @override
  void dispose() {
    _collectionNameController.dispose();
    _retentionDaysController.dispose();
    _sampleMembersController.dispose();
    super.dispose();
  }

  /// One field, two layouts (narrow column / wide row) — built once so the
  /// two cannot drift.
  Widget _scheduleIntervalField() {
    return DurationField(
      value: _scheduleInterval,
      labelText: 'Schedule Interval',
      hintText: 'No schedule',
      min: const Duration(minutes: 1),
      max: const Duration(days: 7),
      units: const [
        DurationUnit.minutes,
        DurationUnit.hours,
        DurationUnit.days,
      ],
      // Serialised as whole minutes.
      resolution: const Duration(minutes: 1),
      onChanged: (v) {
        setState(() => _scheduleInterval = v);
        _notifyChanged();
      },
      // Empty means no scheduled retention job — a real state.
      onCleared: () {
        setState(() => _scheduleInterval = null);
        _notifyChanged();
      },
    );
  }

  /// What the retention field will actually be applied as, and what is wrong
  /// with what was typed.
  ///
  /// Retention is the one setting whose entire job is to delete data, and this
  /// field used to be a bare [TextField]: no formatter, no clamp, and no
  /// objection to 0 or a negative number. Typing 3651 — one day past ten years
  /// — produced a stored value that was read back as five and a quarter
  /// *seconds*, and Timescale then dropped the whole history. Typing 0 produced
  /// a policy that drops everything, and read back as a plausible-looking 0.
  ///
  /// Returns the clamped day count, and a message if the typed text was not
  /// usable as-is.
  ({int days, String? error}) _retentionFromText() {
    final text = _retentionDaysController.text.trim();
    if (text.isEmpty) {
      return (days: _defaultRetentionDays, error: null);
    }
    final parsed = int.tryParse(text);
    if (parsed == null) {
      return (
        days: _defaultRetentionDays,
        error: 'Whole number of days, 1 to $kMaxRetentionDays.'
      );
    }
    if (parsed < 1) {
      return (
        days: 1,
        error: 'Retention must be at least 1 day. '
            '0 would tell the database to delete everything.'
      );
    }
    if (parsed > kMaxRetentionDays) {
      return (
        days: kMaxRetentionDays,
        error: 'Maximum retention is $kMaxRetentionDays days (ten years). '
            'Using $kMaxRetentionDays.'
      );
    }
    return (days: parsed, error: null);
  }

  static const int _defaultRetentionDays = 365;

  /// The retention field, with the guards a delete-my-data setting needs.
  ///
  /// `digitsOnly` removes the minus sign at the source — a negative retention
  /// was accepted here and read back as a negative Duration. The helper text
  /// states the range up front, and [_retentionFromText] reports out-of-range
  /// values rather than silently substituting one, which is what made the old
  /// behaviour so hard to notice: 3651 came back as 0 days and looked fine.
  Widget _buildRetentionField() {
    final validated = _retentionFromText();
    return TextField(
      controller: _retentionDaysController,
      decoration: InputDecoration(
        labelText: 'Retention (days)',
        helperText: '1 to $kMaxRetentionDays days',
        errorText: validated.error,
        errorMaxLines: 3,
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) {
        setState(_notifyChanged);
      },
    );
  }

  void _notifyChanged() {
    final retDays = _retentionFromText().days;

    final collect = CollectEntry(
      key: widget.keyName,
      name: _collectionNameController.text.isNotEmpty
          ? _collectionNameController.text
          : null,
      sampleInterval: _sampleInterval,
      sampleMembers: () {
        final members = _sampleMembersController.text
            .split(',')
            .map((m) => m.trim())
            .where((m) => m.isNotEmpty)
            .toList();
        return members.isEmpty ? null : members;
      }(),
      retention: RetentionPolicy(
        dropAfter: Duration(days: retDays),
        scheduleInterval: _scheduleInterval,
      ),
    );
    widget.onChanged(collect);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FaIcon(FontAwesomeIcons.database, size: 16),
                const SizedBox(width: 8),
                Text('Data Collection',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                Switch(
                  value: widget.enabled,
                  onChanged: widget.onToggle,
                ),
              ],
            ),
            if (widget.enabled) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _collectionNameController,
                decoration: const InputDecoration(
                  labelText: 'Collection Name (optional)',
                ),
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 12),
              DurationField(
                value: _sampleInterval,
                labelText: 'Sample Interval',
                hintText: 'Collector default',
                min: const Duration(microseconds: 100),
                max: const Duration(minutes: 10),
                units: const [
                  DurationUnit.microseconds,
                  DurationUnit.milliseconds,
                  DurationUnit.seconds,
                ],
                onChanged: (v) {
                  setState(() => _sampleInterval = v);
                  _notifyChanged();
                },
                // Empty falls back to the collector's default cadence.
                onCleared: () {
                  setState(() => _sampleInterval = null);
                  _notifyChanged();
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _sampleMembersController,
                decoration: const InputDecoration(
                  labelText: 'Struct members (optional, comma-separated)',
                  hintText: 'e.g. p_stat_Frequency, p_stat_Current',
                  helperText: 'For struct keys: collect only these members — '
                      'one row per sample in one table, and each graph '
                      'series picks a member out of it. Dotted paths '
                      'allowed. Empty collects the whole value.',
                  helperMaxLines: 3,
                ),
                onChanged: (_) => _notifyChanged(),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 400;
                  if (isNarrow) {
                    return Column(
                      children: [
                        _buildRetentionField(),
                        const SizedBox(height: 12),
                        _scheduleIntervalField(),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildRetentionField()),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _scheduleIntervalField(),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ===================== Access Template Section =====================
//
// Spec §7b: "Binding is explicit, per key, always. No inference from asset
// type, no pattern matching on key names." This is where that one explicit act
// happens — one key, one dropdown, one row.
//
// ## Why this control writes immediately, alone among the fields on this card
//
// Every other control on a key card edits part of one JSON blob that the page
// saves as a unit, behind `configure`. A binding is not part of that blob: the
// 2026-08-30 ruling moved bindings into their own `users`-gated table
// precisely because the key-mapping preference is `configure`-classified, and
// leaving them in the blob meant somebody who can edit a page could re-scope
// who may write what — through this page's own import card, or through the raw
// preferences editor.
//
// So batching a binding into the blob's Save would leave exactly two shapes,
// both wrong: a `users` check on Save, which would refuse ordinary key editing
// to every engineer who does not hold it; or a binding write that skips the
// check, which is the hole the ruling closed. Writing straight through the
// store, at the moment the choice is made, is the only shape that keeps both
// gates honest — and it is why `_hasUnsavedChanges` never moves for a binding.

/// The section's label.
const String kKeyAccessTemplateLabel = 'Access template';

/// The "no template governs this key" entry. Named for what it *means*
/// rather than "None" alone, which reads as an omission instead of a state.
/// Since the 2026-09-02 ruling an untemplated key still needs `operate`.
const String kKeyAccessTemplateNoneLabel = 'None — Operate only';

/// A bound name with no template row behind it.
///
/// The name is still shown, because it is the thing that has to be fixed, and
/// it is marked rather than offered: an ordinary binding and a gap must not
/// read alike (T-04-03).
String kKeyAccessTemplateMissingLabel(String name) =>
    '$name — no such template';

/// No database, which is **not** "no templates".
///
/// The same distinction `kAccessTemplatesNoDatabaseNote` draws one card down: a
/// station that was never configured and one whose Postgres will not answer are
/// the same resolved null from here, and the next step is the same either way.
const String kKeyAccessTemplateNoDatabaseNote =
    'Bindings live in the database, and this station has no reachable one — so '
    'this is "cannot tell you", not "nothing is bound". The connection is set '
    'up in Server Config.';

/// A database that answered, with no templates in it. A different claim.
const String kKeyAccessTemplateNoTemplatesNote =
    'No templates exist yet, so there is nothing to bind this key to. Create '
    'one in Access templates, below.';

/// What an unbound key costs, said on the key it costs it on.
const String kKeyAccessTemplateUnboundNote =
    'Nothing governs this key: every member is writable by anybody who can '
    'reach the control.';

/// What a bound key means.
String kKeyAccessTemplateBoundNote(String name) =>
    'Writes to this key need whatever "$name" says the member needs.';

/// A dangling binding, in words. Fail-open, and therefore silent without this.
const String kKeyAccessTemplateMissingNote =
    'This key names a template that no longer exists, which resolves to no '
    'restriction at all. Bind it to one that does, or clear it.';

/// The collapsed card's badge for a key nobody bound.
///
/// Shown only when there is something to bind to — see [KeyBindingBadge].
const String kKeyBindingUnboundBadge = 'Unbound';

/// The collapsed card's badge for a dangling binding.
const String kKeyBindingMissingBadge = 'Binding missing';

/// One key's template dropdown.
Key kKeyAccessTemplateDropdownKey(String keyName) =>
    Key('key-access-template-$keyName');

/// One option inside one key's dropdown.
///
/// Keyed per key as well as per template because a `DropdownButton` keeps every
/// item in the tree (in an `IndexedStack`) whether the menu is open or not, so
/// options shared by several cards would be indistinguishable. Same reasoning
/// as `kAccessTemplateRuleGroupOptionKey`.
Key kKeyAccessTemplateOptionKey(String keyName, String? template) =>
    Key('key-access-template-$keyName-${template ?? '<none>'}');

/// One key's collapsed-card binding badge.
Key kKeyBindingBadgeKey(String keyName) => Key('key-binding-badge-$keyName');

/// What every key card needs to know about bindings, computed **once** for the
/// whole list rather than watched per card.
///
/// The key list is lazy, so a per-card `ref.watch` would only cost the cards on
/// screen — but the section header needs the same values for its unbound count,
/// and two readers of one truth is how a filter starts disagreeing with a
/// badge. One object, built in the key section's `build`, handed down.
@immutable
class KeyBindingView {
  const KeyBindingView({
    required this.store,
    required this.templateNames,
    required this.loaded,
  });

  /// Nothing is known yet. Neither "no database" nor "no templates" is true so
  /// far, and claiming either would be a guess.
  static const KeyBindingView loading =
      KeyBindingView(store: null, templateNames: [], loaded: false);

  /// The `users`-gated store, or null when this station has no database.
  final AccessTemplateStore? store;

  /// The templates that actually exist, by name, in the order the loader
  /// returned them.
  final List<String> templateNames;

  /// Whether the store handle has resolved at all.
  final bool loaded;

  /// Whether there is a table to read and to write.
  bool get available => loaded && store != null;

  /// Whether [name] names a template that exists.
  bool exists(String? name) => name != null && templateNames.contains(name);
}

/// The collapsed card's one-glance answer to "what governs this key?".
///
/// **Nothing here is painted like a fault.** An unbound key is the shipped
/// default — spec §7b: "The system therefore ships gating nothing and becomes
/// stricter only as keys are bound" — so this is information, in the muted
/// `onSurfaceVariant` the locks and the prompts already use, and not a red
/// badge that would train an operator to ignore a page full of them.
///
/// It draws **nothing at all** in two cases, and both are deliberate:
///
///  * the station has no database — "cannot tell you" must not render as
///    "unbound", which is a claim this station cannot make;
///  * no template exists yet — with nothing to bind to, an "Unbound" badge on
///    every one of two thousand cards is noise. The shipped state is reported
///    once, by the section header's count, in words that say it is the default
///    and not a fault.
class KeyBindingBadge extends StatelessWidget {
  const KeyBindingBadge({
    super.key,
    required this.keyName,
    required this.bindings,
    required this.boundTemplate,
  });

  final String keyName;
  final KeyBindingView bindings;

  /// The raw name in the table, dangling or not.
  final String? boundTemplate;

  @override
  Widget build(BuildContext context) {
    if (!bindings.available) return const SizedBox.shrink();
    final bound = boundTemplate;
    if (bound == null && bindings.templateNames.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final missing = bound != null && !bindings.exists(bound);
    final label = bound == null
        ? kKeyBindingUnboundBadge
        : (missing ? kKeyBindingMissingBadge : bound);

    return Container(
      key: kKeyBindingBadgeKey(keyName),
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          // A gap reads differently from an ordinary binding without becoming
          // an alarm: same colour, italic. Spec §7b's visibility requirement,
          // not §8's.
          fontStyle: missing ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }
}

/// The per-key binding control: a dropdown of the templates that exist, plus
/// "None", writing straight through [AccessTemplateStore].
///
/// **Never disabled.** A session without `users` opens it, picks an entry and
/// gets the shared prompt naming the group — the same posture every other
/// control in this milestone takes. Disabling it would hide the boundary
/// instead of explaining it.
class KeyAccessTemplateSection extends ConsumerWidget {
  const KeyAccessTemplateSection({
    super.key,
    required this.keyName,
    required this.bindings,
    required this.boundTemplate,
  });

  final String keyName;
  final KeyBindingView bindings;

  /// The raw name in the table, dangling or not.
  final String? boundTemplate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Nothing while the database handle resolves — not a spinner, and not the
    // no-database line, which would flash on every station that has one.
    if (!bindings.loaded) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final store = bindings.store;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.lock, size: 14),
              const SizedBox(width: 8),
              Text(kKeyAccessTemplateLabel, style: theme.textTheme.titleSmall),
              // The dropdown appears when there is something to *say*, not only
              // when there is something to pick: a key still naming a template
              // somebody deleted has to be showable and clearable even on a
              // station where no template is left at all.
              if (store != null &&
                  (bindings.templateNames.isNotEmpty ||
                      boundTemplate != null))
                // Expanded rather than a Spacer plus a fixed box: on a narrow
                // card the dropdown then shrinks instead of overflowing, and
                // on a wide one it stops growing at a width where the longest
                // entry — a dangling name plus "no such template" — still
                // reads.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _dropdown(context, ref, store),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _note(store),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// The one line under the label. Every branch is a different claim, and no
  /// two of them are the same sentence.
  String _note(AccessTemplateStore? store) {
    if (store == null) return kKeyAccessTemplateNoDatabaseNote;
    final bound = boundTemplate;
    // What the table says about *this key* comes first. A dangling binding on
    // a station whose last template was deleted would otherwise be reported as
    // "no templates exist yet", which is true and beside the point: the row is
    // still there and it is the thing to fix.
    if (bound != null) {
      return bindings.exists(bound)
          ? kKeyAccessTemplateBoundNote(bound)
          : kKeyAccessTemplateMissingNote;
    }
    if (bindings.templateNames.isEmpty) {
      return kKeyAccessTemplateNoTemplatesNote;
    }
    return kKeyAccessTemplateUnboundNote;
  }

  Widget _dropdown(
      BuildContext context, WidgetRef ref, AccessTemplateStore store) {
    final bound = boundTemplate;
    final dangling = bound != null && !bindings.exists(bound);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DropdownButton<String?>(
        key: kKeyAccessTemplateDropdownKey(keyName),
        value: bound,
        isDense: true,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: [
          DropdownMenuItem<String?>(
            key: kKeyAccessTemplateOptionKey(keyName, null),
            value: null,
            child: const Text(kKeyAccessTemplateNoneLabel,
                overflow: TextOverflow.ellipsis),
          ),
          // The dangling name gets an entry of its own so the control can show
          // what the table actually says. Without it the dropdown would fall
          // back to "None", which is a different claim and the wrong one:
          // nobody chose None, and the row is still there.
          if (dangling)
            DropdownMenuItem<String?>(
              key: kKeyAccessTemplateOptionKey(keyName, bound),
              value: bound,
              child: Text(kKeyAccessTemplateMissingLabel(bound),
                  overflow: TextOverflow.ellipsis),
            ),
          for (final name in bindings.templateNames)
            DropdownMenuItem<String?>(
              key: kKeyAccessTemplateOptionKey(keyName, name),
              value: name,
              child: Text(name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (next) =>
            _choose(ref, store, next, ScaffoldMessenger.maybeOf(context)),
      ),
    );
  }

  /// One choice, one gated write, one refresh.
  ///
  /// `AccessDenied` is swallowed on purpose. [AccessTemplateStore] calls
  /// `onDenied` before it throws, which publishes onto `accessDenialsProvider`,
  /// which `AccessDeniedPrompt` is already listening to — so by the time this
  /// catch runs the prompt naming `users` is on screen, and a message of this
  /// widget's own would be two things saying one thing. Nothing moved, so
  /// nothing is refreshed and the dropdown keeps showing the unchanged value.
  ///
  /// The same paragraph `access_templates_section.dart`'s `_write` carries; the
  /// two are separate because that file edits templates from a page and this
  /// edits one binding from a widget library, and merging them would mean
  /// importing a page into `lib/widgets`.
  Future<void> _choose(
    WidgetRef ref,
    AccessTemplateStore store,
    String? next,
    ScaffoldMessengerState? messenger,
  ) async {
    if (next == boundTemplate) return;
    try {
      if (next == null) {
        await store.unbind(keyName);
      } else {
        await store.bind(keyName, next);
      }
    } on AccessDenied {
      return;
    } on Object catch (error) {
      // Not an authorization event — a template deleted underneath us, a
      // database that went away mid-write. Say what happened rather than
      // leaving a control that appears to have done nothing.
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    // 04-05 left exactly one refresh trigger for both tables, and there is no
    // listener that would notice otherwise.
    ref.invalidate(accessTemplatesProvider);
  }
}
