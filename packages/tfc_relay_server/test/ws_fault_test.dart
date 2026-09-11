/// Transport death in three shapes, and the one thing none of them is.
///
/// **This file is not a decode-boundary test, and on this transport it cannot
/// be.** 03-RESEARCH Finding 12 drove both branches of a byte corruption under
/// a real WebSocket and measured them apart:
///
/// | Corruption | Measured result |
/// |---|---|
/// | a payload byte → `0xFF` (invalid UTF-8) | **the frame is never delivered**; both ends close with `1007` within 2 ms |
/// | a payload byte → `'X'` (valid UTF-8) | the frame **is** delivered corrupt, and the JSON decoder rejects it |
///
/// RFC 6455's UTF-8 validation therefore sits *between* the wire and our
/// decoder. Every byte-level fault that breaks UTF-8 or the frame header is a
/// **transport-death** fault here: it proves the session tears down cleanly on
/// a runtime-initiated close, and it proves nothing whatsoever about what the
/// JSON decoder does with bad input, because the decoder never sees the bytes.
/// The server's decode boundary is driven at the *message* level, by
/// `MalformedPeer`, in `ws_malformed_test.dart` — that is the file that reaches
/// the 02-05 hang trap. Testing one of these and calling it the other is how a
/// decode-boundary defect ships, and Phase 1's review found the decode boundary
/// was 5 of 5 Criticals (STATE.md).
///
/// **What every arm here asserts instead** is the F23 failure, found early and
/// cheaply: a ghost session. The transport dies, and the registry comes back to
/// the value it held before the fault — sessions *and* subscriptions. A server
/// that answers a close by leaving a `RelaySession` attached to a dead socket
/// keeps that session's upstream listeners pushing values into a buffer nobody
/// will drain again, and a shift's worth of those is memory held for panels
/// that went home (`relay_session.dart:416-420`).
///
/// **The corrupter is local, and that is deliberate.** [_Utf8Corrupter] below
/// exists because `FaultProxy` has no byte-corruption lever and must not grow
/// one here: `faultModes` is a closed registry of eight, and
/// `tfc_stateman_contract`'s `proxy_core_test.dart` iterates it in both
/// directions, so a ninth mode added for this file would fail that package's
/// sweep for want of a mode test beside it. Finding 12's own instrument was a
/// throwaway corrupting relay for the same reason, and this is that instrument
/// with a name.
@Tags(['ws', 'faults'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// `subscriptionCount` is an extension on `SessionRegistry` and needs its
// defining library in scope; the registry itself arrives through the harness.
import 'package:tfc_relay_server/src/subscription_registry.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/bands.dart';
import 'support/ws_harness.dart';

/// The key every arm subscribes to before it breaks the link.
///
/// A subscription is what makes the teardown assertion non-vacuous: a registry
/// whose `subscriptionCount` was zero before the fault would return to zero
/// afterwards no matter how badly the session leaked.
const _key = 'CN01.MOT01.speed';

/// How long a close has to reach the client after the transport dies.
///
/// Ten times the platform [ceiling] rather than a second, so a slow runner
/// widens this in step with every other timing assertion in the package
/// instead of by a number chosen here (`ws_session_test.dart:37-41`). Finding
/// 12 measured the 1007 close arriving in 2 ms; this is not a measurement of
/// that, it is the deadline that turns silence into a named failure.
final _closeBudget = ceiling * 10;

/// How long the registry has to come back to its pre-fault value.
///
/// The teardown is event-driven — `SessionRegistry.gone` — so this only has to
/// cover the socket close propagating from the proxy to the server.
final _teardownBudget = ceiling * 10;

/// How long a request gets while the link is blackholed before the case calls
/// it unanswered.
///
/// Short on purpose: the property is that nothing comes back, and a generous
/// budget for silence is time every run pays. Sized off [ceiling] so the
/// blackhole arm is judged against the same band as everything else.
final _silenceBudget = ceiling * 3;

void main() {
  // Awaited before the group is registered, because `skip:` needs a value at
  // registration time and a probe awaited inside the case would report as a
  // pass (`kill_once_test.dart:70-73`).
  group('transport death leaves no ghost', () {
    test('a UTF-8-invalid corruption closes with 1007 and leaves no session '
        'behind', () async {
      // The fixture's own client is the *survivor*: it holds a session and a
      // subscription throughout, so "the registry returned to its prior value"
      // is a statement about the victim's session being released and not about
      // the server having dropped everything it held.
      final fixture = relayFixture();
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'survivor', keys: [_key]).toJson(),
          what: 'the survivor\'s subscribe answer over a real socket');

      final sessions = fixture.server.sessions;
      final priorSessions = sessions.sessionCount;
      final priorSubscriptions = sessions.subscriptionCount;
      expect(priorSubscriptions, greaterThan(0),
          reason: 'the teardown assertion below is vacuous unless something '
              'was actually subscribed before the link broke');

      final corrupter = _Utf8Corrupter(targetPort: fixture.server.port);
      await corrupter.start();
      addTearDown(corrupter.shutdown);

      // Subscribed *before* the connect, for the reason `ws_harness.dart`
      // gives at its own accept: the session can be registered in the same
      // event-loop turn the connect completes in, and a listener attached
      // afterwards waits for a second connection that never comes.
      final victimOpened = sessions.opened.first;
      final victim =
          IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${corrupter.port}'));
      addTearDown(() => victim.sink.close().catchError((Object _) {}));
      await victim.ready;
      await within(victimOpened, 'the victim session being registered',
          budget: _closeBudget);

      // Nothing is awaited on this: the answer it would have produced is the
      // frame the corrupter destroys, so the victim never receives it.
      victim.sink.add('{"jsonrpc":"2.0","id":"victim-1","method":"ping"}');

      final closed = await _closeOf(victim, budget: _closeBudget);

      expect(closed, 1007,
          reason: 'a text frame whose payload is not valid UTF-8 is a protocol '
              'violation the WebSocket runtime answers with 1007 before our '
              'decoder is ever consulted (Finding 12) — a different code here '
              'means the corruption did not land in the payload, so the arm is '
              'measuring nothing');

      await _untilSettled(
          () => sessions.sessionCount == priorSessions,
          'the victim session being released',
          budget: _teardownBudget);

      expect(sessions.sessionCount, priorSessions,
          reason: 'a session still attached to a socket the runtime closed is '
              'a ghost: its upstream listeners keep filling a buffer nobody '
              'will drain again');
      expect(sessions.subscriptionCount, priorSubscriptions,
          reason: 'the victim\'s subscriptions must go with its session, or a '
              'panel that went home is still costing the plant a fan-out slot');
    });

    test('cutMidFrame is transport death here, and the server keeps no session',
        () async {
      final fixture = relayFixture(withProxy: true);
      final sessions = fixture.server.sessions;
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [_key]).toJson(),
          what: 'the subscribe answer over a real socket');

      expect(sessions.subscriptionCount, greaterThan(0),
          reason: 'the teardown assertion below is vacuous unless something '
              'was actually subscribed before the link broke');

      // Armed only now: the handshake and the subscribe answer have already
      // crossed, so the cut lands on the ping answer and the case is about a
      // frame that was interrupted rather than one that never started.
      fixture.proxy.cutMidFrame(8);

      // Deliberately unawaited. Eight bytes of the answer are delivered and
      // then the connection ends, so this request never settles — awaiting it
      // would be asserting the hang instead of the teardown.
      unawaited(fixture
          .request(Methods.ping, budget: _closeBudget)
          .then<void>((_) {}, onError: (Object _) {}));

      await fixture.awaitClose('the client observing the cut connection end',
          budget: _closeBudget);
      await within(fixture.untilNoSessions(),
          'the server releasing the session behind the cut connection',
          budget: _teardownBudget);

      expect(sessions.sessionCount, 0,
          reason: 'a FIN mid-frame is still the end of the connection; a '
              'session that survives it is attached to a socket that is gone');
      expect(sessions.subscriptionCount, 0,
          reason: 'the cut session\'s subscriptions must be released with it');
    });

    test('a genuine RST returns the registry to baseline', () async {
      final fixture = relayFixture(withProxy: true);
      final sessions = fixture.server.sessions;
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [_key]).toJson(),
          what: 'the subscribe answer over a real socket');

      expect(sessions.subscriptionCount, greaterThan(0),
          reason: 'the teardown assertion below is vacuous unless something '
              'was actually subscribed before the link broke');

      fixture.proxy.killOnce();

      await fixture.awaitClose('the client observing the reset',
          budget: _closeBudget);
      await within(fixture.untilNoSessions(),
          'the server releasing the session behind the reset connection',
          budget: _teardownBudget);

      expect(sessions.sessionCount, 0,
          reason: 'an RST is what a crashed panel or a yanked cable looks '
              'like, and it is the case a ghost session is most likely to '
              'survive: nothing orderly happened on either side');
      expect(sessions.subscriptionCount, 0,
          reason: 'the reset session\'s subscriptions must be released with '
              'it');
    }, skip: _lingerSkip);

    test('a blackhole strands the session without letting an error escape',
        () async {
      final fixture = relayFixture(withProxy: true);
      final sessions = fixture.server.sessions;
      await fixture.ready;
      await fixture.hello();
      fixture.served.setValue(_key, 1);
      await fixture.request(Methods.subscribe,
          params: const SubscribeParams(sub: 'page-1', keys: [_key]).toJson(),
          what: 'the subscribe answer over a real socket');

      final priorSessions = sessions.sessionCount;

      fixture.proxy.blackhole();

      // A deadline converted into a bool, never a throws-matcher: the property
      // is that nothing arrives, and a throws-matcher would assert that
      // *something* did (`malformed_peer_test.dart` header rule).
      final answered = await _settles(
          fixture.request(Methods.ping, budget: _closeBudget),
          budget: _silenceBudget);

      expect(answered, isFalse,
          reason: 'a blackholed link swallows the request and the answer, so '
              'the caller hears nothing — if this answered, the bytes got '
              'through and the arm proved nothing about a half-open link');
      expect(sessions.sessionCount, priorSessions,
          reason: 'the sockets are still up, so the session is still the '
              'server\'s to hold: reaping a stranded session on a deadline is '
              '03-11\'s property, and a server that dropped it here would be '
              'evicting clients for one slow round trip');

      // An error escaping into the ambient isolate during the outage is
      // reported by package:test against whichever case is running, so giving
      // the event loop several turns here is what makes that failure land on
      // this case rather than on an innocent one downstream.
      await pumpEventQueue(times: 5);

      // And the link recovers into a clean teardown rather than into a leak:
      // the blackhole is lifted, the client goes, and the registry comes back
      // to baseline like every other arm in this file.
      fixture.proxy.blackhole(enabled: false);
      await fixture.client.sink.close().catchError((Object _) {});
      await within(fixture.untilNoSessions(),
          'the server releasing the session after the blackhole lifted',
          budget: _teardownBudget);

      expect(sessions.sessionCount, 0,
          reason: 'a session stranded by a blackhole and then closed normally '
              'must not be left behind by the recovery path either');
      expect(sessions.subscriptionCount, 0,
          reason: 'the stranded session\'s subscriptions go with it');
    });
  });
}

