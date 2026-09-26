import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// A [StateMan] fake exposing only what the key repository's probe uses:
/// [read] and [isKeyDisabled]. Reads block on per-key completers so tests
/// control exactly which probes are in flight and when they finish.
class ProbeFakeStateMan implements StateMan {
  ProbeFakeStateMan({this.disabledKeys = const {}});

  final Set<String> disabledKeys;

  /// Every key handed to [read], in dispatch order.
  final List<String> readRequests = [];

  final Map<String, Completer<DynamicValue>> _pending = {};

  @override
  Future<DynamicValue> read(String key) {
    readRequests.add(key);
    return _pending
        .putIfAbsent(key, () => Completer<DynamicValue>())
        .future;
  }

  @override
  bool isKeyDisabled(String key) => disabledKeys.contains(key);

  /// Number of dispatched reads that have not been completed yet.
  int get inFlight =>
      _pending.values.where((c) => !c.isCompleted).length;

  void completeRead(String key) {
    final completer = _pending[key];
    if (completer != null && !completer.isCompleted) {
      completer.complete(DynamicValue(value: 1));
    }
  }

  bool get hasPending => _pending.values.any((c) => !c.isCompleted);

  void completeAll() {
    // Snapshot: completing a read lets a worker dispatch the next one,
    // which would mutate _pending during iteration.
    for (final key in _pending.keys.toList()) {
      completeRead(key);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ProbeFakeStateMan: ${invocation.memberName}');
}

/// 15 plain keys followed by 5 "zebra" keys, so the zebras sit at the very
/// back of the natural probe order.
KeyMappings probeKeyMappings() {
  final nodes = <String, KeyMappingEntry>{};
  for (var i = 0; i < 15; i++) {
    nodes['key_${i.toString().padLeft(2, '0')}'] = KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Node$i')
        ..serverAlias = 'main_server',
    );
  }
  for (var i = 0; i < 5; i++) {
    nodes['zebra_$i'] = KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Zebra$i')
        ..serverAlias = 'main_server',
    );
  }
  return KeyMappings(nodes: nodes);
}

final Finder searchField = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'Search keys...');

/// Completes every in-flight read (letting workers pull the next keys) until
/// the queue is drained, then flushes the 250 ms status coalescing timer so
/// no timers are left pending at the end of the test.
Future<void> drainProbes(WidgetTester tester, ProbeFakeStateMan sm) async {
  var guard = 0;
  while (sm.hasPending && guard++ < 100) {
    sm.completeAll();
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('probes several keys concurrently, not one at a time',
      (tester) async {
    final sm = ProbeFakeStateMan();
    await tester.pumpWidget(buildTestableKeyRepository(
      keyMappings: probeKeyMappings(),
      stateManConfig: sampleStateManConfig(),
      stateMan: sm,
    ));
    await settle(tester);

    // With no read completed yet, a full worker pool must already be in
    // flight; the old sequential probe would have exactly one.
    expect(sm.inFlight, 6);
    expect(sm.readRequests, [
      'key_00', 'key_01', 'key_02', 'key_03', 'key_04', 'key_05', // pool
    ]);

    await drainProbes(tester, sm);
    expect(sm.readRequests.length, 20);
  });

  testWidgets('search moves matching keys to the front of the probe queue',
      (tester) async {
    final sm = ProbeFakeStateMan();
    await tester.pumpWidget(buildTestableKeyRepository(
      keyMappings: probeKeyMappings(),
      stateManConfig: sampleStateManConfig(),
      stateMan: sm,
    ));
    await settle(tester);
    expect(sm.readRequests.length, 6); // pool filled with key_00..key_05

    await tester.enterText(searchField, 'zebra');
    await tester.pump();

    // Finishing in-flight reads must hand the workers the zebra keys next —
    // not key_06 from the unfiltered order.
    sm.completeRead('key_00');
    await tester.pump();
    sm.completeRead('key_01');
    await tester.pump();
    expect(sm.readRequests.sublist(6, 8), ['zebra_0', 'zebra_1']);

    await drainProbes(tester, sm);
    // Every key still gets probed eventually — filtering reorders, it does
    // not drop the rest of the repository.
    expect(sm.readRequests.toSet().length, 20);
  });

  testWidgets('statuses land as chips; disabled servers are not read',
      (tester) async {
    final sm = ProbeFakeStateMan(disabledKeys: {'key_01'});
    await tester.pumpWidget(buildTestableKeyRepository(
      keyMappings: probeKeyMappings(),
      stateManConfig: sampleStateManConfig(),
      stateMan: sm,
    ));
    await settle(tester);
    await drainProbes(tester, sm);

    expect(sm.readRequests, isNot(contains('key_01')));
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('OK'), findsWidgets);
  });
}
