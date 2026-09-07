/// The acquisition worker's end of the pipe.
///
/// One of these lives inside every acquisition isolate, between the worker's
/// live [StateMan] and the `SendPort` main handed it at spawn. It does four
/// things and deliberately nothing else:
///
///  1. **Inbound control.** Main sends explicit subscribe/unsubscribe messages
///     (refcounted on main, so the worker sees a subscribe only on main's 0→1
///     and an unsubscribe only on main's 1→0). The worker pipes *only*
///     subscribed keys — the collection-only keys it writes to its own database
///     never cross the port at all.
///  2. **Translate at the edge.** Every sample is converted to the pure-Dart
///     `tfc_relay_protocol` vocabulary by [translateOpcUaSample] before it can
///     touch the buffer. The C-coupled `package:open62541` `DynamicValue` stops
///     here; only `relay.DynamicValue` ever crosses the port.
///  3. **Conflate and drain.** Samples accumulate in a [PipeSendBuffer] and are
///     handed over one [PipeFrame] per tick — and only when the buffer is
///     dirty. The timer is **listener-gated**: it is armed when the subscribed-
///     key count leaves zero and cancelled when it returns, so an idle worker
///     runs no timer and sends nothing (project rule; an always-on
///     `Timer.periodic` in this plumbing has broken unrelated suites before).
///  4. **Self-report.** [dataAcquisitionIsolateEntry] runs the worker body
///     inside a `runZonedGuarded` that swallows steady-state errors — they
///     never reach the error port and never kill the isolate. That guard is
///     load-bearing and is NOT removed here. The consequence is that a fault
///     inside this endpoint is invisible to main unless the endpoint says so
///     itself, so stream errors, retirements and write outcomes are put on the
///     buffer's priority lane, where conflation cannot absorb them.
///
/// **Nothing here retries anything.** A write is executed at most once per
/// control message; a re-send is the operator's decision, never the pipe's.
///
/// **IMPORT-PREFIX HAZARD (R-6).** Inside `tfc_dart`, `package:open62541` is the
/// native tongue and is imported bare; the relay protocol is prefixed `as
/// relay`. Two classes are called `DynamicValue` in this file's scope and the
/// prefix is what keeps them apart.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:open62541/open62541.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/write_translation.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

// ------------------------------------------------------- the control channel
//
// Process-internal shapes, not wire shapes: `tfc_relay_protocol` stays frozen
// this phase and these never leave the process (fanin.dart precedent). They are
// plain final classes with final fields, which `Isolate.spawn`-family ports
// send by deep copy.

/// Something main asks the worker to do.
sealed class PipeControl {
  const PipeControl();
}

/// Start piping [key]. Sent on main's 0→1 refcount transition, once.
final class PipeSubscribe extends PipeControl {
  const PipeSubscribe(this.key);

  final String key;

  @override
  String toString() => 'PipeSubscribe($key)';
}

/// Stop piping [key]. Sent on main's 1→0 refcount transition, once.
final class PipeUnsubscribe extends PipeControl {
  const PipeUnsubscribe(this.key);

  final String key;

  @override
  String toString() => 'PipeUnsubscribe($key)';
}

/// Re-deliver the current reading of every named key, in ONE frame.
///
/// **Batched because the alternative is fifty round trips.** `readMany` is on
/// the wire surface for exactly one promise — "fifty keys cost one round trip,
/// not fifty" (`read_contract.dart`) — and that promise cannot be kept with a
/// per-key control message however cheap the message is. One [PipeResnapshot]
/// carrying fifty names produces one drain frame carrying fifty readings.
///
/// **A resnapshot is NOT a subscribe.** A key the worker is not already
/// subscribed to is ignored in silence: inventing a subscription from a read
/// would give a key nobody watches a monitored item on the PLC, which is the
/// cost the whole refcount exists to avoid. It also reaches nowhere upstream —
/// the answer comes from the worker's own last reading — because a read that
/// reached through the link would reintroduce the synchronous stall Phase 12
/// exists to remove.
///
/// **It arms no timer.** A key that is subscribed already armed the drain tick
/// when it was subscribed; a key that is not subscribed buffers nothing. So an
/// idle worker that is asked for a resnapshot stays idle, and the
/// listener-gating law holds.
final class PipeResnapshot extends PipeControl {
  const PipeResnapshot(this.keys);

  final List<String> keys;

  @override
  String toString() => 'PipeResnapshot(${keys.length} key(s))';
}

