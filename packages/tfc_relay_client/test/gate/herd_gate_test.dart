/// The herd family: the rows that need more than one panel on one gateway.
///
/// **F10 — Server process restart.** The catalogue's expectation is that the
/// client treats it as F1; server rebuilds subscription state from client's
/// re-subscribe (server holds no obligation to remember clients). F10 is F11
/// with N=1 and it ships beside it because it is F11's debugging step: a herd
/// that fails for a reason one panel would have shown is a bad afternoon.
///
/// **What the restart in this file is, said plainly.** It is an **in-process
/// `RelayServer.close()` followed by a rebind on the same port**, not a process
/// boundary. What that proves is the whole operational content of the row: the
/// epoch changes, the gateway's subscription registry starts empty, and the
/// page that comes back was rebuilt purely from the panel's own re-subscribe.
/// What it does **not** prove is anything about process startup, port reuse
/// across a `SIGKILL`, or a listener socket surviving into a child. Those need
/// a real process boundary, which needs a docker-compose tier this project does
/// not have, and they belong to the Phase 11 chaos soak. The deviations
/// registry carries the entry (`f_row_registry.dart`, row F10) and it points
/// here.
///
/// **F11 — Thundering herd.** all resubscribe; server tick cost stays bounded;
/// no client starves (fairness across resync bursts). Two halves of this row
/// already existed and neither is the row. `fanout_test.dart:80-120` runs fifty
/// clients through the gateway's encode-once path and proves the **server-cost**
/// half — one encode serves every session watching the same key — but those
/// clients are in-memory `Plant` sessions with no sockets, so they cannot
/// resubscribe, cannot starve and cannot be evicted. That half is cited here
/// and deliberately **not** re-run over sockets: it is measured where it is
/// cheap and it is measured correctly. What this file adds is the other half,
/// which is only expressible over real sockets: twenty real panels, a real
/// gateway restart, and the three things a herd can do wrong.
///
/// **F12 — Slow client / backpressure.** server buffer for that client stays
/// bounded via conflation (§7.6); other clients unaffected. The second clause
/// is this file's; the first is asserted from the gateway's side in
/// `backpressure_test.dart:327-393`, and asserted here as the panel-visible
/// consequence — the throttled panel keeps arriving at the *latest* value and
/// is never thrown off.
///
/// **G2 — Late joiner under sustained loss.** A client subscribing while the
/// link is throttled to 100 kbit and flapping must still reach a fresh,
/// complete view — the snapshot must not be starved by telemetry. Assert the
/// `subscribe` response (priority lane) beats the `u` backlog.
///
/// **Why the descriptor clause is not inside F11.** `openSocketCount` cannot
/// answer on Windows — there is no `/proc/self/fd` and no `lsof`
/// (`fd_count.dart:40-55`) — so an arm that measures descriptors has to skip
/// there. Putting that skip on F11 itself would make the row green-by-skip on
/// one column of the matrix, which is precisely the "capability switched off"
/// failure the manifest's own no-silent-skip sweep exists to catch one level
/// up. So F11 runs everywhere and judges everything a panel can observe, and
/// the descriptor measurement lives in the supporting control arm below, whose
/// per-test skip carries `openSocketCountSkipReason` verbatim.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
// The gateway's own config, for one number only: the heartbeat deadline the
// idle-liveness case has to outlast. Read rather than restated, because a
// window fitted to a literal stops spanning the deadline the moment somebody
// changes the default and nothing says so. `flap_gate_test.dart:97` sets the
// precedent for reaching into the server package from a gate case.
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../support/fault_fixture.dart';
import '../support/gate_fixture.dart';

/// The page every case in this file drives, as `ST101.CNnn.MOT01.setpoint`.
///
/// The plant's own naming (`AREAnn.DEVnn.SUBnn`), so a page reads like a page
/// rather than like `key0…key39` — `resync_gate_test.dart:97-104`'s rule.
List<String> _pageKeys(int n) => [
      for (var i = 1; i <= n; i++)
        'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.setpoint',
    ];

/// How many keys the restart rows put on a page.
///
/// Four, and small on purpose. F9 already owns the every-key-on-a-wide-page
/// clause over a forty-key page, and it argues there why forty is the number
/// that puts a measurable window between the `hello` answer and the snapshot.
/// The restart rows are about *how many panels* come back, not about how wide
/// a page is, and a forty-key page times twenty panels is thirty-two thousand
/// values through one gateway per restart for no additional evidence.
const int _restartPage = 4;

/// What the plant holds before a restart, and after it.
///
/// Two distinct numbers so that "the panel came back" and "the panel is
/// holding what the plant holds *now*" are different observations. A case that
/// re-read the same value could not tell a resynced page from a cache that was
/// never cleared, which is F10's whole subject.
const int _beforeRestart = 1300;
const int _afterRestart = 2500;

/// How long the gateway stays down during the herd's restart.
///
/// **Two seconds, and the number is doing work.** A gateway that is back
/// before anybody's first retry never asks the backoff to spread anything, and
/// F11 would then measure an empty mechanism — every panel would reconnect on
/// its first attempt and the fairness spread would be the accept loop's, not
/// the jitter's.
///
/// Two seconds is also where the attempt bound below discriminates. At 40 ms
/// base and a 2 s cap the schedule walks 20, 40, 80, 160, 320, 640, 1000 ms of
/// expected waiting, and each attempt also costs a dial into a port nobody is
/// listening on — so a panel that backs off makes about seven attempts in the
/// window. A panel whose cap equals its base makes one every 60 ms, which is
/// about thirty-three. At 300 ms the two are four and five, which is not a
/// result; the dial cost dominates a short window and hides the schedule.
const Duration _herdDowntime = Duration(seconds: 2);

/// The backoff schedule the attempt bound is computed from, restated here
/// rather than read off the config the fixture builds.
///
/// 07-04's lesson, and `resync_gate_test.dart:79-88` carries it in the same
/// words: a ceiling that recomputed itself from whatever the client was
/// actually handed would rise to meet a client that had been made to hammer,
/// which is the one failure it exists to catch. These two must move with
/// `faultClientConfig`'s, and the arm says so if they stop agreeing.
const Duration _backoffBase = Duration(milliseconds: 40);
const Duration _backoffCap = Duration(seconds: 2);

