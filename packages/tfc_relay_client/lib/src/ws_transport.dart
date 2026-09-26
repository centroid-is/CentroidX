/// One connect attempt, and the socket seen as a `StreamChannel<String>` a
/// `Peer` can run over — without the idiom that would lock the write side.
///
/// This is `tfc_relay_server`'s `ws_channel.dart` from the other end of the
/// wire: same `mutedRepublish`, same hand-built sink, both copied whole with
/// their reasoning, plus the one thing only the client needs — a connect that
/// can fail, because the panel dials and the gateway answers.
///
/// **The trap, measured** (03-RESEARCH Finding 1, `ws_channel.dart:4-20`). The
/// documented way to hand a WebSocket to `json_rpc_2` is to cast the whole
/// channel to strings, and it is wrong on both ends of this pipe. Casting a
/// channel does not just retype the two halves: it binds the underlying sink
/// with `addStream` and keeps it bound for the connection's whole life, so
/// every later writer gets
///
/// ```text
/// Bad state: Cannot add event while adding stream.
/// package:stream_channel/src/guarantee_channel.dart:121
/// ```
///
/// "Later writer" is exact, and worth being exact about: measured on this
/// side, a single writer going through the cast channel is fine — the cast
/// pipes its frames through the one `addStream` it owns. What throws is the
/// **second** writer, the one that reaches past the channel at the socket. On
/// the gateway that is the fan-out tick; on the panel it is the app-level
/// heartbeat the supervisor sends around the `Peer` (STACK: Flutter web cannot
/// send ping frames, so liveness is an application frame), and anything else
/// the supervisor needs to say without going through the RPC layer. Nothing
/// warns at compile time and nothing fails at startup — the panel connects,
/// shows values, and the first beat of its own liveness check throws. So: cast
/// the **stream**, which is a cheap view, and build the sink by hand.
///
/// **Connect failure is a value, not a throw** (04-RESEARCH Finding 2,
/// executed). A dial at a dead port surfaces as
///
/// ```text
/// WebSocketChannelException: WebSocketChannelException: SocketException:
/// Connection refused (errno 61)
/// ```
///
/// from **both** `ws.ready` and the stream, with `closeCode == null` — there
/// was never a connection, so there is no code. This file awaits `ready`
/// inside a try and returns a [ConnectFailed] carrying the exception, and it
/// drains the second copy so that it does not land on the isolate's ambient
/// handler and get attributed to whichever test case runs next. A gateway that
/// is not up yet is the *normal* state of a panel at power-on, and a reconnect
/// loop that dies on its first attempt leaves the screen grey until somebody
/// drives to the factory.
///
/// **Close codes are data here, and policy nowhere** (Finding 2's caveat).
/// Driving a protocol mismatch against the real gateway showed
/// `closeCode = 4005`, but a `killOnce` through the fault proxy showed
/// `closeCode = 1002` with an empty reason — a yanked link is
/// indistinguishable-by-code from a protocol error. The rule the supervisor
/// follows, stated here because this is where the code is observed: 4001–4005
/// are advisory, 4005 stops the retry loop, and **everything else — 1002, 1006
/// and null included — means the link went away, retry**. Nothing in this file
/// branches on the number, and nothing in it reads `readyState` for liveness
/// either (STACK: `readyState` lies after an OS sleep).
///
/// **This file is `dart:io`-only, and that is the price of pinning a
/// certificate.** `WebSocketChannel.connect` — what [connect] used to call —
/// takes no `HttpClient` and no `SecurityContext`
/// (`web_socket_channel-3.0.3/lib/src/channel.dart:107-108`), so there is no
/// way through it to say which root the panel trusts. The seam exists one
/// layer down: `IOWebSocketChannel.connect` takes `customClient:`
/// (`io.dart:36-56`, read from the resolved source) and forwards it to
/// `WebSocket.connect`, whose security context is what verifies the gateway.
/// SEC-02 is that context, so this call has to be the IO one.
///
/// No conditional import stands in for it. A `_connect_web.dart` twin would be
/// scaffolding for a build that does not exist — the panels are Windows,
/// macOS and eLinux, the Flutter web target is a later milestone, and CLAUDE.md
/// already records that a browser cannot be handed a private CA root at all
/// (no interstitial for `wss` on Flutter web). When that milestone arrives the
/// browser leg needs a *publicly* trusted certificate, which is a deployment
/// decision, not a second dial in this file.
library;

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The outcome of exactly one dial. Sealed, so the supervisor's switch over it
/// has no default arm to hide a third case in.
sealed class ConnectAttempt {
  const ConnectAttempt();

