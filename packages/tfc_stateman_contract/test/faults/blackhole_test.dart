/// Traffic vanishes and nobody is told: the true half-open.
///
/// **The transcript this file encodes.** RESEARCH Finding 4 ran the mode as
/// read-the-bytes-and-drop-them and measured:
///
/// ```
/// baseline echo bytes=100 event=none
/// blackhole: echoed=0 (want 0)  event=none (want none)  write completed
/// recovered: echoed=100 (want 100 => blackholed bytes are LOST, not replayed)
/// ```
///
/// Three separate claims live in those three lines and each has an arm below:
/// nothing arrives, neither end sees a close event, and the writer is not
/// stalled — then, on recovery, the blackholed bytes are **gone** rather than
/// queued behind the recovery.
///
/// **Which scenarios this serves.** F5, F7 and F17 — half-open in one or both
/// directions. This is the fault the whole project is built against: a client
/// whose `readyState` says connected, whose socket has seen no FIN and no RST,
/// and at which nothing is arriving. Every other mode in this phase announces
/// itself to the peer somehow; this one is defined by not announcing itself,
/// which is why the interesting assertions here are all about the *absence* of
/// an event.
///
/// **How an absence is asserted without sleeping.** A `Future.delayed` would
/// only say "nothing arrived in 200 ms", which is a statement about the test
/// host's load. Instead each absence arm raises a barrier that would have
/// carried the event had one been coming: a direct, un-proxied round trip
/// against the same echo server, repeated, so the server is demonstrably alive
/// and answering *after* the blackholed bytes were written. A proxied path that
/// was still forwarding would have delivered them before the third direct
/// round trip completed — and the SUMMARY records the sabotage run that proves
/// it, with the drop switch disabled, this file fails.
///
/// **Read-and-drop, not pause-the-subscription.** Finding 4 is explicit that
/// the alternative implementation stalls the sender's `flush()` within one
/// socket buffer, which is backpressure — a different fault with different
/// client-side code paths. The `write completed` clause of the transcript is
/// the arm that holds the implementation to it.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The payload every round trip in this file carries.
///
/// A hundred bytes, as in the Finding 4 transcript, and comfortably one chunk
/// in each direction so that "nothing arrived" cannot be a partial delivery
/// misread as none.
const _payloadBytes = 100;

/// How many direct round trips make up the barrier.
///
/// Three rather than one: a single one could in principle interleave ahead of
/// a proxied delivery that was merely slow, and the claim being made is that
/// the proxied bytes are not coming at all.
const _barrierTrips = 3;

/// How long one round trip is given.
const _tripBudget = Duration(seconds: 10);

/// How long a loopback connect is given.
const _connectBudget = Duration(seconds: 2);

Future<void> main() async {
  group('while blackholed', () {
    test('nothing arrives, no close event fires, and the write completes',
        () async {
      final echo = await _echoServer();
      final proxy = await _proxyTo(echo.server.port);
      final peer = await _peerTo(proxy.port);

      final baseline = await peer.roundTrip(_pattern(_payloadBytes, 0x00),
          what: 'the connection was carrying traffic before the blackhole');
      expect(baseline.length, _payloadBytes,
          reason: 'the baseline round trip has to work, or the arms below '
              'prove only that the rig is broken');

      proxy.blackhole();
      final receivedBeforeBlackhole = peer.received;

      // The write itself is the `write completed` clause of the transcript: a
      // blackhole implemented by pausing the read subscription would stall
      // this flush inside one socket buffer, and the failure would be a
      // timeout here rather than the assertion below.
      await within(peer.write(_pattern(_payloadBytes, 0x40)),
          'the write into the blackhole completed rather than stalling',
          budget: _tripBudget);

      await _barrier(echo.server.port);

      expect(peer.received, receivedBeforeBlackhole,
          reason: 'bytes written into a blackhole must not arrive at the '
              'peer. The barrier above is $_barrierTrips complete round trips '
              'against the same echo server on a direct connection, so the '
              'server was alive and answering after these bytes were sent — '
              'if the proxied path were still forwarding, they would have '
              'landed well before the barrier finished');
      expect(peer.hasEnded, isFalse,
          reason: 'the client saw a close event. A blackhole that sends a FIN '
              'is an orderly shutdown and a blackhole that sends an RST is a '
              'crash; either one lets a client detect the fault from the '
              'socket alone, which is exactly what F5/F7/F17 say it cannot '
              'do. The whole difficulty of half-open is that there is no '
              'event, and a mode that produces one tests the easy case');
      expect(echo.ends, isEmpty,
          reason: 'the upstream end saw a close event. Silence has to be '
              'symmetric: an upstream that is told the client went away will '
              'clean up and stop answering, which turns the half-open into a '
              'genuine disconnect the client can then legitimately notice');
    });
  });

  group('on recovery', () {
    test('the blackholed bytes are gone, and it is the same connection',
        () async {
      final echo = await _echoServer();
      final proxy = await _proxyTo(echo.server.port);
      final peer = await _peerTo(proxy.port);
      await peer.roundTrip(_pattern(_payloadBytes, 0x00),
          what: 'the connection was carrying traffic before the blackhole');
      final receivedBeforeBlackhole = peer.received;

      proxy.blackhole();
      final swallowed = _pattern(_payloadBytes, 0x40);
      await peer.write(swallowed);
      await _barrier(echo.server.port);

      proxy.blackhole(enabled: false);

      final afterRecovery = _pattern(_payloadBytes, 0x80);
      final echoed = await peer.roundTrip(afterRecovery,
          what: 'the connection carried traffic again after recovery');

      expect(echoed, orderedEquals(afterRecovery),
          reason: 'what came back after recovery must be only what was sent '
              'after recovery. Replay is the dangerous failure here, not a '
              'lost byte: a value written before the blackhole arriving after '
              'it would reach a client that has just recovered, carry no mark '
              'of its age, and be rendered as the current state of a machine '
              'it stopped describing seconds ago. Staleness has to be visible, '
              'and a replayed byte is stale data wearing a fresh timestamp');
      expect(peer.received, receivedBeforeBlackhole + afterRecovery.length,
          reason: 'the peer received more than the post-recovery payload, so '
              'the blackholed bytes were queued rather than dropped — the '
              'same replay hazard, counted rather than compared');
      expect(peer.hasEnded, isFalse,
          reason: 'recovery must not require a reconnect: the scenarios this '
              'mode serves are about a link that goes quiet and comes back on '
              'the same connection, which is what makes them hard to detect');
      expect(proxy.livePairs, 1,
          reason: 'the proxy tore the pair down and built another, so the '
              'client-visible connection identity changed under a mode whose '
              'entire premise is that it does not');
    });
  });
}

