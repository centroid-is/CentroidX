/// The operator's end of a hold-to-run deadman: one button, one timer, and
/// three ways it can end.
///
/// **The failure mode this inverts.** A panel that sets a boolean on press and
/// clears it on release leaves a machine running when it crashes in between —
/// the clear is the message that never gets sent, and there is no message that
/// says "I stopped existing". A counter inverts the polarity: the panel sends
/// an increment every [pulsePeriod], the PLC drops the output when the
/// increments stop for longer than its deadman window, and a panel that
/// crashes, is backgrounded or loses its link stops the machine by doing
/// nothing at all. Everything in this file is shaped by that: nothing here
/// tries hard to deliver a message, and every path out of a hold ends with a
/// timer cancelled.
///
/// **Pure Dart, with the triggers injected** (05-CONTEXT decision 2). Tap
/// cancel is a method call, an app-lifecycle event is a `Stream<void>` handed
/// in at construction, and the link dying arrives on the handle's own
/// `onReleased` — so all three release paths can be driven by a test with no
/// Flutter in the process, and the thin gesture/lifecycle binding is a
/// documented pattern (05-08) rather than a widget this package cannot import.
///
/// **The cadence is handed in, never owned.** `ClientConfig.holdPulsePeriod`
/// is the one named home for it, with `ClientConfig.holdMissedPulsesBeforeStop`
/// giving the deadman it multiplies out to; a number invented here would be
/// the first client timing number with no injectable home, and a test would
/// have to wait on the plant's real 100 ms to prove anything.
///
/// **No queue, and the absence is asserted structurally.** A pulse that cannot
/// be sent is dropped, not stored. `RemoteStateMan` gates every pulse on the
/// link being ready and drops the rest (05-04); this controller never learns
/// that it happened and must not try to. The reason is one layer further down:
/// `_WsSink.add` goes straight to a `dart:io` sink that buffers without bound
/// and offers neither `bufferedAmount` nor `flush()` (flutter#103306), so a
/// buffer here would be a burst of stale counter values delivered the instant
/// a stalled link recovered — a machine jogging on a finger that came off a
/// minute ago. `hold_to_run_test.dart` reads this file as text and fails if a
/// collection appears in it (T-05-28).
///
/// **One watcher on the link, and it is not this one.** `RemoteStateMan`
/// already tracks whether the last transition was into `ready` and releases
/// every live hold on leaving it. A subscription here would be a second thing
/// that can disagree with the first about whether a machine should still be
/// moving, and disagreements between two watchers are decided by whichever
/// runs first.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// One hold-to-run button, from the press to whichever of the three endings
/// arrives first.
///
/// The timer field is the design rather than an implementation detail, and it
/// is copied in all four of its properties from `freshness_watchdog.dart`: one
/// nullable field ("not a list: the type is the design"), a disposed guard on
/// every entry point, an observable count that is 0 or 1 and never more, and a
/// teardown that cancels *and nulls*.
final class HoldToRunController {
  /// [releaseOn] is the app-lifecycle trigger: any event on it ends the hold
  /// with [HoldEnded.lifecycle]. A `Stream<void>` and not a
  /// `WidgetsBindingObserver`, because this package is pure Dart and because a
  /// trigger that can only be produced by a framework is a trigger no test can
  /// pull.
  HoldToRunController({
    required StateManApi api,
    required this.key,
    required this.pulsePeriod,
    Stream<void>? releaseOn,
  }) : _api = api {
    _lifecycle = releaseOn?.listen((_) {
      // Through [_release] and not through [release]: the public method
      // refuses a caller who asked to end a hold that never began, and that
      // refusal is right for a caller and wrong for a trigger — a lifecycle
      // event on a controller nobody has pressed is a no-op, not an error,
      // and swallowing a StateError here is how a real fault would go unseen.
      //
      // What is left is fire-and-forget with the *write's* error swallowed: a
      // lifecycle event is not a caller who can be told anything, the counter
      // has already stopped by the time that outcome could matter, and a
      // stream callback that throws takes down the zone it runs in.
      unawaited(
          _release(HoldEnded.lifecycle)?.then((_) {}, onError: (Object _) {}));
    });
  }

  final StateManApi _api;

  /// The tag being fed. One key, and it is the one the caller named: the tag
  /// *is* the deadman counter (D-P5-D).
  final String key;

  /// How often the counter is advanced while the button is held.
  ///
  /// See the library doc: this belongs to `ClientConfig.holdPulsePeriod` and
  /// is handed in.
  final Duration pulsePeriod;

  StreamSubscription<void>? _lifecycle;

  /// The one timer. Not `late`, not a collection: the type is the design.
  Timer? _pulse;

  HoldHandle? _handle;
  HoldEnded? _releaseReason;