  /// The close code the socket observed, or `null` when there is none.
  ///
  /// Reported as data. A caller may log it or show it; deciding *whether to
  /// retry* from it is the mistake Finding 2's `killOnce` run rules out.
  int? get closeCode;

  /// The close reason that came with [closeCode], if any. Same rule.
  String? get closeReason;
}

/// The socket is up and framed as strings.
final class ConnectSucceeded extends ConnectAttempt {
  ConnectSucceeded(this._ws, this.channel);

  final WebSocketChannel _ws;

  /// Whole messages in and out. Closing its sink closes the socket.
  final StreamChannel<String> channel;

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;
}

/// The dial did not produce a usable socket.
///
/// Not an error state of the client — an ordinary outcome of an attempt, which
/// is why it is a value the supervisor can count, back off from, and put on
/// the health line.
final class ConnectFailed extends ConnectAttempt {
  ConnectFailed(this._ws, this.error, this.stackTrace,
      {this.certificateUntrusted = false});

  /// A dial refused before a socket was opened, because the configuration
  /// cannot be honoured on this platform.
  ///
  /// One outcome type and not two: to the supervisor this is an attempt that
  /// failed, with a reason for the health line, and it backs off from it
  /// exactly as it does from a gateway that did not answer. A separate type
  /// would be a second thing every caller had to remember to handle, and the
  /// one that got forgotten would be the one that reports nothing.
  ConnectFailed.refused(Uri uri, String why)
      : _ws = null,
        error = StateError('cannot dial $uri: $why'),
        stackTrace = StackTrace.current,
        certificateUntrusted = false;

  final WebSocketChannel? _ws;

  /// Whether the dial failed because this panel would not trust what the
  /// gateway presented.
  ///
  /// **Classified here on purpose** (16-07, WSH-14). The supervisor used to ask
  /// `error is HandshakeException` itself, which cost it an
  /// `import 'dart:io' show HandshakeException` for one exception type — and
  /// the supervisor is the state machine a web build reuses through its own
  /// `dial:` seam, so it would not compile there for that one line. This file
  /// is already `dart:io`-only and says at length why (see the library doc):
  /// a pinned dial has no other seam. So the platform-specific judgement lives
  /// in the platform-specific place, which is exactly the split a web leg would
  /// need, and the supervisor reads a `bool`.
  ///
  /// False by default, which is the honest answer for any [ConnectAttempt] a
  /// harness builds by hand: an unknown failure is not a certificate failure,
  /// and the health line that says "the gateway did not answer" is the one that
  /// is right whenever this cannot be established.
  final bool certificateUntrusted;

  /// What `ready` threw — a `WebSocketChannelException` wrapping the
  /// `SocketException` in the refused case. The operator-facing health line
  /// says *why* the panel is not connected; "attempt failed" with no cause is
  /// a phone call to the integrator.
  final Object error;

  final StackTrace stackTrace;

  @override
  int? get closeCode => _ws?.closeCode;

  @override
  String? get closeReason => _ws?.closeReason;
}

