/// The blob→rows migration's cheap lane: everything decidable without a
/// Postgres server.
///
/// The advisory lock itself is not here — it cannot be, sqlite has no such
/// statement — and is proven against a real server in
/// `test/integration/key_mapping_migration_test.dart`. What *is* here is
/// everything the lock protects: the two refusals that must happen before a
/// transaction is ever opened, and the order of the copy body (gate → read →
/// rows → change rows → marker last), driven through the module's test seam
/// against an in-memory database.
///
/// The refusal tests run against an executor that throws on every statement,
/// so "refused before anything was touched" is asserted by construction rather
/// than by counting rows afterwards.
@TestOn('vm')
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_connections.dart';
import 'package:tfc_dart/core/database_drift.dart';

/// Three keys of three shapes, small enough to read in a failure message.
const String _blob = '''
{
  "nodes": {
    "CN04.Belt.Speed": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL.Conveyors[4].Speed",
        "array_index": null,
        "server_alias": "st201"
      },
      "collect": null
    },
    "BER01.Ready": {
      "modbus_node": {
        "server_alias": "ber01",
        "register_type": "holdingRegister",
        "address": 1024,
        "data_type": "uint16",
        "poll_group": "default"
      },
      "collect": null
    },
    "EL9222.Reset": {"io": true, "collect": null}
  }
}
''';

late AppDatabase db;

/// Every `config_item` row, at any scope.
Future<List<ConfigItemRow>> items() => db.select(db.configItemTable).get();

