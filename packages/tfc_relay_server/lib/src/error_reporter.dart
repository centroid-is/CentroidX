/// The package's one error-notification seam.
///
/// A single typedef rather than a logging framework, and rather than nothing.
/// Before this existed, `grep -rn "print\|log\|Logger" lib/` returned nothing
/// and `rpc.Peer` was built without `onUnhandledError` — whose documented
/// behaviour when absent is that "the exception will be swallowed"
/// (`json_rpc_2-4.1.0/lib/src/server.dart:56-61`). Every failure the Phase 3
/// review reproduced was therefore invisible from the server side: an
/// unencodable error response, a session whose socket threw inside the tick,
/// a handler that failed while answering a notification. For a gateway whose
/// whole claim is that operators can trust what the screen shows, "the server
/// cannot say what went wrong" is a gap of the same family as the ones the
/// rest of this package closes.
///
/// [where] is the seam that caught it — `'session peer'`, `'tick'`,
/// `'reap'` — because the same exception means different things from
/// different sites, and the site is the one thing a stack trace of async
/// gaps most often loses.
///
/// The embedder supplies one. [reportToStderr] is what a server binary gets
/// by default, so a deployed gateway is never silent about an error it caught;
/// a test supplies a collector and asserts *that* the error was reported,
/// which is the property.
library;

import 'dart:io';

typedef RelayErrorHandler = void Function(
    Object error, StackTrace stack, String where);

/// The default: one line to stderr, then the trace.
///
/// Deliberately not a `print`. stdout on a gateway is where a supervisor
/// expects structured output to go, and an error interleaved into it is an
/// error that gets parsed as data.
///
/// **[StackTrace.empty] means the line is the whole report** (05-REVIEW
/// WR-03). A caller that passes it is saying this is a condition rather than
/// a defect — something a peer can produce at will, already summarized in the
/// message — and a trace for one of those is unbounded log volume chosen by
/// whoever is connecting. Everything that arrives with a real trace still
/// gets it: an unencodable error response, a socket that threw inside the
/// tick, a handler that failed while answering a notification.
void reportToStderr(Object error, StackTrace stack, String where) {
  stderr.writeln('[tfc-relay] $where: $error');
  if (identical(stack, StackTrace.empty)) return;
  stderr.writeln(stack);
}
