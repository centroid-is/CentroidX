@TestOn('vm')
@Tags(['ws'])

/// What a planned drain owes the client, and what the gateway is allowed to
/// call itself.
///
/// ## The final tick
///
/// A gateway going down on purpose closes every session with
/// [CloseCodes.serverDraining] — 4002, whose documented meaning is "reconnect,
/// do not alarm". What it did not do was say *where each subscription got to*,
/// so a panel reconnecting after a deploy could not tell a sequence it missed
/// from one that never happened, and had no way to know whether the values on
/// its screen were the last ones the gateway evaluated. That is the
/// repudiation half of T-08-48: a client unable to account for what it missed.
///
/// So a planned drain emits one last `tick` naming each subscription's last
/// `seq`, **as its own frame, flushed before the close**.
///
/// ## Why it is a frame and not a close reason
///
/// This is Phase 6's bonus bug, and it is worth re-living once rather than
/// inheriting. RFC 6455 caps a close reason at 123 bytes and
/// `package:web_socket` enforces the cap with an `ArgumentError`
/// (`utils.dart:18`). That throw lands inside `_Connection.closeSocket`'s
/// `try`, is swallowed as "the far end is already gone", and **the socket is
/// never closed** — so a close code the gateway believes it sent was never
/// sent and the session lives on. Splicing a sequence number into the reason
/// would put every planned drain one long station name away from that. The
/// clamp at the close seam is the belt; this file's long-reason arm is the
/// brace, and the sabotage recorded in 08-12-SUMMARY is what proves the arm
/// can fail.
///
/// ## `publisherId`
///
/// The Sparkplug adoption from 07-RESEARCH-PUBSUB: the gateway can name
/// itself, so a plant that runs two of them can tell whose `ST201` an alias
/// belongs to. Advisory — nothing routes on it — and **additive**: an
/// unconfigured deployment's `hello` is byte-identical to the one it sent
/// before this key existed, which is what the captured literal below pins.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/io.dart';

import 'support/permissive_resolver.dart';

const _dialBudget = Duration(seconds: 10);
const _speedKey = 'ST101.CN01.MOT01.speed';

/// 2100-01-01, epoch ms: the wall clock the unplanned-close arm freezes its
/// gateway at, and a stamp no tick the *engine* wrote can wear.
///
/// The engine anchors its wire clock once, at construction, off the real
/// `DateTime.now()` (`TickEngine.wallAt`), and nothing in this file's
/// injection reaches it — so every ordinary tick is stamped in this decade,
/// while `RelaySession._writeFinalTick` reads the injected clock directly.
/// Far enough ahead that the gap is a fact about the two clocks and not about
/// how long a test took.
const _drainStamp = 4102444800000;

/// One dialled panel, and every frame the gateway wrote to it in order.
final class _Panel {
  _Panel(this.peer, this.frames, this.closed, this._ws);

  final rpc.Client peer;

  /// Every frame the socket carried, in arrival order — the assertion in the
  /// ordering arm is an index comparison, which is the only honest way to say
  /// "the tick came before the close".
  final List<String> frames;

  /// Completes when the socket's stream ends, with the close code the client
  /// observed. Reliable here because the *server* initiated every close in
  /// this file (`web_socket_channel` #1698 is about the other direction).
  final Future<int?> closed;

  final IOWebSocketChannel _ws;

  Future<void> dispose() async {
    await peer.close().catchError((Object _) {});
    await _ws.sink.close().catchError((Object _) {});
  }

  /// The `tick` notifications received, decoded through the DTO, so a
  /// hand-spliced envelope that drifted from [TickParams] fails here rather
  /// than on a panel.
  List<TickParams> get ticks => [
        for (final frame in frames)
          if (_methodOf(frame) == Methods.tick)
            TickParams.fromJson(
                ((jsonDecode(frame) as Map)['params'] as Map).cast()),
      ];

  int indexOfLastTick() =>
      frames.lastIndexWhere((f) => _methodOf(f) == Methods.tick);
}

String? _methodOf(String frame) =>
    (jsonDecode(frame) as Map)['method'] as String?;

