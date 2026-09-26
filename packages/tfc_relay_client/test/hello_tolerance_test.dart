@TestOn('vm')

/// A gateway that restructures its hello must not brick every older panel.
///
/// ## The finding
///
/// `HelloResult.fromJson` was six hard casts. A `TypeError` out of it is not
/// an `RpcException`, so it reached `ConnectionSupervisor._serve`'s generic
/// catch as "the link died before the snapshot landed" — backoff, redial, the
/// same frame. A permanent reconnect loop with the wrong diagnosis, from a
/// gateway that moved one object in its handshake, against the promise in
/// `docs/relay-wire-api.md` §5 that a newer backend must never be able to
/// make a panel go dark. The snapshot decode has kept that promise per entry
/// since WSH-08 (`poisoned_snapshot_test.dart`); the hello, the frame every
/// reconnect performs first, did not.
///
/// ## The arms
///
///  1. **A hello with its `session` and `clock` restructured reaches
///     `ready`**, on the first dial, and the two absences are said on the
///     complaint surface under the gateway's name rather than left to a
///     clock warning that would blame the panel. Red before the fix: the
///     panel never reaches `ready` and piles up dials.
///  2. **A hello that is not a JSON object at all is named as the peer
///     problem it is**, on `lastDownReason`, and is still redialled — the
///     posture the snapshot path takes for its own undecodable answer. Red
///     before the fix: the reason reads "the link died before the snapshot
///     landed: FormatException…", which sends the engineer to the cable.
///  3. **Anti-vacuity**: the ordinary hello still anchors the clock. A fix
///     that ignored `clock` for every frame would pass arm 1.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/clock_offset.dart';
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

/// A gateway clock deliberately an hour behind this machine, so arm 3 can tell
/// "anchored from the hello" apart from "left at zero".
final int _gatewayClockMs =
    DateTime.now().millisecondsSinceEpoch - const Duration(hours: 1).inMilliseconds;

const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 300);

/// The hello answers the arms script. Each is the *result* object as the
/// gateway would write it.
Object? _restructuredHello() => {
      'protocol': protocolVersion,
      'server': const PeerInfo('newer-gateway', '9.0.0').toJson(),
      // A newer gateway that folded the session into one string and renamed
      // the clock. Neither object the old decoder cast is here.
      'session': 'S1/E1',
      'clockMs': _gatewayClockMs,
    };

Object? _notAnObjectHello() => <Object?>['hello', 'from', 'a', 'list'];

Object? _ordinaryHello() => HelloResult(
      protocol: protocolVersion,
      server: const PeerInfo('gateway', '0.1.0'),
      sessionId: 'S1',
      epoch: 'E1',
      serverTime: _gatewayClockMs,
    ).toJson();

void main() {
  test('a restructured hello reaches ready on the first dial, and says what '
      'it cost', () async {
    final gateway = await _Gateway.start(hello: _restructuredHello);
    final panel = _connect(gateway);

    await _until(
      'the panel to reach ready',
      () => panel.supervisor.state == LinkState.ready,
      diagnose: () => 'state ${panel.supervisor.state} after ${gateway.dials} '
          'dials; lastDownReason: ${panel.supervisor.lastDownReason}',
    );
    await Future<void>.delayed(_settle);
    expect(panel.supervisor.state, LinkState.ready);
    expect(gateway.dials, 1,
        reason: 'a hello this build can read on the first try must not cost '
            'a redial');
    expect(panel.store.peek(_key)?.value, 41.5,
        reason: 'reaching ready is worthless if the page is empty');

    final complaints = panel.supervisor.resync.complaints;
    expect(complaints.where((line) => line.contains('clock.serverTime')),
        hasLength(1),
        reason: 'the missing clock is said, under the gateway\'s name: '
            '$complaints');
    expect(complaints.where((line) => line.contains('session.epoch')),
        hasLength(1),
        reason: 'and so is the missing epoch: $complaints');
    expect(panel.supervisor.clockOffset, same(ClockOffset.none),
        reason: 'no clock means "clocks agree", never a 1970 default that '
            'reads as a panel whose clock is fifty years out');
    expect(panel.supervisor.clockOffset.warning, isNull,
        reason: 'the one thing this must not do is blame the panel');
  });

  test('a hello that is not an object is named as a peer problem and '
      'redialled', () async {
    final gateway = await _Gateway.start(hello: _notAnObjectHello);
    final panel = _connect(gateway);

    await _until(
      'the attempt to be ended under the hello\'s own name',
      () => (panel.supervisor.lastDownReason ?? '').contains('hello answer'),
      diagnose: () => 'state ${panel.supervisor.state}, lastDownReason: '
          '${panel.supervisor.lastDownReason}',
    );
    expect(panel.supervisor.lastDownReason, isNot(contains('link died')),
        reason: 'the link is fine; what answered on it is not a gateway');
    expect(panel.supervisor.stopped, isFalse,
        reason: 'redialled, as the snapshot path redials its own undecodable '
            'answer: the thing on the other end may be replaced');
    expect(panel.supervisor.state, isNot(LinkState.ready));
  });

  test('the ordinary hello still anchors the clock from the handshake',
      () async {
    final gateway = await _Gateway.start(hello: _ordinaryHello);
    final panel = _connect(gateway);
    await _until('the panel to reach ready',
        () => panel.supervisor.state == LinkState.ready);
    expect(panel.supervisor.clockOffset.offsetMs,
        closeTo(const Duration(hours: 1).inMilliseconds, 2000),
        reason: 'the hour of skew scripted into the gateway clock must be '
            'measured, or arm 1 proves nothing about the tolerant path');
    expect(
        panel.supervisor.resync.complaints
            .where((line) => line.contains('clock.serverTime')),
        isEmpty);
  });
}

/// A gateway whose hello answer is whatever the arm scripted.
final class _Gateway {
  _Gateway._(this._http, this._hello);

  static Future<_Gateway> start({required Object? Function() hello}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway._(http, hello);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final Object? Function() _hello;
  final _links = <WebSocket>[];
  int dials = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      dials++;
      _links.add(socket);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          switch (method) {
            case Methods.hello:
              _send(socket, {'jsonrpc': '2.0', 'id': id, 'result': _hello()});
            case Methods.subscribe:
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': _snapshotSeq,
                  'generation': 1,
                  'handles': {_key: _handle},
                  'snapshot': {'$_handle': WireValue.of(41.5).toJson()},
                },
              });
            default:
              _send(socket, {
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

  void _send(WebSocket socket, Object? frame) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    for (final link in _links) {
      await link.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

typedef _Panel = ({ConnectionSupervisor supervisor, ValueStore store});

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
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
  return (supervisor: supervisor, store: store);
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
