import 'dart:collection' show LinkedHashMap;

import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:open62541/open62541.dart'
    show AttributeId, DynamicValue, LocalizedText, NodeId;

import 'common.dart';
import 'ethercat_asset.dart';
import 'link_anchors.dart' show NetworkPort;
import '../../widgets/panes/pane_chrome.dart';
import '../../widgets/panes/side_pane.dart';
import '../../painter/schneider/atv320.dart';
import 'package:tfc_dart/core/state_man.dart';
import '../../providers/state_man.dart';
import '../../widgets/dynamic_value.dart';
import '../../widgets/memo_stream_builder.dart';
import '../../widgets/tag_access_guard.dart';

part 'schneider.g.dart';

@JsonSerializable(explicitToJson: true)
class SchneiderATV320Config extends EtherCatAsset {
  @override
  String get displayName => 'Schneider ATV320';

  /// The drive label is the CVS/SPB identifier on the plant pages, line break
  /// and all; bind-by-name normalises the whitespace away.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  String get ecName =>
      (label?.isNotEmpty ?? false) ? label! : (text ?? '');

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<NetworkPort> get networkPorts => kAtv320Ports;

  /// The PLC model strings this part answers to.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<String> get ecModels => const ['ATV320 EtherCAT'];
  @override
  String get category => 'Schneider Devices';

  String? label;

  /// Point size of the label drawn on the drive body. Null means the drive's
  /// default; pages saved before the field existed deserialise to that.
  double? labelFontSize;
  String? hmisKey;
  String? freqKey;
  String? configKey;

  SchneiderATV320Config({
    this.label,
    this.labelFontSize,
    this.hmisKey,
    this.freqKey,
    this.configKey,
  });

  /// The label size to paint with: the configured one held inside the range
  /// the drive can actually draw, or the default when unset.
  double get resolvedLabelFontSize => (labelFontSize ?? ATV320.defaultLabelFontSize)
      .clamp(ATV320.minLabelFontSize, ATV320.maxLabelFontSize);

  @override
  Widget build(BuildContext context) {
    return _SchneiderATV320(config: this);
  }

  @override
  Widget configure(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9;
    final maxHeight = media.height * 0.8;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          minWidth: 320,
          minHeight: 200,
        ),
        child: Material(
          borderRadius: BorderRadius.circular(24),
          color: DialogTheme.of(context).backgroundColor ??
              Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: _ATV320ConfigContent(config: this),
            ),
          ),
        ),
      ),
    );
  }

  SchneiderATV320Config.preview() : super();

  /// The drive's own settings, minus its three OPC UA keys — a row of ATV320s
  /// is exactly the selection where sharing a status key would look right on
  /// the mimic and be wrong on the floor.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        TextBulkProperty(
          id: 'SchneiderATV320Config.label',
          label: 'Drive label',
          group: _bulkGroup,
          read: () => label,
          apply: (value) => label = value,
        ),
        NumberBulkProperty(
          id: 'SchneiderATV320Config.labelFontSize',
          label: 'Label font size',
          group: _bulkGroup,
          unit: 'pt',
          decimals: 1,
          min: ATV320.minLabelFontSize,
          max: ATV320.maxLabelFontSize,
          // Null is "the drive's default", which is what every page saved
          // before the field existed holds; clearing the row restores it.
          nullable: true,
          read: () => labelFontSize,
          apply: (value) => labelFontSize = value?.toDouble(),
        ),
      ];

  static const String _bulkGroup = 'Schneider ATV320';

  factory SchneiderATV320Config.fromJson(Map<String, dynamic> json) =>
      _$SchneiderATV320ConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$SchneiderATV320ConfigToJson(this);
}

class _ATV320ConfigContent extends StatefulWidget {
  final SchneiderATV320Config config;

  const _ATV320ConfigContent({required this.config});

  @override
  State<_ATV320ConfigContent> createState() => _ATV320ConfigContentState();
}

