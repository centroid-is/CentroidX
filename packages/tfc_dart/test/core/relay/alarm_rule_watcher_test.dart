/// `AlarmRuleWatcher`: one alarm rule, watched on backend main.
///
/// Every arm here runs against a fake `BackendValueSource` — no pipe, no
/// database, no plant, no wall clock. That is the point of the class existing
/// separately from the engine (14-05): the evaluation core is the part with the
/// subtle properties, and a subtle property nobody can test cheaply is a
/// property that regresses.
///
/// **The four properties these arms exist to pin**, in the order they cost
/// most:
///
///  1. Evaluation starts at `start()`, not at `onListen`. The defect being
///     removed is `alarm.dart:305` / `boolean_expression.dart:79`, where a rule
///     is evaluated only while somebody is listening — so on a backend with no
///     panel attached, no alarm exists.
///  2. A non-good input suspends the rule and HOLDS its state (D-3), on both
///     edges. `Expression._evaluate` coerces a null through `asDouble == 0.0`,
///     and the rig measured the first-ever subscriber to a key receiving
///     `uncertainNotYetKnown` with a null payload (13-RIG-PROBE-EVIDENCE
///     FIND-2), so without the gate every backend restart writes a false row.
///  3. Transitions are on the BOOLEAN, never on the formatted expression
///     string (P-3). The string changes on every tag update; the boolean does
///     not.
///  4. Every transition is stamped by `resolveAlarmStamp` from the bound
///     values' source times, over an INJECTED clock. No `DateTime.now()`
///     appears in this file.
library;

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/relay/alarm_rule_watcher.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

// The fake source, the counting clock, `t0`, `good`, `bad` and `settle` were
// library-private here until 14-05 needed the same seam for the engine. They
// now live in one place; see that file's doc for why a second copy would not
// have failed a test.
import 'fake_backend_value_source.dart';

