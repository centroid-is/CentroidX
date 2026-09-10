/// The transport adapter, against two real ports: one listening, one closed.
///
/// Source: 04-RESEARCH Finding 2, executed. `WebSocketChannel.connect` to a
/// dead port surfaces as `WebSocketChannelException: SocketException:
/// Connection refused (errno 61)` from **both** `ws.ready` and the stream, and
/// `closeCode` is `null` — there never was a connection to close. So the
/// adapter awaits `ready` inside a try and reports an attempt failure, and the
/// duplicate copy of the same error must not be left to land on the isolate's
/// ambient handler.
///
/// What breaks in the plant without this file. Two things, both of which the
/// panel meets on its first bad morning:
///
/// * A gateway that is not up yet is the *normal* state of a panel at
///   power-on — the switch, the server and the screen all come up in whatever
///   order the electrician wired the contactors. If a refused connect escapes
///   as an unhandled async error instead of a value the supervisor can branch
///   on, the reconnect loop dies at the first attempt and the panel stays grey
///   until someone drives to the factory.
/// * The `.cast()` trap (`ws_channel.dart:4-20`, 03-RESEARCH Finding 1) binds
///   the socket's own sink with `addStream` and keeps it bound for the whole
///   life of the connection, so the next writer to reach past the channel gets
///   `Bad state: Cannot add event while adding stream` — measured again here,
///   on this side, in exactly that form. On the gateway the later writer is the
///   fan-out tick; on the panel it is the app-level heartbeat, which STACK
///   makes mandatory because Flutter web cannot send ping frames, and anything
///   else the supervisor has to say around the `Peer` that owns the channel.
///   Nothing warns at compile time: the panel connects, shows values, and the
///   first frame the supervisor sends on its own throws. The case named
///   `a second write on a live connection still lands` is the one that bites
///   it.
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;
import 'package:web_socket_channel/web_socket_channel.dart';

/// A loopback handshake plus one echoed frame, generously: this transport's
/// measured round trip is 50 ms (04-RESEARCH Finding 8) and a loaded CI box is
/// not this machine. The budget exists to turn a hang into a named failure, not
/// to measure latency.
const Duration _socketBudget = Duration(seconds: 5);

/// A minimal echo gateway: whatever a client says, it says back.
///
/// Not the real `RelayServer` — this file is about the socket adapter, and a
/// full gateway would put a JSON-RPC handshake between the test and the thing
/// under test.
final class _EchoServer {
  _EchoServer(this._server);

  final HttpServer _server;
  final List<WebSocket> _accepted = <WebSocket>[];

  static Future<_EchoServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final echo = _EchoServer(server);
    server.listen((HttpRequest request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      echo._accepted.add(socket);
      socket.listen(
        (Object? message) {
          if (socket.closeCode == null) socket.add(message! as String);
        },
        onError: (Object _) {},
      );
    });
    return echo;
  }

  Uri get uri => Uri.parse('ws://${_server.address.host}:${_server.port}');

  /// The far end hangs up, which is what a gateway restart looks like.
  Future<void> hangUp() async {
    final open = List<WebSocket>.of(_accepted);
    _accepted.clear();
    for (final socket in open) {
      await socket.close();
    }
  }

  Future<void> stop() async {
    await hangUp();
    await _server.close(force: true);
  }
}

/// A port nothing is listening on: bind one, read its number, give it back.
Future<Uri> _closedPort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return Uri.parse('ws://127.0.0.1:$port');
}

/// The channel of a successful attempt, or a named failure — never a cast
/// error, so a broken connect reads as "it did not connect" rather than as a
/// type error twelve lines later.
StreamChannel<String> _channelOf(ConnectAttempt attempt) => switch (attempt) {
      ConnectSucceeded(:final StreamChannel<String> channel) => channel,
      ConnectFailed(:final Object error) =>
        fail('the attempt failed instead of connecting: $error'),
    };

