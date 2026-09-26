/// F17 — Long outage.
///
/// The catalogue's expectation, verbatim: client memory bounded (no queued
/// writes piling up),
/// server released the dead session; reconnect after works.
///
/// **The server half is cited, not re-run.** `liveness_test.dart:244` already
/// proves that a black-holed client is reaped on the heartbeat clock from
/// inside the server package, and `faults/blackhole_test.dart:121` proves that
/// on recovery the swallowed bytes are gone rather than replayed. What was
/// missing is the *client* half, and it is what this file is: a panel that
/// cannot reach the wire for half a minute must come out of it holding no more
/// bookkeeping than it went in with, having actuated nothing twice, and able to
/// reconnect.
///
/// **Thirty seconds by default, ten minutes behind `RELAY_SOAK`, and the
/// shortening is declared rather than applied.** `gateDeviations` carries the
/// entry (row F17, clause `` `blackhole()` 10 min ``) with the reason: the
/// mechanism the row is about is the gateway releasing a dead session, and that
/// fires at the first six-second deadline, not at the tenth minute. Thirty
/// seconds is five deadlines. `F17b` is the catalogue's own duration, the same
/// function with a longer outage — literally the same code, so "the soak arm
/// runs the same assertions" is a fact rather than a claim.
/// (07-CONTEXT user ruling 2; `flap_gate_test.dart`'s `F2a`/`F2c` shape.)
///
/// **Why the outage ends by lifting the blackhole, and not with `killOnce`.**
/// The plan's instruction was to end it with `killOnce()` — the rule
/// `write_in_flight_gate_test.dart:23-41` records, and the reason it gives is
/// specific: a blackhole swallows the *client's own close* too, so the
/// replacement session had to establish beside a session the gateway still
/// believed in, and one run in four wedged. Two things make that rule
/// inapplicable here.
///
/// First, it is not expressible: `killOnce` resets the current pair and the
/// blackhole is *sticky across pairs* (`fault_proxy.dart:552-558` applies it to
/// every pair accepted afterwards), so a connection killed while the lever is
/// still armed comes back into the same silence. The outage **is** the
/// blackhole; the only way out of it is to disarm it.
///
/// Second, the hazard the rule was written against is gone, and this row proves
/// it in passing: the reason a replacement used to establish beside a live
/// session is that nothing released the dead one. This case asserts the gateway
/// is holding **zero** sessions for the dark panel before the recovery begins.
/// There is nothing left to establish beside — measured across every run of
/// this file at 441 ms to 2.9 s of recovery, against the fifteen-second budget
/// the wedge used to blow through.
///
/// **Who releases the dead session, measured.** 07-08b's handover predicted the
/// reaper would take it at about six seconds, on the grounds that a blackholed
/// panel cannot get a heartbeat out either. It cannot — but it is *awake*, and
/// its own freshness deadline fires at three seconds, so it hangs up first. The
/// gateway's ledger reads `ConnectionClose(client: 1006, server: null)` every
/// run: the session is released by the socket dying, and the reaper never gets
/// to it. **The clause is satisfied and the mechanism is the other one**, which
/// is worth knowing because it means F16 and F17 cover the two halves between
/// them: a *frozen* panel cannot hang up, so `suspend_gate_test.dart` is where
/// the 4003 reap is asserted, and `liveness_test.dart:244` proves that path
/// from inside the server package.
///
/// **The second panel is the row's strongest arm and it costs nothing.** One
/// blackholed panel and one healthy one, on separate proxies in front of one
/// gateway. "The server released the dead session" is only worth saying if the
/// server did not also release live ones — which is exactly what it did on the
/// build before 07-08b, once every six seconds, to every panel in the plant. So
/// the reap count is asserted at **zero**, no close in the ledger carries a
/// code the gateway chose, and the healthy panel's reconnect count, socket
/// count and session are all asserted flat across the whole outage. That makes
/// this row the longest-running regression arm on the heartbeat pump in the
/// suite, in addition to being F17.
///
/// **Memory is asserted structurally and never off `ProcessInfo.currentRss`.**
/// 07-RESEARCH assumption A9: RSS on this VM moves by megabytes for reasons
/// that have nothing to do with the code under test, so a bound loose enough
/// not to flake is loose enough not to catch a leak. What is asserted instead
/// is the structure the clause is actually about — the unresolved-write set and
/// the count of writes that reached a socket — sampled through the outage so
/// that a leak shows as a slope rather than as one end-state reading, which is
/// `teardown_test.dart`'s checkpoint doctrine. **No line of code in either arm
/// reads `ProcessInfo.currentRss`** — the only two occurrences of that name in
/// this file are in this paragraph, and there is no coarse 10x smoke-detector
/// ceiling in the soak arm either: a ceiling loose enough to survive the VM's
/// own allocator is one no leak this row could produce would ever trip, and it
/// would read like a memory assertion to the next person.
///
/// **The soak arm earned its keep on the first run: ten minutes crosses a
/// safety boundary that thirty seconds does not.** `ServerConfig
/// .writeOutcomeTtl` is 60 s, and outside it the gateway may not answer
/// `not_received` — it cannot tell "never arrived" from "arrived, and
/// forgotten". So the unresolved command settles in `F17a` and deliberately
/// does **not** in `F17b`, where the answer is unknown again and the entry
/// stays. Both are bounded at one entry, which is the clause; which of the two
/// happens is asserted against the arithmetic rather than allowed to vary, and
/// [_outcomeTtl] is read off the gateway's own config so the branch cannot
/// drift away from the number it is about.
///
/// **Why the descriptor clause is a supporting arm and not part of F17.**
/// `openSocketCount` cannot answer on Windows, so an arm that measures
/// descriptors has to skip there; a skip on F17 itself would make the row read
/// as judged on a column of the matrix where it never ran, which is 07-08
/// deviation 2's finding and the failure the manifest's skip audit exists to
/// catch one level up. So F17 runs everywhere and judges everything a panel can
/// observe, and the descriptor measurement is its own case below — with a short
/// outage, because a descriptor leak is a rate per dial cycle rather than a
/// function of wall clock.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;
import 'package:tfc_stateman_contract/faults.dart';

