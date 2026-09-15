import 'package:flutter/material.dart';
import 'package:tfc_dart/core/state_man.dart'
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
///
/// `opcuaUnmonitored` renders amber "Unmonitored". It is deliberately NOT
/// "No data": that state means the client could not be given a health clock,
/// while its existing data subscriptions may be delivering sub-second values
/// throughout. A chip reading "No data" beside a server whose data was
/// demonstrably fine cost two people half an hour, so the two facts get two
/// labels — and [statusDetail] carries the server's own reason string into
/// the tooltip, where it used to exist only in the log.
class ConnectionStatusChip extends StatelessWidget {
  final ConnectionStatus? status;
  final EffectiveDeviceStatus? effectiveStatus;
  final bool stateManLoading;

  /// One line from the client saying what is actually wrong — e.g.
  /// `ClientWrapper.healthDetail`. Appended to the tooltip.
  final String? statusDetail;

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
    this.statusDetail,
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
        // Amber — "link up, values may be fine, but nothing is watching".
        // A degraded diagnostic, not a dead data plane; paler than the
        // deep orange above because it is a less severe claim, and never
        // green because an unwatched client is not a healthy one.
        EffectiveDeviceStatus.opcuaUnmonitored => Colors.amber.shade700,
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
        EffectiveDeviceStatus.opcuaUnmonitored => 'Unmonitored',
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
    final base = switch (effectiveStatus) {
      EffectiveDeviceStatus.umasUnhealthy =>
        'TCP is up but the UMAS session is not paired.\n'
            'Likely causes:\n'
            '  • Data Dictionary disabled in EcoStruxure project\n'
            '  • Another client holds the PLC reservation\n'
            '  • Pairing key drift (try a session reset)',
      EffectiveDeviceStatus.opcuaUnhealthy =>
        'The connection looks up but no values are arriving —\n'
            'the heartbeat has gone silent (dead session, stalled\n'
            'subscription, or a stopped client loop). Values shown for\n'
            'this server are frozen at their last received state.',
      // Says the opposite of "No data" on purpose. This state is about the
      // health clock, not the values: the client is running blind, but the
      // figures on screen may be perfectly current.
      EffectiveDeviceStatus.opcuaUnmonitored =>
        'This server has no health clock: the client could not create\n'
            'the subscription it watches itself with. Values already\n'
            'subscribed may still be arriving normally — but if this\n'
            'server freezes, nothing will notice. The client keeps\n'
            'retrying, backing off to five-minute intervals.',
      _ => null,
    };
    final detail = statusDetail?.trim();
    if (detail == null || detail.isEmpty) return base;
    return base == null ? detail : '$base\n\n$detail';
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
