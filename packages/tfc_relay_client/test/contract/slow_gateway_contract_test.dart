/// The arm that would have caught it: a contract case must be bounded by the
/// property it names, not by how long the gateway took to answer hello.
///
/// **Why this file exists.** The first check the umbrella registers —
/// `subscribe: a subscribed key delivers its current value, good` — went red on
/// both CI runners on this branch's first run, and green on every developer
/// machine. It was not flaky and it was not a regression. Every case gets its
/// implementation from `make()` synchronously and starts asserting on the next
/// line, so on this leg the case's first `within` was covering the dial, the
/// WebSocket handshake, the subscribe of a three-hundred-key page and the two
/// server ticks those two round trips wait on, and only then the value the case
/// is actually about. Measured here on an idle machine: `PIPE.connected` at
/// 105 ms, the plant value 0.3 ms after it, against a 200 ms budget. A runner
/// with two shared cores does not have 105 ms of slack to give.
///
/// **A load test would not do.** Reproducing it by loading the machine works —
/// 28 spinners on 14 cores fails exactly that case and nothing else — but a
/// regression arm that needs the machine to be busy is one that passes on the
/// day it should fail. So the runner condition is reproduced by configuration
/// instead: [ServerConfig.maxTick] is 100 ms, the top of the band the gateway
/// itself declares supported, and the two ticks a hello-then-subscribe costs
/// put readiness past 200 ms on *any* machine. Before the readiness barrier
/// this file failed deterministically with the exact CI sentence — "the first
/// value for a subscribed key did not happen within 200 ms".
///
/// **What it pins, and what it must not become.** It pins that a case's budget
/// bounds the case's property. It is not a claim that the gateway is fast, and
/// it must never be answered by raising a budget: with the barrier in place the
/// property has 200 ms to cover a 0.3 ms delivery, so if this ever fails again
/// the thing that broke is delivery, and the tick is only how long it waited to
/// start.
///
/// One case rather than the whole registry: the barrier is in
/// `runStateManContract`'s per-case body, so it is the same code path for all
/// fifty-one, and the leg beside this one already runs them all at `minTick`.
@TestOn('vm')
@Tags(['contract', 'ws'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import '../support/client_harness.dart';

void main() {
  group('a gateway ticking at the slowest rate it supports', () {
    test('still leaves the first value bounded by its own budget', () async {
      final api = relayFixture(
        config: ServerConfig(tick: ServerConfig.maxTick),
      ).api;
      addTearDown(api.dispose);

      // The barrier the suite applies to every case, applied here by hand:
      // this file drives one check directly rather than through the umbrella,
      // so leaving it out would test the old shape and pass for the wrong
      // reason.
      await linkUp(api);
      await checkListenDeliversCurrentValue(api);
    });

    test('and the barrier is what makes that true', () async {
      // The anti-vacuity arm. Without `linkUp` the same case, on the same
      // fixture, fails on the 200 ms it never had — which is the CI failure,
      // reproduced deterministically rather than by loading the machine.
      final api = relayFixture(
        config: ServerConfig(tick: ServerConfig.maxTick),
      ).api;
      addTearDown(api.dispose);

      Object? caught;
      try {
        await checkListenDeliversCurrentValue(api);
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<TestFailure>(),
          reason: 'the case passed with no readiness barrier at the slowest '
              'supported tick, so this leg no longer demonstrates anything: '
              'either the gateway answers hello and subscribe without waiting '
              'on a tick now, or the budget above has been widened. Check '
              'which before deleting this arm');
      expect('$caught', contains('the first value for a subscribed key'));
      expect('$caught', contains('200 ms'));
    });
  });
}
