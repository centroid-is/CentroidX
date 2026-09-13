/// The first executed Postgres migration arm in this repository.
///
/// ## Why this file has to exist, and why SQLite could not have written it
///
/// `database_drift.dart`'s v6 Postgres branch says it out loud: *"No test
/// executes this arm. Not one in `test/core/`, which can only open SQLite, and
/// none in `test/integration/` either."* That is not a stylistic gap. Two of
/// the four things schema v7 changes are **invisible on SQLite**:
///
/// * The `alarm_uid -> alarm(uid)` foreign key is inert on SQLite, because
///   drift never issues `PRAGMA foreign_keys = ON` and nothing in this package
///   sets it in a `beforeOpen`. On Postgres a foreign key is always enforced,
///   and since **nothing in this codebase has ever inserted a row into the
///   `alarm` table** — alarm definitions live in the `alarm_man_config`
///   preference JSON — every `alarm_history` insert against the plant database
///   has been guaranteed to fail with SQLSTATE 23503. It has never fired only
///   because SVN has zero alarms configured. A SQLite test passes on the broken
///   schema and proves nothing; that is precisely how this survived to be found
///   by a research pass rather than by an operator.
/// * `NULL`s are distinct in a unique index. Arm 5 measures that, and it is the
///   reason the writers added by this phase must always supply a `rule_index`.
///
/// ## The two subjects, and why both
///
/// Every behavioural arm runs twice: once against a database drift **created**
/// (`onCreate`), once against a v6-shaped database drift **upgraded**
/// (`onUpgrade(6, 7)`). They are different code paths that must agree, and only
/// running both makes the sabotage table honest — removing the FK drop from the
/// migration leaves the created subject green, and removing `.references()`
/// from the table class leaves the upgraded subject green. One subject each
/// would let half of v7 be deleted without a red run.
///
/// ## Isolation
///
/// Each subject gets its own physical Postgres **database**, created by this
/// file and dropped by it. The lane is shared (port 15432 is hardcoded in
/// `docker_compose.dart`, and a parallel worktree run collides), and an arm
/// that can see another arm's rows is an arm that goes flaky on CI. Rows are
/// truncated between arms as well.
///
/// The v6 shape is built with raw DDL rather than with drift's `createTable`,
/// deliberately: `createTable` builds the CURRENT schema, which is the shape
/// the upgrade is supposed to produce, so an arm built on it would assert
/// nothing.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:math';

import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart';

import 'docker_compose.dart';

// ---------------------------------------------------------------------------
// Subjects
// ---------------------------------------------------------------------------

/// The subject drift built from scratch with `onCreate`.
const String createdSubject = 'freshly created (onCreate)';

/// The subject drift lifted from a hand-built v6 shape with `onUpgrade(6, 7)`.
const String upgradedSubject = 'upgraded from v6 (onUpgrade 6 -> 8)';

const List<String> subjects = <String>[createdSubject, upgradedSubject];

/// A per-run suffix on every database this file creates.
///
/// Two runs of this file against one server must not fight over a name, and a
/// database left behind by a killed run must not be mistaken for this run's.
final String runSuffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

final Map<String, String> databaseNames = <String, String>{
  createdSubject: 'alarm_v7_created_$runSuffix',
  upgradedSubject: 'alarm_v7_upgraded_$runSuffix',
};

/// A raw `postgres` connection per subject, for the SQLSTATE arms.
///
/// Raw rather than through drift on purpose: the arms assert on the SQLSTATE,
/// and a driver exception that has not been through a wrapper is the shortest
/// path from "this failed" to "this failed with 23503".
final Map<String, pg.Connection> conns = <String, pg.Connection>{};

/// The real `AppDatabase` per subject — the thing under test.
final Map<String, AppDatabase> drifts = <String, AppDatabase>{};

/// The admin connection to `testdb`, used only to CREATE/DROP the subjects.
late pg.Connection admin;

