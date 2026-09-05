/// Main's end of the acquisition pipe.
///
/// One of these lives in `bin/main.dart` and holds every acquisition worker.
/// It is the only thing on main that reaches across an isolate boundary, and it
/// is built so that nothing on this side can ever be parked by what is on the
/// other:
///
///  1. **A cache, not a stream per key.** Every drained [PipeFrame] becomes one
///     `ValueStore.applyBatch` call, so a widget reads a `ValueListenable` that
///     notifies only when its own key actually moved. A key no frame has
///     carried yet reads `notYetKnown` — uncertain, never a plausible zero.
///  2. **A write router over a disjoint map.** `KeyMappingEntry.server` is
///     `opcuaNode ?? m2400Node ?? modbusNode`, so the three `filterByServer`
///     partitions `bin/main.dart` already computes cannot overlap: a key
///     belongs to exactly one worker, and a key that belongs to none is
///     refused here without a single message crossing a port.
///  3. **A refcount, not an idle timer.** The worker pipes only what main asked
///     for, so main has to ask — once per key, no matter how many panels want
///     it. The subscribe/unsubscribe control message crosses on the 0→1 and
///     1→0 transitions and nowhere else (`fanin.dart`'s release-at-zero, whose
///     comment explains at length why a ten-minute idle timer is the wrong
///     shape).
///  4. **Death is an event.** The `null` the VM puts on the worker's data port
///     is a fact, not an absence: every key that worker was piping is marked
///     bad on the spot and every write waiting on it resolves unknown
///     immediately. No freshness sweep, no decay, no silence.
///  5. **Shutdown kills.** [PipeMainEndpoint.shutdown] is
///     `Isolate.kill(priority: immediate)` per worker and nothing else. Nothing
///     on any shutdown path awaits `disconnect()`, `delete()` or
///     `StateMan.close()` — that await is the measured multi-second stall this
///     phase exists to remove, and `test/core/pipe_shutdown_structure_test.dart`
///     scans this file and `bin/` to keep it out.
///
/// **Nothing here retries anything, ever.** A write is sent once; if it expires
/// or its worker dies, the caller is told `unknown` and whether to press the
/// button again is the operator's decision.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/pipe_worker_endpoint.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// How long main waits for a worker to answer a write before it answers
/// without one.
///
/// Five seconds, matching `LocalStateMan.writeDeadline`
/// (`tfc_relay_local/lib/src/local_state_man.dart:98`) — the only write
/// deadline this repository already had, and the sibling this boundary should
/// not disagree with. It is deliberately OUTSIDE the worker's own
/// [kPipeWorkerWriteDeadline] (4 s): when an upstream stops answering it is the
/// worker's verdict that should reach the operator (`plc_timeout` — the request
/// reached the link) rather than main's fallback (`pipe_timeout` — the worker
/// said nothing at all). Both are [relay.WriteUnknown]; neither is ever
/// re-sent.
const kPipeWriteDeadline = Duration(seconds: 5);

/// One acquisition worker, as much of it as the main endpoint touches.
///
/// [DataAcquisitionWorker] is the production implementation, reached through
/// [AcquisitionWorkerLink]; the test's fake is the other. Four members is the
/// whole abstraction budget — CONTEXT's "don't make too much abstraction".
abstract interface class PipeWorkerLink {
  /// The supervisor's name for this worker. Log-facing only.
  String get name;

  /// The CURRENT generation's control port, or null between a death and its
  /// replacement. Read on every send: a handle outlives its isolate, so a port
  /// cached at registration time would address a corpse after the first
  /// respawn.
  SendPort? get controlPort;

  /// Everything the worker sent, plus `null` each time one dies, in the
  /// ReceivePort's own order. Single-subscription: there is exactly one main
  /// endpoint per worker.
  Stream<Object?> get messages;

  /// `Isolate.kill(priority: immediate)`. See [PipeMainEndpoint.shutdown].
  void kill();
}

