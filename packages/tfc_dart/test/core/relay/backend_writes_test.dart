/// `BackendWrites`: an operator's command, carried down the pipe with its
/// three-state outcome intact.
///
/// **Nothing here pokes a map.** Every write crosses a real `PipeMainEndpoint`
/// to a fake worker link and comes back as a `PipeWriteOutcome` on the priority
/// lane — the same path a real acquisition isolate answers on. An
/// implementation that resolved a write from somewhere other than the pipe
/// would go red here.
///
/// **The clock is injected, the waits are not faked.** The outcome log's TTL
/// and the four pieces of evidence `WriteNotReceived` needs are arithmetic
/// about *when*, so they are aged by moving an injected epoch counter rather
/// than by sleeping. Everything else — the deadline, the worker death, the
/// pending badge — runs on the real event loop.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_dart/core/relay/backend_writes.dart';
import 'package:tfc_dart/core/state_man.dart'
    show KeyMappings, KeyMappingEntry, OpcUANodeConfig;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart'
    show runWriteContract;

import '../../support/harnessed_backend_state_man.dart';

// ---------------------------------------------------------------- the fixture
//
// The three keys are spelled exactly as `write_contract.dart` spells them. A
// key outside that vocabulary would be unrouted at the pipe, and every contract
// case would then be judging the router's refusal instead of this adapter.

/// A motor setpoint on the pre-freezer conveyor line: the ordinary writable.
const _setpointKey = 'ST101.CN01.MOT01.setpoint';

/// A second writable, so a poisoned write to one key can be shown to have left
/// the rest of the source working.
const _otherKey = 'ST201.CN04.MOT01.setpoint';

/// A sensor: the natural read-only key, and the one the contract is told about
/// through `readOnlyKey`.
const _sensorKey = 'ST301.CN07.SEN01.temp';

/// A key no worker owns, so the pipe's own `unrouted` refusal is reachable.
const _unroutedKey = 'ST404.CN01.MOT01.setpoint';

/// One element of a PLC array, mapped with an `array_index`.
///
/// The shape the rig probe measured P4a on (`data.real.1` → `MAIN.rData`
/// element 0). Writing it is a read-modify-write: the whole array is read, one
/// element is replaced and the whole array is written back
/// (`state_man.dart:2033-2039`), and the two crossings are not atomic.
const _elementKey = 'ST101.CN01.MOT01.trim.1';

/// One bit of a command word, mapped with a `bit_mask`.
///
/// The second shape of the same hazard, and it is in this backend too:
/// `modbus_device_client.dart:1241-1264` reads the current register, merges the
/// masked bits and writes the whole word back.
const _maskedKey = 'ST201.CN04.MOT01.cmdword.4';

List<String> _routedKeys() =>
    <String>[_setpointKey, _otherKey, _sensorKey, _elementKey, _maskedKey];

KeyMappings _mappings() => KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in <String>[..._routedKeys(), _unroutedKey])
        key: KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: key),
        ),
      // Spelled after the loop so these two override the plain entries above.
      _elementKey: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MAIN.rData')
          ..arrayIndex = 0,
      ),
      _maskedKey: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'MAIN.wCmd'),
        bitMask: 0x10,
        bitShift: 4,
      ),
    });

Logger _quiet() => Logger(level: Level.off);

relay.DynamicValue _good(Object? value) =>
    relay.DynamicValue(value: value, quality: relay.Quality.good);

/// Port delivery is asynchronous even inside one isolate (12-05).
Future<void> _settle() => pumpEventQueue(times: 10);

/// One write the fake plant has taken but not yet answered.
typedef _Parked = ({int id, String key, relay.DynamicValue value});

/// What the plant will say to the next write, once.
typedef _NextAnswer = ({relay.WriteReason reason, bool unknown});

/// A worker main can talk to, with no isolate behind it — and a plant that has
/// opinions about writes.
///
/// It remembers the last reading per key (so a `PipeResnapshot` can be
/// answered), and it answers a [PipeWriteRequest] on the priority lane the way
/// an acquisition worker does: applied with a readback, refused with a named
/// reason, or lost.
class _FakePlantLink implements PipeWorkerLink {
  _FakePlantLink(this.name) {
    _port.listen(_onControl);
  }

