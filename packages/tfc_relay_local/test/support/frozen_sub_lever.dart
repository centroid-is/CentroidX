/// The F25 lever: a test-only seam that freezes ONE subscription's
/// `evaluatedAt` on the wire — producing a gateway fault the shipped gateway
/// **cannot** currently produce. `TickEngine._writeTick`
/// (`tick_engine.dart:400-420`; the range was :376-396 before upstream
/// growth) stamps the same `wallMs` as `evaluatedAt` for every subscription
/// of every session, so on a real gateway the field is a statement about the
/// tick, never about one subscription, and the catalogue's injection —
/// *server stops evaluating one subscription, connection + other subs
/// healthy* — has no shipped producer. Orchestrator ruling 4 (09-CONTEXT) is
/// the decision that made a **lever** the answer rather than a product
/// change: option (ii), deriving `evaluatedAt` from real per-subscription
/// source evaluation, is recorded as a costed follow-up in the registry's
/// seeded F25 deviation and is deliberately not built here.
///
/// **Where the seam sits, and why it is not a field on `TickEngine`.** The
/// house rule (08-03, day one): levers never go on a production class. This
/// one does not touch a production class at all — it is an injected frame
/// builder standing between one shipped `RemoteStateMan` and the one shipped
/// gateway, a WebSocket-level relay that rewrites exactly two frame kinds on
/// the gateway→panel direction and forwards everything else verbatim:
///
///  * `tick` frames: the frozen subscription's `seq` and `evaluatedAt` are
///    pinned at the values of the first tick seen after [freeze]; every
///    other subscription's entries, and `serverTime` itself, pass untouched.
///  * `u` (update) frames for the frozen subscription: dropped, and counted.
///
/// That pair is what "the server stopped evaluating this subscription"
/// looks like from a panel: no new values, a sequence that stands still
/// (pinning `seq` is also what keeps the client's tick-gap resync arm out of
/// the picture — `connection_supervisor.dart:713` treats only an *advertised*
/// sequence ahead of the applied one as a gap), and a per-subscription stamp
/// that stops moving while ticks keep arriving and the socket stays healthy.
///
/// **Why not the client's `dial:` seam.** `ConnectAttempt`'s success case is
/// a `final` class holding its socket privately (`ws_transport.dart:103-116`),
/// so a wrapper cannot rebuild one around a filtered channel, and re-doing
/// the dial here would need `web_socket_channel` — not a declared dependency
/// of this package (09-03 deviation 2's constraint). `dart:io`'s own
/// WebSocket is the in-directory precedent (`ghost_session_gate_test.dart`,
/// `poison_gate_test.dart` F28c).
///
/// The class is annotated `@visibleForTesting` per the plan's artifact
/// contract; living under `test/`, nothing in production can import it
/// either way — the annotation is the label, the location is the fence.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show Methods;

/// The `@visibleForTesting` label the plan's artifact contract names, spelled
/// locally: `package:meta` is not a declared dependency of this package, an
/// undeclared import trips `depend_on_referenced_packages` (09-03 deviation
/// 2's constraint), and adding a pubspec entry is fenced (no new packages).
/// Under `test/` the real annotation is semantically inert anyway — its
/// analyzer warning fires only for `lib/` members reached from production
/// code, and nothing in production can import this file at all. The label is
/// the statement of intent; the location is the fence.
class _TestOnly {
  const _TestOnly();
}

/// See [_TestOnly].
const visibleForTesting = _TestOnly();

/// One frozen-subscription leg: panels dial [uri], the lever dials the
/// gateway at [targetPort], and [freeze] pins one subscription of the panel
/// behind this leg.
///
/// One lever per panel, mirroring the fixture's `proxyPerPanel` shape: the
/// case says in writing which leg is being shaped, and the healthy
/// neighbour's leg holds an identical lever that nobody pulls — which is what
/// makes the every-subscription sabotage (freeze both legs) able to bite.
@visibleForTesting
final class FrozenSubLever {
  FrozenSubLever._(this._server, this.targetPort);

  final HttpServer _server;

  /// The gateway's real port, dialled once per accepted panel socket.
  final int targetPort;

  /// Where a panel dials this leg.
  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');

  final List<WebSocket> _sockets = <WebSocket>[];

  /// Non-null between [freeze] and the first tick frame seen afterwards.
  String? _armed;

