/// The client carries a gateway stall's reason and duration to a surface, it
/// does not decode and drop them.
///
/// Source: 09-07 (RES-02 row F22, clause 2), Ruling 5a. Until this landed,
/// `connection_supervisor.dart`'s `_resynced` decoded `ResyncParams`, used only
/// `asked.sub`, and threw `asked.reason` and `asked.stalledMs` on the floor —
/// so `RemoteStateMan` had `lastDownReason` (the socket dropped), `stopReason`
/// (the gateway refused this build) and `complaints` (the diagnostic list), and
/// **no way to say "the gateway stalled"**, though the gateway put exactly that
/// on the wire. That is structurally the pub/sub survey's finding for the tick
/// sequence, in a third place: the wire carries the fact, the client decodes it
/// and discards it (07-07's G1 precedent, made explicit for this row).
///
/// **These arms use a real socket** because the thing under test is a
/// notification handler, and a notification handler needs a `Peer`, which needs
/// a channel. The scripted gateway below is `resync_test.dart`'s
/// `_SequencedGateway` aimed at a different property: that one scripts sequences
/// to drive recovery, this one scripts `resync` notifications to drive the
/// stall surface.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// The wire reason a stalled gateway announces itself under.
const _gatewayStalled = 'gateway_stalled';

/// The one key the panel watches.
const _pageKey = 'ST101.CN01.MOT01.setpoint';
const _pageHandle = 1;
const _page = 'page';

/// A gateway that answers hello and subscribe by script and pushes whatever
/// `resync` notification an arm asks it to.
final class _StallGateway {
  _StallGateway._(this._http);

  static Future<_StallGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _StallGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many sessions this gateway has accepted — the reconnect arm reads it.
  int connections = 0;