/// Write [value] to [key], and tell main what happened under [id].
///
/// [id] is the per-worker monotonic int minted on MAIN and echoed back beside
/// the outcome. It is deliberately NOT stuffed into `WriteResult.cmd` — Phase
/// 13 needs `cmd` for the operator's ULID idempotency id — although `cmd` is
/// set to `id.toString()` so the protocol type stays well-formed.
final class PipeWriteRequest extends PipeControl {
  const PipeWriteRequest(this.id, this.key, this.value);

  final int id;
  final String key;
  final relay.DynamicValue value;

  @override
  String toString() => 'PipeWriteRequest($id, $key)';
}

// ------------------------------------------------------- the priority lane
//
// News about the pipe rather than news about a value. Everything here is
// appended to PipeSendBuffer's priority lane, which the latest-per-key map can
// never absorb: an error that a later reading quietly overwrote would show the
// operator a fresh-looking number with no sign the link had faulted.

/// Something the worker tells main that is not a reading.
sealed class PipeEvent {
  const PipeEvent();
}

/// The key's stream faulted. [quality] is the mapped band an operator reads.
///
/// A *permanent* band ([relay.Quality.errorConfig] and friends) is emitted on
/// **transition only** — mirroring `AutoDisposingStream._loggedPermanentError`,
/// which is why a dead key mapping does not reprint on every retry of the 600 s
/// monitor ladder.
final class PipeKeyError extends PipeEvent {
  const PipeKeyError(this.key, this.quality, this.message);

  final String key;
  final relay.Quality quality;
  final String message;

  @override
  String toString() => 'PipeKeyError($key, ${quality.code}, $message)';
}

/// The key's stream is done — the node was deleted, the entry was retired.
///
/// Distinct from an error on purpose: retirement is permanent and the value is
/// gone, so main must stop showing a reading for it. Silence is not acceptable.
final class PipeKeyRetired extends PipeEvent {
  const PipeKeyRetired(this.key);

  final String key;

  @override
  String toString() => 'PipeKeyRetired($key)';
}

/// The answer to one [PipeWriteRequest], carrying main's own [id] beside it.
final class PipeWriteOutcome extends PipeEvent {
  const PipeWriteOutcome(this.id, this.result);

  final int id;
  final relay.WriteResult result;

  @override
  String toString() => 'PipeWriteOutcome($id, ${result.runtimeType})';
}

// --------------------------------------------------------------- the upstream

/// The two [StateMan] methods the pipe uses, and nothing else.
///
/// It exists so the endpoint's arms can run against a controllable stream with
/// no OPC UA session, no PLC and no Docker — not as an abstraction layer.
/// Production passes [StateManUpstream]; there is exactly one implementation in
/// `lib/`.
abstract interface class PipeUpstream {
  /// The key's value stream. May take arbitrarily long, or never complete, if
  /// the server is blackholed — hence the fire-and-forget handling in
  /// [PipeWorkerEndpoint].
  Future<Stream<DynamicValue>> subscribe(String key);

  /// Executes one write. Every failure arrives flattened into a
  /// [StateManException] whose message embeds the original — which is why the
  /// classifier reads the text rather than a status code.
  Future<void> write(String key, DynamicValue value);
}

/// The worker's live [StateMan], as a [PipeUpstream].
class StateManUpstream implements PipeUpstream {
  StateManUpstream(this.stateMan);

  final StateMan stateMan;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) => stateMan.subscribe(key);

  @override
  Future<void> write(String key, DynamicValue value) =>
      stateMan.write(key, value);
}

// ------------------------------------------------------------------ the tick

/// How often a worker with at least one subscribed key drains its buffer.
///
/// Fifty milliseconds is well under the eye's threshold for a plant readout and
/// far above the cost of one port send, and the tick only ever costs a message
/// when the buffer is dirty. It is the ceiling on the number of messages a
/// worker can produce, which is the entire point: the 24 s staleness this
/// replaces was queue depth, one message per notification.
const kPipeDrainInterval = Duration(milliseconds: 50);

/// How long the worker waits for [PipeUpstream.write] before it answers main
/// without one.
///
/// Deliberately INSIDE main's own `kPipeWriteDeadline` (5 s, the main-side
/// endpoint) so that when an upstream stops answering it is the worker's
/// verdict that reaches the operator, not main's fallback: the worker knows the
/// request reached the link and can say `plc_timeout`, whereas main can only
/// say `pipe_timeout` — a less honest description of the same event. Both are
/// [relay.WriteUnknown]; neither ever re-sends.
const kPipeWorkerWriteDeadline = Duration(seconds: 4);

