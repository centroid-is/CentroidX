/// The third release path: the link dies under a live hold.
///
/// Source: 05-CONTEXT decision 2 — each of the three release paths gets its
/// own test, and this one is the path the other two cannot reach. The
/// in-memory harness has no link to lose, and the channel pair forwards
/// client-to-server verbatim by design with `sever()` dropping only
/// server-to-client (05-RESEARCH trap 8), so the fault this case exists for is
/// not one that harness can produce. It runs against a real gateway over a
/// real socket with the real `FaultProxy` in front of it (D-P5-M).
///
/// Source: 05-RESEARCH §G.3 — the release is immediate on leaving `ready`,
/// never bounded by a write deadline, because the counter has already stopped
/// reaching the plant and waiting would leave the panel showing a live hold
/// for up to two budgets. The release write is still attempted; it resolves
/// `WriteUnknown(link_down)`, which is the honest answer and costs nothing.
///
/// **Its own file, not `fault_contract_test.dart`.** That file carries the
/// suite-through-the-proxy accounting and 05-06's leg constants, and this
/// plan's work lands in the same wave as edits to those. Two plans editing one
/// file across two waves is a merge conflict wearing a test's clothes; the
/// duplication that costs — the fixture wiring below — is one call to a shared
/// `support/` helper.
///
/// **Every timing assertion is a window.** The bands are the package's, Linux
/// 20/100 and 75/150 elsewhere, and nothing here reads a proxy state at an
/// instant: a connect attempt has been measured completing on the far side of
/// a proxy state transition.
@TestOn('vm')
@Tags(['faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_client/src/hold_to_run_controller.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/fault_fixture.dart';

/// The tag this case's deadman lands on. Seeded before the gateway starts:
/// `FakeStateMan.keys` does not name a tag until a value has been set on it,
/// and a key seeded after the client subscribed is rejected as a typo
/// (`fault_fixture.dart:103-109`).
const _key = 'ST101.CN01.MOT01.setpoint';

/// The cadence injected here, well under the production 100 ms.
const Duration _pulse = Duration(milliseconds: 25);

/// How far the counter must get before "and then it stopped" means anything.
const int _pulsesBeforeTheCut = 4;

/// The budget for "the panel noticed": a freshness deadline, a close and a
/// state transition. `support/gate_bands.dart:64-68`'s number and argument
/// — a liveness budget, never a latency measurement.
const Duration _recovery = Duration(seconds: 5);

/// Long enough for anything still in flight when the link died to have landed.
const Duration _settle = Duration(milliseconds: 400);

/// Longer than three pulse periods: the window "the counter stopped" is
/// measured over, because the absence of an event is the one shape a poll
/// cannot establish.
const Duration _quiet = Duration(milliseconds: 300);

/// The freshness deadline these cases run with.
///
/// Short deliberately and greppably, the way `faultClientConfig` lowers the
/// deadline floor: a blackholed link has to be *noticed* inside the case's own
/// budget, and the watchdog noticing is what takes the client out of `ready`
/// and therefore what fires the release. The production number is 3 s and is
/// not what this case is about.
const Duration _noticeTheSilence = Duration(milliseconds: 500);

void main() {
  group('the link dies under a live hold', () {
    test('losing the link stops the counter, and the release is attempted '
        'honestly', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        config: faultClientConfig(
          freshness: _noticeTheSilence,
          write: const Duration(milliseconds: 400),
          control: const Duration(milliseconds: 400),
        ),
        seed: (plant) => plant.setValue(_key, 0),
      );
      await until('the link', () => fixture.client.isReady);

      final controller = HoldToRunController(
        api: fixture.client,
        key: _key,
        pulsePeriod: _pulse,
      );
      addTearDown(controller.dispose);

      final engagement = await controller.press().timeout(_recovery);
      expect(engagement, isA<WriteApplied>(),
          reason: 'the engage over a healthy socket came back as '
              '${engagement.runtimeType}, so there is no live hold here and '
              'the cut below would be a cut under nothing');

      // Anti-vacuity, and it is read **at the source** rather than from the
      // client's own counter: the property is that the plant stopped being
      // fed, and a client-side number would still be moving if every pulse
      // were vanishing on the way.
      await until(
          'the deadman counter to pass $_pulsesBeforeTheCut at the plant',
          () => (fixture.served.read(_key)?.asInt ?? 0) >= _pulsesBeforeTheCut,
          budget: _recovery);

      // A blackhole rather than a kill: both directions swallowed with the
      // sockets still up is the fault the whole project is built against, and
      // it is the one that keeps the gateway's own session — and therefore the
      // gateway's copy of this hold — alive while the pulses stop arriving. A
      // killed socket would have the gateway release the hold itself in
      // teardown, which proves the gateway's property rather than the panel's.
      fixture.proxy.blackhole();

      await until('the controller to notice the link went away',
          () => controller.debugReleaseReason != null,
          budget: _recovery);

      expect(controller.debugReleaseReason, HoldEnded.disconnect,
          reason: 'the hold ended as ${controller.debugReleaseReason}. A link '
              'that has gone is not the operator letting go, and the panel '
              'has to say which one happened — one of them means "press it '
              'again" and the other means "call somebody"');
      expect(controller.debugTimerCount, 0,
          reason: 'the pulse timer survived the link. It would then be firing '
              'into a socket nobody is reading, on a page that believes it '
              'still holds a machine');
      expect(controller.isHeld, isFalse);

      // The release write, whose outcome is informational — the machine
      // stopped when the counter stopped — but which must still be an answer
      // rather than a throw. `release()` on an already-released handle hands
      // back the same future the disconnect path started.
      final outcome = await controller.release().timeout(_recovery);
      expect(outcome, isA<WriteUnknown>(),
          reason: 'the release write came back $outcome over a link that was '
              'not there. Unknown is the honest verdict and it costs nothing; '
              'anything else is this client inventing an answer about a frame '
              'it could not send');
      expect(
          (outcome as WriteUnknown).reason.kind,
          anyOf(FailureKind.linkDown, FailureKind.linkLost,
              FailureKind.deadlineExpired),
          reason: 'the unknown must name something an integrator can act on; '
              'got ${outcome.reason.kind}');

      // And the counter stops for good. Sampled after a settle rather than at
      // the instant of the cut, because a pulse already on the wire when the
      // blackhole came on may still land — what must never happen is another
      // one afterwards.
      //
      // **It settles at 0, not at the last counter value it received, and the
      // difference is measured rather than assumed.** The plan expected a
      // freeze; what the gateway actually does is stop hearing from the
      // session and tear it down, and `ValueHandlers.releaseAllHolds` then
      // releases the hold *it* was holding — which writes the 0 (T-05-20). So
      // two independent mechanisms stop this machine, the panel's and the
      // gateway's, and 0 is the stronger of the two answers. What is asserted
      // is therefore the property both satisfy and neither may break: after
      // the link died the counter never advances again.
      await Future<void>.delayed(_settle);
      final frozen = fixture.served.read(_key)?.asInt;
      expect(frozen, isNotNull,
          reason: 'the tag has no reading at all, so the comparison below is '
              'between two nulls');
      expect(frozen, anyOf(0, greaterThanOrEqualTo(_pulsesBeforeTheCut)),
          reason: 'the tag settled at $frozen, which is neither the released 0 '
              'nor a counter that had got anywhere. Something put an '
              'intermediate value on a deadman tag after the link died');
      expect(fixture.client.debugHoldTicksSent,
          greaterThanOrEqualTo(_pulsesBeforeTheCut),
          reason: 'this client offered fewer than $_pulsesBeforeTheCut pulses '
              'to the link in the whole case, so "and then it stopped" is a '
              'statement about a hold that was barely fed');
      final pulsesAtTheCut = fixture.client.debugHoldTicksSent;

      await Future<void>.delayed(_quiet);

      expect(fixture.served.read(_key)?.asInt, frozen,
          reason: 'the deadman counter at the plant moved after the link '
              'died. That is the failure this entire design exists to make '
              'impossible: the PLC watches the counter, and a counter that '
              'keeps advancing is a machine that keeps moving for a panel '
              'nobody can see and an operator who may have walked away');
      expect(fixture.client.debugHoldTicksSent, pulsesAtTheCut,
          reason: 'the client offered more pulses to a link that is not '
              'ready. The gate exists because `sendNotification` on a closed '
              'peer throws synchronously and because the sink underneath '
              'buffers without bound');
    });

    test('a live hold adds no timer to the client\'s own ceiling', () async {
      final fixture = await faultFixture(
        keys: const {_key},
        withProxy: true,
        seed: (plant) => plant.setValue(_key, 0),
      );
      await until('the link', () => fixture.client.isReady);
      final ceilingBefore = fixture.client.debugTimerCount;

      final controller = HoldToRunController(
        api: fixture.client,
        key: _key,
        pulsePeriod: _pulse,
      );
      addTearDown(controller.dispose);
      await controller.press().timeout(_recovery);
      await until('the deadman counter to advance at the plant',
          () => (fixture.served.read(_key)?.asInt ?? 0) >= _pulsesBeforeTheCut,
          budget: _recovery);

      expect(fixture.client.debugTimerCount, ceilingBefore,
          reason: 'the client\'s own timer count moved from $ceilingBefore to '
              '${fixture.client.debugTimerCount} while a hold was held. The '
              'ceiling of two (`remote_state_man.dart`, '
              '`connection_supervisor.dart`) is what says no timer outlives '
              'the thing that owns it, and a controller counted into it would '
              'make that ceiling drift with the number of buttons on the '
              'screen until it stopped meaning anything');
      expect(fixture.client.debugTimerCount, lessThanOrEqualTo(2),
          reason: 'the client is holding more than the two timers it is '
              'allowed — the watchdog deadline and a pending reconnect');
      expect(controller.debugTimerCount, 1,
          reason: 'the controller owns its own single timer, and it is the '
              'one that must be 1 while a hold is live');

      await controller.release();
      expect(controller.debugTimerCount, 0);
    });
  });
}
