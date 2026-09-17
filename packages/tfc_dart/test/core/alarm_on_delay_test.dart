// A rule's on-delay: the expression has to hold for the whole delay before
// the alarm goes active.
//
// This is evaluated in `Alarm.onChange`, which is what the backend's headless
// `AlarmMan` runs (bin/main.dart). The delay is a property of the rule, so
// every process evaluating the rule agrees on when the alarm went active.

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/state_man.dart';

AlarmRule _rule(String formula,
        {Duration onDelay = Duration.zero, bool ack = false}) =>
    AlarmRule(
      level: AlarmLevel.error,
      expression: ExpressionConfig(value: Expression(formula: formula)),
      acknowledgeRequired: ack,
      onDelay: onDelay,
    );

AlarmConfig _alarm(AlarmRule rule) => AlarmConfig(
      uid: 'CN01.Jam',
      title: 'Jam',
      description: 'Conveyor jammed',
      rules: [rule],
    );

void main() {
  group('AlarmRule.onDelay serialisation', () {
    test('round-trips through JSON in milliseconds', () {
      final rule = _rule('A', onDelay: const Duration(seconds: 15));
      final json = rule.toJson();
      expect(json['onDelayMs'], 15000);
      expect(AlarmRule.fromJson(jsonDecode(jsonEncode(json))).onDelay,
          const Duration(seconds: 15));
    });

    test('a rule stored before the field existed has no delay', () {
      final rule = AlarmRule.fromJson({
        'level': 'error',
        'expression': {
          'value': {'formula': 'A'}
        },
        'acknowledgeRequired': false,
      });
      expect(rule.onDelay, Duration.zero);
    });

    test('no delay is not written, so undelayed configs stay byte-identical',
        () {
      expect(_rule('A').toJson().containsKey('onDelayMs'), isFalse);
    });

    test('takes part in equality, and survives AlarmRule.from', () {
      final delayed = _rule('A', onDelay: const Duration(seconds: 15));
      expect(delayed == _rule('A'), isFalse);
      expect(AlarmRule.from(delayed), delayed);
    });
  });

  group('Alarm.onChange with an on-delay', () {
    late _FakeStateMan stateMan;
    late List<AlarmNotification> seen;

    void listen(FakeAsync async, AlarmRule rule) {
      seen = [];
      Alarm(config: _alarm(rule)).onChange(stateMan).listen(seen.add);
      async.flushMicrotasks();
    }

    void setA(FakeAsync async, bool value) {
      stateMan.push('A', value);
      async.flushMicrotasks();
    }

    setUp(() => stateMan = _FakeStateMan());
    tearDown(() => stateMan.close());

    test('goes active only once the expression has held for the delay', () {
      fakeAsync((async) {
        listen(async, _rule('A', onDelay: const Duration(seconds: 15)));
        setA(async, true);

        async.elapse(const Duration(seconds: 14, milliseconds: 999));
        expect(seen, isEmpty, reason: 'still inside the delay');

        async.elapse(const Duration(milliseconds: 1));
        expect(seen.map((n) => n.active), [true]);
        expect(seen.single.expression, 'A{true}');
      });
    });

    test('a condition that clears inside the delay never raises, or clears',
        () {
      fakeAsync((async) {
        listen(async, _rule('A', onDelay: const Duration(seconds: 15)));
        setA(async, true);
        async.elapse(const Duration(seconds: 10));
        setA(async, false);
        async.elapse(const Duration(minutes: 1));

        expect(seen, isEmpty,
            reason: 'nothing went active, so there is nothing to clear -- an '
                'inactive notification here would reach AlarmMan as an alarm '
                'it never saw raised');
      });
    });

    test('the delay restarts when the condition drops and returns', () {
      fakeAsync((async) {
        listen(async, _rule('A', onDelay: const Duration(seconds: 15)));
        setA(async, true);
        async.elapse(const Duration(seconds: 10));
        setA(async, false);
        setA(async, true);
        async.elapse(const Duration(seconds: 10));
        expect(seen, isEmpty,
            reason: '10 s + 10 s is not 15 s held without a break');

        async.elapse(const Duration(seconds: 5));
        expect(seen.map((n) => n.active), [true]);
      });
    });

    test('clears immediately once active -- the delay is on-delay only', () {
      fakeAsync((async) {
        listen(async, _rule('A', onDelay: const Duration(seconds: 15)));
        setA(async, true);
        async.elapse(const Duration(seconds: 15));
        setA(async, false);

        expect(seen.map((n) => n.active), [true, false]);
      });
    });

    test('raises with the values as they are when the delay ends', () {
      fakeAsync((async) {
        listen(async, _rule('B > 5', onDelay: const Duration(seconds: 15)));
        stateMan.push('B', 6);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        stateMan.push('B', 9);
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1),
            reason: 'one delay per rule, however often the values change');
        async.elapse(const Duration(seconds: 10));

        expect(seen.single.expression, contains('9'));
        async.elapse(const Duration(minutes: 1));
        expect(seen, hasLength(1),
            reason: 'a value change inside the delay neither restarts it '
                'nor starts a second one');
      });
    });

    test('without a delay the alarm goes active on the first true evaluation',
        () {
      fakeAsync((async) {
        listen(async, _rule('A'));
        setA(async, true);
        expect(seen.map((n) => n.active), [true]);
      });
    });

    test('cancelling the listener cancels a pending delay', () {
      fakeAsync((async) {
        seen = [];
        final sub = Alarm(
                config: _alarm(
                    _rule('A', onDelay: const Duration(seconds: 15))))
            .onChange(stateMan)
            .listen(seen.add);
        async.flushMicrotasks();
        setA(async, true);
        sub.cancel();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty,
            reason: 'a timer left running would outlive the listener');
        async.elapse(const Duration(minutes: 1));

        expect(seen, isEmpty);
      });
    });
  });

  test('the headless AlarmMan (the backend) honours the delay', () {
    fakeAsync((async) {
      final stateMan = _FakeStateMan();
      late AlarmMan man;
      AlarmMan.headless(
        config: AlarmManConfig(alarms: [
          _alarm(_rule('A', onDelay: const Duration(seconds: 15))),
        ]),
        stateMan: stateMan,
      ).then((m) => man = m);
      async.flushMicrotasks();

      Set<AlarmActive> active = {};
      man.activeAlarms().listen((a) => active = Set.of(a));
      async.flushMicrotasks();

      stateMan.push('A', true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 14));
      expect(active, isEmpty);

      async.elapse(const Duration(seconds: 1));
      expect(active.single.alarm.config.uid, 'CN01.Jam');

      stateMan.push('A', false);
      async.flushMicrotasks();
      expect(active, isEmpty);
      stateMan.close();
    });
  });
}

/// A [StateMan] whose tags are pushed by the test.
class _FakeStateMan implements StateMan {
  final _tags = <String, StreamController<DynamicValue>>{};

  StreamController<DynamicValue> _tag(String key) =>
      _tags.putIfAbsent(key, StreamController<DynamicValue>.broadcast);

  void push(String key, Object value) =>
      _tag(key).add(DynamicValue(value: value));

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async => _tag(key).stream;

  @override
  Future<void> close() async {
    for (final c in _tags.values) {
      await c.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('StateMan.${invocation.memberName}');
}
