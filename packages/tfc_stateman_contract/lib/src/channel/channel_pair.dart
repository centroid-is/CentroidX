/// Two ends of an in-memory message channel, with a seam in the middle.
///
/// The shape is RESEARCH Q4's, executed: a `StreamChannelController<String>`
/// per end, with a relay between their foreign halves. A single controller
/// would have been shorter and would have left nowhere to stand. The relay is
/// the whole reason for the second controller: it is the point a socket would
/// occupy, so a corruption applied there is applied to the encoded message
/// exactly where a wire would carry it, and a message dropped there is dropped
/// exactly where a wire would lose it.
///
/// `allowForeignErrors: true` is set because the corruption catalogue that
/// lands in plan 02-10 may want to push an *error* into the channel rather than
/// a malformed message, and a controller that refuses foreign errors turns that
/// into a thrown assertion at the injection site rather than into the fault
/// being injected.
///
/// The corruption hook is declared here now, empty, on purpose. Plan 02-10 owns
/// its catalogue; declaring the seam in advance means that plan adds a function
/// rather than restructuring this file, and nothing built on the pair in the
/// meantime has to move.
///
/// Direction matters. Corruption and severance apply to **server → client**
/// only, and client → server is left untouched. That asymmetry is
/// `packages/tfc_dart/test/proxy.dart:22-25`'s hard-won one, for the same
/// reason: keeping the client → server direction flowing holds the server-side
/// session alive, so a severed harness reproduces a source that has gone silent
/// rather than one that has gone away. Those are different faults and the
/// second one is the easy one.
///
/// Nothing here imports the io library, and nothing behind
/// `lib/channel_harness.dart` does either. A message channel needs no sockets,
/// and this half of the harness has to stay importable by anything —
/// including, in Phase 3 and Phase 4, code that will run in a browser.
library;

import 'package:stream_channel/stream_channel.dart';

/// The client and server ends of one in-memory channel.
final class ChannelPair {
  /// The end a client implementation talks through.
  final StreamChannel<String> client;

  /// The end the served source talks through.
  final StreamChannel<String> server;

  ChannelPair._(this.client, this.server);

  /// Whether [sever] has been called.
  bool get isSevered => _severed;
  bool _severed = false;

  /// Drops every later server → client message on the floor, silently.
  ///
  /// The harness's own sabotage, and it is deliberately the *quiet* one. A
  /// closed sink would reach the client as `onDone`, which `json_rpc_2` turns
  /// into a closed peer — an event a client could notice and report. Dropping
  /// produces silence instead, which is the fault this project exists to make
  /// visible: the link looks up, requests keep going out, and nothing ever
  /// comes back. Every check that depends on a value arriving must then fail by
  /// name inside its budget, and a check that never needed one must still pass.
  /// `test/channel/channel_bite_test.dart` is that proof.
  ///
  /// One-way and one-shot: client → server keeps flowing, so the served source
  /// still applies every lever it is sent. What is lost is only the answer.
  void sever() => _severed = true;
}

/// Two ends of a channel, plus the seam a fault is injected at.
///
/// [corruptServerToClient] is applied to each encoded message travelling from
/// the served source to the client, and to nothing else. Null — the default —
/// forwards verbatim.
ChannelPair channelPair({
  String Function(String message)? corruptServerToClient,
}) {
  final clientSide = StreamChannelController<String>(allowForeignErrors: true);
  final serverSide = StreamChannelController<String>(allowForeignErrors: true);
  final pair = ChannelPair._(clientSide.local, serverSide.local);

  // server -> client, through the seam.
  serverSide.foreign.stream.listen(
    (message) {
      if (pair.isSevered) return;
      clientSide.foreign.sink
          .add(corruptServerToClient?.call(message) ?? message);
    },
    // Forwarded so a peer that closes its end is seen to close by the other —
    // but not once severed, because a severed channel that still delivered its
    // own end-of-stream would be announcing the fault it exists to hide.
    onDone: () {
      if (pair.isSevered) return;
      clientSide.foreign.sink.close();
    },
  );

  // client -> server, verbatim: no seam on this side, and not meant to be one.
  clientSide.foreign.stream.listen(
    serverSide.foreign.sink.add,
    onDone: serverSide.foreign.sink.close,
  );

  return pair;
}