class _ATV320ConfigContentState extends State<_ATV320ConfigContent> {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizeField(
          initialValue: widget.config.size,
          onChanged: (size) => widget.config.size = size,
        ),
        const SizedBox(height: 16),
        CoordinatesField(
          initialValue: widget.config.coordinates,
          onChanged: (coordinates) => widget.config.coordinates = coordinates,
          enableAngle: true,
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: widget.config.label,
          onChanged: (value) => widget.config.label = value,
          // Multiline so the operator can press Enter to break the inline
          // label onto a second line (the drive draws at most two).
          keyboardType: TextInputType.multiline,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Label',
            helperText: 'Enter breaks the label onto a new line (max 2 shown)',
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          initialValue: widget.config.labelFontSize?.toString() ?? '',
          onChanged: (value) {
            final trimmed = value.trim();
            // Blank clears back to the drive's own default rather than
            // pinning the label at whatever half-typed number was left.
            widget.config.labelFontSize = trimmed.isEmpty
                ? null
                : double.tryParse(trimmed)?.clamp(
                    ATV320.minLabelFontSize,
                    ATV320.maxLabelFontSize,
                  );
          },
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Label text size',
            helperText: 'Blank uses the default '
                '(${ATV320.defaultLabelFontSize}); '
                '${ATV320.minLabelFontSize}-${ATV320.maxLabelFontSize}. '
                'Bigger text fits fewer characters per line.',
          ),
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.hmisKey,
          onChanged: (value) => widget.config.hmisKey = value,
          label: 'HMIS Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.freqKey,
          onChanged: (value) => widget.config.freqKey = value,
          label: 'Frequency Key',
        ),
        const SizedBox(height: 16),
        KeyField(
          initialValue: widget.config.configKey,
          onChanged: (value) => widget.config.configKey = value,
          label: 'Configuration Key',
        ),
      ],
    );
  }
}

class _SchneiderATV320 extends ConsumerWidget {
  final SchneiderATV320Config config;

  const _SchneiderATV320({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<StateMan>(
      future: ref.watch(stateManProvider.future),
      builder: (context, snap) {
        final stateMan = snap.data;

        return MemoStreamBuilder<Map<String, DynamicValue>>(
          keys: [stateMan, config],
          stream: (stateMan == null)
              ? const Stream.empty()
              : _combinedStream(
                  LinkedHashMap.fromEntries([
                    MapEntry("hmis", config.hmisKey),
                    MapEntry("freq", config.freqKey),
                  ]),
                  ref,
                ),
          builder: (context, s) {
            final data = (s.hasData && !s.hasError) ? s.data! : null;

            // Determine display text based on frequency value
            String displayText = '';
            String topLabel = config.label ?? '';

            if (data != null) {
              final freqValue = data["freq"]?.asDouble ?? 0;
              if (freqValue > 0.01) {
                displayText = freqValue.toStringAsFixed(1);
              } else if (data["hmis"]?.asString != null) {
                final hmisValue = data["hmis"]!.asInt;
                final enumFields = data["hmis"]!.enumFields;
                displayText = data["hmis"]!
                        .enumFields?[data["hmis"]!.asInt]
                        ?.displayName
                        .value ??
                    "";
              }
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (stateMan == null || config.configKey == null) return;
                showSidePane(
                  context: context,
                  id: 'atv320:${identityHashCode(config)}',
                  builder: (_) => _ATV320ConfigPane(
                    configKey: config.configKey!,
                    stateMan: stateMan,
                  ),
                );
              },
              child: ATV320Widget(
                name: "ATV320",
                displayText: displayText,
                topLabel: topLabel,
                labelFontSize: config.resolvedLabelFontSize,
              ),
            );
          },
        );
      },
    );
  }
}

