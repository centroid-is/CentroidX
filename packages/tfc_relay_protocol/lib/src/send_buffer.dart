/// Per-client bounded, conflating send buffer — the fault-tolerance core
/// from relay-comm-design.md §5 (notes §7.6), with the disconnect policies
/// Home Assistant's websocket_api proved in production
/// (pending-overflow: immediate; sustained-peak: after a grace window).
///
/// Pure state machine: no I/O, no clock — callers pass timestamps, so every
/// behavior is deterministic under test.
library;

import 'methods.dart';
import 'quality.dart';
import 'result_too_large.dart';
import 'wire_value.dart';

sealed class BufferVerdict {
  const BufferVerdict();
}

final class BufferOk extends BufferVerdict {
  const BufferOk();
}

/// The connection should be closed: converting silent server-heap growth
/// (dart:io WebSocket has no bufferedAmount and buffers unboundedly) into a
/// visible reconnect.
final class BufferDisconnect extends BufferVerdict {
  final int closeCode;
  final String reason;
  const BufferDisconnect(this.closeCode, this.reason);
}

/// One drained frame: priority messages first (never conflated, never
/// dropped), then per-subscription telemetry.
final class DrainedFrame {
  final List<Object?> priority;
  final Map<String, PendingSub> subs;
  const DrainedFrame(this.priority, this.subs);

  bool get isEmpty => priority.isEmpty && subs.isEmpty;
}

final class PendingSub {
  final Map<int, WireValue> changes;
  final Map<int, Quality> qualities;
  final List<int> removed;
  const PendingSub(this.changes, this.qualities, this.removed);
}

final class _SubState {
  final changes = <int, WireValue>{};
  final qualities = <int, Quality>{};
  final removed = <int>{};

  int get pendingCount => changes.length + qualities.length + removed.length;
  bool get isEmpty => pendingCount == 0;
}

/// What one subscription has been **sent** against what it has **acknowledged**
/// — the pair option (c) of `16-02-DECISION.md` puts on the wire.
///
/// Deliberately not part of [_SubState]: that is cleared by every [drain], and
/// a delivery gap that reset every tick would measure exactly the same nothing
/// the production counters already measure.
final class _Delivery {
  /// The highest seq this server has actually emitted for the subscription.
  /// **The clamp's source of truth** (T-16-02a): a client cannot acknowledge
  /// what was never sent.
  int sentSeq = 0;

  /// The highest seq the client has claimed to have applied, clamped and
  /// monotonic. Null until it claims anything at all.
  int? ackedSeq;

  /// When the gap first went over the ceiling, or null while it is under —
  /// the same shape and the same reset rule as [ConflatingSendBuffer._peakSinceMs].
  int? gapSinceMs;
}

final class ConflatingSendBuffer {
  /// Hard ceiling on pending entries; exceeding it is an immediate
  /// disconnect verdict (HA: MAX_PENDING_MSG).
  final int maxPending;

  /// Soft ceiling on **production**: how many entries this server may pile up
  /// for one client in one tick, sustained over [peakWindowMs].
  ///
  /// **It is not the slow-consumer defence and it never was** — see [poll].
  /// Null, its default since 16-08, means no production ceiling at all.
  final int? peakThreshold;
  final int peakWindowMs;

  /// How far behind a subscription's acknowledged sequence may fall before the
  /// grace window opens, or null to disable the delivery verdict entirely.
  ///
  /// **128, from `16-02-DECISION.md` §5.3, and the number has a derivation.**
  /// Across seven healthy runs — including one over a 1000 ms WAN link — the
  /// largest gap observed was **24**, and a real ack rides a heartbeat, so the
  /// server's copy is stale by up to one beat: at a 2 s beat and a 50 ms tick
  /// that is a constant +40 frames, giving an adjusted healthy ceiling of
  /// **64**. Unhealthy links floored at **90** and grew without bound at 15–20
  /// frames/s. 128 is 2× the healthy ceiling and still an order of magnitude
  /// below where a stuck link sits ten seconds in.
  ///
  /// **Magnitude is the weaker half of the separation and it is worth knowing
  /// which half you are relying on.** A latent link's gap *plateaus* at
  /// `latency ÷ tick` — it shifts up and its slope stays zero. Only a link
  /// that cannot carry the production rate has a slope at all, which is why
  /// [ackGapWindowMs] rather than this number is what actually distinguishes
  /// slow from stuck.
  final int? ackGapThreshold;

