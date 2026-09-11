/// F25 — dead subscription, live socket: the Home Assistant wall-dashboard
/// failure, where the screen looks healthy, some widgets update, others are
/// hours stale, and whole-connection liveness cannot see it by construction.
///
/// Injection, verbatim: server stops evaluating one subscription, connection + other subs healthy
/// Expect, verbatim: client flags exactly that subscription stale
///
/// **Which half of this file is real and which is a lever — said out loud,
/// because the reader of the case is not necessarily the reader of the
/// lever.** The catalogue's injection has no shipped producer:
/// `TickEngine._writeTick` (`tick_engine.dart:400-420`; :376-396 before
/// upstream growth) stamps one `wallMs` as `evaluatedAt` for every
/// subscription of every session, so the field is a statement about the
/// tick, not about the subscription, and no shipped gateway can stop
/// evaluating *one* subscription while the rest keep going. F25a therefore
/// reaches the injection through `FrozenSubLever` — a test-only frame
/// builder between one shipped panel and the shipped gateway — and is honest
/// about that both here and in the lever's own doc. Orchestrator ruling 4
/// (09-CONTEXT) made the lever the answer; option (ii), real
/// per-subscription `evaluatedAt`, is the registry's costed `post-milestone`
/// follow-up and is not built.
///
/// F25a is the client half proven end to end: the same property
/// `freshness_test.dart:333-366` pins at the unit level (one frozen sub, one
/// healthy neighbour, `viewIsStale` false throughout) driven over real
/// sockets against the real gateway. The standing temptation this row
/// refuses is named in gate A's registry (F13's staleness-age deviation):
/// no per-subscription *age* is published to make the clause look asserted —
/// the verdict is the surface, `StateManApi` stays at 49 members, and
/// `RemoteStateMan` grows no getter here.
///
/// **F25a is the catalogue's injection reached through a lever; F25b is
/// ROADMAP criterion 3's wording — upstream stops updating while the link
/// stays up — reached through the product; and the row is only honest with
/// both.** F25b uses no lever and no test-only subclass: it is built
/// entirely from Phase 8 machinery (08-05's freshness sweep degrading to
/// `badStale`, 08-09's `PIPE.upstream.<alias>.data_age_ms`), because the
/// failure that actually happens in a fish factory is a PLC that stops
/// answering while its TCP connection stays perfectly healthy, and that one
/// the shipped gateway *can* see. Post-CR-02 the stored gauge is pushed only
/// on link events and arrivals, and `judge()` re-derives the age
/// synchronously on the READ path (`pipe_health.dart:210-216`) — so the
/// climb is observed by **repeated reads inside `until()` windows**, never
/// by subscribing: a subscriber sees a frozen last-pushed age during a
/// silent freeze, and F25b prints that frozen number beside the climbing one.
@Tags(['gate'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    show PipeKeys, Quality;
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;

import '../support/frozen_sub_lever.dart' hide visibleForTesting;
import '../support/gate_b_fixture.dart';

void main() {
  test(
      'F25a: one subscription stops being evaluated — the lever\'s injection '
      '— and the client flags exactly that subscription stale while the '
      'neighbour keeps updating', () async {
    final serverConfig = ServerConfig(tick: ServerConfig.minTick);
    final clientConfig = ClientConfig();
    final fixture = await gateBFixture(panels: 1, serverConfig: serverConfig);

    // Two lever legs in front of the one gateway, one per hand-dialled
    // panel — the fixture's proxyPerPanel shape. Only the frozen leg's lever
    // is ever pulled; the healthy leg's identical, un-pulled lever is what
    // lets the freeze-every-subscription sabotage bite the neighbour arm.
    final frozenLever = await FrozenSubLever.start(targetPort: fixture.port);
    addTearDown(frozenLever.shutdown);
    final healthyLever = await FrozenSubLever.start(targetPort: fixture.port);
    addTearDown(healthyLever.shutdown);

    // Registered after the fixture's own teardowns, so both panels dispose
    // before the gateway closes — the dial-storm ordering the fixture's
    // library doc argues.
    final frozenPanel = RemoteStateMan(
      uri: frozenLever.uri,
      config: clientConfig,
      keys: fixture.keys,
    );
    addTearDown(frozenPanel.dispose);
    final healthyPanel = RemoteStateMan(
      uri: healthyLever.uri,
      config: clientConfig,
      keys: fixture.keys,
    );
    addTearDown(healthyPanel.dispose);

    await until(
      'both lever-leg panels ready with a value for every key',
      () =>
          frozenPanel.isReady &&
          healthyPanel.isReady &&
          fixture.keys.every((key) =>
              frozenPanel.read(key) != null && healthyPanel.read(key) != null),
      budget: const Duration(seconds: 30),
    );

    // The per-subscription limit, read from the two configs the pipe was
    // built with rather than restated as a number: the gateway advertises
    // its tick in `hello`, the client multiplies and floors at the link
    // deadline (`freshness_watchdog.dart`, `_subscriptionLimitMs`).
    final linkMs = clientConfig.freshnessDeadline.inMilliseconds;
    final derived = (serverConfig.tick.inMilliseconds *
            clientConfig.subscriptionStalenessMultiple)
        .round();
    final limitMs = derived > linkMs ? derived : linkMs;
    print('F25a per-subscription limit from the client\'s own config: '
        'max(tick ${serverConfig.tick.inMilliseconds} ms × '
        '${clientConfig.subscriptionStalenessMultiple}, link deadline '
        '$linkMs ms) = $limitMs ms');

    // Anti-vacuity: before the freeze, the frozen leg's values are advancing
    // and neither subscription is stale — sampled through the same window.
    const plantKey = 'ST101.CN01.MOT01.setpoint';
    var staleBeforeFreeze = false;
    final beforeFreeze = frozenPanel.read(plantKey)?.value;
    expect(beforeFreeze, isA<int>(),
        reason: 'anti-vacuity: the frozen leg holds no plant value at all '
            'before the freeze, so nothing below would be measuring a live '
            'subscription going dead');
    await until(
      'the soon-to-be-frozen subscription\'s values advancing before the '
      'freeze',
      () {
        staleBeforeFreeze = staleBeforeFreeze ||
            frozenPanel.isSubscriptionStale(defaultPageSubscription) ||
            healthyPanel.isSubscriptionStale(defaultPageSubscription);
        final now = frozenPanel.read(plantKey)?.value;
        return now is int && now > (beforeFreeze as int);
      },
    );
    expect(staleBeforeFreeze, isFalse,
        reason: 'anti-vacuity: a subscription already stale before the '
            'injection would make the flip below vacuous — the case would be '
            'measuring the fixture, not the lever');

    // The injection. Everything after this line is the catalogue's row.
    final linkTransitions = <LinkState>[];
    final watchingLink = frozenPanel.linkStates.listen(linkTransitions.add);
    addTearDown(watchingLink.cancel);
    var healthyEverStale = false;
    var frozenViewEverStale = false;
    final flip = Stopwatch()..start();
    frozenLever.freeze(defaultPageSubscription);

    await until(
      'the client flags exactly that subscription stale — the frozen page '
      'on the frozen leg',
      () {
        healthyEverStale = healthyEverStale ||
            healthyPanel.isSubscriptionStale(defaultPageSubscription) ||
            fixture.panel.client.isSubscriptionStale(defaultPageSubscription);
        frozenViewEverStale = frozenViewEverStale || frozenPanel.viewIsStale;
        return frozenPanel.isSubscriptionStale(defaultPageSubscription);
      },
      budget: Duration(milliseconds: limitMs * 3),
    );
    flip.stop();
    print('F25a verdict flipped ${flip.elapsedMilliseconds} ms after '
        'freeze() against the $limitMs ms limit '
        '(${frozenLever.rewrittenTicks} ticks rewritten, '
        '${frozenLever.droppedUpdates} updates dropped so far)');

    await until(
      'the frozen leg\'s stale set naming exactly the page subscription',
      () {
        healthyEverStale = healthyEverStale ||
            healthyPanel.isSubscriptionStale(defaultPageSubscription) ||
            fixture.panel.client.isSubscriptionStale(defaultPageSubscription);
        frozenViewEverStale = frozenViewEverStale || frozenPanel.viewIsStale;
        final verdict = frozenPanel.staleSubscriptions;
        return verdict.length == 1 &&
            verdict.contains(defaultPageSubscription);
      },
    );

    // The dead widget stands still while the one next to it keeps moving —
    // the wall-dashboard picture, asserted from both sides.
    final frozenAtFlip = frozenPanel.read(plantKey)?.value;
    final healthyAtFlip = healthyPanel.read(plantKey)?.value as int;
    await until(
      'the healthy neighbour delivering three more sweeps past the flip',
      () {
        healthyEverStale = healthyEverStale ||
            healthyPanel.isSubscriptionStale(defaultPageSubscription) ||
            fixture.panel.client.isSubscriptionStale(defaultPageSubscription);
        frozenViewEverStale = frozenViewEverStale || frozenPanel.viewIsStale;
        final now = healthyPanel.read(plantKey)?.value;
        return now is int && now >= healthyAtFlip + 3;
      },
    );
    expect(frozenPanel.read(plantKey)?.value, frozenAtFlip,
        reason: 'the lever drops the frozen subscription\'s updates from the '
            'pin tick on, so its value cannot have moved a whole limit after '
            'the flip — a moving value here means the injection is not the '
            'fault this case claims to inject');

    expect(healthyEverStale, isFalse,
        reason: 'one dead PLC tag must not grey the values next to it: the '
            'healthy leg\'s panel and the direct-dial observer were sampled '
            'through every window above and neither may ever have read '
            'stale');
    expect(frozenViewEverStale, isFalse,
        reason: 'viewIsStale must stay false throughout: ticks kept arriving '
            'on the frozen leg, so the link is provably alive — link-down '
            'and one-value-dead are the two states CLI-04 exists to keep '
            'apart, and greying the whole view over one dead tag is the '
            'wrong one');
    expect(linkTransitions.where((state) => state != LinkState.ready).toList(),
        isEmpty,
        reason: 'linkState never leaves connected: the socket stayed up and '
            'frames kept arriving, so any transition away from ready during '
            'the freeze means the client tore down a healthy link over a '
            'plant-side fault — the resync-loop failure the 04-CONTEXT '
            'ruling forbids');

    // The lever did what the case says it did — and only on its own leg.
    expect(frozenLever.rewrittenTicks, greaterThan(0),
        reason: 'anti-vacuity: no tick was ever rewritten, so the verdict '
            'above flipped for some other reason than this injection');
    expect(frozenLever.droppedUpdates, greaterThan(0),
        reason: 'anti-vacuity: no update was ever dropped, so the frozen '
            'value standing still was luck, not the injection');
    expect(healthyLever.rewrittenTicks, 0,
        reason: 'the healthy leg\'s lever was never pulled, so a rewrite '
            'there means the lever froze more than the one subscription the '
            'case names');
    expect(healthyLever.droppedUpdates, 0,
        reason: 'as above: the healthy neighbour\'s updates must all have '
            'reached it');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
      'F25b: upstream stops updating while the link stays up — ROADMAP '
      'criterion 3\'s scenario from the shipped product, with no lever at '
      'all', () async {
    // F25a is the catalogue's injection reached through a lever; this arm is
    // ROADMAP criterion 3's wording reached through the product, and the row
    // is only honest with both. Everything below is Phase 8 machinery:
    // 08-05's freshness sweep, 08-09's PIPE.upstream.<alias> producer.
    const staleAfter = Duration(seconds: 2);
    final fixture = await gateBFixture(
      panels: 1,
      keysPerAlias: 10,
      staleAfter: staleAfter,
      serverConfig: ServerConfig(tick: ServerConfig.minTick),
    );
    final panel = fixture.panel.client;

    // The plant is hand-driven from here: the fixture's own driver sweeps
    // every alias or none, and this row's injection is one alias going
    // silent while its neighbour keeps talking. Values advance and carry an
    // advancing sourceTime, because "sourceTime not advancing" on the frozen
    // alias is only a statement if the flowing alias's demonstrably does.
    fixture.driver.cancel();
    final st101 = fixture.linkFor('ST101');
    final st201 = fixture.linkFor('ST201');
    final pages = {
      st101: gateBPage('ST101', 10),
      st201: gateBPage('ST201', 10),
    };
    final silenced = <String>{};
    var sweeps = 0;
    final sweeper = Timer.periodic(const Duration(milliseconds: 100), (_) {
      sweeps++;
      final at = DateTime.now();
      for (final entry in pages.entries) {
        if (silenced.contains(entry.key.alias)) continue;
        for (final key in entry.value) {
          entry.key.inner.setValue(key, 5000 + sweeps, sourceTime: at);
        }
      }
    });
    addTearDown(sweeper.cancel);

    const st101Key = 'ST101.CN01.MOT01.setpoint';
    const st201Key = 'ST201.CN01.MOT01.setpoint';
    final dataAgeKey = PipeKeys.upstreamDataAgeMs('ST101');

    // The gauge, on the READ path: post-CR-02 the stored value is pushed
    // only on link events and arrivals, and judge() re-derives the age
    // synchronously on read (pipe_health.dart:210-216) — so the climb below
    // is observed by repeated reads inside until() windows, never by
    // subscribing.
    int? readAge() {
      final value = fixture.plant.read(dataAgeKey)?.value;
      return value is int ? value : null;
    }

    // The subscriber contrast, end to end: a real panel subscribed to the
    // gauge sees only what is pushed, and during a silent freeze that is a
    // frozen last-pushed age. Printed beside the climbing read-path series.
    final gaugeWatcher = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${fixture.port}'),
      config: ClientConfig(),
      keys: {dataAgeKey, st201Key},
    );
    addTearDown(gaugeWatcher.dispose);
    await until(
      'the gauge watcher holding a pushed data_age_ms',
      () => gaugeWatcher.isReady && gaugeWatcher.read(dataAgeKey) != null,
      budget: const Duration(seconds: 30),
    );

    // Anti-vacuity: data_age_ms low and both aliases' keys good and moving
    // before the injection.
    await until(
      'both aliases flowing with good quality and a low ST101 data_age_ms '
      'before the injection',
      () {
        final age = readAge();
        final a = panel.read(st101Key);
        final b = panel.read(st201Key);
        return a?.quality == Quality.good &&
            b?.quality == Quality.good &&
            (a?.value as int? ?? 0) > 5000 &&
            (b?.value as int? ?? 0) > 5000 &&
            age != null &&
            age < staleAfter.inMilliseconds ~/ 2;
      },
    );

    // The injection: ST101's values stop moving. Its link stays connected,
    // its socket stays up, nothing is disconnected — which is the entire
    // point of the row.
    final sweepsAtInjection = sweeps;
    silenced.add('ST101');
    var st101EverNotConnected = false;
    bool linkLied() {
      // Value AND quality: a health key the freshness machinery has greyed
      // is a health key an operator must not trust, so "the link reports
      // itself connected" means a good-quality true — this is also the arm
      // that catches HLTH-02's trap, a sweep greying `PIPE.` keys by their
      // own once-a-shift accounting.
      final connected = panel.read(PipeKeys.upstreamConnected('ST101'));
      final state = panel.read(PipeKeys.upstreamState('ST101'));
      return connected?.value != true ||
          connected?.quality != Quality.good ||
          state?.value != 'connected' ||
          state?.quality != Quality.good;
    }

    final series = <int>[];
    final st101Page = pages[st101]!;
    await until(
      'every ST101 key degrading to badStale while the link still reports '
      'connected and the neighbour keeps flowing',
      () {
        st101EverNotConnected = st101EverNotConnected || linkLied();
        final age = readAge();
        if (age != null) series.add(age);
        return st101Page
            .every((key) => panel.read(key)?.quality == Quality.badStale);
      },
      budget: staleAfter * 3 + const Duration(seconds: 3),
    );

    // No arrival can reach ST101 from here on, so these are post-event
    // consistency facts: the last-delivered source times, the last-pushed
    // gauge at the subscriber.
    final frozenSourceTimes = {
      for (final key in st101Page) key: panel.read(key)?.sourceTime,
    };
    expect(frozenSourceTimes.values, everyElement(isNotNull),
        reason: 'anti-vacuity: a badStale key with no sourceTime at all '
            'never carried a delivered value, so "sourceTime not advancing" '
            'below would be vacuously true');
    final pushedAgeAtFreeze = gaugeWatcher.read(dataAgeKey)?.value;
    final st201SourceAtFreeze =
        panel.read(st201Key)?.sourceTime?.millisecondsSinceEpoch;

    // The climb, continued past double the deadline: strictly non-decreasing
    // under repeated reads, while the stored gauge a subscriber sees stays
    // exactly where the last arrival pushed it.
    final climbing = <int>[];
    await until(
      'ST101\'s data_age_ms climbing past twice the staleAfter deadline '
      'under repeated reads on the read path',
      () {
        st101EverNotConnected = st101EverNotConnected || linkLied();
        final age = readAge();
        if (age != null) climbing.add(age);
        return age != null && age > staleAfter.inMilliseconds * 2;
      },
      budget: staleAfter * 4 + const Duration(seconds: 3),
    );
    print('F25b data_age_ms on the read path, injection -> badStale: '
        '$series');
    print('F25b data_age_ms on the read path, badStale -> past 2x deadline: '
        '$climbing');
    final sortedClimb = [...climbing]..sort();
    expect(climbing, sortedClimb,
        reason: 'after the last ST101 arrival the age is two readings of one '
            'monotonic counter minus a constant, so any decrease in this '
            'series means an arrival happened during the freeze — the '
            'injection leaked');
    expect(climbing.last, greaterThan(staleAfter.inMilliseconds * 2),
        reason: 'the climb must demonstrably continue past the deadline, not '
            'merely reach it');

    // The neighbour, across the entire injection: values and source times
    // advancing, sweeps counted.
    final st201After = panel.read(st201Key);
    final st201SourceAfter = st201After?.sourceTime?.millisecondsSinceEpoch;
    print('F25b neighbour ST201 source-time advance across the freeze: '
        '$st201SourceAtFreeze -> $st201SourceAfter '
        '(sweeps $sweepsAtInjection -> $sweeps, quality '
        '${st201After?.quality})');
    expect(st201SourceAfter, isNotNull);
    expect(st201SourceAfter! > st201SourceAtFreeze!, isTrue,
        reason: 'the neighbour alias\'s keys must keep flowing with '
            'advancing source times — a frozen neighbour means the injection '
            'silenced the plant, not one alias, and the isolation claim is '
            'vacuous');
    expect(sweeps, greaterThan(sweepsAtInjection + 5),
        reason: 'anti-vacuity: the hand sweeper must have kept the plant '
            'busy throughout the freeze');
    expect(st201After?.quality, Quality.good,
        reason: 'the flowing neighbour must never degrade: one silent PLC '
            'costs its own alias, nothing else');

    // The frozen alias: badStale with sourceTime not advancing.
    for (final key in st101Page) {
      expect(panel.read(key)?.sourceTime, frozenSourceTimes[key],
          reason: 'a badStale key whose sourceTime moved received an arrival '
              'during the freeze — the degrade would then be the sweep '
              'racing the plant rather than the plant going silent');
      expect(panel.read(key)?.quality, Quality.badStale,
          reason: 'post-event consistency: no arrival can have reached this '
              'alias since the degrade, so the quality cannot have recovered');
    }

    // The link never reports itself disconnected, because it is not.
    expect(st101EverNotConnected, isFalse,
        reason: 'PIPE.upstream.ST101.connected and .state were sampled '
            'through every window above: the socket is up, the link is '
            'connected, and only the values stopped — reporting a disconnect '
            'here would send an electrician to a healthy cable');

    // The subscriber contrast: the pushed gauge stood still while the read
    // path climbed.
    final pushedAgeAfter = gaugeWatcher.read(dataAgeKey)?.value;
    print('F25b subscriber-cached data_age_ms across the freeze: '
        '$pushedAgeAtFreeze -> $pushedAgeAfter (pushed only on link events '
        'and arrivals; the read path above climbed to ${climbing.last} ms '
        'meanwhile)');
    expect(pushedAgeAfter, pushedAgeAtFreeze,
        reason: 'the stored gauge is pushed only on link events and arrivals '
            '(08-REVIEW CR-02), and ST101 had neither during the freeze — a '
            'moved value here means something pushed the gauge during '
            'silence, which is the timer this package deliberately does not '
            'have');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