/// Every `config_change` row, oldest first.
Future<List<ConfigChangeRow>> changes() =>
    (db.select(db.configChangeTable)..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<void> seedBlob(String blob) =>
    db.into(db.flutterPreferences).insert(FlutterPreferencesCompanion.insert(
          key: kKeyMappingsPrefKey,
          value: Value(blob),
          type: 'String',
        ));

/// The copy body as the migration runs it: inside a transaction, with the lock
/// already held (there is nothing to hold here).
Future<MigrationOutcome> runCopy() =>
    db.transaction(() => copyKeyMappingsIntoRows(db));

/// Lines the package logger emitted while [body] ran.
Future<List<String>> logged(Future<void> Function() body) async {
  final lines = <String>[];
  void listener(OutputEvent event) => lines.addAll(event.lines);
  Logger.addOutputListener(listener);
  try {
    await body();
  } finally {
    Logger.removeOutputListener(listener);
  }
  return lines;
}

void main() {
  setUp(() {
    db = AppDatabase.inMemoryForTest();
  });

  tearDown(() => db.close());

  group('the refusals, taken before a transaction is opened', () {
    test('a database that is not Postgres is left alone', () async {
      await seedBlob(_blob);
      final database = Database(db);
      addTearDown(database.close);

      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.notPostgres);
      expect(await items(), isEmpty);
      expect(await changes(), isEmpty);
    });

    test('a pool wider than one is refused, naming the variable that set it',
        () async {
      // Postgres by dialect, and fatal to touch: any statement at all fails
      // the test, which is what "refused before any transaction" means.
      final unusable = AppDatabase.forTest(
        DatabaseConfig(maxPoolConnections: 4),
        _NoStatementExecutor(),
      );
      final database = Database(unusable);
      addTearDown(database.close);

      late MigrationOutcome outcome;
      final lines = await logged(() async {
        outcome = await migrateKeyMappingsBlobToRows(database);
      });

      expect(outcome, MigrationOutcome.unsafePool);
      expect(lines.join('\n'), contains(kMaxPoolConnectionsEnv));
    });
  });

  group('the copy body, through the test seam', () {
    test('every key becomes a row and a change row, and the marker is last',
        () async {
      await seedBlob(_blob);

      late MigrationOutcome outcome;
      final lines = await logged(() async {
        outcome = await runCopy();
      });
      expect(outcome, MigrationOutcome.migrated);

      final rows = await items();
      final mappings =
          rows.where((r) => r.kind == ConfigKind.keyMapping.wireName).toList();
      expect(mappings.map((r) => r.id).toSet(),
          {'BER01.Ready', 'CN04.Belt.Speed', 'EL9222.Reset'});
      expect(mappings.map((r) => r.scope).toSet(),
          {ConfigScope.shared.wireName});
      expect(mappings.map((r) => r.rev).toSet(), {1});
      expect(mappings.map((r) => r.updatedBy).toSet(), {'migration'});

      // The marker: written, underscore-prefixed, and a preference so it stays
      // out of every surface that lists key mappings.
      final marker = rows.singleWhere(
          (r) => r.kind == ConfigKind.preference.wireName);
      expect(marker.id, kKeyMappingsMigratedMarkerId);
      expect(marker.scope, ConfigScope.shared.wireName);

      // One change row per key, all under one action, from this station.
      final log = await changes();
      expect(log, hasLength(3));
      expect(log.map((c) => c.op).toSet(), {ConfigChangeOp.insert.wireName});
      expect(log.map((c) => c.actionId).toSet(), hasLength(1));
      expect(log.map((c) => c.who).toSet(), {'migration'});
      expect(log.map((c) => c.station).toSet(), {Platform.localHostname});
      expect(log.every((c) => c.oldValue == null), isTrue);

      // The payload is what the codec produces, not a re-encoding of it.
      final expected = {
        for (final item in keyMappingItemsFromBlob(_blob)) item.id: item.payload
      };
      expect({for (final r in mappings) r.id: r.payload}, expected);

      // Rollback insurance: Phase 4 drops the blob, not this.
      expect(
          await (db.select(db.flutterPreferences)
                ..where((t) => t.key.equals(kKeyMappingsPrefKey)))
              .getSingleOrNull(),
          isNotNull);

      expect(
        lines.join('\n'),
        contains('key_mappings migration: 3 keys copied from '
            'flutter_preferences to config_item'),
        reason: 'the line an engineer reads before agreeing to a cutover',
      );
    });

    test('a second run reports alreadyDone and writes nothing', () async {
      await seedBlob(_blob);
      expect(await runCopy(), MigrationOutcome.migrated);
      final before = await items();
      final logBefore = await changes();

      expect(await runCopy(), MigrationOutcome.alreadyDone);

      expect(await changes(), hasLength(logBefore.length));
      final after = await items();
      expect(after.map((r) => '${r.kind}/${r.id}/${r.rev}').toList()..sort(),
          before.map((r) => '${r.kind}/${r.id}/${r.rev}').toList()..sort());
    });

    test('a plant with no mappings migrates once and stays migrated',
        () async {
      await seedBlob('{"nodes": {}}');

      expect(await runCopy(), MigrationOutcome.migrated);
      final rows = await items();
      expect(rows, hasLength(1));
      expect(rows.single.id, kKeyMappingsMigratedMarkerId,
          reason: 'the marker is the only thing that stops a plant with zero '
              'mappings re-running the migration forever');

      expect(await runCopy(), MigrationOutcome.alreadyDone);
      expect(await runCopy(), MigrationOutcome.alreadyDone);
    });

    test('a seeded key mapping row does not count as migrated, and the blob '
        'overwrites it', () async {
      await seedBlob(_blob);
      // What `seedDefaultIfEmpty` — or a station whose copy rolled back —
      // leaves behind. It must not read as proof the migration ran.
      await db.into(db.configItemTable).insert(ConfigItemTableCompanion.insert(
            kind: ConfigKind.keyMapping.wireName,
            id: 'CN04.Belt.Speed',
            scope: ConfigScope.shared.wireName,
            payload: '{}',
            rev: const Value(1),
            updatedAt: DateTime.utc(2026, 1, 1),
            updatedBy: 'someone else',
          ));

      expect(await runCopy(), MigrationOutcome.migrated);
      final row = (await items()).singleWhere((r) => r.id == 'CN04.Belt.Speed');
      expect(row.payload, isNot('{}'));
      expect(row.rev, 2);
      expect((await changes()).where((c) => c.entityId == 'CN04.Belt.Speed')
          .single.op, 'update');
    });

    test('no key_mappings row at all is noBlob, and writes the marker',
        () async {
      expect(await runCopy(), MigrationOutcome.noBlob);
      final rows = await items();
      expect(rows.map((r) => r.id), [kKeyMappingsMigratedMarkerId],
          reason: 'looked at and found nothing, which the sweep and the '
              'preference migration both need to be able to read');
      expect(await runCopy(), MigrationOutcome.alreadyDone);
    });

    test('an unrecognisable blob throws and leaves nothing behind', () async {
      await seedBlob('not json at all');

      await expectLater(runCopy(), throwsA(isA<FormatException>()));
      expect(await items(), isEmpty);
      expect(await changes(), isEmpty);
    });
  });
}

/// A Postgres-dialect executor that fails the test if anything is run on it.
class _NoStatementExecutor extends QueryExecutor {
  @override
  SqlDialect get dialect => SqlDialect.postgres;

  Never _refuse() =>
      throw StateError('the migration executed a statement it must not have');

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async => _refuse();

  @override
  Future<List<Map<String, Object?>>> runSelect(
          String statement, List<Object?> args) async =>
      _refuse();

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      _refuse();

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      _refuse();

  @override
  Future<int> runDelete(String statement, List<Object?> args) async =>
      _refuse();

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async =>
      _refuse();

  @override
  Future<void> runBatched(BatchedStatements statements) async => _refuse();

  @override
  TransactionExecutor beginTransaction() => _refuse();

  @override
  QueryExecutor beginExclusive() => _refuse();

  @override
  Future<void> close() async {}
}
