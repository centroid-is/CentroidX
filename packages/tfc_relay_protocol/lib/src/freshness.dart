/// The freshness kernel: how often to look, and whether a value has gone quiet.
///
/// Two sweeps in this repo notice silence — `BackendFreshnessSweep` in
/// `tfc_dart`, a decorator over `BackendValueSource` that ages only *watched*
/// keys, and `FreshnessSweep` in `tfc_relay_local`, a sweep over a whole
/// `ValueStore` that also answers the read path. **Those two objects are not
/// two copies of one thing and they stay where they are.** What they share, and
/// shared verbatim before this file existed, is the thirty lines below: one
/// cadence and one predicate.
///
/// The failure both exist to prevent is the one PROJECT.md names as the reason
/// the project exists. A frozen OPC UA session, a PLC that stopped scanning and
/// a weigher that answered its last frame an hour ago all look, to an
/// event-driven pipeline, exactly like a tag that has not changed — a plausible
/// number under a good quality. A watchdog carried twice is a watchdog that can
/// be corrected in one copy.
///
/// ## The cadence, and why a quarter
///
/// Two costs pull against each other. The interval bounds how late a stale
/// badge can be: at a quarter, a value is reported stale within 125 % of its
/// deadline rather than within 200 %, and that margin is what keeps a freshness
/// case green on a loaded machine instead of racing its own budget. Against
/// that, it is CPU spent whether or not anything is wrong — at a 10 s deadline
/// this is one pass every 2.5 s, which on a page of 1500 keys is 1500 map
/// lookups and a band comparison, and stages nothing at all unless something
/// has actually gone quiet.
///
/// [minimumFreshnessInterval] is the floor under that, and it is a denial-of-
/// service guard rather than a nicety: `staleAfter` arrives from a
/// configuration file, and an implausibly short one would otherwise turn the
/// sweep into a busy loop on the one isolate serving every client.
///
/// ## The anchor is elapsed milliseconds, and there is deliberately no seam
///
/// [isStaleNow] takes two `int` millisecond readings and never a `DateTime`,
/// and it offers **no clock argument to hand in**. *How long since this value
/// arrived* is an elapsed-time question, and the wall clock steps: NTP corrects
/// it, an operator sets it, a suspended VM resumes with a different one, DST
/// moves it twice a year. A backwards correction larger than `staleAfter` made
/// the old subtraction negative for every key in the store **at once**, so the
/// sweep degraded nothing and the whole plant read fresh from PLCs nobody had
/// heard from (08-REVIEW CR-02, fixed client-side in `6a499d65`); a forward
/// step did the mirror image and greyed every panel at once.
///
/// A seam that accepts a steppable clock is a seam somebody steps, and an
/// injected clock is precisely the machinery that stops testing a watchdog: a
/// source that never runs its sweep passes every fake-clock case and shows a
/// frozen-fresh page in the plant. Both callers pass readings off a monotonic
/// counter; a negative difference is a caller bug, and it reads *not stale*
/// here rather than throwing, which is the verdict both copies gave.
///
/// ## Degrade only
///
/// A key already carrying news at or worse than [Quality.badStale]'s band is
/// left alone. If the sweep could *raise* a quality, an operator would watch a
/// fault clear itself while the fault was still happening — the same lie as a
/// stale value, arrived at from the other direction and harder to catch
/// because it looks like recovery. The comparison is on the **band** and not
/// on one code, so a code invented in a later phase is handled correctly on the
/// day it is invented. It is also what makes the cadence cheap: a quiet plant
/// stages nothing and costs a listening page zero rebuilds.
///
/// ## Why `PIPE.` is skipped
///
/// A health key changes on *a cadence this predicate cannot see*. The link
/// either moves or it does not, so on a healthy pipe `PIPE.connected` is
/// **always** older than any freshness deadline; staling it greys out the one
/// indicator an operator uses to decide whether to believe the rest of the
/// screen, and greys it out exactly when nothing is wrong (HLTH-02, found on
/// `days_to_expiry` in 06-09). The skip is [PipeKeys.isPipeKey] — a prefix
/// test, never an enumerated roster. An enumerated list is a list a new key
/// gets added outside of, and the prefix is what makes a health key invented in
/// a later phase correct on the day it is invented.
///
/// ## Why `ALARM.` is skipped, which is a different reason
///
/// Alarm state changes on *events*. The engine republishes the active set when
/// a rule transitions and at no other time, so on a healthy plant the last
/// publish is arbitrarily old and that is exactly what "no alarms" looks like.
/// Silence here is news, not the absence of news, and badging it stale greys
/// out the alarm banner on a plant where nothing is wrong (D-9, P-6).
///
/// **These are two reasons and therefore two arguments, not one skip set.**
/// A single `Set<String> skipPrefixes` would read as one rule and would let the
/// two quietly collapse; `alarm_keys.dart` pins that neither prefix is a prefix
/// of the other for the same reason. [skipAlarmKeys] is **required and has no
/// default**: a default is what made this an invisible divergence in the first
/// place — one sweep skipped alarm keys, one did not, and neither file said the
/// other existed. Required, the difference is two call sites a reader can
/// compare.
///
/// `tfc_dart`'s backend sweep passes `true`, because that is where the
/// `AlarmEngine` publishes. `tfc_relay_local`'s gateway sweep passes `false`,
/// and that is **correct rather than an oversight**: no alarm producer writes
/// into that store — the only engine is `tfc_dart`'s and it publishes into
/// `PipeMainEndpoint.store`, `tfc_relay_local/lib` references `AlarmKeys`
/// nowhere, and the sweep can only stale a key with an entry in `_lastArrival`,
/// which is written only for keys that genuinely arrived from an upstream link.
/// A key literally named `ALARM.*` in a gateway keymapping is an ordinary plant
/// tag with an unfortunate name, and staling it is the right answer.
library;

