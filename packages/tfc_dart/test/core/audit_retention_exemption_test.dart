// The audit trail is append-only and never pruned, and `registerRetentionPolicy`
// exists precisely to prune tables.
//
// A test asserting that the collector *happens* not to name `audit_entry` would
// hold exactly until somebody named a collected key that. So the refusal lives
// in the register itself, and this file asserts it twice: directly, and end to
// end through the one real call site (`collector.dart:216`), where a
// `CollectEntry`'s free-string `name` is what reaches the register.

import 'dart:async';

import 'package:logger/logger.dart';
import 'package:drift/drift.dart' show Value;
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart'
    show AppDatabase, ConfigChangeTableCompanion, ConfigItemTableCompanion;
import 'package:tfc_dart/core/state_man.dart';

/// A policy that would otherwise be installed — well above
/// [kMinRetentionDuration], so a refusal here can only be the exemption and
/// never `_applyRetentionPolicy`'s separate unusable-policy guard.
const _usable = RetentionPolicy(dropAfter: Duration(days: 30));

/// Runs [body] with a listener on the static `Database.logger` and returns
/// everything it emitted.
Future<List<OutputEvent>> _capture(Future<void> Function() body) async {
  final events = <OutputEvent>[];
  void listener(OutputEvent e) => events.add(e);
  Logger.addOutputListener(listener);
  try {
    await body();
  } finally {
    Logger.removeOutputListener(listener);
  }
  return events;
}

/// Everything emitted at [Level.error], ANSI stripped and joined.
String _errorText(List<OutputEvent> events) => events
    .where((e) => e.level == Level.error)
    .expand((e) => e.lines)
    .join('\n')
    .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

