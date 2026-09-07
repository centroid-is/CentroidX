@TestOn('vm')

/// One malformed snapshot entry must cost one tag — not the connection.
///
/// Source: WEBSOCKET-REVIEW-FINDINGS S7 (WSH-08). `decodeSubscribeResult`
/// promises in its own doc that everything narrower than "not a JSON object"
/// — *"an unmapped handle, a rejected key, a poison number"* — is recorded and
/// the call still succeeds. That promise held for every failure the existing
/// suite exercises and broke for three **shape-level** ones one entry deep:
///
///  1. a snapshot entry that is not a map (`"snapshot": {"5": 3}`) —
///     `_asJson` throws a [FormatException] out of the whole decode;
///  2. a `rejected` entry with no string `kind` — `KeyReject.fromJson`'s
///     `json['kind'] as String` throws a `TypeError`;
///  3. a source timestamp that is *finite but huge* (`1e17`) —
///     `WireValue.toDynamicValue` hands it to
///     `DateTime.fromMillisecondsSinceEpoch`, which refuses anything past
///     ±8.64e15. `isFinite` is not a range check.
///
/// **Why any of that is severe, and why arm 4 is the finding.** The decode is
/// reached from `ResyncEngine.onHello`, which every reconnect performs.
/// `_resubscribeAll` rolls the pass back and *rethrows* by design, so the
/// throw leaves the attempt through `connection_supervisor.dart`'s
/// `'the link died before the snapshot landed'` arm → backoff → redial → the
/// same poisoned snapshot, which no amount of waiting changes. A permanent
/// reconnect loop, from one bad entry, against the single process serving
/// every screen in the factory. Arms 1–3 are the mechanism; arm 4 is the
/// failure an operator would actually see.
///
/// **Arm 5 is the one that stops the fix from becoming a swallow.** A response
/// that is not decodable *at all* is a peer problem, not a data problem, and it
/// must still reach `_resubscribeAll`'s roll-back. Arms 1–4 are all "does not
/// throw", which a catch-everything collapse satisfies vacuously; arm 5 is the
/// only thing that tells isolation apart from deleting the error handling.
///
/// The scripted fakes below are copied from `resync_test.dart`
/// (`_ScriptedSubscribe` at :51, `_SequencedGateway` at :138) rather than
/// exported from it — with one deliberate change: the script here answers with
/// **raw wire JSON** and runs it through the real `decodeSubscribeResult`,
/// because the decode is the subject and a fake that hands back an
/// already-built `DecodedSubscribeResult` would test nothing.
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

/// A page the size of the ones in the plant. The finding's whole shape is
/// "1499 good keys held hostage by one", so the arms are written at that
/// scale rather than at two keys.
const int _keyCount = 1500;

/// The sequence the scripted snapshots answer with. Non-zero on purpose: a
/// baseline of zero reads the same as "nothing applied yet".
const int _snapshotSeq = 4;

/// The handle carrying the poison in the single-poison arms. Deep enough into
/// the map that "everything after it was lost" and "everything was lost" are
/// different observations.
const int _poisonedHandle = 700;

String _keyAt(int index) => 'ST101.TAG${index.toString().padLeft(4, '0')}';

/// The key the handle `h` is announced under by [_rawResult].
String _keyOfHandle(int handle) => _keyAt(handle - 1);

/// One `subscribe` result as it arrives on the wire, before any decoding.
///
/// [poison] replaces the entry at a handle with whatever a hostile or skewed
/// gateway sent instead; [rejected] is passed through verbatim so an arm can
/// hand over a `rejected` entry with no `kind`.
Map<String, Object?> _rawResult(
  String sub, {
  Map<int, Object?> poison = const {},
  Map<String, Object?> rejected = const {},
  int keys = _keyCount,
}) {
  final handles = <String, int>{};
  final snapshot = <String, Object?>{};
  for (var index = 0; index < keys; index++) {
    final handle = index + 1;
    handles[_keyAt(index)] = handle;
    snapshot['$handle'] =
        poison.containsKey(handle) ? poison[handle] : <String, Object?>{'v': index};
  }
  return {
    'sub': sub,
    'epoch': 'E1',
    'seq': _snapshotSeq,
    'generation': 1,
    'handles': handles,
    'snapshot': snapshot,
    if (rejected.isNotEmpty) 'rejected': rejected,
  };
}

/// The keys [_rawResult] announces, as a subscription would have asked for
/// them.
Set<String> _keySet([int keys = _keyCount]) =>
    {for (var index = 0; index < keys; index++) _keyAt(index)};

