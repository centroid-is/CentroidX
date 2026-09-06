---
phase: 14-alarms-consolidated
plan: 12
subsystem: relay-pipe
tags: [alarms, wire-surface, authorization, tdd]
requires:
  - "14-03: AlarmKeys.active / AlarmKeys.isAlarmKey in tfc_relay_protocol"
  - "06-08: KeyPolicy / PolicyStateMan, the hiding rule and the write gate"
provides:
  - "Methods.ackAlarm — the forty-fourth callable name on the wire"
  - "AckAlarmParams — D-4's (alarm_uid, rule_index) and nothing else"
  - "AlarmAckSink — the seam an embedder fills with an alarm engine"
  - "AlarmHandlers — the handler body, behind the write-grade policy gate"
  - "RelayServer(alarmAcks:) / RelaySession.serve(alarmAcks:), both optional"
affects:
  - "14-13 (client): turns -32601 into an operator-grade sentence, and must keep it distinct from the no-engine refusal"
  - "the alarm engine in tfc_dart: implements AlarmAckSink and is passed at gateway construction"
tech-stack:
  added: []
  patterns:
    - "seam-by-injection: AlarmAckSink follows TokenValidator / KeyPolicy — an interface the embedder supplies, so a downstream package can be reached without a dependency cycle"
    - "existence-then-authorization: the hiding rule's ordering, reproduced from value_handlers.dart:416/:444"
    - "one gate expression, not two: AlarmHandlers and ValueHandlers are handed the same api.canWrite"
key-files:
  created:
    - packages/tfc_relay_server/lib/src/alarm_ack_sink.dart
    - packages/tfc_relay_server/lib/src/alarm_handlers.dart
    - packages/tfc_relay_server/test/alarm_ack_test.dart
    - packages/tfc_relay_protocol/test/ack_alarm_params_test.dart
  modified:
    - packages/tfc_relay_protocol/lib/src/methods.dart
    - packages/tfc_relay_protocol/lib/src/messages.dart
    - packages/tfc_relay_server/lib/src/relay_session.dart
    - packages/tfc_relay_server/lib/src/relay_server.dart
    - packages/tfc_relay_server/lib/tfc_relay_server.dart
    - packages/tfc_relay_server/test/surface_test.dart
    - packages/tfc_relay_server/test/session_hello_test.dart
    - packages/tfc_relay_server/test/subscribe_test.dart
decisions:
  - "The no-engine refusal is handlerFailed (-32011), not a new constant: error_codes.dart's rule is that a code exists so a client can behave differently, and there is no different behaviour available to a panel talking to a gateway composed without an engine"
  - "AlarmAckSink returns Future<void>, not a three-state outcome: an ack moves nothing in the plant, so a write's applied/rejected/unknown vocabulary would have no failure mode behind it"
  - "ackAlarm is registered unconditionally, so 'serves no alarm engine' stays distinguishable from 'too old to know the word' (-32601)"
metrics:
  duration: ~50 min
  tasks: 3
  commits: 5
  files-created: 4
  files-modified: 8
  completed: 2026-09-06
---

# Phase 14 Plan 12: Acknowledge on the wire — Summary

`ackAlarm` is now a name a connected panel may call, carrying D-4's
`(alarm_uid, rule_index)` and nothing else, answered by a gateway handler that
asks the same `KeyPolicy.canWrite` question a `write` asks — through the same
expression, not a second role comparison — before handing the acknowledge to an
`AlarmAckSink` an embedder supplied.

Jón's Q-1 ruling of 2026-09-06 governs it: *"The acknowledge is not used
anywhere yet. So let's relay it."* Nothing depended on the old behaviour, so
nothing was preserved and the ack was built properly.

## What shipped

**`Methods.ackAlarm`** (`methods.dart`) — spelled in full, unlike the hot-path
`u` and `h`, because an acknowledge is one frame per operator gesture. Its doc
carries the three things a reader will otherwise re-litigate: why an *action* is
an RPC when D-9 correctly made the active *set* a value key; why it carries no
`cmd` (idempotent by construction — the second ack of the same alarm is the same
intent as the first, so there is nothing for an idempotency key to protect and
no `ackStatus` to reconcile against); and why the RPC's answer is only the
gateway's acceptance, the operator's confirmation being the alarm leaving
`ALARM.active`.

**`AckAlarmParams`** (`messages.dart`) — two fields, `WriteParams`' shape, and
`HoldTickParams`' refusals verbatim including the `1e999` → `Infinity` defusal,
plus a negative-index refusal at both doors. No `historyId`: that would be a
second identity scheme for the same row, and two identities can disagree while
the frame still reads as valid.

**`AlarmAckSink`** (`alarm_ack_sink.dart`) — one member, `Future<void>`. This
package cannot name an alarm engine, because the engine lives in `tfc_dart`
which depends on this package, so the engine is injected in the style
`TokenValidator` and `KeyPolicy` are. Completing means applied; throwing means
not.

