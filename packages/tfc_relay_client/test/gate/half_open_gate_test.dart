/// F4 and F5: the link that is up and carrying nothing.
///
/// **F4 — Asymmetric half-open.** `bufferServerToClient`. The catalogue asks
/// that the app-level freshness deadline fires (rule 1);
/// all values grey out (rule 4) even though socket looks connected.
///
/// **F5 — True half-open both ways.** `blackhole()`. The catalogue asks that
/// `pingInterval` closes the socket within its deadline; freshness deadline
/// fires first or concurrently; no wait for TCP timeouts (minutes).
///
/// This is the fault the whole product is built against, and the one no
/// `onDone` will ever report: the socket is open, the peer is gone, and every
/// surface above the transport reads healthy. F4 is the half where the client's
/// own requests still arrive and the answers are withheld; F5 is the half where
/// both directions are swallowed.
///
/// **What F5a deliberately does not assert.** It does not measure
/// `pingInterval` closing the socket. It measures the *write* resolving as
/// unknown and the link recovering, which is the clause an operator feels; the
/// ping-deadline clause of the row is asserted where the ping is configured,
/// not here.
///
/// **F5b's three wall-clock reads, and what happened to them (07-03).** They
/// were the parked flake 07-CONTEXT ruling 6 names: `viewIsStale` read at an
/// instant against a 500 ms deadline, failing about one full-suite run in three
/// on a loaded runner — on a link with nothing wrong with it. 07-02 moved the
/// case unedited and marked the reads TEMPORARY; 07-03 deleted the markers,
/// watched the sweep name all three, and then split them:
///
/// - the two `viewIsStale` reads became `until()` windows. Both went red under
///   a forced 800 ms isolate stall before the fix and green after it, which is
///   the reproduction the fix was allowed to be built on.
/// - the `linkState` read kept an exemption, now **permanent**, with the
///   completed event named on the line. The same stall left it green, because
///   the barrier and the link state are two surfaces of one statement sequence
///   rather than two events; a window there would accept a client that kept
///   publishing `ready` for four seconds after it stopped believing the link.
///
/// The deadline is now platform-scaled from `gate_bands.dart`, which is a
/// second line of defence and not the fix. A wall-clock boolean read at an
/// instant is a race at any deadline.
///
/// Moved here verbatim from `test/contract/fault_contract_test.dart` in Phase 7
/// (07-02); bodies unchanged then, hardened here.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

