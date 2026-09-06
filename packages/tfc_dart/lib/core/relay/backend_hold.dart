/// The hold-to-run deadman, on the backend's write path.
///
/// A hold is an operator holding a button while a machine jogs. The safety
/// property is stated backwards from everything else this adapter promises:
/// nothing has to *arrive* for the machine to stop — the counter on the tag has
/// to **stop advancing**, and the PLC's own deadman window (~1 s, ~10 missed
/// ticks at 10 Hz) does the rest. `hold_handle.dart` argues that inversion at
/// length; this file is the transport under it.
///
/// ## What is here, and what deliberately is not
///
/// `HoldHandle` already owns the state machine: the counter, the wrap at the
/// signed-DINT ceiling, the inert handle for a refused engage, the idempotent
/// release. This file owns three things and nothing else:
///
///  * **the engage**, which is a real write on `BackendWrites`' path — same
///    three states, same no-repeat rule, same outcome log. 13-CONTEXT is
///    explicit that `holdToRun` is write-shaped and must not be silently
///    unsupported, so a handle is never handed back for a hold the plant did
///    not take;
///  * **the feed**, one write per tick, fire-and-forget with its own error
///    handler; and
///  * **a registry of live holds**, so a source torn down under an operator's
///    finger releases what it is holding rather than leaving a machine fed
///    through an object that no longer exists.
///
/// **There is no clock in this file.** Not a periodic one, not a one-shot one,
/// not a debounce. The caller chooses the cadence — 100 ms against a ~1 s PLC
/// deadman — precisely so that the thing keeping a machine alive is a finger
/// and not a scheduler. A source that helpfully kept a deadman fed would pass
/// every other property in the hold contract.
///
/// **Nothing here uses a bare fire-and-forget wrapper.** A future launched
/// without a handler still reaches the zone when it errors, and it fails
/// whichever unrelated test happens to be running when it lands rather than the
/// hold that stopped being fed. Every launched future below carries an explicit
/// `.catchError`. No teardown path has a deadline on it either: a release that
/// waited for the plant to confirm would hang on exactly the dead link that
/// caused the teardown.
///
/// Protocol types are imported `as relay`, the house rule inside `tfc_dart`.
library;

import 'package:logger/logger.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// How one counter value reaches the plant.
///
/// A function rather than a reference to `BackendWrites`, for
/// `write_translation.dart`'s reason about the classifier: a registry that
/// takes only "how to put a number on a tag" is testable with no pipe at all,
/// which is what makes the fire-and-forget arms affordable — and it cannot
/// reach for a second write path even if somebody later wanted one to.
typedef DeadmanFeed = Future<relay.WriteResult> Function(String key,
    int counter);

/// Every hold this source is currently keeping, and the one way to take one.
final class BackendHoldRegistry {
  BackendHoldRegistry({required DeadmanFeed feed, Logger? logger})
      : _feed = feed,
        _logger = logger ?? Logger();

  final DeadmanFeed _feed;
  final Logger _logger;

  /// The live holds, by identity.
  ///
  /// A `Set` rather than a map keyed by tag: two pages may legitimately hold
  /// two different machines, and a map keyed by key would silently drop one of
  /// two holds on the *same* tag — leaving a handle whose owner still believes
  /// it will be released on teardown.
  final Set<relay.HoldHandle> _live = <relay.HoldHandle>{};

  /// How many holds are live. Diagnostics and tests.
  int get liveHolds => _live.length;

  /// Engages the deadman on [key].
  ///
  /// The engage writes [startCounter] to the tag and its three-state outcome
  /// becomes `HoldHandle.engagement`. Only an applied engage produces a handle
  /// that can be fed: a refusal, and equally an outcome nobody knows, comes
  /// back already released with [relay.HoldEnded.refused]. That second case is
  /// deliberate and is not over-caution — a hold you cannot be sure the plant
  /// took is one you must not feed, because the operator would be holding a
  /// button that may be doing nothing while the panel tells them it is doing
  /// something.
  ///
  /// [startCounter] exists for one arm and is documented as such, exactly as
  /// `HoldHandle.startCounter` is: it is the only way to reach the wrap case
  /// without holding a button for 6.8 years. Production callers leave it at 1.
  Future<relay.HoldHandle> engage(String key, {int startCounter = 1}) async {
    late final relay.HoldHandle handle;
    handle = relay.HoldHandle(
      key: key,
      engagement: await _engageWrite(key, startCounter),
      startCounter: startCounter,
      onTick: (counter) => _tick(key, counter),
      onRelease: (counter) => _stop(handle, key, counter),
    );
    if (handle.isHeld) _live.add(handle);
    return handle;
  }

  /// The engage write, with a throw converted into an outcome.
  ///
  /// The write path promises not to throw to report an outcome, and this is the
  /// one place a hold could still be told about a failure as an exception: a
  /// throw out of `holdToRun` reaches the page as "something went wrong", and
  /// the page has a jog button to decide about either way.
  Future<relay.WriteResult> _engageWrite(String key, int startCounter) async {
    try {
      return await _feed(key, startCounter);
    } catch (error, stack) {
      _logger.e('backend hold: the engage write for "$key" failed',
          error: error, stackTrace: stack);
      return relay.WriteUnknown(
          relay.newUlid(),
          const relay.WriteReason('write_path_failed',
              message: 'the engage could not be sent, so whether this hold '
                  'was taken is not established; the handle is inert'));
    }
  }

  /// Feeds the deadman once.
  ///
  /// Fire-and-forget by construction: safety comes from the counter STOPPING,
  /// so giving a tick an outcome would invite somebody to await it, and
  /// awaiting liveness is how a stalled link becomes a queue. The handler is
  /// explicit because the alternative reaches the zone.
  void _tick(String key, int counter) {
    _feed(key, counter).catchError((Object error, StackTrace stack) {
      _logger.w('backend hold: a tick on "$key" was lost ($error) — the '
          'counter will be fed again by the caller\'s next tick, and if it is '
          'not, the PLC\'s own deadman window stops the machine');
      return relay.WriteUnknown(
          relay.newUlid(),
          const relay.WriteReason('write_path_failed',
              message: 'a deadman tick was lost on the way out')) as
          relay.WriteResult;
    });
  }

  /// Stops feeding [handle] and writes the zero.
  ///
  /// The handle has already marked itself not-held by the time this runs, so
  /// the machine is stopping regardless of what the write answers. The outcome
  /// is returned so the release's three-state answer reaches the caller.
  Future<relay.WriteResult> _stop(
      relay.HoldHandle handle, String key, int counter) {
    _live.remove(handle);
    return _feed(key, counter);
  }

  /// Releases every live hold, because the source is going away.
  ///
  /// The release writes are **not** awaited and have no deadline on them: the
  /// counter stops synchronously inside `HoldHandle.release`, and a teardown
  /// that waited for the plant to confirm would hang on exactly the dead link
  /// that caused it. A disposed panel that leaves a counter advancing is the
  /// one shape of this feature that could hurt somebody.
  void releaseAll() {
    for (final handle in List<relay.HoldHandle>.of(_live)) {
      handle
          .release(reason: relay.HoldEnded.disposed)
          .catchError((Object error, StackTrace stack) {
        _logger.w('backend hold: the release write for "${handle.key}" failed '
            'during teardown ($error) — the counter has already stopped, so '
            'the machine is stopping either way');
        return relay.WriteUnknown(
            relay.newUlid(),
            const relay.WriteReason('write_path_failed',
                message: 'a teardown release was lost on the way out')) as
            relay.WriteResult;
      });
    }
    _live.clear();
  }
}