  /// A release that arrived while the engage was still out, kept until there
  /// is a hold to apply it to.
  ///
  /// Not a queue and not a pulse: one nullable reason, which is the whole
  /// state the in-flight window needs (the release trigger that arrives first
  /// is the only one that matters). See [press] for what it buys.
  HoldEnded? _pendingRelease;

  /// True from the moment [press] asks for the hold until the engage answers.
  ///
  /// The window this exists for is the engage round trip — over a socket a
  /// measured 50-100 ms, which is long enough for a finger to come off a
  /// button.
  var _engaging = false;

  var _pulsesSent = 0;
  var _disposed = false;

  /// Whether a hold is live and the counter is being fed.
  bool get isHeld => _handle?.isHeld ?? false;

  /// How many pulses this controller has emitted, over its whole life.
  ///
  /// Counted where the timer fires rather than where the pulse reaches the
  /// wire, and the difference is the point: this is what a release that
  /// forgot to cancel its timer keeps increasing. What the *link* carried is
  /// `RemoteStateMan.debugHoldTicksSent`, counted after the gate.
  int get debugPulsesSent => _pulsesSent;

  /// Why the hold ended, or null while it is still live.
  ///
  /// The first ending wins. A disconnect racing an operator's finger is the
  /// ordinary case and not the exotic one, and the panel must not tell the
  /// operator the app was backgrounded when in fact they let go.
  HoldEnded? get debugReleaseReason => _releaseReason;

  /// 0 or 1, never more, whatever else the panel is running.
  ///
  /// Deliberately **not** part of `RemoteStateMan.debugTimerCount`'s ceiling
  /// of two: this timer is not owned by the connection supervisor, and folding
  /// it in would make that ceiling drift with the number of buttons on the
  /// screen until it stopped meaning anything.
  int get debugTimerCount => _pulse == null ? 0 : 1;

  /// Engages the hold and starts feeding the counter.
  ///
  /// Returns the engage write's three-state outcome. Only an applied engage
  /// starts the timer: a device that refused is a machine that never agreed to
  /// move, and a UI feeding a deadman for a hold that does not exist is the
  /// shipped version of a button that lights on the local click.
  ///
  /// **A release that arrives while the engage is out wins.** The round trip
  /// is 50-100 ms over a socket, which is long enough for a scroll to steal
  /// the pointer, for a stray second touch, or for the app to be backgrounded.
  /// If any of that happens the hold may still take — the write was already on
  /// its way — so the engage is honoured and then immediately released, and
  /// the pulse timer never starts. The alternative is the one failure this
  /// whole design exists to make impossible: a deadman fed at full cadence
  /// from a panel nobody is touching, stopping only when the page closes or
  /// the link drops. When in doubt, released.
  Future<WriteResult> press() async {
    _refuseIfDisposed('press');
    if (isHeld || _engaging) {
      throw StateError('a hold on "$key" is already live on this controller. '
          'Two concurrent holds on one tag are a contradiction at the '
          'operator\'s end — one finger, one button — and nothing here can '
          'decide which of them the machine should obey');
    }

    // A fresh press is a fresh hold: the previous ending must not still be
    // reported once the button is down again.
    _releaseReason = null;
    _handle = null;
    _pendingRelease = null;
    _engaging = true;

    final HoldHandle handle;
    try {
      handle = await _api.holdToRun(key);
    } finally {
      // Cleared however the engage ended, including by throwing: a controller
      // stuck reporting itself mid-engage would answer every later release
      // with "the hold is coming" and never press again.
      _engaging = false;
    }
    unawaited(handle.onReleased.then(_noteEnded));
    _handle = handle;

    if (!handle.isHeld) return handle.engagement;

    // The operator let go, the app went away, or this controller was disposed
    // while the engage was out. The hold took; nothing is holding it.
    final ending = _disposed ? HoldEnded.disposed : _pendingRelease;
    if (ending != null) {
      // Recorded here rather than left to the [onReleased] listener, which
      // runs a microtask after the caller of `press()` has already been
      // resumed: a panel that read [debugReleaseReason] the instant the
      // engage answered would otherwise see a hold that ended for no reason.
      _releaseReason ??= ending;
      unawaited(_release(ending)?.then((_) {}, onError: (Object _) {}));
      return handle.engagement;
    }

    _pulse = Timer.periodic(pulsePeriod, (_) => _feed(handle));
    return handle.engagement;
  }

