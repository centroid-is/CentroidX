/// A snapshot is not a ping, and a page this client gave up on has to have a
/// way back that does not require the socket to drop.
///
/// Source: 16-01, finding S1b, verified at source before a line was written.
/// `ConnectionSupervisor._subscribe` bounded a `subscribe` — whose answer is a
/// full ~1500-key, ~100 kB snapshot — with `config.controlDeadline`, the same
/// one second that bounds `hello`, a frame with five fields in it. The two
/// failures that falls out of are the two groups below, and the second is the
/// worse one.
///
/// **The asymmetry is the tell.** The identical timeout during `onHello` gets
/// infinite retries — `_resubscribeAll` rethrows, the supervisor calls `_down`,
/// the schedule brings it back. Mid-connection it gets *zero*: `_recover`
/// swallows the failure into a complaint, `_unestablish` sets `lastSeq = null`,
/// and every path that could rebuild the page is guarded on `lastSeq != null`
/// (`connection_supervisor.dart:714` for the update path, `:775-776` for the
/// tick path). The heartbeat then keeps a healthy socket open for days over a
/// blank page.
///
/// What breaks in the plant without this file: the panel by the filleting line
/// comes up on a congested morning and never leaves "connecting", because every
/// attempt abandons a snapshot that would have landed at three seconds and
/// pushes another partial one into the congestion that caused it. Or worse, it
/// comes up fine, drops one page at 09:10, and shows that page blank until
/// somebody power-cycles it at the end of the shift — with the only explanation
/// in a complaint list no operator can see.
///
/// **Why the arms are socket-backed.** Both decisions live in
/// `ConnectionSupervisor` — one in the deadline it passes to `callWithDeadline`,
/// one in a notification handler — and a notification handler needs a `Peer`,
/// which needs a channel. `resync_test.dart` makes the same argument for the
/// same reason; this file's gateway is that one's sibling, aimed at *latency*
/// rather than at sequences.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tfc_relay_client/src/backoff.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/connection_supervisor.dart';
import 'package:tfc_relay_client/src/freshness_watchdog.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// The one key these arms watch.
const String _pageKey = 'ST101.CN01.MOT01.setpoint';

/// The handle the gateway below assigns it.
const int _pageHandle = 1;

/// The subscription name these arms use.
const String _page = 'p';

/// The sequence the scripted snapshot answers with.
///
/// Four rather than zero, for `resync_test.dart`'s reason: a comparison written
/// against a constant, or one that read a fresh page as "nothing applied yet",
/// would pass on a zero baseline whatever it actually did.
const int _snapshotSeq = 4;

/// How long an arm gives the client to do something.
const Duration _budget = Duration(seconds: 10);

/// How long an arm watches to be sure the client did nothing more.
const Duration _settle = Duration(milliseconds: 300);

/// A gateway that answers by script and can be told to take its time.
///
/// The lever this file exists for is [subscribeDelay]: a `subscribe` that is
/// answered correctly and *slowly*, which is what a ~100 kB snapshot on a
/// congested plant link is. It is deliberately not a refusal and not a dropped
/// socket — both of those are already covered, and neither is the failure this
/// file reproduces.
final class _SlowGateway {
  _SlowGateway._(this._http);

  static Future<_SlowGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _SlowGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many `hello` calls this gateway has answered — which is how many
  /// sockets the panel has established, which is how the arms below prove
  /// something happened *without* the link dropping.
  int hellos = 0;

  /// How many `subscribe` calls this gateway has been asked for.
  int subscribes = 0;

  /// How long the next `subscribe` answer is held back before it is sent.
  ///
  /// The answer is still sent — abandoning it here would make this a dropped
  /// call rather than a slow one, and the client is entitled to behave
  /// differently about those.
  Duration subscribeDelay = Duration.zero;

  /// Whether the next `subscribe` is refused outright. The lever that puts a
  /// page into the deliberately-unestablished state `_unestablish` leaves,
  /// without needing a clock.
  bool refuseSubscribe = false;