import 'alarm_keys.dart';
import 'pipe_keys.dart';
import 'quality.dart';

/// The floor under [freshnessIntervalFor]. See the library doc.
const Duration minimumFreshnessInterval = Duration(milliseconds: 5);

/// A quarter of [staleAfter], floored at [minimumFreshnessInterval].
///
/// One answer for both sides of the pipe: the two sweeps having one number is
/// worth more than a second opinion. See the library doc for the two costs the
/// quarter is balancing and for why the floor exists.
Duration freshnessIntervalFor(Duration staleAfter) {
  final quarter = staleAfter ~/ 4;
  return quarter < minimumFreshnessInterval ? minimumFreshnessInterval : quarter;
}

/// Whether [key] has gone unheard-of for longer than [staleAfter].
///
/// Four conditions, each of which is a decision argued in the library doc:
///
///  * **`PIPE.` keys are skipped by prefix** — always, whatever
///    [skipAlarmKeys] says. They change on a cadence this predicate cannot see.
///  * **`ALARM.` keys are skipped by prefix when, and only when, the caller
///    asks.** A second prefix for a second reason, kept as its own required
///    argument so the two can never quietly become one.
///  * **A key with no recorded arrival is not stale.** [lastHeardMs] of `null`
///    means nothing has ever come for it, so it is `uncertainNotYetKnown` and
///    not stale — different statements, and the second implies the first was
///    once true. There is no silence to notice.
///  * **A key already at or worse than [Quality.badStale]'s band is not
///    stale.** Degrade only; see the library doc.
///
/// [lastHeardMs] and [nowMs] are two readings of one **elapsed** counter, in
/// milliseconds. There is no clock argument, deliberately.
bool isStaleNow({
  required String key,
  required Quality quality,
  required int? lastHeardMs,
  required int nowMs,
  required Duration staleAfter,
  required bool skipAlarmKeys,
}) {
  if (PipeKeys.isPipeKey(key)) return false;
  if (skipAlarmKeys && AlarmKeys.isAlarmKey(key)) return false;
  if (lastHeardMs == null) return false;
  // Two readings of a monotonic counter. The subtraction that used to be here
  // took two `DateTime.now()` readings, and a backwards NTP step made it
  // negative for every key at once — the sweep then degraded nothing and the
  // whole plant read fresh (08-REVIEW CR-02).
  if (nowMs - lastHeardMs < staleAfter.inMilliseconds) return false;
  if (Quality.badStale.band <= quality.band) return false;
  return true;
}
