/// WSH-02, finding S2: the slow-consumer verdict, as outcomes rather than as a
/// mechanism.
///
/// **Every arm here asserts an outcome, deliberately.** `16-02-DECISION.md`
/// chose option (c) — an application-level delivery ack — over the two options
/// `tick_engine.dart` had been naming since Phase 3, and it refuted option (a)
/// by measurement. If that choice is ever revisited, these arms should survive
/// the revision unchanged: they say *a stuck client is caught and a healthy one
/// is spared*, and they never say *how*.
///
/// **The two failures are symmetric and a fix that closes one by opening the
/// other is not a fix.** That is why the negative arms (2, 3, 5, 7 — "is never
/// evicted") are paired with arm 4, which is positive and is the most important
/// arm in the file: a server with no backpressure at all satisfies every
/// negative arm here vacuously. Sabotage (c) and (d) in 16-08's plan exist to
/// prove arm 4 bites, and therefore that arms 2 and 3 mean something.
///
/// **Where the numbers come from.** Every budget below is quoted from
/// `16-02-DECISION.md`, with the section it was measured in, because a budget
/// with a source is a budget somebody can argue with. Nothing here sleeps and
/// nothing here reads `DateTime.now()`: the engine takes its timestamp as an
/// argument, so a sixteen-second detection window is arithmetic on a
/// `FakeClock` rather than sixteen seconds of a hosted runner.
///
/// **The ack is a claim by the party being judged** (T-16-02a / T-16-08a), and
/// arm 6 is where that is pinned. The decision licences trusting it only as far
/// as the clamp allows: a client may under-report and evict itself, which is
/// harmless, and may not over-report to evade eviction, which would make the
/// eviction something the client can veto.
@TestOn('vm')
@Tags(['faults'])
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';

import 'support/panels.dart';

/// The buffer production builds, from the config production reads.
///
/// **A faithful copy of `relay_server.dart`'s wiring and not a set of
/// literals.** `Plant.connect`'s default buffer carries `maxPending` and
/// nothing else (`panels.dart:196`), so an arm that used it would be vacuously
/// green the moment any soft ceiling changed — the harness note 16-02 left for
/// this plan (`16-02-DECISION.md` §2.3). Reading the fields off [ServerConfig]
/// rather than restating them is what makes arm 2 sensitive to the default
/// this plan changes.
ConflatingSendBuffer shipping(ServerConfig config) => ConflatingSendBuffer(
      maxPending: config.maxPending,
      peakThreshold: config.peakThreshold,
      peakWindowMs: config.peakWindowMs,
      maxPendingBytes: config.maxPendingBytes,
    );

/// The fastest half-open detection 16-02 measured at the **shipping**
/// `pingInterval` of 20 s (`16-02-DECISION.md` §2.1: 22.8–38.0 s over the
/// sweep, median 32.9 s, worst case 40 s).
///
/// Arm 1's budget is set against the *fastest* figure rather than the median or
/// the worst case on purpose. Beating 40 s is a claim anybody would believe and
/// nobody should be reassured by; beating the best reading the platform ever
/// produced is the claim worth making, and it is the one that fails first if
/// the detector is quietly widened.
const pongTimeoutFastestMs = 22_800;

