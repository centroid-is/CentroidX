@TestOn('vm')

/// `RemoteStateMan.ackAlarm`: the client half of `Methods.ackAlarm`.
///
/// **What this file is about, in one sentence.** An operator pressing
/// Acknowledge puts exactly one frame on the wire, through the same funnel every
/// other request on this client goes through, and the two ways a gateway can
/// decline are two answers a panel can act on differently.
///
/// **Why the frame is asserted against literals.** Arm 1 compares the params
/// map to `{'alarmUid': ..., 'ruleIndex': ...}` written out by hand rather than
/// to `AckAlarmParams(...).toJson()`. A case that builds the expected frame with
/// the same code the production path builds it with asserts nothing about the
/// wire: rename the field on both halves at once and the case still passes while
/// every deployed gateway starts answering `INVALID_PARAMS`. The literal is the
/// only thing in this package that is a statement about the protocol rather than
/// about the DTO.
///
/// **Why `-32601` gets a type of its own.** A name added to the protocol is
/// invisible to an old client and visible to a new one only as
/// `METHOD_NOT_FOUND`, so that code is the *one* place this phase's additive wire
/// change is observable. A panel that cannot tell it from an ordinary refusal
/// says "acknowledge was refused" when the truth is "this gateway predates alarm
/// acknowledge", and those two sentences send an operator to look for different
/// things — a permission that is missing versus a gateway that needs upgrading.
/// 14-12 made the gateway's *own* no-engine refusal share `handlerFailed`
/// (−32011) with a failing engine, deliberately, because a panel can do nothing
/// different about either. That is exactly why the version answer must not be
/// told apart by a code as well: arms 5 and 6 are a pair, and one of them
/// passing alone means the two flavours are not being distinguished at all.
///
/// **The no-queue arms are the point of the file, not decoration.** An ack that
/// waits on a dead barrier and goes out when the link returns is a button
/// pressed at 09:00 arriving at 09:10 — the queue `CLAUDE.md` names as the
/// negation of the write-safety property. Arms 7 and 8 assert both halves: the
/// throw, and the silence that follows it.
///
/// The scripted gateway at the bottom is `remote_state_man_test.dart:1195-1381`'s,
/// trimmed to what these arms need. It is copied rather than imported for the
/// reason that file gives about `test/` trees not being addressable by any
/// `package:` URI — and here it is not even a different package, only a
/// different file, so the copy is small on purpose: `hello`, `subscribe`, a
/// recorded frame list and a scriptable answer.
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
// numbers here: an arm that spelled `-32011` would go on passing after the
// server renumbered it, asserting a client behaviour against a code nothing
// sends. Reaching into another package's `src/` is this test tree's existing
// practice for exactly this reason — `support/fault_fixture.dart:71`,
// `gate/slow_link_gate_test.dart:62`.
import 'package:tfc_relay_server/src/error_codes.dart';

/// A key the scripted gateway snapshots, so the client reaches `ready` with a
/// real subscription behind it rather than an empty one.
const String _seededKey = 'PIPE.connected';

/// The alarm the arms acknowledge. A uid and a rule index, which is D-4's
/// identity of an open `alarm_history` row and the whole of what the frame
/// carries.
const String _uid = 'u-7';
const int _ruleIndex = 2;

/// The budget for "the panel came back": a capped backoff draw, a dial and a
/// handshake. A liveness budget, never a latency measurement.
const Duration _recovery = Duration(seconds: 5);

/// Long enough for anything that was going to reach the wire to have reached
/// it. Used only where the property is that *nothing* further happened, which
/// is the one shape a poll cannot establish — a poll for "no second frame"
/// passes the instant before the second frame.
const Duration _settle = Duration(milliseconds: 400);

/// The client's timing knobs. The deadline floor is lowered deliberately and
/// greppably (`client_config.dart`) so a barrier that never opens fails inside
/// a case's own budget instead of stalling it.
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

/// Polls [done] until it holds or [budget] runs out, and fails naming [what].
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

/// Errors the scripted gateway threw while answering, across the file's run.
///
/// Collected rather than thrown for `remote_state_man_test.dart:168-176`'s
/// reason: the script runs inside a socket's `listen` callback in the ambient
/// zone, so a throw there fails whichever case happens to be running.
final List<String> _escaped = <String>[];

