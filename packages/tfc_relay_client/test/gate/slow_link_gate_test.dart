/// The slow-link control arm, and the boundary between degrading a panel and
/// disconnecting it.
///
/// **F19 — Slow link, fits.** `throttle(1 Mbit/s)`, busy 200-key page at 10 Hz
/// (~0.58 Mbit/s): full cadence sustained; bounded latency (assert p99);
/// no conflation needed; `PIPE.link_degraded` stays false.
///
/// F19 is the control arm of the slow-link family, and it has to exist before
/// F20 means anything. F20's claim is that a page which *cannot* fit is
/// conflated rather than queued; that claim is only interesting if the same
/// page on a link it *can* fit arrives whole and on time. Without this row,
/// "the client kept up" and "the client fell behind" are two measurements with
/// no shared baseline, and a client that had quietly halved its cadence
/// everywhere would satisfy both.
///
/// **G5 — Conflation is not eviction** (the NATS/Redis two-tier boundary).
/// Paired assertions: held above the ceiling every tick ⇒ evicted with the peak
/// verdict; held just under it for 40 ticks ⇒ **never** evicted and always
/// receiving the latest value.
///
/// The survey found two mechanisms that look alike and are not: NATS evicts a
/// slow consumer, Redis bounds its output buffer, and neither of those is
/// conflation. Ours does both, at two different thresholds, and the interesting
/// object is the **boundary** between them rather than either side of it. A
/// case that asserted only the eviction would pass on a gateway that had
/// forgotten how to conflate; a case that asserted only the conflation would
/// pass on a gateway that had forgotten how to evict. So both arms live in one
/// case, over one fixture, on one set of thresholds, differing only in how fast
/// the plant produces — because that is what makes them a pair rather than two
/// cases, and a change that moves the boundary moves one arm across it.
///
/// **What neither row claims, and it matters.** Neither arm observes a *client*
/// backlog, because there is no such observable: `dart:io`'s WebSocket exposes
/// no `bufferedAmount` and no flush completion (flutter#103306), `sink.add`
/// never blocks, and 07-RESEARCH §B.3 measured 700 KB "sent" onto a 100 kbit/s
/// link returning in 5 ms with zero bytes received. What
/// `ConflatingSendBuffer.poll` measures across ticks is therefore this client's
/// own **production** — how many distinct handles changed for it between two
/// ticks — and not how far behind it has fallen (STATE.md 03-REVIEW WR-11, and
/// `send_buffer.dart` says it in the same words). Nobody should read G5's green
/// as evidence that the gateway can see how far behind a panel is: **these arms
/// carry no delivery ack**, so what evicts in them is still a judgement about
/// the *plant's* rate for that page, taken on the panel's behalf.
///
/// **What 16-08 changed about the sentence above, and what it did not.** The
/// flat claim that the gateway *cannot* see a panel's backlog is no longer
/// true as a statement about the design. `16-02-DECISION.md` took option (c) —
/// the panel reports the highest sequence it has applied per subscription on
/// the heartbeat it already sends, and `ConflatingSendBuffer` evicts on a gap
/// that stays wide for a window. So the gateway can see a backlog **when the
/// panel tells it**, and never by observing the socket.
///
/// Two qualifications, both load-bearing:
///
///  * **It is a self-report, from the party being judged.** It is clamped to
///    sequences the server actually sent, so a client cannot over-report its
///    way out of eviction (T-16-02a); under-reporting is left alone, because a
///    client that evicts itself costs only itself a snapshot. Nothing here
///    observes the transport, and no amount of acking makes `dart:io` grow a
///    `bufferedAmount`.
///  * **The wire is not connected yet.** `ping` does not carry the `ack` map:
///    the DTO and the server-side ingestion were outside 16-08's fence. Until
///    they land, every session in production has a null `ackedSeq`, the
///    delivery verdict skips it by design, and these arms describe the whole of
///    what the gateway does. They will keep describing an un-acking client
///    afterwards, which is why they are still correct as written.
///
/// **Why the throttle is the in-process proxy and not `tc netem`.**
/// 07-RESEARCH §B.1: the netem command builder in this repository has no
/// bytes-per-second rate, netem is Linux-only in CI and needs privilege, and
/// using it would take the slow-link family off two of the three platforms.
/// `FaultProxy`'s throttle is measured (`faults/throttle_test.dart:85-105`,
/// ±5 % over 3.5 s at exactly the two rates this family names), cross-platform
/// and free.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';

import '../support/fault_fixture.dart' show until;
import '../support/gate_bands.dart';
import '../support/gate_fixture.dart';

/// How wide the page the slow-link family drives is.
///
/// **The catalogue's own number.** F19 names "busy 200-key page at 10 Hz
/// (~0.58 Mbit/s)" and F20 names "same page"; the builder is shared
/// (`gate_fixture.dart`'s `plantPage`) so that 07-11's rows drive the identical
/// keys rather than a page that has drifted by a name shape.
const int _page = 200;

/// The gateway tick this family runs at, and it is at the band's edge.
///
/// **10 Hz means `tick: 100 ms`, and `ServerConfig` refuses anything outside
/// 50-100 ms** (`server_config.dart:240-246`, an `ArgumentError` at
/// construction). So this is `ServerConfig.maxTick` exactly, and it is named
/// through the constant rather than written as a literal on purpose: the
/// catalogue row is a page at ten hertz, and if the supported band ever moves
/// the compile still succeeds while the scenario silently becomes a different
/// one. Reading the band's own edge is what makes that change visible here.
final Duration _tick = ServerConfig.maxTick;

/// How often the plant moves every key of the page — the row's 10 Hz.
///
/// Equal to [_tick] deliberately: one sweep of the page per tick is what makes
/// "full cadence" a statement about the gateway's pacing rather than about the
/// plant's. A plant twice as fast would be conflated down to the tick and the
/// row would be measuring conflation, which is F20's job.
final Duration _pagePeriod = _tick;

