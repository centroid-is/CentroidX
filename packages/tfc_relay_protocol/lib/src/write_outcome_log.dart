/// What a source has witnessed happen to a write, and — just as load-bearing —
/// the window it is entitled to have an opinion about.
///
/// This is the one copy. It was two: `WriteOutcomeLog` in `tfc_relay_server`
/// and `BackendWriteOutcomeLog` in `tfc_dart`, byte-identical across nine
/// members and with no comment on either side saying so. An **undeclared** copy
/// is worse than a declared one — there is not even a promise to break — and
/// the dating function both called had already drifted once (18-01). Merging
/// them before that was fixed would have been merging a bug.
///
/// ## `not_received` needs positive evidence
///
/// [WriteNotReceived] is the one verdict that tells an operator a second press
/// of a button is safe, and that button may already have moved a machine. It is
/// therefore never the default and never what absence alone buys. Two clocks
/// bound the claim, and both belong to the source making it:
///
///  * **[WriteOutcomeLog.startedAtMs]** — when this log began. A command minted
///    before that is one this source was not present for. Absence from a log
///    that did not exist yet is not evidence of anything, so the answer is
///    unknown.
///  * **`now()`** — a command minted in the *future* is a panel whose clock
///    runs ahead. `ClientConfig.implausibleClockThreshold` defaults to five
///    minutes and 04-CONTEXT rules that skew warns and keeps going, so skew of
///    that size is anticipated elsewhere. Unclamped, a panel ahead by Δ bought
///    itself a `not_received` window of `ttl + Δ`, and one ahead by more than
///    the elapsed time passed the check trivially, for ever.
///
/// Inside both bounds and absent from the log, `not_received` is a positive
/// claim: this source was up, it was recording, and it never saw the command.
///
/// **The four-piece rule that assembles those answers lives in the CALLERS, not
/// here.** This class holds entries and answers [WriteOutcomeLog.witnessed] and
/// [WriteOutcomeLog.insideWindow]; turning those into `unrecognized_cmd` /
/// `outcome_unwitnessed` / `not_received` / `outcome_expired` is each side's own
/// `_statusOf`. The two sides' operator-visible message strings differ today —
/// `tfc_dart` interpolates the TTL, the gateway does not — and unifying them
/// would be a behaviour change, so they stay different.
///
/// ## This log answers about the WIRE. `tfc_relay_local`'s answers about the PLANT
///
/// There is a **third** outcome log in this repo and it is deliberately not
/// this class. `LocalStateMan` (`tfc_relay_local/lib/src/local_state_man.dart`)
/// keeps its own, and it is a different design rather than a stale copy:
///
///  * **five answers, not four** — it adds `outcome_forgotten`, driven by a
///    `_forgottenBeforeMs` watermark moved by both cap eviction and TTL prune,
///    so a command from an evicted era is never told `not_received`. The log
///    remembers that it forgot;
///  * it is **capped** at 4096 entries with LRU eviction, where this one is
///    unbounded in count (see [WriteOutcomeLog]);
///  * its TTL is **10 minutes**, against this one's 60 seconds.
///
/// The reason they must not be merged is not the member list, it is the
/// question each answers. **This log answers whether a FRAME ARRIVED. The
/// plant-side log answers whether a PLANT WAS ASKED.** A gateway restart resets
/// one and not the other. Pretending they were the same would let a
/// `writeStatus` claim knowledge of a write that never reached a PLC — which is
/// the exact failure the three-state write outcome exists to prevent.
///
/// If you have arrived here intending to "finish the job" by folding the third
/// design in: that is the sentence to read again first, and the mirror of this
/// paragraph is at `local_state_man.dart`'s own note.
library;

import 'json_equality.dart';
import 'write_result.dart';

