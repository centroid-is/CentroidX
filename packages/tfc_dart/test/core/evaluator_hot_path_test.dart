import 'dart:async';

import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:test/test.dart';

/// What an expression costs per tag update.
///
/// A 45s sampling profile of an idle production station (latest-profile AOT
/// build) showed `DynamicValue.toString` at 0.9% of self time (130 of ~14000
/// samples), sitting under `MapBase.mapToString`, `StringBuffer.write` and
/// `_OneByteString._concatAll`, next to the malloc/munmap/`_GrowableList.
/// _allocateData` churn that allocating a fresh string per update produces.
///
/// [Evaluator] is one of the two places that put string building on the
/// per-tag-update path. Every alarm rule, every collector sample condition
/// and every conditional icon on screen holds one, and each of them
/// re-evaluated on every update of every variable it binds. The evaluation
/// itself is cheap; what was not cheap was formatting the result for callers
/// that never wanted text, and re-parsing an immutable formula each time.
///
/// These are counting tests, not timing tests: they count `toString()` calls
/// and formula parses across a simulated burst, so they fail deterministically
/// on the old code rather than flaking in CI.

/// A [DynamicValue] that counts every time something renders it as a String.
class _CountingDynamicValue extends DynamicValue {
  _CountingDynamicValue(Object? value) : super(value: value);

  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls++;
    return super.toString();
  }
}

/// An [Expression] that counts how often its formula is taken apart.
///
/// `parseLiteral` is called once per token while parsing, and (for literal
/// tokens only) once per literal while evaluating. The formulas below contain
/// no literals, so every call counted here is a parse.
class _CountingExpression extends Expression {
  _CountingExpression(String formula) : super(formula: formula);

  int parseLiteralCalls = 0;

  @override
  DynamicValue? parseLiteral(String value) {
    parseLiteralCalls++;
    return super.parseLiteral(value);
  }
}

/// A [ClientApi] whose monitored items are driven by the test.
class _FakeClientApi implements ClientApi {
  final List<NodeId> monitored = [];
  final Map<NodeId, StreamController<DynamicValue>> _controllers = {};

  void emit(NodeId node, DynamicValue value) => _controllers[node]?.add(value);

  bool isMonitored(NodeId node) => _controllers.containsKey(node);

  @override
  Future<void> awaitConnect() async {}

  @override
  Future<int> subscriptionCreate({
    Duration requestedPublishingInterval = const Duration(milliseconds: 100),
    int requestedLifetimeCount = 10000,
    int requestedMaxKeepAliveCount = 10,
    int maxNotificationsPerPublish = 0,
    bool publishingEnabled = true,
    int priority = 0,
  }) async =>
      1;

  @override
  Stream<DynamicValue> monitor(
    NodeId nodeId,
    int subscriptionId, {
    MonitoringMode monitoringMode = MonitoringMode.UA_MONITORINGMODE_REPORTING,
    Duration samplingInterval = const Duration(milliseconds: 100),
    bool discardOldest = true,
    int queueSize = 1,
    bool deliverBadStatus = false,
  }) {
    monitored.add(nodeId);
    late StreamController<DynamicValue> controller;
    // The first value has to come from somewhere: StateMan._monitor waits up
    // to 5s for one before it considers the subscribe successful.
    controller = StreamController<DynamicValue>(
      onListen: () => controller.add(DynamicValue(value: 0.0)),
    );
    _controllers[nodeId] = controller;
    return controller.stream;
  }

  @override
  Future<void> delete() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final _nodeA = NodeId.fromString(4, 'plant.a');
final _nodeB = NodeId.fromString(4, 'plant.b');

KeyMappings _mappings() => KeyMappings(nodes: {
      'a': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'plant.a')
          ..serverAlias = 'st101',
      ),
      'b': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 4, identifier: 'plant.b')
          ..serverAlias = 'st101',
      ),
    });

