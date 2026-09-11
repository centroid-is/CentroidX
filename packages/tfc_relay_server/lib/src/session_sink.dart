/// The one place in this package that a `Peer`'s output is written, and it
/// does not write to a socket.
///
/// Everything the session sends — RPC answers, write acks, status
/// notifications, the fan-out tick — goes into the session's
/// `ConflatingSendBuffer` priority lane, and the tick engine is what moves the
/// lane onto the wire. That is what makes backpressure measurable: a buffer
/// the server can poll is the only place a "this client cannot keep up"
/// verdict can come from, because `dart:io`'s WebSocket has no
/// `bufferedAmount`, no `flush`, and an `add` that returns void
/// (03-CONTEXT's written-down divergence). A `Peer` writing straight to the
/// socket would be invisible to that policy while contributing to exactly the
/// heap growth it exists to catch.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// A `StreamSink<String>` that funnels frames into [buffer]'s priority lane.
///
/// Handed to a `rpc.Peer` as the write half of its channel (see
/// `ws_channel.dart` for why the channel is built by hand). Frames arrive here
/// already encoded and leave unchanged: the priority lane stores whatever it
/// is given and `drain()` returns it verbatim, so an encode-once body is not
/// re-encoded per client.
final class SessionSink implements StreamSink<String> {
  SessionSink(this.buffer, {this.socket});

  /// Where every outbound frame goes.
  final ConflatingSendBuffer buffer;

  /// The socket's write side — held, and deliberately never written to or
  /// closed from here.
  ///
  /// It is a field rather than an absence so that the question a reader
  /// arrives with ("does this close the socket?") is answered next to the
  /// thing it is asking about, and so a test can inject a recorder and assert
  /// the answer instead of trusting the comment. `WebSocketSink` is a
  /// `StreamSink<dynamic>`, hence the type. Optional because the session-level
  /// tests run over an in-memory channel with no socket at all.
  final StreamSink<dynamic>? socket;

  /// Whether the `Peer` has closed its side of the channel.
  ///
  /// News the session reads during teardown, not an instruction to it.
  bool get closedByPeer => _closedByPeer;
  var _closedByPeer = false;

  /// Errors the `Peer` handed to the write side, kept for diagnosis.
  List<Object> get errors => List.unmodifiable(_errors);
  final _errors = <Object>[];

  final _done = Completer<void>();

  /// Puts one frame in the lane, or records why it could not be.
  ///
  /// ## Why this catches (10-REVIEW WR-05)
  ///
  /// `ConflatingSendBuffer.putPriority` refuses a single entry larger than the
  /// whole lane, and the throw has to stop here. This is json_rpc_2's write
  /// half: there is no request id in scope to answer with, and letting the
  /// throw out would surface inside the peer's own request handling and take
  /// the session down — which is the eviction the refusal exists to prevent,
  /// arriving by a shorter route.
  ///
  /// So the frame is **dropped at the door and written down**, and the two
  /// halves of that sentence are both deliberate:
  ///
  ///  * *Dropped* rather than queued, because the alternative is what WR-05
  ///    found: the entry sits in the lane, `poll` evicts a tick later, and
  ///    `flushPriority` writes the whole thing to the socket on the way out.
  ///    The panel then pays for the bytes **and** gets a 4004 that says
  ///    backpressure when what happened is that it asked for too much.
  ///  * *Written down* in [errors], because a silently dropped response is a
  ///    caller waiting on a deadline with nothing anywhere saying why. This
  ///    list is what a teardown reads and what a test asserts.
  ///
  /// **What the caller sees is a deadline, not a refusal, and that is the
  /// residual.** It is acceptable only because it is a backstop: every handler
  /// that can build a large answer is bounded first by `data_handlers.dart`'s
  /// `_sized` — the timeseries family, `preferences.getAll` and, since WR-05,
  /// the five history-view reads — where the refusal still carries the request
  /// id and reaches the panel as a sentence. Reaching this line at all means a
  /// handler was added without a bound, and the entry in [errors] is how that
  /// is found.
  @override
  void add(String event) {
    try {
      buffer.putPriority(event);
    } on ResultTooLarge catch (tooLarge) {
      _errors.add(tooLarge);
    }
  }

  /// Records rather than rethrows.
  ///
  /// An error on the write side means the far end is already gone, which is
  /// the ordinary shape of every disconnect here. Rethrowing would surface as
  /// an unhandled async error attributed to whichever test ran next; the
  /// session learns the socket is gone from its read side, which is the
  /// channel the teardown path is watching.
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _errors.add(error);

  @override
  Future<void> addStream(Stream<String> stream) => throw UnsupportedError(
      'SessionSink takes frames one at a time: binding a stream to it would '
      'be the addStream lock this whole shape exists to avoid, and the '
      'priority lane has no notion of a partially delivered stream');

  /// A deliberate no-op on the socket. **Do not make this close anything.**
  ///
  /// `Peer.close()` closes its channel's sink — twice, as it happens. If that
  /// reached `ws.sink.close()` the socket would already be closed, with no
  /// code, by the time the session tried to close it with
  /// `CloseCodes.backpressureOverrun`; measured in 03-RESEARCH Finding 9,
  /// where the deliberate 4004 arrived only once this stopped closing the
  /// socket. A client that is disconnected without a code cannot tell a
  /// backpressure eviction from a crashed server, and those call for opposite
  /// reconnect behaviour.
  ///
  /// The session closes the socket itself, last, in
  /// `RelaySession.close(code, reason)`.
  @override
  Future<void> close() async => _closedByPeer = true;

  /// Completes when the *session* is finished with the sink.
  ///
  /// Not when the `Peer` closes: a Peer that closed its channel while the
  /// session was still writing its goodbye would otherwise strand the
  /// teardown half-done.
  @override
  Future<void> get done => _done.future;

  /// The session, not the peer, ends this sink's life. Idempotent.
  void finish() {
    if (!_done.isCompleted) _done.complete();
  }
}