/// A supervised [DataAcquisitionWorker], as a [PipeWorkerLink].
class AcquisitionWorkerLink implements PipeWorkerLink {
  AcquisitionWorkerLink(this.worker);

  final DataAcquisitionWorker worker;

  @override
  String get name => worker.name;

  @override
  SendPort? get controlPort => worker.controlPort;

  @override
  Stream<Object?> get messages => worker.messages;

  @override
  void kill() => worker.kill();
}

/// One write main is still waiting on.
class _PendingWrite {
  _PendingWrite(this.key, this.cmd, this.completer, this.timer);

  final String key;
  final String cmd;
  final Completer<relay.WriteResult> completer;
  final Timer timer;

  /// Settles the caller's future exactly once and stops the deadline.
  ///
  /// Idempotent on purpose: the deadline, the echo and the worker's death are
  /// three independent races for the same answer, and the first one to arrive
  /// is the one the operator is told.
  void resolve(relay.WriteResult result) {
    timer.cancel();
    if (!completer.isCompleted) completer.complete(result);
  }
}

/// Main's end of the acquisition pipe. See the library doc.
class PipeMainEndpoint {
  PipeMainEndpoint({
    this.writeDeadline = kPipeWriteDeadline,
    Logger? logger,
  }) : _logger = logger ?? Logger();

  final Logger _logger;

  /// How long a write may go unanswered. See [kPipeWriteDeadline].
  final Duration writeDeadline;

  /// The per-key value cache every consumer on main reads.
  final relay.ValueStore store = relay.ValueStore();

  final List<PipeWorkerLink> _workers = <PipeWorkerLink>[];
  final List<StreamSubscription<Object?>> _listens =
      <StreamSubscription<Object?>>[];

  /// The router. Disjoint by construction — see the library doc.
  final Map<String, int> _keyToWorker = <String, int>{};

  /// The next correlation id per worker. Per-worker and monotonic: the ids
  /// never leave the process, so there is nothing to make globally unique.
  final Map<int, int> _nextWriteId = <int, int>{};

  /// Writes still in flight, per worker, by correlation id.
  final Map<int, Map<int, _PendingWrite>> _pending =
      <int, Map<int, _PendingWrite>>{};

  bool _disposed = false;

  /// Registers [worker] as the owner of [keys] and starts reading it.
  ///
  /// [keys] is a `filterByServer` partition straight out of `bin/main.dart` —
  /// the same three filters that decided which worker got spawned with which
  /// mappings, so the router cannot disagree with the spawn. A key already
  /// owned by an earlier worker is REFUSED rather than re-pointed: two owners
  /// for one key means a write could reach either, and the first registration
  /// is the one the spawn actually used.
  ///
  /// Returns the worker's index, which is also the key of its subscription set
  /// and its pending-write table.
  int addWorker(PipeWorkerLink worker, Iterable<String> keys) {
    final index = _workers.length;
    _workers.add(worker);
    _pending[index] = <int, _PendingWrite>{};
    _nextWriteId[index] = 1;
    for (final key in keys) {
      final owner = _keyToWorker[key];
      if (owner != null) {
        _logger.e('pipe: "$key" is already owned by ${_workers[owner].name}; '
            'refusing to re-point it at ${worker.name}');
        continue;
      }
      _keyToWorker[key] = index;
    }
    _listens.add(worker.messages.listen(
      (message) => _onWorkerMessage(index, message),
      onError: (Object error) =>
          _logger.e('pipe: message stream failed for ${worker.name}: $error'),
    ));
    return index;
  }

  /// How many workers are registered.
  int get workerCount => _workers.length;

  /// Which worker owns [key], or null when none does.
  int? workerOf(String key) => _keyToWorker[key];

  /// The cached value for [key] — [relay.notYetKnown] until one arrives.
  relay.DynamicValue read(String key) => store.node(key).value;

  /// [key]'s node, to hand a widget. Always the same instance for the same key.
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      store.node(key);

