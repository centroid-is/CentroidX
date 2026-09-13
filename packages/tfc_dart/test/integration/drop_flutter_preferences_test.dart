// The gated drop against a real Postgres: the only place the one irreversible
// statement of this milestone is ever executed on this branch.
//
// Four things the cheap lane cannot prove, because SQLite has no
// `to_regclass`, no `pg_proc`, and no plpgsql trigger to leave behind:
//
//   1. each gate refuses, by name, and every failure is reported together —
//      an operator in a maintenance window must see the whole list once,
//      not one refusal per re-run;
//   2. the tolerance is exactly two ids and not a relaxed rule: the drop
//      proceeds with the two expected marker omissions present, and refuses
//      when a third appears OR when one of the two develops a different
//      violation;
//   3. a clean drop removes the table AND the orphan notify function that
//      `DROP TABLE` would leave behind;
//   4. the re-run reports the table already gone and exits 0, because the
//      runbook's week-later step has to be safe to repeat.
//
// **The trigger and function are installed here by hand.** 04-12 deleted the
// keyed-notification helper on `AppDatabase` that created them — but a plant
// database migrated by earlier phases still carries what it made, and
// cleaning that up is precisely what the tool is for. The SQL below is what
// that method emitted, kept here because it is now the only record of it.
//
// **This file takes a database of its own, and it is the only one that has
// to.** It runs a real `DROP TABLE`, and every other integration file in this
// package points at the same `testdb`. On the Docker leg that is survivable by
// accident — each file's `setUpAll` does `compose down` then `up`, which takes
// the container's storage with it — but the macOS and Windows CI legs run with
// `TIMESCALEDB_EXTERNAL=1` against a native PostgreSQL, where both of those
// calls are no-ops. One database then lives for the whole run and this file's
// last drop is permanent for every file scheduled after it.
//
// That failure is sequential, not a race: `dart_test.yaml` sets
// `concurrency: 1`. Which file pays depends only on enumeration order, which
// is why CI failed in `page_migration_test.dart` on macOS and in
// `preference_migration_test.dart` on Windows with the same `42P01: relation
// "flutter_preferences" does not exist`, while a local Docker run stayed
// green. `createIsolatedDatabase` is the fix, and the reasoning lives on it.
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
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPagesMigratedMarkerId, kPreferencesMigratedMarkerId;
import 'package:tfc_dart/core/config/key_mapping_migration.dart'
    show kKeyMappingsMigratedMarkerId;
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database.dart';

import '../../bin/drop_flutter_preferences.dart';
import 'docker_compose.dart';

/// The confirmation, as the runbook sets it.
const Map<String, String> kConfirmed = {
  kConfirmDropEnvVar: kConfirmDropValue,
};