/// The frames the gateway was sent that name [Methods.ackAlarm].
List<Map<String, Object?>> _acks(_FakeGateway gateway) => gateway.frames
    .where((frame) => frame['method'] == Methods.ackAlarm)
    .toList(growable: false);

/// A gateway that answers nothing until it is opened.
///
/// A mutable object rather than a captured `var`, because a local that is never
/// assigned inside a case reads as a constant to the analyzer and everything
/// past the guard becomes dead code — which would delete the only thing arm 7's
/// script does.
final class _Admission {
  bool open = false;
}

/// A gateway that handshakes and then answers `ackAlarm` with [answer].
///
/// [answer] is handed the link and the request id, so an arm can reply with a
/// result or throw a chosen `RpcException` back down the wire.
Future<_FakeGateway> _gatewayAnswering(
        void Function(_FakeLink link, int id) answer) =>
    _FakeGateway.start((link, method, id, params) {
      switch (method) {
        case Methods.hello:
          link.hello(id);
        case Methods.subscribe:
          link.snapshot(id, defaultPageSubscription);
        case Methods.ackAlarm:
          answer(link, id);
        default:
          break;
      }
    });

/// Every public member name declared on [type], inherited ones included.
///
/// `tfc_stateman_contract/test/api_surface_test.dart:163-194`'s walk, copied for
/// the same reason the gateway below is: another package's `test/` tree is not
/// addressable by any `package:` URI. `dart:mirrors` reflects the real type
/// rather than its source text, so a member arriving through a superinterface
/// is counted — which is exactly the door a "small" addition would come in by.
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

/// `StateManApi`'s agreed member table, as `api_surface_test.dart:54-69` writes
/// it. Restated here rather than imported for the `package:` URI reason above;
/// the two copies disagreeing is itself the finding.
const Set<String> _expectedStateManApi = {
  'listen',
  'subscribe',
  'read',
  'readFresh',
  'readMany',
  'write',
  'writeStatus',
  'holdToRun',
  'keys',
  'browse',
  'timeseries',
  'historyViews',
  'preferences',
  // The four access families, added to the interface by plan 17-03. They are
  // here for the same reason the four data services are: this copy exists to
  // disagree with `api_surface_test.dart` out loud, and a copy that is merely
  // stale disagrees for the wrong reason.
  'accessTemplates',
  'accessAdmin',
  'audit',
  'backendConfig',
  'dispose',
};

