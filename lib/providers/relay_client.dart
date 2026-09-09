/// The one WebSocket a panel in gateway mode holds.
///
/// **Why this is its own provider, above `stateManProvider`.** The socket used
/// to be built inside `stateManProvider`, which was fine while the only thing
/// crossing it was values. It stopped being fine when the gateway became the
/// panel's configuration store too: `stateManProvider` reads `key_mappings`
/// and `state_man_config` out of preferences *before* it builds anything, so
/// preferences served over the socket would need the socket that
/// `stateManProvider` had not built yet. A provider cannot be its own
/// ancestor.
///
/// So the socket is opened here, from the device-local transport row and
/// nothing else, and everything that needs the far end reads it:
/// `preferencesProvider` for the configuration, `stateManProvider` for the
/// values, the access stores for sign-in and the audit trail. One socket, one
/// session, one thing for the gateway to police — which is what the transport
/// was for.
///
/// **Null on a direct station.** Reading this on a panel that talks to its own
/// PLCs must not open anything; the null is the answer, not a failure.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';

import 'gateway.dart';

/// How the client is built. Production reads the default and never overrides.
///
/// The seam is here rather than on `GatewayStateMan` because this is now the
/// one construction point, and it is what lets a test assert **what the client
/// was pointed at** — the address, the pinned root, the credential — without a
/// unit test opening a socket to the plant's real gateway. Reading those off a
/// constructed client is the wrong way round: its constructor starts dialling
/// immediately, and an undisposed dial loop is what makes unrelated widget
/// tests flaky.
typedef RelayClientFactory = RemoteStateMan Function({
  required Uri uri,
  required ClientConfig config,
});

RemoteStateMan _dial({required Uri uri, required ClientConfig config}) =>
    RemoteStateMan(uri: uri, config: config);

final relayClientFactoryProvider =
    Provider<RelayClientFactory>((ref) => _dial);

/// This panel's relay client, or null when it is not in gateway mode.
///
/// Built with **no keys**. The key set is chosen by `stateManProvider` once
/// the mapping has been read over this very socket, through
/// `RemoteStateMan.setKeys` — see `GatewayStateMan.attach`. A client with no
/// keys is a legitimate client that reads and writes without watching
/// anything, which is exactly what the configuration store needs and all it
/// needs.
///
/// `keepAlive`, and never rebuilt by a value-side concern: disposing it closes
/// the panel's configuration store, its session and its audit trail along with
/// the values. Switching transport stays restart-to-apply, as the rest of the
/// config-watch behaviour on this codebase is.
final relayClientProvider = FutureProvider<RemoteStateMan?>((ref) async {
  final gateway = await ref.watch(gatewayConfigProvider.future);
  if (!gateway.isGateway) return null;

  // Refused here rather than at the dial, so the operator gets the sentence
  // the Server Config page would have shown them instead of a handshake
  // failure indistinguishable from an impostor.
  final refusal = gateway.validationError;
  if (refusal != null) {
    throw StateError(
        'Gateway mode is selected but the configuration cannot be dialled: '
        '$refusal');
  }

  final client = ref.read(relayClientFactoryProvider)(
    uri: gateway.uri,
    config: await gateway.toClientConfig(),
  );
  ref.onDispose(client.dispose);
  return client;
});