  /// How long the gap may stay over [ackGapThreshold] continuously before the
  /// session is evicted.
  ///
  /// Defaults to [peakWindowMs] rather than to a constant of its own: the two
  /// answer the same question — *is this a burst or a stall?* — and a
  /// deployment that has already tuned one has said what it thinks the answer
  /// is. 15–20 frames/s of unbounded growth cannot be transient over ten
  /// seconds; a page change or a GC pause can.
  final int ackGapWindowMs;

  /// Ceiling on **bytes** held in the priority lane, or null for none.
  ///
  /// [maxPending] counts entries, and entries say nothing about size
  /// (03-REVIEW WR-04). The amplifier that makes that matter is json_rpc_2's
  /// own parse-error responder: `respondToFormatExceptions`
  /// (`json_rpc_2-4.1.0/lib/src/utils.dart:60-70`) answers with
  /// `exception.serialize(formatException.source)`, and `source` for a failed
  /// `jsonDecode` is the *entire offending text*. One megabyte-scale garbage
  /// frame therefore becomes one megabyte-scale error response appended
  /// verbatim into this lane, held until the next tick — and 4096 of those is
  /// a heap, not a queue.
  ///
  /// **Only the priority lane is counted**, deliberately. Telemetry is
  /// conflated, so it is bounded by the number of watched handles no matter
  /// how fast the plant moves, and measuring a `WireValue`'s size would mean
  /// encoding it on the hot path to find out. The priority lane is the one
  /// that appends whatever it is handed.
  final int? maxPendingBytes;

  final _priority = <Object?>[];
  final _subs = <String, _SubState>{};
  final _delivery = <String, _Delivery>{};
  int? _peakSinceMs;
  int _priorityBytes = 0;

  ConflatingSendBuffer({
    required this.maxPending,
    this.peakThreshold,
    this.peakWindowMs = 10_000,
    this.maxPendingBytes,
    this.ackGapThreshold = 128,
    int? ackGapWindowMs,
  }) : ackGapWindowMs = ackGapWindowMs ?? peakWindowMs;

  int get pendingCount =>
      _priority.length +
      _subs.values.fold(0, (n, s) => n + s.pendingCount);

  /// Bytes held in the priority lane, as counted by [putPriority].
  int get pendingBytes => _priorityBytes;

  /// What one priority entry is charged.
  ///
  /// An already-encoded frame is charged its own length — the exact number,
  /// and the only shape big enough to matter. A structured message is charged
  /// a flat nominal cost rather than encoded to find out: those are server-
  /// built announcements (`resync`, `status`) of a known small shape, and
  /// paying an encode per put to measure them would put the cost on the path
  /// this whole class exists to keep cheap.
  static const nominalMessageBytes = 256;

  static int _cost(Object? message) =>
      message is String ? message.length : nominalMessageBytes;

  _SubState _sub(String sub) => _subs.putIfAbsent(sub, _SubState.new);

  /// Telemetry: last value wins per (sub, handle). A pending removal of the
  /// same handle is superseded.
  void putValue(String sub, int handle, WireValue value) {
    final s = _sub(sub);
    s.removed.remove(handle);
    s.qualities.remove(handle); // the value carries its own quality
    s.changes[handle] = value;
  }

  /// Quality-only transition (value unchanged upstream).
  ///
  /// Composes rather than replaces when the pending value is already flagged
  /// non-finite: that band is a property of the *value*, the pending value was
  /// sanitized to null when it was put, and a quality-only transition is by
  /// definition not news about the value. Letting it win outright would land
  /// an open-circuit 4–20 mA reading at the client as `null` under good
  /// quality — a blank box that looks like an unbound tag rather than a fault.
  void putQuality(String sub, int handle, Quality quality) {
    final s = _sub(sub);
    final pendingValue = s.changes[handle];
    if (pendingValue != null) {
      final composed = pendingValue.q == Quality.badNonFinite
          ? Quality.worst([quality, Quality.badNonFinite])
          : quality;
      s.changes[handle] =
          WireValue.of(pendingValue.v, quality: composed, t: pendingValue.t);
    } else {
      s.qualities[handle] = quality;
    }
  }

  /// The handle is gone from availability; supersedes any pending state.
  void remove(String sub, int handle) {
    final s = _sub(sub);
    s.changes.remove(handle);
    s.qualities.remove(handle);
    s.removed.add(handle);
  }

