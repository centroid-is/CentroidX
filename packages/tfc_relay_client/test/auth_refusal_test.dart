@TestOn('vm')

/// A credential the gateway refused stops the redial loop, and the refusal an
/// operator reads never repeats the credential back.
///
/// Source: 06-CONTEXT amendment 4 and 06-RESEARCH §C.6. Before this file, a
/// `-32003 unauthorized` on `hello` fell through to `_down` — which re-arms the
/// barrier and calls `_schedule()`. The gateway says the same thing about it
/// from the other end (`error_codes.dart:31-34`): "reconnecting with the same
/// token will be refused again, so a backoff loop around it is a busy loop."
///
/// **What breaks in the plant without this file.** An integrator mistypes one
/// character of a station token during a commissioning weekend. The panel dials,
/// is refused, waits out a capped backoff and dials again — one rejected hello
/// every thirty seconds, from that panel, forever, against the one process that
/// is also serving every other screen in the factory. Nothing on the panel says
/// why: the screen is grey and the link indicator says "connecting", which is
/// the same thing it says for a pulled cable, so the first person called is the
/// network electrician and not the person holding the token file. With the arm,
/// the panel is refused once and says so in a sentence naming the credential.
///
/// **Why the number is a local constant.** The client cannot import the
/// server's `ServerErrorCodes` — that package is a dev dependency here, and
/// `connection_supervisor.dart:92-98` forbids a production file reaching into
/// one. So `-32003` is declared in the supervisor and pinned by this file
/// driving it verbatim against a scripted gateway, exactly as
/// `reconnect_test.dart` pins `-32004`.
///
/// **The two arms are deliberately independent.** `a version refusal still
/// stops the loop` and `an ordinary refusal is retried like any other drop`
/// bracket the new `if`: deleting it must fail the credential cases and leave
/// both of those green, or the arm was a redirection of the version arm rather
/// than an addition beside it.
///
/// **The half this file does not own.** The credential-disclosure case pins the
/// *client's* half: the panel holds the token in `config.token` and must not
/// splice it into the string an operator reads. The gateway's half — that
/// `TokenRejected.reason` and `StatusParams.error` never echo the credential
/// back — is a server-side rule, tested server-side in 06-06. A case here that
/// scripted a gateway into echoing the token would be asserting the server's
/// rule from the one side that cannot enforce it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_client/src/dial/pinned_dialer_io.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// The JSON-RPC code the gateway refuses a credential with.
///
/// Driven verbatim, from the test side of the same package boundary the
/// supervisor's own constant sits on. Two literals that must agree, in two
/// files, with a case failing the moment they stop — which is the whole
/// mechanism keeping a number that crosses a package boundary honest.
const int _unauthorized = -32003;

/// The code for a protocol-version refusal, the arm this one sits beside.
const int _versionMismatch = -32004;

/// A refusal that is neither: the gateway had a bad minute.
const int _internalError = -32603;

/// The credential every case here drives.
///
/// Long and unmistakable on purpose. The disclosure case searches two
/// operator-facing strings for it, and a short or plausible-looking token could
/// collide with ordinary prose ("token", "station") and pass while leaking.
const String _credential = 'ST101-PANEL-CREDENTIAL-3f9a2b7c4e1d8065-DO-NOT-LOG';

/// A key the scripted gateway answers a subscribe for, so a case that needs the
/// panel to reach `ready` can get there.
const String _seededKey = 'PIPE.connected';

/// The attempt-0 backoff window, small enough that a redial this file is
/// waiting for happens inside a case's budget.
const Duration _base = Duration(milliseconds: 40);

/// The ceiling. Far below the production 30 s, for the same reason
/// `reconnect_test.dart` lowers it.
const Duration _cap = Duration(milliseconds: 200);

/// The budget for "the panel got where it was going".
const Duration _recovery = Duration(seconds: 5);

/// How long a case watches a *stopped* supervisor before believing it.
///
/// Seven attempt-0 windows and more than one ceiling: had the refusal left a
/// retry scheduled, or scheduled a fresh one, several would have fired inside
/// this. A stop is the absence of an event, and the only honest way to assert
/// an absence is to wait longer than the event would have taken.
const Duration _quietWindow = Duration(milliseconds: 300);

/// The client's knobs, with the deadline floor lowered deliberately — the same
/// explicit, greppable lowering `reconnect_test.dart` documents.
ClientConfig _config({String? token}) => ClientConfig(
      controlDeadline: const Duration(milliseconds: 400),
      writeDeadline: const Duration(milliseconds: 400),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: _base,
      backoffCap: _cap,
      deadlineFloor: const Duration(milliseconds: 50),
      token: token,
    );

