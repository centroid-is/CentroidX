/// The subscribe half of the contract: what a page is promised when it starts
/// watching a key.
///
/// Cases derive from CONTEXT D-01 — `listen` is the primary read path, a
/// `ValueListenable` over a batch-applied store, and `subscribe` is the derived
/// compatibility adapter for stream-consuming code — and from the promise the
/// whole project exists to keep: an operator can always trust what the screen
/// shows. Each case below is one way that trust can be lost.
///
/// The structure follows dart-lang/http's `http_client_conformance_tests`
/// (umbrella + per-area sub-suite + factory parameter), with one deliberate
/// divergence. That suite inlines its assertions inside `test()` bodies, so its
/// cases cannot be invoked outside the runner and therefore cannot themselves
/// be proven to catch anything. Here every case is a named top-level function
/// and registration is separate, so `test/sabotage_subscribe_test.dart` can run
/// a case against a deliberately damaged implementation and assert that it
/// fails — the suite's teeth are regression-tested, not assumed.
///
/// This file imports no implementation. The factory passed to
/// [runSubscribeContract] is the only coupling to one, which is what lets one
/// suite judge the server-side implementation, the client-side implementation,
/// and later either of them through a fault-injection proxy.
///
/// Every await is wrapped in [within]. An implementation that goes silent must
/// fail in 200 ms with a message naming the property an operator lost, not hang
/// until the runner's timeout names a file.
library;

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import 'check.dart';
import 'harness.dart';

/// A motor speed on the pre-freezer conveyor line: the ordinary case, a number
/// an operator reads off a mimic.
const _speedKey = 'ST101.CN01.MOT01.speed';

/// A second live key, used as a barrier: awaiting a notification for a key that
/// *should* fire is how a case proves a key that should *not* fire stayed
/// silent, without sleeping for an arbitrary interval.
const _otherKey = 'ST201.CN04.MOT01.speed';

/// A key no source in this suite ever delivers — a tag mistyped into a page
/// config, or one whose first batch has simply not landed yet.
const _missingKey = 'ST301.CN17.VLV02.stat';

/// A key that exists, is delivered, and is then retired: the tag renamed or
/// deleted in the PLC under a page that still binds it. Distinct from
/// [_missingKey], and the contract requires that they read differently.
const _deletedKey = 'ST301.CN18.VLV01.stat';

/// A freshly subscribed key carries its current value, and carries it good.
///
/// The first thing an operator sees when a page opens.
Future<void> checkListenDeliversCurrentValue(StateManApi api) async {
  final plant = harnessOf(api);

  final node = api.listen(_speedKey);
  final seen = observe(node);
  plant.setValue(_speedKey, 1450);

  await within(seen.next, 'the first value for a subscribed key');

  expect(node.value.asInt, 1450,
      reason: 'the handle a page holds must carry the number the source has — '
          'an operator opening a page sees readings, not placeholders');
  expect(node.value.quality.isGood, isTrue,
      reason: 'a value delivered over a healthy link must arrive good; a page '
          'of grey boxes on a working plant teaches operators to ignore '
          'quality, which is the one thing they must never learn');
}

/// A listener attached before a change is notified of it, and the handle
/// carries the new value when it fires.
///
/// The property an implementation loses when a subscription dies while the link
/// stays up: the page keeps rendering the last number it saw, and nothing on
/// screen says so.
Future<void> checkListenDeliversSubsequentChanges(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  // The seed has to be *there* before a listener attaches, or the first
  // notification this case sees is the seed's own and the assertion below reads
  // 1450 against an implementation that delivered 1600 perfectly. Free
  // in-process; a real wait only where the value crosses a boundary.
  await arrived(api, _speedKey);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  plant.setValue(_speedKey, 1600);
  await within(seen.next, 'the notification for a key that changed upstream');

  expect(node.value.asInt, 1600,
      reason: 'the listener fired but the handle still carried the old '
          'reading — a page would rebuild and redraw the stale number');
}

/// The stream adapter and the listenable path never disagree.
///
/// `subscribe` exists for code that consumes streams; it is a second *view* of
/// the store, never a second source of truth. Two consumers of one subscription
/// must both be served — a fan-out, not a queue that the first listener drains.
Future<void> checkSubscribeStreamMirrorsListen(StateManApi api) async {
  final plant = harnessOf(api);

  final node = api.listen(_speedKey);
  final seen = observe(node);
  final stream = api.subscribe(_speedKey);

  late final List<Future<List<DynamicValue>>> takers;
  try {
    takers = [stream.take(1).toList(), stream.take(1).toList()];
  } on StateError catch (error) {
    fail('subscribe() handed out a single-subscription stream ($error) — two '
        'widgets watching one key is the normal case, and the second one must '
        'not be refused');
  }

  plant.setValue(_speedKey, 1450);

  final first =
      await within(takers[0], 'the subscribe() stream reaching its listener');
  final second = await within(
      takers[1], 'the subscribe() stream reaching a second listener');
  await within(seen.next, 'the listen() handle seeing the same change');

  expect(first.single.asInt, 1450,
      reason: 'stream-consuming code must see the value the source has, or '
          'ported widgets show something different from new ones');
  expect(second.single, first.single,
      reason: 'both consumers of one subscription must receive the value — a '
          'compat adapter that serves only the first listener silently '
          'freezes every widget after it');
  expect(node.value, first.single,
      reason: 'the stream path and the listenable path disagreed about the '
          'current value; they are two views of one store, and two numbers for '
          'one tag on one page is the worst thing this API can do');
}

