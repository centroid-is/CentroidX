// The blob→rows migration against a real Postgres: the advisory lock, the
// idempotency gate, and the round trip through actual rows.
//
// These are the four things the cheap lane cannot prove, because sqlite has no
// advisory locks and an in-memory database cannot lose a race:
//
//   1. a second station running the migration at the same moment writes
//      nothing and does not wait;
//   2. the transaction-scoped lock is released by drift's emulated COMMIT and
//      ROLLBACK, so the loser's next attempt succeeds (research assumption A2);
//   3. a copy interrupted mid-transaction leaves no rows and no marker, and the
//      re-run is clean — what a station losing power mid-boot does;
//   4. every key that went in comes back out, through real columns.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_diff.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/key_mapping_codec.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'docker_compose.dart';

/// A real `key_mappings` dump to run the round trip against, when one is
/// available. Same contract as `test/core/config/key_mapping_codec_test.dart`:
/// the plant blob is half a megabyte of wiring and is not committed.
///
///     CENTROIDX_KEY_MAPPINGS_BLOB=/path/to/key_mappings.json dart test
const String _realBlobEnv = 'CENTROIDX_KEY_MAPPINGS_BLOB';

/// Four keys, one of each shape the real blob carries.
const String _fixtureBlob = '''
{
  "nodes": {
    "CN04.Belt.Speed": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL.Conveyors[4].Speed",
        "array_index": 2,
        "server_alias": "st201"
      },
      "collect": null,
      "bit_mask": 240,
      "bit_shift": 4
    },
    "Line1.Motor1": {
      "opcua_node": {
        "namespace": 4,
        "identifier": "GVL_BatchLines.Drives_Line1[1].HMI",
        "array_index": null,
        "server_alias": null
      },
      "collect": {
        "key": "Line1.Motor1",
        "name": "Line1.Motor1",
        "retention": {"drop_after_min": 525600, "schedule_interval_min": null},
        "sample_interval_us": 5000000,
        "sample_expression": null
      }
    },
    "BER01.Ready": {
      "modbus_node": {
        "server_alias": "ber01",
        "register_type": "holdingRegister",
        "address": 1024,
        "data_type": "uint16",
        "poll_group": "default"
      },
      "collect": null,
      "variable_name": "M_Elevator.i_isAuto"
    },
    "EL9222.Reset": {"io": true, "collect": null}
  }
}
''';

/// Thrown inside the copy to stand in for the station losing power.
class _PowerCut implements Exception {}

