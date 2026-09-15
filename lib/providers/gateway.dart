/// This station's transport choice, read from the device-local store.
///
/// A separate file from `preferences.dart` on purpose: that file owns the two
/// stores themselves, and a setting that reads one of them belongs beside the
/// other settings rather than inside the plumbing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/gateway_config.dart';
import '../core/gateway_trust.dart';
import 'preferences.dart';

/// Where this panel gets its values from.
///
/// Reads [localPreferencesProvider] and never the shared, DB-backed store: a
/// gateway URL is per-station, exactly as the Postgres address is, and a
/// synced row would re-point one station from another. See
/// `lib/core/gateway_config.dart`.
///
/// Watched by `stateManProvider`, which is `keepAlive`, so invalidating this
/// after a save does **not** by itself swap the transport — restart-to-apply
/// is the deliberate behaviour. Tearing an OPC UA session and a Postgres pool
/// down under widgets that hold live subscriptions is not something a settings
/// toggle should attempt.
final gatewayConfigProvider = FutureProvider<GatewayConfig>(
  (ref) async => readGatewayConfig(ref.watch(localPreferencesProvider)),
);

/// How the Server Config page fetches a gateway's identity for the approval
/// ceremony.
///
/// Production is `fetchGatewayTrust` and nothing else; the provider exists so
/// a widget test can hand the card a fetcher that answers, fails or must not
/// be called at all, without a socket anywhere in the test. The seam carries
/// no policy: whatever it returns still goes through the same dialog, and
/// only an approval pins anything.
final gatewayTrustFetcherProvider =
    Provider<Future<FetchedGatewayTrust> Function(Uri)>(
        (ref) => fetchGatewayTrust);
