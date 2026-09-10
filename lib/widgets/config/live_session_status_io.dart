import 'package:tfc_dart/core/modbus_device_client.dart'
    show ModbusDeviceClientAdapter;
import 'package:tfc_dart/core/state_man.dart'
    show ClientWrapper, M2400DeviceClientAdapter;
import 'package:tfc_dart/core/state_man_types.dart'
    show M2400Config, ModbusConfig, OpcUAConfig, StateMan;

import '../../core/opcua_sessions.dart';
import 'live_session_status_types.dart';

/// The OPC UA session this process holds for [server], if any.
///
/// Matched by alias when the server has one and by endpoint otherwise — the
/// same rule the editor used inline before this moved behind a seam.
LiveSessionStatus? opcUaLiveStatus(StateMan? stateMan, OpcUAConfig server) {
  if (stateMan == null) return null;
  final alias = server.serverAlias;
  final ClientWrapper? wrapper =
      opcUaSessionsOf(stateMan).cast<ClientWrapper?>().firstWhere(
            (w) =>
                (alias != null &&
                    alias.isNotEmpty &&
                    w!.config.serverAlias == alias) ||
                w!.config.endpoint == server.endpoint,
            orElse: () => null,
          );
  if (wrapper == null) return null;
  return LiveSessionStatus(
    connectionStatus: wrapper.connectionStatus,
    connectionStream: wrapper.connectionStream,
    effectiveStatus: wrapper.effectiveStatus,
    effectiveStatusStream: wrapper.effectiveStatusStream,
  );
}

/// The M2400 client this process holds for [server], if any.
LiveSessionStatus? m2400LiveStatus(StateMan? stateMan, M2400Config server) {
  if (stateMan == null) return null;
  final alias = server.serverAlias;
  final M2400DeviceClientAdapter? adapter = stateMan.deviceClients
      .whereType<M2400DeviceClientAdapter>()
      .cast<M2400DeviceClientAdapter?>()
      .firstWhere(
        (dc) =>
            (alias != null &&
                alias.isNotEmpty &&
                dc!.serverAlias == alias) ||
            (dc!.wrapper.host == server.host && dc.wrapper.port == server.port),
        orElse: () => null,
      );
  if (adapter == null) return null;
  return LiveSessionStatus(
    connectionStatus: adapter.connectionStatus,
    connectionStream: adapter.connectionStream,
  );
}

/// The Modbus/UMAS client this process holds for [server], if any.
LiveSessionStatus? modbusLiveStatus(StateMan? stateMan, ModbusConfig server) {
  if (stateMan == null) return null;
  final alias = server.serverAlias;
  final ModbusDeviceClientAdapter? adapter = stateMan.deviceClients
      .whereType<ModbusDeviceClientAdapter>()
      .cast<ModbusDeviceClientAdapter?>()
      .firstWhere(
        (dc) =>
            (alias != null && alias.isNotEmpty && dc!.serverAlias == alias) ||
            (dc!.wrapper.host == server.host && dc.wrapper.port == server.port),
        orElse: () => null,
      );
  if (adapter == null) return null;
  return LiveSessionStatus(
    connectionStatus: adapter.connectionStatus,
    connectionStream: adapter.connectionStream,
    // TD-004 (v1.1.x): combined TCP + UMAS health, so the chip can surface a
    // broken UMAS session as `umasUnhealthy` rather than falsely showing green.
    effectiveStatus: adapter.effectiveStatus,
    effectiveStatusStream: adapter.effectiveStatusStream,
  );
}