/// What each subject's migration threw, or null if it did not throw.
///
/// **Recorded rather than rethrown.** A migration that aborts inside
/// `setUpAll` takes the whole file down with one stack trace and no arm names,
/// which is the worst diagnostic this file could produce: the reader sees a
/// dead fixture and has to guess whether the migration, the seed or Docker is
/// at fault. Recording it lets the fixture arm below say *which* subject's
/// migration threw and *what* it threw, and lets the behavioural arms fail on
/// the shape they are actually about.
final Map<String, Object?> migrationFailures = <String, Object?>{};

/// Whether `setUpAll` got as far as live connections.
///
/// Without this the teardown's `LateInitializationError` lands on top of the
/// real cause — a missing Docker daemon — and the daemon gets diagnosed as a
/// bug in this file.
bool fixtureUp = false;

/// The schema version drift reported for the created subject, read out of
/// drift's own marker table. Arm 3 stamps the upgraded subject through the same
/// name, so the test writes what drift reads rather than a name recalled from
/// memory.
int? markerAsDriftWroteIt;

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

DatabaseConfig configFor(String database) {
  final base = getTestConfig();
  final endpoint = base.postgres!;
  return DatabaseConfig(
    postgres: pg.Endpoint(
      host: endpoint.host,
      port: endpoint.port,
      database: database,
      username: endpoint.username,
      password: endpoint.password,
    ),
    sslMode: base.sslMode,
    connectTimeout: base.connectTimeout,
    queryTimeout: base.queryTimeout,
    applicationName: 'alarm_schema_v8_test',
  );
}

Future<pg.Connection> connectTo(String database) => pg.Connection.open(
      configFor(database).postgres!,
      settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
    );

/// The PostgreSQL SQLSTATE behind [error], unwrapping whatever put it there.
///
/// Drift wraps driver exceptions on some paths and not others. An arm that
/// asserted on the wrapper would pass or fail on drift's internals rather than
/// on what the database said.
String? sqlState(Object? error) {
  Object? current = error;
  for (var depth = 0; depth < 6 && current != null; depth++) {
    if (current is pg.ServerException) return current.code;
    Object? next;
    try {
      next = (current as dynamic).cause as Object?;
    } catch (_) {
      return null;
    }
    if (identical(next, current)) return null;
    current = next;
  }
  return null;
}

/// Runs [body] and hands back whatever it threw, or null if it did not throw.
///
/// `throwsA` cannot express "this must fail, and the SQLSTATE it fails with is
/// part of the claim" without a matcher per state; capturing is shorter and the
/// `reason:` can quote the state that actually arrived.
Future<Object?> errorOf(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}

String describe(Object? error) =>
    error == null ? 'no error' : '${error.runtimeType}: $error';

// ---------------------------------------------------------------------------
// Schema probes — all read the database, none trust drift's opinion of it
// ---------------------------------------------------------------------------

/// Names of the FOREIGN KEY constraints on `alarm_history` that reference
/// `alarm`. This is CD-4's discovery query, and the migration issues the same
/// one rather than trusting drift's default `alarm_history_alarm_uid_fkey`.
Future<List<String>> foreignKeysToAlarm(pg.Connection c) async {
  final rows = await c.execute('''
    SELECT tc.constraint_name
      FROM information_schema.table_constraints tc
      JOIN information_schema.constraint_column_usage ccu
        ON ccu.constraint_name = tc.constraint_name
       AND ccu.constraint_schema = tc.constraint_schema
     WHERE tc.table_name = 'alarm_history'
       AND tc.constraint_type = 'FOREIGN KEY'
       AND ccu.table_name = 'alarm'
  ''');
  return rows.map((r) => r[0]! as String).toList();
}

/// `column_name -> data_type` for `alarm_history`.
Future<Map<String, String>> columnsOf(pg.Connection c) async {
  final rows = await c.execute('''
    SELECT column_name, data_type
      FROM information_schema.columns
     WHERE table_name = 'alarm_history'
  ''');
  return <String, String>{
    for (final r in rows) r[0]! as String: r[1]! as String,
  };
}