  /// The pin: captured from the first tick after [freeze], applied to every
  /// tick after that. Capturing from a *seen* tick rather than inventing a
  /// value keeps the frozen leg self-consistent — at the capture tick the
  /// rewrite is the identity, and the age the panel computes climbs from
  /// that instant, exactly as it would if the gateway had stopped evaluating
  /// the subscription right then.
  ({String sub, int seq, int evaluatedAt})? _pin;

  /// Tick frames whose frozen entry was rewritten. Anti-vacuity: a case that
  /// froze a subscription nobody was ticking would flip no verdict and this
  /// counter says whether the lever ever did anything.
  int rewrittenTicks = 0;

  /// Update frames for the frozen subscription that were dropped.
  int droppedUpdates = 0;

  /// Binds on an ephemeral loopback port (no literal port — 08-03 freeze 9)
  /// and relays every accepted WebSocket to the gateway at [targetPort].
  static Future<FrozenSubLever> start({required int targetPort}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final lever = FrozenSubLever._(server, targetPort);
    server.listen(lever._accept, onError: (Object _) {});
    return lever;
  }

  /// From the next tick frame on, [sub]'s `seq` and `evaluatedAt` are pinned
  /// and its update frames are dropped — the injection, engaged.
  void freeze(String sub) {
    _armed = sub;
  }

  Future<void> _accept(HttpRequest request) async {
    final WebSocket toPanel;
    try {
      toPanel = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }
    final WebSocket toGateway;
    try {
      toGateway = await WebSocket.connect('ws://127.0.0.1:$targetPort');
    } catch (_) {
      await toPanel.close();
      return;
    }
    _sockets
      ..add(toPanel)
      ..add(toGateway);
    unawaited(toPanel.done.catchError((Object _) {}));
    unawaited(toGateway.done.catchError((Object _) {}));
    // Panel → gateway: verbatim. The panel's own frames (hello, subscribe,
    // heartbeats, RPC) are not the fault being injected.
    toPanel.listen(
      toGateway.add,
      onDone: () => toGateway.close(),
      onError: (Object _) => toGateway.close(),
      cancelOnError: true,
    );
    // Gateway → panel: through the frame builder.
    toGateway.listen(
      (dynamic frame) {
        final out = _inbound(frame);
        if (out != null) toPanel.add(out);
      },
      onDone: () => toPanel.close(),
      onError: (Object _) => toPanel.close(),
      cancelOnError: true,
    );
  }

  /// The frame builder: what the panel is given for [frame], or null to drop.
  Object? _inbound(dynamic frame) {
    if (frame is! String) return frame;
    if (_armed == null && _pin == null) return frame;
    // A cheap sniff before any decode: only the two frame kinds this lever
    // exists to shape are worth parsing on the fan-out path.
    final isTick = frame.contains('"method":"${Methods.tick}"');
    final isUpdate = frame.contains('"method":"${Methods.update}"');
    if (!isTick && !isUpdate) return frame;
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return frame;
    }
    if (decoded is! Map<String, Object?>) return frame;
    final params = decoded['params'];
    if (params is! Map) return frame;

    if (decoded['method'] == Methods.tick) {
      final subs = params['subs'];
      if (subs is! Map) return frame;
      final armed = _armed;
      if (armed != null) {
        final entry = subs[armed];
        if (entry is! Map) return frame; // not subscribed yet: stay armed
        _pin = (
          sub: armed,
          seq: (entry['seq'] as num).toInt(),
          evaluatedAt: (entry['evaluatedAt'] as num).toInt(),
        );
        _armed = null;
        return frame; // identity at the capture tick, by construction
      }
      final pin = _pin!;
      final entry = subs[pin.sub];
      if (entry is! Map) return frame;
      entry['seq'] = pin.seq;
      entry['evaluatedAt'] = pin.evaluatedAt;
      rewrittenTicks++;
      return jsonEncode(decoded);
    }

    final pin = _pin;
    if (pin != null && params['sub'] == pin.sub) {
      droppedUpdates++;
      return null;
    }
    return frame;
  }

  /// Closes every relayed socket and the listener. Idempotent.
  Future<void> shutdown() async {
    for (final socket in _sockets) {
      await socket.close().catchError((Object _) => null);
    }
    _sockets.clear();
    await _server.close(force: true);
  }
}