import '../support/fault_fixture.dart' show faultClientConfig, until;
import '../support/gate_fixture.dart';

// ---------------------------------------------------------------------------
// The outage.
// ---------------------------------------------------------------------------

/// How long `F17a` holds the link silent.
///
/// Thirty seconds: five of the gateway's six-second heartbeat deadlines, which
/// is the mechanism the row names. Declared in `gateDeviations` under F17
/// against the catalogue's ten minutes — 07-CONTEXT user ruling 2.
const Duration _outage = Duration(seconds: 30);

/// The catalogue's own duration, which `F17b` runs on demand.
const Duration _soakOutage = Duration(minutes: 10);

/// The environment variable that raises the outage to the catalogue's own.
const String _soakEnvVar = 'RELAY_SOAK';

/// How long the descriptor arm blackholes for.
///
/// Eight seconds — one heartbeat deadline plus a margin, so the session is
/// genuinely reaped and the panel genuinely redials several times. The leak
/// criterion is a rate per establish/teardown cycle (`teardown_test.dart:330-
/// 375`), so dial cycles are its unit and seconds are not; `flap_gate_test`'s
/// `F2b` makes the same trade for the same reason.
const Duration _fdOutage = Duration(seconds: 8);

/// How often the outage is sampled, and how often a write is issued into it.
///
/// Ten seconds gives `F17a` the plan's three samples — 10 s, 20 s and 30 s —
/// and gives the soak arm sixty of them, which is where "no unbounded growth"
/// stops being three points and becomes a line.
const Duration _sample = Duration(seconds: 10);

/// How long the panel is given to come back once the link is restored.
///
/// Generous, and it has to be: the panel is somewhere in a backoff schedule
/// capped at two seconds when the lever is lifted, and a dial that was already
/// in flight into the silence has to reach [_dialCeiling] before the next one
/// starts. Fifteen seconds covers both plus a handshake and a snapshot.
const Duration _recoveryBudget = Duration(seconds: 15);

