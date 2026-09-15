// The link-level freshness verdict, on its own, before anything reads it.
//
// The behaviours pinned here are the three the library doc argues for, and
// each of them is a way the rig defect could come back:
//
//   * a direct station's object is a constant, so it cannot grey out;
//   * a gateway station's object is LIVE, so a value stream opened during an
//     outage reads the outage rather than a construction-time snapshot —
//     `viewFreshness` publishes transitions and only transitions, so an object
//     that merely forwarded the stream would tell a late reader nothing at all,
//     for ever;
//   * only transitions are re-published, so a reader can treat every event as
//     a change.

@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/value_freshness.dart';

void main() {
  group('a direct station', () {
    test('is never stale, and says it is not watching anything', () async {
      final freshness = ValueFreshness.fresh();
      addTearDown(freshness.dispose);

      expect(freshness.isStale, isFalse);
      // The anti-vacuity half: "not stale" is also true of an object nobody
      // wired, and this is what tells the two apart.
      expect(freshness.isWatchingLink, isFalse);
    });

    test('is one shared object, and one reader disposing cannot close it for '
        'the next', () async {
      // **Found by sabotage, not by design.** `ValueFreshness.fresh()` is a
      // singleton because `keyStreamProvider` watches the provider that hands
      // it out and Riverpod rebuilds a dependent when the value changes by
      // `==` — a new object per build re-opens every subscription on the panel
      // (measured: it doubled every subscribe count in
      // `key_stream_provider_test.dart`). Sharing it makes `dispose` a
      // question: one container tearing down would otherwise close the stream
      // every later container is about to listen to. Removing the guard that
      // answers it turned NOTHING red until this arm existed.
      final first = ValueFreshness.fresh();
      final second = ValueFreshness.fresh();
      expect(identical(first, second), isTrue,
          reason: 'a per-build object here is the subscription-churn defect');

      await first.dispose();

      var closed = false;
      final sub = second.changes.listen((_) {}, onDone: () => closed = true);
      addTearDown(sub.cancel);
      await _settle();

      expect(closed, isFalse,
          reason: 'one container\'s teardown closed the verdict stream every '
              'other container on this panel reads');
    });

    test('publishes a stream that never fires', () async {
      final freshness = ValueFreshness.fresh();
      final seen = <bool>[];
      final sub = freshness.changes.listen(seen.add);
      addTearDown(sub.cancel);

      await _settle();

      expect(seen, isEmpty);
      await freshness.dispose();
    });
  });

  group('a gateway station', () {
    test('takes the client\'s verdict as its seed', () {
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      // A panel that was ALREADY stale when this object was built — an operator
      // navigating to a new page in the middle of an outage. The transition
      // that made it stale happened before there was anything to hear it.
      final freshness = ValueFreshness.watching(
        stale: true,
        transitions: transitions.stream,
      );
      addTearDown(freshness.dispose);

      expect(freshness.isStale, isTrue);
      expect(freshness.isWatchingLink, isTrue);
    });

    test('follows the client in both directions', () async {
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      final freshness = ValueFreshness.watching(
        stale: false,
        transitions: transitions.stream,
      );
      addTearDown(freshness.dispose);
      final seen = <bool>[];
      final sub = freshness.changes.listen(seen.add);
      addTearDown(sub.cancel);

      transitions.add(true);
      await _settle();
      expect(freshness.isStale, isTrue, reason: 'the link went quiet');

      transitions.add(false);
      await _settle();
      expect(freshness.isStale, isFalse,
          reason: 'the view is showing the current connection again');

      expect(seen, [true, false]);
    });

    test('republishes transitions only, never repeats', () async {
      // A reader gates a stream on this; an object that re-announced the same
      // verdict would make it re-publish an error every time the client
      // repeated itself.
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      final freshness = ValueFreshness.watching(
        stale: false,
        transitions: transitions.stream,
      );
      addTearDown(freshness.dispose);
      final seen = <bool>[];
      final sub = freshness.changes.listen(seen.add);
      addTearDown(sub.cancel);

      transitions
        ..add(false)
        ..add(true)
        ..add(true)
        ..add(false);
      await _settle();

      expect(seen, [true, false]);
    });

    test('an errored verdict stream leaves the last verdict standing',
        () async {
      // And does not surface as an unhandled zone error, which is how this
      // would fail somebody else's widget test rather than its own.
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      final freshness = ValueFreshness.watching(
        stale: true,
        transitions: transitions.stream,
      );
      addTearDown(freshness.dispose);

      transitions.addError(StateError('the verdict stream broke'));
      await _settle();

      expect(freshness.isStale, isTrue);
    });

    test('stops following once disposed', () async {
      final transitions = StreamController<bool>.broadcast();
      addTearDown(transitions.close);
      final freshness = ValueFreshness.watching(
        stale: false,
        transitions: transitions.stream,
      );

      await freshness.dispose();
      transitions.add(true);
      await _settle();

      expect(freshness.isStale, isFalse,
          reason: 'a disposed verdict must not keep adopting a client it is '
              'no longer wired to');
    });
  });

  group('the reason a withheld value carries', () {
    test('names the key and says the panel has not heard from the gateway', () {
      const stale = StaleValues('CN01.Temp');

      expect(stale.key, 'CN01.Temp');
      expect('$stale', contains('CN01.Temp'));
      expect('$stale', contains('gateway'));
    });

    test('does not send anybody to the switch cupboard', () {
      // 15-08's pinned property, in the other direction: this failure is about
      // what the PANEL knows, and the chip and the Transport card own the
      // diagnosis. A sentence here about cables competes with theirs.
      const stale = StaleValues('CN01.Temp');

      expect('$stale'.toLowerCase(), isNot(contains('cable')));
      expect('$stale'.toLowerCase(), isNot(contains('switch')));
    });
  });
}

/// A few turns of the loop: a broadcast controller delivers asynchronously.
Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
