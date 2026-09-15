/// Every server number has one home, and the combinations that cannot work
/// are refused at construction rather than at 3 a.m.
///
/// The load-bearing case here is the heartbeat/ping relationship. 03-RESEARCH
/// Finding 7 measured it: with `pingInterval: 2s` and a TCP relay black-holing
/// traffic both ways, the server reaped the dead client 3.70 s after the
/// blackhole — 1.85× the interval. At the design's 20 s interval that is a
/// ~37 second window in which the gateway still believes a dead panel is
/// alive, holding its subscriptions, its send buffer and its upstream
/// monitored items. Without the construction rule asserted below, that window
/// is one config line away, and nothing in the running system complains about
/// it: the server simply detects half-open panels late, which is the one
/// thing SRV-05 exists to prevent.
///
/// The tick band (SRV-03) is the other one. A 500 ms tick still runs, still
/// passes every functional test, and is a silently different product — an
/// operator watching a 500 ms screen is watching a slideshow of the plant.
library;

import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:test/test.dart';

/// Matches an `ArgumentError` whose message names every one of [fragments].
///
/// The point is not that it threw — it is that an operator reading the crash
/// can see which two numbers disagreed without opening the source.
Matcher argumentErrorNaming(List<String> fragments) => isA<ArgumentError>()
    .having((e) => e.message.toString(), 'message',
        allOf(fragments.map(contains).toList()));

