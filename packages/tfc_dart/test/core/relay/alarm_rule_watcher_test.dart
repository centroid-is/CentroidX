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

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/relay/alarm_rule_watcher.dart';
import 'package:tfc_dart/core/relay/backend_seams.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// A fixed instant to hang the arms off, so nothing here reads a real clock.
final DateTime t0 = DateTime.utc(2026, 9, 6, 12, 0, 0);

relay.DynamicValue good(Object? value, {DateTime? at}) =>
    relay.DynamicValue(value: value, sourceTime: at);

relay.DynamicValue bad(relay.Quality quality, {DateTime? at}) =>
    relay.DynamicValue(value: null, quality: quality, sourceTime: at);

Future<void> settle() => pumpEventQueue(times: 5);

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
  });
}

// ---------------------------------------------------------------- the fixture

/// A watcher, its fake source, its fake clock and the transitions it produced.
final class _Harness {
  _Harness(String formula, {bool collect = true})
      : values = _FakeValues(),
        clock = _CountingClock(t0) {
    watcher = AlarmRuleWatcher(
      values: values,
      expression: ExpressionConfig(value: Expression(formula: formula)),
      ruleIndex: 7,
      clock: clock.call,
      onTransition: collect ? transitions.add : (_) {},
      logger: Logger(level: Level.off),
    );
  }

  final _FakeValues values;
  final _CountingClock clock;
  final List<AlarmRuleTransition> transitions = [];
  late final AlarmRuleWatcher watcher;

  Future<void> dispose() async {
    await watcher.dispose();
    await values.dispose();
  }
}

/// A clock that never advances by itself and counts every read.
///
/// `DateTime.now()` does not appear in this file. The composition root supplies
/// the real one in 14-08 and nowhere else (D-2).
final class _CountingClock {
  _CountingClock(this.at);

  DateTime at;
  int reads = 0;

  DateTime call() {
    reads++;
    return at;
  }
}

/// A `BackendValueSource` with a plant-shaped hole where the plant would be.
///
/// Records `subscribe` per key and how many of those subscriptions are still
/// live, which is what arm 2 reads. Everything the watcher does not call
/// refuses rather than pretending: a permissive stub is how a test starts
/// passing for the wrong reason.
final class _FakeValues implements BackendValueSource {
  final Map<String, List<StreamController<relay.DynamicValue>>> _controllers =
      {};
  final Map<String, relay.DynamicValue> _last = {};

  /// How many times `subscribe` was called for each key.
  final Map<String, int> subscribeCalls = {};

  /// How many of those subscriptions are still listening.
  final Map<String, int> liveListeners = {};

  @override
  Stream<relay.DynamicValue> subscribe(String key) {
    subscribeCalls[key] = (subscribeCalls[key] ?? 0) + 1;
    late final StreamController<relay.DynamicValue> controller;
    controller = StreamController<relay.DynamicValue>(
      onListen: () {
        liveListeners[key] = (liveListeners[key] ?? 0) + 1;
        final seed = _last[key];
        if (seed != null) controller.add(seed);
      },
      onCancel: () {
        liveListeners[key] = (liveListeners[key] ?? 1) - 1;
        _controllers[key]?.remove(controller);
      },
    );
    (_controllers[key] ??= []).add(controller);
    return controller.stream;
  }

  /// Delivers [value] on [key] to every live subscription.
  void push(String key, relay.DynamicValue value) {
    _last[key] = value;
    for (final controller in [...?_controllers[key]]) {
      if (!controller.isClosed) controller.add(value);
    }
  }

  @override
  relay.DynamicValue? read(String key) => _last[key];

  @override
  List<String> get keys => _last.keys.toList();

  @override
  Duration get staleAfter => const Duration(seconds: 10);

  @override
  Future<void> dispose() async {
    for (final list in _controllers.values) {
      for (final controller in [...list]) {
        await controller.close();
      }
    }
    _controllers.clear();
  }

  Never _unused(String member) =>
      throw UnimplementedError('_FakeValues.$member is not on the watcher path');

  @override
  void applyReadback(String key, relay.DynamicValue value) =>
      _unused('applyReadback');

  @override
  void announceLinkLoss(String reason) => _unused('announceLinkLoss');

  @override
  void announceLinkUp() => _unused('announceLinkUp');

  @override
  void clearPending(String key) => _unused('clearPending');

  @override
  relay.ValueListenable<relay.DynamicValue> listen(String key) =>
      _unused('listen');

  @override
  void markPending(String key) => _unused('markPending');

  @override
  void markStale(Iterable<String> keys) => _unused('markStale');

  @override
  Future<relay.DynamicValue> readFresh(String key) => _unused('readFresh');

  @override
  Future<Map<String, relay.DynamicValue>> readMany(List<String> keys) =>
      _unused('readMany');

  @override
  int get roundTrips => _unused('roundTrips');

  @override
  int get statusNotifications => _unused('statusNotifications');
}
