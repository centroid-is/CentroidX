import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/converter/color_converter.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';

part 'arrow.g.dart';

@JsonSerializable(explicitToJson: true)
class ArrowConfig extends BaseAsset {
  @override
  String get displayName => 'Arrow';
  @override
  String get category => 'Basic Indicators';

  String key;
  String label;

  /// Arrow body / glyph colour. Defaults to `Colors.black` — the prior
  /// hard-coded painter colour. Per-instance configurable via the
  /// configure dialog and JSON round-trips through `@ColorConverter()`.
  @ColorConverter()
  Color color;

  ArrowConfig({
    required this.key,
    required this.label,
    Color? color,
  }) : color = color ?? Colors.black;

  ArrowConfig.preview()
      : key = "",
        label = "Arrow preview",
        color = Colors.black;

  factory ArrowConfig.fromJson(Map<String, dynamic> json) =>
      _$ArrowConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$ArrowConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    if (label == "Arrow preview") {
      return const Icon(Icons.arrow_forward, size: 48, color: Colors.grey);
    }
    return ArrowWidget(config: this);
  }

  @override
  Widget configure(BuildContext context) => _ArrowConfigEditor(config: this);
}

class _ArrowConfigEditor extends StatefulWidget {
  final ArrowConfig config;
  const _ArrowConfigEditor({required this.config});

  @override
  State<_ArrowConfigEditor> createState() => _ArrowConfigEditorState();
}

class _ArrowConfigEditorState extends State<_ArrowConfigEditor> {
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
          KeyField(
            initialValue: widget.config.key,
            onChanged: (value) => setState(() => widget.config.key = value),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _labelController,
            decoration: const InputDecoration(labelText: 'Label'),
            onChanged: (value) => setState(() => widget.config.label = value),
          ),
          const SizedBox(height: 16),
          // -- Arrow Color --
          ColorPickerRow(
            label: 'Arrow Color',
            color: widget.config.color,
            onChanged: (c) => setState(() => widget.config.color = c),
          ),
          const SizedBox(height: 16),
          // -- BaseAsset.text overlay (rendered by page_view's label layer).
          //    Without this control the operator can't enable the standard
          //    text-position label overlay that every other asset surfaces.
          TextFormField(
            initialValue: widget.config.text,
            decoration: const InputDecoration(labelText: 'Text'),
            onChanged: (value) => setState(
                () => widget.config.text = value.isEmpty ? null : value),
          ),
          const SizedBox(height: 8),
          DropdownButton<TextPos>(
            value: widget.config.textPos,
            isExpanded: true,
            hint: const Text('Text position'),
            onChanged: (value) => setState(() => widget.config.textPos = value),
            items: TextPos.values
                .map((e) =>
                    DropdownMenuItem<TextPos>(value: e, child: Text(e.name)))
                .toList(),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            onChanged: (c) => setState(() => widget.config.coordinates = c),
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (value) => setState(() => widget.config.size = value),
            useSingleSize: true,
          ),
        ],
      ),
    );
  }
}

class ArrowWidget extends ConsumerStatefulWidget {
  final ArrowConfig config;
  const ArrowWidget({super.key, required this.config});

  @override
  ConsumerState<ArrowWidget> createState() => _ArrowWidgetState();
}

class _ArrowWidgetState extends ConsumerState<ArrowWidget> {
  double _angleForOperation(String op) {
    switch (op) {
      case "left":
        return -math.pi / 2;
      case "right":
        return math.pi / 2;
      case "down":
        return math.pi;
      case "up":
      default:
        return 0.0;
    }
  }

  IconData _iconForOperation(String op) {
    if (op == "lost") {
      return Icons.question_mark_outlined;
    }
    return Icons.arrow_upward;
  }

  /// Builds the rotated icon at a size derived from its parent constraints.
  ///
  /// `LayoutBuilder` mirrors `IconAsset` (lib/page_creator/assets/icon.dart)
  /// so the arrow consumes the SizedBox the page view gives it
  /// (`asset.size.width * W` × `asset.size.height * H`). A bare
  /// `Icon` without `size:` falls back to `IconTheme.size` (~24 px) and
  /// would ignore the parent — that's the "doesn't scale" bug.
  Widget _buildIcon(String operation, Color color) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasW =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite;
        final hasH =
            constraints.hasBoundedHeight && constraints.maxHeight.isFinite;
        final double w = hasW ? constraints.maxWidth : 48.0;
        final double h = hasH ? constraints.maxHeight : 48.0;
        final double size = w < h ? w : h;
        return Center(
          child: Transform.rotate(
            angle: _angleForOperation(operation),
            child: Icon(
              _iconForOperation(operation),
              color: color,
              size: size,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.config.key.isEmpty) {
      // No live key — render the configured arrow in its configured colour.
      // The operator's chosen colour applies in both editor and runtime
      // fallback paths so what they see in the configure dialog matches
      // what they see on the page.
      return _buildIcon("up", widget.config.color);
    }

    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(widget.config.key)),
      builder: (context, snapshot) {
        String operation = "lost";
        if (snapshot.hasData) {
          final str = snapshot.data.toString().toLowerCase();
          if (str.contains("left")) {
            operation = "left";
          } else if (str.contains("right")) {
            operation = "right";
          } else if (str.contains("up")) {
            operation = "up";
          } else if (str.contains("down")) {
            operation = "down";
          } else if (str.contains("lost")) {
            operation = "lost";
          }
        }

        return _buildIcon(operation, widget.config.color);
      },
    );
  }
}