  /// The value the next snapshot carries, so an arm can prove a rebuild
  /// delivered something rather than merely happening.
  Object? snapshotValue = 1200;

  /// The sequence the next snapshot answers with.
  int snapshotSeq = _snapshotSeq;

  /// The generation the next snapshot carries. Bumped per answer, as the real
  /// registry mints one per establish.
  int generation = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
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
              hellos++;
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('slow-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              if (refuseSubscribe) {
                _send({
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': {'code': -32000, 'message': 'no'},
                });
                return;
              }
              final answer = {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': snapshotSeq,
                  'generation': ++generation,
                  'handles': {_pageKey: _pageHandle},
                  'snapshot': {
                    '$_pageHandle': WireValue.of(snapshotValue).toJson(),
                  },
                },
              };
              if (subscribeDelay == Duration.zero) {
                _send(answer);
              } else {
                // The socket this answer belongs to, captured now: by the time
                // the delay elapses the panel may have hung up and dialled
                // again, and writing the old answer down the new socket would
                // be this harness inventing a frame nothing sent.
                final owner = _link;
                Timer(subscribeDelay, () => _sendOn(owner, answer));
              }
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

  /// Announces a tick naming [seq] for the page.
  void tick(int seq) => _send({
        'jsonrpc': '2.0',
        'method': Methods.tick,
        'params': {
          'serverTime': DateTime.now().millisecondsSinceEpoch,
          'subs': {
            _page: {
              'seq': seq,
              'evaluatedAt': DateTime.now().millisecondsSinceEpoch,
            },
          },
        },
      });

  /// Pushes an update naming [handles] — handle to value — at [seq].
  void update(int seq, Map<int, Object?> handles) => _send({
        'jsonrpc': '2.0',
        'method': Methods.update,
        'params': {
          'sub': _page,
          'seq': seq,
          't': DateTime.now().millisecondsSinceEpoch,
          'g': generation,
          'c': {
            for (final entry in handles.entries)
              '${entry.key}': WireValue.of(entry.value).toJson(),
          },
        },
      });

  void _send(Object? frame) => _sendOn(_link, frame);

  void _sendOn(WebSocket? socket, Object? frame) {
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    await _link?.close().catchError((Object _) => null);
    await _http.close(force: true);
  }
}

/// Everything an arm drives.
typedef _Panel = ({
  ConnectionSupervisor supervisor,
  Map<String, SubscriptionState> subscriptions,
  ValueStore store,
});

