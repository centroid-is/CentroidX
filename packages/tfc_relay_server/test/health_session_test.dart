@TestOn('vm')
@Tags(['ws'])

/// HLTH-01's server-side half: the numbers a panel can only learn about
/// **its own link**, and HLTH-02's lane split.
///
/// ## Why a per-session producer at all
///
/// `LocalStateMan` is one instance serving every panel in the plant, and
/// `PIPE.link_degraded`, `PIPE.effective_hz`, `PIPE.egress_kbps` and
/// `PIPE.pending_keys` are facts about *one socket*. Served from the shared
/// source they would report whichever client last moved them — so a quiet
/// panel in the packing hall would show the busiest panel's degradation, and
/// an engineer looking at it would go and investigate the wrong machine.
///
/// That is the same argument `policy_state_man.dart` makes about identity,
/// and it is why the overlay in the chain slot is built in `_onConnect`
/// rather than in `start()`. The isolation case below is the executable form
/// of it; the build-once sabotage recorded in 08-12-SUMMARY is what proves
/// the case can fail.
///
/// ## The lane split
///
/// The priority lane is documented as never conflated, so a fast-moving gauge
/// put there is a queue — and a queue is what the core value forbids outright.
/// `PipeKeys.ridesPriorityLane` partitions the namespace by suffix: the news
/// (`connected`, `state`, `link_degraded`, `last_error`, `epoch`,
/// `birth_count`, `last_death_at`) is never conflated, the telemetry
/// (`rtt_ms`, `data_age_ms`, `effective_hz`, `egress_kbps`, `pending_keys`,
/// `event_loop_lag_ms`, `days_to_expiry`) is. This file asserts the *arrival*
/// of the news on a throttled subscription, never the ordering of two
/// instants, because an ordering assertion between two frames produced in the
/// same tick is a race dressed as a property.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/health/session_health_state_man.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/tls/tls_config.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/io.dart';

import 'support/certs.dart';
import 'support/panels.dart';
import 'support/permissive_resolver.dart';

/// Trap 17 again: an unreachable address takes 75 s to fail on macOS.
const _dialBudget = Duration(seconds: 10);

/// A plant tag, so "a health key" can be told apart from "every key".
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A tag the rate-limited subscription is anchored on, so `Plant.connect` can
/// do its ordinary hello-then-subscribe and the throttled lane can be added
/// beside it without editing the shared harness.
const _anchorKey = 'ST101.CN01.MOT01.mode';

/// News and telemetry, as `PipeKeys.ridesPriorityLane` partitions them: a
/// per-link `connected` bit against a per-link `data_age_ms` gauge. Per-alias
/// keys on purpose — they are the half of the namespace with no finite
/// roster, so a lane rule that enumerated keys would already be wrong here.
final _newsKey = PipeKeys.upstreamConnected('ST101');
final _gaugeKey = PipeKeys.upstreamDataAgeMs('ST101');

/// The six keys a session answers for itself.
const _perSession = [
  PipeKeys.linkDegraded,
  PipeKeys.effectiveHz,
  PipeKeys.egressKbps,
  PipeKeys.pendingKeys,
  PipeKeys.droppedHoldTicks,
  PipeKeys.eventLoopLagMs,
];

