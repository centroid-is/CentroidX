import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/state_man_types.dart';

/// Refused, and refused by name.
///
/// A browser cannot hold an OPC UA session, a Modbus socket or an M2400 link,
/// so this is not a configuration that could be made to work — it is one that
/// has to be told it is impossible. The alternative, a client that constructs
/// and then never receives a value, is precisely the silent failure that makes
/// a page look configured and render nothing.
///
/// A web build still renders pages and still builds assets: everything the
/// page editor does with a `StateMan` is done against its interface, and an
/// asset with no value draws its no-value state. Only live plant data is
/// absent, and it says so.
Future<StateMan> buildDirectStateMan(
  Ref ref, {
  required StateManConfig config,
  required KeyMappings keyMappings,
}) async {
  throw StateManException(
      'This client is running in a browser, where direct mode is not '
      'available: a page cannot open an OPC UA session, a Modbus socket or an '
      'M2400 link. Pages and assets still render; the values on them do not '
      'arrive.');
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
