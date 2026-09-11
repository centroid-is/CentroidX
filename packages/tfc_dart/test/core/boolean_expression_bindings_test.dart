import 'dart:async';

import 'package:open62541/open62541.dart'
    show ClientApi, DynamicValue, MonitoringMode, NodeId;
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:test/test.dart';

/// What an evaluation has to hand over for an alarm to be honestly stamped.
///
/// `boolean_expression.dart` used to emit `evaluate(map) ? map : null`. On the
/// FALSE branch the bindings -- and with them every `sourceTimestamp` the PLC
/// sent -- were thrown away. A deactivation is a transition, a transition needs
/// an instant, and the only place that instant exists is in the bindings, so a
/// deactivation had nothing to stamp from and fell back to the machine clock.
///
/// The arms below hold the new emission shape to the old contract: `eval()` and
/// `state()` must be byte-for-byte the streams they were, including the
/// property `evaluator_hot_path_test.dart` protects -- that `formatWithValues`
/// runs only on the satisfied branch.

/// A [DynamicValue] carrying a plant instant, which is the whole point.
DynamicValue _stamped(Object? value, DateTime? at) {
  final v = DynamicValue(value: value);
  v.sourceTimestamp = at;
  return v;
}

/// An [Expression] that counts how often its bindings are rendered as text.
class _CountingExpression extends Expression {
  _CountingExpression(String formula) : super(formula: formula);

  int formatCalls = 0;

  @override
  String formatWithValues(Map<String, DynamicValue> values) {
    formatCalls++;
    return super.formatWithValues(values);
  }
}