/// An unknown key degrades to a visibly untrustworthy value; it never throws
/// and never invents traffic. A key the source knows is *gone* reads
/// differently from one it simply has not delivered yet.
///
/// A key mistyped into a page config, or a tag renamed in the PLC after the
/// page was drawn, must take out that one box on the mimic — not the mimic.
///
/// The second half is the one an implementation is most likely to get wrong by
/// collapsing both into [Quality.errorConfig]. "The tag has been deleted, go
/// fix the page" and "the first batch has not landed yet" call for opposite
/// actions from the operator, and on a slow link every key on a page passes
/// through the second state for a round trip. An implementation that reports
/// them identically teaches operators that the one non-transient error code
/// heals on its own, after which nobody acts on the real one.
Future<void> checkUnknownKeyReportsConfigErrorNotThrow(StateManApi api) async {
  final plant = harnessOf(api);

  ValueListenable<DynamicValue>? node;
  Object? thrown;
  try {
    node = api.listen(_missingKey);
  } catch (error) {
    thrown = error;
  }
  expect(thrown, isNull,
      reason: 'listen() on a key the source does not have threw $thrown — one '
          'mistyped key in a page config must degrade to a bad-quality box, '
          'not crash the whole mimic');

  final unknown = node!;
  final quiet = observe(unknown);

  // A key the source has affirmatively been told is gone, to compare against.
  plant.setValue(_deletedKey, 1);
  final deleted = api.listen(_deletedKey);
  plant.dropKey(_deletedKey);

  final live = api.listen(_otherKey);
  final seen = observe(live);
  plant.setValues({_otherKey: 3});
  await within(seen.next, 'a batch reaching a key the source does have');

  expect(unknown.value.value, isNull,
      reason: 'an unknown key reported a value; a number rendered for a tag '
          'that does not exist is indistinguishable from a real reading');
  expect(unknown.value.quality.isGood, isFalse,
      reason: 'a key nothing has arrived for read as good quality — an '
          'operator would believe a box that has never had a value in it');
  expect(deleted.value.quality, Quality.errorConfig,
      reason: 'a key the source was told is gone must read as a configuration '
          'error: waiting will never fix a renamed tag, and the operator '
          'needs to be told to fix the page');
  expect(unknown.value.quality, isNot(Quality.errorConfig),
      reason: 'a key whose first batch has not arrived reads the same as a tag '
          'that has been deleted, so the two are indistinguishable on screen. '
          'One of them heals by itself and the other never will');
  expect(quiet.count, 0,
      reason: 'the source notified listeners of a key it cannot serve — a page '
          'would rebuild for a tag that will never have a value');
}

/// After `dispose`, a later change notifies nobody.
///
/// A disposed source that still fires keeps a closed page alive and rebuilding
/// for the rest of the session — the leak that outlives the widget that caused
/// it.
Future<void> checkDisposeStopsNotifications(StateManApi api) async {
  final plant = harnessOf(api);

  plant.setValue(_speedKey, 1450);
  final node = api.listen(_speedKey);
  final seen = observe(node);

  await within(api.dispose(), 'dispose() completing');

  plant.setValue(_speedKey, 1600);
  await within(Future<void>.delayed(Duration.zero),
      'the event loop turning after dispose');

  expect(seen.count, 0,
      reason: 'a disposed source still notified its listeners; every closed '
          'page would keep rebuilding for the rest of the session');
}

/// Every subscribe property, keyed by the sentence it asserts.
///
/// The key is the test name, so a failure in CI reads as the promise that was
/// broken rather than as a function identifier.
const subscribeChecks = <String, Check<StateManApi>>{
  'a subscribed key delivers its current value, good':
      checkListenDeliversCurrentValue,
  'a listener is notified of every change after it attaches':
      checkListenDeliversSubsequentChanges,
  'the subscribe() stream mirrors listen() and serves every listener':
      checkSubscribeStreamMirrorsListen,
  'an unknown key reports a configuration error instead of throwing':
      checkUnknownKeyReportsConfigErrorNotThrow,
  'a disposed source notifies nobody': checkDisposeStopsNotifications,
};

/// Registers the subscribe contract against implementations from [make].
///
/// One fresh instance per case, disposed by `addTearDown`, so an
/// implementation that leaks after dispose fails its own case rather than the
/// next one.
void runSubscribeContract(StateManApi Function() make) {
  group('subscribe', () {
    subscribeChecks.forEach((property, check) {
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