/// The ceiling on one dial, lowered from `faultClientConfig`'s ten seconds.
///
/// **A blackholed link makes the connect timeout the whole story, so it has to
/// be smaller than the outage.** The proxy accepts the TCP connection and then
/// swallows the upgrade, so every dial into the silence runs to its ceiling
/// rather than failing fast; at ten seconds a thirty-second outage holds three
/// attempts, and a dial started at t=29 s would still be waiting eight seconds
/// after the lever was lifted — the recovery measurement would be measuring
/// this constant. Two seconds gives the outage a genuine dial cycle to leak or
/// re-actuate on, which is what the row is looking for. F14b is the row that
/// owns the timeout itself (`connect_failure_gate_test.dart`); nothing here
/// asserts anything about its value.
const Duration _dialCeiling = Duration(seconds: 2);

/// How long the gateway remembers what became of a write.
///
/// **Read off `ServerConfig` and never restated, because this is the one number
/// the two arms of this row disagree across.** Inside it, `writeStatus` may
/// answer `not_received` — positive evidence that a re-send is safe — and the
/// panel's unresolved command settles. Outside it the gateway cannot tell
/// "never arrived" from "arrived, and forgotten" (`write_outcome_log.dart:15-
/// 29`), so it answers unknown again and the command stays unresolved, which is
/// the design: forgetting is not evidence that it never happened. `F17a`'s
/// thirty seconds is inside; `F17b`'s ten minutes is not, and the soak arm
/// found that boundary rather than being written around it.
final Duration _outcomeTtl = ServerConfig().writeOutcomeTtl;

/// The key the panels watch, and the key the writes go to.
///
/// Two keys, so that "the value that changed while the link was down" and "the
/// tag an operator was pressing a button on" are different observations. One
/// key would make a readback adopted from a write indistinguishable from a
/// resynced value, which is the confusion F8 exists to rule out.
const String _watched = 'ST101.CN01.MOT01.setpoint';
const String _written = 'ST101.CN01.MOT01.command';

/// What the plant holds before the outage, and what it is moved to during it.
const int _beforeOutage = 1300;
const int _duringOutage = 2500;

/// The value each write into the outage carries. Distinct per write, so a
/// readback adopted from the wrong one would be visible.
int _commanded(int n) => 7000 + n;

/// Every close the gateway initiated that was a reap, and every one that was
/// an eviction of any kind. `GateFixture`'s getters, used rather than restated.
String _ledgerOf(GateFixture fixture) =>
    'reaps=${fixture.heartbeatReaps.length} '
    'backpressure=${fixture.evictedForBackpressure.length} '
    'evictions=${fixture.evictions.length}';

/// Stands the two panels up and hands back the dark one, the lit one and the
/// fixture.
///
/// [connectTimeout] is the only thing this changes about `faultClientConfig`,
/// and [_dialCeiling] says why.
Future<GateFixture> _twoPanels() => gateFixture(
      clients: 2,
      // One proxy per panel: `throttleBytesPerSec` and `blackhole` are both
      // properties of the proxy and reach every pair it carries
      // (`fault_proxy.dart:513-517`, `:552-558`), so two panels behind one
      // proxy cannot be silenced separately — a case that thought it had
      // blackholed one of them would have blackholed both and then asserted
      // that the other one was fine.
      proxyPerClient: true,
      keys: const <String>{_watched, _written},
      config: faultClientConfig(connectTimeout: _dialCeiling),
      seed: (plant) => plant.setValues(<String, Object?>{
        _watched: _beforeOutage,
        _written: _commanded(0),
      }),
    );

