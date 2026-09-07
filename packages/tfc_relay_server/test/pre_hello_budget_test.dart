/// WSH-13 / S10, the half that is fixable: **a peer that completes the TLS
/// upgrade and never authenticates costs the gateway something, and what it
/// costs must be bounded in time and in count.**
///
/// The token file gates `hello`, not the upgrade (`relay_server.dart`'s
/// `_onConnect` consults no credential), so anything that can reach the port
/// gets a session built for it — a `ConflatingSendBuffer`, a `SessionSink`, a
/// per-session health overlay and a `Peer` — before it has said who it is.
/// Until this file existed the only bound on that was `heartbeatDeadline`,
/// 6 s by default, because `_LastSeen.touch` refuses to move until the session
/// has helloed. Six seconds is a long time to hold a stranger's allocation,
/// and nothing at all bounded how many strangers there could be:
/// `_connections` is a plain `List` and `_onConnect` refused only while the
/// server was closing.
///
/// ## The residual this file deliberately does not reproduce
///
/// `maxFrameBytes` is enforced on the **decoded string**
/// (`relay_session.dart`'s `_underCeiling`), i.e. after `dart:io` has already
/// assembled and decoded the whole WebSocket message in heap. Neither
/// `dart:io` nor `shelf_web_socket` 3.0.0 exposes an incoming frame-size cap,
/// so there is no earlier place to put it — checked in both packages' source,
/// not assumed. That means one assembled frame per un-helloed connection, up
/// to `maxFrameBytes`, still lands in memory before anything can judge it.
///
/// **There is no arm here that sends hundreds of megabytes**, and that is a
/// decision rather than an omission: the residual is not fixable at this
/// layer, and a case that allocated it would kill the CI runner it ran on
/// while proving something already known. What this file bounds is the
/// *volume* — the deadline and the cap below — and the residual is written
/// down where it bites, at `_underCeiling`'s doc, with the platform reason.
/// The product of the two numbers is the honest exposure: at the shipping
/// defaults, [_cap] un-helloed connections times a 1 MiB ceiling.
///
/// ## Both directions, on purpose
///
/// Arms 1 and 2 say the bounds bite. Arms 3, 4 and 5 say they do not
/// over-bite, and they are not decoration — a pre-hello deadline of one
/// millisecond satisfies arm 1 perfectly while disconnecting every panel in
/// the plant before it can speak, and a cap that counted *sessions* rather
/// than *un-helloed sessions* satisfies arm 2 while capping the plant at
/// [_cap] screens. The 14-13 house rule applies: a bound is pinned only when
/// a mutation in each direction turns something red.
///
/// Timing here is wall-clock and says so. There is no injected clock behind
/// the pre-hello deadline — it is a one-shot `Timer` on the connection — and
/// a test that faked one would be measuring the fake. Windows are asserted
/// against `bands.dart`, never instants.
@TestOn('vm')
@Tags(['ws'])
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/bands.dart';
import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

// ---------------------------------------------------------------------------
// The numbers, and where each one comes from.
// ---------------------------------------------------------------------------

/// The shipping cap on concurrent un-helloed sessions these arms are written
/// against.
///
/// A literal rather than `ServerConfig().maxUnhelloedSessions`, for two
/// reasons that both matter. It had to compile *before* that field existed —
/// the RED run is the evidence, and an arm that could not run until the fix
/// landed proves nothing about the fix. And an arm asserted against the
/// constant it is testing is a tautology: changing the default would keep it
/// green while the property it describes silently moved.
/// `server_config_test.dart` pins the default to this same number, so the two
/// cannot drift without something going red.
const _cap = 64;

/// The pre-hello deadline at the shipping defaults.
///
/// Also a literal, for the same reason. It is a third of the 6 s
/// `heartbeatDeadline` default, which puts it below
/// `ServerConfig.defaultMinHeartbeatDeadline` (3 s) — so it is shorter than
/// *any* heartbeat deadline a real gateway is allowed to run, not merely
/// shorter than the default one.
const _preHello = Duration(seconds: 2);

/// The heartbeat deadline at the shipping defaults, which arm 1 must beat by
/// a margin rather than by a hair.
const _heartbeat = Duration(seconds: 6);

/// The close code an un-helloed peer is closed with when its deadline expires.
///
/// A literal, and this one deliberately stays a literal for good: a wire
/// number asserted against its own constant is a tautology, and renumbering
/// the code would keep this arm green while every deployed gateway's close
/// ledger changed meaning underneath it.
const _preHelloTimeoutCode = 4006;

