import 'dart:async';

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

Future<Collector> makeCollector() async {
  final stateMan = await StateMan.create(
      config: StateManConfig(opcua: []), keyMappings: KeyMappings(nodes: {}));
  final database = Database(AppDatabase.inMemoryForTest());
  return Collector(
    config: CollectorConfig(collect: true),
    stateMan: stateMan,
    database: database,
  );
}

void main() {
  test('sampled entry that has not received a value yet must not throw',
      () async {
    final errors = <Object>[];
    final collector = await makeCollector();
    final controller = StreamController<DynamicValue>();
    addTearDown(controller.close);

    final entry = CollectEntry(
      key: 'never_emits',
      name: 'never_emits',
      sampleInterval: const Duration(milliseconds: 50),
    );

    runZonedGuarded(() {
      // Fire and forget, exactly as the data-acquisition isolate does.
      unawaited(collector.collectEntryImpl(entry, controller.stream));
    }, (e, s) => errors.add(e));

    // Four sample ticks with no value ever delivered by the server.
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(errors, isEmpty,
        reason: 'A sample tick before the first subscription value must be '
            'skipped, not throw. Any error here escapes Timer.periodic and '
            'becomes an uncaught isolate error.');
  });

  test('close() stops the periodic sample timer', () async {
    final collector = await makeCollector();
    final controller = StreamController<DynamicValue>.broadcast();
    addTearDown(controller.close);

    final entry = CollectEntry(
      key: 'sampled',
      name: 'sampled',
      sampleInterval: const Duration(milliseconds: 30),
    );
    await collector.collectEntryImpl(entry, controller.stream,
        skipFirstSample: false);

    controller.add(DynamicValue(value: 1.0));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    collector.close();

    final before = collector.getStats()['total_inserts'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final after = collector.getStats()['total_inserts'] as int;

    expect(after, before,
        reason: 'After close() the sample timer must be cancelled; otherwise '
            'every collector ever built keeps inserting forever.');
  });
}
