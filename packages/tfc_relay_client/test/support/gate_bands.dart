/// The timing vocabulary the fault gate asserts against, defined once.
///
/// These are **three separate numbers with three separate jobs**, and the one
/// change to resist here is collapsing them into a single "timeout". They
/// answer different questions and they fail differently when they are wrong:
///
/// - [slack] is measurement tolerance — how far either side of an expected
///   instant a real event may land before the reading is called wrong. It
///   widens a comparison; it never waits for anything.
/// - [recovery] is a liveness budget — how long "the panel came back" is
///   allowed to take. It bounds a wait; a case that used [slack] here would
///   report a healthy reconnect as a failure.
/// - [settle] is the opposite shape: it is spent on purpose, in the one case
///   family where the property is that *nothing* happened. A poll cannot
///   establish an absence, so this is a delay rather than a budget, and using
///   [recovery] here would make every such case five seconds long for no
///   additional evidence.
///
/// Collapse them and the gate keeps passing while it stops measuring: a
/// tolerance used as a budget is a case that waits 20 ms for a reconnect, and a
/// budget used as a tolerance is a case that accepts a five-second round trip
/// as on time.
///
/// **The slack pair is mirrored in `tfc_relay_server/test/support/bands.dart`
/// and must not diverge.** Two packages that disagree about what "on time"
/// means will eventually disagree about whether the gateway is healthy — one
/// side's green and the other side's red, over the same link, with no way to
/// tell which one is describing the plant. The expression below is
/// byte-identical to that file's `slack`; if one moves, the other moves in the
/// same commit and the reason is recorded in both.
///
/// **Why the non-Linux band is nearly four times wider.** The Linux leg is a
/// quiet dedicated runner and 20 ms is the resolution that would notice a
/// mechanism which had quietly stopped working. The hosted macOS and Windows
/// runners are neither quiet nor dedicated, and tens of milliseconds of
/// event-loop jitter there is ordinary. At 20 ms those legs go red about the
/// runner while naming the mode under test, which trains people to re-run CI
/// until it passes — and a real regression then gets re-run too.
///
/// Assert windows, not instants: `lessThan(ceiling)`, never an equality on a
/// duration.
library;

import 'dart:io';

/// The key every scenario case drives. Seeded before the gateway starts, so it
/// is in the address space by the time the client subscribes.
///
/// Shared rather than per-file: the gate's cases are read side by side when a
/// row goes red, and a key that differs by one segment between two files is a
/// difference a reader will spend time on before discovering it means nothing.
const String scenarioKey = 'ST101.CN01.MOT01.setpoint';

/// How far either side of an expected instant a real event may land.
///
/// STATE's Phase 2 handoff bands, and `bands.dart` in the server package is the
/// same two numbers with the same argument: the Linux leg is a quiet dedicated
/// runner, the hosted macOS and Windows ones are neither, and tens of
/// milliseconds of event-loop jitter there is ordinary.
final Duration slack = Platform.isLinux
    ? const Duration(milliseconds: 20)
    : const Duration(milliseconds: 75);

/// The budget for "the panel came back", named once and used everywhere.
///
/// A liveness budget rather than a latency measurement: it has to cover a
/// capped backoff draw, a dial, a handshake and a snapshot.
const Duration recovery = Duration(seconds: 5);

/// Long enough for anything the gateway was going to send to have arrived, on a
/// tick configured at `ServerConfig.minTick`.
///
/// Used only where the property is that *nothing* happened, which is the one
/// shape a poll cannot establish.
const Duration settle = Duration(milliseconds: 400);

