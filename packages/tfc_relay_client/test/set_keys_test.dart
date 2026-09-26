/// A client that learns what to watch *after* it exists.
///
/// The constructor takes the keys a panel is showing, which assumes the panel
/// already knows them. It does when the key mapping is in a local database. It
/// does not when the mapping arrives over this same socket — a browser has no
/// local copy of the plant's configuration, and neither does a panel once the
/// gateway is the only thing holding one. That is a circle: no mapping without
/// a client, no client's key set without the mapping.
///
/// `setKeys` is the cut. A client is built with no keys — which the
/// constructor already documents as legitimate — the mapping is read over it,
/// and the page is set. What this file pins is that the cut reuses the
/// re-establish path rather than inventing one: the server treats a
/// `subscribe` naming a live subscription as a re-establishment, so what
/// arrives afterwards is a snapshot of the new key set and never a delta
/// against the old.
///
/// The gateway here is scripted rather than real for the same reason
/// `preferences_changed_test.dart`'s is: what is under test is which frames
/// the client sends and what it does with the answers, and a scripted server
/// is the only way to assert "it asked for exactly these keys".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

const _budget = Duration(seconds: 5);

void main() {
  test('a client built with no keys sends no subscribe at all', () async {
    final gateway = await _ScriptedGateway.start();
    final client = _client(gateway);
    await _until('the link', () => client.isReady);
    await _settle();

    // Not "subscribed to nothing" — the server refuses an empty subscription
    // ("a name the client waits on forever"), so the honest state is that the
    // client never asked.
    expect(gateway.subscribeCalls, isEmpty);
  });

  test('setKeys subscribes the page it was given', () async {
    final gateway = await _ScriptedGateway.start();
    final client = _client(gateway);
    await _until('the link', () => client.isReady);

    await client.setKeys({'CN01.speed', 'CN01.running'});

    expect(gateway.subscribeCalls, hasLength(1));
    expect(gateway.subscribeCalls.single.sub, 'page');
    expect(gateway.subscribeCalls.single.keys,
        unorderedEquals(<String>['CN01.speed', 'CN01.running']));
  });

  test('the snapshot that answers it reaches a stream taken beforehand',
      () async {
    // The ordering that matters on a real panel: a widget subscribes to a key
    // while the mapping is still being read, so the stream exists before the
    // subscription does. `_storeOf` files an unknown key under the page
    // subscription for exactly this reason, and this is the arm that says so.
    final gateway = await _ScriptedGateway.start();
    gateway.snapshotFor = {'CN01.speed': 1450};
    final client = _client(gateway);
    await _until('the link', () => client.isReady);

    final seen = <DynamicValue>[];
    client.subscribe('CN01.speed').listen(seen.add);

    await client.setKeys({'CN01.speed'});
    await _settle();

    expect(seen, isNotEmpty, reason: 'the value never reached the stream');
    expect(seen.last.asInt, 1450);
  });

  test('setting a second time re-establishes rather than adding', () async {
    final gateway = await _ScriptedGateway.start();
    final client = _client(gateway);
    await _until('the link', () => client.isReady);

    await client.setKeys({'CN01.speed'});
    await client.setKeys({'CN02.speed', 'CN02.running'});

    expect(gateway.subscribeCalls, hasLength(2));
    // One name throughout: a second subscription would be a second entry for
    // the gateway to police, and the whole point of one socket is one session.
    expect(gateway.subscribeCalls.map((c) => c.sub), everyElement('page'));
    expect(gateway.subscribeCalls.last.keys,
        unorderedEquals(<String>['CN02.speed', 'CN02.running']));
  });

  test('a key that left the set stops arriving', () async {
    final gateway = await _ScriptedGateway.start();
    gateway.snapshotFor = {'CN01.speed': 10};
    final client = _client(gateway);
    await _until('the link', () => client.isReady);

    final seen = <DynamicValue>[];
    client.subscribe('CN01.speed').listen(seen.add);
    await client.setKeys({'CN01.speed'});
    await _settle();
    final beforeSwap = seen.length;
    expect(beforeSwap, greaterThan(0));

    // The new page does not carry CN01 at all. Recovery is a snapshot, so the
    // old cache is cleared rather than left standing — a number from a page
    // this client no longer watches is exactly the stale reading the product
    // exists to prevent.
    gateway.snapshotFor = {'CN02.speed': 20};
    await client.setKeys({'CN02.speed'});
    await _settle();

    expect(client.read('CN01.speed'), isNull,
        reason: 'CN01 survived a page it is not on');
  });

  test('an empty set releases the subscription', () async {
    final gateway = await _ScriptedGateway.start();
    final client = _client(gateway);
    await _until('the link', () => client.isReady);

    await client.setKeys({'CN01.speed'});
    await client.setKeys(const {});
    await _settle();

    expect(gateway.unsubscribeCalls, <String>['page']);
  });

  test('setKeys before the link is up is applied when it comes up', () async {
    // The real ordering on a panel: the mapping read and the first `setKeys`
    // can both be in flight while the socket is still being dialled.
    //
    // `setKeys` does NOT park on the readiness barrier — measured, because the
    // opposite is the intuitive guess. The establish it starts fails, is
    // complained about, and leaves the subscription unestablished; the set it
    // stored is then what `hello` re-establishes from. So the caller sequences
    // nothing and the page still ends up subscribed, but it happens on the
    // reconnect path rather than by waiting.
    final gateway = await _ScriptedGateway.start();
    final client = _client(gateway);

    // Deliberately NOT awaiting `isReady` first.
    expect(client.isReady, isFalse);
    await client.setKeys({'CN01.speed'});
    expect(gateway.subscribeCalls, isEmpty,
        reason: 'nothing can be sent before there is a session to send it on');

    await _until('the link', () => client.isReady);
    await _settle();

    expect(gateway.subscribeCalls, hasLength(1));
    expect(gateway.subscribeCalls.single.keys, <String>['CN01.speed']);
  });
}

