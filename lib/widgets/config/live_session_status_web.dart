import 'package:tfc_dart/core/state_man_types.dart'
    show M2400Config, ModbusConfig, OpcUAConfig, StateMan;

import 'live_session_status_types.dart';

/// Always null: a browser holds no OPC UA session.
LiveSessionStatus? opcUaLiveStatus(StateMan? stateMan, OpcUAConfig server) =>
    null;

/// Always null: a browser holds no M2400 socket.
LiveSessionStatus? m2400LiveStatus(StateMan? stateMan, M2400Config server) =>
    null;

/// Always null: a browser holds no Modbus socket.
LiveSessionStatus? modbusLiveStatus(StateMan? stateMan, ModbusConfig server) =>
    null;
