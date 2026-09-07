@TestOn('vm')

/// The first real-socket test in this package, and the scaffolding every later
/// Phase 15 plan stands on.
///
/// **Why real sockets at all.** `RemoteStateMan`'s `dial:` seam is reachable
/// only from inside `tfc_relay_client` — `ConnectAttempt`, `connect`,
/// `ConnectionSupervisor` and `ValueStore` are `src/`-only and the barrel
/// exports none of them (`tfc_relay_client.dart:52-63`). So the app cannot
/// fake a connection; it can only make one. The far end is
/// `test/helpers/scripted_gateway.dart`, bound to `InternetAddress.loopbackIPv4`
/// on an ephemeral port, speaking the real protocol frames.
///
/// **Every arm here is a plain `test()`, never a widget test.** The widget
/// binding runs in a fake-async zone that will not pump a real socket's
/// completions, so an arm written that way waits forever for a frame that has
/// already arrived. `test/providers/state_man_transport_test.dart` is the
/// in-repo precedent for the plain route in this very directory.
///
/// **Teardown is registered at acquisition, not after success.**
/// `RemoteStateMan`'s constructor starts dialling
/// (`remote_state_man.dart:213-214`), so a client built by an arm that then
/// fails an expectation keeps a backoff loop running for the rest of the run —
/// which is how unrelated widget tests start flaking. Every construction is
/// followed on the next line by `addTearDown(client.dispose)`, and
/// `ScriptedGateway.start` registers its own shutdown before it returns.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../helpers/scripted_gateway.dart';
import '../helpers/throwaway_ca.dart';

/// The credential the wire arm drives.
///
/// Long, obviously synthetic and carrying `-DO-NOT-LOG`, the shape
/// `auth_refusal_test.dart:79` established: a short or plausible token could
/// collide with ordinary prose in a string search and pass while leaking.
const String _credential =
    'ST101-PANEL-CREDENTIAL-3f9a2b7c4e1d8065-DO-NOT-LOG';

/// The attempt-0 backoff window. Small enough that a redial an arm waits for
/// happens inside its budget.
const Duration _base = Duration(milliseconds: 40);

/// The ceiling, far below the production 30 s, for the reason
/// `auth_refusal_test.dart:90-91` gives.
const Duration _cap = Duration(milliseconds: 200);

/// The budget for "the panel got where it was going".
const Duration _recovery = Duration(seconds: 5);

/// The client's knobs, with every production wait lowered deliberately and
/// greppably.
///
/// `allowTokenOverPlaintext` is on because these arms dial `ws://` on loopback
/// with a credential, which `ClientConfig.checkDialable` otherwise refuses by
/// name (`client_config.dart:371-375`) — correctly, for a plant LAN.
ClientConfig _fastConfig({String? token, ClientTlsConfig? tls}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 400),
      writeDeadline: const Duration(milliseconds: 400),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: _base,
      backoffCap: _cap,
      deadlineFloor: const Duration(milliseconds: 50),
      token: token,
      tls: tls,
      allowTokenOverPlaintext: true,
    );

/// Completes with the first [LinkState] satisfying [predicate].
///
/// **Listen first, then seed.** `linkStates` is a broadcast stream and the
/// constructor has already started dialling, so a transition can complete
/// before an arm gets to look — a bare `firstWhere` on the stream then waits
/// for something that already happened, and a bare read of the synchronous
/// getter misses everything after it. Attaching the listener before offering
/// the seed is the only ordering with no window in it. This is the same F-5
/// hazard `lib/providers/gateway_link.dart` will have.
Future<LinkState> _until(
  RemoteStateMan client,
  bool Function(LinkState state) predicate, {
  Duration budget = _recovery,
}) {
  final completer = Completer<LinkState>();
  void offer(LinkState state) {
    if (predicate(state) && !completer.isCompleted) completer.complete(state);
  }

  final subscription = client.linkStates.listen(offer);
  offer(client.linkState);
  return completer.future
      .timeout(budget)
      .whenComplete(subscription.cancel);
}