void main() {
  group('AlarmRuleWatcher', () {
    // --------------------------------------------------------------- arm 1
    test('evaluates from start(), with nobody listening to anything it '
        'produces', () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.active, isTrue);
      expect(h.watcher.evaluations, 1);

      // The other half, and the one an `onListen` gate would fail: a watcher
      // whose output is never read at all still evaluates. There is no stream
      // to subscribe to and no consumer to count, by construction.
      final silent = _Harness('a > 10', collect: false);
      await silent.watcher.start();
      silent.values.push('a', good(20.0, at: t0));
      await settle();

      expect(silent.watcher.evaluations, greaterThan(0),
          reason: 'evaluation must not be gated on a consumer existing');

      await h.dispose();
      await silent.dispose();
    });

    // --------------------------------------------------------------- arm 2
    test('takes one subscription per variable at start(), and holds it', () async {
      final h = _Harness('a > 10 AND b > 10');
      await h.watcher.start();

      expect(h.values.subscribeCalls, {'a': 1, 'b': 1});
      expect(h.values.liveListeners['a'], 1);
      expect(h.values.liveListeners['b'], 1);
      expect(h.watcher.variables, ['a', 'b']);

      // An unrelated consumer of the same keys comes and goes. The engine's own
      // subscription is what keeps the monitored item alive upstream (D-7), so
      // it must survive somebody else's cancel.
      final other = h.values.subscribe('a').listen((_) {});
      await settle();
      expect(h.values.liveListeners['a'], 2);
      await other.cancel();
      await settle();

      expect(h.values.liveListeners['a'], 1,
          reason: 'the watcher holds its subscription for the process life');

      h.values.push('a', good(20.0, at: t0));
      h.values.push('b', good(20.0, at: t0));
      await settle();
      expect(h.transitions, hasLength(1),
          reason: 'and it is still the one being fed');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 3
    test('stamps a transition with the NEWEST bound source time, from the '
        'plant', () async {
      final h = _Harness('a > 10 AND b > 10');
      await h.watcher.start();

      final older = t0;
      final newer = t0.add(const Duration(minutes: 10));
      h.values.push('a', good(20.0, at: older));
      h.values.push('b', good(20.0, at: newer));
      await settle();

      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.stamp.at, newer);
      expect(h.transitions.single.stamp.source, AlarmTsSource.plant);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 4
    test('one null source time makes the stamp the injected clock, labelled '
        'backend_receipt', () async {
      final h = _Harness('a > 10 AND b > 10');
      // The clock is deliberately far from any source time in play, so a stamp
      // that came from it cannot be mistaken for one that came from the plant.
      h.clock.at = t0.add(const Duration(hours: 3));
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      h.values.push('b', good(20.0)); // no instant
      await settle();

      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.stamp.at, h.clock.at);
      expect(h.transitions.single.stamp.source, AlarmTsSource.backendReceipt);
      expect(h.clock.reads, greaterThan(0),
          reason: 'the injected clock is what was read, not a hidden one');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 5
    test('a non-good input suspends the rule and HOLDS its state -- no '
        'activation on a not-yet-known null', () async {
      final h = _Harness('a < 5');
      await h.watcher.start();

      // All good, rule false.
      h.values.push('a', good(10.0, at: t0));
      await settle();
      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.active, isFalse);

      // The measured boot state: uncertainNotYetKnown, null payload. Without
      // the gate this reads asDouble == 0.0, `0 < 5` is TRUE, and a permanent
      // false row lands in alarm_history on every backend restart.
      final tBad = t0.add(const Duration(minutes: 1));
      h.values.push('a', bad(relay.Quality.uncertainNotYetKnown, at: tBad));
      await settle();

      expect(h.transitions, hasLength(1),
          reason: 'the suspension must emit NOTHING -- state is held');
      expect(h.watcher.suspended, isTrue);
      expect(h.watcher.suspensions, 1);

      // Recovery: a good value that really does satisfy the rule.
      final tGood = t0.add(const Duration(minutes: 2));
      h.values.push('a', good(2.0, at: tGood));
      await settle();

      expect(h.transitions, hasLength(2),
          reason: 'exactly one activation, not two and not none');
      expect(h.transitions.last.active, isTrue);
      expect(h.watcher.suspended, isFalse);
      expect(h.transitions.last.stamp.at, tGood,
          reason: 'stamped from the value that actually satisfied the rule, '
              'never from the one that was refused');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 6
    test('the gate holds an ACTIVE alarm too -- a comms fault is not a clear',
        () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.active, isTrue);

      // Deactivating here writes a false clear and closes a real stop early --
      // the under-reporting `alarmHistoryOverlaps` (alarm.dart:205-211) exists
      // to prevent.
      h.values.push('a',
          bad(relay.Quality.badCommFault, at: t0.add(const Duration(minutes: 1))));
      await settle();

      expect(h.transitions, hasLength(1),
          reason: 'no deactivation may be emitted on a lost link');
      expect(h.transitions.single.active, isTrue);
      expect(h.watcher.suspended, isTrue);
      expect(h.watcher.suspensions, 1);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 7
    test('transitions are on the BOOLEAN, not the formatted string -- ten '
        'updates, one transition', () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.transitions, hasLength(1));

      for (var i = 1; i <= 10; i++) {
        h.values.push(
            'a', good(20.0 + i, at: t0.add(Duration(seconds: i))));
      }
      await settle();

      expect(h.transitions, hasLength(1),
          reason: 'the rule stayed true; only the rendered string moved');
      expect(h.watcher.evaluations, 11,
          reason: 'every update WAS evaluated -- it just did not transition');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 8
    test('the first completed evaluation is always reported, even when false',
        () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(5.0, at: t0));
      await settle();

      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.active, isFalse);
      expect(h.transitions.single.isFirstEvaluation, isTrue,
          reason: "14-06's restart reconciliation asks for exactly this");
      expect(h.transitions.single.expressionText, isNull,
          reason: 'the render stays off the unsatisfied branch (T-14-07)');

      h.values.push('a', good(20.0, at: t0.add(const Duration(minutes: 1))));
      await settle();

      expect(h.transitions, hasLength(2));
      expect(h.transitions.last.isFirstEvaluation, isFalse);
      expect(h.transitions.last.expressionText, isNotNull);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 9
    test('nothing is evaluated before every variable has a value', () async {
      final h = _Harness('a > 10 AND b > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      expect(h.transitions, isEmpty);
      expect(h.watcher.evaluations, 0);
      expect(h.watcher.suspensions, 0,
          reason: 'a variable that has said nothing yet is not a suspension');
      expect(h.watcher.suspended, isFalse);

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 10
    test('a malformed formula refuses by name and stays constructed', () async {
      final h = _Harness('foo bar > 5');

      await expectLater(h.watcher.start(), completes);

      // A backend that dies at boot on one bad operator-authored formula is
      // T-14-11, the DoS in the threat register.
      expect(h.watcher.refusal, isNotNull);
      expect(h.watcher.refusal, contains('foo bar > 5'));
      expect(h.watcher.refusal, contains('7'),
          reason: 'the rule index must be in the message');
      expect(h.watcher.refusalCount, 1);
      expect(h.watcher.variables, isEmpty);
      expect(h.values.subscribeCalls, isEmpty);
      expect(h.transitions, isEmpty);

      // Reported once, not once per call.
      await h.watcher.start();
      expect(h.watcher.refusalCount, 1);

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 11
    //
    // Added during the sabotage pass, and the SUMMARY says so. Mutation (b) --
    // gating on `quality == Quality.good` (the exact code) instead of
    // `quality.isGood` (the good BAND) -- left all ten arms above green,
    // which means the band half of the gate was being asserted by nothing.
    // This is the same trap `Quality.worst`'s doc records from the other
    // side: seeding with `good` used to discard `goodWritePending`.
    test('a good-BAND quality does not suspend -- goodWritePending is good',
        () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(5.0, at: t0));
      await settle();
      expect(h.transitions, hasLength(1));
      expect(h.transitions.single.active, isFalse);

      // An operator's write is in flight on this tag. That is a badge the
      // operator watches, not a reason for the backend to stop judging whether
      // the plant is on fire.
      final tPending = t0.add(const Duration(minutes: 1));
      h.values.push(
        'a',
        relay.DynamicValue(
          value: 20.0,
          quality: relay.Quality.goodWritePending,
          sourceTime: tPending,
        ),
      );
      await settle();

      expect(h.watcher.suspended, isFalse,
          reason: 'goodWritePending (2) is in the good band, 0..255');
      expect(h.watcher.suspensions, 0);
      expect(h.transitions, hasLength(2),
          reason: 'the rule must still have been evaluated and have fired');
      expect(h.transitions.last.active, isTrue);
      expect(h.transitions.last.stamp.at, tPending);

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 12
    //
    // The hold made visible. Measured on the SVN rig, 2026-09-08: "Cooler
    // temperature" activated at boot on a good-quality type-default read,
    // the sweep then staled the input, and D-3 held the alarm true — for as
    // long as anybody watched, with nothing anywhere saying which sensor to
    // check or since when. The hold semantics are right; the invisibility is
    // the defect. So the suspension carries data: which RESOLVED keys are out
    // of the good band, and the instant the hold began, over the injected
    // clock.
    test('suspension names the resolved keys that refused, and the instant '
        'the hold began', () async {
      final h = _Harness('a < 5', resolveKey: (v) => 'plc.$v');
      await h.watcher.start();

      h.values.push('plc.a', good(10.0, at: t0));
      await settle();
      expect(h.watcher.suspendedInputs, isEmpty);
      expect(h.watcher.suspendedSince, isNull);

      final tHold = t0.add(const Duration(minutes: 3));
      h.clock.at = tHold;
      h.values.push('plc.a', bad(relay.Quality.badStale, at: tHold));
      await settle();

      expect(h.watcher.suspended, isTrue);
      expect(h.watcher.suspendedInputs, ['plc.a'],
          reason: 'the operator\'s next act is to check a sensor, so the '
              'banner needs the KEY, not the formula variable');
      expect(h.watcher.suspendedSince, tHold,
          reason: 'over the injected clock — DateTime.now() does not appear '
              'in this suite');

      h.clock.at = t0.add(const Duration(minutes: 4));
      h.values.push('plc.a', good(10.0, at: h.clock.at));
      await settle();

      expect(h.watcher.suspendedInputs, isEmpty,
          reason: 'recovery clears the badge');
      expect(h.watcher.suspendedSince, isNull);

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 13
    test('onSuspensionChanged fires on the edges, never per stale tick',
        () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.suspensionChanges, isEmpty,
          reason: 'a good value is not a suspension edge');

      h.values.push('a', bad(relay.Quality.badStale, at: t0));
      await settle();
      expect(h.suspensionChanges, [true]);

      // The sweep re-badges a dead key every cycle. One hold, one callback —
      // the same entries-not-ticks discipline `suspensions` and the log line
      // already keep (T-14-14).
      h.values.push('a', bad(relay.Quality.badStale, at: t0));
      h.values.push('a', bad(relay.Quality.badCommFault, at: t0));
      await settle();
      expect(h.suspensionChanges, [true]);

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.suspensionChanges, [true, false],
          reason: 'the exit is an edge too — a publisher republishing on the '
              'entry alone would leave the badge on a recovered alarm');

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 14
    //
    // The mirror hazard. While the input is dead the alarm cannot CLEAR
    // either, so the first verdict after a resume is a bound — "it was over
    // by the time the sensor came back" — not a measurement of when the plant
    // recovered. The transition says so, and the engine writes the row's
    // `deactivated_reason` from it; presenting that instant as a measured
    // clear would shorten a stop in the direction nobody audits.
    test('the first transition after a resume is flagged afterSuspension; '
        'later measured ones are not', () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.transitions.single.active, isTrue);
      expect(h.transitions.single.afterSuspension, isFalse,
          reason: 'a transition with no suspension behind it is a measurement');

      h.values.push('a', bad(relay.Quality.badStale, at: t0));
      await settle();

      final tBack = t0.add(const Duration(minutes: 30));
      h.values.push('a', good(5.0, at: tBack));
      await settle();

      expect(h.transitions, hasLength(2));
      expect(h.transitions.last.active, isFalse);
      expect(h.transitions.last.afterSuspension, isTrue,
          reason: 'the plant may have recovered at any point in the 30 '
              'minutes nobody could see; this instant is a bound');

      h.values.push('a', good(20.0, at: tBack.add(const Duration(minutes: 1))));
      await settle();
      expect(h.transitions.last.afterSuspension, isFalse,
          reason: 'the gap has been re-measured; this activation was watched '
              'happen');

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 15
    test('a post-resume evaluation that does NOT transition consumes the '
        'flag — the gap was re-measured as continuity', () async {
      final h = _Harness('a > 10');
      await h.watcher.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      h.values.push('a', bad(relay.Quality.badStale, at: t0));
      await settle();

      // Resume with the SAME verdict: no transition, but the rule has been
      // re-measured — the state on the banner is earned again.
      h.values.push('a', good(25.0, at: t0.add(const Duration(minutes: 10))));
      await settle();
      expect(h.transitions, hasLength(1));

      // The clear that follows was watched happen, start to finish.
      h.values.push('a', good(5.0, at: t0.add(const Duration(minutes: 11))));
      await settle();
      expect(h.transitions, hasLength(2));
      expect(h.transitions.last.afterSuspension, isFalse,
          reason: 'labelling a measured clear as a bound would be the same '
              'lie in the other direction');

      await h.dispose();
    });
  });
}

// ---------------------------------------------------------------- the fixture

/// A watcher, its fake source, its fake clock and the transitions it produced.
final class _Harness {
  _Harness(String formula,
      {bool collect = true, String Function(String variable)? resolveKey})
      : values = FakeBackendValueSource(),
        clock = CountingClock(t0) {
    watcher = AlarmRuleWatcher(
      values: values,
      expression: ExpressionConfig(value: Expression(formula: formula)),
      ruleIndex: 7,
      clock: clock.call,
      onTransition: collect ? transitions.add : (_) {},
      onSuspensionChanged: () => suspensionChanges.add(watcher.suspended),
      resolveKey: resolveKey,
      logger: Logger(level: Level.off),
    );
  }

  final FakeBackendValueSource values;
  final CountingClock clock;
  final List<AlarmRuleTransition> transitions = [];

  /// One snapshot of [AlarmRuleWatcher.suspended] per edge the watcher
  /// reported — entries and exits, never ticks.
  final List<bool> suspensionChanges = [];
  late final AlarmRuleWatcher watcher;

  Future<void> dispose() async {
    await watcher.dispose();
    await values.dispose();
  }
}
