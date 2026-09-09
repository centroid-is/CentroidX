import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/state_man_types.dart';

/// Refused, and refused by name.
///
/// A browser cannot hold an OPC UA session, a Modbus socket or an M2400 link,
/// so "direct mode in a browser" is not a configuration that could be made to
/// work — it is a configuration that has to be told it is impossible. The
/// alternative, a client that constructs and then never receives a value, is
/// the silent failure this whole transport exists to prevent.
Future<StateMan> buildDirectStateMan(
  Ref ref, {
  required StateManConfig config,
  required KeyMappings keyMappings,
}) async {
  throw StateManException(
      'This client is running in a browser, where direct mode is not '
      'available: a page cannot open an OPC UA session, a Modbus socket or an '
      'M2400 link. Point it at a gateway — the backend that holds the plant — '
      'and it will read every value over that one connection instead.');
}

/// There is no OPC UA client in a web build, so the seam's default factory
/// refuses too. Reached only if something overrides its way past
/// [buildDirectStateMan], which is a wiring fault rather than a configuration.
Future<StateMan> createOpcUaStateMan({
  required StateManConfig config,
  required KeyMappings keyMappings,
  List<DeviceClient> deviceClients = const [],
}) =>
    throw StateManException(
        'No OPC UA client exists in a browser build. This factory is the '
        'direct-mode default and nothing in a web build should reach it.');

/// Refused: there is no direct station here to have a config, and no secure
/// storage to have kept one in. `readStateManConfig` never calls this — it
/// branches on the transport first — so reaching it is a wiring fault.
Future<StateManConfig> readDirectStateManConfig(Ref ref) =>
    throw StateManException(
        'There is no direct-mode configuration in a browser: the gateway holds '
        'the plant and the secrets, and serves the document over the socket.');
