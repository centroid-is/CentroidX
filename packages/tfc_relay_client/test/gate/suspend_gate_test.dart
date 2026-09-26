/// F16 — Client suspend/resume.
///
/// The catalogue's expectation, verbatim: on resume: detects staleness
/// immediately, reconnects or resyncs;
/// no burst of queued stale timers acting on dead state
/// (generation counter again).
///
/// **The lever is `Isolate.pause()`, and the deviation is only in the
/// spelling.** The catalogue names `SIGSTOP` on the client process for 30 s and
/// then `SIGCONT`. In-process that is not expressible — a stopped process
/// cannot run the assertions — and a child process driven by
/// `Process.killPid(ProcessSignal.sigstop)` is unavailable on Windows, so the
/// row would be green on two platforms and skipped on the third. A paused
/// isolate stops its event loop, so its socket is not read, bytes pile up in
/// the kernel, its timers do not fire and the gateway stops hearing from it:
/// every observable `SIGSTOP` produces, produced by an API with no platform
/// story. See `test/support/suspend_harness.dart`.
///
/// **The first case in this file is that claim being re-measured rather than
/// cited.** 07-RESEARCH §A.4 executed the probe on macOS arm64 only, and its
/// own assumption A3 says Linux and Windows are *assumed* identical because it
/// is a VM-level API. The probe therefore ships as an arm that runs wherever
/// the lane runs. It carries **no skip**: a platform on which `Isolate.pause`
/// does not stop the event loop must make this lane red and say so, not green
/// by omission. A skip would leave F16 below reading as a judged row on a
/// platform where its lever does nothing — which is the "capability switched
/// off" failure the manifest's skip audit exists to catch one level up. If that
/// red ever arrives, the fallback is a child process under
/// `ProcessSignal.sigstop` with a *named* Windows skip, and the probe's failure
/// message says so.
///
/// **The no-burst clause is the VM's property, not the client's, and the row
/// says so out loud.** 07-RESEARCH §A.4 measured Dart coalescing overdue
/// periodic timers rather than replaying them: an isolate paused for 600 ms
/// with a 20 ms timer produced 0 ticks across the pause and then resumed at its
/// ordinary rate, never 30 ticks at once. So "no burst of queued stale timers
/// acting on dead state" is delivered here by the runtime. The row asserts it
/// anyway, because the regression it would catch is real — a client that
/// hand-rolled catch-up, or a future timer wrapper that replayed missed periods
/// — but nobody should read this green as evidence of a client mechanism that
/// does not exist. The generation counter the catalogue names in the same
/// breath *is* a client mechanism and it is gated by F3
/// (`flap_gate_test.dart`), where a half-finished session's callbacks are the
/// subject.
///
/// **What is measured across the pause, and why it is a push.** The panel
/// pushes a report on each of its own ticks. A paused isolate sends nothing, so
/// "zero reports arrived across twenty-nine seconds" is an observation rather
/// than an inference, and there is no poll racing the pause. The tick counter
/// inside those reports is the panel's own, counted in the panel's isolate,
/// which is the only counter that stops when that event loop does.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
// `CloseCodes`, for the one code that means the reaper acted: a close the
// gateway chose, told apart from a socket that merely died.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import '../support/fault_fixture.dart' show until;
import '../support/permissive_resolver.dart';
import '../support/suspend_harness.dart';

// ---------------------------------------------------------------------------
// The probe's windows.
// ---------------------------------------------------------------------------

/// How long the probe measures a healthy rate over, before and after.
///
/// 07-RESEARCH §A.4's own number: 300 ms at a 20 ms period is fifteen ticks,
/// which is enough for a rate and short enough that the probe costs the lane
/// under two seconds in total.
const Duration _probeWindow = Duration(milliseconds: 300);

/// How long the probe stops the isolate for.
///
/// The research probe's 600 ms. Long enough that thirty ticks are owed and a
/// replay would be unmistakable; short enough that the probe is not a second
/// F16.
const Duration _probePause = Duration(milliseconds: 600);