**`AlarmHandlers`** (`alarm_handlers.dart`) — four steps, and the order is the
decision: shape → existence from `api.keys` → authorization → the engine.
Authorization sits *below* existence so a hidden `AlarmKeys.active` takes the
nonexistent-tag path; answering `forbidden` there is the enumeration
`key_policy.dart:16-26` exists to prevent. The `forbidden` message names
`ackAlarm` and the role rule and never echoes the uid. Nothing in the file
registers anything — `data_handlers.dart:54`'s rule, kept.

**Registration** — through `_on`, the one seam where the hello gate and the
error armor are applied, immediately after `writeStatus` so the table reads as
the operator-action group. Registered on every session whether or not a sink was
supplied.

**`RelayServer.alarmAcks`** — optional, forwarded into `RelaySession.serve` the
way `policy` is. `tfc_relay_local` analyzes clean with no edit, which is the
proof that the parameter is compatible.

## Verification

| Suite | Before | After |
|---|---|---|
| `tfc_relay_protocol` | 319 pass | 327 pass |
| `tfc_relay_server` | 732 pass, 1 skip | 742 pass, 1 skip |
| `tfc_relay_local` `dart analyze lib` | clean | clean, untouched |

`dart analyze lib` clean in both edited packages. One package's suite at a time,
per ROADMAP Phase 12 Notes. The Postgres lane was not involved.

Acceptance greps: `ackAlarm = 'ackAlarm'` ×1, `protocolVersion = '2026-08-13'`
×1 (untouched), `registerMethod` in `alarm_handlers.dart` ×0, non-comment
`Role.` in `alarm_handlers.dart` ×0, `alarm_handlers.dart` on the barrel ×0.

## Sabotage — eight mutations, one of which found a hole

Applied from the committed GREEN tree, run, recorded, reverted. The verify
command (`git status --porcelain` over both `lib/` trees) prints `0`.

| # | Mutation | Arm that went red | What it printed |
|---|---|---|---|
| a1 | Delete the `canWriteKey` check | arm 2, plus 3 and 7 | *"a view station's ack was answered instead of refused"* |
| a2 | Move the gate **below** the sink call | arm 2, on its **second** assertion | `Expected: empty / Actual: [(ALM-01, 0)]` — the code was still `-32005`, so a code-only assertion would have passed this |
| b | `canWriteKey(request.alarmUid)` instead of `canWriteKey(AlarmKeys.active)` | arm 7, **alone** (9 pass, 1 fail) | `Expected: ['ALARM.active'] / Actual: ['ALM-9']` |
| c | Authorization **above** existence | arm 6 — **only after the arm was fixed**, see below | `Expected: not <-32005> / Actual: <-32005>` |
| d | Null-sink branch returns success | arm 4 | *"an ack on a gateway with no engine was answered instead of refused"* |
| e | Swallow the sink's exception | arm 5 | *"an ack a failing engine got was answered instead of refused"* |
| f | Register `ackAlarm` only when `alarmAcks != null` | arm 4 **first**, then arm 11, then 5 arms of `surface_test.dart` | arm 4: `Expected: not <-32601> / Actual: <-32601>` |
| g | Accept a negative `ruleIndex` | protocol arm 7 | `Expected: throws FormatException / Actual: <Closure: () => AckAlarmParams>` |

Two of these are worth more than a row.

**(a) is two mutations, not one, and it has to be.** The plan asks that *both*
of arm 2's assertions be shown to bite, and one `expect` failure per run means
that takes two mutations. (a1) deletes the gate and the arm dies at the refusal
itself. (a2) moves the gate below the sink call, which is the interesting one:
the answer is still `-32005 forbidden`, so the first assertion passes and the
arm survives on the code alone — and the second assertion catches that the alarm
had already been cleared before the refusal was written. That is exactly the
failure mode the plan predicted a code-only assertion would miss.

**(f) collapses the two answers into one, and arm 4 saw it before arm 11 did.**
With the registration made conditional, a gateway with no engine answers
`-32601` — indistinguishable from a gateway too old to know the word, which is
the distinction 14-13 is going to build an operator sentence on. Arm 11 (the
registration ledger) and five arms of `surface_test.dart` followed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Arm 6 was vacuous; sabotage (c) found it**

- **Found during:** Task 3, mutation (c)
- **Issue:** Moving the authorization check above the existence check left the
  whole file green. `_SpyPolicy` hid `AlarmKeys.active` and then authorized a
  write to it anyway — `canWrite` returned `role == operate` without consulting
  `hidden` — so with the gate saying yes either way the two orderings produce
  the same answer and the arm asserted nothing about the property it names.
