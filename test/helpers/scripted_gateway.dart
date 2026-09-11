/// A gateway that answers JSON-RPC by script, over a real loopback WebSocket.
///
/// **Why a real socket rather than an in-memory channel.**
/// `RemoteStateMan`'s `dial:` seam and everything behind it —
/// `ConnectAttempt`, `connect`, `ConnectionSupervisor`, `ValueStore` — live in
/// `tfc_relay_client`'s `src/` and are not exported from its barrel
/// (`tfc_relay_client.dart:52-63`). An app-side test therefore cannot inject a
/// fake connection; it can only make a real one. `HttpServer.bind` +
/// `WebSocketTransformer.upgrade` is the shape
/// `packages/tfc_relay_client/test/auth_refusal_test.dart:204-326` and
/// `remote_state_man_test.dart:1206-1381` already use, and this is that class
/// with public names, brought across the package boundary.
///
/// **Loopback and an ephemeral port, never `anyIPv4`.** A test server bound to
/// a routable interface is reachable from the plant LAN for as long as the
/// suite runs.
///
/// **Every frame is built from `tfc_relay_protocol`'s own types** — `Methods`,
/// `HelloResult`, `WireValue`, `CloseCodes` — and never from a hand-typed
/// method string, so a protocol rename fails here instead of drifting into a
/// fixture that answers a name nobody sends any more.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// The key [ScriptedLink.snapshot] seeds, under handle 1.
///
/// Named here rather than in each test so the handle table and the key an arm
/// reads back cannot drift apart.
const String kScriptedSeededKey = 'PIPE.connected';

/// The handle [ScriptedLink.snapshot] files [kScriptedSeededKey] under.
const int kScriptedSeededHandle = 1;

/// How a scripted gateway answers one request.
///
/// Requests only: a notification carries no id and never reaches this. An arm
/// that needs to assert on one reads [ScriptedGateway.frames].
typedef ScriptedGatewayScript = void Function(
    ScriptedLink link, String method, int id);

/// A loopback gateway answering JSON-RPC by [ScriptedGatewayScript].
final class ScriptedGateway {
  ScriptedGateway._(this._http, this._script);

  /// Binds an ephemeral loopback port and starts accepting.
  ///
  /// [shutdown] is registered **at acquisition**, before this returns, rather
  /// than by the caller after a successful assertion: an arm that fails
  /// halfway would otherwise leave a bound server and a dialling client behind
  /// for the rest of the run, and accumulated dial loops are how unrelated
  /// widget tests start flaking.
  static Future<ScriptedGateway> start(ScriptedGatewayScript script) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = ScriptedGateway._(http, script);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final ScriptedGatewayScript _script;

  /// Every socket accepted, in order. The live one is the last.
  final List<ScriptedLink> links = <ScriptedLink>[];

