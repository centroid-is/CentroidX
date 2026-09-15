/// SRV-01 over a real WebSocket: the same session properties `session_hello_test`
/// proves in memory, asserted across a real upgrade on an ephemeral port — plus
/// the two things only a socket can answer.
///
/// **Why re-assert in-memory properties over a port.** A framing or gating
/// mistake does not show up on a `channelPair()`: the pair delivers whole
/// strings by construction and the session's gate runs the same either way.
/// The upgrade is where a message boundary can be invented, where a response
/// can be written to a sink nobody drains, and where a close code can be
/// dropped. Everything below is a property of the *transport plus the session*,
/// which is a different subject from either alone.
///
/// **Every close-code assertion here is on the client's observation.** A
/// server's own socket reports a null close code after a close it initiated
/// (`web_socket_channel` #1698 / dart-lang/http#1698, reproduced server-side in
/// 03-RESEARCH Finding 6), so a test that read the server's socket would pass
/// just as happily against a server that closed with no code at all. The
/// session's `sentCloseCode` is the server-side record and is asserted in
/// `session_hello_test`; what is asserted here is that the code survives the
/// wire. The one place the *server's* observation is trustworthy is a close the
/// **client** initiated — that is the 1005 case.
@Tags(['ws'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/bands.dart';
import 'support/ws_harness.dart';

/// A real upgrade on loopback, plus the fixture's own wiring.
///
/// Ten times the wall-clock [ceiling] rather than a second: the number that
/// matters is that it is a *named* budget derived from the same band every
/// other timing assertion in this package uses, so a slow runner widens all of
/// them together instead of one file drifting on its own.
final Duration connectBudget = ceiling * 10;

/// One request out, one response back, through a tick-paced drain.
///
/// Wider than [ceiling] on purpose: an answer waits for the next pump tick
/// (`ServerConfig.tick`, 50 ms in the fixture) before it reaches the wire, so a
/// budget at the bare ceiling would be measuring the tick and not the answer.
final Duration rpcBudget = ceiling * 10;

/// A close frame's round trip, from the server's decision to the client's
/// `closeCode`.
final Duration closeBudget = ceiling * 10;

/// JSON-RPC 2.0's own METHOD_NOT_FOUND.
///
/// A literal rather than an import: `json_rpc_2` publishes it as
/// `error_code.METHOD_NOT_FOUND` in a library this package has no other reason
/// to import, and the number is frozen by the spec.
const rpcMethodNotFound = -32601;

/// Cycles run before the fd baseline is taken.
///
/// Copied from `tfc_stateman_contract/test/faults/leak_test.dart:48`: the first
/// few allocations are not a leak — the VM grows its own pools and `lsof` on
/// macOS is a subprocess whose plumbing settles. RESEARCH measured a stable
/// baseline after five.
const _warmupCycles = 5;

/// Connect/teardown cycles judged for descriptor hygiene.
const _cycles = 20;

/// Connections the control arm holds open at once.
const _held = 20;

/// How long to wait after a teardown before believing a count.
///
/// `leak_test.dart:67`, same value and same reason: `destroy()` is asynchronous
/// with respect to the descriptor actually closing and the kernel offers no
/// event to say the table has settled.
const _settle = Duration(milliseconds: 400);

/// Counts open socket fds, after letting the kernel catch up.
///
/// The only sleep in this file, and it is a **measurement** delay rather than
/// synchronisation — `leak_test.dart:75-91`, including the unparameterised
/// `Future.delayed` spelling, which is what the phase-wide grep for sleeps
/// used as synchronisation matches.
Future<int> _countAfterSettle() async {
  await Future.delayed(_settle);
  return openSocketCount();
}

void main() {
  test('hello over a real socket negotiates', () async {
    final fixture = relayFixture();
    addTearDown(fixture.teardown);
    await within(fixture.ready, 'the server to accept a real client',
        budget: connectBudget);

    expect(fixture.server.sessions.sessionCount, 1,
        reason: 'one upgraded connection is one session; a server that '
            'registered none has nothing for the reaper or the tick engine to '
            'find, and a server that registered two would drain the same '
            'socket twice');

    final result = await fixture.hello(budget: rpcBudget);
    expect(result.protocol, protocolVersion);
    expect(result.sessionId, isNotEmpty);
    expect(result.epoch, isNotEmpty);
    // There was an `expect(result.resumed, isFalse)` here, under a comment
    // saying nothing was resumable "until 03-09". 16-11 withdrew the surface
    // rather than deferring it again (HARD-03): honouring it meant delta replay
    // across a socket loss, and this product resyncs by snapshot.
    //
    // No replacement assertion in this file, deliberately — `fixture.hello`
    // hands back a decoded `HelloResult`, so the withdrawn key is not visible
    // from here and an assertion written against the object could only restate
    // that a field does not exist, which the compiler already enforces. The
    // wire-level pin lives in `session_hello_test.dart`, which holds the raw
    // frame and asserts the emitted `session` object key for key. The two
    // assertions above are the half that had to survive.

    await fixture.client.sink.close();
    await within(fixture.untilNoSessions(),
        'the server to notice the client left',
        budget: closeBudget);
    expect(fixture.server.sessions.sessionCount, 0,
        reason: 'a session left in the registry after its socket is gone is '
            'the leak the tick engine would keep draining into nothing');
  });

  test('two servers run side by side in one process', () async {
    final first = relayFixture();
    addTearDown(first.teardown);
    final second = relayFixture();
    addTearDown(second.teardown);
    await within(Future.wait([first.ready, second.ready]),
        'both servers to accept their clients', budget: connectBudget);

    expect(first.server.port, isNot(second.server.port),
        reason: 'port 0 means the kernel picks; a server that hard-coded one '
            'would make every parallel case in this phase fight over it');
    expect((await first.hello(budget: rpcBudget)).sessionId,
        isNot((await second.hello(budget: rpcBudget)).sessionId));
  });

  test('a pre-hello request is refused over a real socket without closing it',
      () async {
    final fixture = relayFixture();
    addTearDown(fixture.teardown);
    await within(fixture.ready, 'the server to accept a real client',
        budget: connectBudget);

    final refusal = await fixture.refusal(Methods.ping,
        what: 'a pre-hello ping over a real socket', budget: rpcBudget);
    expect(refusal.code, ServerErrorCodes.helloRequired,
        reason: 'the gate is at the registration seam, so it applies over a '
            'socket exactly as it does in memory');

    // 03-04's plan asks for `subscribe` here. The handler does not exist until
    // 03-05, so what a pre-hello `subscribe` proves *today* is the weaker but
    // still load-bearing half: an unregistered method is refused rather than
    // served, and the refusal does not take the socket down. The code is
    // asserted as either verdict on purpose — 03-05 turns it from
    // METHOD_NOT_FOUND into helloRequired by registering the handler through
    // the same gated seam, and a test pinned to today's answer would fail on
    // that plan for being right.
    final unregistered = await fixture.refusal(Methods.subscribe,
        params: {'keys': <String>[]},
        what: 'a pre-hello subscribe over a real socket',
        budget: rpcBudget);
    expect(unregistered.code,
        anyOf(ServerErrorCodes.helloRequired, rpcMethodNotFound),
        reason: 'either verdict is a refusal; being answered would mean plant '
            'data served to a client that never authenticated');

    final result = await fixture.hello(budget: rpcBudget);
    expect(result.protocol, protocolVersion,
        reason: "Home Assistant's pre-auth rule: a refusal before hello leaves "
            'the link open so the client can correct itself');
    expect(fixture.observedClose.closeCode, isNull,
        reason: 'the socket must still be open — a client disconnected for '
            'asking too early would reconnect in a loop');
  });

  test('an unspeakable version is observed as 4005 by the client', () async {
    final fixture = relayFixture();
    addTearDown(fixture.teardown);
    await within(fixture.ready, 'the server to accept a real client',
        budget: connectBudget);

    final refusal = await fixture.refusal(Methods.hello,
        params: helloParams(supported: const ['1999-01-01']),
        what: 'a hello naming a version the server cannot speak',
        budget: rpcBudget);

    expect(refusal.code, ServerErrorCodes.versionMismatch);
    final data = (refusal.data as Map).cast<String, Object?>();
    expect(data['supported'], contains(protocolVersion));
    expect(data['requested'], contains('1999-01-01'),
        reason: "both lists, MCP's rule: a client told only \"no\" has nothing "
            'to log and nothing to fix. They travel in the error data rather '
            'than in the close reason because a close reason is capped at 123 '
            'bytes and a server supporting several versions would overflow it');

    final close = await fixture.awaitClose(
        'the client socket to be closed by the server',
        budget: closeBudget);
    expect(close.closeCode, CloseCodes.protocolMismatch,
        reason: "the CLIENT's observation. A server's own socket reports a "
            'null close code after a close it initiated (dart-lang/http#1698, '
            'reproduced server-side in Finding 6), so a test that read the '
            'server side would pass against a server that closed with no code '
            'at all');
    expect(close.closeReason, contains('protocol version'),
        reason: 'a panel that reconnects on 4005 loops forever; the reason is '
            "what tells the operator it is the client's build that is wrong");
    expect(fixture.server.closeLedger.single.serverCloseCode,
        CloseCodes.protocolMismatch,
        reason: 'the two records must agree: the code the server says it sent '
            'and the code the client says it received');
    expect(fixture.server.closeLedger.single.clientCloseCode, isNull,
        reason: 'and this is #1698 itself, written down as an assertion so it '
            'stops being folklore');
  });

  test('a draining server is observed as 4002 by the client', () async {
    final fixture = relayFixture();
    addTearDown(fixture.teardown);
    await within(fixture.ready, 'the server to accept a real client',
        budget: connectBudget);
    await fixture.hello(budget: rpcBudget);

    await within(fixture.server.close(), 'the server to drain',
        budget: closeBudget);

    final close = await fixture.awaitClose(
        'the client socket to be closed by the draining server',
        budget: closeBudget);
    expect(close.closeCode, CloseCodes.serverDraining,
        reason: '4002 is the code that tells a panel to reconnect rather than '
            "alarm. Client-observed, for #1698's reason. 03-08 sweeps every "
            'emittable close code for exactly one consumer test each; this is '
            "4002's");
    expect(fixture.server.sessions.sessionCount, 0,
        reason: 'a drained server holds no sessions');

    await within(fixture.server.close(), 'a second close on a drained server',
        budget: closeBudget);
  });

  test('a bare client close is recorded as 1005, not as a protocol close',
      () async {
    final fixture = relayFixture();
    addTearDown(fixture.teardown);
    await within(fixture.ready, 'the server to accept a real client',
        budget: connectBudget);
    await fixture.hello(budget: rpcBudget);
    final session = fixture.server.sessions.sessions.single;

    // No code: the ordinary shape of a panel being closed, a laptop lid, a
    // process killed.
    await fixture.client.sink.close();

    // Waited on the *session*, not on the registry, and 03-11 is why. The
    // registry entry now comes out in the synchronous first step of teardown
    // (Finding 9's order, so no tick can select a session mid-dismantling),
    // while the ledger record is written by the connection's release when the
    // session has finished closing — which is strictly later. An empty
    // registry no longer means the disconnect has been recorded, and a test
    // that read the ledger there was reading it one step early.
    await within(session.closed, 'the session to finish closing',
        budget: closeBudget);
    // The release hangs off `closed` rather than being part of it, so it lands
    // a microtask later. Same reasoning as `RelayFixture.awaitClose`: one turn
    // of the event queue costs nothing and removes the only way this could
    // report an absence it did not mean.
    if (fixture.server.closeLedger.isEmpty) await pumpEventQueue(times: 1);

    final record = fixture.server.closeLedger.single;
    expect(record.clientCloseCode, 1005,
        reason: 'the one close a server may believe its own socket about is '
            'the one the client initiated. 1005 is "no status received" — a '
            'client that went away — and it must stay distinguishable from a '
            '4xxx, because "it left" and "we evicted it for backpressure" '
            'call for opposite operator responses');
    expect(record.serverCloseCode, isNull,
        reason: 'the server sent no code of its own, and a ledger that '
            'invented one would make every disconnect look deliberate');
  });

  group('the fixture itself', () {
    test('$_cycles connect/teardown cycles leak no descriptors', () async {
      for (var i = 0; i < _warmupCycles; i++) {
        await _cycle();
      }
      final baseline = await _countAfterSettle();

      for (var i = 0; i < _cycles; i++) {
        await _cycle();
      }

      expect(await _countAfterSettle() - baseline, 0,
          reason: 'the fixture must not be the leak that F23 later blames on '
              'the server: $_cycles cycles on $platformName left descriptors '
              'behind');
    });

    test('the counter can see $_held connections held open', () async {
      final baseline = await _countAfterSettle();
      final held = <RelayFixture>[];
      for (var i = 0; i < _held; i++) {
        final fixture = relayFixture();
        addTearDown(fixture.teardown);
        held.add(fixture);
        await within(fixture.ready, 'held connection $i',
            budget: connectBudget);
      }

      expect(await _countAfterSettle() - baseline,
          greaterThanOrEqualTo(_held),
          reason: 'the control arm: a counter that cannot see $_held held '
              'sockets cannot see one leaked one, and a zero-delta pass in '
              'the arm above would mean nothing');

      for (final fixture in held) {
        await fixture.teardown();
      }
    });
  },
      skip: canCountOpenSockets ? null : openSocketCountSkipReason);
}

/// One full build/use/teardown of the fixture, as the hygiene arm counts it.
Future<void> _cycle() async {
  final fixture = relayFixture();
  await within(fixture.ready, 'a hygiene cycle to connect',
      budget: connectBudget);
  await fixture.hello(budget: rpcBudget);
  await fixture.teardown();
}
