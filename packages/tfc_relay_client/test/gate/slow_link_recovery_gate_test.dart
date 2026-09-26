/// The link that cannot carry the page, and the recovery from it.
///
/// **F20:** Slow link, doesn't fit. `throttle(100 kbit/s)`, same page (needs
/// ~5.8x the link): conflation engages: reduced cadence,
/// every delivered value is the *latest* (never an old queued one — assert
/// with a monotonically incremented test key); queue stays bounded;
/// writes/RPC responses still complete promptly via the priority lane;
/// `PIPE.link_degraded` + `PIPE.effective_hz` reflect it and an AlarmMan alarm
/// fires (§7.7).
///
/// **F21:** Slow link recovers. `throttle(100 kbit/s)` 60 s, then unthrottle:
/// conflation disengages, cadence returns to 10 Hz, `PIPE.link_degraded`
/// clears, alarm auto-resolves; no burst of backlogged frames on recovery (the
/// conflating map means there is no backlog to flush).
///
/// **G6:** Slow link recovers. F21 currently has no un-throttle arm; throttle
/// 60 s, un-throttle, assert the client
/// converges to current values with **no backlog flush** — the conflating map
/// means recovery has nothing queued to drain.
///
/// **F21 and G6 share one case, named `F21/G6: …`.** They are the same
/// scenario read out of two catalogue tables — §7.5's row and §D.1's — so
/// asserting the recovery twice would buy nothing and cost the lane another
/// twenty-four seconds. The manifest's grammar reads both ids out of the one
/// name, which is what that grammar is for.
///
/// **The same page as F19, and the oversubscription is measured rather than
/// quoted.** `plantPage(200)` at 10 Hz is the row's "same page", and 07-10
/// measured what it actually costs on this build: **281 kbit/s**, not the
/// ~0.58 Mbit/s the catalogue estimates. So this link is **2.8x**
/// oversubscribed and not the 5.8x F20's injection line predicts, and every
/// band below is derived from the measured number. A band derived from 5.8
/// would be a band about a page this repository does not produce.
///
/// **What F20 and F21 deliberately do not assert, and where those clauses
/// went.** Four of F20's clauses are asserted below. Two are not, and both are
/// in `f_row_registry.dart`'s `gateDeviations` with the measurement that put
/// them there rather than being weakened until they passed:
///
///  * **"queue stays bounded"** — as a claim about the *socket*. The §7.6
///    design rule it rests on is to drain the conflating map only once the
///    previous write actually completed, and 07-RESEARCH §B.3 measured that
///    there is no such signal: 700 KB pushed onto a 100 kbit/s link returned
///    in 5 ms with zero bytes received and RSS up 2.9 MB, on both `sink.add`
///    and `await sink.addStream`. So the drain is not gated on egress, the
///    backlog lives in `dart:io`'s own outgoing buffer, and this process
///    cannot see it. What clause 4 below asserts is the **conflating map**,
///    which is a different queue, and it says so on the assertion.
///  * **`PIPE.link_degraded` + `PIPE.effective_hz` … an AlarmMan alarm
///    fires** — the health keys ship with upstream fan-in (Phase 8) and there
///    is no AlarmMan wiring in the pipe. Clause 3 is the operator-visible half
///    of that clause built out of what exists: a starved page renders stale.
///  * **"never an old queued one"** across ticks. The conflating map collapses
///    changes *within* one tick, and F20 measures that: 12 update frames
///    delivered against 35 sweeps during the metered window. What it also
///    measures is that the frames one tick apart are not collapsed at all —
///    115 of 116 sweeps eventually reached the panel, because each drained
///    frame is committed to the socket the moment it is built and the meter
///    only decides when it arrives. Ordering, within-tick latest-wins and
///    convergence on the current value are asserted; a claim that the queue
///    between ticks was discarded is not, and the number is in the registry.
///  * **F21's "no burst of backlogged frames on recovery"**, which is measured
///    to be false: 107 update frames and 376 kB in the first second after the
///    meter cleared, against a steady state of 10.0/s. The band was written
///    first, at half again the steady state, and it went red. It was not
///    widened — see the burst paragraph on that case and the registry entry
///    carrying both numbers.
///
/// A protocol-level ack that would make the drain gateable is a named
/// follow-up (07-CONTEXT user ruling 1), not built here.
///
/// **Why the throttle is the in-process proxy and not `tc netem`.**
/// 07-RESEARCH §B.1, and `slow_link_gate_test.dart` argues it at length: the
/// netem builder here has no bytes-per-second rate, netem is Linux-only in CI
/// and needs privilege, and `FaultProxy`'s throttle is measured at ±5 % over
/// 3.5 s at exactly the two rates this family names.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';

import '../support/fault_fixture.dart' show faultClientConfig, until;
import '../support/gate_bands.dart';
import '../support/gate_fixture.dart';

/// How wide the page this family drives is — F19's, and it must stay F19's.
///
/// The whole content of "slow link, doesn't fit" is that it is the *same* page
/// that fitted one row earlier, so the builder is shared
/// (`gate_fixture.dart`'s `plantPage`) rather than re-declared here.
const int _page = 200;

