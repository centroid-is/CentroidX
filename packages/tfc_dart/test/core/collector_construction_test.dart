import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

/// Two different defects reach the same place — an uncaught async error inside
/// the data-acquisition isolate, which is spawned with `errorsAreFatal`, so it
/// kills acquisition for the WHOLE server and sends the supervisor into a
/// respawn loop. They have different triggers and needed separate fixes:
///
///  - the periodic sample timer dereferencing a null `latestValue`, which
///    fires for any collected key whose value has not arrived yet;
///  - the constructor discarding a rejecting `collectEntry` future, which
///    fires for a key `StateMan.subscribe` refuses outright.
///
/// The distinction is easy to miss and did mislead: an *unroutable* key
/// (`ghost.key`) does NOT throw, because `_throwIfUnresolved` early-returns
/// unless the key contains a `$`, and the non-routable path deliberately holds
/// the stream open and retries. Only a *templated* key reaches the throw. A
/// test named for "a key that cannot be subscribed" while using an unroutable
/// one proves the first defect and says nothing about the second.
Future<Collector> collectorFor(KeyMappings mappings) async {
  final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []), keyMappings: mappings);
  return Collector(
    config: CollectorConfig(collect: true),
    stateMan: stateMan,
    database: Database(AppDatabase.inMemoryForTest()),
  );
}

/// Errors that escape to the zone — what would kill the isolate.
Future<List<Object>> escapedErrors(Future<void> Function() body) async {
  final errors = <Object>[];
  runZonedGuarded(() => unawaited(body()), (e, s) => errors.add(e));
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return errors;
}

void main() {
  test('a sample tick before the first value must not escape the constructor',
      () async {
    // An unroutable key: StateMan holds its stream open and retries, so no
    // value ever arrives and the 100 ms sample timer fires on a null
    // `latestValue`. This is the sample-timer defect, and ONLY that one.
    final mappings = KeyMappings(nodes: {
      'ghost.key': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'i=1'),
        collect: CollectEntry(
            key: 'ghost.key',
            sampleInterval: const Duration(milliseconds: 100)),
      ),
    });

    final errors = await escapedErrors(() async => collectorFor(mappings));

    expect(errors, isEmpty,
        reason: 'A sample tick with no value yet must be skipped. Escaping '
            'Timer.periodic makes it an uncaught isolate error.');
  });

  test('a templated key that subscribe() rejects must not escape the '
      'constructor', () async {
    // `_throwIfUnresolved` (state_man.dart) throws for any key still carrying
    // a `$variable`. Substitutions are published by OptionVariable assets in
    // the UI; nothing publishes them inside the acquisition isolate, so the
    // key stays templated and subscribe() throws every time. The constructor
    // fires collectEntry() without awaiting it, so that rejection has to be
    // handled there or it is fatal.
    final mappings = KeyMappings(nodes: {
      r'Line1.$period.throughput': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'i=2'),
        collect: CollectEntry(key: r'Line1.$period.throughput'),
      ),
    });

    final errors = await escapedErrors(() async => collectorFor(mappings));

    expect(errors, isEmpty,
        reason: 'One unstartable key must cost exactly that key, not the '
            'whole acquisition isolate.');
  });

  test('one unstartable key does not stop the others being collected',
      () async {
    // The point of handling the rejection rather than merely surviving it.
    final mappings = KeyMappings(nodes: {
      r'Line1.$period.throughput': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'i=2'),
        collect: CollectEntry(key: r'Line1.$period.throughput'),
      ),
      'good.key': KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'i=3'),
        collect: CollectEntry(key: 'good.key'),
      ),
    });

    late Collector collector;
    final errors = await escapedErrors(() async {
      collector = await collectorFor(mappings);
    });

    expect(errors, isEmpty);
    expect(collector.collectUpdates('good.key'), isNotNull,
        reason: 'The healthy key must still be registered for collection '
            'after a sibling failed to start.');
  });
}
