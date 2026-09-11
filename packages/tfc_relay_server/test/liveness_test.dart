/// SRV-05, the liveness half: a client that stops talking is reaped on the
/// **app-level heartbeat clock**, and provably sooner than the WebSocket ping
/// could have noticed.
///
/// **Why the relationship is an explicit case and not an implicit property.**
/// 03-RESEARCH Finding 7 measured half-open detection through `pingInterval`
/// at 1.85x the interval — connected at 0 ms, blackhole on at 308 ms, the
/// server's stream ending at 4008 ms with `pingInterval: 2s`. At the design's
/// 20 s interval that is a **~37 second** window in which the gateway holds a
/// dead panel's subscriptions, its buffer and (from Phase 8) its upstream
/// monitored items, against a project constraint that says half-open
/// connections are detected in seconds. `ServerConfig` already refuses to
/// construct a config where the deadline could lose that race; this file is
/// the other half — it watches the race actually being won, over a real
/// socket, with the ping interval set far enough above the deadline that a
/// ping-based reap is arithmetically impossible in the window observed.
///
/// **What each arm can and cannot see.** The silent arm keeps the socket
/// perfectly healthy, so the client observes the close code itself — which is
/// the only observation worth making about a close the server initiated
/// (`web_socket_channel` #1698). The black-holed arm cannot: the close frame
/// the server writes is dropped by the proxy in the same direction as
/// everything else, so what that arm asserts is the server's own record and
/// the release of the resources. Both matter, and neither substitutes for the
/// other — the plant sees the black-holed shape and an operator sees the
/// coded one.
///
/// **The negative control is not decoration.** A reaper that reaps everything
/// passes every arm above. The heartbeating arm is what makes them mean
/// something.
///
/// Timing is asserted as a window against `bands.dart`, never as an instant.
@Tags(['ws', 'faults'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/bands.dart';
import 'support/ws_harness.dart';

/// The heartbeat deadline every arm here runs against.
///
/// Hundreds of milliseconds rather than the 6 s default, and that is a
/// statement about the test rather than about the product: the deadline is
/// configuration, `ServerConfig` validates the *relationship* between it and
/// the ping interval rather than any absolute value, and a suite that waited
/// six seconds per arm is a suite someone eventually deletes. What is being
/// judged is the mechanism, and the mechanism does not know what the number
/// is.
const _deadline = Duration(milliseconds: 400);

/// The ping interval these arms run against.
///
/// Ten times the deadline, so [_earliestPingCouldNotice] lands far outside
/// every window asserted below and the relationship arm is not a coin flip on
/// a busy runner.
const _pingInterval = Duration(seconds: 4);

/// Finding 7's measured ratio of ping-based half-open detection to the ping
/// interval.
///
/// **Provenance, because a constant like this is otherwise indistinguishable
/// from a guess:** 03-RESEARCH Finding 7, `e4.dart`, executed — a TCP relay
/// black-holing traffic both directions with the socket kept open, with
/// `pingInterval: 2s`. The client connected at 0 ms, the blackhole went on at
/// 308 ms, and the server saw its stream end at 4008 ms: 3.70 s after the
/// blackhole, which is 1.85x the 2 s interval. It is used here as a **lower
/// bound** on how long a ping-based reap would have taken, which is the
/// conservative direction — if the real factor is larger, the hole this file
/// is about is bigger and the assertion is easier, never wrong.
const measuredPingDetectionFactor = 1.85;

/// The earliest instant a ping-based reap could have accounted for a dead
/// client, at [_pingInterval].
final _earliestPingCouldNotice = _pingInterval * measuredPingDetectionFactor;

/// How long a reap may take: the deadline, plus the tick that sweeps for it,
/// plus the platform's band.
final _reapCeiling = _deadline + ServerConfig.minTick + ceiling;

/// The budget for waiting on a reap. Generously above [_reapCeiling] so a
/// missed reap fails on its own assertion — naming the window it missed —
/// rather than on a timeout that names nothing.
const _reapBudget = Duration(seconds: 3);

const _connectBudget = Duration(seconds: 5);
const _rpcBudget = Duration(seconds: 2);

/// The keys every arm subscribes to, so a reap has listeners to release.
const _keys = ['CN01.MOT01.speed', 'CN01.MOT02.speed', 'CN01.SEN01.state'];

const _sub = 'page-under-test';

ServerConfig _reaperConfig() => ServerConfig(
      tick: ServerConfig.minTick,
      heartbeatDeadline: _deadline,
      // Said out loud, because [_deadline] is far below the floor a real
      // gateway is held to (07-REVIEW WR-01): a panel beating at
      // `ClientConfig.heartbeatFloor` cannot meet 400 ms, so a *gateway*
      // configured this way reaps every healthy screen in the plant once a
      // cycle. These arms are about the mechanism and not the number — see the
      // library doc above — so the floor is lowered here rather than the arms
      // being made to wait three seconds each.
      minHeartbeatDeadline: _deadline,
      pingInterval: _pingInterval,
    );

/// How many listeners the backing fake currently has attached for [_keys].
///
/// Reached through the node the fake hands out, which is the same object the
/// session's subscribe handler attached to (`session_handlers.dart:183` calls
/// `api.listen(key)`). Asserted as a **delta against a baseline** rather than
/// against zero: the fake attaches listeners of its own for its freshness
/// bookkeeping, and a test that demanded zero would be asserting something
/// about the fake instead of about the gateway.
int _attachedListeners(StateManApi api) => [
      for (final key in _keys) (api.listen(key) as ValueStoreNode).listenerCount
    ].fold(0, (a, b) => a + b);

/// Says hello and subscribes, and hands back the session the server built.
///
/// Returns after the subscribe answer has landed, so the caller's stopwatch
/// starts from the last frame the server saw — which is what "silent since"
/// means.
Future<void> _openAndWatch(RelayFixture fixture) async {
  await within(fixture.ready, 'the server to accept a real client',
      budget: _connectBudget);
  for (final key in _keys) {
    fixture.served.setValue(key, 0);
  }
  await fixture.hello(budget: _rpcBudget);
  await fixture.request(Methods.subscribe,
      params: SubscribeParams(sub: _sub, keys: _keys).toJson(),
      what: 'the subscribe answer over a real socket',
      budget: _rpcBudget);
}

void main() {
  group('SRV-05 — the heartbeat deadline is the reaper', () {
    test('a silent client is reaped on the heartbeat clock', () async {
      final fixture = relayFixture(config: _reaperConfig());
      final listenersBefore = _attachedListeners(fixture.served);
      await _openAndWatch(fixture);

      final session = fixture.server.sessions.sessions.single;
      final watched = session.subscriptions.get(_sub)!;
      expect(watched.listenerCount, _keys.length,
          reason: 'the arm is worthless unless the session actually holds '
              'listeners on the plant before it is reaped');
      expect(_attachedListeners(fixture.served) - listenersBefore,
          _keys.length,
          reason: 'and unless those listeners are attached to the backing '
              'source rather than to something the session owns privately');

      // From here the client says nothing at all. Its socket stays healthy —
      // the kernel still answers the server's WS pings — which is exactly the
      // shape the ping cannot see and the heartbeat deadline can.
      final silence = Stopwatch()..start();
      final close = await fixture.awaitClose(
          'the client observing the heartbeat reap',
          budget: _reapBudget);
      silence.stop();

      // Reported, not just asserted: a window that passes tells you nothing
      // about how much room it had, and the margin is what says whether the
      // sweep is landing on the tick after the deadline or four ticks later.
      print('silent client: reaped ${silence.elapsedMilliseconds} ms after its '
          'last frame, against a ${_deadline.inMilliseconds} ms deadline and a '
          '${_reapCeiling.inMilliseconds} ms $platformName window');

      expect(close.closeCode, CloseCodes.heartbeatTimeout,
          reason: 'a panel disconnected with a bare 1006 cannot tell a '
              'crashed gateway from a gateway that stopped hearing it, and '
              'those call for opposite responses: one is reconnect, the other '
              'is fix your heartbeat. 4003 is the sentence that tells them '
              'apart');
      expect(close.closeReason, contains('heartbeat'),
          reason: 'the reason an operator reads should name the mechanism '
              'without sending them to the source');

      expect(silence.elapsed, greaterThan(_deadline - slack),
          reason: 'reaped after ${silence.elapsedMilliseconds} ms against a '
              '${_deadline.inMilliseconds} ms deadline, judged on the '
              '$platformName band. A reaper that fires early disconnects '
              'healthy panels on a slow network, which is the failure mode '
              'that gets liveness checking turned off in the field');
      expect(silence.elapsed, lessThan(_reapCeiling),
          reason: 'the reap must land within the deadline plus the one tick '
              'that sweeps for it plus the $platformName band '
              '(${_reapCeiling.inMilliseconds} ms); it took '
              '${silence.elapsedMilliseconds} ms. Longer than that and the '
              'sweep is not running on the tick it is supposed to be part of');

      await within(fixture.untilNoSessions(),
          'the reaped session leaving the registry', budget: _reapBudget);
      expect(fixture.server.sessions.subscriptionCount, 0,
          reason: 'a reap that leaves the subscription behind has released a '
              'socket and kept everything the socket was expensive for');
      expect(watched.listenerCount, 0,
          reason: 'the session detached its own listeners');
      expect(_attachedListeners(fixture.served), listenersBefore,
          reason: 'and the backing source is back where it started. A '
              'listener that outlives its session keeps pushing a dead '
              'panel\'s values into a buffer nobody will ever drain, and a '
              'hundred of those is a shift\'s worth of memory held for panels '
              'that went home');
    });

    test('the reap beats the earliest possible ping timeout', () async {
      final fixture = relayFixture(config: _reaperConfig());
      await _openAndWatch(fixture);

      final silence = Stopwatch()..start();
      final close = await fixture.awaitClose(
          'the client observing the heartbeat reap',
          budget: _reapBudget);
      silence.stop();

      print('the race: reaped at ${silence.elapsedMilliseconds} ms; a '
          'ping-based reap could not have noticed before '
          '${_earliestPingCouldNotice.inMilliseconds} ms '
          '(${_pingInterval.inMilliseconds} ms x $measuredPingDetectionFactor, '
          'Finding 7)');

      expect(close.closeCode, CloseCodes.heartbeatTimeout);
      expect(
        silence.elapsed,
        lessThan(_earliestPingCouldNotice),
        reason: 'the reap took ${silence.elapsedMilliseconds} ms; the '
            'earliest a ping-based reap could have accounted for this client '
            'is ${_earliestPingCouldNotice.inMilliseconds} ms '
            '(${_pingInterval.inMilliseconds} ms interval x '
            '$measuredPingDetectionFactor, 03-RESEARCH Finding 7, measured). '
            'If this ever inverts, the gateway is back to detecting half-open '
            'panels on the ping — a ~37 second hole at the design\'s 20 s '
            'interval, during which the server serves a dead panel\'s '
            'subscriptions to nobody and holds its upstream monitored items '
            'against a plant that has moved on',
      );
      expect(silence.elapsed * 2, lessThan(_earliestPingCouldNotice),
          reason: 'and it wins by more than a hair: a relationship that only '
              'holds inside the measurement noise is not a relationship, it '
              'is a coin flip that happens to be passing today');
    });

    test('a black-holed client is reaped on the same clock', () async {
      final fixture = relayFixture(config: _reaperConfig(), withProxy: true);
      await _openAndWatch(fixture);
      final session = fixture.server.sessions.sessions.single;
      final listenersWhileWatching = _attachedListeners(fixture.served);

      // Traffic dropped both ways with the socket left open: the half-open
      // shape the plant actually produces when a panel's switch goes away.
      // The client cannot observe the close code here — the close frame is
      // dropped in the same direction as everything else — so this arm reads
      // the server's own record, which is what `sentCloseCode` is for.
      fixture.proxy.blackhole();
      final silence = Stopwatch()..start();
      await within(fixture.untilNoSessions(),
          'the server reaping the black-holed panel', budget: _reapBudget);
      silence.stop();

      print('black-holed client: reaped ${silence.elapsedMilliseconds} ms '
          'after the blackhole went on, against a '
          '${_reapCeiling.inMilliseconds} ms $platformName window');

      expect(session.sentCloseCode, CloseCodes.heartbeatTimeout,
          reason: 'a black-holed panel is reaped by the same mechanism and '
              'recorded under the same code as a merely silent one — the '
              'server cannot tell them apart, and it should not have to');
      expect(silence.elapsed, lessThan(_reapCeiling),
          reason: 'the black-holed panel was held for '
              '${silence.elapsedMilliseconds} ms against a window of '
              '${_reapCeiling.inMilliseconds} ms on the $platformName band');
      expect(_attachedListeners(fixture.served),
          lessThan(listenersWhileWatching),
          reason: 'the reap released the plant listeners the session held; '
              'this is the resource the ~37 second ping window is expensive '
              'about');
    });

    test('a client that keeps its heartbeat is left alone across three '
        'deadlines', () async {
      final fixture = relayFixture(config: _reaperConfig());
      await _openAndWatch(fixture);
      final session = fixture.server.sessions.sessions.single;

      // A heartbeat cadence, not a sleep used as synchronisation: this is the
      // client doing what a real panel does, and the case is about what the
      // server does not do while it happens.
      final period = _deadline ~/ 4;
      final survival = Stopwatch()..start();
      while (survival.elapsed < _deadline * 3) {
        await fixture.request(Methods.ping,
            what: 'a heartbeat over a real socket', budget: _rpcBudget);
        await Future<void>.delayed(period);
      }
      survival.stop();

      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'the client sent a heartbeat every '
              '${period.inMilliseconds} ms for ${survival.elapsedMilliseconds} '
              'ms — more than three ${_deadline.inMilliseconds} ms deadlines — '
              'and was reaped anyway. Without this arm a reaper that reaps '
              'every session on every tick passes every other case in this '
              'file');
      expect(session.sentCloseCode, isNull,
          reason: 'and the server recorded no close code for it either');
      expect(fixture.server.sessions.subscriptionCount, _keys.isEmpty ? 0 : 1,
          reason: 'a surviving session keeps what it was watching');
    });
  });
}