/// What one attempt costs beyond its backoff wait: a dial into a port nobody
/// is listening on, through a proxy that has to fail its own upstream connect
/// first. Measured at 30-60 ms on macOS; 40 ms is the conservative end, because
/// a *smaller* overhead makes the ceiling larger and the bound weaker only in
/// the direction that cannot produce a false red.
const Duration _attemptOverhead = Duration(milliseconds: 40);

/// What one panel's establishment costs once the gateway is listening again:
/// a dial, a WebSocket handshake, a `hello` round trip and a snapshot over
/// loopback. Measured at 51-112 ms across the runs in 07-08-SUMMARY.
const Duration _establish = Duration(seconds: 1);

/// How far apart the first and last panel of the herd may converge.
///
/// **Derived from the mechanism, not fitted to the measurement.** Once the
/// gateway is listening again, the longest any panel can wait is one draw from
/// its current backoff window, and that window is bounded by [_backoffCap] —
/// two seconds. The luckiest panel is one whose retry lands the instant the
/// gateway returns, at nearly zero. So the honest ceiling on the spread is
/// **one capped draw plus one establishment**, which is what this is.
///
/// Measured over six runs on this machine: 1599, 1664, 1704, 1710, 1813 and
/// 1899 ms — clustered just under the cap, which is the shape twenty
/// independent uniform draws from `[0, 2 s)` produce. The band sits 1.58x above
/// the observed worst and it is not fitted to it; the arithmetic above is what
/// sets it, and a change to `faultClientConfig`'s cap has to move it.
///
/// **What this catches and what it does not.** It catches a straggler: one
/// panel waiting a whole capped draw longer than the rest of the herd for the
/// same event, which is "no client starves (fairness across resync bursts)"
/// and which an averaging assertion would hide inside nineteen fast panels.
/// It does **not** catch a backoff that stopped spreading — measured, see
/// 07-08-SUMMARY's sabotage table: collapsing the cap onto the base makes all
/// twenty converge at the same millisecond, so the spread goes to **zero** and
/// a ceiling is structurally blind to it. That mutation is caught by the
/// attempt bound below, which is why both arms are here.
final Duration _fairnessBand = _backoffCap + _establish;

/// How long the idle-liveness case leaves a healthy panel alone.
///
/// **Twenty seconds, because six is the number being disproved.** The
/// gateway's default `heartbeatDeadline` is 6 s, so a window of one deadline
/// would be a coin toss and a window of two would catch a single reap. Twenty
/// spans three of them: on the build this case was written against it produced
/// three reaps and three redials, and after the pump it produces none. Longer
/// buys nothing the third cycle has not already shown, and the gate lane pays
/// for every second of it.
const Duration _idleSilence = Duration(seconds: 21);

/// How often the idle window is sampled.
///
/// Three seconds, which is 07-08-SUMMARY deviation 3's own sampling interval —
/// half a deadline, so no reap-and-redial cycle can fit between two samples and
/// leave the ledger looking quiet.
const Duration _idleSample = Duration(seconds: 3);

/// How wide the pages the slow-link rows drive are.
///
/// Sixty keys at the tick rate is about 54 kB/s of telemetry, which is four
/// times F12's 10 kB/s throttle and four times G2's 12.5 kB/s. The page has to
/// exceed the link by a clear multiple or the throttle is not the bottleneck
/// and the row measures an unthrottled link with a lever armed on it.
const int _busyPage = 60;

/// How long every rate in this file is measured over.
///
/// **Three and a half seconds, and it is a floor rather than a preference.**
/// `DelayLine`'s token bucket banks up to one second of burst
/// (`delay_line.dart:620-670`), so a window shorter than about two seconds
/// measures the bank rather than the rate, and the proxy's own doc sets three
/// seconds as the minimum with a band of one twentieth. Three and a half is
/// that minimum with the measurement's own scheduling slop on top. Both rows
/// here use it, which is why it is one constant.
const Duration _rateWindow = Duration(milliseconds: 3500);

/// F12's throttle, from the catalogue's own injection: `throttle(10KB/s)`.
const int _f12Throttle = 10 * 1000;

/// G2's throttle, from its own row: 100 kbit/s, which is 12500 bytes.
const int _g2Throttle = 100 * 1000 ~/ 8;

/// The flap G2 runs the link at while the late joiner arrives.
///
/// **The up half has to be longer than a snapshot.** G2's page is small
/// (`_g2Page`) precisely so its snapshot fits: at 12.5 kB/s a twelve-key
/// snapshot is roughly a hundred milliseconds of wire time, and a 200 ms up
/// window — F3's flap — would cut the handshake more often than not and the
/// row would be measuring whether a dial can complete rather than whether a
/// snapshot beats a backlog. A second and a half up against 300 ms down is a
/// link that is genuinely flapping and on which a snapshot is genuinely
/// possible, which is the condition the row describes.
const Duration _g2FlapUp = Duration(milliseconds: 1500);
const Duration _g2FlapDown = Duration(milliseconds: 300);

/// The page G2's late joiner asks for.
const int _g2Page = 12;

/// How long the late joiner has to reach a complete view.
///
/// Generous on purpose: the row's claim is that the snapshot is **not
/// starved**, not that it is fast. Eight seconds covers a dial that lands in a
/// down half, the backoff that follows it, a second dial, and a snapshot
/// metered at 12.5 kB/s — five flap cycles' worth. What it does not cover is a
/// snapshot queued behind a telemetry backlog on a link this slow, which is
/// what the row forbids and what would take tens of seconds.
const Duration _g2Budget = Duration(seconds: 8);

/// Drives every key on [keys] to a fresh value on every tick, until cancelled.
///
/// The plant has to be genuinely busy for a throttle to bite: a quiet page
/// produces the `badStale` follow-up and then nothing, and a link throttled
/// below the rate of nothing is not throttled. The counter makes each value
/// distinct so a case can tell the latest from a queued one.
Timer _drivePlant(FakeStateMan plant, List<String> keys) {
  var n = 0;
  return Timer.periodic(const Duration(milliseconds: 50), (_) {
    n++;
    plant.setValues({for (final key in keys) key: 1000 + n});
  });
}

/// Frames per second arriving at [panel] over [window].
///
/// Counted off the seam, which is the panel's own inbound stream after the
/// lens — the closest thing to "what the operator's screen is being fed" this
/// package can read without asking the client to report on itself.
Future<double> _cadence(GateClient panel, Duration window) async {
  final before = panel.seam.inbound.length;
  await Future<void>.delayed(window);
  final frames = panel.seam.inbound.length - before;
  return frames * 1000 / window.inMilliseconds;
}

