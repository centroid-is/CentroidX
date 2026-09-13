/// The dial's own bound — the one thing the supervisor's schedule cannot give.
///
/// `awaitReady` grew a `timeout` because the browser arm had none. A connect to
/// an address that answers nothing takes about 75 s to fail at the operating
/// system, and the backoff ceiling is 30 s, so a single unbounded attempt
/// outlives the whole schedule the operator can see. On a panel `dart:io`
/// bounds it twice before it ever reaches here; in a browser the WebSocket API
/// offers no hook at all, and closing the socket is the only cancellation
/// there is.
///
/// **Platform-free on purpose.** These arms are the proof and they run on the
/// VM against a fake channel; the browser lane's own case in
/// `test/web/dial_web_test.dart` proves the plumbing reaches this code and
/// nothing more. Putting the proof in the browser lane would have made the
/// load-bearing assertions the ones that only run where a real socket and a
/// real network are involved.
///
/// `fakeAsync` rather than a real delay: a wall-clock timeout test is a slow
/// test that passes on a fast machine and flakes on a loaded one, and the
/// third arm below — "success does not close a live connection" — needs to
/// elapse *past* a deadline that must never fire, which no real clock can do
/// in bounded time.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('awaitReady bounds the dial', () {
    test('a dial that never completes fails with the deadline named', () {
      fakeAsync((async) {
        final ws = _FakeChannel();
        ConnectAttempt? outcome;
        // `whenComplete` rather than an `await`: the defect this arm exists
        // for is a future that NEVER completes, and an `await` on one of those
        // does not fail — it hangs, and `fakeAsync` then reports a pending
        // timer instead of the thing that is actually wrong.
        unawaited(awaitReady(ws,
                certificateUntrusted: _never,
                timeout: const Duration(seconds: 10))
            .then((value) => outcome = value));

        async.elapse(const Duration(seconds: 9));
        expect(outcome, isNull,
            reason: 'the deadline had not passed yet — a bound that fires '
                'early would turn a slow but healthy gateway into an outage');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(outcome, isA<ConnectFailed>(),
            reason: 'SABOTAGE: drop the `timeout:` argument and this future '
                'never completes at all. That is the defect — the attempt '
                'outlives the backoff ceiling and the supervisor never gets '
                'to retry.');
        final failed = outcome! as ConnectFailed;
        expect(failed.error, isA<TimeoutException>());
        expect(failed.error.toString(), contains('did not complete within'),
            reason: "the supervisor renders this into the operator's health "
                'line, so it has to read as an answer rather than as a type '
                'name');
        expect(failed.certificateUntrusted, isFalse,
            reason: 'silence is not a refused certificate, and guessing would '
                'send an engineer to the wrong end of the wire');
      });
    });

    test('and it closes the socket rather than leaving it opening', () {
      fakeAsync((async) {
        final ws = _FakeChannel();
        unawaited(awaitReady(ws,
            certificateUntrusted: _never,
            timeout: const Duration(seconds: 10)));

        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();

        expect(ws.sink.closeCalled, isTrue,
            reason: 'SABOTAGE: race the deadline with `Future.any` and return '
                'without closing. The test above still passes and this one '
                'goes red — which is the point, because the socket is then '
                'still opening, may connect a minute later with nobody '
                'holding it, and its eventual error has no handler.');
      });
    });

    test('a dial that lands in time is not closed by the deadline behind it',
        () {
      fakeAsync((async) {
        final ws = _FakeChannel();
        ConnectAttempt? outcome;
        unawaited(awaitReady(ws,
                certificateUntrusted: _never,
                timeout: const Duration(seconds: 10))
            .then((value) => outcome = value));

        async.elapse(const Duration(seconds: 1));
        ws.completeReady();
        async.flushMicrotasks();

        expect(outcome, isA<ConnectSucceeded>());

        // Well past the deadline, on a connection that is up and carrying
        // traffic.
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();

        expect(ws.sink.closeCalled, isFalse,
            reason: 'SABOTAGE: arm a bare `Timer` that closes the socket when '
                'it fires, instead of `Future.timeout` whose timer is '
                'cancelled by the source completing. The two arms above still '
                'pass; this one goes red, and the plant symptom is every '
                'panel dropping its connection ten seconds after it opened.');
      });
    });

    test('no timeout is no timer — the io arm must keep its own two bounds',
        () {
      fakeAsync((async) {
        final ws = _FakeChannel();
        ConnectAttempt? outcome;
        unawaited(awaitReady(ws, certificateUntrusted: _never)
            .then((value) => outcome = value));

        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();

        expect(outcome, isNull,
            reason: 'null means "this platform bounds its own connect", not '
                '"no policy". `pinned_dialer_io.dart` passes nothing because '
                'HttpClient.connectionTimeout already cancels and '
                'IOWebSocketChannel.connect already abandons; a third bound '
                'here would race those two.');
        expect(ws.sink.closeCalled, isFalse);
      });
    });
  });
}

bool _never(Object error) => false;

/// The smallest thing `awaitReady` can be pointed at: a `ready` nobody
/// completes unless a test says so, a stream that never emits, and a sink that
/// records whether it was closed.
class _FakeChannel extends StreamChannelMixin implements WebSocketChannel {
  final _ready = Completer<void>();
  final _incoming = StreamController<dynamic>();

  @override
  final _FakeSink sink = _FakeSink();

  void completeReady() => _ready.complete();

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  bool closeCalled = false;
  final _done = Completer<void>();

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closeCalled = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}
}
