/// One genuine reset, observed at the peer, and normal service afterwards.
///
/// **The contrast with `cutMidFrame` is the reason both modes exist.** That one
/// cuts with a FIN so the bytes already delivered survive; this one cuts with
/// `SO_LINGER{1, 0}` followed by `destroy()` so they do not. RESEARCH Finding 2
/// measured that pair producing a real RST in 50 of 50 runs, and Finding 1
/// measured plain `destroy()` producing a clean FIN in every state but one — a
/// peer with data still unread in the kernel queue, which is a coincidence of
/// timing and not something a mode can be built on. So the two modes are built
/// on two primitives, and each of these files fails when its mode is
/// reimplemented with the other's (both sabotage runs are recorded in the
/// plan's SUMMARY).
///
/// **Why a half-open scenario needs the reset specifically.** A FIN tells the
/// peer the connection is over; the client's `onDone` fires and its reconnect
/// logic runs. A reset is what a crashed peer, a NAT timeout or a yanked cable
/// produce, and the client-side code paths are different — which is what Phase
/// 3 and Phase 4 exercise through this lever. A `killOnce` that degraded to a
/// FIN would run those scenarios against an orderly shutdown and report them
/// green.
///
/// **The error is caught as `Object`.** Finding 9: `Socket.connect` against a
/// resetting listener throws a bare [OSError], which is not a subtype of
/// [SocketException]. A clause narrowed to [SocketException] does not catch it,
/// so the suite crashes at the moment it meant to report — the errno comes out
/// through `errnoOf` instead, and its value is never asserted because it is a
/// platform's business which number means "reset".
///
/// **The reset assertions are gated on a runtime probe**, never on which
/// operating system this is (Assumptions Log A3): whether this kernel accepts
/// the 8-byte `struct linger` is a question it answers itself, and `setRawOption`
/// rejects a wrong-size struct loudly. The surgical half — that the connection
/// after the killed one is forwarded end to end — is ungated, because it holds
/// whichever way the cut was made.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The payload the liveness round trip carries, small enough for one chunk.
const _probePayloadBytes = 64;

/// The payload the surviving connection carries.
///
/// Larger than the liveness probe and larger than one write, so "normal
/// service" means the whole path — accept, forward, echo, forward back — and
/// not merely that a single small packet got through.
const _survivorPayloadBytes = 128 * 1024;

/// How long a connection is given to end after the kill.
const _endBudget = Duration(seconds: 5);

/// How long a round trip through the proxy is given.
const _tripBudget = Duration(seconds: 20);

/// How long a loopback connect is given.
const _connectBudget = Duration(seconds: 2);

/// What a peer writes at a time.
const _chunkBytes = 64 * 1024;