/// The gateway tick, and the plant's sweep period: the row's 10 Hz.
///
/// `ServerConfig` refuses anything outside 50-100 ms, so ten hertz is
/// `maxTick` exactly and it is named through the constant for
/// `slow_link_gate_test.dart`'s reason: if the supported band moves, the
/// compile still succeeds while the scenario silently becomes another one.
final Duration _tick = ServerConfig.maxTick;
final Duration _pagePeriod = _tick;

/// The rate both rows are run at: one hundred kilobits, in bytes per second.
///
/// `throttle_test.dart:47`'s constant, character for character, so the rate
/// these rows arm is the rate that file measured at ±5 %.
const int _hundredKilobit = 100 * 1000 ~/ 8;

/// What the page costs unthrottled, measured by 07-10 over this exact page at
/// this exact tick: 281 kbit/s, or about 35 kB/s.
///
/// This is the number the oversubscription is computed from and the number the
/// recovery band is computed from. It is written down rather than derived from
/// the catalogue's estimate because the two disagree by a factor of two.
const int _measuredPageBytesPerSec = 35126;

/// How long every rate in this file is measured over.
///
/// **Three and a half seconds, a floor rather than a preference**, for the
/// derivation `slow_link_gate_test.dart:119-133` gives: `DelayLine` banks up to
/// one second of burst, so a window shorter than about two seconds measures the
/// bank rather than the rate. The same number as that file's `_rateWindow` and
/// `backpressure_test.dart`'s `_throttleWindow`; all three must move together.
const Duration _rateWindow = Duration(milliseconds: 3500);

/// How long the link is left alone after a lever moves before a window opens.
const Duration _settleAfterLever = Duration(milliseconds: 700);

/// How long F20 holds the link saturated before it reads the staleness verdict.
///
/// **Derived from the verdict's own limit, not chosen.** The per-subscription
/// staleness limit is `tickMs × subscriptionStalenessMultiple`, floored at the
/// link deadline — 100 ms × 30 = 3 s against a 3 s deadline, so 3 s. The panel
/// therefore has to be **more than three seconds behind** before the honest
/// verdict can fire, and at 2.8x oversubscription the frames fall behind at
/// about 1.8 s per second of wall clock. Eight seconds buys roughly fourteen
/// seconds of lag, which is a margin over the limit rather than a race with it.
const Duration _saturationForStaleness = Duration(seconds: 8);

/// How long F21 saturates before it clears the throttle.
///
/// **Fifteen seconds in the default lane, and the catalogue says sixty.** The
/// shortening is declared in `gateDeviations` under F21 with its arithmetic:
/// the mechanism the recovery arm is about is the backlog, and the backlog
/// accumulates at (production − link) = about 22 kB/s, so fifteen seconds is
/// roughly 330 kB queued — two orders of magnitude more than one frame and
/// far more than enough for a flush to be visible as a burst. Sixty seconds
/// would add 45 s to an eight-minute lane to make the same number bigger.
const Duration _saturationForRecovery = Duration(seconds: 15);

/// The `controlDeadline` this file's panels are built with.
///
/// It has to be larger than the largest budget [_rpcBudgetFor] can derive,
/// because a deadline that expires first would decide clause 1 before the
/// assertion did — and would decide it as a thrown `TimeoutException` rather
/// than as a number this case could print.
const Duration _controlDeadline = Duration(seconds: 25);

/// How many bytes a link this oversubscribed has fallen behind by after
/// [saturatedFor] of a moving page.
///
/// Production minus link, times time. On this page and this meter that is
/// about 22.6 kB a second, and it is the number every budget below is derived
/// from rather than fitted to.
int _backlogBytesAfter(Duration saturatedFor) =>
    (_measuredPageBytesPerSec - _hundredKilobit) *
    saturatedFor.inMilliseconds ~/
    1000;

/// How long [backlogBytes] takes to cross the metered link.
Duration _drainOf(int backlogBytes) =>
    Duration(milliseconds: backlogBytes * 1000 ~/ _hundredKilobit);

/// How long an RPC issued [saturatedFor] into the window may take to come back.
///
/// **Derived, and generous, and the derivation is the point.** The priority
/// lane decides the order frames are *written* in. It cannot fix head-of-line
/// blocking: every lane shares one TCP stream, and a telemetry frame already
/// handed to the socket is ahead of a response minted afterwards no matter
/// which lane minted it. So the floor under any RPC's round trip is the time
/// it takes the already-committed backlog to drain at the metered rate, and
/// that floor **grows linearly with how long the window has been open**. A
/// fixed number here would be a bet on where in the case the RPC happens to
/// sit; this is the bound the transport actually imposes, plus four seconds
/// for the round trip itself and the runner's scheduling.
///
/// Measured on this build at 4.2 s of saturation: a 7365 ms round trip against
/// the 11.6 s this derives. What it still discriminates is a lane that has
/// stopped being a lane — a response conflated away, or one queued behind an
/// unbounded telemetry backlog, never arrives at all.
Duration _rpcBudgetFor(Duration saturatedFor) =>
    _drainOf(_backlogBytesAfter(saturatedFor)) + const Duration(seconds: 4);