/// The close code a connection over the un-helloed budget is refused with.
/// Literal for the same reason as [_preHelloTimeoutCode].
const _unhelloedBudgetCode = 4007;

/// How long arm 3's legitimate-but-slow panel takes to get its `hello` out.
///
/// Derived rather than round. What has to fit between the upgrade completing
/// and the `hello` frame arriving at the gateway is three terms:
///
///  * **The frame on the wire.** On the slowest link this project has measured
///    a panel over — `slow_link_gate_test.dart`'s hundred-kilobit control,
///    12 500 B/s — a `hello` carrying a token is about 300 bytes, so **24 ms**.
///    Bandwidth is not the term that matters here, which is worth saying
///    because it is the term that looks like it should be.
///  * **The panel's own scheduling.** A Flutter panel that has just finished a
///    TLS handshake is also building its first page. `ClientConfig`'s
///    `connectTimeout` doc calls its own 10 s "a generous hang guard rather
///    than a tight bound" for exactly this reason: the client end of this
///    handshake is not a tight loop, and sizing a server deadline as if it
///    were is how a defence becomes a denial of service against the plant.
///  * **A retransmit round trip** on a link whose SYN/ACK already took
///    hundreds of milliseconds.
///
/// 1200 ms is far past all three and still has 800 ms of room inside
/// [_preHello] — which is the margin the default is supposed to have. It is a
/// real wait, and it is the price of the arm that makes sabotage (b) possible.
const _slowPanel = Duration(milliseconds: 1200);

/// How long a reap may take: the deadline, the tick that would sweep for it,
/// and the platform's band. `liveness_test.dart`'s `_reapCeiling`, same shape.
final _preHelloCeiling = _preHello + ServerConfig.minTick + ceiling;

/// Generously above [_preHelloCeiling] *and* above [_heartbeat], so a missing
/// pre-hello deadline fails on the assertion that names the window it missed
/// — reporting the instant it actually closed — rather than on a timeout that
/// names nothing. That is what makes the RED run readable.
const _closeBudget = Duration(seconds: 9);

/// How long a connection that must NOT be closed is watched before it is
/// believed. Long enough that a refusal in flight would have landed; short
/// enough that five arms of it are not the suite's runtime.
const _survivalBudget = Duration(milliseconds: 400);

/// How long a connection over the budget has to be refused in.
///
/// Deliberately far below [_preHello] and [_heartbeat], because *when* the
/// refusal arrives is half of what "refused loudly" means. The budget check
/// runs synchronously inside `_onConnect`, so a second is generous by three
/// orders of magnitude — and a close that only turns up after it is not a
/// refusal at all, it is the connection being accepted and then reaped later
/// by a deadline that was never about the budget. Those two look identical to
/// an arm that only asks "did it close eventually", and they are opposite
/// facts about the gateway.
const _refusalBudget = Duration(seconds: 1);

const _dialBudget = Duration(seconds: 10);
const _rpcBudget = Duration(seconds: 5);

// ---------------------------------------------------------------------------
// One gateway, and as many raw panels as an arm wants.
// ---------------------------------------------------------------------------

/// A gateway with no fixture client attached, so an arm decides exactly how
/// many peers exist and which of them ever authenticate.
///
/// `relayFixture` connects one client of its own, which would spend a slot of
/// the very budget arms 2, 4 and 5 are counting.
final class _Gateway {
  _Gateway._(this.server, this._served);

  final RelayServer server;
  final FakeStateMan _served;
  final _panels = <_Panel>[];

  int get sessionCount => server.sessions.sessionCount;

  /// Opens one raw WebSocket and returns before saying anything on it.
  Future<_Panel> dial() async {
    final panel = await within(_Panel._dial(server.port),
        'a raw client completing the WebSocket upgrade',
        budget: _dialBudget);
    _panels.add(panel);
    return panel;
  }

  /// Opens [n] raw sockets at once.
  ///
  /// Concurrently rather than in a loop, and that is load-bearing: every arm
  /// that opens a batch has to finish opening it inside the pre-hello
  /// deadline, or the gateway starts reaping the head of the batch while the
  /// tail is still connecting and the arm reads its own slowness as the
  /// behaviour under test.
  Future<List<_Panel>> dialAll(int n) async {
    final panels = await within(
        Future.wait([for (var i = 0; i < n; i++) _Panel._dial(server.port)]),
        '$n raw clients completing the WebSocket upgrade',
        budget: _dialBudget);
    _panels.addAll(panels);
    return panels;
  }

