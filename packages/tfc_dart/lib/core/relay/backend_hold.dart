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
/// release. Since 18-05 the **registry** — the live set, the engage
/// throw-guard, release-all on teardown — is `relay.HoldRegistry`, shared with
/// `tfc_relay_local` because it was the same forty lines in both places. What
/// stayed here is what is genuinely this backend's:
///
///  * **the feed**, `BackendWrites.write`, which is what makes an engage and a
///    release ordinary commands with the same three states, the same no-repeat
///    rule and the same outcome log. 13-CONTEXT is explicit that `holdToRun` is
///    write-shaped and must not be silently unsupported, so a handle is never
///    handed back for a hold the plant did not take;
///  * **the tick**, one write per tick, fire-and-forget with its own error
///    handler. It stays a *separate* injected function rather than the feed
///    fired-and-forgotten, because `tfc_relay_local`'s tick path is a
///    different write path — it bypasses the outcome log on purpose. Folding
///    the two would have been a policy change dressed as a merge; and
///  * **the `Logger`**, which is why the shared registry takes an
///    `onLostWrite` callback instead of a logger: `tfc_relay_protocol` has zero
///    runtime dependencies and must keep them.
///
/// **There is no clock in this file.** Not a periodic one, not a one-shot one,
/// not a debounce. The caller chooses the cadence — 100 ms against a ~1 s PLC
/// deadman — precisely so that the thing keeping a machine alive is a finger
/// and not a scheduler. A source that helpfully kept a deadman fed would pass
/// every other property in the hold contract. The same prohibition is scanned
/// on the shared file by
/// `tfc_relay_protocol/test/hold_registry_source_test.dart`, because a pin that
/// reads a path stops holding what moves out of that path.
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
///
/// Structurally the same type as `relay.DeadmanFeed`; kept declared here
/// because it is this file's published name and `backend_hold_test.dart` and
/// `backend_writes.dart` both spell it.
typedef DeadmanFeed = Future<relay.WriteResult> Function(String key,
    int counter);

/// Every hold this source is currently keeping, and the one way to take one.
///
/// A thin wrapper over `relay.HoldRegistry` since 18-05: it holds the `Logger`,
/// owns the tick path, and answers the one question the two call sites answer
/// differently — see the `awaitReleases` line in the constructor.
final class BackendHoldRegistry {
  BackendHoldRegistry({required DeadmanFeed feed, Logger? logger})
      : _feed = feed,
        _logger = logger ?? Logger() {
    _registry = relay.HoldRegistry(
      feed: _feed,
      onTick: _tick,
      // **Difference 3, and it is now visible rather than structural.** This
      // side does not wait for the release writes: the machine stops when the
      // counter stops, which happens synchronously inside `HoldHandle.release`,
      // and a teardown that waited for a release to be confirmed would hang on
      // exactly the dead link that caused it.
      //
      // `tfc_relay_local` passes `true` and argues the opposite — its upstream
      // writes carry a *required* deadline, so nothing there can hang, and a
      // dispose that gave up half way leaves the thing it was disposing in a
      // state nobody owns. **That argument is the better one**, and changing
      // this `false` to `true` is a DEFERRED decision recorded in
      // 18-05-SUMMARY, not something a refactor gets to make.
      awaitReleases: false,
      onLostWrite: (message, error) => _logger.w(message, error: error),
    );
  }

  final DeadmanFeed _feed;
  final Logger _logger;
  late final relay.HoldRegistry _registry;

  /// How many holds are live. Diagnostics and tests.
  int get liveHolds => _registry.liveHolds;

  /// Engages the deadman on [key]. See `relay.HoldRegistry.engage`.
  ///
  /// Only an applied engage produces a handle that can be fed: a refusal, and
  /// equally an outcome nobody knows, comes back already released with
  /// [relay.HoldEnded.refused]. A throw on the way out becomes
  /// `WriteUnknown(write_path_failed)` rather than an exception at a page.
  Future<relay.HoldHandle> engage(String key, {int startCounter = 1}) =>
      _registry.engage(key, startCounter: startCounter);

  /// Feeds the deadman once.
  ///
  /// Fire-and-forget by construction: safety comes from the counter STOPPING,
  /// so giving a tick an outcome would invite somebody to await it, and
  /// awaiting liveness is how a stalled link becomes a queue. The handler is
  /// explicit because the alternative reaches the zone.
  ///
  /// On this side a tick is the full `write` path, so every tick is recorded in
  /// the outcome log and appends to `_mintedCmds`. That is a **known defect
  /// with a measured cost** — 36 000 entries per hour of held button — written
  /// up in 18-05-SUMMARY and deliberately not fixed inside an extraction.
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

  /// Releases every live hold, because the source is going away.
  ///
  /// Stays `void`, so `BackendWrites.dispose` cannot accidentally start waiting
  /// on it. The future the registry returns under `awaitReleases: false`
  /// completes on the next microtask and cannot fail — every release error is
  /// handled inside the registry, which is why there is no handler here and no
  /// bare fire-and-forget wrapper either.
  void releaseAll() {
    _registry.releaseAll(reason: relay.HoldEnded.disposed);
  }
}