void main() {
  group('Arm 1 — a client that stopped reading is caught, in seconds', () {
    test('a frozen ack is a delivery stall, and the reason says so', () async {
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(40, prefix: 'CN03.STUCK');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));
      final state = panel.session.subscriptions.get('page-1')!;

      // Twenty healthy ticks first. A session that has *never* acknowledged
      // anything is an old client, and the decision is explicit that such a
      // client is not judged by this verdict at all (§5.3, and arm 7). The
      // failure being reproduced is a panel that was reading and stopped.
      var value = 0;
      for (var t = 0; t < 20; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
        panel.buffer.recordAck('page-1', state.seq);
      }

      expect(panel.session.sentCloseCode, isNull,
          reason: 'a panel that is keeping up is not evicted for keeping up');

      // The stall. The plant keeps moving and the server keeps producing, so
      // the server's seq advances every tick; the client acknowledges nothing
      // further. This is exactly the shape 16-02 §2.1 measured — a panel that
      // has stopped reading while its heartbeat keeps arriving, so the reaper
      // never fires and only the platform's pong timeout is left.
      final stalledAtMs = plant.clock.nowMs;
      var ticks = 0;
      while (panel.session.sentCloseCode == null && ticks < 2000) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
        ticks++;
      }
      final detectionMs = plant.clock.nowMs - stalledAtMs;

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'a client that has stopped reading must be detected by this '
              'server, not by the platform giving up on its own pong. Today '
              'nothing here notices: the buffer measures one tick of '
              'production for one client and drains itself every tick, so the '
              'only bound is `pingInterval`');

      expect(detectionMs, lessThan(pongTimeoutFastestMs),
          reason: 'the detector has to beat the thing it replaces. '
              '$pongTimeoutFastestMs ms is the FASTEST half-open detection '
              '16-02 measured at the shipping pingInterval (§2.1; the median '
              'was 32 900 ms and the worst case 40 000 ms), so a detector '
              'slower than this has bought nothing at all');

      await pumpEventQueue();
      final close = panel.closes.single;
      expect(close.code, CloseCodes.backpressureOverrun);
      expect(close.reason, contains('delivery stalled'),
          reason: 'the reason string names what was actually measured. The '
              'string this replaces said "client unable to keep up" about a '
              'measurement of the server\'s own production — which is the '
              'second half of the finding in one sentence (T-16-08e)');
      expect(close.reason, contains('page-1'),
          reason: 'an operator reading the close ledger should learn which '
              'page stalled without reading the server\'s source');
      expect(close.reason, isNot(contains('unable to keep up')),
          reason: 'the sentence that blamed the panel is retired with the '
              'measurement that could not support it');
    });

    test('a stall shorter than the window is not an eviction', () async {
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(40, prefix: 'CN03.BLIP');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));
      final state = panel.session.subscriptions.get('page-1')!;

      var value = 0;
      void run(int ticks, {required bool acking}) {
        for (var t = 0; t < ticks; t++) {
          plant.api.setValues({for (final key in keys) key: ++value});
          plant.tick();
          if (acking) panel.buffer.recordAck('page-1', state.seq);
        }
      }

      run(10, acking: true);
      // Long enough to open the window and to put the gap well past the
      // threshold, nowhere near long enough to close it.
      run(160, acking: false);
      expect(panel.session.sentCloseCode, isNull,
          reason: 'a burst is not a stall. A link that falls behind and '
              'catches up — a page change, a GC pause, a switch with a busy '
              'minute — must not be evicted for it');

      // Recovery, and then a SECOND excursion — which is the only shape that
      // actually tests the reset.
      //
      // §5.3 calls the reset branch load-bearing and says why: a window that
      // accumulates with no recovery signal evicts every panel eventually,
      // the mistake `send_buffer.dart`'s peak window already records once.
      // **But a case that stops at "it caught up and was not evicted" does not
      // pin it**, and this one did until sabotage (f) said so: while the
      // client is acking the gap is zero, so the verdict never reaches its
      // eviction check and a stale `gapSinceMs` sits there doing nothing
      // visible. It only bites on the *next* bad minute — which is exactly
      // when an operator would experience it, as a disconnect with no
      // proportion to what just happened.
      run(400, acking: true);
      expect(panel.session.sentCloseCode, isNull,
          reason: 'the client caught up');

      run(160, acking: false);
      expect(panel.session.sentCloseCode, isNull,
          reason: 'a second short stall, long after the first one ended, is '
              'judged on its own window. Carrying the old one forward would '
              'evict this panel on the first tick of its second bad minute — '
              'and every panel in the plant eventually, each on whatever tick '
              'it happened to have its second bad minute on');
    });
  });

  group('Arm 2 — a healthy fast producer is never evicted', () {
    test('1800 handles a tick for 400 ticks, and every latest value lands',
        () async {
      // 16-02 §2.3, exactly: no fault, injected clock, the real engine, and
      // the shipping config. At 1800 changed handles a tick this panel was
      // evicted after 202 ticks — 10.1 s — with a 4004 whose reason told it it
      // could not keep up, on a rig where it was keeping up perfectly. A
      // 1500-key page is the size this project's own fan-out benchmark uses.
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(1800, prefix: 'CN02.LOAD');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));
      final handle = plant.handles.handleFor(keys.first);

      // Every key to the *same* value each tick, so "the latest value" is one
      // number rather than one per key: the assertion below is about which
      // tick's data landed, and a per-key counter would make it about which
      // key was read.
      var value = 0;
      for (var t = 0; t < 400; t++) {
        value = t;
        plant.api.setValues({for (final key in keys) key: value});
        plant.tick();
      }

      expect(panel.session.sentCloseCode, isNull,
          reason: 'a page of fast struct members is what this gateway exists '
              'to serve. Evicting it every 10.1 s and telling it it cannot '
              'keep up produces a reconnect loop into the same wall, and the '
              'panel had done nothing wrong — the number the verdict read was '
              'the server\'s own production');

      expect(panel.updates.last.changes[handle]?.v, value,
          reason: 'sparing the panel is worth nothing if it is being fed '
              'stale values. The last frame carries the last value the plant '
              'produced, which is the property conflation is for');
    });
  });

  group('Arm 3 — a PLC reconnect does not take the fleet down at once', () {
    test('five subscribed panels survive a republish-everything burst',
        () async {
      // The shape: an upstream reconnect republishes every tag, so every
      // subscribed session blows the soft ceiling on the same tick. The
      // failure is not one panel disconnecting — it is every screen in the
      // plant going dark simultaneously, and then reconnecting together into
      // the burst that is still running (T-16-08d).
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(1500, prefix: 'CN04.PLC');
      final panels = [
        for (var i = 0; i < 5; i++)
          await plant.connect('page-$i', keys, buffer: shipping(config)),
      ];

      var value = 0;
      for (var t = 0; t < 300; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
      }

      final closed = [
        for (final panel in panels)
          if (panel.session.sentCloseCode != null) panel.sub,
      ];
      expect(closed, isEmpty,
          reason: 'a synchronised mass disconnect is the worst shape this '
              'verdict can take: it is indistinguishable from the gateway '
              'dying, and it arrives precisely when the plant has just come '
              'back and every operator is looking at a screen');
    });
  });

  group('Arm 4 — the hard ceilings still bite', () {
    // **The most important arm in the file.** Arms 2, 3, 5 and 7 are all
    // negative — "is never evicted" — and a server that evicts nobody at all
    // satisfies every one of them. This arm is the only thing distinguishing
    // "spares the healthy" from "has no backpressure", and it is what makes
    // buying the negative arms by deleting the ceilings impossible.
    test('past maxPending is still 4004, with the count and the limit',
        () async {
      final plant = Plant(config: ServerConfig(tick: ServerConfig.maxTick));
      final keys = plant.seed(10, prefix: 'CN05.FLOOD');
      final panel = await plant.connect('page-1', keys,
          buffer: ConflatingSendBuffer(maxPending: 6));

      plant.api.setValues({for (final key in keys) key: 1});
      await pumpEventQueue();
      expect(panel.buffer.pendingCount, greaterThan(6),
          reason: 'ten changed handles clear a ceiling of six; if they did '
              'not, what follows would pass for the wrong reason');
      plant.tick();

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'the hard ceiling is a memory ceiling and stays hard '
              'whatever any ack says (T-16-02b / T-16-08c). A client whose '
              'buffer genuinely explodes is still evicted');
      // `sentCloseCode` is recorded synchronously by the tick that decided;
      // the sentence only reaches the `closeChannel` seam when the teardown
      // it started gets a turn.
      await pumpEventQueue();
      expect(panel.closes.single.reason, contains('exceeded hard limit'));
      expect(panel.closes.single.reason, contains('6'),
          reason: 'the limit the client actually hit, not a generic sentence');
    });

    test('past maxPendingBytes is still 4004, and it is a separate ceiling',
        () async {
      // Separate from the arm above because the two ceilings answer different
      // questions — entries and bytes — and 03-REVIEW WR-04's whole point is
      // that 4096 arbitrarily large entries is a heap, not a queue. Sabotage
      // (d) removes this one alone and this arm is what must go red for it.
      final plant = Plant(config: ServerConfig(tick: ServerConfig.maxTick));
      final panel = await plant.connect('page-1', plant.seed(1, prefix: 'CN05.B'),
          buffer: ConflatingSendBuffer(maxPending: 100_000, maxPendingBytes: 4096));

      // Six entries of 1000 bytes: each one comfortably under the whole-lane
      // ceiling `putPriority` refuses at the door (10-REVIEW WR-05), and six
      // of them over it. Accumulation is `poll`'s question, which is the
      // ceiling being asserted here.
      for (var i = 0; i < 6; i++) {
        panel.buffer.putPriority('x' * 1000);
      }
      plant.tick();

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'the byte ceiling is the one that stops one megabyte-scale '
              'parse-error echo per tick from becoming a heap');
      await pumpEventQueue();
      expect(panel.closes.single.reason, contains('byte limit'));
    });
  });

  group('Arm 5 — conflation is still not eviction', () {
    test('held just under the ceiling for 40 ticks, never evicted, never stale',
        () async {
      // G5's paired boundary (`slow_link_gate_test.dart`), restated on the
      // server side of the wire. The client-side row asserts the same pair
      // from the far end; if these two ever disagree, one of them is lying
      // about where the ceiling is.
      final plant = Plant(config: ServerConfig(tick: ServerConfig.minTick));
      final keys = plant.seed(9, prefix: 'CN06.EDGE');
      final panel = await plant.connect('page-1', keys,
          buffer: ConflatingSendBuffer(maxPending: 10));
      final handle = plant.handles.handleFor(keys.first);

      var value = 0;
      for (var t = 0; t < 40; t++) {
        value = t;
        plant.api.setValues({for (final key in keys) key: value});
        plant.tick();
      }

      expect(panel.session.sentCloseCode, isNull,
          reason: 'nine changed handles against a ceiling of ten is a busy '
              'panel, not a failing one, for as long as it likes');
      expect(panel.updates.last.changes[handle]?.v, value,
          reason: 'and it is being served the latest value on every tick, '
              'which is what makes the previous expectation worth having');
    });
  });

  group('Arm 6 — the ack is a claim by the party being judged', () {
    test('an over-reporting client cannot acknowledge what was never sent',
        () async {
      // T-16-02a / T-16-08a. Without the clamp, eviction becomes something the
      // client can veto: a panel that has stopped reading answers every beat
      // with a sequence far beyond anything the server produced, the gap is
      // permanently negative, and the stuck reader grows this isolate's heap
      // for ever — one isolate that serves every screen in the plant.
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(40, prefix: 'CN07.LIAR');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));

      var value = 0;
      for (var t = 0; t < 10; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
        panel.buffer.recordAck('page-1', 1_000_000_000);
      }

      // Nothing further is acknowledged, truthfully or otherwise. A client
      // whose lie was believed would now be immune.
      var ticks = 0;
      while (panel.session.sentCloseCode == null && ticks < 2000) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
        ticks++;
      }

      expect(panel.session.sentCloseCode, CloseCodes.backpressureOverrun,
          reason: 'the ack is clamped to sequences this server actually sent, '
              'so over-reporting buys the client nothing. Under-reporting is '
              'left alone deliberately: a client that evicts itself is '
              'harmless, and the reconnect costs it a snapshot');
      await pumpEventQueue();
      expect(panel.closes.single.reason, contains('delivery stalled'));
    });

    test('an ack naming a subscription this session does not hold is dropped',
        () async {
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(5, prefix: 'CN07.SCOPE');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));

      // Silently, and without creating an entry: a map keyed by whatever a
      // peer puts in an ack is a peer-controlled allocation on a path that
      // runs every heartbeat (§5.2 rule 3).
      panel.buffer.recordAck('a-page-nobody-subscribed', 42);
      expect(panel.buffer.deliveryGapOf('a-page-nobody-subscribed'), isNull);

      var value = 0;
      for (var t = 0; t < 40; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
      }
      expect(panel.session.sentCloseCode, isNull,
          reason: 'a stray ack must not be able to open a window against a '
              'subscription, nor to hold one open');
    });

    test('an ack never runs backwards within one establishment', () async {
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(5, prefix: 'CN07.BACK');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));
      final state = panel.session.subscriptions.get('page-1')!;

      var value = 0;
      for (var t = 0; t < 10; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
      }
      panel.buffer.recordAck('page-1', state.seq);
      expect(panel.buffer.deliveryGapOf('page-1'), 0);

      // Beats can be reordered on the wire and a client can restart its own
      // counter; neither is evidence that a frame was un-applied.
      panel.buffer.recordAck('page-1', 1);
      expect(panel.buffer.deliveryGapOf('page-1'), 0,
          reason: 'a late beat carrying an older ack is stale news, not a '
              'regression, and treating it as one would open a window against '
              'a client that is perfectly healthy');
    });
  });

  group('Arm 7 — a client that never acks is not judged by the ack', () {
    test('no ack, a huge gap, and no eviction at any point', () async {
      // §5.3's first line: `if (ackedSeq == null) skip`. The gateway and the
      // panels do not ship together, so a `ping` with no ack must stay valid
      // for ever — and a client that has never acknowledged anything has made
      // no claim for the server to hold it to. Evicting it would be a fleet
      // outage on the morning of an upgrade.
      final config = ServerConfig(tick: ServerConfig.minTick);
      final plant = Plant(config: config);
      final keys = plant.seed(40, prefix: 'CN08.OLD');
      final panel = await plant.connect('page-1', keys, buffer: shipping(config));

      var value = 0;
      for (var t = 0; t < 600; t++) {
        plant.api.setValues({for (final key in keys) key: ++value});
        plant.tick();
      }

      expect(panel.session.sentCloseCode, isNull,
          reason: 'six hundred ticks — thirty seconds of tick time, three '
              'windows — with a gap of six hundred frames and no ack. An old '
              'client is governed by the hard ceilings and by the heartbeat '
              'reaper, exactly as it was before this plan');
    });
  });
}