/// A scripted `subscribe` that answers with **raw wire JSON** and puts it
/// through the production decode.
///
/// After `resync_test.dart:51`, but that one answers with a finished
/// `DecodedSubscribeResult`; this one has to go through
/// `decodeSubscribeResult` because the decode is what is on trial.
final class _RawScriptedSubscribe {
  /// sub → the raw result that subscribe answers with.
  final Map<String, Object?> results = {};

  /// Sub names in call order.
  final calls = <String>[];

  Future<DecodedSubscribeResult> call(String sub, Set<String> keys) async {
    calls.add(sub);
    // Through jsonEncode/jsonDecode, because a hand-built Dart map is not the
    // same object graph a socket produces: `jsonDecode` yields
    // `Map<String, dynamic>` and `List<dynamic>`, and a decoder that only ever
    // sees literals can pass on a type the wire never hands it.
    return decodeSubscribeResult(jsonDecode(jsonEncode(results[sub])));
  }
}

void main() {
  late _RawScriptedSubscribe script;
  late Map<String, ValueStore> stores;
  late Map<String, SubscriptionState> subs;
  late ResyncEngine engine;

  ValueStore storeFor(String sub) => stores.putIfAbsent(sub, () {
        final store = ValueStore();
        addTearDown(store.dispose);
        return store;
      });

  setUp(() {
    script = _RawScriptedSubscribe();
    stores = {};
    subs = {};
    engine = ResyncEngine(
      storeFor: storeFor,
      subscribe: script.call,
      subscriptions: subs,
    );
  });

  /// Registers a page of [keys] keys under [sub].
  SubscriptionState register(String sub, {int keys = _keyCount}) =>
      subs[sub] = SubscriptionState(subId: sub, keys: _keySet(keys));

  group('one poisoned entry in a 1500-key snapshot', () {
    test('a snapshot entry that is not an object costs that entry only',
        () async {
      register('p');
      // A bare number where `{"v": …}` belongs. `_asJson` throws on it, and
      // today that throw leaves the whole decode.
      script.results['p'] = _rawResult('p', poison: {_poisonedHandle: 3});

      await engine.onHello('E1');

      final store = storeFor('p');
      expect(subs['p']!.lastSeq, _snapshotSeq,
          reason: 'the page must still be established');
      expect(store.keys, hasLength(_keyCount - 1),
          reason: 'the other 1499 keys are not the gateway\'s typo to lose');
      expect(store.peek(_keyOfHandle(_poisonedHandle)), isNull,
          reason: 'the poisoned entry is dropped, never filed under a guess');
      // Anti-vacuity: a fix that dropped the whole snapshot would satisfy
      // "does not throw" too, so pin a neighbour on each side.
      expect(store.peek(_keyOfHandle(_poisonedHandle - 1))?.value,
          _poisonedHandle - 2);
      expect(store.peek(_keyOfHandle(_poisonedHandle + 1))?.value,
          _poisonedHandle);

      final named = engine.complaints
          .where((line) => line.contains('$_poisonedHandle'))
          .toList();
      expect(named, hasLength(1),
          reason: 'the drop must be visible, and it must name the handle: '
              '${engine.complaints}');
      expect(named.single, contains(_keyOfHandle(_poisonedHandle)));
    });

    test('a rejected entry with no kind costs that rejection only', () async {
      register('p');
      script.results['p'] = _rawResult('p', rejected: {
        // No `kind`. `KeyReject.fromJson` casts it to String today.
        'ST101.TYPO': <String, Object?>{'message': 'no such key'},
        'ST101.TAG0042': <String, Object?>{
          'kind': 'unknown_key',
          'message': 'not on this gateway',
        },
      });

      await engine.onHello('E1');

      expect(subs['p']!.lastSeq, _snapshotSeq);
      expect(storeFor('p').keys, hasLength(_keyCount),
          reason: 'the snapshot lane is untouched by a bad rejection');
      expect(
          engine.complaints.where((line) => line.contains('ST101.TYPO')),
          hasLength(1),
          reason: 'the undecodable rejection is reported, not swallowed: '
              '${engine.complaints}');
      // Anti-vacuity: the *good* rejection beside it still lands as the
      // rejection complaint `_establish` files, not as a decode failure.
      expect(
          engine.complaints.where(
              (line) => line.contains('ST101.TAG0042') && line.contains('unknown_key')),
          hasLength(1));
    });

    test('a finite but unrepresentable timestamp costs the timestamp, not the '
        'value', () async {
      register('p');
      // 1e17 is finite, so `wire_value.dart`'s `isFinite` guard admits it, and
      // `DateTime.fromMillisecondsSinceEpoch` then refuses it: the range ends
      // at 8.64e15.
      script.results['p'] = _rawResult('p', poison: {
        _poisonedHandle: <String, Object?>{'v': 41.5, 't': 1e17},
      });

      await engine.onHello('E1');

      final store = storeFor('p');
      expect(subs['p']!.lastSeq, _snapshotSeq);
      expect(store.keys, hasLength(_keyCount),
          reason: 'an unusable timestamp is not a reason to lose the reading');
      final poisoned = store.peek(_keyOfHandle(_poisonedHandle));
      expect(poisoned?.value, 41.5);
      expect(poisoned?.sourceTime, isNull,
          reason: 'absent, never clamped: a clamped timestamp is a lie about '
              'freshness');
      expect(
          engine.complaints
              .where((line) => line.contains('$_poisonedHandle'))
              .length,
          1,
          reason: 'a dropped timestamp says so: ${engine.complaints}');
      // Anti-vacuity again: nothing else lost its timestamp or its value.
      expect(store.peek(_keyOfHandle(1))?.value, 0);
    });
  });

  group('a response that is not decodable at all', () {
    test('still fails the whole pass and rolls it back', () async {
      register('s1', keys: 2);
      register('s2', keys: 2);
      script.results['s1'] = _rawResult('s1', keys: 2);
      // Not one bad entry — no decodable result at all. This is a peer
      // problem, and `_resubscribeAll` exists for exactly it.
      script.results['s2'] = <Object?>['not', 'an', 'object'];

      await expectLater(engine.onHello('E1'), throwsA(isA<FormatException>()));

      expect(subs['s1']!.lastSeq, isNull,
          reason: 'the pass rolls back: a page the client believes is live '
              'that the server may never have registered is the leak '
              '_resubscribeAll is shaped against');
      // `ValueStore.clear` keeps the nodes and forgets the values — orphaning
      // nodes would take every listening widget dark — so "no cache" is read
      // through `peek`, not through `keys`.
      expect(storeFor('s1').peek(_keyAt(0)), isNull);
      expect(storeFor('s1').peek(_keyAt(1)), isNull);
    });
  });

  group('the permanent reconnect loop', () {
    test('a panel served the same poisoned snapshot on every reconnect still '
        'reaches ready', () async {
      final gateway = await _PoisonGateway.start();
      final panel = _connect(gateway);

      await _until(
        'the panel to reach ready',
        () => panel.supervisor.state == LinkState.ready,
        diagnose: () => 'state is ${panel.supervisor.state}, after '
            '${gateway.dials} dials and ${gateway.subscribes} subscribes — a '
            'snapshot that is fatal on one attempt is fatal on all of them',
      );

      // And it stays there: a loop that merely took longer would show up as a
      // drop back to connecting during the settle window.
      final dialsAtReady = gateway.dials;
      await Future<void>.delayed(_settle);
      expect(panel.supervisor.state, LinkState.ready);
      expect(gateway.dials, dialsAtReady,
          reason: 'the link is not being torn down and rebuilt behind ready');
      expect(dialsAtReady, lessThan(3),
          reason: 'one poisoned entry must not cost a redial at all, let '
              'alone a redial per backoff period forever');

      // **Anti-vacuity, and it is not optional.** "Reaches ready" is satisfied
      // by any collapse that stops the throw — including one that discards the
      // whole snapshot and establishes an empty page. Sabotage (a) proved it:
      // widening the per-entry try to wrap the loop left this arm GREEN until
      // these three lines existed. A page that is ready and blank is the
      // failure mode this product exists to prevent, wearing the fix's hat.
      for (var index = 0; index < _pageKeys; index++) {
        if (index + 1 == _poisonedPageHandle) continue;
        expect(panel.store.peek(_keyAt(index))?.value, index,
            reason: 'reaching ready is worthless if the page is empty');
      }
      expect(panel.store.peek(_keyOfHandle(_poisonedPageHandle)), isNull,
          reason: 'the poisoned entry, and only it, is missing');
    });
  });
}

