/// F2 and F3: the link that will not stay up.
///
/// **F2 — Dropout every other second.** `flap(1s, 1s)` for 60 s. The catalogue
/// asks for no crash, no unbounded memory/log growth,
/// no reconnect storm (backoff caps attempt rate); UI shows disconnected —
/// never flickers stale values as fresh during the 1 s up-windows unless
/// resync completed.
///
/// **F3 — Fast flap, shorter than handshake.** `flap(200ms, 200ms)`. The
/// catalogue asks that
/// reconnect attempts that never complete subscribe are discarded cleanly;
/// generation counter (§7.2) prevents a half-finished session's callbacks
/// touching state.
///
/// **F3 covers the first of those clauses and measurably cannot reach the
/// second, which is a finding rather than a shortfall.** The plan this case was
/// written from expected the generation counter — proven in memory at
/// `resync_test.dart:255` against a scripted peer — to be driven here over a
/// real socket. It is not, and the measurement is unambiguous: temporary probes
/// inside both guards in `resync_engine.onUpdate` fired **0** times across a
/// ten-second `flap(200ms, 200ms)` and **2** times in `resync_test.dart`, and
/// this case stayed green with *both* the epoch guard and the generation guard
/// deleted. The reason is structural. A flap kills the socket, so the
/// supervisor retires the peer (`connection_supervisor.dart:_retirePeer`) and
/// there is no handler left for an in-flight frame to arrive at — nothing needs
/// discarding because nothing is delivered. The generation counter's hazard is
/// a **same-socket** re-establish, where a server-announced resync or a
/// gap-triggered resubscribe rebuilds one page while the session stays put
/// (04-REVIEW CR-04, and the reason the epoch cannot do the job). That is row
/// G4, and F3 carried a **partial** entry owned by 07-06 with this measurement
/// in it until that row landed.
///
/// **It has landed** (07-06). `G4` in `stale_frame_gate_test.dart` drives a
/// same-socket re-establish over a real socket and re-injects a frame from the
/// previous generation whose *sequence the sequence check would have accepted*,
/// so the generation guard is the only thing that can reject it. Deleting the
/// guard reddens G4 — the page publishes the old value, then blanks, then comes
/// back — while F18a and F18b both stay green, which is the comparison that
/// says the guard is uniquely G4's. So the row's second clause is asserted over
/// a real socket by the pair: F3 for the establishments that never complete,
/// G4 for the one shape in which a frame from a retired establishment can
/// actually be delivered. F3's partial entry was deleted in that commit.
///
/// What F3 does prove over a real socket, and what nothing else in the tree
/// does: an establishment that is genuinely cut between its socket and its
/// snapshot leaves no value in the cache, no subscription half-registered on
/// the gateway, and no complaint about a page the client believes is live.
///
/// **Three F2 arms, and each of them exists because the other two cannot say
/// what it says.**
///
/// `F2a` is the operator's scenario at the phase's declared duration: twenty
/// seconds of dropping every other second, with the storm bound, the log-flood
/// ceiling, the structural counts and the honesty arm. It runs on every
/// platform, which is why the descriptor clause is **not** in it: the only
/// spelling of "this platform cannot count descriptors" that package:test
/// offers is a skip on the whole case, and a whole-case Windows skip would take
/// the storm bound, the log ceiling and the honesty arm off the Windows column
/// behind a reason that mentions only file descriptors. That is precisely the
/// failure `gate_manifest_test.dart`'s skip audit exists to catch — a green
/// tick and a skipped tick look the same, and the reason is the only thing that
/// tells them apart.
///
/// `F2b` is therefore the descriptor clause on its own, Windows-skipped by name
/// with `openSocketCountSkipReason`, which then says exactly what stopped being
/// judged there because it is *all* that arm judges. It runs a shorter window
/// on purpose: the leak criterion is a **rate per establish/teardown cycle**
/// (`teardown_test.dart:330-375`), so cycles are its unit and seconds are not,
/// and five cycles show a per-cycle leak as clearly as ten at half the cost.
///
/// `F2c` is the catalogue's own sixty seconds, behind `RELAY_SOAK`. It is the
/// same function as `F2a` with a longer window — literally the same, so "same
/// assertions" is a fact about the code rather than a claim in a comment. The
/// shortened default is declared in `gateDeviations` (07-CONTEXT user ruling 2)
/// rather than quietly applied.
///
/// **What is asserted about the flap is asserted over a window, never at an
/// instant.** `fault_proxy.dart:359-363` measured a connect attempt completing
/// on the far side of a transition, so a flag read at assertion time does not
/// describe what the connection experienced. Every number below is a count, a
/// delta between checkpoints, or a bound.
///
/// **`seam.inbound` is cleared at every checkpoint, and its length is carried
/// forward as a running total** (07-RESEARCH trap 15). `FrameSeam` retains
/// every inbound frame as a `String`; twenty seconds of ticks left accumulating
/// would make this case the unbounded memory growth it is asserting against.
/// The count is what the case wants; the strings are not.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart' show LinkState;
import 'package:tfc_relay_server/src/subscription_registry.dart'
    show SessionSubscriptionCounts;