void main() {
  group('defaults', () {
    test('every knob has a default, and they are the researched numbers', () {
      final c = ServerConfig();

      expect(c.tick, const Duration(milliseconds: 100),
          reason: 'the tick is how often the screen can change; changing this '
              'default changes what operators see, not just a number');
      expect(c.heartbeatDeadline, const Duration(seconds: 6),
          reason: '6 s is OPC UA\'s 3× LifetimeCount ratio over a 2 s app '
              'heartbeat — the deadline that reaps a dead panel in seconds');
      expect(c.pingInterval, const Duration(seconds: 20),
          reason: 'the WS ping is NAT keepalive and backstop only; it is not '
              'the reaper, and a shorter interval would imply it is');
      expect(c.stallThreshold, const Duration(milliseconds: 300),
          reason: 'three ticks: comfortably above the +/-2 ms idle drift '
              'noise floor, so a reported stall means the event loop really '
              'stopped serving panels');
      expect(c.allowedOrigins, isEmpty,
          reason: 'an empty list rejects every browser Origin with 403 and '
              'leaves the non-browser panels, which send no Origin, working; '
              'Phase 6 supplies the real list');
      expect(c.maxPending, greaterThan(0));
      expect(c.peakThreshold, isNull,
          reason: 'the soft PRODUCTION ceiling is off by default since 16-08. '
              'It was never the slow-consumer defence — at 1024 a panel that '
              'had stopped reading produced 41 pending entries a tick, while '
              'a healthy 1100-key page was evicted after 10.1 s and told it '
              'could not keep up (16-02-DECISION.md §2.3, §5.4). What '
              'replaced it measures delivery, and lives on the buffer as '
              'ackGapThreshold. The two HARD ceilings did not move');
      expect(c.peakWindowMs, 10_000,
          reason: 'matches ConflatingSendBuffer\'s own default, so the buffer '
              'this config configures behaves as its tests describe');
      expect(c.maxKeysPerSubscribe, greaterThan(1500),
          reason: 'a real panel carries about 1500 keys; a ceiling below that '
              'rejects a legitimate screen');
      expect(c.maxSubscriptionsPerSession, greaterThan(0));
    });

    test('the default combination is itself legal', () {
      expect(ServerConfig.new, returnsNormally,
          reason: 'a default that its own validation rejects is a server that '
              'cannot start');
    });
  });

  group('the tick band', () {
    test('a tick outside 50-100 ms is refused, naming the bound', () {
      expect(
          () => ServerConfig(tick: const Duration(milliseconds: 500)),
          throwsA(argumentErrorNaming(['500', '50', '100'])),
          reason: 'a 500 ms tick is a slideshow of the plant, and it would '
              'otherwise start and pass every functional test');

      expect(() => ServerConfig(tick: const Duration(milliseconds: 40)),
          throwsA(argumentErrorNaming(['40', '50', '100'])),
          reason: 'below the band the server burns a core to redraw screens '
              'nobody can read that fast');
    });

    test('both ends of the band are legal', () {
      expect(() => ServerConfig(tick: const Duration(milliseconds: 50)),
          returnsNormally);
      expect(() => ServerConfig(tick: const Duration(milliseconds: 100)),
          returnsNormally);
    });
  });

  group('liveness', () {
    test('heartbeat deadline at or beyond the ping interval is refused', () {
      expect(
          () => ServerConfig(
                heartbeatDeadline: const Duration(seconds: 25),
                pingInterval: const Duration(seconds: 20),
              ),
          throwsA(argumentErrorNaming(['25000 ms', '20000 ms'])),
          reason: 'a deadline the ping could beat leaves a ~37 s window in '
              'which the gateway believes a dead panel is alive and keeps '
              'serving its subscriptions to nobody');

      expect(
          () => ServerConfig(
                heartbeatDeadline: const Duration(seconds: 20),
                pingInterval: const Duration(seconds: 20),
              ),
          throwsA(argumentErrorNaming(['20000 ms'])),
          reason: 'equal is not safe either: detection was measured at 1.85x '
              'the ping interval, so a tie is still lost by the heartbeat');
    });

    test('a deadline no client could beat is refused', () {
      // **07-REVIEW WR-01, the other half.** The only bound here was the
      // relationship with `pingInterval`, which is a bound from above. Nothing
      // bounded it from below, and a deadline below the reference client's
      // floor is a gateway that reaps every healthy panel in the plant once a
      // cycle for ever — 07-08's measurement, reinstated by configuration with
      // the client's heartbeat pump running and its counters climbing.
      //
      // The number is three times `ClientConfig.heartbeatFloor`'s 1 s default,
      // for the reason the pump derives its own period the same way: the
      // client's skip-on-traffic rule means the gateway can see up to two
      // floors of silence between beats, so two floors is the failure and
      // three is the smallest deadline with any margin at all.
      expect(
          () => ServerConfig(heartbeatDeadline: const Duration(seconds: 2)),
          throwsA(argumentErrorNaming(['2000 ms', '3000 ms'])),
          reason: 'a gateway configured to reap after two seconds accepted the '
              'configuration silently. Every panel in the plant then resyncs '
              'its whole page every two seconds, and the only symptom from '
              'outside is that sessionCount keeps returning to normal');

      expect(
          () => ServerConfig(
                heartbeatDeadline: ServerConfig.defaultMinHeartbeatDeadline,
              ),
          returnsNormally,
          reason: 'the floor itself must be usable, or the bound is really a '
              'bound one millisecond higher and nobody can tell');
    });

    test('a gateway may go below the floor by saying so', () {
      // The escape, and it is the same one `ClientConfig.deadlineFloor` is: a
      // liveness case has to watch a reap happen inside its own budget, and a
      // suite that waited three seconds per arm is a suite somebody deletes.
      // Lowering the floor is a sentence the caller has to write; inheriting a
      // 400 ms deadline from a default is not.
      expect(
          () => ServerConfig(
                heartbeatDeadline: const Duration(milliseconds: 400),
                minHeartbeatDeadline: const Duration(milliseconds: 100),
              ),
          returnsNormally);
      expect(
          () => ServerConfig(
                heartbeatDeadline: const Duration(milliseconds: 50),
                minHeartbeatDeadline: const Duration(milliseconds: 100),
              ),
          throwsA(argumentErrorNaming(['50 ms', '100 ms'])),
          reason: 'the lowered floor is still a floor; a knob that stops being '
              'checked once it is set is not one');
    });

    test('a deadline comfortably inside the ping interval is accepted', () {
      expect(
          () => ServerConfig(
                heartbeatDeadline: const Duration(seconds: 6),
                pingInterval: const Duration(seconds: 20),
              ),
          returnsNormally,
          reason: 'the rule must refuse the unfireable case only; refusing '
              'the intended configuration would be worse than no rule');
    });

    test('a stall threshold inside the measurement noise is refused', () {
      expect(() => ServerConfig(stallThreshold: const Duration(milliseconds: 1)),
          throwsA(argumentErrorNaming(['1 ms'])),
          reason: 'idle drift alone measured +/-2 ms, so a 1 ms threshold '
              'reports a stalled event loop on a server doing nothing — and '
              'an alarm that is always on is an alarm nobody reads');
    });
  });

  group('the denial-of-service ceilings', () {
    test('a non-positive maxKeysPerSubscribe is refused', () {
      expect(() => ServerConfig(maxKeysPerSubscribe: 0),
          throwsA(argumentErrorNaming(['maxKeysPerSubscribe', '0'])),
          reason: 'zero means no panel can subscribe to anything, which is a '
              'server that starts and then serves nothing');
      expect(() => ServerConfig(maxKeysPerSubscribe: -1),
          throwsA(argumentErrorNaming(['maxKeysPerSubscribe'])));
    });

    test('a non-positive maxSubscriptionsPerSession is refused', () {
      expect(() => ServerConfig(maxSubscriptionsPerSession: 0),
          throwsA(argumentErrorNaming(['maxSubscriptionsPerSession', '0'])));
      expect(() => ServerConfig(maxSubscriptionsPerSession: -3),
          throwsA(argumentErrorNaming(['maxSubscriptionsPerSession'])));
    });

    test('a non-positive maxFrameBytes or maxPendingBytes is refused', () {
      expect(() => ServerConfig(maxFrameBytes: 0),
          throwsA(argumentErrorNaming(['maxFrameBytes'])));
      expect(() => ServerConfig(maxPendingBytes: -1),
          throwsA(argumentErrorNaming(['maxPendingBytes'])));
    });

    test('the ingress ceiling has room for the largest legitimate request',
        () {
      final config = ServerConfig();
      // A subscribe carrying the full key allowance, at a generous 60 bytes
      // per plant tag (`CN01.MOT01.speed` is 16). The ceiling exists to refuse
      // an order of magnitude, so a default that could refuse a real page
      // config would be a denial of service written as a defence.
      expect(config.maxFrameBytes,
          greaterThan(config.maxKeysPerSubscribe * 60),
          reason: 'the largest request a real panel sends is a page config of '
              'about ${config.maxKeysPerSubscribe} keys');
    });

    // --- the pre-hello budget (16-09, WSH-13) ---

    test('the pre-hello budget\'s defaults are the shipping numbers', () {
      final c = ServerConfig();

      expect(c.preHelloDeadline, const Duration(seconds: 2),
          reason: 'the number `pre_hello_budget_test.dart` is written against '
              'as a literal — the two are pinned to each other here so they '
              'cannot drift silently — and the number a slow but legitimate '
              'panel has to get its hello out in');
      expect(c.maxUnhelloedSessions, 64,
          reason: 'several times the plant\'s panel count, so the worst '
              'legitimate burst — every screen reconnecting at once after a '
              'gateway restart, all of them un-helloed for the same instant — '
              'fits with room to spare');
    });

    test('the pre-hello deadline is shorter than any heartbeat deadline a '
        'real gateway may run', () {
      expect(ServerConfig().preHelloDeadline,
          lessThan(ServerConfig.defaultMinHeartbeatDeadline),
          reason: 'not merely shorter than the 6 s default: below the floor, '
              'so no legal reconfiguration of heartbeatDeadline can make the '
              'pre-hello deadline the later of the two and quietly turn it '
              'into a knob with no effect');
    });

    test('the default is derived from heartbeatDeadline, not typed beside it',
        () {
      // The property that keeps every previously-coherent configuration
      // coherent. `liveness_test.dart` runs a 400 ms heartbeat deadline
      // deliberately; a fixed 2 s pre-hello default would have refused it at
      // construction — a new field breaking configurations it has nothing to
      // say about.
      final fast = ServerConfig(
        heartbeatDeadline: const Duration(milliseconds: 400),
        minHeartbeatDeadline: const Duration(milliseconds: 100),
      );
      expect(
          fast.preHelloDeadline,
          const Duration(milliseconds: 400) ~/
              ServerConfig.preHelloShareOfHeartbeat);
      expect(fast.preHelloDeadline, lessThan(fast.heartbeatDeadline));
    });

    test('a pre-hello deadline at or above the heartbeat deadline is refused',
        () {
      expect(
          () => ServerConfig(preHelloDeadline: const Duration(seconds: 6)),
          throwsA(argumentErrorNaming(
              ['preHelloDeadline', '6000 ms', 'heartbeatDeadline'])),
          reason: 'an un-helloed socket is already closed at the heartbeat '
              'deadline — _LastSeen refuses to move until the handshake lands '
              '— so a pre-hello deadline that is not strictly shorter fires no '
              'earlier than the reaper that already existed. A knob that '
              'cannot change the outcome is worse than no knob: it reads in a '
              'config diff as a defence that is switched on');
      expect(
          () => ServerConfig(preHelloDeadline: const Duration(seconds: 30)),
          throwsA(argumentErrorNaming(['preHelloDeadline', '30000 ms'])));
    });

    test('a non-positive pre-hello deadline is refused', () {
      expect(() => ServerConfig(preHelloDeadline: Duration.zero),
          throwsA(argumentErrorNaming(['preHelloDeadline', '0 ms'])),
          reason: 'zero closes every connection at the instant it is upgraded, '
              'so no panel can ever say hello — and the only symptom from '
              'outside is a sessionCount that keeps coming back to zero, '
              'which looks exactly like a plant that is switched off');
      expect(
          () => ServerConfig(
              preHelloDeadline: const Duration(milliseconds: -1)),
          throwsA(argumentErrorNaming(['preHelloDeadline'])));
    });

    test('a non-positive maxUnhelloedSessions is refused', () {
      expect(() => ServerConfig(maxUnhelloedSessions: 0),
          throwsA(argumentErrorNaming(['maxUnhelloedSessions', '0'])),
          reason: 'zero refuses every connection before it can authenticate, '
              'which is a gateway that binds a port and then serves nobody');
      expect(() => ServerConfig(maxUnhelloedSessions: -1),
          throwsA(argumentErrorNaming(['maxUnhelloedSessions'])));
    });

    test('the un-helloed budget has room for the whole plant reconnecting',
        () {
      final c = ServerConfig();
      // A panel carries about 1500 keys and subscribes in one call, so
      // `maxKeysPerSubscribe / 1500` is this config's own idea of how many
      // pages a screen is — not a count of panels. The sizing that matters is
      // simpler and is asserted directly: the budget must exceed the number of
      // screens that can be switched on at once, and the plant is tens.
      expect(c.maxUnhelloedSessions, greaterThan(32),
          reason: 'the cap is aimed at an attacker and must never be reachable '
              'by the plant. Every panel reconnecting at once after a gateway '
              'restart is un-helloed for the same instant, and a cap under '
              'that count would refuse half the screens in the factory every '
              'time the gateway was updated');
    });

    // --- end of the pre-hello budget ---

    test('a non-positive maxPending is refused', () {
      expect(() => ServerConfig(maxPending: 0),
          throwsA(argumentErrorNaming(['maxPending'])),
          reason: 'the hard ceiling is what converts silent server-heap '
              'growth into a visible reconnect; zero disconnects everyone on '
              'the first pending message');
    });
  });

  group('the write-outcome window', () {
    test('a gateway that remembers nothing is refused', () {
      expect(() => ServerConfig(writeOutcomeTtl: Duration.zero),
          throwsA(argumentErrorNaming(['writeOutcomeTtl'])),
          reason: 'writeStatus answers "never received" only for a command '
              'minted inside this window. A zero window makes that the answer '
              'to every re-query, and "never received" is the one outcome '
              'that tells an operator it is safe to actuate the machine '
              'again');
    });

    test('the default outlives a reconnect', () {
      // Backoff is capped at 30 s (CLAUDE.md), so a client that dropped mid
      // write has one full retry cycle plus its resync inside the window. A
      // TTL under it would turn "the link flapped" into "we forgot", and a
      // forgotten outcome is one an operator has to establish by reading the
      // value back.
      expect(ServerConfig().writeOutcomeTtl,
          greaterThan(const Duration(seconds: 30)));
    });
  });

  test('the config is data, not a clock', () {
    final a = ServerConfig();
    final b = ServerConfig();
    expect(a.tick, b.tick,
        reason: 'two configs built from the same arguments must be the same '
            'configuration — nothing here may read a clock at construction');
  });
}
