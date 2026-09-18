/// The store behind `listen(key)` — CONTEXT D-01's primary read path, chosen
/// for one measured scenario: 1500 keys on one page over a slow link. Every
/// case below states the operational consequence in its `reason:`, because the
/// properties here are the ones that make that page survivable (CLI-06), not
/// micro-optimizations.
///
/// No clock and no I/O appear in these tests: the sequence number is a
/// parameter, exactly as `ConflatingSendBuffer.poll(int nowMs)` takes its
/// timestamp.
library;

import 'package:test/test.dart';
// Through the barrel on purpose: if the export is ever dropped, the store
// stops being reachable from the package's public entry point and this file
// stops compiling.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

/// 100 keys, small enough to run instantly and large enough that a per-key
/// notification cost would be visible in the count.
const _n = 100;

Map<String, DynamicValue> _batch(int Function(int i) valueOf) =>
    {for (var i = 0; i < _n; i++) 'K$i': DynamicValue.of(valueOf(i))};

void main() {
  group('nodes and the not-yet-known value', () {
    test('node() returns the same instance for a key, forever', () {
      final store = ValueStore();
      final first = store.node('CN01.MOTOR.RUN');
      expect(identical(store.node('CN01.MOTOR.RUN'), first), isTrue,
          reason: 'a widget holds the node it was handed; a second node for '
              'the same key would silently stop receiving updates');
    });

    test('a node is a ValueListenable of DynamicValue', () {
      expect(ValueStore().node('A'), isA<ValueListenable<DynamicValue>>(),
          reason: 'the Phase 4 builder widget listens to this interface with '
              'no adapter object per key');
    });

    test('reading a never-updated key yields a null value nobody may trust',
        () {
      final node = ValueStore().node('MISSING');
      expect(node.value.value, isNull,
          reason: 'a fabricated good zero would render as a plausible reading '
              'for a tag that does not exist');
      expect(node.value.quality, Quality.uncertainNotYetKnown,
          reason: 'not-yet-known is untrustworthy and must never throw to '
              'read, but it is not a configuration error');
    });

    test('not-yet-known is distinguishable from a deleted tag', () {
      // WR-02. On a slow link every key on a page is not-yet-known for the
      // first round trip. Reporting that as errorConfig — "the tag is gone,
      // fix the page" — teaches operators that the one non-transient error
      // code heals on its own.
      expect(notYetKnown.quality, isNot(Quality.errorConfig));
      expect(notYetKnown.quality.isGood, isFalse,
          reason: 'nothing has arrived, so nothing may be believed');
      expect(notYetKnown.quality.isUncertain, isTrue,
          reason: 'waiting fixes this one, which is what uncertain means');
    });

    test('peek is null until a value has actually arrived', () {
      final store = ValueStore();
      expect(store.peek('A'), isNull, reason: 'never seen');
      store.node('A');
      expect(store.peek('A'), isNull,
          reason: 'creating a node is subscribing, not knowing a value');
      store.applyBatch({'A': DynamicValue.of(7)});
      expect(store.peek('A')!.asInt, 7);
    });

    test('keys lists every key the store holds a node for', () {
      final store = ValueStore();
      store.node('B');
      store.applyBatch({'A': DynamicValue.of(1)});
      expect(store.keys, containsAll(<String>['A', 'B']));
      expect(store.keys, hasLength(2));
    });
  });

  group('notification counts — the k-of-n property (CLI-06)', () {
    test('a two-key batch notifies each of two listeners exactly once', () {
      final store = ValueStore();
      var a = 0;
      var b = 0;
      store.node('A').addListener(() => a++);
      store.node('B').addListener(() => b++);
      store.applyBatch({'A': DynamicValue.of(1), 'B': DynamicValue.of(2)});
      expect([a, b], [1, 1],
          reason: 'one notification per changed key, not one per batch entry '
              'per listener');
    });

    test('a $_n-key batch with 3 changed values produces exactly 3 '
        'notifications', () {
      final store = ValueStore();
      var notifications = 0;
      for (var i = 0; i < _n; i++) {
        store.node('K$i').addListener(() => notifications++);
      }

      store.applyBatch(_batch((i) => 0));
      expect(notifications, _n,
          reason: 'first sight of a key is genuine news for every key');

      notifications = 0;
      store.applyBatch(_batch((i) => i < 3 ? 1 : 0));
      expect(notifications, 3,
          reason: 'a slow link with 1500 keys on one page costs k rebuilds, '
              'not 1500 — this is the property the read path was chosen for');
    });

    test('re-applying values equal to the current ones notifies nobody', () {
      final store = ValueStore();
      var notifications = 0;
      for (var i = 0; i < _n; i++) {
        store.node('K$i').addListener(() => notifications++);
      }
      store.applyBatch(_batch((i) => i));
      notifications = 0;

      store.applyBatch(_batch((i) => i));
      expect(notifications, 0,
          reason: 'an unchanged poll result must cost zero rebuilds; this is '
              'why DynamicValue is immutable with structural equality');
    });

    test('quality alone changing is a change', () {
      final store = ValueStore();
      var notifications = 0;
      store.node('A').addListener(() => notifications++);
      store.applyBatch({'A': DynamicValue.of(42)});
      store.applyBatch({
        'A': DynamicValue.of(42, quality: Quality.badStale),
      });
      expect(notifications, 2,
          reason: 'the number did not move but its trustworthiness did — the '
              'stale badge is exactly what an operator needs to see');
    });

    test('re-applying the identical instance notifies nobody', () {
      final store = ValueStore();
      var notifications = 0;
      store.node('A').addListener(() => notifications++);
      final v = DynamicValue.of(1);
      store.applyBatch({'A': v});
      notifications = 0;
      store.applyBatch({'A': v});
      expect(notifications, 0,
          reason: 'the identity fast path spares a deep structural compare on '
              'a re-sent object graph');
    });

    test('listeners run synchronously: the counter is final when applyBatch '
        'returns', () async {
      final store = ValueStore();
      var count = 0;
      store.node('A').addListener(() => count++);
      store.applyBatch({'A': DynamicValue.of(1)});
      expect(count, 1,
          reason: 'the batch is applied in one loop; nothing is scheduled, so '
              'a frame never renders a value the store has already replaced');
      await Future<void>.delayed(Duration.zero);
      expect(count, 1, reason: 'and nothing arrives late on the event loop');
    });
  });

  group('listener registration', () {
    test('a listener added twice is notified twice; removing once leaves one',
        () {
      final store = ValueStore();
      var count = 0;
      void listener() => count++;
      store.node('A').addListener(listener);
      store.node('A').addListener(listener);
      store.applyBatch({'A': DynamicValue.of(1)});
      expect(count, 2, reason: 'registrations are counted, not deduplicated');

      count = 0;
      store.node('A').removeListener(listener);
      store.applyBatch({'A': DynamicValue.of(2)});
      expect(count, 1, reason: 'removeListener drops one registration');
    });

    test('removeListener stops notifications', () {
      final store = ValueStore();
      var count = 0;
      void listener() => count++;
      store.node('A').addListener(listener);
      store.node('A').removeListener(listener);
      store.applyBatch({'A': DynamicValue.of(1)});
      expect(count, 0);
    });

    test('removing a listener that was never added is a no-op', () {
      final node = ValueStore().node('A');
      expect(() => node.removeListener(() {}), returnsNormally,
          reason: 'teardown paths must not need bookkeeping to be safe');
    });

    test('a listener that removes itself mid-notification does not corrupt '
        'the run', () {
      final store = ValueStore();
      final node = store.node('A');
      var selfCount = 0;
      var otherCount = 0;
      late final VoidCallback once;
      once = () {
        selfCount++;
        node.removeListener(once);
      };
      node.addListener(once);
      node.addListener(() => otherCount++);

      store.applyBatch({'A': DynamicValue.of(1)});
      store.applyBatch({'A': DynamicValue.of(2)});
      expect(selfCount, 1, reason: 'the self-removing listener ran once');
      expect(otherCount, 2,
          reason: 'a widget disposing itself inside a rebuild must not skip '
              'the next listener in the list');
    });
  });

  group('sequence bookkeeping — once per batch, not once per key', () {
    test('an in-order batch is BatchOk', () {
      final store = ValueStore();
      expect(store.applyBatch({'A': DynamicValue.of(1)}, seq: 4),
          isA<BatchOk>(),
          reason: 'the first seq seen sets the baseline, it is not a gap');
      expect(
          store.applyBatch({'A': DynamicValue.of(2)}, seq: 5), isA<BatchOk>());
    });

    test('a skipped sequence is reported once for the whole batch, and the '
        'values are still applied', () {
      final store = ValueStore();
      store.applyBatch({'A': DynamicValue.of(1)}, seq: 2);

      final verdict = store.applyBatch({
        'A': DynamicValue.of(10),
        'B': DynamicValue.of(20),
        'C': DynamicValue.of(30),
      }, seq: 5);

      expect(verdict, isA<BatchSeqGap>(),
          reason: 'a lost batch means the cache may be wrong; the client '
              'resyncs on this verdict (CLI-03)');
      final gap = verdict as BatchSeqGap;
      expect(gap.expected, 3);
      expect(gap.received, 5,
          reason: 'both numbers travel so the log says how much was lost');
      expect([store.peek('A')!.asInt, store.peek('B')!.asInt], [10, 20],
          reason: 'the values in hand are newer than what was cached; '
              'discarding them would show older data, not safer data');
    });

    test('the next in-order batch after a gap is BatchOk again', () {
      final store = ValueStore();
      store.applyBatch(const {}, seq: 2);
      store.applyBatch(const {}, seq: 5);
      expect(store.applyBatch(const {}, seq: 6), isA<BatchOk>(),
          reason: 'one lost batch reports one gap, not a gap on every batch '
              'thereafter');
    });

    test('a replayed old batch is reported and does not rewind the '
        'expectation', () {
      final store = ValueStore();
      store.applyBatch(const {}, seq: 4);
      final replay = store.applyBatch(const {}, seq: 2) as BatchReplay;
      expect([replay.lastApplied, replay.received], [4, 2],
          reason: 'a re-delivery is a re-delivery of 2, not a batch that is '
              'late for 5');
      expect(store.applyBatch(const {}, seq: 5), isA<BatchOk>(),
          reason: 'the replay must not turn the next legitimate batch into a '
              'false gap');
    });

    test('a replayed batch does not overwrite newer cached values', () {
      // CR-02. The operator reads the number off the mimic, not the verdict.
      // A duplicate frame carrying seq 1 after seq 2 was applied used to put
      // a reading from two batches ago back on screen under good quality.
      final store = ValueStore();
      store.applyBatch({'k': DynamicValue.of(10)}, seq: 1);
      store.applyBatch({'k': DynamicValue.of(20)}, seq: 2);

      final verdict = store.applyBatch({'k': DynamicValue.of(10)}, seq: 1);

      expect(verdict, isA<BatchReplay>());
      expect(store.peek('k')!.asInt, 20,
          reason: 'the cached value is newer than the replayed one; the '
              'F18 rule discards the old frame rather than displaying it');
    });

    test('a replayed batch notifies nobody', () {
      final store = ValueStore();
      store.applyBatch({'k': DynamicValue.of(20)}, seq: 2);
      var count = 0;
      store.node('k').addListener(() => count++);

      store.applyBatch({'k': DynamicValue.of(10)}, seq: 1);

      expect(count, 0,
          reason: 'a discarded batch changes nothing, so no widget rebuilds');
    });

    test('a duplicate of the batch just applied is a replay', () {
      // The common case: the same frame delivered twice, not an old one.
      final store = ValueStore();
      store.applyBatch({'k': DynamicValue.of(1)}, seq: 3);
      expect(store.applyBatch({'k': DynamicValue.of(1)}, seq: 3),
          isA<BatchReplay>(),
          reason: 'seq 3 was already applied; re-applying it is not progress');
    });

    test('batches without a seq never report a gap', () {
      final store = ValueStore();
      expect(store.applyBatch({'A': DynamicValue.of(1)}), isA<BatchOk>());
      store.applyBatch(const {}, seq: 7);
      expect(store.applyBatch({'A': DynamicValue.of(2)}), isA<BatchOk>(),
          reason: 'an unsequenced batch is not part of the sequence and must '
              'not disturb its bookkeeping');
      expect(store.applyBatch(const {}, seq: 8), isA<BatchOk>());
    });
  });

  group('resync and teardown', () {
    test('clear() drops cached values and keeps node identity', () {
      final store = ValueStore();
      final node = store.node('A');
      store.applyBatch({'A': DynamicValue.of(1)});

      store.clear();

      expect(identical(store.node('A'), node), isTrue,
          reason: 'a resync must not orphan the node a widget is listening '
              'to — it would go dark for the rest of the session');
      expect(store.peek('A'), isNull, reason: 'the cache is discarded');
      expect(node.value.quality, Quality.uncertainNotYetKnown,
          reason: 'after a resync starts, nothing is known yet');
    });

    test('clear() notifies listeners of keys that held a value', () {
      final store = ValueStore();
      var count = 0;
      store.node('A').addListener(() => count++);
      store.node('B').addListener(() => count++);
      store.applyBatch({'A': DynamicValue.of(1)});
      count = 0;

      store.clear();
      expect(count, 1,
          reason: 'the screen showing a value must learn it is no longer '
              'known; B never had one, so it is not news');
    });

    test('clear() resets sequence bookkeeping', () {
      final store = ValueStore();
      store.applyBatch(const {}, seq: 90);
      store.clear();
      expect(store.applyBatch(const {}, seq: 1), isA<BatchOk>(),
          reason: 'a resync restarts the stream; the server numbering from '
              'scratch is not a gap');
    });

    test('dispose() drops every listener', () {
      final store = ValueStore();
      var count = 0;
      store.node('A').addListener(() => count++);
      store.dispose();
      store.applyBatch({'A': DynamicValue.of(1)});
      expect(count, 0,
          reason: 'a torn-down page must not keep rebuilding widgets that no '
              'longer exist');
    });
  });
}