import 'package:tfc_stateman_contract/faults.dart';

import '../support/fault_fixture.dart';
import '../support/gate_bands.dart';

// ---------------------------------------------------------------------------
// F2's cycle and its windows.
// ---------------------------------------------------------------------------

/// The operator's scenario, in the operator's words: down every other second.
const _flapUp = Duration(seconds: 1);
const _flapDown = Duration(seconds: 1);

/// How long `F2a` holds the lever.
///
/// Twenty seconds, not the catalogue's sixty. Ten cycles is enough for a
/// backoff storm or a per-cycle leak to show as a **rate** across four
/// checkpoints rather than as one end-state sample, which is
/// `teardown_test.dart`'s checkpoint doctrine applied to time. Declared in
/// `gateDeviations` under F2, per 07-CONTEXT user ruling 2 — a gate that
/// silently shortens its own scenarios is the "capability switched off"
/// failure in another register.
const _flapWindow = Duration(seconds: 20);

/// The catalogue's own duration, which `F2c` runs on demand.
const _soakWindow = Duration(seconds: 60);

/// How long `F2b` flaps.
///
/// Five cycles. The descriptor criterion is a per-cycle rate, so the unit is
/// establish/teardown cycles and not wall clock; ten seconds buys the same
/// number of cycles this arm needs at half `F2a`'s cost, and this arm is the
/// one that is skipped on a platform and therefore worth keeping cheap.
const _fdWindow = Duration(seconds: 10);

/// How many checkpoints each window is divided into.
///
/// Four, because a leak that only shows as a slope is invisible in an end
/// state and three points is the fewest that can show one.
const _checkpoints = 4;

/// How often the honesty arm samples the client.
///
/// Fast enough that a 1 s up-window holds tens of samples — a sampler that
/// took one reading per up-window could miss the flicker the row is named for.
const _sampleInterval = Duration(milliseconds: 25);

/// The environment variable that raises `F2c` to the catalogue's full minute.
const _soakEnvVar = 'RELAY_SOAK';

// ---------------------------------------------------------------------------
// The backoff schedule the dial bound is computed from.
// ---------------------------------------------------------------------------

/// The schedule `faultClientConfig` hands the client, restated here.
///
/// **Restated rather than read off the config on purpose, and the two must
/// move together.** The bound below is the *claim* — "this schedule permits at
/// most this many attempts over this window" — and a bound that recomputed
/// itself from whatever the client was actually given would rise to meet a
/// client that had been made to hammer, which is the one failure the bound
/// exists to catch. Sabotage arm 1 of this plan raises `faultClientConfig`'s
/// cap to 40 ms and expects the assertion to fail; it can only do that if these
/// numbers stay put. Same argument, same shape, as `gate_bands.dart`'s slack
/// pair mirroring the server package's.
const _backoffBase = Duration(milliseconds: 40);
const _backoffCap = Duration(seconds: 2);

/// How much slack the computed ceiling carries over the schedule's expectation.
///
/// Three. Full jitter draws uniformly from `[0, window)`, so a single run has
/// **no hard ceiling** — every draw can come back near zero — and the only
/// honest bound is the expectation with a margin. The number this is watching
/// for is not "a few more attempts than average"; it is a reconnect loop that
/// stopped backing off, which against ten down-windows produces attempts in the
/// hundreds. Three is comfortably above the variance of ten cycles and an order
/// of magnitude below a client that spins.
const _attemptSafetyFactor = 3;

/// Attempts allowed for the first connect and for the partial cycle at each
/// end of the window, which belong to no down-window.
const _edgeAttemptSlack = 6;

/// The most complaints the gateway may report per flap cycle.
///
/// One cycle kills one session, and one dead session is a bounded number of
/// events on the gateway's side: the socket's error, the transport ending, and
/// the session wiring noticing. Four is that with room; the observed number is
/// printed beside it on every run, because the assertion can tell "bounded"
/// from "flood" and only the number says which end of bounded it was.
const _errorsPerCycle = 4;

/// Complaints allowed outside the cycles — the first connect, the recovery.
const _edgeErrorSlack = 10;

/// The most sessions the gateway may hold at a checkpoint.
///
/// Two: the live one, plus one the flap has just killed that the gateway has
/// not finished retiring. Three would be a session per cycle accumulating,
/// which is the leak `teardown_test.dart:340-352` describes — a gateway that
/// keeps a session per reconnect dies of memory after a shift of flapping
/// plant network, and stops serving every operator at once.
const _sessionCeiling = 2;

/// How many descriptors above the baseline the process may hold *while* the
/// link is cycling.
///
/// Not zero, and deliberately: a checkpoint can land in the moment between a
/// socket being replaced and the old one's descriptor being released. Eight is
/// wide enough for that and far too narrow for a leak of one per cycle to hide
/// in over five cycles.
const _fdCeilingDuringFlap = 8;

