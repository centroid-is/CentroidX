import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/modbus_device_client.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/state_man_types.dart';

import 'collector.dart';
import 'preferences_local_store.dart';
import 'state_man.dart';

/// Builds the panel's own sessions: OPC UA, Modbus/UMAS and M2400, plus the
/// collector that historises what they carry.
///
/// Lifted out of `stateManProvider` unchanged. It is here rather than there so
/// that naming `stateManProvider` does not compile an OPC UA client — which is
/// `dart:ffi`, and which a browser has no equivalent of. See
/// `direct_transport.dart`.
Future<StateMan> buildDirectStateMan(
  Ref ref, {
  required StateManConfig config,
  required KeyMappings keyMappings,
}) async {
  final m2400Clients = createM2400DeviceClients(config.jbtm);
  final modbusClients = buildModbusDeviceClients(config.modbus, keyMappings);
  final deviceClients = [...m2400Clients, ...modbusClients];
  final stateMan = await ref.read(stateManFactoryProvider)(
      config: config, keyMappings: keyMappings, deviceClients: deviceClients);

  // Initialize collector
  ref.read(collectorProvider.future);
  return stateMan;
}

/// The default [StateManFactory]: a real OPC UA client.
///
/// Named here rather than inline in `stateManFactoryProvider` for the same
/// reason this file exists — `OpcUaStateMan` is the FFI one, and the provider
/// that declares the seam must stay nameable from a web build.
Future<StateMan> createOpcUaStateMan({
  required StateManConfig config,
  required KeyMappings keyMappings,
  List<DeviceClient> deviceClients = const [],
}) =>
    OpcUaStateMan.create(
        config: config,
        keyMappings: keyMappings,
        deviceClients: deviceClients);

/// The direct station's config, out of secure storage.
///
/// `secret: true` is the whole reason this is here and not in
/// `state_man_config_read.dart`: it is a member of the drift-backed
/// `Preferences` and of nothing else, and a browser has neither the class nor
/// anywhere to keep a secret.
Future<StateManConfig> readDirectStateManConfig(Ref ref) async {
  final prefs = await ref.read(localStorePreferencesProvider.future);
  return StateManConfigStorage.fromPrefs(prefs);
}
