@TestOn('vm')

/// An inbound frame over the ceiling costs the frame, never the link — and
/// before the snapshot lands, it ends the attempt under its own name.
///
/// ## The finding
///
/// Every ceiling in this client was on a *deadline*. Nothing bounded how large
/// an inbound frame could be: `ws_transport.dart` cast the socket's stream to
/// strings and the supervisor handed every one to `json_rpc_2`, whose first
/// act is `jsonDecode`. A gateway replaced by something hostile on a hijacked
/// route — or an honest one with a bug in its result sizing — could make a
/// plant-floor panel build the object tree of whatever it sent. The gateway
/// has refused oversized ingress since 03; the panel, the smaller machine,
/// refused nothing.
///
/// ## What each arm pins, and which one fails on the unfixed client
///
///  1. **In `ready`, an oversized push is dropped unread and the link is
///     kept.** The value it carried never lands, a complaint names the size
///     and the ceiling, and there is no redial. Red before the fix: the frame
///     lands, its value shows, and no complaint is filed — the `_until` on the
///     complaint times out.
///  2. **In `resyncing`, an oversized snapshot ends the attempt under its own
///     name**, on `lastDownReason`, well inside the snapshot deadline — and
///     schedules a redial rather than stopping. Red before the fix: the
///     snapshot decodes, the panel reaches `ready`, and the reason is never
///     written.
///  3. **The anti-vacuity arm**: with the same small ceiling, a gateway whose
///     frames all fit reaches `ready` and stays there. A ceiling that refused
///     everything would pass arms 1 and 2 by refusing the hello.
///
/// The gateway is a raw `HttpServer` after `update_lanes_test.dart`'s, because
/// the subject is what the supervisor does with a frame the real socket
/// delivered, and a scripted `dial:` that never assembled a WebSocket message
/// would test the seam and not the property.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

const String _page = 'p';
const String _key = 'ST101.CN01.MOT01.speed';
const int _handle = 1;
const int _snapshotSeq = 4;
const Object _seeded = 41.5;

/// Small enough that a padded frame trips it in a few kilobytes, large enough
/// that the hello answer and an unpadded snapshot fit with room to spare —
/// which arm 3 proves rather than assumes.
const int _ceiling = 4096;

/// Comfortably over [_ceiling] once wrapped in a `u` frame.
final String _oversized = 'x' * (_ceiling * 2);

const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 300);

void main() {
  group('an inbound frame over ClientConfig.maxFrameBytes', () {
    test('in ready costs the frame and keeps the link', () async {
      final gateway = await _Gateway.start();
      final panel = await _connected(gateway);
      final complaintsBefore = panel.supervisor.resync.complaints.length;

      gateway.push(_snapshotSeq + 1, value: _oversized);

      await _until(
        'the refused frame to be reported',
        () => panel.supervisor.resync.complaints
            .skip(complaintsBefore)
            .any((line) => line.contains('maxFrameBytes')),
        diagnose: () => 'complaints: ${panel.supervisor.resync.complaints}; '
            'value now ${panel.store.peek(_key)?.value.runtimeType}',
      );
      final refusal = panel.supervisor.resync.complaints
          .skip(complaintsBefore)
          .singleWhere((line) => line.contains('maxFrameBytes'));
      expect(refusal, contains('$_ceiling'),
          reason: 'the complaint must name the ceiling the frame was measured '
              'against, so the integrator knows which knob this is');
      expect(refusal, isNot(contains(_oversized)),
          reason: 'a refusal must not echo the megabytes it is refusing');

      await Future<void>.delayed(_settle);
      expect(panel.store.peek(_key)?.value, _seeded,
          reason: 'the oversized push must never be applied');
      expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq,
          reason: 'a dropped frame advances nothing: the next tick that '
              'advertises a sequence past this one is what rebuilds the page');
      expect(panel.supervisor.state, LinkState.ready);
      expect(gateway.dials, 1,
          reason: 'one bad frame must not cost the connection');
      expect(panel.supervisor.lastDownReason, isNull);
    });

    test('before the snapshot lands ends the attempt under its own name',
        () async {
      final gateway = await _Gateway.start(padSnapshot: true);
      final panel = _connect(gateway);
      var reachedReady = false;
      panel.supervisor.states.listen((state) {
        if (state == LinkState.ready) reachedReady = true;
      });

      await _until(
        'the attempt to end on the frame ceiling',
        () => (panel.supervisor.lastDownReason ?? '').contains('maxFrameBytes'),
        diagnose: () => 'state ${panel.supervisor.state}, lastDownReason '
            '${panel.supervisor.lastDownReason}, ${gateway.dials} dials',
      );

      expect(reachedReady, isFalse,
          reason: 'an oversized snapshot is not a page this panel can show');
      expect(panel.supervisor.stopped, isFalse,
          reason: 'not a stop: the gateway or the ceiling may be changed under '
              'a running panel, and the schedule is how it finds out');
      expect(panel.supervisor.debugScheduledWaits, isNotEmpty,
          reason: 'a redial is scheduled, at the ordinary backoff');
      expect(panel.supervisor.lastDownReason, contains('$_ceiling'));
      expect(panel.supervisor.lastDownReason, isNot(contains('deadline')),
          reason: 'the attempt was ended by the ceiling, and the health line '
              'must not blame the snapshot deadline for it');
      // The state machine's own account: the schedule has taken over.
      expect(panel.supervisor.state, isNot(LinkState.ready));
    });

    test('is not tripped by frames that fit, at the same ceiling', () async {
      final gateway = await _Gateway.start();
      final panel = await _connected(gateway);
      gateway.push(_snapshotSeq + 1, value: 42.0);
      await _until('the small push to land',
          () => panel.store.peek(_key)?.value == 42.0);
      await Future<void>.delayed(_settle);
      expect(panel.supervisor.state, LinkState.ready);
      expect(gateway.dials, 1);
      expect(
          panel.supervisor.resync.complaints
              .where((line) => line.contains('maxFrameBytes')),
          isEmpty,
          reason: 'a ceiling that complains about frames under it would be a '
              'ceiling nobody could set');
    });
  });

  group('ClientConfig.maxFrameBytes', () {
    test('defaults to twice the gateway\'s priority lane', () {
      expect(ClientConfig().maxFrameBytes, 16 * 1024 * 1024,
          reason: 'the largest frame a conforming gateway writes fits its '
              '8 MiB priority lane; twice that leaves room for a generous '
              'gateway without admitting the hundreds of megabytes the ceiling '
              'exists to refuse');
    });

    test('refuses a non-positive ceiling by name', () {
      expect(
        () => ClientConfig(maxFrameBytes: 0),
        throwsA(isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('maxFrameBytes'))),
        reason: 'zero admits nothing, not even the hello answer, and there is '
            'deliberately no unbounded setting',
      );
    });
  });
}