/// The worker's end of the acquisition pipe. See the library doc.
class PipeWorkerEndpoint {
  PipeWorkerEndpoint({
    required PipeUpstream stateMan,
    required SendPort toMain,
    this.drainInterval = kPipeDrainInterval,
    this.writeDeadline = kPipeWorkerWriteDeadline,
    DateTime Function()? now,
    Logger? logger,
  })  : _stateMan = stateMan,
        _toMain = toMain,
        _now = now ?? DateTime.now,
        _logger = logger ?? Logger();

  final PipeUpstream _stateMan;
  final SendPort _toMain;
  final DateTime Function() _now;
  final Logger _logger;

  /// The drain period. See [kPipeDrainInterval].
  final Duration drainInterval;

  /// How long one write may take before it is answered unknown. See
  /// [kPipeWorkerWriteDeadline].
  final Duration writeDeadline;

  final PipeSendBuffer _buffer = PipeSendBuffer();

  /// Keys main has asked for. This is *intent*, not attachment: a key sits here
  /// from the instant the subscribe control message lands, before (and even if
  /// never) the upstream stream arrives. Gating the timer on intent rather than
  /// on live streams is what keeps a blackholed key from silencing a healthy
  /// one on the same worker.
  final Set<String> _subscribed = <String>{};

  /// The live stream subscription per key, once the upstream handed one over.
  final Map<String, StreamSubscription<DynamicValue>> _streams =
      <String, StreamSubscription<DynamicValue>>{};

  /// The last permanent-error band reported for a key, so the same dead mapping
  /// is not reprinted on every retry. Cleared the moment the key recovers, so
  /// the NEXT transition still speaks.
  final Map<String, relay.Quality> _permanentError = <String, relay.Quality>{};

  /// The last reading translated for each subscribed key — the only thing a
  /// [PipeResnapshot] is allowed to answer from.
  ///
  /// A cache and not a reach: [PipeUpstream] has no read method and adding one
  /// would put a synchronous call to a possibly-blackholed server on the read
  /// path, which is the stall this whole phase removed. It is bounded by
  /// [_subscribed] — dropped on unsubscribe, on retirement and on dispose — so
  /// it cannot outgrow the set of keys main is actually watching.
  final Map<String, relay.DynamicValue> _last = <String, relay.DynamicValue>{};

  /// Which keys in [_last] carry a `sourceTime` this backend substituted.
  ///
  /// Kept beside [_last] rather than derived from it, because it cannot be
  /// derived: the substituted instant is a real, non-null `DateTime` that looks
  /// exactly like a source one. Without this a resnapshot would replay every
  /// reading with no claim attached, and `PipeFrame`'s absence-means-substituted
  /// rule would demote a genuine OPC UA stamp on every reconnect.
  final Set<String> _lastSubstituted = <String>{};

  Timer? _tick;
  bool _disposed = false;

  /// How many samples arrived with no source timestamp. A counter rather than
  /// silence, per [translateOpcUaSample]'s contract.
  int _sourceTimeFallbacks = 0;

  /// Diagnostics: samples the server sent with no source timestamp.
  int get sourceTimeFallbacks => _sourceTimeFallbacks;

  /// Whether the drain timer is armed. The listener-gating property, observable.
  @visibleForTesting
  bool get isDraining => _tick != null;

  /// The keys this worker is currently piping.
  @visibleForTesting
  Set<String> get subscribedKeys => Set<String>.unmodifiable(_subscribed);

  /// One inbound control message from main.
  ///
  /// **Non-serial by construction (R-3).** Nothing in here awaits: a subscribe
  /// hands its upstream call to the microtask queue and returns, so a key whose
  /// `_monitorLoop` is grinding against a blackholed server cannot park the
  /// subscribe of a second key or the unsubscribe of its own.
  void handleControl(Object? message) {
    if (_disposed) return;
    switch (message) {
      case PipeSubscribe(key: final key):
        _subscribe(key);
      case PipeUnsubscribe(key: final key):
        _unsubscribe(key);
      case PipeResnapshot(keys: final keys):
        _resnapshot(keys);
      case PipeWriteRequest():
        // Fire-and-forget WITH a handler, same rule as the subscribe path: a
        // write must not park the next control message, and an escaped error
        // here would be swallowed by the guarded zone and leave main waiting
        // out its own deadline for an answer that was never coming.
        _executeWrite(message).catchError((Object error) {
          _logger.e('pipe endpoint: the write handler itself failed for '
              '"${message.key}": $error');
        });
      default:
        _logger.w('pipe endpoint: unrecognised control message '
            '(${message.runtimeType}) — ignored');
    }
  }

