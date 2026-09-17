import 'dart:math';

import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc/converter/color_converter.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/theme.dart' show HmiColorRole;

part 'speedbatcher.g.dart';

@JsonSerializable(explicitToJson: true)
class SpeedBatcherConfig extends BaseAsset {
  @override
  String get displayName => 'Speed Batcher';
  @override
  String get category => 'Application';

  String label;
  String key;

  SpeedBatcherConfig({
    required this.label,
    required this.key,
  });

  // Preview constructor: just shows text
  SpeedBatcherConfig.preview()
      : label = "SpeedBatcher preview",
        key = "";

  factory SpeedBatcherConfig.fromJson(Map<String, dynamic> json) =>
      _$SpeedBatcherConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$SpeedBatcherConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return SpeedBatcher(config: this);
  }

  @override
  Widget configure(BuildContext context) =>
      _SpeedBatcherConfigEditor(config: this);
}

class _SpeedBatcherConfigEditor extends StatefulWidget {
  final SpeedBatcherConfig config;
  const _SpeedBatcherConfigEditor({required this.config});

  @override
  State<_SpeedBatcherConfigEditor> createState() =>
      _SpeedBatcherConfigEditorState();
}

class _SpeedBatcherConfigEditorState extends State<_SpeedBatcherConfigEditor> {
  late TextEditingController _labelController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.config.label);
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _labelController,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => widget.config.label = value),
          ),
          const SizedBox(height: 16),
          KeyField(
            label: 'Speedbatcher key',
            initialValue: widget.config.key,
            onChanged: (v) => setState(() => widget.config.key = v),
          ),
          const SizedBox(height: 8),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => setState(() => widget.config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (v) => setState(() => widget.config.coordinates = v),
          ),
        ],
      ),
    );
  }
}

class SpeedBatcher extends ConsumerWidget {
  final SpeedBatcherConfig config;
  const SpeedBatcher({super.key, required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.key)),
      builder: (context, snapshot) {
        if (snapshot.hasError || snapshot.hasData == false) {
          return speedBatcher([null, null, null, null, null]);
        }
        final dyn = snapshot.data!;
        return speedBatcher([
          dyn['p_stat_Running'].asBool,
          dyn['p_stat_Cleaning'].asBool,
          dyn['p_stat_BatchReady'].asBool,
          dyn['p_stat_DropOk'].asBool,
          dyn['p_stat_Dropped'].asBool
        ]);
      },
    );
  }

  Widget speedBatcher(List<bool?> values) {
    assert(values.length == 5);

    // Build your LEDConfig list exactly as before
    final ledConfigs = <LEDConfig>[
      for (final e in [
        'Running',
        'Cleaning',
        'Batch ready',
        'Drop Ok from PLC',
        'Dropped Batch'
      ])
        LEDConfig(
          key: "",
          onColor: (e == 'Cleaning')
              ? const AssetColor.role(HmiColorRole.blue)
              : AssetColor.green,
          offColor: const AssetColor.literal(Colors.white),
        )
          ..text = e
          ..size = config.size
          ..textPos = TextPos.right,
    ];

    return LayoutBuilder(builder: (context, constraints) {
      // Force this widget to be square (1:1 aspect ratio),
      // so it will expand as much as possible within its parent.
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.blueGrey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          // We want 6 equally‐spaced "rows": 5 for LED/status, 1 for the label.
          children: [
            for (int i = 0; i < 5; i++)
              Expanded(
                flex: 1, // Each LED row is 1/5 of the square’s height
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 10% of the row’s width is given to the LED, and it's forced to be a square via AspectRatio
                    Expanded(
                      flex: 10, // 10 parts out of 100
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: LedRaw(
                          ledConfigs[i],
                          value: values[i],
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    // The remaining 90% of the row’s width is for the text.
                    Expanded(
                      flex: 90,
                      child: AutoSizedText(
                        ledConfigs[i].text!,
                        alignment: Alignment.centerLeft,
                        heightFraction: 0.5,
                      ),
                    ),
                  ],
                ),
              ),

            // The 5th “row” is the label, also taking up 1/5 of the height
            Expanded(
              flex: 1,
              child: AutoSizedText(
                config.label,
                heightFraction: 0.6,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// Whether the gate should read as tripped, given its key and polarity.
///
/// Kept out of the widget so the decision can be tested without a `StateMan`,
/// mirroring [sensorIsActive].
bool gateIsTripped({
  required bool rawBool,
  required bool invertPolarity,
}) {
  return invertPolarity ? !rawBool : rawBool;
}

@JsonSerializable(explicitToJson: true)
class GateStatusConfig extends BaseAsset {
  String key;

  /// When true, the key reads TRUE for a *healthy* gate.
  ///
  /// This asset was written against a "tripped" signal — true paints red. The
  /// safety gates here publish the opposite: `FB_MonitorOSSD.q_xOk` is true
  /// when the gate is safe, and it is the only one of the two that reaches
  /// OPC UA (the PLC's `xGateTripped` is assigned twice and ends up carrying
  /// the speedbatcher's emergency gate). A key mapping cannot bridge that —
  /// it has `bitMask` and `bitShift`, neither of which negates a bool — so
  /// the polarity lives here.
  ///
  /// Defaults to false, which is how every page persisted before this field
  /// behaves.
  @JsonKey(defaultValue: false)
  bool invertPolarity;

  GateStatusConfig({
    required this.key,
    this.invertPolarity = false,
  });

  GateStatusConfig.preview()
      : key = "",
        invertPolarity = false;

  factory GateStatusConfig.fromJson(Map<String, dynamic> json) =>
      _$GateStatusConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$GateStatusConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return GateStatus(config: this);
  }

  @override
  Widget configure(BuildContext context) =>
      _GateStatusConfigEditor(config: this);
}

class _GateStatusConfigEditor extends StatefulWidget {
  final GateStatusConfig config;
  const _GateStatusConfigEditor({required this.config});

  @override
  State<_GateStatusConfigEditor> createState() =>
      _GateStatusConfigEditorState();
}

class _GateStatusConfigEditorState extends State<_GateStatusConfigEditor> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyField(
            label: 'key',
            initialValue: widget.config.key,
            onChanged: (v) => setState(() => widget.config.key = v),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('Invert Polarity'),
            subtitle: Text(
              widget.config.invertPolarity
                  ? 'Tripped when state is false (key reads OK, e.g. q_xOk)'
                  : 'Tripped when state is true (key reads tripped)',
            ),
            value: widget.config.invertPolarity,
            onChanged: (v) => setState(() => widget.config.invertPolarity = v),
          ),
          const SizedBox(height: 8),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => setState(() => widget.config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            enableAngle: true,
            initialValue: widget.config.coordinates,
            onChanged: (v) => setState(() => widget.config.coordinates = v),
          ),
        ],
      ),
    );
  }
}