  /// Ends the hold: stops the counter first, then writes the zero.
  ///
  /// **Cancel before release, and the order is the property.** A timer that
  /// fires between the release write leaving and its answer arriving is a
  /// pulse sent after the operator let go — the counter would be fed once more
  /// by a controller that believes it has already stopped.
  ///
  /// Idempotent, because the handle is: every later call hands back the first
  /// one's future and writes nothing, so a disconnect racing a finger cannot
  /// put two zeros on the wire.
  ///
  /// Safe to call with the engage still in flight, and the binding depends on
  /// it: §4.6a wires `onTapCancel` straight here with no `try` around it, so a
  /// throw would land in a gesture callback. There is no hold to end yet and
  /// no zero to write, so the answer is [WriteUnknown] and the intent is kept
  /// for [press] to honour the moment the hold exists.
  ///
  /// Throws only for the one case that is a caller's mistake: a release on a
  /// controller that has never pressed at all.
  ///
  /// The returned outcome is informational. What stops the machine is the
  /// counter stopping, which has already happened before this future exists,
  /// so a release over a dead link resolving `WriteUnknown` is the honest
  /// answer and not a failure to release.
  Future<WriteResult> release(
      {HoldEnded reason = HoldEnded.operatorLetGo}) async {
    final outcome = _release(reason);
    if (outcome == null) {
      throw StateError('release() was called on a controller for "$key" that '
          'has never pressed. There is no hold to end and no write to make; '
          'a release that invented one would put a 0 on a deadman tag some '
          'other panel may be feeding');
    }
    return outcome;
  }

  /// The one place a hold ends, whichever trigger got here first.
  ///
  /// Null means there was nothing to release — no hold, and no engage on its
  /// way. What that means is the caller's to decide: [release] refuses,
  /// because a caller who asked deserves to be told; the lifecycle listener
  /// ignores it, because a trigger firing on a controller nobody pressed is a
  /// no-op. Both go through here so neither can end a hold in a way the other
  /// does not, which is exactly how the in-flight window came to behave
  /// differently on the two paths.
  Future<WriteResult>? _release(HoldEnded reason) {
    _cancelPulse();
    final handle = _handle;
    if (handle == null) {
      if (!_engaging) return null;
      // The engage has not answered yet, so there is no handle to release and
      // no zero to write. The intent is recorded and [press] honours it the
      // moment the hold exists; the counter never starts.
      _pendingRelease ??= reason;
      _releaseReason ??= reason;
      return Future<WriteResult>.value(WriteUnknown(
          '',
          const WriteReason('hold_released_before_engage_answered',
              message: 'the operator let go before the engage came back; the '
                  'hold is released as soon as it exists and the counter is '
                  'never fed')));
    }
    final outcome = handle.release(reason: reason);
    // The ending is recorded by the listener registered in [press], which is
    // ahead of this continuation in the completer's own order — so by the time
    // the caller has its outcome, [debugReleaseReason] is set.
    return handle.onReleased.then<WriteResult>((_) => outcome);
  }

  /// Ends everything this controller owns, and is safe to call twice.
  ///
  /// **The counter stops before the first `await`.** The timer is cancelled
  /// and the handle released synchronously, which is the whole safety
  /// property; the future this returns only carries the release write's
  /// outcome afterwards, so a caller in a teardown that cannot wait may drop
  /// it. That is the same bargain `RemoteStateMan` makes when it releases
  /// every hold on a link that has just gone, and for the same reason: a page
  /// that waited for a write on a dead link would stay open for a deadline
  /// over an answer nobody reads.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelPulse();
    final lifecycle = _lifecycle;
    _lifecycle = null;
    final handle = _handle;
    final released = handle != null && handle.isHeld
        ? handle
            .release(reason: HoldEnded.disposed)
            .then((_) {}, onError: (Object _) {})
        : Future<void>.value();
    await lifecycle?.cancel();
    await released;
  }

  /// One pulse. Counted first, sent second.
  ///
  /// Counting before the send is deliberate: [HoldHandle.tick] is a no-op on a
  /// hold that has ended, so a controller that released without cancelling
  /// this timer would leave the tag looking perfectly still while feeding a
  /// dead hold ten times a second. The count is what makes that visible.
  void _feed(HoldHandle handle) {
    _pulsesSent++;
    handle.tick();
  }

  /// The hold ended, by whichever of the three paths got there first.
  ///
  /// The disconnect path arrives here and nowhere else: `RemoteStateMan`
  /// completes `onReleased` with [HoldEnded.disconnect] when the link leaves
  /// ready, and this controller learns of it the same way it learns of every
  /// other ending.
  void _noteEnded(HoldEnded reason) {
    _cancelPulse();
    _releaseReason ??= reason;
  }

  /// Cancel *and* null. A cancelled timer left in the field reports as one
  /// through [debugTimerCount], which is the observable every release case
  /// checks.
  void _cancelPulse() {
    _pulse?.cancel();
    _pulse = null;
  }

  void _refuseIfDisposed(String what) {
    if (!_disposed) return;
    throw StateError('HoldToRunController for "$key" was asked to "$what" '
        'after it was disposed; the page it belonged to is gone, so there is '
        'nobody holding a button and nothing that would keep the counter '
        'moving');
  }
}
