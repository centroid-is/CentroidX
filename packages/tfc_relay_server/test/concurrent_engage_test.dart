/// Two engages for one key that both cross the `await` in the middle of the
/// hold branch.
///
/// ## The mechanism, named once for this file and for `concurrent_hello_test`
///
/// `json_rpc_2`'s `Server.listen` is
/// `_channel.stream.listen(_handleRequest)` (`server.dart:115`) and the future
/// `_handleRequest` returns is **not awaited**. Nothing between the socket and
/// a handler body serializes anything: `registerMethod` stores a callback,
/// `RelaySession._on`, `_gated` and `_answer` each add an `await` and no lock.
/// So one frame's suspended handler does not hold the next frame back, and two
/// handlers can be interleaved inside the same method body.
///
/// A JSON-RPC **batch** is the deterministic version of that same race, not a
/// different one: `server.dart:175-181` dispatches a batch's members through
/// `Future.wait(request.map(_handleSingleRequest))`, so both members are
/// started in one turn and interleave by construction. That is why arm 2
/// exists beside arm 1 rather than instead of it — a fix that only handled
/// batches would be a fix for the demo.
///
/// ## What is actually broken
///
/// `value_handlers.dart`'s hold branch refuses a second live hold
/// **synchronously** (`:580-594`), and `write` has no `await` at all before
/// that point, so within one turn the refusal is sound. It then does
/// `await api.holdToRun(request.key)` and stores the handle afterwards. Two
/// engages that both reach the guard while `_holds` is empty both pass it,
/// both suspend, and the second store overwrites the first.
///
/// The displaced handle is a live engagement — a `1` on a deadman tag — that
/// no tick can feed (the tick's authorisation boundary is the `_holds`
/// lookup), that no release write can reach (the release branch also reads
/// `_holds`), and that `releaseAllHolds` cannot see, because it iterates the
/// map the handle is no longer in. The plant risk is bounded by the deadman
/// being fail-safe — the counter stops advancing, so the machine stops — but
/// the `1` was placed by an engage nothing will ever explicitly take back.
///
/// The sibling case needs no second engage and no hostile client at all: a
/// session torn down while `holdToRun` is still upstream runs
/// `releaseAllHolds` (and its `_holds.clear()`) first, and the handler then
/// resumes and stores a **held** handle into a dead session's cleared map.
///
/// ## What the arms assert, and why on the source rather than on the map
///
/// The map's size is 1 in every version of this defect, including the broken
/// one. What separates a fix from a re-arrangement is the number of holds the
/// **source** is still feeding, so arms 1 to 3 count live handles at the
/// source. A fix that dropped the loser instead of releasing it would move the
/// strand rather than close it, and would pass any assertion phrased about
/// `_holds`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:json_rpc_2/error_code.dart' as rpc_error;
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/value_handlers.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/fake_clock.dart';
import 'support/permissive_resolver.dart';

/// A clock far enough from zero that a ULID minted on it is a plausible id.
/// `value_handlers_test.dart:39`'s constant, same value and same reason.
const int _epochStart = 1_760_000_000_000;

const String _key = 'CN01.MOT01.jog';

// ---------------------------------------------------------------------------
// The source whose `holdToRun` a case can hold open.
// ---------------------------------------------------------------------------

/// A `FakeStateMan` whose `holdToRun` suspends until the case says otherwise.
///
/// `_EndsHoldsItself` (`value_handlers_test.dart:82`) is the shape this
/// follows: subclass, delegate to `super`, and record what was handed out. The
/// one addition is the gate, and it is what turns "two engages might
/// interleave" into "two engages are both suspended inside the branch, right
/// now, and here is the count that proves it".
final class _GatedEngages extends FakeStateMan {
  /// Every handle this source has minted, in the order it minted them.
  final handedOut = <HoldHandle>[];

  final _gate = Completer<void>();

  /// How many `holdToRun` calls have entered and suspended.
  ///
  /// The anti-vacuity number for every arm here: a case that opened the gate
  /// before both engages had crossed the synchronous guard would be asserting
  /// about a sequence, not a race.
  int arrivals = 0;

  @override
  Future<HoldHandle> holdToRun(String key) async {
    arrivals++;
    await _gate.future;
    final hold = await super.holdToRun(key);
    handedOut.add(hold);
    return hold;
  }

  /// Lets every suspended engage proceed, in the order it arrived.
  void open() {
    if (!_gate.isCompleted) _gate.complete();
  }

