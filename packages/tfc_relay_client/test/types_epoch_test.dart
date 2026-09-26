@TestOn('vm')

/// The type dictionary merges within a gateway session and starts over
/// across one.
///
/// ## The finding
///
/// `RemoteStateMan._types` grew by `addAll` on every establishment and was
/// never cleared, and `_typeIdByKey` beside it likewise. Within a session that
/// is right — a resync re-sends the dictionary for the keys it establishes,
/// and a type cannot change under a session. Across sessions it is wrong: a
/// reprogrammed PLC behind a restarted gateway (the `plc_reprogrammed` resync
/// reason exists for exactly that) left every old descriptor standing, so a
/// tag whose enum the new program dropped kept naming states that no longer
/// existed, and a plant whose type ids hash the type's shape grew the map by
/// one dictionary per reprogram.
///
/// ## The arms, in one run
///
///  1. A snapshot under epoch E1 names `T1` for the key: `typeOf` answers it.
///  2. A same-epoch re-establishment that carries no dictionary keeps it —
///     the merge the field doc promises.
///  3. The gateway drops the link and comes back under epoch E2 with a
///     snapshot whose meta names no type for the key: `typeOf` answers null.
///     Red before the fix: the E1 descriptor is answered for ever.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

const String _key = 'ST101.CN01.MOT01.p_stat_RunMode';
const int _handle = 1;
const Duration _budget = Duration(seconds: 5);

void main() {
  test('a new epoch starts the type dictionary over; the same epoch merges',
      () async {
    final gateway = await _Gateway.start();
    final client = RemoteStateMan(
      uri: gateway.uri,
      config: ClientConfig(
        controlDeadline: const Duration(milliseconds: 600),
        writeDeadline: const Duration(milliseconds: 600),
        freshnessDeadline: const Duration(seconds: 30),
        backoffBase: const Duration(milliseconds: 20),
        backoffCap: const Duration(milliseconds: 200),
        deadlineFloor: const Duration(milliseconds: 50),
      ),
      keys: const {_key},
    );
    addTearDown(client.dispose);

    // 1. Learned under E1.
    await _until('the E1 dictionary to be adopted',
        () => client.typeOf(_key)?.enumFields?[1]?.name == 'Old',
        diagnose: () => '${client.typeOf(_key)} after ${gateway.subscribes} '
            'subscribes on ${gateway.dials} dials');

    // 2. Same epoch, a re-establishment with no dictionary: merged, kept.
    gateway.describeTypes = false;
    gateway.send({
      'jsonrpc': '2.0',
      'method': Methods.resync,
      'params': const ResyncParams(
              sub: defaultPageSubscription, epoch: 'E1', reason: 'overrun')
          .toJson(),
    });
    await _until('the same-epoch rebuild', () => gateway.subscribes == 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(client.typeOf(_key)?.enumFields?[1]?.name, 'Old',
        reason: 'a type cannot change under a session, so a rebuild that '
            'carries no dictionary keeps the one already learned');

    // 3. A new session: the gateway restarts under E2 and the PLC no longer
    //    declares an enum for this tag.
    gateway.epoch = 'E2';
    await gateway.dropLink();
    await _until('the E2 snapshot to be adopted',
        () => gateway.dials == 2 && gateway.subscribes >= 3);
    await _until(
      'the E1 descriptor to be forgotten',
      () => client.typeOf(_key) == null,
      diagnose: () => 'typeOf still answers ${client.typeOf(_key)} under '
          'epoch E2: the dictionary from the previous session survived it',
    );
  });
}

/// A gateway that describes `T1` for the key under whatever [epoch] it is
/// currently answering hello with, until told not to describe anything.
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
  int _generation = 0;
  String epoch = 'E1';
  bool describeTypes = true;

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
                  server: const PeerInfo('types-gateway', '0.0.1'),
                  sessionId: 'S-$epoch',
                  epoch: epoch,
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              final params = frame['params'];
              final sub = params is Map ? '${params['sub']}' : '';
              send({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': sub,
                  'epoch': epoch,
                  'seq': subscribes,
                  'generation': ++_generation,
                  'handles': {_key: _handle},
                  if (describeTypes)
                    'meta': {
                      '$_handle': {'ty': 'T1'}
                    },
                  if (describeTypes)
                    'types': {
                      'T1': {
                        'enum': {
                          '1': {'value': 1, 'name': 'Old'}
                        }
                      }
                    },
                  'snapshot': {'$_handle': WireValue.of(1).toJson()},
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

  /// The gateway restarting: the current socket is closed and the next hello
  /// is answered under whatever [epoch] now says.
  Future<void> dropLink() async {
    final socket = _link;
    _link = null;
    if (socket != null) await socket.close().catchError((Object _) => null);
  }

  Future<void> shutdown() async {
    for (final link in _links) {
      await link.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
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
