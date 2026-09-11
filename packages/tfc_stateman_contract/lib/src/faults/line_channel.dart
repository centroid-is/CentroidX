/// A `Socket` seen as a `StreamChannel<String>`, so `Peer` can run over one.
///
/// **Why this exists.** `json_rpc_2.Peer` speaks `StreamChannel<String>`: one
/// string in, one message out. A `Socket` is a byte stream with no message
/// boundaries at all — the kernel is free to hand a reader half a payload, or
/// two payloads in one read, and it does both under load. Something has to
/// impose boundaries, and this file is that something. Without it the socket
/// leg of the fault harness would need its own client, and a second client is
/// the one thing the harness exists to avoid: two implementations judged by
/// one contract prove that the contract is satisfiable, not that the shipping
/// client satisfies it.
///
/// **Why newline framing, specifically.** Because it is the cheapest framing
/// that is not wrong, and because *nothing ships on it*. Phase 3's real
/// transport is a WebSocket, which brings its own framing in the protocol and
/// hands whole messages to `IOWebSocketChannel` — so the wire format here is
/// not a decision about the product, it is scaffolding that lets the same
/// `Peer` code run over a descriptor a fault can be injected into. Anyone
/// reading this file looking for the project's wire protocol is in the wrong
/// place; anyone extending it to carry production traffic should reach for the
/// WebSocket channel instead.
///
/// **What it does not do.** No frame-size limit. A peer that sends a gigabyte
/// without a newline will be buffered until the process dies. That is a
/// deliberate accept (T-02-34) and it matches the surrounding code:
/// `json_rpc_2` imposes no frame-size limit either, so a cap added here would
/// protect a harness while the shipping path stayed uncapped, which is the
/// worst of both. The cap belongs in Phase 3's server, and the fault
/// catalogue's `oversize` entry is the test that will hold it there.
///
/// **Malformed bytes become U+FFFD.** The decoder allows malformed input
/// rather than throwing, because a corruption injected into the byte stream is
/// something this kit does on purpose and a stream error would kill the socket
/// before the peer could reject the message. The consequence is worth writing
/// down, because 02-10 hit it from the other side: an unpaired surrogate
/// survives a `StreamChannel<String>` as 0xD800 and arrives here as U+FFFD.
/// A test that compares the two legs on the exact text of a corrupted message
/// is comparing UTF-8's error handling, not the two harnesses.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// Wraps [socket] as a channel of newline-delimited UTF-8 messages.
///
/// Incoming bytes are decoded and split on newlines, so a message delivered in
/// several reads is reassembled and several messages delivered in one read are
/// separated. Outgoing messages are encoded with a trailing newline.
///
/// Closing the returned channel's sink closes [socket]. The socket is
/// destroyed once the write side is done, so the descriptor is released rather
/// than left to a finaliser — the fd-hygiene arms in this phase measure
/// exactly that.
/// **Who listens to the socket, and for how long.** The read side is not
/// handed to the caller directly. This adapter keeps its own subscription to
/// [socket] for the whole life of the descriptor and republishes through a
/// controller, because a `Peer` cancels its subscription the moment it is
/// closed and a socket with no Dart listener delivers its next error event to
/// the isolate's ambient handler instead. Measured: disposing the client while
/// a reply was in flight produced a `Broken pipe` with a stack trace reading
/// `dart:isolate _RawReceivePort._handleMessage` — no frame in this package at
/// all — which package:test attributed to whichever case was running next.
/// Owning the subscription is what turns that into a swallow.
StreamChannel<String> lineChannel(Socket socket) {
  final incoming = StreamController<String>();

  // Whether anything is still interested. Cleared when the consumer cancels or
  // the socket ends, and read before every forward — everything arriving after
  // it is cleared is a fault landing on a descriptor nobody is reading, which
  // is normal here and must stay silent.
  var listening = true;
  void stopListening() => listening = false;

  // Never cancelled. Cancelling a socket's subscription tears its read side
  // down, and a peer that then writes to it gets EPIPE — which is exactly what
  // happens when a client is disposed while a reply is still crossing the
  // proxy: the proxy's write fails against a descriptor whose reader has gone,
  // and the failure lands on a socket nothing is listening to. The
  // subscription outlives the channel and stops forwarding instead, so the
  // descriptor keeps draining quietly until whoever owns it destroys it.
  socket
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(
    (message) {
      if (listening && !incoming.isClosed) incoming.add(message);
    },
    onError: (Object error, StackTrace stack) {
      // Forwarded while anyone is listening, because a reset that the client
      // does not see is a fault that does not bite. Swallowed afterwards.
      if (listening && !incoming.isClosed) incoming.addError(error, stack);
    },
    onDone: () {
      stopListening();
      if (!incoming.isClosed) incoming.close();
    },
  );
  incoming.onCancel = stopListening;

  final outgoing = StreamController<String>();
  unawaited(_pump(outgoing.stream, socket, stopListening));

  return StreamChannel<String>(incoming.stream, outgoing.sink);
}

/// Writes every message from [messages] to [socket], then releases both.
///
/// Errors are swallowed rather than propagated: writing to a peer that has
/// already gone is the normal shape of every fault in this kit, and an
/// unhandled async error here would fail whichever test happened to be running
/// instead of the check that named the property. The peer learns the socket is
/// gone from its own read side, which is the channel the contract cases are
/// watching.
///
/// `addStream` rather than a loop of `add`, because `IOSink.add` does not
/// report a failed write to its caller at all — the error surfaces on `done`,
/// after the call returned, where a `try` around the loop cannot see it.
Future<void> _pump(
  Stream<String> messages,
  Socket socket,
  void Function() stopListening,
) async {
  // The write side reports a failure twice: once to `addStream`, which the
  // `try` below catches, and once on `done`, which nothing is awaiting. The
  // second copy is what reaches the ambient handler, so it needs a listener of
  // its own — attached before the first byte, because a broken pipe on a
  // loopback socket can arrive within the same event loop turn as the write.
  unawaited(socket.done.catchError((Object _) => null));
  try {
    await socket.addStream(messages.map((m) => utf8.encode('$m\n')));
    await socket.flush();
    await socket.close();
  } catch (_) {
    // Only here is the descriptor torn down hard: the write side is already
    // broken, so there is nothing a FIN would buy.
    socket.destroy();
  } finally {
    stopListening();
  }
}