/// How long a pause is given to take effect before its window is believed.
///
/// `Isolate.pause` is a message to the VM, not a system call on this thread, so
/// a tick already scheduled may still land after the call returns. Everything
/// this file asserts about a pause is measured from *after* this settle, which
/// turns "almost no ticks" into a genuine zero and costs the case a tenth of a
/// second.
const Duration _pauseSettle = Duration(milliseconds: 200);

// ---------------------------------------------------------------------------
// F16's own numbers.
// ---------------------------------------------------------------------------

/// The catalogue's own duration: `SIGSTOP client process 30 s`.
///
/// Unlike F2's and F17's, this one is **not** shortened — thirty seconds is
/// what the row says and thirty seconds is what runs, so F16 adds no entry to
/// the deviations registry.
const Duration _suspend = Duration(seconds: 30);

/// How long the panel is given to settle after the pause is lifted.
///
/// Everything the row asserts about the resume happens inside this: the first
/// stale verdict, the reconnect, and the page agreeing with the plant again.
/// Ten seconds covers a dial that has to wait out a backoff draw capped at two
/// seconds, plus a handshake and a snapshot over loopback measured at 51-112 ms
/// (07-08-SUMMARY).
const Duration _recovery = Duration(seconds: 10);

/// How often the gateway is sampled while the panel is stopped.
///
/// Three seconds — half the gateway's default heartbeat deadline, so no
/// reap-and-redial cycle can fit between two samples and leave the ledger
/// looking quiet. `herd_gate_test.dart`'s idle-liveness case sets the interval
/// and the reason.
const Duration _sample = Duration(seconds: 3);

/// The page F16 drives, in the plant's own naming.
const String _watched = 'ST101.CN01.MOT01.setpoint';

/// What the plant holds before the pause, and what it is moved to during it.
///
/// Two distinct numbers so that "the panel came back" and "the panel is holding
/// what the plant holds *now*" are different observations — `herd_gate_test`'s
/// rule, and here it is the difference between a resync and a cache that was
/// never cleared.
const int _beforeSuspend = 1300;
const int _duringSuspend = 2500;

/// How many reports the panel may push after a resume before one of them says
/// the view is stale — and, separately, how many may carry the pre-freeze value
/// with `stale` unset.
///
/// **Three, and the number is a measurement.** Observed on this machine: the
/// **second** report after the resume carries `stale: true`. The freshness
/// deadline's timer came due twenty-seven seconds ago, so it is owed on the
/// first turn of the loop — but so is the panel's own periodic tick, and the
/// tick's due time is the earlier of the two, so exactly one report gets out
/// ahead of the verdict. Three reports is sixty milliseconds, a fiftieth of the
/// freshness deadline: wide enough that the ordering of two overdue timers is
/// not what reddens a row about staleness, and nowhere near wide enough to
/// admit a panel that painted a thirty-second-old value as current.
///
/// **Not "every run" — that claim used to be here and the macOS runner
/// disproved it.** A third thing is due at the same instant: the resync. When
/// it lands first the panel goes straight from silent to correct, no report
/// says stale because no report ever had a stale view to describe, and the
/// number below bounds nothing on that run. That is why the row's assertions
/// are written as a bound on unmarked pre-freeze reports rather than as a
/// requirement that a stale one exist — see the resume block for the argument.
const int _staleWithinReports = 3;

/// Builds the plant and the gateway the panel dials, and registers both
/// teardowns.
///
/// A gateway with no in-process panel, which no existing fixture builds:
/// `faultFixture` and `gateFixture` both construct their clients here, and F16's
/// client is the one thing that has to live somewhere else. The teardown order
/// is the fixtures' own — the panel is released first by the case, then the
/// gateway, then the plant.
({FakeStateMan plant, RelayServer gateway, List<String> complaints})
    _gatewayOnly() {
  final plant = FakeStateMan();
  addTearDown(plant.dispose);
  plant.setValues(<String, Object?>{_watched: _beforeSuspend});

  final complaints = <String>[];
  final gateway = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: plant,
    config: ServerConfig(tick: ServerConfig.minTick),
    // Collected rather than discarded, for `gate_fixture.dart`'s reason: a
    // case that provokes a socket to die under a handler is exactly the shape
    // that escapes an async error, and an assertion that none escaped has to
    // be able to refute itself.
    onError: (error, _, where) => complaints.add('$where: $error'),
  );
  addTearDown(gateway.close);
  return (plant: plant, gateway: gateway, complaints: complaints);
}