void main() {
  late AppDatabase appDb;
  late Database database;

  setUp(() {
    appDb = AppDatabase.inMemoryForTest();
    database = Database(appDb);
    addTearDown(() => appDb.close());
  });

  group('kRetentionExemptTables', () {
    test('is exactly the access-control tables and the configuration ones',
        () {
      expect(
          kRetentionExemptTables,
          {
            'audit_entry',
            'app_user',
            'app_role',
            'config_change',
            'config_item',
          },
          reason: 'Widening this set is a decision, not a detail: every name '
              'in it is a table the retention machinery may never point at. '
              'The two config tables are the milestone\'s locked "retention: '
              'forever" ruling, asserted here the way spec §8 asserts it for '
              'the audit trail — and narrowing it is the change that would '
              'quietly make the plant\'s configuration sweepable.');
    });

    test('every exempt table says why, in its own words', () {
      expect(kRetentionExemptionReasons.keys.toSet(), kRetentionExemptTables,
          reason: 'A table with no reason falls back to a generic sentence, '
              'which is how a wrong claim gets into a log line.');
      expect(kRetentionExemptionReasons['config_item'],
          isNot(contains('append-only')),
          reason: 'config_item is live configuration — mutable, never pruned. '
              'Calling it append-only would send the next engineer looking '
              'for a bug that is not there.');
      expect(kRetentionExemptionReasons['config_change'],
          contains('append-only'));
    });
  });

  group('registerRetentionPolicy refuses an exempt table', () {
    for (final table in [
      'audit_entry',
      'app_user',
      'app_role',
      'config_change',
      'config_item',
    ]) {
      test('"$table" is not stored in retentionPolicies', () async {
        await database.registerRetentionPolicy(table, _usable);

        expect(database.retentionPolicies.containsKey(table), isFalse,
            reason: 'Blocking the map insert blocks every path: '
                '_applyRetentionPolicy is reached either from here or from '
                '_createTimeseriesTable, and _tryToCreateTimeseriesTable only '
                'calls that when retentionPolicies already contains the name.');
      });

      test('"$table" is refused loudly, at error level', () async {
        final events =
            await _capture(() => database.registerRetentionPolicy(table, _usable));

        final logged = _errorText(events);
        expect(logged, contains(table),
            reason: 'The line has to name the table, or nobody can act on it.');
        expect(logged, contains(kRetentionExemptionReasons[table]!),
            reason: 'And the reason, so the next person does not read this as '
                'a bug to fix by removing the guard — the table\'s own '
                'reason, because "append-only" is false of config_item.');
        expect(logged.toLowerCase(), contains('never pruned'),
            reason: 'Every one of them shares that much, whatever else it is.');
      });

      test('"$table" does not throw — a bad collect entry must not stop the '
          'collector starting', () async {
        await expectLater(
            database.registerRetentionPolicy(table, _usable), completes);
      });
    }

    test('a refused registration issues nothing against the config tables '
        'either — the rows that were there are still there', () async {
      // The same assertion as the audit one below, for the two tables the
      // locked "retention: forever" decision covers: one live configuration
      // row and one history row beneath it.
      await appDb.into(appDb.configItemTable).insert(
            ConfigItemTableCompanion.insert(
              kind: 'key_mapping',
              id: 'CN04.Belt.Speed',
              scope: 'shared',
              payload: '{}',
              updatedAt: DateTime.utc(2026, 8, 28),
              updatedBy: 'gudrun',
            ),
          );
      await appDb.into(appDb.configChangeTable).insert(
            ConfigChangeTableCompanion.insert(
              at: DateTime.utc(2026, 8, 28),
              actionId: 'act-survives',
              who: 'gudrun',
              station: 'SVN-NES-OT-CL02',
              roleName: 'Engineering',
              kind: 'key_mapping',
              entityId: 'CN04.Belt.Speed',
              scope: 'shared',
              op: 'insert',
              newValue: const Value('{}'),
            ),
          );

      await database.registerRetentionPolicy('config_item', _usable);
      await database.registerRetentionPolicy('config_change', _usable);

      expect(await appDb.select(appDb.configItemTable).get(), hasLength(1));
      expect(await appDb.select(appDb.configChangeTable).get(), hasLength(1));
    });

    test('an ordinary table is still registered', () async {
      // The guard must not break the thing registerRetentionPolicy exists for.
      await database.registerRetentionPolicy('CN04_MOT01_frequency', _usable);

      expect(database.retentionPolicies['CN04_MOT01_frequency'], _usable);
    });

    test('a refused registration issues nothing against audit_entry — the row '
        'that was there is still there', () async {
      final sink = DriftAuditSink(appDb);
      await sink.record(AuditRecord.login(
        who: 'gudrun',
        station: 'SVN-NES-OT-CL02',
        roleName: 'Engineering',
        actionId: 'act-survives',
        at: DateTime.utc(2026, 8, 28, 9, 0, 0),
      ));

      await database.registerRetentionPolicy('audit_entry', _usable);

      final rows = await appDb.select(appDb.auditEntry).get();
      expect(rows, hasLength(1));
      expect(rows.single.actionId, 'act-survives');
    });
  });

  group('end to end, through the collector', () {
    late StreamController<DynamicValue> values;
    late Collector collector;

    setUp(() async {
      // Never closed during a test: `collectEntryImpl`'s onDone handler logs
      // at error level, which would land in the same capture as the refusal.
      values = StreamController<DynamicValue>();
      addTearDown(() => values.close());

      final stateMan = await StateMan.create(
        config: StateManConfig(opcua: []),
        keyMappings: KeyMappings(nodes: {}),
      );
      collector = Collector(
        config: CollectorConfig(collect: true),
        stateMan: stateMan,
        database: database,
      );
    });

    test('a CollectEntry named audit_entry gets no retention policy', () async {
      // `name` is a free string from the collector config, and
      // `registerRetentionPolicy(entry.name ?? entry.key, ...)` is the only
      // call site in lib/. This is the route by which the trail could be
      // swept, driven through the real code rather than simulated.
      await collector.collectEntryImpl(
        CollectEntry(
          key: 'CN04.MOT01.HMI',
          name: 'audit_entry',
          retention: _usable,
        ),
        values.stream,
      );

      expect(database.retentionPolicies.containsKey('audit_entry'), isFalse);
    });

    test('a CollectEntry named config_item gets no retention policy', () async {
      // The same route, for the table that holds the plant's live wiring: a
      // collected key called `config_item` must not become a sweep of it.
      await collector.collectEntryImpl(
        CollectEntry(
          key: 'CN04.MOT01.HMI',
          name: 'config_item',
          retention: _usable,
        ),
        values.stream,
      );

      expect(database.retentionPolicies.containsKey('config_item'), isFalse);
    });

    test('a CollectEntry named config_change gets no retention policy',
        () async {
      await collector.collectEntryImpl(
        CollectEntry(
          key: 'CN04.MOT01.HMI',
          name: 'config_change',
          retention: _usable,
        ),
        values.stream,
      );

      expect(database.retentionPolicies.containsKey('config_change'), isFalse);
    });

    test('an ordinary CollectEntry does get one — the harness is not inert',
        () async {
      await collector.collectEntryImpl(
        CollectEntry(
          key: 'CN04.MOT01.HMI',
          name: 'cn04_mot01_hmi',
          retention: _usable,
        ),
        values.stream,
      );

      expect(database.retentionPolicies['cn04_mot01_hmi'], _usable,
          reason: 'Without this the audit assertion above could pass because '
              'collectEntryImpl never reached the register at all.');
    });

    test('an entry with no name falls back to its key, and that key is '
        'exempt too', () async {
      // `entry.name ?? entry.key` — CollectEntry defaults name to key in its
      // constructor, but the register is what has to be safe either way.
      await collector.collectEntryImpl(
        CollectEntry(key: 'audit_entry', retention: _usable),
        values.stream,
      );

      expect(database.retentionPolicies.containsKey('audit_entry'), isFalse);
    });
  });
}