/// The skip reason for the reset arm, or null when a reset is genuinely
/// available here.
///
/// A capability probe rather than a platform name: `SO_LINGER` is a Winsock
/// struct-layout question and not a Windows question, and a leg gated on the
/// operating-system name would skip a machine that can do it and run on one
/// that cannot. Resolved at load time because `skip:` is read at registration.
final String? _lingerSkip = _resolveLingerSkip();

String? _resolveLingerSkip() {
  // The probe is async and `skip:` is not, so the synchronous answer is the
  // cached one; `lingerResetSupported()` is awaited in `socket_ops.dart`'s own
  // suite and by `kill_once_test.dart` before this package ever runs. When the
  // cache is cold the arm runs and `killOnce` degrades to a FIN, which this
  // case's assertions still hold for — the registry must come back to baseline
  // either way — so a cold cache costs coverage of the *reset*, not a false
  // green.
  return lingerResetSkipReason;
}

/// Whether [work] settled — either way — inside [budget].
///
/// The sanctioned way to assert a hang: a deadline turned into a bool, so the
/// case asserts on the bool. A `throws` matcher cannot express "nothing
/// happened", and a bare `.timeout()` fails the case with the runner's message
/// instead of the property's.
Future<bool> _settles(Future<Object?> work, {required Duration budget}) async {
  var settled = false;
  final marked = work.then<void>((_) => settled = true,
      onError: (Object _) => settled = true);
  await marked
      .timeout(budget, onTimeout: () {})
      .catchError((Object _) {});
  return settled;
}