/// `indexname -> indexdef` for `alarm_history`.
Future<Map<String, String>> indexesOf(pg.Connection c) async {
  final rows = await c.execute('''
    SELECT indexname, indexdef
      FROM pg_indexes
     WHERE tablename = 'alarm_history'
  ''');
  return <String, String>{
    for (final r in rows) r[0]! as String: r[1]! as String,
  };
}

/// The partial unique index D-4 makes "two open rows for one alarm-rule"
/// unrepresentable with, identified by what it *does* rather than by its name.
///
/// Matching on the name would pass on an index that is unique over the wrong
/// columns; matching on the definition is what the arm is actually about.
MapEntry<String, String>? openRowIndex(Map<String, String> indexes) {
  for (final entry in indexes.entries) {
    final def = entry.value.toLowerCase();
    if (def.contains('unique') &&
        def.contains('alarm_uid') &&
        def.contains('rule_index') &&
        def.contains('deactivated_at is null')) {
      return entry;
    }
  }
  return null;
}

/// Drift's own schema marker on Postgres, read rather than assumed.
Future<int> readDriftMarker(pg.Connection c) async {
  final rows = await c.execute('SELECT version FROM __schema');
  return rows.first.first! as int;
}

// ---------------------------------------------------------------------------
// Row helpers
// ---------------------------------------------------------------------------

/// Inserts an `alarm_history` row and returns its id.
///
/// [ruleIndex] and [deactivatedAt] are bound as typed NULLs when omitted, so a
/// NULL reaches the server as a NULL of the column's type and not as the empty
/// string P-2 is about.
Future<int> insertHistory(
  pg.Connection c, {
  required String uid,
  int? ruleIndex,
  String? deactivatedAt,
  bool active = true,
  String? createdAt,
}) async {
  final rows = await c.execute(
    pg.Sql.named('''
      INSERT INTO alarm_history (
        alarm_uid, alarm_title, alarm_description, alarm_level,
        expression, active, pending_ack, created_at, rule_index, deactivated_at
      ) VALUES (
        @uid, @title, @description, @level,
        @expression, @active, @ack, @created, @ruleIndex, @deactivated
      ) RETURNING id
    '''),
    parameters: <String, Object?>{
      'uid': pg.TypedValue(pg.Type.text, uid),
      'title': pg.TypedValue(pg.Type.text, 'Frystir yfirhiti'),
      'description': pg.TypedValue(pg.Type.text, 'temperature over setpoint'),
      'level': pg.TypedValue(pg.Type.text, 'warning'),
      'expression': pg.TypedValue(pg.Type.text, 'tank.temp > 5'),
      'active': pg.TypedValue(pg.Type.boolean, active),
      'ack': pg.TypedValue(pg.Type.boolean, false),
      'created': pg.TypedValue(
          pg.Type.text, createdAt ?? '2026-09-06T10:00:00.000Z'),
      // `bigInteger`, matching what drift's Postgres dialect makes of an
      // `IntColumn`. Binding an int4 against the int8 column does not fail
      // with a type error — it fails with SQLSTATE 08P01, "insufficient data
      // left in message", which reads like a driver bug.
      'ruleIndex': pg.TypedValue(pg.Type.bigInteger, ruleIndex),
      'deactivated': pg.TypedValue(pg.Type.text, deactivatedAt),
    },
  );
  return rows.first.first! as int;
}