/// How long the socket-backed arm gives the panel, and how long it then
/// watches to be sure nothing else happened.
const Duration _budget = Duration(seconds: 5);
const Duration _settle = Duration(milliseconds: 400);

/// A gateway that answers `hello` and then serves the **same poisoned
/// snapshot** to every `subscribe`, on every connection.
///
/// After `resync_test.dart:138`. The poison is the non-map entry from arm 1 —
/// deliberately one shape rather than all three, so the sabotage matrix can
/// tell which containment this arm depends on.
final class _PoisonGateway {
  _PoisonGateway._(this._http);

  static Future<_PoisonGateway> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _PoisonGateway._(http);
    unawaited(gateway._accept());
    addTearDown(gateway.shutdown);
    return gateway;
  }

  final HttpServer _http;
  final _links = <WebSocket>[];

  /// How many sockets this gateway has accepted — the redial count the
  /// finding is about.
  int dials = 0;

  /// How many `subscribe` calls it has answered.
  int subscribes = 0;

  int _generation = 0;

  Uri get uri => Uri.parse('ws://127.0.0.1:${_http.port}');

  Future<void> _accept() async {
    await for (final request in _http) {
      final socket = await WebSocketTransformer.upgrade(request);
      dials++;
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
                  server: const PeerInfo('poison-gateway', '0.0.1'),
                  sessionId: 'S1',
                  epoch: 'E1',
                  serverTime: DateTime.now().millisecondsSinceEpoch,
                ).toJson(),
              });
            case Methods.subscribe:
              subscribes++;
              _send(socket, {
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  ..._rawResult(_page,
                      poison: {_poisonedPageHandle: 3}, keys: _pageKeys),
                  'generation': ++_generation,
                },
              });
            default:
              _send(socket, {
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

  void _send(WebSocket socket, Object? frame) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(frame));
  }

  Future<void> shutdown() async {
    for (final link in _links) {
      await link.close().catchError((Object _) => null);
    }
    await _http.close(force: true);
  }
}

