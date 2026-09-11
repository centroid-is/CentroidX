/// The two things plan 13-03 adds to the pipe itself: the retirement hook that
/// discharges Phase 12's IN-02, and `PipeResnapshot` — the one batched control
/// message a round trip is counted against.
///
/// **Why a new file rather than arms in `pipe_main_endpoint_test.dart`.** Plans
/// 13-01 through 13-08 run in overlapping waves against one working tree, so
/// every plan writes its own test file and edits nobody else's. The four Phase
/// 12 suites are run unchanged beside this one as regression cover; if an arm
/// there moves, this plan broke something it does not own.
///
/// Port delivery is asynchronous even inside one isolate — 12-05 lost three
/// arms to that — so every arm that asserts on control traffic drains the event
/// queue first through [_settle].
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:open62541/open62541.dart' as ua;
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// A worker main can talk to, with no isolate behind it.
///
/// The control port is a REAL [ReceivePort], because its delivery semantics are
/// what the endpoint has to live with. [answersResnapshot] is the switch the
/// no-hang arm flips: a worker that hears a [PipeResnapshot] and says nothing
/// back is exactly the blackholed-upstream case, and main must resolve anyway.
class _FakeLink implements PipeWorkerLink {
  _FakeLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  /// Everything main sent down the control channel, in order.
  final List<Object?> received = <Object?>[];

  /// The worker's last reading per key — what a resnapshot re-delivers.
  final Map<String, relay.DynamicValue> last = <String, relay.DynamicValue>{};

  /// Whether this worker answers a [PipeResnapshot] at all.
  bool answersResnapshot = true;

  bool down = false;
  int kills = 0;

  @override
  SendPort? get controlPort => down ? null : _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() => kills++;

  /// One message from the worker to main.
  void emit(Object? message) {
    if (_out.isClosed) return;
    _out.add(message);
  }

  /// Delivers [value] for [key] as a worker frame, and remembers it.
  void deliver(String key, relay.DynamicValue value) {
    last[key] = value;
    emit(PipeFrame(const <Object?>[], <String, relay.DynamicValue>{key: value}));
  }

  List<PipeResnapshot> get resnapshots =>
      received.whereType<PipeResnapshot>().toList();

  List<PipeUnsubscribe> get unsubscribes =>
      received.whereType<PipeUnsubscribe>().toList();