/// Builds a supervisor holding one page, pointed at [gateway], and starts it.
///
/// [freshness] is per arm on purpose. An arm that leaves the link silent for a
/// second while a slow snapshot crosses it needs a deadline far longer than it
/// runs, or the watchdog tears the socket down mid-arm and the arm is measuring
/// a reconnect. An arm that drives the damper needs one short enough to expire
/// inside its own budget, and pays for it by ticking at 10 Hz so the watchdog
/// is fed while it does.
///
/// [establish] is false for the arms whose whole subject is a page that never
/// establishes; those cannot wait for a baseline that is the thing in question.
Future<_Panel> _panelOn(
  _SlowGateway gateway, {
  required Duration freshness,
  Duration control = const Duration(milliseconds: 200),
  Duration snapshot = const Duration(seconds: 15),
  bool establish = true,
}) async {
  final config = ClientConfig(
    controlDeadline: control,
    snapshotDeadline: snapshot,
    writeDeadline: const Duration(milliseconds: 600),
    freshnessDeadline: freshness,
    backoffBase: const Duration(milliseconds: 40),
    backoffCap: const Duration(milliseconds: 200),
    // Lowered deliberately and greppably, which is what this knob is for: every
    // arm here has to make a deadline fire inside a ten-second budget.
    deadlineFloor: const Duration(milliseconds: 50),
  );
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_pageKey}),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: config,
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(milliseconds: 200),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog:
        FreshnessWatchdog(config: config, onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  if (establish) {
    await _until('the page to be established',
        () => subscriptions[_page]!.lastSeq != null);
  }
  return (supervisor: supervisor, subscriptions: subscriptions, store: store);
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

/// Ticks [gateway] every 100 ms until the returned timer is cancelled.
///
/// A tick and not an update: the tick is the frame a quiet plant sends, so an
/// arm built on it is an arm about a panel watching a line that is not moving —
/// which is what every panel in the factory does all shift.
Timer _ticking(_SlowGateway gateway, int seq) {
  final timer =
      Timer.periodic(const Duration(milliseconds: 100), (_) => gateway.tick(seq));
  addTearDown(timer.cancel);
  return timer;
}

void main() {
  group('a snapshot that takes longer than a ping', () {
    test('lands, rather than locking the panel out of its own plant', () async {
      final gateway = await _SlowGateway.start();
      // Nine hundred milliseconds is the shape of the plant case, scaled: a
      // ~100 kB snapshot on a link that is carrying the rest of the line as
      // well. What matters is only that it is comfortably longer than the
      // deadline a ping-class call is given.
      const control = Duration(milliseconds: 200);
      const slow = Duration(milliseconds: 900);
      // Anti-vacuity, and it is not decoration: if a later edit lowers the
      // delay under the control deadline, every assertion below passes without
      // the client having changed at all.
      expect(slow, greaterThan(control),
          reason: 'the snapshot must take longer than a ping-class deadline or '
              'this arm is not about anything');
      gateway.subscribeDelay = slow;

      final panel = await _panelOn(gateway,
          // Far longer than this arm runs: the link is genuinely silent while
          // the snapshot is in flight, and a watchdog that fired would tear
          // down the socket and make this a reconnect case.
          freshness: const Duration(seconds: 30),
          control: control,
          establish: false);

      await _until('the panel to reach ready over a link that is merely slow',
          () => panel.supervisor.state == LinkState.ready);

      expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq,
          reason: 'the panel reported ready without holding the snapshot the '
              'gateway sent, so "ready" means something other than what '
              '`_enter(ready)` claims it means');
      expect(panel.store.peek(_pageKey)?.value, 1200,
          reason: 'the page reached ready with nothing in the cache, so the '
              'operator is looking at a screen that says it is live and is '
              'blank');
      expect(gateway.subscribes, 1,
          reason: 'a link that answers every frame correctly, only slowly, '
              'cost ${gateway.subscribes} subscribe attempts. Each abandoned '
              'snapshot is another ~100 kB pushed into the congestion that '
              'caused it, and `backoff.reset()` lives only in `_enter(ready)` '
              '— which this panel can never reach — so the loop is '
              'self-sustaining and caps at the backoff ceiling forever');
      expect(gateway.hellos, 1,
          reason: 'the panel redialled ${gateway.hellos - 1} times against a '
              'gateway that never once failed to answer');
    });
  });

  group('a page left unestablished on a healthy socket', () {
    test('is rebuilt from a tick, without waiting for the link to drop',
        () async {
      final gateway = await _SlowGateway.start();
      // Short, and affordable because this arm ticks at 10 Hz: the damper that
      // bounds the rebuild rate is `freshnessDeadline`, and an arm that cannot
      // outlive one damper window cannot observe a second attempt.
      final panel =
          await _panelOn(gateway, freshness: const Duration(seconds: 1));
      expect(gateway.subscribes, 1);

      // The page is dropped exactly the way `_recover` drops one: the rebuild
      // a divergent tick asks for is refused, so `_unestablish` runs and the
      // baseline goes to null. A refusal rather than a timeout here on
      // purpose — it isolates the closed door from the deadline that walked
      // the client through it, so this arm stays red for one reason only.
      gateway.refuseSubscribe = true;
      gateway.tick(_snapshotSeq + 5);
      await _until('the refused rebuild', () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      expect(panel.subscriptions[_page]!.lastSeq, isNull,
          reason: 'the refused rebuild did not leave the page unestablished, '
              'so the rest of this arm is about a different state than the one '
              'it names');

      // The condition clears. Nothing else about the link changes: the same
      // socket, the same session, the same gateway going on announcing this
      // page in every tick it sends — which is the gateway saying, ten times a
      // second, that the subscription exists at its end.
      gateway.refuseSubscribe = false;
      gateway.snapshotValue = 2000;
      gateway.snapshotSeq = _snapshotSeq + 10;
      _ticking(gateway, _snapshotSeq + 5);

      await _until('the page to find its own way back',
          () => panel.subscriptions[_page]!.lastSeq != null);

      expect(panel.store.peek(_pageKey)?.value, 2000,
          reason: 'the page came back holding something other than the '
              'snapshot the rebuild answered with, so whatever healed it did '
              'not heal it from the gateway');
      expect(gateway.hellos, 1,
          reason: 'the page only came back because the socket dropped and the '
              'panel redialled (${gateway.hellos} handshakes). The whole '
              'defect is that the heartbeat keeps a healthy socket open for '
              'days, so a recovery that needs a drop is a recovery that waits '
              'for the end of the shift');
    });

    test('comes back from the timeout that dropped it, not merely from a '
        'refusal', () async {
      // The arm above isolates the closed door by using a refusal. This one is
      // the plant sequence end to end, with the clock in it: a rebuild whose
      // snapshot is slower than the deadline, the page dropped for that reason
      // alone, and the congestion then clearing while the socket stays up.
      final gateway = await _SlowGateway.start();
      const snapshot = Duration(milliseconds: 300);
      const slow = Duration(milliseconds: 800);
      expect(slow, greaterThan(snapshot),
          reason: 'the rebuild has to outlast its own deadline or nothing '
              'below is about a timeout');

      final panel = await _panelOn(gateway,
          freshness: const Duration(seconds: 1), snapshot: snapshot);
      expect(gateway.subscribes, 1);

      // The congestion arrives. The gateway is not broken and never refuses:
      // it answers, correctly, too late.
      gateway.subscribeDelay = slow;
      gateway.tick(_snapshotSeq + 5);
      await _until('the rebuild the divergent tick asked for',
          () => gateway.subscribes == 2);
      await _until('that rebuild to be abandoned on its deadline',
          () => panel.subscriptions[_page]!.lastSeq == null);

      // The congestion clears. Nothing else changes — same socket, same
      // session, same gateway announcing the page in every tick.
      gateway.subscribeDelay = Duration.zero;
      gateway.snapshotValue = 3000;
      gateway.snapshotSeq = _snapshotSeq + 10;
      _ticking(gateway, _snapshotSeq + 5);

      await _until('the page to come back once the link is quick again',
          () => panel.subscriptions[_page]!.lastSeq != null);
      await Future<void>.delayed(_settle);

      expect(panel.store.peek(_pageKey)?.value, 3000,
          reason: 'the page is established again but is not holding the '
              'snapshot the successful rebuild answered with');
      expect(gateway.hellos, 1,
          reason: 'a transient snapshot timeout cost the panel '
              '${gateway.hellos - 1} redials. It must cost none: the socket '
              'was healthy throughout and the gateway never stopped speaking');
      expect(
          panel.supervisor.resync.complaints
              .where((line) => line.contains('holds null'))
              .toList(),
          isEmpty,
          reason: 'the client accused the gateway of a sequence mismatch '
              'against a baseline it did not have. A page with no sequence '
              'cannot disagree with one, and a complaint that says it does '
              'sends whoever reads it to the wrong end of the link');
    });

    test('is retried at a bounded rate when the gateway will never answer',
        () async {
      // **The other direction, and it is the direction that keeps the door
      // narrow.** `resync_test.dart`'s
      // `costs nothing at all once the page has been left unestablished`
      // protects the *update* path from exactly this: a page that cannot be
      // rebuilt, retried once per inbound frame, forever. Reopening the tick
      // path puts that hazard within reach again at 10 Hz, so the damper is
      // load-bearing and this arm is what fails without it.
      final gateway = await _SlowGateway.start();
      const freshness = Duration(seconds: 1);
      final panel = await _panelOn(gateway, freshness: freshness);
      expect(gateway.subscribes, 1);

      // Broken for good, and ticking all the while — the shape of a gateway
      // with a bug in its own subscription bookkeeping.
      gateway.refuseSubscribe = true;
      _ticking(gateway, _snapshotSeq + 5);

      const watched = Duration(milliseconds: 2500);
      await Future<void>.delayed(watched);

      // Twenty-five ticks went out over that window.
      const undamped = 25;
      final windows = watched.inMilliseconds / freshness.inMilliseconds;
      // **Two, not one, and the difference is the whole lower bound.** The
      // first tick arrives while the page is still established, so it takes
      // the *mismatch* branch and costs a rebuild — which is refused, which is
      // what leaves the page unestablished in the first place. A client that
      // then locked the door would sit at exactly two for the rest of the
      // window. Measured at four here against a bound of two, and the version
      // with the door shut was measured at two: a `greaterThan(1)` would have
      // passed on both and proved nothing, which is what it did on the first
      // pass of this matrix.
      expect(gateway.subscribes, greaterThan(2),
          reason: 'the client asked for ${gateway.subscribes} rebuilds across '
              '$undamped ticks at a page it has given up on. Two is the count '
              'a locked door produces — the establish, and the one refused '
              'rebuild that unestablished the page — so anything at or below '
              'it means no tick ever reopened anything');
      expect(gateway.subscribes, lessThan(8),
          reason: 'the client asked for ${gateway.subscribes} rebuilds across '
              '$undamped ticks. One per subscription per '
              '${freshness.inMilliseconds} ms allows about '
              '${windows.round()} across this window; one per tick is the '
              'F9/G3 resync storm, aimed at the one process serving every '
              'screen in the plant, and driven by a page nothing can fix');
      expect(panel.supervisor.resync.complaints.length, lessThan(8),
          reason: 'the complaint list grew to '
              '${panel.supervisor.resync.complaints.length} entries while the '
              'client was pacing itself. An unbounded List<String> filled by a '
              'loop is the leak, not just the symptom of it');
    });
  });

  group('the deadline a snapshot is given', () {
    test('is its own number, and a far larger one than a ping gets', () {
      final config = ClientConfig();

      expect(config.snapshotDeadline, const Duration(seconds: 15),
          reason: 'the plant\'s largest page is ~1500 keys and about 100 kB. '
              'A link metered at a tenth of a megabit — which is what '
              'slow_link_gate_test.dart holds the plant link to — needs eight '
              'seconds for that before the gateway has done anything wrong, '
              'and the gateway still has to assemble it behind whatever '
              'backlog is already committed to the socket');
      expect(config.snapshotDeadline, greaterThan(config.controlDeadline),
          reason: 'a snapshot is bounded no more generously than a hello, '
              'which is the whole of S1b: the panel abandons a page that was '
              'about to land, redials, and asks for it again — and '
              'backoff.reset() lives only in _enter(ready), which it can '
              'never reach');
    });

    test('is still refused below the floor, by name', () {
      expect(
        () => ClientConfig(snapshotDeadline: const Duration(milliseconds: 100)),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message.toString(),
          'message',
          allOf(contains('snapshotDeadline'), contains('100 ms')),
        )),
        reason: 'a new deadline that skipped the floor check would be the one '
            'number in this class that can be set under a measured round '
            'trip, and it is the number a whole page is bounded by',
      );
    });
  });
}
