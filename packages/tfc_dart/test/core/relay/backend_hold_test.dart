/// `BackendHold`: the hold-to-run deadman, on the write path's discipline.
///
/// The one control on a plant where the safety property is stated backwards.
/// Everything else in this directory promises that something *happens*; here
/// the promise is that something **stops** — the counter on the tag stops
/// advancing, the PLC notices inside its deadman window (~1 s), and the machine
/// coasts to a halt.
///
/// **There is no timer in this file and none in the source it judges.** Every
/// tick is called by hand. A test that started a tick loop would leak its last
/// failure into the zone after its own case had ended, and the class under test
/// having a clock of its own is precisely the defect the A5 condition is about:
/// a hold nothing has to hold is a machine running unattended.
///
/// **Nothing here pokes a map.** Every engage, tick and release crosses a real
/// `PipeMainEndpoint` to a fake worker link and comes back on the priority lane.
/// The counter is read off the *tag* — `listen(key).value.asInt` — never off a
/// bookkeeping variable, because the tag is what the PLC compares against its
/// deadman window and what the operator sees on the mimic.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_hold.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show runHoldContract;

import '../../support/harnessed_backend_state_man.dart';

// ---------------------------------------------------------------- the fixture
//
// The two keys are spelled exactly as `hold_contract.dart` spells them: the
// deadman is taken on the same motor tag the write cases drive, and the refused
// engage is taken on a sensor. A key outside that vocabulary would be unrouted
// at the pipe, and the cases would then be judging the router.

/// The tag a hold is taken on. The tag IS the deadman counter.
const _holdKey = 'ST101.CN01.MOT01.setpoint';

/// A sensor: the natural key for a device that refuses writes, and so the
/// natural key for an engage that must not take.
const _refusedKey = 'ST301.CN07.SEN01.temp';

/// A second writable, so two live holds can be torn down together.
const _otherKey = 'ST201.CN04.MOT01.setpoint';

List<String> _routedKeys() => <String>[_holdKey, _refusedKey, _otherKey];

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in _routedKeys())
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key),
        ),
    });

Logger _quiet() => Logger(level: Level.off);

relay.DynamicValue _good(Object? value) =>
    relay.DynamicValue(value: value, quality: relay.Quality.good);

/// Port delivery is asynchronous even inside one isolate (12-05).
Future<void> _settle() => pumpEventQueue(times: 10);

/// A window long enough that a write which should not exist would have crossed.
///
/// Deliberately short: this file's absence arms are about the pipe's own
/// delivery, which is measured in microseconds, and the contract's own quiet
/// window is derived from the source's declared freshness deadline instead.
const _quiet2 = Duration(milliseconds: 60);

/// Awaits [future], or fails saying which promise went silent.
///
/// The contract kit does this for its own cases (`check.dart`'s `within`) and
/// this file needs it for the same reason: a hold whose `onReleased` never
/// completes is a real defect, and without a budget it is reported as a runner
/// timeout naming the file instead of as the property an operator lost.
Future<T> _within<T>(Future<T> future, String what,
        {Duration budget = const Duration(seconds: 2)}) =>
    future.timeout(budget,
        onTimeout: () => fail('$what did not happen within '
            '${budget.inMilliseconds} ms'));

/// One write the fake plant has taken but not yet answered.
typedef _Parked = ({int id, String key, relay.DynamicValue value});

/// What the plant will say to the next write, once.
typedef _NextAnswer = ({relay.WriteReason reason, bool unknown});

/// A worker main can talk to, with no isolate behind it.
///
/// **A copy of `backend_writes_test.dart`'s, and the duplication is
/// deliberately visible.** 13-09 consolidates every fixture in this directory
/// into `test/support/`; until it does, a shared helper edited by two tasks of
/// one plan is a merge conflict in the file both legs depend on.
class _FakePlantLink implements PipeWorkerLink {
  _FakePlantLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  final List<PipeWriteRequest> writes = <PipeWriteRequest>[];
  final Map<String, relay.DynamicValue> last = <String, relay.DynamicValue>{};
  final Set<String> readOnly = <String>{};
  final List<_Parked> parked = <_Parked>[];

  bool down = false;
  bool stalled = false;
  _NextAnswer? _failNext;
  bool _hasClamp = false;
  Object? _clamp;

  @override
  SendPort? get controlPort => down ? null : _port.sendPort;

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void kill() {}