  // ------------------------------------------------------------- the inbound

  void _onWorkerMessage(int index, Object? message) {
    if (_disposed) return;
    switch (message) {
      case PipeFrame():
        _applyFrame(index, message);
      case SendPort():
        // A generation announced itself. The FIRST one has nothing to replay;
        // every later one is a respawn and gets the whole snapshot.
        _onWorkerReady(index, message);
      case null:
        _onWorkerDied(index);
      default:
        _logger.w('pipe: unrecognised worker message '
            '(${message.runtimeType}) from ${_workers[index].name} — ignored');
    }
  }

  /// One drained tick, applied.
  ///
  /// Values first, priority lane second, and the order is deliberate. Within a
  /// single tick there is no timeline to consult — the buffer holds a latest
  /// reading and an append-only list, not a merged log — so one of the two has
  /// to win, and a fault is the conservative winner. A link that faulted and
  /// recovered inside 50 ms shows the fault until the next sample clears it,
  /// which is a transient badge; the other order shows a fresh-looking number
  /// over a fault that was never displayed at all, which is the silent-fault
  /// mode this project exists to remove.
  void _applyFrame(int index, PipeFrame frame) {
    if (frame.values.isNotEmpty) {
      // seq omitted: the pipe is process-internal and has no gap chain to
      // reason about — a lost frame is a dead isolate, which arrives as its
      // own event.
      store.applyBatch(frame.values);
    }
    for (final event in frame.priority) {
      _applyEvent(index, event);
    }
  }

  void _applyEvent(int index, Object? event) {
    switch (event) {
      case PipeKeyError(key: final key, quality: final quality):
        // No payload under a bad badge: `translateOpcUaSample`'s rule, for the
        // same reason — a number nobody measured, greyed out, is still a
        // number nobody measured.
        _markBad(<String>[key], quality);
      case PipeKeyRetired(key: final key):
        // Affirmatively gone, which is a different fact from "not yet known"
        // and from "the link is sick": errorConfig says waiting will not help.
        _markBad(<String>[key], relay.Quality.errorConfig);
      case PipeWriteOutcome(id: final id, result: final result):
        final pending = _pending[index]?.remove(id);
        if (pending == null) {
          // The deadline or a death already answered this one. Not an error:
          // the answer simply lost the race, and re-answering would mean
          // completing a future the caller already acted on.
          _logger.i('pipe: late write outcome $id from '
              '${_workers[index].name} — already resolved');
          return;
        }
        pending.resolve(result);
      default:
        _logger.w('pipe: unrecognised priority event '
            '(${event.runtimeType}) from ${_workers[index].name} — ignored');
    }
  }

  /// Writes [quality] with no payload for every key in [keys], immediately.
  ///
  /// A direct [relay.ValueStore.applyBatch]: there is no tick on this side and
  /// no buffer to sit in, so "un-conflated" here means the operator's screen
  /// changes on this call and not one drain later.
  void _markBad(Iterable<String> keys, relay.Quality quality) {
    if (keys.isEmpty) return;
    store.applyBatch(<String, relay.DynamicValue>{
      for (final key in keys)
        key: relay.DynamicValue(value: null, quality: quality),
    });
  }

  void _onWorkerReady(int index, SendPort control) {
    // Task 3 replays the subscription snapshot here.
  }

  void _onWorkerDied(int index) {
    // Task 3 owns death-as-event.
  }

  // --------------------------------------------------------------- the write