  void _subscribe(String key) {
    if (!_subscribed.add(key)) return; // already piping it; main refcounts
    _armTick();
    // Fire-and-forget WITH a handler attached. A bare `unawaited()` attaches
    // nothing, so an upstream that rejects would become an unhandled
    // asynchronous error — which the guarded zone then swallows, and main is
    // told nothing at all.
    _stateMan
        .subscribe(key)
        .then((stream) => _attach(key, stream))
        .catchError((Object error) => _onSubscribeFailed(key, error));
  }

  void _attach(String key, Stream<DynamicValue> stream) {
    // The unsubscribe (or the endpoint's own teardown) may have landed while
    // the upstream call was in flight. Attaching now would leave a stream
    // nobody will ever cancel — but simply dropping it leaks the monitored
    // items instead, so it is released rather than ignored. See [_release].
    if (_disposed || !_subscribed.contains(key)) {
      _release(key, stream);
      return;
    }
    _streams[key]?.cancel();
    _streams[key] = stream.listen(
      (sample) => _onSample(key, sample),
      onError: (Object error) => _onStreamError(key, error),
      onDone: () => _onDone(key),
      cancelOnError: false,
    );
  }

  /// Lets go of an upstream stream that arrived after nobody wanted it — by
  /// listening to it once and cancelling straight back.
  ///
  /// **Doing nothing here leaks one OPC UA monitored item per race hit, for
  /// the life of the worker.** `StateMan._monitor` creates the raw monitored
  /// items inside `_monitorLoop`, BEFORE the stream it returns is handed over
  /// and regardless of whether anyone ever listens; `AutoDisposingStream` only
  /// tears them down in `_handleCancel`, which cannot fire until
  /// `_handleListen` has fired at least once. An untouched stream therefore
  /// never arms the idle teardown, and the entry sits in
  /// `StateMan._subscriptions` with a live item on the PLC — invisibly, since
  /// a later subscribe of the same key reuses the cached (not spent) stream
  /// and does attach a listener that time. The trigger is ordinary navigation
  /// churn, not a fault: the subscribe→ready window spans `awaitConnect`,
  /// `doTheWork` and a 10 s `subscriptionCreate`, and a page teardown lands
  /// inside it easily.
  ///
  /// The listener is deaf on purpose — this touch is a release, not an
  /// attachment — but it takes [onError] anyway, because the stream is a
  /// `ReplaySubject` that may hand over a buffered error the instant it is
  /// listened to, and an unhandled one here would be swallowed by the guarded
  /// zone with nothing said to main.
  void _release(String key, Stream<DynamicValue> stream) {
    stream
        .listen((_) {}, onError: (Object _) {}, cancelOnError: false)
        .cancel()
        .catchError((Object error) {
      _logger.w('pipe endpoint: releasing the unwanted stream for "$key" '
          'failed: $error');
    });
  }

  /// Answers one [PipeResnapshot]: every named key this worker is subscribed to
  /// and has a reading for, put back on the value lane in one go.
  ///
  /// Nothing here flushes and nothing here arms a tick. A subscribed key means
  /// the tick is already armed (see [_subscribe]), so the readings ride the
  /// next drain — one frame, whatever the key count. A worker with nothing
  /// subscribed buffers nothing and stays silent, which is what keeps "an idle
  /// worker runs no timer" literally true across this new message.
  void _resnapshot(List<String> keys) {
    for (final key in keys) {
      if (!_subscribed.contains(key)) continue;
      final reading = _last[key];
      if (reading == null) continue;
      _buffer.putValue(key, reading,
          sourceTimeSubstituted: _lastSubstituted.contains(key));
    }
  }

  void _unsubscribe(String key) {
    _subscribed.remove(key);
    _last.remove(key);
    _lastSubstituted.remove(key);
    // Cancel the stream we own for this key. Synchronous dispatch: this can
    // never queue behind another key's hung subscribe.
    final stream = _streams.remove(key);
    stream?.cancel();
    _buffer.remove(key);
    _permanentError.remove(key);
    _disarmTickIfIdle();
  }

