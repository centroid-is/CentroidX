/// A `WebSocketChannel` seen as a `StreamChannel<String>`, so a `Peer` can run
/// over one — without the idiom that would lock the write side.
///
/// **The trap, measured** (03-RESEARCH Finding 1). The documented way to hand
/// a WebSocket to `json_rpc_2` is `rpc.Peer(ws.cast<String>())`, and on this
/// server it is wrong. `StreamChannel.cast<String>()` does not just retype the
/// two halves: it binds the underlying sink with `addStream` and keeps it bound
/// for the whole life of the connection. Every later writer — and the fan-out
/// tick, which is the reason this gateway exists, is a later writer — gets
///
/// ```text
/// Bad state: Cannot add event while adding stream.
/// package:stream_channel/src/guarantee_channel.dart:121
/// ```
///
/// on its first push. Nothing warns at compile time and nothing fails at
/// startup; the first symptom is that the server can answer requests and cannot
/// send anything on its own. The mitigation is the whole shape of this file:
/// cast the **stream**, which is a cheap view, and build the sink by hand so
/// the session keeps ownership of it (`session_sink.dart`).
///
/// **No framing here.** `line_channel.dart` in the contract kit does the same
/// job for a `Socket` and needs a `Utf8Decoder` and a `LineSplitter` to invent
/// message boundaries. A WebSocket is message-framed by the protocol, so this
/// is that file minus the framing — and its doc comment already says so
/// (`line_channel.dart:13-21`). What survives from it is the subscription
/// lesson, which was expensive.
library;

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Wraps [ws] as a channel of whole string messages.
///
/// This is the *harness* leg: the plain adapter, with a sink that writes
/// straight through. A server session does not use it — the session composes
/// [mutedRepublish] with its own `SessionSink` so every outbound frame goes
/// through the priority lane instead. Closing the returned sink closes [ws].
StreamChannel<String> wsChannel(WebSocketChannel ws) => StreamChannel<String>(
      mutedRepublish(ws.stream.cast<String>()),
      _WsSink(ws.sink),
    );

/// Republishes [source] through a controller that stops forwarding when its
/// consumer cancels, instead of cancelling the underlying subscription.
///
/// **Why a `Peer` must not own the socket's subscription.** A `Peer` cancels
/// its subscription the moment it is closed, and a socket with no Dart listener
/// delivers its next error event to the isolate's ambient handler instead.
/// Measured in the contract kit (`line_channel.dart:57-102`): disposing a
/// client while a reply was in flight produced a `Broken pipe` whose stack read
/// `dart:isolate _RawReceivePort._handleMessage` — no frame in the package at
/// all — which `package:test` attributed to whichever case ran next. That is
/// the flake class a 200-cycle kill test manufactures, and it is diagnosed
/// once per project, painfully.
///
/// So the subscription here outlives the consumer and goes quiet rather than
/// away. Everything arriving after the consumer cancels is a fault landing on
/// a socket nobody is reading, which is normal at teardown and must stay
/// silent.
Stream<String> mutedRepublish(Stream<String> source) {
  final incoming = StreamController<String>();

  // Whether anything is still interested. Read before every forward.
  var listening = true;
  void stopListening() => listening = false;

  source.listen(
    (message) {
      if (listening && !incoming.isClosed) incoming.add(message);
    },
    onError: (Object error, StackTrace stack) {
      // Forwarded while anyone is listening, because a reset the session does
      // not see is a fault that does not bite. Swallowed afterwards.
      if (listening && !incoming.isClosed) incoming.addError(error, stack);
    },
    onDone: () {
      stopListening();
      if (!incoming.isClosed) incoming.close();
    },
  );
  incoming.onCancel = stopListening;

  return incoming.stream;
}

/// `ws.sink` typed as the `StreamSink<String>` a `StreamChannel<String>` wants.
///
/// A hand-written adapter rather than a cast, for two reasons. `WebSocketSink`
/// is a `StreamSink<dynamic>` and carries no `cast` method of its own, and
/// casting the *channel* is the locking idiom this file exists to avoid.
final class _WsSink implements StreamSink<String> {
  _WsSink(this._sink) {
    // Attached before the first write: a broken pipe on a loopback socket can
    // arrive in the same event-loop turn as the write that caused it, and the
    // copy delivered here is the one that would otherwise reach the ambient
    // handler (`line_channel.dart:110-144`).
    unawaited(_sink.done.catchError((Object _) => null));
  }

  final StreamSink<dynamic> _sink;

  @override
  void add(String event) => _sink.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => _sink.addStream(stream);

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> get done => _sink.done;
}
