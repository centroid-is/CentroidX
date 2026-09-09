/// Every station that is not the collector still constructs a [Collector],
/// with `collect: false`, so it can chart data the collector station wrote.
@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/state_man.dart';

void main() {
  test('collectUpdates on a non-collector station must not throw a TypeError',
      () async {
    final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(opcua: []),
      keyMappings: KeyMappings(nodes: {}),
    );
    addTearDown(() =>
        stateMan.close().timeout(const Duration(seconds: 5), onTimeout: () {}));

    final collector = Collector(
      config: CollectorConfig(collect: false),
      stateMan: stateMan,
      database: Database(AppDatabase.inMemoryForTest()),
    );
    addTearDown(collector.close);
    await collector.collectEntry(CollectEntry(key: 'k', name: 'k'));

    expect(() => collector.collectUpdates('k'), returnsNormally,
        reason: 'collectEntry registers the entry and then returns early when '
            'config.collect is false, so _realTimeStreams has no stream for '
            'it. collectUpdates did `_realTimeStreams[entry]!`, throwing a '
            'bare null-check TypeError instead of the StateError its own '
            'sibling branch returns three lines above for the same class of '
            '"nothing to stream" condition.');
  });
}
