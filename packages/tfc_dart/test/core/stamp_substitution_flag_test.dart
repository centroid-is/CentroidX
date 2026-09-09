/// The substituted-stamp flag rides the pipe from the worker to main.
///
/// **Why a flag is needed at all, given the drivers now claim nothing.**
/// `stamp_substitution_test.dart` stopped the Modbus driver and the M2400's
/// no-device-clock branch from putting a backend clock in `sourceTimestamp`.
/// That fixes direct mode outright: `AlarmMan` reads the field, gets null, and
/// D-2 labels the row `backend_receipt`.
///
/// It does **not** fix the pipe, because `translateOpcUaSample` substitutes its
/// own `arrivedAt` for an unstamped sample — deliberately, and it must keep
/// doing so. `relay.DynamicValue.sourceTime` is not only the alarm engine's
/// input: it becomes `t:` on the wire, and `RemoteStateMan._adoptReadback`'s S3
/// guard (`remote_state_man.dart:935`) compares a write readback against it to
/// refuse a superseded reading. Blanking it for the whole Modbus fleet would
/// trade one lie for a different loss. So the instant stays and the *provenance*
/// travels beside it.
///
/// **Where the fact is decided, and where it is read.** `translateOpcUaSample`
/// already knows — `stamped == null` — and already says so through
/// `onSourceTimeFallback`, synchronously, inside the call. The worker captures
/// that per sample; `PipeSendBuffer` conflates it alongside the value;
/// `PipeFrame` carries it; `PipeMainEndpoint` records it beside the store
/// (`relay.ValueStore` is in the protocol package and cannot hold it); and
/// `BackendValueSource.subscribeStamped` hands the value and its provenance to
/// the alarm engine **as one object, built inside the store's synchronous
/// notification**. Pairing at emission rather than at consumption is what makes
/// the join exact instead of a lookup that can be one frame out of date.
///
/// **The safe default is absence-means-substituted**, at both ends: a
/// `PipeFrame` that states nothing has every value in it read as a substitute,
/// and a key main has never seen in a frame reads `backendReceipt`. That covers
/// the backend-minted `PIPE.*` / `ALARM.*` values written straight through
/// `applyBatch`, which are backend receipts and should never say otherwise.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/alarm_rule_watcher.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import 'relay/fake_backend_value_source.dart';

/// A genuine plant instant. Years from every other fixture instant here, so no
/// arm can pass because two clocks happened to read the same second.
final _plantClock = DateTime.utc(2028, 4, 1, 9, 30, 0);

/// The instant the alarm engine's injected clock reads.
final _evaluationClock = DateTime.utc(2030, 12, 24, 17, 45, 0);

/// A pipe arrival instant.
final _arrivedAt = DateTime.utc(2031, 1, 1, 0, 0, 0);

relay.DynamicValue _value(Object? v, {DateTime? at}) =>
    relay.DynamicValue(value: v, sourceTime: at);

// ---------------------------------------------------------------------------
// Worker-side fixtures (shape borrowed from pipe_worker_endpoint_test.dart)
// ---------------------------------------------------------------------------

class _FakeUpstream implements PipeUpstream {
  final Map<String, StreamController<DynamicValue>> controllers = {};

  StreamController<DynamicValue> controllerFor(String key) =>
      controllers.putIfAbsent(key, () => StreamController<DynamicValue>());

  @override
  Future<Stream<DynamicValue>> subscribe(String key) =>
      Future.value(controllerFor(key).stream);

  @override
  Future<void> write(String key, DynamicValue value) async {}

  void dispose() {
    for (final c in controllers.values) {
      if (!c.isClosed) c.close();
    }
  }
}

/// An open62541 sample as a driver hands one over.
DynamicValue _sample(Object? value, {DateTime? stamped}) =>
    DynamicValue(value: value)
      ..statusCode = 0
      ..sourceTimestamp = stamped;

// ---------------------------------------------------------------------------
// Main-side fixtures (shape borrowed from pipe_main_endpoint_test.dart)
// ---------------------------------------------------------------------------

