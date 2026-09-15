@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:open62541/open62541.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/state_man.dart' show StateManException;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The drain period the arms run at. Short enough that a whole suite of
/// tick-driven arms costs milliseconds, long enough that "several notifications
/// between two ticks" is a thing the test can actually arrange.
const _interval = Duration(milliseconds: 10);

/// A stand-in for the worker's live [StateMan], carrying only the two methods
/// the pipe endpoint uses.
///
/// Every hazard the endpoint has to survive is a knob here: a subscribe that
/// never completes (the blackholed `_monitorLoop`, R-3), a subscribe that
/// throws, a write that succeeds, a write that is refused BY NAME, a write that
/// dies of link loss, and a write that never answers at all.
class _FakeUpstream implements PipeUpstream {
  final Map<String, StreamController<DynamicValue>> controllers = {};
  final List<String> subscribeCalls = [];

  /// Keys whose `subscribe` future never completes.
  final Set<String> hangingKeys = {};

  /// Keys whose `subscribe` future throws.
  final Map<String, Object> subscribeFailures = {};

  /// Keys whose `subscribe` future is held open until [resolveSubscribe].
  ///
  /// The controllable version of [hangingKeys]: it lets an arm stand inside the
  /// subscribe→ready window — the one `_monitorLoop` can hold open across
  /// `awaitConnect`, `doTheWork` and a 10 s `subscriptionCreate` — and decide
  /// what happens in it.
  final Set<String> deferredKeys = {};
  final Map<String, Completer<Stream<DynamicValue>>> _deferred = {};

  /// How many times each key's stream was listened to and cancelled.
  ///
  /// This is the observable that stands in for `AutoDisposingStream`: it tears
  /// its raw OPC UA monitored items down in `_handleCancel`, which cannot fire
  /// until `_handleListen` has fired at least once. A stream that is never
  /// touched leaks the items on the PLC, and these counters are how an arm sees
  /// the difference between "declined" and "released".
  final Map<String, int> listenCounts = {};
  final Map<String, int> cancelCounts = {};

  final List<({String key, DynamicValue value})> writes = [];

  /// Thrown by `write` when non-null.
  Object? writeError;

  /// How long `write` takes before it answers.
  Duration writeDelay = Duration.zero;

  StreamController<DynamicValue> controllerFor(String key) =>
      controllers.putIfAbsent(
        key,
        () => StreamController<DynamicValue>(
          onListen: () => listenCounts[key] = (listenCounts[key] ?? 0) + 1,
          onCancel: () => cancelCounts[key] = (cancelCounts[key] ?? 0) + 1,
        ),
      );

  @override
  Future<Stream<DynamicValue>> subscribe(String key) {
    subscribeCalls.add(key);
    if (hangingKeys.contains(key)) return Completer<Stream<DynamicValue>>().future;
    final failure = subscribeFailures[key];
    if (failure != null) return Future<Stream<DynamicValue>>.error(failure);
    if (deferredKeys.contains(key)) {
      return (_deferred[key] = Completer<Stream<DynamicValue>>()).future;
    }
    return Future.value(controllerFor(key).stream);
  }

  /// Hands over the stream a [deferredKeys] subscribe has been holding back.
  void resolveSubscribe(String key) =>
      _deferred.remove(key)!.complete(controllerFor(key).stream);

  @override
  Future<void> write(String key, DynamicValue value) async {
    writes.add((key: key, value: value));
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    final error = writeError;
    if (error != null) throw error;
  }

  /// Deliberately does NOT await `close()`. A single-subscription controller
  /// that never had a listener — or whose listener was cancelled — never
  /// completes its close future, and an arm where a key was unsubscribed before
  /// its stream attached is exactly that case.
  void dispose() {
    for (final c in controllers.values) {
      if (!c.isClosed) c.close();
    }
  }
}

/// An open62541 sample as a server would hand one over.
DynamicValue _sample(Object? value, {int? statusCode = 0, DateTime? stamped}) =>
    DynamicValue(value: value)
      ..statusCode = statusCode
      ..sourceTimestamp = stamped;