/// F17's whole body, shared by the default arm and the soak arm.
///
/// One function so that "the soak arm runs the same assertions" is a fact about
/// the code rather than a comment. Everything that differs between the two is
/// [outage].
Future<void> _longOutage(Duration outage) async {
  final fixture = await _twoPanels();
  final dark = fixture.clients[0];
  final lit = fixture.clients[1];

  // ANTI-VACUITY, first half: both panels carried the plant's value and the
  // gateway held both sessions before anything was injected. A panel that
  // never had a page cannot be shown to have got it back, and a session count
  // that was never two cannot be read as one being released.
  expect(dark.client.read(_watched)?.value, _beforeOutage,
      reason: 'the panel about to be silenced was not holding the plant\'s '
          'seeded value, so "reconnect after works" below would be comparing '
          'the plant against a page that had never arrived');
  expect(lit.client.read(_watched)?.value, _beforeOutage,
      reason: 'the panel that stays healthy was not holding the plant\'s '
          'seeded value, so it cannot stand as the control this row needs');
  expect(fixture.sessionCount, 2,
      reason: 'the gateway is holding ${fixture.sessionCount} sessions for two '
          'panels before anything was injected. Every session number below is '
          'read against this one');

  final litAttemptsBefore = lit.attempts;
  final litDialsBefore = lit.seam.dials;
  final beatsBefore = lit.client.debugHeartbeatsSent;

  // THE OUTAGE. Both directions go silent while the sockets stay up, which is
  // the row's own injection and the fault this whole project is built against:
  // a peer that has not closed anything and has simply stopped answering.
  dark.proxy.blackhole();
  final clock = Stopwatch()..start();

  // The plant moves while the panel cannot hear it — a value it never held
  // before the outage, so a page that comes back holding it was rebuilt rather
  // than remembered.
  fixture.served.setValues(<String, Object?>{_watched: _duringOutage});

  // The first write goes out while the panel still believes its link is up, so
  // its bytes are genuinely offered to a socket and genuinely swallowed. That
  // is the one write the gateway could conceivably have an opinion about, and
  // it is therefore the one that stays unresolved.
  var issued = 0;
  final outcomes = <WriteResult>[];
  outcomes.add(await dark.client.write(_written, _commanded(++issued)));

  final samples = <String>[];
  final unresolvedSamples = <int>[];
  final sentSamples = <int>[];
  var darkSessionReleased = false;

  while (clock.elapsed < outage) {
    final remaining = outage - clock.elapsed;
    await Future<void>.delayed(remaining < _sample ? remaining : _sample);

    // One panel left means the dark one's session is gone: the lit one is
    // asserted to have survived below, so this is the release rather than a
    // count that happens to be low.
    if (fixture.sessionCount <= 1) darkSessionReleased = true;

    outcomes.add(await dark.client.write(_written, _commanded(++issued)));
    unresolvedSamples.add(dark.client.debugUnresolvedCmds.length);
    sentSamples.add(dark.client.debugWritesSent);
    samples.add('t=${clock.elapsed.inSeconds}s  issued=$issued  '
        'unresolved=${dark.client.debugUnresolvedCmds.length}  '
        'writesSent=${dark.client.debugWritesSent}  '
        'sessions=${fixture.sessionCount}  ${_ledgerOf(fixture)}');
  }
  final table = samples.join('\n  ');
  final sentDuringOutage = dark.client.debugWritesSent;

  // ANTI-VACUITY, second half: the link genuinely went silent. Inside a window
  // and not at an instant — this is a wall-clock verdict and the F5 flake is
  // what a point read of one measures.
  await until(
    'the silenced panel to notice that nothing is arriving',
    () => dark.client.viewIsStale,
    budget: const Duration(seconds: 10),
  );

  // THE RECOVERY. The lever is lifted rather than the connection killed; the
  // library doc argues that at length, and the session count asserted just
  // below is the argument's evidence.
  expect(darkSessionReleased, isTrue,
      reason: 'the gateway never dropped below two sessions across '
          '${outage.inSeconds} seconds of one panel being unreachable:\n  '
          '$table\n\nThat is the row\'s own clause — server released the dead '
          'session — and it is also what makes the recovery below safe: a '
          'replacement establishing beside a session the gateway still '
          'believes in is the wedge write_in_flight_gate_test.dart:23-41 '
          'records');

  dark.proxy.blackhole(enabled: false);
  final recovery = Stopwatch()..start();
  await until(
    'the silenced panel to agree with the plant again',
    () => dark.client.read(_watched)?.value == _duringOutage,
    budget: _recoveryBudget,
  );
  recovery.stop();

  // The re-query is asynchronous with the resync, so it gets its own window —
  // and the wait is on the *answer* arriving rather than on the set draining,
  // because whether an answer settles anything depends on how long the outage
  // was. See [_outcomeTtl].
  await until(
    'the recovered panel to ask the gateway what became of its unresolved '
        'write',
    () => dark.client.debugWriteStatusAnswers.isNotEmpty,
    budget: _recoveryBudget,
  );
  final insideTtl = outage < _outcomeTtl;
  if (insideTtl) {
    await until(
      'the answer to settle the command it was about',
      () => dark.client.debugUnresolvedCmds.isEmpty,
      budget: _recoveryBudget,
    );
  }

  final reaps = fixture.heartbeatReaps;
  print('F17: ${outage.inSeconds} s of blackhole on one of two panels.\n  '
      '$table\n'
      'the outage swallowed $issued writes, of which '
      '$sentDuringOutage reached a socket; the panel came back in '
      '${recovery.elapsedMilliseconds} ms holding '
      '${dark.client.read(_watched)?.value}, having sent '
      '${dark.client.debugWritesSent} writes in total and asked '
      '${dark.client.debugWriteStatusQueries.length} writeStatus questions '
      '(answers ${dark.client.debugWriteStatusAnswers.map((a) => a.runtimeType).toList()}); '
      'the gateway reaped ${reaps.length} $reaps, its whole close ledger is '
      '${fixture.server.closeLedger}, and it holds '
      '${fixture.sessionCount} sessions; the healthy panel made '
      '${lit.attempts - litAttemptsBefore} reconnect attempts, '
      '${lit.seam.dials - litDialsBefore} new sockets and '
      '${lit.client.debugHeartbeatsSent - beatsBefore} heartbeats');

  // ------------------------------------------------------------------------
  // CLIENT MEMORY BOUNDED (no queued writes piling up), structurally.
  // ------------------------------------------------------------------------

  expect(unresolvedSamples.last, lessThanOrEqualTo(issued),
      reason: 'the panel is holding ${unresolvedSamples.last} unresolved '
          'commands after issuing $issued writes into a dead link:\n  $table\n\n'
          'The unresolved set is the one structure a long outage can grow '
          'without bound, and it is bounded by operator actions — one entry '
          'per write, removed the moment the command settles');
  expect(unresolvedSamples.toSet(), hasLength(1),
      reason: 'the unresolved count moved across the outage: '
          '$unresolvedSamples.\n  $table\n\nEvery write after the first is '
          'issued into a link the client knows is down, and a command that '
          'never reached a socket is dropped rather than kept — it is one no '
          'gateway can have an opinion about, and re-querying it on every '
          'reconnect for the rest of the shift is how a panel with a dead link '
          'grows an unresolved set until writeStatus is refused for being over '
          'maxKeysPerSubscribe, taking the recovery path for the genuine '
          'unknowns down with it. A slope here is that leak');

  // ------------------------------------------------------------------------
  // NO QUEUED WRITES PILING UP — the write-safety property, from the side an
  // operator feels it: a button pressed once actuates once.
  // ------------------------------------------------------------------------

  expect(sentSamples.toSet(), hasLength(1),
      reason: 'the count of writes that reached a socket moved across the '
          'outage: $sentSamples.\n  $table\n\nOnly the first write was issued '
          'while the link was believed up; every one after it was refused at '
          'the barrier without bytes being offered. A number that grows here '
          'is a client re-sending — either retrying its own unresolved write '
          'or draining a queue on each redial — and on a plant that is a '
          'second actuation of machinery an operator commanded once '
          '(CLAUDE.md: no queue / no retry is the write-safety property)');
  expect(dark.client.debugWritesSent, sentDuringOutage,
      reason: 'the panel had sent $sentDuringOutage writes when the link came '
          'back and ${dark.client.debugWritesSent} after it recovered. The '
          'reconnect is the moment a queue would drain and a retry would fire, '
          'and this client does neither: it asks writeStatus what became of '
          'the command, it does not send the command again');
  expect(dark.client.debugUnresolvedCmds.length, lessThanOrEqualTo(1),
      reason: 'the panel came out of the outage holding '
          '${dark.client.debugUnresolvedCmds.length} unresolved commands. One '
          'write was dispatched into the silence, so one is the ceiling '
          'whatever the gateway answered — a larger number is the recovery '
          'itself growing the set it exists to drain');
  expect(dark.client.debugUnresolvedCmds.isEmpty, insideTtl,
      reason: 'the outage was ${outage.inSeconds} s against a gateway that '
          'remembers a write outcome for ${_outcomeTtl.inSeconds} s, and the '
          'panel came back holding ${dark.client.debugUnresolvedCmds} with '
          'answers ${dark.client.debugWriteStatusAnswers.map((a) => a.runtimeType).toList()}.\n\n'
          'These two must agree, and this is the one assertion in the row that '
          'reads differently in its two arms. Inside the window the gateway '
          'can say `not_received` — positive evidence that a re-send is safe — '
          'and the command settles. Outside it the gateway cannot tell "never '
          'arrived" from "arrived, and forgotten" (`write_outcome_log.dart:15-'
          '29`), so it answers unknown again and the command **stays** '
          'unresolved, for ever if need be: forgetting is not evidence that it '
          'never happened. That is bounded — one entry, asserted just above — '
          'and it is the design, not a leak. A green here in the other '
          'direction would mean either that a ten-minute-old command was '
          'settled on evidence the gateway does not have, or that a '
          'thirty-second-old one was abandoned unanswered');
  expect(dark.client.debugWriteStatusQueries, isNotEmpty,
      reason: 'the panel recovered with an unresolved command and never asked '
          'the gateway what became of it. "Never re-sent" is only half the '
          'property — the other half is that the operator who was told '
          '"unknown" is told the answer when there is one, and a client that '
          'is silent about it has lost the write quietly instead of loudly');
  expect(outcomes, everyElement(isA<WriteUnknown>()),
      reason: 'a write issued into a blackholed link came back with something '
          'other than unknown: ${outcomes.map((o) => o.runtimeType).toList()}. '
          'Nothing reached the plant, and the only honest verdicts are unknown '
          'for the one that was dispatched into the silence and unknown for '
          'the ones the barrier refused — never applied, and never an '
          'exception thrown out of write()');

  // ------------------------------------------------------------------------
  // SERVER RELEASED THE DEAD SESSION — and only the dead one.
  // ------------------------------------------------------------------------

  // **The session ended, and the panel is what ended it.** Measured, and it
  // corrects 07-08b's handover note: that note predicted the reaper would take
  // this session at ~6 s, because a blackholed panel cannot get a ping out
  // either. It cannot — but it is not silent, it is *awake*, and its own
  // freshness deadline fires at three seconds, half a deadline before the
  // reaper's. So the panel hangs up first, the proxy carries the socket death
  // upstream, and the gateway releases the session on a client-observed 1006
  // with no close code of its own. The row's clause is satisfied either way —
  // the gateway is holding nothing for a panel that is gone — and which of the
  // two mechanisms fires is a fact about who noticed first.
  //
  // F16 is the other half of the same pair and it is why nothing is lost by
  // this: a *frozen* panel cannot hang up, so there the reaper does take the
  // session at six seconds and `suspend_gate_test.dart` asserts the 4003.
  // `liveness_test.dart:244` proves the same path from inside the server
  // package. Between them the reap is covered; here what is worth asserting is
  // that nobody was reaped at all.
  expect(reaps, isEmpty,
      reason: 'the gateway reaped ${reaps.length} sessions for silence across '
          '${outage.inSeconds} seconds: $reaps.\n  $table\n\nThe unreachable '
          'panel hangs up on its own freshness deadline three seconds in, so '
          'there is nothing left for the reaper to take; anything in this list '
          'is therefore a session that *was* talking — which is the defect '
          '07-08 measured and 07-08b fixed, every panel in the plant thrown '
          'off once every six seconds. Over ${outage.inSeconds} seconds this '
          'is the longest-running regression arm on the heartbeat pump in the '
          'suite');
  expect(fixture.server.closeLedger, isNotEmpty,
      reason: 'the gateway ended no session at all across '
          '${outage.inSeconds} seconds of one panel being unreachable, yet its '
          'session count fell. A release that leaves no ledger entry is one '
          'nothing can be asserted about — and "server released the dead '
          'session" would then be a count going down for reasons this row '
          'cannot see');
  expect([
    for (final close in fixture.server.closeLedger)
      if (close.serverCloseCode != null) close,
  ], isEmpty,
      reason: 'the gateway chose to end a session during this outage: '
          '${fixture.server.closeLedger}. Nothing here should cost anybody '
          'their session on the gateway\'s initiative — one panel became '
          'unreachable and hung up on itself, and the other did nothing but '
          'watch a page and beat');
  expect(lit.seam.dials, litDialsBefore,
      reason: 'the healthy panel opened '
          '${lit.seam.dials - litDialsBefore} new sockets while its neighbour '
          'was blackholed. Its link was never touched, so a new socket means '
          'it lost the one it had');
  expect(lit.attempts, litAttemptsBefore,
      reason: 'the healthy panel redialled '
          '${lit.attempts - litAttemptsBefore} times while its neighbour was '
          'blackholed. Nothing was done to its link. This is the heartbeat '
          'pump asserted over the longest window in the suite: a panel that is '
          'only watching a page sends the gateway nothing but its beat, and '
          'without that beat it is reaped and resyncs the whole page once a '
          'deadline for as long as the plant is running');
  expect(fixture.evictedForBackpressure, isEmpty,
      reason: 'the gateway threw a panel off for being slow: '
          '${fixture.evictedForBackpressure}. The dark panel is not slow, it '
          'is unreachable — its send buffer is the gateway\'s and its verdict '
          'should be the heartbeat\'s, not the backpressure ceiling\'s');

  // ------------------------------------------------------------------------
  // RECONNECT AFTER WORKS.
  // ------------------------------------------------------------------------

  expect(dark.client.read(_watched)?.value, _duringOutage,
      reason: 'the panel came back holding '
          '${dark.client.read(_watched)?.value} against a plant at '
          '$_duringOutage. The value changed while the link was silent, so a '
          'panel showing the old one has reconnected without resyncing — rule '
          '2, and the silent-permanent-staleness case');
  expect(fixture.sessionCount, 2,
      reason: 'the gateway holds ${fixture.sessionCount} sessions after the '
          'recovery, against two panels. Fewer means the recovered panel is '
          'reading a page nobody is sending; more means the reaped session is '
          'registered beside its replacement');
  expect(fixture.gatewayComplaints, isEmpty,
      reason: 'the gateway reported errors across the outage: '
          '${fixture.gatewayComplaints}. A client that stops reading is a '
          'condition it is built for — it reaps the session — not one it '
          'should be logging exceptions about');
  expect(lit.client.complaints, isEmpty,
      reason: 'the healthy panel complained while its neighbour was silent: '
          '${lit.client.complaints}');
}

