/// The hold-to-run deadman: one handle, every hold verb on it.
///
/// A hold is an operator holding a button while a machine jogs. The safety
/// property is not that a release message arrives — it is that a counter
/// **stops advancing**, which the PLC notices within its deadman window
/// (~1 s, the user's decision, ~10 missed ticks at 10 Hz; the PLC-side
/// counterpart is `relay-comm-design.md` §4.6a). Everything in this file is
/// shaped by that inversion: engaging and releasing are real writes with
/// three-state outcomes, and the ticks in between are fire-and-forget because
/// a tick that is lost costs nothing a re-tick 100 ms later does not fix.
///
/// [HoldHandle] is a concrete `final class` rather than an interface, and it
/// is deliberately **not** part of the wire surface walked by
/// `packages/tfc_stateman_contract/test/api_surface_test.dart` — the two
/// injected callbacks are what let one class serve the fake, the channel
/// harness, the gateway and the remote client without any of them
/// subclassing it, so `StateManApi` grows by one member and not by seven
/// (05-RESEARCH §B.2).
///
/// `tick()` is **not** on `StateManApi` and must never be put there: a method
/// on the interface is a thing any connected client may invoke against any
/// key (`state_man_api.dart:1-10`), and a bare `tick(key, n)` is a write
/// primitive with no engage in front of it.
library;

import 'dart:async';

import 'write_result.dart';

/// Why a hold ended. Five arms, and no sixth without a decision.
///
/// Every arm is a real thing that stops a machine, and callers switch over
/// this exhaustively (no `default:`) so that adding a sixth reason does not
/// compile until somebody has written down what it means for the operator.
enum HoldEnded {
  /// The operator let go of the button. The ordinary path.
  ///
  /// Spelled with the suffix because `operator` is a Dart keyword.
  operatorLetGo,

  /// The app stopped being in front of the operator — backgrounded, window
  /// hidden, screen locked. A finger on a button nobody is looking at is not
  /// a hold.
  lifecycle,

  /// The link to the gateway left `ready`. The counter has already stopped
  /// reaching the plant, so the machine is stopping regardless; this reason
  /// is what tells the UI to say so instead of showing a live hold.
  disconnect,

  /// The engage write did not come back applied, so the hold was never taken.
  /// A handle in this state is inert: it cannot be fed.
  refused,

  /// The source was torn down under the hold. A disposed source that leaves a
  /// counter advancing is a machine nobody is holding.
  disposed,
}

/// A live hold on one tag, and every verb that can act on it.
///
/// Construct one by calling `StateManApi.holdToRun`; the implementation does
/// the engage write and injects [onTick] and [onRelease] so this class carries
/// the state machine and nothing about transport.
final class HoldHandle {
  /// The tag being fed. Per D-P5-D there is exactly one key and it is the one
  /// the caller passed in: the tag *is* the deadman counter, and a
  /// sibling-tag naming convention invented in Dart would have to be matched
  /// by hand in every PLC program.
  final String key;

  /// The outcome of the engage write — a three-state answer to "did the hold
  /// take". Only [WriteApplied] produces a handle that can be fed.
  final WriteResult engagement;

  final void Function(int counter) _onTick;
  final Future<WriteResult> Function(int counter) _onRelease;
  final Completer<HoldEnded> _released = Completer<HoldEnded>();

  int _counter;
  bool _isHeld;
  Future<WriteResult>? _releaseFuture;

  /// 2³¹−1: the largest value a signed DINT on the PLC side can hold.
  static const int _maxCounter = 2147483647;

  /// [startCounter] exists for one test and is documented as such: it is the
  /// only way to reach the wrap case without holding a button for 6.8 years.
  /// Production callers leave it at 1, which is the value the engage write
  /// already put on the tag.
  HoldHandle({
    required this.key,
    required this.engagement,
    required void Function(int counter) onTick,
    required Future<WriteResult> Function(int counter) onRelease,
    int startCounter = 1,
  })  : _onTick = onTick,
        _onRelease = onRelease,
        _counter = startCounter,
        _isHeld = engagement is WriteApplied {
    if (!_isHeld) {
      // A hold that was never taken must not be feedable, and must not write
      // a release for something it never engaged. `onReleased` is completed
      // here so a caller can await it uniformly without first inspecting
      // [engagement], and `release()` answers with the engage outcome —
      // which is the honest report of what happened to this hold.
      _releaseFuture = Future<WriteResult>.value(engagement);
      _released.complete(HoldEnded.refused);
    }
  }

  /// The last counter value sent, and the value on the tag.
  ///
  /// 1 immediately after a successful engage, +1 per tick, 0 once released.
  int get counter => _counter;

  /// Whether this hold is still live and still feedable.
  bool get isHeld => _isHeld;

  /// Completes exactly once, with why the hold ended.
  ///
  /// Completes even when the release write fails: the machine stopped when
  /// the counter stopped, so the release write's outcome is informational and
  /// arrives separately through [release]'s future.
  Future<HoldEnded> get onReleased => _released.future;

  /// Feeds the deadman: advances the counter and hands it to the transport.
  ///
  /// A no-op when the hold is not held. Never throws, never awaits, returns
  /// nothing — safety comes from the counter STOPPING, so giving a tick an
  /// outcome would invite somebody to await it, and awaiting liveness is how
  /// a stalled socket becomes a queue.
  void tick() {
    if (!_isHeld) return;
    // Cannot happen at 10 Hz inside a human lifetime; written anyway, because
    // a signed DINT going negative is an ugly thing to explain to an
    // integrator, and 0 is reserved for "released" (D-P5-E).
    _counter = _counter >= _maxCounter ? 1 : _counter + 1;
    _onTick(_counter);
  }

  /// Ends the hold: stops the counter, writes 0, and completes [onReleased].
  ///
  /// Idempotent. The first call marks the handle not-held and returns the
  /// release write's three-state outcome; every later call returns that same
  /// future and writes nothing, so a disconnect racing an operator's finger
  /// cannot put two zeros on the wire.
  Future<WriteResult> release({HoldEnded reason = HoldEnded.operatorLetGo}) {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    _isHeld = false;
    _counter = 0;
    if (!_released.isCompleted) _released.complete(reason);
    // `Future.sync` so that a transport that throws synchronously still
    // leaves this handle released rather than releasable a second time.
    return _releaseFuture = Future<WriteResult>.sync(() => _onRelease(0));
  }
}