/// A gateway that answers `hello` and `subscribe`, and pushes what an arm asks
/// for. With [padSnapshot] every subscribe answer carries a `meta` entry far
/// over the ceiling, on every connection.
final class _Gateway {
  _Gateway._(this._http, this._padSnapshot);

  static Future<_Gateway> start({bool padSnapshot = false}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway._(http, padSnapshot);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final bool _padSnapshot;
  final _links = <WebSocket>[];
  WebSocket? _link;

  /// How many sockets this gateway has accepted.
  int dials = 0;

  static const int generation = 7;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      dials++;
      _links.add(socket);
      _link = socket;
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          switch (method) {
            case Methods.hello:
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('ceiling-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': _snapshotSeq,
                  'generation': generation,
                  'handles': {_key: _handle},
                  if (_padSnapshot)
                    'meta': {
                      '$_handle': {'typeId': 'double', 'pad': _oversized},
                    },
                  'snapshot': {
                    '$_handle': WireValue.of(_seeded).toJson(),
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
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  /// Pushes a `u` frame carrying [value] for the page's one handle.
  void push(int seq, {required Object value}) => _send({
        'jsonrpc': '2.0',
        'method': Methods.update,
        'params': UpdateParams(
          sub: _page,
          seq: seq,
          t: DateTime.now().millisecondsSinceEpoch,
          generation: generation,
          changes: {_handle: WireValue.of(value)},
        ).toJson(),
      });

  void _send(Object? frame) {
    final socket = _link;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    for (final link in _links) {
      await link.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

typedef _Panel = ({
  ConnectionSupervisor supervisor,
  Map<String, SubscriptionState> subscriptions,
  ValueStore store,
});

/// The knobs: a small ceiling, a snapshot deadline far longer than the budget
/// (so arm 2 cannot pass on the deadline's word instead of the ceiling's), a
/// freshness deadline far longer than any arm (a scripted gateway that pushes
/// nothing is a silent link), and a fast backoff.
ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      snapshotDeadline: const Duration(seconds: 15),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
      maxFrameBytes: _ceiling,
    );

_Panel _connect(_Gateway gateway) {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_key}),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: _config(),
    backoff: Backoff(
        base: const Duration(milliseconds: 20),
        cap: const Duration(milliseconds: 200),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog:
        FreshnessWatchdog(config: _config(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  return (supervisor: supervisor, subscriptions: subscriptions, store: store);
}

Future<_Panel> _connected(_Gateway gateway) async {
  final panel = _connect(gateway);
  await _until('the page to be established',
      () => panel.subscriptions[_page]!.lastSeq == _snapshotSeq);
  await _until('the link to be ready',
      () => panel.supervisor.state == LinkState.ready);
  return panel;
}

Future<void> _until(
  String what,
  bool Function() done, {
  String Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for $what'
          '${diagnose == null ? '' : ': ${diagnose()}'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
