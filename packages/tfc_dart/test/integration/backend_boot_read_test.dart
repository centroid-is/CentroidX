// What the acquisition backend's boot read does to the database: nothing.
//
// The 04-12 claim is an absence — the backend no longer writes the empty
// `alarm_man_config` default when the row is missing — and an absence proved
// by "the value I looked for is not there" proves very little. So this
// compares the **whole** `config_change` table before and after, serialised
// row by row, with the log seeded non-empty first: two empty lists must not be
// able to pass for a result, and a write of any shape anywhere in the log
// fails it, not only a write of the key the test happens to name.
//
// The read under test is the one `bin/main.dart` performs. The boot itself
// cannot be executed here — it connects, spawns isolates and then waits
// forever — so what is exercised is `readSharedPreferenceValue`, which is the
// entirety of what that boot does to this database on the alarm path, plus
// `readSharedKeyMappingItems` beside it for the same reason.
//
// PARALLEL WORKTREES: `docker_compose.dart` hardcodes the container name and
// both ports (5432, and the proxy on 15432). Run integration tests in one
// worktree at a time.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/config/config_change.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart'
    show kPreferencesMigratedMarkerId;
import 'package:tfc_dart/core/config/key_mapping_rows.dart';
import 'package:tfc_dart/core/config/preference_payload.dart';
import 'package:tfc_dart/core/database.dart';

import 'docker_compose.dart';

void main() {
  group("the backend's boot read, against Postgres", () {
    late Database database;

    /// A second connection, standing in for the operator's `psql`: it seeds
    /// and it asserts. Assertions must not ride the connection under test.
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

    setUp(() async {
      await other.execute('DELETE FROM config_change');
      await other.execute('DELETE FROM config_item');
    });

    /// Every `config_change` row, oldest first, serialised whole.
    ///
    /// Every column, not a count and not the ones the test cares about: a
    /// comparison that named columns would miss a write that differed only in
    /// one it forgot, which is the failure mode a whole-table comparison
    /// exists to rule out.
    Future<List<String>> changeLog() async {
      final rows = await other.execute(
          'SELECT * FROM config_change ORDER BY id ASC', queryMode: pg.QueryMode.simple);
      return [
        for (final row in rows) jsonEncode([for (final c in row) '$c']),
      ];
    }

    /// A row and its change row, so the log under comparison is never empty.
    Future<void> seedRowWithHistory(String id, String value) async {
      final item = ConfigItem.of(
        kind: ConfigKind.preference,
        id: id,
        value: preferencePayload(kPrefStringType, value),
      );
      final change = ConfigChange.of(
        at: DateTime.now(),
        actionId: 'seed-$id',
        who: 'a-station',
        station: 'test',
        roleName: 'system',
        after: item,
      );
      await other.execute(
        pg.Sql.named('INSERT INTO config_item (kind, id, scope, payload, rev, '
            "updated_at, updated_by) VALUES ('preference', @id, 'shared', "
            "@payload, 1, now(), 'a-station')"),
        parameters: {'id': id, 'payload': item.payload},
      );
      await other.execute(
        pg.Sql.named(
            'INSERT INTO config_change (at, action_id, who, station, '
            'role_name, kind, entity_id, scope, op, old_value, new_value) '
            'VALUES (@at, @action_id, @who, @station, @role_name, @kind, '
            '@entity_id, @scope, @op, @old_value, @new_value)'),
        parameters: {
          'at': change.at,
          'action_id': change.actionId,
          'who': change.who,
          'station': change.station,
          'role_name': change.roleName,
          'kind': change.kind.wireName,
          'entity_id': change.entityId,
          'scope': change.scope.wireName,
          'op': change.op.wireName,
          'old_value': change.oldValue,
          'new_value': change.newValue,
        },
      );
    }

    test('an absent alarm_man_config leaves the whole change log untouched',
        () async {
      // The regression this exists for. `AlarmMan.create` seeded
      // `{"alarms":[]}` when the read answered null; the backend called it
      // with a `Preferences` built over this database, so an unconfigured
      // plant grew a shared row written by a process with no station
      // identity, no checked group and no audit row.
      //
      // Seeded non-empty on purpose: an assertion that both lists are equal
      // is worth nothing if both are `[]`.
      await seedRowWithHistory('update_channel', 'stable');
      final before = await changeLog();
      expect(before, isNotEmpty,
          reason: 'seed the log first — two empty lists must not be able to '
              'pass for a result');

      final value = await readSharedPreferenceValue(database.db, 'alarm_man_config');
      expect(value, isNull, reason: 'the row is genuinely absent here');

      expect(await changeLog(), before,
          reason: 'the boot read wrote something. The backend has one read '
              'and no reconcile: it cannot tell "no alarms" from "not yet '
              'migrated", so it must never write the default');
    });

    test('the config_item table is untouched too, not merely its history',
        () async {
      // The change log and the rows are two tables. A write that skipped the
      // log would be worse than one that did not, so both are compared.
      await seedRowWithHistory('update_channel', 'stable');
      final itemsBefore = await other.execute(
          'SELECT kind, id, scope, payload, rev FROM config_item ORDER BY kind, id',
          queryMode: pg.QueryMode.simple);
      final before = [for (final r in itemsBefore) jsonEncode([for (final c in r) '$c'])];
      expect(before, isNotEmpty);

      await readSharedPreferenceValue(database.db, 'alarm_man_config');
      await readSharedKeyMappingItems(database.db);
      await readSharedPreferenceValue(
          database.db, kPreferencesMigratedMarkerId);

      final itemsAfter = await other.execute(
          'SELECT kind, id, scope, payload, rev FROM config_item ORDER BY kind, id',
          queryMode: pg.QueryMode.simple);
      expect([for (final r in itemsAfter) jsonEncode([for (final c in r) '$c'])],
          before);
    });

    test('a present alarm_man_config is read back as the config it holds, '
        'still writing nothing', () async {
      final config = AlarmManConfig(alarms: []);
      await seedRowWithHistory('alarm_man_config', jsonEncode(config));
      final before = await changeLog();

      final value =
          await readSharedPreferenceValue(database.db, 'alarm_man_config');
      expect(value, isA<String>());
      expect(AlarmManConfig.fromJson(jsonDecode(value! as String)).alarms,
          isEmpty);

      expect(await changeLog(), before);
    });

    test('the migration marker is what separates the two absences', () async {
      // Both arms run with zero alarms; the marker only decides which line the
      // backend logs. It has to be readable from here for that to work at all.
      await seedRowWithHistory('update_channel', 'stable');
      expect(
          await readSharedPreferenceValue(
              database.db, kPreferencesMigratedMarkerId),
          isNull,
          reason: 'no marker: the migration has not run');

      await seedRowWithHistory(kPreferencesMigratedMarkerId, '2026-09-08');
      expect(
          await readSharedPreferenceValue(
              database.db, kPreferencesMigratedMarkerId),
          '2026-09-08',
          reason: 'marker present: an absent alarm row means no alarms');
    });
  });
}
