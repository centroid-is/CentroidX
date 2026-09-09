@TestOn('vm')

/// `RemoteStateMan.recentAlarms`: the client half of `Methods.alarmHistory`.
///
/// ## What this file is about, in one sentence
///
/// A gateway-mode panel asking what went wrong last shift either gets the
/// plant's history or gets something it can show the operator — and **never an
/// empty list it did not earn**.
///
/// ## Why that sentence needed a file
///
/// `RelayAlarmSource.getRecentAlarms` read the panel's own database, under a
/// ruling whose premise was that a gateway-mode panel has one. It stopped
/// having one: `lib/providers/preferences.dart:60` branches on the transport
/// before it reads the config row, so `Preferences` is built with `db: null` and
/// `if (preferences.database == null) return []` became the only branch that
/// ever ran. No error, no log line, no badge — a history page that looks like a
/// factory which has never had an alarm. Every arm in the `unreadable` group
/// exists to keep the *replacement* from having the same property.
///
/// ## Why the frame is asserted against literals
///
/// `alarm_ack_test.dart`'s rule, verbatim: a case that builds the expected frame
/// with the code the production path builds it with asserts nothing about the
/// wire. Rename a field on both halves at once and the case passes while every
/// deployed gateway answers `INVALID_PARAMS`.
///
/// ## Why `-32601` gets a type of its own
///
/// The same pair-of-arms argument `alarm_ack_test.dart` makes. "This gateway
/// predates alarm history" and "this gateway serves no alarm history" are fixed
/// by different people in different places, and both are different again from
/// "this plant has had no alarms". Three sentences, and the failure this whole
/// change is about is the third one being said when one of the first two was
/// true.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:json_rpc_2/error_code.dart' as rpc_errors;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/deadline.dart';
import 'package:tfc_relay_client/src/failure_taxonomy.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
// The gateway's own codes, read from the gateway rather than restated as
// numbers — `alarm_ack_test.dart`'s reason: an arm spelling `-32011` would go
// on passing after the server renumbered it.
import 'package:tfc_relay_server/src/error_codes.dart';

const String _seededKey = 'PIPE.connected';

/// The budget for "the panel came back": a backoff draw, a dial, a handshake.
const Duration _recovery = Duration(seconds: 5);

/// Long enough for anything that was going to reach the wire to have reached
/// it — used only where the property is that *nothing* further happened.
const Duration _settle = Duration(milliseconds: 400);

final DateTime _from = DateTime.utc(2026, 9, 1, 6);
final DateTime _to = DateTime.utc(2026, 9, 1, 14);

AlarmHistoryEntry _row({String uid = 'CN04.MOT01', int? ruleIndex = 1}) =>
    AlarmHistoryEntry(
      uid: uid,
      ruleIndex: ruleIndex,
      level: 'error',
      title: 'Motor overload',
      description: 'the drive tripped',
      group: const ['Line 3'],
      expression: 'a{10.0} > 5',
      acknowledgeRequired: true,
      createdAt: DateTime.utc(2026, 9, 1, 7, 18, 3),
      deactivatedAt: DateTime.utc(2026, 9, 1, 7, 22, 3),
      tsSource: AlarmActiveEntry.tsSourcePlant,
    );

ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 400),
      writeDeadline: const Duration(milliseconds: 400),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: const Duration(milliseconds: 40),
      backoffCap: const Duration(milliseconds: 400),
      deadlineFloor: const Duration(milliseconds: 50),
    );

RemoteStateMan _client(int port, {ClientConfig? config}) {
  final client = RemoteStateMan(
    uri: Uri.parse('ws://127.0.0.1:$port'),
    config: config ?? _config(),
    keys: const {_seededKey},
  );
  addTearDown(client.dispose);
  return client;
}

