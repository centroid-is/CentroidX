/// `preferences.changed` carries a **list** of keys, and the client fans it
/// out to one event per key.
///
/// 10-PATTERNS finding 7, ruled in 10-CONTEXT amendment 4. The shape shipped
/// with one key per frame, and a `clear()` over 500 keys is then 500 frames
/// per connected client on the un-conflated priority lane — which is how a
/// settings page evicts every panel in the plant with `4004`
/// (`CloseCodes.backpressureOverrun`). One frame per burst is the fix; this
/// file is the receiving half of it.
///
/// **The fan-out is here and the coalescing is not.** The client's job is to
/// turn one frame into N events; deciding what goes in one frame is the
/// gateway's, and it lands in 10-05 task 2. A second buffer on this side would
/// delay an edit an operator is watching for, to save nothing.
///
/// The gateway is a slim relative of `remote_state_man_test.dart:1187-1289`'s
/// `_FakeGateway`, kept here rather than shared for the reason that file
/// already gives about another package's `test/` tree: it answers a handshake,
/// a subscribe and nothing else, and it can be told to speak on demand.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

const _key = 'Line1.Motor1';
const _page = 'page';

/// Long enough that no arm here races it, except the one that wants it.
const _budget = Duration(seconds: 5);

void main() {
  group('one frame, many keys', () {
    test('three keys produce three events, in order', () async {
      final panel = await _panel();

      panel.gateway.notifyLive(DataServiceMethods.preferencesChanged, {
        'keys': ['ui.theme', 'ui.locale', 'chart.window'],
      });

      await _until('all three announcements to reach the stream',
          () => panel.changed.length >= 3);
      await _settle();
      expect(panel.changed, ['ui.theme', 'ui.locale', 'chart.window'],
          reason: 'one frame naming three keys is three edits a settings page '
              'has to re-read, and the order is the order the gateway applied '
              'them in — a listener that re-reads in a different order can '
              'settle on the older of two writes to the same key');
    });

    test('one key still produces one event', () async {
      final panel = await _panel();

      panel.gateway.notifyLive(DataServiceMethods.preferencesChanged, {
        'keys': ['ui.theme'],
      });

      await _until('the announcement to reach the stream',
          () => panel.changed.isNotEmpty);
      await _settle();
      expect(panel.changed, ['ui.theme'],
          reason: 'the single-key case is the common one — one operator '
              'changing one setting — and the list shape must not turn it '
              'into anything cleverer than one event');
      expect(panel.client.complaints, isEmpty,
          reason: 'a well-formed frame is not a complaint');
    });

    test('a burst of five hundred keys is one frame and five hundred events',
        () async {
      // The case amendment 4 exists for. Five hundred keys used to be five
      // hundred frames on the priority lane; here they are one.
      final panel = await _panel();
      final keys = [for (var i = 0; i < 500; i++) 'bulk.$i'];

      panel.gateway
          .notifyLive(DataServiceMethods.preferencesChanged, {'keys': keys});

      await _until('all five hundred announcements',
          () => panel.changed.length >= 500);
      await _settle();
      expect(panel.changed, keys,
          reason: 'a clear() over five hundred keys reaches every local '
              'listener, and it costs the wire exactly one frame');
      expect(panel.gateway.notificationsSent, 1,
          reason: 'anti-vacuity for the whole file: if the fan-out were done '
              'by sending N frames the assertion above would also pass, and '
              'the backpressure eviction amendment 4 names would be exactly '
              'as bad as before');
    });
  });

  group('a malformed frame is refused, armed and dropped', () {
    test('no keys field at all', () async {
      final panel = await _panel();

      panel.gateway
          .notifyLive(DataServiceMethods.preferencesChanged, {'nothing': 1});

      await _settle();
      expect(panel.changed, isEmpty,
          reason: 'a settings listener told that "null" changed goes and '
              're-reads a preference nobody has — refusing is the same answer '
              'a frame with no "key" got before the list landed');
      expect(panel.client.isReady, isTrue,
          reason: 'and a malformed notification is not fatal to the link: it '
              'is one bad frame, not a reason to evict a running panel');
      expect(panel.gateway.accepted, 1,
          reason: 'the client did not tear the socket down and redial over it');
    });

    test('keys is not a list', () async {
      final panel = await _panel();

      panel.gateway.notifyLive(
          DataServiceMethods.preferencesChanged, {'keys': 'ui.theme'});

      await _settle();
      expect(panel.changed, isEmpty,
          reason: 'a bare string is the old shape spelled under the new name; '
              'splitting it into characters or announcing it whole would both '
              'be guesses');
      expect(panel.client.isReady, isTrue);
    });

    test('an element is not a string', () async {
      final panel = await _panel();

      panel.gateway.notifyLive(DataServiceMethods.preferencesChanged, {
        'keys': ['ui.theme', 7],
      });

      await _settle();
      expect(panel.changed, isEmpty,
          reason: 'the whole frame is refused rather than the good half kept: '
              'a frame this malformed came from a gateway that is not sending '
              'what it thinks it is, and announcing the readable half would '
              'hide that while leaving the other key stale');
      expect(panel.client.isReady, isTrue);
    });

    test('an empty keys list announces nothing and is not a complaint',
        () async {
      final panel = await _panel();

      panel.gateway
          .notifyLive(DataServiceMethods.preferencesChanged, {'keys': <String>[]});

      await _settle();
      expect(panel.changed, isEmpty,
          reason: 'nothing changed, so nobody is told anything');
      expect(panel.client.isReady, isTrue);
    });

    test('a good frame after a bad one still announces — anti-vacuity',
        () async {
      // Without this arm every case above is satisfied by a client that
      // dropped the notification handler altogether.
      final panel = await _panel();

      panel.gateway
          .notifyLive(DataServiceMethods.preferencesChanged, {'keys': 3});
      await _settle();
      expect(panel.changed, isEmpty);

      panel.gateway.notifyLive(DataServiceMethods.preferencesChanged, {
        'keys': ['ui.theme'],
      });

      await _until('the good frame to get through',
          () => panel.changed.isNotEmpty);
      expect(panel.changed, ['ui.theme'],
          reason: 'the refusal armed and dropped one frame; it did not '
              'poison the handler for the next one');
    });
  });

  group('the notification is evidence the link is alive', () {
    test('a stream of changed frames alone keeps the link from going quiet',
        () async {
      // `_preferenceChanged` calls `watchdog.sawFrame`, and this is the arm
      // that says so in behaviour rather than by reading the source. The
      // gateway answers the handshake and then says nothing at all except
      // these notifications, so if they did not count the freshness deadline
      // would expire and the supervisor would redial — the half-open case a
      // close code never arrives for (`connection_supervisor.dart:905-915`).
      final panel = await _panel(freshness: const Duration(milliseconds: 400));

      final pump = Timer.periodic(const Duration(milliseconds: 80), (_) {
        panel.gateway.notifyLive(DataServiceMethods.preferencesChanged, {
          'keys': ['ui.theme'],
        });
      });
      addTearDown(pump.cancel);

      await _within(const Duration(milliseconds: 1200));
      pump.cancel();

      expect(panel.changed.length, greaterThan(4),
          reason: 'anti-vacuity: the pump has to have actually delivered, or '
              '"the link stayed up" is a claim about a link nothing was sent '
              'on');
      expect(panel.gateway.accepted, 1,
          reason: 'three freshness deadlines went by with no tick, no update '
              'and no response — only these notifications. Each one is a '
              'frame from the gateway and therefore proof the link is alive; '
              'a client that did not count them would have declared the '
              'gateway half-open and redialled');
      expect(panel.client.isReady, isTrue,
          reason: 'and the panel is still showing live values rather than a '
              'reconnecting banner');
    });
  });
}