/// F19's link, in bytes per second: one megabit.
///
/// Spelled the way `faults/throttle_test.dart:44` spells it, so the rate this
/// row arms is character-for-character the rate that file measured at ±5 %.
///
/// **The catalogue's own estimate of what the page costs is high, and the
/// measurement is here rather than in a summary nobody will read.** The row
/// says "~0.58 Mbit/s", which is 07-RESEARCH assumption A1's ~22 bytes per slim
/// delta key times 200 keys times 10 Hz. Measured on this build, over this
/// page, at this tick: **281 kbit/s** — a 200-key `u` frame is about 3.5 kB, or
/// 17.5 bytes a key. So the real headroom is **3.6x** rather than the two the
/// row assumes, and the scenario is if anything safer than written. It matters
/// to F20 (07-11) in the other direction: the same page at 100 kbit/s needs
/// about **2.8x** the link, not the 5.8x that row's injection line predicts,
/// and a conflation arm banded off 5.8 would be banded off a number this page
/// does not produce.
const int _oneMegabit = 1000 * 1000 ~/ 8;

/// The rate the positive control drops the same link to: one hundred kilobits.
///
/// `throttle_test.dart:47`'s second constant, and F20's own rate. It is used
/// here only to prove the meter meters — see the control window in F19.
const int _hundredKilobit = 100 * 1000 ~/ 8;

/// How long every rate in this file is measured over.
///
/// **Three and a half seconds, a floor rather than a preference.** `DelayLine`
/// banks up to one second of burst (`delay_line.dart:620-670`), so a window
/// shorter than about two seconds measures the bank instead of the rate, and
/// the proxy's own doc sets three seconds as the minimum with a band of one
/// twentieth. This is that minimum with the measurement's own scheduling slop
/// on top.
///
/// **It is the same number as `herd_gate_test.dart`'s `_rateWindow` and
/// `backpressure_test.dart`'s `_throttleWindow`, and the three must move
/// together.** They are separate declarations because each is private to its
/// file and the third is in another package; what keeps them honest is that all
/// three carry the same derivation from the same measured bucket.
const Duration _rateWindow = Duration(milliseconds: 3500);

/// How long the link is left alone after a lever moves, before a window opens.
///
/// The token bucket has to reach its steady state and the first metered frame
/// has to clear: a window opened on the instant a rate changes measures the
/// transition, which is neither of the two rates the case is comparing.
const Duration _settleAfterLever = Duration(milliseconds: 700);

/// The ceiling F19's p99 inter-frame interval must stay under.
///
/// **Derived, not fitted.** One tick is the cadence itself. A second tick is
/// what a `Timer.periodic` may drift by before the next fire under ordinary
/// load — the engine schedules on wall time and coalesces rather than
/// accumulating, so a single late tick costs at most one whole period. On top
/// of that is [slack], the platform's ordinary event-loop jitter, which is the
/// same 20 ms / 75 ms pair every other timed assertion in this directory uses.
///
/// What it discriminates: on the 100 kbit/s control link the same page needs
/// about 400 ms per frame, so the ceiling sits at a little over half of what a
/// link that does *not* fit produces. That is the margin the row is bought
/// with, and it is why the number is allowed to be generous.
final Duration _p99Ceiling = _tick * 2 + slack;

/// The value the page is seeded with before the gateway starts.
const int _seed = 1000;

// ---------------------------------------------------------------------------
// G5.
// ---------------------------------------------------------------------------

/// How wide G5's page is.
///
/// Small, and its only job is to be comfortably above [_ceiling] when every key
/// moves and comfortably below it when one does. Twenty-four changed handles a
/// tick against a ceiling of four is six times over, which is a production rate
/// nobody can mistake for jitter; one changed handle a tick is a quarter of the
/// ceiling, with room for the heartbeat's own priority entry beside it.
///
/// It is deliberately **not** [_page]. F19's page is wide because the row is
/// about bytes on a link; G5's threshold is counted in *handles* and a 200-key
/// page would clear a four-handle ceiling on the first tick of the quiet arm
/// too, which is the one thing the pair needs to be able to tell apart.
const int _g5Page = 24;

/// The soft ceiling both of G5's arms are judged against.
///
/// **One number for both arms, and that is what makes them a pair.** The
/// eviction arm and the never-evicted arm differ in the plant's production rate
/// and in nothing else: same gateway, same page, same ceiling, same window. A
/// change that moved the boundary would move one arm across it and redden
/// exactly one half, which is the failure signature the survey asked for
/// (07-RESEARCH-PUBSUB §D.1 row G5) and which two separately-configured cases
/// could not produce.
const int _ceiling = 4;

/// How long production may sit above [_ceiling] before the session is closed.
///
/// A second, which is ten ticks — long enough that a single tick above the
/// ceiling cannot evict anybody (the establishment's own resync is one such
/// tick and the quiet arm has to survive it), short enough that the eviction
/// arm costs about a second of lane. The default is ten seconds and a gate row
/// paying that ten times over buys nothing.
const Duration _peakWindow = Duration(seconds: 1);

/// How many ticks the never-evicted arm holds production under the ceiling.
///
/// **The catalogue's own forty**, and it is counted in ticks rather than
/// waited out in milliseconds: the clause is "held just under it for 40 ticks",
/// the ceiling is judged once per tick, and a wall-clock sleep on a loaded
/// runner can cover thirty-eight of them. At [_tick] this is 4 s, which also
/// clears this file's 3.5 s floor for anything calling itself a rate.
const int _quietTicks = 40;

/// How long the eviction arm may wait for the verdict it provokes.
///
/// Generous against [_peakWindow]: the window is what decides, and the budget
/// only has to be longer than one window plus a tick plus the close crossing a
/// loopback socket.
const Duration _evictionBudget = Duration(seconds: 15);

