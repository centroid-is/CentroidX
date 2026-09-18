/// The Temperatures section of the About Linux page.
///
/// Read-only and unprivileged, like the clock's status half: "is this box
/// cooking?" is an operator question. The numbers come from sysfs through
/// [readHostTemperatures]; this file only polls and draws, and takes the
/// reader as a callback so tests and goldens need no `/sys`.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/hardware_temperatures.dart';
import '../theme.dart';

/// Sensor files are cheap to read and temperatures move slowly; this paces
/// the redraw, not any hardware.
const Duration hardwareTemperaturePollInterval = Duration(seconds: 5);

class HardwareTemperaturesSection extends StatefulWidget {
  final Future<List<TemperatureReading>> Function() read;
  final Duration pollInterval;

  const HardwareTemperaturesSection({
    super.key,
    this.read = readHostTemperatures,
    this.pollInterval = hardwareTemperaturePollInterval,
  });

  @override
  State<HardwareTemperaturesSection> createState() =>
      _HardwareTemperaturesSectionState();
}

class _HardwareTemperaturesSectionState
    extends State<HardwareTemperaturesSection> {
  List<TemperatureReading> _readings = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final readings = await widget.read();
      if (mounted) setState(() => _readings = readings);
    } catch (_) {
      // The reader does not throw; a custom one that does keeps the last rows.
    }
  }

  @override
  Widget build(BuildContext context) {
    // No sensors — a dev build off Linux, or a VM — is not worth a heading
    // over an empty box; the page simply has one section fewer.
    if (_readings.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        const Divider(),
        HardwareTemperaturesCard(readings: _readings),
      ],
    );
  }
}

/// The heading and the table, from readings already in hand.
@visibleForTesting
class HardwareTemperaturesCard extends StatelessWidget {
  final List<TemperatureReading> readings;

  const HardwareTemperaturesCard({super.key, required this.readings});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Text('Temperatures',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final r in readings) _TemperatureRow(reading: r)],
          ),
        ),
      ],
    );
  }
}

class _TemperatureRow extends StatelessWidget {
  final TemperatureReading reading;

  const _TemperatureRow({required this.reading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final states = HmiStateColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final level = temperatureLevel(reading);

    // Normal is plain text: a column of green numbers would say nothing a
    // plain one does not, and would dull the one that turns yellow.
    final valueColor = switch (level) {
      TemperatureLevel.normal => theme.colorScheme.onSurface,
      TemperatureLevel.high => states.yellow,
      TemperatureLevel.critical => states.red,
    };

    final min = reading.minCelsius;
    final value = min == null
        ? _fmt(reading.celsius)
        : '${_fmt(min, unit: false)}–${_fmt(reading.celsius)}';

    final limits = [
      if (reading.count > 1) '${reading.count} cores',
      if (reading.high != null && reading.high != reading.critical)
        'high ${_fmt(reading.high!)}',
      if (reading.critical != null) 'crit ${_fmt(reading.critical!)}',
    ].join('  ·  ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // The same 120px label gutter as the system card above and the
          // time sync rows below, so the page reads as one table.
          SizedBox(
            width: 120,
            child: Text(reading.label,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                overflow: TextOverflow.ellipsis),
          ),
          SizedBox(
            width: 124,
            child: Row(
              children: [
                if (level != TemperatureLevel.normal)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      level == TemperatureLevel.critical
                          ? Icons.error
                          : Icons.warning_amber,
                      size: 16,
                      color: valueColor,
                    ),
                  ),
                Flexible(
                  child: Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: valueColor, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              limits,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _fmt(double c, {bool unit = true}) =>
    '${c.round()}${unit ? ' °C' : ''}';