/// Waits for [ws] to be usable and reports what happened.
///
/// The half of a dial that is the same everywhere. What differs by platform is
/// *how the socket was opened* and *whether a refused certificate can be told
/// apart from an absent gateway* — so the opening is the caller's and the
/// telling-apart arrives as [certificateUntrusted], a predicate the platform
/// arm supplies. See `dial/pinned_dialer.dart`.
///
/// No retry and no backoff live here: one attempt, one value. The schedule is
/// `backoff.dart`'s and the loop is the supervisor's, because a transport that
/// retried on its own would be a second, invisible policy sitting under the
/// one the operator can see.
///
/// ## [timeout], and why only one platform passes it
///
/// It bounds the dial itself, which is **the one thing the supervisor's
/// schedule cannot bound**: a connect to an address that answers nothing takes
/// 75 s to fail (06-RESEARCH C.4), so a single attempt can otherwise outlive
/// the whole backoff ceiling of 30 s. That sentence used to live on the old
/// `connect()` this function replaced; it went missing in the web split, and
/// the web arm then walked straight into the condition it described.
///
/// **The io arm must not pass it, and does not.** `pinned_dialer_io.dart`
/// bounds its connect twice already — `HttpClient.connectionTimeout`, which
/// *cancels*, and `IOWebSocketChannel.connect(connectTimeout:)`, which
/// abandons — so a third bound here would only race those two. Null is
/// therefore not "no policy": it is "this platform has its own, closer to the
/// socket". The io tests (`tls_client_test`, `tls_fault_test`,
/// `ws_transport_test`) are untouched by this parameter and are the guard that
/// it stays that way.
///
/// The web arm passes it because a browser gives Dart no hook at all: the
/// WebSocket API has no connect timeout, and the only cancellation available
/// is closing the socket, which is what expiry does here.
Future<ConnectAttempt> awaitReady(
  WebSocketChannel ws, {
  required bool Function(Object error) certificateUntrusted,
  Duration? timeout,
}) async {
  try {
    // `Future.timeout`, deliberately, and not a `Future.any` race. `timeout`
    // consumes a late completion of the source — the error included — so the
    // abandoned `ws.ready` can never surface as an unhandled rejection on the
    // isolate's ambient handler. A `Future.any` leaves that copy live, which
    // is the same fault the catch arm below spends two lines defusing.
    await (timeout == null
        ? ws.ready
        // `onTimeout` rather than the default, whose message is
        // "TimeoutException after 0:00:10.000000: Future not completed" — a
        // type name and a duration, which is what the supervisor would then
        // put on the operator's health line. This one names the thing that
        // did not happen.
        : ws.ready.timeout(timeout,
            onTimeout: () => throw TimeoutException(
                'the dial did not complete within '
                '${timeout.inMilliseconds} ms',
                timeout)));
  } on TimeoutException catch (error, stack) {
    // Guards first, close second. The socket may still be connecting, and it
    // will error both `ws.ready` (already consumed, above) and the stream when
    // it gives up; the stream copy needs a home before anything can emit it.
    ws.stream.listen(null, onError: (Object _) {}, cancelOnError: true);
    unawaited(ws.sink.done.catchError((Object _) => null));
    // **This close is the cancellation, and it is unconditional on purpose.**
    // Closing during CONNECTING fails the connection attempt, which is the
    // whole point — a timeout that left the socket opening would be a leak and,
    // worse, a socket that connects later with nobody holding it. If the timer
    // won against a peer that answered in the same instant, this is an ordinary
    // clean close of an OPEN socket. Either way the loser of that race is
    // closed rather than orphaned, and `close()` is legal in every readyState.
    //
    // No close code. Nothing was established, so no close frame reaches any
    // wire and a code would be inert — and a null code already means "there was
    // never a connection" to [ConnectFailed.closeCode]'s readers.
    unawaited(ws.sink.close());
    return ConnectFailed(ws, error, stack, certificateUntrusted: false);
  } catch (error, stack) {
    // The same exception is queued on the stream as well. Nothing will ever
    // read it, and an unread error on a socket stream is exactly the fault
    // that reaches the ambient handler with no frame of this package in its
    // trace. Swallow that copy; the caller gets the one above.
    ws.stream.listen(null, onError: (Object _) {}, cancelOnError: true);
    unawaited(ws.sink.done.catchError((Object _) => null));
    return ConnectFailed(ws, error, stack,
        certificateUntrusted: certificateUntrusted(error));
  }
  return ConnectSucceeded(ws, wsChannel(ws));
}

/// Wraps [ws] as a channel of whole string messages.
///
/// The stream is cast — cheap, a view. The sink is built by hand so that the
/// socket's own sink stays **unbound**, which is the difference that matters:
/// a channel-wide cast holds `ws.sink` in an `addStream` for the connection's
/// life, and the next writer to reach past the channel — the app-level
/// heartbeat the supervisor sends around the `Peer`, since Flutter web cannot
/// send ping frames (STACK) — gets `Bad state: Cannot add event while adding
/// stream`. Measured on this transport in `ws_transport_test.dart`.
///
/// Public, and named as the gateway names it, because that second writer is
/// how the property is provable: a caller holding the socket must still be
/// able to write to it after this has wrapped it.
///
/// **No size ceiling here, on purpose, and there is one.** This cast admits a
/// frame of any length; the ceiling (`ClientConfig.maxFrameBytes`) is applied
/// by `ConnectionSupervisor._admit` on the stream it builds over this channel,
/// because that is the one seam every inbound frame crosses on every platform
/// and through every `dial:` a harness injects — a ceiling here would cover
/// the io dial and miss the web one and the seams. What neither place can do
/// is refuse the frame before `dart:io` has assembled it; `_admit` says so.
StreamChannel<String> wsChannel(WebSocketChannel ws) =>
    StreamChannel<String>(
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
/// It is *more* load-bearing on this end than on the gateway. The server tears
/// a session down when a client leaves; the client tears a socket down on
/// every reconnect attempt, and a panel whose gateway is rebooting does that
/// for as long as the reboot takes.
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
      // Forwarded while anyone is listening, because a reset the supervisor
      // does not see is a fault that does not bite — the link reads "up" on
      // screen while nothing arrives. Swallowed afterwards.
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
