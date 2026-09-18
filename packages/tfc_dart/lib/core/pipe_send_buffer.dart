/// The acquisition pipe's conflation core: **conflate, never queue**.
///
/// One worker isolate accumulates notifications between drain ticks and hands
/// main *one* frame per tick. A key that changed two hundred times since the
/// last tick crosses the port once, carrying its latest reading; a key that
/// changed once crosses once. The number of messages a tick costs is therefore
/// bounded by the number of subscribed keys and not by how fast the plant
/// moves — which is the whole finding behind PIPE-11. The measured 24 s
/// staleness this replaces was queue depth: one message per notification
/// (`data_acquisition_isolate.dart` style) turns a busy PLC into a backlog that
/// main walks through minutes late, showing readings that are stale but
/// perfectly plausible.
///
/// **Two lanes, and the second one is the point.** Conflation is only safe for
/// telemetry. An error, a worker-death notice, a ready/epoch bump — those are
/// news *about the pipe*, and a degraded link must still be able to say that it
/// is degraded. They go on the priority lane: appended verbatim, drained first,
/// never conflated, never dropped. If an error could be absorbed by the
/// latest-per-key map (a later value for the same key quietly winning), the
/// operator would see a fresh-looking number with no indication the link had
/// faulted in between — the exact silent-fault mode this project exists to
/// remove.
///
/// **Pure state machine — no clock, no I/O.** Timestamps arrive as data
/// (`sourceTime` on the value the caller puts), the tick is the caller's timer,
/// and nothing here touches a socket or a database. Mirrors
/// `tfc_relay_protocol`'s `ConflatingSendBuffer` (whose library doc says the
/// same in the same words) so that both are deterministic under test with no
/// fake time.
///
/// **What this deliberately is NOT** (CONTEXT §5). It is keyed by `String`, not
/// by an int handle: there is no handle table to keep in sync across an isolate
/// port, and the pipe is process-internal so nothing is paying for compactness
/// on a wire. It has no byte accounting, no `maxPending`/`peakThreshold`, and
/// no disconnect verdict — those exist on the WebSocket buffer because a remote
/// client can silently grow the server's heap, and an isolate port is not that
/// boundary. And it has no per-subscription namespacing: one worker owns one
/// flat key space.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// One drained tick.
///
/// [priority] first (never conflated, never dropped), then the latest reading
/// per key. Both collections are the buffer's own state handed over — the
/// buffer is empty once this exists, so nothing can mutate them behind the
/// caller's back.
final class PipeFrame {
  /// Errors, worker-death notices, ready/epoch bumps, write outcomes: whatever
  /// the caller put, in the order it was put, un-conflated.
  final List<Object?> priority;

  /// Latest reading per key since the previous drain. Values are the pure-Dart
  /// protocol type — the C-coupled `open62541` `DynamicValue` stops at the
  /// worker edge and never enters this buffer.
  final Map<String, relay.DynamicValue> values;

  /// Which of [values]' keys carry a `sourceTime` the **backend** put there,
  /// not the source.
  ///
  /// `relay.DynamicValue.sourceTime` is non-null for every one of them —
  /// `translateOpcUaSample` substitutes its arrival instant for an unstamped
  /// sample and must keep doing so, because that field also becomes `t:` on the
  /// wire and feeds `RemoteStateMan`'s superseded-readback guard. So the
  /// instant is present and useful, and the *claim* about where it came from
  /// lives here instead of being guessed at the far end.
  ///
  /// **Null means the frame states nothing, and a frame that states nothing is
  /// read as all-substituted.** That is the safe direction and it is not a
  /// formality: the alternative default would have an unaware producer silently
  /// asserting plant provenance for every value it emits. Nothing on the
  /// production path relies on it — [PipeSendBuffer.drain] always supplies a
  /// real set, and [PipeSendBuffer.putValue] cannot be called without stating
  /// the flag — so the null case is for frames minted directly, which are
  /// either value-less (a write outcome) or a test's.
  final Set<String>? substitutedStamps;

  const PipeFrame(this.priority, this.values, [this.substitutedStamps]);

  /// True when this tick has nothing to send. A worker that drains an empty
  /// frame sends nothing at all, which is what makes an idle pipe silent
  /// rather than a heartbeat generator.
  bool get isEmpty => priority.isEmpty && values.isEmpty;
}

/// Accumulates a tick's worth of pipe traffic into two lanes.
///
/// See the library doc for why there are exactly two and why neither is
/// bounded by bytes.
final class PipeSendBuffer {
  final _priority = <Object?>[];
  final _values = <String, relay.DynamicValue>{};

