/// F9 and G3: recovery going wrong while it is happening.
///
/// **F9 — Drop during resync.** The catalogue's injection is *drop, reconnect,
/// drop again mid-resync burst, reconnect*, and it expects that the second
/// resync is complete and consistent; no key left with pre-first-drop value.
/// The operative half is the last clause: **every** key on the page, not the one
/// key the case happens to watch. A single-key page has no burst to interrupt
/// and no "every", which is why `resync_test.dart`'s in-memory arms cannot make
/// this row's claim.
///
/// **G3 — Resync storm / gap thrash.** The industry survey's version of the same
/// worry (07-RESEARCH-PUBSUB §D.1): induce repeated sequence gaps and assert
/// resyncs are **coalesced, not stacked** — one in-flight resync per
/// subscription, backoff not reset until it completes, no unbounded growth.
/// Sparkplug's rebirth and Ably's re-attach both rate-limit for this reason and
/// OPC UA Part 14 caps discovery responses at five times the KeepAliveTime;
/// ours has no stated limit, so the coalescing in `resync_engine.dart` is the
/// whole of the protection and nothing asserted it.
///
/// **What the resync of one page actually looks like on the wire, measured.**
/// A 40-key page recovers in **two inbound frames**: the `hello` answer (280 b)
/// and then the whole snapshot as a single 4275-byte response, 49 ms later. The
/// "burst" of the catalogue's phrase is not a stream of frames at this layer —
/// one subscription is one snapshot in one frame however large the page — so
/// the interruptible window is *between* those two frames: the session is
/// re-established, the client has asked for the page, and the answer has not
/// arrived. That is where F9's second kill is armed, and the case measures both
/// numbers on every run rather than trusting this paragraph.
///
/// **Neither case reaches into `_inFlight`.** The property the plant cares about
/// is how many times the *gateway* was asked to rebuild the page, so the count
/// is read from the gateway's own registry and corroborated against the
/// subscribe answers on the wire. A case that read the private map would assert
/// the implementation, and the implementation is allowed to change while the
/// property stays.
@TestOn('vm')
@Tags(['gate', 'faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fault_fixture.dart';
import '../support/frame_seam.dart';
import '../support/gate_bands.dart';

/// How many keys F9's page carries.
///
/// Forty rather than one because the row's clause is "no key left with
/// pre-first-drop value" and a one-key page cannot distinguish "the page came
/// back" from "the key this case watches came back". Forty is also the size at
/// which the snapshot stops being a rounding error on the exchange: measured,
/// forty keys are a 4275-byte answer against a 280-byte `hello` answer and a
/// 125-byte tick, and the gateway spends ~49 ms building and sending it — which
/// is the window the second kill has to land in. A smaller page shrinks that
/// window towards the scheduler's resolution; a much larger one buys nothing,
/// because the answer is still one frame.
const int _f9PageSize = 40;

/// How many sequence gaps G3a induces in one burst.
///
/// Eight, injected in one synchronous loop so that every one of them lands
/// while the first resync is still in flight — which is the only window in
/// which there is anything to coalesce. A client that started an establish per
/// gap would answer eight; the coalescing one answers one, and an
/// order-of-magnitude difference is a result rather than a margin.
const int _g3Gaps = 8;

/// How long G3b keeps killing connections before their snapshot can arrive.
///
/// Three seconds is seven attempts of the schedule below (20 + 40 + 80 + 160 +
/// 320 + 640 + 1280 ms of expected waiting) and about forty of a schedule that
/// restarted at the base every time the socket answered. The two numbers are
/// what the arm discriminates between, and three seconds is where they are
/// furthest apart per second of lane.
const Duration _g3StormWindow = Duration(seconds: 3);

/// The backoff schedule G3b's bound is computed from, restated here rather than
/// read off the config the fixture builds.
///
/// 07-04's lesson, and it is the whole reason the bound has teeth: a ceiling
/// that recomputed itself from whatever the client was actually handed would
/// rise to meet a client that had been made to hammer, which is the one failure
/// it exists to catch. These two must move with `faultClientConfig`'s, and the
/// arm says so if they stop agreeing about the shape of the storm.
const Duration _g3BackoffBase = Duration(milliseconds: 40);
const Duration _g3BackoffCap = Duration(seconds: 2);

/// What one attempt costs beyond its backoff wait: a dial, a WebSocket
/// handshake and a `hello` round trip over loopback. Measured at 40-60 ms on
/// macOS across the runs in 07-06-SUMMARY; 40 ms is the conservative end,
/// because a *smaller* overhead makes the ceiling below larger and the bound
/// weaker only in the direction that cannot produce a false red.
const Duration _g3AttemptOverhead = Duration(milliseconds: 40);

/// The page F9 drives, as `ST101.CNnn.MOT01.setpoint`.
///
/// The plant's own naming (`AREAnn.DEVnn.SUBnn`), so the page reads like a page
/// rather than like `key0…key39`.
List<String> _pageKeys(int n) => [
      for (var i = 1; i <= n; i++)
        'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.setpoint',
    ];

/// The gateway's answer to a `subscribe`, recognised by the one field only it
/// carries.
///
/// `generation` is spelled out in the subscribe result and abbreviated to `g` in
/// the hot-path `u` frame (`messages.dart:263-323`), so this matches the answer
/// and never an update.
bool _isSnapshotAnswer(String frame) => frame.contains('"generation"');

/// The gateway's own count of how many times it has rebuilt this page.
///
/// The generation is minted by `SubscriptionRegistry.nextGeneration()` once per
/// subscribe, from a counter that spans the whole gateway
/// (`subscription_registry.dart:190-205`), so with one client on one page the
/// delta across a window **is** the number of subscribes the gateway served in
/// it. Read off the server's registry rather than off the client or the resync
/// engine's `_inFlight` map: the property G3 is about is how many times the
/// *gateway* was asked to rebuild the page, and a case that read the private map
/// would be asserting an implementation that is allowed to change while the
/// property stays.
int _rebuildsServed(FaultFixture fixture, String sub) {
  final session = fixture.server.sessions.sessions.single;
  final state = session.subscriptions.get(sub);
  if (state == null) {
    fail('the gateway holds no subscription named "$sub", so there is nothing '
        'to count rebuilds of');
  }
  return state.generation;
}

/// How many attempts a schedule that is **never reset** fits into [window].
///
/// Full jitter draws uniformly from `[0, min(cap, base * 2^n))`, so attempt *n*
/// waits half that window on average, and each attempt also costs one dial and
/// one `hello` round trip. The walk at 40 ms base and a 2 s cap is 20, 40, 80,
/// 160, 320, 640, 1280, 1000… ms of waiting, so a three-second window holds
/// eight attempts.
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

/// What was true at the instant the second kill fired.
///
/// Captured at a causally-defined moment — the arrival of the first frame of the
/// new connection — and asserted afterwards, which is why the readiness read
/// below is not the instant read of a wall-clock boolean the manifest's sweep
/// forbids.
typedef ArmRecord = ({int frames, bool snapshotSeen, bool isReady, int holding});

void main() {
  group('F9 — a drop in the middle of the resync', () {
    test('F9: a second drop mid-resync still leaves every key equal to the '
        'plant', () async {
      final keys = _pageKeys(_f9PageSize);
      final fixture = await faultFixture(
        keys: keys.toSet(),
        withProxy: true,
        seed: (plant) {
          for (var i = 0; i < keys.length; i++) {
            plant.setValue(keys[i], 100 + i);
          }
        },
      );
      await until('the link', () => fixture.client.isReady);
      await until('the whole page',
          () => keys.every((key) => fixture.client.read(key) != null));

      // Anti-vacuity 1: the page was carrying its pre-drop values before
      // anything was pulled. A page that never held them cannot be shown not to
      // be holding them at the end.
      final preDrop = <String, Object?>{
        for (final key in keys) key: fixture.client.read(key)?.value,
      };
      expect(preDrop.values.where((value) => value != null).length, keys.length,
          reason: 'the page did not carry a value for every key before the '
              'first drop, so the assertion below would be comparing the plant '
              'against keys that had never arrived');

      final markBefore = fixture.seam.inbound.length;
      final dialsBefore = fixture.seam.dials;
      fixture.proxy.killOnce();

      // The plant moves while the link is down — every key, to a distinct new
      // value, so the comparison at the end has something to catch on every one
      // of them.
      final postDrop = <String, Object?>{};
      for (var i = 0; i < keys.length; i++) {
        fixture.served.setValue(keys[i], 900 + i);
        postDrop[keys[i]] = 900 + i;
      }

      // The second kill is armed off an observation rather than a sleep: the
      // first frame of the new connection has arrived, so the resync exchange
      // has begun, and the snapshot has not. A `Future.delayed` here is a case
      // that stops interrupting the exchange the day the gateway gets faster.
      ArmRecord? atKill;
      final armDeadline = DateTime.now().add(recovery);
      while (atKill == null) {
        if (DateTime.now().isAfter(armDeadline)) {
          fail('no frame arrived on the reconnected link within '
              '${recovery.inMilliseconds} ms, so the second kill was never '
              'armed and this case has not run its own scenario');
        }
        final arrived = fixture.seam.inbound.sublist(markBefore);
        if (arrived.isNotEmpty) {
          atKill = (
            frames: arrived.length,
            snapshotSeen: arrived.any(_isSnapshotAnswer),
            isReady: fixture.client.isReady,
            holding: keys
                .where((key) =>
                    fixture.client.read(key)?.value == postDrop[key])
                .length,
          );
          fixture.proxy.killOnce();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final markAfter = fixture.seam.inbound.length;
      await until('the second recovery', () => fixture.client.isReady,
          budget: recovery);
      await until('the whole page, again',
          () => keys.every((key) => fixture.client.read(key) != null),
          budget: recovery);
      // The deferred changes the gateway had queued for the abandoned
      // establishment arrive as an ordinary update a tick later; the property
      // is what the page settles on, not what it holds mid-exchange.
      await Future<void>.delayed(settle);

      // How long a *complete* exchange is, measured on this run rather than
      // asserted from the paragraph in the library doc: the frames from the
      // third dial up to and including the snapshot answer.
      final afterTheKill = fixture.seam.inbound.sublist(markAfter);
      final snapshotAt = afterTheKill.indexWhere(_isSnapshotAnswer);
      final burstFrames = snapshotAt + 1;

      print('F9: page of ${keys.length} keys; a complete resync exchange is '
          '$burstFrames inbound frames (hello answer then the snapshot); the '
          'second kill was armed on frame ${atKill.frames} of the interrupted '
          'one, with the snapshot not yet delivered '
          '(snapshotSeen=${atKill.snapshotSeen}, keys holding a post-drop '
          'value=${atKill.holding}); dials $dialsBefore -> '
          '${fixture.seam.dials}');

      // Anti-vacuity 2: the second kill landed, and it landed inside the resync
      // exchange rather than after it. Three observations, none of them a
      // clock: a third dial exists, the snapshot had not arrived when the kill
      // fired, and the interrupted exchange was shorter than a complete one.
      expect(fixture.seam.dials, dialsBefore + 2,
          reason: 'the link was dialled ${fixture.seam.dials - dialsBefore} '
              'times, not twice. Two kills cost two redials; anything else '
              'means one of them did not land and the row\'s injection — drop, '
              'reconnect, drop again mid-resync — did not happen');
      expect(atKill.snapshotSeen, isFalse,
          reason: 'the snapshot answer had already arrived when the second '
              'kill fired, so the kill landed after the resync rather than '
              'inside it and this is F1 with extra steps');
      expect(atKill.frames, lessThan(burstFrames),
          reason: 'the interrupted exchange carried ${atKill.frames} frames '
              'and a complete one carries $burstFrames, so the kill did not '
              'interrupt anything');
      expect(atKill.isReady, isFalse, // window-exempt: recorded at the arrival of the first frame of the reconnected link — the completed event this case arms its second kill on — and asserted afterwards from the record, not read live
          reason: 'the client was already ready when the second kill fired, so '
              'the resync it was supposed to interrupt had finished');

      // The row's own clause, over every key, with the expectation built from
      // the plant so the case cannot drift from what was actually set.
      final wrong = <String>[];
      for (final key in keys) {
        final plant = fixture.served.read(key)?.value;
        final panel = fixture.client.read(key)?.value;
        if (panel != plant) {
          wrong.add('$key: panel $panel, plant $plant, before the first drop '
              '${preDrop[key]}');
        }
      }
      expect(wrong, isEmpty,
          reason: 'these keys do not hold the plant\'s current value after two '
              'drops around one resync: $wrong. A key still holding its '
              'pre-first-drop value is the F9 failure exactly — the second '
              'resync completed, the banner cleared, and part of the page is '
              'a photograph of the plant from before the outage, under good '
              'quality, with nothing on screen to say so');

      // Anti-vacuity 3: the page moved. Without this the case would pass
      // against a client that ignored every frame and a plant that never
      // changed.
      final moved = keys
          .where((key) => fixture.client.read(key)?.value != preDrop[key])
          .length;
      expect(moved, keys.length,
          reason: 'only $moved of ${keys.length} keys differ from their '
              'pre-drop value, so the comparison above was partly against '
              'values that never changed and could not have caught a client '
              'that kept them');
    });
  });

  group('G3 — a resync storm coalesces instead of stacking', () {
    test('G3a: a burst of sequence gaps on one page costs one resync, not a '
        'stack', () async {
      final fixture = await faultFixture(
        keys: const {scenarioKey},
        seed: (plant) => plant.setValue(scenarioKey, 1200),
      );
      await until('the link', () => fixture.client.isReady);

      // A real frame off the wire, so the storm is made of frames the gateway
      // genuinely sent rather than of a shape somebody guessed.
      fixture.served.setValue(scenarioKey, 1300);
      await until('an update frame',
          () => fixture.client.read(scenarioKey)?.value == 1300);
      final captured = fixture.seam.lastMatching(
          (message) => message.contains('"method":"${Methods.update}"'));
      expect(captured, isNotNull,
          reason: 'no update frame was captured, so the storm below would '
              'inject nothing and every count in this case would be zero');

      final rebuiltBefore = _rebuildsServed(fixture, defaultPageSubscription);
      final answersBefore =
          fixture.seam.inbound.where(_isSnapshotAnswer).length;
      final serverSeq = fixture
          .server.sessions.sessions.single.subscriptions
          .get(defaultPageSubscription)!
          .seq;

      // The lever is repeated sequence gaps rather than repeated kills, and the
      // choice is the row's: a kill storm is a *reconnect* storm, whose
      // recoveries the supervisor serialises one per connection, so it cannot
      // put two recoveries in flight for one subscription and has nothing to
      // coalesce (07-04 measured the same thing from the other side: under a
      // flap neither guard in `onUpdate` fires at all, because the peer is
      // retired before a frame can reach it). Gaps arrive on a live socket,
      // which is the only place `_inFlight` can have two callers.
      for (var i = 1; i <= _g3Gaps; i++) {
        fixture.seam.inject(FrameSeam.restamped(captured!,
            seq: serverSeq + i * 10, generation: rebuiltBefore));
      }

      await until('the page to be rebuilt at least once',
          () => _rebuildsServed(fixture, defaultPageSubscription) >
              rebuiltBefore,
          budget: recovery);
      // Spent on purpose: a client that stacked its resyncs would serve the
      // remaining seven here, and an absence is only worth the window it was
      // watched over.
      await Future<void>.delayed(settle);

      final rebuilt =
          _rebuildsServed(fixture, defaultPageSubscription) - rebuiltBefore;
      final answers =
          fixture.seam.inbound.where(_isSnapshotAnswer).length - answersBefore;
      print('G3a: $_g3Gaps gaps induced, $rebuilt rebuilds served by the '
          'gateway, $answers snapshot answers on the wire; '
          'complaints ${fixture.client.complaints.length}, sessions '
          '${fixture.server.sessions.sessionCount}, subscriptions '
          '${fixture.server.sessions.sessions.single.subscriptions.count}');

      // Anti-vacuity: something did resync. Eight gaps that cost nothing at all
      // would satisfy every bound below while measuring an absence of load.
      expect(rebuilt, greaterThanOrEqualTo(1),
          reason: 'the gateway rebuilt the page $rebuilt times across '
              '$_g3Gaps sequence gaps, so nothing was coalesced because '
              'nothing happened — the injected frames were not read as gaps at '
              'all and this case is measuring an absence of load');
      expect(rebuilt, lessThan(_g3Gaps),
          reason: 'the gateway rebuilt the page $rebuilt times for $_g3Gaps '
              'gaps. Resyncs are stacking rather than coalescing: one flapping '
              'panel turns one broken stream into a rebuild per gap against a '
              'gateway serving the whole plant, which is the denial of service '
              'Sparkplug rebirth and Ably re-attach both rate-limit for');
      // Bounded by the recoveries that *completed*, not by the gaps: every
      // rebuild the gateway served came back as a snapshot the client applied,
      // so none was left in flight.
      expect(rebuilt, answers,
          reason: 'the gateway served $rebuilt rebuilds and the client saw '
              '$answers snapshot answers. A rebuild with no answer is a resync '
              'the gateway paid for and nobody completed, which is the '
              'unbounded-growth half of the row');

      // No unbounded growth: one session, one subscription, no complaints, and
      // the page still current.
      expect(fixture.server.sessions.sessionCount, lessThanOrEqualTo(1),
          reason: 'the storm left more than one session on the gateway');
      expect(
          fixture.server.sessions.sessions.single.subscriptions.count, 1,
          reason: 'the gateway holds more subscriptions than the client asked '
              'for, so a re-establish registered beside its predecessor '
              'instead of replacing it');
      expect(fixture.client.complaints, isEmpty,
          reason: 'the resync engine complained during the storm: '
              '${fixture.client.complaints}. A refused or failed recovery '
              'leaves the page unestablished, and a case whose storm ends with '
              'the page gone is not measuring coalescing');
      final value = await fixture.client.readFresh(scenarioKey).timeout(recovery);
      expect(value.value, 1300,
          reason: 'a forced round trip after the storm did not answer with the '
              'plant\'s value, so the page did not survive its own recovery');
    });

    test('G3b: the backoff does not restart until a resync completes',
        () async {
      final keys = _pageKeys(_f9PageSize);
      final fixture = await faultFixture(
        keys: keys.toSet(),
        withProxy: true,
        seed: (plant) {
          for (var i = 0; i < keys.length; i++) {
            plant.setValue(keys[i], 100 + i);
          }
        },
      );
      await until('the link', () => fixture.client.isReady);

      // `LinkState.connecting`, not `seam.dials`: a dial counts a socket whose
      // handshake finished, and the number this arm is about is how often the
      // client *tried* (07-04, measured — the same sabotage moved dials 5 to 9
      // while attempts went 42 to 420).
      final attemptAt = <DateTime>[];
      final states = fixture.client.linkStates.listen((state) {
        if (state == LinkState.connecting) attemptAt.add(DateTime.now());
      });
      addTearDown(states.cancel);

      // Every connection is killed on its first inbound frame — the `hello`
      // answer — so the socket answers the phone every time and the snapshot
      // never lands. `LinkState.ready` is entered only after the resync
      // completes (`connection_supervisor.dart:470,508`) and that is the one
      // place `backoff.reset()` is called, so a schedule that grew here is a
      // schedule that was not reset by the socket coming up. The page is forty
      // keys for the reason F9 needs it to be: it puts ~49 ms between the
      // `hello` answer and the snapshot, which is the room this loop has to
      // fire in.
      final stormFrom = fixture.seam.inbound.length;
      var mark = fixture.seam.inbound.length;
      final started = DateTime.now();
      fixture.proxy.killOnce();
      var kills = 1;
      while (DateTime.now().difference(started) < _g3StormWindow) {
        if (fixture.seam.inbound.length > mark) {
          mark = fixture.seam.inbound.length;
          fixture.proxy.killOnce();
          kills++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final during = fixture.seam.inbound.sublist(stormFrom);
      final completed = during.where(_isSnapshotAnswer).length;
      final attempts = attemptAt.length;
      final intervals = [
        for (var i = 1; i < attemptAt.length; i++)
          attemptAt[i].difference(attemptAt[i - 1]).inMilliseconds,
      ];
      final ceiling = _attemptsIn(
              _g3StormWindow, _g3BackoffBase, _g3BackoffCap, _g3AttemptOverhead) *
          2;

      print('G3b: ${_g3StormWindow.inSeconds}s of killing every connection on '
          'its first frame: $kills kills, $attempts attempts, $completed '
          'resyncs completed, ${during.length} frames; intervals $intervals ms '
          '(last ${intervals.isEmpty ? 'none' : intervals.last}); ceiling '
          '$ceiling attempts for a schedule that is never reset, against the '
          '${(_g3StormWindow.inMilliseconds / (_g3BackoffBase.inMilliseconds / 2 + _g3AttemptOverhead.inMilliseconds)).round()} '
          'a schedule reset at every connection would fit');

      // The precondition the clause rests on: not one recovery completed, so
      // the backoff never earned its reset.
      expect(completed, 0,
          reason: '$completed snapshots were served during the storm, so a '
              'recovery completed, the backoff was legitimately reset, and the '
              'growth this arm measures would be measuring the kill loop '
              'instead');
      // Anti-vacuity: the storm happened.
      expect(attempts, greaterThan(2),
          reason: 'only $attempts reconnect attempts were made in '
              '${_g3StormWindow.inSeconds} s, so the client was not in a '
              'reconnect loop at all and the bound below judges nothing');
      expect(attempts, lessThan(ceiling),
          reason: 'the client made $attempts attempts in '
              '${_g3StormWindow.inSeconds} s against a ceiling of $ceiling '
              'computed from a 40 ms base and a 2 s cap. A schedule restarted '
              'at the base every time the socket answered fits about '
              '${(_g3StormWindow.inMilliseconds / (_g3BackoffBase.inMilliseconds / 2 + _g3AttemptOverhead.inMilliseconds)).round()} '
              'attempts in the same window, which is what this bound is '
              'between: the backoff is reset when a page is delivered, never '
              'when a socket answers the phone (`connection_supervisor.dart:'
              '712-721`)');

      // The positive control: with the storm over, the client recovers. Without
      // it, a client that had given up entirely would satisfy every bound
      // above.
      await until('the recovery once the storm stops',
          () => fixture.client.isReady, budget: const Duration(seconds: 10));
      await until('the whole page',
          () => keys.every((key) => fixture.client.read(key) != null),
          budget: recovery);
    });
  });
}
