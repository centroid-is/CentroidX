/// F13: a slow link is slow, not down.
///
/// **F13 — High latency.** `latency(500ms, 200ms)`. The catalogue asks for no
/// false disconnects: ping and freshness deadlines tolerate configured RTT;
/// staleness age (rule 4) reflects real delay.
///
/// A panel that reconnects on latency turns a congested switch into a reconnect
/// storm, and the storm is what keeps the switch congested — so the property is
/// as much about what must *not* happen as about the answer arriving.
///
/// **Uprated to the catalogue's numbers in 07-05.** It ran at a flat 100 ms with
/// no jitter, against a row written for 500 ms ± 200 ms; the arithmetic that
/// sizes the deadline against the worst jitter draw is in `gate_bands.dart`
/// beside [f13Deadline], and the settle window is now derived from the round
/// trip rather than being the flat 400 ms that had become shorter than a single
/// exchange.
///
/// **The second clause, and the honest limit on how far it can be asserted
/// today.** The row asks that the staleness *age* reflect the real delay. The
/// client exposes no age: `viewIsStale` and `staleSubscriptions` are booleans
/// and a set of ids, `DynamicValue.sourceTime` is null on this path (measured —
/// the plant does not stamp it), and the only place a per-subscription age
/// exists at all is inside `FreshnessWatchdog`, which keeps `_evaluatedAt` in
/// the gateway's clock and publishes only the verdict derived from it
/// (`freshness_watchdog.dart`, `staleSubscriptionsNow`). So this file asserts
/// the *transition timing* of the boolean instead — the surface an operator
/// actually sees — and no getter is invented here to make a number appear.
/// 07-11 wires the staleness surface (07-CONTEXT ruling 1) and F13's outstanding
/// entry names that as the remaining clause.
///
/// What the boolean arm is worth: at half a second each way the panel is a long
/// way inside every deadline it holds, so the operator must be shown a live page
/// for the whole window. A single transition to stale here is the false grey
/// that trains people to ignore grey.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

/// How often the per-subscription verdict is read across the settle window.
///
/// Fast enough that a verdict flickering for a tick or two is caught — the
/// gateway's measured fan-out is 50 ms and the client re-judges on every one
/// of those — and slow enough that the sampler is not the load.
const Duration _staleSamplePeriod = Duration(milliseconds: 20);