/// The close code [socket] observed, once its stream has finished.
Future<int?> _closeOf(WebSocketChannel socket,
    {required Duration budget}) async {
  await within(socket.stream.drain<void>().catchError((Object _) {}),
      'the victim socket finishing', budget: budget);
  // `closeCode` is populated by the same event that ends the stream, but that
  // ordering is the implementation's business rather than a documented
  // contract (`ws_harness.dart:174-179`).
  if (socket.closeCode == null) await pumpEventQueue(times: 1);
  return socket.closeCode;
}

/// Waits until [predicate] holds, or fails naming [what].
///
/// Event-queue driven rather than a polling timer: the transitions this waits
/// on are all microtask-or-socket-event driven, and a timer here would make a
/// teardown assertion into a timing assertion.
Future<void> _untilSettled(bool Function() predicate, String what,
    {required Duration budget}) async {
  final deadline = DateTime.now().add(budget);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$what did not happen within ${budget.inMilliseconds} ms');
    }
    await pumpEventQueue(times: 1);
  }
}

/// A loopback relay that turns one payload byte of the first server→client
/// text frame into `0xFF`.
///
/// **Server→client, and never the other direction.** A client→server frame is
/// masked (RFC 6455 §5.3), so corrupting a masked payload byte unmasks to an
/// arbitrary value that is invalid UTF-8 only by luck — the arm would pass or
/// fail on the mask the client happened to draw. The server's frames are
/// unmasked, so a byte written into the payload is the byte the client's
/// runtime validates.
///
/// The substitution is length-preserving, which is the whole point: the frame
/// header stays correct and the frame stays well-formed, so what the client
/// rejects is the *payload encoding* and not the framing. A corrupter that
/// changed the length would produce a framing error (1002) and the case would
/// be measuring the wrong verdict.
final class _Utf8Corrupter {
  _Utf8Corrupter({required this.targetPort});