/// Records every state the supervisor announced, and lets a case await one.
///
/// Attached before `start()`, which is the ordering property
/// `reconnect_test.dart:93-115` states: a transition can happen in the same
/// event-loop turn the connect completes in, so a listener attached afterwards
/// waits for something that already happened.
final class _StateLog {
  _StateLog(Stream<LinkState> states) {
    _sub = states.listen((state) {
      seen.add(state);
      final waiter = _waiting.remove(state);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });
  }

  final List<LinkState> seen = <LinkState>[];
  final Map<LinkState, Completer<void>> _waiting =
      <LinkState, Completer<void>>{};
  late final StreamSubscription<LinkState> _sub;

  Future<void> next(LinkState state) =>
      _waiting.putIfAbsent(state, Completer<void>.new).future;

  int count(LinkState state) => seen.where((s) => s == state).length;

  Future<void> cancel() => _sub.cancel();
}

/// Completes once [state] has been entered [n] times in total.
Future<void> _afterNth(_StateLog log, LinkState state, int n) async {
  while (log.count(state) < n) {
    await log.next(state);
  }
}

/// Counts dials by wrapping the real one, never by replacing it.
///
/// The `dial:` seam's own doc (`connection_supervisor.dart:172-185`) insists an
/// override stay "one attempt in, one `ConnectAttempt` out, same as the real
/// one" — so this delegates to [connect] rather than fabricating an outcome.
/// A counter that also decided what a dial returned would be measuring a
/// schedule it had itself invented.
final class _Dials {
  int count = 0;

  Future<ConnectAttempt> call(Uri uri) {
    count++;
    return connect(uri);
  }
}

/// Everything one case needs, built and torn down together.
final class _Panel {
  _Panel(this.supervisor, this.log, this.dials);

  final ConnectionSupervisor supervisor;
  final _StateLog log;
  final _Dials dials;
}

