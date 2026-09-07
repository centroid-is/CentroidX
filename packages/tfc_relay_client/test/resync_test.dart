/// The resync discipline: epoch global, sequence local, snapshot only.
///
/// Source: 04-RESEARCH Finding 3, which is flagged **designed, not fully
/// executed** — the primitives were verified live (Finding 7) but no multi-sub
/// flap run happened, and RESEARCH's assumption log carries it as A1 with
/// "a two-sub flap test in Wave 0 settles it". This file is that test.
///
/// The arm that settles it is `a gap on one page does not blank the other`.
/// The server makes the same argument from its own side —
/// `subscription_registry.dart:101-102`: a sequence counter shared between two
/// subscriptions "would make each one resync every time the other moved".
///
/// What breaks in the plant without it: a control room runs several panels off
/// one gateway. If a dropped frame on the packing-hall page blanked the
/// freezer page too, one lost UDP-sized hiccup would take every screen in the
/// factory to "not yet known" at once, and the resulting resubscribe storm is
/// self-sustaining. And an engine that resynced everything on any gap passes
/// every single-subscription case in this file — which is why the two-sub arm
/// carries an anti-vacuity check that the other page held values at all.
///
/// **The last two groups do use a socket, and they have to** (07-07). What
/// triggers a recovery is not only a verdict the engine reaches on its own:
/// since 07-07 a *tick* whose advertised sequence is ahead of the client's
/// starts one, and an update naming a handle nobody announced starts one too.
/// Both decisions live in `ConnectionSupervisor`'s notification handlers, and a
/// notification handler needs a `Peer`, which needs a channel. So those arms
/// script a gateway on loopback and count the subscribes it is asked for — the
/// same instrument `reconnect_test.dart`'s `_FakeGateway` is, aimed at a
/// different property: that one scripts *closes and refusals* to drive the
/// backoff, this one scripts *sequences* to drive the recovery.
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
import 'package:tfc_relay_client/src/resync_engine.dart';
import 'package:tfc_relay_client/src/subscription_state.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

/// A scripted stand-in for the deadline-wrapped `subscribe` call: it records
/// what was asked for and answers from a canned script. No socket, no server —
/// the sequence discipline is a pure state machine and is tested as one.
final class _ScriptedSubscribe {
  /// Sub names in call order, so "s2 issued no subscribe" is a readable fact.
  final calls = <String>[];

  /// sub → the snapshot each resubscribe answers with.
  final Map<String, Map<String, DynamicValue>> snapshots;

  /// sub → epoch each resubscribe answers with.
  final Map<String, String> epochs;

  /// Sub names whose next subscribe throws, standing in for a call that fails
  /// partway through re-establishing N subscriptions.
  final Set<String> failing;

  _ScriptedSubscribe({
    Map<String, Map<String, DynamicValue>>? snapshots,
    Map<String, String>? epochs,
    Set<String>? failing,
  })  : snapshots = snapshots ?? {},
        epochs = epochs ?? {},
        failing = failing ?? {};

  /// sub → the generation the *next* answer carries. Bumped on every call, as
  /// the gateway bumps it on every establish.
  final _generations = <String, int>{};

  /// The generation this script last handed out for [sub].
  int generationOf(String sub) => _generations[sub] ?? 0;

  /// Held open until [release] is called, for the concurrency arm.
  Completer<void>? gate;

  Future<DecodedSubscribeResult> call(String sub, Set<String> keys) async {
    calls.add(sub);
    final held = gate;
    if (held != null) await held.future;
    if (failing.contains(sub)) {
      throw StateError('subscribe($sub) refused');
    }
    final values = snapshots[sub] ?? const <String, DynamicValue>{};
    return DecodedSubscribeResult(
      sub: sub,
      epoch: epochs[sub] ?? 'E1',
      seq: 0,
      generation: _generations[sub] = generationOf(sub) + 1,
      handles: {
        for (final (index, key) in keys.indexed) index + 1: key,
      },
      values: values,
      meta: const {},
      rejected: const {},
      complaints: const [],
    );
  }
}