/// The server-side pair this row depends on, and cannot import.
///
/// **Read as text, and the reason is a language rule rather than a preference.**
/// Another package's `test/` directory is not addressable by any `package:`
/// URI — only `lib/` is — so there is no import that would let this file name
/// those two cases. The in-tree answer to exactly this is the read-the-source
/// -as-text arm with an `existsSync` guard: `no_retry_test.dart:401-410` and
/// `client_config_test.dart:483-490` both do it, and the guard is the load
/// bearing half. A file that moved would otherwise make every "is it still
/// there" check below pass on an empty string.
const String _serverPairPath =
    '../tfc_relay_server/test/backpressure_test.dart';

/// The two engine-driven arms that must not be deleted alone.
///
/// `backpressure_test.dart:275-326`. They are the pair 03-REVIEW WR-02 landed
/// after discovering that the three arms above them construct a
/// `ConflatingSendBuffer` by hand and call `poll`/`drain` themselves — so they
/// would pass unchanged whether the engine drained every tick or never, and the
/// soft verdict was dead in production while STATE.md recorded it as "pinned in
/// a named test". These two are driven through `tickOnce` on the pacing the
/// server actually uses.
///
/// Substrings rather than whole names, so a group being re-worded does not
/// redden this arm; distinctive enough that renaming either *case* does, which
/// is the mutation this exists to catch.
const List<String> _engineArms = <String>[
  'held above the soft ceiling every tick is evicted',
  'under the soft ceiling is never evicted for a long run',
];

/// What a window saw: what arrived, what it cost, and when.
///
/// [frames] and [updates] are deliberately two numbers. **A quiet gateway still
/// sends this panel about ten frames a second** — the tick engine emits a `tick`
/// notification carrying each subscription's sequence on every one of its own
/// ticks, whether or not a value moved (`tick_engine.dart:388`, and G1 is the
/// row about the client reading that sequence). Measured on a page seeded once
/// and never touched: 36 inbound frames in 3.5 s, 4437 bytes, and not one of
/// them an update.
///
/// So a cadence counted off raw inbound frames is a cadence a *dead plant*
/// satisfies, and every clause F19 makes would have passed on a page nobody was
/// driving. `herd_gate_test.dart`'s `_cadence` counts raw frames and is right to
/// — it compares one link against another and the tick floor is common to both
/// — but an absolute claim has to count the frames that carry values.
typedef _Window = ({
  int frames,
  int updates,
  int bytes,
  double updatesPerSecond,
  double bytesPerSecond,
  List<int> intervals,
});

