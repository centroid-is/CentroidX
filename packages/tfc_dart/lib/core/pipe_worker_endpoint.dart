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
import 'dart:isolate';

import 'package:logger/logger.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:open62541/open62541.dart';
import 'package:tfc_dart/core/opcua_value_translation.dart';
import 'package:tfc_dart/core/pipe_send_buffer.dart';
import 'package:tfc_dart/core/state_man.dart';
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
    if (_disposed) return;
    // The unsubscribe may have landed while the upstream call was in flight.
    // Attaching now would leave a stream nobody will ever cancel.
    if (!_subscribed.contains(key)) return;
    _streams[key]?.cancel();
    _streams[key] = stream.listen(
      (sample) => _onSample(key, sample),
      onError: (Object error) => _onStreamError(key, error),
      onDone: () => _onDone(key),
      cancelOnError: false,
    );
  }

  void _unsubscribe(String key) {
    _subscribed.remove(key);
    // Cancel the stream we own for this key. Synchronous dispatch: this can
    // never queue behind another key's hung subscribe.
    final stream = _streams.remove(key);
    stream?.cancel();
    _buffer.remove(key);
    _permanentError.remove(key);
    _disarmTickIfIdle();
  }

  void _onSample(String key, DynamicValue sample) {
    final value = translateOpcUaSample(
      sample,
      arrivedAt: _now(),
      onSourceTimeFallback: () => _sourceTimeFallbacks++,
    );
    // The key answered. Whatever permanent fault was last reported for it is
    // over, so the NEXT occurrence is a transition again and must speak.
    if (!value.quality.isError) _permanentError.remove(key);
    _buffer.putValue(key, value);
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

  void _onDone(String key) {
    _streams.remove(key);
    // Cancel the pending telemetry FIRST: a reading for a key that no longer
    // exists is worse than no reading, because it is indistinguishable from a
    // live one. `remove` never touches the priority lane, so the announcement
    // below cannot be lost to it.
    _buffer.remove(key);
    _permanentError.remove(key);
    _logger.w('pipe endpoint: "$key" was retired by the upstream');
    _emitPriority(PipeKeyRetired(key));
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
  }
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
class PipeControlInbox {
  PipeControlInbox({SendPort? toMain}) : _toMain = toMain;

  // ignore: unused_field
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
    _queued.add(message);
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
