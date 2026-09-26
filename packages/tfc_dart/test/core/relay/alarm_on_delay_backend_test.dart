/// A rule's on-delay (#571), on the backend.
///
/// On main the delay is evaluated in `Alarm.onChange`, "which is what the
/// backend's headless `AlarmMan` runs". On this line the backend runs no
/// `AlarmMan` at all (D-6, `alarm_structure_test.dart` arm 3b): it evaluates
/// every rule in `AlarmRuleWatcher` under `AlarmEngine`. A delay honoured only
/// in `Alarm.onChange` would therefore be a field the editor saves and the
/// plant ignores, so the property main pinned against the headless `AlarmMan`
/// is pinned here, against the engine that replaced it — plus the two
/// questions only this line has to answer: what the D-3 hold does to a running
/// delay, and where a delayed raise is stamped.
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/alarm_rule_watcher.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import 'fake_backend_value_source.dart';

const _delay = Duration(seconds: 15);

void main() {
  group('AlarmRuleWatcher with an on-delay', () {
    test('goes active only once the expression has held for the delay', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(_delay - const Duration(milliseconds: 1));
        expect(h.transitions, isEmpty, reason: 'still inside the delay');
        expect(h.watcher.delaying, isTrue);

        async.elapse(const Duration(milliseconds: 1));
        expect(h.transitions.map((t) => t.active), [true]);
        expect(h.transitions.single.isFirstEvaluation, isTrue,
            reason: 'the first transition reported is still the first '
                'verdict, which is what restart adoption keys on');
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
        'the raise is stamped where the delay ends, from the plant instant '
        'that started it', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        // Far from any plant instant, so a stamp read off it is unmistakable.
        h.clock.at = t0.add(const Duration(hours: 3));
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(_delay);

        final stamp = h.transitions.single.stamp;
        expect(stamp.at, t0.add(_delay));
        expect(stamp.source, AlarmTsSource.plant);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
        'a condition that clears inside the delay never raises; a later '
        'clear is not a transition', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        // A first verdict of false is always reported, so get it out of the
        // way: what is under test is the delay, not restart adoption.
        h.values.push('a', good(0.0, at: t0));
        async.flushMicrotasks();
        expect(h.transitions.map((t) => t.active), [false]);

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        h.values.push('a', good(0.0, at: t0));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(h.transitions.map((t) => t.active), [false],
            reason: 'nothing went active, so there is nothing to clear');
        expect(h.watcher.delaying, isFalse);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
        'a first verdict that drops inside the delay is still reported, so an '
        'open row from a previous process can be closed', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        h.values.push('a', good(0.0, at: t0));
        async.flushMicrotasks();

        expect(h.transitions, hasLength(1));
        expect(h.transitions.single.active, isFalse);
        expect(h.transitions.single.isFirstEvaluation, isTrue);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test('clears immediately once active -- the delay is on-delay only', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(_delay);
        h.values.push('a', good(0.0, at: t0));
        async.flushMicrotasks();

        expect(h.transitions.map((t) => t.active), [true, false]);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
        'raises with the values as they are when the delay ends, from one '
        'timer however often they change', () {
      fakeAsync((async) {
        final h = _Watcher('a > 5', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(6.0, at: t0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        h.values.push('a', good(9.0, at: t0));
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        async.elapse(const Duration(seconds: 10));

        expect(h.transitions.single.expressionText, contains('9'));
        async.elapse(const Duration(minutes: 1));
        expect(h.transitions, hasLength(1));
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test(
        'a suspension inside the delay cancels it; the delay starts again '
        'when the input is good', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        h.values.push('a', bad(relay.Quality.badCommFault, at: t0));
        async.flushMicrotasks();
        expect(h.watcher.delaying, isFalse,
            reason: 'D-3: an input that is not good cannot vouch that the '
                'condition held');
        async.elapse(const Duration(minutes: 1));
        expect(h.transitions, isEmpty);

        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        async.elapse(_delay - const Duration(seconds: 1));
        expect(h.transitions, isEmpty,
            reason: 'the delay restarted with the good verdict');
        async.elapse(const Duration(seconds: 1));
        expect(h.transitions.map((t) => t.active), [true]);
        h.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose cancels a pending delay', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10', onDelay: _delay);
        h.watcher.start();
        async.flushMicrotasks();
        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();

        h.dispose();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty,
            reason: 'a timer left running would outlive the watcher');
        async.elapse(const Duration(minutes: 1));
        expect(h.transitions, isEmpty);
      });
    });

    test('without a delay the first true verdict raises at once', () {
      fakeAsync((async) {
        final h = _Watcher('a > 10');
        h.watcher.start();
        async.flushMicrotasks();
        h.values.push('a', good(20.0, at: t0));
        async.flushMicrotasks();
        expect(h.transitions.map((t) => t.active), [true]);
        h.dispose();
        async.flushMicrotasks();
      });
    });
  });

  // main pinned this against `AlarmMan.headless`; the engine is what the
  // backend runs here.
  test('the backend\'s AlarmEngine honours the delay', () {
    fakeAsync((async) {
      final values = FakeBackendValueSource();
      final preferences = InMemoryPreferences();
      preferences.setString(
          'alarm_man_config',
          jsonEncode(AlarmManConfig(alarms: [
            AlarmConfig(
              uid: 'CN01.Jam',
              title: 'Jam',
              description: 'Conveyor jammed',
              rules: [
                AlarmRule(
                  level: AlarmLevel.error,
                  expression: ExpressionConfig(value: Expression(formula: 'A')),
                  acknowledgeRequired: false,
                  onDelay: _delay,
                ),
              ],
            ),
          ]).toJson()));
      async.flushMicrotasks();
      final clock = CountingClock(t0);
      final engine = AlarmEngine(
        values: values,
        preferences: preferences,
        publisher: _NullPublisher(),
        clock: clock.call,
        logger: Logger(level: Level.off),
      );
      engine.start();
      async.flushMicrotasks();

      values.push('A', good(true, at: t0));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 14));
      expect(engine.active, isEmpty);

      async.elapse(const Duration(seconds: 1));
      expect(engine.active.single.uid, 'CN01.Jam');
      expect(engine.active.single.activeAt, t0.add(_delay));

      values.push('A', good(false, at: t0.add(const Duration(seconds: 20))));
      async.flushMicrotasks();
      expect(engine.active, isEmpty);

      engine.dispose();
      values.dispose();
      async.flushMicrotasks();
    });
  });
}

final class _Watcher {
  _Watcher(String formula, {Duration onDelay = Duration.zero})
      : values = FakeBackendValueSource(),
        clock = CountingClock(t0) {
    watcher = AlarmRuleWatcher(
      values: values,
      expression: ExpressionConfig(value: Expression(formula: formula)),
      ruleIndex: 0,
      clock: clock.call,
      onDelay: onDelay,
      onTransition: transitions.add,
      logger: Logger(level: Level.off),
    );
  }

  final FakeBackendValueSource values;
  final CountingClock clock;
  final List<AlarmRuleTransition> transitions = [];
  late final AlarmRuleWatcher watcher;

  void dispose() {
    watcher.dispose();
    values.dispose();
  }
}

final class _NullPublisher implements AlarmStatePublisher {
  @override
  void publish(String key, relay.DynamicValue value) {}
}
