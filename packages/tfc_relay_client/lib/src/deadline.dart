/// A deadline on every RPC, applied at the call site.
///
/// Source: 04-RESEARCH Finding 1, executed against `json_rpc_2` 4.1.0. One
/// measured row is the entire justification for this file:
///
/// > Response arrives carrying a **different id** → **never settles — still
/// > pending after 400 ms** (eternal hang).
///
/// A closed transport *does* fail its in-flight requests — the library tracks
/// them and completes them with a `StateError` on close — so a deadline is not
/// a second line of defence against link loss. What the library cannot notice
/// is that a well-formed response for id 999999 was not the response to id 3.
/// That is `malformed_peer.dart`'s `rewrittenId`, which is what a reconnect
/// replaying a queue produces, and the deadline covers a failure nothing else
/// in the stack can see.
///
/// What breaks in the plant without it: the socket stays up, the gateway keeps
/// answering other calls, and one page waits forever on a spinner. Nothing is
/// stale, because nothing arrived to be stale; nothing is disconnected,
/// because the link is fine. The operator has no error to report and no
/// symptom to act on beyond "it is just sitting there".
///
/// **Why a function and not a deadline-aware `Peer` subclass** (Finding 1's
/// shape recommendation, and 04-PATTERNS names the wrapper as an
/// anti-pattern): a fresh `Peer` is built per connection, so a wrapper is
/// rebuilt per connection too, and any timer registry it owns must be torn
/// down in the same breath as the socket — one more thing to forget in the
/// error path. `Future.timeout` allocates one timer per call and cancels it
/// when the future settles either way, so no timer outlives the call it
/// belongs to and nothing leaks across a reconnect. The Peer stays disposable;
/// the deadline stays local.
///
/// **The timeout is terminal here.** Finding 1's caveat: `.timeout()` leaves
/// the underlying `sendRequest` pending inside the Peer, which is harmless —
/// the Peer fails it on close — but it means the late answer really does turn
/// up. Nothing downstream may act on it. A write that was reported unknown and
/// then quietly resolves "applied" is worse than either verdict on its own,
/// because the operator has already gone to look at the machine.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart';

/// Where the current connection's peer lives — read at the moment of the call.
///
/// A getter rather than a `Peer`, because the supervisor swaps its peer on
/// every reconnect and this seam has to read that field itself, once, before
/// anything suspends. See [callWithDeadline].
typedef CurrentPeer = Peer? Function();

/// There is no connection to send this call down.
///
/// The client's own name for the condition, deliberately not `json_rpc_2`'s
/// `StateError: The client is closed.` — that one has to be told apart from a
/// genuine programming error by matching a message string
/// (`failure_taxonomy.dart`), and the fewer cases that reach the string match,
/// the fewer chances there are to get it wrong.
final class LinkDown implements Exception {
  /// The RPC that could not be sent. Named so a log line says which page
  /// stopped working, not merely that something did.
  final String method;

  const LinkDown(this.method);

  @override
  String toString() =>
      'LinkDown: no connection to the gateway when calling "$method"';
}

/// Sends [method] down the current peer and gives up after [deadline].
///
/// The peer is read from [currentPeer] into a local **before** anything
/// suspends, so a reconnect landing mid-call cannot retarget the request at
/// the replacement socket. That matters most for a write: re-sending one down
/// a new link is a second actuation of the machinery, which this client never
/// does on its own.
///
/// Throws [LinkDown] synchronously when there is no peer, and completes with a
/// `TimeoutException` when [deadline] expires. Neither is an outcome on its
/// own — the write path turns both into `WriteUnknown` through
/// `failure_taxonomy.dart`, because a request whose fate we cannot establish
/// is exactly what "unknown" means.
Future<Object?> callWithDeadline(
  CurrentPeer currentPeer,
  String method, {
  Object? params,
  required Duration deadline,
}) {
  // Captured first. This line is the whole of the reconnect guarantee, and it
  // is why this function is not `async`: there is structurally no "after the
  // await" for a later edit to move the read to.
  final peer = currentPeer();
  if (peer == null) throw LinkDown(method);
  return peer.sendRequest(method, params).timeout(deadline);
}
