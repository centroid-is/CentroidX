/// Reading this station's [StateManConfig] from whichever store is in force.
///
/// The two transports keep it in different places, and the difference is not
/// incidental:
///
///  * **Direct** keeps it in secure storage (`secret: true`) because it holds
///    PLC credentials, and this station is the thing that talks to the PLCs.
///  * **Gateway** does not have it locally at all. The gateway holds the plant
///    — and the secrets with it — and serves the document over the socket with
///    passwords redacted. A panel, and especially a browser, has no business
///    receiving them.
///
/// So the read branches on the transport, once, here, rather than every caller
/// guessing. The direct half lives behind `direct_transport.dart` so that
/// naming this function does not compile a secure-storage path a browser
/// cannot have.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/state_man_types.dart';

import 'direct_transport.dart';
import 'gateway.dart';
import 'preferences.dart';

/// This station's config, read the way this station stores it.
///
/// A provider rather than a free function taking a `Ref`, because both a
/// provider (`Ref`) and a widget (`WidgetRef`) ask for it and those are
/// different types.
final stateManConfigProvider =
    FutureProvider<StateManConfig>(readStateManConfig);

/// The body behind [stateManConfigProvider].
Future<StateManConfig> readStateManConfig(Ref ref) async {
  final gateway = await ref.read(gatewayConfigProvider.future);
  if (!gateway.isGateway) return readDirectStateManConfig(ref);

  // Plain, because there is no `secret:` on the wire and there should not be:
  // what comes back is the gateway's document, redacted. A station that has
  // never been configured reads as one unnamed OPC UA server, which is what
  // the direct path seeds too.
  final prefs = await ref.read(preferencesProvider.future);
  final raw = await prefs.getString(StateManConfig.configKey);
  if (raw == null) return StateManConfig(opcua: [OpcUAConfig()]);
  return StateManConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
