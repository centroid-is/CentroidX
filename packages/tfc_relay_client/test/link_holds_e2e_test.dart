/// Three things a panel's link has to do, measured end to end over a real
/// socket: a real `RelayServer`, a real `RemoteStateMan`, and between them a
/// proxy that can make the wire as slow as a plant's worst morning.
///
/// Each case here is a defect found by review on 2026-09-19 and reproduced
/// before it was fixed. They share one cause: the design says the freshness
/// clock resets on **any inbound frame**, and the code reset it on
/// notifications — so a link that is working but not notifying looked dead.
///
/// They are in one file because they are one mechanism seen three ways, and
/// a reader who finds one of them should find the other two beside it.
@TestOn('vm')
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'support/client_harness.dart';

/// The one key the slow-snapshot gateway serves.
const String _slowKey = 'ST101.CN01.MOT01.temperature';
const int _slowHandle = 1;

/// Short, so the arm measures in tenths of a second rather than in tens.
const Duration _freshness = Duration(milliseconds: 250);

ClientConfig _slowConfig() => ClientConfig(
      controlDeadline: const Duration(seconds: 5),
      // The window this arm is about: longer than the freshness deadline, so
      // a snapshot that takes longer than a quiet link may be still has
      // somewhere to land.
      snapshotDeadline: const Duration(seconds: 5),
      writeDeadline: const Duration(seconds: 5),
      freshnessDeadline: _freshness,
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// A gateway that answers `hello` at once and the `subscribe` late, and says
/// nothing in between — a page-sized snapshot crossing a slow wire, which is
/// how the gateway behaves by construction: it writes the subscribe answer
/// first and queues every later tick behind it.
final class _SlowSnapshotGateway {
  _SlowSnapshotGateway._(this._http, this._answerAfter);

  static Future<_SlowSnapshotGateway> start(
      {required Duration answerAfter}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _SlowSnapshotGateway._(http, answerAfter);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final Duration _answerAfter;
  WebSocket? _link;

  /// How many connections were opened, and how many pages asked for. Both are
  /// 1 on a link that was never redialled.
  int helloes = 0;
  int subscribes = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      _link = socket;
      socket.listen((Object? data) async {
        final frame = jsonDecode('$data');
        if (frame is! Map) return;
        final id = frame['id'];
        final method = frame['method'];
        if (id is! int || method is! String) return;
        switch (method) {
          case Methods.hello:
            helloes++;
            _send({
              'jsonrpc': '2.0',
              'id': id,
              'result': HelloResult(
                protocol: protocolVersion,
                server: const PeerInfo('slow-gateway', '0.0.1'),
                sessionId: 'S1',
                epoch: 'E1',
                serverTime: DateTime.now().millisecondsSinceEpoch,
              ).toJson(),
            });
          case Methods.subscribe:
            subscribes++;
            // The whole arm: the socket is open, the gateway is working, and
            // nothing at all arrives until the answer does.
            await Future<void>.delayed(_answerAfter);
            _send({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'sub': 'p',
                'epoch': 'E1',
                'seq': 1,
                'generation': 1,
                'handles': {_slowKey: _slowHandle},
                'snapshot': {
                  '$_slowHandle':
                      WireValue.of(DynamicValue(value: 21.5)).toJson(),
                },
              },
            });
          default:
            _send({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32601, 'message': 'no such method'},
            });
        }
      });
    }
  }

  void _send(Object? frame) {
    final socket = _link;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    await _link?.close().catchError((Object _) => null);
    await _http.close(force: true);
  }
}