  @override
  final String name;

  final ReceivePort _port = ReceivePort();
  final StreamController<Object?> _out = StreamController<Object?>();

  final List<Object?> received = <Object?>[];
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

  /// The device says no to the next write only.
  void failNext(relay.WriteReason reason, {bool unknown = false}) =>
      _failNext = (reason: reason, unknown: unknown);

  /// The next write is taken, but the device ends up holding [readback].
  void clampNext(Object? readback) {
    _hasClamp = true;
    _clamp = readback;
  }

  /// Writes go upstream and no answer comes back. The in-flight window.
  void stall() => stalled = true;

  /// Ends the stall and settles everything parked by it.
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

  /// The isolate is gone: `null` on the data port, and no control port.
  void die() {
    down = true;
    emit(null);
  }

  void respawn() {
    down = false;
    emit(_port.sendPort);
  }

  void _onControl(Object? message) {
    received.add(message);
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

  relay.WriteResult _decide(
      String cmd, String key, relay.DynamicValue value) {
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
  _Fixture({this.outcomeTtl = const Duration(seconds: 60)}) {
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
      // Derived from the same mappings the fixture registers, exactly as
      // `composeBackendRelay` derives it from the plant's.
      readModifyWriteKeys: readModifyWriteKeysOf(_mappings()),
      outcomeTtl: outcomeTtl,
      now: () => clock,
      logger: _quiet(),
    );
  }

  final Duration outcomeTtl;

  /// Injected epoch milliseconds. Seeded from the real clock so a ULID minted
  /// by the shipping mint is inside the window this log vouches for.
  int clock = DateTime.now().millisecondsSinceEpoch;

  late final _FakePlantLink plant;
  late final PipeMainEndpoint pipe;
  late final BackendLiveValues values;
  late final BackendWrites writes;

  /// Seeds a reading and waits for it to land, so an arm that asserts about a
  /// badge is not racing the seed's own notification.
  Future<void> seed(String key, Object? value) async {
    plant.deliver(key, _good(value));
    await _settle();
  }

  Future<void> tearDown() async {
    await writes.dispose();
    await values.dispose();
    pipe.dispose();
    plant.dispose();
  }
}

/// A `BackendValueSource` that delegates everything and detonates on one
/// member.
///
/// The only way to get a throw onto the write path: the pipe promises not to
/// throw and the store does not either, so the failure has to be injected at
/// the one seam this class calls after an outcome arrives.
class _ExplodingValues implements BackendValueSource {
  _ExplodingValues(this._inner);

  final BackendValueSource _inner;
  bool explodeOnReadback = false;

  @override
  void applyReadback(String key, relay.DynamicValue value) {
    if (explodeOnReadback) {
      throw StateError('the store rejected the readback for "$key"');
    }
    _inner.applyReadback(key, value);
  }

  @override
  Stream<StampedValue> subscribeStamped(String key) =>
      _inner.subscribeStamped(key);

  @override
  void announceLinkLoss(String reason) => _inner.announceLinkLoss(reason);

  @override
  void announceLinkUp() => _inner.announceLinkUp();

  @override
  void clearPending(String key) => _inner.clearPending(key);

  @override
  Future<void> dispose() => _inner.dispose();

  @override
  List<String> get keys => _inner.keys;

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _inner.listen(key);

  @override
  void markPending(String key) => _inner.markPending(key);

  @override
  void markStale(Iterable<String> keys) => _inner.markStale(keys);

  @override
  relay.DynamicValue? read(String key) => _inner.read(key);

  @override
  Future<relay.DynamicValue> readFresh(String key) => _inner.readFresh(key);

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) =>
      _inner.readMany(keys);

  @override
  int get roundTrips => _inner.roundTrips;

  @override
  Duration get staleAfter => _inner.staleAfter;

  @override
  int get statusNotifications => _inner.statusNotifications;

  @override
  Stream<relay.DynamicValue> subscribe(String key) => _inner.subscribe(key);
}