/// Three complete round trips straight to the echo server, bypassing the proxy.
///
/// The barrier absence arms are asserted after. Direct, so that a proxy in any
/// state cannot affect it, and against the *same* server so that what it
/// proves is the thing in question — that the far end was alive and answering
/// after the blackholed bytes went out.
Future<void> _barrier(int echoPort) async {
  for (var i = 0; i < _barrierTrips; i++) {
    final direct = await _peerTo(echoPort);
    await direct.roundTrip(_pattern(_payloadBytes, 0xc0),
        what: 'barrier round trip ${i + 1} of $_barrierTrips reached the echo '
            'server directly');
  }
}

/// A client socket with one listener over it: bytes, and how the stream ended.
///
/// One listener because `Socket` is single-subscription, and both questions
/// this file asks — what arrived, and did the stream end — have to come from
/// the same subscription or the second one throws.
final class _Peer {
  _Peer(this._socket) {
    _socket.listen(
      (data) {
        _bytes.addAll(data);
        _serveWaiter();
      },
      onDone: () => _finish(null),
      onError: _finish,
    );
    unawaited(_socket.done.catchError((Object _) => _socket));
  }

  final Socket _socket;
  final List<int> _bytes = <int>[];
  final Completer<Object?> _ended = Completer<Object?>();
  ({int want, Completer<Uint8List> completer})? _waiter;

  /// How many bytes have arrived over the life of this connection.
  ///
  /// Cumulative rather than per-trip, because the absence arms are stated as
  /// "no more arrived than had already", which a counter says exactly and a
  /// list comparison only says once the expected content is known.
  int get received => _bytes.length;

  /// Whether the stream has ended at all — cleanly or with an error.
  bool get hasEnded => _ended.isCompleted;

  /// Writes [payload] and returns when it has left this process.
  Future<void> write(Uint8List payload) async {
    _socket.add(payload);
    await _socket.flush();
  }

  /// Writes [payload] and returns the same number of bytes read back.
  Future<Uint8List> roundTrip(Uint8List payload, {required String what}) async {
    final waiter = Completer<Uint8List>();
    final from = _bytes.length;
    _waiter = (want: from + payload.length, completer: waiter);
    _serveWaiter();
    await write(payload);
    final all = await within(waiter.future, what, budget: _tripBudget);
    return Uint8List.sublistView(all, from);
  }

  void _serveWaiter() {
    final waiter = _waiter;
    if (waiter == null || _bytes.length < waiter.want) return;
    _waiter = null;
    waiter.completer
        .complete(Uint8List.fromList(_bytes.sublist(0, waiter.want)));
  }

  void _finish(Object? outcome) {
    if (!_ended.isCompleted) _ended.complete(outcome);
    final waiter = _waiter;
    if (waiter == null) return;
    _waiter = null;
    waiter.completer.completeError(StateError(
        'the connection ended after ${_bytes.length} of ${waiter.want} bytes'));
  }
}

/// Connects to [port] on loopback and wraps it, destroyed at the end.
Future<_Peer> _peerTo(int port) async {
  final socket = await within(
    Socket.connect(InternetAddress.loopbackIPv4, port),
    'the client reached port $port on loopback',
    budget: _connectBudget,
  );
  addTearDown(socket.destroy);
  return _Peer(socket);
}

/// A proxy in front of [targetPort], torn down at the end of the test.
Future<FaultProxy> _proxyTo(int targetPort) async {
  final proxy = FaultProxy(targetPort: targetPort);
  await proxy.start();
  addTearDown(proxy.shutdown);
  return proxy;
}

/// An echo server that also reports how each of its connections ended.
///
/// The ends list is what makes the upstream half of the no-close-event arm
/// checkable at all: the client can see its own socket, and nothing else in
/// the rig can see the far one.
Future<({ServerSocket server, List<Object?> ends})> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
  final ends = <Object?>[];
  addTearDown(() {
    for (final socket in accepted) {
      socket.destroy();
    }
  });

  final accepts = server.listen((socket) {
    accepted.add(socket);
    unawaited(socket.done.catchError((Object _) => socket));
    late final StreamSubscription<Uint8List> echoing;
    echoing = socket.listen(
      (data) {
        socket.add(data);
        echoing.pause(socket.flush().catchError((Object _) {}));
      },
      onDone: () {
        ends.add(null);
        socket.destroy();
      },
      onError: (Object error) {
        ends.add(error);
        socket.destroy();
      },
    );
  });
  addTearDown(accepts.cancel);
  return (server: server, ends: ends);
}

/// A deterministic pattern, tagged with [mark] so a replayed payload is
/// distinguishable from a fresh one by content and not only by length.
Uint8List _pattern(int length, int mark) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (mark + i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}