DynamicValue _v(Object? value) => DynamicValue(value: value);

/// The one key the socket-backed arms watch.
const String _pageKey = 'ST101.CN01.MOT01.setpoint';

/// The handle the gateway below assigns it.
const int _pageHandle = 1;

/// The subscription name those arms use.
const String _page = 'p';

/// The sequence the scripted snapshot answers with.
///
/// Four rather than zero on purpose: a comparison written against a constant,
/// or one that treated a fresh page as "nothing applied yet", would pass every
/// arm below if the baseline were zero.
const int _snapshotSeq = 4;

/// How long the socket-backed arms give the client to do something, and how
/// long they watch to be sure it did nothing more.
const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 300);

/// A gateway that answers `hello` and `subscribe` by script and pushes
/// whatever notification an arm asks it to.
///
/// It counts subscribes, which is the number all four arms below are about:
/// how many times the client asked for the page to be rebuilt. Nothing here
/// reaches into the client — not `_inFlight`, not `lastSeq` — because the
/// property is what the *gateway* was asked for, and that is a fact about the
/// wire.
final class _SequencedGateway {
  _SequencedGateway._(this._http);

  static Future<_SequencedGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _SequencedGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  WebSocket? _link;

  /// How many `subscribe` calls this gateway has answered.
  int subscribes = 0;

  /// Whether the next `subscribe` is refused. The lever that puts a page into
  /// the deliberately-unestablished state `ResyncEngine._unestablish` leaves.
  bool refuseSubscribe = false;