void main() {
  group('F13 — a link that is merely slow', () {
    test('F13: a slow link is slow, not down', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        config: faultClientConfig(control: f13Deadline, write: f13Deadline),
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      final dialsBefore = fixture.seam.dials;

      // Every transition of the operator-visible verdicts, recorded across the
      // whole slow window. Attached *before* the latency rises, because the
      // clause is that nothing happens from here on and a recorder attached
      // afterwards could not see the first thing that did.
      final freshness = <bool>[];
      final watchingFreshness =
          fixture.client.viewFreshness.listen(freshness.add);
      addTearDown(watchingFreshness.cancel);
      final states = <LinkState>[];
      final watchingStates = fixture.client.linkStates.listen(states.add);
      addTearDown(watchingStates.cancel);

      // The per-subscription verdict is not a transition stream, so it cannot
      // be recorded the way the two above are — it is sampled instead, which
      // is what turns "it is empty" into "it stayed empty across the window"
      // (07-REVIEW WR-05). The sampler is attached here, with them, for the
      // same reason they are: the clause is that nothing happens from now on.
      final staleSamples = <Set<String>>[];
      final samplingStale = Timer.periodic(
          _staleSamplePeriod, (_) => staleSamples.add(
              fixture.client.staleSubscriptions));
      addTearDown(samplingStale.cancel);

      // Live: it reaches the connection that is already open, which is the
      // only shape "the link degrades while the panel is connected" comes in.
      fixture.proxy.latency = f13Latency;
      fixture.proxy.jitter = f13Jitter;

      final started = DateTime.now();
      final value = await fixture.client.readFresh(scenarioKey).timeout(recovery);
      final took = DateTime.now().difference(started);
      print('F13: round trip ${took.inMilliseconds} ms at '
          '${f13Latency.inMilliseconds} ms +/- ${f13Jitter.inMilliseconds} ms '
          'one way, against a ${f13Deadline.inMilliseconds} ms deadline');

      expect(value.quality, Quality.good,
          reason: 'a slow answer is still an answer; degrading its quality '
              'because it took 200 ms would grey a healthy plant');
      expect(took, greaterThan(f13Latency * 2 - slack),
          reason: 'the round trip took ${took.inMilliseconds} ms, less than '
              'the two one-way delays the proxy was told to impose. The lever '
              'did not reach the open connection, so this case is measuring an '
              'ordinary link');
      expect(took, lessThan(f13Deadline),
          reason: 'a round trip of ${took.inMilliseconds} ms exceeded the '
              'deadline it was given. That is not a fault report, it is a '
              'false one: the gateway answered');

      // And no false disconnect over a window. Instants are useless here —
      // the whole point is that nothing happens for a while.
      await Future<void>.delayed(f13Settle);
      expect(fixture.seam.dials, dialsBefore,
          reason: 'the client redialled during a link that was merely slow. A '
              'panel that reconnects on latency turns a congested switch into '
              'a reconnect storm, and the storm is what keeps the switch '
              'congested');
      expect(fixture.client.isReady, isTrue, // window-exempt: the settle delay above completed and the dials assertion just proved no redial happened during it; the property is that readiness STAYED true across that elapsed window, and until() would accept a client that became ready late — which is precisely the false disconnect this case forbids
          reason: 'the client left ready on a link that was answering');

      // **The clause about what the operator sees.** Judged over the collected
      // transitions rather than by reading a boolean at an instant, which is
      // the F5 flake this directory's sweep exists to forbid.
      expect(states.where((state) => state != LinkState.ready), isEmpty,
          reason: 'the client published $states across a window in which every '
              'request was answered inside its deadline. Any state but ready '
              'here is the false disconnect the row forbids, and the operator '
              'sees it as the page dropping out');
      expect(freshness.where((stale) => stale), isEmpty,
          reason: 'the view went stale ${freshness.where((s) => s).length} '
              'time(s) on a link whose every answer arrived inside its '
              'deadline. A half-second link is slow, not gone, and greying the '
              'page here is how an operator learns to ignore grey');
      // The per-subscription verdict, over the same window rather than at the
      // instant the window closed.
      //
      // **This used to be an exemption, and the exemption was wrong** — the
      // first one in the tree that was (07-REVIEW WR-05). It claimed the
      // freshness transition list asserted two lines above established the
      // state being read. It does not: `viewFreshness` is the **link-level**
      // verdict and `staleSubscriptions` is the **per-subscription** one, and
      // `freshness_watchdog.dart` and this file's own header both say the two
      // are deliberately independent — the set can be non-empty while the link
      // is provably healthy, which is the whole of CLI-04. So the completed
      // event the marker named could not establish the state it was
      // suppressing an arm about, and a forty-character floor cannot detect a
      // reason that is long, fluent and false.
      samplingStale.cancel();
      expect(staleSamples.where((stale) => stale.isNotEmpty), isEmpty,
          reason: 'the page was reported stale by the per-subscription verdict '
              '${staleSamples.where((s) => s.isNotEmpty).length} time(s) '
              'across ${f13Settle.inMilliseconds} ms in which the link '
              'answered every request inside its deadline. A half-second link '
              'is slow, not gone, and a widget reading this surface shows a '
              'grey page while the one reading viewFreshness shows a live one');
      expect(staleSamples.length,
          greaterThan(f13Settle.inMilliseconds ~/
              _staleSamplePeriod.inMilliseconds ~/ 2),
          reason: 'the sampler took ${staleSamples.length} readings over '
              '${f13Settle.inMilliseconds} ms at one per '
              '${_staleSamplePeriod.inMilliseconds} ms, less than half what it '
              'should have. "Every sample was empty" is a claim about the '
              'samples, and too few of them makes the arm above vacuous — the '
              'same anti-vacuity the flap row states for its own sampler');

      // **Anti-vacuity, and why it has to be a positive control rather than an
      // `isNotEmpty`.** Both recorders are *transition* streams, so a correct
      // client on a link that never faltered emits nothing on either — which is
      // exactly what the arms above assert. Demanding a non-empty list would
      // demand the failure the row forbids. Measured: the first draft asserted
      // `states, isNotEmpty` and went red with `Expected: non-empty / Actual:
      // []` against a perfectly healthy client.
      //
      // So the emptiness is given teeth from the other end: provoke one
      // transition on purpose, after every assertion above has been made, and
      // require the recorder to report it. A stream that was never attached
      // fails here, which is the only thing that could have made the arms above
      // vacuous.
      final observedDuringSlowLink = List<LinkState>.of(states);
      fixture.proxy.killOnce();
      await until('the recorder to report the link this case just killed',
          () => states.length > observedDuringSlowLink.length,
          budget: recovery);
      expect(states.skip(observedDuringSlowLink.length), isNotEmpty,
          reason: 'the recorder did not report a link that was deliberately '
              'killed under it, so it was never attached and the emptiness '
              'arms above were statements about an unwired stream');
      print('F13: ${observedDuringSlowLink.length} link-state transitions '
          'during the slow window, ${freshness.length} freshness transitions '
          '(${freshness.where((s) => s).length} to stale); the control kill '
          'was reported as ${states.skip(observedDuringSlowLink.length)}');
    });
  });
}
