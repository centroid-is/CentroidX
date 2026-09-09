/// `subscribe` and `unsubscribe`: the two methods a panel spends its life in.
///
/// Driven over `channelPair()` with a real `json_rpc_2` client on the far end
/// and no sockets — the same reasoning as `session_hello_test.dart`, and the
/// real-socket coverage of these same handlers arrives free in 03-06's contract
/// leg and 03-07's fan-out cases. A property that needs a port to be asserted
/// is a property that gets asserted rarely.
///
/// The two cases this file exists for:
///
///  * **One response carries everything.** Handles, metadata and the snapshot
///    arrive together or the client is holding an integer it has no value for
///    and no way to ask for one — a widget bound to a tag that will render
///    blank until the tag happens to change, which on a plant can be a shift.
///  * **A per-key problem stays per-key.** One tag mistyped into a page config
///    must cost that tag, not the page. A subscribe that fails whole because
///    one key of fifteen hundred is unknown is a blank screen in a control
///    room, and it is the single easiest way to turn a typo into an outage.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

import 'support/permissive_resolver.dart';

/// A source that can serve a key whose value has not arrived yet.
///
/// `FakeStateMan.keys` deliberately filters to keys a value has arrived for, so
/// a typo cannot launder itself into the picker. The gateway still has to cope
/// with the other case — a key the source will serve, currently unknown — and
/// this is the smallest honest way to produce one.
final class _SourceWithAPendingKey extends FakeStateMan {
  static const pendingKey = 'CN01.MOT01.torque';

  @override
  List<String> get keys => [...super.keys, pendingKey];
}

final class _Link {
  _Link(this.session, this.client, this.api);
  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'test over');
    await api.dispose();
  }
}

_Link _link({
  FakeStateMan? api,
  ServerConfig? config,
  HandleTable? handles,
  ConflatingSendBuffer? buffer,
}) {
  final pair = channelPair();
  final source = api ?? FakeStateMan();
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: source,
    config: config ?? ServerConfig(),
    handles: handles ?? HandleTable(),
    buffer: buffer ?? ConflatingSendBuffer(maxPending: 4096),
  );
  final client = rpc.Client(pair.client);
  unawaited(client.listen());
  return _Link(session, client, source);
}

Future<void> _sayHello(_Link link) => within(
        link.client.sendRequest(
            Methods.hello,
            HelloParams(
              protocol: protocolVersion,
              supported: const [protocolVersion],
              client: const PeerInfo('panel-under-test', '0.1.0'),
            ).toJson()),
        'the hello')
    .then((_) {});

Future<SubscribeResult> _subscribe(_Link link,
    {required String sub, required List<String> keys, double? maxRateHz}) async {
  final raw = await within(
      link.client.sendRequest(
          Methods.subscribe,
          SubscribeParams(sub: sub, keys: keys, maxRateHz: maxRateHz).toJson()),
      'the subscribe result for "$sub"');
  return SubscribeResult.fromJson((raw as Map).cast<String, Object?>());
}