void main() {
  group('F4/F5 — the link that is up and carrying nothing', () {
    test('F4: a link that withholds answers degrades honestly — nothing is '
        'aged into looking current', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        config: faultClientConfig(control: const Duration(milliseconds: 400)),
        // Stamped, unlike the other cases' seeds: the gateway puts `t` on the
        // wire only when the source has one (`session_handlers.dart:297-306`),
        // and this is the one case whose property is about the *age* of the
        // cached reading rather than its value. A real PLC reading always
        // carries one.
        seed: (plant) =>
            plant.setValue(scenarioKey, 1200, sourceTime: DateTime.now().toUtc()),
      );
      await until('the link', () => fixture.client.isReady);
      final held = fixture.client.read(scenarioKey);
      expect(held?.sourceTime, isNotNull,
          reason: 'the cached reading carries no source time, so the '
              'assertion below that its age did not move is comparing two '
              'nulls (the WireValue.t decode defect 04-09 fixed)');

      // The asymmetric half-open: the client's requests still reach the
      // gateway and the gateway's answers are held. The socket stays up, which
      // is what makes this the quiet failure rather than a disconnect.
      fixture.proxy.bufferServerToClient = true;

      final started = DateTime.now();
      Object? failure;
      await fixture.client
          .readFresh(scenarioKey)
          .then<void>((_) {}, onError: (Object error) => failure = error);
      final took = DateTime.now().difference(started);

      expect(failure, isA<TimeoutException>(),
          reason: 'a forced round trip during a half-open came back with '
              '$failure. `readFresh` promises the caller a *fresh* value; the '
              'one thing it must never do is quietly answer from the cache, '
              'because then a panel behind a withheld link shows an operator a '
              'reading it has no current evidence for');
      expect(took, greaterThan(const Duration(milliseconds: 400) - slack),
          reason: 'the call failed in ${took.inMilliseconds} ms, well inside '
              'its own deadline, so something other than the deadline ended '
              'it and the withhold is not what this measured');
      expect(took, lessThan(const Duration(milliseconds: 400) + recovery),
          reason: 'the deadline did not bound the call: a request that '
              'outlives its deadline is the spinner the deadline exists to '
              'prevent');

      expect(fixture.client.read(scenarioKey)?.value, held?.value,
          reason: 'the cached value moved while nothing was arriving, which '
              'means it came from somewhere other than the gateway');
      expect(fixture.client.read(scenarioKey)?.sourceTime, held?.sourceTime,
          reason: 'the cached reading\'s source time advanced during an outage '
              'in which no frame arrived. That is the product\'s one '
              'unforgivable failure: a value that ages itself into looking '
              'current is indistinguishable, on screen, from a live one');

      // And the fault is survivable: releasing the direction brings the client
      // back without a reconnect, because the socket never went away.
      fixture.proxy.bufferServerToClient = false;
      fixture.served.setValue(scenarioKey, 1500);
      await until('the value after the withhold was released',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);
    });

    test('F5a: a total half-open resolves a write as unknown rather than '
        'refused, and the link recovers', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        config: faultClientConfig(write: const Duration(milliseconds: 400)),
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      expect(fixture.client.read(scenarioKey)?.value, 1200,
          reason: 'the page was not live before the blackhole, so the '
              'recovery arm at the end is about nothing');

      // Both directions swallowed, sockets still up: the fault the whole
      // project is built against, and the one no `onDone` will ever report.
      fixture.proxy.blackhole();

      final outcome = await fixture.client.write(scenarioKey, 1500).timeout(recovery);

      expect(outcome, isA<WriteUnknown>(),
          reason: 'the write came back $outcome. Nobody knows whether the '
              'setpoint reached the device — the request may have crossed '
              'before the link went silent — and reporting a swallowed link as '
              'a refusal tells an operator a machine definitely did not move '
              'when it may well have');
      expect((outcome as WriteUnknown).reason.kind,
          anyOf(FailureKind.deadlineExpired, FailureKind.linkLost,
              FailureKind.linkDown),
          reason: 'the unknown must name something an integrator can act on; '
              'got ${outcome.reason.kind}');
      expect(fixture.client.debugWritesSent, 1,
          reason: 'the write was sent more than once. On a plant that is a '
              'second stroke of a ram the operator commanded once, and no '
              'amount of link trouble makes it acceptable');
      expect(fixture.client.debugUnresolvedCmds, contains(outcome.cmd),
          reason: 'an unknown outcome that is not held for re-query is an '
              'outcome nobody will ever establish');

      fixture.proxy.blackhole(enabled: false);
      fixture.served.setValue(scenarioKey, 1500);
      await until('the link recovering after the blackhole lifted',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);
    });

    test('F5b: a half-open link stops reading ready, and says so', () async {
      // 04-REVIEW CR-06. The watchdog computed all of this correctly and
      // nothing above it could read a word, so the case the whole product is
      // built around — socket up, no frames, values frozen — presented as
      // LinkState.ready, isReady true, Quality.good, and no observable of any
      // kind for as long as the panel stayed on.
      //
      // **A precondition you are willing to wait for is a precondition; one you
      // read at an instant is a race.** Both freshness reads below are windows
      // for that reason and not because the property is weaker than it was:
      // `viewIsStale` is a wall clock rendered as a bool, and a read of it at
      // one moment is a bet that the isolate was not busy over the preceding
      // deadline. The bet loses about one full-suite run in three
      // (07-RESEARCH §E.2), and it loses on a link with nothing wrong with it,
      // which is the worst way for a gate to be wrong: it names the mechanism
      // under test while measuring the machine underneath.
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        config: faultClientConfig(freshness: freshnessDeadline),
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);
      await until(
          'a fresh view before the blackhole is armed, without which the '
          'transition below is not a measurement of the blackhole',
          () => !fixture.client.viewIsStale,
          budget: recovery);

      final transitions = <bool>[];
      final watching = fixture.client.viewFreshness.listen(transitions.add);
      addTearDown(watching.cancel);

      fixture.proxy.blackhole();

      // Budgeted by the deadline and not by the flat recovery number: what is
      // being bounded here *is* the deadline, and a watchdog that had quietly
      // slowed to four seconds would clear a five-second budget.
      await until('the view to be reported stale',
          () => fixture.client.viewIsStale,
          budget: freshnessTransition);
      expect(transitions, contains(true),
          reason: 'the freshness stream never emitted, so nothing above this '
              'client could render the staleness it had detected');
      await until('the link to stop reading ready',
          () => !fixture.client.isReady,
          budget: recovery);
      // The exemption below is PERMANENT, and it is a different shape from the
      // two freshness reads above. `isReady` is `barrier.isOpen`, and the only
      // thing that closes that barrier is `_down()`, which re-arms the barrier
      // and calls `_enter(LinkState.down)` in one unbroken statement sequence
      // with no await between them (`connection_supervisor.dart:661-663`). The
      // `until()` above therefore waited for the completed event; this line
      // reads the *other* surface of it and asks whether the two agree.
      //
      // Rewriting it as a window would weaken it. `until()` polls for a
      // predicate to *become* true, so a windowed version would accept a client
      // that kept publishing `ready` for another four seconds after it had
      // stopped believing in the link — an operator watching a green banner
      // over a dead one, which is the exact disagreement this line exists to
      // forbid. Measured, not assumed: 07-03's P2 probe stalled the isolate for
      // 800 ms against a 500 ms deadline immediately before this read and it
      // held, while the same stall turned both freshness reads red.
      expect(fixture.client.linkState, isNot(LinkState.ready), // window-exempt: the until() above waited for the barrier to re-arm, and _down() re-arms it and leaves LinkState.ready in one statement sequence with no await between
          reason: 'a socket that has said nothing for a whole freshness '
              'deadline is one this client must stop believing in; leaving it '
              'at ready is the operator reading a five-minute-old tank level '
              'as current');

      // And it recovers on its own, which is what makes acting on the silence
      // safe: the reconnect loop is the same one every other kind of drop uses.
      fixture.proxy.blackhole(enabled: false);
      await until('the reconnect', () => fixture.client.isReady,
          budget: recovery);
      // Freshness clearing is a *different event* from the barrier opening —
      // `sawFrame` clears it, `_enter(ready)` opens the barrier — so the read
      // this replaced was not a consistency check against the wait above it. It
      // was the wall clock read at an instant, and it is the one of the three
      // that carried no reason string at all.
      await until('the view to be fresh again after the reconnect',
          () => !fixture.client.viewIsStale,
          budget: recovery);
      fixture.served.setValue(scenarioKey, 1500);
      await until('values flowing again',
          () => fixture.client.read(scenarioKey)?.value == 1500,
          budget: recovery);
    });
  });
}
