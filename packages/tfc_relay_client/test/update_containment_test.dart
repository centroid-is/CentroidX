@TestOn('vm')

/// One bad entry in a `u` frame costs that entry — and the page is rebuilt so
/// the cache does not diverge behind an intact sequence.
///
/// ## The finding
///
/// `UpdateParams.fromJson` was five hard casts and two `_intKeyed` calls with
/// no per-entry containment, so one `c` entry that was not an object threw a
/// `FormatException` out of the whole frame, through `_armored`, once per
/// frame for as long as the gateway kept sending it — and every lost frame is
/// a sequence gap and a full-page snapshot against the one process serving
/// every screen in the plant. `decodeSubscribeResult` has kept "one bad entry
/// costs one tag" since WSH-08; the hot path did not.
///
/// ## What the arm pins, over a real socket
///
/// A `u` frame carrying one good change and one entry that is not an object.
/// After the fix: the good change lands, a complaint names the bad entry's
/// handle and the failure's type, and the page is rebuilt — because a dropped
/// entry is a diverged cache behind an intact sequence, the same hazard a
/// handle this session never announced is rebuilt for. Before the fix the
/// whole frame was lost: no complaint, no value, no rebuild (nothing advances
/// the sequence, and no tick is sent to notice the gap). The `_until` on the
/// complaint is the arm that goes red.
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
const String _goodKey = 'ST101.CN01.MOT01.speed';
const String _otherKey = 'ST101.CN01.MOT01.torque';
const int _goodHandle = 1;
const int _poisonedHandle = 2;
const int _snapshotSeq = 4;
const double _seeded = 41.5;
const double _pushed = 42.0;

const Duration _budget = Duration(seconds: 5);

void main() {
  test('a u frame with one undecodable entry keeps the rest and rebuilds the '
      'page', () async {
    final gateway = await _Gateway.start();
    final panel = await _connected(gateway);

    // Hand-built rather than through `UpdateParams.toJson`, because the
    // protocol package cannot produce the malformed entry on trial.
    gateway.send({
      'jsonrpc': '2.0',
      'method': Methods.update,
      'params': {
        'sub': _page,
        'seq': _snapshotSeq + 1,
        't': DateTime.now().millisecondsSinceEpoch,
        'g': _Gateway.generation,
        'c': {
          '$_goodHandle': {'v': _pushed},
          // A bare number where `{"v": …}` belongs.
          '$_poisonedHandle': 3,
        },
      },
    });

    await _until(
      'the dropped entry to be reported',
      () => panel.supervisor.resync.complaints
          .any((line) => line.contains('handle $_poisonedHandle')),
      diagnose: () => 'complaints: ${panel.supervisor.resync.complaints}; '
          'lastSeq ${panel.subscriptions[_page]!.lastSeq}; '
          '${gateway.subscribes} subscribes',
    );
    final complaint = panel.supervisor.resync.complaints
        .firstWhere((line) => line.contains('handle $_poisonedHandle'));
    expect(complaint, contains('FormatException'),
        reason: 'the failure\'s type is the diagnostic');
    expect(complaint, contains('rebuilt'),
        reason: 'the line says what the client is doing about it');

    await _until('the good entry to land',
        () => panel.store.peek(_goodKey)?.value == _pushed);
    await _until('the page to be rebuilt', () => gateway.subscribes == 2,
        diagnose: () => '${gateway.subscribes} subscribes');

    expect(panel.store.peek(_otherKey)?.value, _seeded,
        reason: 'the poisoned entry is dropped, never filed under a guess');
    expect(panel.supervisor.state, LinkState.ready);
    expect(gateway.dials, 1, reason: 'one bad entry must not cost the link');
  });
}

/// A gateway whose snapshot echoes the last value it pushed for the good
/// handle, so the rebuild the arm expects lands the same reading the frame
/// carried rather than reverting it.
final class _Gateway {
  _Gateway._(this._http);

  static Future<_Gateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final _links = <WebSocket>[];
  WebSocket? _link;
  int dials = 0;
  int subscribes = 0;
  int _lastSeq = _snapshotSeq;
  double _goodValue = _seeded;

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
              send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('containment-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              send({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': _lastSeq,
                  'generation': generation,
                  'handles': {
                    _goodKey: _goodHandle,
                    _otherKey: _poisonedHandle
                  },
                  'snapshot': {
                    '$_goodHandle': WireValue.of(_goodValue).toJson(),
                    '$_poisonedHandle': WireValue.of(_seeded).toJson(),
                  },
                },
              });
            default:
              send({
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

  /// Writes [frame] and, for a `u`, records what the next snapshot echoes.
  void send(Map<String, Object?> frame) {
    if (frame['method'] == Methods.update) {
      final params = frame['params'] as Map;
      _lastSeq = params['seq'] as int;
      final changes = params['c'] as Map?;
      final good = changes?['$_goodHandle'];
      if (good is Map && good['v'] is double) _goodValue = good['v'] as double;
    }
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

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    );

Future<_Panel> _connected(_Gateway gateway) async {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_goodKey, _otherKey}),
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
  await _until('the page to be established',
      () => subscriptions[_page]!.lastSeq == _snapshotSeq);
  await _until('the link to be ready',
      () => supervisor.state == LinkState.ready);
  return (supervisor: supervisor, subscriptions: subscriptions, store: store);
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