/// One connected panel, its gateway, and everything its preference stream saw.
typedef _Panel = ({
  _SlimGateway gateway,
  RemoteStateMan client,
  List<String> changed,
});

/// Starts a gateway, connects a panel to it, and listens to its preferences.
Future<_Panel> _panel({Duration? freshness}) async {
  final gateway = await _SlimGateway.start();
  final client = RemoteStateMan(
    uri: Uri.parse('ws://127.0.0.1:${gateway.port}'),
    config: ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: freshness ?? const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    ),
    keys: const {_key},
  );
  addTearDown(client.dispose);
  await _until('the link', () => client.isReady);

  final changed = <String>[];
  final listening = client.preferences.onPreferencesChanged.listen(changed.add);
  addTearDown(listening.cancel);
  return (gateway: gateway, client: client, changed: changed);
}

/// Polls [done] until it holds or [_budget] runs out, naming [what] on failure.
Future<void> _until(String what, bool Function() done) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets the event loop and the socket run for [span].
Future<void> _within(Duration span) async {
  final deadline = DateTime.now().add(span);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Lets whatever is in flight arrive, so "nothing happened" is a claim about a
/// drained event loop rather than about an unlucky moment.
Future<void> _settle() => _within(const Duration(milliseconds: 120));

/// A gateway that answers `hello` and `subscribe` and otherwise speaks only
/// when told to.
final class _SlimGateway {
  _SlimGateway._(this._http);

  static Future<_SlimGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _SlimGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final List<WebSocket> _links = <WebSocket>[];

  /// How many sockets have been accepted. A redial makes it two, which is how
  /// "the client decided the link was dead" is observed from out here.
  int get accepted => _links.length;

  /// How many notifications this gateway has sent. The fan-out claim is only
  /// interesting against this number.
  int notificationsSent = 0;

  int get port => _http.port;

  void notifyLive(String method, Map<String, Object?> params) {
    if (_links.isEmpty) return;
    notificationsSent++;
    _send(_links.last, {'jsonrpc': '2.0', 'method': method, 'params': params});
  }

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
          switch (method) {
            case Methods.hello:
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('slim-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': 0,
                  'handles': {_key: 1},
                  'snapshot': {'1': WireValue.of(true).toJson()},
                },
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
      // The teardown window `remote_state_man_test.dart:1289-1320` documents.
    }
  }

  Future<void> shutdown() async {
    for (final socket in _links) {
      await socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}