void main() {
  final realBlobPath = Platform.environment[_realBlobEnv];

  // The same guard the two codec suites carry, and the one this file was
  // missing: `CENTROIDX_REQUIRE_REAL_BLOB=1` was inert here, so the runbook's
  // third gate command ran green against the committed fixture and proved
  // nothing about production data. That is T-04-13a — "the gate signed off on
  // the fixture" — with the mitigation absent on a third of its surface, and
  // it left the printed `over <source>` line as the only evidence, i.e. an
  // operator reading carefully at 02:00.
  //
  // It throws **before the group is declared**, so `setUpAll` never runs and
  // no container is started: a refused gate costs nothing and takes no lock
  // on port 15432.
  if (Platform.environment['CENTROIDX_REQUIRE_REAL_BLOB'] == '1' &&
      realBlobPath == null) {
    throw StateError('CENTROIDX_REQUIRE_REAL_BLOB=1 but $_realBlobEnv is not '
        'set: this run would have passed against the committed fixture and '
        'proved nothing about production data.');
  }

  final blob = realBlobPath != null
      ? File(realBlobPath).readAsStringSync()
      : _fixtureBlob;
  final blobKeys =
      (jsonDecode(blob) as Map<String, dynamic>)['nodes'] as Map<String, dynamic>;
  final source = realBlobPath ?? 'the committed fixture';

  group('key_mappings migration against Postgres, over $source', () {
    late Database database;

    /// A second connection, standing in for another station: it seeds, it
    /// counts, and it holds the lock. Assertions must not ride the connection
    /// under test.
    late pg.Connection other;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      database = await connectToDatabase();
      other = await getTestConnection();
    });

    tearDownAll(() async {
      await other.close();
      await database.close();
      await stopDockerCompose();
    });

    Future<int> scalar(String sql) async {
      final result = await other.execute(sql);
      return (result.first.first! as num).toInt();
    }

    Future<int> itemCount({String? kind}) => scalar(
        'SELECT count(*) FROM config_item'
        "${kind == null ? '' : " WHERE kind = '$kind'"}");
    Future<int> changeCount() => scalar('SELECT count(*) FROM config_change');
    Future<int> maxRev() =>
        scalar('SELECT coalesce(max(rev), 0) FROM config_item');
    Future<int> markerCount() => scalar('SELECT count(*) FROM config_item '
        "WHERE kind = 'preference' AND id = '$kKeyMappingsMigratedMarkerId'");

    Future<void> seed(String value) async {
      await other.execute(
        pg.Sql.named('INSERT INTO flutter_preferences (key, value, type) '
            "VALUES (@key, @value, 'String') "
            'ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value'),
        parameters: {'key': kKeyMappingsPrefKey, 'value': value},
      );
    }

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
      await other.execute(pg.Sql.named(
          'DELETE FROM flutter_preferences WHERE key = @key'),
          parameters: {'key': kKeyMappingsPrefKey});
      await seed(blob);
    });

    test('a station that loses the lock writes nothing, and does not wait',
        () async {
      // Another station, mid-copy. The session-level form is what a *test* may
      // hold across statements; the migration itself must never use it.
      await other.execute(
          'SELECT pg_advisory_lock($kConfigLockNamespace, '
          '$kKeyMappingMigrationLock)');

      final start = DateTime.now();
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.heldByAnother);
      expect(DateTime.now().difference(start), lessThan(const Duration(seconds: 5)),
          reason: 'try-lock returns false immediately; a station that waited '
              'would stall its own boot behind another station');
      expect(await itemCount(), 0);
      expect(await changeCount(), 0);

      await other.execute(
          'SELECT pg_advisory_unlock($kConfigLockNamespace, '
          '$kKeyMappingMigrationLock)');

      // A2: the loser's own xact lock from the failed attempt was released by
      // drift's COMMIT, so this attempt is not blocked by its own predecessor.
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);
      expect(await itemCount(kind: 'key_mapping'), blobKeys.length);
      expect(await changeCount(), blobKeys.length);
      expect(await markerCount(), 1);
    });

    test('a second run reports alreadyDone, bumps no rev and logs nothing',
        () async {
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);
      final items = await itemCount();
      final changes = await changeCount();
      final rev = await maxRev();

      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.alreadyDone);

      expect(await itemCount(), items);
      expect(await changeCount(), changes);
      expect(await maxRev(), rev,
          reason: 'a re-run that bumped a rev would make every other station '
              'believe the configuration had changed');
    });

    test('the blob row survives the migration', () async {
      await migrateKeyMappingsBlobToRows(database);

      final row = await other.execute(
        pg.Sql.named('SELECT value FROM flutter_preferences WHERE key = @key'),
        parameters: {'key': kKeyMappingsPrefKey},
      );
      expect(row, hasLength(1),
          reason: 'the blob is the rollback insurance for the cutover; '
              'Phase 4 drops it, not the migration');
      expect(row.first.first, blob);
    });

    test('a copy interrupted mid-transaction leaves nothing behind, and the '
        'next run is clean', () async {
      // The copy runs to completion and the transaction is then abandoned —
      // which is what a station losing power mid-boot leaves the server with:
      // an implicit ROLLBACK, no rows, no marker.
      await expectLater(
        database.db.transaction(() async {
          await copyKeyMappingsIntoRows(database.db);
          throw _PowerCut();
        }),
        throwsA(isA<_PowerCut>()),
      );
      expect(await itemCount(), 0);
      expect(await changeCount(), 0);
      expect(await markerCount(), 0,
          reason: 'a marker that outlived its rows would leave the plant '
              'permanently unmigrated and believing otherwise');

      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);
      expect(await itemCount(kind: 'key_mapping'), blobKeys.length);
    });

    test('a plant with no mappings migrates once and stays migrated', () async {
      await seed('{"nodes": {}}');

      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);
      expect(await itemCount(kind: 'key_mapping'), 0);
      expect(await markerCount(), 1);

      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.alreadyDone);
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.alreadyDone);
      expect(await changeCount(), 0);
    });

    /// The migrated rows, read back as items the way a reconcile reads them.
    Future<List<ConfigItem>> storedItems() async {
      final rows = await other.execute(
          'SELECT id, payload, parent_id, sort_index FROM config_item '
          "WHERE kind = 'key_mapping' AND scope = 'shared'");
      return [
        for (final row in rows)
          ConfigItem(
            kind: ConfigKind.keyMapping,
            id: row[0]! as String,
            payload: row[1]! as String,
            parentId: row[2] as String?,
            sortIndex: (row[3] as num?)?.toInt(),
          )
      ];
    }

    test('the first reconcile after the migration diffs as nothing at all',
        () async {
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);

      // The **wanted** side built the way a booting station builds it: from a
      // `KeyMappings` in memory, through `keyMappingItems` — not through the
      // blob parser the migration itself used. That is the whole point.
      // `KeyMappingEntry.toJson()` emits an explicit null for each of its
      // unset optionals, so a payload assembled any other way is structurally
      // a different item and `diffConfigItems` is right to call it a change.
      // If this ever fails, every station's first reconcile after the cutover
      // reports every key changed, re-subscribes every key, and writes a
      // change row for an edit nobody made — the exact noise this milestone
      // exists to remove, reintroduced by the migration that started it.
      final wanted = keyMappingItems(
          KeyMappings.fromJson(jsonDecode(blob) as Map<String, dynamic>));
      final diff =
          diffConfigItems(stored: await storedItems(), wanted: wanted);

      expect(diff.isEmpty, isTrue,
          reason: 'the migration wrote payloads a station would not: $diff '
              '(+${diff.added.map((i) => i.id).take(3).toList()} '
              '~${diff.changed.map((i) => i.id).take(3).toList()} '
              '-${diff.removed.map((i) => i.id).take(3).toList()})');
    });

    test('every key comes back out of the rows unchanged', () async {
      expect(await migrateKeyMappingsBlobToRows(database),
          MigrationOutcome.migrated);

      final items = await storedItems();

      // Compared against what the codec makes of the same blob, not against
      // the blob's bytes: the codec's own round trip is proven in
      // `key_mapping_codec_test.dart`. What is under test here is the database
      // leg — that storing and re-reading the items changed nothing.
      expect(keyMappingBlobOf(items), keyMappingBlobOf(keyMappingItemsFromBlob(blob)));
      expect(items.map((i) => i.id).toSet(), blobKeys.keys.toSet());
    });
  });
}
