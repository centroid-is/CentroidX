/// A plant, a handle table, a registry and one tick engine — the server's
/// wiring with the sockets taken out and the clock handed over.
///
/// Every session here is built in its **production shape**: the channel's
/// sink is a [SessionSink], so an RPC answer lands in the priority lane and
/// reaches the client only when a tick drains it, exactly as
/// `relay_server.dart` wires it. A harness that handed the peer the raw
/// channel sink would answer requests instantly and quietly delete the
/// property every case in `fanout_test.dart` and `tick_test.dart` is written
/// about.
///
/// **Why in-memory and hand-cranked.** 03-RESEARCH's Wave 0 note: every core
/// in this stack takes its timestamp as a parameter, so a 400 ms freeze is
/// arithmetic rather than a sleep on a hosted runner, and fifty clients cost
/// microseconds rather than fifty ephemeral ports. The properties that need a
/// real socket — "the client received A before B" — are asserted over
/// `relayFixture` instead, and there are deliberately few of them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/frame_encoder.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/lag_monitor.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/session_sink.dart';
import 'package:tfc_relay_server/src/tick_engine.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'counting_encoder.dart';
import 'fake_clock.dart';
import 'permissive_resolver.dart';

/// Whether this panel's socket has been broken by a case.
///
/// A mutable holder rather than a `connect` flag, because a panel that threw
/// from its very first write could never complete its own hello — and the
/// failure CR-03 is about is a socket that dies *between* two ticks, on a
/// session that is fully established.
final class SocketFault {
  bool broken = false;
}

/// One connected panel, and every frame the tick engine wrote to it.
final class Panel {
  Panel(this.sub, this.session, this.client, this.buffer, this.frames,
      this._fault, this.closes);

  final String sub;
  final RelaySession session;
  final rpc.Client client;

  /// Every close code and reason the session handed its channel, in order.
  ///
  /// `RelaySession` records only the *code* it sent (`sentCloseCode`); the
  /// reason it never keeps, because in production the socket carries it and is
  /// gone. A reaper case has to read the exact sentence — "no heartbeat for
  /// N ms; the deadline is D ms" — to measure its byte length against the
  /// 123-byte RFC 6455 seam, so the harness wires the `closeChannel` seam
  /// `relay_server.dart` fills with a real socket and records what crosses it.
  final List<({int code, String reason})> closes;

  /// This session's outbound buffer, for a case that wants to load a lane
  /// without going through the plant.
  final ConflatingSendBuffer buffer;

  /// Everything [RelaySession.emit] wrote, in order — this session's wire.
  final List<String> frames;

  /// The `u` notifications received, decoded through the DTO, so a hand-spliced
  /// envelope that drifted from [UpdateParams] fails here rather than on a
  /// panel.
  List<UpdateParams> get updates => [
        for (final frame in frames)
          if (methodOf(frame) == Methods.update)
            UpdateParams.fromJson(paramsOf(frame)),
      ];

  /// The `tick` notifications received, decoded through [TickParams].
  List<TickParams> get ticks => [
        for (final frame in frames)
          if (methodOf(frame) == Methods.tick)
            TickParams.fromJson(paramsOf(frame)),
      ];

  /// The `resync` announcements received, decoded through [ResyncParams].
  List<ResyncParams> get resyncs => [
        for (final frame in frames)
          if (methodOf(frame) == Methods.resync)
            ResyncParams.fromJson(paramsOf(frame)),
      ];

  final SocketFault _fault;

  /// Makes every subsequent write to this panel throw, as a socket that died
  /// since the last tick does.
  void breakSocket() => _fault.broken = true;

  /// Where the first frame carrying [method] sits on this wire, or -1.
  /// Frame *order* is the assertion in every lane case, so it is read by
  /// index rather than by "did it arrive".
  int indexOf(String method) =>
      frames.indexWhere((frame) => methodOf(frame) == method);

  void clear() => frames.clear();
}

/// The JSON-RPC method a frame carries, or null when it is a response.
String? methodOf(String frame) =>
    (jsonDecode(frame) as Map)['method'] as String?;

/// A notification's params.
Map<String, Object?> paramsOf(String frame) =>
    ((jsonDecode(frame) as Map)['params'] as Map).cast<String, Object?>();

/// The server's wiring, minus the sockets, driven by hand.
final class Plant {
  Plant({ServerConfig? config})
      : config = config ?? ServerConfig(tick: ServerConfig.minTick) {
    addTearDown(dispose);
  }

  final api = FakeStateMan();
  final handles = HandleTable();
  final registry = SessionRegistry();
  final counter = CountingEncoder();
  final clock = FakeClock(start: 1_000_000);
  final ServerConfig config;

  late final TickEngine engine = TickEngine(
    registry: registry,
    config: config,
    encoder: FrameEncoder(encode: counter.call),
    lag: LagMonitor(
      periodMs: config.tick.inMilliseconds,
      thresholdMs: config.stallThreshold.inMilliseconds,
    ),
    clock: clock.now,
    onSessionError: (error, stack, where) =>
        errors.add((where: where, error: error)),
  );