  /// How many of this source's handles are still live.
  ///
  /// **The property, and the reason it is read here rather than off `_holds`.**
  /// A handle the gateway dropped without releasing is still held at the
  /// source; a handle the gateway released is not. The map cannot tell those
  /// two apart and this can.
  int get liveHolds => handedOut.where((hold) => hold.isHeld).length;
}

// ---------------------------------------------------------------------------
// The unit kit. Copied from `value_handlers_test.dart:42-120` rather than
// exported from it: those helpers are private to that file on purpose, and a
// test-only export exists to be imported by something that should not have it.
// ---------------------------------------------------------------------------

final class _Kit {
  _Kit(this.handlers, this.api, this.clock);

  final ValueHandlers handlers;
  final FakeStateMan api;
  final FakeClock clock;

  String mintCmd() => newUlid(nowMs: clock.nowMs);
}

_Kit _kit({FakeStateMan? source}) {
  final api = source ?? FakeStateMan();
  final clock = FakeClock(start: _epochStart);
  const ttl = Duration(seconds: 60);
  final config = ServerConfig(writeOutcomeTtl: ttl);
  addTearDown(api.dispose);
  return _Kit(
    ValueHandlers(
      api: api,
      config: config,
      now: clock.now,
      outcomes: WriteOutcomeLog(ttl: ttl, now: clock.now),
    ),
    api,
    clock,
  );
}

rpc.Parameters _params(String method, Map<String, Object?> value) =>
    rpc.Parameters(method, value);

Map<String, Object?> _engage(String cmd, {String key = _key}) => {
      'cmd': cmd,
      'key': key,
      'value': 1,
      'hold': true,
    };

/// The call's outcome, whichever way it went, with a handler attached in the
/// same turn the call was made in.
///
/// Attaching immediately is load-bearing rather than tidy: a refusal that
/// nobody is listening to yet is an unhandled async error, and `package:test`
/// attributes one of those to whichever case happens to be running when it
/// lands.
Future<Object?> _settle(Future<Object?> call) =>
    call.then<Object?>((value) => value, onError: (Object error) => error);

/// Spins the event queue until [done], or fails naming [what].
///
/// A deadline turned into a fail, in `ws_malformed_test.dart:703`'s shape:
/// silence is the failure mode, and a matcher cannot express it.
Future<void> _until(bool Function() done, String what) async {
  for (var turn = 0; turn < 500; turn++) {
    if (done()) return;
    await pumpEventQueue(times: 1);
  }
  fail('waited 500 turns of the event queue for $what, and it never happened');
}

// ---------------------------------------------------------------------------
// One session over an in-memory channel, with the raw client sink kept.
// ---------------------------------------------------------------------------

/// `hold_gateway_test.dart:_Gate` with the pair's own sink left reachable, so
/// a case can put a JSON-RPC **array** frame on the wire. No `Peer` API can
/// build one, and the batch is the deterministic shape of this race.
final class _Wire {
  _Wire(this.session, this.client, this.sink, this.inbound, this.api,
      this.clock);

  final RelaySession session;
  final rpc.Client client;

  /// The raw client end. Everything else here goes through [client].
  final StreamSink<String> sink;

  /// Every frame the server sent this client, in order.
  final List<String> inbound;

  final _GatedEngages api;
  final FakeClock clock;

  Future<Object?> ask(String method, Object? params) =>
      within(client.sendRequest(method, params), 'the $method answer');

  Future<void> hello() => ask(
      Methods.hello,
      HelloParams(
        protocol: protocolVersion,
        supported: const [protocolVersion],
        client: const PeerInfo('panel-under-test', '0.1.0'),
      ).toJson());

  String mintCmd() => newUlid(nowMs: clock.nowMs);

  int? valueOf(String key) => api.read(key)?.value as int?;
}

_Wire _wire() {
  final pair = channelPair();
  final api = _GatedEngages();
  final clock = FakeClock(start: _epochStart);
  final inbound = <String>[];
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: api,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    now: clock.now,
    onError: (_, __, ___) {},
  );
  final client = rpc.Client(StreamChannel<String>(
      pair.client.stream.map((frame) {
        inbound.add(frame);
        return frame;
      }),
      pair.client.sink));
  unawaited(client.listen().catchError((Object _) => null));
  addTearDown(() async {
    api.open();
    await client.close();
    await session.close(1000, 'concurrent engage test over');
    await api.dispose();
  });
  return _Wire(session, client, pair.client.sink, inbound, api, clock);
}

