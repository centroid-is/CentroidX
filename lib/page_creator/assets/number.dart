// A number assets
// Subscribe to key
// Can have label above, below, left, right
// We should have config for number of digits, size, angle, textPos and key

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'package:flutter/services.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:rxdart/rxdart.dart';

import 'common.dart';
import '../../providers/state_man.dart';
import '../../widgets/tag_access_guard.dart';
import 'package:tfc/converter/color_converter.dart';
import 'graph.dart';

part 'number.g.dart';

@JsonSerializable(explicitToJson: true)
class NumberConfig extends BaseAsset {
  @override
  String get displayName => 'Number';
  @override
  String get category => 'Text & Numbers';

  String key;
  bool showDecimalPoint;
  int decimalPlaces;
  double? scale;
  String? units; // Optional units to display after the number
  @ColorConverter()
  Color textColor;

  @JsonKey(name: 'graph_config')
  GraphAssetConfig? graphConfig;

  /// If true, number is editable by tapping it (dialog opens).
  /// When true, graphConfig must be null.
  @JsonKey(defaultValue: false)
  bool writable;

  NumberConfig({
    required this.key,
    this.showDecimalPoint = true,
    this.decimalPlaces = 2,
    this.units,
    this.textColor = Colors.black,
    this.graphConfig,
    this.scale,
    this.writable = false,
  });

  NumberConfig.preview()
      : key = "Number preview",
        showDecimalPoint = true,
        decimalPlaces = 2,
        units = "units",
        textColor = Colors.black,
        graphConfig = GraphAssetConfig.preview(),
        writable = false;

  /// How the figure reads. The tag it reads from is not here: see
  /// [AnalogBoxConfig.bulkProperties] for why keys stay in the per-asset form.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        BoolBulkProperty(
          id: 'NumberConfig.showDecimalPoint',
          label: 'Show decimal point',
          group: _bulkGroup,
          read: () => showDecimalPoint,
          apply: (value) => showDecimalPoint = value,
        ),
        NumberBulkProperty(
          id: 'NumberConfig.decimalPlaces',
          label: 'Decimal places',
          group: _bulkGroup,
          isInt: true,
          decimals: 0,
          min: 0,
          max: 6,
          read: () => decimalPlaces,
          apply: (value) => decimalPlaces = (value ?? decimalPlaces).round(),
        ),
        NumberBulkProperty(
          id: 'NumberConfig.scale',
          label: 'Scale',
          group: _bulkGroup,
          decimals: 4,
          // Null is "unscaled", which is not the same as x1 to every reader of
          // the form, so clearing the field has to be able to say so.
          nullable: true,
          read: () => scale,
          apply: (value) => scale = value?.toDouble(),
        ),
        TextBulkProperty(
          id: 'NumberConfig.units',
          label: 'Units',
          group: _bulkGroup,
          read: () => units,
          apply: (value) => units = value,
        ),
        BoolBulkProperty(
          id: 'NumberConfig.writable',
          label: 'Writable',
          group: _bulkGroup,
          read: () => writable,
          apply: (value) => writable = value,
        ),
        ColorBulkProperty(
          id: 'NumberConfig.textColor',
          label: 'Text colour',
          group: _bulkGroup,
          read: () => textColor,
          apply: (value) => textColor = value ?? textColor,
        ),
      ];

  static const String _bulkGroup = 'Number';

  factory NumberConfig.fromJson(Map<String, dynamic> json) =>
      _$NumberConfigFromJson(json);
  Map<String, dynamic> toJson() => _$NumberConfigToJson(this);

  @override
  Widget build(BuildContext context) => NumberWidget(config: this);

  @override
  Widget configure(BuildContext context) => _NumberConfigEditor(config: this);
}

class _NumberConfigEditor extends StatefulWidget {
  final NumberConfig config;
  const _NumberConfigEditor({required this.config});

  @override
  State<_NumberConfigEditor> createState() => _NumberConfigEditorState();
}

class _NumberConfigEditorState extends State<_NumberConfigEditor> {
  late TextEditingController _unitsController;
  bool showGraph = false;

  @override
  void initState() {
    super.initState();
    _unitsController = TextEditingController(text: widget.config.units);
    showGraph = widget.config.graphConfig != null;
  }

