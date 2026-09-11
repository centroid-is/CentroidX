/// WSH-02, the stuck-consumer half — **over the wire, end to end**.
///
/// `slow_consumer_test.dart` proves the verdict is correct when it is fed.
/// This file proves it is fed at all. 16-08 shipped `recordAck` with no
/// production caller: `ackedSeq` was null for every live session, the verdict
/// skipped every one of them by design, and a stuck reader was caught exactly
/// as slowly as it had always been. Nothing in that file could have noticed —
/// it calls `recordAck` itself.
///
/// **So every arm here drives the ack from the client end of a real socket**,
/// as a `ping` frame and nothing else, and reads the outcome the gateway
/// reaches on its own. The seam under test is `PingParams` →
/// `RelaySession._ping` → `ConflatingSendBuffer.recordAck`, and no arm may
/// call `recordAck` directly — an arm that did would pass with the wire
/// disconnected, which is precisely the state this plan found the code in.
///
/// **The negative arms are paired, deliberately** (the 14-13 house rule).
/// "A panel that keeps up is not evicted" and "a panel that sends no ack is
/// never judged" are both satisfied by a gateway that evicts nobody — which is
/// the gateway 16-08 shipped. They are only worth something beside the frozen-
/// ack arm, which acks and *is* evicted, on the same horizon, through the same
/// code. If that arm is ever deleted, delete these with it.
///
/// **The ack is a claim by the party being judged**, and this file must not
/// quietly strengthen that. The trust boundary is one clamp in `recordAck`;
/// over-reporting is pinned here as buying nothing, and under-reporting is
/// left alone on purpose, because a client that evicts itself is harmless.
@Tags(['ws', 'faults'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/server_config.dart';

import 'support/ws_harness.dart';

const _sub = 'page-1';
const _key = 'CN01.MOT01.speed';

/// The window the delivery verdict waits out, shortened for a wall-clock test.
///
/// **Set through `peakWindowMs` and not by reaching into the buffer**, because
/// that is the wiring production uses: `ackGapWindowMs` derives from
/// `peakWindowMs` (`send_buffer.dart`, 16-08), and `relay_server.dart` passes
/// `peakWindowMs` through from the config. An arm that mutated the buffer
/// directly would be green against a gateway that never wired the config at
/// all.
const _window = Duration(milliseconds: 400);

ServerConfig _config() => ServerConfig(
      tick: ServerConfig.minTick,
      peakWindowMs: _window.inMilliseconds,
    );

/// Every `u` frame the client has actually received, decoded.
List<UpdateParams> _updates(List<String> frames) {
  final updates = <UpdateParams>[];
  for (final frame in frames) {
    final decoded = jsonDecode(frame);
    if (decoded is! Map) continue;
    if (decoded['method'] != Methods.update) continue;
    updates.add(UpdateParams.fromJson(
        (decoded['params'] as Map).cast<String, Object?>()));
  }
  return updates;
}

/// The highest sequence this client has seen for [_sub], or null before the
/// first frame. **Read from the client's own inbound frames**, which is the
/// only number a real panel could honestly put in an ack.
int? _appliedSeq(RelayFixture fixture) {
  int? seq;
  for (final update in _updates(fixture.inbound)) {
    if (update.sub != _sub) continue;
    if (seq == null || update.seq > seq) seq = update.seq;
  }
  return seq;
}

/// Stands up a subscribed panel over a real socket and starts the plant
/// moving, so the gateway mints one sequence per tick for it.
Future<RelayFixture> _panel() async {
  final fixture = relayFixture(config: _config());
  await fixture.ready;
  await fixture.hello();
  fixture.served.setValue(_key, 0);
  await fixture.request(Methods.subscribe,
      params: const SubscribeParams(sub: _sub, keys: [_key]).toJson(),
      what: 'the subscribe answer over a real socket');
  return fixture;
}

/// The buffer the gateway is judging this session's link with.
ConflatingSendBuffer _buffer(RelayFixture fixture) =>
    fixture.server.sessions.sessions.single.buffer;

void main() {
  group('the delivery ack reaches the gateway', () {
    test('a ping carrying an ack is what makes the gap knowable', () async {
      final fixture = await _panel();
      final buffer = _buffer(fixture);

      // Move the plant until the client has actually been sent something.
      var written = 0;
      while (_appliedSeq(fixture) == null) {
        fixture.served.setValue(_key, ++written);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(buffer.deliveryGapOf(_sub), isNull,
          reason: 'before any ack the gateway has made no claim about '
              'delivery, and null is a third answer rather than a zero: '
              '"this client has said nothing" and "this client is caught up" '
              'call for opposite responses');

      final applied = _appliedSeq(fixture)!;
      await fixture.request(Methods.ping,
          params: PingParams(ack: {_sub: applied}).toJson(),
          what: 'a heartbeat carrying a delivery ack');

      final gap = buffer.deliveryGapOf(_sub);
      expect(gap, isNotNull,
          reason: 'THE point of this plan: one ping frame is what turns the '
              'delivery gap from an unreachable mechanism into a number. If '
              'this is null the wire is not connected and the stuck-consumer '
              'half of WSH-02 is still open, whatever slow_consumer_test says');
      expect(gap, greaterThanOrEqualTo(0),
          reason: 'the ack is clamped to what was sent, so the gap it '
              'produces can never be negative');
    });

    test('an over-reported ack buys the client nothing', () async {
      final fixture = await _panel();
      final buffer = _buffer(fixture);

      var written = 0;
      while (_appliedSeq(fixture) == null) {
        fixture.served.setValue(_key, ++written);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // A client claiming a sequence beyond anything this gateway has ever
      // produced. T-16-08a: without the clamp this holds the gap permanently
      // negative and the eviction becomes something the client can veto.
      await fixture.request(Methods.ping,
          params: const PingParams(ack: {_sub: 1 << 40}).toJson(),
          what: 'a heartbeat carrying an impossible ack');

      expect(buffer.deliveryGapOf(_sub), isNonNegative,
          reason: 'the clamp is the whole of the trust boundary — an ack is a '
              'claim by the party being judged, and a client may not '
              'acknowledge what was never sent');
    });

    test('an ack naming a subscription this session does not hold is dropped',
        () async {
      final fixture = await _panel();
      final buffer = _buffer(fixture);

      await fixture.request(Methods.ping,
          params:
              const PingParams(ack: {'a-page-nobody-subscribed': 9}).toJson(),
          what: 'a heartbeat naming a foreign subscription');

      expect(buffer.deliveryGapOf('a-page-nobody-subscribed'), isNull,
          reason: 'a map keyed by whatever a peer puts in an ack would be a '
              'peer-controlled allocation on a path that runs every '
              'heartbeat (rule 3)');
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'and it is dropped silently: a client with a stale page '
              'name is not a client to disconnect');
    });

    test('a malformed ack still leaves the beat a beat', () async {
      final fixture = await _panel();

      // A `ping` is what stops the reaper. Each of these must be answered
      // normally, because a decode that threw would convert a cosmetic client
      // bug into a disconnect every heartbeat.
      for (final params in <Object?>[
        {'ack': 'not-a-map'},
        {'ack': 42},
        {'ack': <String>[]},
        {
          'ack': {_sub: 'not-a-number'}
        },
        {'unknownField': true},
        null,
      ]) {
        final answer = await fixture.request(Methods.ping,
            params: params, what: 'a heartbeat carrying $params');
        expect((answer! as Map)['serverTime'], isA<int>(),
            reason: 'the beat was answered, so the deadline moved');
      }

      expect(fixture.observedClose.closeCode, isNull,
          reason: 'no malformation of an optional field may cost a panel its '
              'socket');
      expect(_buffer(fixture).deliveryGapOf(_sub), isNull,
          reason: 'and none of them was mistaken for an ack either');
    });
  });

  group('a panel that stops reading is caught by what it says, not by what '
      'the socket says', () {
    /// Drives the plant until the gateway has minted [target] sequences for
    /// [_sub], beating on the way with whatever [ack] says.
    ///
    /// The beat matters as much as the plant does: a panel that fell silent
    /// would be collected by the heartbeat reaper, and this file is about the
    /// panel the reaper *cannot* catch — one that is answering every beat
    /// while reading nothing.
    Future<void> driveTo(RelayFixture fixture, int target,
        {required Map<String, int>? Function() ack}) async {
      var written = 0;
      while ((_appliedSeq(fixture) ?? 0) < target) {
        if (fixture.observedClose.closeCode != null) return;
        fixture.served.setValue(_key, ++written);
        if (written % 4 == 0) {
          final claim = ack();
          try {
            await fixture.request(Methods.ping,
                params: claim == null ? null : PingParams(ack: claim).toJson(),
                what: 'a heartbeat while the plant runs');
          } on Object {
            return; // the socket went; the arm below says whether it should
            // have.
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    /// Past `ackGapThreshold` with room to spare, so the window starts.
    ///
    /// Read off the buffer rather than restated as 128: an arm that spelled
    /// the number itself would go quietly vacuous the day the default moves.
    int targetSeq(RelayFixture fixture) =>
        _buffer(fixture).ackGapThreshold! + 16;

    test('a panel whose ack is frozen is evicted, and told why',
        () async {
      final fixture = await _panel();

      // The first thing it applied, and the last. A reader whose event loop
      // is wedged behind a slow render keeps answering pings — that is a
      // separate code path from the one that decodes `u` frames — while the
      // sequence it can honestly claim stands still. §2.4 measured this
      // population: its gap grows at 15–20 frames/s without bound.
      int? frozen;
      await driveTo(fixture, targetSeq(fixture), ack: () {
        frozen ??= _appliedSeq(fixture);
        return frozen == null ? null : {_sub: frozen!};
      });

      final close = await fixture.awaitClose(
          'the gateway giving up on a panel that stopped reading',
          budget: _window * 4 + const Duration(seconds: 2));

      expect(close.closeCode, CloseCodes.backpressureOverrun,
          reason: 'this is the whole of WSH-02\'s stuck-consumer half: the '
              'gateway learned the panel had stopped reading from the panel, '
              'and acted on it. Nothing observed the socket — dart:io still '
              'has no bufferedAmount, and every addStream still returns in '
              '0 ms while the bytes pile up');
      expect(close.closeReason, contains('delivery stalled'),
          reason: 'and the reason names delivery rather than blaming the '
              'panel for producing');
      expect(close.closeReason, contains(_sub),
          reason: 'an operator reading the close ledger learns which page '
              'stalled without reading the source');
    });

    test('a panel that keeps its ack current is never evicted', () async {
      final fixture = await _panel();

      // The live control for the arm above. Same horizon, same plant, same
      // frames — the only difference is that this panel is reading them.
      await driveTo(fixture, targetSeq(fixture), ack: () {
        final applied = _appliedSeq(fixture);
        return applied == null ? null : {_sub: applied};
      });
      await Future<void>.delayed(_window * 2);

      expect(fixture.observedClose.closeCode, isNull,
          reason: 'a healthy panel acking every beat must survive the '
              'horizon that evicts a frozen one, or the verdict is a clock '
              'rather than a detector');
      expect(fixture.server.sessions.sessionCount, 1);
    });

    test('a panel that sends no ack at all is never judged', () async {
      final fixture = await _panel();

      // §5.3's first line, and the compatibility promise it exists for: the
      // gateway and the panels do not ship together, so a beat with no ack
      // must stay valid for ever. Vacuous on its own — a gateway that evicts
      // nobody passes it — which is why it lives beside _stuckArm.
      await driveTo(fixture, targetSeq(fixture), ack: () => null);
      await Future<void>.delayed(_window * 2);

      expect(fixture.observedClose.closeCode, isNull,
          reason: 'treating silence as a stall is a fleet-wide outage on the '
              'morning of an upgrade');
      expect(_buffer(fixture).deliveryGapOf(_sub), isNull,
          reason: 'and the gateway holds no opinion about it to act on later');
    });
  });
}