  /// The value the next snapshot carries, so an arm can prove a rebuild
  /// actually delivered something.
  Object? snapshotValue = 1200;

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
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': HelloResult(
                  protocol: protocolVersion,
                  server: const PeerInfo('sequenced-gateway', '0.0.1'),
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
              _send({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'sub': _page,
                  'epoch': 'E1',
                  'seq': _snapshotSeq,
                  'generation': ++generation,
                  'handles': {_pageKey: _pageHandle},
                  'snapshot': {
                    '$_pageHandle': WireValue.of(snapshotValue).toJson(),
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

/// Everything a socket-backed arm drives.
typedef _Panel = ({
  ConnectionSupervisor supervisor,
  Map<String, SubscriptionState> subscriptions,
  ValueStore store,
});

/// The client's knobs for those arms.
///
/// The freshness deadline is far longer than any of them run, deliberately: a
/// scripted gateway that only speaks when an arm tells it to is a silent link,
/// and a watchdog that tore it down mid-arm would reconnect, re-subscribe, and
/// add a subscribe nobody asked for to the count the arms are built on.
ClientConfig _socketConfig() => ClientConfig(
      controlDeadline: Duration(milliseconds: 600),
      writeDeadline: Duration(milliseconds: 600),
      freshnessDeadline: Duration(seconds: 30),
      backoffBase: Duration(milliseconds: 40),
      backoffCap: Duration(seconds: 2),
      deadlineFloor: Duration(milliseconds: 50),
    );

/// Builds a supervisor holding one page, pointed at [gateway], and starts it.
Future<_Panel> _connected(_SequencedGateway gateway) async {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: const {_pageKey}),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: _socketConfig(),
    backoff: Backoff(
        base: const Duration(milliseconds: 40),
        cap: const Duration(seconds: 2),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog: FreshnessWatchdog(
        config: _socketConfig(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  await _until('the page to be established',
      () => subscriptions[_page]!.lastSeq == _snapshotSeq);
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

void main() {
  late _ScriptedSubscribe script;
  late Map<String, ValueStore> stores;
  late Map<String, SubscriptionState> subs;
  late ResyncEngine engine;

  ValueStore storeFor(String sub) =>
      stores.putIfAbsent(sub, () {
        final store = ValueStore();
        addTearDown(store.dispose);
        return store;
      });

  setUp(() {
    script = _ScriptedSubscribe();
    stores = {};
    subs = {};
    engine = ResyncEngine(
      storeFor: storeFor,
      subscribe: script.call,
      subscriptions: subs,
    );
  });

  /// Registers a subscription and gives it a snapshot to come back with.
  SubscriptionState register(String sub, Map<String, Object?> snapshot) {
    final state = SubscriptionState(subId: sub, keys: snapshot.keys.toSet());
    subs[sub] = state;
    script.snapshots[sub] = {
      for (final entry in snapshot.entries) entry.key: _v(entry.value)
    };
    return state;
  }

  group('two subscriptions, one gaps', () {
    test('a gap on one page does not blank the other', () async {
      register('s1', {'PACK.rate': 10});
      register('s2', {'FREEZER.temp': -24});
      await engine.onHello('E1');
      script.calls.clear();

      // Anti-vacuity: the other page must actually be holding values, or
      // "unchanged" is a statement about an empty map.
      expect(storeFor('s2').keys.length, greaterThan(0),
          reason: 'if the freezer page never cached anything, the assertion '
              'below that it survived the packing-hall gap proves nothing');
      final before = storeFor('s2').peek('FREEZER.temp');
      expect(before?.value, -24);

      // s1 skips a sequence number.
      await engine.onUpdate('s1',
          seq: 7, epoch: 'E1', changes: {'PACK.rate': _v(11)});

      expect(script.calls, ['s1'],
          reason: 'a dropped frame on the packing-hall page is that page\'s '
              'problem; resubscribing the freezer page too is how one hiccup '
              'becomes a factory-wide resubscribe storm');
      expect(storeFor('s2').peek('FREEZER.temp')?.value, -24,
          reason: 'the freezer reading never went unknown, so the operator '
              'never saw it blank');
      expect(storeFor('s2').peek('FREEZER.temp'), before,
          reason: 'byte-identical, not merely re-fetched to the same number');
    });
  });

  group('sequence discipline', () {
    test('an in-sequence batch advances lastSeq and issues no subscribe',
        () async {
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();

      await engine.onUpdate('s1',
          seq: 1, epoch: 'E1', changes: {'PACK.rate': _v(11)});

      expect(s1.lastSeq, 1,
          reason: 'the chain has to count on, or the next frame reads as a '
              'gap and the page resyncs for nothing');
      expect(script.calls, isEmpty,
          reason: 'an intact stream costs no round trip');
      expect(storeFor('s1').peek('PACK.rate')?.value, 11);
    });

    test('a sequence gap resubscribes that subscription and keeps the values '
        'in hand', () async {
      register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();
      // What the resubscribe will answer with, so the snapshot is
      // distinguishable from the gapped frame's own values.
      script.snapshots['s1'] = {'PACK.rate': _v(12)};

      await engine.onUpdate('s1',
          seq: 9, epoch: 'E1', changes: {'PACK.rate': _v(11)});

      expect(script.calls, ['s1'],
          reason: 'recovery is a snapshot, never a delta replay');
      expect(storeFor('s1').peek('PACK.rate')?.value, 12,
          reason: 'the snapshot is the newest truth and lands last');
    });

    test('a replayed batch resyncs and leaves the cache unpolluted', () async {
      register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      await engine.onUpdate('s1',
          seq: 5, epoch: 'E1', changes: {'PACK.rate': _v(50)});
      script.calls.clear();
      // The resubscribe answers with what is already cached, so any change
      // below can only have come from the replayed frame.
      script.snapshots['s1'] = {'PACK.rate': _v(50)};

      await engine.onUpdate('s1',
          seq: 3, epoch: 'E1', changes: {'PACK.rate': _v(30)});

      expect(storeFor('s1').peek('PACK.rate')?.value, 50,
          reason: 'F18: a re-delivered batch is older than what is cached, '
              'and applying it puts a reading from two batches ago on the '
              'mimic under good quality');
      expect(script.calls, ['s1'],
          reason: 'a duplicate on the wire means the stream is not what the '
              'client thought it was, so it resyncs on it too');
    });

    test('an update naming an unknown subscription is dropped', () async {
      register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();

      await engine.onUpdate('ghost',
          seq: 1, epoch: 'E1', changes: {'PACK.rate': _v(99)});

      expect(script.calls, isEmpty,
          reason: 'a subscription the client never opened must never be '
              'auto-registered off an inbound frame');
      expect(storeFor('s1').peek('PACK.rate')?.value, 10,
          reason: 'and its values must not reach a page');
    });

    test('an old-epoch frame is dropped and does not advance seq', () async {
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();
      final seqBefore = s1.lastSeq;

      await engine.onUpdate('s1',
          seq: 4, epoch: 'E0', changes: {'PACK.rate': _v(99)});

      expect(s1.lastSeq, seqBefore,
          reason: 'a frame from a session that no longer exists must not '
              'move the chain, or the next live frame reads as a gap');
      expect(storeFor('s1').peek('PACK.rate')?.value, 10,
          reason: 'a value from the previous epoch applied late is the F18 '
              'stale-reading-under-good-quality failure');
      expect(script.calls, isEmpty,
          reason: 'dropped in silence: the epoch already changed, and the '
              'hello path is what heals that');
    });
  });

  // 04-REVIEW CR-04. The epoch cannot do this job: a server-announced resync
  // or a gap-triggered resubscribe rebuilds one subscription while the session
  // — and therefore the epoch — stays exactly where it was. The frame in
  // flight across that boundary is the one that poisons the cache, and it is
  // 04-11's measured F18 deviation.
  group('generation', () {
    test('a frame from the establishment before a resubscribe is dropped',
        () async {
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      final stale = script.generationOf('s1');

      // The page is rebuilt on the same socket. Nothing about the session
      // changed; only this subscription did.
      await engine.onResync('s1');
      final live = script.generationOf('s1');
      expect(live, greaterThan(stale));
      final seqBefore = s1.lastSeq;

      await engine.onUpdate('s1',
          seq: 1, generation: stale, changes: {'PACK.rate': _v(99)});

      expect(storeFor('s1').peek('PACK.rate')?.value, 10,
          reason: 'the frame belongs to a subscription that no longer exists; '
              'applied, it is a reading from before the rebuild sitting on a '
              'mimic under good quality');
      expect(s1.lastSeq, seqBefore,
          reason: 'not advancing the sequence is the half that stops the '
              'poisoning — a stale frame that takes the baseline makes the '
              'genuine frame at the same seq read as a replay, and the store '
              'discards it');
    });

    test('the genuine frame at that sequence is still applied afterwards',
        () async {
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      final stale = script.generationOf('s1');
      await engine.onResync('s1');
      final live = script.generationOf('s1');

      await engine.onUpdate('s1',
          seq: 1, generation: stale, changes: {'PACK.rate': _v(99)});
      await engine.onUpdate('s1',
          seq: 1, generation: live, changes: {'PACK.rate': _v(42)});

      expect(storeFor('s1').peek('PACK.rate')?.value, 42,
          reason: 'this is the value the plant actually has. The whole cost of '
              'letting the stale frame through is that this one is then '
              'thrown away as a duplicate and never seen again');
      expect(s1.lastSeq, 1);
    });

    test('a frame carrying the current generation is applied', () async {
      // Anti-vacuity: a guard that dropped everything would pass both arms
      // above.
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');

      await engine.onUpdate('s1',
          seq: 1,
          generation: script.generationOf('s1'),
          changes: {'PACK.rate': _v(11)});

      expect(storeFor('s1').peek('PACK.rate')?.value, 11);
      expect(s1.lastSeq, 1);
    });
  });

  // 04-REVIEW WR-04 and CR-03's client half.
  group('recovery that cannot complete', () {
    test('two gaps on one subscription cost one subscribe', () async {
      register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();
      script.gate = Completer<void>();

      // Two frames, both gaps, neither awaited: `onUpdate` from the
      // notification handler, `onResync` from a server announcement.
      final first =
          engine.onUpdate('s1', seq: 9, changes: {'PACK.rate': _v(11)});
      final second = engine.onResync('s1');
      await pumpEventQueue();

      expect(script.calls, ['s1'],
          reason: 'two re-establishes racing interleave store.clear(), adopt '
              'and applyBatch — blanking a snapshot that has just been '
              'applied and leaving lastSeq describing a generation that is '
              'already gone');

      script.gate!.complete();
      await Future.wait([first, second]);
    });

    test('a refused recovery is recorded and leaves the page unestablished',
        () async {
      final s1 = register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.failing.add('s1');

      // From a notification handler, where a throw unwinds into json_rpc_2 on
      // a message that has no reply and is dropped in silence.
      await engine.onUpdate('s1', seq: 9, changes: {'PACK.rate': _v(11)});

      expect(engine.complaints, isNotEmpty,
          reason: 'a recovery that cannot complete is the one thing the '
              'operator needs told, and it was reaching nobody at all');
      expect(s1.lastSeq, isNull,
          reason: 'a surviving baseline makes the next frame another gap, '
              'which asks again, for as long as the socket lives');
      expect(s1.generation, 0);
      expect(storeFor('s1').peek('PACK.rate'), isNull,
          reason: 'values from a page the client can no longer establish must '
              'not stay on screen under good quality');
    });
  });

  group('epoch', () {
    test('an epoch change at hello discards every cache and every handle map',
        () async {
      final s1 = register('s1', {'PACK.rate': 10});
      final s2 = register('s2', {'FREEZER.temp': -24});
      await engine.onHello('E1');
      expect(storeFor('s1').peek('PACK.rate')?.value, 10);
      expect(s1.handles, isNotEmpty);

      // The gateway restarted: new server-side subscription state, new epoch.
      script.snapshots['s1'] = {'PACK.rate': _v(77)};
      script.snapshots['s2'] = {};
      script.epochs['s1'] = 'E2';
      script.epochs['s2'] = 'E2';
      script.calls.clear();
      await engine.onHello('E2');

      expect(storeFor('s2').peek('FREEZER.temp'), isNull,
          reason: 'the new epoch did not re-send this tag, and a number left '
              'on screen from the previous session is exactly the lie this '
              'product exists to prevent');
      expect(storeFor('s1').peek('PACK.rate')?.value, 77,
          reason: 'what the new session did send replaces what was there');
      expect(s2.handles, isNotEmpty,
          reason: 'handles are re-minted per epoch; the old map is dropped '
              'and the fresh one adopted');
      expect(script.calls.toSet(), {'s1', 's2'},
          reason: 'an epoch change is global — every subscription comes back');
    });

    test('the same epoch at hello keeps the caches and still resubscribes',
        () async {
      register('s1', {'PACK.rate': 10});
      await engine.onHello('E1');
      script.calls.clear();
      script.snapshots['s1'] = {'PACK.rate': _v(10)};

      await engine.onHello('E1');

      expect(script.calls, ['s1'],
          reason: 'a reconnect always re-establishes the subscription, '
              'because the socket is new even when the session survived');
      expect(storeFor('s1').peek('PACK.rate')?.value, 10);
    });
  });

  group('server-announced resync', () {
    test('resubscribes the named subscription only', () async {
      register('s1', {'PACK.rate': 10});
      register('s2', {'FREEZER.temp': -24});
      await engine.onHello('E1');
      script.calls.clear();

      await engine.onResync('s2');

      expect(script.calls, ['s2'],
          reason: 'the server named one subscription; touching the other is '
              'the same factory-wide storm by another route');
    });

    test('a resync for an unknown subscription is dropped', () async {
      await engine.onHello('E1');
      script.calls.clear();

      await engine.onResync('ghost');

      expect(script.calls, isEmpty);
    });
  });

  group('rollback', () {
    test('a resubscribe that throws partway leaves no half-registered '
        'subscription', () async {
      register('s1', {'PACK.rate': 10});
      register('s2', {'FREEZER.temp': -24});
      script.failing.add('s2');

      await expectLater(engine.onHello('E1'), throwsA(isA<StateError>()),
          reason: 'the failure must surface to the supervisor, which is what '
              'schedules the next attempt');

      expect(subs['s1']!.handles, isEmpty,
          reason: 'the server-side rollback argument, client side: a '
              'subscription established in a pass that failed is a page the '
              'client believes is live and the server may not be feeding');
      expect(subs['s1']!.lastSeq, isNull,
          reason: 'a surviving baseline would turn the next attempt\'s first '
              'frame into a false gap');
      expect(storeFor('s1').peek('PACK.rate'), isNull,
          reason: 'and its values must not stay on screen as if fresh');
    });
  });

  // 07-07, G1 arm A. The gateway has written its current per-subscription
  // sequence into every tick since Phase 3 and the client threw it away; a `u`
  // lost on the way in was caught only by the *next* one's gap, and a quiet
  // plant sends no next one.
  group('the tick carries the gateway\'s sequence, and the client reads it',
      () {
    test('a tick advertising a sequence ahead of the client\'s costs exactly '
        'one resubscribe', () async {
      final gateway = await _SequencedGateway.start();
      final panel = await _connected(gateway);
      expect(gateway.subscribes, 1,
          reason: 'the page was established by more than one subscribe, so '
              'the count below starts from a number this arm did not set');

      // The gateway has pushed frames this client never received — which is
      // what a locally dropped `u` looks like from the far end. The snapshot
      // the recovery brings carries a different value, so "it resubscribed"
      // and "it got the current reading" are two assertions and not one.
      gateway.snapshotValue = 1300;
      gateway.tick(_snapshotSeq + 1);

      await _until('the recovery the tick asked for',
          () => gateway.subscribes == 2);
      // Spent on purpose: a client that resynced once per tick would answer
      // the next number here, and an absence is only worth the window it was
      // watched over.
      await Future<void>.delayed(_settle);

      expect(gateway.subscribes, 2,
          reason: 'one tick advertising one lost push cost '
              '${gateway.subscribes - 1} resubscribes. The recovery goes '
              'through onResync so the engine\'s in-flight coalescing applies; '
              'one per tick is the rebuild storm this detector must not be');
      expect(panel.store.peek(_pageKey)?.value, 1300,
          reason: 'the page resubscribed and did not end up holding the '
              'snapshot it was answered with, so the recovery healed nothing');
      expect(panel.subscriptions[_page]!.lastSeq, _snapshotSeq,
          reason: 'the baseline was not taken from the new snapshot, so the '
              'next genuine frame reads as a gap and asks again');
    });

    test('a gateway whose advertised sequence never comes down is damped, and '
        'said out loud', () async {
      // **07-REVIEW WR-02.** `ResyncEngine._resubscribe`'s `_inFlight` map
      // coalesces resyncs that *overlap*; it does not coalesce sequential
      // ones. Any condition in which the gateway's advertised sequence stays
      // ahead of what its own `subscribe` answer returns — a seq-bookkeeping
      // bug, a misbehaving or hostile peer — is one full-page resubscribe per
      // tick, indefinitely, at 10 Hz, against the one process serving every
      // screen in the plant. That is the F9/G3 resync-storm hazard reached
      // through this detector.
      //
      // And it was invisible: the unannounced-handle branch beside it appends
      // to `complaints`, this one appended nothing, so the client's only
      // diagnostic surface stayed empty while the panel rebuilt itself twenty
      // times a second.
      final gateway = await _SequencedGateway.start();
      final panel = await _connected(gateway);

      // The gateway's `subscribe` answers `_snapshotSeq` for ever, so the
      // rebuild never catches the number the tick advertises. Twenty ticks at
      // the measured fan-out cadence.
      for (var i = 0; i < 20; i++) {
        gateway.tick(_snapshotSeq + 5);
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await Future<void>.delayed(_settle);

      expect(gateway.subscribes, lessThan(4),
          reason: 'twenty divergent ticks cost ${gateway.subscribes - 1} full '
              'page rebuilds. A gateway that disagrees with itself must cost '
              'this client a bounded number of rebuilds, not one per tick for '
              'as long as the disagreement lasts');

      final damping = panel.supervisor.resync.complaints
          .where((line) => line.contains('sequence'))
          .toList();
      expect(damping, hasLength(1),
          reason: 'the client recorded $damping about a page it rebuilt and '
              'then declined to keep rebuilding. Exactly one: silence sends '
              'whoever is debugging this to the wrong end of the link, and a '
              'line per suppressed tick is the unbounded list WR-07 is about');
      expect(damping.single, contains('${_snapshotSeq + 5}'),
          reason: 'the complaint has to carry the sequence the gateway '
              'advertises, or it names a disagreement without saying what the '
              'disagreement is');
    });

    test('a tick advertising the sequence the client has applied costs none',
        () async {
      final gateway = await _SequencedGateway.start();
      await _connected(gateway);

      // Five of them, and one behind for good measure: the comparison is
      // "ahead of", not "different from". A tick *behind* the client is a
      // gateway that rewound — a different bug, which resyncing would mask —
      // and it is also what a same-socket re-establish looks like in the
      // window before this client adopts the replacement snapshot.
      for (var i = 0; i < 5; i++) {
        gateway.tick(_snapshotSeq);
      }
      gateway.tick(_snapshotSeq - 1);
      await Future<void>.delayed(_settle);

      expect(gateway.subscribes, 1,
          reason: 'six ticks on a healthy link cost '
              '${gateway.subscribes - 1} rebuilds. A detector that fires when '
              'the gateway and the client agree turns every idle panel into a '
              'resync per tick against the one process serving all of them');
    });
  });

  // 07-07, G1 arm B. The sequence is intact and the cache is not, which is why
  // the tick comparison above cannot see this one: the frame is in sequence,
  // the surviving changes are applied, and the number the tick advertises is
  // the number the client holds.
  group('an update naming a handle nobody announced', () {
    test('applies the rest of the batch, complains once, and resubscribes '
        'once', () async {
      final gateway = await _SequencedGateway.start();
      final panel = await _connected(gateway);

      // A recorder, not a reading: the recovery this arm asks for blanks the
      // cache and re-fills it from a snapshot, so a value applied before it
      // is gone by the time the arm could read it. 07-06's G4 lesson, and the
      // "the rest of the batch is still applied" clause needs it.
      final applied = <Object?>[];
      final node = panel.store.node(_pageKey);
      void record() => applied.add(node.cached?.value);
      node.addListener(record);
      addTearDown(() => node.removeListener(record));

      // What the rebuild will deliver, distinct from both the baseline and the
      // legitimate change, so the three states are three numbers.
      gateway.snapshotValue = 2000;
      gateway.update(_snapshotSeq + 1, {_pageHandle: 1300, 99: 'stranger'});

      await _until('the recovery the unannounced handle asked for',
          () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      expect(applied, contains(1300),
          reason: 'the batch named one handle this session announced and one '
              'it did not, and the announced one never reached the cache: '
              '$applied. Dropping the whole frame makes a partial frame worse '
              '— the store is the only thing that can judge the sequence');
      expect(panel.store.peek(_pageKey)?.value, 2000,
          reason: 'the page did not end up holding the snapshot the rebuild '
              'answered with, so the resync healed nothing');
      expect(
          panel.supervisor.resync.complaints
              .where((line) => line.contains('99'))
              .length,
          1,
          reason: 'the client recorded '
              '${panel.supervisor.resync.complaints} for one unannounced '
              'handle. The complaint is diagnostic and somebody reads it, so '
              'the resync is in addition to it and never instead of it');
      expect(gateway.subscribes, 2,
          reason: 'one batch naming one stranger cost '
              '${gateway.subscribes - 1} rebuilds');
    });

    test('costs nothing at all once the page has been left unestablished',
        () async {
      // **07-REVIEW WR-07.** `_recover` failing appends a complaint and calls
      // `_unestablish`, which deliberately leaves the subscription down — but
      // it does not unsubscribe server-side, so the gateway goes on pushing
      // `u` frames for the whole life of the socket. Every one of those frames
      // now has all its handles unknown, so the unannounced-handle branch
      // restarts the recovery that just failed, for ever, appending a
      // complaint per attempt to an unbounded list. Coalescing keeps it to one
      // attempt per control deadline rather than one per frame, so it is a
      // slow leak rather than a storm — and it is still a retry loop on a
      // class whose whole discipline is about not retrying.
      final gateway = await _SequencedGateway.start();
      final panel = await _connected(gateway);

      gateway.refuseSubscribe = true;
      gateway.update(_snapshotSeq + 1, {_pageHandle: 1300, 99: 'stranger'});

      await _until('the recovery the unannounced handle asked for, and its '
          'refusal', () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      final state = panel.subscriptions[_page]!;
      expect(state.lastSeq, isNull,
          reason: 'the refused recovery did not leave the page '
              'unestablished, so the rest of this case is about a different '
              'state than the one it names');

      // The gateway keeps pushing, because nothing told it to stop.
      for (var i = 2; i < 8; i++) {
        gateway.update(_snapshotSeq + i, {_pageHandle: 1300 + i, 99: 'again'});
        await Future<void>.delayed(_settle);
      }

      expect(gateway.subscribes, 2,
          reason: 'six further frames at a page this client has deliberately '
              'given up on cost ${gateway.subscribes - 2} more subscribe '
              'attempts. `lastSeq == null` is the exact "unestablished" signal '
              '`_tick`\'s loop already skips on, and the unannounced-handle '
              'branch beside it has to skip on the same one or a page that '
              'failed recovery retries it for as long as the socket lives');
      expect(panel.supervisor.resync.complaints.length, lessThan(4),
          reason: 'the complaint list grew to '
              '${panel.supervisor.resync.complaints.length} entries while the '
              'client was doing nothing but refusing to act. An unbounded '
              'List<String> filled by a loop is the leak, not just the '
              'symptom of it');
    });

    test('costs one resubscribe however many handles in it were strangers',
        () async {
      final gateway = await _SequencedGateway.start();
      final panel = await _connected(gateway);

      gateway.update(_snapshotSeq + 1, {
        _pageHandle: 1300,
        for (var handle = 90; handle < 95; handle++) handle: 'stranger',
      });

      await _until('the recovery the unannounced handles asked for',
          () => gateway.subscribes == 2);
      await Future<void>.delayed(_settle);

      expect(panel.supervisor.resync.complaints, hasLength(5),
          reason: 'five unannounced handles must still cost five complaints: '
              'the diagnostic is per key, because that is what tells an '
              'integrator which tag is misconfigured');
      expect(gateway.subscribes, 2,
          reason: 'five strangers in one batch cost '
              '${gateway.subscribes - 1} rebuilds. A resync is per '
              'subscription and one batch is one event, however many keys in '
              'it the client could not file');
    });
  });
}