Future<void> _until(String what, bool Function() done,
    {Duration budget = _recovery}) async {
  final deadline = DateTime.now().add(budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${budget.inMilliseconds} ms waiting for: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Errors the scripted gateway threw while answering. Collected rather than
/// thrown: the script runs in the ambient zone, so a throw there would fail
/// whichever case happened to be running.
final List<String> _escaped = <String>[];

List<Map<String, Object?>> _queries(_FakeGateway gateway) => gateway.frames
    .where((frame) => frame['method'] == Methods.alarmHistory)
    .toList(growable: false);

final class _Admission {
  bool open = false;
}

Future<_FakeGateway> _gatewayAnswering(
        void Function(_FakeLink link, int id) answer) =>
    _FakeGateway.start((link, method, id, params) {
      switch (method) {
        case Methods.hello:
          link.hello(id);
        case Methods.subscribe:
          link.snapshot(id, defaultPageSubscription);
        case Methods.alarmHistory:
          answer(link, id);
        default:
          break;
      }
    });

/// Every public member name declared on [type], inherited ones included.
/// `alarm_ack_test.dart`'s walk, copied for the reason it records.
Set<String> _declaredMemberNames(Type type) {
  final seen = <String>{};
  final visited = <ClassMirror>{};

  void walk(ClassMirror mirror) {
    if (!visited.add(mirror)) return;
    for (final member in mirror.declarations.values.whereType<MethodMirror>()) {
      if (member.isConstructor || member.isPrivate) continue;
      final name = MirrorSystem.getName(member.simpleName);
      seen.add(name.endsWith('=') ? name.substring(0, name.length - 1) : name);
    }
    mirror.superinterfaces.forEach(walk);
    final parent = mirror.superclass;
    if (parent != null && parent.reflectedType != Object) walk(parent);
  }

  walk(reflectClass(type));
  return seen;
}

void main() {
  group('the frame', () {
    test('recentAlarms puts the window on the wire and nothing else', () async {
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(const [])));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client
          .recentAlarms(limit: 250, from: _from, to: _to)
          .timeout(_recovery);

      final queries = _queries(gateway);
      expect(queries, hasLength(1),
          reason: 'one page load is one frame. Everything the gateway was '
              'sent: ${gateway.frames}');
      // Literals, not `AlarmHistoryParams(...).toJson()`. See the library doc.
      expect(queries.single['params'], {
        'limit': 250,
        'fromMs': _from.millisecondsSinceEpoch,
        'toMs': _to.millisecondsSinceEpoch,
      });
      expect(queries.single['method'], 'alarmHistory');
      expect(queries.single['id'], isNotNull,
          reason: 'a query is a request, not a notification: a frame with no '
              'id can never carry the answer or the refusal');
    });

    test('an unbounded window omits both bounds rather than sending nulls',
        () async {
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(const [])));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client.recentAlarms(limit: 10).timeout(_recovery);

      expect(_queries(gateway).single['params'], const {'limit': 10},
          reason: '17-06 measured what a present-null costs on this wire: '
              'every call answering -32602');
    });

    test('the rows come back decoded, newest-first order preserved', () async {
      final rows = [_row(), _row(uid: 'CN05.MOT01', ruleIndex: null)];
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(rows)));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      final answer = await client.recentAlarms(limit: 10).timeout(_recovery);

      expect(answer, rows,
          reason: 'order is the gateway\'s, unchanged — two transports that '
              'disagreed about which end of the list is newest would draw the '
              'same plant two ways on the same screen');
    });

    test('an empty history is answered as an empty list', () async {
      // The one case that must stay representable: a plant that genuinely has
      // had no alarms in the window says so, legibly. What must never happen
      // is that answer being *invented*, which is the group below.
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(const [])));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      expect(await client.recentAlarms(limit: 10).timeout(_recovery), isEmpty);
    });
  });

  group('an unreadable answer is never an empty history', () {
    test('an answer of the wrong shape throws instead of returning []',
        () async {
      // **The arm this file exists for.** Every other failure here is loud.
      // This is the one that reproduces the original defect if it is written
      // the tolerant way — and tolerant is exactly how `AlarmActiveEntry`
      // decodes, deliberately and correctly, because there the previous active
      // set stands and a banner must not go blank. History has no previous set
      // to stand on.
      final gateway =
          await _gatewayAnswering((link, id) => link.result(id, 'history'));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<FormatException>()),
        reason: 'returning [] here would put an empty page on screen and '
            'present it as the plant\'s history — the exact silence this '
            'change removes, reintroduced one layer down',
      );
    });

    test('an answer with no entries list throws', () async {
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, const <String, Object?>{'rows': []}));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(client.recentAlarms(limit: 10).timeout(_recovery),
          throwsA(isA<FormatException>()));
    });

    test('one unreadable row refuses the whole answer', () async {
      // Not "skip it and return the rest". A history quietly missing rows is a
      // stop analysis missing the interval nobody knows is missing.
      final gateway = await _gatewayAnswering((link, id) => link.result(id, {
            'entries': [
              _row().toJson(),
              {..._row().toJson(), 'tsSource': 'ntp'},
            ]
          }));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(client.recentAlarms(limit: 10).timeout(_recovery),
          throwsA(isA<FormatException>()));
    });
  });

  group('the three ways a gateway declines', () {
    test('a gateway refusal is thrown carrying the gateway\'s own words',
        () async {
      const refusal = 'this gateway does not serve "ALARM.active"';
      final gateway = await _gatewayAnswering(
          (link, id) => link.error(id, rpc_errors.INVALID_PARAMS, refusal));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<rpc.RpcException>()
            .having((e) => e.code, 'code', rpc_errors.INVALID_PARAMS)
            .having((e) => e.message, 'message', contains(refusal))),
      );
    });

    test('METHOD_NOT_FOUND is a named failure of its own', () async {
      final gateway = await _gatewayAnswering((link, id) => link.error(
          id,
          rpc_errors.METHOD_NOT_FOUND,
          'Unknown method "${Methods.alarmHistory}".'));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<AlarmHistoryUnsupported>()
            .having((e) => e.method, 'method', Methods.alarmHistory)),
        reason: 'a panel against a gateway from before this change must be '
            'able to say "this gateway cannot answer alarm history" rather '
            'than "history was refused" — and above all rather than drawing an '
            'empty page',
      );
    });

    test('the no-source refusal is not that type', () async {
      // The gateway's own words and its own code: it refuses by name when it
      // serves no `AlarmHistorySource`, under `handlerFailed`.
      const noSource = 'this gateway serves no alarm history, so there is '
          'nothing to read';
      final gateway = await _gatewayAnswering(
          (link, id) => link.error(id, ServerErrorCodes.handlerFailed, noSource));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<rpc.RpcException>()
            .having((e) => e.message, 'message', contains(noSource))),
      );
      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isNot(isA<AlarmHistoryUnsupported>())),
        reason: 'a gateway that knows the name and serves no reader is a '
            'composition problem; one that does not know the name is a '
            'version problem. This arm and the one above it must disagree or '
            'neither is measuring anything',
      );
    });
  });

  group('no link, no invented answer', () {
    test('with no link it throws LinkDown and reads nothing', () async {
      final admit = _Admission();
      final gateway = await _FakeGateway.start((link, method, id, params) {
        if (!admit.open) return;
        switch (method) {
          case Methods.hello:
            link.hello(id);
          case Methods.subscribe:
            link.snapshot(id, defaultPageSubscription);
          case Methods.alarmHistory:
            link.result(id, AlarmHistoryEntry.encodeList(const []));
          default:
            break;
        }
      });
      final client = _client(gateway.port);

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<LinkDown>()
            .having((e) => e.method, 'method', Methods.alarmHistory)),
        reason: 'a link that is not there is not a plant with no alarms, and '
            'the failure has to name the call or a log says a panel stopped '
            'working without saying which page went blank',
      );
      expect(_queries(gateway), isEmpty,
          reason: 'the throw is only half the property: a client that reported '
              'LinkDown and left the frame parked would still be a queue');
    });
  });

  group('the surface', () {
    test('after dispose it refuses by name', () async {
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(const [])));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client.dispose();

      await expectLater(
        client.recentAlarms(limit: 10).timeout(_recovery),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains(Methods.alarmHistory))),
        reason: 'a page that closed has no round trip left to make and no '
            'answer that would not be invented',
      );
      expect(_queries(gateway), isEmpty);
    });

    test('an impossible window is refused here, before a frame leaves',
        () async {
      final gateway = await _gatewayAnswering(
          (link, id) => link.result(id, AlarmHistoryEntry.encodeList(const [])));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
          client.recentAlarms(limit: 0).timeout(_recovery), throwsArgumentError);
      await Future<void>.delayed(_settle);

      expect(_queries(gateway), isEmpty,
          reason: 'a query that could only ever answer empty is caught at the '
              'caller, where the sentence can still say which argument was '
              'wrong');
    });

    test('StateManApi did not grow', () {
      final actual = _declaredMemberNames(StateManApi);

      expect(actual, hasLength(18),
          reason: 'the count is written down so a same-size swap cannot slip '
              'through as a coincidence');
      expect(actual, isNot(contains('recentAlarms')),
          reason: 'alarm history has no LocalStateMan meaning — on the backend '
              'the alarm engine and its history writer are reached directly, '
              'not through a state-management call — so putting it on the '
              'interface would oblige every implementation, and the shared '
              'contract suite, to answer for a capability only one of them '
              'has. Same ruling as ackAlarm, for the same reason');
    });

    test('no scripted answer escaped into the zone', () async {
      await Future<void>.delayed(_settle);
      expect(_escaped, isEmpty,
          reason: 'the fake gateway threw while answering and the throw '
              'escaped into the ambient zone: $_escaped');
    });
  });
}