void main() {
  RelayServer buildServer(
      {required FakeStateMan plant,
      String? publisherId,
      int Function()? now}) {
    final server = RelayServer(
      resolver: const PermissiveSeriesResolver(),
      api: plant,
      config: ServerConfig(
          tick: ServerConfig.minTick, publisherId: publisherId),
      now: now,
      onError: (_, __, ___) {},
    );
    addTearDown(() async {
      await server.close();
      await plant.dispose();
    });
    return server;
  }

  Future<_Panel> station(RelayServer server, {bool hello = true}) async {
    final opened = server.sessions.opened.first;
    final ws = IOWebSocketChannel.connect(
      Uri.parse('ws://localhost:${server.port}'),
      connectTimeout: _dialBudget,
    );
    await ws.ready.timeout(_dialBudget);
    final base = wsChannel(ws);
    final frames = <String>[];
    final closed = Completer<int?>();
    final tapped = base.stream.map((frame) {
      frames.add(frame);
      return frame;
    }).asBroadcastStream();
    unawaited(tapped.drain<void>().then((_) {
      if (!closed.isCompleted) closed.complete(ws.closeCode);
    }).catchError((Object _) {
      if (!closed.isCompleted) closed.complete(ws.closeCode);
    }));
    final peer = rpc.Client(StreamChannel<String>(tapped, base.sink));
    unawaited(peer.listen().catchError((Object _) => null));
    final panel = _Panel(peer, frames, closed.future, ws);
    addTearDown(panel.dispose);
    await opened.timeout(const Duration(seconds: 5));
    if (hello) await _hello(peer);
    return panel;
  }

  group('the final tick', () {
    test('a planned drain names the last seq, in its own frame before the '
        'close', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);
      await panel.peer.sendRequest(Methods.subscribe,
          SubscribeParams(sub: 'page-1', keys: const [_speedKey]).toJson());

      // Move the tag so the sequence is somewhere other than its initial
      // value: a final tick that always said the same number would pass this
      // case without carrying any information.
      plant.setValue(_speedKey, 1451);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final lastSeqBeforeDrain = panel.ticks.last.subs['page-1']!.seq;

      final framesBefore = panel.frames.length;
      await server.close();
      final code = await panel.closed.timeout(_dialBudget);

      final finalTick = panel.ticks.last;
      expect(panel.indexOfLastTick(), greaterThanOrEqualTo(framesBefore),
          reason: 'the tick has to be produced by the drain, not scraped from '
              'the last ordinary one before it');
      expect(finalTick.subs['page-1']!.seq, lastSeqBeforeDrain,
          reason: 'the last sequence the client should have — this is what '
              'lets a panel tell a frame it missed from one that never '
              'happened');
      expect(code, CloseCodes.serverDraining,
          reason: 'and the close still happened, after it. A frame spliced '
              'into the close reason instead would be a frame that arrives '
              'only if the reason fits in 123 bytes');
    });

    test('an unplanned close emits no final tick', () async {
      // Told apart by what the frame *says*, not by when it arrived.
      //
      // A close-produced tick is stamped from the session's wall clock —
      // `_writeFinalTick` does `final at = _now()` and puts that in both
      // `serverTime` and every `evaluatedAt`. An ordinary tick is stamped by
      // the tick engine from an anchor it sampled once at construction from
      // the *real* clock (`TickEngine.wallAt`: `_epochAnchor + nowMs`), and
      // this injection does not reach it. So freezing the server's wall clock
      // at a stamp no real anchor can reach makes the two sources tell
      // themselves apart, and a tick wearing [_drainStamp] is a tick the close
      // wrote.
      //
      // The arm this replaces compared indices — the last tick's index against
      // the frame count snapshotted just before the close — and that cannot
      // decide this question. The server ticks every `ServerConfig.minTick`,
      // so an ordinary tick lands between the snapshot and the close about a
      // third of the time locally and did so once on the macOS lane; it sits
      // at exactly the index a synthesised one would. Nor can the arm wait for
      // quiet first: the silence that would make an index honest is silence
      // the gateway reaps idle sessions during, and the session has to still
      // be here to be closed.
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant, now: () => _drainStamp);
      await server.start();
      final panel = await station(server, hello: false);

      // The discriminator, proven live before it is trusted. `serverTime` in
      // the handshake is read from the very `_now` that `_writeFinalTick`
      // stamps with, so this failing says "this arm can no longer see a final
      // tick", which is a different thing from "there was none" — and without
      // it a `_writeFinalTick` that changed clocks would leave an arm that
      // passes whatever the server does.
      final hello = HelloResult.fromJson(await _hello(panel.peer));
      expect(hello.serverTime, _drainStamp,
          reason: 'the frozen clock has to reach the field the final tick is '
              'stamped from, or the assertion below is vacuous');

      await panel.peer.sendRequest(Methods.subscribe,
          SubscribeParams(sub: 'page-1', keys: const [_speedKey]).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // A backpressure eviction: nothing about this close is planned, and the
      // gateway has no business claiming a sequence it did not verify anybody
      // received.
      await server.sessions.sessions.single
          .close(CloseCodes.backpressureOverrun, 'pending messages exceeded');
      await panel.closed.timeout(_dialBudget);

      expect(panel.ticks.where((t) => t.serverTime == _drainStamp), isEmpty,
          reason: 'a tick after an abrupt drop would be a claim about state '
              'nobody verified');
      expect(panel.ticks, isNotEmpty,
          reason: 'and the session really was ticking while this watched, so '
              'the emptiness above is a statement about the close rather than '
              'about a socket nothing was ever written to');
    });

    test('a drain with a long reason still closes', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server);
      await panel.peer.sendRequest(Methods.subscribe,
          SubscribeParams(sub: 'page-1', keys: const [_speedKey]).toJson());
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 300 bytes: well past the 123-byte cap, and the failure mode is
      // silent — `sink.close` throws, the throw is swallowed as "the far end
      // is already gone", and the socket simply stays open.
      final reason = 'draining for a deploy ' * 15;
      expect(utf8.encode(reason).length, greaterThan(123),
          reason: 'the fixture has to actually be over the cliff');
      await server.sessions.sessions.single
          .close(CloseCodes.serverDraining, reason);

      final code = await panel.closed.timeout(_dialBudget);
      expect(code, CloseCodes.serverDraining,
          reason: 'the clamp at the close seam is what makes this close '
              'happen at all, and the final tick must not have widened the '
              'reason\'s budget');
      expect(panel.ticks.last.subs['page-1'], isNotNull,
          reason: 'and the tick still went out, in its own frame');
    });
  });

  group('the gateway can name itself', () {
    test('hello carries publisherId when one is configured', () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant, publisherId: 'gw-north');
      await server.start();
      final panel = await station(server, hello: false);

      final result = HelloResult.fromJson(await _hello(panel.peer));
      expect(result.publisherId, 'gw-north',
          reason: 'a plant running two gateways has to be able to tell whose '
              'ST201 an alias belongs to');
    });

    test('with none configured the hello frame is byte-identical to today\'s',
        () async {
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      final server = buildServer(plant: plant);
      await server.start();
      final panel = await station(server, hello: false);

      final raw = await _hello(panel.peer);
      // The captured literal: every key the handshake answered with before
      // `publisherId` existed, and no other. Compared as a *set of names*
      // rather than as an encoded string because the values are minted per
      // session (two ULIDs and a clock) — the shape is the thing that must not
      // move, and an added key is exactly what would move it.
      expect(
          raw.keys.toSet(),
          {'protocol', 'server', 'capabilities', 'session', 'clock'},
          reason: 'additive means additive: an unconfigured deployment must '
              'pay nothing for a field it did not ask for, and `publisherId: '
              'null` on the wire is a payment');
      expect(raw.containsKey('publisherId'), isFalse);
    });

    test('the status notification carries the same value', () async {
      // The one production `StatusParams` emitter is the wiring-failure
      // notification, and it is reached by making session construction throw:
      // `RelaySession.serve` samples the clock before anything else, so a
      // clock that throws is a wiring failure with no side effects to unpick.
      // 03-REVIEW WR-06 is why this frame is worth a case at all — it used to
      // be hand-built as `{'fatal': ...}` under the `status` method, which is
      // `StatusParams`, so the one frame whose job is to explain a fatal
      // wiring failure was the one frame a conforming client could not read.
      final plant = FakeStateMan()..setValue(_speedKey, 1450);
      // Armed only after the bind: `WriteOutcomeLog` samples the clock in
      // `RelayServer`'s own constructor, and a gateway that could not be built
      // at all would never reach the seam this case is about.
      var armed = false;
      final server = buildServer(
          plant: plant,
          publisherId: 'gw-north',
          now: () => armed
              ? throw StateError('the clock is broken')
              : DateTime.now().millisecondsSinceEpoch);
      await server.start();
      armed = true;

      final ws = IOWebSocketChannel.connect(
        Uri.parse('ws://localhost:${server.port}'),
        connectTimeout: _dialBudget,
      );
      await ws.ready.timeout(_dialBudget);
      addTearDown(() => ws.sink.close().catchError((Object _) {}));
      final frame = await wsChannel(ws).stream.first.timeout(_dialBudget);

      final decoded = (jsonDecode(frame) as Map).cast<String, Object?>();
      expect(decoded['method'], Methods.status);
      final status =
          StatusParams.fromJson((decoded['params']! as Map).cast());
      expect(status.publisherId, 'gw-north',
          reason: 'a notification a client cannot attribute to a gateway is a '
              'fault report with no return address');
      expect(status.state, 'unhealthy');
      expect(status.error, isNotNull,
          reason: 'and the underlying error still rides in the field the '
              'contract has for it, not spliced into free text');
    });
  });
}

Future<Map<String, Object?>> _hello(rpc.Client peer) async {
  final answer = await peer
      .sendRequest(
          Methods.hello,
          HelloParams(
            protocol: protocolVersion,
            supported: const [protocolVersion],
            client: const PeerInfo('panel-under-test', '0.1.0'),
          ).toJson())
      .timeout(_dialBudget);
  return (answer! as Map).cast<String, Object?>();
}
