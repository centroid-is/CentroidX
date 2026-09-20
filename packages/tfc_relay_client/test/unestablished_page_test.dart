@TestOn('vm')

/// A `g`-less frame must not establish a page that has no snapshot — and a
/// gateway that mints no generations must still be able to push to one that
/// has.
///
/// ## The finding
///
/// `resync_engine.dart`'s `_unestablish` set `generation = 0` and claimed no
/// gateway mints zero so nothing could match it. True of gateways; false of
/// `UpdateParams.fromJson`, which decoded an *absent* `g` as zero. So a
/// `g`-less frame arriving at a page the client had given up on passed the
/// generation gate, resolved every handle to nothing (the table is empty),
/// applied an empty batch — and the store, having no baseline, took the
/// frame's sequence as one. The page then read as established with no handle
/// table: every later frame carrying a real `g` was dropped as the wrong
/// generation, and the tick's "unestablished" door (16-01) stayed shut because
/// `lastSeq` was no longer null. Nothing rebuilt it.
///
/// ## The arms
///
///  1. **The page is unestablished by a refused rebuild, then a `g`-less
///     frame arrives.** After the fix `lastSeq` stays null and the frame's
///     value never lands; the tick remains the way back. Red before the fix:
///     `lastSeq` becomes the frame's sequence.
///  2. **A gateway that mints no generations at all** — no `generation` in
///     its snapshot, no `g` on its frames — still pushes to an established
///     page. Anti-vacuity: a fix that refused every `g`-less frame would pass
///     arm 1 and break every pre-generation gateway in the field.
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
const double _seeded = 41.5;
const double _pushed = 99.0;

const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 300);

void main() {
  test('a g-less frame at an unestablished page establishes nothing',
      () async {
    final gateway = await _Gateway.start(mintsGenerations: true);
    final panel = await _connected(gateway);

    // Take the page down the way 16-01 describes: a rebuild the gateway
    // answers with something that is not a snapshot at all.
    gateway.refuseSubscribes = true;
    gateway.send({
      'jsonrpc': '2.0',
      'method': Methods.resync,
      'params': const ResyncParams(sub: _page, epoch: 'E1', reason: 'overrun')
          .toJson(),
    });
    await _until('the page to be unestablished',
        () => panel.subscriptions[_page]!.lastSeq == null,
        diagnose: () => '${panel.subscriptions[_page]}');
    expect(panel.subscriptions[_page]!.generation,
        SubscriptionState.unestablished);

    // The frames the finding is about: no `g`, at a page with no table. Two
    // of them, because the unfixed client's own stranger-rebuild masks the
    // first: the frame sets a baseline, the rebuild it triggers is refused
    // and unestablishes the page again, and only the *second* frame — landing
    // inside the rebuild damper's window — leaves the baseline standing with
    // no handle table under it. That is the state every later real frame is
    // dropped from.
    for (final seq in [_snapshotSeq + 20, _snapshotSeq + 21]) {
      gateway.send({
        'jsonrpc': '2.0',
        'method': Methods.update,
        'params': {
          'sub': _page,
          'seq': seq,
          't': DateTime.now().millisecondsSinceEpoch,
          'c': {
            '$_handle': {'v': _pushed}
          },
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(_settle);

    expect(panel.subscriptions[_page]!.lastSeq, isNull,
        reason: 'a frame cannot establish a page; only a snapshot can. A '
            'baseline set here leaves a page with no handle table that every '
            'later frame is dropped from and nothing rebuilds');
    expect(panel.subscriptions[_page]!.handles, isEmpty);
    expect(panel.store.peek(_key)?.value, isNot(_pushed),
        reason: 'nothing in the frame could be filed: the table is empty');
    expect(panel.supervisor.state, LinkState.ready,
        reason: 'the link is fine; it is the page that is down');
    expect(gateway.dials, 1);
  });

  test('a gateway that mints no generations still pushes to an established '
      'page', () async {
    final gateway = await _Gateway.start(mintsGenerations: false);
    final panel = await _connected(gateway);
    expect(panel.subscriptions[_page]!.generation, isNull,
        reason: 'absent decodes as absent, distinct from the sentinel');

    gateway.send({
      'jsonrpc': '2.0',
      'method': Methods.update,
      'params': {
        'sub': _page,
        'seq': _snapshotSeq + 1,
        't': DateTime.now().millisecondsSinceEpoch,
        'c': {
          '$_handle': {'v': _pushed}
        },
      },
    });
    await _until('the g-less push to land',
        () => panel.store.peek(_key)?.value == _pushed,
        diagnose: () => '${panel.subscriptions[_page]}, complaints '
            '${panel.supervisor.resync.complaints}');
    expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq + 1);
  });
}

/// A gateway that answers `hello`, serves one page, and — when asked —
/// refuses every further subscribe with an answer that is not an object.
final class _Gateway {
  _Gateway._(this._http, this._mintsGenerations);

  static Future<_Gateway> start({required bool mintsGenerations}) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway._(http, mintsGenerations);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final bool _mintsGenerations;
  final _links = <WebSocket>[];
  WebSocket? _link;
  int dials = 0;
  int subscribes = 0;
  bool refuseSubscribes = false;

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
                  server: const PeerInfo('sentinel-gateway', '0.0.1'),
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
                'result': refuseSubscribes
                    ? <Object?>['not', 'a', 'snapshot']
                    : {
                        'sub': _page,
                        'epoch': 'E1',
                        'seq': _snapshotSeq,
                        if (_mintsGenerations) 'generation': generation,
                        'handles': {_key: _handle},
                        'snapshot': {
                          '$_handle': WireValue.of(_seeded).toJson()
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

  void send(Object? frame) {
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
      snapshotDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    );

Future<_Panel> _connected(_Gateway gateway) async {
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