Future<rpc.RpcException> _refusal(Future<Object?> call, String what) async {
  try {
    await within(call, what);
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

/// Ten plant keys in the house convention, all with values.
Map<String, Object?> _tenKeys() => {
      for (var i = 1; i <= 10; i++)
        'CN${i.toString().padLeft(2, '0')}.MOT01.speed': i,
    };

void main() {
  test('handles, meta and snapshot arrive together', () async {
    final link = _link();
    addTearDown(link.dispose);
    link.api.setValues(_tenKeys());
    await _sayHello(link);

    final keys = _tenKeys().keys.toList();
    final result = await _subscribe(link, sub: 'page-1', keys: keys);

    expect(result.sub, 'page-1');
    expect(result.epoch, isNotEmpty);
    expect(result.handles, hasLength(10));
    expect(result.rejected, isEmpty);

    final handled = result.handles.values.toSet();
    expect(result.snapshot.keys.toSet(), handled,
        reason: 'a handle with no snapshot entry is a widget with no value and '
            'no way to ask for one — it renders blank until the tag happens to '
            'move, which on a plant can be a whole shift');
    expect(result.meta.keys.toSet(), handled,
        reason: 'metadata rides once, here, and never again on the hot path; a '
            'handle missing from it has no units and no display name for the '
            'life of the subscription');

    final firstKey = keys.first;
    final firstHandle = result.handles[firstKey]!;
    expect(result.snapshot[firstHandle]!.v, 1);
    expect((result.meta[firstHandle]! as Map)['key'], firstKey,
        reason: 'meta names the key the handle stands for, so a diagnostic can '
            'read a frame without the subscribe response that made it');
  });

  test('one impossible key does not sink the other nine', () async {
    final link = _link();
    addTearDown(link.dispose);
    link.api.setValues(_tenKeys());
    await _sayHello(link);

    final good = _tenKeys().keys.toList()..removeLast();
    final result = await _subscribe(link,
        sub: 'page-1', keys: [...good, 'CN99.NOPE01.invented']);

    expect(result.handles.keys.toSet(), good.toSet(),
        reason: 'the nine good keys are served: one tag mistyped into a page '
            'config must cost that tag, not the page');
    expect(result.snapshot, hasLength(9));
    expect(result.rejected.keys, ['CN99.NOPE01.invented']);
    final reject = result.rejected['CN99.NOPE01.invented']!;
    expect(reject.kind, isNotEmpty);
    expect(reject.message, isNotNull,
        reason: 'the kind is for the client to branch on and the message is '
            'for the engineer reading the log at 3am');
    expect(link.session.subscriptions.count, 1,
        reason: 'the call succeeded, so the subscription exists');
  });

  test('a key the source will serve but has no value for yet still gets a '
      'snapshot entry', () async {
    final api = _SourceWithAPendingKey();
    final link = _link(api: api);
    addTearDown(link.dispose);
    api.setValue('CN01.MOT01.speed', 3);
    await _sayHello(link);

    final result = await _subscribe(link,
        sub: 'page-1',
        keys: ['CN01.MOT01.speed', _SourceWithAPendingKey.pendingKey]);

    expect(result.rejected, isEmpty,
        reason: 'the source lists the key, so it is servable — "not known yet" '
            'is a value state, not a rejection');
    final pending = result.handles[_SourceWithAPendingKey.pendingKey]!;
    expect(result.snapshot.containsKey(pending), isTrue,
        reason: 'a missing map entry is indistinguishable from a dropped key; '
            'the client must be able to tell "no value yet" from "you never '
            'sent me this one"');
    expect(result.snapshot[pending]!.v, isNull);
    expect(result.snapshot[pending]!.q, Quality.uncertainNotYetKnown,
        reason: 'uncertain, not error: nothing is misconfigured, the value has '
            'simply not arrived');
  });

  test('a non-finite value is sanitized into the snapshot, not thrown',
      () async {
    final link = _link();
    addTearDown(link.dispose);
    link.api.setValue('CN01.SCL01.rate', double.infinity);
    await _sayHello(link);

    final result =
        await _subscribe(link, sub: 'page-1', keys: ['CN01.SCL01.rate']);

    final handle = result.handles['CN01.SCL01.rate']!;
    expect(result.snapshot[handle]!.v, isNull);
    expect(result.snapshot[handle]!.q, Quality.badNonFinite,
        reason: 'a divide-by-zero rate off a weigher must arrive as a flagged '
            'null, never as an Infinity on the wire: jsonEncode throws on it, '
            'the frame is lost, and the loss is silent');
  });

  test('two sessions get the same handle for one key', () async {
    final handles = HandleTable();
    final first = _link(handles: handles);
    final second = _link(handles: handles);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    first.api.setValue('CN04.MOT01.speed', 1);
    second.api.setValue('CN04.MOT01.speed', 2);
    await _sayHello(first);
    await _sayHello(second);

    final a =
        await _subscribe(first, sub: 'page-a', keys: ['CN04.MOT01.speed']);
    final b =
        await _subscribe(second, sub: 'page-b', keys: ['CN04.MOT01.speed']);

    expect(a.handles['CN04.MOT01.speed'], b.handles['CN04.MOT01.speed'],
        reason: 'Finding 3: the update body is keyed by handle, so two panels '
            'watching one motor must be handed the same integer or the body '
            'stops being byte-identical and every client costs its own encode '
            '(measured at 69.6x)');
  });

  test('an empty key list is refused rather than silently accepted', () async {
    final link = _link();
    addTearDown(link.dispose);
    await _sayHello(link);

    final refusal = await _refusal(
        link.client.sendRequest(
            Methods.subscribe, const SubscribeParams(sub: 'page-1', keys: [])
                .toJson()),
        'an empty subscribe');

    expect(refusal.message, contains('keys'));
    expect(link.session.subscriptions.count, 0,
        reason: 'an empty subscription is a name the client will wait on '
            'forever; refusing it is what turns a client bug into an error '
            'message instead of a blank page');
  });

  // 04-REVIEW CR-03. This used to be `a duplicate subscription name is
  // refused`, and the refusal wedged the one client move it was refusing: a
  // page whose sequence gapped can only ask for the page again. The refusal
  // threw before the client's `store.clear()` could rebase its baseline, so the
  // next frame was another gap, which asked again, for as long as the socket
  // lived — pre-gap values on screen under good quality with the link
  // indicator reading ready.
  test('a subscribe naming a live subscription re-establishes it', () async {
    final link = _link();
    addTearDown(link.dispose);
    link.api.setValue('CN01.MOT01.speed', 1);
    await _sayHello(link);

    final first =
        await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);
    // Move the sequence off its baseline, the way a few ticks of a live plant
    // would, so "rebased" is a claim about something.
    link.session.subscriptions.get('page-1')!.nextSeq();
    link.api.setValue('CN01.MOT01.speed', 2);

    final again =
        await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);

    expect(link.session.subscriptions.count, 1,
        reason: 'two subscriptions under one name make seq ambiguous, and an '
            'ambiguous seq is a permanent resync loop. Re-establishing keeps '
            'exactly one, which is what the old refusal was protecting');
    expect(again.seq, 0,
        reason: 'the answer is a snapshot, and a snapshot is a new baseline; '
            'a client that rebased onto a mid-stream seq would read the next '
            'frame as a gap');
    expect(again.snapshot.values.single.v, 2,
        reason: 'the snapshot is read now, not remembered from the first '
            'establishment');
    expect(again.generation, greaterThan(first.generation),
        reason: 'the generation is how the client tells a frame from the '
            'establishment just torn down from one belonging to this snapshot '
            '— on the same socket, where the epoch has not moved');
    expect(link.session.subscriptions.listenerCount, 1,
        reason: 'the old establishment\'s listener came off the source. Left '
            'on, every re-establish would double the work one changed tag '
            'costs, and the leak is per recovery, forever');
  });

  test('re-establishing at the subscription ceiling is not refused', () async {
    final link = _link(config: ServerConfig(maxSubscriptionsPerSession: 1));
    addTearDown(link.dispose);
    link.api.setValue('CN01.MOT01.speed', 1);
    await _sayHello(link);

    await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);
    final again =
        await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);

    expect(again.sub, 'page-1',
        reason: 'a panel holding its ceiling in live pages still has to be '
            'able to recover one of them; counting the entry it is replacing '
            'against the limit would make the last page unrecoverable');
    expect(link.session.subscriptions.count, 1);
  });

  test('a refused re-establish leaves the live subscription alone', () async {
    final link = _link();
    addTearDown(link.dispose);
    link.api.setValue('CN01.MOT01.speed', 1);
    await _sayHello(link);
    await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);

    // A shape refusal: the teardown must sit behind every check that can say
    // no, or a malformed retry costs the operator a working page.
    await _refusal(
        link.client.sendRequest(
            Methods.subscribe,
            const SubscribeParams(
                    sub: 'page-1', keys: ['CN01.MOT01.speed'], maxRateHz: 0)
                .toJson()),
        'a re-establish with an impossible rate');

    expect(link.session.subscriptions.count, 1);
    expect(link.session.subscriptions.listenerCount, 1,
        reason: 'the page that was working is still working; a refusal is not '
            'a reason to take it down');
  });

  test('a key list over the ceiling is refused naming the limit', () async {
    final link = _link(config: ServerConfig(maxKeysPerSubscribe: 4));
    addTearDown(link.dispose);
    await _sayHello(link);

    final refusal = await _refusal(
        link.client.sendRequest(
            Methods.subscribe,
            SubscribeParams(
                sub: 'page-1',
                keys: [for (var i = 0; i < 5; i++) 'CN01.MOT01.k$i']).toJson()),
        'an oversized subscribe');

    expect(refusal.message, contains('4'),
        reason: 'T-03-13: the cheapest denial of service against this server '
            'is one unbounded key list, and a client told the number can stay '
            'under it');
  });

  test('a session at its subscription ceiling is refused naming the limit',
      () async {
    final link = _link(config: ServerConfig(maxSubscriptionsPerSession: 2));
    addTearDown(link.dispose);
    link.api.setValue('CN01.MOT01.speed', 1);
    await _sayHello(link);

    await _subscribe(link, sub: 'page-1', keys: ['CN01.MOT01.speed']);
    await _subscribe(link, sub: 'page-2', keys: ['CN01.MOT01.speed']);
    final refusal = await _refusal(
        link.client.sendRequest(
            Methods.subscribe,
            const SubscribeParams(sub: 'page-3', keys: ['CN01.MOT01.speed'])
                .toJson()),
        'a subscribe past the ceiling');

    expect(refusal.message, contains('2'),
        reason: 'T-03-14: the other cheap denial of service is one '
            'authenticated client opening subscriptions until the memory is '
            'gone');
    expect(link.session.subscriptions.count, 2);
  });

  test('a subscribed value change lands in the buffer under its handle',
      () async {
    final buffer = ConflatingSendBuffer(maxPending: 4096);
    final link = _link(buffer: buffer);
    addTearDown(link.dispose);
    link.api.setValue('CN02.MOT01.speed', 1);
    await _sayHello(link);

    final result =
        await _subscribe(link, sub: 'page-1', keys: ['CN02.MOT01.speed']);
    final handle = result.handles['CN02.MOT01.speed']!;

    link.api.setValue('CN02.MOT01.speed', 2);
    await pumpEventQueue();

    final drained = buffer.drain();
    expect(drained.subs['page-1']!.changes[handle]!.v, 2,
        reason: 'subscribe is not a one-shot read: the listener it attaches is '
            'the subscription');
  });

  test('unsubscribe releases the subscription and an unknown one is named',
      () async {
    final buffer = ConflatingSendBuffer(maxPending: 4096);
    final link = _link(buffer: buffer);
    addTearDown(link.dispose);
    link.api.setValue('CN03.MOT01.speed', 1);
    await _sayHello(link);

    await _subscribe(link, sub: 'page-1', keys: ['CN03.MOT01.speed']);
    expect(link.session.subscriptions.count, 1);

    await within(
        link.client.sendRequest(Methods.unsubscribe, {'sub': 'page-1'}),
        'the unsubscribe');
    expect(link.session.subscriptions.count, 0,
        reason: 'SRV-02 asks for the release to be asserted by registry '
            'inspection, because inferring it from silence passes just as well '
            'for a server that leaked every listener it made');

    link.api.setValue('CN03.MOT01.speed', 2);
    await pumpEventQueue();
    expect(buffer.drain().subs, isEmpty,
        reason: 'and the listener went with it');

    final refusal = await _refusal(
        link.client.sendRequest(Methods.unsubscribe, {'sub': 'page-1'}),
        'a second unsubscribe');
    expect(refusal.code, ServerErrorCodes.unknownSubscription,
        reason: 'the client is told there is no such subscription so it can '
            'stop sending for it — usually the tail of a resync it did not '
            'finish applying');
  });

  test('subscribe before hello is refused by the same gate as everything else',
      () async {
    final link = _link();
    addTearDown(link.dispose);

    final refusal = await _refusal(
        link.client.sendRequest(Methods.subscribe,
            const SubscribeParams(sub: 'page-1', keys: ['CN01.MOT01.speed'])
                .toJson()),
        'a pre-hello subscribe');

    expect(refusal.code, ServerErrorCodes.helloRequired,
        reason: 'registering through the `_on` seam is what makes a handler '
            'gated by construction; a second registration path is how the one '
            'method nobody remembered ends up serving plant data to a client '
            'that never authenticated');
    expect(link.session.subscriptions.count, 0);
  });

  test('the wire surface is exactly the seventy-four methods declared today, '
      'plus the one name a client announces', () async {
    final link = _link();
    addTearDown(link.dispose);

    expect(link.session.registeredMethods, {
      Methods.hello,
      Methods.ping,
      // Increment B of the no-station-file ruling: sign-in over the socket
      // and its way back down. Constants here, bare strings in
      // `surface_test.dart` — the standing split.
      Methods.sessionLogin,
      Methods.sessionLogout,
      Methods.subscribe,
      Methods.unsubscribe,
      Methods.write,
      Methods.writeStatus,
      // Phase 14 plan 12, the acknowledge. Same rule as the families below:
      // constants here because this file pins the *ledger*, bare strings in
      // `surface_test.dart` because that one pins the wire spelling.
      Methods.ackAlarm,
      Methods.read,
      Methods.readFresh,
      Methods.readMany,
      // Phase 10 plan 02, the first four data services. Spelled as constants
      // here and as bare strings in `surface_test.dart`, deliberately: that
      // file is pinning the wire *spelling* and this one is pinning the
      // *ledger*, so a rename must break exactly one of the two.
      DataServiceMethods.browseFetchRoots,
      DataServiceMethods.browseFetchChildren,
      DataServiceMethods.browseFetchDetail,
      DataServiceMethods.browseResolvePath,
      // Phase 10 plan 03, the timeseries three (four until the 2026-09-07
      // audit cut the count method). Same rule, same commit: the
      // handler bodies, this ledger and the contract legs' gap lists move
      // together or the suite is red between two commits.
      DataServiceMethods.timeseriesQuery,
      DataServiceMethods.timeseriesQueryMultiple,
      DataServiceMethods.timeseriesQueryDownsampled,
      // Phase 10 plan 04, the history-view eleven. Same rule, same commit.
      DataServiceMethods.historyCreateView,
      DataServiceMethods.historyUpdateView,
      DataServiceMethods.historyDeleteView,
      DataServiceMethods.historySelectViews,
      DataServiceMethods.historyGetKeys,
      DataServiceMethods.historyGetGraphs,
      DataServiceMethods.historyGetKeyNames,
      DataServiceMethods.historyAddPeriod,
      DataServiceMethods.historyDeletePeriod,
      DataServiceMethods.historyListPeriods,
      DataServiceMethods.historyRetentionHorizon,
      // Phase 10 plan 05, the preferences fifteen. Same rule, same commit —
      // and this is the family that closes the table: after these there is no
      // thirty-fifth data-service name to add.
      DataServiceMethods.prefGetKeys,
      DataServiceMethods.prefGetAll,
      DataServiceMethods.prefGetBool,
      DataServiceMethods.prefGetInt,
      DataServiceMethods.prefGetDouble,
      DataServiceMethods.prefGetString,
      DataServiceMethods.prefGetStringList,
      DataServiceMethods.prefContainsKey,
      DataServiceMethods.prefSetBool,
      DataServiceMethods.prefSetInt,
      DataServiceMethods.prefSetDouble,
      DataServiceMethods.prefSetString,
      DataServiceMethods.prefSetStringList,
      DataServiceMethods.prefRemove,
      DataServiceMethods.prefClear,
      // Phase 17 plan 09, the access twenty-eight. Iterated from the
      // declared set here — this ledger already spells every family through
      // its constants, and `surface_test.dart` holds the canonical bare
      // strings a rename must break against.
      ...AccessMethods.all,
      // 05-05. Not a forty-fourth callable name: `h` is a client→server
      // notification, dispatched through the same table because that is how
      // json_rpc_2 routes a frame with no id. `surface_test.dart` keeps the
      // two apart in separate literals; here the ledger is one set.
      Methods.holdTick,
    }, reason: 'a declared name with no handler answers METHOD_NOT_FOUND from '
        'a table claiming to carry it; a handler nobody declared is surface '
        'nobody counted. 03-08 freezes this set, 04-02 added the five value '
        'methods to it, 10-02 the four browse ones, 10-03 the four timeseries '
        'ones, 10-04 the eleven history-view ones and 10-05 the preferences '
        'fifteen that closed it, 14-12 the acknowledge that reopened it '
        'for exactly one name, and 17-09 the access twenty-eight. This is the '
        'third file '
        'spelling the table out — '
        '`surface_test.dart` holds the canonical literal, and the fact that '
        'three copies had to be edited in lockstep is itself worth the note');
  });

  group('a partial subscribe leaves nothing attached', () {
    // 03-REVIEW WR-08. `state.watch` sits outside the per-key try, and
    // `subscriptions.put(state)` does not run until the end. A throw from
    // `api.listen` on the tenth of fifty keys left the nine listeners already
    // attached unreachable: the state never entered the registry, so teardown
    // could not find it, and the only other reference was the unwinding stack
    // frame. A permanent leak per failure.
    test('a listen that throws mid-loop detaches what it already attached',
        () async {
      final api = _ListenFailsOn('CN01.MOT03.speed');
      final link = _link(api: api);
      await _sayHello(link);

      final keys = [for (var i = 1; i <= 5; i++) 'CN01.MOT0$i.speed'];
      api.setValues({for (final key in keys) key: 0});
      final baseline = _attached(api, keys);

      await _refusal(
          link.client.sendRequest(Methods.subscribe,
              SubscribeParams(sub: 'page-1', keys: keys).toJson()),
          'a subscribe whose third key cannot be listened to');

      expect(_attached(api, keys), baseline,
          reason: 'every listener attached before the failure has to come off '
              'on the way out or never: the subscription never reached the '
              'registry, so `subscriptions.clear()` at teardown cannot see it, '
              'and the listeners keep pushing a dead page\'s values into a '
              'buffer nothing will drain');
      expect(link.session.subscriptions.count, 0,
          reason: 'a subscribe that failed must leave no subscription behind, '
              'or the name is taken and the client can never retry it');
    });
  });
}

/// Listeners the session has attached to [api] across [keys].
///
/// Read through [_ListenFailsOn.node] rather than `listen`, because the whole
/// point of that source is that `listen` throws for one of these keys — and a
/// measurement that could not survive the fault it is measuring would be no
/// measurement at all.
int _attached(_ListenFailsOn api, List<String> keys) => [
      for (final key in keys) api.node(key).listenerCount
    ].fold(0, (a, b) => a + b);

/// A source whose `listen` throws for one key — an upstream that is there for
/// most tags and gone for one, which is what a real DeviceClient does when a
/// node id has been renamed underneath it (Phase 8).
final class _ListenFailsOn extends FakeStateMan {
  _ListenFailsOn(this.badKey);
  final String badKey;

  /// The backing node, reachable even for [badKey].
  ValueStoreNode node(String key) => super.listen(key) as ValueStoreNode;

  @override
  ValueListenable<DynamicValue> listen(String key) {
    if (key == badKey) {
      throw StateError('the upstream has no monitored item for "$key"');
    }
    return super.listen(key);
  }
}