void main() {
  group('the gated drop against Postgres', () {
    late Database database;

    /// A second connection, standing in for the operator's `psql`: it seeds
    /// and it asserts. Assertions must not ride the connection under test.
    late pg.Connection other;

    /// The database this file owns outright — see the header. Both connections
    /// below point at it, so the `DROP TABLE` under test cannot reach any
    /// other file's state.
    late String ownDatabase;

    setUpAll(() async {
      await stopDockerCompose();
      await startDockerCompose();
      await waitForDatabaseReady();
      ownDatabase = await createIsolatedDatabase('drop');
      database = await connectToDatabaseNamed(ownDatabase);
      other = await getTestConnectionFor(ownDatabase);
    });

    tearDownAll(() async {
      await other.close();
      await database.close();
      // Before the compose teardown: dropping the database needs the proxy
      // the teardown shuts down, and a database left behind is a leak that
      // accumulates one per run forever.
      await dropIsolatedDatabase(ownDatabase);
      await stopDockerCompose();
    });

    /// A `config_item` marker row written the way `blob_migration.dart` really
    /// writes one: the row, and **no** change row. That omission is the whole
    /// subject of the tolerance.
    Future<void> seedMarkerWithoutHistory(String id) => other.execute(
          pg.Sql.named(
              'INSERT INTO config_item (kind, id, scope, payload, rev, '
              "updated_at, updated_by) VALUES ('preference', @id, 'shared', "
              "@payload, 1, now(), 'migration')"),
          parameters: {
            'id': id,
            'payload': ConfigItem.of(
              kind: ConfigKind.preference,
              id: id,
              value: preferencePayload(kPrefStringType, '2026-09-08'),
            ).payload,
          },
        );

    /// A row **and** its change row, the way 04-11 writes its own marker —
    /// built through `ConfigChange.of` so `new_value` is the entity encoding
    /// the consistency check compares against, rather than a hand-written
    /// string that would diverge the moment the encoding moved.
    Future<void> seedRowWithHistory(String id, String value) async {
      final item = ConfigItem.of(
        kind: ConfigKind.preference,
        id: id,
        value: preferencePayload(kPrefStringType, value),
      );
      final change = ConfigChange.of(
        at: DateTime.now(),
        actionId: 'seed-$id',
        who: 'migration',
        station: 'test',
        roleName: 'system',
        after: item,
      );
      await other.execute(
        pg.Sql.named('INSERT INTO config_item (kind, id, scope, payload, rev, '
            "updated_at, updated_by) VALUES ('preference', @id, 'shared', "
            "@payload, 1, now(), 'migration')"),
        parameters: {'id': id, 'payload': item.payload},
      );
      await other.execute(
        pg.Sql.named(
            'INSERT INTO config_change (at, action_id, who, station, '
            'role_name, kind, entity_id, scope, op, old_value, new_value) '
            'VALUES (now(), @action, @who, @station, @role, @kind, @entity, '
            '@scope, @op, NULL, @new)'),
        parameters: {
          'action': change.actionId,
          'who': change.who,
          'station': change.station,
          'role': change.roleName,
          'kind': change.kind.wireName,
          'entity': change.entityId,
          'scope': change.scope.wireName,
          'op': change.op.wireName,
          'new': change.newValue,
        },
      );
    }

    Future<void> seedLegacy(String key, String value) => other.execute(
          pg.Sql.named('INSERT INTO flutter_preferences (key, value, type) '
              'VALUES (@key, @value, @type) ON CONFLICT (key) DO UPDATE SET '
              'value = EXCLUDED.value, type = EXCLUDED.type'),
          parameters: {'key': key, 'value': value, 'type': 'String'},
        );

    Future<bool> tableExists() async {
      final rows = await other
          .execute("SELECT to_regclass('public.flutter_preferences')");
      return rows.first.first != null;
    }

    Future<bool> functionExists() async {
      final rows = await other.execute(
          pg.Sql.named('SELECT count(*) FROM pg_proc WHERE proname = @name'),
          parameters: {'name': kDroppedFunction});
      return (rows.first.first! as num).toInt() > 0;
    }

    /// The table and the keyed notify machinery, as a plant carries them.
    /// Recreated per test so the drop can be exercised more than once.
    Future<void> restoreLegacyTable() async {
      await other.execute('CREATE TABLE IF NOT EXISTS flutter_preferences ('
          'key text NOT NULL PRIMARY KEY, value text, type text NOT NULL)');
      await other.execute(r'''
        CREATE OR REPLACE FUNCTION "notify_flutter_preferences_key_change"()
        RETURNS TRIGGER AS $$
        BEGIN
          PERFORM pg_notify(
            'table_flutter_preferences_key_changes',
            json_build_object(
              'action', TG_OP,
              'key', CASE WHEN TG_OP = 'DELETE' THEN OLD."key" ELSE NEW."key" END
            )::text
          );
          RETURN COALESCE(NEW, OLD);
        END;
        $$ LANGUAGE plpgsql;
      ''');
      await other.execute('DROP TRIGGER IF EXISTS '
          '"flutter_preferences_key_notify" ON "flutter_preferences"');
      await other.execute('CREATE TRIGGER "flutter_preferences_key_notify" '
          'AFTER INSERT OR UPDATE OR DELETE ON "flutter_preferences" '
          'FOR EACH ROW EXECUTE FUNCTION '
          '"notify_flutter_preferences_key_change"()');
    }

    /// The state of a plant that has migrated cleanly: three markers, the two
    /// older ones without history because that is how they were written.
    Future<void> seedMigratedPlant() async {
      await seedMarkerWithoutHistory(kKeyMappingsMigratedMarkerId);
      await seedMarkerWithoutHistory(kPagesMigratedMarkerId);
      await seedRowWithHistory(kPreferencesMigratedMarkerId, '2026-09-08');
    }

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
      await restoreLegacyTable();
      await other.execute('DELETE FROM flutter_preferences');
    });

    test('refuses, naming every gate that failed, and writes nothing',
        () async {
      // No markers at all, an unrecognised key, no confirmation: three
      // refusals from one run. Reported together on purpose — four sequential
      // refusals separated by four re-runs is how somebody reaches for a flag
      // that skips them.
      await seedLegacy('a_key_this_build_has_never_heard_of', 'x');

      final result = await dropFlutterPreferences(database.db,
          environment: const {});

      expect(result.outcome, DropOutcome.refused);
      expect(result.exitCode, 1);
      expect(result.refusals, hasLength(3));
      expect(result.refusals.join('\n'), contains(kKeyMappingsMigratedMarkerId));
      expect(result.refusals.join('\n'), contains(kPreferencesMigratedMarkerId));
      expect(result.refusals.join('\n'),
          contains('a_key_this_build_has_never_heard_of'));
      expect(result.refusals.join('\n'), contains(kConfirmDropEnvVar));
      expect(await tableExists(), isTrue, reason: 'a refusal writes nothing');
    });

    test('a wrong confirmation value is refused as loudly as a missing one',
        () async {
      await seedMigratedPlant();

      final result = await dropFlutterPreferences(database.db,
          environment: const {kConfirmDropEnvVar: 'yes'});

      expect(result.outcome, DropOutcome.refused);
      expect(result.refusals.single, contains('"yes"'));
      expect(await tableExists(), isTrue);
    });

    test('proceeds with exactly the two expected marker omissions present',
        () async {
      // The gate as originally specified could never pass on any plant we
      // would run it against: `blob_migration.dart` writes its two markers
      // with no change row, so `checkConfigConsistency` reports both as
      // `missing_history` on every database Phases 2 and 3 touched.
      await seedMigratedPlant();
      await seedLegacy('key_mappings', '{}'); // abandoned, not unknown

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.dropped, reason: result.refusals.join('; '));
      expect(await tableExists(), isFalse);
    });

    test('refuses a THIRD missing_history — the tolerance is two ids', () async {
      await seedMigratedPlant();
      // Not a marker at all: an ordinary preference row somebody wrote without
      // a change row. If the tolerance were "missing_history is fine" this
      // would sail through.
      await seedMarkerWithoutHistory('update_channel');

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.refused);
      expect(result.refusals.single, contains('update_channel'));
      expect(await tableExists(), isTrue);
    });

    test('refuses a tolerated marker that develops a DIFFERENT violation',
        () async {
      await seedMigratedPlant();
      // `_migrated.pages` now has history, and the history disagrees with the
      // row. Same id, different invariant — the allow-list must not cover it,
      // which is why every clause of the match is on the invariant as well as
      // the id.
      await other.execute(pg.Sql.named(
          'INSERT INTO config_change (at, action_id, who, station, role_name, '
          "kind, entity_id, scope, op, old_value, new_value) VALUES (now(), "
          "'tamper', 'nobody', 'test', 'system', 'preference', @entity, "
          "'shared', 'update', NULL, @new)"),
          parameters: {
            'entity': kPagesMigratedMarkerId,
            'new': ConfigItem.of(
              kind: ConfigKind.preference,
              id: kPagesMigratedMarkerId,
              value: preferencePayload(kPrefStringType, 'something else'),
            ).encodeEntity(),
          });

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.refused);
      expect(result.refusals.single, contains(kPagesMigratedMarkerId));
      expect(result.refusals.single, contains('entity_disagrees'));
      expect(await tableExists(), isTrue);
    });

    test('an unknown key refuses even on an otherwise perfect plant', () async {
      await seedMigratedPlant();
      await seedLegacy('some_setting_nobody_classified', 'x');

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.refused);
      expect(result.refusals.single, contains('some_setting_nobody_classified'));
      expect(await tableExists(), isTrue);
    });

    test('a migrated key with no config_item row refuses, naming it', () async {
      // The migration reports a known key it could not read as unknown — in
      // a log line. A week later the classifier decides by name alone and
      // would have called the key migrated; the row check is what stands in
      // for the log line. The same gate covers a key written into the table
      // after the marker existed, which no later run of the migration moves.
      await seedMigratedPlant();
      await seedLegacy('collector_config', '30');

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.refused);
      expect(result.refusals.single, contains('collector_config'));
      expect(result.refusals.single, contains('no config_item row'));
      expect(await tableExists(), isTrue);
    });

    test('a clean drop takes the table AND the orphan notify function',
        () async {
      await seedMigratedPlant();
      expect(await functionExists(), isTrue,
          reason: 'the fixture must install what a plant carries, or the '
              'assertion below proves nothing');

      final result =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(result.outcome, DropOutcome.dropped);
      expect(await tableExists(), isFalse);
      // `DROP TABLE` takes the trigger and leaves the function. An orphan
      // plpgsql function is not harmful, it is unaccountable — the next
      // engineer reading `\df` cannot tell it from something still in use.
      expect(await functionExists(), isFalse);
      expect(result.dropped.join('\n'), contains('flutter_preferences'));
      expect(result.dropped.join('\n'),
          contains('notify_flutter_preferences_key_change'));
    });

    test('the re-run reports it already gone and exits 0', () async {
      await seedMigratedPlant();
      await dropFlutterPreferences(database.db, environment: kConfirmed);

      // The runbook's week-later step, and an operator who cannot remember
      // whether they ran it.
      final again =
          await dropFlutterPreferences(database.db, environment: kConfirmed);

      expect(again.outcome, DropOutcome.alreadyGone);
      expect(again.exitCode, 0);
      expect(again.refusals, isEmpty);
    });

    test('the re-run is safe without the confirmation too', () async {
      await seedMigratedPlant();
      await dropFlutterPreferences(database.db, environment: kConfirmed);

      // "Already gone" is decided before the gates, so a rehearsal against a
      // dropped database reports the truth rather than four refusals about a
      // table that is not there.
      final again = await dropFlutterPreferences(database.db,
          environment: const {});

      expect(again.outcome, DropOutcome.alreadyGone);
      expect(again.exitCode, 0);
    });
  });
}