void main() {
  group('a live gateway', () {
    late _EchoServer echo;

    setUp(() async {
      echo = await _EchoServer.start();
      addTearDown(echo.stop);
    });

    test('a frame written immediately after connect comes back', () async {
      final attempt =
          await within(connect(echo.uri), 'the connect attempt settling',
              budget: _socketBudget);
      final channel = _channelOf(attempt);
      addTearDown(() async => channel.sink.close());

      final firstEcho = Completer<String>();
      channel.stream.listen((String message) {
        if (!firstEcho.isCompleted) firstEcho.complete(message);
      });
      channel.sink.add('hello');

      expect(
        await within(firstEcho.future, 'the first frame coming back',
            budget: _socketBudget),
        'hello',
        reason: 'if the first frame after connect never lands, the handshake '
            'never completes and every panel shows a spinner forever',
      );
    });

    test('a second write on a live connection still lands', () async {
      // The socket is built here rather than through `connect` because the
      // property under test is what the adapter leaves *unbound*: a second
      // writer must still be able to reach the socket after the channel exists.
      final ws = WebSocketChannel.connect(echo.uri);
      await within(ws.ready, 'the handshake', budget: _socketBudget);
      final channel = wsChannel(ws);
      addTearDown(() async => channel.sink.close());

      final echoed = <String>[];
      final both = Completer<void>();
      channel.stream.listen((String message) {
        echoed.add(message);
        if (echoed.length == 2 && !both.isCompleted) both.complete();
      });

      channel.sink.add('the operator pressed a button');
      await within(
        Future<void>.delayed(Duration.zero),
        'a turn of the event loop between the two writes',
        budget: _socketBudget,
      );
      // The push that a cast of the whole channel makes throw: the socket's own
      // sink is still bound by the `addStream` the cast set up. Measured, on
      // this transport: `Bad state: Cannot add event while adding stream.`
      ws.sink.add('the heartbeat, sent around the Peer');

      await within(both.future, 'both frames coming back',
          budget: _socketBudget);
      expect(
        echoed,
        <String>[
          'the operator pressed a button',
          'the heartbeat, sent around the Peer',
        ],
        reason: 'the supervisor writes an app-level heartbeat around the Peer '
            'that owns the channel, because Flutter web cannot send ping '
            'frames; if the cast locked the socket, the panel connects, shows '
            'values, and the liveness check it depends on throws on its first '
            'beat',
      );
    });

    test('the stream completes when the far end hangs up', () async {
      final attempt =
          await within(connect(echo.uri), 'the connect attempt settling',
              budget: _socketBudget);
      final channel = _channelOf(attempt);

      final closed = Completer<void>();
      channel.stream.listen((_) {}, onDone: closed.complete);
      await echo.hangUp();

      await within(closed.future, 'the channel stream completing on hang-up',
          budget: _socketBudget);
      expect(
        attempt,
        isA<ConnectSucceeded>(),
        reason: 'a gateway restart must reach the supervisor as a finished '
            'stream, because that is the only signal that starts the '
            'reconnect — a link that dies silently leaves the panel showing '
            'values that stopped updating minutes ago',
      );
    });
  });

  group('a closed port', () {
    test('a refused connect fails as an attempt, not as a zone error',
        () async {
      final uri = await _closedPort();
      final zoneErrors = <Object>[];

      final attempt = await within(
        runZonedGuarded<Future<ConnectAttempt>>(
          () => connect(uri),
          (Object error, StackTrace stack) => zoneErrors.add(error),
        )!,
        'the refused connect settling as an attempt failure',
        budget: _socketBudget,
      );

      // Finding 2: the same exception arrives twice, once from `ready` and once
      // from the stream. The second copy is the one that lands on the ambient
      // handler and gets attributed to whichever case runs next.
      await pumpEventQueue();

      expect(
        attempt,
        isA<ConnectFailed>(),
        reason: 'a gateway that is not up yet is the normal state of a panel '
            'at power-on; the supervisor has to be able to branch on it',
      );
      expect(
        zoneErrors,
        isEmpty,
        reason: 'a connect failure escaping to the isolate handler kills the '
            'reconnect loop on its first attempt and makes package:test blame '
            'whichever case runs next',
      );
    });

    test('a refused connect reports no close code', () async {
      final uri = await _closedPort();
      final attempt = await within(connect(uri), 'the refused connect settling',
          budget: _socketBudget);

      expect(
        attempt.closeCode,
        isNull,
        reason: 'there was never a connection, so there is no code to read — '
            'and a supervisor that read one here would be branching on a '
            'number the OS never sent (Finding 2: killOnce produced 1002)',
      );
    });

    test('the failure carries the exception the caller has to log', () async {
      final uri = await _closedPort();
      final attempt = await within(connect(uri), 'the refused connect settling',
          budget: _socketBudget);

      final message = switch (attempt) {
        ConnectFailed(:final Object error) => '$error',
        ConnectSucceeded() => fail('the closed port accepted a connection'),
      };

      // The property is that the cause survives the wrapping, not that it
      // survives in any one platform's words. A refused dial reads
      // "Connection refused (OS Error: Connection refused, errno = 61)" on
      // POSIX and "The remote computer refused the network connection (OS
      // Error: ..., errno = 1225)" on Windows — same fault, same thing to tell
      // the integrator, two sentences. Pinning the POSIX phrasing failed the
      // Windows leg for saying it in English rather than for saying nothing.
      expect(message, matches(RegExp('refused', caseSensitive: false)),
          reason: 'the operator-facing health line says why the panel is not '
              'connected; "attempt failed" with no cause is a call to the '
              'integrator. What arrived: $message');

      // Anti-vacuity in the direction that matters: "refused" alone would also
      // be satisfied by a hand-written sentence with the real exception thrown
      // away. These two are what an integrator actually needs off the line —
      // the class of fault and the number to look up.
      expect(message, contains('SocketException'),
          reason: 'the underlying exception was replaced by prose somewhere in '
              'the transport, so the caller logs a summary and not a fault: '
              '$message');
      expect(message, contains('errno'),
          reason: 'the OS error number did not survive, and it is the half of '
              'this line that is the same in every language: $message');
    });
  });

  group('mutedRepublish', () {
    test('cancelling the consumer does not cancel the socket subscription',
        () async {
      var sourceCancelled = false;
      final source =
          StreamController<String>(onCancel: () => sourceCancelled = true);
      addTearDown(source.close);

      final subscription = mutedRepublish(source.stream).listen((_) {});
      await subscription.cancel();
      await pumpEventQueue();

      expect(
        sourceCancelled,
        isFalse,
        reason: 'a socket with no Dart listener delivers its next error to the '
            'isolate ambient handler; the reconnect loop tears one down on '
            'every attempt, so this fires constantly',
      );
    });

    test('an error arriving after the consumer cancels reaches nobody',
        () async {
      final source = StreamController<String>();
      addTearDown(source.close);
      final seen = <Object>[];

      final subscription = mutedRepublish(source.stream).listen(
        (_) {},
        onError: seen.add,
      );
      await subscription.cancel();
      source.addError(const SocketException('Broken pipe'));
      await pumpEventQueue();

      expect(
        seen,
        isEmpty,
        reason: 'a fault on a socket nobody is reading is normal at teardown '
            'and must stay silent',
      );
    });

    test('an error arriving while the consumer listens is forwarded', () async {
      final source = StreamController<String>();
      addTearDown(source.close);
      final seen = <Object>[];

      final subscription = mutedRepublish(source.stream).listen(
        (_) {},
        onError: seen.add,
      );
      addTearDown(subscription.cancel);
      source.addError(const SocketException('Connection reset by peer'));
      await pumpEventQueue();

      expect(
        seen,
        hasLength(1),
        reason: 'a reset the supervisor does not see is a fault that does not '
            'bite: the link stays "up" on screen while nothing arrives',
      );
    });
  });
}