/// How many attempts a schedule that is **never reset** fits into [window].
///
/// Full jitter draws uniformly from `[0, min(cap, base * 2^n))`, so attempt *n*
/// waits half that window on average, and each attempt also costs a dial.
/// `resync_gate_test.dart:146-157`'s function, restated here for the same
/// reason its constants are: two files that shared it would share a mutation.
///
/// **A full-jitter schedule has no hard ceiling** — every draw can come back
/// near zero — so the only honest bound is this expectation with a margin, and
/// the margin is applied at the call site where it is visible.
int _attemptsIn(Duration window, Duration base, Duration cap, Duration cost) {
  var elapsed = 0;
  var attempts = 0;
  var next = base.inMilliseconds;
  while (elapsed < window.inMilliseconds) {
    attempts++;
    elapsed += next ~/ 2 + cost.inMilliseconds;
    final doubled = next * 2;
    next = doubled > cap.inMilliseconds ? cap.inMilliseconds : doubled;
  }
  return attempts;
}

void main() {
  group('the fixture can see what it is about to measure', () {
    test('the herd fixture holds N real panels, and the counters can see them',
        () async {
      final keys = _pageKeys(4).toSet();
      final n = herdSize;
      final baseline = openSocketCount();

      // **Registered before the fixture, so it runs after it.** `addTearDown`
      // is last-registered-first, and `gateFixture` registers four groups of
      // teardowns of its own while it is being awaited — so a leak check
      // written on the line after the fixture call runs *first*, against a
      // herd that is still fully connected. Measured, the first time this was
      // written that way: six descriptors, two listeners in LISTEN and two
      // pairs ESTABLISHED, reported as a leak by a check that had simply run
      // too early.
      addTearDown(() async {
        final settled = await untilSocketsSettle(baseline);
        print('herd control arm: open sockets settled at $settled against a '
            'baseline of $baseline');
        expect(settled, lessThanOrEqualTo(baseline),
            reason: 'the herd released its panels, its gateway and its proxy '
                'and the process is still holding ${settled - baseline} more '
                'socket descriptors than it did before the fixture was built. '
                'TIME_WAIT is not a descriptor (`fd_count.dart:28-31`, '
                'measured over 1245 system-wide entries), so this is a socket '
                'nobody closed');
      });

      final fixture = await gateFixture(
        keys: keys,
        seed: (plant) => plant.setValues({for (final key in keys) key: 1}),
      );
      final held = openSocketCount();

      print('herd control arm: ${fixture.clients.length} panels; the gateway '
          'holds ${fixture.sessionCount} sessions; open sockets $baseline -> '
          '$held (delta ${held - baseline})');

      expect(fixture.clients.length, n,
          reason: 'the fixture built ${fixture.clients.length} panels against '
              'a declared herd size of $n. Every number this file reports is '
              'per-herd, so a fixture that quietly built one panel would make '
              'the herd rows pass as single-client rows wearing herd names');

      expect(fixture.sessionCount, n,
          reason: 'the gateway is holding ${fixture.sessionCount} sessions '
              'against $n panels this fixture built. Every leak arm in this '
              'file counts sessions, so a counter that cannot see $n held '
              'connections cannot see a leak either — it would report zero '
              'before and zero after and call that a clean teardown');

      expect(held - baseline, greaterThanOrEqualTo(n),
          reason: 'standing up $n panels moved the open-socket count by '
              '${held - baseline}, which is fewer than one descriptor per '
              'panel. Each of them costs four in this process — the panel\'s '
              'socket, the proxy\'s accepted socket, the proxy\'s upstream '
              'socket and the gateway\'s accepted socket — so a delta below '
              '$n means the count is not seeing this fixture\'s connections '
              'at all, and the leak assertion built on it is vacuous');
    },
        skip: canCountOpenSockets ? null : openSocketCountSkipReason);
  });

  group('F10 — the gateway goes away and comes back', () {
    test('F10: a gateway that comes back on the same port is an ordinary '
        'reconnect', () async {
      final keys = _pageKeys(_restartPage).toSet();
      final fixture = await gateFixture(
        clients: 1,
        keys: keys,
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final panel = fixture.clients.single;

      // Anti-vacuity: the page was carrying the plant's pre-restart values
      // before the gateway was touched. A page that never held them cannot be
      // shown to have been rebuilt.
      expect(
          [for (final key in keys) panel.client.read(key)?.value],
          everyElement(_beforeRestart),
          reason: 'the panel did not hold the pre-restart value for every key, '
              'so "the page came back" below would be comparing the plant '
              'against keys that had never arrived in the first place');

      final epochBefore = fixture.server.sessions.sessions.single.epoch;
      final handlesBefore = fixture.server.handles.size;
      expect(handlesBefore, keys.length,
          reason: 'the gateway minted $handlesBefore handles for a page of '
              '${keys.length} keys. The handle table is keyed by key '
              '(`handle_table.dart:75`), so this is the number the rebuild is '
              'compared against and it has to be the page size before the '
              'comparison means anything');

      final retries = await fixture.restartGateway();

      // Read immediately, before the panel can have redialled: this is the
      // clause. `server` is the replacement — the getter re-reads the slot —
      // and the replacement has never heard of anybody.
      final sessionsAtRebind = fixture.sessionCount;
      final handlesAtRebind = fixture.server.handles.size;

      // The plant moves to a value it never held while the old gateway was
      // up, so a cache that survived the restart is a cache holding the wrong
      // number rather than a cache holding a stale-but-equal one.
      fixture.served
          .setValues({for (final key in keys) key: _afterRestart});

      final at = await fixture.untilAllRead(keys.first, _afterRestart);
      await until(
          'the whole page to agree with the plant after the restart',
          () => keys.every(
              (key) => panel.client.read(key)?.value == _afterRestart));

      final epochAfter = fixture.server.sessions.sessions.single.epoch;

      print('F10: rebind took $retries retries on port ${fixture.port}; the '
          'replacement held $sessionsAtRebind sessions and '
          '$handlesAtRebind handles at the instant it came up, '
          '${fixture.sessionCount} and ${fixture.server.handles.size} after '
          'the panel resubscribed; epoch $epochBefore -> $epochAfter; the '
          'panel reconverged in ${at.single} ms');

      expect(sessionsAtRebind, 0,
          reason: 'the replacement gateway came up already holding '
              '$sessionsAtRebind sessions. The row\'s clause is that the '
              'server holds no obligation to remember clients, and a gateway '
              'that started with a session in its registry would be serving a '
              'subscription nobody had asked it for — a stale subscription '
              'that looks live, which is T-07-28 exactly');
      expect(handlesAtRebind, 0,
          reason: 'the replacement gateway came up holding $handlesAtRebind '
              'handles. The handle table is the other half of the same '
              'memory: a table that survived the restart would let a `u` frame '
              'name a handle the new session never announced');

      expect(fixture.sessionCount, 1,
          reason: 'the panel reached its post-restart value but the gateway is '
              'holding ${fixture.sessionCount} sessions rather than one. The '
              'page was therefore not rebuilt from this panel\'s '
              're-subscribe, or the panel is holding two');
      expect(fixture.server.handles.size, keys.length,
          reason: 'the rebuilt page holds ${fixture.server.handles.size} '
              'handles against ${keys.length} keys. The subscription was '
              'rebuilt purely from the panel\'s re-subscribe, so the count has '
              'to be the page size — more means something was remembered');

      expect(epochAfter, isNot(epochBefore),
          reason: 'the replacement gateway minted the same epoch as the one it '
              'replaced ($epochAfter). The epoch is what tells the panel that '
              'the establishment it is talking to is a different one, and two '
              'gateways sharing an epoch is how a frame from the first is '
              'accepted by a client talking to the second');

      expect(panel.observedClose.closeCode, isNull,
          reason: 'the panel is sitting on a closed socket '
              '(${panel.observedClose}) after a restart it was supposed to '
              'have recovered from');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway threw the panel off during a restart: '
              '${fixture.evictions}. A restart drains with 4002 and that is '
              'not counted here — anything in this list is a heartbeat, a '
              'credential or a send buffer verdict, and none of them should '
              'fire because a gateway was replaced');
      expect(panel.client.complaints, isEmpty,
          reason: 'the panel complained during the restart: '
              '${panel.client.complaints}. A gateway coming back on the same '
              'port is an ordinary reconnect and F1 makes no complaints');
      expect(fixture.gatewayComplaints, isEmpty,
          reason: 'the gateway reported errors across the restart: '
              '${fixture.gatewayComplaints}');
    });
  });

  group('F11 — twenty of them at once', () {
    test('F11: twenty panels come back together without anybody starving',
        () async {
      final keys = _pageKeys(_restartPage).toSet();
      final fixture = await gateFixture(
        keys: keys,
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final n = fixture.clients.length;

      expect(fixture.sessionCount, n,
          reason: 'the herd is $n panels and the gateway is holding '
              '${fixture.sessionCount} sessions before anything was injected');
      final handlesBefore = fixture.server.handles.size;
      final attemptsBefore = [for (final one in fixture.clients) one.attempts];

      final retries = await fixture.restartGateway(downtime: _herdDowntime);
      final sessionsAtRebind = fixture.sessionCount;

      fixture.served
          .setValues({for (final key in keys) key: _afterRestart});

      final at = await fixture.untilAllRead(keys.first, _afterRestart);
      final spread = at.reduce((a, b) => a > b ? a : b) -
          at.reduce((a, b) => a < b ? a : b);
      final attempts = [
        for (var i = 0; i < n; i++)
          fixture.clients[i].attempts - attemptsBefore[i],
      ];
      final totalAttempts = attempts.reduce((a, b) => a + b);
      final ceiling = _attemptsIn(
              _herdDowntime, _backoffBase, _backoffCap, _attemptOverhead) *
          2;

      print('F11: $n panels, ${_herdDowntime.inMilliseconds} ms of downtime, '
          '$retries rebind retries; convergence instants (ms from the '
          'restart) $at; spread $spread ms against a '
          '${_fairnessBand.inMilliseconds} ms band; reconnect attempts per '
          'panel $attempts (total $totalAttempts, ceiling '
          '${ceiling * n} for a schedule that never resets)');

      // ALL RESUBSCRIBE. Not `isReady`, which a panel reaches before its
      // snapshot lands: every one of them has to be holding a value the plant
      // set *after* the gateway it was talking to stopped existing.
      for (final one in fixture.clients) {
        expect(
            [for (final key in keys) one.client.read(key)?.value],
            everyElement(_afterRestart),
            reason: 'panel ${one.index} came back holding '
                '${[for (final key in keys) one.client.read(key)?.value]} '
                'against a plant at $_afterRestart. The row\'s first clause is '
                '"all resubscribe", and a panel that reconnected without '
                'resyncing is the silent-permanent-staleness case with twenty '
                'chances to happen instead of one');
      }

      // FAIRNESS. The spread, not the mean: nineteen panels back in 200 ms and
      // one back in nine seconds is the starvation this row forbids, and an
      // averaging assertion reports it as a healthy herd.
      expect(spread, lessThan(_fairnessBand.inMilliseconds),
          reason: 'the first panel converged at ${at.reduce((a, b) => a < b ? a : b)} '
              'ms and the last at ${at.reduce((a, b) => a > b ? a : b)} ms, a '
              'spread of $spread ms against a '
              '${_fairnessBand.inMilliseconds} ms band. One panel waiting far '
              'longer than the herd for the same event is what "no client '
              'starves (fairness across resync bursts)" forbids');

      // THE MECHANISM THAT SPREADS THE HERD. Full jitter is why twenty panels
      // do not arrive as one connection flood, and the bound is on the attempt
      // count rather than on an interval because a full-jitter draw has no
      // floor — 07-06 deviation 3 measured four consecutive last-intervals at
      // 848, 264, 753 and 419 ms and concluded that any band tight enough to
      // catch a broken schedule also catches a legitimate low draw.
      expect(totalAttempts, lessThan(ceiling * n),
          reason: 'the herd made $totalAttempts reconnect attempts across '
              '${_herdDowntime.inMilliseconds} ms of downtime, against a '
              'ceiling of ${ceiling * n} for $n panels on a schedule that is '
              'never reset. This is the self-inflicted connection flood '
              '(T-07-25): the backoff is the only thing between a gateway '
              'restart and every panel in the plant dialling it at once');

      // NO LEAKS. The descriptor half is the control arm's, for the reason the
      // library doc gives; what is asserted here is the gateway's own memory.
      expect(sessionsAtRebind, 0,
          reason: 'the replacement gateway came up holding $sessionsAtRebind '
              'sessions');
      expect(fixture.sessionCount, n,
          reason: 'the gateway is holding ${fixture.sessionCount} sessions at '
              'steady state against $n panels. More than $n means a session '
              'from before the restart is still registered — the gateway '
              'remembering a client it has no obligation to remember, and '
              'ticking for a socket nobody is reading');
      expect(fixture.server.handles.size, handlesBefore,
          reason: 'the handle table holds ${fixture.server.handles.size} '
              'handles after the restart against $handlesBefore before it. '
              'The table is keyed by key and not by session, so $n panels on '
              'one page cost ${keys.length} handles however many times they '
              'reconnect — a number that grew with the herd would be a '
              'per-client leak in the one structure that is supposed to be '
              'shared');

      // NO VERDICT MISFIRES. ROADMAP criterion 4's first clause.
      expect([for (final one in fixture.clients) one.observedClose.closeCode],
          everyElement(isNull),
          reason: 'these panels are sitting on closed sockets after the herd '
              'reconverged: ${fixture.observedCloses}');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway threw ${fixture.evictions.length} panels off '
              'while twenty of them were reconnecting: ${fixture.evictions}. '
              'A herd arriving at once is load, not misbehaviour, and a '
              'heartbeat or backpressure verdict firing here is the gateway '
              'punishing panels for the gateway\'s own restart');

      // ESCAPED ASYNC ERRORS. Twenty reconnecting panels is exactly the shape
      // that leaks one.
      expect(fixture.gatewayComplaints, isEmpty,
          reason: 'the gateway reported '
              '${fixture.gatewayComplaints.length} errors while the herd '
              'reconnected: ${fixture.gatewayComplaints}');
      for (final one in fixture.clients) {
        expect(one.client.complaints, isEmpty,
            reason: 'panel ${one.index} complained during the herd restart: '
                '${one.client.complaints}');
      }

      // SERVER COST is cited, not re-run. `fanout_test.dart:80-120` drives
      // fifty sessions through the gateway's encode-once path and proves one
      // encode serves every session watching the same key. Those sessions have
      // no sockets, which is why this file exists — and it is also why
      // re-running the encode-once claim over twenty real sockets would
      // measure loopback rather than the property.
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('the gateway\'s unauthenticated slots, measured', () {
    test('a session that never says hello holds a slot until the reaper takes '
        'it', () async {
      final keys = _pageKeys(1).toSet();
      final fixture = await gateFixture(
        clients: 1,
        keys: keys,
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final authenticated = fixture.sessionCount;

      // Real WebSocket upgrades that complete and then say nothing. A raw TCP
      // connect would not do: the gateway mints a `RelaySession` at the
      // upgrade, so a socket that never became a WebSocket never took a slot.
      const silent = 4;
      final quiet = <WebSocketChannel>[];
      for (var i = 0; i < silent; i++) {
        final ws =
            WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${fixture.port}'));
        await ws.ready;
        ws.stream.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
        quiet.add(ws);
      }
      addTearDown(() async {
        for (final ws in quiet) {
          await ws.sink.close().catchError((Object _) {});
        }
      });

      final held = Stopwatch()..start();
      await until(
        'the gateway to register all $silent silent sockets as sessions',
        () => fixture.unauthenticatedSlots >= silent,
      );
      final peak = fixture.unauthenticatedSlots;

      // The only assertion: the reaper does eventually take them. The ceiling
      // itself is not enforced — 07-CONTEXT orchestrator ruling 4 — and the
      // two numbers printed below are the input to whether `maxSessions`
      // belongs in `ServerConfig` at all.
      await until(
        'the heartbeat reaper to take every unauthenticated session',
        () => fixture.unauthenticatedSlots == 0,
        budget: const Duration(seconds: 20),
      );
      held.stop();

      print('unauthenticated slots: $peak sockets completed the WebSocket '
          'upgrade and never said hello, held beside $authenticated '
          'authenticated sessions; the reaper took the last of them '
          '${held.elapsedMilliseconds} ms after they connected, against a '
          '6000 ms heartbeat deadline. The emergent bound is connect rate x '
          'that deadline; nothing enforces a ceiling and nothing here asks '
          'for one');

      expect(peak, silent,
          reason: 'the gateway registered $peak unauthenticated sessions for '
              '$silent silent sockets. If it registers fewer than one slot per '
              'socket then the number this arm reports is not the bound it '
              'claims to be measuring');
      expect(fixture.sessionCount, authenticated,
          reason: 'the reaper took the silent sessions and left '
              '${fixture.sessionCount} rather than the $authenticated '
              'authenticated ones. A reaper that also took the panel would be '
              'reaping on the wrong predicate');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('the idle panel, and the reaper that used to take it', () {
    test('a panel that only watches a page is never thrown off for silence',
        () async {
      final keys = _pageKeys(1).toSet();
      final fixture = await gateFixture(
        clients: 1,
        keys: keys,
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final panel = fixture.clients.single;

      // ANTI-VACUITY, first half: the window has to be longer than the
      // gateway's own patience or the case proves nothing. A run that finished
      // inside one deadline would be green on the build that reaps every
      // healthy panel, which is the build this case was written against.
      final deadline = ServerConfig().heartbeatDeadline;
      expect(_idleSilence, greaterThan(deadline * 2),
          reason: 'the silence this case holds ($_idleSilence) does not span '
              'two of the gateway\'s heartbeat deadlines ($deadline), so a '
              'reaper that takes every panel once a deadline could go '
              'unobserved and the row would be green about nothing');

      // The baseline is taken *after* readiness, so the establishment's own
      // dial and its transitions are not counted as churn. Everything below is
      // a delta against this instant.
      final attemptsAtRest = panel.attempts;
      final dialsAtRest = panel.seam.dials;
      final statesAtRest = panel.states.length;

      // Sampled rather than settled, and the shape is 07-08-SUMMARY deviation
      // 3's own measurement inverted: that one printed sessions 1, 0, 1, 1, 1
      // and evictions 0, 1, 1, 1, 2 at three-second intervals. A single read
      // after twenty seconds would show one reap where there were three, and
      // the table is what makes a failure here diagnosable instead of merely
      // red.
      final ledger = <String>[];
      final samples = _idleSilence.inMilliseconds ~/ _idleSample.inMilliseconds;
      for (var i = 1; i <= samples; i++) {
        await Future<void>.delayed(_idleSample);
        ledger.add('t=${i * _idleSample.inSeconds}s  '
            'sessions=${fixture.sessionCount}  '
            'reaps=${fixture.heartbeatReaps.length}  '
            'attempts=${panel.attempts - attemptsAtRest}  '
            'dials=${panel.seam.dials - dialsAtRest}');
      }
      final table = ledger.join('\n  ');
      final beats = panel.client.debugHeartbeatsSent;
      print('idle liveness: one panel, subscribed, silent for '
          '${_idleSilence.inSeconds} s; the pump sent $beats heartbeats '
          'against a ${deadline.inMilliseconds} ms deadline\n  $table');

      // ANTI-VACUITY, second half, and the arm that matters most: every
      // assertion below is a statement that *nothing happened*, and nothing
      // happening is also what a fixture that never connected looks like. The
      // band is arithmetic — one beat per third of a deadline over the window
      // — with generous slack, because this is a liveness claim and not a
      // cadence measurement. Both ends are load-bearing: too few and the pump
      // is not running, too many and it is beating faster than its own floor.
      final expectedBeats = _idleSilence.inMilliseconds ~/ (deadline ~/ 3).inMilliseconds;
      expect(beats, greaterThanOrEqualTo(expectedBeats ~/ 2),
          reason: 'the panel sent $beats heartbeats in '
              '${_idleSilence.inSeconds} idle seconds, against roughly '
              '$expectedBeats expected at a third of the gateway\'s '
              '$deadline deadline. Everything below asserts that nothing '
              'happened, and on a panel that is not beating "nothing '
              'happened" is exactly what a broken pump looks like right up '
              'until the first reap');
      expect(beats, lessThanOrEqualTo(expectedBeats * 2),
          reason: 'the panel sent $beats heartbeats where about '
              '$expectedBeats were due. A pump beating well above its derived '
              'period is a panel spending the gateway\'s tick budget on '
              'liveness frames, multiplied by every screen in the factory');

      // THE ROW. Three ways of asking the same question, because each of them
      // is the one a different regression would move.
      expect(fixture.heartbeatReaps, isEmpty,
          reason: 'the gateway reaped a healthy, subscribed panel for silence '
              '${fixture.heartbeatReaps.length} times in '
              '${_idleSilence.inSeconds} seconds:\n  $table\n\n'
              'Every panel in the plant watches a page and writes nothing, so '
              'this is every panel, for ever, at a full page resync per cycle '
              '— and it is invisible from outside because the panel comes '
              'straight back. The client owes the gateway a periodic frame: '
              'that is what HeartbeatPump is for, and what CLAUDE.md means by '
              '"server pings + app heartbeat"');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway threw the panel off for some reason of its own '
              'over an idle window: ${fixture.evictions}. Nothing was '
              'injected, nothing was throttled and nothing was written — a '
              'close here is the gateway deciding against a client that is '
              'behaving perfectly');
      expect(panel.attempts, attemptsAtRest,
          reason: 'the panel redialled ${panel.attempts - attemptsAtRest} '
              'times while doing nothing but watching a page:\n  $table\n\n'
              'A redial is a resync, and a resync is the whole page arriving '
              'again — on this link that is invisible, and on a plant LAN '
              'carrying every screen in the factory it is the load the '
              'heartbeat exists to prevent');
      expect(panel.seam.dials, dialsAtRest,
          reason: 'the panel opened ${panel.seam.dials - dialsAtRest} new '
              'sockets over an idle window. `attempts` counts intent and this '
              'counts sockets that actually came up; a regression that moved '
              'one and not the other would be worth looking at closely');
      expect(panel.states.skip(statesAtRest), isEmpty,
          reason: 'the link left `ready` and came back '
              '${panel.states.skip(statesAtRest)} while nothing was happening '
              'to it. The operator sees this as the connection indicator '
              'flickering on a healthy plant, which teaches them to ignore it');

      expect(fixture.gatewayComplaints, isEmpty,
          reason: 'the gateway logged errors over an idle window: '
              '${fixture.gatewayComplaints}');
      expect(panel.client.complaints, isEmpty,
          reason: 'the panel complained over an idle window: '
              '${panel.client.complaints}');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('F12 — one slow panel', () {
    test('F12: one throttled panel does not slow anybody else', () async {
      final keys = _pageKeys(_busyPage);
      // One proxy per panel: `throttleBytesPerSec` reaches every pair its proxy
      // carries, so two panels behind one proxy cannot be throttled
      // separately. See `gateFixture`'s `proxyPerClient` doc — a case that
      // believed it had throttled one of two panels sharing a proxy would have
      // throttled both and then asserted that neither was affected.
      final fixture = await gateFixture(
        clients: 2,
        proxyPerClient: true,
        keys: keys.toSet(),
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final slow = fixture.clients[0];
      final fast = fixture.clients[1];

      final driver = _drivePlant(fixture.served, keys);
      addTearDown(driver.cancel);

      // Recorders on one key, so the values each panel was actually shown can
      // be compared against the values the plant actually produced. A reading
      // taken afterwards cannot tell conflation from a queue — both end up at
      // the latest value, and the difference is entirely in what happened on
      // the way there.
      final slowSaw = <num>[];
      final plantSaw = <num>[];
      // Nulls are dropped rather than recorded. A resync blanks the page
      // before it refills it (`resync_engine.dart:108-116`, and G4 observed
      // the `[1300, null, 1500]` trace end to end), so a null on this stream is
      // "the panel is between establishments", not a value the operator was
      // shown. Counting it would make the ordering assertion below fail on a
      // reconnect rather than on a queue.
      final slowTap = slow.client.subscribe(keys.first).listen((value) {
        final seen = value.value;
        if (seen is num) slowSaw.add(seen);
      });
      addTearDown(slowTap.cancel);
      final plantTap = fixture.served.subscribe(keys.first).listen((value) {
        final seen = value.value;
        if (seen is num) plantSaw.add(seen);
      });
      addTearDown(plantTap.cancel);

      final fastBefore = await _cadence(fast, _rateWindow);
      final slowBefore = await _cadence(slow, _rateWindow);

      slow.proxy.throttleBytesPerSec = _f12Throttle;
      final slowFrom = slowSaw.length;
      final plantFrom = plantSaw.length;

      final fastAfter = await _cadence(fast, _rateWindow);
      final slowAfter = await _cadence(slow, _rateWindow);

      final slowDuring = slowSaw.sublist(slowFrom);
      final plantDuring = plantSaw.sublist(plantFrom);

      final drift = (fastAfter - fastBefore).abs() / fastBefore;
      print('F12: over ${_rateWindow.inMilliseconds} ms windows — the '
          'unthrottled panel ran at ${fastBefore.toStringAsFixed(1)} frames/s '
          'before the throttle and ${fastAfter.toStringAsFixed(1)} after '
          '(${(drift * 100).toStringAsFixed(1)}% drift); the throttled panel '
          'went ${slowBefore.toStringAsFixed(1)} -> '
          '${slowAfter.toStringAsFixed(1)} frames/s at '
          '$_f12Throttle bytes/s');

      // ANTI-VACUITY: the throttle actually bit. Without this the isolation
      // clause below is asserted about a link nobody shaped, which passes on
      // an unthrottled pair of panels and means nothing at all.
      expect(slowAfter, lessThan(slowBefore / 2),
          reason: 'the throttled panel was receiving '
              '${slowBefore.toStringAsFixed(1)} frames/s before the lever and '
              '${slowAfter.toStringAsFixed(1)} after it, which is not the '
              'collapse a $_f12Throttle bytes/s meter should impose on a '
              '${keys.length}-key page at the tick rate. The lever did not '
              'bite, so the isolation assertion below is measuring two healthy '
              'links');

      // THE ROW'S CLAUSE: other clients unaffected. A band, never an equality
      // — the unthrottled panel's cadence is a real measurement over a real
      // socket and it moves a few percent between any two windows.
      expect(drift, lessThan(0.25),
          reason: 'the unthrottled panel went from '
              '${fastBefore.toStringAsFixed(1)} to '
              '${fastAfter.toStringAsFixed(1)} frames/s — '
              '${(drift * 100).toStringAsFixed(1)}% — when its *neighbour* was '
              'throttled. Nothing was done to this panel\'s link. Shared-fate '
              'degradation is exactly what the per-client conflating map '
              'exists to prevent (T-07-27), and one slow panel dragging the '
              'plant\'s cadence down for everybody is the failure an operator '
              'would report as "the whole system got slow"');

      // BOUNDED VIA CONFLATION, from the panel's side. The gateway's own half
      // of this clause is `backpressure_test.dart:327-393`. What a panel can
      // see is the difference between a conflating map and a queue, and it is
      // entirely in what happens on the way: a queue delivers **every** value
      // the plant produced, late; a conflating map delivers **fewer**, each of
      // them the latest at the moment it went out. Both end at the same
      // number, which is why a reading taken afterwards cannot tell them apart
      // and this is asserted off a recorder.
      print('F12: over the throttled window the plant produced '
          '${plantDuring.length} values for ${keys.first} and the throttled '
          'panel was shown ${slowDuring.length} of them, ending at '
          '${slowDuring.isEmpty ? 'nothing' : slowDuring.last} against a '
          'plant at ${plantDuring.isEmpty ? 'nothing' : plantDuring.last}');

      expect(slowDuring, isNotEmpty,
          reason: 'the throttled panel was shown no values at all during the '
              'window. Conflation is not starvation — a panel under the '
              'ceiling keeps being served, more slowly');
      expect(slowDuring.length, lessThan(plantDuring.length),
          reason: 'the plant produced ${plantDuring.length} values and the '
              'throttled panel was shown ${slowDuring.length} of them. A panel '
              'shown every value the plant produced, over a link that cannot '
              'carry them, is being served out of a queue — which is the '
              'unbounded-buffer failure §7.6\'s conflating map exists to '
              'prevent');
      expect(slowDuring, orderedEquals(slowDuring.toList()..sort()),
          reason: 'the values the throttled panel was shown are not in '
              'ascending order: $slowDuring. The plant only ever counts up, so '
              'a value that arrived after a larger one is an old queued value '
              'being delivered late — never an old queued one is the clause, '
              'and this is the only place it can be seen');
      // CONFLATION IS NOT EVICTION, and since 07-08b the row asks it **both
      // ways**. When 07-08 wrote this clause it could only ask "was anybody
      // thrown off *for being slow*", because the answer to "was anybody
      // thrown off" was yes for a reason that had nothing to do with this row:
      // no client sent a periodic heartbeat, so every panel was reaped once
      // every six seconds and a fourteen-second case saw two of them
      // (07-08-SUMMARY deviation 3). 07-08b built the pump, so the general
      // question is answerable again and the general clause is restored.
      //
      // Both arms stay, and they fail differently. `evictedForBackpressure` is
      // the row's own clause — 4004 on a throttled-but-conflating panel — and
      // it is the one that would still be here if the heartbeat were ever
      // removed. `heartbeatReaps` is now a **regression arm on the pump**, on
      // the one case in the suite where it is hardest: a fourteen-second
      // window on a link metered to ten kilobytes a second, where a heartbeat
      // that queued behind telemetry would arrive late and the reaper would
      // take a panel that is doing everything right.
      print('F12: ${fixture.evictedForBackpressure.length} panels thrown off '
          'for being slow, ${fixture.heartbeatReaps.length} reaped for '
          'silence, ${fixture.evictions.length} evicted in total');
      expect(fixture.evictedForBackpressure, isEmpty,
          reason: 'the gateway threw a panel off for being slow: '
              '${fixture.evictedForBackpressure}. Conflation is not eviction: '
              'a panel under the ceiling is served the latest value, never '
              'disconnected. This is the two-tier boundary G5 pairs from the '
              'other side, and 4004 firing on a throttled-but-conflating panel '
              'is the gateway punishing a slow link for being slow');
      expect(fixture.heartbeatReaps, isEmpty,
          reason: 'the gateway reaped ${fixture.heartbeatReaps.length} panels '
              'for silence over this window. The throttled panel\'s link is '
              'metered to $_f12Throttle bytes/s while a ${keys.length}-key '
              'page pours down it, which is the hardest place in this suite '
              'for a heartbeat to get out — and it is also the place where '
              'being reaped hurts most, because the panel then has to resync '
              'the whole page across the same throttle');
      expect(fixture.evictions, isEmpty,
          reason: 'the gateway threw ${fixture.evictions.length} panels off '
              'over this case: ${fixture.evictions}. Nothing here should cost '
              'anybody their session — one link is slow and the other is '
              'untouched');

      // ISOLATION, again and structurally: whatever the background is doing,
      // it is doing it equally to both panels. A throttle that caused its own
      // panel to be thrown off more often than its neighbour would show here
      // even if the cadence band somehow did not.
      final reconnects = [for (final one in fixture.clients) one.attempts];
      expect((reconnects[0] - reconnects[1]).abs(), lessThanOrEqualTo(1),
          reason: 'the throttled panel reconnected ${reconnects[0]} times and '
              'the unthrottled one ${reconnects[1]}. Only one of them had a '
              'lever pulled on it, so a difference beyond one is the throttle '
              'costing its own panel sessions — shared-fate degradation '
              'measured from the other end');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('G2 — joining a link that is already bad', () {
    test('G2: a panel that joins while the link is bad still gets its page',
        () async {
      final keys = _pageKeys(_busyPage);
      final joinerKeys = _pageKeys(_g2Page).toSet();
      final fixture = await gateFixture(
        clients: 1,
        keys: keys.toSet(),
        seed: (plant) =>
            plant.setValues({for (final key in keys) key: _beforeRestart}),
      );
      final resident = fixture.clients.single;

      final driver = _drivePlant(fixture.served, keys);
      addTearDown(driver.cancel);

      final residentBefore = await _cadence(resident, _rateWindow);

      // Throttle and flap together. The carried trap (Phase 2 handoff, STATE):
      // a latency-waited chunk does not re-check blackhole and the flap's down
      // half bites the *next* chunk, so a chunk already in flight when the flap
      // fires is delivered. Nothing here asserts that an in-flight chunk
      // vanishes; what is asserted is what arrives and when.
      fixture.proxy.throttleBytesPerSec = _g2Throttle;
      fixture.proxy.flap(_g2FlapUp, _g2FlapDown);
      addTearDown(() => fixture.proxy.flap(_g2FlapUp, _g2FlapDown,
          enabled: false));

      final residentDuring = await _cadence(resident, _rateWindow);

      // ANTI-VACUITY: the telemetry genuinely is backlogged. Without this, G2
      // passes on an idle link — a snapshot arriving promptly over a link with
      // nothing on it proves nothing about a priority lane.
      expect(residentDuring, lessThan(residentBefore / 2),
          reason: 'the resident panel was receiving '
              '${residentBefore.toStringAsFixed(1)} frames/s on a clean link '
              'and ${residentDuring.toStringAsFixed(1)} on one throttled to '
              '$_g2Throttle bytes/s and flapping. The link is therefore not '
              'under load, and a snapshot that arrives promptly across it '
              'beats no backlog at all — which is the vacuous pass this row is '
              'one measurement away from');

      final joined = Stopwatch()..start();
      final joiner = fixture.joinLate(keys: joinerKeys);
      await until(
        'the late joiner to reach a complete view of its page',
        () => joinerKeys.every((key) =>
            joiner.client.read(key)?.value ==
            fixture.served.read(key)?.value),
        budget: _g2Budget,
      );
      joined.stop();

      print('G2: the resident panel went ${residentBefore.toStringAsFixed(1)} '
          '-> ${residentDuring.toStringAsFixed(1)} frames/s under '
          '$_g2Throttle bytes/s and a '
          '${_g2FlapUp.inMilliseconds}/${_g2FlapDown.inMilliseconds} ms flap; '
          'the late joiner reached a complete ${joinerKeys.length}-key view '
          '${joined.elapsedMilliseconds} ms after it dialled, against a '
          '${_g2Budget.inMilliseconds} ms budget');

      // COMPLETE, not merely ready. `isReady` is reached before a snapshot
      // lands, so a case that waited on it would be timing the handshake and
      // calling it the page.
      for (final key in joinerKeys) {
        expect(joiner.client.read(key)?.value,
            fixture.served.read(key)?.value,
            reason: 'the late joiner is holding '
                '${joiner.client.read(key)?.value} for $key against a plant at '
                '${fixture.served.read(key)?.value}. The row\'s claim is a '
                '*complete* view, and one key short of the page is a panel '
                'showing an operator a blank where a number should be');
      }

      expect(joined.elapsed, lessThan(_g2Budget),
          reason: 'the late joiner took ${joined.elapsedMilliseconds} ms to '
              'reach a complete view against a ${_g2Budget.inMilliseconds} ms '
              'budget. The subscribe answer rides the priority lane and the '
              'telemetry it is competing with conflates, so a snapshot that '
              'cannot get out inside this budget is a snapshot being starved '
              'by the backlog');

      // As in F12: the row's own question is whether anybody was thrown off
      // *for the condition this row injects*. What is different since 07-08b
      // is that the second question — was anybody reaped for silence — has a
      // right answer again, so it is asked rather than merely printed.
      //
      // **`evictions` as a whole is deliberately not asserted here, and F12
      // does assert it.** A flapping link resets every pair it carries
      // (`fault_proxy.dart`'s `_dropForFlap`), so sockets die by design in
      // this case; what must not happen is the *gateway* choosing to end a
      // session. `heartbeatReaps` is that question in the form this row can
      // ask it: no session here lives longer than the 1500 ms up-half, so a
      // reap would mean the deadline is being missed on a link that is only
      // briefly up — which is the panel losing a race it should not be in.
      print('G2: ${fixture.evictedForBackpressure.length} panels thrown off '
          'for being slow, ${fixture.heartbeatReaps.length} reaped for '
          'silence');
      expect(fixture.heartbeatReaps, isEmpty,
          reason: 'the gateway reaped ${fixture.heartbeatReaps.length} panels '
              'for silence over a flapping, throttled link. Every session in '
              'this case is younger than the flap\'s up-half and far younger '
              'than the heartbeat deadline, so a reap here is not the panel '
              'being quiet — it is the gateway holding a session across a '
              'reset it should have noticed, or a heartbeat that cannot get '
              'out at $_g2Throttle bytes/s');
      expect(fixture.evictedForBackpressure, isEmpty,
          reason: 'the gateway threw a panel off for being slow while the link '
              'was throttled and flapping: ${fixture.evictedForBackpressure}. '
              'A bad link is the condition this row establishes, not '
              'misbehaviour by the panels on it — and a late joiner that '
              'reached its page only to be evicted for the link it joined over '
              'has not reached anything');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
