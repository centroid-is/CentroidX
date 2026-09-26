/// The gateway half of hold-to-run, judged where it can hurt somebody.
///
/// Three properties, and none of them is "the feature works" — that is
/// asserted next door in `value_handlers_test.dart`, where the write path's
/// hold branch is judged as a handler body. What is here is what happens when
/// the hold is fed by the wrong peer, by nobody, or after the panel has gone
/// home:
///
///  * **The tick is an authorization boundary** (D-P5-G, T-05-16). `'h'` is an
///    un-idded, unanswered frame that moves a plant tag, and the only thing
///    standing between it and a write primitive is the per-session hold map.
///    A tick naming a key this session never engaged is dropped, counted, and
///    never answered — silently, because a throw at 10 Hz is a log flood
///    (`json_rpc_2` hands a notification's exception to `onUnhandledError`
///    rather than to the client; measured, 05-RESEARCH §B.1 #2).
///  * **A hold dies with the session** (T-05-20). The map is per-session state
///    on `ValueHandlers`, so `RelaySession._teardown` — the one body every way
///    of ending a session arrives at — releases every hold it engaged. A hold
///    that outlived its socket is a machine fed by nobody.
///  * **Nothing advances a counter but a tick** (D-P5-J, assumption A5).
///    05-RESEARCH §G.4 argued the gateway needs no expiry timer of its own,
///    because if ticks stop the counter stops and the PLC's ~1 s deadman drops
///    the output. That argument has a premise — *no ticks means no advance* —
///    and the last group in this file is the standing proof that the premise
///    is true of the code and not only of the reasoning. It is the assumption
///    in that document with the highest consequence if wrong: a wedged gateway
///    driving a counter with nobody feeding it is a machine running
///    unattended.
///
/// **Why the counter the plant sees is the gateway's and not the frame's.**
/// The tick frame carries `n`, and this handler decodes it, validates it, and
/// then does not use it as the value: the advance is `HoldHandle.tick()`,
/// which mints the next value from the handle the *engage* created. That is
/// deliberate. Trusting `n` would let any peer past the handshake put an
/// arbitrary integer on a deadman tag through a path with no cmd, no outcome
/// and no refusal — which is the same door the write path's "a hold write
/// carrying 7 is refused" closes from the other side.
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/value_handlers.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/bands.dart';
import 'support/fake_clock.dart';
import 'support/panels.dart';
import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

/// A clock far enough from zero that a ULID minted on it is a plausible id.
const int _epochStart = 1_760_000_000_000;

const String _key = 'CN01.MOT01.jog';

/// One session over an in-memory channel, with the client's end tapped.
///
/// The channel's sink is the raw pair end rather than a [SessionSink], so an
/// answer comes back without a tick having to drain it — every case here is
/// about what the *handler* did, and the lane's pacing is `fanout_test.dart`'s
/// subject. The tap is what lets a case assert that a refused notification
/// produced no frame at all, which no `Peer` API can report.
final class _Gate {
  _Gate(this.session, this.client, this.api, this.clock, this.inbound,
      this.errors);

  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;
  final FakeClock clock;

  /// Every frame the server sent this client, in order.
  final List<String> inbound;

  /// Everything the session's `RelayErrorHandler` was told about.
  ///
  /// The stack is kept as well as the message: a condition an unauthenticated
  /// peer can produce at will must not carry one (05-REVIEW WR-03), and the
  /// only way to assert that is to look.
  final List<({String where, Object error, StackTrace stack})> errors;

  Future<Object?> ask(String method, Object? params) => within(
      client.sendRequest(method, params), 'the $method answer from the gateway');

  /// Sends one client→server notification and lets it be dispatched.
  Future<void> notify(String method, Object? params) async {
    client.sendNotification(method, params);
    await pumpEventQueue();
  }

  Future<void> hello() => ask(
      Methods.hello,
      HelloParams(
        protocol: protocolVersion,
        supported: const [protocolVersion],
        client: const PeerInfo('panel-under-test', '0.1.0'),
      ).toJson());

  /// Engages a hold on [key] through the wire, and returns the outcome.
  Future<WriteResult> engage(String key) async {
    final answer = await ask(Methods.write, {
      'cmd': newUlid(nowMs: clock.nowMs),
      'key': key,
      'value': 1,
      'hold': true,
    });
    return WriteResult.fromJson((answer! as Map).cast<String, Object?>());
  }