  @override
  void dispose() {
    _unitsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height:
          MediaQuery.of(context).size.height * 0.8, // Use 80% of screen height
      child: SingleChildScrollView(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LEFT COLUMN: Number config fields
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyField(
                    initialValue: widget.config.key,
                    onChanged: (value) =>
                        setState(() => widget.config.key = value),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: widget.config.text,
                    decoration: const InputDecoration(labelText: 'Label'),
                    onChanged: (value) =>
                        setState(() => widget.config.text = value),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          initialValue: widget.config.decimalPlaces.toString(),
                          decoration: const InputDecoration(
                            labelText: 'Decimal Places',
                            helperText: 'Range: 0-5',
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (value) {
                            final places = int.tryParse(value);
                            if (places != null && places >= 0 && places <= 5) {
                              setState(
                                  () => widget.config.decimalPlaces = places);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          initialValue: widget.config.scale?.toString(),
                          decoration: const InputDecoration(
                            labelText: 'Scale',
                            helperText: 'Scale the number, 1.0 is normal',
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (value) {
                            final scale = double.tryParse(value);
                            if (scale != null) {
                              setState(() => widget.config.scale = scale);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _unitsController,
                    decoration: const InputDecoration(labelText: 'Units'),
                    onChanged: (value) =>
                        setState(() => widget.config.units = value),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Show Decimal Point'),
                    value: widget.config.showDecimalPoint,
                    onChanged: (value) =>
                        setState(() => widget.config.showDecimalPoint = value),
                  ),
                  const SizedBox(height: 16),
                  DropdownButton<TextPos>(
                    value: widget.config.textPos ?? TextPos.right,
                    isExpanded: true,
                    onChanged: (value) =>
                        setState(() => widget.config.textPos = value!),
                    items: TextPos.values
                        .map((e) => DropdownMenuItem<TextPos>(
                            value: e, child: Text(e.name)))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  CoordinatesField(
                    initialValue: widget.config.coordinates,
                    onChanged: (c) =>
                        setState(() => widget.config.coordinates = c),
                    enableAngle: true,
                  ),
                  const SizedBox(height: 16),
                  SizeField(
                    initialValue: widget.config.size,
                    onChanged: (size) =>
                        setState(() => widget.config.size = size),
                  ),
                  const SizedBox(height: 16),

                  // Writable toggle (mutually exclusive with graph)
                  SwitchListTile(
                    title: const Text('Writable (tap number to edit)'),
                    subtitle: const Text('Disables graph'),
                    value: widget.config.writable,
                    onChanged: (v) => setState(() {
                      widget.config.writable = v;
                      if (v) {
                        showGraph = false;
                        widget.config.graphConfig = null;
                      }
                    }),
                  ),

                  // Graph toggle
                  SwitchListTile(
                    title: const Text('Include Graph'),
                    subtitle: const Text('Make number clickable to show graph'),
                    value: showGraph,
                    onChanged: (value) => setState(() {
                      showGraph = value;
                      if (value) {
                        widget.config.writable = false; // enforce exclusivity
                        if (widget.config.graphConfig == null) {
                          widget.config.graphConfig =
                              GraphAssetConfig.preview(key: widget.config.key);
                        }
                      } else {
                        widget.config.graphConfig = null;
                      }
                    }),
                  ),
                ],
              ),
            ),
            // RIGHT COLUMN: Graph config
            if (showGraph && widget.config.graphConfig != null)
              const SizedBox(width: 24),
            if (showGraph && widget.config.graphConfig != null)
              Expanded(
                flex: 3,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Graph Configuration',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        GraphContentConfig(config: widget.config.graphConfig!),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The text a readout actually renders: the value, and the units only when
/// there are units.
///
/// The empty string is not a unit. It read like one to `units != null`, which
/// appended the separator anyway and left a trailing space on every value. The
/// readout is laid out with `FittedBox(BoxFit.contain)`, so that space is
/// measured like any other glyph and the digits are scaled down to make room
/// for it -- around a tenth of the available width, spent on nothing, on every
/// unitless readout in the app.
String numberDisplayText(String value, String? units) =>
    (units == null || units.isEmpty) ? value : '$value $units';

class NumberWidget extends ConsumerWidget {
  final NumberConfig config;
  const NumberWidget({super.key, required this.config});

  String _formatNumber(num value) {
    if (!config.showDecimalPoint) {
      return value.toInt().toString();
    }
    if (config.scale != null) {
      value = value * config.scale!;
    }

    final formatted = value.toStringAsFixed(config.decimalPlaces);
    final parts = formatted.split('.');
    final integerPart = parts[0].padLeft(config.decimalPlaces - 1, '0');
    final decimalPart =
        parts.length > 1 ? parts[1] : '0' * config.decimalPlaces;

    return '$integerPart.$decimalPart';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (config.key == "Number preview") {
      return _buildDisplay(context, "123.45");
    }

    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.key)),
      builder: (context, snapshot) {
        String displayValue = "---";

        if (snapshot.hasData) {
          final value = snapshot.data!;
          if (value.isDouble || value.isInteger) {
            displayValue = _formatNumber(value.asDouble);
          }
        }

        return _buildDisplay(context, displayValue,
            ref: ref, rawSnapshot: snapshot.data);
      },
    );
  }

  Widget _buildDisplay(BuildContext context, String value,
      {WidgetRef? ref, DynamicValue? rawSnapshot}) {
    final displayText = numberDisplayText(value, config.units);

    // The readout is laid out at the size it is drawn at, not laid out small
    // and scaled up by a `FittedBox` -- scaling a raster made for one size is
    // what left every number on the page soft. `AutoSizedText` fits the
    // *rotated* bounding box, so a turned readout still fills its asset.
    Widget displayWidget = AutoSizedText(
      displayText,
      angleRadians: (config.coordinates.angle ?? 0) * math.pi / 180,
      style: TextStyle(
        color: config.textColor,
      ),
    );

    // Make clickable: writable OR graph (mutually exclusive in config UI)
    if (config.writable) {
      displayWidget = GestureDetector(
        onTap: () => _showWriteDialog(context, ref!),
        child: displayWidget,
      );
    } else if (config.graphConfig != null) {
      displayWidget = GestureDetector(
        onTap: () => _showGraphDialog(context),
        child: displayWidget,
      );
    }

    return displayWidget;
  }

  void _showGraphDialog(BuildContext context) =>
      showNumberGraphDialog(context, config);

  /// Writing a value stays MODAL: the operator is answering a question and
  /// the answer must land before anything else happens.
  void _showWriteDialog(BuildContext context, WidgetRef ref) {
    if (config.key == "Number preview") return;

    showDialog(
      context: context,
      builder: (_) => _NumberWriteDialog(config: config),
    );
  }
}

/// The number's trend, in a free-floating window.
///
/// This is the case the floating variant exists for: the operator wants the
/// chart AND the live number on the mimic behind it, so the window can be
/// dragged off the value it belongs to and left open.
///
/// Top-level rather than private to [NumberWidget] so other surfaces — the
/// 3rd-party side pane's trend button — can open the same window without
/// faking a tap on the readout.
void showNumberGraphDialog(BuildContext context, NumberConfig config) {
  if (config.graphConfig == null) return;
  final size = MediaQuery.of(context).size;
  showFloatingDialog(
    context: context,
    id: 'number-graph:${identityHashCode(config)}',
    title: config.graphConfig?.headerText ?? config.text ?? config.key,
    icon: Icons.show_chart,
    size: Size(size.width * 0.7, size.height * 0.7),
    scrollable: false,
    builder: (_) => _NumberGraphBody(config: config),
  );
}

class _NumberWriteDialog extends ConsumerStatefulWidget {
  final NumberConfig config;
  const _NumberWriteDialog({required this.config});

  @override
  ConsumerState<_NumberWriteDialog> createState() => _NumberWriteDialogState();
}

class _NumberWriteDialogState extends ConsumerState<_NumberWriteDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;
  bool _isInteger = false; // inferred from current value type
  double? _currentRaw; // raw value (unscaled)
  bool _hasValue = false;

  /// Subscribed once, here, not in build: an inline stream re-subscribed on
  /// every rebuild, and each re-subscribe showed the spinner in place of the
  /// field for a frame -- the field lost focus and the cursor with it.
  late final Stream<DynamicValue> _value$ = ref
      .read(stateManProvider.future)
      .asStream()
      .switchMap((sm) =>
          sm.subscribe(widget.config.key).asStream().switchMap((s) => s));

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _writeValue() async {
    final key = widget.config.key;
    if (_controller.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a value to write.')),
      );
      return;
    }

    num? parsed;
    if (_isInteger) {
      parsed = int.tryParse(_controller.text.trim());
    } else {
      parsed = double.tryParse(_controller.text.trim());
    }
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid number.')),
      );
      return;
    }

    final sm = await ref.read(stateManProvider.future);
    final dv = await sm.read(key);

    // preserve underlying type when possible
    if (_isInteger) {
      dv.value = parsed as int;
    } else {
      dv.value = parsed as double;
    }
    // No member: this writes the whole key, which is a scalar.
    final wrote = await writeTag(ref, sm, key, dv);

    // Refused: the prompt is already up, saying which permission is missing.
    // The dialog stays open with the typed value still in the field, so
    // signing in leaves the operator a field to press Enter in rather than a
    // value that was already sent on their behalf.
    if (!wrote) return;

    if (mounted) Navigator.of(context).pop();
  }

  String _formatDisplayed(double raw) {
    final scale = widget.config.scale ?? 1.0;
    final v = raw * scale;
    if (!widget.config.showDecimalPoint) {
      return v.toInt().toString();
    }
    final fixed = v.toStringAsFixed(widget.config.decimalPlaces);
    final parts = fixed.split('.');
    final integerPart = parts[0].padLeft(widget.config.decimalPlaces - 1, '0');
    final decimalPart =
        parts.length > 1 ? parts[1] : '0' * widget.config.decimalPlaces;
    return '$integerPart.$decimalPart';
  }

  @override
  Widget build(BuildContext context) {
    final value$ = _value$;

    return StandardDialogFrame(
      title: widget.config.text?.isNotEmpty == true
          ? widget.config.text!
          : widget.config.key,
      subtitle: 'Write value',
      icon: Icons.edit,
      actions: [
        PaneAction.primary(
          label: 'Write',
          icon: Icons.save,
          onPressed: () async {
            if (_formKey.currentState?.validate() == true) {
              await _writeValue();
            }
          },
        ),
      ],
      child: StreamBuilder<DynamicValue>(
        stream: value$,
        builder: (context, snap) {
          _hasValue =
              snap.hasData && (snap.data!.isDouble || snap.data!.isInteger);
          if (_hasValue) {
            _currentRaw = snap.data!.asDouble;
            _isInteger = snap.data!.isInteger;
          }

          final units = widget.config.units ?? '';
          final rawText = _hasValue
              ? _currentRaw!.toStringAsFixed(_isInteger ? 0 : 3)
              : '---';
          final displayedText =
              _hasValue ? _formatDisplayed(_currentRaw!) : '---';
          final typeText =
              _hasValue ? (_isInteger ? 'Integer' : 'Double') : 'Unknown';

          // prefill once
          if (_hasValue && _controller.text.isEmpty) {
            _controller.text = _isInteger
                ? _currentRaw!.toStringAsFixed(0)
                : _currentRaw!.toStringAsFixed(3);
          }

          final inputFormatters = <TextInputFormatter>[
            FilteringTextInputFormatter.allow(
              _isInteger ? RegExp(r'[0-9-]') : RegExp(r'[0-9\.\-]'),
            ),
          ];

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Current value card (RAW + Displayed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.speed,
                            color: Theme.of(context).primaryColor),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current (raw): $rawText ${units.isNotEmpty && widget.config.scale == null ? units : ''}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.visibility, size: 16),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Displayed: $displayedText ${units.isNotEmpty ? units : ''}',
                                    style:
                                        Theme.of(context).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                              if (widget.config.scale != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Scale: ×${widget.config.scale}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.grey[700]),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'Type: $typeText',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(fontStyle: FontStyle.italic),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Input field
                Form(
                  key: _formKey,
                  child: TextFormField(
                    controller: _controller,
                    keyboardType: TextInputType.numberWithOptions(
                      decimal: !_isInteger,
                      signed: true,
                    ),
                    inputFormatters: inputFormatters,
                    decoration: InputDecoration(
                      labelText: 'New value',
                      helperText:
                          _isInteger ? 'Enter an integer' : 'Enter a decimal',
                      suffixText: units,
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Enter a value';
                      }
                      return _isInteger
                          ? (int.tryParse(v.trim()) == null
                              ? 'Invalid integer'
                              : null)
                          : (double.tryParse(v.trim()) == null
                              ? 'Invalid number'
                              : null);
                    },
                    onFieldSubmitted: (_) async {
                      if (_formKey.currentState?.validate() == true) {
                        await _writeValue();
                      }
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// Title bar and close button come from the floating dialog now.
//
// This used to cache the GraphAsset because the floating dialog rebuilt its
// content on every drag frame and GraphAsset refetched on every rebuild —
// both fixed at the source (see `_FloatingDialogShell` and
// `graphDataSignature`), so a plain rebuild is cheap and a real config change
// now reaches the chart.
class _NumberGraphBody extends StatelessWidget {
  final NumberConfig config;
  const _NumberGraphBody({required this.config});

  @override
  Widget build(BuildContext context) {
    final gc = config.graphConfig!;
    if (gc.primarySeries.isEmpty && config.key.isNotEmpty) {
      gc.primarySeries = [GraphSeriesConfig(key: config.key, label: '')];
    }
    return GraphAsset(gc);
  }
}