void main() {
  group('F17 — half a minute of nothing at all', () {
    test('F17a: half a minute of silence costs the client nothing it cannot '
        'give back', () => _longOutage(_outage),
        timeout: const Timeout(Duration(minutes: 3)));

    test('F17b: the catalogue\'s own ten minutes of blackhole',
        () => _longOutage(_soakOutage),
        timeout: const Timeout(Duration(minutes: 20)),
        skip: (Platform.environment[_soakEnvVar] ?? '').isNotEmpty
            ? null
            : 'the catalogue names blackhole() for 10 min and the default lane '
                'runs 30 s, so this arm is the declared deviation being made '
                'good on demand. What stops being judged while $_soakEnvVar is '
                'unset: whether the unresolved set, the write counter and the '
                'reap count are still flat over sixty samples rather than '
                'three — a leak of one entry per redial, or a reaper that '
                'takes a healthy panel on its hundredth heartbeat rather than '
                'its fifth, is visible at ten minutes and not at thirty '
                'seconds. Set $_soakEnvVar=1 to run it');
  });

  group('the outage gives its descriptors back', () {
    test('a blackholed panel that redials for eight seconds leaks no sockets',
        () async {
      final baseline = openSocketCount();

      // **Registered before the fixture, so it runs after it.** `addTearDown`
      // is last-registered-first and `gateFixture` registers four groups of
      // its own while it is being awaited, so a check written on the line
      // after the fixture call runs *first*, against panels that are still
      // fully connected — 07-08-SUMMARY's hour, spent so nobody spends it
      // again.
      addTearDown(() async {
        final settled = await untilSocketsSettle(baseline);
        print('F17 descriptor arm: open sockets settled at $settled against a '
            'baseline of $baseline');
        expect(settled, lessThanOrEqualTo(baseline),
            reason: 'the outage arm released both panels, the gateway and both '
                'proxies and the process is still holding ${settled - baseline} '
                'more socket descriptors than before. A blackholed panel '
                'redials every couple of seconds and each attempt opens a '
                'socket the proxy accepts and never forwards, so this is the '
                'shape that leaks one per cycle. TIME_WAIT is not a descriptor '
                '(`fd_count.dart:28-31`)');
      });

      final fixture = await _twoPanels();
      final dark = fixture.clients[0];
      final held = openSocketCount();

      dark.proxy.blackhole();
      final dialsBefore = dark.seam.dials;
      final attemptsBefore = dark.attempts;
      await Future<void>.delayed(_fdOutage);
      final attempts = dark.attempts - attemptsBefore;
      dark.proxy.blackhole(enabled: false);

      await until(
        'the panel to come back after the short outage',
        () => dark.client.isReady,
        budget: _recoveryBudget,
      );

      print('F17 descriptor arm: ${_fdOutage.inSeconds} s of blackhole cost '
          '$attempts reconnect attempts and '
          '${dark.seam.dials - dialsBefore} completed dials; open sockets '
          '$baseline -> $held (delta ${held - baseline}) with both panels up');

      expect(held - baseline, greaterThanOrEqualTo(2),
          reason: 'standing up two panels moved the open-socket count by '
              '${held - baseline}. Each costs four descriptors in this process '
              '— the panel\'s socket, the proxy\'s accepted socket, the '
              'proxy\'s upstream socket and the gateway\'s accepted socket — '
              'so a delta this small means the counter cannot see this '
              'fixture\'s connections and the leak check in the teardown is '
              'vacuous');
      expect(attempts, greaterThan(1),
          reason: 'the blackholed panel made $attempts reconnect attempts in '
              '${_fdOutage.inSeconds} seconds. The leak this arm looks for is '
              'a rate per dial cycle, so a window that produced no cycles '
              'measures nothing — the dial ceiling is '
              '${_dialCeiling.inSeconds} s and the outage is '
              '${_fdOutage.inSeconds} s, and if that stops producing attempts '
              'the two constants have drifted apart');
    },
        timeout: const Timeout(Duration(seconds: 90)),
        skip: canCountOpenSockets ? null : openSocketCountSkipReason);
  });

  group('the row\'s own arithmetic', () {
    test('the two arms sit on opposite sides of the write-outcome window', () {
      expect(_outage, lessThan(_outcomeTtl),
          reason: 'the default outage ($_outage) is longer than the gateway\'s '
              'write-outcome memory ($_outcomeTtl), so `F17a` would take the '
              'soak arm\'s branch and the row would stop asserting that a '
              'reconnecting panel can be told what became of the button its '
              'operator pressed — which is the whole of the writeStatus '
              'recovery story');
      expect(_soakOutage, greaterThan(_outcomeTtl),
          reason: 'the soak outage ($_soakOutage) is inside the gateway\'s '
              'write-outcome memory ($_outcomeTtl), so both arms would assert '
              'the same branch and the `insideTtl` clause in `_longOutage` '
              'would never be exercised in its false form. If the TTL grows '
              'past ten minutes, that clause is asserting a constant');
    });

    test('the default outage spans several heartbeat deadlines', () {
      final deadline = ServerConfig().heartbeatDeadline;
      expect(_outage, greaterThan(deadline * 3),
          reason: 'the default outage ($_outage) does not span three of the '
              'gateway\'s heartbeat deadlines ($deadline). The clause this row '
              'shortens ten minutes down to is "server released the dead '
              'session", and it is only honest to shorten it as far as a '
              'window that still contains the mechanism several times over. If '
              'the gateway\'s default patience grows, this constant and the '
              'gateDeviations entry that declares it both have to move');
    });
  });
}