  /// Completes when the gateway is holding exactly [n] sessions.
  ///
  /// Event-driven off the registry's own two streams. A poll loop here would
  /// be a timing assertion wearing a helper's clothes
  /// (`ws_harness.dart`'s `untilNoSessions`, same argument).
  Future<void> untilSessions(int n, {Duration budget = _dialBudget}) async {
    if (sessionCount == n) return;
    final reached = Completer<void>();
    void check() {
      if (!reached.isCompleted && sessionCount == n) reached.complete();
    }

    final opened = server.sessions.opened.listen((_) => check());
    final gone = server.sessions.gone.listen((_) => check());
    check();
    try {
      await within(reached.future, 'the gateway to be holding $n sessions',
          budget: budget);
    } finally {
      await opened.cancel();
      await gone.cancel();
    }
  }

  Future<void> teardown() async {
    for (final panel in _panels) {
      await panel.dispose();
    }
    _panels.clear();
    await server.close();
    await _served.dispose();
  }
}

_Gateway _gateway({ServerConfig? config}) {
  final served = FakeStateMan();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: config ?? fixtureConfig(),
    // These arms provoke refusals on purpose; a collector that printed each
    // one would train everyone to scroll past them.
    onError: (_, __, ___) {},
  );
  final gateway = _Gateway._(server, served);
  addTearDown(gateway.teardown);
  return gateway;
}

/// Starts [gateway]'s server and hands it back, ready to dial.
Future<_Gateway> _started({ServerConfig? config}) async {
  final gateway = _gateway(config: config);
  await gateway.server.start();
  return gateway;
}

/// One raw peer: a socket, an RPC client over it, and the close it observed.
final class _Panel {
  _Panel._(this._ws, this._peer, this._done);

  final WebSocketChannel _ws;
  final rpc.Client _peer;
  final Future<void> _done;

  static Future<_Panel> _dial(int port) async {
    final ws = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$port'));
    await ws.ready;
    final done = Completer<void>();
    final base = wsChannel(ws);
    final tapped = base.stream.transform(
        StreamTransformer<String, String>.fromHandlers(handleDone: (sink) {
      if (!done.isCompleted) done.complete();
      sink.close();
    }));
    final peer = rpc.Client(StreamChannel<String>(tapped, base.sink));
    // Swallowed for `ws_harness.dart:333-335`'s reason: a channel failure must
    // fail the arm that named the property, not arrive as an unhandled zone
    // error attributed to an unrelated case.
    unawaited(peer.listen().catchError((Object _) => null));
    return _Panel._(ws, peer, done.future);
  }

  /// Says `hello` and returns the negotiated result.
  Future<HelloResult> hello({Duration budget = _rpcBudget}) async {
    final raw = await within(_peer.sendRequest(Methods.hello, helloParams()),
        'the hello result over a real socket',
        budget: budget);
    return HelloResult.fromJson((raw as Map).cast<String, Object?>());
  }

  /// The close this peer observed, or null if it is still open after [budget].
  ///
  /// Null rather than a failure, so the arm that wants a close and the arm
  /// that wants survival can both read the same helper and both fail on their
  /// own sentence.
  Future<ClientClose?> closeWithin(Duration budget) async {
    try {
      await _done.timeout(budget);
    } on TimeoutException {
      return null;
    }
    // `closeCode` is populated by the same event that ends the stream, but
    // that ordering is the socket implementation's business rather than a
    // documented contract (`ws_harness.dart:178-181`).
    if (_ws.closeCode == null) await pumpEventQueue(times: 1);
    return ClientClose(_ws.closeCode, _ws.closeReason);
  }

  Future<void> dispose() async {
    await _peer.close().catchError((Object _) {});
    await _ws.sink.close().catchError((Object _) {});
  }
}