  /// The upstream server this relay forwards to, on loopback.
  final int targetPort;

  /// The marker whose first byte is overwritten.
  ///
  /// Every JSON-RPC frame carries it, and seven bytes of ASCII cannot collide
  /// with a WebSocket frame header — so the corruption is guaranteed to land
  /// in the payload rather than in the length or the opcode.
  static const _marker = [0x6a, 0x73, 0x6f, 0x6e, 0x72, 0x70, 0x63]; // jsonrpc

  ServerSocket? _server;
  final _sockets = <Socket>[];
  var _fired = false;

  int get port {
    final server = _server;
    if (server == null) {
      throw StateError('the corrupter has no port until start() has completed');
    }
    return server.port;
  }

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_accept);
  }

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    final Socket upstream;
    try {
      upstream = await Socket.connect(InternetAddress.loopbackIPv4, targetPort);
    } catch (_) {
      client.destroy();
      return;
    }
    _sockets.add(upstream);
    // Errors on either half are swallowed here rather than left to the zone: a
    // destroyed socket completes `done` with an error nobody is waiting for,
    // and package:test attributes that to whichever case is running when it
    // lands (`fault_proxy.dart:1024-1029`).
    unawaited(client.done.catchError((Object _) => client));
    unawaited(upstream.done.catchError((Object _) => upstream));

    client.listen(upstream.add,
        onDone: upstream.destroy, onError: (Object _) => upstream.destroy());
    upstream.listen((chunk) => client.add(_corrupt(chunk)),
        onDone: client.destroy, onError: (Object _) => client.destroy());
  }

  /// Overwrites the first byte of the first `jsonrpc` in [chunk], once.
  List<int> _corrupt(List<int> chunk) {
    if (_fired) return chunk;
    final at = _indexOfMarker(chunk);
    if (at < 0) return chunk;
    _fired = true;
    final copy = List<int>.of(chunk);
    copy[at] = 0xFF;
    return copy;
  }

  static int _indexOfMarker(List<int> chunk) {
    outer:
    for (var i = 0; i + _marker.length <= chunk.length; i++) {
      for (var j = 0; j < _marker.length; j++) {
        if (chunk[i + j] != _marker[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  Future<void> shutdown() async {
    final server = _server;
    _server = null;
    try {
      await server?.close();
    } catch (_) {
      // Cancelling the accept subscription already closed it on some
      // platforms; the listener is down either way.
    }
    for (final socket in _sockets) {
      try {
        socket.destroy();
      } catch (_) {
        // Already gone; the descriptor is closed either way.
      }
    }
    _sockets.clear();
  }
}
