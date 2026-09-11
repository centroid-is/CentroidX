/// F14: two ways for a dial to fail, and one loop they both have to reach.
///
/// **F14 — Connect refused vs connect timeout.** `reject()` vs blackhole
/// pre-connect. The catalogue asks that both paths reach the same backoff loop;
/// Windows-specific: `reject()` keeps ServerSocket open to get fast
/// `ECONNREFUSED`.
///
/// **The row is the comparison, not the two stories.** Both halves already
/// existed in the tree before this file — `reconnect_test.dart:394,488` cycles a
/// dead port, and `faults/reject_test.dart:109,226` proves every attempt reaches
/// a terminal failure inside a budget. What nothing stated is the row's actual
/// claim: that a refusal and a silence are *the same event* as far as the panel
/// is concerned. So the two legs below are observed through **one helper
/// returning one shape**, and the assertions compare those shapes to each other.
/// Two cases telling two separate stories would leave the row unasserted while
/// looking thorough.
///
/// **Which side of the branch this row is on.** `connection_supervisor.dart`
/// has a `_stop` arm that ends the loop for good — a refused protocol version
/// (`:479`) and a refused credential (`:497`). That is F15's side. This row is
/// the opposite side: a refused *connection* and an unanswered one are both
/// conditions of the network rather than verdicts about this panel, so the loop
/// must keep going with backoff. A client that treated `ECONNREFUSED` as
/// terminal would go dark for the shift the moment a gateway restarted a second
/// too slowly.
///
/// **Why the blackhole leg needs a client-side bound, and what happens without
/// one.** A blackholed dial completes the TCP connect and then never answers the
/// WebSocket handshake, so nothing about it fails — it simply hangs until the
/// operating system gives up, which on macOS is **75 seconds** (07-RESEARCH trap
/// 19). A single case of that would consume a sixth of the whole gate lane's
/// budget and would be measuring the OS rather than the panel. The bound comes
/// from `ClientConfig.connectTimeout`, and `FrameSeam` had to learn to apply it
/// before this leg could exist at all: measured before that change, this leg
/// recorded **zero** link-state transitions in three seconds.
///
/// **Windows is cited, not re-proved.** `reject()`'s fast `ECONNREFUSED`
/// depends on the listener staying bound, which `faults/reject_test.dart:226`
/// already pins with the reason. Nothing here re-measures it.

@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_stateman_contract/faults.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

/// The bound on each individual dial, short enough that the blackhole leg is
/// paced by the client rather than by the operating system.
///
/// Deliberately far below the 10 s default: the leg's whole point is that *this*
/// number is what ends an unanswered dial, and at the default the case would
/// take a minute to show a handful of attempts.
const Duration _connectTimeout = Duration(milliseconds: 300);

/// How long each leg is watched cycling.
const Duration _window = Duration(seconds: 2);

/// What one leg looked like from the panel's side.
typedef LegObservation = ({List<LinkState> states, int attempts});

/// The backoff schedule the ceiling below is computed from, **restated rather
/// than read off the config the fixture builds**.
///
/// 07-04's lesson, and it is the whole value of the bound: a ceiling that
/// recomputed itself from whatever the client was actually handed would rise to
/// meet a client that had been made to hammer, which is the one failure it
/// exists to catch. These two must move together with `faultClientConfig`, and
/// a reader who changes one is meant to be stopped by this comment.
const _backoffBase = Duration(milliseconds: 40);
const _backoffCap = Duration(seconds: 2);

/// How many attempts a window of [_window] can hold under full jitter.
///
/// Full jitter draws uniformly from `[0, min(cap, base * 2^n))`, so attempt *n*
/// waits half that window on average, and the schedule only resets on entry to
/// `ready` — which never happens on either leg, so the walk runs to the cap.
/// A blackholed attempt additionally costs its own [_connectTimeout] before the
/// wait even starts, which is why this counts the timeout in.
int _attemptCeiling() {
  var elapsed = 0;
  var attempts = 0;
  var window = _backoffBase.inMilliseconds;
  while (elapsed < _window.inMilliseconds) {
    attempts++;
    elapsed += window ~/ 2;
    final doubled = window * 2;
    window = doubled > _backoffCap.inMilliseconds
        ? _backoffCap.inMilliseconds
        : doubled;
  }
  // Times three, the same safety factor 07-04's storm bound uses: a full-jitter
  // schedule has no hard ceiling — every draw can come back near zero — so the
  // only honest bound is the expectation with a margin. Three is comfortably
  // above the variance of a two-second window and an order of magnitude below a
  // client that spins.
  return attempts * 3;
}