  void _onControl(Object? message) {
    received.add(message);
    if (message is! PipeResnapshot || !answersResnapshot) return;
    // The production worker's answer: ONE frame carrying every named key it
    // has a reading for. Not one frame per key — that is sabotage (b)'s shape.
    final values = <String, relay.DynamicValue>{
      for (final key in message.keys)
        if (last[key] != null) key: last[key]!,
    };
    emit(PipeFrame(const <Object?>[], values));
  }

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

/// Port delivery is asynchronous even inside one isolate. See the library doc.
Future<void> _settle() => pumpEventQueue(times: 10);

relay.DynamicValue _good(Object? v) => relay.DynamicValue(
      value: v,
      sourceTime: DateTime.utc(2026, 1, 1),
    );

/// Quiet: these arms assert on control traffic, not on log lines, and the
/// endpoint warns loudly about keys no worker owns by design.
Logger _quiet() => Logger(level: Level.off);

void main() {
  late _FakeLink alpha;
  late _FakeLink beta;
  late PipeMainEndpoint endpoint;

  setUp(() {
    alpha = _FakeLink('alpha');
    beta = _FakeLink('beta');
    endpoint = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 120),
      logger: _quiet(),
    );
    endpoint.addWorker(alpha, const <String>['a.one', 'a.two', 'a.three']);
    endpoint.addWorker(beta, const <String>['b.one', 'b.two']);
  });

  tearDown(() {
    endpoint.dispose();
    alpha.dispose();
    beta.dispose();
  });

  group('the retirement hook', () {
    test(
        'a retired key is retracted by main, or the worker\'s drain timer '
        'never disarms (IN-02)', () async {
      // The obligation, quoted from 12-REVIEW and from `_onDone`'s own doc:
      // "_onDone removes the key from _streams, the buffer and _permanentError,
      // and announces PipeKeyRetired — but deliberately leaves the key in
      // _subscribed ('main is the only thing that retracts it'). Since
      // _disarmTickIfIdle only fires on _unsubscribe, a worker whose only
      // subscribed key was permanently retired keeps its 50 ms drain timer
      // running forever."
      final retired = <String>[];
      endpoint.onKeyRetired = (key) {
        retired.add(key);
        endpoint.unsubscribe(key);
      };

      endpoint.subscribe('a.one');
      endpoint.subscribe('a.two');
      await _settle();
      alpha.received.clear();

      alpha.emit(PipeFrame(
          const <Object?>[PipeKeyRetired('a.one')], const <String, relay.DynamicValue>{}));
      await _settle();

      expect(retired, <String>['a.one'],
          reason: 'the hook must fire once, naming the retired key');
      expect(alpha.unsubscribes.map((m) => m.key), <String>['a.one'],
          reason: 'a PipeUnsubscribe for exactly the retired key must cross to '
              'the worker; without it _disarmTickIfIdle never runs and the '
              '50ms drain timer stays armed for the life of the process');
      expect(endpoint.refcountOf('a.one'), 0);
      expect(endpoint.refcountOf('a.two'), 1,
          reason: 'the sibling key on the same worker is untouched');
      expect(endpoint.subscribedKeys(0), <String>{'a.two'});
    });

    test('the hook fires AFTER the errorConfig value is applied', () async {
      // Ordering matters: a consumer that unsubscribes first would race the
      // value it is supposed to see last, and would read the key as still
      // carrying its old good reading at the moment it decides what to do.
      relay.Quality? qualityAtHookTime;
      Object? valueAtHookTime;
      endpoint.onKeyRetired = (key) {
        qualityAtHookTime = endpoint.read(key).quality;
        valueAtHookTime = endpoint.read(key).value;
      };

      endpoint.subscribe('a.one');
      alpha.deliver('a.one', _good(7));
      await _settle();
      expect(endpoint.read('a.one').value, 7, reason: 'fixture precondition');

      alpha.emit(PipeFrame(
          const <Object?>[PipeKeyRetired('a.one')], const <String, relay.DynamicValue>{}));
      await _settle();

      expect(qualityAtHookTime, relay.Quality.errorConfig,
          reason: 'the consumer must observe the retirement already applied; '
              'firing the hook first shows it the pre-retirement reading');
      expect(valueAtHookTime, isNull);
    });

    test('a consumer that throws does not stop the message pump', () async {
      endpoint.onKeyRetired = (_) => throw StateError('consumer blew up');

      endpoint.subscribe('a.one');
      await _settle();
      alpha.emit(PipeFrame(
          const <Object?>[PipeKeyRetired('a.one')], const <String, relay.DynamicValue>{}));
      await _settle();

      // The pump survived: a later frame still lands in the cache.
      alpha.deliver('a.two', _good(11));
      await _settle();
      expect(endpoint.read('a.two').value, 11,
          reason: 'one bad consumer must not take the whole worker stream down '
              'with it — every later reading from that worker would be lost');
    });

    test('no hook registered is not an error', () async {
      endpoint.subscribe('a.one');
      await _settle();
      alpha.emit(PipeFrame(
          const <Object?>[PipeKeyRetired('a.one')], const <String, relay.DynamicValue>{}));
      await _settle();

      expect(endpoint.read('a.one').quality, relay.Quality.errorConfig);
    });
  });

  group('the resnapshot', () {
    test('fifty keys owned by one worker are ONE message and ONE round trip',
        () async {
      final keys = <String>['a.one', 'a.two', 'a.three'];
      for (final key in keys) {
        endpoint.subscribe(key);
      }
      // Fifty distinct names, all routed to alpha, so the arithmetic is about
      // the message count and not about the routing.
      final many = <String>[
        for (var i = 0; i < 50; i++) 'a.bulk$i',
      ];
      final bulk = _FakeLink('bulk');
      addTearDown(bulk.dispose);
      final bulkIndex = endpoint.addWorker(bulk, many);
      expect(bulkIndex, 2);
      for (final key in many) {
        bulk.last[key] = _good(1);
      }
      await _settle();

      final before = endpoint.resnapshots;
      await endpoint.resnapshot(many);

      expect(bulk.resnapshots, hasLength(1),
          reason: 'fifty keys on one worker must cost ONE PipeResnapshot; a '
              'per-key message is the fifty-round-trip failure readMany exists '
              'to remove');
      expect(bulk.resnapshots.single.keys, hasLength(50));
      expect(endpoint.resnapshots, before + 1);
    });

    test('keys spanning two workers are two messages and two round trips',
        () async {
      final before = endpoint.resnapshots;
      alpha.last['a.one'] = _good(1);
      beta.last['b.one'] = _good(2);

      await endpoint.resnapshot(const <String>['a.one', 'b.one', 'a.two']);

      expect(alpha.resnapshots, hasLength(1));
      expect(beta.resnapshots, hasLength(1));
      expect(alpha.resnapshots.single.keys, <String>['a.one', 'a.two'],
          reason: 'each worker is asked only about the keys it owns');
      expect(beta.resnapshots.single.keys, <String>['b.one']);
      expect(endpoint.resnapshots, before + 2,
          reason: 'a key set spanning two workers really is two round trips, '
              'and the counter must say so rather than flatter the caller');
    });

    test('a resnapshot re-delivers the current value into the cache', () async {
      endpoint.subscribe('a.one');
      alpha.last['a.one'] = _good(42);
      await _settle();
      expect(endpoint.store.peek('a.one'), isNull,
          reason: 'fixture precondition: nothing has been drained yet');

      await endpoint.resnapshot(const <String>['a.one']);

      expect(endpoint.read('a.one').value, 42);
    });

    test('a worker that never answers still resolves inside the deadline',
        () async {
      alpha.answersResnapshot = false;
      alpha.last['a.one'] = _good(1);

      final stopwatch = Stopwatch()..start();
      await endpoint
          .resnapshot(const <String>['a.one']).timeout(const Duration(seconds: 2),
              onTimeout: () => fail('resnapshot hung on a silent worker; a '
                  'read that cannot be answered must resolve anyway and let '
                  'the caller read whatever the cache has'));
      stopwatch.stop();

      expect(stopwatch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)),
          reason: 'it must actually have waited out the deadline rather than '
              'returned without asking');
      expect(alpha.resnapshots, hasLength(1));
    });

    test('a key no worker owns costs no message and no round trip', () async {
      final before = endpoint.resnapshots;

      await endpoint.resnapshot(const <String>['nobody.owns.this']);

      expect(alpha.resnapshots, isEmpty);
      expect(beta.resnapshots, isEmpty);
      expect(endpoint.resnapshots, before,
          reason: 'nothing was spawned for the key, so nothing could answer '
              'for it and no round trip was made');
    });

    test('a worker with no control port costs no round trip', () async {
      alpha.down = true;
      final before = endpoint.resnapshots;

      await endpoint.resnapshot(const <String>['a.one']);

      expect(endpoint.resnapshots, before,
          reason: 'a message that was never sent is not a round trip; '
              'counting it would let readFresh claim a freshness it never '
              'went and got');
    });
  });

  group('the worker end of a resnapshot', () {
    late _RecordingUpstream upstream;
    late ReceivePort toMain;
    late List<Object?> frames;
    late PipeWorkerEndpoint worker;

    setUp(() {
      upstream = _RecordingUpstream();
      toMain = ReceivePort();
      frames = <Object?>[];
      toMain.listen(frames.add);
      worker = PipeWorkerEndpoint(
        stateMan: upstream,
        toMain: toMain.sendPort,
        drainInterval: const Duration(milliseconds: 10),
        logger: _quiet(),
      );
    });

    tearDown(() {
      worker.dispose();
      upstream.dispose();
      toMain.close();
    });

    test('a subscribed key with a reading is re-delivered in one frame',
        () async {
      worker.handleControl(const PipeSubscribe('k.one'));
      worker.handleControl(const PipeSubscribe('k.two'));
      await _settle();
      upstream.push('k.one', 1);
      upstream.push('k.two', 2);
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      frames.clear();

      worker.handleControl(const PipeResnapshot(<String>['k.one', 'k.two']));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final delivered = frames.whereType<PipeFrame>().toList();
      expect(delivered, hasLength(1),
          reason: 'both keys must ride ONE frame — the batching is the whole '
              'reason this message carries a list');
      expect(delivered.single.values.keys, containsAll(<String>['k.one', 'k.two']));
    });

    test('a key the worker is not subscribed to is ignored, not subscribed',
        () async {
      worker.handleControl(const PipeResnapshot(<String>['k.ghost']));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(upstream.subscribed, isEmpty,
          reason: 'a resnapshot is not a subscribe; inventing one would give a '
              'key nobody watches a monitored item on the PLC');
      expect(worker.subscribedKeys, isEmpty);
      expect(frames.whereType<PipeFrame>(), isEmpty);
    });

    test('a resnapshot on an idle worker arms no drain timer', () async {
      expect(worker.isDraining, isFalse, reason: 'fixture precondition');

      worker.handleControl(const PipeResnapshot(<String>['k.one']));
      await _settle();

      expect(worker.isDraining, isFalse,
          reason: 'the listener-gating law: an idle worker runs no timer, and '
              'a read must not be the thing that arms one');
    });
  });
}

/// A [PipeUpstream] whose streams the arm drives by hand.
class _RecordingUpstream implements PipeUpstream {
  final Map<String, StreamController<ua.DynamicValue>> _controllers =
      <String, StreamController<ua.DynamicValue>>{};

  /// Keys the endpoint actually asked for a stream for.
  final List<String> subscribed = <String>[];

  @override
  Future<Stream<ua.DynamicValue>> subscribe(String key) async {
    subscribed.add(key);
    return (_controllers[key] ??=
            StreamController<ua.DynamicValue>.broadcast())
        .stream;
  }

  @override
  Future<void> write(String key, ua.DynamicValue value) async {}

  /// Pushes one open62541-shaped sample onto [key]'s stream.
  void push(String key, Object? value) {
    _controllers[key]?.add(_sample(value));
  }

  void dispose() {
    for (final controller in _controllers.values) {
      if (!controller.isClosed) controller.close();
    }
  }
}

/// One open62541 `DynamicValue`, the shape `translateOpcUaSample` reads.
ua.DynamicValue _sample(Object? value) => ua.DynamicValue(value: value)
  ..statusCode = 0
  ..sourceTimestamp = DateTime.utc(2026, 1, 1);
