/// The connection supervisor: four states, a fresh peer per socket, and a
/// backoff that only forgives a link which actually delivered a snapshot.
///
/// Source: 04-RESEARCH Finding 2, whose state table is the spec, and whose one
/// load-bearing line is CLI-02's testable property — **backoff resets on entry
/// to `ready`, not on entry to `resyncing`**. Finding 2 also carries the
/// measured caveat this file refuses to let the implementation forget: a
/// `killOnce` through the fault proxy reported `closeCode = 1002` with an empty
/// reason, so a yanked cable is indistinguishable-by-code from a protocol
/// error, and reconnect policy may not be read off the number.
///
/// What breaks in the plant without this file: the gateway is a single process
/// and every panel in the factory loses its socket in the same second when it
/// restarts. A supervisor that reset its backoff the moment a socket came up —
/// before any snapshot landed — would bring the whole factory back at the
/// attempt-0 window over and over against a gateway still replaying snapshots
/// for the previous wave. That is the thundering herd, and it is
/// self-sustaining: the synchronised retry is what keeps the gateway too busy
/// to finish, which is what keeps the retries synchronised.
///
/// **The bite.** `a server that closes before the snapshot does not earn a
/// reset` is the arm that fails an implementation which calls
/// `backoff.reset()` on entry to `resyncing`. Every happy-path reconnect case
/// in this file passes under that wrong implementation, which is exactly why
/// the flap arm exists and why it asserts a *band* rather than an instant: the
/// schedule is jittered, so the only honest claim is about the window a draw
/// came from, and a seeded `Random` is what makes that claim deterministic.
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
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:web_socket_channel/io.dart';

import 'support/permissive_resolver.dart';
import 'support/runner_budget.dart';

/// A health key `FakeStateMan` seeds at construction, so a subscribe against a
/// real gateway answers with a real snapshot and no plant has to be simulated.
const String _seededKey = 'PIPE.connected';

/// The attempt-0 backoff window every case in this file is configured with.
///
/// Small enough that ten kill cycles cost about a second, large enough that a
/// draw from it is distinguishable from a draw from the fourth window
/// (`16 x base`) on a wall clock that only promises milliseconds.
const Duration _base = Duration(milliseconds: 40);

/// The ceiling. Far below the production 30 s, because a case that waited the
/// production ceiling out would be a case nobody runs.
const Duration _cap = Duration(seconds: 2);

/// The budget for "the panel came back", named once and used everywhere.
///
/// Generous against the 50–100 ms tick-quantised round trip this transport
/// carries (04-RESEARCH Finding 8) plus a capped backoff draw: this is a
/// liveness budget, not a latency measurement.
const Duration _recovery = Duration(seconds: 5);

/// The client's timing knobs, with the deadline floor lowered deliberately.
///
/// Lowering it is explicit and greppable for the reason `client_config.dart`
/// gives: nobody lowers it in production by accident. Here it buys a control
/// deadline short enough that a gateway which accepts a socket and then says
/// nothing fails the pass inside a case's own budget instead of stalling it.
ClientConfig _config() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 400),
      writeDeadline: const Duration(milliseconds: 400),
      freshnessDeadline: const Duration(seconds: 3),
      backoffBase: _base,
      backoffCap: _cap,
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// Records every state the supervisor announced, in order, and lets a case
/// await a particular one.
///
/// Attached **before** the supervisor is started, which is the ordering trap
/// `ws_fault_test.dart:118-121` names from the other end: the session can be
/// registered in the same event-loop turn the connect completes in, so a
/// listener attached afterwards waits for a transition that already happened.
final class _StateLog {
  _StateLog(Stream<LinkState> states) {
    _sub = states.listen((state) {
      seen.add(state);
      final waiter = _waiting.remove(state);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    });
  }

  final List<LinkState> seen = <LinkState>[];
  final Map<LinkState, Completer<void>> _waiting = <LinkState, Completer<void>>{};
  late final StreamSubscription<LinkState> _sub;

  /// Completes the next time [state] is entered. Registered before the action
  /// that provokes it, never after.
  Future<void> next(LinkState state) =>
      _waiting.putIfAbsent(state, Completer<void>.new).future;

  /// How many times [state] has been entered so far.
  int count(LinkState state) => seen.where((s) => s == state).length;

  Future<void> cancel() => _sub.cancel();
}