  void emit(Object? message) {
    if (_out.isClosed) return;
    _out.add(message);
  }

  void deliverAll(Map<String, relay.DynamicValue> values) {
    last.addAll(values);
    emit(PipeFrame(
        const <Object?>[], Map<String, relay.DynamicValue>.of(values)));
  }

  void deliver(String key, relay.DynamicValue value) =>
      deliverAll(<String, relay.DynamicValue>{key: value});

  void failNext(relay.WriteReason reason, {bool unknown = false}) =>
      _failNext = (reason: reason, unknown: unknown);

  void clampNext(Object? readback) {
    _hasClamp = true;
    _clamp = readback;
  }

  void stall() => stalled = true;

  void release({bool applied = true}) {
    stalled = false;
    final pending = List<_Parked>.of(parked);
    parked.clear();
    for (final write in pending) {
      if (applied) {
        _answer(write.id, write.key, write.value);
      } else {
        emit(PipeFrame(<Object?>[
          PipeWriteOutcome(
              write.id,
              relay.WriteUnknown(
                  '${write.id}',
                  const relay.WriteReason('plc_timeout',
                      message: 'the plant never said'))),
        ], const <String, relay.DynamicValue>{}));
      }
    }
  }

  void die() {
    down = true;
    emit(null);
  }

  void respawn() {
    down = false;
    emit(_port.sendPort);
  }

  /// Every counter value that has crossed the pipe for [key], in order.
  List<Object?> counters(String key) => <Object?>[
        for (final write in writes)
          if (write.key == key) write.value.value,
      ];

  void _onControl(Object? message) {
    switch (message) {
      case PipeResnapshot(keys: final keys):
        emit(PipeFrame(const <Object?>[], <String, relay.DynamicValue>{
          for (final key in keys)
            if (last[key] != null) key: last[key]!,
        }));
      case PipeWriteRequest(id: final id, key: final key, value: final value):
        writes.add(message);
        if (stalled) {
          parked.add((id: id, key: key, value: value));
          return;
        }
        _answer(id, key, value);
      default:
        break;
    }
  }

  void _answer(int id, String key, relay.DynamicValue value) {
    final result = _decide('$id', key, value);
    if (result is relay.WriteApplied) {
      last[key] = _good(result.readback);
    }
    emit(PipeFrame(<Object?>[PipeWriteOutcome(id, result)],
        const <String, relay.DynamicValue>{}));
  }

  relay.WriteResult _decide(String cmd, String key, relay.DynamicValue value) {
    if (readOnly.contains(key)) {
      return relay.WriteRejected(
          cmd,
          const relay.WriteReason('not_writable',
              message: 'this device does not accept writes',
              status: 'Bad_NotWritable'),
          at: DateTime.now().millisecondsSinceEpoch);
    }
    final failure = _failNext;
    _failNext = null;
    if (failure != null) {
      return failure.unknown
          ? relay.WriteUnknown(cmd, failure.reason)
          : relay.WriteRejected(cmd, failure.reason,
              at: DateTime.now().millisecondsSinceEpoch);
    }
    final clamped = _hasClamp;
    final clamp = _clamp;
    _hasClamp = false;
    _clamp = null;
    return relay.WriteApplied(cmd,
        readback: clamped ? clamp : value.value,
        at: DateTime.now().millisecondsSinceEpoch);
  }

  void dispose() {
    _port.close();
    if (!_out.isClosed) _out.close();
  }
}

/// One assembled subject: one worker, one pipe, the live values and the writes.
class _Fixture {
  _Fixture() {
    plant = _FakePlantLink('alpha');
    pipe = PipeMainEndpoint(
      writeDeadline: const Duration(milliseconds: 150),
      logger: _quiet(),
    );
    pipe.addWorker(plant, _routedKeys());
    values = BackendLiveValues(
      pipe: pipe,
      keyMappings: _mappings(),
      logger: _quiet(),
    );
    writes = BackendWrites(
      pipe: pipe,
      values: values,
      // Derived, not spelled: none of the hold keys is an array element or a
      // bit field, and a deadman counter that became one would then be refused
      // at the engage rather than fed blind (`backend_writes.dart`).
      readModifyWriteKeys: readModifyWriteKeysOf(_mappings()),
      logger: _quiet(),
    );
  }