class _FakeLink implements PipeWorkerLink {
  _FakeLink(this.name) {
    _port.listen((_) {});
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  @override
  SendPort? get controlPort => _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() {}

  void emit(Object? message) => _out.add(message);

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

Future<void> _pump() => pumpEventQueue(times: 10);

void main() {
  test('the fixture instants are all distinct', () {
    expect(<DateTime>{_plantClock, _evaluationClock, _arrivedAt}, hasLength(3));
  });

  // -------------------------------------------------------------------------
  group('PipeSendBuffer conflates the provenance with the value', () {
    test('a substituted value is named in the drained frame', () {
      final buffer = PipeSendBuffer()
        ..putValue('k', _value(1, at: _arrivedAt), sourceTimeSubstituted: true);

      expect(buffer.drain().substitutedStamps, contains('k'));
    });

    test('CONTROL: a genuinely stamped value is not', () {
      final buffer = PipeSendBuffer()
        ..putValue('k', _value(1, at: _plantClock),
            sourceTimeSubstituted: false);

      final frame = buffer.drain();
      expect(frame.substitutedStamps, isNot(contains('k')));
      // Not vacuous: the frame does carry the value.
      expect(frame.values.keys, contains('k'));
    });

    test('the LATEST put for a key wins, provenance included', () {
      // Conflation is the buffer's whole job. A key that was substituted and is
      // then genuinely stamped inside one tick must not stay flagged, and the
      // reverse must not be lost.
      final buffer = PipeSendBuffer()
        ..putValue('k', _value(1, at: _arrivedAt), sourceTimeSubstituted: true)
        ..putValue('k', _value(2, at: _plantClock),
            sourceTimeSubstituted: false);
      expect(buffer.drain().substitutedStamps, isNot(contains('k')));

      final other = PipeSendBuffer()
        ..putValue('k', _value(1, at: _plantClock), sourceTimeSubstituted: false)
        ..putValue('k', _value(2, at: _arrivedAt), sourceTimeSubstituted: true);
      expect(other.drain().substitutedStamps, contains('k'));
    });

    test('a retired key takes its provenance with it', () {
      final buffer = PipeSendBuffer()
        ..putValue('k', _value(1, at: _arrivedAt), sourceTimeSubstituted: true)
        ..remove('k');

      final frame = buffer.drain();
      expect(frame.values, isEmpty);
      expect(frame.substitutedStamps, isEmpty);
    });

    test('a quality-only transition with no pending value is substituted', () {
      // The buffer mints this sample itself. Nobody sourced it, so it may not
      // travel as anything but a backend receipt.
      final buffer = PipeSendBuffer()
        ..putQuality('k', relay.Quality.badCommFault);

      expect(buffer.drain().substitutedStamps, contains('k'));
    });

    test('drain leaves nothing behind', () {
      final buffer = PipeSendBuffer()
        ..putValue('k', _value(1, at: _arrivedAt), sourceTimeSubstituted: true);
      buffer.drain();

      expect(buffer.drain().substitutedStamps, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('the worker flags what translateOpcUaSample substituted', () {
    late _FakeUpstream upstream;
    late ReceivePort port;
    late List<Object?> received;
    late PipeWorkerEndpoint endpoint;

    const interval = Duration(milliseconds: 10);

    Future<void> ticks([int n = 2]) async {
      await Future<void>.delayed(interval * n + const Duration(milliseconds: 8));
      await pumpEventQueue(times: 10);
    }

    List<PipeFrame> frames() => received.whereType<PipeFrame>().toList();

    setUp(() {
      upstream = _FakeUpstream();
      received = [];
      port = ReceivePort();
      port.listen(received.add);
      endpoint = PipeWorkerEndpoint(
        stateMan: upstream,
        toMain: port.sendPort,
        drainInterval: interval,
        logger: Logger(level: Level.off),
      );
    });

    tearDown(() {
      endpoint.dispose();
      upstream.dispose();
      port.close();
    });

    test('NEGATIVE: an unstamped (Modbus-shaped) sample crosses flagged',
        () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(7));
      await ticks(2);

      final frame = frames().firstWhere((f) => f.values.containsKey('k'));
      expect(frame.substitutedStamps, contains('k'));
      // The instant is still there — staleness and the S3 readback guard both
      // read it, and blanking it would be a different loss.
      expect(frame.values['k']!.sourceTime, isNotNull);
    });

    test('CONTROL: a server-stamped sample crosses unflagged', () async {
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(7, stamped: _plantClock));
      await ticks(2);

      final frame = frames().firstWhere((f) => f.values.containsKey('k'));
      expect(frame.substitutedStamps, isNot(contains('k')));
      expect(frame.values['k']!.sourceTime, _plantClock);
    });

    test('a resnapshot replays the provenance, not just the value', () async {
      // `_last` is what a resnapshot answers from. A copy that remembers the
      // reading but forgets where its instant came from would put the whole
      // fleet back to claiming plant time on every reconnect.
      endpoint.handleControl(const PipeSubscribe('k'));
      await ticks(1);
      upstream.controllerFor('k').add(_sample(7));
      await ticks(2);
      received.clear();

      endpoint.handleControl(const PipeResnapshot(['k']));
      await ticks(2);

      final frame = frames().firstWhere((f) => f.values.containsKey('k'));
      expect(frame.substitutedStamps, contains('k'));
    });
  });

  // -------------------------------------------------------------------------
  group('main records the provenance beside the store', () {
    late _FakeLink alpha;
    late PipeMainEndpoint endpoint;

    setUp(() {
      alpha = _FakeLink('alpha');
      endpoint = PipeMainEndpoint(logger: Logger(level: Level.off));
      endpoint.addWorker(alpha, const ['a.one', 'a.two']);
    });

    tearDown(() {
      endpoint.dispose();
      alpha.dispose();
    });

    test('NEGATIVE: a flagged key reads backendReceipt', () async {
      alpha.emit(PipeFrame(
        const [],
        {'a.one': _value(7, at: _arrivedAt)},
        const {'a.one'},
      ));
      await _pump();

      expect(endpoint.stampSourceOf('a.one'), AlarmTsSource.backendReceipt);
      // The value itself still landed — the arm is not passing on an empty cache.
      expect(endpoint.read('a.one').value, 7);
    });

    test('CONTROL: an unflagged key reads plant', () async {
      alpha.emit(PipeFrame(
        const [],
        {'a.one': _value(7, at: _plantClock)},
        const <String>{},
      ));
      await _pump();

      expect(endpoint.stampSourceOf('a.one'), AlarmTsSource.plant);
    });

    test('the provenance follows the key when it changes', () async {
      alpha.emit(PipeFrame(
          const [], {'a.one': _value(7, at: _arrivedAt)}, const {'a.one'}));
      await _pump();
      expect(endpoint.stampSourceOf('a.one'), AlarmTsSource.backendReceipt);

      alpha.emit(PipeFrame(
          const [], {'a.one': _value(8, at: _plantClock)}, const <String>{}));
      await _pump();
      expect(endpoint.stampSourceOf('a.one'), AlarmTsSource.plant);
    });

    test('NEGATIVE: a key main has never seen reads backendReceipt', () {
      // Every backend-minted value — PIPE.*, ALARM.*, a seeded health key — is
      // written straight through `applyBatch` and never appears in a frame.
      // Those are backend receipts, and the default must say so rather than
      // inherit a claim nobody made.
      expect(endpoint.stampSourceOf('never.heard.of'),
          AlarmTsSource.backendReceipt);
    });

    test('NEGATIVE: a frame that states nothing is read as substituted',
        () async {
      // The safe direction. A frame built without a provenance set makes no
      // claim, and an unclaimed instant is not a plant instant.
      alpha.emit(PipeFrame(const [], {'a.two': _value(9, at: _plantClock)}));
      await _pump();

      expect(endpoint.stampSourceOf('a.two'), AlarmTsSource.backendReceipt);
    });
  });

  // -------------------------------------------------------------------------
  //
  // The arm this group exists for was MISSING until a sabotage found it. Moving
  // `_recordStampProvenance` to AFTER `store.applyBatch` — defeating the whole
  // ordering argument written at that call site — turned nothing red, because
  // every other arm here either calls `stampSourceOf` directly after the frame
  // has fully landed or runs against the fake, which pairs at push. Neither can
  // see a listener being handed the previous frame's claim.
  group('BackendLiveValues pairs inside the store\'s own notification', () {
    late _FakeLink alpha;
    late PipeMainEndpoint pipe;
    late BackendLiveValues values;

    setUp(() {
      alpha = _FakeLink('alpha');
      pipe = PipeMainEndpoint(logger: Logger(level: Level.off));
      pipe.addWorker(alpha, const ['a.one']);
      values = BackendLiveValues(
        pipe: pipe,
        keyMappings: KeyMappings(nodes: <String, KeyMappingEntry>{
          'a.one': KeyMappingEntry(
            opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'a.one'),
          ),
        }),
        logger: Logger(level: Level.off),
      );
    });

    tearDown(() async {
      await values.dispose();
      pipe.dispose();
      alpha.dispose();
    });

    test('an emission carries THIS frame\'s claim, not the previous one',
        () async {
      final seen = <StampedValue>[];
      final sub = values.subscribeStamped('a.one').listen(seen.add);
      await _pump();

      // Frame 1: a genuine plant stamp.
      alpha.emit(PipeFrame(
          const [], {'a.one': _value(1, at: _plantClock)}, const <String>{}));
      await _pump();

      // Frame 2: the SAME key, now substituted. This is the transition a
      // provenance recorded after the batch would get wrong: the listener would
      // be woken with value 2 while the claim still said frame 1's.
      alpha.emit(PipeFrame(
          const [], {'a.one': _value(2, at: _arrivedAt)}, const {'a.one'}));
      await _pump();

      await sub.cancel();

      // Not vacuous: two distinct readings actually arrived.
      final withValues =
          seen.where((s) => s.value.value != null).toList(growable: false);
      expect(withValues.map((s) => s.value.value), containsAllInOrder([1, 2]));

      final first = withValues.firstWhere((s) => s.value.value == 1);
      final second = withValues.firstWhere((s) => s.value.value == 2);
      expect(first.stampSource, AlarmTsSource.plant);
      expect(second.stampSource, AlarmTsSource.backendReceipt,
          reason: 'the emission carrying value 2 must carry value 2\'s claim');
      // And the two really do differ, so neither expectation is trivially met.
      expect(first.stampSource, isNot(second.stampSource));
    });
  });

  // -------------------------------------------------------------------------
  group('the alarm writer labels from the flag, not from the instant', () {
    Future<void> run({
      required AlarmTsSource provenance,
      required DateTime? sourceTime,
      required void Function(AlarmRuleTransition) onTransition,
    }) async {
      final values = FakeBackendValueSource();
      final clock = CountingClock(_evaluationClock);
      final watcher = AlarmRuleWatcher(
        values: values,
        expression: ExpressionConfig(value: Expression(formula: 'a > 10')),
        ruleIndex: 0,
        clock: clock.call,
        onTransition: onTransition,
        skewWarnAfter: const Duration(days: 4000),
        logger: Logger(level: Level.off),
      );
      await watcher.start();
      values.pushStamped(
        'a',
        relay.DynamicValue(value: 20.0, sourceTime: sourceTime),
        provenance,
      );
      await settle();
      await watcher.dispose();
      await values.dispose();
    }

    test('NEGATIVE: a substituted instant is NOT written as plant', () async {
      final transitions = <AlarmRuleTransition>[];
      await run(
        provenance: AlarmTsSource.backendReceipt,
        // Non-null and perfectly plausible — this is the whole trap. Nothing
        // about the instant says it is a substitute; only the flag does.
        sourceTime: _arrivedAt,
        onTransition: transitions.add,
      );

      expect(transitions, hasLength(1));
      final stamp = transitions.single.stamp;
      expect(stamp.source, AlarmTsSource.backendReceipt);
      expect(stamp.source.wireName, 'backend_receipt');
      expect(stamp.source.wireName, isNot('plant'));
      // And the instant written is the backend's own clock, openly — not the
      // arrival instant that was dressed up as a source time.
      expect(stamp.at, _evaluationClock);
      expect(stamp.at, isNot(_arrivedAt));
    });

    test('CONTROL: a genuine plant instant IS written as plant', () async {
      final transitions = <AlarmRuleTransition>[];
      await run(
        provenance: AlarmTsSource.plant,
        sourceTime: _plantClock,
        onTransition: transitions.add,
      );

      expect(transitions, hasLength(1));
      final stamp = transitions.single.stamp;
      expect(stamp.source, AlarmTsSource.plant);
      expect(stamp.source.wireName, 'plant');
      expect(stamp.at, _plantClock);
      // Unchanged, not clamped to the receipt: CD-3 reports skew, never hides it.
      expect(stamp.at, isNot(_evaluationClock));
    });

    test('NEGATIVE: one substituted operand poisons a mixed rule', () async {
      // The realistic SVN case: a rule binding a PLC tag and a Modbus tag.
      final values = FakeBackendValueSource();
      final clock = CountingClock(_evaluationClock);
      final transitions = <AlarmRuleTransition>[];
      final watcher = AlarmRuleWatcher(
        values: values,
        expression:
            ExpressionConfig(value: Expression(formula: 'a > 10 AND b > 10')),
        ruleIndex: 0,
        clock: clock.call,
        onTransition: transitions.add,
        skewWarnAfter: const Duration(days: 4000),
        logger: Logger(level: Level.off),
      );
      await watcher.start();
      values.pushStamped(
          'a',
          relay.DynamicValue(value: 20.0, sourceTime: _plantClock),
          AlarmTsSource.plant);
      values.pushStamped(
          'b',
          relay.DynamicValue(value: 20.0, sourceTime: _arrivedAt),
          AlarmTsSource.backendReceipt);
      await settle();

      expect(transitions, hasLength(1));
      expect(transitions.single.stamp.source, AlarmTsSource.backendReceipt);
      expect(transitions.single.stamp.at, _evaluationClock);

      await watcher.dispose();
      await values.dispose();
    });
  });
}
