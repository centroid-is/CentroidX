/// One direction of one proxied connection: a bounded queue that gates every
/// write on the previous `flush()`.
///
/// **The measurement this file exists for.** RESEARCH Finding 7 ran a firehose
/// through a proxy into a consumer whose subscription was paused. The obvious
/// implementation — `destination.add(data)` and move on, which is what
/// `tfc_dart/test/proxy.dart:121-143` does in both directions — took the host
/// from 163 MB to **4463 MB** of RSS in four seconds. `dart:io`'s `Socket`
/// sink buffers without limit and exposes no `bufferedAmount`, so nothing in
/// the proxy can even notice it is happening; the same hazard the repo's
/// CLAUDE.md already flags for WebSocket. Gating on `flush()` with a 1 MiB
/// high-water and a 256 KiB low-water measured 164 → 181 MB at four seconds
/// and 188 → 193 MB at twelve, with the internal queue peaking at 1.26 and
/// 1.29 MB.
///
/// **The bound is high-water plus one socket buffer, not high-water**, and
/// "one socket buffer" is not a constant. `dart:io` reads a POSIX socket with
/// `available()`, so a single chunk is however much the kernel let that
/// connection's receive buffer grow: measured at 1.59 MB on macOS loopback
/// with the default 408 KB buffer, and at 5.57 MB with `SO_RCVBUF` raised to
/// 4 MiB. Linux autotunes to `tcp_rmem`'s maximum — 6 MiB on a GitHub runner,
/// half of it usable payload — and Windows reads a fixed 64 KiB. So an
/// assertion written at any constant is a reading of one machine's kernel: the
/// 4 MiB one this file used to recommend passed on macOS and failed on ubuntu
/// at 4.21–4.33 MB. Assert [peakPendingBytes] against
/// `highWaterBytes + largestChunkBytes` instead, which is the invariant the
/// code enforces rather than a number somebody observed.
///
/// **Why this is the phase keystone.** Latency, throttle, blackhole and
/// backpressure are all decisions about *when and whether* a queued chunk is
/// forwarded, so they compose on one queue per direction rather than
/// interacting through three. RESEARCH Risk 2: building the modes first makes
/// the bounded-memory and socket-leak criteria fail late, for a reason that
/// looks like a mode bug.
///
/// **Deliberate divergence from the bounded-policy analog.**
/// `tfc_relay_protocol/lib/src/send_buffer.dart:6-7` opens with "pure state
/// machine: no I/O, no clock — callers pass timestamps". This file is the
/// opposite by mandate: it holds real sockets and will hold real timers,
/// because CONTEXT restricts injected clocks to pure state machines, and a
/// backpressure gate driven by a fake clock is exactly the machinery that
/// stops being tested. What is copied from that analog is the *shape* of the
/// policy — ceilings declared as named fields with the reason in the doc, not
/// magic numbers buried in a method. Do not "fix" this file toward its analog.
///
/// The line never destroys the sockets it is given. Lifetime belongs to the
/// pair that opened them (`fault_proxy.dart`), because both directions share
/// them and a line that closed its destination would cut the other direction
/// out from under its partner.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Pending bytes at which the line stops reading from its source.
///
/// 1 MiB, the value RESEARCH Finding 7 measured. Big enough that ordinary
/// bursts never touch it, small enough that a stalled consumer is caught
/// within a few chunks.
const defaultHighWaterBytes = 1024 * 1024;

/// Pending bytes at which the line starts reading again.
///
/// 256 KiB — a quarter of [defaultHighWaterBytes]. The gap is hysteresis: a
/// low-water equal to the high-water pauses and resumes on every chunk, which
/// costs a syscall pair per chunk and makes the pause events useless as a
/// backpressure signal.
const defaultLowWaterBytes = 256 * 1024;

/// How many slices of its budget a throttled line hands out per second.
///
/// Fifty, so a slice is 20 ms of traffic: 2500 bytes at 1 Mbit/s, 250 at
/// 100 kbit/s. The number trades two failures against each other. Slices too
/// small mean a write and a `flush()` per few bytes, where the syscalls cost
/// more than the traffic and the timer's own resolution — about a millisecond
/// — becomes most of the interval. Slices too large mean the rate is only
/// correct when averaged over something longer than the window, and Finding 5
/// measures over three seconds.
///
/// Accuracy does not depend on the timer being punctual. Tokens accrue from
/// the clock, not from the schedule, so a slice that fires late finds more
/// budget waiting and the next ones go out back to back until the arrears are
/// paid.
const _slicesPerSecond = 50;