class GateStatus extends ConsumerWidget {
  final GateStatusConfig config;
  const GateStatus({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget buildGate(Color color) {
      return LayoutRotatedBox(
        angle: (config.coordinates.angle ?? 0.0) * pi / 180,
        child: CustomPaint(
          size: config.size.toSize(MediaQuery.of(context).size),
          painter: GatePainter(color: color),
        ),
      );
    }

    if (config.key.isEmpty) {
      return buildGate(HmiColorRole.grey.resolve(context));
    }

    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.key)),
      builder: (context, snapshot) {
        // Scheme roles rather than literals, so the gate tracks a theme
        // switch like every other status colour on the page.
        final color = !snapshot.hasData
            ? HmiColorRole.grey.resolve(context)
            : gateIsTripped(
                    rawBool: snapshot.data!.asBool,
                    invertPolarity: config.invertPolarity)
                ? HmiColorRole.red.resolve(context)
                : HmiColorRole.green.resolve(context);
        return buildGate(color);
      },
    );
  }
}

class GatePainter extends CustomPainter {
  final Color color;
  GatePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final double circleRadius = size.width * 0.25;
    final double topCenterY = size.height * 0.15;
    final double bottomCenterY = size.height * 0.85;

    // Draw top bubble
    canvas.drawCircle(Offset(size.width / 2, topCenterY), circleRadius, paint);
    // Draw bottom bubble
    canvas.drawCircle(
        Offset(size.width / 2, bottomCenterY), circleRadius, paint);

    // Draw line: start/end inside the circles
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.15
      ..strokeCap = StrokeCap.round;

    // Start a bit inside the top circle, end a bit inside the bottom circle
    final double lineStartY = topCenterY + circleRadius * 0.2;
    final double lineEndY = bottomCenterY - circleRadius * 0.2;

    canvas.drawLine(
      Offset(size.width / 2, lineStartY),
      Offset(size.width / 2, lineEndY),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(GatePainter oldDelegate) => color != oldDelegate.color;
}
