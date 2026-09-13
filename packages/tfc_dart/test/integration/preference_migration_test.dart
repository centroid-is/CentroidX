// The preference migration against a real Postgres: the four properties the
// cutover window rests on.
//
// These are the things the cheap lane cannot prove, because SQLite has no
// advisory locks and an in-memory database cannot lose a race:
//
//   1. the families land as typed, grouped rows and the images land exempt —
//      through real columns, from a table seeded the way a plant's really is;
//   2. a copy interrupted mid-transaction leaves **no rows and no marker**,
//      and the re-run is clean. That is the claim the runbook rests on: a
//      station losing power mid-boot must not leave a half-migrated plant
//      that believes it has migrated;
//   3. an unknown key survives untouched and is reported, and the evidence
//      line carries the counts step 4 greps for;
//   4. `checkConfigConsistency` finds nothing this migration wrote — the
//      migration must not be the first writer that skips the log.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Two checkouts running integration
// suites at once bind the same ports and each `setUpAll` tears the other's
// database down mid-run — the symptom is connection resets that read exactly
// like a resilience regression. Run integration tests in one worktree at a
// time.
@TestOn('vm')
library;

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/config/config_consistency.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:tfc_dart/core/config/key_mapping_migration.dart';
import 'package:tfc_dart/core/config/preference_migration.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database.dart';

import 'docker_compose.dart';

/// Thrown to abandon a transaction the way a power cut does.
class _PowerCut implements Exception {}