/// A [ClientApi] whose monitored items are driven by the test.
///
/// Same shape as `evaluator_hot_path_test.dart`'s: the class there is private
/// to that library and there is no shared helper, so the shape is repeated
/// rather than a second, different fake being invented.
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
    // to 5s for one before it considers the subscribe successful. It carries
    // no sourceTimestamp, exactly like a first reading from a server that
    // sent none.
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
  late _FakeClientApi fake;
  late OpcUaStateMan stateMan;

  final tA = DateTime.utc(2026, 9, 6, 11, 0, 0);
  final tB = DateTime.utc(2026, 9, 6, 11, 0, 5);
  final tAClear = DateTime.utc(2026, 9, 6, 11, 30, 0);

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
    await stateMan.close().timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  group('Evaluator.evaluations() carries the bindings on both branches', () {
    test('bindings survive the FALSE branch, source timestamps intact',
        () async {
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression:
            ExpressionConfig(value: Expression(formula: 'a > 5 AND b > 5')),
      );
      final seen = <Evaluation>[];
      final sub = evaluator.evaluations().listen(seen.add);

      await _waitFor(
          () => fake.isMonitored(_nodeA) && fake.isMonitored(_nodeB));

      // Satisfy it...
      fake.emit(_nodeA, _stamped(10.0, tA));
      fake.emit(_nodeB, _stamped(20.0, tB));
      await _waitFor(() => seen.any((e) => e.satisfied));

      // ...then break it. THIS is the emission the old code threw away.
      fake.emit(_nodeA, _stamped(1.0, tAClear));
      await _waitFor(() => seen.last.satisfied == false && seen.length > 1);

      final last = seen.last;
      expect(last.satisfied, isFalse);
      expect(last.bindings.keys, containsAll(<String>['a', 'b']),
          reason: 'a deactivation binds every variable the formula names, '
              'the same set the satisfied branch bound');
      expect(last.bindings['a']!.sourceTimestamp, tAClear,
          reason: 'the instant the plant says the condition stopped holding');
      expect(last.bindings['b']!.sourceTimestamp, tB,
          reason: 'an input that did not move still contributes its instant, '
              'which is what D-1 takes the max over');

      await sub.cancel();
      evaluator.cancel();
    });

    test('bindings survive the TRUE branch, and are what state() formats',
        () async {
      final expression = Expression(formula: 'a > 5 AND b > 5');
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: expression),
      );
      final seen = <Evaluation>[];
      final sub = evaluator.evaluations().listen(seen.add);

      await _waitFor(
          () => fake.isMonitored(_nodeA) && fake.isMonitored(_nodeB));

      fake.emit(_nodeA, _stamped(10.0, tA));
      fake.emit(_nodeB, _stamped(20.0, tB));
      await _waitFor(() => seen.any((e) => e.satisfied));

      final hit = seen.firstWhere((e) => e.satisfied);
      expect(hit.bindings['a']!.sourceTimestamp, tA);
      expect(hit.bindings['b']!.sourceTimestamp, tB);
      expect(expression.formatWithValues(hit.bindings),
          'a{10.0} > 5 AND b{20.0} > 5',
          reason: 'the same map state() renders, handed over unformatted');

      await sub.cancel();
      evaluator.cancel();
    });
  });

  group('the public streams are unchanged', () {
    test('eval() still emits a distinct false, true, false', () async {
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: Expression(formula: 'a > 5')),
      );
      final seen = <bool>[];
      final sub = evaluator.eval().listen(seen.add);

      await _waitFor(() => fake.isMonitored(_nodeA));

      fake.emit(_nodeA, _stamped(10.0, tA));
      await _waitFor(() => seen.contains(true));
      fake.emit(_nodeA, _stamped(1.0, tAClear));
      await _waitFor(() => seen.length >= 4);

      // The leading pair is pre-existing and deliberately pinned rather than
      // "fixed": `startWith(false)` is applied AFTER `distinct()`, so the
      // prepended false is never compared against the seeded 0.0's false.
      // Two more unsatisfied emissions (1.0 then 2.0) would still collapse.
      expect(seen, [false, false, true, false],
          reason: 'startWith(false) ahead of distinct(false, true, false) -- '
              'one emission per TRANSITION and no extra ones now that the '
              'false branch carries a payload');

      // And a second unsatisfied reading is still collapsed away.
      fake.emit(_nodeA, _stamped(2.0, tAClear));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, [false, false, true, false]);

      await sub.cancel();
      evaluator.cancel();
    });

    test('state() still formats on satisfaction and nulls otherwise',
        () async {
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: Expression(formula: 'a > 5')),
      );
      final seen = <String?>[];
      final sub = evaluator.state().listen(seen.add);

      await _waitFor(() => fake.isMonitored(_nodeA));

      fake.emit(_nodeA, _stamped(10.0, tA));
      await _waitFor(() => seen.any((s) => s != null));
      expect(seen.last, 'a{10.0} > 5');

      fake.emit(_nodeA, _stamped(1.0, tAClear));
      await _waitFor(() => seen.last == null);
      expect(seen.last, isNull);

      await sub.cancel();
      evaluator.cancel();
    });

    test('formatWithValues is still called ONLY on the satisfied branch',
        () async {
      // The hot-path property: an unsatisfied evaluation must not build a
      // string. Counted rather than timed, so it fails deterministically if a
      // later edit maps the formatter over both branches.
      final expression = _CountingExpression('a > 5');
      final evaluator = Evaluator(
        stateMan: stateMan,
        expression: ExpressionConfig(value: expression),
      );
      final seen = <String?>[];
      final sub = evaluator.state().listen(seen.add);

      await _waitFor(() => fake.isMonitored(_nodeA));

      // Four unsatisfied emissions (plus the seeded 0.0)...
      for (var i = 0; i < 4; i++) {
        fake.emit(_nodeA, _stamped(i.toDouble(), tA));
      }
      await _waitFor(() => seen.length >= 5);
      expect(expression.formatCalls, 0,
          reason: 'five evaluations, none satisfied, zero strings built');

      // ...then one that holds.
      fake.emit(_nodeA, _stamped(10.0, tA));
      await _waitFor(() => seen.any((s) => s != null));
      expect(expression.formatCalls, 1);

      await sub.cancel();
      evaluator.cancel();
    });
  });
}