void main() {
  // ---------------------------------------------------------------- D1 ----
  //
  // The gateway writes the subscribe answer first and queues every later tick
  // behind it, so until the whole snapshot has crossed, the client receives
  // no frame at all. The freshness watchdog counted that silence: on a link
  // slow enough, the client dropped at 3 s, redialled, and pushed the same
  // snapshot into the same congestion, forever. `snapshotDeadline` (15 s)
  // could never be reached.
  group('a snapshot slower than the freshness deadline', () {
    test('still lands, and the link is not redialled under it', () async {
      final gateway = await _SlowSnapshotGateway.start(
          answerAfter: _freshness * 4);

      final subscriptions = <String, SubscriptionState>{
        'p': SubscriptionState(subId: 'p', keys: const {_slowKey}),
      };
      final store = ValueStore();
      addTearDown(store.dispose);
      final barrier = ReadinessBarrier();
      final supervisor = ConnectionSupervisor(
        uri: gateway.uri,
        config: _slowConfig(),
        backoff: Backoff(
            base: const Duration(milliseconds: 40),
            cap: const Duration(seconds: 2),
            random: Random(1)),
        barrier: barrier,
        watchdog: FreshnessWatchdog(
            config: _slowConfig(), onViewFreshnessChanged: (_) {}),
        subscriptions: subscriptions,
        storeFor: (_) => store,
      );
      addTearDown(supervisor.dispose);
      supervisor.start();

      await barrier.ready.timeout(_freshness * 12);

      expect(supervisor.state, LinkState.ready);
      expect(gateway.subscribes, 1,
          reason: 'the gateway was mid-answer, not silent: the snapshot was '
              'still crossing when the freshness deadline passed. Redialling '
              'there re-sends the same page into the same congestion, which '
              'is a panel that never gets its page back on a busy morning — '
              'and `snapshotDeadline`, written for exactly this window, '
              'could never be reached');
      expect(gateway.helloes, 1, reason: 'on the connection it started on');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // ---------------------------------------------------------------- D2 ----
  //
  // The tick engine sends nothing to a session holding no subscription, and
  // RPC answers did not feed the watchdog, so a ready link with an empty page
  // reported that the gateway had stopped speaking — every three seconds,
  // forever. Reachable from `setKeys({})`, from a browser between boot and
  // its first mapping fetch, and from signing out.
  group('a session holding no subscription', () {
    test('stays up, and the gateway is not accused of going quiet', () async {
      final fixture = relayFixture();
      addTearDown(fixture.teardown);
      await fixture.ready;

      await fixture.client.setKeys(const {});

      final drops = <LinkState>[];
      final watch = fixture.client.linkStates.listen((state) {
        if (state == LinkState.down || state == LinkState.connecting) {
          drops.add(state);
        }
      });
      addTearDown(watch.cancel);

      // Four freshness deadlines. One is enough to fail; four is enough that
      // a pass is not a race the arm happened to win.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(drops, isEmpty,
          reason: 'the link was up the whole time and the page was empty on '
              'purpose. Dropping it here is the sign-out defect: the server '
              'clears the subscriptions, the panel holds every value as good '
              'for three seconds, and then blames the gateway');
      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'and the session it was admitted on is the session it '
              'still holds');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // ---------------------------------------------------------------- D3 ----
  //
  // A key the gateway rejects — a tag renamed in the PLC, a typo in a mapping
  // — left the node at `uncertainNotYetKnown`, which is what a tag that has
  // simply not reported yet looks like. So a page showed `---` for months and
  // nothing said why. The same client's `readMany` already answered
  // `errorConfig` for the same key, so two read paths disagreed about one
  // tag.
  group('a key the gateway rejects', () {
    test('is a named refusal, not "not yet known"', () async {
      final fixture = relayFixture();
      addTearDown(fixture.teardown);
      await fixture.ready;

      const absent = 'CN99.NOT_IN_THE_PLANT';
      await fixture.client.setKeys({...fixture.served.keys, absent});
      // The rejection rides the subscribe answer; give it the round trip.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(fixture.client.read(absent)?.quality, Quality.errorConfig,
          reason: 'the gateway said this key is not in its address space. '
              'Leaving it "not yet known" makes a renamed tag look like a '
              'tag that is merely quiet, which is the empty-answer-as-fact '
              'failure this project refuses');

      final readMany = await fixture.client.readMany([absent]);
      expect(readMany[absent]?.quality, Quality.errorConfig,
          reason: 'and the two read paths agree about one tag');
    },
        timeout: const Timeout(Duration(seconds: 30)),
        // NOT a defect to fix quietly: the two halves of this repository
        // disagree in writing, and the decision is the owner's.
        //
        // `value_handlers.dart:273-295` rules that a key the gateway knows
        // the source does not serve reads `errorConfig` (770) — "the gateway
        // knows … and only the second is a sentence an engineer can act on"
        // — and `readMany` answers that today. The shared contract rules the
        // opposite for the subscribe path
        // (`subscribe_contract.dart:345`, `checkUnknownKeyReportsConfigErrorNotThrow`):
        // a key whose first batch has not arrived must stay 258, because on a
        // source that cannot know the difference it may still heal.
        //
        // Both rules are right about their own source. A gateway is the case
        // the contract did not have: it holds the source's key list and can
        // answer at subscribe time. Making that a named capability on the
        // contract (as it already does for sources with no historian or no
        // address space) is the fix; flipping one side to make a suite green
        // would make a renamed tag read as "waiting" on one leg and "fix your
        // page" on the other.
        skip: 'the subscribe path and the read path disagree about a key the '
            'gateway does not serve, in writing, on both sides. Needs a '
            'ruling and a contract capability, not a patch');
  });
}