// ---------------------------------------------------------------------------
// The scripted gateway. `alarm_ack_test.dart`'s, verbatim.
// ---------------------------------------------------------------------------

typedef _Script = void Function(
    _FakeLink link, String method, int id, Map<String, Object?> params);

final class _FakeGateway {
  _FakeGateway._(this._http, this._script);

  static Future<_FakeGateway> start(_Script script) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _FakeGateway._(http, script);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final _Script _script;
  final List<_FakeLink> _links = <_FakeLink>[];

  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];

  int get port => _http.port;

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      final link = _FakeLink(socket);
      _links.add(link);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          frames.add(frame.cast<String, Object?>());
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
          final params = frame['params'];
          try {
            _script(link, method, id,
                params is Map ? params.cast<String, Object?>() : const {});
          } catch (error, stack) {
            _escaped.add('the fake gateway\'s script answering $method: '
                '${error.runtimeType} — $error\n$stack');
          }
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    }
  }

  Future<void> shutdown() async {
    for (final link in _links) {
      link._closing = true;
    }
    for (final link in _links) {
      await link.socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

final class _FakeLink {
  _FakeLink(this.socket);

  final WebSocket socket;

  bool _closing = false;

  void result(int id, Object? value) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'result': value,
      });

  void error(int id, int code, String message) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });

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

  void snapshot(int id, String sub) => result(id, {
        'sub': sub,
        'epoch': 'E1',
        'seq': 0,
        'handles': {_seededKey: 1},
        'snapshot': {'1': WireValue.of(true).toJson()},
      });

  void _send(Object? frame) {
    if (_closing) return;
    if (socket.readyState != WebSocket.open) return;
    try {
      socket.add(jsonEncode(frame));
    } on StateError {
      // A fake gateway throwing at teardown is never the finding.
    }
  }
}