  int? valueOf(String key) => api.read(key)?.value as int?;
}

_Gate _gate() {
  final pair = channelPair();
  final api = FakeStateMan();
  final clock = FakeClock(start: _epochStart);
  final inbound = <String>[];
  final errors = <({String where, Object error, StackTrace stack})>[];
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    now: clock.now,
    onError: (error, stack, where) =>
        errors.add((where: where, error: error, stack: stack)),
  );
  final client = rpc.Client(StreamChannel<String>(
      pair.client.stream.map((frame) {
        inbound.add(frame);
        return frame;
      }),
      pair.client.sink));
  unawaited(client.listen().catchError((Object _) => null));
  addTearDown(() async {
    await client.close();
    await session.close(1000, 'hold gateway test over');
    await api.dispose();
  });
  return _Gate(session, client, api, clock, inbound, errors);
}

void main() {
  group('the tick is an authorization boundary', () {
    test('a tick for a key this session never engaged is dropped and counted',
        () async {
      final gate = _gate();
      await gate.hello();
      gate.api.setValue(_key, 5);

      await gate.notify(Methods.holdTick, {'k': _key, 'n': 2});

      expect(gate.valueOf(_key), 5,
          reason: 'the handler writes only through a HoldHandle this '
              'session\'s own engage created. It never writes the key the '
              'frame names, or `h` would be a write primitive with no engage '
              'in front of it (T-05-16)');
      expect(gate.session.droppedHoldTicks, 1,
          reason: 'dropped is not the same as ignored: the drop is counted, '
              'because a panel feeding a hold the gateway does not have is a '
              'real failure and the count is what Phase 8 will surface as a '
              'PIPE.* health key');
      expect(gate.errors, isEmpty,
          reason: 'an unknown hold is an ordinary, expected condition — a '
              'throw here reaches onUnhandledError, not the client, and at '
              '10 Hz that is a log flood (05-RESEARCH §B.1 #2)');
    });

    test('a malformed tick is dropped and counted, and the session keeps '
        'answering ordinary requests', () async {
      final gate = _gate();
      await gate.hello();
      gate.api.setValue(_key, 5);

      await gate.notify(Methods.holdTick, {'k': _key, 'n': 'seven'});

      expect(gate.session.droppedHoldTicks, 1,
          reason: 'a frame that cannot be decoded is a dropped tick like any '
              'other; refusing it would buy a refusal nobody will ever see');
      expect(gate.errors, isEmpty);

      final answer = ((await gate.ask(Methods.read, {'key': _key}))! as Map)
          .cast<String, Object?>();
      expect(WireValue.fromJson((answer['value']! as Map).cast()).v, 5,
          reason: 'the peer must survive a bad notification (§B.1 #4): a '
              'session that died on a malformed tick would take every '
              'subscription on that panel with it');
    });

    test('a tick before hello is dropped, counted, and complained about once',
        () async {
      // D-P5-H, as amended by 05-REVIEW WR-03. A pre-hello tick is refused —
      // correctly, since there is no hold to feed — and the refusal is
      // *invisible* to the peer, because the frame has no id for a response
      // to name. What changed is how the gateway records it: the refusal used
      // to be thrown, and a notification's exception goes to
      // `onUnhandledError`, which means one exception and one full stack
      // trace per frame from a peer that has not authenticated. It is now
      // dropped and counted like every other tick the handler cannot use,
      // with one summary line for the session.
      final gate = _gate();
      gate.api.setValue(_key, 5);

      await gate.notify(Methods.holdTick, {'k': _key, 'n': 2});

      expect(gate.inbound, isEmpty,
          reason: 'json_rpc_2 returns before building a response for a frame '
              'with no id, so a refused notification tells an unauthenticated '
              'peer nothing at all');
      expect(gate.session.droppedHoldTicks, 1,
          reason: 'dropped is not the same as ignored. A pre-hello tick is a '
              'frame that reached a handler and did nothing, which is exactly '
              'what droppedHoldTicks counts — and the one number Phase 8 will '
              'surface should not have a hole in it where the unauthenticated '
              'peers go');
      expect(gate.errors, hasLength(1),
          reason: 'the condition is worth exactly one line: it is reachable '
              'by anyone who completes the WebSocket upgrade, so a report per '
              'frame is a peer choosing how much the gateway logs');
      expect('${gate.errors.single.error}', contains('before hello'),
          reason: 'the line has to say what was dropped and why, because it '
              'is the only trace of a peer that never authenticated: '
              '${gate.errors.single.error}');
      expect(gate.errors.single.stack, StackTrace.empty,
          reason: 'a stack trace here points at json_rpc_2\'s dispatch and '
              'says nothing the message does not, and reportToStderr writes '
              'the whole of it. Empty is how this file says "the line is the '
              'report"');
      expect(gate.valueOf(_key), 5);
    });

    test('a pre-hello tick flood is one complaint and does not keep the '
        'session alive', () async {
      // 05-REVIEW WR-03, the flood the case above is the unit of. An
      // unauthenticated peer that completes the upgrade and sends `h` at line
      // rate used to drive one exception plus one full stack trace to the
      // gateway's stderr per frame — the log volume that fills a plant
      // gateway's disk or drowns the line an operator needs — *and* keep its
      // own session out of the reaper's reach while doing it.
      final gate = _gate();
      gate.api.setValue(_key, 5);

      gate.clock.advance(const Duration(seconds: 10).inMilliseconds);
      expect(gate.session.silentForMs(), 10000,
          reason: 'anti-vacuity: with nothing arriving the session is silent '
              'and the reaper would eventually take it');

      for (var i = 0; i < 100; i++) {
        gate.client.sendNotification(Methods.holdTick, {'k': _key, 'n': i + 2});
      }
      await pumpEventQueue();

      expect(gate.session.droppedHoldTicks, 100,
          reason: 'every frame was counted');
      expect(gate.errors, hasLength(1),
          reason: 'a hundred frames produced ${gate.errors.length} reports. '
              'The complaint is per session, not per frame — otherwise the '
              'peer decides how big the log gets');
      expect(gate.session.silentForMs(), 10000,
          reason: 'the flood fed the session\'s own liveness, so a peer that '
              'never says hello holds its session open indefinitely by '
              'shouting at a gate that keeps refusing it. A frame the *gate* '
              'refuses is not evidence of a client worth keeping — the '
              'handshake is what makes an inbound frame mean that');
      expect(gate.valueOf(_key), 5);
      expect(gate.inbound, isEmpty);
    });

    test('the handshake starts the heartbeat clock', () async {
      // The other half of gating the liveness tap: a session whose lastSeen
      // stopped moving pre-hello must be given the clock back the moment the
      // handshake lands, or a panel that took its time connecting would be
      // reaped for the silence that preceded its own hello.
      final gate = _gate();

      gate.clock.advance(const Duration(seconds: 10).inMilliseconds);
      await gate.hello();

      expect(gate.session.silentForMs(), 0,
          reason: 'the session has been silent for '
              '${gate.session.silentForMs()} ms immediately after a '
              'successful handshake');
    });

    test('a hundred unknown-hold ticks cost a map lookup each and nothing else',
        () async {
      // T-05-17 / T-05-18. Rate limiting is a Phase 6/7 question and is
      // deliberately not built here; what is built is a handler that is O(1),
      // allocation-light and incapable of throwing, so a flood costs a map
      // lookup per frame instead of a hundred stack traces.
      final gate = _gate();
      await gate.hello();
      gate.api.setValue(_key, 5);

      final started = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        gate.client.sendNotification(Methods.holdTick, {'k': _key, 'n': i + 2});
      }
      await pumpEventQueue();
      started.stop();

      expect(gate.session.droppedHoldTicks, 100,
          reason: 'every frame was counted, and none of them moved the tag');
      expect(gate.valueOf(_key), 5);
      expect(gate.errors, isEmpty,
          reason: 'a hundred throws is a hundred onUnhandledError calls into '
              'the RelayErrorHandler — the 10 Hz log flood §B.1 #2 warns '
              'about, and the reason this handler cannot throw at all');

      final answer = ((await gate.ask(Methods.read, {'key': _key}))! as Map)
          .cast<String, Object?>();
      expect(WireValue.fromJson((answer['value']! as Map).cast()).v, 5,
          reason: 'the session answers ordinary requests after the flood');
      // Not an assertion — a floor of a few hundred ms would be a measurement
      // of the runner, not of the handler. The number is recorded in the
      // plan's SUMMARY as the cost evidence T-05-17 asks for.
      printOnFailure('100 dropped ticks in ${started.elapsedMilliseconds} ms '
          'on $platformName');
    });
  });

  group('a hold dies with the session', () {
    test('closing the session releases every hold it engaged', () async {
      final gate = _gate();
      await gate.hello();
      gate.api.setValue(_key, 0);
      gate.api.setValue('CN02.MOT01.jog', 0);
      expect(await gate.engage(_key), isA<WriteApplied>());
      expect(await gate.engage('CN02.MOT01.jog'), isA<WriteApplied>());
      await gate.notify(Methods.holdTick, {'k': _key, 'n': 2});
      expect(gate.valueOf(_key), 2,
          reason: 'anti-vacuity: the holds are live and being fed at the '
              'moment the session is closed');

      await gate.session.close(1000, 'the panel went home');
      await pumpEventQueue();

      expect(gate.valueOf(_key), 0,
          reason: 'the teardown released the hold, which stops the counter '
              'and writes the 0 that says released. A hold outliving its '
              'socket is a machine fed by nobody (T-05-20)');
      expect(gate.valueOf('CN02.MOT01.jog'), 0,
          reason: '*every* hold, not the first one: the map is cleared, and a '
              'second jog axis left running would be the same hazard with a '
              'different tag name');
    });

    test('a held button keeps the heartbeat reaper quiet', () async {
      // T-05-22, accepted rather than mitigated, and asserted so that it
      // reads as a decision. `_lastSeen` is tapped on any inbound frame, so a
      // 10 Hz tick stream suppresses `heartbeatTimeout` for as long as the
      // button is held. That is correct — the peer demonstrably is alive, and
      // reaping a panel whose operator has a finger on a jog button would be
      // the worst possible moment to drop a session.
      final gate = _gate();
      await gate.hello();
      gate.api.setValue(_key, 0);
      expect(await gate.engage(_key), isA<WriteApplied>());

      gate.clock.advance(const Duration(seconds: 10).inMilliseconds);
      expect(gate.session.silentForMs(), 10000,
          reason: 'anti-vacuity: with nothing arriving the session is silent '
              'and the reaper would eventually take it');

      await gate.notify(Methods.holdTick, {'k': _key, 'n': 2});

      expect(gate.session.silentForMs(), 0,
          reason: 'the tick is an inbound frame and it moves lastSeen like '
              'any other. A held button is a live panel, and this is the '
              'gateway agreeing');
      expect(gate.valueOf(_key), 2,
          reason: 'and the tick did its actual job on the way past');
    });
  });

  // Assumption A5, and the condition attached to accepting it. Every arm
  // below asserts that a number did **not** change, which is exactly the
  // shape of case that passes for free against an implementation where
  // nothing works — so each one ticks the counter to 2 first and asserts it
  // moved. The property is not "it does not start", it is "it does not
  // continue".
  group('nothing advances a counter but a tick', () {
    test('an unfed hold does not advance across two hundred engine cycles',
        () async {
      // The fake-clock arm. A self-advancing counter hiding in the server's
      // one repeating timer would be driven by exactly this seam: the engine
      // is stepped by hand with `tickOnce`, ten seconds of fake time per
      // window, which is ten times the PLC's deadman.
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CN01.JOG');
      final key = keys.single;
      final panel = await plant.connect('page-1', keys);

      final engaged = WriteResult.fromJson(((await plant.ask(panel,
              Methods.write, {
        'cmd': newUlid(),
        'key': key,
        'value': 1,
        'hold': true,
      }))! as Map)
          .cast<String, Object?>());
      expect(engaged, isA<WriteApplied>());
      expect(plant.api.read(key)?.value, 1);

      final ticksBefore = plant.engine.ticks;
      for (var i = 0; i < 200; i++) {
        plant.tick();
      }

      expect(plant.engine.ticks - ticksBefore, 200,
          reason: 'anti-vacuity for the driver: the engine really did run 200 '
              'cycles over this window');
      expect(plant.api.read(key)?.value, 1,
          reason: 'ten seconds of gateway time with nobody feeding the hold, '
              'and the tag holds exactly the engage value. A gateway that '
              'advanced it here would be jogging a machine on its own '
              'authority');

      panel.client.sendNotification(Methods.holdTick, {'k': key, 'n': 2});
      await pumpEventQueue();

      expect(plant.api.read(key)?.value, 2,
          reason: 'the anti-vacuity arm, and it matters more here than usual: '
              'an adversarial case that asserts nothing happened passes '
              'trivially against an implementation where nothing works');

      for (var i = 0; i < 200; i++) {
        plant.tick();
      }

      expect(plant.api.read(key)?.value, 2,
          reason: 'and it does not continue either: the counter is exactly '
              'the last tick received, forever');
    });

    test('an unfed hold does not advance while a real wall clock runs',
        () async {
      // The wall-clock arm. The fake clock cannot see a timer somebody added
      // to the session or to the handlers — that timer would fire on real
      // time regardless of what `tickOnce` is told.
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_key, 0);

      final engaged = WriteResult.fromJson(((await fixture.request(
              Methods.write,
              params: {
                'cmd': newUlid(),
                'key': _key,
                'value': 1,
                'hold': true,
              },
              what: 'the engage outcome over a real socket'))! as Map)
          .cast<String, Object?>());
      expect(engaged, isA<WriteApplied>());
      expect(fixture.served.read(_key)?.value, 1);

      final window = ceiling * 2;
      final seen = await _sample(fixture, window);

      expect(fixture.server.engine?.running, isTrue,
          reason: 'anti-vacuity for the driver: the server\'s one repeating '
              'timer was running for the whole window');
      expect(seen, {1},
          reason: 'every sample across ${window.inMilliseconds} ms on '
              '$platformName read exactly the engage value. Sampled rather '
              'than read once at the end, so a counter that advanced and was '
              'put back cannot pass');

      fixture.client.sink.add(jsonEncode({
        'jsonrpc': '2.0',
        'method': Methods.holdTick,
        'params': {'k': _key, 'n': 2},
      }));
      await _until(() => fixture.served.read(_key)?.value == 2,
          'the tick to reach the tag');

      expect(fixture.served.read(_key)?.value, 2,
          reason: 'the anti-vacuity arm: the hold is live and one tick moves '
              'it by exactly one');

      expect(await _sample(fixture, window), {2},
          reason: 'and then it stops again, for as long as nobody feeds it');
    }, tags: 'ws');

    test('an unfed hold does not advance across an hour of handler time',
        () async {
      // The handler-level arm: no socket, no engine, no timer anywhere in the
      // picture. If `ValueHandlers` grew a cadence of its own this is where it
      // would show, and an hour of it costs nothing because the clock is
      // arithmetic.
      final api = FakeStateMan();
      addTearDown(api.dispose);
      final clock = FakeClock(start: _epochStart);
      final handlers = ValueHandlers(
        api: api,
        config: ServerConfig(),
        now: clock.now,
      );
      api.setValue(_key, 0);

      final engaged = WriteResult.fromJson(
          ((await handlers.write(rpc.Parameters(Methods.write, {
        'cmd': newUlid(nowMs: clock.nowMs),
        'key': _key,
        'value': 1,
        'hold': true,
      })))! as Map)
              .cast<String, Object?>());
      expect(engaged, isA<WriteApplied>());
      expect(api.read(_key)?.value, 1);

      clock.advance(const Duration(hours: 1).inMilliseconds);
      await pumpEventQueue();

      expect(api.read(_key)?.value, 1,
          reason: 'an hour on the gateway\'s clock, and the deadman counter '
              'is where the operator left it');
      expect(handlers.droppedHoldTicks, 0,
          reason: 'nothing was dropped either, so the stillness is the '
              'absence of ticks and not a handler quietly refusing them');

      await handlers.holdTick(
          rpc.Parameters(Methods.holdTick, {'k': _key, 'n': 2}));

      expect(api.read(_key)?.value, 2,
          reason: 'the anti-vacuity arm: the handle is still live an hour '
              'later, and a tick still feeds it');
    });
  });
}

/// Reads the tag every few milliseconds for [window], and hands back every
/// distinct value seen.
///
/// A window rather than an instant, per the package's band convention: what
/// is being asserted is that nothing moved *during* the window, and a single
/// read at the end cannot tell that from a value that moved and came back.
Future<Set<int?>> _sample(RelayFixture fixture, Duration window) async {
  final seen = <int?>{};
  final until = Stopwatch()..start();
  while (until.elapsed < window) {
    seen.add(fixture.served.read(_key)?.value as int?);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  seen.add(fixture.served.read(_key)?.value as int?);
  return seen;
}

/// Waits for [ready] inside the platform's ceiling, naming what was waited on.
Future<void> _until(bool Function() ready, String what) async {
  final waited = Stopwatch()..start();
  while (!ready()) {
    if (waited.elapsed > ceiling * 4) {
      fail('$what did not happen within ${(ceiling * 4).inMilliseconds} ms on '
          '$platformName');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
