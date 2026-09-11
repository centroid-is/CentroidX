/// What the server can be *asked* about its own subscriptions.
///
/// SRV-02 says an unsubscribe's release is "asserted by registry inspection",
/// and that phrase is the whole reason this file exists. The alternative —
/// infer the release from silence, by unsubscribing and then observing that no
/// update arrived — passes just as well when the listener is still attached and
/// the value simply did not change, and it passes for a server that has leaked
/// every listener it ever made. A leak that only shows up after eight hours of
/// plant churn is not a leak a test finds by waiting.
///
/// So every case below reads state: the count, the names, the handle union, and
/// — for the one property that cannot be read directly — whether a value change
/// on a detached key still lands in the send buffer. The listener bookkeeping
/// measured here is what 03-11's kill-cycle test re-measures against real
/// session churn.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_server.dart' show SessionRegistry;
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/subscription_registry.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';

/// One session's worth of the pieces a subscription is made of.
final class _Bench {
  _Bench() : api = FakeStateMan();

  final FakeStateMan api;
  final handles = HandleTable();
  final buffer = ConflatingSendBuffer(maxPending: 4096);
  final registry = SubscriptionRegistry(maxSubscriptions: 32);

  /// Registers [sub] over [keys], attaching one listener per key that pushes
  /// into [buffer] — the same shape `session_handlers.dart` builds, assembled
  /// by hand here so this file tests the registry and not the handler.
  SubscriptionState open(String sub, List<String> keys) {
    final state = SubscriptionState(sub: sub, epoch: 'epoch-of-$sub');
    for (final entry in handles.handlesFor(keys).entries) {
      final handle = entry.value;
      state.watch(entry.key, handle, api.listen(entry.key),
          (value) => buffer.putValue(sub, handle, WireValue.of(value.value)));
    }
    registry.put(state);
    return state;
  }

  /// Which handles have pending changes, per subscription, draining as it goes.
  Map<String, Set<int>> drained() => {
        for (final entry in buffer.drain().subs.entries)
          entry.key: entry.value.changes.keys.toSet(),
      };

  Future<void> dispose() async {
    registry.clear();
    await api.dispose();
  }
}