  /// Writes [value] to [key] and answers applied, rejected or unknown.
  ///
  /// The future ALWAYS settles. If the owning worker never answers,
  /// [writeDeadline] resolves it [relay.WriteUnknown] with kind `pipe_timeout`;
  /// if the worker dies first, its death resolves it sooner. Nothing on this
  /// path re-sends, on any outcome.
  Future<relay.WriteResult> write(String key, relay.DynamicValue value) {
    final index = _keyToWorker[key];
    if (index == null) {
      // Definitively no effect: no worker was spawned for this key, so nothing
      // was ever going to move. That is a refusal, not an unknown — telling an
      // operator "unknown" about a write that provably never left the process
      // would send them to look at a machine that never heard of it.
      _logger.w('pipe: refusing a write to "$key" — no worker owns it');
      return Future<relay.WriteResult>.value(relay.WriteRejected(
        '0',
        relay.WriteReason('unrouted',
            message: 'no acquisition worker owns "$key"'),
      ));
    }

    final id = _nextWriteId[index]!;
    _nextWriteId[index] = id + 1;
    final cmd = id.toString();

    final port = _workers[index].controlPort;
    if (port == null) {
      // Between generations. Nothing was sent — but "nothing was sent" and
      // "sent, and the answer died with the isolate" are not distinguishable
      // from a caller's seat once a respawn is in the air, so this side does
      // not claim the stronger fact.
      _logger.w('pipe: "$key" is owned by ${_workers[index].name}, which has '
          'no live control port');
      return Future<relay.WriteResult>.value(relay.WriteUnknown(
        cmd,
        relay.WriteReason('worker_down',
            message: '${_workers[index].name} is not currently running'),
      ));
    }

    final completer = Completer<relay.WriteResult>();
    final timer = Timer(writeDeadline, () {
      final pending = _pending[index]?.remove(id);
      if (pending == null) return;
      _logger.w('pipe: write $id to "$key" went unanswered for '
          '${writeDeadline.inSeconds}s');
      pending.resolve(relay.WriteUnknown(
        cmd,
        relay.WriteReason('pipe_timeout',
            message: '${_workers[index].name} did not answer within '
                '${writeDeadline.inMilliseconds}ms'),
      ));
    });
    _pending[index]![id] = _PendingWrite(key, cmd, completer, timer);

    // Sent exactly once. There is no loop here and no re-send anywhere else.
    port.send(PipeWriteRequest(id, key, _withTypeId(key, value)));
    return completer.future;
  }

  /// Fills the payload's `sourceTypeId` from the cache when the caller left it
  /// blank.
  ///
  /// The worker rebuilds an open62541 value from this and `valueToVariant`
  /// refuses a scalar with no type id, so the fallback is the Dart runtime type
  /// — which cannot tell an `Int16` tag from an `Int64` one, and a wrong guess
  /// on a setpoint costs a `Bad_TypeMismatch`. The last reading main saw for
  /// the key carries the node's OWN data type id, observed rather than
  /// inferred, which is the best answer available on this side. A caller that
  /// supplied one keeps it.
  relay.DynamicValue _withTypeId(String key, relay.DynamicValue value) {
    if (value.sourceTypeId != null) return value;
    final cached = store.peek(key)?.sourceTypeId;
    if (cached == null) return value;
    return value.copyWith(sourceTypeId: cached);
  }

  /// Writes still waiting on [index]. Diagnostics and tests.
  @visibleForTesting
  int pendingWriteCount(int index) => _pending[index]?.length ?? 0;

  // ------------------------------------------------------------ the teardown

  /// Kills every worker. The whole of PIPE-13 on this side.
  ///
  /// `Isolate.immediate` runs no `finally` and flushes nothing, and that is the
  /// point: an OPC UA teardown that is awaited takes seconds, and a backend
  /// that takes seconds to stop is a backend Docker kills mid-write. Nothing
  /// here awaits anything — there is no future to return, deliberately, so no
  /// caller can be tempted to wait on one.
  void shutdown() {
    for (final worker in _workers) {
      worker.kill();
    }
  }

  /// Stops reading the workers. Does not kill them — see [shutdown].
  void dispose() {
    _disposed = true;
    for (final listen in _listens) {
      listen.cancel();
    }
    _listens.clear();
    for (final table in _pending.values) {
      for (final pending in table.values) {
        pending.timer.cancel();
      }
    }
    _pending.clear();
    store.dispose();
  }
}
