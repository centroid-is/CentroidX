/// One direction withheld while the other keeps flowing.
///
/// **The asymmetry is the mode, and it is deliberate.** `bufferServerToClient`
/// holds server→client traffic and keeps forwarding client→server, carried
/// over from `tfc_dart/test/proxy.dart:118-154` (02-PATTERNS Keep #2). The
/// reason is the non-obvious part: forwarding the client's bytes keeps the
/// server-side conversation alive, so the upstream peer goes on receiving,
/// answering and not timing out while every one of its answers is held back.
/// A symmetric hold would be `blackhole`, and the scenarios that need this one
/// need a server that is demonstrably fine and a client that is nonetheless
/// hearing nothing.
///
/// **Withhold, not discard.** The bytes are still owed. `flush()` releases
/// them, in order and complete, and so does turning the lever off — which is
/// the whole difference from `blackhole`, where they are gone. `flush()`
/// deliberately leaves the lever armed, as the original `flushBuffer()` did:
/// releasing a batch and continuing to withhold is what a store-and-forward
/// stall looks like, and a flush that disarmed could not express it.
///
/// **The bounded arm is the one that keeps this mode honest.** Plan 02-02
/// removed an unbounded queue that took a host from 163 MB to 4463 MB of RSS
/// in four seconds (RESEARCH Finding 7), and a withhold lever is the most
/// natural way to put it straight back — a second buffer, off to the side,
/// outside the high-water mark. So the withheld bytes live in the same
/// `DelayLine` queue as everything else and count toward the same
/// `pendingBytes`, and the arm below firehoses into a withheld direction for
/// four seconds to prove the pause still engages.
@Tags(['faults'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The payload the withhold-and-release arms carry.
const _payloadBytes = 4096;

/// How many direct round trips make up the barrier.
///
/// The absence arms are asserted after these have completed, so "nothing
/// arrived" is a statement about a server that was demonstrably answering and
/// not about how long the test host was willing to wait.
const _barrierTrips = 3;

/// The coarse ceiling the withheld queue must stay under.
///
/// The bound that means something is the relational one the arm asserts first:
/// the peak stays below the high-water mark plus the largest chunk the proxy's
/// source ever handed it, because the pause is applied synchronously the moment
/// the queue reaches the mark. That number is not a constant — `dart:io` reads
/// a POSIX socket with `available()`, so one chunk is as large as the kernel
/// let that connection's receive buffer grow, which is ~3 MiB on ubuntu, ~0.4
/// MB on macOS and a fixed 64 KiB on Windows. The 4 MiB this file used to
/// assert was the macOS reading; ubuntu peaked at 4 325 694 on the first CI run
/// and the arm failed for a property it does not test.
///
/// 16 MiB, matching `delay_line_test.dart`'s `_rssCeiling` and derived there:
/// above every plausible kernel receive buffer plus the 1 MiB high-water, and
/// far enough below Finding 7's 4463 MB that the unbounded implementation
/// trips it within the first tenth of a second of the window.
const _rssCeiling = 16 * 1024 * 1024;

/// How long the firehose runs against a withheld direction.
///
/// Four seconds because that is the window Finding 7's unbounded run reached
/// 4463 MB in: a shorter one would not distinguish a bounded queue from a slow
/// start.
const _firehoseDuration = Duration(seconds: 4);

/// What the firehose writes at a time.
const _chunkBytes = 64 * 1024;

/// The delay that holds a batch in the queue while the credit arm sets up.
///
/// Long enough that a flush and a blackhole both land while the bytes are
/// still owed, which is the state the arm is about.
const _creditLatency = Duration(milliseconds: 500);

/// The batch the credit arm queues, discards and then counts.
///
/// Several chunks, deliberately: the pump writes the one chunk it is already
/// holding when the blackhole lands and discards the rest, and the credit
/// stranded on that remainder is what the next withhold would spend.
const _creditPayloadBytes = 256 * 1024;

/// The gap between the credit arm's two writes.
///
/// Long enough that the upstream reads them as two events rather than one.
const _chunkGap = Duration(milliseconds: 50);

/// How long a round trip is given.
const _tripBudget = Duration(seconds: 20);

/// How long a loopback connect is given.
const _connectBudget = Duration(seconds: 2);

/// How long the upstream is given to receive what the client sent.
const _upstreamBudget = Duration(seconds: 10);

Future<void> main() async {
  test('client→server still arrives while server→client is withheld',
      () async {
    final echo = await _echoServer();
    final proxy = await _proxyTo(echo.server.port);
    final peer = await _peerTo(proxy.port);

    proxy.bufferServerToClient = true;

    final payload = _pattern(_payloadBytes);
    await peer.write(payload);

    await within(echo.received(_payloadBytes),
        'the upstream server received the client\'s bytes despite the withhold',
        budget: _upstreamBudget);
    await _barrier(echo.server.port);

    expect(peer.received, 0,
        reason: 'the withheld direction delivered anyway. The upstream has '
            'already acknowledged every byte of the request and answered '
            '$_barrierTrips direct round trips since, so its echo was written '
            'into the proxy long ago — if any of it reached the client, the '
            'lever is not holding');
    expect(peer.hasEnded, isFalse,
        reason: 'withholding is not closing: a client whose replies are held '
            'must stay connected, or the scenario becomes an ordinary '
            'disconnect that any reconnect logic already handles');
  });

  test('flush() releases everything withheld, in order and complete', () async {
    final echo = await _echoServer();
    final proxy = await _proxyTo(echo.server.port);
    final peer = await _peerTo(proxy.port);

    proxy.bufferServerToClient = true;
    final payload = _pattern(_payloadBytes);
    await peer.write(payload);
    await within(echo.received(_payloadBytes),
        'the upstream received the bytes it is about to echo',
        budget: _upstreamBudget);
    await _barrier(echo.server.port);
    expect(peer.received, 0, reason: 'the arm starts from a withheld state');

    proxy.flush();

    final released = await within(peer.awaiting(_payloadBytes),
        'the withheld bytes were released by flush()',
        budget: _tripBudget);
    expect(released, orderedEquals(payload),
        reason: 'the release must be the withheld bytes themselves, in the '
            'order the server produced them, with nothing lost and nothing '
            'duplicated. A withhold that reordered or dropped would be a '
            'corruption fault wearing a delay fault\'s name, and every '
            'scenario built on it would be testing the wrong thing');
  });

  test('turning the lever off releases them too — a withhold, not a discard',
      () async {
    final echo = await _echoServer();
    final proxy = await _proxyTo(echo.server.port);
    final peer = await _peerTo(proxy.port);

    proxy.bufferServerToClient = true;
    final payload = _pattern(_payloadBytes);
    await peer.write(payload);
    await within(echo.received(_payloadBytes),
        'the upstream received the bytes it is about to echo',
        budget: _upstreamBudget);
    await _barrier(echo.server.port);
    expect(peer.received, 0, reason: 'the arm starts from a withheld state');

    proxy.bufferServerToClient = false;

    final released = await within(peer.awaiting(_payloadBytes),
        'clearing the lever released the withheld bytes',
        budget: _tripBudget);
    expect(released, orderedEquals(payload),
        reason: 'a scenario that ends by turning the fault off must not lose '
            'the traffic it was holding. Discarding here would make the mode '
            'a second blackhole with a misleading name, and the client would '
            'see a gap it has no way to detect');
  });

  test('a blackhole between a flush and a withhold does not let the next '
      'batch through', () async {
    final echo = await _echoServer();
    final proxy = await _proxyTo(echo.server.port);
    final peer = await _peerTo(proxy.port);

    // Withheld *and* delayed. The withhold is what makes the batch sit in the
    // queue deterministically; the latency is what keeps the pump inside an
    // await while the levers below are pulled, so the release cannot drain
    // the queue between two of them.
    proxy.latency = _creditLatency;
    proxy.bufferServerToClient = true;
    // Two writes, far enough apart that the upstream reads them as two events
    // and echoes them as two chunks. One chunk would be written whole when the
    // pump wakes, and a queue with nothing left in it after the write has no
    // discarded bytes for a credit to outlive.
    final half = _pattern(_creditPayloadBytes ~/ 2);
    await peer.write(half);
    await Future<void>.delayed(_chunkGap);
    await peer.write(half);
    await within(echo.received(_creditPayloadBytes),
        'the upstream received the batch it is about to echo back',
        budget: _upstreamBudget);
    await _barrier(echo.server.port);

    // No awaits between these four: the pump is parked on the injected delay
    // and must stay parked until the blackhole is armed, or the release it is
    // already carrying out drains the very queue this arm needs discarded.
    proxy.flush();
    proxy.bufferServerToClient = false;
    proxy.blackhole();

    // Waiting out the injected delay, which is a known quantity this test set
    // itself — not a guess about the scheduler. The blackhole bites when the
    // pump next comes round, which is when that delay expires.
    await Future<void>.delayed(_creditLatency * 3);
    final before = peer.received;
    expect(before, lessThan(_creditPayloadBytes),
        reason: 'the whole batch was delivered before the blackhole reached '
            'it, so nothing was discarded and there is no stranded credit for '
            'the withhold below to spend');

    proxy.blackhole(enabled: false);
    proxy.latency = null;
    proxy.bufferServerToClient = true;

    await peer.write(half);
    await Future<void>.delayed(_chunkGap);
    await peer.write(half);
    await within(echo.received(_creditPayloadBytes * 2),
        'the upstream received the second batch it is now withholding',
        budget: _upstreamBudget);
    await _barrier(echo.server.port);

    expect(peer.received, before,
        reason: 'the store-and-forward stall forwarded its first batch. '
            'flush() takes a release credit against the bytes queued at that '
            'moment, and a blackhole discards those bytes — so a credit that '
            'survives the drop is spent on the *next* batch instead, and a '
            'withhold that was armed before a single byte of it existed lets '
            'exactly that many through. A fault that silently does not bite '
            'is the failure this phase ranks worst');
  });

  test('a firehose into a withheld direction stays inside the bound', () async {
    final echo = await _echoServer();
    final proxy = await _proxyTo(echo.server.port);
    final peer = await _peerTo(proxy.port);

    proxy.bufferServerToClient = true;

    final chunk = _pattern(_chunkBytes);
    final deadline = Stopwatch()..start();
    var sent = 0;
    while (deadline.elapsed < _firehoseDuration && !peer.hasEnded) {
      final remaining = _firehoseDuration - deadline.elapsed;
      // Gated on the peer's own flush, so the rig pushes on the proxy rather
      // than measuring how much `dart:io` will buffer on this side — and
      // bounded by what is left of the window, because a stalled write *is*
      // the expected outcome here. Backpressure reaches this writer once the
      // withheld direction pauses its source, the upstream stops draining,
      // and the request direction fills in turn. Waiting the rest of the
      // window out inside that stalled flush is the measurement, not a
      // synchronisation sleep.
      final completed = await peer
          .write(chunk)
          .then((_) => true)
          .timeout(remaining, onTimeout: () => false);
      if (!completed) break;
      sent += chunk.length;
    }

    print('withheld firehose: sent $sent bytes in '
        '${deadline.elapsedMilliseconds} ms, proxy peak pending '
        '${proxy.peakPendingBytes} bytes, largest chunk '
        '${proxy.largestChunkBytes} against a high-water of '
        '$defaultHighWaterBytes');

    expect(
        proxy.peakPendingBytes,
        lessThan(defaultHighWaterBytes + proxy.largestChunkBytes),
        reason: 'the withheld queue grew past the high-water mark plus the one '
            'chunk that can cross it. Withholding must happen inside the same '
            'queue the high-water pause watches — a buffer of its own would be '
            'exactly the unbounded sink plan 02-02 removed, reintroduced by the '
            'one mode whose job is to hold bytes (T-02-24). What stops it is '
            'that the withheld bytes still count toward pendingBytes, so the '
            'source is paused and the upstream feels the backpressure');
    expect(proxy.peakPendingBytes, lessThan(_rssCeiling),
        reason: 'the withheld queue reached ${proxy.peakPendingBytes} bytes '
            'against a ceiling of $_rssCeiling. If this fails while the '
            'assertion above passes, the queue is obeying its policy and the '
            'kernel handed it one chunk larger than any receive buffer the '
            'ceiling was derived against');
    expect(proxy.peakPendingBytes, greaterThan(0),
        reason: 'nothing was ever pending, so the firehose never reached the '
            'withheld direction and the bound above was measured against an '
            'idle proxy');
  });
}

/// Direct round trips against the echo server, bypassing the proxy.
Future<void> _barrier(int echoPort) async {
  for (var i = 0; i < _barrierTrips; i++) {
    final direct = await _peerTo(echoPort);
    final sent = _pattern(64);
    await direct.write(sent);
    await within(direct.awaiting(sent.length),
        'barrier round trip ${i + 1} of $_barrierTrips reached the echo '
        'server directly',
        budget: _tripBudget);
  }
}

/// A client socket with one listener over it: bytes, and how the stream ended.
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
  int get received => _bytes.length;

  /// Whether the stream has ended at all — cleanly or with an error.
  bool get hasEnded => _ended.isCompleted;

  /// Writes [payload] and returns when it has left this process.
  ///
  /// A failing flush is swallowed rather than thrown: the firehose arm
  /// deliberately abandons a write that backpressure has stalled, and the
  /// socket is destroyed at teardown underneath it. That would surface as an
  /// unhandled async error attributed to whichever test was running next.
  Future<void> write(Uint8List payload) async {
    _socket.add(payload);
    await _socket.flush().catchError((Object _) {});
  }

  /// The next [n] bytes to arrive, counted from what has arrived already.
  ///
  /// Separate from [write] because every arm here writes first and reads much
  /// later, on purpose: the gap between the two is where the withhold lives.
  Future<Uint8List> awaiting(int n) {
    final from = _bytes.length;
    final waiter = Completer<Uint8List>();
    _waiter = (want: from + n, completer: waiter);
    _serveWaiter();
    return waiter.future
        .then((all) => Uint8List.sublistView(all, from));
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

/// An echo server that can also be asked how much it has received.
///
/// The receive counter is the half of this mode that cannot be observed from
/// the client: "client→server still arrives" is a claim about the far end, and
/// with a plain echo server the only evidence would be the echo — which this
/// mode is holding back.
final class _EchoServer {
  _EchoServer(this.server);

  final ServerSocket server;
  int _received = 0;
  ({int want, Completer<void> completer})? _waiter;

  /// Completes once at least [n] bytes have reached this server in total.
  Future<void> received(int n) {
    final waiter = Completer<void>();
    _waiter = (want: n, completer: waiter);
    _serveWaiter();
    return waiter.future;
  }

  void accept(int bytes) {
    _received += bytes;
    _serveWaiter();
  }

  void _serveWaiter() {
    final waiter = _waiter;
    if (waiter == null || _received < waiter.want) return;
    _waiter = null;
    waiter.completer.complete();
  }
}

/// A loopback echo server that gates its own writes and counts what it reads.
Future<_EchoServer> _echoServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(server.close);
  final echo = _EchoServer(server);
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
        echo.accept(data.length);
        socket.add(data);
        echoing.pause(socket.flush().catchError((Object _) {}));
      },
      onDone: socket.destroy,
      onError: (Object _) => socket.destroy(),
    );
  });
  addTearDown(accepts.cancel);
  return echo;
}

/// A deterministic pattern whose shifts are visible.
Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}