/// The subscription the socket-backed arm holds.
const String _page = 'p';

/// Smaller than a real page: this arm's subject is the redial count, and 1500
/// keys per attempt would only slow the loop down.
const int _pageKeys = 8;

/// The handle the socket arm poisons. It has to be **inside** [_pageKeys] —
/// the first draft of this arm reused [_poisonedHandle] (700), which named no
/// entry in an 8-key snapshot, so the gateway served a clean page and the arm
/// passed against the unfixed client. An arm that cannot fail is worse than no
/// arm; it is recorded here because the mistake is easy to repeat.
const int _poisonedPageHandle = 4;

/// The client's knobs for the socket arm.
///
/// The backoff is deliberately fast, so "it loops forever" shows up inside the
/// budget as a pile of dials rather than as one slow attempt. The freshness
/// deadline is far longer than the arm runs: a scripted gateway that pushes
/// nothing is a silent link, and a watchdog tear-down would add reconnects
/// this arm would misread as the loop.
ClientConfig _socketConfig() => ClientConfig(
      controlDeadline: const Duration(milliseconds: 600),
      writeDeadline: const Duration(milliseconds: 600),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// What the socket arm holds: the supervisor for the link state and the store
/// for the anti-vacuity check that the page is not merely ready but populated.
typedef _Panel = ({ConnectionSupervisor supervisor, ValueStore store});

_Panel _connect(_PoisonGateway gateway) {
  final subscriptions = <String, SubscriptionState>{
    _page: SubscriptionState(subId: _page, keys: _keySet(_pageKeys)),
  };
  final store = ValueStore();
  addTearDown(store.dispose);
  final supervisor = ConnectionSupervisor(
    uri: gateway.uri,
    config: _socketConfig(),
    backoff: Backoff(
        base: const Duration(milliseconds: 20),
        cap: const Duration(milliseconds: 200),
        random: Random(1)),
    barrier: ReadinessBarrier(),
    watchdog: FreshnessWatchdog(
        config: _socketConfig(), onViewFreshnessChanged: (_) {}),
    subscriptions: subscriptions,
    storeFor: (_) => store,
  );
  addTearDown(supervisor.dispose);
  supervisor.start();
  return (supervisor: supervisor, store: store);
}

/// Polls [done] until it holds or [_budget] runs out, reporting [diagnose] —
/// evaluated at the moment of failure — so the arm names the loop it saw
/// rather than only the thing it did not see.
Future<void> _until(
  String what,
  bool Function() done, {
  String Function()? diagnose,
}) async {
  final deadline = DateTime.now().add(_budget);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${_budget.inMilliseconds} ms waiting for $what'
          '${diagnose == null ? '' : ': ${diagnose()}'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