/// The write a recorded outcome belongs to: the tag, the payload, and the
/// compare-and-set guard it was sent under.
///
/// A record rather than three loose fields on the entry, because the question
/// asked of it is one question — "is the frame in my hand the same operator
/// action as the one I already answered?" — and three fields are three
/// comparisons that can drift apart. A `matches` written half-way (key only, or
/// key and value) is the failure mode this shape exists to make awkward, and
/// [WriteOutcomeEntry.matches] is the single place it is answered.
///
/// **`expect` is in here deliberately** (05-03 D-P5-B). "Set 1450" and "set
/// 1450 only if it still reads 1200" are two different operator intents;
/// answering the unguarded one from the guarded one's log entry would report
/// that a check passed which was never made.
typedef WriteFingerprint = ({String key, Object? value, Object? expect});

/// One recorded write outcome, the instant it was recorded, the request it was
/// recorded for, and who recorded it.
final class WriteOutcomeEntry {
  const WriteOutcomeEntry(this.result, this.atMs, this.fingerprint,
      {this.ownerHint});

  /// What became of the write. In-flight writes are recorded too, as
  /// [WriteUnknown]: a `writeStatus` crossing a write that is still upstream
  /// must not answer `not_received` about a command on its way to a machine.
  final WriteResult result;

  /// The recording source's clock when this was recorded.
  final int atMs;

  /// The write this outcome is about.
  ///
  /// **Required and non-nullable, and that is the one place this shared class
  /// deliberately differs from the `tfc_relay_server` copy it replaces.** That
  /// copy allowed a null fingerprint and handled it with a `mine == null ->
  /// false` branch in [matches] — a match that silently never matches. The
  /// branch was already dead in production: the server's own doc recorded that
  /// "both record sites in `value_handlers.dart` have the decoded
  /// [WriteParams] in scope", so nothing but a test ever built one.
  ///
  /// Making the unsafe state unrepresentable beats handling it, and no
  /// behavioural test can tell the two shapes apart — both refuse a replay — so
  /// the guard against reverting this is a **structural** arm in
  /// `write_outcome_log_test.dart`, not a behavioural one.
  final WriteFingerprint fingerprint;

  /// The session that issued the write, for the Phase 6 narrowing. Carried,
  /// never read as a filter today — a reconnect is by definition a different
  /// session, and filtering on it would rebuild the defect this log exists to
  /// fix (04-REVIEW CR-02).
  ///
  /// **Phase 6 landed identity and deliberately did not narrow on it.** The
  /// hint is still the session id. `RelaySession.identity` now exists and
  /// carries a `stationId`, so the narrowing 06-RESEARCH §E.6 offers as cheap
  /// is finally *possible* — and it is still wrong while this field holds a
  /// session id, because a reconnecting panel is a new session with a new id
  /// and every post-reconnect `writeStatus` would be filtered to nothing.
  ///
  /// **The prerequisite, so the next reader does not have to re-derive it:**
  /// narrowing becomes correct once the hint carries the **stationId**, which
  /// is stable across reconnects. Changing the recorded field on its own is not
  /// the work — a field whose meaning changed with no consumer is a change
  /// nobody can test — so whoever does it lands the recorder and the filter
  /// together, with a case that reconnects and still gets its answer.
  ///
  /// Only `tfc_relay_server` supplies one; `tfc_dart` never has.
  final String? ownerHint;

  /// Whether [other] is the same write this outcome was recorded for.
  ///
  /// The key compares as a string; the value and the guard compare with
  /// [jsonEquals], which is deep, insensitive to JSON object key order, and
  /// holds numbers to their runtime type so a DINT `1` and a REAL `1.0` stay
  /// two different writes. `DynamicValue.operator ==` would compare quality and
  /// sourceTime that a write payload does not have, and comparing encoded
  /// strings would make key order significant — both are argued out in
  /// `json_equality.dart`'s library doc.
  ///
  /// The caller is the idempotency window at each side's duplicate-cmd
  /// decision. The payload it hands over has been through `sanitize` at
  /// ingress, which is what bounds the depth [jsonEquals] recurses to.
  bool matches(WriteFingerprint other) =>
      fingerprint.key == other.key &&
      jsonEquals(fingerprint.value, other.value) &&
      jsonEquals(fingerprint.expect, other.expect);
}