  int _generation = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      _link = socket;
      connections++;
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
                  server: const PeerInfo('stall-gateway', '0.0.1'),
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
                  'seq': 0,
                  'generation': ++_generation,
                  'handles': {_pageKey: _pageHandle},
                  'snapshot': {
                    '$_pageHandle': WireValue.of(1200).toJson(),
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

  /// Pushes one `resync` notification for [sub] with [reason] and [stalledMs].
  void resync(String sub, String reason, {int? stalledMs}) => _send({
        'jsonrpc': '2.0',
        'method': Methods.resync,
        'params': ResyncParams(
          sub: sub,
          epoch: 'E1',
          reason: reason,
          stalledMs: stalledMs,
        ).toJson(),
      });

  /// Drops the current socket, so the client reconnects and accepts a new one.
  Future<void> dropLink() async {
    await _link?.close();
    _link = null;
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

/// The client's knobs for these arms.
///
/// A long freshness deadline: a scripted gateway that only speaks when an arm
/// tells it to is a silent link, and a watchdog that tore it down mid-arm would
/// reconnect and clear the very surface the arm is reading.
ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(seconds: 2),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// Builds a client pointed at [gateway] and waits for it to be ready.
Future<RemoteStateMan> _connected(_StallGateway gateway) async {
  final client = RemoteStateMan(
    uri: gateway.uri,
    config: _config(),
    keys: const {_pageKey},
  );
  addTearDown(client.dispose);
  await _until('the client to be ready', () => client.isReady);
  return client;
}

Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after 5000 ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('a gateway_stalled resync makes the reason and duration readable',
      () async {
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);

    gateway.resync(_page, _gatewayStalled, stalledMs: 9840);

    await _until('the stall surface to carry the reason',
        () => client.stallReason == _gatewayStalled);
    expect(client.stallReason, _gatewayStalled,
        reason: 'the gateway announced its event loop stalled and the panel '
            'still cannot say so — the reason crossed the wire and was decoded '
            'and dropped, which is the F20-shaped defect Ruling 5a permits '
            'fixing');
    expect(client.stalledMs, 9840,
        reason: 'the panel can say "stalled" but not "for how long", so the '
            'operator sentence is half-built');
  });

  test('a non-stall resync leaves the stall surface unchanged', () async {
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);

    gateway.resync(_page, _gatewayStalled, stalledMs: 5000);
    await _until('the stall to be recorded',
        () => client.stallReason == _gatewayStalled);

    // The ordinary case: an epoch bump, a server restart — a resync that is not
    // a stall. It must not clear a real stall to a misleading default nor set a
    // bogus one. (`reason` is non-nullable on the wire, so "no reason" is
    // unrepresentable; the ordinary reasons are the vocabulary.)
    gateway.resync(_page, 'epoch_changed');
    // Give the notification time to be handled, then assert it changed nothing.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(client.stallReason, _gatewayStalled,
        reason: 'an epoch_changed resync cleared a real gateway_stalled '
            'surface — a panel that had a true stall to report now reports '
            'nothing');
    expect(client.stalledMs, 5000,
        reason: 'the duration of the real stall was lost when an unrelated '
            'resync arrived');
  });

  test('fifty subscriptions resyncing on one stall produce one complaint',
      () async {
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);
    final before = client.complaints.length;

    // One stall, announced per subscription — fifty resyncs on one wire.
    for (var i = 0; i < 50; i++) {
      gateway.resync('page-$i', _gatewayStalled, stalledMs: 4000);
    }

    await _until('the stall to be recorded', () => client.stalledMs == 4000);
    // Let every one of the fifty be handled before counting.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final added = client.complaints.length - before;
    expect(added, 1,
        reason: 'fifty subscriptions resyncing on one stall produced $added '
            'complaints; one stall is one operator-facing sentence, not fifty '
            '(WR-02\'s damping shape). A complaint at the resync cadence is the '
            'unbounded list WR-07 is about');
  });

  test('the stall surface starts clean on a fresh connection', () async {
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);

    gateway.resync(_page, _gatewayStalled, stalledMs: 7000);
    await _until('the stall to be recorded',
        () => client.stallReason == _gatewayStalled);

    // The socket dies; the client reconnects and takes a fresh snapshot.
    await gateway.dropLink();
    await _until('the client to reconnect',
        () => gateway.connections >= 2 && client.isReady);

    expect(client.stallReason, isNull,
        reason: 'a stall reported over the previous socket is not a fact about '
            'this one — the surface must start clean, or a panel shows an old '
            'freeze as if it just happened');
    expect(client.stalledMs, isNull,
        reason: 'the duration of a previous connection\'s stall survived a '
            'reconnect');

    // And the once-per-connection damper is RE-ARMED, not merely the surface
    // cleared (09-REVIEW IN-02): a regression that cleared the surface but
    // left _stallComplained set would silence every stall after the first
    // for the process lifetime, and without this half the suite stayed green
    // through it. A second connection's stall is a second operator sentence.
    final before = client.complaints.length;
    gateway.resync(_page, _gatewayStalled, stalledMs: 8000);
    await _until('the second connection\'s stall to be recorded',
        () => client.stalledMs == 8000);
    expect(client.complaints.length - before, 1,
        reason: 'a stall on the second connection produced no complaint — the '
            'surface was reset on reconnect but the damper was not, so the '
            'first stall of the process is the only one an engineer ever '
            'reads about');
  });

  test('the stall surface carries its own age, so a panel can say WHEN',
      () async {
    // 09-REVIEW IN-05: stallReason/stalledMs persist until the connection
    // dies, so a widget binding them on a long-lived healthy connection
    // showed "gateway stalled for 5015 ms" hours after the fact with nothing
    // to age it by. stallAge is the "when" — capture time on this side,
    // measured on the panel's monotonic clock (a display fact, not a wire
    // fact, so no gateway clock arithmetic and no NTP exposure).
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);

    expect(client.stallAge, isNull,
        reason: 'no stall has been announced on this connection, so there is '
            'no age to render — a zero here would read as "a stall just '
            'happened"');

    gateway.resync(_page, _gatewayStalled, stalledMs: 5015);
    await _until('the stall to be recorded',
        () => client.stallReason == _gatewayStalled);

    final first = client.stallAge;
    expect(first, isNotNull,
        reason: 'the stall is on the surface but carries no age — the first '
            'widget built on this surface has nothing to age the sentence by');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final second = client.stallAge;
    expect(second, greaterThan(first!),
        reason: 'the age does not climb, so it is a stored constant rather '
            'than a measurement — "5015 ms, 0 s ago" forever is the same '
            'stale-sentence defect one field over');

    // Cleared with the pair: an old connection's stall age on a new
    // connection would be the exact confusion the surface reset exists for.
    await gateway.dropLink();
    await _until('the client to reconnect',
        () => gateway.connections >= 2 && client.isReady);
    expect(client.stallAge, isNull,
        reason: 'the age survived the reconnect that cleared the reason and '
            'duration — the three fields must travel as one surface');
  });

  test('stalledMs is carried through as the absolute figure the gateway sent',
      () async {
    final gateway = await _StallGateway.start();
    final client = await _connected(gateway);

    // A distinctive figure no clock arithmetic on this side would produce.
    gateway.resync(_page, _gatewayStalled, stalledMs: 42137);

    await _until('the stall to be recorded',
        () => client.stallReason == _gatewayStalled);
    expect(client.stalledMs, 42137,
        reason: 'the surfaced duration is not the exact figure the gateway '
            'sent, so it was recomputed from this panel\'s clock — which drifts '
            'and defeats the point of the gateway sending an absolute number');
  });
}