/// Runs one leg and reports what the panel did, for both legs identically.
///
/// One function rather than two case bodies **is** the row: the comparison the
/// catalogue asks for is only meaningful if both sides were observed the same
/// way, and two hand-written observations would differ in some detail that later
/// reads as a difference between the faults.
Future<LegObservation> _observe(
  void Function(FaultProxy proxy) arm,
  void Function(FaultProxy proxy) disarm,
) async {
  final states = <LinkState>[];
  final fixture = await faultFixture(
    keys: const {scenarioKey},
    withProxy: true,
    config: faultClientConfig(connectTimeout: _connectTimeout),
    seed: (plant) => plant.setValue(scenarioKey, 1200),
    // Pulled after the proxy binds and before the client is constructed: the
    // client dials from its own constructor, so a lever pulled on the line
    // after `faultFixture` returns would race the first attempt — and for a
    // row about *pre-connect* faults that race is the whole measurement.
    armBeforeDial: arm,
  );
  final watching = fixture.client.linkStates.listen(states.add);
  addTearDown(watching.cancel);

  await Future<void>.delayed(_window);
  final observed = List<LinkState>.of(states);

  // **Anti-vacuity, and it belongs inside the helper so neither leg can skip
  // it.** Clearing the lever must let the panel through, which proves the
  // fixture could have connected all along — without it, a leg that was
  // pointed at a port nobody was listening on would produce an identical
  // cycling loop and pass every assertion in this file.
  disarm(fixture.proxy);
  await until('the link once the lever was cleared',
      () => fixture.client.isReady,
      budget: const Duration(seconds: 20));

  return (
    states: observed,
    attempts: observed.where((state) => state == LinkState.connecting).length,
  );
}

/// The states each leg visited, in first-occurrence order.
///
/// The comparison the row asks for is between *sequences of distinct
/// transitions*, not between raw lists: the two legs cycle at different rates —
/// a refusal fails instantly and an unanswered dial burns its whole timeout
/// first — so their raw lists differ in length by construction and comparing
/// those would assert that the two faults are equally fast, which is not the
/// claim and is not true.
List<LinkState> _shape(List<LinkState> states) {
  final seen = <LinkState>[];
  for (final state in states) {
    if (!seen.contains(state)) seen.add(state);
  }
  return seen;
}

void main() {
  group('F14 — a refused dial and an unanswered one', () {
    late LegObservation refused;
    late LegObservation unanswered;

    test('F14a: a refused dial cycles the backoff loop', () async {
      refused = await _observe(
        (proxy) => proxy.reject(),
        (proxy) => proxy.reject(enabled: false),
      );
      print('F14a: refused — states ${_shape(refused.states)}, '
          '${refused.attempts} attempts in ${_window.inSeconds}s');

      expect(refused.attempts, greaterThan(1),
          reason: 'the panel attempted ${refused.attempts} dials against a '
              'refusing gateway. A loop that stops on ECONNREFUSED goes dark '
              'for the shift the moment a gateway restarts a second too '
              'slowly — that is the _stop arm, and it is for a refused '
              'credential, not a refused connection');
      expect(refused.attempts, lessThan(_attemptCeiling()),
          reason: 'the panel made ${refused.attempts} attempts against a '
              'ceiling of ${_attemptCeiling()} for a ${_window.inSeconds}s '
              'window. A client hammering a refusing gateway is a self-'
              'inflicted denial of service that keeps the gateway too busy to '
              'come back');
      expect(refused.states, isNot(contains(LinkState.ready)),
          reason: 'the panel reported ready over a link nothing was answering, '
              'which is the one thing an operator must never be shown');
    });

    test('F14b: a dial that is never answered cycles the same loop', () async {
      unanswered = await _observe(
        (proxy) => proxy.blackhole(),
        (proxy) => proxy.blackhole(enabled: false),
      );
      print('F14b: unanswered — states ${_shape(unanswered.states)}, '
          '${unanswered.attempts} attempts in ${_window.inSeconds}s');

      expect(unanswered.attempts, greaterThan(1),
          reason: 'the panel attempted ${unanswered.attempts} dials into a '
              'blackhole. Fewer than two means the dial was not bounded by '
              'connectTimeout and the operating system is what is pacing this '
              'leg — 75 seconds per attempt on macOS');
      expect(unanswered.attempts, lessThan(_attemptCeiling()),
          reason: 'the panel made ${unanswered.attempts} attempts against a '
              'ceiling of ${_attemptCeiling()}');
      expect(unanswered.states, isNot(contains(LinkState.ready)),
          reason: 'the panel reported ready over a handshake that was never '
              'answered');
    });

    test('F14c: both failures reach the same loop, asserted as one observable',
        () async {
      // The row itself. Deliberately a third case reading the two above rather
      // than a clause tacked onto the second: the claim is about the pair, and
      // a failure here names the comparison instead of naming whichever leg
      // happened to run last.
      expect(_shape(unanswered.states), _shape(refused.states),
          reason: 'a refused dial produced ${_shape(refused.states)} and an '
              'unanswered one produced ${_shape(unanswered.states)}. The '
              'catalogue\'s claim is that both reach the *same* backoff loop; '
              'two different shapes here mean the panel distinguishes a '
              'gateway that said no from one that said nothing, and only one '
              'of those two behaviours can be the right one');

      final ceiling = _attemptCeiling();
      expect(refused.attempts, inInclusiveRange(2, ceiling),
          reason: 'the refused leg sits outside the band both legs must share');
      expect(unanswered.attempts, inInclusiveRange(2, ceiling),
          reason: 'the unanswered leg made ${unanswered.attempts} attempts, '
              'outside the [2, $ceiling] band the refused leg '
              '(${refused.attempts}) sits in. The two faults are supposed to '
              'be paced by one schedule');
      print('F14c: both legs shaped ${_shape(refused.states)}; '
          'refused ${refused.attempts} attempts, unanswered '
          '${unanswered.attempts}, band [2, $ceiling]');
    });
  });
}