RemoteStateMan _client(_ScriptedGateway gateway) {
  final client = RemoteStateMan(
    uri: Uri.parse('ws://127.0.0.1:${gateway.port}'),
    config: ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 100),
      deadlineFloor: const Duration(milliseconds: 50),
    ),
  );
  addTearDown(client.dispose);
  return client;
}

typedef _SubscribeCall = ({String sub, List<String> keys});

/// A gateway that answers `hello`, `subscribe` and `unsubscribe`, and records
/// what it was asked for.
final class _ScriptedGateway {
  _ScriptedGateway._(this._http);

  static Future<_ScriptedGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _ScriptedGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final List<WebSocket> _links = <WebSocket>[];

  final subscribeCalls = <_SubscribeCall>[];
  final unsubscribeCalls = <String>[];

  /// key -> int value the next subscribe answers with.
  Map<String, int> snapshotFor = const {};

  int get port => _http.port;

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      _links.add(socket);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          final params = (frame['params'] as Map?) ?? const {};
          switch (method) {
            case Methods.hello:
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('scripted-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              final sub = params['sub'] as String;
              final keys = (params['keys'] as List).cast<String>();
              subscribeCalls.add((sub: sub, keys: keys));
              // Handles are minted per establishment, which is what makes the
              // snapshot addressable; the numbering restarts here exactly as a
              // fresh establishment does on the real server.
              final handles = <String, int>{};
              final snapshot = <String, Object?>{};
              var handle = 1;
              for (final key in keys) {
                handles[key] = handle;
                final value = snapshotFor[key];
                if (value != null) {
                  snapshot['$handle'] = WireValue.of(value).toJson();
                }
                handle++;
              }
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': sub,
                  'epoch': 'E1',
                  'seq': 0,
                  'handles': handles,
                  'snapshot': snapshot,
                },
              });
            case Methods.unsubscribe:
              final sub = params['sub'] as String;
              unsubscribeCalls.add(sub);
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': {'sub': sub, 'released': true},
              });
            default:
              break;
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  void _send(WebSocket socket, Object? frame) {
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(frame));
    } on StateError {
      // The teardown window remote_state_man_test.dart documents.
    }
  }

  Future<void> shutdown() async {
    for (final socket in _links) {
      await socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() async {
  final deadline = DateTime.now().add(const Duration(milliseconds: 150));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