/// Inserts an `alarm_history` row naming **only v6 columns**.
///
/// Arm 2 is about the foreign key and nothing else, and it has to be able to
/// say so on a schema that has not been migrated yet: an insert mentioning
/// `rule_index` fails with 42703 before Postgres ever gets as far as checking
/// the FK, and the arm's RED output would then name the wrong defect.
Future<void> insertLegacyHistory(pg.Connection c, {required String uid}) async {
  await c.execute(
    pg.Sql.named('''
      INSERT INTO alarm_history (
        alarm_uid, alarm_title, alarm_description, alarm_level,
        expression, active, pending_ack, created_at
      ) VALUES (
        @uid, @title, @description, @level,
        @expression, @active, @ack, @created
      )
    '''),
    parameters: <String, Object?>{
      'uid': pg.TypedValue(pg.Type.text, uid),
      'title': pg.TypedValue(pg.Type.text, 'Frystir yfirhiti'),
      'description': pg.TypedValue(pg.Type.text, 'temperature over setpoint'),
      'level': pg.TypedValue(pg.Type.text, 'warning'),
      'expression': pg.TypedValue(pg.Type.text, 'tank.temp > 5'),
      'active': pg.TypedValue(pg.Type.boolean, true),
      'ack': pg.TypedValue(pg.Type.boolean, false),
      'created': pg.TypedValue(pg.Type.text, '2026-09-06T10:00:00.000Z'),
    },
  );
}

/// Rows currently in `alarm_history`.
Future<int> historyCount(pg.Connection c) async {
  final rows = await c.execute('SELECT count(*) FROM alarm_history');
  return rows.first.first! as int;
}

// ---------------------------------------------------------------------------
// The v6 shape, by hand
// ---------------------------------------------------------------------------

/// The database exactly as schema v6 leaves it: `alarm_history`'s foreign key
/// present, none of v8's three columns, and the v6 access tables **without**
/// `allowed_pages`, which is v7's addition.
///
/// The access tables are here even though nothing in this file reads them,
/// because the migration does: v7's Postgres arm runs
/// `ALTER TABLE app_role ADD COLUMN IF NOT EXISTS allowed_pages` on the way
/// from 6 to 8, and `IF NOT EXISTS` says nothing about a table that is not
/// there — the statement fails with `42P01`. A fixture claiming to be v6 has
/// to carry what v6 created, or the first arm above 6 dies on the shape rather
/// than on the change it is testing. Copied from the v6 branch's own CREATE
/// literals in `database_drift.dart`, minus the column v7 adds.
///
/// Datetimes are TEXT on both backends — this database sets
/// `DriftDatabaseOptions(storeDateTimeAsText: true)`.
///
/// `BIGSERIAL`, not `SERIAL`: drift's Postgres dialect maps every `IntColumn`
/// to `bigint`, so a v6 database drift actually created has `id bigint`. A
/// seed that used `SERIAL` would be a v6 shape no station has ever run, and
/// the column-parity arm would then report a difference this migration did not
/// cause.
const List<String> v6Ddl = <String>[
  '''
  CREATE TABLE alarm (
    uid TEXT NOT NULL PRIMARY KEY,
    key TEXT,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    rules TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE alarm_history (
    id BIGSERIAL PRIMARY KEY,
    alarm_uid TEXT NOT NULL REFERENCES alarm(uid),
    alarm_title TEXT NOT NULL,
    alarm_description TEXT NOT NULL,
    alarm_level TEXT NOT NULL,
    expression TEXT,
    active BOOLEAN NOT NULL,
    pending_ack BOOLEAN NOT NULL,
    created_at TEXT NOT NULL,
    deactivated_at TEXT,
    acknowledged_at TEXT
  )
  ''',
  '''
  CREATE TABLE app_role (
    name TEXT PRIMARY KEY,
    groups TEXT NOT NULL,
    seeded BOOLEAN NOT NULL DEFAULT FALSE
  )
  ''',
  '''
  CREATE TABLE app_user (
    username TEXT PRIMARY KEY,
    role_name TEXT NOT NULL REFERENCES app_role(name),
    password_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_login_at TEXT,
    station_account BOOLEAN NOT NULL DEFAULT FALSE
  )
  ''',
  '''
  CREATE TABLE audit_entry (
    id BIGSERIAL PRIMARY KEY,
    at TEXT NOT NULL,
    who TEXT NOT NULL,
    station TEXT NOT NULL,
    role_name TEXT NOT NULL,
    surface TEXT NOT NULL,
    item_key TEXT NOT NULL,
    member TEXT,
    old_value TEXT,
    new_value TEXT,
    group_required TEXT NOT NULL,
    allowed BOOLEAN NOT NULL,
    origin TEXT NOT NULL DEFAULT 'operator',
    action_id TEXT NOT NULL,
    reason TEXT
  )
  ''',
  '''
  CREATE TABLE access_template (
    name TEXT PRIMARY KEY,
    rules TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  ''',
  '''
  CREATE TABLE access_key_binding (
    key_name TEXT PRIMARY KEY,
    template_name TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  ''',
];