/// A supervisor pointed at [uri] with one subscription registered.
///
/// One rather than none, for `reconnect_test.dart:128-137`'s reason: with an
/// empty registry `resyncing` completes without a call reaching the wire, which
/// would make the mid-session case's `ready` meaningless.
_Panel _panel(Uri uri, {required int seed, String? token}) {
  final subscriptions = <String, SubscriptionState>{
    's1': SubscriptionState(subId: 's1', keys: {_seededKey}),
  };
  final stores = <String, ValueStore>{};
  final dials = _Dials();
  final supervisor = ConnectionSupervisor(
    uri: uri,
    config: _config(token: token),
    backoff: Backoff(base: _base, cap: _cap, random: Random(seed)),
    barrier: ReadinessBarrier(),
    watchdog:
        FreshnessWatchdog(config: _config(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (id) => stores.putIfAbsent(id, ValueStore.new),
    dial: dials.call,
  );
  final log = _StateLog(supervisor.states);
  addTearDown(log.cancel);
  addTearDown(supervisor.dispose);
  return _Panel(supervisor, log, dials);
}

/// How a scripted gateway answers one request.
typedef _Script = void Function(_Link link, String method, int id);

/// A hand-rolled gateway that answers JSON-RPC by script and keeps every
/// `hello` it was sent.
///
/// The same shape as `reconnect_test.dart:200-253`, which no `package:` URI can
/// reach from here. It keeps the hello params because one case asserts on what
/// crossed the wire rather than on what the client meant to send.
final class _Gateway {
  _Gateway._(this._http, this._script);

  static Future<_Gateway> start(_Script script) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _Gateway._(http, script);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final _Script _script;
  final List<_Link> links = <_Link>[];

  /// Every `hello` this gateway received, in order, as decoded params.
  final List<Map<String, Object?>> hellos = <Map<String, Object?>>[];

  int get port => _http.port;

  /// How many sockets were accepted — the client's dial count seen from the
  /// far end, and the cross-check on [_Dials].
  int get accepted => links.length;

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      final link = _Link(socket);
      links.add(link);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
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

  Future<void> shutdown() async {
    for (final link in links) {
      await link.socket.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

/// One accepted socket, with the replies these scripts need.
final class _Link {
  _Link(this.socket);

  final WebSocket socket;

  void result(int id, Object? value) =>
      _send({'jsonrpc': '2.0', 'id': id, 'result': value});

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

  void close(int code) =>
      unawaited(socket.close(code).catchError((Object _) => null));

  void _send(Object? frame) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }
}

/// A gateway that refuses every credential, in the shape the real one produces.
///
/// Both signals, in the order `relay_session.dart:701-709` emits them: the
/// pending `hello` rejects with `-32003`, and the socket then closes 4001.
/// Whichever reaches the client first must be able to stop the loop, which is
/// what `_stop` being ungenerationed is for.
Future<_Gateway> _refusingGateway() => _Gateway.start((link, method, id) {
      if (method != Methods.hello) return;
      link.error(id, _unauthorized,
          'hello refused: the credential is not in the station map');
      link.close(CloseCodes.authExpired);
    });

void main() {
  group('a refused credential is not a transient fault', () {
    test('a refused credential stops the redial loop', () async {
      final gateway = await _refusingGateway();
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 1, token: _credential);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel gave up on a refused credential',
          budget: _recovery);
      // A stop is an absence. Waiting longer than the schedule would have
      // taken is the only honest way to assert one.
      await Future<void>.delayed(_quietWindow);

      expect(panel.supervisor.stopped, isTrue,
          reason: 'a mistyped station token will not correct itself on the '
              'next attempt. A panel that keeps dialling turns one '
              'commissioning typo into a rejected hello every thirty seconds '
              'against the single process serving every other screen in the '
              'factory, and never says why');
      expect(panel.supervisor.debugScheduledWaits, isEmpty,
          reason: 'nothing may be scheduled after the refusal. A retry that '
              'is scheduled and then cancelled is a different property from '
              'one that was never scheduled, and only the second is what the '
              'gateway is being spared — this list is the schedule\'s own '
              'record of what it decided to do');
      expect(panel.dials.count, 1,
          reason: 'the -32003 and the 4001 close are one event; a second dial '
              'means the close was treated as its own reason to come back, '
              'which is the loop this arm exists to end');
      expect(gateway.accepted, 1,
          reason: 'the far end agrees with the near end about how many times '
              'it was dialled; a disagreement means the counter is wrapping '
              'something other than the real dial');
    });

    test('the operator is told it was the credential, in words', () async {
      final gateway = await _refusingGateway();
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 2, token: _credential);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel gave up on a refused credential',
          budget: _recovery);

      expect(panel.supervisor.stopReason, isNotNull);
      expect(panel.supervisor.stopReason, contains('credential'),
          reason: 'this string is what `RemoteStateMan.stopReason` forwards to '
              'the screen. "The handshake was refused" sends the integrator to '
              'the network; naming the credential sends them to the token '
              'file, which is where the fault is');
    });

    test('the refusal never repeats the credential back to the operator',
        () async {
      final gateway = await _refusingGateway();
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 3, token: _credential);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel gave up on a refused credential',
          budget: _recovery);

      // Anti-vacuity, and it is load-bearing: `isNot(contains(...))` is
      // satisfied by null, so a supervisor that never stopped at all would
      // pass this case while leaking nothing for the trivial reason that it
      // said nothing. The string has to exist before its contents mean
      // anything.
      expect(panel.supervisor.stopReason, isNotNull,
          reason: 'there is no disclosure claim to make about a message that '
              'was never produced');

      // The client is the one side that certainly *has* the credential — it is
      // sitting in `config.token` — so it is the side that could most easily
      // splice it into the message while trying to be helpful. The gateway's
      // half of this rule (never echoing the token in `TokenRejected.reason`
      // or `StatusParams.error`) is enforced server-side, in 06-06.
      expect(panel.supervisor.stopReason, isNot(contains(_credential)),
          reason: 'this string is displayed at the panel, on a screen in a '
              'public part of the factory floor. A credential printed there is '
              'a credential anyone walking past can copy, and rotating it '
              'means an integrator visiting the station');
      expect(panel.supervisor.lastDownReason ?? '',
          isNot(contains(_credential)),
          reason: 'the health line is the other operator-facing string, and it '
              'outlives the refusal — a leak here is a leak that stays on the '
              'screen');
    });

    test('a panel revoked mid-session redials exactly once', () async {
      // Live, then revoked: the gateway serves one whole session, the token
      // file changes underneath it, and the session is closed 4001 with no RPC
      // error attached. The panel cannot tell that close from a gateway
      // restart, so it must try again — once.
      var revoked = false;
      final gateway = await _Gateway.start((link, method, id) {
        if (method == Methods.hello) {
          if (revoked) {
            link.error(id, _unauthorized,
                'hello refused: the credential is not in the station map');
            link.close(CloseCodes.authExpired);
          } else {
            link.hello(id);
          }
          return;
        }
        if (method == Methods.subscribe) link.snapshot(id, 's1');
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 4, token: _credential);

      final ready = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(ready, 'the panel reached ready before the revocation',
          budget: _recovery);
      expect(panel.dials.count, 1,
          reason: 'the redial count below is only meaningful measured from a '
              'known start');

      final secondDown = _afterNth(panel.log, LinkState.down, 2);
      revoked = true;
      gateway.links.first.close(CloseCodes.authExpired);
      await within(secondDown, 'the panel dialled back and was refused',
          budget: _recovery);
      await Future<void>.delayed(_quietWindow);

      expect(panel.dials.count, 2,
          reason: 'exactly one redial. Zero would strand the panel on every '
              'gateway restart, because a bare 4001 close carries no way to '
              'tell revocation from a process that is coming back. Unbounded '
              'is the flood this file exists to end — the count is the '
              'assertion, not a timing window, because a slow CI box would '
              'make a window say either');
      expect(panel.supervisor.stopped, isTrue,
          reason: 'the second refusal is the one that carries a reason, and it '
              'must be the last');
    });
  });

  group('the arm beside it, and the fallthrough under it', () {
    test('a version refusal still stops the loop', () async {
      // The independence arm. Deleting the credential `if` must not touch
      // this: the two are additions beside each other, not one redirected.
      final gateway = await _Gateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _versionMismatch, 'no common protocol version');
        link.close(CloseCodes.protocolMismatch);
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 5, token: _credential);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel gave up on a protocol mismatch',
          budget: _recovery);
      await Future<void>.delayed(_quietWindow);

      expect(panel.supervisor.stopped, isTrue);
      expect(panel.supervisor.stopReason, contains('protocol'),
          reason: 'a version refusal and a credential refusal are different '
              'faults with different people to call; a stop reason that named '
              'the wrong one would be worse than none');
      expect(panel.dials.count, 1);
    });

    test('an ordinary refusal is retried like any other drop', () async {
      // The fallthrough arm. Everything that is not one of the two named codes
      // still reaches `_down` and still comes back — a gateway having a bad
      // minute during a restart is exactly what the backoff is for, and a
      // client that stopped on it would need a human to walk to the panel.
      final gateway = await _Gateway.start((link, method, id) {
        if (method != Methods.hello) return;
        link.error(id, _internalError, 'the gateway is having a bad minute');
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 6, token: _credential);

      final thirdDown = _afterNth(panel.log, LinkState.down, 3);
      panel.supervisor.start();
      await within(thirdDown, 'the panel kept dialling through three refusals',
          budget: _recovery);

      expect(panel.supervisor.stopped, isFalse,
          reason: 'an internal error is transient by definition. Reading every '
              'refusal as final would turn one bad minute during a gateway '
              'restart into a factory of dark screens waiting for somebody to '
              'power-cycle them one at a time');
      expect(panel.supervisor.debugScheduledWaits, isNotEmpty,
          reason: 'the schedule is still running, which is the observable '
              'difference between this arm and the two above it');
      expect(panel.dials.count, greaterThanOrEqualTo(3));
    });
  });

  group('what the panel puts on the wire', () {
    test('the panel presents its configured credential on the first frame',
        () async {
      final gateway = await _refusingGateway();
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'),
          seed: 7, token: _credential);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel completed one handshake attempt',
          budget: _recovery);

      expect(gateway.hellos, hasLength(1));
      expect(gateway.hellos.single['token'], _credential,
          reason: 'the config field and the wire field are joined by exactly '
              'one line in the supervisor. Without it every panel presents '
              'nothing, every panel is refused, and the fault looks like a '
              'broken token file rather than a credential that was never sent');
    });

    test('a panel with no credential sends a hello with no token key',
        () async {
      // The compatibility property, observed on the wire rather than inferred
      // from the DTO: every fixture in this workspace dials a gateway running
      // the permissive validator, and none of them may start sending a key
      // they did not send yesterday.
      final gateway = await _refusingGateway();
      final panel =
          _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'), seed: 8);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel completed one handshake attempt',
          budget: _recovery);

      expect(gateway.hellos, hasLength(1));
      expect(gateway.hellos.single.containsKey('token'), isFalse,
          reason: 'an unconfigured panel sends no credential at all, not an '
              'empty one. A gateway logging a blank token would record a '
              'station as having presented a credential it never had');
    });
  });
}
