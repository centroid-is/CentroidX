/// The link-level freshness verdict, as one provider every value stream reads.
///
/// The companion to `lib/providers/gateway_link.dart`, built to the same five
/// rules and for the same reason: there is one place that knows how to reach the
/// live relay client from `lib/`, and every surface that needs it goes through
/// that place rather than repeating the unwrap.
///
/// **1. The config is consulted first, and direct mode short-circuits before
/// `stateManProvider` is ever read.** A direct station cannot grow a staleness
/// verdict by accident, and reading `stateManProvider` to be told so would open
/// every OPC UA session on the panel from a provider that has nothing to report.
/// `value_freshness_provider_test.dart` pins it with a tripwire.
///
/// **2. The unwrap is by name, through `GuardedStateMan.innerAs`.** A bare
/// `value is GatewayStateMan` on `stateManProvider`'s value is **false on every
/// real panel** and true only in a hand-built test (15-RESEARCH F-1): that
/// provider always answers a `GuardedStateMan`, whose inner object is private
/// with no getter. Do not "simplify" the two lines below back to a type test.
///
/// **3. A client that could not be built reads as fresh, and that is not a
/// contradiction.** There is no socket, so no value ever arrives, so every asset
/// on the page already renders `---`. `gatewayLinkProvider` publishes the red
/// `Panel misconfigured` chip for that station and owns the explanation; a
/// second verdict layered on top would be a second sentence about the same fact
/// and would need a staleness number nothing computes.
///
/// **4. No timer, and nothing to gate.** Unlike `gateway_link.dart` — which
/// argues its way into one one-shot timer — every transition this provider
/// publishes is an event the client already raised. `FreshnessWatchdog` owns the
/// only clock involved, which is exactly the "one master model per concern" rule
/// this milestone stands on.
///
/// **5. It is rebuilt by the same two things `keyStreamProvider` is** — the
/// transport row and `stateManProvider` — so a reader watching both never sees a
/// verdict belonging to a client it is no longer reading values from.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/access/guarded_state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show RemoteStateMan;

import '../core/gateway_state_man.dart';
import '../core/value_freshness.dart';
import 'gateway.dart';
import 'state_man.dart';

/// Whether this panel can currently vouch for the values it is showing.
///
/// Always answers an object — never null and never an `AsyncValue` — because
/// every caller is on a render path and "we do not know yet whether we know" is
/// not a state a value stream can do anything useful with. While the transport
/// row is still being read the answer is [ValueFreshness.fresh]: a panel that
/// greyed every value for the first frames of every boot is a panel whose grey
/// stops being read.
final valueFreshnessProvider = Provider<ValueFreshness>((ref) {
  // 1. Config first. See the library doc.
  final config = ref.watch(gatewayConfigProvider).valueOrNull;
  if (config == null || !config.isGateway) return ValueFreshness.fresh();

  // 2. The unwrap, by name and read-only.
  final built = ref.watch(stateManProvider).valueOrNull;
  final RemoteStateMan? remote =
      built is GuardedStateMan ? built.innerAs<GatewayStateMan>()?.remote : null;

  // 3. No client, no verdict. See the library doc.
  if (remote == null) return ValueFreshness.fresh();

  final freshness = ValueFreshness.watching(
    stale: remote.viewIsStale,
    transitions: remote.viewFreshness,
  );
  ref.onDispose(freshness.dispose);
  return freshness;
});