/// The single member of [after] that differs from [before], or null when none
/// or several do.
///
/// The ATV320 pane writes the whole parameter struct back, so the member a
/// template's rules are written against is invisible at the write. This reads
/// it at the **edit**, where `DynamicValueWidget` hands back the value it was
/// rendered from with exactly one member replaced.
///
/// Compared by rendered form rather than by `==`: `DynamicValue` defines no
/// equality, so two structurally identical values are never equal and an
/// identity comparison would report every member as changed — and therefore
/// answer null on every real edit. `toString` walks the whole value, which is
/// what makes a nested parameter answer with the top-level member containing
/// it, and the top level is what a template names.
///
/// **Null is the safe answer, not a failure.** It asks about the key as a
/// whole — a template's `*` row — which can only be broader than the member
/// rule, never narrower. Top-level and named so the answer is pinned by
/// `schneider_changed_member_test.dart` rather than trusted: a member that
/// does not match the struct's key silently means "unrestricted".
String? atv320ChangedMember(DynamicValue before, DynamicValue after) {
  if (!before.isObject || !after.isObject) return null;
  String? changed;
  for (final entry in after.asObject.entries) {
    if (!before.contains(entry.key)) return null;
    if (before[entry.key].toString() == entry.value.toString()) continue;
    if (changed != null) return null;
    changed = entry.key;
  }
  return changed;
}

/// The drive's parameter surface.
///
/// A docked pane rather than a dialog: commissioning an ATV320 means reading
/// a parameter, watching what the motor does, then reading the next one — and
/// the old modal covered the very mimic that shows it. `Write` stays pinned
/// in the footer so it cannot scroll out of reach of a long parameter list.
///
/// A `ConsumerStatefulWidget` rather than a plain one, because `Write` asks
/// `writeTag` whether this session may set the parameter it is about to send,
/// and that question needs a `WidgetRef`.
class _ATV320ConfigPane extends ConsumerStatefulWidget {
  final String configKey;
  final StateMan stateMan;

  const _ATV320ConfigPane({
    required this.configKey,
    required this.stateMan,
  });

  @override
  ConsumerState<_ATV320ConfigPane> createState() => _ATV320ConfigPaneState();
}

class _ATV320ConfigPaneState extends ConsumerState<_ATV320ConfigPane> {
  DynamicValue? _pendingConfigValue;

  /// Which member [_pendingConfigValue] changes, or null when that cannot be
  /// told — and it is the member a template's rules are written against.
  ///
  /// This pane writes the **whole** parameter struct back, so the member is
  /// not visible at the write. It is visible at the edit: [DynamicValueWidget]
  /// is rebuilt from the live value every frame and hands back that same value
  /// with exactly one member replaced, so the member is whichever one differs
  /// from what was rendered. Captured there rather than recomputed here,
  /// because "what was rendered" is gone by the time `Write` is pressed.
  ///
  /// Null when nothing or more than one member differs. That asks about the
  /// key as a whole — a template's `*` row — which is the answer that cannot
  /// be wrong, only broader.
  String? _pendingMember;

  /// browseName -> {displayName, description} from OPC UA browse
  Map<String, ({String? displayName, String? description})>? _fieldMeta;

  @override
  void initState() {
    super.initState();
    _fetchFieldDescriptions();
  }

  Future<void> _fetchFieldDescriptions() async {
    try {
      final stateMan = widget.stateMan;
      final key = stateMan.resolveKey(widget.configKey);
      final nodeIdResult = stateMan.keyMappings.lookupNodeId(key);
      if (nodeIdResult == null) return;
      final (nodeId, _) = nodeIdResult;

      final alias = stateMan.keyMappings.lookupServerAlias(key);
      final wrapper = stateMan.clients.firstWhere(
        (w) => w.config.serverAlias == alias,
      );
      await wrapper.client.awaitConnect();

      final children = await wrapper.client.browse(nodeId);

      // Batch read descriptions for all children
      final readParams = <NodeId, List<AttributeId>>{};
      for (final child in children) {
        readParams[child.nodeId] = [
          AttributeId.UA_ATTRIBUTEID_DESCRIPTION,
          AttributeId.UA_ATTRIBUTEID_DISPLAYNAME,
        ];
      }
      final results = await wrapper.client.readAttribute(readParams);

      final meta = <String, ({String? displayName, String? description})>{};
      for (final child in children) {
        final val = results[child.nodeId];
        meta[child.browseName] = (
          displayName: val?.displayName?.value,
          description: val?.description?.value,
        );
      }

      if (mounted) {
        setState(() => _fieldMeta = meta);
      }
    } catch (e) {
      debugPrint('Failed to fetch field descriptions: $e');
    }
  }