  /// Records that the server emitted [seq] for [sub] — the numerator of the
  /// delivery gap, and the ceiling every ack is clamped to.
  ///
  /// Called by the tick engine at the one place a sequence is minted, so the
  /// two halves of the gap can never be read from different generations of the
  /// same counter.
  void noteSent(String sub, int seq) {
    final d = _delivery.putIfAbsent(sub, _Delivery.new);
    if (seq > d.sentSeq) d.sentSeq = seq;
  }

  /// Records what the client claims to have applied for [sub].
  ///
  /// **This is a claim by the party being judged, and the four rules below are
  /// the whole of how far it is trusted** (`16-02-DECISION.md` §5.2).
  ///
  ///  1. **Clamped to what was actually sent** (T-16-02a). Without this, a
  ///     client that has stopped reading can answer every beat with a sequence
  ///     beyond anything this server produced, hold the gap permanently
  ///     negative, and grow this isolate's heap for ever — and the isolate
  ///     serves every screen in the plant. The clamp makes eviction something
  ///     the client cannot veto. **Under-reporting is deliberately left
  ///     alone**: a client that evicts itself is harmless and pays for it with
  ///     one snapshot.
  ///  2. **Never decreases.** Beats reorder on the wire and a client can
  ///     restart its own counter; neither is evidence a frame was un-applied,
  ///     and treating a late beat as a regression would open a window against a
  ///     healthy panel.
  ///  3. **Scoped to subscriptions this session actually holds** — an ack
  ///     naming anything else is discarded without creating an entry, because a
  ///     map keyed by whatever a peer puts in an ack is a peer-controlled
  ///     allocation on a path that runs every heartbeat.
  ///  4. **Reset on re-establishment**, via [dropSub]: a generation's acks say
  ///     nothing about its successor.
  void recordAck(String sub, int reported) {
    final d = _delivery[sub];
    if (d == null) return; // rule 3
    final clamped = reported > d.sentSeq ? d.sentSeq : reported; // rule 1
    final previous = d.ackedSeq;
    if (previous != null && clamped <= previous) return; // rule 2
    d.ackedSeq = clamped;
    // **[gapSinceMs] is deliberately not touched here.** An earlier draft also
    // closed the window on the spot when a moving ack brought the gap back
    // under the ceiling — which was correct, and redundant, and therefore
    // worse than useless: it made the recovery branch in [_deliveryVerdict]
    // unreachable, so deleting that branch left the whole suite green. The gap
    // shrinks only when an ack arrives and grows only when a frame is sent, so
    // one reset site is enough and the verdict is the right one to own it. It
    // mirrors `_peakSinceMs` exactly, which is what §5.2 asks for.
  }

  /// How many frames [sub] is behind, or null when it holds no subscription of
  /// that name or the client has never acknowledged anything for it.
  ///
  /// Read by tests and by the health overlay. Null is a third answer and not a
  /// zero: "this client has made no claim" and "this client is exactly caught
  /// up" call for opposite responses.
  int? deliveryGapOf(String sub) {
    final d = _delivery[sub];
    final acked = d?.ackedSeq;
    if (d == null || acked == null) return null;
    return d.sentSeq - acked;
  }

  /// Forgets everything pending for [sub].
  ///
  /// For a subscription being **re-established** under the same name: the
  /// snapshot the client is about to be handed was read from the source a
  /// moment ago, and anything still in this lane was put there before it. Left
  /// alone, that older reading is emitted on the next tick with the new
  /// generation and a sequence the client accepts, so the mimic goes backwards
  /// under good quality — which is the same failure the generation exists to
  /// stop, arriving by a different door.
  ///
  /// The delivery record goes with it (§5.2 rule 4). A re-established
  /// subscription starts its sequence afresh, so an `ackedSeq` carried across
  /// the boundary would be a number from the previous life measured against a
  /// counter from this one — either an instant eviction or a permanent
  /// immunity, depending only on which way the two counters happened to sit.
  void dropSub(String sub) {
    _subs.remove(sub);
    _delivery.remove(sub);
  }

