/// The clock that notices silence — and only runs while somebody is watching.
///
/// ## Why a clock at all
///
/// Staleness is a function of time, not of events. The failure this exists to
/// make visible **emits nothing**: a frozen OPC UA session, a PLC that stopped
/// scanning, a weigher that answered its last frame an hour ago. Every one of
/// those looks, to an event-driven pipeline, exactly like a tag that has not
/// changed — and a plausible number under a good quality is the single failure
/// PROJECT.md names as the reason the whole project exists. The shipped stack
/// has `staleAfter` declared and **nothing sweeping for it**, which is that
/// failure waiting to happen on the gateway side.
///
/// ## Why it is listener-gated, and what that costs
///
/// `ClientWrapper`'s effective-status timer is the in-repo pattern and this
/// copies its **three properties**, not just its shape
/// (`packages/tfc_dart/lib/core/state_man.dart:966-992`):
///
///  1. **The clock only runs while someone is watching** (`:970-975`). An
///     always-on `Timer.periodic` leaks past every test that builds a source
///     without draining it ("A Timer is still pending…"), and an unobserved
///     gateway has nobody to tell anyway. The gate here is the fan-in's watcher
///     count: [start] on the transition from zero, [stop] on the return to it.
///  2. **The verdict is re-derived on read, so nothing goes stale while the
///     timer is parked** (`:1000`, `:1005-1031`). [judge] is that
///     re-derivation, and it is what makes the gate *safe* rather than merely
///     cheap — a read taken after an unwatched hour is still correct.
///  3. **A recompute bails when nothing would change** (`:1033-1038`). Here
///     that is the band comparison in [sweep]: a key already carrying worse
///     news than `badStale` stages nothing, so the four-times-per-deadline
///     cadence costs a listening page zero rebuilds until something actually
///     moves.
///
/// The reference implementation's watchdog is always-on
/// (`fake_state_man.dart:71`) — **that is a fake's licence and not a
/// gateway's**. A fake exists for the length of one test; this object exists
/// for the length of a plant shift.
///
/// ## The fourth property: the age is asked of an elapsed clock
///
/// `ClientWrapper`'s three properties are above; this one is 07-REVIEW CR-01's,
/// and it is the reason this file takes an `int Function()` rather than a
/// `DateTime Function()`. *How long since this value arrived* is an
/// elapsed-time question, and `DateTime.now()` steps: NTP corrects it, an
/// operator sets it, a suspended VM resumes with a different one. A backwards
/// correction larger than [staleAfter] made the old subtraction negative for
/// **every key in the store at once**, so this swept nothing and the read
/// path's [judge] agreed with it — the whole plant reading fresh from PLCs
/// nobody had heard from. A forward step did the mirror image and greyed
/// everything.
///
/// The client was fixed for this in `6a499d65`; 08-REVIEW CR-02 found the same
/// arithmetic gateway-side, where it costs every panel rather than one. There
/// is deliberately **no wall-clock seam left to hand in** (07-REVIEW's note on
/// `c4e62845`): a seam that accepts a steppable clock is a seam somebody steps.
///
/// ## Why health keys are skipped by prefix
///
/// 06-09 found the trap on `days_to_expiry`: a value that changes once a day is
/// *always* older than any freshness deadline, so freshness accounting greys
/// out the indicator permanently and precisely while nothing is wrong. **The
/// trap is not specific to that key.** `PIPE.upstream.<alias>.connected`,
/// `.birth_count`, `.last_death_at`, `.state`, `.epoch` and `PIPE.connected`
/// itself all change only on an event, and every one of them would grey out the
/// same way (08-RESEARCH §D.3).
///
/// So the skip is [PipeKeys.isPipeKey] — a **prefix test**, never an enumerated
/// list. An enumerated list is a list a new key gets added outside of, and the
/// symptom of forgetting is an indicator that reads stale exactly when an
/// operator is deciding whether to believe the rest of the screen.
///
/// ## Freshness is anchored per link as well as per key (HARD-01)
///
/// A key's age is measured from the **later** of two anchors: the last value
/// heard for that key, and the last time its link spoke — by any value on
/// it, or by a proof of life (`LinkLiveness`). The per-key anchor alone was
/// the defect the backend measured on the plant on 2026-09-16 and fixed in
/// `16024ca80` ("a link's keep-alive proves its values, as OPC UA does"):
/// OPC UA notifies on **change**, so a healthy line's stable signals — a
/// stopped drive's 0 Hz, a setpoint, a mode in auto all shift — arrive once
/// and then never again, and the sweep badged 1103 of 1437 values `badStale`
/// while the PLC was fine. That fix landed only in
/// `tfc_dart/lib/core/relay/backend_freshness.dart`; this sweep never got
/// it, and the same stack measured it here: a node published every 200 ms
/// with an unchanging value went 192 → 516 at t≈2.5 s against a 2 s deadline
/// with the link healthy throughout. Two sweeps disagreeing on the one
/// question they exist to answer is precisely what `freshness.dart`'s doc
/// says must never happen.
///
/// A data change on any tag of a session proves that session's publish loop
/// alive, and a monitored item on a live session that has not notified has
/// not changed — that is what the protocol promises; a heartbeat sample
/// proves the same thing with no tag attached. So the link's last arrival
/// vouches for its constant tags. What it cannot vouch for is a link nobody
/// has heard from at all: a frozen session or a PLC that stopped scanning
/// goes quiet on every tag at once, the link anchor ages with them, and every
/// key on it still goes stale at the deadline — which is the failure this
/// file exists to catch, and it is caught exactly as before. The trade is a
/// single blackholed tag on an otherwise talking link, which now reads
/// fresh; the backend's doc records why that window was already accepted.
///
/// `linkAnchor` is a seam and not a lookup this file does itself: the
/// composer knows which alias serves a key and keeps the per-alias instant
/// in its health producer, and hands in one function. Without it the sweep
/// is per-key, as it was — a fake built without one is judged exactly as
/// before, which is what keeps the dead-link cases honest.
///
/// **Still degrade-only.** The backend's port also restores a badge it put on
/// when the link speaks again; this sweep does not, because the kernel's
/// doc rules a sweep must never raise a quality, and a raise is a decision
/// for the person who owns that rule rather than a line smuggled into a port.
/// The window it leaves is recorded rather than hidden: a key badged between
/// the deadline and the OPC UA wrapper's 15 s heartbeat verdict stays badged
/// until it changes or the session cycles.
library;