void main() {
  // ------------------------------------------------------------- the id rules

  group('the id', () {
    test(
        'a relay-supplied cmd is passed through unchanged, and is never '
        'counted as one this source minted', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final supplied = relay.newUlid();
      final result = await f.writes.write(_setpointKey, 1450, cmd: supplied);

      expect(result.cmd, supplied,
          reason: 'the client minted "$supplied" and this source answered '
              'about "${result.cmd}". A middle implementation that re-mints '
              'has created a write the client can no longer reconcile: the id '
              'it holds is not the id the outcome log knows about, so its '
              'writeStatus after a reconnect asks about a command this '
              'gateway will say it never received');
      expect(f.writes.mintedCmds, isNot(contains(supplied)),
          reason: 'a passed-through id was recorded as one this source '
              'minted; the mint list is what proves the relay case is a '
              'pass-through and not a coincidence');
    });

    test('a write with no cmd mints its own 26-character ULID', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final first = await f.writes.write(_setpointKey, 1450);
      final second = await f.writes.write(_setpointKey, 1460);

      final ulid = RegExp(r'^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}$');
      expect(first.cmd, matches(ulid));
      expect(second.cmd, matches(ulid));
      expect(first.cmd, isNot(second.cmd),
          reason: 'two operator actions carried one id; they merge into a '
              'single entry in the outcome log and one of the two silently '
              'reports the other\'s outcome');
      expect(f.writes.mintedCmds, containsAllInOrder([first.cmd, second.cmd]));
    });

    test(
        'the pipe\'s own correlation id never reaches the caller — it is a '
        'transport number, not an operator action', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final result = await f.writes.write(_setpointKey, 1450);

      expect(int.tryParse(result.cmd), isNull,
          reason: 'the answer came back carrying "${result.cmd}", which is '
              'the pipe\'s per-worker sequence number. That number is unique '
              'to one isolate and restarts with it, so two writes to two PLCs '
              'would share an id and a respawn would re-issue one that has '
              'already been answered');
    });
  });

  // --------------------------------------------------------- the three states

  group('three states, one attempt', () {
    test('applied stays applied and carries the readback the plant reported',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.clampNext(1500);

      final result = await f.writes.write(_setpointKey, 5000);

      expect(result, isA<relay.WriteApplied>());
      expect((result as relay.WriteApplied).readback, 1500,
          reason: 'the operator typed 5000 and the device holds 1500');
      expect(result.at, greaterThan(0));
      expect(f.values.read(_setpointKey)?.asInt, 1500,
          reason: 'the store holds what was typed rather than what the plant '
              'reported; the mimic would then show a setpoint the machine is '
              'not running at, and show it as confirmed');
      expect(f.values.read(_setpointKey)?.quality, relay.Quality.good);
    });

    test('rejected stays rejected, with the device\'s own greppable kind',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.failNext(
          const relay.WriteReason('interlocked', message: 'guard door open'));

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteRejected>());
      expect((result as relay.WriteRejected).reason.kind, 'interlocked',
          reason: 'the kind is what a support engineer greps six months '
              'later; a generic one invented on the way out loses the only '
              'fact the device gave');
      expect(f.values.read(_setpointKey)?.asInt, 1200,
          reason: 'a refused write moved the stored value; nothing upstream '
              'agreed to anything');
    });

    test('unknown stays unknown — a lost answer is never a refusal', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.failNext(const relay.WriteReason('plc_timeout'), unknown: true);

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteUnknown>());
      expect(result, isNot(isA<relay.WriteRejected>()),
          reason: 'an outcome nobody knows was reported as a refusal, and '
              '"rejected" is the sentence that sends an operator to press the '
              'button a second time');
      expect((result as relay.WriteUnknown).reason.kind, isNotEmpty);
    });

    test(
        'a write in flight when the worker dies is unknown, and nothing is '
        'sent again', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.stall();

      final pending = f.writes.write(_setpointKey, 1450);
      await _settle();
      f.plant.die();
      final result = await pending;

      expect(result, isA<relay.WriteUnknown>(),
          reason: 'the isolate exited with the write in flight; the PLC may '
              'have applied it and unknown is the only true answer');
      expect(f.writes.upstreamAttempts(result.cmd), 1,
          reason: 'a write whose outcome nobody knows was attempted '
              '${f.writes.upstreamAttempts(result.cmd)} times. Unknown is not '
              'proof that nothing happened, so this is exactly the case where '
              'a helpful wrapper actuates the machine a second time');
      expect(f.plant.writes, hasLength(1),
          reason: 'the observable and the pipe disagree about how many times '
              'this command crossed; the count that matters is the one on the '
              'wire');
    });

    test(
        'the deadline resolves unknown, and the observable agrees with the '
        'wire about how many requests crossed', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.stall();

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteUnknown>());
      expect((result as relay.WriteUnknown).reason.kind, 'pipe_timeout');
      expect(f.writes.upstreamAttempts(result.cmd), 1);
      expect(
          f.plant.writes.where((w) => w.key == _setpointKey).length, 1,
          reason: 'the pipe timed out and something re-sent; a re-send is an '
              'operator decision, never a machine\'s');
    });

    test('a key no worker owns is a refusal, re-stamped with the operator\'s id',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final result = await f.writes.write(_unroutedKey, 1);

      expect(result, isA<relay.WriteRejected>(),
          reason: 'nothing could have moved, so this is the one write outcome '
              'that is definitively safe: a refusal, not an unknown');
      expect((result as relay.WriteRejected).reason.kind, 'unrouted');
      expect(result.cmd, isNot('0'),
          reason: 'the pipe\'s placeholder id reached the caller');
      expect(f.plant.writes, isEmpty);
    });
  });

  // --------------------------------------------------------------- the guards

  group('compare-and-set', () {
    test('a mismatch is a refusal naming both values, and NOTHING is sent',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final result = await f.writes.write(_setpointKey, 1450, expect: 999);

      expect(result, isA<relay.WriteRejected>());
      final reason = (result as relay.WriteRejected).reason;
      expect(reason.kind, 'compare_failed');
      expect(reason.message, contains('999'),
          reason: 'the refusal must name the value the caller guarded on');
      expect(reason.message, contains('1200'),
          reason: 'and the value the key actually holds — a compare-and-set '
              'refusal with neither number in it tells the page nothing it '
              'can put in front of an operator');
      // The barrier is the assertion. Port delivery is a separate event-loop
      // task, not a microtask, so a request that HAD crossed would still be in
      // flight at the end of the awaited call and an immediate read of the
      // plant's log would report the absence it was looking for. Sabotage (d)
      // is what found this: the mutation that sends before comparing left this
      // arm green until the queue was pumped.
      await _settle();
      expect(f.plant.writes, isEmpty,
          reason: 'a guarded write whose guard failed still crossed the pipe. '
              'Compare-and-set exists so that a concurrent change is NOT '
              'overwritten, and a write that is sent and then judged has '
              'already overwritten it');
    });

    test('a match sends the write', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final result = await f.writes.write(_setpointKey, 1450, expect: 1200);

      expect(result, isA<relay.WriteApplied>());
      expect(f.plant.writes, hasLength(1));
    });
  });

  // ------------------------------------------------ the read-modify-write guard
  //
  // P4a, measured on the rig against this very process
  // (13-RIG-PROBE-EVIDENCE.md): a blind array-element write came back
  // `applied` here where the standalone gateway refused it. It was proven NOT
  // to be F7's whole-node clobber — a sentinel stayed element-scoped and the
  // other nine elements kept their own ramp — so nothing was being destroyed.
  // What was gone is the GUARD: an element write with no `expect` is a
  // read-modify-write racing every other writer on that array, and the
  // gateway's OPC UA adapter refused it on purpose
  // (`opcua_upstream_link.dart:506-513`).

  group('the read-modify-write guard', () {
    test('a blind array-element write is refused by name, and NOTHING is sent',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_elementKey, 8218.5);

      final result = await f.writes.write(_elementKey, 1234.5);

      expect(result, isA<relay.WriteRejected>(),
          reason: 'this is P4a exactly: the rig answered '
              '{"outcome":"applied"} to a blind element write. A refusal is a '
              'page-editor bug report; a silent read-modify-write is another '
              'operator\'s setpoint gone');
      final reason = (result as relay.WriteRejected).reason;
      expect(reason.kind, 'array_element_requires_expect',
          reason: 'the same kind the gateway refuses with, so a panel that '
              'already handles the gateway\'s refusal handles this one');
      expect(reason.message, contains('expect'),
          reason: 'the refusal must name the escape, or the operator is told '
              'no with no way forward');
      // The barrier is the assertion — port delivery is an event-loop task,
      // not a microtask, so an immediate read of the plant's log would report
      // an absence it had not waited for (sabotage (d), 13-08).
      await _settle();
      expect(f.plant.writes, isEmpty,
          reason: 'the guarded shape crossed the pipe anyway; a write that is '
              'sent and then judged has already overwritten whatever it raced');
    });

    test('the documented escape: the same write WITH a matching expect is sent',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_elementKey, 8218.5);

      final result = await f.writes.write(_elementKey, 1234.5, expect: 8218.5);

      expect(result, isA<relay.WriteApplied>(),
          reason: 'a guard that cannot be satisfied is an element nobody can '
              'ever write, which is a different defect from the one being '
              'fixed. Under a comparison the read-modify-write may run');
      await _settle();
      expect(f.plant.writes, hasLength(1));
    });

    test('a bit-masked write is the same hazard and gets the same refusal',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_maskedKey, 1);

      final result = await f.writes.write(_maskedKey, 0);

      expect(result, isA<relay.WriteRejected>(),
          reason: 'two operators toggling two bits of one status word lose '
              'one of the two edits, silently, and the loser is whoever read '
              'first (`modbus_upstream_link.dart:766-788`)');
      expect((result as relay.WriteRejected).reason.kind,
          'array_element_requires_expect');
      await _settle();
      expect(f.plant.writes, isEmpty);
    });

    test('a whole-node key is untouched by the guard', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteApplied>(),
          reason: 'the ordinary blind write is most of the plant. A guard '
              'that refused those would be a gateway nobody can actuate '
              'through, which is a worse defect than the one it fixes');
      expect(f.plant.writes, hasLength(1));
    });

    test('the refusal is recorded, so writeStatus answers rejected rather '
        'than not_received', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_elementKey, 8218.5);
      const cmd = '01M1TVWC8V88KR8NDNX6XRZXMN';

      final refused = await f.writes.write(_elementKey, 1234.5, cmd: cmd);
      final requeried = await f.writes.writeStatus(<String>[cmd]);

      expect(refused, isA<relay.WriteRejected>());
      expect(requeried.single, isA<relay.WriteRejected>(),
          reason: 'a refusal this source issued and then forgot would come '
              'back not_received, which is the one verdict that licenses a '
              'second press');
      expect((requeried.single as relay.WriteRejected).at,
          (refused as relay.WriteRejected).at,
          reason: 'the re-query must answer with the outcome that was issued, '
              'instant included — P5\'s property on the rig');
    });

    test('the set is derived from the mappings: array_index and bit_mask, '
        'and nothing else', () {
      expect(readModifyWriteKeysOf(_mappings()),
          <String>{_elementKey, _maskedKey},
          reason: 'a derivation that missed a shape would leave that shape '
              'unguarded on the plant, and one that over-matched would refuse '
              'ordinary writes. Both failures are silent until an operator '
              'meets them');
    });
  });

  group('the pending badge', () {
    test('goes on before the send and comes off when the outcome settles',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      final node = f.values.listen(_setpointKey);
      f.plant.stall();

      final pending = f.writes.write(_setpointKey, 1450);

      expect(node.value.quality, relay.Quality.goodWritePending,
          reason: 'over a slow link the pending badge is the only thing '
              'telling an operator their press was registered, and an '
              'operator who sees nothing presses again');
      expect(node.value.asInt, 1200,
          reason: 'the typed value was shown while the write was still in '
              'flight; that is a confirmation nothing upstream has given');

      f.plant.release();
      await pending;

      expect(node.value.quality, relay.Quality.good);
      expect(node.value.asInt, 1450);
    });

    test('a throw on the way out still takes the badge off', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      final exploding = _ExplodingValues(f.values)..explodeOnReadback = true;
      final writes = BackendWrites(
        pipe: f.pipe,
        values: exploding,
        readModifyWriteKeys: readModifyWriteKeysOf(_mappings()),
        now: () => f.clock,
        logger: _quiet(),
      );
      addTearDown(writes.dispose);

      final result = await writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteUnknown>(),
          reason: 'something threw on the way out and the call threw with it. '
              'A write that throws has collapsed "the PLC may have applied '
              'this" into "this failed"');
      expect(f.values.read(_setpointKey)?.quality,
          isNot(relay.Quality.goodWritePending),
          reason: 'the value is still badged pending after the write '
              'resolved. A badge that never clears is a permanent amber box '
              'the operator learns to ignore, on the one key they most need '
              'to trust');
    });

    test(
        'an applied write that reported no readback is uncertain, never '
        'confirmed', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.clampNext(null);

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteApplied>());
      expect(f.values.read(_setpointKey)?.quality,
          relay.Quality.uncertainLastKnown,
          reason: 'the device took the write and said nothing about what it '
              'now holds. Readback is the only confirmation there is, so the '
              'number on the screen is the last one anybody measured and it '
              'must not be badged as agreed');
      expect(f.values.read(_setpointKey)?.asInt, 1200,
          reason: 'the typed value was stored on no evidence at all');
    });
  });

  group('poison values', () {
    test('a non-finite write is refused before the pipe, never nulled into it',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      await f.seed(_otherKey, 3);

      for (final poison in const <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => f.writes.write(_setpointKey, poison), throwsArgumentError,
            reason: 'a write of $poison was not refused. Sanitising it puts a '
                'write of null on a live tag: the device is actuated with a '
                'value nobody chose and the operator is told it applied');
      }

      expect(f.plant.writes, isEmpty,
          reason: 'a refused write reached the pipe. The refusal is a shape '
              'refusal and it is only worth anything raised BEFORE the plant '
              'is touched');
      expect(f.writes.mintedCmds, isEmpty,
          reason: 'the router minted a cmd for a write it refused; an id that '
              'exists is an action a writeStatus can no longer answer '
              'not_received about, which is the one verdict that makes a '
              're-send safe');
      expect(f.values.read(_setpointKey)?.asInt, 1200,
          reason: 'the reading moved on a write that never happened');
      expect(f.values.read(_setpointKey)?.quality,
          isNot(relay.Quality.badNonFinite),
          reason: 'the tag was badged for a fault the plant does not have — '
              'one caller divided by zero');
      expect(f.values.read(_setpointKey)?.quality,
          isNot(relay.Quality.goodWritePending),
          reason: 'a pending badge outlived a write that was never sent; a '
              'value stuck pending is a permanent amber box the operator '
              'learns to ignore');

      final after = await f.writes.write(_otherKey, 5);
      expect(after, isA<relay.WriteApplied>(),
          reason: 'one divide-by-zero in a widget took the whole write path '
              'down');
    });
  });

  group('read-only keys', () {
    test('are refused, never thrown', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_sensorKey, 4);
      f.plant.readOnly.add(_sensorKey);

      final result = await f.writes.write(_sensorKey, 9);

      expect(result, isA<relay.WriteRejected>(),
          reason: 'an UnsupportedError here reaches the page as "something '
              'went wrong", where "this device does not take writes" is the '
              'sentence that stops the operator trying again');
      expect((result as relay.WriteRejected).reason.kind, isNotEmpty);
    });
  });

  // ------------------------------------------------------------ the outcome log

  group('the outcome log', () {
    test('replays a recorded outcome identically — same outcome, same at',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final done =
          await f.writes.write(_setpointKey, 1450) as relay.WriteApplied;
      final answers = await f.writes.writeStatus(<String>[done.cmd]);

      expect(answers, hasLength(1));
      expect(answers.single, isA<relay.WriteApplied>());
      expect((answers.single as relay.WriteApplied).at, done.at,
          reason: 're-querying an outcome produced a different timestamp, so '
              'the answer is being re-derived rather than replayed and the '
              'audit trail has two instants for one event');
      expect(answers.single.readbackOrNull, done.readback);
      expect(answers.single.isSafeToResend, isFalse);
    });

    test('a re-sent frame under a recorded cmd sends nothing a second time',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final cmd = relay.newUlid();
      final first = await f.writes.write(_setpointKey, 1450, cmd: cmd);
      final again = await f.writes.write(_setpointKey, 1450, cmd: cmd);

      expect(f.plant.writes, hasLength(1),
          reason: 'the same operator action crossed the pipe twice; one press '
              'of a jog button is one movement of the machine');
      expect(again.cmd, first.cmd);
      expect(f.writes.upstreamAttempts(cmd), 1);
    });

    test('answers are positional, one per input, in input order', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final first = await f.writes.write(_setpointKey, 1450);
      final second = await f.writes.write(_setpointKey, 1460);
      // Dated on the fixture's injected clock: this source's log started at
      // that instant, and an id from a millisecond it has not reached yet is
      // one it cannot vouch for.
      final never = relay.newUlid(nowMs: f.clock);

      final answers = await f.writes
          .writeStatus(<String>[second.cmd, never, first.cmd]);

      expect(answers, hasLength(3));
      expect(answers[0].cmd, second.cmd);
      expect(answers[1].cmd, never);
      expect(answers[2].cmd, first.cmd);
      expect(answers[1], isA<relay.WriteNotReceived>(),
          reason: 'the answers are positional; a map keyed by cmd, or a list '
              'in any other order, shifts every later verdict onto the wrong '
              'command — and one of those verdicts is the not_received that '
              'invites a second actuation');
    });

    test('a write still in flight answers unknown, never not-received',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      f.plant.stall();

      final cmd = relay.newUlid();
      final pending = f.writes.write(_setpointKey, 1450, cmd: cmd);
      final answers = await f.writes.writeStatus(<String>[cmd]);

      expect(answers.single, isA<relay.WriteUnknown>(),
          reason: 'a writeStatus that crossed a write on its way to a machine '
              'answered that the command never arrived, which is a licence to '
              'send it again while the first one is still upstream');
      expect(answers.single.isSafeToResend, isFalse);

      f.plant.release();
      await pending;
    });

    test('is bounded: an outcome past its TTL is forgotten', () async {
      final f = _Fixture(outcomeTtl: const Duration(seconds: 30));
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);

      final done = await f.writes.write(_setpointKey, 1450);
      expect(f.writes.recordedOutcomes, greaterThan(0));

      f.clock += const Duration(seconds: 31).inMilliseconds;
      final answers = await f.writes.writeStatus(<String>[done.cmd]);

      expect(f.writes.recordedOutcomes, 0,
          reason: 'the log grows one entry per write and is never pruned; on '
              'a backend that runs for months that is the whole write history '
              'of the plant, in memory');
      expect(answers.single, isA<relay.WriteUnknown>(),
          reason: 'forgetting is not evidence that nothing happened');
    });
  });

  // ---------------------------------------------- the four pieces of evidence

  group('not-received needs four pieces of evidence', () {
    test('all four hold: the one re-send-safe answer', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final never = relay.newUlid(nowMs: f.clock);
      final answers = await f.writes.writeStatus(<String>[never]);

      expect(answers.single, isA<relay.WriteNotReceived>());
      expect(answers.single.isSafeToResend, isTrue,
          reason: 'this source was up, was recording, and never saw the '
              'command; refusing to say so leaves the operator with no safe '
              'move at all');
    });

    test('1: an id nothing can date answers unknown', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final answers = await f.writes.writeStatus(<String>['not-a-ulid']);

      expect(answers.single, isA<relay.WriteUnknown>());
      expect((answers.single as relay.WriteUnknown).reason.kind,
          'unrecognized_cmd');
      expect(answers.single.isSafeToResend, isFalse,
          reason: 'an id this source could never have issued an outcome for '
              'was reported as definitely never received. Nothing about it '
              'can be ruled out');
    });

    test('2: an id minted before this source started answers unknown',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final older = relay.newUlid(nowMs: f.clock - 5000);
      final answers = await f.writes.writeStatus(<String>[older]);

      expect(answers.single, isA<relay.WriteUnknown>());
      expect((answers.single as relay.WriteUnknown).reason.kind,
          'outcome_unwitnessed');
      expect(answers.single.isSafeToResend, isFalse,
          reason: 'the backend restarted while the write was in the air, and '
              'answered that it never happened. Absence from a log that did '
              'not exist yet is not evidence of anything');
    });

    test('3: an id minted in the future answers unknown', () async {
      final f = _Fixture();
      addTearDown(f.tearDown);

      final ahead = relay.newUlid(nowMs: f.clock + 300000);
      final answers = await f.writes.writeStatus(<String>[ahead]);

      expect(answers.single, isA<relay.WriteUnknown>());
      expect((answers.single as relay.WriteUnknown).reason.kind,
          'outcome_unwitnessed');
      expect(answers.single.isSafeToResend, isFalse,
          reason: 'a panel whose clock runs ahead bought itself a '
              'not_received window of ttl + skew, and one ahead by more than '
              'the elapsed time would pass the check for ever');
    });

    test('4: an id older than the window answers unknown', () async {
      final f = _Fixture(outcomeTtl: const Duration(seconds: 30));
      addTearDown(f.tearDown);

      final old = relay.newUlid(nowMs: f.clock);
      f.clock += const Duration(seconds: 31).inMilliseconds;
      final answers = await f.writes.writeStatus(<String>[old]);

      expect(answers.single, isA<relay.WriteUnknown>());
      expect((answers.single as relay.WriteUnknown).reason.kind,
          'outcome_expired');
      expect(answers.single.isSafeToResend, isFalse,
          reason: 'outside the window this source cannot tell "never '
              'arrived" from "arrived, and forgotten"');
    });
  });

  // ------------------------------------------------------------ the structure

  group('the shipping source', () {
    test('contains no re-send on any path', () {
      final source =
          File('lib/core/relay/backend_writes.dart').readAsLinesSync();
      final offenders = <String>[
        for (final line in source)
          if (!line.trimLeft().startsWith('//') &&
              RegExp('retry|resend|re-send', caseSensitive: false)
                  .hasMatch(line))
            line.trim(),
      ];

      expect(offenders, isEmpty,
          reason: 'a re-send lives on a code line of the write router. It is '
              'invisible from the API surface — same call, same result type, '
              'a few hundred milliseconds later — and on a plant it is a '
              'second actuation of machinery an operator commanded once');
    });

    test('is disposed loudly: a write after teardown is refused, not dropped',
        () async {
      final f = _Fixture();
      addTearDown(f.tearDown);
      await f.seed(_setpointKey, 1200);
      await f.writes.dispose();

      final result = await f.writes.write(_setpointKey, 1450);

      expect(result, isA<relay.WriteRejected>(),
          reason: 'a command accepted by a torn-down router is accepted and '
              'dropped, and silence and success look the same at the panel');
      expect(f.plant.writes, isEmpty);
    });
  });

  // ---------------------------------------------------------- the contract leg

  group('the write contract, against writes that cross the real pipe', () {
    runWriteContract(
      makeHarnessedBackendStateMan,
      // The shared harness's key, not this file's `_sensorKey`: every leg of
      // this suite names the same read-only key, and a leg that judged a
      // different set of cases would make a parity sweep across legs
      // meaningless (`harnessed_backend_state_man.dart`).
      readOnlyKey: contractReadOnlyKey,
      upstreamWriteAttempts: (api, cmd) =>
          (api as HarnessedBackendStateMan).writes.upstreamAttempts(cmd),
      stallWrites: (api) => (api as HarnessedBackendStateMan).plant.stall(),
      // The isolate really dies here, and does not merely announce: a command
      // that was out when the channel went is what this case is about, and an
      // announcement does not settle a parked write.
      dropLinkWithWritesInFlight: (api) =>
          (api as HarnessedBackendStateMan).killUpstreamWorker(),
    );
  });
}

/// The readback of an applied result, or null for every other arm.
///
/// A tiny extension rather than a cast at each call site: the arms that ask
/// only care whether the replay carried the same number back.
extension on relay.WriteResult {
  Object? get readbackOrNull =>
      this is relay.WriteApplied ? (this as relay.WriteApplied).readback : null;
}

// ------------------------------------------------------------ the harness leg
//
// **13-09 consolidated it.** `_HarnessedWriteBackend` and its three siblings
// are now one file, `test/support/harnessed_backend_state_man.dart`, and the
// eleven write checks above run against it. The shared subject also composes
// the freshness sweep and the mapping-backed browse; neither is reachable from
// a write case, and the write path's `markPending`/`applyReadback` land on the
// sweep rather than on the raw store so a pending badge is visible to the
// listener the case attached.