  late final _FakePlantLink plant;
  late final PipeMainEndpoint pipe;
  late final BackendLiveValues values;
  late final BackendWrites writes;

  Future<void> seed(String key, Object? value) async {
    plant.deliver(key, _good(value));
    await _settle();
  }

  /// The number on the tag, which is the only number that stops a machine.
  int tag(String key) => values.listen(key).value.asInt;

  Future<void> tearDown() async {
    await writes.dispose();
    await values.dispose();
    pipe.dispose();
    plant.dispose();
  }
}

void main() {
  // ------------------------------------------------------------- the engage

  group('the engage', () {
    test('is a real write on the same path, and the tag carries the 1',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);

      expect(hold.engagement, isA<relay.WriteApplied>(),
          reason: 'taking a hold is an ordinary write and the operator is '
              'owed the same three-state answer for it as for any other — '
              'this one decides whether a machine is about to move');
      expect(hold.isHeld, isTrue);
      expect(hold.key, _holdKey,
          reason: 'the tag IS the deadman counter and there is exactly one '
              'key; a sibling-tag convention invented in Dart would have to '
              'be matched by hand in every PLC program');
      expect(f.tag(_holdKey), 1);
      expect(f.plant.counters(_holdKey), <Object?>[1]);
    });

    test('is recorded in the outcome log like any other operator action',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      final answers =
          await f.writes.writeStatus(<String>[hold.engagement.cmd]);

      expect(answers.single, isA<relay.WriteApplied>(),
          reason: 'a hold engage that no writeStatus can answer about is the '
              'one write an operator is most likely to re-ask about after a '
              'reconnect — "did the machine ever take my hold?"');
      expect(answers.single.isSafeToResend, isFalse);
    });

    test('a refusal leaves an inert handle, already ended, feeding nothing',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_refusedKey, 0);
      f.plant.readOnly.add(_refusedKey);

      final hold = await f.writes.holdToRun(_refusedKey);

      expect(hold.engagement, isA<relay.WriteRejected>());
      expect(hold.isHeld, isFalse,
          reason: 'the operator is looking at a lit button for a machine that '
              'was never given permission to move');
      expect(
          await _within(hold.onReleased,
              'a refused hold reporting, without being asked, that it already '
              'ended'),
          relay.HoldEnded.refused,
          reason: 'a caller awaits onReleased to know when to put the button '
              'back up; a refused hold whose future never completes leaves it '
              'lit for ever');

      final before = f.plant.writes.length;
      hold.tick();
      hold.tick();
      await _settle();
      await Future<void>.delayed(_quiet2);

      expect(f.plant.writes, hasLength(before),
          reason: 'a tick on a hold the device refused reached the plant. '
              'Nothing engaged it, so a counter advancing there is a UI '
              'feeding a deadman for a hold that does not exist');
      expect(f.tag(_refusedKey), 0);
    });

    test('an engage whose fate is unknown is not a live hold', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);
      f.plant.failNext(const relay.WriteReason('plc_timeout'), unknown: true);

      final hold = await f.writes.holdToRun(_holdKey);

      expect(hold.engagement, isA<relay.WriteUnknown>());
      expect(hold.isHeld, isFalse,
          reason: 'nobody knows whether the plant took the engage, and a hold '
              'you cannot be sure was taken is one you must not feed: the '
              'operator would be holding a button that may be doing nothing, '
              'told that it is doing something');
      expect(
          await _within(
              hold.onReleased, 'an unknown engage reporting that it ended'),
          relay.HoldEnded.refused);
    });

    test('an engage that throws on the way out is an outcome, not an exception',
        () async {
      final registry = BackendHoldRegistry(
        feed: (key, counter) =>
            Future<relay.WriteResult>.error(StateError('the link exploded')),
        logger: _quiet(),
      );

      final hold = await registry.engage(_holdKey);

      expect(hold.engagement, isA<relay.WriteUnknown>(),
          reason: 'holdToRun threw instead of resolving. A throw collapses '
              '"the PLC may have taken this hold" into "this failed", and the '
              'call site has a jog button to decide about either way');
      expect(hold.isHeld, isFalse);
    });
  });

  // ------------------------------------------------------------ the counter

  group('the counter', () {
    test('advances by one per tick, on the tag, and nowhere else', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      for (final expected in const <int>[2, 3, 4]) {
        hold.tick();
        await _settle();
        expect(f.tag(_holdKey), expected,
            reason: 'the counter must pass THROUGH every value on its way up; '
                'a transport that drops ticks leaves the operator holding a '
                'button while the machine refuses to jog');
        expect(hold.counter, expected,
            reason: 'the tag reached $expected and the handle says '
                '${hold.counter}; the number the PLC compares and the number '
                'the panel believes are different, and only one of them stops '
                'the machine');
      }
      expect(f.plant.counters(_holdKey), <Object?>[1, 2, 3, 4]);
    });

    test('sits exactly where it was left when nobody feeds it', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      hold.tick();
      await _settle();
      expect(f.tag(_holdKey), 2,
          reason: 'the anti-vacuity arm: an assertion that nothing happened '
              'passes trivially against an implementation where nothing '
              'works');

      final crossed = f.plant.writes.length;
      await Future<void>.delayed(_quiet2 * 4);

      expect(f.plant.writes, hasLength(crossed),
          reason: 'something other than an operator\'s finger kept this '
              'deadman alive across a whole window. A hold nothing has to '
              'hold is a machine running unattended, and it would pass every '
              'other arm in this file');
      expect(f.tag(_holdKey), 2);
      expect(hold.counter, 2);
    });

    test('wraps to 1 at the DINT ceiling rather than going negative',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      // The only way to reach the wrap without holding a button for 6.8 years.
      final hold =
          await f.writes.holds.engage(_holdKey, startCounter: 2147483647);
      expect(hold.isHeld, isTrue);
      hold.tick();
      await _settle();

      expect(hold.counter, 1);
      expect(f.plant.counters(_holdKey).last, 1,
          reason: 'the counter written to the plant went to '
              '${f.plant.counters(_holdKey).last}. 0 is reserved for '
              '"released", so a wrap through it stops the machine for one '
              'tick, and a signed DINT going negative is a PLC block that '
              'drops an output');
      expect(f.tag(_holdKey), 1);
    });
  });

  // ------------------------------------------------------------ the release

  group('the release', () {
    test('writes 0, ends operatorLetGo, and stops every later tick', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      hold.tick();
      await _settle();

      final result = await hold.release();

      expect(result, isA<relay.WriteApplied>());
      expect(result.cmd, isNotEmpty,
          reason: 'the release came back with no cmd, so the one write an '
              'operator is most likely to ask about afterwards — "did the '
              'stop land?" — cannot be looked up');
      expect(hold.isHeld, isFalse);
      expect(
          await _within(hold.onReleased, 'the hold reporting why it ended'),
          relay.HoldEnded.operatorLetGo);
      await _settle();
      expect(f.tag(_holdKey), 0);

      final crossed = f.plant.writes.length;
      hold.tick();
      hold.tick();
      await _settle();
      await Future<void>.delayed(_quiet2);

      expect(f.plant.writes, hasLength(crossed),
          reason: 'the counter advanced again after the hold was released. '
              'The operator has taken their finger off the button and the '
              'machine is still being told somebody is holding it — the '
              'failure the whole deadman exists to prevent');
      expect(f.tag(_holdKey), 0);
    });

    test('is idempotent: two releases put one zero on the wire', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      await hold.release();
      await _settle();
      final crossed = f.plant.writes.length;
      await hold.release();
      await _settle();

      expect(f.plant.writes, hasLength(crossed),
          reason: 'a disconnect racing an operator\'s finger put two zeros on '
              'the wire');
    });
  });

  // ----------------------------------------------------------- the teardown

  group('the teardown', () {
    test('releases every live hold, writing 0 for each', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);
      await f.seed(_otherKey, 0);

      final first = await f.writes.holdToRun(_holdKey);
      final second = await f.writes.holdToRun(_otherKey);
      expect(first.isHeld, isTrue);
      expect(second.isHeld, isTrue);

      await f.writes.dispose();
      await _settle();

      expect(
          await _within(first.onReleased,
              'the first hold reporting that the teardown ended it'),
          relay.HoldEnded.disposed,
          reason: 'a source that tears itself down and leaves the counter '
              'advancing has left a machine moving with the window that was '
              'watching it already closed');
      expect(
          await _within(second.onReleased,
              'the second hold reporting that the teardown ended it'),
          relay.HoldEnded.disposed,
          reason: 'one of two live holds was released and the other was '
              'forgotten; the registry has to release what it is holding, not '
              'the last thing it heard about');
      expect(first.isHeld, isFalse);
      expect(second.isHeld, isFalse);
      expect(f.plant.counters(_holdKey), <Object?>[1, 0]);
      expect(f.plant.counters(_otherKey), <Object?>[1, 0]);
    });

    test('does not wait for the plant to confirm the zero', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_holdKey, 0);

      final hold = await f.writes.holdToRun(_holdKey);
      // The link that caused the teardown is the link the release would be
      // waiting on. Stalled writes never answer here.
      f.plant.stall();

      await f.writes.dispose().timeout(const Duration(seconds: 2),
          onTimeout: () => fail('dispose waited for a release write to be '
              'confirmed, on exactly the dead link that caused the teardown'));

      expect(hold.isHeld, isFalse);
      expect(
          await _within(hold.onReleased,
              'the hold reporting that the teardown ended it'),
          relay.HoldEnded.disposed);
    });

    test('a tick whose write is lost leaves no unhandled error on the zone',
        () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final registry = BackendHoldRegistry(
          feed: (key, counter) => counter == 1
              ? Future<relay.WriteResult>.value(relay.WriteApplied('engage',
                  readback: 1, at: 1))
              : Future<relay.WriteResult>.error(StateError('the tick blew up')),
          logger: _quiet(),
        );
        final hold = await registry.engage(_holdKey);
        expect(hold.isHeld, isTrue);
        hold.tick();
        await _settle();
      }, (error, stack) => errors.add(error));

      expect(errors, isEmpty,
          reason: 'a fire-and-forget tick left an error on the zone. It fails '
              'whichever unrelated test happens to be running when it lands, '
              'and the real one — the hold that stopped being fed — is never '
              'reported at all');
    });
  });

  // ----------------------------------------------------------- the structure

  group('the shipping source', () {
    test('has no clock of its own — only a tick advances the counter', () {
      final source =
          File('lib/core/relay/backend_hold.dart').readAsLinesSync();
      final offenders = <String>[
        for (final line in source)
          if (!line.trimLeft().startsWith('//') && line.contains('Timer'))
            line.trim(),
      ];

      expect(offenders, isEmpty,
          reason: 'a clock inside the deadman feeds it without an operator. '
              'The caller chooses the cadence — 100 ms against a ~1 s PLC '
              'deadman — precisely so that the thing keeping the machine '
              'alive is a finger and not a scheduler');
    });

    test('every fire-and-forget future carries its own handler', () {
      final source =
          File('lib/core/relay/backend_hold.dart').readAsStringSync();

      expect(source.contains('unawaited' '('), isFalse,
          reason: 'a bare fire-and-forget wrapper attaches NO error handler; '
              'the future it swallows still reaches the zone');
      expect(source.contains('.catchError('), isTrue,
          reason: 'the ticks and the teardown releases are fire-and-forget by '
              'design, so each one has to carry an explicit handler');
    });

    test('tick is nowhere a member of the StateManApi surface', () {
      for (final path in const <String>[
        'lib/core/relay/backend_state_man.dart',
        'lib/core/relay/backend_writes.dart',
        'lib/core/relay/backend_seams.dart',
      ]) {
        final declarations = <String>[
          for (final line in File(path).readAsLinesSync())
            if (!line.trimLeft().startsWith('//') &&
                RegExp(r'\btick\s*\(').hasMatch(line))
              line.trim(),
        ];
        expect(declarations, isEmpty,
            reason: '$path declares a tick. A method on StateManApi is a '
                'thing any connected client may invoke against any key, and a '
                'bare tick(key, n) is a write primitive with no engage in '
                'front of it');
      }
    });
  });

  // ---------------------------------------------------------- the contract leg

  group('the hold contract, against a deadman fed down the real pipe', () {
    // The contract derives its quiet window from the source's own declared
    // freshness deadline — the production ten seconds — so three of its five
    // cases spend that long proving the absence of a tick. Two minutes moves
    // the runner's boundary without loosening one assertion.
    runHoldContract(makeHarnessedBackendStateMan, supportsHoldToRun: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// ------------------------------------------------------------ the harness leg
//
// **13-09 consolidated it.** `_HarnessedHoldBackend` and its three siblings
// are now one file, `test/support/harnessed_backend_state_man.dart`, and the
// five deadman checks above run against it.
