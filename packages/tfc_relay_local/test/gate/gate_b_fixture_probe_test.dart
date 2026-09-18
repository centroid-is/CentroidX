/// The gate-B fixture's non-vacuity probe — a **supporting case** that gates
/// no catalogue row, on purpose, and is registered as such in
/// `gate_b_manifest_test.dart`'s `_supportingCases` with the argument for why
/// numbering it would be wrong.
///
/// What it proves, before any row leans on the fixture: two panels reach
/// ready inside a window; a value set on a link arrives at both panels with
/// its real payload; the plant driver's sweep count advanced; and the socket
/// count settles back to this case's own baseline after an explicit teardown
/// in the argued order. A fixture that cannot show these four things is
/// standing up a mirage, and every row written on top of it would be green
/// about nothing.
///
/// It also records the two numbers the rows inherit as overhead: the
/// fixture's own setUp and teardown wall clock, paid once per case in seven
/// row files.
@TestOn('vm')
@Tags(['gate'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/faults.dart'
    show canCountOpenSockets, openSocketCount, openSocketCountSkipReason;

import '../support/gate_b_fixture.dart';

void main() {
  // The name is ONE literal on one line, deliberately: the manifest's
  // discovery reads the first string literal of a `test(` call, so a wrapped
  // name would register here as only its first fragment and the
  // supporting-case exemption would point at a case that "vanished".
  test('the gate-B pipe probe (supporting case, gates no row)', () async {
    // The descriptor baseline is THIS case's, taken before the pipe exists —
    // a suite-wide baseline would blame this fixture for whatever a
    // neighbouring case leaked.
    final canCount = canCountOpenSockets;
    final baseline = canCount ? openSocketCount() : 0;

    final setUpClock = Stopwatch()..start();
    final fixture = await gateBFixture(panels: 2, keysPerAlias: 5);
    setUpClock.stop();

    // T-09-11: the identity this pipe ran under, recorded rather than
    // assumed. No TLS and no token file means every panel holds operate
    // rights — the gateway's own bind advisory names this exact deployment.
    print('PROBE policy: plaintext, no token file — every panel operate '
        '(the ordinary station identity for this suite)');
    print('PROBE fixture setUp wall clock = ${setUpClock.elapsedMilliseconds} '
        'ms (2 panels, 2 aliases, 10 keys)');

    // The plant was actually busy — the first question every row asks.
    final sweepsAtCheck = fixture.driver.sweeps;
    expect(sweepsAtCheck, greaterThan(0),
        reason: 'the driver has not swept once; every "other keys keep '
            'flowing" clause in this gate would be measured against a quiet '
            'plant');
    await until(
      'the plant driver advancing while the pipe is up',
      () => fixture.driver.sweeps > sweepsAtCheck,
      budget: const Duration(seconds: 5),
    );
    print('PROBE plant sweeps = ${fixture.driver.sweeps} '
        '(writes = ${fixture.driver.writes})');

    // A value set on a link — the plant boundary, where every gate-B lever
    // lives — arrives at both panels with its real payload. The driver is
    // stopped first, because the pipe conflates rather than queues: a lever
    // value published between two sweeps is legitimately superseded by the
    // next sweep before a tick carries it, and a probe racing that would be
    // measuring the scheduler. 777 rather than a value the driver could have
    // written, so a pass cannot be the sweep arriving in the probe's clothes.
    fixture.driver.cancel();
    const key = 'ST101.CN01.MOT01.setpoint';
    fixture.linkFor('ST101').inner.setValue(key, 777);
    await until(
      'both panels reading the value the link just published',
      () => fixture.panels
          .every((panel) => panel.client.read(key)?.value == 777),
      budget: const Duration(seconds: 10),
    );
    for (final panel in fixture.panels) {
      final seen = panel.client.read(key)!;
      expect(seen.value, 777,
          reason: 'panel ${panel.index} must hold the value the plant '
              'published, not a placeholder the fixture invented');
      expect(seen.quality, Quality.good,
          reason: 'and at the quality the link gave it — a fixture that '
              'launders qualities would make every quality assertion in the '
              'seven rows a claim about the fixture');
    }

    // Both sessions are held, nobody was thrown off, and nothing escaped an
    // error handler while the pipe stood.
    expect(fixture.sessionCount, 2);
    expect(fixture.evictions, isEmpty,
        reason: 'a healthy two-panel pipe evicted somebody during setUp — '
            'whatever did that will fire inside every row too');
    expect(fixture.heartbeatReaps, isEmpty,
        reason: 'the 07-08b pump regression arm: a healthy panel is never '
            'reaped for silence');
    expect(fixture.gatewayComplaints, isEmpty,
        reason: 'the gateway complained while nothing was being injected: '
            '${fixture.gatewayComplaints}');

    // The explicit teardown, in the argued order — panels, gateway, proxies,
    // plant — timed, and then the descriptor table read back at baseline.
    // The addTearDown registrations replay over this as no-ops.
    final tearDownClock = Stopwatch()..start();
    await fixture.dispose();
    tearDownClock.stop();
    print('PROBE fixture teardown wall clock = '
        '${tearDownClock.elapsedMilliseconds} ms');

    if (canCount) {
      final settled = await untilSocketsSettle(baseline);
      print('PROBE sockets: baseline=$baseline settled=$settled');
      expect(settled, lessThanOrEqualTo(baseline),
          reason: 'the pipe tore down and the descriptor count did not come '
              'back to this case\'s own baseline — the fixture leaks a '
              'socket per case, and the seven rows would pay it seven times '
              'before F23 blamed the gateway for it');
    } else {
      // Windows: lsof-style counting is unavailable; the probe still proved
      // establishment, delivery, and an orderly teardown above.
      print('PROBE sockets: skipped — $openSocketCountSkipReason');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