void main() {
  group('preference migration against Postgres', () {
    late Database database;

    /// A second connection, standing in for another station: it seeds, it
    /// counts, and it asserts. Assertions must not ride the connection under
    /// test.
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

    Future<void> seedLegacy(String key, String value,
            {String type = kPrefStringType}) =>
        other.execute(
          pg.Sql.named('INSERT INTO flutter_preferences (key, value, type) '
              'VALUES (@key, @value, @type) ON CONFLICT (key) DO UPDATE SET '
              'value = EXCLUDED.value, type = EXCLUDED.type'),
          parameters: {'key': key, 'value': value, 'type': type},
        );

    /// A marker row, written the way the blob migrations really write one:
    /// the row, and **no** change row.
    Future<void> seedMarker(String id) => other.execute(
          pg.Sql.named(
              'INSERT INTO config_item (kind, id, scope, payload, rev, '
              "updated_at, updated_by) VALUES ('preference', @id, 'shared', "
              "@payload, 1, now(), 'migration')"),
          parameters: {
            'id': id,
            'payload': ConfigItem.of(
              kind: ConfigKind.preference,
              id: id,
              value: preferencePayload(kPrefStringType, '2026-09-01'),
            ).payload,
          },
        );

    Future<List<pg.ResultRow>> rowsOf(String kind) => other.execute(
          pg.Sql.named('SELECT id, payload, rev FROM config_item '
              "WHERE kind = @kind AND scope = 'shared' ORDER BY id"),
          parameters: {'kind': kind},
        );

    /// Every change row, as comparable text. Whole-table before/after
    /// comparison is how an absence is proved here: a claim that a write
    /// touched nothing is only worth something against a log that was not
    /// empty to begin with.
    Future<List<String>> changeLog() async {
      final rows = await other.execute(
          'SELECT id, action_id, kind, entity_id, op, old_value, new_value '
          'FROM config_change ORDER BY id');
      return [for (final row in rows) row.map((c) => '$c').join('|')];
    }

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
      await other.execute('DELETE FROM flutter_preferences');
      // The siblings this migration refuses to run without.
      await seedMarker(kKeyMappingsMigratedMarkerId);
      await seedMarker(kPagesMigratedMarkerId);
    });

    /// The table as a plant's really looks at the window: every family, an
    /// abandoned name, and a key nobody in this repository has heard of.
    Future<void> seedPlant() async {
      await seedLegacy('alarm_man_config', '{"alarms":[{"key":"CN04"}]}');
      await seedLegacy('state_man_config', '{"servers":[]}');
      await seedLegacy('collector_config', '30', type: kPrefIntType);
      await seedLegacy('page_editor_top_level_order', 'roe,baader',
          type: kPrefStringListType);
      await seedLegacy('server_config_envelope', 'ciphertext-here');
      await seedLegacy('line1.recipes', '[]');
      await seedLegacy('page_editor_image:9f86d081884c', 'aGVsbG8gd29ybGQ=');
      // Abandoned: device-local by design.
      await seedLegacy('update_channel', 'stable');
      // Abandoned, and the key whose verdict has flipped twice — the reason
      // it is seeded here at all. A plant really does carry this row, and
      // what has to hold end to end is that it neither becomes a `preference`
      // row (an editable shared setting no consumer reads) nor lands in
      // `unknown` (which would block the drop over a key everybody has
      // already decided about).
      await seedLegacy('mcp.config', '{"servers":[]}');
      // The blob rows Phases 2 and 3 already migrated, still there as
      // rollback insurance.
      await seedLegacy('key_mappings', '{"nodes":{}}');
      // The one nobody here can classify.
      await seedLegacy('svn.weigher.calibration', '3.14');
    }

    test('the families land typed and grouped, and the image lands exempt',
        () async {
      await seedPlant();

      final result = await migratePreferencesIntoRows(database);
      expect(result.outcome, PreferenceMigrationOutcome.migrated);

      final prefs = {
        for (final row in await rowsOf('preference')) row[0]! as String: row[1],
      };
      // Through real columns: the type tag travels with the value, so an int
      // is an int and a list is a list rather than everything being the text
      // the old table stored.
      expect(decodePreferencePayload(prefs['collector_config']! as String), 30);
      expect(
          decodePreferencePayload(
              prefs['page_editor_top_level_order']! as String),
          ['roe', 'baader']);
      expect(decodePreferencePayload(prefs['alarm_man_config']! as String),
          '{"alarms":[{"key":"CN04"}]}');
      expect(prefs.keys, contains('line1.recipes'));
      expect(prefs.keys, contains(kPreferencesMigratedMarkerId));
      // Not promoted. A dev box on a prerelease channel must not take the
      // plant with it.
      expect(prefs.keys, isNot(contains('update_channel')));
      // Not promoted either, for a different reason: nothing reads the shared
      // copy since 04-12 (`d47f7633` deleted the MCP binary's reader,
      // `b1b60726` the table class under it), and the raw preferences editor
      // merges shared keys over device-local ones — so a row here would mask
      // this station's real value behind an edit that changes nothing.
      expect(prefs.keys, isNot(contains('mcp.config')));

      final images = await rowsOf('page_image');
      expect(images, hasLength(1));
      expect(images.single[0], '9f86d081884c',
          reason: 'keyed by the suffix verbatim — every asset references that '
              'exact string in its image_id');
      expect(images.single[1], contains('aGVsbG8gd29ybGQ='));

      // The two exempt things wrote no change rows, and the rest did.
      final changes = await other.execute(
          'SELECT entity_id FROM config_change ORDER BY entity_id');
      final logged = [for (final row in changes) row.first! as String];
      expect(logged, isNot(contains('9f86d081884c')),
          reason: 'a page image writes no change row: both sides of a '
              'multi-megabyte payload in a table nothing prunes is C-3');
      expect(logged, isNot(contains('server_config_envelope')),
          reason: 'the ciphertext keeps the lifetime it has today');
      expect(logged, contains('alarm_man_config'));
      expect(logged, contains(kPreferencesMigratedMarkerId),
          reason: 'the marker is logged under the values action id, which is '
              'what makes config_undo refuse the whole migration');
    });

    test('interrupted mid-transaction it leaves no rows and no marker, and '
        'the re-run is clean', () async {
      await seedPlant();
      final before = await changeLog();
      final itemsBefore = await scalar('SELECT count(*) FROM config_item');

      // The copy runs to completion and the transaction is then abandoned —
      // what a station losing power mid-boot leaves the server with: an
      // implicit ROLLBACK, no rows, no marker.
      await expectLater(
        database.db.transaction(() async {
          await copyPreferencesIntoRowsLocked(database.db);
          throw _PowerCut();
        }),
        throwsA(isA<_PowerCut>()),
      );

      expect(await changeLog(), before,
          reason: 'the whole log, compared row by row — and it was not empty '
              'to begin with, so two empty lists cannot pass for a result');
      expect(await scalar('SELECT count(*) FROM config_item'), itemsBefore);
      expect(
          await scalar("SELECT count(*) FROM config_item WHERE id = "
              "'$kPreferencesMigratedMarkerId'"),
          0,
          reason: 'a marker that outlived its rows would leave the plant '
              'permanently unmigrated and believing otherwise');

      // And the next station comes along and does it properly.
      final result = await migratePreferencesIntoRows(database);
      expect(result.outcome, PreferenceMigrationOutcome.migrated);
      expect(result.migratedCount, 6);
    });

    test('an unknown key survives untouched and is reported, with the counts',
        () async {
      await seedPlant();

      final result = await migratePreferencesIntoRows(database);

      expect(result.unknown, ['svn.weigher.calibration'],
          reason: 'mcp.config must NOT be here: an abandoned key waves the '
              'drop through, and blocking the drop over a key three people '
              'have already decided about is the other way to be wrong');
      // Untouched in the old table: this migration reads, it never deletes.
      final legacy = await other.execute(
          pg.Sql.named('SELECT value FROM flutter_preferences WHERE key = @k'),
          parameters: {'k': 'svn.weigher.calibration'});
      expect(legacy.single.first, '3.14');
      // And no row was invented for it.
      expect(
          await scalar("SELECT count(*) FROM config_item WHERE id = "
              "'svn.weigher.calibration'"),
          0);

      final line = result.evidenceLine;
      expect(line, startsWith('Preference migration: 6 migrated'));
      expect(line, contains('images: 1'));
      expect(line, contains('recipes: 1'));
      expect(line, contains('4 abandoned'),
          reason: 'update_channel, key_mappings and mcp.config');
      // Left where it was, and no row invented for it: the whole content of
      // "abandoned" for a key the old table still holds.
      final mcp = await other.execute(
          pg.Sql.named('SELECT value FROM flutter_preferences WHERE key = @k'),
          parameters: {'k': 'mcp.config'});
      expect(mcp.single.first, '{"servers":[]}');
      expect(
          await scalar(
              "SELECT count(*) FROM config_item WHERE id = 'mcp.config'"),
          0);
      expect(line, contains('1 unknown [svn.weigher.calibration]'),
          reason: '04-12 refuses to drop the table while this is non-empty, '
              'and an operator has to know which key is holding it');
    });

    test('the migration leaves nothing inconsistent with its own log',
        () async {
      await seedPlant();

      await migratePreferencesIntoRows(database);

      final found = await checkConfigConsistency(database.db);
      // Nothing this migration wrote. The two that remain are the sibling
      // markers, which `blob_migration.dart` writes with no change row at all
      // — every plant migrated by Phases 2 and 3 carries them, and they are
      // reported here for the same reason they would be on a real station.
      expect(
          found.map((f) => f.entityId).toSet(),
          {kKeyMappingsMigratedMarkerId, kPagesMigratedMarkerId},
          reason: 'a violation naming a migrated preference, an image or this '
              "migration's own marker would mean it skipped the log");
    });

    test('a second station finds it done and writes nothing', () async {
      await seedPlant();
      await migratePreferencesIntoRows(database);
      final after = await changeLog();

      expect((await migratePreferencesIntoRows(database)).outcome,
          PreferenceMigrationOutcome.alreadyDone);

      expect(await changeLog(), after);
    });
  });
}