import 'dart:async';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// Re-evaluates every key's age and degrades the ones past the deadline.
final class FreshnessSweep {
  FreshnessSweep({
    required this.staleAfter,
    required ValueStore store,
    required Map<String, int> lastArrival,
    required void Function(Map<String, DynamicValue>) degrade,
    required int Function() elapsedMs,
    int? Function(String key)? linkAnchor,
  })  : _store = store,
        _lastArrival = lastArrival,
        _linkAnchor = linkAnchor,
        _degrade = degrade,
        _elapsedMs = elapsedMs;

  /// How long a value may go unheard-of before it must stop claiming to be
  /// current.
  final Duration staleAfter;

  final ValueStore _store;

  /// Arrival instants **on the elapsed anchor**, in milliseconds. Owned by
  /// `LocalStateMan` and read here.
  final Map<String, int> _lastArrival;

  /// When [key]'s link last spoke, on the same anchor, or null for a key no
  /// link serves or a sweep built without the seam. See the library doc.
  final int? Function(String key)? _linkAnchor;
  final void Function(Map<String, DynamicValue>) _degrade;

  /// The elapsed clock, and there is deliberately no wall-clock alternative to
  /// hand it — see the library doc's fourth property.
  final int Function() _elapsedMs;

  /// The floor under [intervalFor]. [minimumFreshnessInterval], under this
  /// object's own name.
  ///
  /// An implausibly short deadline out of a configuration file must not turn
  /// the sweep into a busy loop on the one isolate serving every client.
  static const Duration minimumInterval = minimumFreshnessInterval;

  /// A quarter of the deadline, floored — [freshnessIntervalFor].
  ///
  /// The arithmetic lives in `tfc_relay_protocol` because the backend's
  /// `BackendFreshnessSweep` needs the same answer and used to reach it by
  /// carrying the same four lines. The reasoning is in that file's library doc.
  /// Kept as a static member here because callers and cases name it.
  static Duration intervalFor(Duration staleAfter) =>
      freshnessIntervalFor(staleAfter);

  /// This sweep's cadence.
  Duration get interval => intervalFor(staleAfter);

  /// The clock. A named field, in the one file `freeze_test.dart`'s
  /// `periodicTimerAllowList` names.
  Timer? _timer;

  /// Whether the clock is running right now.
  bool get running => _timer != null;

  /// How many passes have been made. A diagnostic, and the observable that
  /// tells a case the gate actually opened.
  int get sweeps => _sweeps;
  int _sweeps = 0;

