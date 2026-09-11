/// The set of live holds, the guard in front of it, and release-all on
/// teardown — the part of hold-to-run that is genuinely one thing.
///
/// `hold_handle.dart` owns the state machine: the counter, the wrap at the
/// signed-DINT ceiling, the inert handle for a refused engage, the idempotent
/// release, `onReleased` completing exactly once. This file owns the ~40 lines
/// that sat around it in two packages, byte-for-byte the same in most of their
/// length and differing in four places that mattered.
///
/// ## The inversion, restated because everything here depends on it
///
/// A hold is an operator holding a button while a machine jogs. Nothing has to
/// *arrive* for the machine to stop — the counter has to **stop advancing**,
/// and the PLC's own deadman window (~1 s, ~10 missed ticks at 10 Hz;
/// `relay-comm-design.md` §4.6a) does the rest. So a teardown that abandons a
/// live hold is the one shape of this feature that could hurt somebody, and a
/// teardown whose *release write* is lost is merely untidy.
///
/// ## What is deliberately NOT here
///
/// **No clock.** Not periodic, not one-shot, not a debounce. The caller
/// chooses the cadence, precisely so that the thing keeping a machine alive is
/// a finger and not a scheduler. A source that helpfully kept a deadman fed
/// would pass every other property in the hold contract.
///
/// **No tick path.** [DeadmanTick] is injected, and that is not tidiness — it
/// is difference 4 of the four this extraction found, left where it was. On
/// `tfc_dart` a tick is the full `write` path and lands in the outcome log; on
/// `tfc_relay_local` a tick deliberately bypasses the log and passes
/// `confirmByReading: false`, because at 10 Hz a two-minute hold is 1 200
/// entries. Those are two different write paths and always will be. A registry
/// that derived the tick from [DeadmanFeed] would have silently moved every
/// gateway tick into the outcome log, which is a **policy decision, not a
/// merge**.
///
/// **No logger.** `tfc_relay_protocol` has zero runtime dependencies and must
/// keep them. [HoldRegistry] takes [onLostWrite] instead, and each call site
/// wires it to its own `Logger`. That is also the honest shape: this file does
/// not know what a log line costs in the process it is running in.
///
/// **No deadline on any teardown path.** No `.timeout(` anywhere below. Both
/// call sites argue for that and they argue for it from opposite directions —
/// see [HoldRegistry.new]'s `awaitReleases`.
///
/// **Nothing here uses a bare fire-and-forget wrapper.** Every launched future
/// carries an explicit `.catchError`. A future launched without a handler still
/// reaches the zone when it errors, and it fails whichever unrelated test
/// happens to be running when it lands rather than the hold that stopped being
/// fed. (The wrapper is not named in this file even in prose, because
/// `hold_registry_source_test.dart` scans for it textually — the same rule
/// `backend_hold.dart` has always followed.)
library;

import 'hold_handle.dart';
import 'ulid.dart';
import 'write_result.dart';

/// How one counter value reaches the plant, with an outcome.
///
/// A function rather than a reference to a write router: a registry that takes
/// only "how to put a number on a tag" is testable with no pipe at all, and it
/// cannot reach for a second write path even if somebody later wanted one to.
typedef DeadmanFeed = Future<WriteResult> Function(String key, int counter);

/// How one *tick* reaches the plant — a different path, on purpose.
///
/// Returns nothing, because safety comes from the counter STOPPING: giving a
/// tick an outcome would invite somebody to await it, and awaiting liveness is
/// how a stalled socket becomes a queue. The call site owns the error handling
/// for the same reason it owns the path.
typedef DeadmanTick = void Function(String key, int counter);

/// Told when a write on the hold path was lost, so the process it is running
/// in can say so in whatever way that process says things.
typedef LostWriteReport = void Function(String message, Object? error);

/// Every hold one source is currently keeping, and the one way to take one.
final class HoldRegistry {
  /// [awaitReleases] is **required and has no default**, and that is the whole
  /// point of it.
  ///
  /// The two call sites disagree, each in writing, and neither cites the
  /// other. A default is what would make one of them invisible:
  ///
  ///  * **`tfc_relay_local` passes `true`.** Its argument: every upstream
  ///    write is bounded by a *required* deadline, so nothing on this path can
  ///    hang, and a dispose that gave up half way leaves the thing it was
  ///    disposing in a state nobody owns.
  ///  * **`tfc_dart` passes `false`.** Its argument: a teardown that waited
  ///    would hang on exactly the dead link that caused the teardown.
  ///
  /// **This author's reading is that `tfc_relay_local` is right and `tfc_dart`
  /// should change** — the deadline over there is required rather than hoped
  /// for, which is what defeats the hang argument. That change is a **deferred
  /// decision and is not this file's to make**: both behaviours are preserved
  /// exactly as they shipped, and the difference is now a boolean a reader can
  /// see at two call sites instead of a shape difference between two files.
  ///
  /// Either way the *machine* stops at the same instant. `HoldHandle.release`
  /// marks the handle not-held and zeroes the counter synchronously; what
  /// `awaitReleases` decides is only whether the caller waits to hear that the
  /// zero reached the plant.
  HoldRegistry({
    required DeadmanFeed feed,
    required DeadmanTick onTick,
    required bool awaitReleases,
    LostWriteReport? onLostWrite,
  })  : _feed = feed,
        _onTick = onTick,
        _awaitReleases = awaitReleases,
        _onLostWrite = onLostWrite;