void main() {
  late _FakeUpstream upstream;
  late ReceivePort port;
  late List<Object?> received;
  late PipeWorkerEndpoint endpoint;

  /// Waits out [n] drain periods plus a margin, then drains the event queue.
  ///
  /// The second half is not optional. `SendPort.send` inside one isolate still
  /// goes through the message queue, so a frame the tick has already handed
  /// over is not yet in [received] when a plain `Future.delayed` resumes — and
  /// under load (the logger's PrettyPrinter is the usual culprit) that race
  /// loses about one run in three.
  Future<void> ticks([int n = 2]) async {
    await Future<void>.delayed(_interval * n + const Duration(milliseconds: 8));
    await pumpEventQueue(times: 10);
  }

  /// Every frame main received, in order.
  List<PipeFrame> frames() => received.whereType<PipeFrame>().toList();

  /// Every priority-lane event main received, in order, flattened.
  List<Object?> priority() => [for (final f in frames()) ...f.priority];

  setUp(() {
    upstream = _FakeUpstream();
    received = [];
    port = ReceivePort();
    port.listen(received.add);
    endpoint = PipeWorkerEndpoint(
      stateMan: upstream,
      toMain: port.sendPort,
      drainInterval: _interval,
    );
  });

  tearDown(() {
    endpoint.dispose();
    upstream.dispose();
    port.close();
  });

  group('subscribe / unsubscribe control + the listener-gated drain tick', () {
    test('an idle endpoint runs no timer and sends nothing', () async {
      expect(endpoint.isDraining, isFalse,
          reason: 'a worker with no subscribed keys must not arm a Timer');
      await ticks(4);
      expect(received, isEmpty);
      expect(endpoint.isDraining, isFalse);
    });

    test('the drain timer starts on the 0 -> 1 subscribed-key transition',
        () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      expect(endpoint.isDraining, isTrue);
      expect(upstream.subscribeCalls, ['k']);
    });

    test('a subscribed key crosses on the next tick, translated', () async {
      final stamped = DateTime.utc(2026, 9, 5, 12, 30, 15);
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(42, stamped: stamped));
      await ticks(2);

      final values = frames().expand((f) => f.values.entries).toList();
      expect(values, hasLength(1));
      expect(values.single.key, 'k');
      final v = values.single.value;
      expect(v, isA<relay.DynamicValue>());
      expect(v.value, 42);
      expect(v.quality, relay.Quality.good);
      expect(v.sourceTime, stamped);
    });

    test('a sample carries the node data type main needs to write it back',
        () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(42)
        ..typeId = NodeId.fromNumeric(0, Namespace0Id.int16.value));
      await ticks(2);

      final values = frames().expand((f) => f.values.entries).toList();
      // The write payload's ONLY honest source of an integer width. Without
      // it main can offer the worker nothing but the Dart runtime type, which
      // makes every Int16 setpoint an Int64 guess and a Bad_TypeMismatch.
      expect(values.single.value.sourceTypeId, 'ns=0;i=4');
    });

    test('100 notifications between two ticks conflate to one value', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      // Drop everything the subscribe itself may have produced.
      received.clear();
      for (var i = 0; i < 100; i++) {
        upstream.controllerFor('k').add(_sample(i));
      }
      await ticks(2);

      final values = frames().expand((f) => f.values.entries).toList();
      expect(values, hasLength(1),
          reason: 'the tick is bounded by subscribed keys, not notifications');
      expect(values.single.value.value, 99);
    });

    test('a tick with an empty buffer sends nothing', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(5);
      expect(received, isEmpty,
          reason: 'the drain sends only when dirty — no heartbeat frames');
    });

    test('unsubscribe cancels the key stream and stops piping it', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(1));
      await ticks(2);
      expect(frames(), hasLength(1));

      endpoint.handleControl(const PipeUnsubscribe('k'));
      await ticks(1);
      expect(upstream.controllerFor('k').hasListener, isFalse,
          reason: 'the stored StreamSubscription must be cancelled');

      received.clear();
      upstream.controllerFor('k').add(_sample(2));
      await ticks(3);
      expect(received, isEmpty);
    });

    test('unsubscribing the last key cancels the drain timer', () async {
      endpoint.handleControl(const PipeSubscribe('a'));
      endpoint.handleControl(const PipeSubscribe('b'));
      await ticks(1);
      expect(endpoint.isDraining, isTrue);

      endpoint.handleControl(const PipeUnsubscribe('a'));
      await ticks(1);
      expect(endpoint.isDraining, isTrue, reason: 'b is still subscribed');

      endpoint.handleControl(const PipeUnsubscribe('b'));
      await ticks(1);
      expect(endpoint.isDraining, isFalse);
    });

    test('unsubscribe drops the key pending in the buffer', () async {
      // A period long enough that the whole subscribe → sample → unsubscribe
      // sequence provably fits inside ONE window. At the suite's 10 ms period
      // an overdue tick can fire between the sample's delivery microtask and
      // the next timer, which would make this arm a coin toss rather than a
      // statement about the buffer.
      final slow = PipeWorkerEndpoint(
        stateMan: upstream,
        toMain: port.sendPort,
        drainInterval: const Duration(milliseconds: 300),
      );
      addTearDown(slow.dispose);

      slow.handleControl(const PipeSubscribe('k'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      upstream.controllerFor('k').add(_sample(7));
      await Future<void>.delayed(Duration.zero);
      slow.handleControl(const PipeUnsubscribe('k'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue(times: 10);

      final values = frames().expand((f) => f.values.entries).toList();
      expect(values.where((e) => e.key == 'k'), isEmpty,
          reason: 'a retired key must not deliver a reading behind its own '
              'unsubscribe');
    });

    test(
        'a key unsubscribed while its subscribe is in flight still releases '
        'the stream it is handed', () async {
      // The race: main subscribes, the operator navigates away (AssetStack
      // tears every asset down on a fresh page), the unsubscribe lands — and
      // only THEN does `_monitorLoop` finish and hand a stream over.
      //
      // Declining to wire it up is correct but not sufficient. StateMan's
      // `_monitor` created the four monitored items on the PLC before that
      // future resolved, independent of whether anybody ever listens, and
      // `AutoDisposingStream` only reaps them on a listen→cancel transition.
      // A stream this endpoint never touches is a monitored item that stays
      // live on a real PLC for the rest of the worker's life — with no code
      // path left to reap it, because the next successful subscribe reuses
      // the same cached stream and hides the leak.
      upstream.deferredKeys.add('k');
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      endpoint.handleControl(const PipeUnsubscribe('k'));
      upstream.resolveSubscribe('k');
      await ticks(1);

      expect(upstream.listenCounts['k'], 1,
          reason: 'the unwanted stream must be listened to once, or '
              'AutoDisposingStream._handleListen never fires and its teardown '
              'can never be reached');
      expect(upstream.cancelCounts['k'], 1,
          reason: 'and cancelled straight back, so the 1→0 listener '
              'transition arms the idle teardown that reaps the monitored '
              'item');
      expect(endpoint.subscribedKeys, isEmpty);

      received.clear();
      upstream.controllerFor('k').add(_sample(9));
      await ticks(3);
      expect(received, isEmpty,
          reason: 'releasing it is not attaching it — a key nobody asked for '
              'must still pipe nothing');
    });

    test('a hung subscribe parks neither a later subscribe nor an unsubscribe',
        () async {
      upstream.hangingKeys.add('blackholed');
      endpoint.handleControl(const PipeSubscribe('blackholed'));
      endpoint.handleControl(const PipeSubscribe('healthy'));
      endpoint.handleControl(const PipeUnsubscribe('blackholed'));
      await ticks(1);

      expect(upstream.subscribeCalls, contains('healthy'));
      upstream.controllerFor('healthy').add(_sample(3));
      await ticks(2);
      final values = frames().expand((f) => f.values.entries).toList();
      expect(values.map((e) => e.key), ['healthy']);
    });
  });

  group('errors / onDone / permanent errors ride the priority lane', () {
    test('a typed UaStatusException lands on the priority lane un-conflated',
        () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      received.clear();

      // value -> error -> value, all inside one tick.
      upstream.controllerFor('k').add(_sample(1));
      upstream.controllerFor('k')
          .addError(const UaStatusException(0x80050000)); // BadCommunicationError
      upstream.controllerFor('k').add(_sample(2));
      await ticks(2);

      final errors = priority().whereType<PipeKeyError>().toList();
      expect(errors, hasLength(1));
      expect(errors.single.key, 'k');
      expect(errors.single.quality, relay.Quality.badCommFault);

      final values = frames().expand((f) => f.values.entries).toList();
      expect(values, hasLength(1),
          reason: 'telemetry still conflates, the error is beside it');
      expect(values.single.value.value, 2);
    });

    test('onDone announces the retirement and clears the pending value',
        () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      received.clear();

      upstream.controllerFor('k').add(_sample(5));
      await upstream.controllerFor('k').close();
      await ticks(2);

      final retired = priority().whereType<PipeKeyRetired>().toList();
      expect(retired, hasLength(1), reason: 'silence is not acceptable');
      expect(retired.single.key, 'k');
      final values = frames().expand((f) => f.values.entries).toList();
      expect(values, isEmpty,
          reason: 'a reading for a retired key is worse than no reading');
    });

    test('a permanent-error quality is emitted on transition only', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      received.clear();

      // BadNodeIdUnknown -> errorConfig. The monitor loop retries it forever.
      for (var i = 0; i < 5; i++) {
        upstream.controllerFor('k')
            .addError(const UaStatusException(0x80340000));
        await ticks(2);
      }

      final errors = priority().whereType<PipeKeyError>().toList();
      expect(errors, hasLength(1),
          reason: 'mirrors _loggedPermanentError: reported once, never per '
              'retry');
      expect(errors.single.quality, relay.Quality.errorConfig);
    });

    test('a permanent error re-emits after the key recovers', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      received.clear();

      upstream.controllerFor('k').addError(const UaStatusException(0x80340000));
      await ticks(2);
      upstream.controllerFor('k').add(_sample(1));
      await ticks(2);
      upstream.controllerFor('k').addError(const UaStatusException(0x80340000));
      await ticks(2);

      expect(priority().whereType<PipeKeyError>(), hasLength(2),
          reason: 'transition-only means the NEXT transition still speaks');
    });

    test('a failing subscribe reports and does not park another key', () async {
      upstream.subscribeFailures['dead'] =
          const UaStatusException(0x80340000); // BadNodeIdUnknown
      endpoint.handleControl(const PipeSubscribe('dead'));
      endpoint.handleControl(const PipeSubscribe('alive'));
      await ticks(2);

      final errors = priority().whereType<PipeKeyError>().toList();
      expect(errors.map((e) => e.key), ['dead']);
      expect(errors.single.quality, relay.Quality.errorConfig);

      upstream.controllerFor('alive').add(_sample(9));
      await ticks(2);
      final values = frames().expand((f) => f.values.entries).toList();
      expect(values.map((e) => e.key), ['alive']);
    });
  });

  group('write execution and three-state classification', () {
    test('a successful write echoes (id, WriteApplied)', () async {
      endpoint.handleControl(
          PipeWriteRequest(7, 'k', relay.DynamicValue(value: 1)));
      await ticks(2);

      final outcomes = priority().whereType<PipeWriteOutcome>().toList();
      expect(outcomes, hasLength(1));
      expect(outcomes.single.id, 7);
      expect(outcomes.single.result, isA<relay.WriteApplied>());
      expect(outcomes.single.result.cmd, '7',
          reason: 'cmd is the id as text; the int rides beside it');
    });

    test('a named refusal classifies as WriteRejected', () async {
      upstream.writeError =
          StateManException('Failed to write node: "k": '
              '${const UaStatusException(0x803B0000)}'); // Bad_NotWritable
      endpoint.handleControl(
          PipeWriteRequest(8, 'k', relay.DynamicValue(value: 1)));
      await ticks(2);

      final outcome = priority().whereType<PipeWriteOutcome>().single;
      expect(outcome.id, 8);
      expect(outcome.result, isA<relay.WriteRejected>());
      expect((outcome.result as relay.WriteRejected).reason.status,
          'Bad_NotWritable');
    });

    test('an unrecognised failure classifies as WriteUnknown — the safe half',
        () async {
      upstream.writeError = StateManException(
          'Failed to write node: "k": SocketException: connection reset');
      endpoint.handleControl(
          PipeWriteRequest(9, 'k', relay.DynamicValue(value: 1)));
      await ticks(2);

      final outcome = priority().whereType<PipeWriteOutcome>().single;
      expect(outcome.result, isA<relay.WriteUnknown>());
    });

    test('a write is executed at most once — never retried', () async {
      upstream.writeError = StateManException('Failed to write node: "k": nope');
      endpoint.handleControl(
          PipeWriteRequest(10, 'k', relay.DynamicValue(value: 1)));
      await ticks(6);
      expect(upstream.writes, hasLength(1));
      expect(priority().whereType<PipeWriteOutcome>(), hasLength(1));
    });

    test('a write that never answers settles unknown inside the worker deadline',
        () async {
      upstream.writeDelay = const Duration(seconds: 30);
      endpoint = PipeWorkerEndpoint(
        stateMan: upstream,
        toMain: port.sendPort,
        drainInterval: _interval,
        writeDeadline: const Duration(milliseconds: 40),
      );
      endpoint.handleControl(
          PipeWriteRequest(11, 'k', relay.DynamicValue(value: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await pumpEventQueue(times: 10);

      final outcome = priority().whereType<PipeWriteOutcome>().single;
      expect(outcome.id, 11);
      expect(outcome.result, isA<relay.WriteUnknown>());
      expect(upstream.writes, hasLength(1), reason: 'no re-send on expiry');
    });

    test('a write outcome reaches main even with no subscribed key', () async {
      expect(endpoint.isDraining, isFalse);
      endpoint.handleControl(
          PipeWriteRequest(12, 'k', relay.DynamicValue(value: 1)));
      await ticks(2);
      expect(priority().whereType<PipeWriteOutcome>(), hasLength(1),
          reason: 'an idle worker runs no tick, so the write answer cannot '
              'depend on one');
    });

    test('the payload is rebuilt with a usable open62541 type id', () async {
      endpoint.handleControl(PipeWriteRequest(
          13, 'k', relay.DynamicValue(value: 42, sourceTypeId: 'ns=0;i=6')));
      await ticks(2);
      final written = upstream.writes.single.value;
      expect(written.value, 42);
      expect(written.typeId, isNotNull,
          reason: 'valueToVariant throws without one — a write with no type '
              'is a write that can never encode');
      expect(written.typeId.toString(), 'ns=0;i=6');
    });

    test('a payload with no source type id still gets an inferred type',
        () async {
      endpoint.handleControl(
          PipeWriteRequest(14, 'k', relay.DynamicValue(value: true)));
      await ticks(2);
      final written = upstream.writes.single.value;
      expect(written.value, true);
      expect(written.typeId, NodeId.boolean);
    });
  });

  group('the control inbox: nothing main sends is dropped on the floor', () {
    test('control messages queued before the endpoint attaches are replayed',
        () async {
      final inbox = PipeControlInbox(toMain: port.sendPort);
      inbox.receive(const PipeSubscribe('k'));
      inbox.receive(const PipeSubscribe('j'));
      inbox.receive(const PipeUnsubscribe('j'));
      expect(upstream.subscribeCalls, isEmpty);

      inbox.attach(endpoint);
      await ticks(1);
      expect(upstream.subscribeCalls, ['k', 'j']);
      upstream.controllerFor('k').add(_sample(4));
      await ticks(2);
      final values = frames().expand((f) => f.values.entries).toList();
      expect(values.map((e) => e.key), ['k']);
    });

    test('a write that arrives before the stack is up is answered unknown, '
        'not executed late', () async {
      final inbox = PipeControlInbox(toMain: port.sendPort);
      inbox.receive(PipeWriteRequest(21, 'k', relay.DynamicValue(value: 1)));
      await ticks(1);

      final outcome = priority().whereType<PipeWriteOutcome>().single;
      expect(outcome.id, 21);
      expect(outcome.result, isA<relay.WriteUnknown>());

      inbox.attach(endpoint);
      await ticks(2);
      expect(upstream.writes, isEmpty,
          reason: 'a write already answered unknown must never be executed '
              'later — that is a re-send nobody asked for');
    });
  });
}