/// Every write outcome a source is still prepared to speak about.
///
/// One per server or per backend, never per session: the only path that ever
/// runs `writeStatus` is a client re-querying after a link death, and after a
/// link death the session is always a new one. A log that died with the socket
/// was therefore always empty at exactly the moment it was asked, and an empty
/// log answered [WriteNotReceived] — the one verdict that invites a second
/// press — for precisely the commands whose fate was unknown. That was
/// 04-REVIEW CR-02, and it is why this object outlives every socket.
///
/// Pruned on access rather than by a timer: it is data with a clock passed in,
/// not a scheduler, so a test models a stale entry with arithmetic instead of a
/// sleep.
///
/// **Bounded in time, unbounded in count.** There is no cap and no eviction;
/// the only thing that removes an entry is age. That is safe as far as
/// `outcome_forgotten` goes — there is no eviction era to remember, which is
/// why this class needs four answers where `tfc_relay_local`'s needs five — but
/// it is a growth path under a held deadman, where `tfc_dart` records every
/// tick. The current behaviour is pinned deliberately by an arm in
/// `write_outcome_log_test.dart` so that a later change to it is visible.
final class WriteOutcomeLog {
  WriteOutcomeLog({required this.ttl, required this.now})
      : startedAtMs = now();

  /// How long an outcome is kept, and the width of the `not_received` window.
  ///
  /// Readable because a caller interpolates it into the operator-visible
  /// `outcome_expired` message; a log that would not say its own TTL would
  /// force every caller to hold a second copy of it.
  final Duration ttl;

  /// Wall-clock epoch milliseconds, injected: every promise here is arithmetic
  /// about *when*.
  final int Function() now;

  /// This source's own clock at the moment the log began recording.
  ///
  /// The lower bound on every `not_received`. On a running server or backend
  /// that is boot time, so the window opens once and stays open across every
  /// reconnect — which is the difference between "I was watching and it never
  /// came" and "I have only just started watching".
  final int startedAtMs;

  final _entries = <String, WriteOutcomeEntry>{};

  /// How many outcomes are being held. Read by the arms that pin the log's
  /// bound (T-04-06); nothing in production depends on it.
  int get recordedOutcomes => _entries.length;

  /// Records [result] for [cmd], replacing whatever was there.
  ///
  /// [fingerprint] is the write the outcome is about, carried so a later frame
  /// under the same id can be told from it — see [WriteOutcomeEntry.matches].
  /// It is **required**: see [WriteOutcomeEntry.fingerprint].
  void record(String cmd, WriteResult result,
      {String? ownerHint, required WriteFingerprint fingerprint}) {
    prune();
    _entries[cmd] =
        WriteOutcomeEntry(result, now(), fingerprint, ownerHint: ownerHint);
  }

  /// The entry held for [cmd] after pruning, or null.
  WriteOutcomeEntry? entryFor(String cmd) {
    prune();
    return _entries[cmd];
  }

  /// Whether this log was recording when [mintedAtMs] was minted, and whether
  /// that instant is one this source's clock can vouch for.
  ///
  /// False for a command from before [startedAtMs] and for one from the future.
  /// Both are the "forgetting is not evidence" case wearing different clothes,
  /// and both must answer unknown rather than never-received.
  ///
  /// Both bounds are **inclusive**: minted exactly at [startedAtMs], or exactly
  /// at `now()`, is witnessed.
  bool witnessed(int mintedAtMs) =>
      mintedAtMs >= startedAtMs && mintedAtMs <= now();

  /// Whether [mintedAtMs] is inside the window this log still answers for.
  ///
  /// **Inclusive at the TTL**: `now() - mintedAtMs == ttl` is inside. The flip
  /// to an exclusive bound is a one-character mutation and it changes which
  /// verdict an operator is given, so it is pinned directly.
  bool insideWindow(int mintedAtMs) =>
      now() - mintedAtMs <= ttl.inMilliseconds;

  /// Drops everything past the TTL.
  void prune() {
    final horizon = now() - ttl.inMilliseconds;
    _entries.removeWhere((_, entry) => entry.atMs < horizon);
  }
}