  /// Every frame this gateway was sent, in order, decoded.
  ///
  /// Recorded rather than scripted because an arm may assert on frames the
  /// script never sees — a notification carries no id, so [_script] is never
  /// called for one — and because "what the client put on the wire" is a
  /// different claim from "what the gateway answered".
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];

  /// The params of each handshake this gateway received, in order.
  ///
  /// The same observation as [frames], pre-filtered, kept because the
  /// credential an arm asserts on rides in these.
  final List<Map<String, Object?>> hellos = <Map<String, Object?>>[];

  /// The ephemeral port the kernel picked.
  int get port => _http.port;

  /// Where a client dials this gateway.
  Uri get uri => Uri.parse('ws://${InternetAddress.loopbackIPv4.address}:'
      '$port');

  /// How many sockets were accepted — the client's dial count, seen from the
  /// far end. A disagreement with the near end means the counter is wrapping
  /// something other than the real dial.
  int get accepted => links.length;

  /// Sends an unsolicited notification to the live client.
  ///
  /// No id: nothing that needs an outcome is ever a notification.
  void notifyLive(String method, Map<String, Object?> params) {
    if (links.isEmpty) return;
    links.last.notifyLive(method, params);
  }

  /// Hangs up on the live client without a close code, the way a plant switch
  /// does. The client's answer to that is always to come back.
  Future<void> dropLive() async {
    if (links.isEmpty) return;
    await links.last.close();
  }

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      final link = ScriptedLink(socket);
      links.add(link);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          frames.add(frame.cast<String, Object?>());
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          if (method == Methods.hello) {
            final params = frame['params'];
            hellos.add(params is Map
                ? params.cast<String, Object?>()
                : <String, Object?>{});
          }
          _script(link, method, id);
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  /// Closes every link, then the server.
  ///
  /// Every link is **marked** before any of them is closed. Closing one can
  /// let the client's next frame through to another, and a gateway that marked
  /// them one at a time would have the window [ScriptedLink._closing] exists
  /// to close open on link two while it shut link one.
  Future<void> shutdown() async {
    for (final link in links) {
      link._closing = true;
    }
    for (final link in links) {
      await link.socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

/// One accepted socket on a [ScriptedGateway].
final class ScriptedLink {
  ScriptedLink(this.socket);

  final WebSocket socket;

  /// Whether *this* side is the one that asked for the close.
  ///
  /// **`dart:io` will not tell you this, so track it.** `close()` closes the
  /// outgoing sink synchronously while `readyState` only moves when the close
  /// handshake completes, which leaves a window — measured at ~3 ms with a
  /// peer listening, indefinitely without one — where `readyState` reads
  /// `open` and `add` throws `Bad state: StreamSink is closed`. A bare
  /// `readyState` check is what was here first and what flaked; the flag is
  /// the fix and the `readyState` read stays beside it because it is
  /// measured-correct for the other direction (a *peer*-initiated close, or a
  /// peer that vanished without a close frame, never once read `open` over a
  /// throwing sink across ~2 million attempts).
  ///
  /// This is the same defect class CLAUDE.md's "Known bugs to work around"
  /// already names for the client adapter: *"`closeCode` null after
  /// self-initiated close (dart-lang/http#1698) → track own close codes"*.
  /// **Do not simplify it back to a bare `readyState` read.**
  bool _closing = false;

  /// A JSON-RPC result for [id].
  void result(int id, Object? value) =>
      _send({'jsonrpc': '2.0', 'id': id, 'result': value});

  /// A JSON-RPC error for [id].
  void error(int id, int code, String message) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });

  /// The handshake answer the client blocks on. Everything else is optional.
  void hello(int id) => result(
        id,
        HelloResult(
          protocol: protocolVersion,
          server: const PeerInfo('fake-gateway', '0.0.1'),
          sessionId: 'S1',
          epoch: 'E1',
          serverTime: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      );

  /// A subscribe answer seeding one key at sequence 0.
  ///
  /// Without one the client never leaves `resyncing`: `ResyncEngine.onHello`
  /// returns only once every page holds a snapshot.
  void snapshot(
    int id,
    String sub, {
    String key = kScriptedSeededKey,
    Object? value = true,
  }) =>
      result(id, {
        'sub': sub,
        'epoch': 'E1',
        'seq': 0,
        'handles': {key: kScriptedSeededHandle},
        'snapshot': {
          '$kScriptedSeededHandle': WireValue.of(value).toJson(),
        },
      });

  /// A push naming [handles] — handle to value — at [seq].
  ///
  /// `g` is the generation and `c` the changes map, keyed by handle **as a
  /// string**. [sub] defaults to the name `RemoteStateMan` files its
  /// constructor keys under, so a rename of that constant fails here.
  void update(
    int seq,
    Map<int, Object?> handles, {
    String sub = defaultPageSubscription,
    int generation = 0,
  }) =>
      notifyLive(Methods.update, {
        'sub': sub,
        'seq': seq,
        't': DateTime.now().millisecondsSinceEpoch,
        'g': generation,
        'c': {
          for (final entry in handles.entries)
            '${entry.key}': WireValue.of(entry.value).toJson(),
        },
      });

  /// An unsolicited notification: no id, so nothing waits on an answer.
  void notifyLive(String method, Map<String, Object?> params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  /// Closes this socket, optionally with [code].
  ///
  /// The flag is set **before** the close, not after: the window [_closing]
  /// documents opens the instant `close()` is called, and a flag set after the
  /// await is a flag set on the far side of it.
  Future<void> close([int? code]) async {
    _closing = true;
    await (code == null ? socket.close() : socket.close(code))
        .catchError((Object _) => null);
  }

  void _send(Object? frame) {
    // Own intent first, then the socket's opinion. See [_closing] for why the
    // order is the whole fix and why the second condition stays.
    //
    // Nothing catches below this line, deliberately. A swallowed `StateError`
    // would make the guard's absence invisible, and a guard that has quietly
    // stopped working looks exactly like one that works.
    if (_closing) return;
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }
}