void main() {
  test('a session with two subscriptions counts both and unions their keys',
      () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    bench.open('page-a', ['A.one', 'A.two', 'shared.key']);
    bench.open('page-b', ['B.one', 'B.two', 'B.three', 'shared.key']);

    expect(bench.registry.count, 2,
        reason: 'two subscriptions is two subscriptions; the tick engine '
            'selects per subscription, so a count that collapses them would '
            'hide one page from every sweep');
    expect(bench.registry.names, {'page-a', 'page-b'});
    expect(bench.registry.handles.length, 6,
        reason: 'six distinct keys across the two, with `shared.key` counted '
            'once — the handle is the key\'s identity, not the '
            'subscription\'s');
  });

  test('an unsubscribed key stops delivering', () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    bench.open('page-a', ['A.one']);
    bench.open('page-b', ['B.one']);
    final handleB = bench.handles.handleFor('B.one');

    expect(bench.registry.remove('page-a'), isTrue,
        reason: 'removing a live subscription reports that it removed one');

    bench.api.setValue('A.one', 1);
    bench.api.setValue('B.one', 2);
    await pumpEventQueue();

    final pending = bench.drained();
    expect(pending.containsKey('page-a'), isFalse,
        reason: 'a registry that drops its map entry without detaching the '
            'listener keeps pushing values into a buffer for a subscription '
            'the client has already forgotten — the leak this case exists to '
            'catch, and the one that only shows itself after a shift of plant '
            'churn');
    expect(pending['page-b'], {handleB},
        reason: 'removing one subscription must detach exactly its own '
            'listeners: the other page is still on screen');
  });

  test('removing a subscription twice is not an error', () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    bench.open('page-a', ['A.one']);

    expect(bench.registry.remove('page-a'), isTrue);
    expect(bench.registry.remove('page-a'), isFalse,
        reason: 'the second removal is a no-op, not a throw: a client that '
            'unsubscribes twice after a resync it did not finish applying is '
            'confused, not hostile');
    expect(bench.registry.count, 0);

    bench.api.setValue('A.one', 1);
    await pumpEventQueue();
    expect(bench.drained(), isEmpty,
        reason: 'and the second removal must not double-detach some other '
            'subscription\'s listener by index');
  });

  test('handle table size is unchanged by subscribe/unsubscribe', () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    bench.open('page-a', ['A.one', 'A.two']);
    final afterFirst = bench.handles.size;
    expect(afterFirst, 2);

    bench.registry.remove('page-a');
    expect(bench.handles.size, afterFirst,
        reason: 'handles are permanent (03-CONTEXT): the registry releases '
            'subscriptions and listeners, never handles. Reuse would point a '
            'reconnecting panel at whichever tag inherited its integer');

    bench.open('page-a-again', ['A.one', 'A.two']);
    expect(bench.handles.size, afterFirst,
        reason: 'and re-subscribing the same keys mints nothing new — same '
            'key, same integer, which is what keeps the encode-once body '
            'byte-identical across clients');
  });

  test('each subscription owns its own seq', () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    final a = bench.open('page-a', ['A.one']);
    final b = bench.open('page-b', ['B.one']);

    expect(a.seq, 0);
    expect(b.seq, 0);
    expect(a.nextSeq(), 1);
    expect(a.nextSeq(), 2);
    expect(b.nextSeq(), 1,
        reason: 'a shared counter would make every page see gaps in its own '
            'sequence whenever another page moved, and a gap is the client\'s '
            'signal to throw its cache away and resync');
    expect(a.epoch, isNot(b.epoch));
  });

  test('the registry hands out views a caller cannot mutate', () async {
    final bench = _Bench();
    addTearDown(bench.dispose);

    bench.open('page-a', ['A.one']);

    expect(() => bench.registry.names.add('invented'), throwsUnsupportedError,
        reason: '`registeredMethods`\' spirit: a read-only view of server '
            'state, so an inspection cannot become a mutation by accident');
    expect(() => bench.registry.handles.add(99), throwsUnsupportedError);
  });

  test('closing a session drops the server-wide subscription count to zero',
      () async {
    final sessions = SessionRegistry();
    final benches = <_Bench>[];
    final live = <RelaySession>[];

    for (var i = 0; i < 2; i++) {
      final pair = channelPair();
      final bench = _Bench();
      benches.add(bench);
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: bench.api,
        config: ServerConfig(),
        handles: bench.handles,
        buffer: bench.buffer,
      );
      live.add(session);
      sessions.add(session);
      session.subscriptions
          .put(SubscriptionState(sub: 'page-$i', epoch: 'epoch-$i'));
      session.subscriptions
          .put(SubscriptionState(sub: 'other-$i', epoch: 'epoch-$i'));
    }
    addTearDown(() async {
      for (final bench in benches) {
        await bench.dispose();
      }
      await sessions.dispose();
    });

    expect(sessions.subscriptionCount, 4,
        reason: 'the server-wide count is the sum over live sessions — what '
            '03-11 reads to prove a kill cycle left nothing behind');

    await live.first.close(1000, 'test over');
    expect(live.first.subscriptions.count, 0,
        reason: 'teardown clears the session\'s own subscriptions, or a '
            'closed session keeps a listener on every key it was watching');

    sessions.remove(live.first);
    expect(sessions.sessionCount, 1);
    expect(sessions.subscriptionCount, 2,
        reason: 'the surviving session\'s subscriptions are untouched by its '
            'neighbour\'s death');

    await live.last.close(1000, 'test over');
    sessions.remove(live.last);
    expect(sessions.subscriptionCount, 0);
  });
}