- **Fix:** `_SpyPolicy.canWrite` now refuses anything hidden. That is the only
  honest answer as well: a station that may not know a tag exists cannot
  meaningfully be permitted to actuate it. `policy_test.dart:_HidesTags` has the
  same blind spot and survives it because that file's subject is the
  hidden-versus-nonexistent *contrast* rather than the ordering.
- **Verified:** unmutated 10/10 still green; re-applying (c) now answers
  `-32005` for a hidden key and the arm goes red.
- **Files modified:** `packages/tfc_relay_server/test/alarm_ack_test.dart`
- **Commit:** `89c9ea24`

**2. [Rule 3 — Blocking] Two more hand-written ledgers went red**

- **Found during:** Task 2 GREEN
- **Issue:** The plan named `surface_test.dart` as the frozen table, but
  `session_hello_test.dart:353` and `subscribe_test.dart:460` each spell the
  whole ledger out as a third and fourth copy, and both failed on the new name.
- **Fix:** `Methods.ackAlarm` added to both, with the constants-versus-bare-
  strings comment each file already carries, and their "forty-three" / 
  "forty-four" sentences advanced. `subscribe_test.dart`'s own note — *"the fact
  that three copies had to be edited in lockstep is itself worth the note"* —
  is this cost, observed a second time.
- **Files modified:** `packages/tfc_relay_server/test/session_hello_test.dart`,
  `packages/tfc_relay_server/test/subscribe_test.dart`
- **Commit:** `762fa582`

### Judgement calls the plan left open

**The no-engine refusal is `handlerFailed` (-32011).** The plan fixed the
*message* and ruled out both success and `-32601`, but named no code. A new
constant is refused by `error_codes.dart`'s stated rule — a code exists so the
client can behave differently, and there is nothing different a panel can do
about a gateway composed without an engine. `handlerFailed` also matches three
of its four documented clauses exactly: well-formed request, not the client's
fault, nothing applied. The fourth — *"possibly transient: retrying is
legitimate"* — is a licence rather than an instruction, and a retry here is one
idempotent frame refused again with the same sentence. The argument is in the
code beside the branch. **A consequence for 14-13:** the no-engine refusal and a
failing-engine refusal share a code and differ only in their message, so a
client that wants to tell them apart must read the message.

**Arms 4 and 11 are driven through `RelaySession.serve`, not `RelayServer`.**
The plan's wording for both mentions "a `RelayServer` built without
`alarmAcks:`". Registration and the null-sink branch are session-level facts and
an in-memory session exercises the identical code path with no port, no
wall-clock and no `ws` tag; `ws_harness.dart`'s `relayFixture` accepts neither
`policy:` nor `alarmAcks:` and is shared with every socket case in the package,
so widening it was the larger change. `RelayServer`'s own forwarding is covered
by the compile-time fact that `tfc_relay_local` builds a `RelayServer` untouched
and analyzes clean.

## Threat Flags

None. Every surface this plan adds is in the plan's own threat register:
T-14-49 (arms 2, 7; sabotage a, b), T-14-50 (arms 3, 6; sabotage c), T-14-51
(arms 4, 5; sabotage d, e). T-14-52 and T-14-53 were accepted, and nothing in
the implementation widened either — no new limiter, no new pre-hello path, and
the ack is reachable only past `hello` on an authenticated session.

## Known Stubs

None. `AlarmAckSink` is an unimplemented *interface*, which is the plan's
deliverable rather than a stub: no production embedder exists yet, and a gateway
with no engine refuses by name rather than pretending to succeed — arm 4 and
sabotage (d) are exactly that property. The engine that implements it is
`tfc_dart`'s and is not this plan's.

## Commits

| Hash | Message |
|---|---|
| `95a88066` | `test(14-12): failing arms for the ackAlarm wire shape` |
| `1a635c78` | `feat(14-12): Methods.ackAlarm and AckAlarmParams` |
| `ce163914` | `test(14-12): failing arms for the ackAlarm gateway handler` |
| `762fa582` | `feat(14-12): ackAlarm on the gateway, behind the write-grade policy gate` |
| `89c9ea24` | `test(14-12): make the ordering arm bite — a hidden key is not writable` |

## TDD Gate Compliance

Both tasks ran RED → GREEN with the failing output quoted in the RED commit
body. No REFACTOR commit: neither GREEN needed cleaning up. Task 3's mutation
work produced one further `test(...)` commit, which is a strengthened arm rather
than a fourth gate.

## Self-Check: PASSED

All four created files present on disk; all five commit hashes present in
`git log`.

## Note on where this file lives

`.planning/` is in `.gitignore` (line 32) and no prior plan in this phase
committed a summary — wave 1's three commits are source and tests only. This
file is committed with `git add -f` regardless, because the worktree it was
written in is force-removed when the wave ends and an ignored file in it would
be lost. If the phase convention is that summaries stay untracked, this commit
is the thing to drop.