/// The smallest slice a throttled line will wait for.
///
/// Below this the write is mostly syscall. At very low rates it makes the
/// slice interval longer rather than the rate wrong.
const _minimumSliceBytes = 64;

/// The largest slice a throttled line hands out at once.
///
/// A fast throttle should not turn into "one enormous write per second",
/// which is a burst with an average rather than a rate.
const _maximumSliceBytes = 64 * 1024;

/// One queued chunk and the earliest moment it may be written.
///
/// [releaseAtMicros] is a reading of the owning line's monotonic clock, and
/// zero means "already due": with no delay configured the comparison is
/// against a deadline in the past, so the pump never awaits and the write path
/// is exactly the flush-gated one that was measured before latency existed.
typedef _Queued = ({List<int> bytes, int releaseAtMicros});

/// A flush-gated, bounded, one-directional byte pipe.
final class DelayLine {
  DelayLine({
    required Socket destination,
    this.highWaterBytes = defaultHighWaterBytes,
    this.lowWaterBytes = defaultLowWaterBytes,
  })  : assert(lowWaterBytes <= highWaterBytes,
            'the low-water mark must not sit above the high-water mark, or '
            'the line pauses and immediately resumes for ever'),
        _destination = destination;

  /// Pending bytes at which this line pauses its source subscription.
  final int highWaterBytes;

  /// Pending bytes at which this line resumes its source subscription.
  final int lowWaterBytes;

  final Socket _destination;
  final Queue<_Queued> _pending = Queue<_Queued>();
  final StreamController<bool> _pauseChanges = StreamController<bool>.broadcast();
  final Completer<void> _finished = Completer<void>();

  /// The line's own monotonic clock, for release deadlines.
  ///
  /// A `Stopwatch` rather than `DateTime.now()`: release times are compared
  /// across an await, and a wall clock that steps — NTP, a suspended laptop —
  /// would release a chunk early or hold it for the length of the step. The
  /// deadline is an elapsed-microsecond reading, so nothing outside this
  /// object can move it.
  final Stopwatch _clock = Stopwatch()..start();

  StreamSubscription<List<int>>? _source;
  int _pendingBytes = 0;
  int _peakPendingBytes = 0;
  int _largestChunkBytes = 0;

  /// Bytes of the head chunk already written.
  ///
  /// Non-zero only under a throttle, which hands out slices rather than whole
  /// chunks. The remainder stays at the head of the same queue instead of
  /// moving to a holding area of its own — one queue is what keeps the memory
  /// bound and the ordering guarantee the same statement they were before.
  int _headWritten = 0;
  bool _sourceDone = false;
  bool _writing = false;
  bool _paused = false;
  bool _closed = false;

  // ---------------------------------------------------------------------
  // Mode seats.
  //
  // Seats the mode plans fill one at a time. The queue that enforces the
  // memory bound and the queue the modes act on have to be the same object,
  // or the bound proved here is not the bound they inherit.
  //
  // These are not silent no-ops in disguise. The only public way to reach
  // them is a `FaultProxy` lever, and every lever whose mode has not landed
  // throws `UnimplementedError` naming its plan rather than setting one of
  // these and returning.
  // ---------------------------------------------------------------------

  /// Per-chunk delay before a queued chunk is forwarded. Null means no delay.
  ///
  /// The seat `latency` and `jitter` take (plan 02-04). A function rather than
  /// a `Duration` because jitter is redrawn per chunk, and live-mutable
  /// because a scenario that degrades a link at minute three sets it on a
  /// connection that is already open.
  ///
  /// **Drawn at arrival, honoured at the head of the queue.** The draw happens
  /// in [_onData] so the delay is a property of the chunk; the wait happens in
  /// [_pump] so a chunk that came in behind a slower one cannot overtake it.
  /// Head-of-line waiting is what makes this a delay rather than a reordering
  /// fault — and the chunk waits *inside* [_pending], so its bytes still count
  /// toward the high-water mark while they are held.
  Duration Function()? chunkDelay;