  void _onSample(String key, DynamicValue sample) {
    // `onSourceTimeFallback` fires SYNCHRONOUSLY inside the call, so this local
    // belongs to this sample and no other. That is the whole mechanism: the one
    // place that knows whether the instant was substituted already says so, and
    // this captures the fact instead of re-deriving it downstream from an
    // instant that carries no evidence either way.
    var sourceTimeSubstituted = false;
    var value = translateOpcUaSample(
      sample,
      arrivedAt: _now(),
      onSourceTimeFallback: () {
        sourceTimeSubstituted = true;
        _sourceTimeFallbacks++;
      },
    );
    // Carry the node's own data type across with the reading.
    //
    // `translateOpcUaSample` is shared with `tfc_relay_local` and describes a
    // READING — quality, payload, source time — so the type id is attached
    // here, at the pipe's edge, where it is needed rather than in a converter
    // two packages depend on. It is needed because the value edge runs both
    // ways: [uaValueFromRelayValue] rebuilds a write payload on this side and
    // `valueToVariant` refuses a scalar with no type id, so without this the
    // only source left is the Dart runtime type — which cannot tell an `Int16`
    // tag from an `Int64` one, and the cost of that guess on a setpoint is a
    // `Bad_TypeMismatch` refusal. Main fills it onto the write payload from
    // its cache (`PipeMainEndpoint._withTypeId`); this is where the cache gets
    // it from. `NodeId.toString()` is exactly the textual form
    // [nodeIdFromSourceTypeId] parses back.
    final typeId = sample.typeId;
    if (typeId != null) {
      value = value.copyWith(sourceTypeId: typeId.toString());
    }
    // The key answered. Whatever permanent fault was last reported for it is
    // over, so the NEXT occurrence is a transition again and must speak.
    if (!value.quality.isError) _permanentError.remove(key);
    // Remembered before it is buffered: the buffer conflates and is drained
    // empty every tick, so it cannot answer "what does this key read right
    // now" a moment later. See [_last].
    _last[key] = value;
    if (sourceTimeSubstituted) {
      _lastSubstituted.add(key);
    } else {
      _lastSubstituted.remove(key);
    }
    _buffer.putValue(key, value,
        sourceTimeSubstituted: sourceTimeSubstituted);
  }

  void _onStreamError(String key, Object error) {
    _reportKeyFault(key, error, 'stream error');
  }

  void _onSubscribeFailed(String key, Object error) {
    // The subscribe never produced a stream, so there is nothing to cancel.
    // The key stays in [_subscribed] — that is main's intent, and main is the
    // only thing that retracts it.
    _reportKeyFault(key, error, 'subscribe failed');
  }

  /// Puts one key fault on the priority lane, once per transition.
  ///
  /// The quality is read from the typed exception's `.statusCode` when there is
  /// one — `StateMan`'s monitored-item streams deliver `UaStatusException`, so
  /// the code is available rather than only a formatted sentence — and from the
  /// text otherwise, which is the branch `useIsolate: true` forces because
  /// `isolate.dart` marshals every error across its port as `e.toString()`.
  ///
  /// **Permanent bands are emitted on transition only** (OQ-6), mirroring
  /// `AutoDisposingStream._loggedPermanentError`. `BadNodeIdUnknown` is the
  /// server's final answer and `_monitorLoop` re-asks it on a ladder forever; a
  /// per-retry event would bury every actionable fault behind one dead mapping.
  /// Transient bands (`badCommFault`, `uncertainLastKnown`) are NOT suppressed —
  /// they are news each time, because each one may be the one that recovers.
  void _reportKeyFault(String key, Object error, String what) {
    final quality = error is UaStatusException
        ? qualityForOpcUaStatus(error.statusCode)
        : qualityForOpcUaErrorText(error.toString());
    if (quality.isError) {
      if (_permanentError[key] == quality) return;
      _permanentError[key] = quality;
    }
    _logger.e('pipe endpoint: $what for "$key": $error');
    _emitPriority(PipeKeyError(key, quality, _describe(error)));
  }