Future<void> _waitFor(bool Function() test,
    {Duration budget = const Duration(seconds: 6)}) async {
  final deadline = DateTime.now().add(budget);
  while (!test() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('Expression parses its formula once', () {
    // `formula` is final, so the token list cannot change -- but every
    // evaluate() and every formatWithValues() used to re-run the regex, a
    // substring + trim per token, and parseLiteral's toLowerCase +
    // double.tryParse + int.tryParse. Per tag update, per condition.

    test('repeated evaluations do not re-parse', () {
      final expression = _CountingExpression('a AND b');

      expression.evaluate(
          {'a': DynamicValue(value: true), 'b': DynamicValue(value: true)});
      final afterFirst = expression.parseLiteralCalls;
      expect(afterFirst, greaterThan(0),
          reason: 'the first evaluation still has to parse');

      for (var i = 0; i < 100; i++) {
        expression.evaluate({
          'a': DynamicValue(value: i.isEven),
          'b': DynamicValue(value: true),
        });
      }

      expect(expression.parseLiteralCalls, afterFirst,
          reason: '100 further evaluations must reuse the parse');
    });

    test('formatWithValues reuses the same parse', () {
      final expression = _CountingExpression('a AND b');
      final bindings = {
        'a': DynamicValue(value: true),
        'b': DynamicValue(value: true),
      };

      expression.evaluate(bindings);
      final afterFirst = expression.parseLiteralCalls;

      for (var i = 0; i < 50; i++) {
        expression.formatWithValues(bindings);
      }

      expect(expression.parseLiteralCalls, afterFirst);
    });

    test('an invalid formula still throws every time it is asked', () {
      // A failed parse is not cached, so nothing is silently swallowed.
      final expression = Expression(formula: 'a b AND c');
      expect(() => expression.extractVariables(), throwsArgumentError);
      expect(() => expression.extractVariables(), throwsArgumentError);
      expect(expression.isValid(), isFalse);
    });

    test('parsing still produces the same tokens on the second call', () {
      final expression = Expression(formula: '(a > 5) AND b');
      expect(expression.extractVariables(), ['a', 'b']);
      expect(expression.extractVariables(), ['a', 'b']);
      expect(expression.isValid(), isTrue);
    });
  });

  group('Evaluator', () {
    late _FakeClientApi fake;
    late OpcUaStateMan stateMan;

    setUp(() async {
      fake = _FakeClientApi();
      stateMan = await OpcUaStateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: _mappings(),
        deviceClients: const [],
      );
      stateMan.clients
          .add(ClientWrapper(fake, OpcUAConfig()..serverAlias = 'st101'));
    });

    tearDown(() async {
      await stateMan
          .close()
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    });

    test('eval() never renders the bound values as strings', () async {
      // The condition below is true for every value the burst carries, so
      // this exercises exactly the branch that used to call
      // formatWithValues -- the expensive one.
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: Expression(formula: 'a > 5')),
      );
      final seen = <bool>[];
      final sub = evaluator.eval().listen(seen.add);

      await _waitFor(() => fake.isMonitored(_nodeA));

      const updates = 200;
      final values = <_CountingDynamicValue>[];
      for (var i = 0; i < updates; i++) {
        final v = _CountingDynamicValue(10.0 + i);
        values.add(v);
        fake.emit(_nodeA, v);
      }
      await _waitFor(() => seen.contains(true));

      expect(seen, contains(true),
          reason: 'the condition must still evaluate true');
      expect(values.map((v) => v.toStringCalls), everyElement(0),
          reason: 'eval() only ever asked "true or false?"; formatting the '
              'bindings for it built and discarded $updates strings');

      await sub.cancel();
      evaluator.cancel();
    });

    test('state() still formats the satisfied expression', () async {
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: Expression(formula: 'a > 5')),
      );
      final seen = <String?>[];
      final sub = evaluator.state().listen(seen.add);

      await _waitFor(() => fake.isMonitored(_nodeA));

      fake.emit(_nodeA, DynamicValue(value: 10.0));
      await _waitFor(() => seen.any((s) => s != null));

      expect(seen.last, 'a{10.0} > 5',
          reason: 'the alarm text an operator sees must not change');

      // And it goes back to null when the condition stops holding.
      fake.emit(_nodeA, DynamicValue(value: 1.0));
      await _waitFor(() => seen.last == null);
      expect(seen.last, isNull);

      await sub.cancel();
      evaluator.cancel();
    });

    test('a multi-variable condition binds and formats every variable',
        () async {
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression:
            ExpressionConfig(value: Expression(formula: 'a > 5 AND b > 5')),
      );
      final seen = <String?>[];
      final sub = evaluator.state().listen(seen.add);

      await _waitFor(
          () => fake.isMonitored(_nodeA) && fake.isMonitored(_nodeB));

      fake.emit(_nodeA, DynamicValue(value: 10.0));
      fake.emit(_nodeB, DynamicValue(value: 20.0));
      await _waitFor(() => seen.any((s) => s != null));

      expect(seen.last, 'a{10.0} > 5 AND b{20.0} > 5');

      await sub.cancel();
      evaluator.cancel();
    });
  });
}