  /// Every error the engine reported, as `(where, error)`.
  ///
  /// The engine's containment is only half a fix without somewhere for the
  /// error to land: a tick that swallowed a session's throw would look exactly
  /// like a tick that contained it (03-REVIEW CR-03 / WR-10).
  final errors = <({String where, Object error})>[];

  final _panels = <Panel>[];

  /// Every panel built through [connect], in order.
  List<Panel> get panels => List.unmodifiable(_panels);

  /// Seeds [count] keys with a value, so the source will serve them:
  /// `FakeStateMan.keys` filters to keys a value has arrived for, on purpose —
  /// otherwise a typo could launder itself into a valid binding.
  List<String> seed(int count, {String prefix = 'CN01.MOT'}) {
    final keys = [for (var i = 0; i < count; i++) '$prefix$i.speed'];
    api.setValues({for (final key in keys) key: 0});
    return keys;
  }

  /// One tick, [advance] milliseconds after the last one — the tick period by
  /// default, and a longer gap when a case is modelling a frozen event loop.
  int tick({int? advance}) {
    clock.advance(advance ?? config.tick.inMilliseconds);
    engine.tickOnce(clock.nowMs);
    return clock.nowMs;
  }

  /// A connected, helloed, subscribed panel.
  ///
  /// [now] is the SESSION's wall clock — the reported `lastSeenMs` instant —
  /// handed through to `RelaySession.serve`. [monotonicNow] is the session's
  /// LIVENESS clock, the one `silentForMs()` measures on; in production the
  /// composition root injects the engine's own uptime clock here (09-REVIEW
  /// WR-01), and a clock-domain case does the same with `plant.clock.now`.
  /// Absent, the liveness clock falls back to [now], so the F22 forgiveness
  /// arms accrue silence on the one FakeClock they crank. Absent both, the
  /// session runs on the real wall clock as before.
  Future<Panel> connect(String sub, List<String> keys,
      {ConflatingSendBuffer? buffer,
      int Function()? now,
      int Function()? monotonicNow}) async {
    final pair = channelPair();
    final lane = buffer ?? ConflatingSendBuffer(maxPending: config.maxPending);
    final frames = <String>[];
    final closes = <({int code, String reason})>[];
    final fault = SocketFault();
    final session = RelaySession.serve(
      resolver: const PermissiveSeriesResolver(),
      channel: StreamChannel<String>(pair.server.stream, SessionSink(lane)),
      api: api,
      config: config,
      handles: handles,
      buffer: lane,
      now: now,
      monotonicNow: monotonicNow,
      // What a real socket does with a close code, minus the socket: record
      // the code and reason so a reaper case can read the exact sentence.
      closeChannel: (code, reason) async => closes.add((code: code, reason: reason)),
      // Two destinations for one frame: the list a case asserts on, and the
      // far end, so the client's `Peer` can complete the request it is waiting
      // for. Both are what a socket would have done.
      emitFrame: (frame) {
        frames.add(frame);
        pair.server.sink.add(frame);
        if (fault.broken) throw StateError('socket is gone');
      },
    );
    registry.add(session);
    final client = rpc.Client(pair.client);
    unawaited(client.listen());
    final panel = Panel(sub, session, client, lane, frames, fault, closes);
    _panels.add(panel);

    await ask(
        panel,
        Methods.hello,
        HelloParams(
          protocol: protocolVersion,
          supported: const [protocolVersion],
          client: const PeerInfo('panel-under-test', '0.1.0'),
        ).toJson());
    await ask(panel, Methods.subscribe,
        SubscribeParams(sub: sub, keys: keys).toJson());
    return panel;
  }

  /// Sends a request and runs the tick that carries its answer.
  ///
  /// The tick is not the harness leaking: in the production shape the answer
  /// sits in the priority lane until something drains it, and that something
  /// is the engine.
  Future<Object?> ask(Panel panel, String method, Object? params) async {
    final pending = panel.client.sendRequest(method, params);
    await pumpEventQueue();
    tick();
    return within(pending, 'the $method answer, which reaches a client only '
        'because a tick drained the priority lane');
  }

  /// The wall-clock epoch ms the engine will stamp a frame produced at
  /// [monotonicMs] with (03-REVIEW CR-04). The band assertions are what pin
  /// the conversion to reality; this is what keeps the per-tick cases about
  /// *which* tick produced a frame.
  int wall(int monotonicMs) => engine.wallAt(monotonicMs);

  /// Clears every panel's recorded wire, so the next tick is the only thing a
  /// case is reading.
  void clearWires() {
    for (final panel in _panels) {
      panel.clear();
    }
  }

  Future<void> dispose() async {
    for (final panel in _panels) {
      await panel.client.close();
      await panel.session.close(1000, 'test over');
    }
    _panels.clear();
    await engine.stop();
    await registry.dispose();
    await api.dispose();
  }
}