/// Closes over the gateway's reap ledger, told apart from every other close.
///
/// `GateFixture.heartbeatReaps`' definition, restated over a bare `RelayServer`
/// because this file builds no `GateFixture`: a reap is a close the *gateway*
/// initiated with `heartbeatTimeout`, which is the only code that means "this
/// session stopped talking to me". A client-observed 1006 is the socket dying,
/// which is a different fact.
List<ConnectionClose> _reaps(RelayServer gateway) => [
      for (final close in gateway.closeLedger)
        if (close.serverCloseCode == CloseCodes.heartbeatTimeout) close,
    ];

void main() {
  group('the lever does what the catalogue\'s lever does', () {
    test('a paused isolate stops its event loop and the VM does not replay its '
        'overdue timers', () async {
      // No client: the ticker and the pause machinery on their own, which is
      // 07-RESEARCH §A.4's probe exactly. Same spawn, same timer and same
      // pause path the row below is driven with, so a green here is a statement
      // about the instrument rather than about a second one.
      final ticker = await SuspendedPanel.spawn();
      addTearDown(ticker.shutdown);

      await Future<void>.delayed(_probeWindow);
      final before = ticker.reportsSeen;
      await Future<void>.delayed(_probeWindow);
      final running = ticker.reportsSeen - before;

      ticker.pause();
      await Future<void>.delayed(_pauseSettle);
      final atSettle = ticker.reportsSeen;
      await Future<void>.delayed(_probePause);
      final duringPause = ticker.reportsSeen - atSettle;

      // Asked while it is stopped, and expected to fail by name. This is the
      // strongest available statement that the event loop is not running:
      // no reports is consistent with a timer that was cancelled, but a
      // command loop that cannot answer is an event loop that is not turning.
      Object? refusal;
      try {
        await ticker.ask('tickCount', budget: const Duration(milliseconds: 300));
      } on Object catch (error) {
        refusal = error;
      }

      final atResume = ticker.reportsSeen;
      ticker.resume();
      await Future<void>.delayed(_probeWindow);
      final afterResume = ticker.reportsSeen - atResume;
      final counter = await ticker.ask('tickCount') as int;

      print('Isolate.pause probe: ${_probeWindow.inMilliseconds} ms windows at '
          'a ${defaultPanelTick.inMilliseconds} ms period — $running ticks '
          'running, $duringPause across ${_probePause.inMilliseconds} ms of '
          'pause (measured after a ${_pauseSettle.inMilliseconds} ms settle), '
          '$afterResume in the window after the resume; the isolate\'s own '
          'counter reads $counter');

      expect(running, greaterThan(_probeWindow.inMilliseconds ~/
              (defaultPanelTick.inMilliseconds * 2)),
          reason: 'the isolate produced $running ticks in '
              '${_probeWindow.inMilliseconds} ms at a '
              '${defaultPanelTick.inMilliseconds} ms period, which is not a '
              'healthy rate. Everything below is a claim that a number stopped '
              'moving, and a number that was barely moving to begin with '
              'cannot be shown to have stopped');

      expect(duringPause, 0,
          reason: '$duringPause reports arrived from an isolate that was '
              'paused for ${_probePause.inMilliseconds} ms. `Isolate.pause` is '
              'this row\'s SIGSTOP: if the event loop keeps turning on this '
              'platform then F16 below is injecting nothing, and its green '
              'would mean a healthy panel stayed healthy. The fallback is a '
              'child process driven with ProcessSignal.sigstop and a named '
              'Windows skip (07-RESEARCH §A.4) — take it here rather than '
              'weakening the row');

      expect(refusal, isA<TimeoutException>(),
          reason: 'a paused isolate answered a command, or failed to answer it '
              'in a way this harness does not recognise: $refusal. The command '
              'loop is the event loop; an isolate that can still reply is not '
              'stopped, whatever its timers are doing');

      expect(afterResume, lessThanOrEqualTo(running * 2),
          reason: 'the isolate produced $afterResume ticks in the '
              '${_probeWindow.inMilliseconds} ms after the resume, against '
              '$running in the same window before the pause. This is the whole '
              'of the no-burst property and the VM is what provides it: Dart '
              'coalesces overdue periodic timers instead of replaying them, so '
              'the ${_probePause.inMilliseconds ~/ defaultPanelTick.inMilliseconds} '
              'periods that came due while the isolate was stopped are owed '
              'once, not once each. A platform that replayed them would show '
              'this number as the whole debt');

      expect(counter, ticker.reportsSeen,
          reason: 'the isolate has counted $counter ticks and this side has '
              'received ${ticker.reportsSeen} reports. One report is pushed '
              'per tick, so a difference means reports are being dropped or '
              'coalesced on the way — and every measurement above is a count '
              'of reports standing in for a count of ticks');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('F16 — the panel that was not there', () {
    test('F16: a panel that was frozen for thirty seconds comes back honest',
        () async {
      final plant = _gatewayOnly();
      await plant.gateway.start();

      final panel = await SuspendedPanel.spawn(
        uri: Uri.parse('ws://127.0.0.1:${plant.gateway.port}'),
        keys: <String>{_watched},
        watch: _watched,
      );
      addTearDown(panel.shutdown);

      await until(
        'the panel in the second isolate to hold the plant\'s seeded value',
        () => panel.last?.value == _beforeSuspend,
        budget: const Duration(seconds: 15),
      );

      // ANTI-VACUITY, first half: the page carried the seeded value and the
      // panel's own timer was running before anything was stopped. A counter
      // that was not moving cannot be shown to have stopped, and a page that
      // never arrived cannot be shown to have been rebuilt.
      final movingFrom = panel.reportsSeen;
      await Future<void>.delayed(_probeWindow);
      final movingTicks = panel.reportsSeen - movingFrom;
      final beatsBefore = panel.last!.beats;

      expect(movingTicks, greaterThan(0),
          reason: 'the panel pushed $movingTicks reports in '
              '${_probeWindow.inMilliseconds} ms before the pause. Its own '
              'periodic timer is the instrument this row measures the freeze '
              'with, and one that was already stopped would make every number '
              'below vacuously correct');
      expect(plant.gateway.sessions.sessionCount, 1,
          reason: 'the gateway is holding '
              '${plant.gateway.sessions.sessionCount} sessions for one panel '
              'before anything was injected, so the session count cannot be '
              'read as evidence of anything during the freeze');

      // THE FREEZE.
      final frozen = Stopwatch()..start();
      panel.pause();
      await Future<void>.delayed(_pauseSettle);
      final frozenAt = panel.reportsSeen;
      final tickAtFreeze = panel.last!.tick;

      // The plant moves while nobody is listening. A value the panel never
      // held before the freeze, so a page that came back holding it was
      // rebuilt rather than remembered.
      plant.plant.setValues(<String, Object?>{_watched: _duringSuspend});

      // Driven off the stopwatch and not off a sample count, so the freeze is
      // the catalogue's thirty seconds whatever `_sample` is set to — and so
      // that shortening `_suspend` (this plan's sabotage arm) genuinely
      // shortens the outage instead of merely dropping samples off the table.
      final ledger = <String>[];
      var sessionsHitZero = false;
      while (frozen.elapsed < _suspend) {
        final remaining = _suspend - frozen.elapsed;
        await Future<void>.delayed(remaining < _sample ? remaining : _sample);
        final sessions = plant.gateway.sessions.sessionCount;
        if (sessions == 0) sessionsHitZero = true;
        ledger.add('t=${frozen.elapsed.inSeconds}s  sessions=$sessions  '
            'reaps=${_reaps(plant.gateway).length}  '
            'reports=${panel.reportsSeen - frozenAt}');
      }
      final frozenReports = panel.reportsSeen - frozenAt;
      final table = ledger.join('\n  ');

      // THE RESUME.
      final resumedAt = panel.reportsSeen;
      final resumed = Stopwatch()..start();
      panel.resume();

      await until(
        'the panel to agree with the plant again after the resume',
        () => panel.last?.value == _duringSuspend,
        budget: _recovery,
      );
      resumed.stop();

      final firstStale =
          panel.firstReportWhere((r) => r.stale, mark: resumedAt);
      final firstRecovered = panel.firstReportWhere(
          (r) => r.value == _duringSuspend,
          mark: resumedAt);
      final afterResume = panel.reportsSeen - resumedAt;
      final counter = await panel.ask('tickCount') as int;
      final reaps = _reaps(plant.gateway);

      print('F16: ${_suspend.inSeconds} s of Isolate.pause. Before the freeze '
          'the panel ticked $movingTicks times in '
          '${_probeWindow.inMilliseconds} ms and had sent $beatsBefore '
          'heartbeats; across the freeze it pushed $frozenReports reports and '
          'its own counter stood still at $tickAtFreeze. The gateway:\n  '
          '$table\n  reaps=${reaps.length} $reaps\n'
          'On resume: the first report was report '
          '${firstStale == null ? 'never' : firstStale - resumedAt + 1} to say '
          'stale and report '
          '${firstRecovered == null ? 'never' : firstRecovered - resumedAt + 1} '
          'to hold the plant\'s new value; $afterResume reports in '
          '${resumed.elapsedMilliseconds} ms of recovery, against '
          '${_suspend.inMilliseconds ~/ defaultPanelTick.inMilliseconds} '
          'periods owed; the isolate\'s counter reads $counter and the gateway '
          'holds ${plant.gateway.sessions.sessionCount} sessions');

      // ANTI-VACUITY, second half: the freeze was real. Zero reports across
      // twenty-nine seconds from an isolate that pushes fifty a second is the
      // pause being observed rather than assumed.
      expect(frozenReports, 0,
          reason: '$frozenReports reports arrived from a panel that was paused '
              'for ${_suspend.inSeconds} seconds. The freeze is this row\'s '
              'whole injection: a panel that kept running was never frozen, '
              'and everything below would be a healthy panel being asked '
              'whether it recovered from nothing');

      // THE GATEWAY RELEASED THE DEAD SESSION. Thirty seconds is five of the
      // gateway's six-second heartbeat deadlines, and a paused event loop
      // fires no timer, so `HeartbeatPump` cannot get a ping out either — the
      // panel is genuinely silent and the reaper is right to take it. That is
      // the distinction 07-08b's pump draws and this row depends on: a healthy
      // idle panel is not reaped (`herd_gate_test.dart`'s idle-liveness case),
      // and a frozen one is.
      expect(sessionsHitZero, isTrue,
          reason: 'the gateway never went to zero sessions while the panel was '
              'frozen for ${_suspend.inSeconds} seconds:\n  $table\n\n'
              'The heartbeat deadline is '
              '${ServerConfig().heartbeatDeadline.inSeconds} s and a paused '
              'isolate cannot beat, so a gateway still holding this session is '
              'one ticking for a socket nobody is reading — and F16\'s recovery '
              'below would then be a reconnect onto a session the gateway '
              'still believes in');
      expect(reaps, isNotEmpty,
          reason: 'the gateway holds no heartbeat reap in its ledger after '
              '${_suspend.inSeconds} seconds of a panel that could not send a '
              'byte: ${plant.gateway.closeLedger}. If the session went away '
              'for some other reason then "the reaper releases a dead session" '
              'is not what this row measured');

      // NEVER PAINTS THE OLD VALUE AS CURRENT — T-07-29 exactly, and the
      // claim this row exists for. A panel that resynced first and greyed out
      // afterwards would satisfy a "went stale at some point" assertion while
      // having shown a thirty-second-old number, unmarked, in between.
      //
      // Stated as a property of every report rather than as the existence of a
      // stale one, because whether a stale report exists at all is not up to
      // the client. Three things come due the instant the isolate resumes: the
      // panel's own 20 ms tick, the freshness deadline (overdue by
      // twenty-seven seconds), and the resync. The row used to assume the tick
      // wins, and on the macOS runner the resync did — it finished inside
      // 38 ms, so the first report after the resume already held the plant's
      // new value and the panel never had a stale moment to report. Nothing
      // was wrong: the operator was shown nothing during the freeze and a
      // correct number after it. The old arm read that as the failure it was
      // built to catch.
      //
      // What follows cannot be satisfied by a fast resync, and still reddens
      // for the behaviour the row names.
      final paintedOldAsFresh = [
        for (var i = resumedAt; i < panel.reports.length; i++)
          if (panel.reports[i].value == _beforeSuspend &&
              !panel.reports[i].stale)
            i - resumedAt + 1,
      ];
      //
      // Bounded rather than forbidden, and the bound is [_staleWithinReports]
      // — the same three reports that budget already argued for, for the same
      // reason. Two timers come due on the resume and the tick is the earlier
      // of the two, so exactly one report gets out ahead of the verdict; that
      // one is a fiftieth of the freshness deadline of unmarked screen and it
      // is the runtime's ordering, not a decision this client makes. Zero is
      // the wrong number here: it fails the row for the behaviour its own
      // budget was written to permit.
      expect(paintedOldAsFresh.length, lessThan(_staleWithinReports),
          reason: 'after ${_suspend.inSeconds} seconds frozen, reports '
              '$paintedOldAsFresh carried the pre-freeze value '
              '($_beforeSuspend) with stale unset — '
              '${paintedOldAsFresh.length * defaultPanelTick.inMilliseconds} '
              'ms of it. Its last frame is half a minute old and its socket '
              'has been reaped; every one of those reports put a number from '
              'before the freeze on an operator\'s screen with nothing marking '
              'its age, and past the first that is no longer two overdue '
              'timers racing');

      // ANTI-VACUITY. The sweep above is over reports that arrived; zero
      // reports would pass it while measuring nothing.
      expect(afterResume, greaterThan(0),
          reason: 'no report arrived after the resume, so the sweep above ran '
              'over an empty list and this row asserts nothing about what the '
              'panel showed');

      // WHEN A STALE VERDICT IS REPORTED AT ALL, IT IS REPORTED IN TIME AND IN
      // ORDER.
      //
      // **Conditional on one arriving, and that is not a weakening — it is the
      // third correction this row has needed on the same point.** Three things
      // come due when the isolate resumes: the panel's tick, the overdue
      // freshness deadline, and the resync. The row originally required a stale
      // report to exist; the macOS runner resynced in 38 ms and produced none.
      // The fix made the requirement conditional on some report preceding the
      // recovery — and the Windows runner then produced exactly that: report 1
      // held neither the new value nor a stale flag, report 2 held the new
      // value, 47 ms in total. One report got out ahead of BOTH the verdict and
      // the resync, which the condition had assumed impossible.
      //
      // The lesson, written down so it is not learned a fourth time: **whether
      // a stale report is ever emitted is not the client's to decide**, so no
      // phrasing of "one must exist" can be made safe by narrowing when it is
      // demanded. The operator-facing guarantee is the bound above — how many
      // reports may show the pre-freeze value unmarked — and it holds in every
      // one of these interleavings. What is left here is the ordering, which is
      // a real property whenever the verdict does arrive.
      if (firstStale != null) {
        expect(firstStale - resumedAt, lessThan(_staleWithinReports),
            reason: 'the panel took ${firstStale - resumedAt + 1} reports — '
                '${(firstStale - resumedAt + 1) * defaultPanelTick.inMilliseconds} '
                'ms — to report its view stale after the resume. "Detects '
                'staleness immediately" is the row\'s own word: the verdict is '
                'owed on the first turn of the event loop and not after a '
                'round trip');
        if (firstRecovered != null) {
          expect(firstStale, lessThan(firstRecovered),
              reason: 'the panel reported the plant\'s new value at report '
                  '${firstRecovered - resumedAt + 1} and did not say its view '
                  'was stale until report ${firstStale - resumedAt + 1}. '
                  'Recovering before admitting staleness is the '
                  'silent-permanent-staleness case with a happy ending: for '
                  'those reports the screen showed a value from before the '
                  'freeze, unmarked, and an operator had no way to know');
        }
      }

      // NO BURST OF QUEUED STALE TIMERS. The panel owes
      // ${_suspend / tick} periods; the VM coalesces them, so what comes back
      // is one. **This is the runtime's property and not the client's** — see
      // the library doc. What a regression here would catch is a client that
      // hand-rolled catch-up, and the arm is cheap enough to keep for that.
      final owed = _suspend.inMilliseconds ~/ defaultPanelTick.inMilliseconds;
      final atRate = resumed.elapsedMilliseconds ~/
          defaultPanelTick.inMilliseconds;
      expect(afterResume, lessThan(owed ~/ 2),
          reason: 'the panel pushed $afterResume reports in the '
              '${resumed.elapsedMilliseconds} ms after the resume, against '
              'about $atRate at its ordinary rate and $owed periods that came '
              'due while it was stopped. A burst here is the catalogue\'s "no '
              'burst of queued stale timers acting on dead state": every one '
              'of those overdue callbacks would run against a socket the '
              'gateway closed half a minute ago');
      expect(counter, panel.reportsSeen,
          reason: 'the panel\'s own counter reads $counter and this side has '
              'received ${panel.reportsSeen} reports. They are one per tick, '
              'so a gap means the burst assertion above is counting deliveries '
              'rather than timer fires');

      // RECONNECTS OR RESYNCS, and the page is the plant's.
      expect(panel.last!.value, _duringSuspend,
          reason: 'the panel came back holding ${panel.last!.value} against a '
              'plant at $_duringSuspend. The value changed while it was '
              'frozen, so a panel still showing the old one has reconnected '
              'without resyncing — the silent-permanent-staleness case (rule '
              '2: resync on reconnect, never resume)');
      // **Waited for, not sampled.** This arm is about a *leak* — its own
      // reason says "more means the reaped one is still registered beside its
      // replacement" — and zero is not that. Zero is the panel's new session
      // not being registered yet, which is ordinary: the wait above returns as
      // soon as a report carries the plant's new value, and on a fast resync
      // (40 ms, one report, measured on the macOS runner) that lands before
      // the gateway has finished registering the socket it came over.
      //
      // Sampling an instant here asked a question the row does not have — "is
      // it registered *now*" — and got the answer that means "not yet" while
      // reading as though it meant "never".
      await until(
        'the gateway to register the panel\'s new session',
        () => plant.gateway.sessions.sessionCount >= 1,
        budget: _recovery,
      );
      expect(plant.gateway.sessions.sessionCount, 1,
          reason: 'the gateway holds '
              '${plant.gateway.sessions.sessionCount} sessions after the panel '
              'recovered. One panel is one session: more means the reaped one '
              'is still registered beside its replacement, and the gateway is '
              'ticking for a socket nobody will ever read');
      expect(plant.complaints, isEmpty,
          reason: 'the gateway reported errors across the freeze and the '
              'recovery: ${plant.complaints}. A panel that stops reading is a '
              'condition the gateway is built for — it reaps the session — and '
              'not one it should be logging exceptions about');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