void main() {
  group('WSH-13 — the pre-hello surface is bounded in time', () {
    test('arm 1: an un-helloed peer is closed on its own deadline, well '
        'before the heartbeat one', () async {
      final gateway = await _started();
      final panel = await gateway.dial();
      await gateway.untilSessions(1);

      // From here the peer says nothing at all. Its socket is perfectly
      // healthy — this is not a half-open link, it is a stranger holding an
      // allocation.
      final silence = Stopwatch()..start();
      final close = await panel.closeWithin(_closeBudget);
      silence.stop();

      // Reported, not just asserted: a window that passes tells you nothing
      // about how much room it had, and in the RED run this line is the whole
      // finding.
      print('un-helloed peer: closed ${silence.elapsedMilliseconds} ms after '
          'the upgrade, against a ${_preHello.inMilliseconds} ms pre-hello '
          'deadline, a ${_heartbeat.inMilliseconds} ms heartbeat deadline and '
          'a ${_preHelloCeiling.inMilliseconds} ms $platformName window');

      expect(close, isNotNull,
          reason: 'the peer was still connected after '
              '${_closeBudget.inMilliseconds} ms having never authenticated. '
              'A gateway that holds a stranger\'s session buffer, sink, health '
              'overlay and Peer indefinitely has no pre-hello bound at all');

      expect(silence.elapsed, lessThan(_preHelloCeiling),
          reason: 'closed after ${silence.elapsedMilliseconds} ms; the '
              'pre-hello deadline is ${_preHello.inMilliseconds} ms and the '
              '$platformName window for noticing it is '
              '${_preHelloCeiling.inMilliseconds} ms. A close that lands '
              'outside it is the heartbeat reaper doing the job, not a '
              'pre-hello deadline');
      expect(silence.elapsed * 2, lessThan(_heartbeat),
          reason: 'and it must beat the ${_heartbeat.inMilliseconds} ms '
              'heartbeat deadline by more than a hair — a bound that merely '
              'coincides with the one that already existed adds nothing, and '
              'is indistinguishable from having done nothing');
      expect(silence.elapsed, greaterThan(_preHello - slack),
          reason: 'closed after only ${silence.elapsedMilliseconds} ms. A '
              'deadline that fires early is not a defence, it is a gateway '
              'that disconnects panels before they can speak');

      expect(close!.closeCode, _preHelloTimeoutCode,
          reason: 'the close ledger records codes, not sentences, so the code '
              'is the only thing that tells an operator "this peer never '
              'authenticated" from "this panel went quiet". 4003 for both '
              'would send them looking at a heartbeat that was never sent');
      expect(close.closeReason, contains('hello'),
          reason: 'and the reason an operator reads should name the handshake '
              'that did not happen');
      expect(close.closeReason, isNot(contains('heartbeat')),
          reason: 'a pre-hello close described as a heartbeat timeout is the '
              'wrong diagnosis in the operator\'s hand: it points at the '
              'panel\'s beat, which was never due');
    });

    test('arm 3: a slow but legitimate panel is not caught', () async {
      final gateway = await _started();
      final panel = await gateway.dial();
      await gateway.untilSessions(1);

      // A real wait, not a fake clock: see [_slowPanel] for the three terms it
      // is sized from.
      await Future<void>.delayed(_slowPanel);

      expect(await panel.closeWithin(Duration.zero), isNull,
          reason: 'a panel that took ${_slowPanel.inMilliseconds} ms to get '
              'its hello out — well inside the ${_preHello.inMilliseconds} ms '
              'deadline — was disconnected before it could send it. This is '
              'the direction that turns a defence into an outage: every arm '
              'about the deadline biting is also satisfied by a deadline of '
              'one millisecond');

      final result = await panel.hello();
      expect(result.sessionId, isNotEmpty,
          reason: 'and it authenticated normally once it did speak');
      expect(gateway.sessionCount, 1,
          reason: 'a panel that hellos inside the deadline keeps its session');

      // The deadline must not fire *after* a successful hello either: the
      // timer is one-shot and armed at the upgrade, so a fix that forgot to
      // check `helloed` when it fires would disconnect this panel a moment
      // from now, and every panel in the plant a moment after it connected.
      await Future<void>.delayed(_preHello - _slowPanel + slack);
      expect(await panel.closeWithin(Duration.zero), isNull,
          reason: 'the pre-hello deadline expired while this panel was already '
              'authenticated, and closed it anyway');
      expect(gateway.sessionCount, 1);
    });
  });

  group('WSH-13 — the pre-hello surface is bounded in count', () {
    test('arm 2: a flood of un-helloed sockets is refused, loudly', () async {
      final gateway = await _started();

      final opening = Stopwatch()..start();
      final under = await gateway.dialAll(_cap);
      await gateway.untilSessions(_cap);
      opening.stop();

      // Said out loud because it is the arm's own precondition: the batch has
      // to be open inside the pre-hello deadline or the gateway is reaping the
      // head of it while the tail connects.
      print('flood: $_cap un-helloed sockets open in '
          '${opening.elapsedMilliseconds} ms, against a '
          '${_preHello.inMilliseconds} ms pre-hello deadline');
      expect(opening.elapsed, lessThan(_preHello),
          reason: 'this arm opened its batch in '
              '${opening.elapsedMilliseconds} ms, which is not inside the '
              'pre-hello deadline — so whatever it measures next is the '
              'runner, not the cap');

      final refused = await gateway.dial();
      final close = await refused.closeWithin(_refusalBudget);

      expect(close, isNotNull,
          reason: 'the ${_cap + 1}th concurrent un-helloed connection was '
              'accepted in silence and was still open '
              '${_refusalBudget.inMilliseconds} ms later. Silence is not '
              'success — a gateway with no cap on un-helloed sessions can be '
              'made to build one session buffer, sink, health overlay and '
              'Peer per socket by anything that can reach the port, without '
              'ever presenting a credential. A close that arrives later than '
              'this is not a refusal either: it is the connection having been '
              'accepted and then reaped by a deadline that is not about the '
              'budget');
      expect(close!.closeCode, _unhelloedBudgetCode,
          reason: 'refused with a code of its own: this is not a draining '
              'gateway (4002) and not a revoked credential (4001), and a peer '
              'that cannot tell those apart retries the one case that can '
              'never succeed');
      expect(close.closeReason, contains('$_cap'),
          reason: 'the refusal must name the budget it hit. The alternative — '
              'a silent drop — is exactly the "silence, not success" failure '
              'this project has already paid for once, and it costs an '
              'engineer a packet capture to discover');

      expect(gateway.sessionCount, _cap,
          reason: 'the refused connection must be refused *before* it becomes '
              'a session; one that is registered and then closed has already '
              'paid for everything the cap exists to avoid');
      for (final panel in under) {
        expect(await panel.closeWithin(Duration.zero), isNull,
            reason: 'a connection under the cap was disconnected by the cap. '
                'The budget refuses the arrival that would exceed it, and '
                'never the arrivals that fit');
      }
    });

    test('arm 4: sessions that have helloed do not hold the budget', () async {
      final gateway = await _started();

      final filled = await gateway.dialAll(_cap);
      await gateway.untilSessions(_cap);
      await within(Future.wait([for (final panel in filled) panel.hello()]),
          '$_cap panels authenticating', budget: _rpcBudget);

      // The budget is now nominally full of *sessions* and empty of
      // *un-helloed* sessions, which is the whole distinction.
      final next = await gateway.dial();
      expect(await next.closeWithin(_survivalBudget), isNull,
          reason: 'a plant of $_cap authenticated panels exhausted the '
              'un-helloed budget, so the next screen to be switched on was '
              'refused. A cap that counts sessions rather than un-helloed '
              'sessions caps the plant — it is the same defect as the flood, '
              'aimed at the operators instead of at an attacker');

      final result = await next.hello();
      expect(result.sessionId, isNotEmpty,
          reason: 'and the connection that got through is a working one, not '
              'a socket held open to make an assertion pass');
      expect(gateway.sessionCount, _cap + 1);
    });

    test('arm 5: connect-and-drop peers do not exhaust the budget for ever',
        () async {
      final gateway = await _started();

      final dropped = await gateway.dialAll(_cap);
      await gateway.untilSessions(_cap);
      for (final panel in dropped) {
        await panel.dispose();
      }
      await gateway.untilSessions(0);

      // This is the obvious way to get the cap wrong: count up on connect and
      // down only on hello, and a peer that connects and drops without ever
      // saying anything spends a slot of the budget permanently. A few
      // hundred of those and the gateway refuses the whole plant while holding
      // no sessions at all — which from the outside looks exactly like a
      // gateway that is fine.
      final after = await gateway.dialAll(_cap);
      // Watched in parallel and *before* the session count is waited on, so
      // this arm fails on the sentence that names the property rather than on
      // a registry that never fills. Serially this would be $_cap survival
      // budgets end to end — half a minute of a passing test waiting to be
      // sure nothing happened.
      final closes = await Future.wait(
          [for (final panel in after) panel.closeWithin(_survivalBudget)]);
      expect(closes.where((close) => close != null), isEmpty,
          reason: 'the gateway refused ${closes.where((c) => c != null).length}'
              ' of $_cap fresh connections while holding no session at all — '
              'every one of the $_cap peers before them connected, said '
              'nothing, and dropped. A budget that is released on hello but '
              'not on teardown is spent permanently by exactly that peer, and '
              'a few hundred of them lock out the whole plant while the '
              'gateway reports itself healthy: sessionCount is zero, which is '
              'what a quiet night shift looks like');
      await gateway.untilSessions(_cap);
      expect(gateway.sessionCount, _cap);
    });
  });
}