  /// The key's upstream stream ended: the node is gone and the entry is
  /// retired.
  ///
  /// **[PipeKeyRetired] obligates main to unsubscribe (Phase 13 consumer).**
  /// The key is deliberately left in [_subscribed] — that set is main's intent
  /// and main is the only thing that retracts it — but [_disarmTickIfIdle] only
  /// runs on [_unsubscribe], so a worker whose last subscribed key was retired
  /// keeps its 50 ms drain timer running forever, ticking an empty buffer. That
  /// is the one path where this library's own listener-gating law ("an idle
  /// worker runs no timer") is not actually true: nothing is arriving for the
  /// key any more, yet `_subscribed.isNotEmpty` still calls the worker busy.
  ///
  /// Whoever wires the main-side consumer of this event must therefore either
  /// call `pipe.unsubscribe(key)` on receipt of it, or change the idle test
  /// here to "every subscribed key has no live stream and nothing buffered".
  /// A consumer that merely blanks the reading and moves on leaves a timer
  /// armed for the life of the process.
  void _onDone(String key) {
    _streams.remove(key);
    // Cancel the pending telemetry FIRST: a reading for a key that no longer
    // exists is worse than no reading, because it is indistinguishable from a
    // live one. `remove` never touches the priority lane, so the announcement
    // below cannot be lost to it.
    _buffer.remove(key);
    _permanentError.remove(key);
    // The tag is gone, so the last reading is no longer an answer to anything:
    // a resnapshot must not resurrect it between the retirement and main's
    // retraction.
    _last.remove(key);
    _lastSubstituted.remove(key);
    _logger.w('pipe endpoint: "$key" was retired by the upstream');
    _emitPriority(PipeKeyRetired(key));
  }

  /// Executes exactly one write and echoes the outcome.
  ///
  /// **At most one call to the upstream per control message, always.** There is
  /// no loop and no re-send anywhere on this path: a write that expires is
  /// answered [relay.WriteUnknown], and whether to press the button again is
  /// the operator's decision, not the pipe's.
  ///
  /// The three states come from [translateWriteAnswer], not from anything
  /// decided here. `StateMan.write` flattens every failure into a
  /// [StateManException] carrying one string, so the classifier reads the TEXT
  /// branch (R-2): `UaStatusException.toString()` renders
  /// `UaStatusException(0x803b0000: Bad_NotWritable)`, which the refusal table
  /// recognises by name. **Everything it cannot read is unknown, never
  /// rejected** — "rejected" is the one answer that invites a second movement
  /// of a machine somebody may be standing next to.
  Future<void> _executeWrite(PipeWriteRequest request) async {
    final cmd = request.id.toString();
    WriteAnswer answer;
    try {
      await _stateMan
          .write(request.key, uaValueFromRelayValue(request.value))
          .timeout(writeDeadline);
      answer = const WriteAcknowledged();
    } on TimeoutException {
      // The request is on the wire and this side cannot tell whether it landed.
      answer = const WriteDeadlineExpired();
    } catch (error) {
      answer = WriteErrorText(error.toString());
    }
    _emitPriority(PipeWriteOutcome(
      request.id,
      translateWriteAnswer(
        protocol: UpstreamProtocol.opcUa,
        cmd: cmd,
        answer: answer,
      ),
    ));
  }

  /// How much of an upstream error crosses the port.
  ///
  /// Bounded because a key fault becomes a plant-visible string and an
  /// unbounded one is an unbounded thing to fan out. It is NOT redacted here:
  /// main is the same process and already holds the endpoint configuration, and
  /// the redaction boundary is the relay's own write/lastError surface.
  static String _describe(Object error) {
    final text = error.toString();
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }

  /// Appends [event] to the un-conflated priority lane.
  ///
  /// When no tick is armed the frame goes out immediately. An idle worker runs
  /// no timer by design, and an answer that waits for a tick that will never
  /// come is silence — which on the write path is the difference between
  /// "rejected" and "the operator was told nothing".
  void _emitPriority(PipeEvent event) {
    _buffer.putPriority(event);
    if (_tick == null) _flush();
  }

  // ------------------------------------------------------------- the tick

  void _armTick() {
    if (_tick != null || _disposed) return;
    _tick = Timer.periodic(drainInterval, (_) => _flush());
  }

  void _disarmTickIfIdle() {
    if (_subscribed.isNotEmpty) return;
    _tick?.cancel();
    _tick = null;
  }

  /// Drains the buffer and sends the frame — **only when there is something in
  /// it**. An empty tick costs nothing and produces no message, which is what
  /// makes an idle pipe silent rather than a heartbeat generator.
  void _flush() {
    if (_disposed) return;
    final frame = _buffer.drain();
    if (frame.isEmpty) return;
    _toMain.send(frame);
  }

  /// Stops the timer and lets go of every upstream stream.
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _tick = null;
    for (final stream in _streams.values) {
      stream.cancel();
    }
    _streams.clear();
    _subscribed.clear();
    _last.clear();
    _lastSubstituted.clear();
  }
}

// ------------------------------------------------- the write payload, inbound
//
// The value edge runs both ways. Readings are translated OUT of open62541 by
// `translateOpcUaSample`; a write payload has to be translated back IN, because
// only the protocol type crosses the port.