  /// Bytes per second this line may forward. Null means unmetered.
  ///
  /// The seat `throttle` takes (plan 02-04), implemented as a token bucket
  /// consulted by the same flush-gated writer everything else goes through —
  /// **not** a second buffer. A rate limiter with its own queue would be a
  /// second place bytes can pile up, and only one of the two would be under
  /// the high-water mark this line's memory bound was measured against.
  ///
  /// The bucket holds at most one second of traffic, so a line that has been
  /// idle can burst for a second and no longer. That cap is why Finding 5
  /// measures over windows of three seconds and up: below about two the burst
  /// is most of what is being measured.
  int? get bytesPerSecond => _bytesPerSecond;

  set bytesPerSecond(int? value) {
    if (value == _bytesPerSecond) return;
    _bytesPerSecond = value;
    // Re-base the bucket on every change. Budget accrued under the old rate —
    // or accrued while unmetered, where the clock ran and nothing ever spent
    // it — is not credit against the new one. Without this, setting a
    // throttle on a connection that has been open for a minute would release
    // a full second of the new rate immediately, and the first measurement
    // window would read high for a reason no test could see.
    _tokens = 0;
    _tokensAtMicros = _clock.elapsedMicroseconds;
  }

  int? _bytesPerSecond;

  /// Bytes of budget available to spend right now.
  ///
  /// Fractional because a slice interval is rarely a whole number of bytes at
  /// these rates, and rounding it away every 20 ms is a systematic error of a
  /// few per cent — an error the size of the tolerance being measured.
  double _tokens = 0;

  /// When [_tokens] was last brought up to date, on the line's own clock.
  int _tokensAtMicros = 0;

  /// Drop queued chunks instead of forwarding them. False means forward.
  ///
  /// The seat `blackhole` takes in plan 02-09 — a true half-open, where the
  /// socket stays up and the bytes stop arriving.
  ///
  /// **Read-and-drop, and specifically not a paused subscription.** The bytes
  /// are taken off the source and discarded in [_onData], so nothing
  /// accumulates and no backpressure reaches the sender: its `add` and
  /// `flush()` complete exactly as they did before the switch was thrown
  /// (RESEARCH Finding 4, the `write completed` clause). Pausing the source
  /// instead would stall the sender inside one socket buffer, which is
  /// backpressure — a different fault, with different client-side code paths,
  /// wearing this one's name. See `fault_proxy.dart`'s `blackhole` for the
  /// same statement from the lever's side.
  ///
  /// Dropping happens on arrival *and* at the head of the queue, because the
  /// switch can be thrown while chunks are already waiting — under a latency
  /// or a throttle they may be waiting for some time, and a blackhole that
  /// delivered them anyway would let bytes cross a link that is supposed to
  /// have gone silent.
  bool discardInsteadOfForward = false;

  /// Hold queued chunks back until released. False means forward.
  ///
  /// The seat `bufferServerToClient` takes in plan 02-09. Withholding differs
  /// from [discardInsteadOfForward] in that the bytes are still owed, which is
  /// why it must live behind the same high-water mark as everything else:
  /// they stay in [_pending] and keep counting toward [pendingBytes], so a
  /// server firehosing into a withheld direction pauses its source instead of
  /// growing the process (T-02-24). A holding area of its own would be the
  /// unbounded sink RESEARCH Finding 7 measured at 4463 MB, reintroduced by
  /// the one mode whose job is to hold bytes.
  ///
  /// Clearing it releases what is held — the lever is a withhold, not a
  /// discard — which is why this is a setter rather than a bare field: the
  /// pump has nothing to wake it once the queue has stopped moving, so the
  /// transition to false has to kick it.
  bool get withholdUntilReleased => _withholdUntilReleased;

  set withholdUntilReleased(bool value) {
    if (value == _withholdUntilReleased) return;
    _withholdUntilReleased = value;
    if (!value) unawaited(_pump());
  }

  bool _withholdUntilReleased = false;

  /// Bytes that may pass despite [withholdUntilReleased].
  ///
  /// How [releaseWithheld] lets a batch out while the lever stays armed. A
  /// byte count rather than a queue marker because the head chunk can be split
  /// — by a throttle, or by a cut — and the release has to be able to stop
  /// mid-chunk at exactly the boundary it was given.
  int _releasableBytes = 0;

