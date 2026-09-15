import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

part 'elcab.g.dart';

@JsonSerializable(explicitToJson: true)
class ElCabConfig extends BaseAsset {
  @override
  String get displayName => 'Electrical Cabinet';
  @override
  String get category => 'Industrial Equipment';

  String key;

  ElCabConfig({
    required this.key,
  });

  // Preview constructor
  ElCabConfig.preview() : key = "";

  factory ElCabConfig.fromJson(Map<String, dynamic> json) => _$ElCabConfigFromJson(json);
  @override
  Map<String, dynamic> toJson() => _$ElCabConfigToJson(this);

  @override
  Widget build(BuildContext context) {
    return LayoutRotatedBox(
      angle: (coordinates.angle ?? 0.0) * math.pi / 180,
      child: ElCab(config: this),
    );
  }

  @override
  Widget configure(BuildContext context) => _ElCabConfigEditor(config: this);
}

class _ElCabConfigEditor extends StatefulWidget {
  final ElCabConfig config;
  const _ElCabConfigEditor({required this.config});

  @override
  State<_ElCabConfigEditor> createState() => _ElCabConfigEditorState();
}

class _ElCabConfigEditorState extends State<_ElCabConfigEditor> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyField(
            initialValue: widget.config.key,
            onChanged: (v) => setState(() => widget.config.key = v),
          ),
          const SizedBox(height: 16),
          SizeField(
            initialValue: widget.config.size,
            onChanged: (size) => setState(() => widget.config.size = size),
          ),
          const SizedBox(height: 16),
          CoordinatesField(
            initialValue: widget.config.coordinates,
            enableAngle: true,
            onChanged: (v) => setState(() => widget.config.coordinates = v),
          ),
        ],
      ),
    );
  }
}

class ElCab extends ConsumerWidget {
  final ElCabConfig config;
  const ElCab({super.key, required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (config.key.isEmpty) {
      return _ElCabDoor(isOpen: false, size: config.size);
    }
    return StreamBuilder<DynamicValue>(
      stream: ref.watch(keyStreamProvider(config.key)),
      builder: (context, snapshot) {
        final isOpen = snapshot.data?.asBool ?? false;
        return _ElCabDoor(isOpen: isOpen, size: config.size);
      },
    );
  }
}

class _ElCabDoor extends StatelessWidget {
  final bool isOpen;
  final RelativeSize size;
  const _ElCabDoor({required this.isOpen, required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: ElCabPainter(isOpen: isOpen),
    );
  }
}

class ElCabPainter extends CustomPainter {
  final bool isOpen;
  ElCabPainter({required this.isOpen});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey[400]!
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Draw the cabinet rectangle
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.1, size.height * 0.05, size.width * 0.35, size.height * 0.8),
      Radius.circular(size.width * 0.05),
    );
    canvas.drawRRect(rect, paint);
    canvas.drawRRect(rect, borderPaint);

    // Draw the open door line if open
    if (isOpen) {
      final start = Offset(size.width * 0.45, size.height * 0.85);
      final end = Offset(size.width * 0.95, size.height * 0.05);
      canvas.drawLine(start, end, borderPaint);
    }
  }

  @override
  bool shouldRepaint(ElCabPainter oldDelegate) => isOpen != oldDelegate.isOpen;
}