  /// Keys in [_values] whose `sourceTime` the backend supplied. Conflated
  /// alongside the value it describes — see [PipeFrame.substitutedStamps].
  final _substituted = <String>{};

  /// How many messages the next [drain] would produce. Diagnostics only — no
  /// policy reads this (there is no disconnect verdict here to feed).
  int get pendingCount => _priority.length + _values.length;

  /// Telemetry: last value wins for [key].
  ///
  /// A whole sample supersedes everything pending for that key — an earlier
  /// value, a pending quality-only transition (the new sample carries its own
  /// quality), and a pending removal (the key came back inside the same tick).
  ///
  /// [sourceTimeSubstituted] says whether `value.sourceTime` is the source's
  /// own instant or one this backend put there. It is **required** rather than
  /// defaulted on purpose: a caller that forgets it would be asserting plant
  /// provenance by omission, which is the exact failure this parameter exists
  /// to end. It conflates with the value — the latest put wins for both, so a
  /// key that was substituted and is then genuinely stamped inside one tick
  /// does not stay flagged.
  void putValue(
    String key,
    relay.DynamicValue value, {
    required bool sourceTimeSubstituted,
  }) {
    _values[key] = value;
    if (sourceTimeSubstituted) {
      _substituted.add(key);
    } else {
      _substituted.remove(key);
    }
  }

  /// A quality transition with no new reading behind it.
  ///
  /// **Composes rather than replaces when the pending value is already flagged
  /// [relay.Quality.badNonFinite].** That band is a property of the *value* —
  /// the pending payload was sanitized to `null` when it was put — and a
  /// quality-only transition is by definition not news about the value. Letting
  /// a good quality win outright would land an open-circuit 4–20 mA reading on
  /// the operator's screen as a blank box under good quality: it would look
  /// like an unbound tag rather than a fault. Straight from
  /// `ConflatingSendBuffer.putQuality`, for the same reason.
  ///
  /// With **no** pending value for the key, the transition crosses as a
  /// null-payload sample carrying that quality. The value lane speaks whole
  /// samples (there is no `lastKnown` here to compose against — this is a pure
  /// state machine with no memory across drains), and dropping the transition
  /// to preserve a payload the buffer does not hold would be the silent fault.
  /// In the pipe the caller for this path is a bad/uncertain transition, where
  /// the translated sample carries `value: null` anyway.
  void putQuality(String key, relay.Quality quality) {
    final pending = _values[key];
    if (pending == null) {
      // The buffer mints this one itself, so nobody sourced it. It carries no
      // `sourceTime` at all today, but the flag is set regardless: the claim
      // "the source said when" must never be made by omission, and a later
      // change that gives this sample an instant must not silently start
      // making it.
      _values[key] = relay.DynamicValue(value: null, quality: quality);
      _substituted.add(key);
      return;
    }
    final composed = pending.quality == relay.Quality.badNonFinite
        ? relay.Quality.worst([quality, relay.Quality.badNonFinite])
        : quality;
    _values[key] = relay.DynamicValue(
      value: pending.value,
      quality: composed,
      sourceTime: pending.sourceTime,
      typeId: pending.typeId,
      sourceTypeId: pending.sourceTypeId,
      displayName: pending.displayName,
      description: pending.description,
      enumFields: pending.enumFields,
    );
  }

  /// The key is retired — the subscription's `onDone`, a deleted node.
  ///
  /// Supersedes everything pending for it: sending a reading for a key that no
  /// longer exists is worse than sending nothing, because it is indistinguish-
  /// able from a live one. The retirement itself is announced by the caller on
  /// the priority lane (silence is not acceptable); this only cancels the
  /// pending telemetry.
  void remove(String key) {
    _values.remove(key);
    // The provenance describes a value that is no longer going anywhere. Left
    // behind it would name a key the frame does not carry.
    _substituted.remove(key);
  }

  /// Errors, worker death, ready/epoch bumps, write outcomes: appended
  /// verbatim, drained ahead of telemetry, **never** conflated against the
  /// value lane.
  ///
  /// Unlike the WebSocket buffer this mirrors, there is no byte ceiling and so
  /// no `ResultTooLarge` refusal: the peer is an isolate in the same process,
  /// not a remote client that can be made to grow the heap.
  void putPriority(Object? message) {
    _priority.add(message);
  }

  /// Drains everything pending into one frame. The buffer is empty afterwards
  /// — recovery never has a backlog to flush.
  PipeFrame drain() {
    final priority = List<Object?>.of(_priority);
    _priority.clear();
    final values = Map<String, relay.DynamicValue>.of(_values);
    _values.clear();
    final substituted = Set<String>.of(_substituted);
    _substituted.clear();
    return PipeFrame(priority, values, substituted);
  }
}