  /// Lets everything currently held go, leaving the lever armed.
  ///
  /// The behaviour of the original proxy's `flushBuffer()`
  /// (`tfc_dart/test/proxy.dart:145-154`), and the reason it is worth keeping:
  /// releasing a batch and going on withholding is what a store-and-forward
  /// stall looks like from the client's side, and a release that disarmed
  /// could only ever express "the fault is over".
  ///
  /// Bytes that arrive after this call are withheld again, because they are
  /// not part of the batch that was released — the count is taken now, once.
  ///
  /// A no-op when nothing is being withheld, which is what
  /// `FaultProxy.flush()`'s doc claims of itself: teardown paths and scenario
  /// scripts call it unconditionally, and a credit taken while the lever is
  /// off is a number that nothing will ever spend — until a blackhole
  /// discards the bytes it was counted against and a later withhold spends it
  /// on somebody else's.
  void releaseWithheld() {
    if (!_withholdUntilReleased) return;
    _releasableBytes = _pendingBytes;
    unawaited(_pump());
  }

  /// Bytes this line may still forward before the cut fires. Null means none
  /// is armed.
  ///
  /// The seat `cutMidFrame` takes (plan 02-07), and it counts **bytes**: the
  /// head chunk is split at the boundary using the same `_headWritten`
  /// remainder the throttle already needed, because a cut that rounded up to
  /// the end of whichever chunk happened to straddle n would deliver a number
  /// nobody asked for and would vary with the peer's write sizes.
  ///
  /// Counts down as bytes leave. The countdown lives on the line rather than
  /// in the proxy because this is the only place that knows how many bytes
  /// actually reached the socket — bytes still queued here have not been
  /// delivered, and a mode promising "exactly n at the peer" cannot count what
  /// it merely accepted.
  ///
  /// Arming or disarming it moves [_cutGeneration], which is how the writer
  /// tells its own countdown from one somebody replaced while it was awaiting
  /// a flush.
  int? get cutAfterBytes => _cutAfterBytes;

  set cutAfterBytes(int? value) {
    _cutAfterBytes = value;
    _cutGeneration++;
  }

  int? _cutAfterBytes;

  /// How many times the cut has been armed or disarmed.
  ///
  /// [_pump] reads the countdown once per iteration and writes it back after
  /// its awaits, and a `cutMidFrame(null)` landing in between would otherwise
  /// be undone by that write-back — the disarm this field's doc promises would
  /// not hold while a write was in flight, and the resurrected countdown would
  /// later expire with no callback left to hand the connection to. The writer
  /// carries the generation it read across the awaits and only writes back
  /// while it still matches.
  int _cutGeneration = 0;

  /// Invoked once, after the last byte before the cut has been **flushed**.
  ///
  /// Called from inside the writer, after its `flush()` has completed, so the
  /// n bytes have left this process before whatever the callback does to the
  /// socket. Cleared as it fires: a cut is one event, and a second call would
  /// tear down a connection the proxy may have replaced by then.
  ///
  /// What it must not do is reset the socket. See `fault_proxy.dart`: the FIN
  /// is the mode.
  Future<void> Function()? onCutReached;

  /// Bytes this line has accepted and not yet delivered.
  ///
  /// Includes the chunk currently in flight: it has left the queue but the
  /// destination has not acknowledged it, and a caller asking what the line is
  /// holding is asking about that chunk too.
  int get pendingBytes => _pendingBytes;

  /// The largest [pendingBytes] has ever been.
  ///
  /// The observable the bounded-memory criterion is stated against. Sampling
  /// RSS instead would measure the whole test host — including the payload the
  /// firehose is generating — and could not tell a bounded queue from a lucky
  /// garbage collection.
  int get peakPendingBytes => _peakPendingBytes;

  /// The largest single chunk this line's source has ever handed it.
  ///
  /// The other half of the memory bound, and the half nothing in this process
  /// chooses. `dart:io` reads a POSIX socket with `available()` — the whole
  /// kernel receive queue in one call, uncapped — so the chunk that crosses
  /// [highWaterBytes] and triggers the pause is as large as the kernel let the
  /// receive buffer grow. Measured on macOS loopback: 1.59 MB at the default
  /// buffer of 408 KB, and 5.57 MB with `SO_RCVBUF` raised to 4 MiB. Windows
  /// reads a fixed 64 KiB (`ClientSocket::IssueReadLocked`), so the same rig
  /// overshoots by three orders of magnitude less there.
  ///
  /// Exposed because it turns the bounded-memory criterion from a number
  /// somebody calibrated into the invariant the code actually enforces:
  /// [peakPendingBytes] is strictly below `highWaterBytes + largestChunkBytes`,
  /// because the pause is applied synchronously in `_onData` the moment the
  /// queue reaches the mark, and nothing else can arrive until the queue drains
  /// to [lowWaterBytes]. A test asserting that is measuring the queue's policy;
  /// a test asserting a constant is measuring the runner's kernel.
  int get largestChunkBytes => _largestChunkBytes;