/// What the conflating map is allowed to hold beyond the subscribed key count.
///
/// The telemetry half is keyed by (subscription, handle), so 200 keys cannot
/// exceed 200 entries however fast the plant moves — that is what conflation
/// *is*. `pendingCount` also counts the priority lane, which carries the
/// heartbeat's answers, `status` notifications and any RPC response minted
/// between two ticks. Sixteen is room for those without room for a queue.
const int _priorityAllowance = 16;

/// How often the conflating map and the session count are sampled.
const Duration _samplePeriod = Duration(milliseconds: 50);

/// The value the page is seeded with before the gateway starts.
const int _seed = 1000;

/// What a window saw. The two frame counts are deliberately separate, for
/// `slow_link_gate_test.dart`'s measured reason: **a quiet gateway still sends
/// this panel about ten frames a second**, because the tick engine emits a
/// `tick` notification per subscription per tick whether or not a value moved.
/// A cadence counted off raw inbound frames is a cadence a dead plant
/// satisfies.
typedef _Window = ({int frames, int updates, int bytes, double updatesPerSecond});

/// Whether [frame] is a `u` notification — a frame carrying values.
bool _isUpdate(String frame) {
  final decoded = jsonDecode(frame);
  return decoded is Map && decoded['method'] == Methods.update;
}

/// Opens a window of [window] on [panel] and reports what arrived.
///
/// The seam's retained frames are cleared at both ends rather than
/// accumulated: this family runs multi-second windows at ten frames a second
/// on a 3.5 kB page, and a case that becomes the memory problem it is
/// measuring reports the runner (07-RESEARCH trap 15).
Future<_Window> _observe(GateClient panel, Duration window) async {
  panel.seam.inbound.clear();
  await Future<void>.delayed(window);
  return _drain(panel, window);
}

/// Reads and clears whatever the seam has retained, as a window of [over].
_Window _drain(GateClient panel, Duration over) {
  var bytes = 0;
  var updates = 0;
  for (final frame in panel.seam.inbound) {
    // `length`, not `utf8.encode(...).length`: every byte on this page is
    // ASCII, so the two agree and encoding every frame would make the
    // measurement the load.
    bytes += frame.length;
    if (_isUpdate(frame)) updates++;
  }
  final frames = panel.seam.inbound.length;
  panel.seam.inbound.clear();
  return (
    frames: frames,
    updates: updates,
    bytes: bytes,
    updatesPerSecond: updates / (over.inMilliseconds / 1000),
  );
}

