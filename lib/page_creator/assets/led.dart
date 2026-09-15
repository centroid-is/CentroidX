import 'dart:math';

import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'common.dart';
import '../../providers/state_man.dart';
import '../../widgets/panes/color_picker_dialog.dart';
import 'package:tfc/converter/color_converter.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

part 'led.g.dart';

@JsonEnum()
enum LEDType {
  circle,
  square,
}

@JsonSerializable(explicitToJson: true)
class LEDConfig extends BaseAsset {
  @override
  String get displayName => 'LED';
  @override
  String get category => 'Basic Indicators';

  String key;
  @AssetColorConverter()
  @JsonKey(name: 'on_color')
  AssetColor onColor;
  @AssetColorConverter()
  @JsonKey(name: 'off_color')
  AssetColor offColor;
  @JsonKey(name: 'led_type')
  LEDType ledType = LEDType.circle;

  LEDConfig({
    required this.key,
    this.onColor = AssetColor.green,
    this.offColor = AssetColor.grey,
  });

  static const previewStr = 'Led preview';

  LEDConfig.preview()
      : key = previewStr,
        onColor = AssetColor.green,
        offColor = AssetColor.grey {
    textPos = TextPos.right;
  }

  @override
  Widget build(BuildContext context) {
    return Led(this);
  }

  @override
  Widget configure(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(16),
        child: _ConfigContent(config: this),
      ),
    );
  }

  /// Shape and the two state colours. The colours are [AssetColor]s, so a
  /// selection set to a theme role keeps tracking the scheme rather than
  /// freezing at whatever the role resolved to on the day of the edit.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  List<BulkProperty> get bulkProperties => [
        ...super.bulkProperties,
        ChoiceBulkProperty<LEDType>(
          id: 'LEDConfig.ledType',
          label: 'Shape',
          group: _bulkGroup,
          options: LEDType.values,
          optionLabel: (value) => BaseAsset.bulkEnumLabel(value.name),
          read: () => ledType,
          apply: (value) => ledType = value,
        ),
        AssetColorBulkProperty(
          id: 'LEDConfig.onColor',
          label: 'On colour',
          group: _bulkGroup,
          read: () => onColor,
          apply: (value) => onColor = value,
        ),
        AssetColorBulkProperty(
          id: 'LEDConfig.offColor',
          label: 'Off colour',
          group: _bulkGroup,
          read: () => offColor,
          apply: (value) => offColor = value,
        ),
      ];

  static const String _bulkGroup = 'LED';

  factory LEDConfig.fromJson(Map<String, dynamic> json) =>
      _$LEDConfigFromJson(json);
  Map<String, dynamic> toJson() => _$LEDConfigToJson(this);
}

class _ConfigContent extends StatefulWidget {
  final LEDConfig config;

  const _ConfigContent({required this.config});

  @override
  State<_ConfigContent> createState() => _ConfigContentState();
}

class _ConfigContentState extends State<_ConfigContent> {
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    final maxWidth = media.width * 0.9; // Use 90% of screen width
    final maxHeight = media.height * 0.8; // Use 80% of screen height

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
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyField(
                    initialValue: widget.config.key,
                    onChanged: (value) {
                      setState(() {
                        widget.config.key = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: widget.config.text,
                    decoration: const InputDecoration(
                      labelText: 'Text',
                    ),
                    onChanged: (value) {
                      setState(() {
                        widget.config.text = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  AssetColorPickerRow(
                    label: 'On Color',
                    color: widget.config.onColor,
                    onChanged: (value) {
                      setState(() {
                        widget.config.onColor = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  AssetColorPickerRow(
                    label: 'Off Color',
                    color: widget.config.offColor,
                    onChanged: (value) {
                      setState(() {
                        widget.config.offColor = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButton<TextPos>(
                    value: widget.config.textPos,
                    isExpanded: true,
                    onChanged: (value) {
                      setState(() {
                        widget.config.textPos = value!;
                      });
                    },
                    items: TextPos.values
                        .map((e) => DropdownMenuItem<TextPos>(
                            value: e, child: Text(e.name)))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  DropdownButton<LEDType>(
                    value: widget.config.ledType,
                    isExpanded: true,
                    onChanged: (value) {
                      setState(() {
                        widget.config.ledType = value!;
                      });
                    },
                    items: LEDType.values
                        .map((e) => DropdownMenuItem<LEDType>(
                              value: e,
                              child: Text(e.name[0].toUpperCase() +
                                  e.name.substring(1)),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  SizeField(
                    initialValue: widget.config.size,
                    useSingleSize: widget.config.ledType == LEDType.circle,
                    onChanged: (value) {
                      setState(() {
                        widget.config.size = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  CoordinatesField(
                    initialValue: widget.config.coordinates,
                    onChanged: (c) =>
                        setState(() => widget.config.coordinates = c),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Led extends ConsumerWidget {
  final LEDConfig config;

  const Led(this.config, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (config.key.isEmpty || config.key == LEDConfig.previewStr) {
      return LedRaw(config, value: null);
    }
    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.key)),
      builder: (context, snapshot) {
        // A key the PLC will not serve is already reported by StateMan, with
        // the node id and the server's own answer. Repeating it here wrote a
        // line per rebuild — which, while a window is being dragged, is a
        // line per frame.
        if (snapshot.hasError || !snapshot.hasData) {
          return LedRaw(config, value: null);
        }
        return LedRaw(config, value: snapshot.data!.asBool);
      },
    );
  }
}

class LedRaw extends ConsumerWidget {
  final LEDConfig config;
  final bool? value;

  const LedRaw(this.config, {super.key, this.value});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    bool? isOn = value;
    if (config.key == LEDConfig.previewStr) {
      isOn = true;
    }
    final color = isOn == null
        ? null
        : (isOn ? config.onColor : config.offColor).resolve(context);

    return CustomPaint(
      painter: LEDPainter(color: color, ledType: config.ledType),
    );
  }
}

class LEDPainter extends CustomPainter {
  final Color? color;
  final LEDType ledType;

  LEDPainter({required this.color, required this.ledType});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color ?? Colors.grey
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height / 2);

    // Draw shape based on type
    if (ledType == LEDType.circle) {
      // Draw circle
      canvas.drawCircle(
        center,
        (min(size.width, size.height) / 2),
        paint,
      );

      // Draw border
      paint.color = Colors.black;
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2;
      canvas.drawCircle(
        center,
        (min(size.width, size.height) / 2),
        paint,
      );
    } else {
      // Draw rounded rectangle
      final rect = Rect.fromCenter(
        center: center,
        width: size.width,
        height: size.height,
      );
      final borderRadius = Radius.circular(
          size.shortestSide * 0.2); // 20% of shortest side like conveyor
      final rrect = RRect.fromRectAndRadius(rect, borderRadius);

      // Draw filled rounded rectangle
      canvas.drawRRect(rrect, paint);

      // Draw border
      paint.color = Colors.black;
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2;
      canvas.drawRRect(rrect, paint);
    }

    if (color == null) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '!',
          style: TextStyle(
            color: Colors.white,
            fontSize: size.height * 0.6,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(LEDPainter oldDelegate) =>
      color != oldDelegate.color || ledType != oldDelegate.ledType;
}