  /// RPC responses, write acks, status, ticks: appended verbatim, flushed
  /// ahead of telemetry, never conflated — a degraded link must still
  /// deliver the news that it is degraded.
  ///
  /// ## One entry may not exceed the whole lane (10-REVIEW WR-05)
  ///
  /// Until this check, `putPriority` accepted anything and only [poll]
  /// measured — one tick later, by which time the entry is already held. That
  /// is a gap rather than a delay, because the entry does not have to survive
  /// until the next tick to do harm: `closeSocket` calls `flushPriority`,
  /// which drains and **writes the whole lane out before the close code**, so
  /// an entry too big for the lane is written to the socket on the way to the
  /// eviction it caused.
  ///
  /// The condition is deliberately `cost > ceiling` and not
  /// `_priorityBytes + cost > ceiling`. This is an invariant about a single
  /// entry — one that can never be held no matter how empty the lane is — and
  /// not a second backpressure policy. Accumulation stays [poll]'s question,
  /// which is where the grace window and the disconnect verdict live; a door
  /// that refused on accumulation would evict a well-behaved client for
  /// arriving second.
  ///
  /// **Throwing is the honest answer here and it has a cost.** The caller is
  /// `SessionSink.add`, which is json_rpc_2's write half, so there is no
  /// request id in scope to refuse *to* — see `SessionSink.add` for what it
  /// does with this and what the caller sees. That is why every handler that
  /// can build a large answer is bounded by `data_handlers.dart`'s `_sized`
  /// first, where the refusal can name the request: this is the backstop
  /// behind those, not a substitute for them.
  void putPriority(Object? message) {
    final cost = _cost(message);
    final ceiling = maxPendingBytes;
    if (ceiling != null && cost > ceiling) {
      throw ResultTooLarge.bytes(
        limit: ceiling,
        measured: cost,
        detail: 'one response cannot exceed the whole priority lane, however '
            'empty the lane is. Nothing was queued, so the session is not '
            'evicted for it',
        suggestion: 'a narrower request, or the bounded form of this method',
      );
    }
    _priority.add(message);
    _priorityBytes += cost;
  }

  /// Disconnect policy. Call once per tick with a monotonic timestamp,
  /// **before** [drain].
  ///
  /// [poll] — not [drain] — is the only thing that decides a client has
  /// recovered, and it decides it on the count it measured before the drain
  /// emptied the buffer. See [drain] for why that used to be untrue.
  ///
  /// ## Four verdicts, and what each of them actually measures
  ///
  /// The order below is the order they are checked in, and it is not
  /// arbitrary:
  ///
  ///  1. **[maxPendingBytes]** and 2. **[maxPending]** — hard memory ceilings,
  ///     first, because they are the only two verdicts that are about this
  ///     process surviving. They stay hard whatever any client says about
  ///     itself (T-16-02b), which is what stops the delivery verdict below
  ///     from being bought by removing backpressure.
  ///  3. **[ackGapThreshold]** — *delivery*. How far behind the client says it
  ///     is, sustained over [ackGapWindowMs]. This is the slow-consumer
  ///     defence, per `16-02-DECISION.md`.
  ///  4. **[peakThreshold]** — *production*, and nothing else. Null by default
  ///     since 16-08.
  ///
  /// **Why (4) is no longer the slow-consumer defence** (03-REVIEW WR-11,
  /// settled by `16-02-DECISION.md` §2.3). [drain] runs unconditionally every
  /// tick and `ws.sink.add` never blocks, so the count (4) reads is *how much
  /// this server produced for one client during one tick* — never how far
  /// behind that client is. 16-02 measured both ends of what that costs: a
  /// comprehensively stuck panel produced **41 pending entries a tick** against
  /// a threshold of 1024, so the defence was watching a number two orders of
  /// magnitude from tripping on a session that had stopped reading entirely;
  /// and a **healthy** 1100-key page was evicted after 10.1 s and told, in the
  /// close reason, that it could not keep up. Two symmetric failures, and a
  /// fix that closed one by opening the other would not have been a fix.
  BufferVerdict poll(int nowMs) {
    final byteCeiling = maxPendingBytes;
    if (byteCeiling != null && _priorityBytes > byteCeiling) {
      return BufferDisconnect(
          CloseCodes.backpressureOverrun,
          'pending priority bytes ($_priorityBytes) exceeded the byte limit '
          '($byteCeiling)');
    }
    final pending = pendingCount;
    if (pending > maxPending) {
      return BufferDisconnect(CloseCodes.backpressureOverrun,
          'pending messages ($pending) exceeded hard limit ($maxPending)');
    }
    final stalled = _deliveryVerdict(nowMs);
    if (stalled != null) return stalled;
    final threshold = peakThreshold;
    if (threshold != null) {
      if (pending > threshold) {
        _peakSinceMs ??= nowMs;
        if (nowMs - _peakSinceMs! > peakWindowMs) {
          // **The string says production, because production is what was
          // measured.** It used to say "client unable to keep up", which was
          // the finding's second half in one sentence: a verdict computed from
          // this server's own output, reported to an operator as a statement
          // about a panel (T-16-08e).
          return BufferDisconnect(CloseCodes.backpressureOverrun,
              'sustained production: > $threshold pending per tick for '
              '${peakWindowMs}ms');
        }
      } else {
        _peakSinceMs = null;
      }
    }
    return const BufferOk();
  }