/// Rebuilds an open62541 write payload from the protocol value main sent.
///
/// **A type id is not decoration on this path.** `valueToVariant` throws
/// `Unable to determine type for …` for a scalar with no `typeId`, so a payload
/// that arrives without one is a write that can never encode — the failure
/// would be honest (an unparsed error is [relay.WriteUnknown]) but the write
/// would never work at all. Two sources, in order:
///
///  1. [relay.DynamicValue.sourceTypeId] — the opaque round-trip of the
///     source's own type id, e.g. `ns=2;s=X` or `ns=0;i=6`. This is the one
///     main should always fill, because it is the only one that can tell an
///     `Int16` tag from an `Int64` one.
///  2. Failing that, the Dart runtime type. A guess, and deliberately a
///     conservative one: if it disagrees with the node the server answers
///     `Bad_TypeMismatch`, which is a NAMED refusal and therefore
///     [relay.WriteRejected] — an operator is told the write did not happen,
///     rather than being left to wonder.
DynamicValue uaValueFromRelayValue(relay.DynamicValue value) {
  final raw = value.value;
  final out = DynamicValue();
  if (raw is Map) {
    final members = LinkedHashMap<String, DynamicValue>();
    for (final entry in raw.entries) {
      final member = entry.value;
      members['${entry.key}'] = member is relay.DynamicValue
          ? uaValueFromRelayValue(member)
          : DynamicValue(value: member);
    }
    out.value = members;
  } else if (raw is List) {
    out.value = <DynamicValue>[
      for (final element in raw)
        if (element is relay.DynamicValue)
          uaValueFromRelayValue(element)
        else
          DynamicValue(value: element),
    ];
  } else {
    out.value = raw;
  }
  final declared = nodeIdFromSourceTypeId(value.sourceTypeId);
  // A struct is encoded as an extension object and its type id is the struct's
  // own encoding id, which is deliberately NOT one of the scalar payload types
  // — so the filter below must not touch it.
  out.typeId = raw is Map
      ? declared
      : (isEncodableUaTypeId(declared) ? declared : _inferUaTypeId(raw));
  return out;
}

/// The Namespace-0 types the binding's serializer can actually write.
///
/// Exactly the keys of `create_type.dart`'s `_payloadTypes`, which is private,
/// so this list is the mirror of it. Kept as a named set rather than a
/// try/catch because the failure it prevents is not catchable in a useful
/// place: `opcua_serializer.dart:228` does
/// `nodeIdToPayloadType(value.typeId ?? …)!.set(…)`, and an id that is not in
/// that map makes the `!` throw a bare "Null check operator used on a null
/// value" from inside the binding.
final Set<NodeId> _encodableUaTypeIds = <NodeId>{
  NodeId.boolean,
  NodeId.sbyte,
  NodeId.byte,
  NodeId.int16,
  NodeId.uint16,
  NodeId.int32,
  NodeId.uint32,
  NodeId.int64,
  NodeId.uint64,
  NodeId.float,
  NodeId.double,
  NodeId.datetime,
  NodeId.uastring,
};

/// Whether [id] is a type the write path can encode a scalar or array with.
///
/// **A type id that cannot be encoded is worse than none**, which is why this
/// exists. A node whose DataType is abstract — `BaseDataType` (`ns=0;i=24`),
/// `Number`, `Integer`, all legal on a real server and what an in-process
/// data-source node reports by default — is observed on the reading, carried
/// across as `sourceTypeId` and handed back on the next write. Without this
/// check that write never reaches the wire at all: the serializer's `!` throws
/// inside the binding, `StateMan` flattens it to
/// `Failed to write node: "…": Null check operator used on a null value`, and
/// the classifier — correctly, having no idea what that sentence means —
/// answers [relay.WriteUnknown]. The operator is told the outcome is unknown
/// for a write that provably never left the process, on every attempt, forever.
///
/// With it, an unencodable id degrades to the Dart runtime type exactly as
/// [uaValueFromRelayValue]'s second source already promised: the server then
/// rules on the value, and a genuine mismatch comes back as the NAMED refusal
/// `Bad_TypeMismatch`, which is [relay.WriteRejected] — an answer.
@visibleForTesting
bool isEncodableUaTypeId(NodeId? id) =>
    id != null && _encodableUaTypeIds.contains(id);