/// The link deadline the half-open cases configure: how long the socket may go
/// without a frame of any kind before the client stops believing in it.
///
/// **Platform-scaled for the same reason [slack] is, and it is not a weaker
/// assertion.** The mechanism is `FreshnessWatchdog.sawFrame` arming a plain
/// `Timer(freshnessDeadline)` that any inbound frame resets, and the fault
/// injected against it — a blackhole — is *instantaneous*. What the case
/// measures is therefore "no frame for a whole deadline is noticed", which is
/// the same claim at 500 ms and at 1500 ms; the longer number costs a second of
/// wall clock and proves the identical mechanism.
///
/// What the longer number buys is the difference between a real fault and a
/// runner. At 500 ms on a hosted macOS or Windows box, a GC or a neighbouring
/// case's teardown stalls the isolate for longer than the deadline and the
/// watchdog fires on a link with nothing wrong with it — which is 07-RESEARCH
/// §E.2's parked F5 flake exactly, one full-suite run in three. A deadline
/// shorter than the platform's ordinary stalls does not measure the watchdog,
/// it measures the scheduler, and it reports the difference as a product fault.
///
/// **Scaling the deadline is not the fix on its own** and must not be read as
/// one: the fix is that nothing derives a verdict from an instant read of a
/// wall-clock boolean (see the `until()` windows in
/// `half_open_gate_test.dart`). This number widens the gap a stall has to clear
/// before it fires at all; the windows are what make a stall that does fire
/// harmless.
final Duration freshnessDeadline = Platform.isLinux
    ? const Duration(milliseconds: 500)
    : const Duration(milliseconds: 1500);

/// The budget for "the freshness deadline fired and the view went stale".
///
/// Derived from [freshnessDeadline] rather than from [recovery], because the
/// thing being bounded *is* the deadline: budgeted at the flat recovery number,
/// a watchdog that had quietly slowed to four seconds would still pass, and
/// "the deadline fires" is the clause of the F4/F5 catalogue rows an operator
/// feels.
///
/// One whole deadline of margin, and no less. The mechanism promises the
/// transition at exactly one deadline after the last frame; the margin has to
/// absorb the poll granularity, the dial of the case's own scheduling, and the
/// isolate stalls that made the flake — which were themselves about the length
/// of a deadline. Anything tighter re-creates the failure this constant exists
/// to end, and reports a runner as a broken watchdog.
final Duration freshnessTransition = freshnessDeadline * 2;

/// The one-way delay F13 imposes. A round trip therefore costs twice this.
///
/// **The catalogue's own number**, `latency(500ms, 200ms)`. It ran at a flat
/// 100 ms with no jitter until 07-05, which is why F13 carried a `partial`
/// entry: a tenth of a second is inside every deadline in the client by such a
/// margin that the row's headline — no false disconnect — was never actually
/// put at risk.
const Duration f13Latency = Duration(milliseconds: 500);

/// The spread drawn on top of [f13Latency], per chunk and per direction.
///
/// The second half of `latency(500ms, 200ms)`, and it is not decoration: a flat
/// delay is a link the client could in principle predict, and the deadline
/// arithmetic below has to hold against the *worst* draw rather than the mean.
/// `FaultProxy.jitter` redraws uniformly from `[0, 200 ms]` for every chunk, so
/// the two legs of one round trip draw independently.
const Duration f13Jitter = Duration(milliseconds: 200);

/// The control deadline F13's client is given: comfortably above the round trip
/// the case imposes, which is the whole point — a link that is merely slow must
/// not read as a link that is gone.
///
/// **The arithmetic, stated so that changing it is visibly a scenario change.**
/// The injected round trip is two one-way delays plus two independent jitter
/// draws: `2 x (500 + U[0, 200])`, so **1000 ms at best and 1400 ms at worst**,
/// before any of the gateway's own work. Measured on macOS over ten round
/// trips at these numbers: 1150, 1163, 1167, 1173, 1203, 1227, 1275, 1277,
/// 1282, 1284 ms.
///
/// Three seconds is therefore more than twice the worst injected case. The
/// margin is deliberate and it is **not** a widened band: this number is the
/// client's *configured patience*, not a measurement tolerance, and the row's
/// clause is literally "ping and freshness deadlines tolerate configured RTT".
/// A deadline set below the RTT would not measure the client at all — it would
/// stage a false disconnect and then assert that it happened. The old 1500 ms
/// left 100 ms of headroom over the worst draw, which is how a green case turns
/// into a flake on a loaded runner.
const Duration f13Deadline = Duration(seconds: 3);

/// How long F13 watches for something to go wrong after the link is slow.
///
/// Derived from the round trip rather than from the flat [settle], because the
/// property is an absence and an absence is only worth as much as the window it
/// was watched over: at 400 ms this window was **shorter than a single round
/// trip** once the latency rose, so a client that redialled on its very next
/// exchange would have been recorded as having done nothing. Two worst-case
/// round trips give the false disconnect this row forbids room to actually
/// happen.
const Duration f13Settle = Duration(milliseconds: 2800);