  /// The delivery verdict: a subscription whose acknowledged sequence has
  /// stayed more than [ackGapThreshold] behind for longer than
  /// [ackGapWindowMs], or null when there is none.
  ///
  /// **A client that has never acknowledged anything is not judged here at
  /// all.** The gateway and the panels do not ship together, so a `ping`
  /// carrying no ack stays valid for ever and such a session is governed by
  /// the hard ceilings and the heartbeat reaper exactly as it was before. The
  /// alternative — treating silence as a stall — is a fleet-wide outage on the
  /// morning of an upgrade.
  BufferDisconnect? _deliveryVerdict(int nowMs) {
    final ceiling = ackGapThreshold;
    if (ceiling == null) return null;
    for (final entry in _delivery.entries) {
      final d = entry.value;
      final acked = d.ackedSeq;
      if (acked == null) continue;
      final gap = d.sentSeq - acked;
      if (gap <= ceiling) {
        // Recovery, and it is load-bearing. `send_buffer.dart`'s own peak
        // window already records what happens without one: a window that
        // accumulates and never resets evicts every panel eventually.
        d.gapSinceMs = null;
        continue;
      }
      final since = d.gapSinceMs ??= nowMs;
      if (nowMs - since > ackGapWindowMs) {
        // Names the subscription, the distance and both sequences: an operator
        // reading the close ledger learns which page stalled and how far
        // behind it was without reading this source. 4004 because the soft and
        // hard verdicts are the same failure at different speeds, and a client
        // should not have to learn two codes to handle one condition.
        return BufferDisconnect(
            CloseCodes.backpressureOverrun,
            'delivery stalled: "${entry.key}" is $gap frames behind '
            '(applied $acked of ${d.sentSeq}) for ${ackGapWindowMs}ms');
      }
    }
    return null;
  }

  /// Drains everything pending. The buffer is empty afterwards — recovery
  /// never has a backlog to flush.
  ///
  /// **Draining is not evidence that the client caught up** (03-REVIEW WR-02).
  /// This used to clear `_peakSinceMs` whenever it drained anything, and the
  /// tick engine drains every tick — so [poll] could only ever see
  /// `_peakSinceMs == null` or `== nowMs`, the window never accumulated, and
  /// the soft verdict was unreachable in production. Only `maxPending` bit.
  /// On `dart:io` WebSockets `sink.add` never blocks and tells us nothing, so
  /// a completed drain says only that the frames left this process. What
  /// [poll] measures across ticks is therefore the *production* rate for one
  /// client staying above the soft ceiling continuously — see
  /// `server_config.dart`'s `peakThreshold`, which says so in the same words a
  /// reader will find at the other end.
  ///
  /// **The delivery record deliberately does not drain** (16-08). `_subs` is
  /// cleared here; `_delivery` is not, and that asymmetry is the whole reason
  /// the delivery verdict can see something the production ones cannot. A gap
  /// that reset every tick would measure the same nothing this paragraph is
  /// about. The delivery record is cleared by [dropSub] instead — on
  /// unsubscribe and on re-establishment — because those are the two events
  /// after which an old acknowledged sequence means nothing.
  DrainedFrame drain() {
    final priority = List<Object?>.of(_priority);
    _priority.clear();
    _priorityBytes = 0;

    final subs = <String, PendingSub>{};
    _subs.forEach((name, s) {
      if (s.isEmpty) return;
      subs[name] = PendingSub(
        Map.of(s.changes),
        Map.of(s.qualities),
        List.of(s.removed),
      );
    });
    _subs.clear();
    return DrainedFrame(priority, subs);
  }
}
