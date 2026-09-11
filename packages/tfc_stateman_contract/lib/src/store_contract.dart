/// The store half of the contract: what an arriving batch is allowed to cost.
///
/// Cases come from one measured scenario, recorded in CONTEXT D-01 and pinned
/// as CLI-06: **1500 keys on one page over a slow connection**. The rejected
/// design — one broadcast stream per key — pays an event per key per update and
/// wakes every widget whether its value moved or not. The chosen design applies
/// a batch in one synchronous loop over a single map and notifies only where
/// the value genuinely changed, so k changed keys cost k rebuilds rather than
/// n.
///
/// That is a promise about a *count*, and a count is only enforceable if
/// something counts it. These three cases are that something. They are what
/// stops an implementation from being correct and unusable at the same time: a
/// source that delivers every right value and rebuilds the world on every tick
/// passes every case in `subscribe_contract.dart` and turns a mimic into a
/// slideshow.
///
/// As with every file in this suite, no implementation is imported — the
/// factory passed to [runStoreContract] is the only coupling — and every await
/// is wrapped in [within] so silence fails fast and by name.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// The key under test in the unchanged-value case.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key, used as a barrier: awaiting a notification that *should*
/// arrive is how a case proves another one did not, with no arbitrary sleep.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// A key that never receives a value, for the enumeration case.
const _neverDeliveredKey = 'ST301.CN17.VLV02.stat';

/// How many keys the batch case applies, and which of them actually move.
///
/// A hundred is enough to make an n-notification implementation unmistakable
/// while keeping the case readable; the real page has fifteen times as many.
const _batchSize = 100;
const _changedIndices = [7, 42, 91];

/// Re-delivering a value equal to the current one notifies nobody.
///
/// The single guard the k-of-n property rests on. Upstream sources re-send
/// unchanged readings constantly — a poll cycle, a resubscribe, a snapshot
/// after reconnect — and every one of them must be free.
Future<void> checkUnchangedValueNotifiesNobody(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // Counting cannot start until the seed has landed: an in-flight seed arrives
  // *after* the observer attaches and is then indistinguishable from the
  // re-delivery this case is asserting costs nothing.
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  plant.setValue(_speedKey, 1450);

  final other = api.listen(_otherKey);
  final barrier = observe(other);
  plant.setValue(_otherKey, 3);
  await within(barrier.next, 'a genuinely changed key notifying');

  expect(seen.count, 0,
      reason: 're-delivering an identical reading rebuilt the page; at 1500 '
          'keys every poll cycle would cost 1500 rebuilds for no new '
          'information, which is exactly what the value store exists to '
          'prevent (CLI-06)');
  expect(node.value.asInt, 1450,
      reason: 'the value must still be the one that was delivered — silence '
          'means nothing changed, not that the value was dropped');
}

/// A batch where k of n keys changed costs exactly k notifications.
///
/// The scaling property stated as a number. An implementation that notifies per
/// key in the batch, or that stamps arrivals in a way that defeats the equality
/// guard, fails here rather than in production on the busiest page in the
/// plant.
Future<void> checkBatchNotifiesOnlyChangedKeys(StateManApi api) async {
  final plant = harnessOf(api);

  final keys = [
    for (var i = 0; i < _batchSize; i++)
      'ST101.CN${i.toString().padLeft(2, '0')}.MOT01.speed',
  ];
  final initial = <String, Object?>{
    for (var i = 0; i < _batchSize; i++) keys[i]: 1000 + i,
  };
  plant.setValues(initial);

  // Every seeded key, not just one: the promise under test is about a count, so
  // a single seed value still in flight when the observers attach is counted
  // against the batch under test. Waiting per key rather than on the last one
  // costs nothing in-process and does not assume the seed arrived as one batch,
  // which is a promise about the *source*, not something this case may lean on
  // while measuring the source.
  for (final key in keys) {
    await arrived(api, key);
  }

  final watched = [for (final key in keys) observe(api.listen(key))];

  final next = <String, Object?>{
    ...initial,
    for (final i in _changedIndices) keys[i]: 2000 + i,
  };
  plant.setValues(next);

  for (final i in _changedIndices) {
    await within(watched[i].next,
        'the notification for ${keys[i]}, whose value changed in the batch');
  }

  final total = watched.fold(0, (sum, seen) => sum + seen.count);
  expect(total, _changedIndices.length,
      reason: 'a $_batchSize-key batch carrying ${_changedIndices.length} real '
          'changes cost $total notifications; at 1500 keys on one page over a '
          'slow link that difference is a responsive mimic versus a slideshow');

  for (final i in _changedIndices) {
    expect(api.listen(keys[i]).value.asInt, 2000 + i,
        reason: 'a key that notified must carry its new reading');
  }
}

/// `keys` lists what the source can serve, and nothing else.
///
/// It feeds the page editor's picker and the diagnostics page. Omitting a
/// served key hides a tag that is visibly on screen; listing an unserved one
/// sends whoever draws the next page to bind a tag that will never produce a
/// value.
Future<void> checkKeysEnumeratesSubscribedKeys(StateManApi api) async {
  final plant = harnessOf(api);

  final node = api.listen(_speedKey);
  final seen = observe(node);
  plant.setValue(_speedKey, 1450);
  await within(seen.next, 'the value for the key under test arriving');

  expect(api.keys, contains(_speedKey),
      reason: 'a key the source is actively serving was missing from its own '
          'key list — the picker cannot find a tag that is on the screen');
  expect(api.keys, isNot(contains(_neverDeliveredKey)),
      reason: 'the key list offered a key the source has never served; a page '
          'bound to it would show a permanently empty box that looks like a '
          'plant fault');
}

/// Every store property, keyed by the sentence it asserts.
const storeChecks = <String, Check<StateManApi>>{
  'an unchanged value notifies nobody': checkUnchangedValueNotifiesNobody,
  'a batch notifies once per genuinely changed key, and no more':
      checkBatchNotifiesOnlyChangedKeys,
  'keys lists what the source can serve and nothing else':
      checkKeysEnumeratesSubscribedKeys,
};

/// Registers the store contract against implementations from [make].
///
/// One fresh instance per case, disposed by `addTearDown` — a notification
/// count is only meaningful when nothing from a previous case is still
/// attached.
void runStoreContract(StateManApi Function() make) {
  group('store', () {
    storeChecks.forEach((property, check) {
      test(property, () async {
        final api = make();
        addTearDown(api.dispose);
        // The link, before the property. On an in-process source this is a
        // synchronous read and nothing more; behind a socket it is where the
        // connect, the handshake and the first subscribe come due, and leaving
        // them inside the case's own budget made the first check in this suite
        // a measurement of the transport (`harness.dart`'s [linkUp]).
        await linkUp(api);
        await check(api);
      });
    });
  });
}