void main() {
  group('F2 — a dropout every other second', () {
    test(
        'F2a: dropping every other second for twenty seconds is weathered, '
        'not survived', () => _storm(_flapWindow),
        timeout: const Timeout(Duration(minutes: 3)));

    test('F2b: twenty flap transitions leave no socket descriptor behind',
        () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1),
      );
      await until('the link', () => fixture.client.isReady);

      // The baseline is taken with the link **up**, so it already includes the
      // client socket, both ends of the proxy pair and the gateway's, and the
      // recovered state at the end is the same shape. A baseline taken before
      // the client connected would make "back to baseline" a demand that the
      // client be gone.
      final baseline = openSocketCount();

      // The control arm. `openSocketCount` answers 0 rather than throwing when
      // it cannot see anything — `lsof` exits 1 on no matching rows and that
      // is a legitimate zero — so a counter that had quietly stopped working
      // would report 0 here, 0 at every checkpoint, and satisfy every delta
      // below without ever having counted a socket.
      expect(baseline, greaterThan(0),
          reason: 'the process reports $baseline open socket descriptors while '
              'a client, a proxy pair and a gateway are all connected. That is '
              'a counter that is not counting, and every delta in this arm '
              'passes trivially against it');

      final counts = <int>[];
      fixture.proxy.flap(_flapUp, _flapDown);
      for (var i = 0; i < _checkpoints; i++) {
        await Future<void>.delayed(_fdWindow ~/ _checkpoints);
        counts.add(openSocketCount());
      }
      fixture.proxy.flap(_flapUp, _flapDown, enabled: false);

      final cycles = _fdWindow.inMilliseconds ~/
          (_flapUp + _flapDown).inMilliseconds;
      print('F2b: baseline $baseline fds; during flap(1s, 1s) for '
          '${_fdWindow.inSeconds}s: $counts; ${fixture.proxy.flapTransitions} '
          'transitions over $cycles cycles');

      // Read as a rate, not as an end state: one descriptor per cycle is a
      // teardown path a reset never reaches, and a client that leaks one per
      // reconnect dies of EMFILE on a plant network that flaps all shift.
      for (var i = 0; i < counts.length; i++) {
        expect(counts[i] - baseline, lessThanOrEqualTo(_fdCeilingDuringFlap),
            reason: 'at checkpoint ${i + 1} of ${counts.length} the process '
                'held ${counts[i] - baseline} descriptors above the baseline '
                'of $baseline, against a ceiling of $_fdCeilingDuringFlap. The '
                'whole series is $counts — read it as a slope: a flat series '
                'near the baseline is sockets being replaced, a rising one is '
                'a descriptor kept per cycle');
      }

      await until('the link to come back after the flap was disarmed',
          () => fixture.client.isReady, budget: recovery);
      await until(
          'the descriptor count to return to its pre-flap baseline',
          () => openSocketCount() <= baseline,
          budget: recovery);

      final settled = openSocketCount();
      print('F2b: settled at $settled fds against a baseline of $baseline');
      expect(settled, lessThanOrEqualTo(baseline),
          reason: 'after the flap was disarmed and the link came back, the '
              'process holds $settled socket descriptors against a pre-flap '
              'baseline of $baseline. The link is in the same state it was in '
              'when the baseline was taken, so the difference is what '
              '$cycles establish/teardown cycles left behind');
    },
        timeout: const Timeout(Duration(minutes: 2)),
        onPlatform: const {'windows': Skip(openSocketCountSkipReason)});

    test('F2c: the catalogue\'s own sixty seconds of dropping every other '
        'second', () => _storm(_soakWindow),
        timeout: const Timeout(Duration(minutes: 5)),
        skip: (Platform.environment[_soakEnvVar] ?? '').isNotEmpty
            ? null
            : 'the catalogue names sixty seconds of flap(1s, 1s) and the '
                'default lane runs twenty, so this arm is the declared '
                'deviation being made good on demand. What stops being judged '
                'while $_soakEnvVar is unset: whether the dial bound, the '
                'complaint ceiling and the flat handle count still hold over '
                'thirty cycles rather than ten — a leak of a third of a '
                'descriptor per cycle, or a backoff that only degrades after '
                'the twentieth reconnect, is visible at sixty seconds and not '
                'at twenty. Set $_soakEnvVar=1 to run it');
  });

  group('F3 — a flap shorter than the handshake', () {
    test(
        'F3: a flap shorter than the handshake leaves no half-finished session '
        'touching state', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        withProxy: true,
        seed: (plant) => plant.setValue(scenarioKey, 1),
      );
      await until('the link', () => fixture.client.isReady);
      expect(fixture.client.read(scenarioKey)?.value, 1,
          reason: 'the page was not carrying the seeded value before the flap '
              'started, so nothing below is about a subscription that worked');

      // **The anti-vacuity observable, counted directly rather than inferred
      // from a difference.** `LinkState.resyncing` is entered once the peer is
      // wired over a live socket and before the hello goes out
      // (`connection_supervisor.dart:437`); `LinkState.ready` is entered only
      // after `_resync.onHello` returns, which it does only when every page is
      // holding a snapshot (`:470,508`). So a `resyncing` that reaches `down`
      // without passing through `ready` **is** an establishment that opened a
      // socket and was cut before its subscribe completed — the row's whole
      // precondition, as one number.
      //
      // The first draft asserted `seam.dials > readyTransitions` instead. Ten
      // runs put that difference between 1 and 6: it holds, but a difference
      // of two noisy aggregates comes down to one establishment often enough
      // that the arm would eventually pass on a run that measured nothing.
      // Both numbers are still printed; the assertion is on this one.
      var completed = 0;
      var interrupted = 0;
      var previousState = LinkState.ready;

      // **And one of them is armed off the observation rather than raced
      // against the clock** (07-REVIEW WR-06). The flap alone leaves the
      // precondition to a race between a fixed 200 ms up-window and a hello
      // plus subscribe measured at 50-100 ms, and on a fast quiet machine the
      // round trip sometimes wins every cycle: `deferred-items.md` recorded
      // **2 failures in 20 standalone runs** reading `N sockets opened, N
      // subscribes completed, 0 cut`. The arm was right and the lever was
      // unreliable, which is not a reason to relax the arm.
      //
      // So the first `resyncing` inside the flap window is cut on sight, the
      // way 07-06's F9 arms its second kill. `resyncing` is entered once the
      // peer is wired and before the hello goes out, so a reset delivered
      // there lands strictly inside the window this row is about — and if the
      // flap's own drop gets there first, that is the same event and the same
      // transition. The flap still supplies the other tens of them; what this
      // removes is the possibility of zero.
      var cutTheNextEstablishment = false;
      var cutOnSight = 0;
      final watching = fixture.client.linkStates.listen((state) {
        if (state == LinkState.ready) completed++;
        if (state == LinkState.down && previousState == LinkState.resyncing) {
          interrupted++;
        }
        if (cutTheNextEstablishment && state == LinkState.resyncing) {
          cutTheNextEstablishment = false;
          cutOnSight++;
          // Composes with the flap: `exclusiveModePairs` excludes `killOnce`
          // from `cutMidFrame` and `reject`, neither of which this row pulls.
          fixture.proxy.killOnce();
        }
        previousState = state;
      });
      addTearDown(watching.cancel);
      final dialsBefore = fixture.seam.dials;
      final completedBefore = completed;

      // Monotonic, so a frame from an establishment that was cut before its
      // subscribe finished is *distinguishable*: it carries a number the plant
      // has already moved past, and applying it moves the client's value
      // backwards. A page whose value never moved could not tell a stale frame
      // from a fresh one at all.
      var plantValue = 1;
      final samples = <int?>[];
      final escaped = <String>[];

      await _guarded(escaped, () async {
        final bumping = Timer.periodic(_plantTick, (_) {
          fixture.served.setValue(scenarioKey, ++plantValue);
        });
        final sampling = Timer.periodic(_sampleInterval, (_) {
          samples.add(fixture.client.read(scenarioKey)?.value as int?);
        });
        cutTheNextEstablishment = true;
        fixture.proxy.flap(_fastUp, _fastDown);
        // The window *is* the experiment: there is no event that means "forty
        // establishments were interrupted", so the time has to pass.
        await Future<void>.delayed(_fastWindow);
        fixture.proxy.flap(_fastUp, _fastDown, enabled: false);
        bumping.cancel();
        sampling.cancel();
      });

      await until('the link to come back after the flap was disarmed',
          () => fixture.client.isReady, budget: recovery);
      await until('the recovered page to converge on the plant\'s last value',
          () => fixture.client.read(scenarioKey)?.value == plantValue,
          budget: recovery);

      final attempted = fixture.seam.dials - dialsBefore;
      final finished = completed - completedBefore;
      print('F3: flap(${_fastUp.inMilliseconds}ms, '
          '${_fastDown.inMilliseconds}ms) for ${_fastWindow.inSeconds}s: '
          '$attempted sockets opened, $finished subscribes completed, '
          '$interrupted cut between the socket and the snapshot '
          '($cutOnSight of them armed off an observed resyncing rather than '
          'the clock), ${fixture.proxy.flapTransitions} transitions, '
          '${samples.length} samples, plant reached $plantValue');


      // Anti-vacuity, and the whole reason 200 ms is the number. 04-RESEARCH
      // Finding 8 measured a 50-100 ms transport round trip, and a completed
      // establishment costs a hello *and* a subscribe on top of the WebSocket
      // handshake — so a 200 ms up-window straddles it and some sockets open
      // and are cut before their subscribe returns. On a fast quiet machine
      // the round trip sometimes won every cycle, which is the flake
      // `deferred-items.md` recorded at 2 of 20; the cut armed off the first
      // observed `resyncing` is what removed it. Do not relax this arm — it is
      // the only thing standing between this case and a vacuous pass, and the
      // fix for a red one is a more reliable lever, not a weaker assertion.
      expect(interrupted, greaterThan(0),
          reason: 'not one of the $attempted sockets that opened during the '
              'flap was cut between the socket and the snapshot — all '
              '$finished of them finished their subscribe — so no '
              'establishment was actually interrupted and the generation '
              'property below was never put under any load. $cutOnSight cut(s) '
              'were armed off an observed resyncing transition, so if that '
              'number is 1 the arm fired and the client still reached ready '
              'before the reset landed; if it is 0 the arm never ran at all');
      expect(cutOnSight, 1,
          reason: 'the interruption armed off an observed `resyncing` did not '
              'run, so the arm above is back to racing a 200 ms window against '
              'a 50-100 ms handshake — which is exactly the 2-in-20 flake this '
              'lever replaced');
      expect(samples.length, greaterThan(_fastWindow.inMilliseconds ~/
          _sampleInterval.inMilliseconds ~/ 2),
          reason: 'the sampler took ${samples.length} readings over '
              '${_fastWindow.inSeconds} s at one per '
              '${_sampleInterval.inMilliseconds} ms, which is less than half '
              'what it should have; the isolate was stalled for most of the '
              'window and the sequence below is not a picture of it');

      // The catalogue's clause, made observable: every reading is the last
      // good value, a newer one, or **absent** — never a value from a
      // subscribe that did not complete, which against a monotonic plant is a
      // value the client has already moved past. The library doc records what
      // this does *not* reach: measured, no frame from an abandoned
      // establishment arrives at all under this lever, so the guard that would
      // have discarded it is never asked to. What is asserted here is the
      // observable the catalogue names — the cache never carries a reading the
      // plant has moved past — which holds whether the frame was discarded or
      // never delivered, and would fail if either stopped being true.
      //
      // **Absent is not a violation, and it is not a shrug either.** Measured
      // here: a page reads null for most of an outage, because
      // `resync_engine.dart:262` (`_unestablish`) clears the store when a
      // subscription stops being live, so "a key the new session no longer
      // sends cannot survive as a stale number". The catalogue wrote the
      // clause as "the last good value or absent" for that reason. What the
      // absence must **not** do is launder a regression: `previous` is
      // therefore carried across the gaps, so a value that vanishes at 101 and
      // comes back at 44 is still caught.
      final regressions = <String>[];
      var absences = 0;
      int? previous;
      for (var i = 0; i < samples.length; i++) {
        final value = samples[i];
        if (value == null) {
          absences++;
          continue;
        }
        if (previous != null && value < previous) {
          regressions.add('sample $i: $previous -> $value');
        }
        previous = value;
      }
      print('F3: $absences of ${samples.length} readings were absent, '
          '${samples.length - absences} carried a value, $regressions '
          'went backwards');

      // The other half of the anti-vacuity pair: a page that never went away
      // was never re-established, and a re-establish is the boundary the
      // generation counter guards. `attempted > finished` above proves an
      // establishment was interrupted; this proves the page felt it.
      expect(absences, greaterThan(0),
          reason: 'not one reading was absent across '
              '${_fastWindow.inSeconds} s of flap(200ms, 200ms), so the '
              'subscription was never torn down and nothing ever crossed a '
              're-establish boundary');
      expect(regressions, isEmpty,
          reason: 'the value the client was holding went backwards: '
              '$regressions. The plant only ever counts up, so a reading below '
              'the one before it is a frame from an establishment that was cut '
              'before its subscribe completed, applied to the cache anyway — a '
              'number on the mimic under good quality that the plant stopped '
              'holding, which is exactly what the generation counter in '
              'resync_engine.dart:131 is there to discard');

      expect(escaped, isEmpty,
          reason: 'an async error escaped the zone during the flap: $escaped. '
              'This is the failure that does not stay in its own case — an '
              'error with no handler is reported against whichever test is '
              'running when it lands, so the case it fails is never this one');

      await until('the gateway to be holding one session again',
          () => fixture.server.sessions.sessionCount <= 1, budget: recovery);
      expect(fixture.server.sessions.sessionCount, lessThanOrEqualTo(1),
          reason: 'the gateway is holding '
              '${fixture.server.sessions.sessionCount} sessions after one '
              'client finished flapping. A session per interrupted '
              'establishment is the half-registered subscription this row '
              'forbids, seen from the gateway\'s side');
      expect(fixture.server.sessions.subscriptionCount, lessThanOrEqualTo(1),
          reason: 'the gateway is holding '
              '${fixture.server.sessions.subscriptionCount} subscriptions for '
              'one page. A session can leave the registry with its '
              'subscriptions still attached, which the session count alone '
              'cannot see');
      expect(fixture.client.keys, contains(scenarioKey),
          reason: 'the client is no longer carrying a value for the one key it '
              'asked for, so the page it re-established is not the page it '
              'subscribed to');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the resync engine collected ${fixture.client.complaints} '
              'while re-establishing a page it believes is live. A complaint '
              'about a live page is a subscription the client thinks it has '
              'and the gateway does not');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

// ---------------------------------------------------------------------------
// F3's cycle.
// ---------------------------------------------------------------------------

/// Below the handshake on purpose: 04-RESEARCH Finding 8 measured the transport
/// round trip at 50-100 ms, and a completed establishment costs a hello and a
/// subscribe on top of the WebSocket handshake. 200 ms therefore **straddles**
/// it — some establishments finish and some are cut part-way, which is the only
/// condition under which the row's property can be observed at all. A number
/// comfortably below would leave nothing ever established; one comfortably
/// above would leave nothing ever interrupted.
const _fastUp = Duration(milliseconds: 200);
const _fastDown = Duration(milliseconds: 200);

/// Long enough for tens of interrupted establishments.
///
/// Ten seconds — the top of the 8-10 s range this row was planned at, and the
/// number is a measurement rather than a preference. At eight seconds, ten runs
/// on this machine opened 6-12 sockets and completed 4-9 subscribes: the
/// anti-vacuity gap held every time but twice came down to **one**
/// establishment, which is one scheduling accident away from a case that
/// measures nothing on a quiet runner. Twenty-five cycles instead of twenty
/// widens that margin by a quarter, and it does it by lengthening the window
/// rather than by narrowing the flap — `flap(200ms, 200ms)` is the catalogue's
/// own lever and shortening it would be a deviation to declare, where the
/// window is this case's to choose.
const _fastWindow = Duration(seconds: 10);

/// How often the plant's value moves during F3.
///
/// Four bumps per up-window: enough that a frame from an interrupted
/// establishment is measurably behind the plant by the time the next one
/// completes, and slow enough that the sampler is not reading a value that
/// changed between two of its own readings.
const _plantTick = Duration(milliseconds: 50);

// ---------------------------------------------------------------------------
// F2's storm, shared by the twenty-second arm and the sixty-second one.
// ---------------------------------------------------------------------------

/// One reading of the structural counters, taken at a checkpoint.
typedef _Checkpoint = ({
  Duration at,
  int attempts,
  int dials,
  int sessions,
  int handles,
  int frames,
  int errors,
});

/// One reading of what the panel was showing, taken by the honesty sampler.
///
/// **The field order is the read order, and the read order is load-bearing.**
/// [floor] is captured first, the client's own verdict second, the value last.
/// Taken the other way round a sample could pair a verdict from the
/// establishment *before* an outage with a floor raised during it, and report
/// a healthy client as dishonest. Captured this way the ordering can only ever
/// make the assertion weaker by one sample, never wrongly stronger.
typedef _Sample = ({int floor, bool trusted, bool viewStale, int? value});

/// F2's whole scenario over [window], asserted.
///
/// Shared by `F2a` and `F2c` so that "the soak arm runs the same assertions" is
/// a property of the code rather than a claim in a comment.
Future<void> _storm(Duration window) async {
  final cycles = window.inMilliseconds ~/ (_flapUp + _flapDown).inMilliseconds;
  final perCheckpoint = window ~/ _checkpoints;

  // Counted rather than discarded, which is the whole reason the fixture grew
  // an `onError` parameter: a storm that is also a log flood is the second
  // half of "no unbounded memory/log growth", and a discarded complaint cannot
  // be counted. Nothing is printed per error — the count is what is wanted.
  var complaints = 0;

  final fixture = await faultFixture(
    keys: const {scenarioKey},
    withProxy: true,
    seed: (plant) => plant.setValue(scenarioKey, 1),
    onError: (_, __, ___) => complaints++,
  );
  await until('the link', () => fixture.client.isReady);
  expect(fixture.client.read(scenarioKey)?.value, 1,
      reason: 'the page was not carrying the seeded value before the flap '
          'started, so nothing below is about a subscription that worked');

  // Every establishment the supervisor *begins*, which is the storm
  // observable. `seam.dials` counts sockets that opened, and during a down
  // window the proxy resets the connection before the WebSocket handshake
  // finishes — so a client hammering through the down windows is invisible to
  // `seam.dials` and perfectly visible here. Both are recorded; the bound is
  // on this one.
  var attempts = 0;
  var floor = 0;
  var floorRaises = 0;
  final watching = fixture.client.linkStates.listen((state) {
    if (state == LinkState.connecting) attempts++;
    if (state != LinkState.down) return;
    // Changed *during* the down window, so an honest resync has something to
    // get wrong: a client that re-presented its pre-outage value would be
    // showing a number the plant no longer holds, under a fresh verdict. The
    // proxy stays down for a whole second after the drop, so this listener has
    // run long before any reconnect can take a snapshot.
    floor++;
    floorRaises++;
    fixture.served.setValue(scenarioKey, floor);
  });
  addTearDown(watching.cancel);

  final attemptsBefore = attempts;
  final dialsBefore = fixture.seam.dials;
  final complaintsBefore = complaints;
  final handlesBefore = fixture.server.handles.size;

  final samples = <_Sample>[];
  final marks = <_Checkpoint>[];
  final escaped = <String>[];
  var frames = 0;

  await _guarded(escaped, () async {
    final sampling = Timer.periodic(_sampleInterval, (_) {
      // Read floor, then verdict, then value. See [_Sample].
      final floorNow = floor;
      final trusted = fixture.client.isReady;
      final viewStale = fixture.client.viewIsStale;
      samples.add((
        floor: floorNow,
        trusted: trusted,
        viewStale: viewStale,
        value: fixture.client.read(scenarioKey)?.value as int?,
      ));
    });

    fixture.proxy.flap(_flapUp, _flapDown);
    final elapsed = Stopwatch()..start();
    for (var i = 0; i < _checkpoints; i++) {
      // The window is the experiment: there is no event that means "ten
      // cycles of dropping every other second happened".
      await Future<void>.delayed(perCheckpoint);
      // Counted, then dropped. Retaining twenty seconds of frames as Strings
      // would make this case the memory growth it is asserting against
      // (07-RESEARCH trap 15).
      frames += fixture.seam.inbound.length;
      fixture.seam.inbound.clear();
      marks.add((
        at: elapsed.elapsed,
        attempts: attempts - attemptsBefore,
        dials: fixture.seam.dials - dialsBefore,
        sessions: fixture.server.sessions.sessionCount,
        handles: fixture.server.handles.size,
        frames: frames,
        errors: complaints - complaintsBefore,
      ));
    }
    elapsed.stop();
    fixture.proxy.flap(_flapUp, _flapDown, enabled: false);
    sampling.cancel();
  });

  await until('the link to come back after the flap was disarmed',
      () => fixture.client.isReady, budget: recovery);
  await until('the recovered page to carry the value the plant last set',
      () => fixture.client.read(scenarioKey)?.value == floor,
      budget: recovery);

  // The ceiling, computed from the schedule rather than chosen. See
  // [_attemptsPerDownWindow] for the walk and [_attemptSafetyFactor] for why a
  // full-jitter schedule can only be bounded in expectation.
  final perDown = _attemptsPerDownWindow(_flapDown, _backoffBase, _backoffCap);
  final cyclesPerCheckpoint = perCheckpoint.inMilliseconds /
      (_flapUp + _flapDown).inMilliseconds;
  final attemptCeilingPerCheckpoint =
      (_attemptSafetyFactor * perDown * cyclesPerCheckpoint).ceil();
  final attemptCeiling =
      attemptCeilingPerCheckpoint * _checkpoints + _edgeAttemptSlack;
  final errorCeiling = _errorsPerCycle * cycles + _edgeErrorSlack;

  final trusted = samples.where((s) => s.trusted).toList();
  final trustedAfterARaise =
      trusted.where((s) => s.floor > 0).toList(growable: false);
  final dishonest = [
    for (final sample in trustedAfterARaise)
      if (sample.value == null || sample.value! < sample.floor)
        'floor ${sample.floor}, showing ${sample.value}, '
        'stale=${sample.viewStale}',
  ];

  print('F2 over ${window.inSeconds}s of flap(${_flapUp.inSeconds}s, '
      '${_flapDown.inSeconds}s), $cycles cycles, '
      '${fixture.proxy.flapTransitions} transitions:');
  for (final mark in marks) {
    print('  +${mark.at.inSeconds}s: ${mark.attempts} attempts, '
        '${mark.dials} sockets opened, ${mark.sessions} sessions, '
        '${mark.handles} handles, ${mark.frames} frames seen, '
        '${mark.errors} gateway complaints');
  }
  print('  bounds: attempts <= $attemptCeiling '
      '($_attemptSafetyFactor x $perDown per down-window x '
      '${cyclesPerCheckpoint.toStringAsFixed(1)} cycles per checkpoint x '
      '$_checkpoints + $_edgeAttemptSlack), complaints <= $errorCeiling '
      '($_errorsPerCycle per cycle x $cycles + $_edgeErrorSlack)');
  print('  honesty: ${samples.length} samples, ${trusted.length} while the '
      'panel was showing the page as live, ${trustedAfterARaise.length} of '
      'those after the plant had moved during an outage, $floorRaises outages '
      'the plant moved during');

  // ---- no reconnect storm -------------------------------------------------

  for (var i = 0; i < marks.length; i++) {
    final delta = marks[i].attempts - (i == 0 ? 0 : marks[i - 1].attempts);
    expect(delta, lessThan(attemptCeilingPerCheckpoint + _edgeAttemptSlack),
        reason: 'between checkpoint $i and ${i + 1} the client began $delta '
            'establishments, against a per-checkpoint ceiling of '
            '$attemptCeilingPerCheckpoint computed from the backoff schedule '
            '(${_backoffBase.inMilliseconds} ms base, '
            '${_backoffCap.inSeconds} s cap, full jitter). Read the series '
            'above as a rate: a flat one is the schedule working, a rising one '
            'is a client whose backoff stopped growing');
  }
  expect(attempts - attemptsBefore, lessThan(attemptCeiling),
      reason: 'the client began ${attempts - attemptsBefore} establishments '
          'over $cycles down-windows, against a ceiling of $attemptCeiling. '
          'That ceiling is the schedule\'s own expectation times '
          '$_attemptSafetyFactor, and a client that exceeds it is not backing '
          'off — which against a single gateway serving every panel in the '
          'factory is a denial of service the panels inflict on themselves');

  // ---- no log flood -------------------------------------------------------

  expect(complaints - complaintsBefore, lessThan(errorCeiling),
      reason: 'the gateway\'s error handler was called '
          '${complaints - complaintsBefore} times across $cycles flap cycles, '
          'against a ceiling of $errorCeiling ($_errorsPerCycle per cycle plus '
          '$_edgeErrorSlack for the edges). A storm that is also a log flood '
          'is the second half of the catalogue\'s "no unbounded memory/log '
          'growth", and it is the half nobody notices until the disk fills');

  // ---- no structural growth ----------------------------------------------

  for (final mark in marks) {
    expect(mark.handles, handlesBefore,
        reason: 'the gateway held ${mark.handles} handles at '
            '+${mark.at.inSeconds}s against $handlesBefore before the flap. '
            'Handles are permanent by the 03-CONTEXT ruling, so this number '
            'does not move for a page that was already subscribed — one more '
            'per reconnect is a table that grows for the lifetime of the '
            'process');
    expect(mark.sessions, lessThanOrEqualTo(_sessionCeiling),
        reason: 'the gateway held ${mark.sessions} sessions at '
            '+${mark.at.inSeconds}s, against a ceiling of $_sessionCeiling — '
            'the live one plus one being retired. Read the series above as a '
            'rate: a session per cycle is a gateway that dies of memory after '
            'a shift of flapping plant network');
  }
  await until('the gateway to be holding one session again',
      () => fixture.server.sessions.sessionCount <= 1, budget: recovery);
  expect(fixture.server.sessions.sessionCount, lessThanOrEqualTo(1),
      reason: 'after the flap was disarmed and the link came back the gateway '
          'is holding ${fixture.server.sessions.sessionCount} sessions for one '
          'client');

  // ---- the honesty arm ----------------------------------------------------

  expect(samples, isNotEmpty,
      reason: 'the sampler recorded nothing at all, so the arm below is a '
          'statement about an empty list — which is the shape every honesty '
          'assertion passes trivially in');
  expect(floorRaises, greaterThanOrEqualTo(cycles ~/ 2),
      reason: 'the plant moved during only $floorRaises outages over $cycles '
          'cycles, so most up-windows had nothing for the client to get wrong '
          'and the arm below judged almost nothing');
  expect(trustedAfterARaise, isNotEmpty,
      reason: 'not one sample caught the panel showing the page as live after '
          'the plant had moved during an outage. Either the client never came '
          'back inside the window, or the sampler is not reading the verdict — '
          'and in both cases the assertion below is about nothing. This is the '
          'arm that has teeth: the violation list is empty for a client that '
          'never reconnected exactly as it is for one that never lied');
  expect(samples.where((s) => !s.trusted), isNotEmpty,
      reason: 'every sample caught the panel showing the page as live, so the '
          'link never actually went away and this whole case was run against a '
          'healthy connection');
  expect(dishonest, isEmpty,
      reason: 'the panel showed the page as live while holding a value the '
          'plant had already moved past: $dishonest. Each entry pairs the '
          'value the plant was last given during an outage with what the '
          'client was showing at a moment it reported the page as live — and '
          'the client only reports that once its resync has returned a '
          'snapshot for every page, so a value below the floor is a pre-outage '
          'reading wearing a fresh verdict. That is the operator looking at a '
          'setpoint the machine no longer holds, with nothing on screen to say '
          'so');

  expect(escaped, isEmpty,
      reason: 'an async error escaped the zone during the storm: $escaped. An '
          'error with no handler is reported against whichever case is running '
          'when it lands, so a flap that leaks one turns a green suite into a '
          'suite with a wandering red, and the case it fails is never this one');
}

/// How many attempts the backoff schedule expects to fit inside [down].
///
/// Full jitter draws uniformly from `[0, min(cap, base * 2^n))`, so attempt *n*
/// waits `min(cap, base * 2^n) / 2` on average, and the schedule resets on
/// entry to `ready` (`backoff.dart:81`) — so every down-window starts again at
/// the base. Walking that sum until it fills the window is therefore the
/// attempts a healthy client makes per cycle, computed from the schedule rather
/// than counted once and written down.
///
/// At 40 ms base and a 2 s cap the walk is 20, 60, 140, 300, 620, 1260 ms: six
/// attempts fill a one-second down-window.
int _attemptsPerDownWindow(Duration down, Duration base, Duration cap) {
  var elapsed = 0;
  var attempts = 0;
  var window = base.inMilliseconds;
  while (elapsed < down.inMilliseconds) {
    attempts++;
    elapsed += window ~/ 2;
    final doubled = window * 2;
    window = doubled > cap.inMilliseconds ? cap.inMilliseconds : doubled;
  }
  return attempts;
}

/// Runs [body] in a zone that collects escaped async errors into [escaped].
///
/// `flap_test.dart:234-249`'s shape, with its reason: an error on a future
/// nobody holds is reported against whichever test is running when it lands,
/// and during a twenty-second soak that is never this one. Assertions stay
/// *outside* the body — a failed `expect` inside the zone would be collected as
/// an escaped error rather than reported as the failure it is.
Future<void> _guarded(
    List<String> escaped, Future<void> Function() body) async {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await body();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    },
    (error, stack) => escaped.add('${error.runtimeType} — $error'),
  );
  await done.future;
}