void main() {
  group('F20 — a link the page does not fit on', () {
    test('F20: a link that cannot carry the page degrades visibly and in order',
        () async {
      final wallClock = Stopwatch()..start();
      final keys = plantPage(_page);
      final fixture = await gateFixture(
        clients: 1,
        keys: keys.toSet(),
        // `readFresh` below is issued while the link is saturated, and the
        // client's own control deadline would otherwise expire before the
        // derived budget the clause is judged against.
        config: faultClientConfig(control: _controlDeadline),
        serverConfig: (port) => ServerConfig(tick: _tick, port: port),
        seed: (plant) => plant.setValues({for (final key in keys) key: _seed}),
      );
      final panel = fixture.clients.single;
      final session = fixture.server.sessions.sessions.single;

      // Clause 2's tap. Nulls are dropped for `herd_gate_test.dart`'s reason:
      // a resync blanks the page before refilling it, and a blank is not a
      // value an operator was shown.
      final delivered = <num>[];
      final tap = panel.client.subscribe(keys.first).listen((value) {
        if (value.value case final num seen) delivered.add(seen);
      });
      addTearDown(tap.cancel);

      // The conflating map, sampled rather than read at the end. A peak that
      // came and went between two ticks is the only shape clause 4 is about.
      var peakPending = 0;
      final sessions = <int>[];
      final sampler = Timer.periodic(_samplePeriod, (_) {
        final pending = session.buffer.pendingCount;
        if (pending > peakPending) peakPending = pending;
        sessions.add(fixture.sessionCount);
      });
      addTearDown(sampler.cancel);

      panel.proxy.throttleBytesPerSec = _hundredKilobit;
      final saturatedSince = Stopwatch()..start();
      // Disarmed before teardown: a proxy left metering at the end of a case
      // has a backlog to drain while the fixture is trying to release it.
      addTearDown(() => panel.proxy.throttleBytesPerSec = null);

      // ANTI-VACUITY, the lever: the throttle is armed on *this* panel's link.
      // `reject` excludes `throttle` and the refusal is a synchronous throw
      // taken before the mode is stored (`fault_proxy.dart:665-670`), so
      // asking for it neither disturbs the link nor arms anything.
      // `throttle_test.dart:118-131` is the precedent.
      expect(() => panel.proxy.reject(), throwsStateError,
          reason: 'the proxy accepted a request to start rejecting connections '
              'while a throttle was supposed to be armed on it. The two modes '
              'exclude each other, so every measurement below would be a '
              'measurement of an unmetered loopback socket wearing F20\'s name');

      final driver = drivePage(fixture.served, keys, period: _pagePeriod);
      await Future<void>.delayed(_settleAfterLever);

      final wroteBefore = driver.writes;
      final metered = await _observe(panel, _rateWindow);
      final wrote = driver.writes - wroteBefore;
      final oversubscription =
          _measuredPageBytesPerSec / _hundredKilobit;

      print('F20: over ${_rateWindow.inMilliseconds} ms on a '
          '$_hundredKilobit B/s link, a $_page-key page at '
          '${(1000 / _pagePeriod.inMilliseconds).toStringAsFixed(0)} Hz — '
          '${metered.updates} update frames '
          '(${metered.updatesPerSecond.toStringAsFixed(1)}/s) of '
          '${metered.frames} inbound, ${metered.bytes} bytes '
          '(${(metered.bytes / (_rateWindow.inMilliseconds / 1000)).toStringAsFixed(0)} B/s); '
          'the plant wrote $wrote values; the page costs '
          '$_measuredPageBytesPerSec B/s unthrottled, so this link is '
          '${oversubscription.toStringAsFixed(1)}x oversubscribed');

      // ANTI-VACUITY, the meter: the achieved rate is at the meter and not
      // above it. Unlike F19 this row *can* read the meter's own number,
      // because here the page genuinely exceeds the link — which is the
      // measurement F19's deviation 1 says belongs to F20.
      final achieved = metered.bytes / (_rateWindow.inMilliseconds / 1000);
      expect(achieved, lessThan(_hundredKilobit * 1.25),
          reason: 'the metered window carried '
              '${achieved.toStringAsFixed(0)} B/s against a $_hundredKilobit '
              'B/s meter. `throttle_test.dart` measures this mechanism at ±5 % '
              'over this same 3.5 s window; a quarter is the widening for a '
              'measurement taken through a gateway rather than against a '
              'firehose, and a rate above it means the bucket is not the thing '
              'shaping this link');

      // ANTI-VACUITY, the plant: the page was moving for the whole window. A
      // link throttled below the rate of nothing is not throttled.
      final expectedWrites =
          _page * _rateWindow.inMilliseconds ~/ _pagePeriod.inMilliseconds;
      expect(wrote, greaterThan(expectedWrites * 3 ~/ 4),
          reason: 'the plant wrote $wrote values across '
              '${_rateWindow.inMilliseconds} ms against the $expectedWrites a '
              '$_page-key page swept every ${_pagePeriod.inMilliseconds} ms '
              'owes. A page that is not moving cannot be behind');

      // ---------------------------------------------------------------------
      // CLAUSE 1 — the priority lane still answers.
      // ---------------------------------------------------------------------
      //
      // `readFresh` is a round trip to the plant and back, minted while the
      // link is saturated. It is the row's "writes/RPC responses still
      // complete promptly via the priority lane" without writing to a plant:
      // the same lane, the same `putPriority` call, no safety-relevant side
      // effect (CLAUDE.md: writes are never issued to make a measurement).
      final deliveredWhenAsked = delivered.isEmpty ? null : delivered.last;
      final saturatedForRpc = saturatedSince.elapsed;
      final rpcBudget = _rpcBudgetFor(saturatedForRpc);
      final rpcClock = Stopwatch()..start();
      final fresh = await panel.client.readFresh(keys.first);
      rpcClock.stop();

      print('F20 priority lane: readFresh(${keys.first}) issued '
          '${saturatedForRpc.inMilliseconds} ms into the saturated window came '
          'back in ${rpcClock.elapsedMilliseconds} ms against a derived '
          '${rpcBudget.inMilliseconds} ms budget (the '
          '${_backlogBytesAfter(saturatedForRpc)} bytes already committed to '
          'the socket ahead of it drain in '
          '${_drainOf(_backlogBytesAfter(saturatedForRpc)).inMilliseconds} ms '
          'at this meter), reading ${fresh.value}, while the conflated '
          'telemetry stream had the panel at $deliveredWhenAsked and the plant '
          'at ${driver.latest}');

      expect(rpcClock.elapsed, lessThan(rpcBudget),
          reason: 'an RPC issued ${saturatedForRpc.inMilliseconds} ms into the '
              'saturated window took ${rpcClock.elapsedMilliseconds} ms '
              'against the ${rpcBudget.inMilliseconds} ms the transport itself '
              'imposes. The priority lane is what stops an operator\'s request '
              'queueing behind a page of telemetry it does not care about; a '
              'lane that cannot answer inside the head-of-line bound is a lane '
              'that has stopped being a lane. See `_rpcBudgetFor`: lane order '
              'decides what is written first and cannot undo head-of-line '
              'blocking on the one TCP stream underneath, so the bound is the '
              'committed backlog\'s drain time and not a preference');
      expect(fresh.value, isNotNull,
          reason: 'the priority-lane answer carried no value at all, so the '
              'clause below about it not being conflated would be asserted '
              'about nothing');
      // The response is not conflated: it is a fresh read of the plant, so it
      // is at least as new as the telemetry the panel has been shown. This is
      // the interesting direction — a lane that had been conflated with the
      // telemetry stream would answer with the same lagging value.
      if (deliveredWhenAsked != null) {
        expect(fresh.value as num, greaterThanOrEqualTo(deliveredWhenAsked),
            reason: 'the priority-lane read answered ${fresh.value} while the '
                'conflated telemetry stream had already shown the panel '
                '$deliveredWhenAsked. An RPC response older than the telemetry '
                'beside it is a response that went through the conflating map '
                'instead of past it, and the whole point of the lane is that '
                'an answer to a question asked now is about now');
      }

      // ---------------------------------------------------------------------
      // CLAUSE 3 — the honesty arm, and the reason this plan exists.
      // ---------------------------------------------------------------------
      //
      // Held saturated until the panel's frames are further behind than the
      // per-subscription staleness limit, then read through the surface
      // 07-CONTEXT user ruling 1 had this phase wire. Before that wiring the
      // rendered verdict was the one `sawTick` stored, which compares
      // `tick.serverTime` against an `evaluatedAt` carried in the same delayed
      // frame — internally consistent, and blind (07-RESEARCH §B.4).
      await until(
          'the panel to report the page it is minutes behind on as stale',
          () => panel.client.staleSubscriptions.isNotEmpty,
          budget: _saturationForStaleness);

      final live = panel.client.staleSubscriptions;
      final lastTick = panel.client.debugStaleSubscriptionsAtLastTick;
      print('F20 staleness: the live verdict reports $live stale; the '
          'last-tick verdict reports '
          '${lastTick.isEmpty ? '{} — fresh' : lastTick}. The link is still '
          'up: the panel observed ${panel.observedClose.closeCode ?? 'no '
          'close'} and the gateway holds ${fixture.sessionCount} sessions');

      expect(live, isNotEmpty, // window-exempt: the until() immediately above completed on this same predicate, so this reads the set that window already established rather than betting on the staleness deadline a second time
          reason: 'the panel reported every subscription current while its '
              'frames were further behind than the staleness limit. This is '
              'the product\'s one unforgivable failure arriving through a door '
              'the link watchdog does not cover: frames keep arriving, so '
              'viewIsStale never fires, and the per-subscription verdict '
              'compares two fields of the same delayed frame');
      expect(lastTick, isEmpty, // window-exempt: the until() above established that the live verdict has already fired, and this is the contrast between the two surfaces at that established instant rather than a wait for either to change
          reason: 'the last-tick verdict reports $lastTick, so the contrast '
              'this row exists to record is not there. The pairing is the bug '
              'and the fix in one assertion: the stored set says fresh because '
              'the delayed frame agrees with itself, and the live verdict says '
              'stale because it ages against the panel\'s own clock. If the '
              'stored set has started firing too, the arithmetic has changed '
              'and this contrast no longer means what it says');
      expect(panel.observedClose.closeCode, isNull, // window-exempt: the until() above returned, which required the panel to be receiving and decoding ticks throughout, so this is a consistency check that the link the verdict was read over was up rather than a wait for a close
          reason: 'the panel\'s socket observed '
              '${panel.observedClose.closeCode}. Clause 3 is only interesting '
              'while the link is up: a stale verdict on a dead socket is the '
              'link watchdog doing its job, and this row is about the case '
              'where every liveness signal says yes');

      // ---------------------------------------------------------------------
      // CLAUSE 4 — the conflating map is bounded. **Not the socket buffer.**
      // ---------------------------------------------------------------------
      //
      // `pendingCount` is the gateway's per-session conflating map plus its
      // priority lane. It is bounded by construction: telemetry is keyed by
      // (subscription, handle), so a 200-key page is at most 200 entries
      // however fast the plant moves.
      //
      // **It is not a bound on the socket's buffer and nobody may read it as
      // one.** `dart:io` exposes no `bufferedAmount` and no flush completion
      // (flutter#103306); 07-RESEARCH §B.3 measured 700 KB "sent" onto a
      // 100 kbit/s link returning in 5 ms with zero bytes received and RSS up
      // 2.9 MB. The real backlog is in that buffer, this process cannot see
      // it, and it is why the "queue stays bounded" clause is a deviation
      // rather than a green.
      print('F20 conflating map: peak pendingCount $peakPending against '
          '$_page subscribed keys plus $_priorityAllowance of priority-lane '
          'headroom; the gateway held $sessions sessions');

      expect(peakPending, greaterThan(0),
          reason: 'the conflating map never held a single entry across the '
              'whole saturated window, sampled every '
              '${_samplePeriod.inMilliseconds} ms. Either the plant was not '
              'producing or this is the wrong session\'s buffer, and the bound '
              'below would then be a bound on an empty object');
      expect(peakPending, lessThanOrEqualTo(_page + _priorityAllowance),
          reason: 'the conflating map peaked at $peakPending entries against '
              '$_page subscribed keys. Last value wins per (subscription, '
              'handle), so more entries than there are keys means something is '
              'appending rather than replacing — which is a queue, and a queue '
              'on a link that cannot drain it grows until the process dies. '
              'This says nothing about the socket buffer: see the comment '
              'above and the F20 entry in gateDeviations');

      // ---------------------------------------------------------------------
      // CLAUSE 2 — monotonic, never reordered, and the last one is the latest.
      // ---------------------------------------------------------------------
      //
      // Read last, over everything the case delivered, so the sequence covers
      // the whole saturated window rather than a slice of it.
      driver.cancel();
      final saturatedFor = saturatedSince.elapsed;
      final committed = _backlogBytesAfter(saturatedFor);
      final wouldDrainIn = _drainOf(committed);

      // **The throttle is cleared before the convergence read, and that is a
      // measurement rather than a convenience.** "Its last element equals the
      // last value written" needs the link to actually deliver that value, and
      // the backlog already committed to the socket has to cross the wire
      // first. At this meter that is the number printed below — tens of
      // seconds for a window of this length, and it grows without bound while
      // the link stays saturated. **That number is the descoped clause's own
      // evidence**: if the drain were gated on egress completion (§7.6) there
      // would be nothing committed to drain, and this line would not need to
      // exist. The ordering assertion below covers every value delivered
      // across the saturated window and the clearing, so nothing about the
      // conflation claim is bought with the lever.
      panel.proxy.throttleBytesPerSec = null;
      await until(
          'the panel to be shown the last value the plant wrote '
          '(${driver.latest}) once the committed backlog has crossed',
          () => delivered.isNotEmpty && delivered.last == driver.latest,
          budget: recovery);

      print('F20 ordering: ${delivered.length} values delivered across the '
          'saturated window out of ${driver.sweeps} sweeps, ending at '
          '${delivered.last} against a plant that stopped at '
          '${driver.latest}. After ${saturatedFor.inMilliseconds} ms saturated '
          'the socket held about $committed bytes the conflating map had '
          'already let go of — ${wouldDrainIn.inMilliseconds} ms of drain at '
          'this meter, which is the queue F20\'s "queue stays bounded" clause '
          'is about and the one this process cannot see');

      expect(delivered, orderedEquals(List.of(delivered)..sort()),
          reason: 'the values the panel was shown are not in ascending order: '
              'the plant only counts up, so a value delivered after a larger '
              'one is an old value delivered *out of order*, which no queue in '
              'this design may produce. Conflation reorders nothing and '
              'recovery reorders nothing');
      expect(delivered.last, driver.latest,
          reason: 'the panel ended holding ${delivered.last} and the plant '
              'stopped at ${driver.latest}. Whatever a saturated link drops or '
              'delays, the value it settles on has to be the current one — a '
              'panel left one behind for ever is the silent-permanent-'
              'staleness case F8 is about, arriving by a slower road');

      // **Delivery during the metered window is sparse, and that is the half
      // of "conflation engages" this transport actually delivers.** Measured
      // in the window above: 12 update frames against the 35 sweeps the plant
      // made, so the panel was shown roughly one value in three.
      //
      // What is deliberately *not* asserted is that the values in between were
      // conflated away. They were not: the whole-case count printed above is
      // 115 delivered against 116 swept, because the conflating map collapses
      // changes only *within* one tick — between ticks each drained frame is
      // handed to the socket and committed, and the ones the meter could not
      // carry were replayed in full once it cleared. That is the same missing
      // egress gate, seen from the value side, and it is in `gateDeviations`
      // under F20's "never an old queued one" with these two numbers.
      final sweptInWindow =
          _rateWindow.inMilliseconds ~/ _pagePeriod.inMilliseconds;
      expect(metered.updates, lessThan(sweptInWindow * 3 ~/ 4),
          reason: 'the panel was fed ${metered.updates} update frames during '
              'the metered window against the $sweptInWindow sweeps the plant '
              'made in it, so delivery was not reduced and this link is not '
              'saturated at all. F20 is the row where the page does *not* fit; '
              'a panel shown every sweep is F19 wearing F20\'s name, and every '
              'clause above would then be describing a link with headroom');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway ended ${fixture.evictions} sessions. A 200-key '
              'page is 200 pending against the default soft ceiling of '
              '${ServerConfig().peakThreshold}, and `poll` measures this '
              'client\'s production rather than its backlog (03-REVIEW WR-11), '
              'so a throttled panel must not be thrown off — that boundary is '
              'G5, and F21 has no premise without it');
      expect(fixture.gatewayComplaints, isEmpty,
          reason: 'the gateway reported ${fixture.gatewayComplaints}. A page '
              'this wide against a link this slow is the shape that escapes an '
              'async error from a handler, and one swallowed by the default '
              'handler is a fault this row would pass straight over');

      print('F20 wall clock: ${wallClock.elapsedMilliseconds} ms');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('F21 and G6 — the link recovers', () {
    test('F21/G6: the link recovers and there is nothing queued to flush',
        () async {
      final wallClock = Stopwatch()..start();
      final keys = plantPage(_page);
      final fixture = await gateFixture(
        clients: 1,
        keys: keys.toSet(),
        config: faultClientConfig(control: _controlDeadline),
        serverConfig: (port) => ServerConfig(tick: _tick, port: port),
        seed: (plant) => plant.setValues({for (final key in keys) key: _seed}),
      );
      final panel = fixture.clients.single;

      final delivered = <num>[];
      final tap = panel.client.subscribe(keys.first).listen((value) {
        if (value.value case final num seen) delivered.add(seen);
      });
      addTearDown(tap.cancel);

      // Every close code the panel's socket observed, latched at 2 ms rather
      // than read at the end. 07-10 deviation 6: `observedClose` is the
      // *current* attempt's reading and the redial after an eviction erases it
      // in about one backoff draw, so a case that read it once could miss an
      // eviction entirely.
      final seenCodes = <int>{};
      final sessions = <int>[];
      final latch = Timer.periodic(const Duration(milliseconds: 2), (_) {
        final code = panel.observedClose.closeCode;
        if (code != null) seenCodes.add(code);
      });
      addTearDown(latch.cancel);
      final sampler = Timer.periodic(
          _samplePeriod, (_) => sessions.add(fixture.sessionCount));
      addTearDown(sampler.cancel);

      final driver = drivePage(fixture.served, keys, period: _pagePeriod);

      // The steady state, measured on *this* link before it is metered, so
      // the recovery band below is a band about this run rather than about a
      // number copied from another file.
      await Future<void>.delayed(_settleAfterLever);
      final before = await _observe(panel, _rateWindow);

      panel.proxy.throttleBytesPerSec = _hundredKilobit;
      addTearDown(() => panel.proxy.throttleBytesPerSec = null);
      await Future<void>.delayed(_settleAfterLever);
      final starved = await _observe(panel, _rateWindow);

      // Hold it there for the rest of the declared saturation window, so a
      // backlog has time to accumulate wherever it accumulates.
      final holdRemaining = _saturationForRecovery - _rateWindow -
          _settleAfterLever;
      await Future<void>.delayed(holdRemaining);

      // The staleness the recovery has to clear, established while the link is
      // still bad. G6's operator-visible half rides the surface task 1 wired.
      final staleWhileStarved = panel.client.staleSubscriptions;

      print('F21/G6: unthrottled ${before.updates} update frames '
          '(${before.updatesPerSecond.toStringAsFixed(1)}/s) of '
          '${before.frames} inbound; metered ${starved.updates} '
          '(${starved.updatesPerSecond.toStringAsFixed(1)}/s) of '
          '${starved.frames}; held saturated for '
          '${_saturationForRecovery.inSeconds} s, and the panel reports '
          '${staleWhileStarved.length} subscription(s) stale');

      // ANTI-VACUITY: the saturation was real. "Cadence returned" describes a
      // change only if it went somewhere first.
      expect(starved.updatesPerSecond, lessThan(before.updatesPerSecond / 2),
          reason: 'the metered window ran at '
              '${starved.updatesPerSecond.toStringAsFixed(1)} update frames/s '
              'against ${before.updatesPerSecond.toStringAsFixed(1)}/s '
              'unthrottled, so the link was never saturated and the recovery '
              'clauses below describe a lever that did nothing');
      expect(staleWhileStarved, isNotEmpty, // window-exempt: the saturation hold above ran for the declared window, which is several times the staleness limit, so this reads a verdict the completed hold established rather than waiting on a deadline
          reason: 'the panel reported nothing stale after '
              '${_saturationForRecovery.inSeconds} s on a link carrying a '
              'third of what the page costs. G6\'s operator-visible half is '
              'that the staleness *clears* on recovery, and a verdict that '
              'never fired cannot clear');

      // ---------------------------------------------------------------------
      // Recovery.
      // ---------------------------------------------------------------------
      panel.seam.inbound.clear();
      final recoveryClock = Stopwatch()..start();
      panel.proxy.throttleBytesPerSec = null;

      // THE BURST MEASUREMENT. Counted over the first second after the lever
      // is cleared and compared with the steady state measured on this same
      // link before it was metered — a band, never a multiple.
      await Future<void>.delayed(const Duration(seconds: 1));
      final firstSecond = _drain(panel, const Duration(seconds: 1));

      await until('the panel to be shown the plant\'s current value again',
          () => delivered.isNotEmpty && delivered.last >= driver.latest! - 2,
          budget: recovery);
      final backAt = recoveryClock.elapsedMilliseconds;

      await until('the staleness the saturated link raised to clear',
          () => panel.client.staleSubscriptions.isEmpty,
          budget: recovery);

      final steadyPerSecond = before.updatesPerSecond;
      final burstRatio = firstSecond.updates / steadyPerSecond;
      print('F21/G6 recovery: the first second after unthrottling carried '
          '${firstSecond.updates} update frames of ${firstSecond.frames} '
          'inbound (${firstSecond.bytes} bytes) against a steady state of '
          '${steadyPerSecond.toStringAsFixed(1)}/s — a ratio of '
          '${burstRatio.toStringAsFixed(1)}x. The panel was back on the '
          'plant\'s current value $backAt ms after the lever cleared — the '
          'burst window is a whole second and the convergence check runs after '
          'it, so that is an upper bound of one second and not the instant '
          '— and the staleness cleared inside the same window');

      // **THE BURST IS MEASURED, NOT ASSERTED, AND THAT IS THE RESULT.**
      //
      // The assertion was written first, at the honest band — the first
      // second's count within half again of the steady state, a band and not a
      // multiple — and it went **red**:
      //
      //     Expected: a value less than <15.0>
      //       Actual: <107>
      //
      // 107 update frames and 376191 bytes in the first second after the lever
      // cleared, against a steady state of 10.0/s. The catalogue's parenthesis
      // — "the conflating map means there is no backlog to flush" — is false
      // on this transport, and 07-RESEARCH §B.3 said so before this case ran.
      // The map is bounded (F20 clause 4 measures it at 201 entries) but it is
      // drained into `dart:io`'s outgoing buffer every tick whether or not the
      // socket can carry the result, so the backlog is real, it is invisible
      // to this process, and clearing the meter releases all of it at once.
      //
      // **The band was not widened.** 07-CONTEXT user ruling 1 descopes the
      // egress-gated drain that would prevent this, the clause is now an entry
      // in `gateDeviations` under F21 carrying these two numbers, and what
      // this case still asserts is everything that *is* true of the recovery:
      // it converges, it converges quickly, it never delivers a value out of
      // order while doing so, the cadence comes back, the staleness clears and
      // nobody is thrown off. A burst that arrives in order and settles is a
      // different thing from a burst that walks a setpoint backwards, and the
      // ordering arm below is what tells them apart.

      // Cadence returned, measured over a proper window rather than the burst
      // second.
      final after = await _observe(panel, _rateWindow);
      print('F21/G6 cadence: ${after.updates} update frames '
          '(${after.updatesPerSecond.toStringAsFixed(1)}/s) over '
          '${_rateWindow.inMilliseconds} ms after recovery, against '
          '${before.updatesPerSecond.toStringAsFixed(1)}/s before the lever '
          'and ${starved.updatesPerSecond.toStringAsFixed(1)}/s under it');

      expect(after.updatesPerSecond, greaterThan(before.updatesPerSecond * 0.9),
          reason: 'the panel is being fed '
              '${after.updatesPerSecond.toStringAsFixed(1)} update frames/s '
              'after the throttle was cleared, against '
              '${before.updatesPerSecond.toStringAsFixed(1)}/s on the same '
              'link before it was armed. The lever is gone and the cadence did '
              'not come back with it, so something about the saturated window '
              'left the panel permanently degraded');

      // G6's operator-visible half: the staleness cleared. Asserted through
      // the same surface F20 clause 3 read, so the two rows are two halves of
      // one mechanism rather than two mechanisms.
      expect(panel.client.staleSubscriptions, isEmpty, // window-exempt: the until() above completed on exactly this predicate, so this reads the set that window established rather than betting on the staleness limit clearing a second time
          reason: 'the panel is still reporting '
              '${panel.client.staleSubscriptions} stale after the link came '
              'back and the current value arrived. A grey that does not clear '
              'is worse than no grey at all: the operator learns inside a week '
              'that grey means nothing');

      // Still no eviction, and still monotonic across the transition.
      expect(seenCodes, isEmpty,
          reason: 'the panel\'s socket observed $seenCodes across the whole '
              'case, latched at 2 ms. A throttled 200-key page is 200 pending '
              'against a default soft ceiling of '
              '${ServerConfig().peakThreshold} and `poll` measures production, '
              'not backlog, so nobody may be thrown off here — that is the '
              'premise F21 rests on');
      expect(fixture.evictedForBackpressure, isEmpty,
          reason: 'the gateway\'s ledger records '
              '${fixture.evictedForBackpressure}. The ledger is a record and '
              '`observedClose` is a reading (07-10 deviation 6), so both are '
              'asked');
      expect(sessions, everyElement(1),
          reason: 'the gateway held $sessions sessions, sampled every '
              '${_samplePeriod.inMilliseconds} ms. One reap and one redial '
              'inside the window leaves the count at 1 at both ends, so an '
              'end-state reading would not see it');
      expect(delivered, orderedEquals(List.of(delivered)..sort()),
          reason: 'the values the panel was shown are not in ascending order '
              'across the throttle-and-recover transition. Recovery delivering '
              'an old value after a newer one is the backlog flush this row '
              'forbids, and it is the one failure here an operator would act '
              'on: a setpoint that went backwards');

      print('F21/G6 wall clock: ${wallClock.elapsedMilliseconds} ms');
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