  /// Somebody started watching.
  ///
  /// Sweeps once immediately, for `ClientWrapper._startHealthTimer`'s reason
  /// (`state_man.dart:977-979`): the state the new watcher is about to read may
  /// predate them, and waiting a quarter of a deadline to tell them so is a
  /// quarter of a deadline of a number they should not have believed.
  void start() {
    if (_timer != null) return;
    sweep();
    _timer = Timer.periodic(interval, (_) => sweep());
  }

  /// Nobody is watching any more.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass over the store.
  ///
  /// Three rules, and each one is a decision:
  ///
  ///  * **Health keys are skipped by prefix** (HLTH-02, see the library doc).
  ///  * **A key with no recorded arrival is skipped.** Nothing has ever come
  ///    for it, so it is `uncertainNotYetKnown` and not stale — those are
  ///    different statements and the second one implies the first was once
  ///    true.
  ///  * **A key already carrying worse news stages no change.** The comparison
  ///    is `Quality.badStale.band <= cached.quality.band`, deliberately *not*
  ///    `Quality.worst`: worst-wins would return the same verdict but would
  ///    stage a value, and a staged value that happens to equal the cached one
  ///    still costs an allocation and a comparison per key per tick. More to
  ///    the point, a key needing no change should notify nobody
  ///    (`fake_state_man.dart:517`, `:570`).
  void sweep() {
    _sweeps++;
    final now = _elapsedMs();
    final stale = <String, DynamicValue>{};
    for (final key in _store.keys) {
      final cached = _store.peek(key);
      if (cached == null) continue;
      if (!_isStale(key, cached, now)) continue;
      // copyWith carries sourceTime through untouched. A degradation is not
      // news from upstream, and restamping it would make the value look freshly
      // delivered at the exact moment it stopped being trustworthy.
      stale[key] = cached.copyWith(quality: Quality.badStale);
    }
    if (stale.isEmpty) return;
    _degrade(stale);
  }

  /// The synchronous re-derivation: what [key] should read as *right now*.
  ///
  /// Property 2 of the three above. A caller on the read path gets the correct
  /// verdict whether or not a tick has happened since the deadline passed,
  /// which is what makes the listener gate safe. It does **not** write to the
  /// store: a read is not an event, and a read that notified every listener
  /// would make a diagnostics page's poll a rebuild storm.
  DynamicValue judge(String key, DynamicValue cached) =>
      _isStale(key, cached, _elapsedMs())
          ? cached.copyWith(quality: Quality.badStale)
          : cached;

  /// The shared predicate, with this sweep's alarm policy stated.
  ///
  /// **`skipAlarmKeys: false`, and that is a decision rather than an
  /// omission.** The backend's sweep passes `true` because that is where the
  /// `AlarmEngine` publishes; nothing writes an `ALARM.*` key into *this*
  /// store — this package references `AlarmKeys` nowhere, and [_lastArrival] is
  /// written in one place (`local_state_man.dart`'s `applyUpstreamBatch`) and
  /// therefore only for keys that genuinely arrived from an upstream link. A
  /// key named `ALARM.*` in a gateway keymapping is an ordinary plant tag with
  /// an unfortunate name, and staling it is correct. The argument is required
  /// so the two sides can be compared by reading them.
  bool _isStale(String key, DynamicValue cached, int nowMs) => isStaleNow(
        key: key,
        quality: cached.quality,
        lastHeardMs: _anchorOf(key),
        nowMs: nowMs,
        staleAfter: staleAfter,
        skipAlarmKeys: false,
      );

  /// The later of the key's own last arrival and its link's — or null when
  /// nothing has ever arrived for the key, whatever the link has been doing.
  ///
  /// The null rule is the kernel's: no data and stale are different
  /// statements, and a link chattering about other keys is not evidence this
  /// one ever produced a value. Same arithmetic as
  /// `BackendFreshnessSweep._anchorOf`, so the two sides of the pipe age a
  /// key the same way.
  int? _anchorOf(String key) {
    final own = _lastArrival[key];
    if (own == null) return null;
    final onLink = _linkAnchor?.call(key);
    return onLink == null || onLink < own ? own : onLink;
  }

  /// Teardown. A timer that outlives its source keeps the isolate alive and
  /// keeps sweeping a store nobody is watching, so a leak in one case surfaces
  /// as an inexplicable notification in the next one.
  void dispose() => stop();
}
