/// The outbound seam: who owns the socket's write side, and what closing it
/// is allowed to mean.
///
/// Two measured traps are asserted here as executable cases rather than left
/// as review comments, because both of them are silent until production.
///
///  * **The `cast` trap** (03-RESEARCH Finding 1). Handing a `Peer` a
///    `StreamChannel.cast<String>()` is the documented idiom and it binds the
///    sink with `addStream` for the connection's life. The next writer — the
///    fan-out tick, which is the whole reason this server exists — gets
///    `Bad state: Cannot add event while adding stream`. Reproduced below over
///    an in-memory channel, so the trap fails a test instead of a review.
///  * **The close trap** (Finding 9). `Peer.close()` closes its channel's
///    sink, twice as it happens. If that reached `ws.sink.close()` the socket
///    would already be gone by the time the session tried to close it with
///    4004, and the client would learn nothing about why it was disconnected.
///
/// No sockets: everything here runs over a `StreamChannelController`, which is
/// the same message boundary a WebSocket provides and none of the setup cost.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/session_sink.dart';
import 'package:tfc_relay_server/src/ws_channel.dart';

ConflatingSendBuffer _buffer() => ConflatingSendBuffer(maxPending: 4096);

void main() {
  test('frames reach the priority lane verbatim and in order', () {
    final buffer = _buffer();
    final sink = SessionSink(buffer);

    // Distinct instances rather than literals, so "verbatim" can be asserted
    // as identity: a sink that re-encoded would hand back an equal string and
    // pass a value comparison while quietly costing an encode per client.
    final first = String.fromCharCodes('{"id":1}'.codeUnits);
    final second = String.fromCharCodes('{"id":2}'.codeUnits);
    sink
      ..add(first)
      ..add(second);

    final drained = buffer.drain();
    expect(drained.priority, hasLength(2));
    expect(identical(drained.priority[0], first), isTrue,
        reason: 'a frame the encoder already produced must ride the priority '
            'lane unchanged — re-encoding it here is the 69.6x per-client '
            'encode arrived at by accident');
    expect(identical(drained.priority[1], second), isTrue);
    expect(drained.subs, isEmpty,
        reason: 'RPC answers are priority traffic; nothing here is telemetry '
            'and nothing here may be conflated');
  });

  test('close() does not close the websocket', () async {
    final buffer = _buffer();
    final socket = _RecordingSink();
    final sink = SessionSink(buffer, socket: socket);

    await sink.close();

    expect(sink.closedByPeer, isTrue,
        reason: 'the peer closing its channel is news the session needs, so '
            'it is recorded');
    expect(socket.closeCalls, 0,
        reason: 'if Peer.close() reached the websocket the socket would be '
            'gone before the session could close it with a 4xxx code, and the '
            'client would never learn why it was disconnected (Finding 9)');
  });

  test('done waits for the session, not for the peer', () async {
    final sink = SessionSink(_buffer());
    var completed = false;
    unawaited(sink.done.then((_) => completed = true));

    await sink.close();
    await pumpEventQueue();
    expect(completed, isFalse,
        reason: 'a Peer that closes its channel must not strand the session '
            'mid-teardown by completing its sink for it');

    sink.finish();
    await sink.done.timeout(const Duration(milliseconds: 200));
    expect(sink.closedByPeer, isTrue);
  });

  test('an error handed to the sink is recorded, not thrown at the socket',
      () {
    final sink = SessionSink(_buffer());
    sink.addError(StateError('peer trouble'));

    expect(sink.errors, hasLength(1),
        reason: 'an error on the write side is a diagnosis the session reads; '
            'rethrowing it here would surface as an unhandled async error in '
            'whichever test ran next');
  });

  test('addStream says why it is unsupported', () {
    final sink = SessionSink(_buffer());
    expect(
        () => sink.addStream(const Stream<String>.empty()),
        throwsA(isA<UnsupportedError>().having((e) => '$e', 'message',
            contains('priority lane'))));
  });

  test('a second writer can still add a frame', () async {
    final buffer = _buffer();
    final socket = StreamChannelController<String>();
    final sink = SessionSink(buffer);
    final peer = rpc.Peer(
        StreamChannel<String>(socket.local.stream.cast<String>(), sink));
    unawaited(peer.listen());
    await pumpEventQueue();

    // The fan-out tick, arriving while the Peer holds the channel.
    sink.add('{"method":"u"}');

    expect(buffer.drain().priority, ['{"method":"u"}'],
        reason: 'the Peer must not own the write side: the tick writes to the '
            'same socket every reply does, and a locked sink means the server '
            'cannot push at all');
    await peer.close();
  });

  test('the cast idiom locks the sink — the trap this shape exists to avoid',
      () async {
    final socket = StreamChannelController<String>();
    final peer = rpc.Peer(socket.local.cast<String>());
    unawaited(peer.listen());
    await pumpEventQueue();

    expect(
        () => socket.local.sink.add('{"method":"u"}'),
        throwsA(isA<StateError>().having((e) => '$e', 'message',
            contains('Cannot add event while adding stream'))),
        reason: 'measured, not predicted (Finding 1) — this is the exception '
            'the fan-out would hit on its first tick if the adapter used '
            'StreamChannel.cast');
    await peer.close().catchError((Object _) {});
  });

  test('a socket error arriving after the consumer cancels is swallowed',
      () async {
    final source = StreamController<String>();
    final errors = <Object>[];

    await runZonedGuarded(() async {
      final republished = mutedRepublish(source.stream);
      final subscription = republished.listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();

      // A reset landing on a descriptor nobody is reading. With the Peer's own
      // subscription this becomes an ambient async error attributed to
      // whichever case runs next; owning the subscription turns it into a
      // swallow (line_channel.dart:57-102).
      source.addError(StateError('connection reset by peer'));
      await pumpEventQueue();
    }, (error, _) => errors.add(error));

    expect(errors, isEmpty,
        reason: 'an unhandled async error here fails the *next* test, which '
            'is the flake class a 200-cycle kill test manufactures');
  });

  // 10-REVIEW WR-05. The buffer refuses a single entry larger than the whole
  // lane; this sink is json_rpc_2's write half, so the throw has nowhere to go
  // and must stop here.
  group('a frame too big for the whole lane is dropped, not thrown', () {
    test('add() does not throw, and the frame never reaches the lane', () {
      final buffer =
          ConflatingSendBuffer(maxPending: 4096, maxPendingBytes: 1000);
      final sink = SessionSink(buffer);

      expect(() => sink.add('x' * 5000), returnsNormally,
          reason: 'this is called from inside the Peer\'s own request '
              'handling. A throw out of here takes the session down, which is '
              'the eviction the refusal exists to prevent arriving by a '
              'shorter route');

      final drained = buffer.drain();
      expect(drained.priority, isEmpty,
          reason: 'the whole point: the entry is refused AT THE DOOR rather '
              'than queued and evicted a tick later. Queued, closeSocket\'s '
              'flushPriority would write all 5000 bytes to the socket before '
              'the 4004 — the panel pays for the frame and is then told it '
              'was backpressure');
      expect(buffer.pendingBytes, 0);
    });

    test('and it is written down, because a silent drop is a caller waiting '
        'on a deadline', () {
      final buffer =
          ConflatingSendBuffer(maxPending: 4096, maxPendingBytes: 1000);
      final sink = SessionSink(buffer)..add('x' * 5000);

      expect(sink.errors, hasLength(1));
      expect(sink.errors.single, isA<ResultTooLarge>(),
          reason: 'there is no request id in scope here, so the caller cannot '
              'be answered — what it sees is its own deadline. Reaching this '
              'line means a handler was added without a `_sized` bound, and '
              'this list is the only place that says so');
    });

    test('an ordinary frame is unaffected', () {
      // The anti-vacuity arm: a sink that dropped everything would satisfy
      // both cases above and would also be a gateway that answers nothing.
      final buffer =
          ConflatingSendBuffer(maxPending: 4096, maxPendingBytes: 1000);
      final sink = SessionSink(buffer)..add('{"id":1,"result":true}');

      expect(sink.errors, isEmpty);
      expect(buffer.drain().priority, ['{"id":1,"result":true}']);
    });
  });
}

/// Stands in for `ws.sink`: a `StreamSink<dynamic>`, because that is what
/// `WebSocketSink` is — it has no `cast` and it is not ours to close.
final class _RecordingSink implements StreamSink<dynamic> {
  final written = <Object?>[];
  var closeCalls = 0;
  final _done = Completer<void>();

  @override
  void add(dynamic event) => written.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async =>
      throw UnsupportedError('not used');

  @override
  Future<void> close() async {
    closeCalls++;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
