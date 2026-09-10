import 'package:flutter/material.dart';
import 'package:tfc_dart/core/state_man_types.dart'
    show ConnectionStatus, EffectiveDeviceStatus;

/// A pill-shaped chip that displays connection status with color coding.
///
/// Used by OPC UA, JBTM, and Modbus server config cards to show whether
/// the server is connected, connecting, disconnected, or not yet active.
///
/// TD-004 (v1.1.x): when an [effectiveStatus] is supplied (set by
/// [_ModbusServerConfigCard] for adapters where `umasEnabled == true`),
/// the chip surfaces the combined TCP + UMAS health. `umasUnhealthy`
/// renders amber/yellow with a "UMAS error" label so operators see at a
/// glance that TCP is up but the UMAS handshake is broken (Data
/// Dictionary disabled, refused reservation, pairing-key drift). When
/// only [status] is provided, the chip falls back to pure TCP behavior
/// — keeping classic-Modbus / OPC UA / JBTM cards untouched.
class ConnectionStatusChip extends StatelessWidget {
  final ConnectionStatus? status;
  final EffectiveDeviceStatus? effectiveStatus;
  final bool stateManLoading;

  /// The operator switched this server off in the server config.
  ///
  /// Wins over every other state: a disabled server has no client, so any
  /// status it might still carry is stale. Rendered grey so it reads as
  /// "parked on purpose", never red like a genuine outage.
  final bool disabled;

  const ConnectionStatusChip({
    super.key,
    required this.status,
    this.effectiveStatus,
    this.stateManLoading = false,
    this.disabled = false,
  });

  Color _color() {
    if (disabled) return Colors.grey;
    if (effectiveStatus != null) {
      return switch (effectiveStatus!) {
        EffectiveDeviceStatus.connected => Colors.green,
        EffectiveDeviceStatus.connecting => Colors.orange,
        EffectiveDeviceStatus.disconnected => Colors.red,
        // Amber — "TCP up, UMAS broken". Distinct from `connecting`
        // (transient) and `disconnected` (no link at all). The chip
        // is the operator's only top-level signal that the UMAS
        // session is the failure surface.
        EffectiveDeviceStatus.umasUnhealthy => Colors.amber.shade700,
        // Deep orange — "link claims up, values frozen". The frozen-
        // session failure looks exactly like healthy-and-quiet from the
        // socket's point of view; this chip state is the only place an
        // operator can tell the difference.
        EffectiveDeviceStatus.opcuaUnhealthy => Colors.deepOrange,
      };
    }
    if (status == null) {
      return stateManLoading ? Colors.orange : Colors.grey;
    }
    return switch (status!) {
      ConnectionStatus.connected => Colors.green,
      ConnectionStatus.connecting => Colors.orange,
      ConnectionStatus.disconnected => Colors.red,
    };
  }

  String _label() {
    if (disabled) return 'Disabled';
    if (effectiveStatus != null) {
      return switch (effectiveStatus!) {
        EffectiveDeviceStatus.connected => 'Connected',
        EffectiveDeviceStatus.connecting => 'Connecting...',
        EffectiveDeviceStatus.disconnected => 'Disconnected',
        EffectiveDeviceStatus.umasUnhealthy => 'UMAS error',
        EffectiveDeviceStatus.opcuaUnhealthy => 'No data',
      };
    }
    if (status == null) {
      return stateManLoading ? 'Loading...' : 'Not active';
    }
    return switch (status!) {
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.connecting => 'Connecting...',
      ConnectionStatus.disconnected => 'Disconnected',
    };
  }

  String? _tooltip() {
    if (disabled) {
      return 'Server is disabled — it is not connected to and its keys\n'
          'are not read, written or collected.';
    }
    if (effectiveStatus == EffectiveDeviceStatus.umasUnhealthy) {
      return 'TCP is up but the UMAS session is not paired.\n'
          'Likely causes:\n'
          '  • Data Dictionary disabled in EcoStruxure project\n'
          '  • Another client holds the PLC reservation\n'
          '  • Pairing key drift (try a session reset)';
    }
    if (effectiveStatus == EffectiveDeviceStatus.opcuaUnhealthy) {
      return 'The connection looks up but no values are arriving —\n'
          'the heartbeat has gone silent (dead session, stalled\n'
          'subscription, or a stopped client loop). Values shown for\n'
          'this server are frozen at their last received state.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    final label = _label();
    final tooltip = _tooltip();
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip, child: chip);
  }
}