  /// Apply browsed descriptions onto DynamicValue children
  DynamicValue _enrichWithDescriptions(DynamicValue value) {
    if (_fieldMeta == null || !value.isObject) return value;
    final enriched = DynamicValue.from(value);
    for (final entry in enriched.asObject.entries) {
      final meta = _fieldMeta![entry.key];
      if (meta == null) continue;
      if (meta.description != null && meta.description!.isNotEmpty) {
        entry.value.description = LocalizedText(meta.description!, '');
      }
      if (meta.displayName != null && meta.displayName!.isNotEmpty) {
        entry.value.displayName = LocalizedText(meta.displayName!, '');
      }
    }
    return enriched;
  }

  Future<void> _write() async {
    final pending = _pendingConfigValue;
    if (pending == null) return;
    try {
      // The member the edit changed, so a template can say that this one
      // parameter needs `device` while the rest of the struct does not. A
      // whole-struct write with no member asks only the key-level rule, and on
      // a drive that is the difference between "commission the motor" and
      // "nudge one setpoint".
      final wrote = await writeTag(
        ref,
        widget.stateMan,
        widget.configKey,
        pending,
        member: _pendingMember,
      );
      if (!mounted) return;
      // A refusal keeps the edit. The operator has been told what permission
      // is missing; throwing their parameter away as well would mean typing it
      // again after signing in.
      if (!wrote) return;
      setState(() {
        _pendingConfigValue = null;
        _pendingMember = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration updated successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error updating configuration: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SidePane(
      title: 'ATV320',
      subtitle: widget.configKey,
      icon: Icons.settings_input_component,
      status: _pendingConfigValue != null
          ? const PaneStatus.warning('Unwritten changes')
          : const PaneStatus.running('Live'),
      actions: [
        PaneAction.primary(
          label: 'Write',
          icon: Icons.upload,
          // Disabled until something is actually edited — the drive should
          // never take a write the operator did not ask for.
          onPressed: _pendingConfigValue != null ? _write : null,
        ),
      ],
      child: StreamBuilder<DynamicValue>(
        stream: widget.stateMan
            .subscribe(widget.configKey)
            .asStream()
            .asyncExpand((s) => s),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.hasError) {
            return const PaneSection(
              child: Text('No configuration data available'),
            );
          }
          final rendered = _enrichWithDescriptions(snapshot.data!);
          return PaneSection(
            title: 'Parameters',
            child: DynamicValueWidget(
              value: rendered,
              onSubmitted: (newValue) {
                setState(() {
                  _pendingConfigValue = newValue;
                  // The member is only knowable here, against the value that
                  // was on screen — see [_pendingMember].
                  _pendingMember = atv320ChangedMember(rendered, newValue);
                });
              },
            ),
          );
        },
      ),
    );
  }
}

/// The named keys of one module, combined.
///
/// Reads each key through [keyStreamProvider] rather than subscribing here.
/// These modules are page assets, so this runs on every rebuild — and a fresh
/// `subscribe` per rebuild is a monitored-item create-and-cancel per frame
/// while a window is being dragged. The per-key streams are shared and stable
/// now; only the combination of them is rebuilt, which costs nothing.
CombineLatestStream<DynamicValue, Map<String, DynamicValue>> _combinedStream(
    LinkedHashMap<String, String?> keys, WidgetRef ref) {
  return CombineLatestStream([
    for (var entry in keys.entries)
      if (entry.value != null) ref.watch(keyStreamProvider(entry.value!)),
  ], (values) {
    final map = <String, DynamicValue>{};
    int i = 0;
    for (var entry in keys.entries) {
      if (entry.value != null) {
        map[entry.key] = values[i++];
      }
    }
    return map;
  });
}