/// The answers in the batch response frame that carries every id in [ids].
Future<Map<String, Map<String, Object?>>> _batchAnswers(
    _Wire wire, List<String> ids) async {
  List<Map<String, Object?>>? found;
  await _until(() {
    for (final frame in wire.inbound) {
      final decoded = jsonDecode(frame);
      if (decoded is! List) continue;
      final answers = decoded
          .map((entry) => (entry! as Map).cast<String, Object?>())
          .toList();
      if (ids.every((id) => answers.any((answer) => answer['id'] == id))) {
        found = answers;
        return true;
      }
    }
    return false;
  }, 'a batch response carrying $ids');
  return {
    for (final answer in found!) answer['id']! as String: answer,
  };
}

void main() {
  group('two engages for one key that both cross the await', () {
    test('leave exactly one live hold, and the loser is released', () async {
      final source = _GatedEngages();
      final kit = _kit(source: source);
      kit.api.setValue(_key, 0);

      // Both calls are made in one turn, and `write` has no `await` before the
      // hold guard — so each of them runs its whole prologue, passes the
      // refusal at `value_handlers.dart:580-594` against an empty `_holds`,
      // and suspends inside `api.holdToRun`.
      final first = _settle(kit.handlers.write(
          _params(Methods.write, _engage(kit.mintCmd()))));
      final second = _settle(kit.handlers.write(
          _params(Methods.write, _engage(kit.mintCmd()))));

      expect(source.arrivals, 2,
          reason: 'only one engage reached the source, so the two calls were '
              'sequential and this case is asserting about a sequence rather '
              'than about a race. The guard at :580 is synchronous and `write` '
              'has no await in front of it, so both must cross it while '
              '`_holds` is still empty');

      source.open();
      final outcomes = [await first, await second];

      final refusals = outcomes.whereType<rpc.RpcException>().toList();
      final answers =
          outcomes.where((outcome) => outcome is! rpc.RpcException).toList();
      expect(answers, hasLength(1),
          reason: 'both engages were answered as though they had taken. One '
              'key is one deadman counter, and a client told twice that it '
              'holds the button is a UI showing a live hold on whichever of '
              'the two handles the gateway threw away');
      expect(refusals, hasLength(1));
      expect(refusals.single.code, rpc_error.INVALID_PARAMS,
          reason: 'the engage that loses across the await gets the same code '
              'as the one that loses in front of it, so a client sees one '
              'answer for "one key, one hold" whichever side of the suspend '
              'it lost on');

      expect(source.liveHolds, 1,
          reason: 'the source is feeding ${source.liveHolds} holds on one '
              'tag. The displaced handle is a live engagement no tick can '
              'reach (the `_holds` lookup is the tick\'s authorisation '
              'boundary), no release write can find, and `releaseAllHolds` '
              'cannot see — a `1` placed on a deadman by an engage nothing '
              'will ever explicitly take back');

      // The survivor is the one in the map: still feedable, and still the one
      // teardown ends. A fix that released the *winner* would satisfy the
      // count above and leave the operator holding a dead button.
      await kit.handlers
          .holdTick(_params(Methods.holdTick, {'k': _key, 'n': 2}));
      expect(kit.api.read(_key)?.value, 2,
          reason: 'the hold left in `_holds` is not the live one, so the tick '
              'that follows a successful engage does not reach the tag');

      kit.handlers.releaseAllHolds();
      await pumpEventQueue();
      expect(source.liveHolds, 0,
          reason: 'teardown must end every hold this session took, and it can '
              'only end the ones it can see');
      expect(kit.api.read(_key)?.value, 0);
    });

    test('leave exactly one live hold when they arrive as a JSON-RPC batch',
        () async {
      final wire = _wire();
      await wire.hello();
      wire.api.setValue(_key, 0);

      // The batch shape, hand-built: `json_rpc_2` has no client API that emits
      // one with ids a case chose, and the array frame is what makes
      // `Future.wait(request.map(_handleSingleRequest))` (`server.dart:181`)
      // start both members in the same turn.
      const idOne = 'engage-a';
      const idTwo = 'engage-b';
      wire.sink.add(jsonEncode([
        {
          'jsonrpc': '2.0',
          'id': idOne,
          'method': Methods.write,
          'params': _engage(wire.mintCmd()),
        },
        {
          'jsonrpc': '2.0',
          'id': idTwo,
          'method': Methods.write,
          'params': _engage(wire.mintCmd()),
        },
      ]));

      await _until(() => wire.api.arrivals == 2,
          'both members of the batch to reach the source');

      wire.api.open();
      final answers = await _batchAnswers(wire, [idOne, idTwo]);

      final applied = answers.values
          .where((answer) => answer.containsKey('result'))
          .toList();
      final refused =
          answers.values.where((answer) => answer.containsKey('error')).toList();
      expect(applied, hasLength(1),
          reason: 'both members of the batch were answered as though they had '
              'taken the hold');
      expect(refused, hasLength(1));

      expect(wire.api.liveHolds, 1,
          reason: 'a batch is one frame, so this needs no timing luck at all: '
              'json_rpc_2 starts both members concurrently and the second '
              'store displaces the first handle into a place nothing in this '
              'gateway can reach');

      await wire.session.close(1000, 'the panel went home');
      await pumpEventQueue();
      expect(wire.api.liveHolds, 0,
          reason: 'the session ended and a hold survived it, which is a '
              'machine being fed on behalf of a panel that is gone (T-05-20)');
      expect(wire.valueOf(_key), 0);
    });
  });

  group('a holdToRun that resumes after the session died', () {
    test('stores nothing, and releases the handle it was handed', () async {
      final source = _GatedEngages();
      final kit = _kit(source: source);
      kit.api.setValue(_key, 0);

      final call = _settle(
          kit.handlers.write(_params(Methods.write, _engage(kit.mintCmd()))));
      expect(source.arrivals, 1,
          reason: 'the engage has not reached the source, so there is nothing '
              'in flight for the teardown to race');

      // `RelaySession._teardown:1471` calls this synchronously, while an
      // in-flight `holdToRun` may be suspended — a heartbeat sweep, a
      // backpressure eviction, a yanked cable. One engage and no second
      // client: this shape needs nothing hostile at all.
      kit.handlers.releaseAllHolds();
      source.open();

      final outcome = await call;
      expect(outcome, isA<rpc.RpcException>(),
          reason: 'an engage that resumes into a torn-down session cannot be '
              'answered as though it took: there is no session left to hold '
              'anything');

      expect(source.liveHolds, 0,
          reason: 'a held handle landed in a dead session\'s cleared map. '
              'Nothing will tick it, nothing will release it, and the '
              'teardown that would have has already run');

      await kit.handlers
          .holdTick(_params(Methods.holdTick, {'k': _key, 'n': 2}));
      expect(kit.handlers.droppedHoldTicks, 1,
          reason: 'the tick found a hold in the map of a session that has '
              'already been torn down, which is exactly the authorisation '
              'boundary `_holds` is supposed to be');
      expect(kit.api.read(_key)?.value, 0,
          reason: 'the tag is still carrying the engage\'s 1, so the handle '
              'was dropped rather than released');
    });
  });

  group('the synchronous refusal still refuses', () {
    test('a second engage after the first has settled is refused and mints no '
        'second hold', () async {
      // `value_handlers_test.dart:987`'s property, restated here so that a fix
      // for the arms above cannot be bought by weakening the guard those arms
      // race past. If this goes green by way of "there is no guard any more",
      // it goes red first.
      final kit = _kit();
      kit.api.setValue(_key, 0);

      final first = await kit.handlers
          .write(_params(Methods.write, _engage(kit.mintCmd())));
      expect(
          WriteResult.fromJson((first! as Map).cast<String, Object?>()),
          isA<WriteApplied>(),
          reason: 'the first engage did not take, so there is no live hold '
              'for the second to collide with');
      final mintedAfterFirst = kit.api.mintedCmds.length;

      final secondCmd = kit.mintCmd();
      final outcome = await _settle(
          kit.handlers.write(_params(Methods.write, _engage(secondCmd))));

      expect(outcome, isA<rpc.RpcException>());
      expect((outcome! as rpc.RpcException).code, rpc_error.INVALID_PARAMS,
          reason: 'the refusal is raised before api.holdToRun, so '
              '"definitively no effect" is true and INVALID_PARAMS is the '
              'honest code');
      expect(kit.api.mintedCmds, hasLength(mintedAfterFirst),
          reason: 'a second source-side hold was taken in front of a guard '
              'whose whole job is to stop one');
      expect(kit.api.upstreamWriteAttempts(secondCmd), 0);
    });
  });
}