/// Everything one case needs to drive a supervisor, built and torn down
/// together.
final class _Panel {
  _Panel(this.supervisor, this.log, this.subscriptions, this.stores);

  final ConnectionSupervisor supervisor;
  final _StateLog log;
  final Map<String, SubscriptionState> subscriptions;
  final Map<String, ValueStore> stores;
}

/// Builds a supervisor pointed at [uri] with one subscription registered.
///
/// One subscription rather than none on purpose: with an empty registry the
/// resubscribe pass has nothing to do and `resyncing` completes without a
/// single call reaching the wire — which would make the flap arm vacuous.
_Panel _panel(
  Uri uri, {
  required int seed,
  Set<String> keys = const {_seededKey},
  String sub = 's1',
}) {
  final subscriptions = <String, SubscriptionState>{
    sub: SubscriptionState(subId: sub, keys: {...keys}),
  };
  final stores = <String, ValueStore>{};
  final supervisor = ConnectionSupervisor(
    uri: uri,
    config: _config(),
    // Seeded, so a band assertion is a claim about this schedule and not a
    // coin flip that fails one CI run in twenty.
    backoff: Backoff(base: _base, cap: _cap, random: Random(seed)),
    barrier: ReadinessBarrier(),
    watchdog: FreshnessWatchdog(config: _config(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (id) => stores.putIfAbsent(id, ValueStore.new),
  );
  // Attached before `start()` — see `_StateLog`'s doc for why the order is the
  // property and not a style choice.
  final log = _StateLog(supervisor.states);
  addTearDown(log.cancel);
  addTearDown(supervisor.dispose);
  return _Panel(supervisor, log, subscriptions, stores);
}

/// Starts a real gateway on an ephemeral port, optionally behind a fault proxy.
///
/// The server package's own `relayFixture` is not reachable from here — it
/// lives in that package's `test/` tree, which no `package:` URI addresses —
/// so this is the same wiring, minus the client the fixture builds for itself.
Future<({RelayServer server, FaultProxy? proxy, Uri uri})> _gateway({
  bool withProxy = false,
}) async {
  final served = FakeStateMan();
  final server = RelayServer(
    resolver: const PermissiveSeriesResolver(),
    api: served,
    config: ServerConfig(tick: ServerConfig.minTick),
    // Several arms here provoke errors on purpose; a suite that printed a
    // stack per provoked error trains everyone to scroll past them.
    onError: (_, __, ___) {},
  );
  await server.start();
  addTearDown(server.close);
  addTearDown(served.dispose);

  FaultProxy? proxy;
  if (withProxy) {
    proxy = FaultProxy(targetPort: server.port);
    await proxy.start();
    addTearDown(proxy.shutdown);
  }
  final port = proxy?.port ?? server.port;
  return (
    server: server,
    proxy: proxy,
    uri: Uri.parse('ws://127.0.0.1:$port'),
  );
}

/// How a scripted gateway answers one request, and what it does to the socket
/// afterwards.
typedef _Script = void Function(_FakeLink link, String method, int id);

/// A hand-rolled gateway that answers JSON-RPC by script.
///
/// The real server cannot be made to close a socket *during* a resubscribe on
/// demand, and that is precisely the flap the backoff property is about — so
/// the flap, the 4005 refusal and the 4002 eviction are driven by this instead
/// of by a fault mode. It speaks only what those three arms need.
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
  final List<_FakeLink> links = <_FakeLink>[];

  int get port => _http.port;

  /// How many sockets this gateway has accepted — the client's attempt count
  /// seen from the far end.
  int get accepted => links.length;

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      final link = _FakeLink(socket);
      links.add(link);
      socket.listen(
        (Object? data) {
          final frame = jsonDecode('$data');
          if (frame is! Map) return;
          final id = frame['id'];
          final method = frame['method'];
          if (id is! int || method is! String) return;
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

/// One accepted socket on a [_FakeGateway], with the two replies the scripts
/// need and a close that carries a code.
final class _FakeLink {
  _FakeLink(this.socket);

  final WebSocket socket;

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

  void close(int code) =>
      unawaited(socket.close(code).catchError((Object _) => null));

  void _send(Object? frame) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }
}

void main() {
  useRunnerBudgets();

  group('the four states and the peer that belongs to each', () {
    test('a live gateway is reached through connecting and resyncing, in order',
        () async {
      final gateway = await _gateway();
      final panel = _panel(gateway.uri, seed: 1);

      final ready = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(ready, 'the panel reached ready against a live gateway',
          budget: _recovery);

      expect(
        panel.log.seen,
        [LinkState.connecting, LinkState.resyncing, LinkState.ready],
        reason: 'the operator-facing link indicator is driven off these '
            'transitions; a skipped resyncing means the screen claims the '
            'values are trustworthy while the snapshot is still in flight',
      );
      expect(panel.supervisor.barrier.isOpen, isTrue,
          reason: 'every call that touches the wire waits on this barrier, so '
              'a panel that reached ready with it shut is a page that hangs '
              'while the link underneath it is perfectly healthy');
      expect(panel.stores[panel.subscriptions.keys.first]?.peek(_seededKey),
          isNotNull,
          reason: 'ready is defined as every subscription holding its '
              'snapshot; without a cached value this case would pass on a '
              'supervisor that reached ready having subscribed to nothing');
    }, tags: 'ws');

    test('each connection gets a fresh peer, and the old one is closed with it',
        () async {
      final gateway = await _gateway(withProxy: true);
      final panel = _panel(gateway.uri, seed: 2);

      final first = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(first, 'the panel reached ready the first time',
          budget: _recovery);
      final peerOne = panel.supervisor.peer;
      expect(peerOne, isNotNull);

      final second = panel.log.next(LinkState.ready);
      gateway.proxy!.killOnce();
      await within(second, 'the panel reached ready again after the link was '
          'yanked', budget: _recovery);
      final peerTwo = panel.supervisor.peer;

      expect(identical(peerOne, peerTwo), isFalse,
          reason: 'a reused peer carries the previous socket\'s pending '
              'requests and handlers into the new connection, which is how a '
              'reply to the dead session lands on the live one');
      expect(peerOne!.isClosed, isTrue,
          reason: 'the notification handlers registered on the first peer go '
              'away with it; a peer left open is a listener still attached to '
              'a socket nobody reads, which is the leak class that reports '
              'itself against whichever case runs next');
    }, tags: 'ws');

    test('ten kill cycles leave one watchdog timer and no backoff timer',
        () async {
      final gateway = await _gateway(withProxy: true);
      final panel = _panel(gateway.uri, seed: 3);

      final first = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(first, 'the panel reached ready before the leak cycles',
          budget: _recovery);

      for (var cycle = 0; cycle < 10; cycle++) {
        final back = panel.log.next(LinkState.ready);
        gateway.proxy!.killOnce();
        await within(back, 'the panel reached ready again on cycle $cycle',
            budget: _recovery);
        expect(panel.supervisor.debugTimerCount, lessThanOrEqualTo(2),
            reason: 'a panel that flaps all shift accumulates one orphaned '
                'timer per cycle, and the one that is missed fires into a '
                'connection that no longer exists (cycle $cycle)');
      }

      expect(panel.log.count(LinkState.ready), 11,
          reason: 'the leak assertion below is vacuous unless every cycle '
              'really tore a link down and built a new one');
      expect(panel.supervisor.debugTimerCount, 1,
          reason: 'at rest on a healthy link the only timer the client owns '
              'is the freshness watchdog; a second one is a reconnect still '
              'scheduled against a connection that is already up');
    }, tags: 'ws');
  });

  group('the retry policy, and what it refuses to read', () {
    test('a dead port cycles connecting and down without throwing out of start',
        () async {
      // A port nothing is listening on, obtained by binding and releasing:
      // a hard-coded number is a collision with whatever else the CI box runs.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      final panel = _panel(Uri.parse('ws://127.0.0.1:$deadPort'), seed: 4);

      final thirdDown = _afterNth(panel.log, LinkState.down, 3);
      // Deliberately not awaited and deliberately not guarded: a start() that
      // threw on a gateway which is not up yet would leave the screen grey
      // until somebody drove to the factory.
      panel.supervisor.start();
      await within(thirdDown, 'three failed attempts against a dead port',
          budget: _recovery);

      expect(panel.log.seen.take(4),
          [LinkState.connecting, LinkState.down, LinkState.connecting,
            LinkState.down],
          reason: 'a panel at power-on dials before the gateway is up; the '
              'normal shape of that is an alternating cycle, not an error');
      expect(panel.supervisor.stopped, isFalse,
          reason: 'a refused connection is the ordinary state of a panel '
              'booting with the rest of the line, and a loop that gave up on '
              'it never recovers on its own');
      expect(panel.supervisor.debugScheduledWaits.every((w) => w <= _cap), isTrue,
          reason: 'past the cap the operator standing in front of a blank '
              'panel has already reached for the power switch, and the '
              'automatic recovery never runs');
    });

    test('a killed link reports a code no policy may read', () async {
      final gateway = await _gateway(withProxy: true);
      // Observed on a raw socket rather than through the supervisor, because
      // the supervisor deliberately has no way to report one: Finding 2's
      // caveat is that the code here is a yanked cable, and the same code is
      // also what a protocol error looks like.
      final raw = IOWebSocketChannel.connect(gateway.uri);
      addTearDown(() => raw.sink.close().catchError((Object _) => null));
      await within(raw.ready, 'the observation socket connected',
          budget: _recovery);
      final done = raw.stream.drain<void>().catchError((Object _) {});

      gateway.proxy!.killOnce();
      await within(done, 'the observation socket saw its link yanked',
          budget: _recovery);

      // Finding 2 measured 1002 here on POSIX; the Windows stack reports 1006
      // for the same yanked cable, which is if anything the more accurate of
      // the two. Pinning either number tests the platform rather than the
      // property, and the property is the one that constrains the supervisor:
      // whatever a cut cable reports, it lands in the range the protocol
      // reserves for itself, so it is indistinguishable by number from a
      // protocol fault and no policy may branch on it.
      final code = raw.closeCode;
      expect(code, isNotNull,
          reason: 'the yanked link produced no close code at all, so the '
              'claim below is about nothing — and Finding 2\'s caveat, that '
              'the supervisor cannot tell these apart, would be resting on an '
              'observation this test never made');
      // 4000 is the floor of the range this protocol mints in — every member
      // of CloseCodes is 4001 or above, and dart-lang/http#1690 is why nothing
      // below it may be minted by us.
      expect(code, lessThan(4000),
          reason: 'a yanked cable came back as $code, inside the application '
              'range this protocol mints its own codes in. If a cut cable can '
              'produce an application code then the numbers are no longer '
              'disjoint and something upstream is inventing one');
      expect(code, isNot(CloseCodes.serverDraining),
          reason: 'a cut cable is reporting the gateway\'s own draining code, '
              'which is the exact confusion an implementation that retried by '
              'number would act on');
    }, tags: 'faults');

    test('an eviction the client never inspects is retried like any other drop',
        () async {
      // 4002 is server-draining — advisory, and the client's answer to it is
      // the same as its answer to a cut cable: come back.
      var evicted = false;
      final gateway = await _FakeGateway.start((link, method, id) {
        if (method == Methods.hello) {
          link.hello(id);
          return;
        }
        if (method == Methods.subscribe) {
          link.snapshot(id, 's1');
          if (!evicted) {
            evicted = true;
            link.close(CloseCodes.serverDraining);
          }
        }
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'), seed: 5);

      final first = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(first, 'the panel reached ready before the eviction',
          budget: _recovery);

      final second = panel.log.next(LinkState.ready);
      await within(second, 'the panel came back after a 4002 eviction',
          budget: _recovery);

      expect(gateway.accepted, greaterThanOrEqualTo(2),
          reason: 'the gateway must have been dialled again; a client that '
              'read 4002 as "stop" would leave the panel dark for the whole '
              'of a rolling gateway upgrade');
      expect(panel.supervisor.stopped, isFalse,
          reason: 'draining is advisory — the gateway is coming back, and so '
              'must the panel');
    });

    test('a refused handshake stops the loop, and counts as one attempt',
        () async {
      final gateway = await _FakeGateway.start((link, method, id) {
        if (method == Methods.hello) {
          // Both signals Finding 2 measured, in the order the real gateway
          // produces them: the pending hello rejects with -32004 and the
          // socket then closes 4005.
          link.error(id, -32004, 'no common protocol version');
          link.close(CloseCodes.protocolMismatch);
        }
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'), seed: 6);

      final down = panel.log.next(LinkState.down);
      panel.supervisor.start();
      await within(down, 'the panel gave up on a protocol mismatch',
          budget: _recovery);
      // One turn is enough for a second attempt to have been scheduled and
      // fired if the implementation treated the close as its own event. This
      // is scenario setup, not the assertion.
      await pumpEventQueue(times: 4);

      expect(panel.supervisor.stopped, isTrue,
          reason: 'a build that cannot speak the gateway\'s protocol will not '
              'learn to; retrying forever is a panel hammering a gateway it '
              'can never talk to, and an integrator with no error to read');
      expect(gateway.accepted, 1,
          reason: 'the rejected hello and the 4005 close are one event; '
              'counting them as two is a second dial nobody asked for and a '
              'stop reason that describes the wrong signal');
      expect(panel.supervisor.stopReason, contains('protocol'),
          reason: 'the integrator reads this line; "connection failed" sends '
              'them to the network when the fault is a version pin');
    });
  });

  group('the line that a flap bites', () {
    test('a server that closes before the snapshot does not earn a reset',
        () async {
      // Accepts every socket, answers hello, and then cuts the link with the
      // subscribe still in flight — the gateway that is up but not yet able to
      // serve, which is exactly what a restarting gateway looks like to the
      // factory for the first few seconds.
      final gateway = await _FakeGateway.start((link, method, id) {
        if (method == Methods.hello) {
          link.hello(id);
          return;
        }
        if (method == Methods.subscribe) link.close(1002);
      });
      final panel = _panel(Uri.parse('ws://127.0.0.1:${gateway.port}'), seed: 7);

      final fifthDown = _afterNth(panel.log, LinkState.down, 5);
      panel.supervisor.start();
      await within(fifthDown, 'five flap cycles against a gateway that closes '
          'before the snapshot', budget: _recovery);

      expect(panel.log.count(LinkState.resyncing), greaterThanOrEqualTo(5),
          reason: 'the band assertion below is vacuous unless every cycle '
              'really got as far as resyncing — a socket that never came up '
              'would grow the backoff for a different reason');
      expect(panel.log.count(LinkState.ready), 0,
          reason: 'no snapshot ever landed, so the link was never usable, and '
              'a supervisor that announced ready here would put untrustworthy '
              'values on a mimic');

      final waits = panel.supervisor.debugScheduledWaits;
      final longest = waits.reduce((a, b) => a > b ? a : b);
      expect(longest, greaterThan(_base),
          reason: 'this is the herd. Every draw stays inside the attempt-0 '
              'window only if the schedule was reset on entry to resyncing — '
              'and a factory of panels drawing from one 40 ms window against a '
              'gateway that is still starting comes back in a synchronised '
              'wave, repeatedly, which is what keeps the gateway too busy to '
              'finish. Observed: $waits');
      expect(longest, lessThanOrEqualTo(_cap),
          reason: 'the growth is bounded; a panel that has backed off past the '
              'ceiling is a panel the operator power-cycles');
    });

    test('a link that did deliver a snapshot puts the schedule back to zero',
        () async {
      final gateway = await _gateway(withProxy: true);
      final panel = _panel(gateway.uri, seed: 8);

      final first = panel.log.next(LinkState.ready);
      panel.supervisor.start();
      await within(first, 'the panel reached ready before the kill cycles',
          budget: _recovery);

      for (var cycle = 0; cycle < 4; cycle++) {
        final back = panel.log.next(LinkState.ready);
        gateway.proxy!.killOnce();
        await within(back, 'the panel reached ready again on cycle $cycle',
            budget: _recovery);
      }

      final waits = panel.supervisor.debugScheduledWaits;
      expect(waits.length, greaterThanOrEqualTo(4),
          reason: 'four kills must have produced four scheduled retries, or '
              'the window assertion below is measuring nothing');
      expect(waits.every((w) => w < _base), isTrue,
          reason: 'each of these links delivered a snapshot, so each earned '
              'its reset — a schedule that kept growing across healthy '
              'reconnects would have a panel that flaps once an hour stalling '
              'for the full cap by the end of a shift. Observed: $waits');
    }, tags: 'ws');
  });
}

/// Completes once [state] has been entered [n] times in total.
///
/// Registered before the action that provokes the transitions, like every
/// other waiter here.
Future<void> _afterNth(_StateLog log, LinkState state, int n) async {
  while (log.count(state) < n) {
    await log.next(state);
  }
}
