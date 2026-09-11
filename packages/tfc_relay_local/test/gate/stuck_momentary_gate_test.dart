/// F26 — Stuck momentary: the release that never arrives.
///
/// Catalogue §7.9, verbatim on one line each so a `grep -F` finds the same
/// bytes in the registry and here:
///
///   Injection:  hold jog, then (a) pull cable (b) kill app (c) background app
///   Expect:     machine stops in all three — deadman counter stops advancing
///
/// **Why a stopped counter stops the machine, quoted from the PLC contract.**
/// `relay-comm-design.md` §4.6a carries `FB_HoldToRun` with `Deadman : TON;
/// // PT := T#1000MS`, and *"The counter CHANGING is the signal. Its value
/// carries no meaning"* — `Run := Permissive AND (Counter <> 0) AND NOT
/// Deadman.Q`. So the machine runs only while the counter advances, and the
/// safety this row asserts is exactly that the counter on the plant tag
/// **stops advancing** when the panel holding it is gone. That `T#1000MS` is
/// the PLC's own deadman and the safety authority; this phase measures the
/// gateway's behaviour against it and adds no second timeout to the safety
/// path (09-CONTEXT ruling 3).
///
/// **The observable is the plant tag, read off the fake link — never the
/// client.** The gateway mints the counter and discards the wire's `n`
/// (`value_handlers.dart:180-185`, §4.6a), so a client-supplied number is the
/// wrong thing to assert on. Every arm reads the counter through
/// [_plantTag], which is what the PLC would see.
///
/// **Three deaths, one control.** Each injection is a different way for the
/// panel to stop being there — the link blackholed, the isolate killed, the
/// isolate paused — and each is judged the same way: the counter freezes at
/// once, and the tag reads 0 within a bound read off the gateway's own config
/// and printed. A second session holding a **different** key ticks through
/// every injection (one session may hold one live hold per key, 05-REVIEW
/// WR-02, so it must be a different key), and its counter keeps advancing —
/// without it, an arm would pass whenever the fixture ended every hold for
/// everyone, which is the vacuous form of this row.
///
/// The panel-isolate harness (`support/panel_isolate.dart`) is a copy of
/// `suspend_harness.dart`'s pattern: the plant and the gateway stay in this
/// isolate and only the panel moves, so the deadman counter is an ordinary
/// in-process read while the panel that dies is a real second isolate.
@TestOn('vm')
@Tags(['gate'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import '../support/gate_b_fixture.dart';
import '../support/panel_isolate.dart';

/// The key the dying panel holds, on ST101.
const String _heldKey = 'ST101.CN01.MOT01.setpoint';

/// The key the control session holds — a **different** key on a different
/// alias, because one session holds one live hold per key (05-REVIEW WR-02).
/// Spelled out here so the next reader does not "simplify" it to [_heldKey].
const String _controlKey = 'ST201.CN01.MOT01.setpoint';

/// A short heartbeat deadline so the reaper-bounded arms finish inside the
/// case budget. It is the floor the gateway accepts (`ServerConfig
/// .defaultMinHeartbeatDeadline`, 3 s) — not lowered past what a real panel on
/// its `ClientConfig.heartbeatFloor` can meet, and every arm reads the bound
/// back off the gateway's own config rather than restating this number.
const Duration _heartbeatDeadline = Duration(seconds: 3);

ServerConfig _fastReaperConfig() => ServerConfig(
      tick: ServerConfig.minTick,
      heartbeatDeadline: _heartbeatDeadline,
    );

/// What the PLC would read on [key] right now — the link's own cache, reached
/// through the fake link exactly as `hold_test.dart:51-54` does it, because
/// the question this file asks is what the *plant* sees, not what the client
/// believes. `resolve`/`peek` delegate through [GateBLink] to the inner fake.
int? _plantTag(GateBFixture fixture, String alias, String key) {
  final link = fixture.linkFor(alias);
  final ref = link.resolve(key, 'entry');
  return ref == null ? null : link.peek(ref)?.value as int?;
}

/// Samples the tag a handful of times over a short window and returns the
/// series, so an arm asks "did it advance" of a *rate* rather than of a single
/// pair of reads that cannot tell "stopped" from "between ticks".
Future<List<int>> _sampleTag(
  GateBFixture fixture,
  String alias,
  String key, {
  int samples = 8,
  Duration gap = const Duration(milliseconds: 60),
}) async {
  final series = <int>[];
  for (var i = 0; i < samples; i++) {
    series.add(_plantTag(fixture, alias, key) ?? -1);
    if (i < samples - 1) await Future<void>.delayed(gap);
  }
  return series;
}

/// The gateway's total of dropped hold ticks across every live session — a
/// climbing number after a panel's death would mean somebody else's ticks are
/// landing on it.
int _droppedHoldTicks(GateBFixture fixture) =>
    fixture.server.sessions.sessions
        .fold(0, (n, s) => n + s.droppedHoldTicks);

void main() {
  // ------------------------------------------------------- capability probe
  //
  // The file's first case, a SUPPORTING case that gates no row (registered in
  // gate_b_manifest_test.dart's _supportingCases). It measures on THIS
  // platform that a paused panel isolate stops sending and a killed one stops
  // immediately — the two capabilities every F26 arm below leans on. Re-run
  // the measurement here rather than trusting F16's number (07-RESEARCH §A.4's
  // instruction), and print it so the SUMMARY can paste it per platform.
  test('the panel-isolate probe (supporting case, gates no row)', () async {
    final fixture = await gateBFixture(
      panels: 1,
      keysPerAlias: 5,
      serverConfig: _fastReaperConfig(),
    );
    fixture.driver.cancel();

    // A panel with a live hold, the same instrument the rows drive.
    final paused = await PanelIsolate.spawn(
      uri: Uri.parse('ws://127.0.0.1:${fixture.port}'),
      holdKey: _heldKey,
      keys: fixture.keys,
    );
    expect(paused.engaged, isTrue,
        reason: 'the probe panel could not engage a hold, so the pause '
            'measurement below would be about a panel that was never holding '
            'anything');

    // Running: reports arrive at the panel's own cadence.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final beforePause = paused.reportsSeen;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final running = paused.reportsSeen - beforePause;

    paused.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final atPause = paused.reportsSeen;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final duringPause = paused.reportsSeen - atPause;

    // Asked while stopped, expected to fail by name — the strongest available
    // statement that the event loop is not turning.
    Object? refusal;
    try {
      await paused.ask('tickCount', budget: const Duration(milliseconds: 300));
    } on Object catch (error) {
      refusal = error;
    }
    paused.resume();

    print('F26 probe: Isolate.pause — $running reports running in 200 ms, '
        '$duringPause across 400 ms of pause; ask() while paused: '
        '${refusal.runtimeType}');

    expect(running, greaterThan(0),
        reason: 'the probe panel produced no reports even while running, so a '
            'stopped count below would prove nothing');
    expect(duringPause, 0,
        reason: '$duringPause reports arrived from a paused isolate. '
            'Isolate.pause is F26c\'s injection; if the event loop keeps '
            'turning on this platform the background-app arm injects nothing');
    expect(refusal, isA<TimeoutException>(),
        reason: 'a paused isolate answered a command: $refusal. The command '
            'loop is the event loop, so an isolate that can still reply is not '
            'stopped');

    // A second panel, to measure the kill: once killed it cannot resume.
    final killed = await PanelIsolate.spawn(
      uri: Uri.parse('ws://127.0.0.1:${fixture.port}'),
      holdKey: _heldKey,
      keys: fixture.keys,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final beforeKill = killed.reportsSeen;
    killed.kill();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final afterKill = killed.reportsSince(beforeKill + 1);

    print('F26 probe: Isolate.kill — reports stopped, '
        '$afterKill arrived in the 300 ms after the kill');
    expect(afterKill, lessThanOrEqualTo(1),
        reason: '$afterKill reports arrived from a killed isolate. A killed '
            'isolate runs nothing; more than the one that may already have '
            'been in flight means the kill did not take');
  }, timeout: const Timeout(Duration(minutes: 2)));

  // --------------------------------------------------------------- F26b
  //
  // Kill app: the panel isolate is killed without a close while its hold is
  // live. The plant counter freezes at once, the tag reads 0 within one
  // heartbeatDeadline (read off the gateway's config and printed), and
  // droppedHoldTicks does not climb afterwards.
  test('F26b: kill app — the panel isolate dies without a word and the '
      'deadman counter stops advancing', () async {
    final fixture = await gateBFixture(
      panels: 1,
      serverConfig: _fastReaperConfig(),
    );
    fixture.driver.cancel();
    final bound = fixture.server.config.heartbeatDeadline;

    // The control session, in this isolate, holding a DIFFERENT key. It ticks
    // through the whole injection; a stopped control counter would mean the
    // injection stopped everyone, not just the dying panel.
    final control = HoldToRunController(
      api: fixture.panel.client,
      key: _controlKey,
      pulsePeriod: const Duration(milliseconds: 50),
    );
    addTearDown(control.dispose);
    expect(await control.press(), isA<WriteApplied>());

    final panel = await PanelIsolate.spawn(
      uri: Uri.parse('ws://127.0.0.1:${fixture.port}'),
      holdKey: _heldKey,
      keys: fixture.keys,
    );
    expect(panel.engaged, isTrue,
        reason: 'the panel never engaged its hold, so the kill below is a kill '
            'under nothing');

    // Anti-vacuity: the counter was advancing before the kill.
    final advancing = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(advancing.last, greaterThan(advancing.first),
        reason: 'the held counter was not advancing before the kill '
            '($advancing), so "it stopped advancing" measures nothing');
    final controlBefore = _plantTag(fixture, 'ST201', _controlKey)!;

    // The injection.
    panel.kill();
    final frozenAt = _plantTag(fixture, 'ST101', _heldKey)!;

    // Stops advancing at once: over the next few pulse periods the counter
    // never rises above where it froze — it either holds that value (the reaper
    // has not fired yet) or drops to 0 (it has). A live panel would have
    // advanced it by several ticks here.
    final afterKill = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(afterKill.every((v) => v <= frozenAt), isTrue,
        reason: 'the held counter rose above $frozenAt after the panel was '
            'killed ($afterKill) — a dead panel sends no ticks, so a counter '
            'that kept advancing means the kill did not take');

    // Reads 0 within one heartbeatDeadline, printed rather than assumed.
    final toZero = Stopwatch()..start();
    await until(
      'the plant tag to read 0 after the reaper takes the killed session',
      () => _plantTag(fixture, 'ST101', _heldKey) == 0,
      budget: bound + const Duration(seconds: 2),
    );
    toZero.stop();
    print('F26b: held counter froze at $frozenAt, tag reached 0 in '
        '${toZero.elapsedMilliseconds} ms (bound = one heartbeatDeadline = '
        '${bound.inMilliseconds} ms, read off the gateway config)');
    expect(toZero.elapsed, lessThanOrEqualTo(bound + const Duration(seconds: 2)),
        reason: 'the killed session was not reaped and its hold zeroed inside '
            'the heartbeat deadline');

    // droppedHoldTicks does not climb afterwards: a dead panel sends nothing.
    final droppedAfter = _droppedHoldTicks(fixture);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final droppedLater = _droppedHoldTicks(fixture);
    print('F26b: droppedHoldTicks $droppedAfter -> $droppedLater after the '
        'death; control counter $controlBefore -> '
        '${_plantTag(fixture, 'ST201', _controlKey)}');
    expect(droppedLater, droppedAfter,
        reason: 'droppedHoldTicks climbed from $droppedAfter to $droppedLater '
            'after the panel died — a dead panel sends nothing, so a climbing '
            'counter means somebody else\'s ticks are landing on the gateway');

    // The control kept advancing throughout — the injection stopped the dead
    // panel, not every hold.
    final controlAfter = _plantTag(fixture, 'ST201', _controlKey)!;
    expect(controlAfter, greaterThan(controlBefore),
        reason: 'the control session on $_controlKey stopped advancing '
            '($controlBefore -> $controlAfter) — the injection reached a hold '
            'it was never supposed to touch');
  }, timeout: const Timeout(Duration(minutes: 2)));

  // --------------------------------------------------------------- F26a
  //
  // Pull cable: a hold is live and the proxy blackholes the link (a half-open,
  // the "pull cable" shape). Same two observables as F26b, plus the client-
  // side property Phase 5 shipped: the release path answers rather than
  // throwing into onTapCancel.
  test('F26a: pull cable — the link is blackholed under a live hold and the '
      'deadman counter stops advancing', () async {
    final fixture = await gateBFixture(
      panels: 2,
      proxyPerPanel: true,
      serverConfig: _fastReaperConfig(),
    );
    fixture.driver.cancel();
    final bound = fixture.server.config.heartbeatDeadline;

    // Panel 0 is the dying leg (it dials through proxy 0); panel 1 is the
    // control, holding a DIFFERENT key through an un-faulted proxy.
    final dying = HoldToRunController(
      api: fixture.panels[0].client,
      key: _heldKey,
      pulsePeriod: const Duration(milliseconds: 50),
    );
    addTearDown(dying.dispose);
    final control = HoldToRunController(
      api: fixture.panels[1].client,
      key: _controlKey,
      pulsePeriod: const Duration(milliseconds: 50),
    );
    addTearDown(control.dispose);
    expect(await dying.press(), isA<WriteApplied>());
    expect(await control.press(), isA<WriteApplied>());

    // Anti-vacuity: both counters advancing before the cut.
    final heldAdvancing = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(heldAdvancing.last, greaterThan(heldAdvancing.first),
        reason: 'the held counter was not advancing before the cut '
            '($heldAdvancing)');
    final controlBefore = _plantTag(fixture, 'ST201', _controlKey)!;
    final frozenAt = _plantTag(fixture, 'ST101', _heldKey)!;

    // Pull the cable: blackhole swallows the bytes in BOTH directions
    // (fault_proxy.dart:948-958, applyBlackhole sets discard on toUpstream and
    // toClient), so the panel's ticks never reach the plant even though the
    // panel keeps generating them.
    fixture.panels[0].proxy.blackhole();

    // Stops advancing at once: no tick crosses the blackhole, so the counter
    // never rises above where it froze (it holds, then drops to 0 when the
    // gateway learns the panel is gone).
    final afterCut = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(afterCut.every((v) => v <= frozenAt), isTrue,
        reason: 'the held counter rose above $frozenAt after the blackhole '
            '($afterCut) — no tick can cross a blackholed link');

    // The client-side property Phase 5 shipped: asking the controller to
    // release answers rather than throwing into onTapCancel, even over a link
    // whose bytes vanish.
    final releaseOutcome = await dying.release();
    expect(releaseOutcome, isA<WriteResult>(),
        reason: 'the release over a blackholed link threw instead of '
            'answering; §4.6a wires onTapCancel straight to release() with no '
            'try around it, so a throw would land in a gesture callback');

    // Reads 0 within one heartbeatDeadline: no heartbeat reaches the gateway,
    // so the reaper takes the session and releaseAllHolds writes the zero.
    final toZero = Stopwatch()..start();
    await until(
      'the plant tag to read 0 after the reaper takes the blackholed session',
      () => _plantTag(fixture, 'ST101', _heldKey) == 0,
      budget: bound + const Duration(seconds: 2),
    );
    toZero.stop();

    final controlSeries = await _sampleTag(fixture, 'ST201', _controlKey);
    print('F26a: held counter froze at $frozenAt, tag reached 0 in '
        '${toZero.elapsedMilliseconds} ms (bound = one heartbeatDeadline = '
        '${bound.inMilliseconds} ms); control series across the cut = '
        '$controlSeries');

    // The control on a different session kept advancing throughout.
    final controlAfter = _plantTag(fixture, 'ST201', _controlKey)!;
    expect(controlAfter, greaterThan(controlBefore),
        reason: 'the control session on $_controlKey stopped advancing '
            '($controlBefore -> $controlAfter) — a second operator\'s hold on '
            'another machine must be provably unaffected by this cable pull');

    fixture.panels[0].proxy.blackhole(enabled: false);
  }, timeout: const Timeout(Duration(minutes: 2)));

  // --------------------------------------------------------------- F26c
  //
  // Background app: the panel isolate is PAUSED, not killed. A paused panel
  // stops beating, so the counter stops within one tick period (the real
  // safety, because the PLC's TON sees a stopped counter) and the tag reaches
  // 0 when the reaper takes the session. The interval between those two
  // moments is the window in which the gateway believes a hold is live that
  // nobody is holding — the number 09-CONTEXT ruling 3 asked for, printed and
  // carried into the registry deviation.
  test('F26c: background app — the panel isolate is paused and the deadman '
      'counter stops advancing', () async {
    final fixture = await gateBFixture(
      panels: 1,
      serverConfig: _fastReaperConfig(),
    );
    fixture.driver.cancel();
    final bound = fixture.server.config.heartbeatDeadline;

    final control = HoldToRunController(
      api: fixture.panel.client,
      key: _controlKey,
      pulsePeriod: const Duration(milliseconds: 50),
    );
    addTearDown(control.dispose);
    expect(await control.press(), isA<WriteApplied>());

    final panel = await PanelIsolate.spawn(
      uri: Uri.parse('ws://127.0.0.1:${fixture.port}'),
      holdKey: _heldKey,
      keys: fixture.keys,
    );
    expect(panel.engaged, isTrue);

    final advancing = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(advancing.last, greaterThan(advancing.first),
        reason: 'the held counter was not advancing before the pause '
            '($advancing)');
    final controlBefore = _plantTag(fixture, 'ST201', _controlKey)!;

    // The injection: pause the isolate. This is where the two moments the
    // interval spans begin — the counter is about to stop.
    final window = Stopwatch()..start();
    panel.pause();
    final frozenAt = _plantTag(fixture, 'ST101', _heldKey)!;

    // Stops within one tick period: a paused panel runs no pulse timer, so the
    // counter stops advancing.
    //
    // **Stops, not freezes at the instant of the call.** `Isolate.pause` takes
    // effect at the isolate's next safepoint, not when it returns, so a pulse
    // already scheduled can still land — and `frozenAt` is read immediately
    // after the call, before that pulse. `[9, 10, 10, 10, 10, 10, 10, 10]` on
    // the macOS runner is a counter that stopped, and the old ceiling read it
    // as one that had not: eight samples at 60 ms against a 50 ms pulse period
    // means a *running* timer shows about eight increments across this window,
    // not one.
    final afterPause = await _sampleTag(fixture, 'ST101', _heldKey);
    expect(afterPause.last, lessThanOrEqualTo(frozenAt + 1),
        reason: 'the held counter reached ${afterPause.last} after freezing at '
            '$frozenAt ($afterPause). At most one pulse may be in flight when '
            'the isolate reaches its safepoint; more than that is a pulse '
            'timer still running inside a paused isolate');
    final advanced = [
      for (var i = 1; i < afterPause.length; i++)
        if (afterPause[i] > afterPause[i - 1]) '${afterPause[i - 1]}->'
            '${afterPause[i]}',
    ];
    expect(advanced.length, lessThanOrEqualTo(1),
        reason: 'the held counter advanced $advanced across '
            '${afterPause.length} samples taken after the pause '
            '($afterPause). One step is the pulse that was already scheduled '
            'when the isolate reached its safepoint, and it lands wherever the '
            'sampling happens to catch it — between two samples just as often '
            'as before the first, which is what [9, 10, 10, ...] is. More than '
            'one step is a pulse timer still running inside a paused isolate, '
            'and a hold the gateway believes in that nobody is holding. A fall '
            'to 0 is the reaper and is allowed here — the arm below waits for '
            'it');

    // Reaches 0 when the reaper takes the paused session.
    await until(
      'the plant tag to read 0 after the reaper takes the paused session',
      () => _plantTag(fixture, 'ST101', _heldKey) == 0,
      budget: bound + const Duration(seconds: 2),
    );
    window.stop();
    final intervalMs = window.elapsedMilliseconds;

    print('F26c: counter froze at $frozenAt on pause; tag reached 0 '
        '$intervalMs ms later. That interval is the window in which the '
        'gateway believed a hold was live that nobody was holding — the '
        'measurement 09-CONTEXT ruling 3 asked for (bound = one '
        'heartbeatDeadline = ${bound.inMilliseconds} ms). No gateway-side '
        'hold expiry was added; the PLC T#1000MS TON is the safety authority.');

    // The control kept advancing throughout.
    final controlAfter = _plantTag(fixture, 'ST201', _controlKey)!;
    expect(controlAfter, greaterThan(controlBefore),
        reason: 'the control session on $_controlKey stopped advancing '
            '($controlBefore -> $controlAfter) while the other panel was '
            'merely backgrounded');

    // The interval is a real, bounded number: the reaper takes the session no
    // later than one heartbeat deadline (plus the poll margin) after silence
    // began.
    expect(intervalMs, greaterThan(0));
    expect(window.elapsed, lessThanOrEqualTo(bound + const Duration(seconds: 2)),
        reason: 'the paused session outlived one heartbeat deadline before '
            'its hold was zeroed');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
