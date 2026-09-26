/// A completion barrier that can be waited on before there is anything to wait
/// for, and armed again after the thing it was waiting for goes away.
///
/// Source: 04-RESEARCH Finding 6. The shared contract suite calls
/// `StateManApi Function() make` **synchronously**, once per case — there is no
/// async factory hook in the signature and no `arrived()` to await. So
/// `RemoteStateMan` cannot connect in its constructor; it starts the supervisor
/// and every method that touches the wire awaits [ready] first.
///
/// That constraint happens to be the right production shape as well, which is
/// why it is a class and not a workaround. A panel in the packing hall comes up
/// with the rest of the line: it boots while the gateway is still starting, on
/// a switch that is still learning MAC addresses. A client that threw at
/// construction would put the plant's start-up order in the operator's hands.
///
/// **Re-armable, and by swapping the completer.** A `Future` that has completed
/// cannot un-complete — that is a property of the language, not a limitation
/// here — so [rearm] installs a *new* completer for the callers that arrive
/// after the link died, and everyone already through stays through. It swaps
/// only a completer that is already complete: re-arming one with callers still
/// pending on it would strand them, and a stranded call is a panel that hangs
/// instead of retrying.
///
/// No timers. The supervisor owns the clock; this is a rendezvous, and a
/// rendezvous with a timeout in it would be a second, invisible deadline
/// competing with the ones in `ClientConfig`.
library;

import 'dart:async';

/// One rendezvous point: open on entry to `ready`, re-armed on entry to `down`.
final class ReadinessBarrier {
  Completer<void> _completer = Completer<void>();
  bool _disposed = false;

  /// Completes when the link is usable, now or later.
  ///
  /// Read it *per call*, not once: after a [rearm] the barrier hands out a
  /// different future, and that is the whole point.
  Future<void> get ready => _completer.future;

  /// Whether the link is usable right now.
  bool get isOpen => _completer.isCompleted;

  /// The supervisor entered `ready`: let everyone through.
  ///
  /// Idempotent. The supervisor re-enters `ready` after every resync, and a
  /// barrier that objected to the second entry would take the panel down on
  /// its first reconnect.
  void open() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }

  /// The supervisor entered `down`: the next caller waits for the new link.
  ///
  /// A no-op while the current completer is still pending — see the class doc
  /// on stranding — and after [dispose], because a disposed barrier that
  /// re-armed would go back to promising a connection it will never have.
  void rearm() {
    if (_disposed) return;
    if (!_completer.isCompleted) return;
    _completer = Completer<void>();
  }

  /// The client is going away; nobody is ever getting through.
  ///
  /// Waiters are completed with an error rather than left pending: a page
  /// closing while a read is in flight has to get something it can show, and a
  /// future that never settles is a spinner that never stops.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_completer.isCompleted) return;

    final Completer<void> stranded = _completer;
    stranded.completeError(
      StateError('the readiness barrier was disposed while a call was waiting '
          'for the link: the client is shutting down and this request will '
          'never be sent'),
    );
    // The common case is a page that closed without ever reading anything, so
    // this error usually has no listener at all — and an unlistened error on a
    // future is reported to the isolate's ambient handler, which `package:test`
    // attributes to whichever case runs next. A real waiter still sees it: a
    // future delivers its error to every listener, and this is one more.
    unawaited(stranded.future.catchError((Object _) {}));
  }
}