  final DeadmanFeed _feed;
  final DeadmanTick _onTick;
  final bool _awaitReleases;
  final LostWriteReport? _onLostWrite;

  /// The live holds, **by identity**.
  ///
  /// A `Set` rather than a map keyed by tag: two pages may legitimately hold
  /// two different machines, and a map keyed by key would silently drop one of
  /// two holds on the *same* tag — leaving a handle whose owner still believes
  /// it will be released on teardown.
  final Set<HoldHandle> _live = <HoldHandle>{};

  /// How many holds are live. Diagnostics and tests.
  int get liveHolds => _live.length;

  /// Engages the deadman on [key].
  ///
  /// The engage writes [startCounter] to the tag and its three-state outcome
  /// becomes `HoldHandle.engagement`. Only an applied engage produces a handle
  /// that can be fed: a refusal, and equally an outcome nobody knows, comes
  /// back already released with [HoldEnded.refused]. That second case is
  /// deliberate and is not over-caution — a hold you cannot be sure the plant
  /// took is one you must not feed, because the operator would be holding a
  /// button that may be doing nothing while the panel tells them it is doing
  /// something.
  ///
  /// [startCounter] exists for one arm and is documented as such, exactly as
  /// `HoldHandle.startCounter` is: it is the only way to reach the wrap case
  /// without holding a button for 6.8 years. Production callers leave it at 1.
  Future<HoldHandle> engage(String key, {int startCounter = 1}) async {
    late final HoldHandle handle;
    handle = HoldHandle(
      key: key,
      engagement: await _engageWrite(key, startCounter),
      startCounter: startCounter,
      onTick: (counter) => _onTick(key, counter),
      onRelease: (counter) => _stop(handle, key, counter),
    );
    if (handle.isHeld) _live.add(handle);
    return handle;
  }

  /// The engage write, with a throw converted into an outcome.
  ///
  /// The write path promises not to throw to report an outcome, and this is
  /// the one place a hold could still be told about a failure as an exception:
  /// a throw out of `holdToRun` reaches the page as "something went wrong",
  /// and the page has a jog button to decide about either way. A throw here is
  /// a bug rather than news about a plant, and the honest report of a bug on
  /// the write path is still "nobody knows".
  Future<WriteResult> _engageWrite(String key, int startCounter) async {
    try {
      return await _feed(key, startCounter);
    } catch (error) {
      _report('hold registry: the engage write for "$key" failed', error);
      return WriteUnknown(
          newUlid(),
          const WriteReason('write_path_failed',
              message: 'the engage could not be sent, so whether this hold '
                  'was taken is not established; the handle is inert'));
    }
  }

  /// Stops feeding [handle] and writes the zero.
  ///
  /// The handle has already marked itself not-held by the time this runs, so
  /// the machine is stopping regardless of what the write answers. The outcome
  /// is returned so the release's three-state answer reaches the caller.
  ///
  /// The removal is **synchronous**, which is one of the two shapes this
  /// extraction had to choose between: pruning a microtask later (from
  /// `onReleased.then`) is also correct, but it forces a teardown to clear the
  /// set *before* its release loop rather than after, and that ordering trap is
  /// the kind that survives a refactor by looking like a tidy-up.
  Future<WriteResult> _stop(HoldHandle handle, String key, int counter) {
    _live.remove(handle);
    return _feed(key, counter);
  }

  /// Releases every live hold, because the source is going away.
  ///
  /// Idempotent, and idempotent twice over: the set is emptied here and
  /// `HoldHandle.release` is itself idempotent, so a disconnect racing an
  /// operator's finger cannot put two zeros on the wire.
  ///
  /// One throwing release does **not** stop the others. A teardown that
  /// abandoned the remaining holds because one write failed is the one shape
  /// of this feature that could hurt somebody.
  Future<void> releaseAll({HoldEnded reason = HoldEnded.disposed}) async {
    if (_live.isEmpty) return;
    final holds = List<HoldHandle>.of(_live);
    // Belt and braces since [_stop] prunes synchronously: with the microtask
    // form this line was load-bearing, and it is kept because a teardown that
    // empties the set up front cannot be made wrong by a later change to when
    // pruning happens.
    _live.clear();
    for (final handle in holds) {
      final released = handle.release(reason: reason).catchError(
          (Object error, StackTrace stack) {
        _report(
            'hold registry: the release write for "${handle.key}" failed '
            'during teardown — the counter has already stopped, so the '
            'machine is stopping either way',
            error);
        return WriteUnknown(
            newUlid(),
            const WriteReason('write_path_failed',
                message: 'a teardown release was lost on the way out'))
            as WriteResult;
      });
      if (_awaitReleases) await released;
    }
  }

  void _report(String message, Object? error) {
    final sink = _onLostWrite;
    if (sink != null) sink(message, error);
  }
}