// ---------------------------------------------------------------------------

void main() {
  group('alarm_history schema v8, against a real Postgres', () {
    setUpAll(() async {
      // Two AppDatabase instances are open at once ON PURPOSE — one per
      // subject, each against its own physical database. Drift's warning is
      // about two instances sharing ONE executor, which is not what this is.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      await startDockerCompose();
      await waitForDatabaseReady();
      admin = await getTestConnection();

      for (final name in databaseNames.values) {
        await admin.execute('DROP DATABASE IF EXISTS "$name" WITH (FORCE)');
        await admin.execute('CREATE DATABASE "$name"');
      }

      // ---- the created subject -------------------------------------------
      // drift builds the whole schema from the current table definitions.
      final createdName = databaseNames[createdSubject]!;
      final created = await AppDatabase.create(configFor(createdName));
      migrationFailures[createdSubject] = await errorOf(created.open);
      drifts[createdSubject] = created;
      conns[createdSubject] = await connectTo(createdName);

      // Read drift's marker off a database drift itself wrote, so the stamp
      // below uses the name drift reads rather than one recalled from memory.
      // Left null when the marker is not there — a fixture whose creation
      // threw has no marker to read, and arm 3 says so rather than dying here.
      try {
        markerAsDriftWroteIt = await readDriftMarker(conns[createdSubject]!);
      } catch (_) {
        markerAsDriftWroteIt = null;
      }

      // ---- the upgraded subject ------------------------------------------
      final upgradedName = databaseNames[upgradedSubject]!;
      final seed = await connectTo(upgradedName);
      for (final stmt in v6Ddl) {
        await seed.execute(stmt);
      }
      // Drift's Postgres version delegate keeps one row in `__schema`; the
      // shape here is `_PgVersionDelegate.init()`'s, and the SELECT above
      // proved this database engine answers through it.
      await seed.execute(
          'CREATE TABLE IF NOT EXISTS __schema (version integer NOT NULL DEFAULT 0)');
      await seed.execute('INSERT INTO __schema (version) VALUES (6)');
      await seed.close();

      // Opening the REAL AppDatabase is what runs onUpgrade(6, 7).
      final upgraded = await AppDatabase.create(configFor(upgradedName));
      migrationFailures[upgradedSubject] = await errorOf(upgraded.open);
      drifts[upgradedSubject] = upgraded;
      conns[upgradedSubject] = await connectTo(upgradedName);

      fixtureUp = true;
    });

    tearDownAll(() async {
      if (!fixtureUp) return;
      for (final c in conns.values) {
        try {
          await c.close();
        } catch (_) {/* a connection an arm already closed is not a failure */}
      }
      for (final db in drifts.values) {
        try {
          await db.close();
        } catch (_) {/* same */}
      }
      for (final name in databaseNames.values) {
        try {
          await admin.execute('DROP DATABASE IF EXISTS "$name" WITH (FORCE)');
        } catch (_) {/* a leftover database is noise, not a failure */}
      }
      await admin.close();
      await stopDockerCompose();
    });

    // No arm may see another arm's rows. The lane is shared and an arm that
    // depends on ordering is an arm that goes flaky on CI.
    setUp(() async {
      for (final c in conns.values) {
        await c.execute('TRUNCATE TABLE alarm_history, alarm CASCADE');
      }
    });

    test('the fixture: neither subject\'s migration threw', () {
      for (final subject in subjects) {
        expect(migrationFailures[subject], isNull,
            reason: 'the migration for the "$subject" subject THREW: '
                '${describe(migrationFailures[subject])}. Every arm below is '
                'about the shape v8 produces, and none of them can mean '
                'anything until it produces one. On a real station this is '
                'not a failed test — it is a backend that will not open its '
                'database.');
      }
    });

    for (final subject in subjects) {
      group(subject, () {
        // -------------------------------------------------------------- 1 --
        test('arm 1: alarm_history carries no foreign key to alarm', () async {
          final found = await foreignKeysToAlarm(conns[subject]!);
          expect(found, isEmpty,
              reason: 'alarm_history still references the alarm table through '
                  '${found.join(', ')}. Nothing in this codebase ever inserts '
                  'into `alarm` (definitions live in the alarm_man_config '
                  'preference JSON), so on Postgres every history insert is a '
                  'guaranteed 23503. D-5 change 1 drops it.');
        });

        // -------------------------------------------------------------- 2 --
        test('arm 2: an insert for an alarm uid no alarm row names succeeds',
            () async {
          final c = conns[subject]!;
          final error = await errorOf(() async {
            await insertLegacyHistory(c, uid: 'uid-that-is-in-no-alarm-row');
          });
          expect(error, isNull,
              reason: 'the insert was refused: ${describe(error)} '
                  '(SQLSTATE ${sqlState(error) ?? 'none'}). SQLSTATE 23503 is '
                  'foreign_key_violation and it is the live production defect '
                  'P-1 names: the FK guarantees every alarm_history insert '
                  'fails on Postgres, invisible only because SVN has zero '
                  'alarms configured.');
          expect(await historyCount(c), 1,
              reason: 'the row must actually be there, not merely un-refused');
        });

        // -------------------------------------------------------------- 4 --
        test(
            'arm 4: a second OPEN row for the same (alarm_uid, rule_index) is '
            'refused by the database', () async {
          final c = conns[subject]!;

          final firstId = await insertHistory(c, uid: 'CN04.MOT01', ruleIndex: 0);

          final clash = await errorOf(() async {
            await insertHistory(c, uid: 'CN04.MOT01', ruleIndex: 0);
          });
          expect(clash, isNotNull,
              reason: 'two open rows for one alarm-rule were storable. D-4 '
                  'reads a row as ONE interval with a nullable end, so a '
                  'second open row double-counts every stop. The partial '
                  'unique index makes it unrepresentable rather than merely '
                  'discouraged — application discipline does not survive a '
                  'crash between the SELECT and the INSERT.');
          expect(sqlState(clash), '23505',
              reason: 'expected unique_violation; got ${describe(clash)}');
          expect(await historyCount(c), 1,
              reason: 'the refused insert must not have landed');

          // Closing the first row must free the slot: the index is partial,
          // and a row with a deactivation time is no longer open.
          await c.execute(
            pg.Sql.named(
                'UPDATE alarm_history SET deactivated_at = @ts WHERE id = @id'),
            parameters: <String, Object?>{
              'ts': pg.TypedValue(pg.Type.text, '2026-09-06T11:00:00.000Z'),
              'id': pg.TypedValue(pg.Type.bigInteger, firstId),
            },
          );

          final reopen = await errorOf(() async {
            await insertHistory(c, uid: 'CN04.MOT01', ruleIndex: 0);
          });
          expect(reopen, isNull,
              reason: 'the same alarm-rule going off again after it cleared '
                  'was refused: ${describe(reopen)}. The index must carry '
                  'WHERE deactivated_at IS NULL, or history becomes '
                  'one-activation-ever per alarm rule.');
          expect(await historyCount(c), 2);
        });

        // -------------------------------------------------------------- 5 --
        test(
            'arm 5: a NULL rule_index does not pretend to be unique — two open '
            'legacy rows both insert', () async {
          final c = conns[subject]!;
          await insertHistory(c, uid: 'LEGACY.ROW');
          await insertHistory(c, uid: 'LEGACY.ROW');
          expect(await historyCount(c), 2,
              reason: 'Postgres treats NULLs as DISTINCT in a unique index, so '
                  'the open-row guarantee holds only for rows written WITH a '
                  'rule index. This is measured rather than assumed so that '
                  'nobody later "fixes" the index into COALESCE(rule_index, '
                  '-1) and starts refusing legacy rows.');
        });

        // -------------------------------------------------------------- 6 --
        test(
            'arm 6: deactivated_at takes a real SQL NULL through the '
            '\$9::timestamp cast, and refuses the empty string', () async {
          final db = drifts[subject]!;
          final c = conns[subject]!;

          // The exact parameterised shape AlarmMan._addToDb uses.
          const insertSql = r'''
            INSERT INTO alarm_history (
              alarm_uid, alarm_title, alarm_description, alarm_level,
              expression, active, pending_ack, created_at, deactivated_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8::timestamp, $9::timestamp)
          ''';

          List<Variable> bind(Variable deactivated) => <Variable>[
                Variable.withString('CN21.SNS03'),
                Variable.withString('Frystir yfirhiti'),
                Variable.withString('temperature over setpoint'),
                Variable.withString('warning'),
                Variable.withString('tank.temp > 5'),
                Variable.withBool(true),
                Variable.withBool(false),
                Variable.withString('2026-09-06T10:00:00.000Z'),
                deactivated,
              ];

          final withNull = await errorOf(() async {
            await db.customInsert(insertSql,
                variables: bind(Variable<String>(null)));
          });
          expect(withNull, isNull,
              reason: 'an activation row — the FIRST insert this codebase has '
                  'ever made with a null deactivation — was refused: '
                  '${describe(withNull)} (SQLSTATE '
                  '${sqlState(withNull) ?? 'none'}). D-4 opens a row on '
                  'activation, so this shape runs on day one.');
          expect(await historyCount(c), 1);

          final withEmptyString = await errorOf(() async {
            await db.customInsert(insertSql,
                variables: bind(Variable.withString('')));
          });
          expect(withEmptyString, isNotNull,
              reason: "''::timestamp was accepted. P-2's assumption A1 is that "
                  'it is not, and the writer therefore must not keep '
                  "`alarm.deactivated?.toIso8601String() ?? ''`. If this ever "
                  'passes, the assumption is refuted and the fallback is '
                  'merely ugly rather than fatal.');
          expect('$withEmptyString'.toLowerCase(),
              contains('invalid input syntax for type timestamp'),
              reason: 'expected the timestamp input-syntax error; got '
                  '${describe(withEmptyString)} (SQLSTATE '
                  '${sqlState(withEmptyString) ?? 'none'})');
          expect(await historyCount(c), 1,
              reason: 'the refused insert must not have landed');
        });
      });
    }

    // ------------------------------------------------------------------ 3 --
    group('the upgrade itself', () {
      test(
          'arm 3: a v6-shaped Postgres database reaches v8 — FK gone, three '
          'columns added, partial unique index created', () async {
        final c = conns[upgradedSubject]!;

        expect(markerAsDriftWroteIt, isNotNull,
            reason: "drift's own schema marker could not be read back from a "
                'database drift created, so the stamp this arm relies on is '
                'guesswork');
        expect(markerAsDriftWroteIt, drifts[createdSubject]!.schemaVersion,
            reason: 'drift wrote a different version into __schema than the '
                'one AppDatabase declares; the v6 stamp below would then mean '
                'something other than "this database is at v6"');

        // The literal, not `drifts[createdSubject]!.schemaVersion`: this arm
        // is about the upgrade arriving at a NAMED version, and reading the
        // number off the thing under test would pass for any number at all.
        // 8 rather than 7 because main's page-visibility whitelist took 7
        // when the two branches collided; the alarm change moved up.
        expect(await readDriftMarker(c), 8,
            reason: 'the upgraded database did not end at schema version 8. '
                'It was stamped 6 and opened with the real AppDatabase, so '
                'either schemaVersion is not yet 8 or onUpgrade threw.');

        final fks = await foreignKeysToAlarm(c);
        expect(fks, isEmpty,
            reason: 'the v7 Postgres arm left ${fks.join(', ')} in place. '
                'CD-4: discover the constraint name from '
                'information_schema.table_constraints rather than trusting '
                "drift's default alarm_history_alarm_uid_fkey, and tolerate "
                'zero hits (A2 — a database provisioned another way may not '
                'carry it).');

        final columns = await columnsOf(c);
        // `bigint`, because that is what drift's Postgres dialect makes of an
        // `IntColumn` and therefore what `onCreate` produces. See the
        // column-parity arm below for why the two paths agreeing is the claim
        // and this line is only half of it.
        expect(columns['rule_index'], 'bigint',
            reason: 'rule_index missing or wrongly typed. It is what gives an '
                'open row its identity (D-4); without it the table cannot '
                "tell one alarm's rules apart. Columns present: "
                '${columns.keys.join(', ')}');
        expect(columns['ts_source'], 'text',
            reason: "ts_source missing or wrongly typed — D-2's provenance "
                "label ('plant' | 'backend_receipt'). Columns present: "
                '${columns.keys.join(', ')}');
        expect(columns['deactivated_reason'], 'text',
            reason: 'deactivated_reason missing or wrongly typed — D-4 uses it '
                'to tell a measured clear from a reconstructed one. Columns '
                'present: ${columns.keys.join(', ')}');

        // Everything v6 had must still be there. An upgrade that reached the
        // right shape by rebuilding the table would pass every check above and
        // silently discard the plant's history.
        for (final legacy in <String>[
          'id',
          'alarm_uid',
          'alarm_title',
          'alarm_description',
          'alarm_level',
          'expression',
          'active',
          'pending_ack',
          'created_at',
          'deactivated_at',
          'acknowledged_at',
        ]) {
          expect(columns.containsKey(legacy), isTrue,
              reason: 'the upgrade lost the v6 column $legacy');
        }

        final indexes = await indexesOf(c);
        final open = openRowIndex(indexes);
        expect(open, isNotNull,
            reason: 'no UNIQUE index on (alarm_uid, rule_index) WHERE '
                'deactivated_at IS NULL. Indexes found: '
                '${indexes.values.join(' | ')}');
      });

      test(
          'arm 3b: the created subject carries the same partial unique index '
          'as the upgraded one', () async {
        final open = openRowIndex(await indexesOf(conns[createdSubject]!));
        expect(open, isNotNull,
            reason: 'the index was added to the v7 migration arm but not to '
                'onCreate, so a freshly created database has no index and '
                "arm 4 passes only on databases that were upgraded — which is "
                'every database except the ones a new station creates.');
      });

      test(
          'arm 3c: created and upgraded produce the SAME alarm_history — '
          'column for column, type for type', () async {
        final created = await columnsOf(conns[createdSubject]!);
        final upgraded = await columnsOf(conns[upgradedSubject]!);

        expect(upgraded, created,
            reason: 'one release produced two shapes for one table. A station '
                'that CREATES the schema and a station that UPGRADES to it '
                'share the same plant database and must not disagree about '
                'it.\n'
                '  created:  $created\n'
                '  upgraded: $upgraded\n'
                'This arm exists because the first draft of the v7 Postgres '
                "branch wrote `rule_index INTEGER` while drift's own dialect "
                'maps every IntColumn to bigint. The symptom on the upgraded '
                'shape was not a type error but SQLSTATE 08P01, "insufficient '
                'data left in message" — which reads like a driver bug and '
                'would have been diagnosed as one.');
      });
    });
  });
}
