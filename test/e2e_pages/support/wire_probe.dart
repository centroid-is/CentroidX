/// A second client on the same socket the panel dials, with none of the
/// panel's manners.
///
/// The property under test for every advanced page is docs/relay-wire-api.md
/// §10: "once the transport is a WebSocket, anything a panel declines to send
/// another client can send anyway." The app's `AccessGate` hides a page from a
/// session without the group; this probe is the client that does not care what
/// is hidden. It dials the gateway with `dart:io`'s `WebSocket`, sends the
/// handshake and then any method with any params, and hands back the raw
/// JSON-RPC answer — so a case can assert that the GATEWAY refused, by error
/// code, rather than that a button was absent.
///
/// Deliberately not a `RemoteStateMan`. The real client is what the page runs
/// on (see `panel.dart`); this is the adversary, and an adversary built from
/// the client under test inherits every check the client makes before a frame
/// leaves it. `test/helpers/scripted_gateway.dart` builds the far side of the
/// wire from `tfc_relay_protocol`'s own types for the same reason this builds
/// the near side from them: a protocol rename fails here instead of drifting
/// into a probe that speaks a dialect nobody answers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// One JSON-RPC answer, either half.
final class WireAnswer {
  const WireAnswer._({this.result, this.errorCode, this.errorMessage,
      this.errorData});

  final Object? result;
  final int? errorCode;
  final String? errorMessage;
  final Object? errorData;

  bool get isError => errorCode != null;

  @override
  String toString() => isError
      ? 'error $errorCode: $errorMessage'
      : 'result: ${jsonEncode(result)}';
}

/// A raw session: handshake done, identity whatever the caller made it.
final class WireProbe {
  WireProbe._(this._socket) {
    _socket.listen(_onFrame, onError: (Object _) {}, onDone: () {
      for (final pending in _pending.values) {
        if (!pending.isCompleted) {
          pending.completeError(StateError('the gateway closed the socket'));
        }
      }
      _pending.clear();
    });
  }

  final WebSocket _socket;
  final Map<int, Completer<WireAnswer>> _pending = {};
  int _nextId = 1;

  /// Every notification the gateway pushed, in order — a case that wants to
  /// know whether something was announced reads this.
  final List<Map<String, Object?>> notifications = [];

  /// Dials [port] on loopback and completes the handshake as **nobody**: no
  /// token, no sign-in. What that session may do is exactly what the plant's
  /// `anonymous` account grants, which is what §10 says it is.
  static Future<WireProbe> anonymous(int port, {String client = 'probe'}) async {
    final socket =
        await WebSocket.connect('ws://${InternetAddress.loopbackIPv4.address}:$port');
    final probe = WireProbe._(socket);
    final hello = await probe.call(
        Methods.hello,
        HelloParams(
          protocol: protocolVersion,
          supported: const [protocolVersion],
          client: PeerInfo(client, '0.0.0'),
        ).toJson());
    if (hello.isError) {
      await probe.close();
      throw StateError('the handshake was refused: $hello');
    }
    return probe;
  }

  /// Dials and signs in as [username], the way a browser would — through
  /// `session.login`, verified by the gateway against its own user source.
  /// [station] is what the audit `station` column will carry, and it is the
  /// CLIENT that supplies it; one of the known defects is pinned on that.
  static Future<WireProbe> signedIn(int port,
      {required String username,
      required String password,
      String? station,
      String client = 'probe'}) async {
    final probe = await anonymous(port, client: client);
    final login = await probe.call(
        Methods.sessionLogin,
        SessionLoginParams(
                username: username, password: password, station: station)
            .toJson());
    if (login.isError) {
      await probe.close();
      throw StateError('session.login as $username was refused: $login');
    }
    return probe;
  }

  /// Sends [method] with [params] and waits for the answer.
  Future<WireAnswer> call(String method, [Object? params]) {
    final id = _nextId++;
    final completer = Completer<WireAnswer>();
    _pending[id] = completer;
    _socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return completer.future.timeout(const Duration(seconds: 20),
        onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('no answer to $method within 20s');
    });
  }

  Future<void> close() => _socket.close().catchError((Object _) => null);

  void _onFrame(Object? data) {
    final decoded = jsonDecode('$data');
    if (decoded is! Map) return;
    final frame = decoded.cast<String, Object?>();
    final id = frame['id'];
    if (id is! int) {
      if (frame['method'] is String) notifications.add(frame);
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    final error = frame['error'];
    if (error is Map) {
      pending.complete(WireAnswer._(
        errorCode: error['code'] as int?,
        errorMessage: error['message'] as String?,
        errorData: error['data'],
      ));
    } else {
      pending.complete(WireAnswer._(result: frame['result']));
    }
  }
}

/// The gateway's `ServerErrorCodes`, spelled locally.
///
/// `tfc_relay_server`'s `error_codes.dart` is not exported from its barrel, so
/// these are the two literals every §10 case asserts on — the same discipline
/// `test/providers/gateway_access_route_test.dart` records: two literals in
/// two files that a case fails the moment they disagree.
abstract final class WireErrors {
  /// "You may not": the policy refused, the identity was resolved.
  static const int forbidden = -32005;

  /// The handler threw: the request reached the backend and the backend
  /// refused it for a reason of its own.
  static const int handlerFailed = -32011;

  /// The credential was not accepted.
  static const int unauthorized = -32003;
}