/// A gateway that completes an ordinary session: hello, then a snapshot.
///
/// Without the subscribe snapshot the client never leaves `resyncing` —
/// `ResyncEngine.onHello` returns only once every page holds one.
Future<ScriptedGateway> _healthyGateway() =>
    ScriptedGateway.start((link, method, id) {
      if (method == Methods.hello) link.hello(id);
      if (method == Methods.subscribe) {
        link.snapshot(id, defaultPageSubscription);
      }
    });

void main() {
  group('the scaffolding Phase 15 stands on', () {
    // Assumption A2, and it runs first because three later plans are written
    // against it being true. `RemoteStateMan` mounts a pinned root with
    // `SecurityContext(withTrustedRoots: false)..setTrustedCertificates(path)`
    // (`remote_state_man.dart:124-132`); a PEM that does not parse there is a
    // fixture that cannot be used, and the phase has a specified fallback.
    test('the throwaway CA is a PEM SecurityContext parses, and it lives '
        'outside the checkout', () {
      final path = throwawayCaPath();

      expect(() {
        final context = SecurityContext(withTrustedRoots: false);
        context.setTrustedCertificates(path);
      }, returnsNormally,
          reason: 'this is the one call the fixture exists to survive; if it '
              'throws, the TLS leg of this phase falls back to dialling wss '
              'at a plaintext listener and no PEM is minted at all');

      // A test that mints a private key and leaves it in the checkout is a
      // private key one `git add -A` away from the history. systemTemp, and
      // nothing under the working directory, is the whole rule.
      expect(path, startsWith(Directory.systemTemp.path),
          reason: 'the key beside this PEM is a real RSA private key');
      expect(path, isNot(startsWith(Directory.current.path)),
          reason: 'no run may leave a .pem somewhere git add would find it');
    });

    test('a real client reaches ready against the scripted gateway', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      expect(client.linkState, LinkState.ready);
      expect(gateway.accepted, 1,
          reason: 'the far end agrees with the near end about how many times '
              'it was dialled; a disagreement means the client never got past '
              'the handshake and something else completed the arm');
    });

    test('a pushed update reaches the client', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      // The snapshot seeded `true` at seq 0. The push is the next sequence,
      // and it is what plan 15-04's criterion-4 guard measures: values flow
      // over a real socket and land definite, not merely grey.
      final arrived = client
          .subscribe(kScriptedSeededKey)
          .firstWhere((value) => value.value == false)
          .timeout(_recovery);
      gateway.links.last.update(1, const {1: false});

      final value = await arrived;
      expect(value.value, isFalse);
      expect(value.quality.isGood, isTrue,
          reason: 'a value that arrives under bad quality renders grey, which '
              'is what the operator sees when nothing is flowing at all — the '
              'two must not be indistinguishable');
      expect(client.read(kScriptedSeededKey)?.value, isFalse,
          reason: 'the synchronous read is what a widget rebuild sees');
    });

    test('the gateway records the frames the client sent', () async {
      final gateway = await _healthyGateway();

      final client = RemoteStateMan(
        uri: gateway.uri,
        config: _fastConfig(token: _credential),
        keys: const {kScriptedSeededKey},
      );
      addTearDown(client.dispose);

      await _until(client, (state) => state == LinkState.ready);

      final hello = gateway.frames
          .firstWhere((frame) => frame['method'] == Methods.hello);
      final params = hello['params'];
      expect(params, isA<Map<String, Object?>>());

      // The recording is what plan 15-03's dial-target arm reads: it proves
      // the configured credential is the one that crossed the wire, rather
      // than the one the app meant to send.
      expect((params! as Map)['token'], _credential);
      expect(gateway.hellos, hasLength(1),
          reason: 'hellos is the same observation, pre-filtered, and the two '
              'must not disagree');
    });
  });
}