Future<void> main() async {
  // Awaited in `main` before the group is registered, because `skip:` is
  // evaluated at registration time and the probe is a future: a group that
  // asked inside its own body would already have been registered as running.
  final lingerWorks = await lingerResetSupported();

  group('a genuine reset, observed at the peer', () {
    test('the killed connection ends with an error, not with onDone', () async {
      final proxy = await _proxyToEcho();
      final peer = await _peerTo(proxy.port);
      await peer.roundTrip(_pattern(_probePayloadBytes),
          what: 'the connection was carrying traffic before the kill');

      proxy.killOnce();

      final outcome = await within(
          peer.ended, 'the killed peer\'s stream ended',
          budget: _endBudget);

      expect(outcome, isNotNull,
          reason: 'a null outcome is onDone, which is a FIN — the orderly '
              'shutdown this mode exists not to be. Finding 1: plain '
              'destroy() sends exactly that, so a killOnce that lost its '
              'SO_LINGER would land here and every half-open scenario built '
              'on it would be testing a graceful close');
      expect(errnoOf(outcome), isNotNull,
          reason: 'the errno must narrow out of whatever was thrown, because '
              'this path raises bare OSError as well as SocketException '
              '(Finding 9) and a harness that cannot read the code crashes '
              'where it meant to report. Which number it is belongs to the '
              'platform and is deliberately not asserted');
    });

    test('with no connection open, the next one is killed instead', () async {
      final proxy = await _proxyToEcho();

      proxy.killOnce();

      // A terminal failure within a budget, never an errno: the reset races
      // the handshake, so the client sees either a connect that fails or a
      // connect that is immediately reset (the shape Finding 8 measured for
      // `reject`). Both are the mode biting; neither is a lever that armed
      // and did nothing.
      Object? outcome;
      try {
        final peer = await _peerTo(proxy.port);
        outcome = await within(peer.ended, 'the armed kill reached the peer',
            budget: _endBudget);
      } catch (error) {
        outcome = error;
      }

      expect(outcome, isNotNull,
          reason: 'killOnce with nothing open must arm rather than evaporate. '
              'A lever that silently does nothing when it is pulled a moment '
              'early is the failure this phase declares every mode up front '
              'to avoid, and it would read as a passing scenario');
    });
  }, skip: lingerWorks ? null : lingerResetSkipReason);

  group('and then normal service', () {
    test('the connection after the killed one is forwarded end to end',
        () async {
      final proxy = await _proxyToEcho();
      final doomed = await _peerTo(proxy.port);
      await doomed.roundTrip(_pattern(_probePayloadBytes),
          what: 'the doomed connection was carrying traffic');

      proxy.killOnce();
      await within(doomed.ended, 'the killed connection ended',
          budget: _endBudget);

      final survivor = await _peerTo(proxy.port);
      final payload = _pattern(_survivorPayloadBytes);
      final echoed = await survivor.roundTrip(payload,
          what: 'the connection after the killed one completed a round trip');

      expect(echoed.length, payload.length,
          reason: 'the mode is one shot: it fires, it disarms, and the proxy '
              'goes back to forwarding. A kill that stayed armed would make '
              'every scenario after the fault fail for a reason the scenario '
              'did not inject');
      expect(_firstDifference(echoed, payload), -1,
          reason: 'the bytes after the kill must come back unchanged — '
              'proving the reset tore down one connection rather than '
              'leaving the proxy in a state that mangles the next');
      expect(survivor.hasEnded, isFalse,
          reason: 'the surviving connection must still be open after its '
              'round trip; a proxy that resets it too has fired twice');
    });
  });
}

/// A client socket with one listener over it: bytes, and how the stream ended.
///
/// One listener because `Socket` is single-subscription, and both questions
/// this file asks — did the bytes come back, and did the stream end with an
/// error — have to be answered from the same subscription or the second one
/// throws.
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

  /// The error the stream ended with, or null for a clean `onDone`.
  ///
  /// Collapsing "ended cleanly" to null is what keeps the reset arm honest:
  /// the question is which of the two ends happened, and a type that can say
  /// both without ambiguity is the one that cannot be misread.
  Future<Object?> get ended => _ended.future;

  /// Whether the stream has ended at all yet.
  bool get hasEnded => _ended.isCompleted;

  /// Writes [payload] and returns the same number of bytes read back.
  Future<Uint8List> roundTrip(Uint8List payload, {required String what}) async {
    final waiter = Completer<Uint8List>();
    _waiter = (want: payload.length, completer: waiter);
    _serveWaiter();

    for (var offset = 0; offset < payload.length; offset += _chunkBytes) {
      final end = min(offset + _chunkBytes, payload.length);
      _socket.add(Uint8List.sublistView(payload, offset, end));
      // Gated per chunk, so the rig pushes on the proxy rather than measuring
      // how much `dart:io` will buffer for it.
      await _socket.flush();
    }

    return within(waiter.future, what, budget: _tripBudget);
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
    'the client reached the proxy on port $port',
    budget: _connectBudget,
  );
  addTearDown(socket.destroy);
  return _Peer(socket);
}

/// A proxy in front of a fresh echo server, torn down at the end of the test.
Future<FaultProxy> _proxyToEcho() async {
  final echo = await _echoServer();
  final proxy = FaultProxy(targetPort: echo.port);
  await proxy.start();
  addTearDown(proxy.shutdown);
  return proxy;
}

/// A loopback echo server that gates its own writes and destroys what it
/// accepted.
Future<ServerSocket> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final accepted = <Socket>[];
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
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  });
  addTearDown(accepts.cancel);
  return server;
}

/// A deterministic pattern whose shifts are visible.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}

/// The index of the first differing byte, or -1 when the lists match.
int _firstDifference(List<int> a, List<int> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    if (a[i] != b[i]) return i;
  }
  return a.length == b.length ? -1 : shared;
}