void main() {
  group('the frame', () {
    test('ackAlarm puts the alarm identity on the wire and nothing else',
        () async {
      final gateway = await _gatewayAnswering((link, id) => link.result(id, null));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client.ackAlarm(_uid, _ruleIndex).timeout(_recovery);

      final acks = _acks(gateway);
      expect(acks, hasLength(1),
          reason: 'one operator gesture is one frame. Everything the gateway '
              'was sent: ${gateway.frames}');
      // Literals, not `AckAlarmParams(...).toJson()`. See the library doc.
      expect(acks.single['params'], {'alarmUid': _uid, 'ruleIndex': _ruleIndex},
          reason: 'the wire shape drifted from the one 14-12 gave the gateway, '
              'and a rename applied to both halves of this repo at once still '
              'breaks every gateway already deployed');
      expect(acks.single['method'], 'ackAlarm',
          reason: 'the method name is the protocol; a constant that was '
              'renamed is a constant both ends agree about and no deployed '
              'gateway does');
      expect(acks.single['id'], isNotNull,
          reason: 'an acknowledge is a request and not a notification: it has '
              'an addressee, an authorization decision and an answer, and a '
              'frame with no id can never carry the refusal');
    });

    test('exactly one frame leaves for one call', () async {
      final gateway = await _gatewayAnswering((link, id) => link.result(id, null));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client.ackAlarm(_uid, _ruleIndex).timeout(_recovery);
      await Future<void>.delayed(_settle);

      expect(_acks(gateway), hasLength(1),
          reason: 'a convenience that "makes sure" by sending twice is caught '
              'here. Counted rather than asserted as a shape, because two '
              'identical frames are indistinguishable from one by any other '
              'means');
    });

    test('a null result completes the future with no value', () async {
      final gateway = await _gatewayAnswering((link, id) => link.result(id, null));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      // `Future<void>`: nothing to unwrap, nothing to believe about the row.
      // The operator's confirmation is the alarm leaving `ALARM.active`.
      await expectLater(client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
          completes);
    });
  });

  group('the two ways a gateway declines', () {
    test('a gateway refusal is thrown carrying the gateway\'s own words',
        () async {
      const refusal = 'this station may not acknowledge alarms';
      final gateway = await _gatewayAnswering((link, id) => link.error(
          id, ServerErrorCodes.forbidden, refusal));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isA<rpc.RpcException>()
            .having((e) => e.code, 'code', ServerErrorCodes.forbidden)
            .having((e) => e.message, 'message', contains(refusal))),
        reason: 'the operator reads the gateway\'s sentence — which names the '
            'missing permission and where it is fixed — rather than a generic '
            'one this client invented on its behalf',
      );
    });

    test('METHOD_NOT_FOUND is a named failure of its own', () async {
      final gateway = await _gatewayAnswering((link, id) => link.error(
          id,
          rpc_errors.METHOD_NOT_FOUND,
          'Unknown method "${Methods.ackAlarm}".'));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isA<AlarmAckUnsupported>()),
        reason: 'a panel talking to a gateway from before this phase must be '
            'able to say "this gateway cannot acknowledge" rather than '
            '"acknowledge was refused". The first sends somebody to upgrade a '
            'gateway; the second sends them hunting a permission that is not '
            'missing',
      );
    });

    test('the no-engine refusal is not that type', () async {
      // 14-12's own words, and its own code: the gateway refuses by name when
      // it serves no `AlarmAckSink`, under `handlerFailed` — shared with a
      // failing engine, because a panel can do nothing different about either.
      const noEngine = 'this gateway serves no alarm engine, so there is '
          'nothing to acknowledge into';
      final gateway = await _gatewayAnswering((link, id) =>
          link.error(id, ServerErrorCodes.handlerFailed, noEngine));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isA<rpc.RpcException>()
            .having((e) => e.message, 'message', contains(noEngine))),
      );
      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isNot(isA<AlarmAckUnsupported>())),
        reason: 'a gateway that knows the name and serves no engine is a '
            'composition problem; one that does not know the name is a version '
            'problem. They are fixed in different places and by different '
            'people, so telling them apart is the whole compatibility story — '
            'and this arm and the one above it must disagree or neither is '
            'measuring anything',
      );
    });
  });

  group('no queue, no retry', () {
    test('with no link it throws LinkDown and writes nothing', () async {
      // A gateway that accepts the socket and never answers `hello`, so the
      // readiness barrier stays shut and the ack meets it closed. A dead port
      // would prove the throw and nothing about the silence — there would be
      // no gateway to have received a frame.
      final admit = _Admission();
      final gateway = await _FakeGateway.start((link, method, id, params) {
        if (!admit.open) return;
        switch (method) {
          case Methods.hello:
            link.hello(id);
          case Methods.subscribe:
            link.snapshot(id, defaultPageSubscription);
          case Methods.ackAlarm:
            link.result(id, null);
          default:
            break;
        }
      });
      final client = _client(gateway.port);

      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isA<LinkDown>()
            .having((e) => e.method, 'method', Methods.ackAlarm)),
        reason: 'the failure has to name the call, or a log line says a panel '
            'stopped working without saying which gesture went nowhere',
      );
      expect(_acks(gateway), isEmpty,
          reason: 'the throw is only half the property. A client that reported '
              'LinkDown and left the frame parked would satisfy the assertion '
              'above and still be a queue');
    });

    test('the ack that failed for want of a link is never re-sent', () async {
      final admit = _Admission();
      final gateway = await _FakeGateway.start((link, method, id, params) {
        if (!admit.open) return;
        switch (method) {
          case Methods.hello:
            link.hello(id);
          case Methods.subscribe:
            link.snapshot(id, defaultPageSubscription);
          case Methods.ackAlarm:
            link.result(id, null);
          default:
            break;
        }
      });
      final client = _client(gateway.port);

      // **The link comes back while the call is still in the air, not after
      // it has settled.** The first version of this arm opened the gateway on
      // the line *below* the await, and a retry measured it: one bounded
      // re-attempt inside `ackAlarm` — send, catch LinkDown, wait a second,
      // send again — passed the whole file, because both attempts met the same
      // shut barrier and the second one threw the same LinkDown the arm was
      // asserting. The arm was pinning the *answer* and calling it the
      // property.
      //
      // The dangerous retry is the one that outlives the outage, so the outage
      // has to end underneath it. [_reopen] is comfortably past
      // `controlDeadline`, which is what keeps this from being a race in the
      // other direction: the first attempt's barrier has provably expired
      // before the gateway answers anything, so a passing run can never be a
      // run where the ack simply succeeded.
      const reopen = Duration(milliseconds: 700);
      final pending = client.ackAlarm(_uid, _ruleIndex).timeout(_recovery);
      final opening = Timer(reopen, () => admit.open = true);
      addTearDown(opening.cancel);

      await expectLater(pending, throwsA(isA<LinkDown>()),
          reason: 'the honest answer is owed at the time of the gesture, and '
              'it is owed even though the link is about to come back — an '
              'operator watching a spinner that resolves when the switch '
              'finishes rebooting has been told the plant answered');

      await _until('the link to come up under the refused ack',
          () => client.isReady);
      await Future<void>.delayed(_settle);

      expect(_acks(gateway), isEmpty,
          reason: 'an acknowledge that arrives at shift change is the queue '
              'CLAUDE.md names as the negation of the write-safety property, '
              'and a retry is how it gets written by accident. For an ack the '
              'operator symptom is mild — an alarm silenced later than it '
              'looked — but the principle is not: the moment a retry is '
              'acceptable here, the argument for one on `write` gets made by '
              'analogy, and there it is a second stroke of a ram. Everything '
              'the gateway was sent: ${gateway.frames}');
    });
  });

  group('the surface', () {
    test('after dispose it refuses by name', () async {
      final gateway = await _gatewayAnswering((link, id) => link.result(id, null));
      final client = _client(gateway.port);
      await _until('the link', () => client.isReady);

      await client.dispose();

      await expectLater(
        client.ackAlarm(_uid, _ruleIndex).timeout(_recovery),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains(Methods.ackAlarm))),
        reason: 'pinned free of `_request` so a future hand-rolled call cannot '
            'lose it: a page that closed has no round trip left to make and no '
            'answer that would not be invented',
      );
      expect(_acks(gateway), isEmpty);
    });

    test('StateManApi did not grow', () {
      final actual = _declaredMemberNames(StateManApi);

      expect(actual, _expectedStateManApi,
          reason: 'the surface api_surface_test.dart calls "the access-control '
              'policy" is implemented by LocalStateMan and exercised by a '
              'shared contract suite against both ends. An acknowledge has no '
              'LocalStateMan meaning at all — on the backend the alarm engine '
              'is reached directly — so putting it here would oblige every '
              'implementation to answer for a capability only one of them has');
      expect(actual, hasLength(18),
          reason: 'the count is written down so a same-size swap cannot slip '
              'through as a coincidence. It moved from 14 to 18 when plan '
              '17-03 added the four access families — and this copy going '
              'stale is exactly the disagreement it exists to produce, so it '
              'is updated deliberately rather than deleted');
      expect(actual, isNot(contains('ackAlarm')),
          reason: 'RemoteStateMan.ackAlarm is a public member that is '
              'deliberately off the interface, the way _write\'s hold flag is. '
              'If it is here, the contract suite and LocalStateMan both now owe '
              'an implementation of it');
    });

    test('no scripted answer escaped into the zone', () async {
      await Future<void>.delayed(_settle);
      expect(_escaped, isEmpty,
          reason: 'the fake gateway threw while answering and the throw '
              'escaped into the ambient zone: $_escaped. That fails whichever '
              'case happened to be running, which is a scaffold fault read as '
              'a product one');
    });
  });
}

// ---------------------------------------------------------------------------
// The scripted gateway. `remote_state_man_test.dart:1195-1381`, trimmed.
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

  /// Every frame this gateway has been sent, in order, decoded. Recorded rather
  /// than scripted because the no-queue arms assert on frames that were never
  /// answered — the claim is about what left the client, not about what came
  /// back.
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

  /// Whether *this* side asked for the close. `dart:io` will not tell you, and
  /// the window between `close()` and `readyState` moving is where
  /// `Bad state: StreamSink is closed` comes from — see
  /// `remote_state_man_test.dart:1314-1332` for the measurement.
  bool _closing = false;

  void result(int id, Object? value) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'result': value,
      });

  /// A JSON-RPC error, spelled as a frame rather than raised as an exception:
  /// the arms below are about what a *gateway* answered, and a throw inside the
  /// script would be this process's error rather than the wire's.
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