  /// Whether the line is currently refusing to read from its source.
  bool get sourcePaused => _paused;

  /// Every transition of [sourcePaused]: true on pause, false on resume.
  ///
  /// Broadcast, and it emits only on transitions, so a test can await the
  /// backpressure event itself instead of sleeping and hoping. Subscribe
  /// before applying pressure — a broadcast stream has no history.
  Stream<bool> get sourcePausedChanges => _pauseChanges.stream;

  /// Completes when the source has ended and everything it sent has been
  /// written, or when [close] is called.
  Future<void> get done => _finished.future;

  /// Begins carrying [source] to the destination.
  ///
  /// A source error is treated as the end of the stream rather than propagated:
  /// on a socket it means the peer went away mid-connection, which is the
  /// normal end of a proxied pair and, for half this phase's modes, the
  /// deliberate one.
  void start(Stream<List<int>> source) {
    if (_source != null) {
      throw StateError('this delay line is already carrying a source; one '
          'line carries one direction of one connection, so a second source '
          'would interleave two conversations into one stream');
    }
    if (_closed) return;
    _source = source.listen(
      _onData,
      onDone: _onSourceEnded,
      onError: (Object _) => _onSourceEnded(),
      cancelOnError: false,
    );
  }

  /// Stops the line, cancels its source subscription, and drops what is queued.
  ///
  /// Completes rather than hanging even with bytes pending and a destination
  /// that has stopped accepting them. Awaiting the in-flight `flush()` here
  /// would be awaiting a peer that is, in this phase, quite deliberately not
  /// reading — so teardown would inherit the very stall the harness injects.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final source = _source;
    _source = null;
    _pending.clear();
    _pendingBytes = 0;
    _headWritten = 0;
    _releasableBytes = 0;
    _paused = false;
    await source?.cancel();
    if (!_pauseChanges.isClosed) await _pauseChanges.close();
    if (!_finished.isCompleted) _finished.complete();
  }

  void _onData(List<int> chunk) {
    if (_closed || chunk.isEmpty) return;
    if (discardInsteadOfForward) {
      // Read and dropped. Returning before the queue is touched is what keeps
      // the sender unstalled: nothing is counted toward the high-water mark,
      // so the source is never paused and the peer's `flush()` keeps
      // completing while its bytes go nowhere.
      return;
    }
    final delay = chunkDelay?.call();
    final releaseAtMicros = delay == null || delay <= Duration.zero
        ? 0
        : _clock.elapsedMicroseconds + delay.inMicroseconds;
    _pending.addLast((bytes: chunk, releaseAtMicros: releaseAtMicros));
    _pendingBytes += chunk.length;
    if (_pendingBytes > _peakPendingBytes) _peakPendingBytes = _pendingBytes;
    if (chunk.length > _largestChunkBytes) _largestChunkBytes = chunk.length;
    if (!_paused && _pendingBytes >= highWaterBytes) {
      _paused = true;
      _source?.pause();
      _announce(true);
    }
    unawaited(_pump());
  }

  void _onSourceEnded() {
    _sourceDone = true;
    if (!_writing && _pending.isEmpty && !_finished.isCompleted) {
      _finished.complete();
    }
  }

  /// The one place bytes are written to the destination.
  ///
  /// Every `add` is followed by an awaited `flush()` before the next chunk
  /// leaves the queue. That single line is the whole memory bound: without it
  /// the loop hands `dart:io` chunks faster than the kernel takes them and the
  /// queue that is supposed to be bounded lives inside the socket sink, where
  /// nothing can see or limit it.
  Future<void> _pump() async {
    if (_writing) return;
    _writing = true;
    try {
      while (!_closed && _pending.isNotEmpty) {
        if (discardInsteadOfForward) {
          // Chunks that were already queued when the switch was thrown. Break
          // rather than return, so a source that has already ended still
          // completes `done` below — a blackholed direction whose peer went
          // away must still be collectable, or the pair outlives both its
          // sockets.
          _dropQueued();
          break;
        }
        if (_withholdUntilReleased && _releasableBytes <= 0) {
          // Held, not dropped. The chunks stay in `_pending` and stay counted,
          // which is what puts the withhold behind the high-water mark rather
          // than beside it.
          break;
        }
        // Read once per iteration and use that reading for both the clamp and
        // the countdown. Re-reading after the awaits below would let a cut
        // re-armed mid-write have `take` subtracted from a budget those bytes
        // were never spent against.
        final untilCut = _cutAfterBytes;
        final cutGeneration = _cutGeneration;
        if (untilCut != null && untilCut <= 0) {
          // Only the hand-off ends the pump. A cut that fires with no
          // callback — which is what a disarm leaves behind — has nobody to
          // give the connection to, so ending here would drop out of the loop
          // with bytes still queued and strand them on a quiet source.
          if (await _fireCut()) return;
          continue;
        }
        final queued = _pending.first;
        final waitMicros = queued.releaseAtMicros - _clock.elapsedMicroseconds;
        if (waitMicros > 0) {
          // A `Future.delayed` that is the mode itself, not a guess about
          // someone else's scheduler: the phase forbids sleeping *as
          // synchronisation*, and this is the delay being injected. The chunk
          // stays in `_pending` for the wait, so a line holding bytes back
          // still counts them against the high-water mark — a latency mode
          // that parked its chunks somewhere else would be an unbounded queue
          // wearing the bounded one's name.
          await Future<void>.delayed(Duration(microseconds: waitMicros));
          if (_closed) return;
        }
        final chunk = queued.bytes;
        var take = chunk.length - _headWritten;
        // Before the throttle, so the two clamps compose the only way that
        // makes sense: a cut of 40 bytes on a line handing out 2500-byte
        // slices delivers 40, not a slice.
        if (untilCut != null && take > untilCut) take = untilCut;
        // A release stops at the boundary it was given, mid-chunk if that is
        // where the batch ended: bytes that arrived after `releaseWithheld`
        // were never part of it.
        if (_withholdUntilReleased && take > _releasableBytes) {
          take = _releasableBytes;
        }
        final rate = _bytesPerSecond;
        if (rate != null && rate > 0) {
          take = await _spendBudget(take, rate);
          // Re-read after the await: `close()` may have emptied the queue
          // under a line that was waiting for its next slice.
          if (_closed || take <= 0) return;
        }
        final slice = _sliceOf(chunk, _headWritten, _headWritten + take);
        try {
          _destination.add(slice);
          await _destination.flush();
        } catch (_) {
          // The destination went away — a closed or reset socket throws from
          // `add`, and `flush` completes with the error the peer sent. Either
          // way this direction is over, and it is not this line's business to
          // decide what that means for the connection.
          await close();
          return;
        }
        // Re-read the state the await suspended across: `close()` empties the
        // queue, and a pump that resumed into a cleared queue would take the
        // teardown down with a `Bad state: No element` naming this line rather
        // than the teardown.
        if (_closed) return;
        _headWritten += take;
        _pendingBytes -= take;
        if (_releasableBytes > 0) {
          _releasableBytes = _releasableBytes > take ? _releasableBytes - take : 0;
        }
        if (_headWritten >= chunk.length) {
          _pending.removeFirst();
          _headWritten = 0;
        }
        if (untilCut != null && _cutGeneration == cutGeneration) {
          // After the flush above, which is what makes the promise "n bytes
          // have left this process" rather than "n bytes were handed to the
          // sink". A cut that fired before the flush would close the socket
          // with its own send buffer still holding some of the n.
          //
          // Guarded on the generation because the awaits above are exactly
          // where a `cutMidFrame(null)` lands: writing the countdown back
          // unconditionally would resurrect a cut the caller had taken away,
          // and the connection would be cut after all.
          _cutAfterBytes = untilCut - take;
          if (untilCut - take <= 0 && await _fireCut()) return;
        }
        if (_paused && _pendingBytes <= lowWaterBytes) {
          _paused = false;
          _source?.resume();
          _announce(false);
        }
      }
    } finally {
      _writing = false;
    }
    if (_sourceDone && _pending.isEmpty && !_finished.isCompleted) {
      _finished.complete();
    }
  }

  /// Throws away everything queued, and lets the source run again.
  ///
  /// Resuming matters as much as clearing: a line that hit the high-water mark
  /// before it was blackholed has a paused source, and a blackhole is defined
  /// by the sender never noticing. Leaving it paused would deliver
  /// backpressure to a peer that is supposed to be writing into silence.
  void _dropQueued() {
    _pending.clear();
    _pendingBytes = 0;
    _headWritten = 0;
    // The release was a credit against bytes that no longer exist. Carrying it
    // forward would let the next withhold leak exactly this many: the credit
    // normally drains to zero as the same bytes are written, and a blackhole
    // in between is the one thing that separates the two.
    _releasableBytes = 0;
    if (_paused) {
      _paused = false;
      _source?.resume();
      _announce(false);
    }
  }

  /// Hands the connection to [onCutReached], once.
  ///
  /// Disarms first and calls second, so a callback that closes this line — and
  /// they all do — cannot come back round through a pump that still thinks a
  /// cut is pending.
  ///
  /// Returns whether there was a callback to hand it to. False means the cut
  /// was disarmed under a countdown already in flight, so nothing happened to
  /// the connection and the writer must go on draining rather than treat this
  /// as the end of the direction.
  Future<bool> _fireCut() async {
    final onCut = onCutReached;
    cutAfterBytes = null;
    onCutReached = null;
    if (onCut == null) return false;
    await onCut();
    return true;
  }

  /// Waits until the bucket can pay for a slice, then spends it.
  ///
  /// Returns how many of [wanted] bytes may be written now — a slice, not the
  /// whole chunk. Splitting the head chunk is what makes a 64 KiB read
  /// deliverable at 100 kbit/s as five seconds of even traffic instead of one
  /// write five seconds late, and it is why the rate holds inside a window
  /// rather than only on average across several.
  ///
  /// Returns 0 only when the line closed while waiting.
  Future<int> _spendBudget(int wanted, int rate) async {
    final slice = _sliceSizeFor(rate);
    final want = wanted < slice ? wanted : slice;
    while (!_closed) {
      _accrue(rate);
      if (_tokens >= want) {
        _tokens -= want;
        return want;
      }
      final shortfallMicros =
          ((want - _tokens) * Duration.microsecondsPerSecond / rate).ceil();
      // The rate limit itself, not a synchronisation guess: this is the wait
      // that makes the link slow. The bytes stay in `_pending` throughout, so
      // a firehose against a slow throttle still hits the high-water mark and
      // pauses its source (T-02-09) rather than piling up out of sight.
      await Future<void>.delayed(Duration(microseconds: shortfallMicros));
    }
    return 0;
  }

  /// Credits the bucket for the time since it was last read.
  ///
  /// Capped at one second of traffic. An idle line may bank a second's burst
  /// and no more — which is the cap Finding 5's measurements were taken under,
  /// and the reason its windows start at three seconds.
  void _accrue(int rate) {
    final now = _clock.elapsedMicroseconds;
    final elapsed = now - _tokensAtMicros;
    _tokensAtMicros = now;
    if (elapsed <= 0) return;
    _tokens += rate * elapsed / Duration.microsecondsPerSecond;
    final cap = rate.toDouble();
    if (_tokens > cap) _tokens = cap;
  }

  /// How much a throttled line hands out at a time, at [rate].
  int _sliceSizeFor(int rate) {
    final perSlice = rate ~/ _slicesPerSecond;
    if (perSlice < _minimumSliceBytes) return _minimumSliceBytes;
    if (perSlice > _maximumSliceBytes) return _maximumSliceBytes;
    return perSlice;
  }

  /// A view of `chunk[start..end)`, copying only when it has to.
  ///
  /// `sublistView` for the typed lists every socket produces, so slicing a
  /// throttled stream costs no copies; `sublist` is the fallback for a source
  /// that hands out a plain `List<int>`, which the tests do.
  List<int> _sliceOf(List<int> chunk, int start, int end) {
    if (start == 0 && end == chunk.length) return chunk;
    if (chunk is Uint8List) return Uint8List.sublistView(chunk, start, end);
    return chunk.sublist(start, end);
  }

  void _announce(bool paused) {
    if (!_pauseChanges.isClosed) _pauseChanges.add(paused);
  }
}