void main() {
  /// A gateway serving [plant], torn down whatever happens to it.
  RelayServer buildServer({
    required FakeStateMan plant,
    TlsConfig? tls,
    // `AccessPolicyKeyPolicy` since 17-07 deleted `AllVisibleOperatorWrites`:
    // the shipped adapter, everything visible, writes graded by the master
    // policy — which under the permissive validator's full group set answers
    // exactly as the old default did for every case in this file.
    KeyPolicy policy = const AccessPolicyKeyPolicy(),
    // **Named rather than defaulted since 16-08.** The `link_degraded` case
    // below needs *a* soft ceiling to push one session over, and it used to
    // borrow `ServerConfig`'s default. That default is now null
    // (`16-02-DECISION.md` §5.4 — it measured production and evicted healthy
    // panels for it), so the case has to say what ceiling it means. It is a
    // better case for saying so: its property is that one session's reading is
    // its own, and that has nothing to do with where the ceiling happens to
    // sit.
    int? peakThreshold,
  }) {
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: plant,
      config: ServerConfig(
          tick: ServerConfig.minTick, tls: tls, peakThreshold: peakThreshold),
      policy: policy,
      onError: (_, __, ___) {},
    );
    addTearDown(() async {
      await server.close();
      await plant.dispose();
    });
    return server;
  }

  HttpClient pinnedClient(String rootPem) {
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(rootPem.codeUnits);
    final client = HttpClient(context: context);
    addTearDown(() => client.close(force: true));
    return client;
  }

  /// A connected station on [server], past the handshake.
  Future<rpc.Client> station(RelayServer server,
      {String? root, bool hello = true}) async {
    final opened = server.sessions.opened.first;
    final ws = IOWebSocketChannel.connect(
      Uri.parse('${root == null ? 'ws' : 'wss'}://localhost:${server.port}'),
      customClient: root == null ? null : pinnedClient(root),
      connectTimeout: _dialBudget,
    );
    await ws.ready.timeout(_dialBudget);
    final base = wsChannel(ws);
    final peer = rpc.Client(
        StreamChannel<String>(base.stream.asBroadcastStream(), base.sink));
    unawaited(peer.listen().catchError((Object _) => null));
    addTearDown(() async {
      await peer.close().catchError((Object _) {});
      await ws.sink.close().catchError((Object _) {});
    });
    await opened.timeout(const Duration(seconds: 5));
    if (!hello) return peer;
    await peer
        .sendRequest(
            Methods.hello,
            HelloParams(
              protocol: protocolVersion,
              supported: const [protocolVersion],
              client: const PeerInfo('panel-under-test', '0.1.0'),
            ).toJson())
        .timeout(_dialBudget);
    return peer;
  }

  Map<String, Object?> asMap(Object? value) =>
      (value! as Map).cast<String, Object?>();

  /// One `read` over the wire, decoded through the DTO.
  Future<Map<String, Object?>> read(rpc.Client panel, String key) async =>
      asMap(await panel.sendRequest(Methods.read, {'key': key}));

  group('the per-session overlay', () {
    test('a session serves the six per-session keys and the certificate key',
        () async {
      final ca = mintCa();
      final at = DateTime.now().toUtc();
      final mounted = writeCertFixture(
        chainPem: mintLeaf(
            ca: ca,
            notBefore: at.subtract(const Duration(days: 400)),
            notAfter: at.add(const Duration(days: 365))),
        keyPem: leafKeyPem(),
        rootPem: ca.certPem,
      );
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(
          plant: plant,
          tls: TlsConfig(
              chainPath: mounted.chainPath, keyPath: mounted.keyPath));
      await server.start();
      await station(server, root: ca.certPem);

      final session = server.sessions.sessions.single;
      expect(session.api.source, isA<SessionHealthStateMan>(),
          reason: 'the per-session overlay takes the chain slot the cert '
              'overlay used to hold: policy over health over source');
      expect((session.api.source as SessionHealthStateMan).source,
          same(plant),
          reason: 'one overlay over the one shared source — a second source '
              'here would be a second place plant state lives');

      for (final key in _perSession) {
        expect(session.api.keys, contains(key), reason: '$key is per-session');
      }
      expect(session.api.keys, contains(PipeKeys.certDaysToExpiry),
          reason: 'the certificate key is one number for the process and is '
              'served by every session\'s overlay');
      expect(session.api.keys, contains(_speedKey),
          reason: 'a union, not a replacement');
    });

    test('a plaintext session serves the six and no certificate key', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);

      final session = server.sessions.sessions.single;
      for (final key in _perSession) {
        expect(session.api.keys, contains(key),
            reason: 'the per-session facts are about a socket, and a '
                'plaintext socket is still a socket');
      }
      expect(session.api.keys, isNot(contains(PipeKeys.certDaysToExpiry)),
          reason: 'a gateway that was never given a certificate has nothing '
              'to report on, and a key reading errorConfig forever is a '
              'permanent false alarm');
      expect((await read(panel, PipeKeys.certDaysToExpiry))['rejected'],
          isNotNull,
          reason: 'absent means absent');
    });

    test('one session\'s numbers are not another session\'s numbers',
        () async {
      // The phase's most likely mistake, in one case: an overlay built once in
      // `start()` reports the busiest client's condition to everybody.
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant, peakThreshold: 1024);
      await server.start();

      final quiet = await station(server);
      final throttled = await station(server);
      expect(server.sessions.sessionCount, 2);

      // The second session's buffer is pushed over its own soft ceiling. This
      // is the shedding `link_degraded` is about, and it is done to exactly
      // one of the two sockets.
      final loaded = server.sessions.sessions.last;
      for (var i = 0; i <= server.config.peakThreshold!; i++) {
        loaded.buffer.putPriority('{"jsonrpc":"2.0","method":"noop"}');
      }

      final degradedHere = await read(throttled, PipeKeys.linkDegraded);
      final degradedThere = await read(quiet, PipeKeys.linkDegraded);
      expect(WireValue.fromJson(asMap(degradedHere['value'])).v, isTrue,
          reason: 'the throttled panel is the one that is shedding');
      expect(WireValue.fromJson(asMap(degradedThere['value'])).v, isFalse,
          reason: 'and the quiet one is not — a shared overlay would report '
              'the busiest client\'s condition to a panel that is fine, and '
              'send an engineer to the wrong machine');

      // And a counter, which unlike a buffer census is not drained by the next
      // tick: one panel drops a hold tick, the other does not, and neither
      // reads the other's number.
      throttled.sendNotification(Methods.holdTick, {'hold': 'never-engaged'});
      await pumpEventQueue();

      final droppedHere = await read(throttled, PipeKeys.droppedHoldTicks);
      final droppedThere = await read(quiet, PipeKeys.droppedHoldTicks);
      expect(WireValue.fromJson(asMap(droppedHere['value'])).v, greaterThan(0),
          reason: 'the panel that dropped one counts it');
      expect(WireValue.fromJson(asMap(droppedThere['value'])).v, 0,
          reason: 'and the panel that did not is not billed for it — an '
              'overlay built once in start() would report one number to both');
    });

    test('a number not yet measurable reads null under errorConfig, never 0',
        () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);

      // Nothing has ticked for this session yet, and zero is a different and
      // alarming claim: it means the pipe has stopped.
      final wire =
          WireValue.fromJson(asMap((await read(panel, PipeKeys.effectiveHz))
              ['value']));
      expect(wire.v, isNull,
          reason: 'unknown is not zero — zero means the pipe has stopped');
      expect(wire.q, Quality.errorConfig,
          reason: 'the same statement the certificate producer makes about an '
              'unreadable chain: the gateway looked and there is no number '
              'to report');
    });

    test('dropped_hold_ticks is the sum of both halves', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server, hello: false);
      final session = server.sessions.sessions.single;

      // **The half the handler never sees.** A hold tick sent before the
      // handshake is refused by the gate and never reaches `ValueHandlers`,
      // so it is counted on the session as an ungated notification. It is
      // still a tick that reached a handler and did nothing, which is what
      // every other entry in this count is — and a health key with a hole in
      // it exactly where the unauthenticated peers go is a number an operator
      // would read as "nothing is being dropped" (05-REVIEW WR-03,
      // relay_session.dart:470-478).
      panel.sendNotification(Methods.holdTick, {'hold': 'never-engaged'});
      await pumpEventQueue();
      await panel
          .sendRequest(
              Methods.hello,
              HelloParams(
                protocol: protocolVersion,
                supported: const [protocolVersion],
                client: const PeerInfo('panel-under-test', '0.1.0'),
              ).toJson())
          .timeout(_dialBudget);

      // And one after it, which the handler does see: the key is the sum, not
      // either half.
      panel.sendNotification(Methods.holdTick, {'hold': 'never-engaged'});
      await pumpEventQueue();

      expect(session.droppedHoldTicks, 2,
          reason: 'one refused by the gate and one refused by the handler — '
              'the fixture has to produce both for this case to mean '
              'anything');
      final wire = WireValue.fromJson(
          asMap((await read(panel, PipeKeys.droppedHoldTicks))['value']));
      expect(wire.v, 2,
          reason: 'the health key is the sum of both halves; reporting only '
              'the handler\'s would read 1 and hide the peer that never '
              'authenticated');
    });

    test('a policy that hides a health key hides it here too', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server =
          buildServer(plant: plant, policy: const _HidesEgress());
      await server.start();
      final panel = await station(server);

      final session = server.sessions.sessions.single;
      expect(session.api.keys, isNot(contains(PipeKeys.egressKbps)),
          reason: 'the chain is policy OVER health: `canSee` filters a key '
              'list that already contains the health keys');
      expect(session.api.keys, contains(PipeKeys.pendingKeys),
          reason: 'and it filters that one only — anti-vacuity');
      expect((await read(panel, PipeKeys.egressKbps))['rejected'], isNotNull);
    });

    test('a write to a per-session health key is refused as a reading',
        () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);

      final answer = asMap(await panel.sendRequest(
          Methods.write,
          WriteParams(cmd: newUlid(), key: PipeKeys.linkDegraded, value: false)
              .toJson()));
      expect(answer['outcome'], 'rejected',
          reason: 'a health key is a reading of the world, not a setpoint — '
              'a write that moved it would let somebody silence an alarm by '
              'typing a number into it');
      expect(jsonEncode(answer['reason']), contains('not_writable'),
          reason: 'and it reuses the read-only shape a device gives, so '
              'nothing on the panel side needs a special case');
    });
  });

  group('the priority lane, split by key', () {
    test('the news arrives on a throttled subscription while the telemetry '
        'is conflated', () async {
      final plant = Plant();
      plant.api.setValues({
        _anchorKey: 0,
        _newsKey: false,
        _gaugeKey: 0,
      });
      final panel = await plant.connect('s0', [_anchorKey]);
      // 1 Hz against a 50 ms tick: this subscription is due roughly once in
      // twenty ticks, which is the "held" link the design's sentence is about.
      // Subscribed by hand rather than through `Plant.connect`, so the shared
      // harness stays exactly as every other file in the suite reads it.
      await plant.ask(
          panel,
          Methods.subscribe,
          SubscribeParams(sub: 's1', keys: [_newsKey, _gaugeKey], maxRateHz: 1)
              .toJson());
      // One warm-up push, because the rate limiter's first push is always due
      // — `dueAt` has nothing to compare against until something has been
      // pushed. Everything after this tick is inside the 1 Hz window.
      plant.api.setValue(_gaugeKey, 99);
      await pumpEventQueue();
      plant.tick();
      plant.clearWires();

      plant.api.setValue(_newsKey, true);
      for (var i = 1; i <= 40; i++) {
        plant.api.setValue(_gaugeKey, i);
      }
      await pumpEventQueue();
      plant.tick();

      final arrived =
          panel.updates.expand((u) => u.changes.keys).toSet();
      expect(arrived, contains(_handleOf(plant, _newsKey)),
          reason: 'a degraded link must still deliver the news that it is '
              'degraded — the state change rides the never-conflated lane and '
              'does not wait for the rate limiter');
      expect(arrived, isNot(contains(_handleOf(plant, _gaugeKey))),
          reason: 'the telemetry is still conflated behind the rate limiter: '
              'an unconflated fast-moving gauge on the priority lane is a '
              'queue, and a queue is what the core value forbids');
    });

    test('a gauge updated forty times between drains arrives once', () async {
      final plant = Plant();
      plant.api.setValue(_gaugeKey, 0);
      final panel = await plant.connect('s1', [_gaugeKey]);
      plant.clearWires();

      for (var i = 1; i <= 40; i++) {
        plant.api.setValue(_gaugeKey, i);
      }
      await pumpEventQueue();
      plant.tick();

      expect(panel.updates.length, 1,
          reason: 'conflation is the design\'s core value, and the lane split '
              'must not cost it');
      expect(panel.updates.single.changes[_handleOf(plant, _gaugeKey)]!.v, 40,
          reason: 'and the one that arrives is the newest');
    });

    test('a plant key is unaffected by the split', () async {
      final plant = Plant();
      plant.api.setValues({_anchorKey: 0, _speedKey: 0});
      final panel = await plant.connect('s0', [_anchorKey]);
      await plant.ask(
          panel,
          Methods.subscribe,
          SubscribeParams(sub: 's1', keys: [_speedKey], maxRateHz: 1)
              .toJson());
      // The same warm-up: the first push through a rate limiter is due.
      plant.api.setValue(_speedKey, 1);
      await pumpEventQueue();
      plant.tick();
      plant.clearWires();

      plant.api.setValue(_speedKey, 1450);
      await pumpEventQueue();
      plant.tick();

      expect(panel.updates, isEmpty,
          reason: 'an ordinary tag is deferred by the rate limiter exactly as '
              'it always was. A key outside the PIPE namespace is never '
              'promoted, however it is spelled — plant telemetry on the '
              'unconflated lane is how that lane becomes a queue');
    });
  });
}

/// The handle the gateway minted for [key]. `handlesFor` is idempotent, so
/// asking again is a lookup rather than a second mint.
int _handleOf(Plant plant, String key) =>
    plant.handles.handlesFor([key]).values.single;

/// A policy that hides exactly one health key, and nothing else.
///
/// `StationIdentity` since 17-04b deleted `Identity`; the judgement — hide
/// egress, permit nothing — is unchanged. `canWritePreference` answers as
/// `canWrite` does, because a policy this closed has no reason to grade the
/// two surfaces apart.
final class _HidesEgress implements KeyPolicy {
  const _HidesEgress();

  @override
  bool canSee(String key, StationIdentity identity) =>
      key != PipeKeys.egressKbps;

  @override
  bool canWrite(String key, StationIdentity identity) => false;

  @override
  bool canWritePreference(String key, StationIdentity identity) => false;
}