/// Parses OPC UA's textual NodeId form — `ns=2;s=Name`, `ns=0;i=6`, `i=6`,
/// `ns=1;g=<guid>` — the exact shape `NodeId.toString()` writes.
///
/// Returns null for anything it cannot read, so an unrecognised id degrades to
/// the inferred type rather than throwing on the write path.
NodeId? nodeIdFromSourceTypeId(String? text) {
  if (text == null || text.isEmpty) return null;
  var namespace = 0;
  var body = text;
  final parts = text.split(';');
  if (parts.length == 2 && parts[0].startsWith('ns=')) {
    final parsed = int.tryParse(parts[0].substring(3));
    if (parsed == null || parsed < 0) return null;
    namespace = parsed;
    body = parts[1];
  } else if (parts.length != 1) {
    return null;
  }
  if (body.startsWith('i=')) {
    final numeric = int.tryParse(body.substring(2));
    return numeric == null ? null : NodeId.fromNumeric(namespace, numeric);
  }
  if (body.startsWith('s=')) {
    return NodeId.fromString(namespace, body.substring(2));
  }
  if (body.startsWith('g=')) {
    return NodeId.fromGuid(namespace, body.substring(2));
  }
  return null;
}

/// The Namespace-0 type a Dart payload most plausibly is. See
/// [uaValueFromRelayValue] for why a guess is acceptable here and what happens
/// when it is wrong.
NodeId? _inferUaTypeId(Object? raw) {
  if (raw is bool) return NodeId.boolean;
  if (raw is int) return NodeId.int64;
  if (raw is double) return NodeId.double;
  // Spelled out rather than `NodeId.string`: that static getter is shadowed by
  // NodeId's instance getter of the same name and does not resolve.
  if (raw is String) {
    return NodeId.fromNumeric(0, Namespace0Id.string.value);
  }
  if (raw is DateTime) return NodeId.datetime;
  return null;
}

/// The control port's listener, from the instant main holds the port.
///
/// The worker announces itself (and hands main its control port) BEFORE it
/// dials Postgres — deliberately, so a database outage cannot be mistaken for a
/// wedged spawn — which leaves a window where main can legitimately send
/// control messages the endpoint does not exist to answer yet. Dropping them
/// would make the handshake a promise the worker cannot keep: main would
/// believe a key is subscribed and the screen would never fill.
///
/// So subscribe/unsubscribe messages are queued and replayed in order the
/// moment the endpoint attaches.
///
/// **A write is NOT queued.** Replaying one after the stack finally comes up
/// would execute an operator's command minutes — or, with
/// `Database.connectWithRetry` riding out a real outage, hours — after main had
/// already resolved it unknown and moved on. That is a re-send nobody asked
/// for, and re-sending is the one thing this pipe may never do. A write that
/// arrives before the link exists is answered [relay.WriteUnknown] on the spot.
class PipeControlInbox {
  PipeControlInbox({SendPort? toMain}) : _toMain = toMain;

  final SendPort? _toMain;

  final List<Object?> _queued = <Object?>[];
  PipeWorkerEndpoint? _endpoint;

  /// Whether the endpoint has been attached — i.e. the acquisition stack is up.
  bool get isAttached => _endpoint != null;

  /// How many messages are waiting for the stack. Diagnostics only.
  int get queuedCount => _queued.length;

  /// One raw message off the control [ReceivePort].
  void receive(Object? message) {
    final endpoint = _endpoint;
    if (endpoint != null) {
      endpoint.handleControl(message);
      return;
    }
    if (message is PipeWriteRequest) {
      _refuse(message);
      return;
    }
    _queued.add(message);
  }

  /// Answers a write that arrived before there was a link to write to.
  ///
  /// `requestSent: false` is the literal truth — the acquisition stack does not
  /// exist yet — and it still classifies [relay.WriteUnknown], because from
  /// main's side "the deadline passed before the link answered at all" and "the
  /// request landed and the answer was lost" are not distinguishable and this
  /// side must not guess.
  void _refuse(PipeWriteRequest request) {
    final result = translateWriteAnswer(
      protocol: UpstreamProtocol.opcUa,
      cmd: request.id.toString(),
      answer: const WriteDeadlineExpired(requestSent: false),
    );
    _toMain?.send(
        PipeFrame(<Object?>[PipeWriteOutcome(request.id, result)], const {}));
  }

  /// The acquisition stack is up: hand everything queued to [endpoint], in the
  /// order main sent it.
  void attach(PipeWorkerEndpoint endpoint) {
    _endpoint = endpoint;
    final replay = List<Object?>.of(_queued);
    _queued.clear();
    for (final message in replay) {
      endpoint.handleControl(message);
    }
  }
}