/// The nearest-rank [q]th percentile of [sorted], which must be sorted and
/// must not be empty.
///
/// **Empty throws rather than answering zero.** An empty interval list is the
/// signature of a window in which nothing arrived, and a percentile helper that
/// answered `0` for it would hand every "below the ceiling" assertion in this
/// file a free pass on exactly the run where the transport had stopped. Measured
/// during this plan's RED: with the plant quiet the list is empty and a
/// zero-returning helper reported `p50 0 ms, p99 0 ms, max 0 ms` and passed.
///
/// **At this cadence p99 is the maximum, and that is stated rather than
/// hidden.** Nearest rank puts the 99th percentile of *n* samples at index
/// `ceil(0.99 n) - 1`, which is the last element for every n below 101; a
/// 3.5 s window at 10 Hz holds about 35 intervals. So F19's p99 arm is in
/// practice asserting the whole tail rather than a trimmed one, which is the
/// stronger claim and the reason the mean is not used: a mean over 35 intervals
/// hides one 900 ms straggler inside a 100 ms average, and one straggler is a
/// frame an operator did not get.
int _percentile(List<int> sorted, double q) {
  if (sorted.isEmpty) {
    throw StateError('a percentile was asked of an empty sample. Nothing '
        'arrived in the window, which is a failure of the measurement rather '
        'than a fast one — see this helper\'s doc');
  }
  final rank = (q * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

/// Whether [frame] is an `u` notification — a frame carrying values.
bool _isUpdate(String frame) {
  final decoded = jsonDecode(frame);
  return decoded is Map && decoded['method'] == Methods.update;
}

/// Opens a window of [window] on [panel] and reports what arrived.
///
/// **The seam's retained frames are cleared at both ends, not accumulated.**
/// A multi-second case at ten frames a second on a 200-key page retains
/// megabytes of JSON as `String`s if nobody empties the list, and a case that
/// becomes the memory problem it is measuring reports the runner
/// (07-RESEARCH trap 15). Only the count and the total size survive the window.
///
/// Intervals come from [marks] rather than from the seam, because the seam
/// records frames without recording when they arrived. [marks] is filled by a
/// tap on one key of the page: every `u` frame carries all 200 changed handles,
/// so one emission on that key is one frame at the point the panel actually
/// hands a value to whatever is drawing it.
Future<_Window> _observe(
  GateClient panel,
  List<int> marks,
  Duration window,
) async {
  panel.seam.inbound.clear();
  marks.clear();
  await Future<void>.delayed(window);
  final frames = panel.seam.inbound.length;
  var bytes = 0;
  var updates = 0;
  for (final frame in panel.seam.inbound) {
    // `length` and not `utf8.encode(...).length`: every byte on this page is
    // ASCII — the keys are `AREAnn.DEVnn.SUBnn`, the values are integers — so
    // the two agree, and encoding every frame to find out would make the
    // measurement the load.
    bytes += frame.length;
    if (_isUpdate(frame)) updates++;
  }
  panel.seam.inbound.clear();
  final intervals = <int>[
    for (var i = 1; i < marks.length; i++) marks[i] - marks[i - 1],
  ];
  final seconds = window.inMilliseconds / 1000;
  return (
    frames: frames,
    updates: updates,
    bytes: bytes,
    updatesPerSecond: updates / seconds,
    bytesPerSecond: bytes / seconds,
    intervals: intervals,
  );
}

void main() {
  group('F19 — a link the page fits on', () {
    test('F19: a link with headroom carries the page at full cadence',
        () async {
      final keys = plantPage(_page);
      final fixture = await gateFixture(
        clients: 1,
        keys: keys.toSet(),
        serverConfig: (port) => ServerConfig(tick: _tick, port: port),
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _seed}),
      );
      final panel = fixture.clients.single;

      // The tap the interval measurement reads, on one key of the page. Nulls
      // are dropped for `herd_gate_test.dart`'s reason: a resync blanks the
      // page before refilling it, and a blank is not a frame an operator was
      // shown.
      final clock = Stopwatch()..start();
      final marks = <int>[];
      final tap = panel.client.subscribe(keys.first).listen((value) {
        if (value.value is num) marks.add(clock.elapsedMilliseconds);
      });
      addTearDown(tap.cancel);

      panel.proxy.throttleBytesPerSec = _oneMegabit;
      // Disarmed before teardown: a proxy left metering at the end of a case
      // has a backlog to drain while the fixture is trying to release it.
      addTearDown(() => panel.proxy.throttleBytesPerSec = null);

      // ANTI-VACUITY, and the only observable of an armed throttle there is:
      // the lever is setter-only, so "armed" is a claim about the composition
      // table. `reject` excludes `throttle`, and the refusal is a synchronous
      // throw taken before the mode is stored (`fault_proxy.dart:665-670`), so
      // asking for it neither disturbs the link nor arms anything.
      // `throttle_test.dart:118-131` is the precedent and says so in the same
      // words.
      expect(() => panel.proxy.reject(), throwsStateError,
          reason: 'the proxy accepted a request to start rejecting '
              'connections while a throttle was supposed to be armed on it. '
              'The two modes exclude each other, so a proxy that took the '
              'second one is a proxy carrying no throttle — and every '
              'measurement below would then be a measurement of an unmetered '
              'loopback socket wearing F19\'s name');

      final sessions = <int>[];
      final sampler = Timer.periodic(const Duration(milliseconds: 100),
          (_) => sessions.add(fixture.sessionCount));
      addTearDown(sampler.cancel);

      final driver = drivePage(fixture.served, keys, period: _pagePeriod);
      final attemptsBefore = panel.attempts;
      await Future<void>.delayed(_settleAfterLever);

      final wroteBefore = driver.writes;
      final fits = await _observe(panel, marks, _rateWindow);
      final wrote = driver.writes - wroteBefore;

      print('F19: over ${_rateWindow.inMilliseconds} ms on a $_oneMegabit B/s '
          'link, a $_page-key page at '
          '${(1000 / _pagePeriod.inMilliseconds).toStringAsFixed(0)} Hz — '
          '${fits.updates} update frames '
          '(${fits.updatesPerSecond.toStringAsFixed(1)}/s) of ${fits.frames} '
          'inbound, ${fits.bytes} bytes '
          '(${fits.bytesPerSecond.toStringAsFixed(0)} B/s, '
          '${(fits.bytesPerSecond * 8 / 1000).toStringAsFixed(0)} kbit/s); '
          '${fits.intervals.length} inter-frame intervals; the plant wrote '
          '$wrote values across the window');

      // ANTI-VACUITY, first arm: value-carrying frames arrived at all. Raw
      // inbound frames would not do — see [_Window], where a quiet plant is
      // measured producing 36 of them in this same window.
      expect(fits.updates, greaterThan(0),
          reason: 'not one update frame arrived at the panel across '
              '${_rateWindow.inMilliseconds} ms, out of ${fits.frames} inbound '
              'frames. The gateway ticks whether or not the plant moves, so an '
              'inbound count above zero says only that the gateway is alive; '
              'everything below is a statement about values, and no values '
              'crossed this link');
      expect(fits.intervals, isNotEmpty,
          reason: 'the tap on ${keys.first} recorded no value at all, so there '
              'is no interval to take a percentile of. The panel either never '
              'subscribed to that key or was never shown a new value for it, '
              'and the latency clause below would be asserted about an empty '
              'sample');

      // ANTI-VACUITY, second arm: the plant genuinely moved the whole page for
      // the whole window. The band is a quarter either side, because the
      // driver's sweeps are a `Timer.periodic` and the window's ends do not
      // line up with them; what it forbids is a plant running at half rate or
      // a page that has silently shrunk, either of which would make "full
      // cadence" a claim about a link nobody was loading.
      final expectedWrites = _page * _rateWindow.inMilliseconds ~/
          _pagePeriod.inMilliseconds;
      expect(wrote, greaterThan(expectedWrites * 3 ~/ 4),
          reason: 'the plant wrote $wrote values across '
              '${_rateWindow.inMilliseconds} ms against the $expectedWrites a '
              '$_page-key page swept every ${_pagePeriod.inMilliseconds} ms '
              'owes. A page that is not moving cannot be behind, so the '
              'cadence and latency clauses below would be measuring an idle '
              'link with a lever armed on it');
      expect(wrote, lessThan(expectedWrites * 5 ~/ 4),
          reason: 'the plant wrote $wrote values across '
              '${_rateWindow.inMilliseconds} ms, well above the '
              '$expectedWrites a ${(1000 / _pagePeriod.inMilliseconds).toStringAsFixed(0)} Hz '
              'sweep of $_page keys owes. F19 is the row where the page fits '
              'in the link; a plant running faster than 10 Hz is F20\'s '
              'scenario wearing F19\'s name, and the headroom arithmetic in '
              'this file\'s doc no longer describes it');

      final sorted = List.of(fits.intervals)..sort();
      final p50 = _percentile(sorted, 0.50);
      final p99 = _percentile(sorted, 0.99);
      final worst = sorted.last;
      print('F19: inter-frame p50 $p50 ms, p99 $p99 ms, max $worst ms against '
          'a ${_p99Ceiling.inMilliseconds} ms ceiling');

      // THE ROW'S CLAUSE, first half: full cadence sustained.
      final expectedFps = 1000 / _pagePeriod.inMilliseconds;
      expect(fits.updatesPerSecond, greaterThan(expectedFps * 0.9),
          reason: 'the panel was fed '
              '${fits.updatesPerSecond.toStringAsFixed(1)} update frames/s '
              'against the ${expectedFps.toStringAsFixed(0)} Hz the plant is '
              'moving the page at and the gateway is ticking at. The link '
              'carries this page with roughly two times headroom, so anything '
              'short of the tick rate is the transport losing frames the plant '
              'produced — and a panel shown eight of every ten values is a '
              'panel whose operator is watching a slideshow nobody told them '
              'about');

      // THE ROW'S CLAUSE, second half: bounded latency, asserted at the tail.
      expect(p99, lessThan(_p99Ceiling.inMilliseconds),
          reason: 'the p99 inter-frame interval was $p99 ms against a '
              '${_p99Ceiling.inMilliseconds} ms ceiling (p50 $p50, max $worst). '
              'The mean is deliberately not what is asserted: a mean over '
              '${fits.intervals.length} intervals hides one long gap inside a '
              'run of short ones, and the gap is the thing an operator sees');

      // THE ROW'S CLAUSE, third half: no verdict fires.
      //
      // **"No verdict" is fully observable, and it is worth saying why.** A
      // `BufferVerdict` is not a surface that can be read between ticks: `poll`
      // returns `BufferOk` or a `BufferDisconnect`, and `applyVerdict` turns
      // the second into `RelaySession.close` on the same turn
      // (`relay_session.dart:416-424`). There is no state in which a verdict
      // has fired and the session is still up, so a verdict that fired is a
      // 4004 close — visible from the gateway's ledger and, independently, from
      // the panel's own socket. Both are asserted, because the ledger is what
      // the gateway *decided* and the close code is what the panel *observed*,
      // and 07-09 measured a row where those two disagree.
      final closed = panel.observedClose;
      print('F19: ${fixture.evictedForBackpressure.length} thrown off for '
          'being slow, ${fixture.heartbeatReaps.length} reaped for silence, '
          '${fixture.evictions.length} evicted in all; the panel observed '
          '${closed.closeCode ?? 'no close'}, made '
          '${panel.attempts - attemptsBefore} reconnect attempts across the '
          'window, and the gateway held $sessions sessions');

      expect(fixture.evictedForBackpressure, isEmpty,
          reason: 'the gateway threw the panel off for being slow: '
              '${fixture.evictedForBackpressure}. This is the row where the '
              'page *fits* — 200 changed handles a tick against a soft ceiling '
              'of ${ServerConfig().peakThreshold} — so a backpressure verdict '
              'here is the gateway disconnecting a panel that was keeping up, '
              'and F20 loses the baseline that makes its own conflation '
              'evidence mean anything');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway ended ${fixture.evictions.length} sessions over '
              'this window: ${fixture.evictions}. Nothing was injected here '
              'except a link with two times the headroom the page needs');
      expect(closed.closeCode, isNull,
          reason: 'the panel\'s own socket observed close code '
              '${closed.closeCode} (${closed.closeReason}). The gateway\'s '
              'ledger and the panel\'s socket are two independent observations '
              'of the same event and both have to be quiet: 07-09 measured a '
              'row where the session ended on a client-observed 1006 with the '
              'gateway\'s ledger recording no decision of its own at all');
      expect(panel.attempts - attemptsBefore, 0,
          reason: 'the panel entered LinkState.connecting '
              '${panel.attempts - attemptsBefore} times during the measurement '
              'window. A reconnect mid-window costs a full 200-key resync and '
              'a gap in the cadence, so a window containing one is not '
              'measuring a sustained link — and this is the observable that '
              'sees an attempt the seam cannot (07-08 deviation 5)');
      expect(sessions, everyElement(1),
          reason: 'the gateway held $sessions sessions across the window, '
              'sampled every 100 ms. One reap and one redial inside a window '
              'leaves the count at 1 at both ends, so the end-state reading '
              'that every other row takes would not see it');
      expect(fixture.gatewayComplaints, isEmpty,
          reason: 'the gateway reported ${fixture.gatewayComplaints}. A page '
              'this wide at this rate is the shape that escapes an async error '
              'from a handler, and an error swallowed by the default handler '
              'is a fault this row would otherwise pass straight over');

      // ANTI-VACUITY, third arm — the positive control, and the honest form of
      // "the throttle actually limited".
      //
      // **The plan asks for the achieved byte rate to land near 1 Mbit/s. It
      // cannot, and the reason is the row.** F19's whole scenario is a page
      // that *fits*: production is about 0.58 Mbit/s against a 1 Mbit/s meter,
      // so the achieved rate is bounded by the plant and not by the lever, and
      // a link with no throttle on it at all would deliver the same number.
      // Asserting the meter's own rate would mean saturating the link, which
      // is F20.
      //
      // So the arm that proves the meter meters is a control rather than a
      // reading: the *same* lever on the *same* proxy is dropped to the rate
      // F20 names, and the same page over the same window collapses. That
      // proves three things at once — the lever is armed on this panel's link,
      // it genuinely meters bytes, and this page really does exceed a slower
      // link, which is the headroom claim stated from the other side. It is
      // `latency_gate_test.dart`'s provoked-transition pattern (07-05's RED 3)
      // applied to a rate.
      panel.proxy.throttleBytesPerSec = _hundredKilobit;
      await Future<void>.delayed(_settleAfterLever);
      final starved = await _observe(panel, marks, _rateWindow);

      print('F19 control: the same page on the same link metered down to '
          '$_hundredKilobit B/s — ${starved.updates} update frames '
          '(${starved.updatesPerSecond.toStringAsFixed(1)}/s), '
          '${starved.bytes} bytes '
          '(${starved.bytesPerSecond.toStringAsFixed(0)} B/s, '
          '${(starved.bytesPerSecond * 8 / 1000).toStringAsFixed(0)} kbit/s) '
          'against a $_hundredKilobit B/s meter');

      expect(starved.updatesPerSecond, lessThan(fits.updatesPerSecond / 2),
          reason: 'the same page over the same socket ran at '
              '${starved.updatesPerSecond.toStringAsFixed(1)} update frames/s '
              'when the meter was dropped from $_oneMegabit to '
              '$_hundredKilobit B/s, against '
              '${fits.updatesPerSecond.toStringAsFixed(1)}/s before. The lever '
              'therefore does nothing on this link, and the measurement above '
              'was taken on an unmetered loopback socket wearing F19\'s name');
      expect(starved.bytesPerSecond, lessThan(_hundredKilobit * 1.25),
          reason: 'the metered window carried '
              '${starved.bytesPerSecond.toStringAsFixed(0)} B/s against a '
              '$_hundredKilobit B/s meter. `throttle_test.dart` measures this '
              'mechanism at ±5 % over this same 3.5 s window; a quarter is the '
              'widening for a measurement taken through a gateway rather than '
              'against a firehose, and a rate above it means the bucket is not '
              'the thing shaping this link');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('G5 — the boundary between conflating and evicting', () {
    // A supporting case, not a row arm: its name carries no `Gn:` token, so
    // the manifest never discovers it and G5 keeps its single unlettered case
    // (07-08 deviation 6 — a non-row name *is* the supporting-case exemption,
    // there is no list to register in). It is a text sweep rather than a
    // socket, and it runs whether or not the row beside it is green, which is
    // the point: the half of this pair that lives in another package has to
    // fail here by name rather than by nobody noticing.
    test('the engine-driven pair G5 rests on is still in the server package',
        () {
      final source = File(_serverPairPath);
      expect(source.existsSync(), isTrue,
          reason: 'this arm reads $_serverPairPath as text, so it must run '
              'with the tfc_relay_client package root as the working '
              'directory; dart test was invoked from ${Directory.current.path} '
              'and found nothing there. A moved file has to fail loudly: the '
              'substring checks below would all pass against an empty string, '
              'and the deletion this arm exists to catch would be the thing '
              'that made them pass');

      final code = source.readAsStringSync();
      final missing = [
        for (final arm in _engineArms)
          if (!code.contains(arm)) arm,
      ];
      expect(missing, isEmpty,
          reason: 'these engine-driven arms are no longer in '
              '$_serverPairPath: $missing. They are a pair — held above the '
              'ceiling every tick means evicted, held under it for forty ticks '
              'means never evicted — and the pub/sub survey asked the gate to '
              'own them *as a pair so nobody deletes one* '
              '(07-RESEARCH-PUBSUB §D.1 row G5). Half of that pair still '
              'passes while the product has lost the other behaviour: delete '
              'the eviction arm and a gateway that never evicts is green; '
              'delete the never-evicted arm and a gateway that evicts every '
              'panel on a busy page is green. If one of them has genuinely '
              'been replaced, say what now asserts its half before editing '
              'this list');
    });

    test('G5: conflation is not eviction, and the boundary between them is a '
        'pair', () async {
      final keys = plantPage(_g5Page);
      final fixture = await gateFixture(
        clients: 1,
        keys: keys.toSet(),
        serverConfig: (port) => ServerConfig(
          tick: _tick,
          port: port,
          peakThreshold: _ceiling,
          peakWindowMs: _peakWindow.inMilliseconds,
        ),
        seed: (plant) => plant.setValues({for (final key in keys) key: _seed}),
      );
      final panel = fixture.clients.single;
      final engine = fixture.server.engine!;

      // **No hand-built buffer anywhere in this case, and that is the point.**
      // 03-REVIEW WR-02: the original arms constructed a `ConflatingSendBuffer`
      // and called `poll`/`drain` themselves, which made them pass whether the
      // engine's own order — poll before drain — was right or not. Everything
      // below goes through a real gateway on a real socket, so what is asserted
      // is the path production takes.

      // **The registry invariant, sampled rather than read at the end.** The
      // eviction is decided inside a tick, and the session has to leave the
      // registry in the same turn it was decided in: everything before the
      // first `await` in `RelaySession._teardown` is the synchronous half, and
      // the registry removal is step 2 of it (`relay_session.dart:1035-1062`).
      // A session still selectable after its close code was set is one the next
      // tick fans out to and the reaper sweeps. Sampled at 2 ms, a fiftieth of
      // a tick, so a removal deferred by so much as one turn of the event loop
      // lands in this list.
      //
      // **The same sampler latches what the panel's socket observed, and that
      // is not a nicety.** `GateClient.observedClose` reads the *most recent*
      // connect attempt, so a close code lives on it only until the redial that
      // follows returns — about one backoff draw, forty milliseconds at this
      // config. A wait that polls it every ten milliseconds can therefore miss
      // the close entirely, and this arm then waits out another whole peak
      // window and evicts the panel a second time; measured inside a full-suite
      // run, three evictions and thirty-eight ticks before a poll happened to
      // land on one. So the close is latched at 2 ms into a set, and what the
      // arm *waits* on is the gateway's ledger, which is a record rather than
      // a reading and cannot be overwritten by a reconnect.
      //
      // **And it latches the close *reason* beside the code, in the same
      // sample** (07-13). Latching only the code left half the race in place:
      // the arm below waits on the latched set and then reads the reason off
      // `observedClose`, which by then is the *next* attempt's — so on a
      // loaded run the redial won and the reason read null while the code was
      // still in the set. Reproduced deterministically by putting a 300 ms
      // delay between the wait and the read: `Expected: contains 'unable to
      // keep up' / Actual: <null>`, which is byte-for-byte the failure one in
      // five full-suite runs produced. Read here, the two fields come off one
      // `ConnectAttempt` in one synchronous turn, so a latched code always has
      // whatever reason accompanied it. **Do not widen the `until()` above** —
      // the value is destroyed by the passage of time rather than produced by
      // it, so a longer wait makes this worse.
      final zombies = <String>[];
      final seenCodes = <int>{};
      final seenReasons = <int, String>{};
      final watch = Timer.periodic(const Duration(milliseconds: 2), (_) {
        for (final session in fixture.server.sessions.sessions) {
          final code = session.sentCloseCode;
          if (code != null) {
            zombies.add('a session with sentCloseCode $code was still in the '
                'registry at tick ${engine.ticks}');
          }
        }
        final observed = panel.observedClose;
        if (observed.closeCode case final int code) {
          seenCodes.add(code);
          if (observed.closeReason case final String said) {
            seenReasons.putIfAbsent(code, () => said);
          }
        }
      });
      addTearDown(watch.cancel);

      // ARM ONE — held just under the ceiling for forty ticks.
      //
      // It runs first on purpose. The other arm ends with the panel thrown off
      // and redialling, and a quiet arm measured on a session that has just
      // re-established would be measuring the resync's own burst of handles
      // rather than a steady line.
      final delivered = <num>[];
      final tap = panel.client.subscribe(keys.first).listen((value) {
        // Nulls dropped: a resync blanks the page before refilling it, so a
        // null is "between establishments" rather than a value an operator was
        // shown. Counting them would make the ordering arm below fail on a
        // reconnect instead of on a queue.
        if (value.value case final num seen) delivered.add(seen);
      });
      addTearDown(tap.cancel);

      final quiet = drivePage(fixture.served, [keys.first], period: _tick);
      final quietFrom = engine.ticks;
      await until(
        'the gateway to turn $_quietTicks ticks with one changed handle each',
        () => engine.ticks - quietFrom >= _quietTicks,
        budget: Duration(milliseconds: _tick.inMilliseconds * _quietTicks * 3),
      );
      quiet.cancel();
      final quietTicks = engine.ticks - quietFrom;
      final closesAfterQuiet = Set.of(seenCodes);

      // The last value has to be allowed to cross the socket: the plant stopped
      // between two ticks, so the newest value is at most one tick from having
      // been sent. A window, never an instant.
      await until(
          'the panel to hold the last value the quiet plant wrote '
          '(${quiet.latest})',
          () => delivered.isNotEmpty && delivered.last == quiet.latest,
          budget: recovery);

      print('G5 under the ceiling: $quietTicks ticks at 1 changed handle each '
          'against a ceiling of $_ceiling; the plant swept ${quiet.sweeps} '
          'times and the panel was shown ${delivered.length} values, ending at '
          '${delivered.last} against a plant at ${quiet.latest}; the panel '
          'observed ${closesAfterQuiet.isEmpty ? 'no close' : closesAfterQuiet} '
          'and the gateway holds ${fixture.sessionCount} sessions');

      expect(quietTicks, greaterThanOrEqualTo(_quietTicks),
          reason: 'the gateway turned $quietTicks ticks while production was '
              'held under the ceiling, against the $_quietTicks the catalogue '
              'names. The clause is counted in ticks because the ceiling is '
              'judged once per tick, and an arm that ran short would be '
              'asserting that a shorter run does not evict');
      expect(closesAfterQuiet, isEmpty,
          reason: 'the panel\'s socket observed $closesAfterQuiet while '
              'producing one changed handle a tick against a ceiling of '
              '$_ceiling. That is conflation being confused for eviction, and '
              'it is the failure an operator meets as a panel dropping off the '
              'wall on a healthy line — a window that accumulated without a '
              'recovery signal would evict every panel in the plant '
              'eventually. Latched at 2 ms across all $quietTicks ticks rather '
              'than read once at the end, so a close-and-redial inside the arm '
              'cannot heal itself before anybody looks');
      expect(fixture.sessionCount, 1,
          reason: 'the gateway holds ${fixture.sessionCount} sessions after '
              '$quietTicks ticks under the ceiling, against the one panel this '
              'fixture built');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway ended ${fixture.evictions} over the quiet arm. '
              'Nothing was injected: one key moved at the tick rate on an '
              'unmetered loopback socket');
      expect(delivered, orderedEquals(List.of(delivered)..sort()),
          reason: 'the values the panel was shown are not in ascending order: '
              '$delivered. The plant only counts up, so a value that arrived '
              'after a larger one is an old value delivered late — which is a '
              'queue. Conflation reorders nothing, and never an old queued one '
              'is the clause');
      expect(delivered.last, quiet.latest,
          reason: 'the panel is holding ${delivered.last} and the plant left '
              'off at ${quiet.latest}. "Always receiving the latest value" is '
              'the half of this arm that says conflation is not *starvation*: '
              'a panel under the ceiling is served, and what it is served is '
              'current');
      expect(delivered.length, greaterThan(quiet.sweeps * 3 ~/ 4),
          reason: 'the plant swept ${quiet.sweeps} times and the panel was '
              'shown ${delivered.length} values. At one changed handle a tick '
              'against a tick-paced plant there is nothing to conflate, so a '
              'panel shown a fraction of them is a panel being starved under '
              'the ceiling rather than served under it');

      // ARM TWO — held above the ceiling every tick.
      //
      // Same fixture, same page, same ceiling, same window. The *only* thing
      // that changes is how many handles the plant moves between two ticks,
      // which is what makes this a boundary rather than two scenarios.
      final busy = drivePage(fixture.served, keys, period: _tick, from: 100000);
      final busyFrom = engine.ticks;
      final held = Stopwatch()..start();
      // **Waited on the gateway's ledger and not on the panel's reading.** The
      // ledger is appended once per released connection and is never rewritten;
      // the panel's `observedClose` is the current attempt's, and the redial
      // that follows an eviction erases it in about one backoff draw. See the
      // sampler above for the measurement that made this necessary.
      await until('the gateway to record that it gave up on the panel',
          () => fixture.evictedForBackpressure.isNotEmpty,
          budget: _evictionBudget);
      held.stop();
      // Stopped the instant the verdict lands: left running, the panel redials
      // into the same production rate and is evicted again every window for the
      // rest of the case, which is an eviction storm in the teardown rather
      // than evidence.
      busy.cancel();
      final firedAfter = engine.ticks - busyFrom;
      final windowTicks = _peakWindow.inMilliseconds ~/ _tick.inMilliseconds;
      final decided = fixture.evictedForBackpressure;

      // The panel's own view of the same event, which crosses a socket and so
      // lands a few milliseconds after the gateway's. A window, never an
      // instant.
      await until('the panel\'s own socket to observe the close the gateway '
          'has already recorded', () => seenCodes.isNotEmpty, budget: recovery);
      // Off the latch, not off the panel: see the sampler's own note.
      final reason = seenReasons[CloseCodes.backpressureOverrun];

      print('G5 above the ceiling: $_g5Page changed handles a tick against a '
          'ceiling of $_ceiling; the verdict fired after '
          '${held.elapsedMilliseconds} ms and $firedAfter ticks (the window is '
          '${_peakWindow.inMilliseconds} ms, which is $windowTicks ticks at '
          'this pacing), the panel observed $seenCodes "$reason", the '
          'gateway\'s ledger reads $decided, and it holds '
          '${fixture.sessionCount} sessions');

      expect(seenCodes, {CloseCodes.backpressureOverrun},
          reason: 'the panel\'s socket observed $seenCodes across this whole '
              'case rather than exactly '
              '{${CloseCodes.backpressureOverrun}}. A panel that is thrown off '
              'has to be told which ceiling it hit: a bare 1006 is '
              'indistinguishable from a crashed gateway, and a panel that '
              'cannot tell those apart reconnects into the same wall for ever. '
              'The set is every code latched at 2 ms since the fixture came '
              'up, so a 1006 during the quiet arm would still be in it');
      // `contains('unable to keep up')` until 16-08. The verdict is the same
      // verdict and this arm still pins the same boundary; the sentence stopped
      // attributing a measurement of the server's own production to the panel
      // receiving it (`16-02-DECISION.md` §5.4, T-16-08e).
      expect(reason, contains('sustained production'),
          reason: 'the close reason was "$reason". This arm is about the '
              '**soft** ceiling — the sustained-peak verdict, judged over a '
              'window — and the hard `maxPending` limit carries a different '
              'sentence. A 4004 arriving for the wrong reason would let this '
              'pair pass on a gateway whose peak verdict is dead, which is '
              'precisely the state 03-REVIEW WR-02 found it in');
      expect(reason, contains('$_ceiling'),
          reason: 'the reason names no ceiling: "$reason". An operator reading '
              'it should learn which limit was hit without reading the '
              'gateway\'s source');
      expect(decided, hasLength(1),
          reason: 'the gateway\'s own ledger records $decided backpressure '
              'evictions. The panel\'s socket and the gateway\'s ledger are '
              'two independent observations of one decision, and a 4004 the '
              'gateway did not record deciding is a close that came from '
              'somewhere else');
      expect(zombies, isEmpty,
          reason: 'these sessions were still in the gateway\'s registry after '
              'their close code had been set: $zombies. The eviction is a '
              'decision a tick takes, and the session has to be out of the '
              'registry in the same turn — a session still selectable is one '
              'the next tick fans out to and the reaper sweeps, which is a '
              'gateway writing frames to a socket it has already given up on. '
              'The same-tick property is asserted exactly, with hand-driven '
              'ticks, at backpressure_test.dart:99-190; what is sampled here '
              'is the half a client-side case can see');
      // **The window is judged in wall clock, and the tick count is printed
      // rather than asserted.** `poll` fires when `nowMs - _peakSinceMs >
      // peakWindowMs`, which is milliseconds; how many ticks that takes depends
      // on whether the runner let the engine's `Timer.periodic` keep to its
      // period. Under a loaded full-suite run this file measured the same
      // verdict at 12 ticks and at 38, so a bound counted in ticks would be a
      // bound on the runner. Wall clock is what the mechanism uses and it is
      // what the arm reads.
      expect(held.elapsed, greaterThanOrEqualTo(_peakWindow),
          reason: 'the verdict fired ${held.elapsedMilliseconds} ms after '
              'production went above the ceiling, against a '
              '${_peakWindow.inMilliseconds} ms window ($firedAfter ticks '
              'turned). An eviction that fires sooner than its own window is '
              'an instant verdict wearing a window\'s name, and it would throw '
              'a panel off for one busy tick — which is every panel, on every '
              'resync');
      expect(held.elapsed, lessThan(_peakWindow * 4),
          reason: 'the verdict took ${held.elapsedMilliseconds} ms to fire '
              'against a ${_peakWindow.inMilliseconds} ms window. Three whole '
              'windows of slack covers the tick the peak is first noticed on, '
              'the tick it is acted on, and a runner that is late for both; '
              'beyond that the window is sliding rather than expiring, and a '
              'window that keeps sliding is a ceiling nobody ever hits');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
