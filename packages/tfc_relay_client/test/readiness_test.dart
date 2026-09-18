/// The re-armable readiness barrier every API method awaits.
///
/// Source: 04-RESEARCH Finding 6. The shared contract suite's entry point is
/// `void runStateManContract(StateManApi Function() make, {...})` — `make`
/// returns an implementation **synchronously**, once per case, with no async
/// factory hook and no `arrived()` in the signature. So `RemoteStateMan` has
/// to be constructible before a socket exists, which means the constructor
/// starts the supervisor and every method waits on a barrier.
///
/// That is not a test workaround, it is the production shape: a panel in the
/// packing hall is powered from the same contactor as everything else, so it
/// boots while the gateway is still starting, and a client that threw at
/// construction would need the operator to restart the app in the right order.
/// The barrier must also **re-arm**, because the link dies (gateway restart,
/// switch reboot, Wi-Fi) and the next call after that has to wait for the new
/// connection rather than sail through on the old one's completion.
@Tags(['meta'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_relay_client/src/readiness_barrier.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

/// How long a caller is watched for to conclude it really is waiting. Well
/// above this transport's 50–100 ms round trip (04-RESEARCH Finding 8) so the
/// answer is "it is blocked", not "it was busy".
const Duration _watchFor = Duration(milliseconds: 300);

void main() {
  group('before the first connection', () {
    test('a caller waits while there is no link', () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);

      final outcome = await within(
        Future.any(<Future<String>>[
          barrier.ready.then((_) => 'let through'),
          Future<String>.delayed(_watchFor, () => 'still waiting'),
        ]),
        'the pending-barrier race settling',
        budget: _watchFor * 4,
      );

      expect(
        outcome,
        'still waiting',
        reason: 'a page that reads a key before the gateway is reachable must '
            'wait for a real connection, not be handed the answer of a link '
            'that does not exist',
      );
      expect(barrier.isOpen, isFalse);
    });

    test('the waiter completes when the link comes up', () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);

      final waiting = barrier.ready;
      barrier.open();

      await within(waiting, 'the waiter completing on entry to ready',
          budget: _watchFor);
      expect(barrier.isOpen, isTrue);
    });

    test('opening twice is harmless', () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);

      barrier.open();
      barrier.open();

      await within(barrier.ready, 'the barrier still being open',
          budget: _watchFor);
      expect(
        barrier.isOpen,
        isTrue,
        reason: 'the supervisor re-enters ready after every resync; a barrier '
            'that threw on the second entry would take the panel down on the '
            'first reconnect',
      );
    });
  });

  group('on a healthy link', () {
    test('an open barrier costs a waiter a microtask, not a tick', () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);
      barrier.open();

      var arrived = false;
      unawaited(barrier.ready.then((_) => arrived = true));
      await Future<void>.microtask(() {});

      expect(
        arrived,
        isTrue,
        reason: 'every read and every write on a healthy link goes through '
            'this barrier first; if it cost a timer, a 1500-key page would pay '
            'for one per value',
      );
    });
  });

  group('when the link drops', () {
    test('a caller who already completed stays completed across a rearm',
        () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);

      final firstCaller = barrier.ready;
      barrier.open();
      await within(firstCaller, 'the first caller completing',
          budget: _watchFor);

      barrier.rearm();

      var laterCallerArrived = false;
      // Still pending when the tear-down disposes the barrier under it, which
      // is the ordinary shutdown path: a call waiting for a link that never
      // came back. Its error is the subject of the `at shutdown` group, so it
      // is answered rather than left to the ambient handler here.
      unawaited(barrier.ready
          .then((_) => laterCallerArrived = true)
          .catchError((Object _) => false));
      await pumpEventQueue();

      expect(
        laterCallerArrived,
        isFalse,
        reason: 'the call that arrives after the link died has to wait for the '
            'new connection, or it writes into a socket that is gone',
      );
      // The proof that `rearm` swaps the completer instead of resetting one: a
      // future cannot un-complete, so anyone already through stays through.
      await within(firstCaller, 'the completed caller staying completed',
          budget: _watchFor);
      expect(barrier.isOpen, isFalse);
    });

    test('rearming a barrier nobody opened leaves its waiters alone', () async {
      final barrier = ReadinessBarrier();
      addTearDown(barrier.dispose);

      final waiting = barrier.ready;
      barrier.rearm();
      barrier.open();

      await within(
        waiting,
        'the waiter from before the rearm completing anyway',
        budget: _watchFor,
      );
      expect(
        barrier.isOpen,
        isTrue,
        reason: 'the supervisor can enter down twice in a row; a rearm that '
            'swapped a pending completer would strand every call already '
            'waiting on it — the panel would hang, not retry',
      );
    });
  });

  group('at shutdown', () {
    test('dispose completes waiters with an error naming the disposal',
        () async {
      final barrier = ReadinessBarrier();
      final waiting = barrier.ready;

      barrier.dispose();

      await expectLater(
        waiting,
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('disposed'),
          ),
        ),
        reason: 'a page closing while a read is in flight must get an error it '
            'can show, not a future that never settles and a spinner that '
            'never stops',
      );
    });

    test('disposing with nobody waiting raises nothing on the ambient handler',
        () async {
      final zoneErrors = <Object>[];

      await runZonedGuarded<Future<void>>(() async {
        ReadinessBarrier().dispose();
        await pumpEventQueue();
      }, (Object error, StackTrace stack) => zoneErrors.add(error))!;

      expect(
        zoneErrors,
        isEmpty,
        reason: 'closing a page that never read anything is the common case; '
            'an unhandled error there gets attributed to whatever runs next',
      );
    });

    test('a caller arriving after dispose is told, not left hanging', () async {
      final barrier = ReadinessBarrier();
      barrier.dispose();

      await expectLater(barrier.ready, throwsA(isA<StateError>()));
    });
  });
}
