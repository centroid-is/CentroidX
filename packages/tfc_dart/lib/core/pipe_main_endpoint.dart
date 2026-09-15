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
import 'package:tfc_dart/core/alarm_stamp.dart';
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

  /// Keys whose cached `sourceTime` a worker frame affirmatively claimed came
  /// from the source.
  ///
  /// **An allow-list, not a deny-list**, and that is the safety property: every
  /// key not named here reads [AlarmTsSource.backendReceipt], so a value that
  /// arrives by a route nobody taught this class about cannot acquire a plant
  /// claim by default.
  ///
  /// **Beside the store rather than in it**, because `relay.ValueStore` and
  /// `relay.DynamicValue` live in the protocol package and this is not a wire
  /// fact — it never leaves the process. It is maintained in [_applyFrame]
  /// strictly BEFORE `store.applyBatch`, so a listener the batch notifies
  /// synchronously already reads the provenance belonging to the value it was
  /// woken for.
  final Set<String> _sourceStamped = <String>{};

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

  /// How many callers on main want each key. The subscribe/unsubscribe control
  /// message crosses the port only when this leaves or returns to zero.
  ///
  /// A named count in a map, exactly as `fanin.dart` holds one — and for the
  /// reason its comment gives at length: the release point is then a line of
  /// code with a name rather than an emergent side effect, and it happens when
  /// the last watcher goes rather than ten minutes later while the PLC keeps
  /// paying for a monitored item nobody is reading.
  final Map<String, int> _refcount = <String, int>{};

  /// What each worker is currently piping — the keys whose refcount is >= 1,
  /// per worker, maintained in lockstep with [_refcount].
  ///
  /// This is the snapshot a respawn replays. It survives a death on purpose:
  /// the worker is gone, main's intent is not.
  final Map<int, Set<String>> _subscribedByWorker = <int, Set<String>>{};

  /// Callers waiting for the next frame from each worker, by worker index.
  ///
  /// Only [resnapshot] uses this, and only to answer the question "has the
  /// worker had a turn since I asked". A completer list rather than a
  /// `StreamController`: a controller would need a `close()` on this class's
  /// teardown, and `test/core/pipe_shutdown_structure_test.dart` scans
  /// `lib/core/pipe*.dart` for exactly that call — the whole point of PIPE-13
  /// being that nothing on a shutdown path awaits anything.
  final Map<int, List<Completer<void>>> _frameWaiters =
      <int, List<Completer<void>>>{};

  int _resnapshots = 0;

  bool _disposed = false;

  /// Called with a key the upstream has affirmatively retired.
  ///
  /// **Phase 12's IN-02, and the reason this hook exists at all.** The worker's
  /// `_onDone` announces [PipeKeyRetired] but deliberately leaves the key in
  /// its own `_subscribed` set — "main is the only thing that retracts it" —
  /// and `_disarmTickIfIdle` only runs on an unsubscribe. So a worker whose
  /// last subscribed key was retired keeps its 50 ms drain timer running for
  /// the life of the process, ticking an empty buffer. **A consumer of this
  /// hook that merely blanks the reading has not discharged the obligation:**
  /// it must call [unsubscribe] for the key, which is what makes the
  /// [PipeUnsubscribe] cross and the timer disarm.
  ///
  /// Fired AFTER the `errorConfig` value has been applied to the store, so a
  /// consumer that reads the key inside the callback sees the retirement
  /// rather than the reading it replaced.
  ///
  /// A plain callback and not a `StreamController` — see [_frameWaiters] for
  /// why this file has none.
  void Function(String key)? onKeyRetired;

  /// Called with the index of a worker whose isolate has just died.
  ///
  /// **The signal, not the degrade.** This endpoint has already marked
  /// everything that worker was piping `badCommFault` by the time the hook
  /// fires (see [_onWorkerDied]), so a consumer reads a cache with the fact
  /// already in it. What a consumer adds is *policy* — whether one dead worker
  /// out of three is a whole-of-upstream event worth announcing to every
  /// connected client, which is a question this endpoint has no opinion on and
  /// plan 13-07's `BackendFreshnessSweep` does.
  ///
  /// Added in 13-07 because the alternative was to infer a link transition
  /// from a mass quality change, and a heuristic over qualities cannot tell a
  /// dead isolate from fifteen tags that happened to fault together.
  ///
  /// A plain callback, guarded against a throwing consumer, for the same two
  /// reasons as [onKeyRetired].
  void Function(int worker)? onWorkerDied;

  /// Called with the index of a worker whose new generation has announced
  /// itself, after the subscription snapshot has been replayed to it.
  ///
  /// Fires on **every** generation, including the first. A consumer that only
  /// cares about a respawn is the thing that knows whether it announced a loss
  /// to recover from; this side just reports the fact.
  void Function(int worker)? onWorkerReady;

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
    _subscribedByWorker[index] = <String>{};
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

  /// Where the instant on [key]'s cached value came from.
  ///
  /// [AlarmTsSource.plant] only for a key a worker frame has affirmatively
  /// claimed a source stamp for. **Everything else is
  /// [AlarmTsSource.backendReceipt]**, and the list of "everything else" is why
  /// the default is the one it is:
  ///
  ///  * a key that arrived in a frame flagged substituted — the Modbus fleet,
  ///    an M2400 with no device clock, a server that omits the timestamp;
  ///  * a key main has never seen in a frame at all — every backend-minted
  ///    `PIPE.*` and `ALARM.*` value goes straight through `applyBatch`, and
  ///    those instants are backend receipts;
  ///  * a key from a frame that stated nothing (`substitutedStamps == null`).
  ///
  /// A `sourceTime` cannot answer this question: the substituted one is a real,
  /// non-null `DateTime` and looks exactly like a source one. That is precisely
  /// why the claim has to travel rather than be inferred here.
  AlarmTsSource stampSourceOf(String key) => _sourceStamped.contains(key)
      ? AlarmTsSource.plant
      : AlarmTsSource.backendReceipt;

  // ----------------------------------------------------------- the subscribe

  /// One more caller on main wants [key] piped.
  ///
  /// The worker pipes only what it was asked for, so somebody has to ask — but
  /// only once, however many panels are watching. On the **0 -> 1 transition**
  /// a [PipeSubscribe] crosses to the owning worker and [key] joins that
  /// worker's subscribed set; every later call is a `++` and nothing else.
  ///
  /// A key no worker owns is a no-op refusal: no message, no refcount, no
  /// entry in anybody's set. Nothing is spawned for such a key, so there is
  /// nothing that could ever answer for it.
  void subscribe(String key) {
    if (_disposed) return;
    final index = _keyToWorker[key];
    if (index == null) {
      _logger.w('pipe: refusing to subscribe "$key" — no worker owns it');
      return;
    }
    final count = (_refcount[key] ?? 0) + 1;
    _refcount[key] = count;
    if (count > 1) return; // already piping; the worker has been told once
    _subscribedByWorker[index]!.add(key);
    _sendControl(index, PipeSubscribe(key));
  }

  /// One fewer caller on main wants [key].
  ///
  /// The [PipeUnsubscribe] crosses on the **1 -> 0 transition** and [key]
  /// leaves the worker's subscribed set at that same instant — synchronously,
  /// so "released when the last watcher goes" is literally true rather than
  /// true one event-loop turn later.
  ///
  /// Unsubscribing something that was never subscribed is a no-op, so teardown
  /// paths need no bookkeeping (`ValueStoreNode.removeListener`'s convention,
  /// which `fanin.dart` follows for the same reason).
  void unsubscribe(String key) {
    if (_disposed) return;
    final index = _keyToWorker[key];
    if (index == null) return;
    final count = _refcount[key] ?? 0;
    if (count == 0) return;
    if (count > 1) {
      _refcount[key] = count - 1;
      return;
    }
    _refcount.remove(key);
    _subscribedByWorker[index]!.remove(key);
    _sendControl(index, PipeUnsubscribe(key));
  }

  /// How many callers on main currently want [key]. Diagnostics and tests.
  @visibleForTesting
  int refcountOf(String key) => _refcount[key] ?? 0;

  // -------------------------------------------------------- the resnapshot

  /// Asks every worker that owns one of [keys] to re-deliver what it has.
  ///
  /// **One message per WORKER, not per key** — which is the entire reason
  /// [PipeResnapshot] carries a list. Fifty keys on one worker are one message
  /// and one round trip; a key set spanning three workers is three messages and
  /// three round trips, and [resnapshots] says three. That fan-out is worth
  /// stating out loud because the contract cases seed every key on one source
  /// and would otherwise hide it: a diagnostics page reading across ST101,
  /// ST201 and the Baader PLC really does pay three.
  ///
  /// **It always resolves.** A worker that never answers is waited out for
  /// [writeDeadline] and then given up on; the caller reads the cache and gets
  /// whatever is in it, which is honest. Hanging instead would put a read on
  /// the same footing as a blackholed link — the exact stall this phase exists
  /// to remove, arriving through the method that was supposed to be cheap.
  ///
  /// A key no worker owns costs nothing at all: no message, no round trip. So
  /// does a worker with no live control port — a message that was never sent is
  /// not a round trip, and counting it would let `readFresh` claim a freshness
  /// it never went and got.
  Future<void> resnapshot(Iterable<String> keys) async {
    if (_disposed) return;
    final byWorker = <int, List<String>>{};
    for (final key in keys) {
      final index = _keyToWorker[key];
      if (index == null) continue;
      (byWorker[index] ??= <String>[]).add(key);
    }
    if (byWorker.isEmpty) return;

    final waits = <Future<void>>[];
    byWorker.forEach((index, group) {
      if (!_sendControl(index, PipeResnapshot(group))) return;
      _resnapshots++;
      waits.add(_nextFrameFrom(index));
    });
    if (waits.isEmpty) return;
    await Future.wait(waits);
  }

  /// How many [PipeResnapshot] messages this endpoint has actually sent.
  ///
  /// The round-trip counter the read contract's arithmetic is made of: `read`
  /// must not move it, `readFresh` must move it by exactly one, and fifty keys
  /// must move it by one rather than by fifty.
  int get resnapshots => _resnapshots;

  /// Completes when worker [index] next hands over a frame, or at the deadline.
  Future<void> _nextFrameFrom(int index) {
    final completer = Completer<void>();
    (_frameWaiters[index] ??= <Completer<void>>[]).add(completer);
    final timer = Timer(writeDeadline, () {
      _frameWaiters[index]?.remove(completer);
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future.whenComplete(timer.cancel);
  }

  /// Releases everyone waiting on a frame from worker [index].
  void _settleFrameWaiters(int index) {
    final waiting = _frameWaiters.remove(index);
    if (waiting == null) return;
    for (final completer in waiting) {
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// Exactly the keys worker [index] is piping right now — the respawn
  /// snapshot.
  @visibleForTesting
  Set<String> subscribedKeys(int index) =>
      Set<String>.unmodifiable(_subscribedByWorker[index] ?? const <String>{});

  /// Sends one control message to a worker, if it currently has a port.
  ///
  /// A worker between generations is not an error and not a lost intent: the
  /// refcount and the subscribed set have already been updated, and the
  /// respawn's ready handshake replays the whole snapshot.
  ///
  /// Returns whether the message actually crossed. [resnapshot] is the one
  /// caller that cares: it must not count a round trip it did not make, and it
  /// must not then wait for an answer to a question nobody was asked.
  bool _sendControl(int index, PipeControl message) {
    final port = _workers[index].controlPort;
    if (port == null) {
      _logger.i('pipe: ${_workers[index].name} has no control port for '
          '$message — the respawn replay will carry it');
      return false;
    }
    port.send(message);
    return true;
  }

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
      // BEFORE applyBatch. The batch notifies its listeners synchronously, and
      // `BackendLiveValues.subscribeStamped` reads the provenance inside that
      // notification to pair it with the value. Recording it afterwards would
      // hand every one of those listeners the previous frame's claim.
      _recordStampProvenance(frame);
      // seq omitted: the pipe is process-internal and has no gap chain to
      // reason about — a lost frame is a dead isolate, which arrives as its
      // own event.
      store.applyBatch(frame.values);
    }
    for (final event in frame.priority) {
      _applyEvent(index, event);
    }
    // The worker has had its turn: anything waiting on a resnapshot from it can
    // stop waiting. Last, so a caller that resumes here reads a cache with this
    // whole frame already in it.
    _settleFrameWaiters(index);
  }

  /// Folds one frame's provenance claims into [_substitutedStamps]/[_claimed].
  ///
  /// A frame that states nothing (`substitutedStamps == null`) has every value
  /// in it treated as substituted. That is the safe direction and the one the
  /// milestone requires: an unknown provenance must never be read as a plant
  /// instant, because the cost of that mistake is an alarm row an operator is
  /// judged on saying the plant vouched for a number it never saw.
  void _recordStampProvenance(PipeFrame frame) {
    final substituted = frame.substitutedStamps;
    for (final key in frame.values.keys) {
      if (substituted == null || substituted.contains(key)) {
        _sourceStamped.remove(key);
      } else {
        _sourceStamped.add(key);
      }
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
        // THEN the hook (IN-02). Order matters: a consumer that unsubscribes
        // before the value lands would race the reading it is supposed to see
        // last, and would decide what to do while the key still carried its
        // old, good-looking number.
        _announceRetired(key);
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

  /// Tells [onKeyRetired], if anybody registered, that [key] is gone.
  ///
  /// Guarded because the consumer is somebody else's code on the pipe's own
  /// message pump: an escaping error here would take down the worker's message
  /// subscription, and every later reading from that worker with it — a total,
  /// silent loss of one PLC because one adapter threw once.
  void _announceRetired(String key) {
    final hook = onKeyRetired;
    if (hook == null) return;
    try {
      hook(key);
    } catch (error) {
      _logger.e('pipe: the onKeyRetired consumer failed for "$key": $error — '
          'the key stays subscribed, so that worker\'s drain timer is now '
          'armed with nothing to drain (IN-02)');
    }
  }

  /// Tells [hook], if anybody registered one, that worker [index] changed
  /// generation.
  ///
  /// Guarded for exactly [_announceRetired]'s reason: the consumer is somebody
  /// else's code on the pipe's own message pump, and an escaping error would
  /// cancel the worker's message subscription and lose every later reading
  /// from that PLC — a total, silent loss of one station because one adapter
  /// threw once.
  void _announceWorker(void Function(int)? hook, int index, String name) {
    if (hook == null) return;
    try {
      hook(index);
    } catch (error) {
      _logger.e('pipe: the $name consumer failed for '
          '${_workers[index].name}: $error — the link transition was not '
          'announced to it');
    }
  }

  /// Writes [quality] with no payload for every key in [keys], immediately.
  ///
  /// A direct [relay.ValueStore.applyBatch]: there is no tick on this side and
  /// no buffer to sit in, so "un-conflated" here means the operator's screen
  /// changes on this call and not one drain later.
  void _markBad(Iterable<String> keys, relay.Quality quality) {
    if (keys.isEmpty) return;
    // This class mints these values, so whatever the source last vouched for is
    // superseded by something it never said. Dropping the claim first keeps the
    // rule exact: only a value a frame arrived with may be called a plant one.
    _sourceStamped.removeAll(keys);
    store.applyBatch(<String, relay.DynamicValue>{
      for (final key in keys)
        key: relay.DynamicValue(value: null, quality: quality),
    });
  }

  /// A generation announced itself: replay main's whole intent to it.
  ///
  /// **A snapshot, never a delta.** A fresh worker is piping nothing at all, so
  /// there is no state on that side to diff against — a delta would be
  /// describing changes to a set the new isolate never had. Everything with a
  /// watcher right now is re-sent; a key released while the worker was dead is
  /// simply absent, and no [PipeUnsubscribe] is minted for it because there is
  /// nothing to retract.
  ///
  /// The first generation replays an empty set, which costs nothing: main has
  /// not had a chance to want anything yet.
  ///
  /// **No write is replayed, on any generation.** In-flight writes died with
  /// the isolate and were answered unknown by [_onWorkerDied]; re-sending one
  /// now would execute an operator's command after they had already been told
  /// its fate was unknown.
  void _onWorkerReady(int index, SendPort control) {
    final snapshot = _subscribedByWorker[index];
    if (snapshot != null && snapshot.isNotEmpty) {
      _logger.i('pipe: ${_workers[index].name} is ready; replaying '
          '${snapshot.length} subscription(s)');
      for (final key in List<String>.of(snapshot)) {
        control.send(PipeSubscribe(key));
      }
    }
    // AFTER the replay, and unconditionally: a generation with nothing to
    // replay is still a generation, and a consumer deciding whether to
    // announce a recovery must not have that decision depend on whether main
    // happened to want anything at the moment the isolate died.
    _announceWorker(onWorkerReady, index, 'onWorkerReady');
  }

  /// The worker died. This is news, and it is delivered as news.
  ///
  /// Everything that worker was piping goes bad on this turn — `badCommFault`,
  /// the band that says something went wrong on the link and waiting might fix
  /// it, which is exactly true of an isolate the supervisor is about to
  /// respawn. Only the keys it was actually piping: a key it owned but nobody
  /// ever subscribed to has never been known, and `notYetKnown` remains the
  /// honest answer for it.
  ///
  /// Every write still waiting on that worker resolves [relay.WriteUnknown]
  /// **now** rather than at its own deadline. The deadline would eventually
  /// say the same thing, but seconds later, and there is nothing uncertain
  /// left to wait for: the isolate that held the request is gone.
  ///
  /// The subscription set is deliberately NOT cleared. The worker is gone;
  /// main's intent is not, and that set is what the respawn replays.
  void _onWorkerDied(int index) {
    final name = _workers[index].name;
    final piped = _subscribedByWorker[index] ?? const <String>{};
    _logger.e('pipe: $name died — marking ${piped.length} key(s) bad and '
        'resolving ${pendingWriteCount(index)} pending write(s) unknown');
    _markBad(piped, relay.Quality.badCommFault);
    // Death is an event here too: a resnapshot waiting on this worker resolves
    // NOW rather than at its own deadline. There is nothing uncertain left to
    // wait for, and the caller reads a cache that has just been badged bad.
    _settleFrameWaiters(index);
    // THEN the hook, for `_announceRetired`'s reason: a consumer that reads
    // the keys inside the callback must see the degrade already applied rather
    // than the good-looking numbers it replaced.
    _announceWorker(onWorkerDied, index, 'onWorkerDied');

    final pendingTable = _pending[index];
    if (pendingTable == null || pendingTable.isEmpty) return;
    final dying = List<_PendingWrite>.of(pendingTable.values);
    pendingTable.clear();
    for (final pending in dying) {
      pending.resolve(relay.WriteUnknown(
        pending.cmd,
        relay.WriteReason('worker_died',
            message: '$name exited while the write to "${pending.key}" was in '
                'flight'),
      ));
    }
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
  /// `Isolate.kill` runs no `finally` and flushes nothing, and that is the
  /// point: an OPC UA teardown that is awaited takes seconds, and a backend
  /// that takes seconds to stop is a backend Docker kills mid-write. Nothing
  /// here awaits anything — there is no future to return, deliberately, so no
  /// caller can be tempted to wait on one.
  ///
  /// [DataAcquisitionWorker.kill] owns which PRIORITY, and it is two of them:
  /// a polite `beforeNextEvent` that cannot abort the VM inside an open62541
  /// callback, backed on a timer by the `immediate` that guarantees the
  /// worker dies. Neither of them waits for a peer, which is the only
  /// property this method cares about.
  void shutdown() {
    for (final worker in _workers) {
      worker.kill();
    }
  }

  /// Stops reading the workers. Does not kill them — see [shutdown].
  ///
  /// Every write still in flight settles [relay.WriteUnknown] on the way out,
  /// mirroring [_onWorkerDied]. [write] promises the future ALWAYS settles, and
  /// cancelling the deadline timer without resolving the completer is exactly
  /// how that promise gets broken: the caller waits forever on an answer the
  /// only remaining source of has just been torn down. Unknown is the honest
  /// verdict — the request is on the wire and this side can no longer hear the
  /// reply — and, as everywhere else on this path, nothing re-sends.
  void dispose() {
    _disposed = true;
    for (final listen in _listens) {
      listen.cancel();
    }
    _listens.clear();
    // Same promise as a pending write: a caller waiting on a resnapshot must
    // not be left holding a future whose only remaining source has just been
    // torn down.
    for (final index in _frameWaiters.keys.toList(growable: false)) {
      _settleFrameWaiters(index);
    }
    for (final table in _pending.values) {
      for (final pending in List<_PendingWrite>.of(table.values)) {
        pending.resolve(relay.WriteUnknown(
          pending.cmd,
          relay.WriteReason('endpoint_disposed',
              message: 'the pipe endpoint was disposed while the write to '
                  '"${pending.key}" was in flight'),
        ));
      }
    }
    _pending.clear();
    store.dispose();
  }
}
