/// The activation, deactivation and restart edges of `alarm_history`, executed
/// against a real Postgres.
///
/// ## Why these arms cannot be written anywhere else
///
/// Every property this file is about is a property of the **server**:
///
///  * `deactivated_at` being a real SQL NULL rather than `''` is measurable
///    only where `''::timestamp` raises (14-01 arm 6 measured it: SQLSTATE
///    22007, `invalid input syntax for type timestamp`). On SQLite the empty
///    string is stored happily and the arm proves nothing.
///  * "there is never a second open row for one alarm-rule" is enforced by the
///    v7 partial unique index, and arm 8 requires the **database** to be what
///    refuses — application discipline does not survive a crash between the
///    SELECT and the INSERT.
///  * `rule_index` is `bigint` on Postgres, because drift's dialect maps every
///    `IntColumn` to bigint. Getting the width wrong does not present as a type
///    error; it presents as SQLSTATE 08P01, *"insufficient data left in
///    message"*, which reads like a driver bug (14-01's decision log).
///
/// ## The lane
///
/// Port 15432 is hardcoded in `docker_compose.dart` and a parallel worktree run
/// collides (project memory `tfc-dart-integration-port-collision`). **Run this
/// file alone.** It creates and drops its own physical database, and truncates
/// `alarm_history` between arms, so no arm can see another arm's rows.
///
/// ## The shape of a "restart"
///
/// A restart here is a second `AlarmEngine` + `AlarmHistoryWriter` pair built
/// over the same connection, not a second process. What the reconciliation
/// actually depends on is the state of the table and the first post-restart
/// evaluation of each rule, and both of those are reproducible in one process.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/database.dart' show Database, DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarm_history.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart' show StateMan;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../core/relay/fake_backend_value_source.dart';
import 'docker_compose.dart';

// ---------------------------------------------------------------------------
// Instants. Three of them, and they are all different on purpose.
// ---------------------------------------------------------------------------

/// The plant's instant for the activation. `t0` from the shared fake.
final DateTime plantOnset = t0;

/// The plant's instant for the clear, an hour later.
final DateTime plantClear = t0.add(const Duration(hours: 1));

/// What the BACKEND's clock reads, all run long.
///
/// Deliberately far from both plant instants: an arm that asserts the row
/// carries the plant's instant is worth nothing if the two agree by accident.
/// The distance also exceeds `kAlarmSkewWarnAfter`, so `resolveAlarmStamp`
/// logs its skew warning — which is the honest behaviour and is left in place.
final DateTime machineNow = DateTime.utc(2026, 9, 6, 23, 45, 12);

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

final String runSuffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

final String databaseName = 'alarm_history_edges_$runSuffix';

late pg.Connection admin;
late pg.Connection conn;
late AppDatabase appDatabase;
late Database database;
late Preferences preferences;

bool fixtureUp = false;

/// A secure store that refuses, so this process never reaches a keychain.
///
/// `Preferences.create` asks `SecureStorage.getInstance()` unconditionally, and
/// the default instance on macOS prompts for the login keychain on every fresh
/// binary (project memory `macos-debug-keychain-prompts`). Nothing in this file
/// wants secret material.
final class RefusingSecureStorage implements MySecureStorage {
  const RefusingSecureStorage();

  static Never _refuse(String op) => throw StateError(
      'the alarm history lane handles no secret material: $op was asked of the '
      'refusing secure store');

  @override
  Future<String?> read({required String key}) async => _refuse('read');

  @override
  Future<void> write({required String key, required String value}) async =>
      _refuse('write');

  @override
  Future<void> delete({required String key}) async => _refuse('delete');
}

/// A `StateMan` that refuses everything, by name.
///
/// `AlarmMan.create` takes one, and arm 6's control call — `getRecentAlarms` —
/// must not touch it. A permissive stub would let the control start passing for
/// a reason that has nothing to do with what the arm claims.
final class UnusedStateMan implements StateMan {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'getRecentAlarms reached the StateMan (${invocation.memberName}); it is '
      'a database read and must not need a plant connection');
}

DatabaseConfig configFor(String name) {
  final base = getTestConfig();
  final endpoint = base.postgres!;
  return DatabaseConfig(
    postgres: pg.Endpoint(
      host: endpoint.host,
      port: endpoint.port,
      database: name,
      username: endpoint.username,
      password: endpoint.password,
    ),
    sslMode: base.sslMode,
    connectTimeout: base.connectTimeout,
    queryTimeout: base.queryTimeout,
    applicationName: 'alarm_history_edges_test',
  );
}

Future<pg.Connection> connectTo(String name) => pg.Connection.open(
      configFor(name).postgres!,
      settings: const pg.ConnectionSettings(sslMode: pg.SslMode.disable),
    );

/// The PostgreSQL SQLSTATE behind [error], unwrapping whatever put it there.
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

String describe(Object? error) =>
    error == null ? 'no error' : '${error.runtimeType}: $error';

Future<Object?> errorOf(Future<void> Function() body) async {
  try {
    await body();
    return null;
  } catch (e) {
    return e;
  }
}

// ---------------------------------------------------------------------------
// Row access — raw, so the arms judge what the server holds
// ---------------------------------------------------------------------------

typedef HistoryRow = Map<String, Object?>;

Future<List<HistoryRow>> historyRows() async {
  final rows = await conn.execute('''
    SELECT id, alarm_uid, alarm_title, alarm_description, alarm_level,
           expression, active, pending_ack, created_at, deactivated_at,
           acknowledged_at, rule_index, ts_source, deactivated_reason
      FROM alarm_history
     ORDER BY id
  ''');
  return <HistoryRow>[
    for (final row in rows) row.toColumnMap(),
  ];
}

Future<int> openRowCount() async {
  final rows = await conn
      .execute('SELECT count(*) FROM alarm_history WHERE deactivated_at IS NULL');
  return rows.first.first! as int;
}

/// Writes an open row the way a previous process would have left one.
///
/// Through the raw driver rather than through [AlarmHistoryWriter], on purpose:
/// the restart arms are about what this process does with a row it did not
/// write, and seeding through the subject would make them assertions about the
/// writer agreeing with itself.
///
/// `created_at` is bound as the **zoneless** text a real row carries, and not
/// through a `::timestamp` cast. The cast is what the writer does and is what
/// produces that shape, but a *bound* parameter inside one makes the server
/// infer the parameter's type as `timestamp` while the driver has already
/// declared it `text`, and the answer is
/// `22P03: incorrect binary data format in bind parameter 7`. Rendering the
/// stored form directly reaches the same row by a route the driver can encode.
///
/// The shape matters and is not cosmetic: a value written through
/// `::timestamp` comes back out as `2026-09-06 12:00:00` with no zone at all,
/// so a seed that used an ISO string ending in `Z` would let a UTC-handling bug
/// in the reader pass unnoticed.
Future<int> seedOpenRow({
  required String uid,
  required int ruleIndex,
  required DateTime createdAt,
  String level = 'error',
  String tsSource = 'plant',
  bool pendingAck = false,
  DateTime? acknowledgedAt,
}) async {
  final rows = await conn.execute(
    pg.Sql.named('''
      INSERT INTO alarm_history (
        alarm_uid, alarm_title, alarm_description, alarm_level,
        expression, active, pending_ack, created_at, deactivated_at,
        acknowledged_at, rule_index, ts_source
      ) VALUES (
        @uid, @title, @description, @level,
        @expression, TRUE, @ack, @created, NULL,
        @acknowledged, @ruleIndex, @tsSource
      ) RETURNING id
    '''),
    parameters: <String, Object?>{
      'uid': pg.TypedValue(pg.Type.text, uid),
      'title': pg.TypedValue(pg.Type.text, 'left open by a previous process'),
      'description': pg.TypedValue(pg.Type.text, 'seeded'),
      'level': pg.TypedValue(pg.Type.text, level),
      'expression': pg.TypedValue(pg.Type.text, 'a > 10'),
      'ack': pg.TypedValue(pg.Type.boolean, pendingAck),
      'created': pg.TypedValue(pg.Type.text, zonelessInstant(createdAt)),
      'acknowledged': pg.TypedValue(pg.Type.text,
          acknowledgedAt == null ? null : zonelessInstant(acknowledgedAt)),
      // bigInteger: drift's Postgres dialect makes `rule_index` a bigint, and
      // binding an int4 against it fails with SQLSTATE 08P01 rather than with
      // anything that names a type (14-01).
      'ruleIndex': pg.TypedValue(pg.Type.bigInteger, ruleIndex),
      'tsSource': pg.TypedValue(pg.Type.text, tsSource),
    },
  );
  return rows.first.first! as int;
}

/// An instant as `alarm_history` really holds one after a `::timestamp` cast:
/// UTC, space-separated, and carrying no zone.
String zonelessInstant(DateTime at) {
  final iso = at.toUtc().toIso8601String();
  return iso.substring(0, iso.length - 1).replaceFirst('T', ' ');
}

/// A stored instant, read the way drift reads one.
///
/// `created_at` is a TEXT column (`storeDateTimeAsText`), and a value written
/// through a `::timestamp` cast comes back out as `2026-09-06 12:00:00` with no
/// zone. Drift's own `_readDateTime` appends a `Z` in exactly that case; this
/// mirrors it, so the test and the production reader agree about what a stored
/// instant means instead of disagreeing by the machine's UTC offset.
DateTime parseStored(Object? raw) {
  final value = '$raw';
  if (RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(value)) {
    return DateTime.parse(value).toUtc();
  }
  if (value.endsWith('Z')) return DateTime.parse(value).toUtc();
  return DateTime.parse('${value}Z').toUtc();
}

// ---------------------------------------------------------------------------
// The engine harness
// ---------------------------------------------------------------------------

typedef Record = ({String key, relay.DynamicValue value});

final class RecordingPublisher implements AlarmStatePublisher {
  final List<Record> records = [];

  @override
  void publish(String key, relay.DynamicValue value) =>
      records.add((key: key, value: value));
}

final class RecordingOutput extends LogOutput {
  RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}

/// One engine over the real database, with a fake plant in front of it.
final class Harness {
  Harness._(this.values, this.publisher, this.logs, this.clock);

  /// Builds an engine whose `alarm_man_config` is [alarms].
  ///
  /// Every call is a fresh engine and a fresh writer over the SAME database —
  /// which is what "a second engine after a restart" means here.
  static Future<Harness> create(
    List<AlarmConfig> alarms, {
    bool withHistory = true,
  }) async {
    await preferences.setString(
        'alarm_man_config', jsonEncode(AlarmManConfig(alarms: alarms).toJson()));

    final logs = <String>[];
    final h = Harness._(
      FakeBackendValueSource(),
      RecordingPublisher(),
      logs,
      CountingClock(machineNow),
    );
    h.logger = Logger(
      filter: ProductionFilter(),
      level: Level.all,
      printer: SimplePrinter(colors: false),
      output: RecordingOutput(logs),
    );
    h.writer = AlarmHistoryWriter(database, logger: h.logger);
    h.engine = AlarmEngine(
      values: h.values,
      preferences: preferences,
      publisher: h.publisher,
      clock: h.clock.call,
      history: withHistory ? h.writer : null,
      logger: h.logger,
    );
    return h;
  }

  final FakeBackendValueSource values;
  final RecordingPublisher publisher;
  final List<String> logs;
  final CountingClock clock;
  late final Logger logger;
  late final AlarmHistoryWriter writer;
  late final AlarmEngine engine;

  /// Lets the plant emission land AND the database work that follows it finish.
  Future<void> settleAll() async {
    await settle();
    await engine.persistenceIdle();
    await settle();
  }

  ({List<relay.AlarmActiveEntry> entries, bool truncated, int omitted})
      get lastPayload => relay.AlarmActiveEntry.decodeList(
          publisher.records.last.value.toJson(slim: true));

  Future<void> dispose() async {
    await engine.dispose();
    await values.dispose();
  }
}

/// A stamp the plant is the source of, for the arms that drive the writer
/// directly rather than through a rule.
AlarmStamp plantStamp(DateTime at) =>
    AlarmStamp(at: at, source: AlarmTsSource.plant);

AlarmConfig alarmConfig(
  String uid,
  List<String> formulas, {
  String title = 'Frystir yfirhiti',
  String description = 'temperature over setpoint',
  AlarmLevel level = AlarmLevel.error,
  bool acknowledgeRequired = false,
}) =>
    AlarmConfig(
      uid: uid,
      title: title,
      description: description,
      rules: [
        for (final formula in formulas)
          AlarmRule(
            level: level,
            expression: ExpressionConfig(value: Expression(formula: formula)),
            acknowledgeRequired: acknowledgeRequired,
          ),
      ],
    );

// ---------------------------------------------------------------------------

void main() {
  group('alarm_history activation, deactivation and restart, against a real '
      'Postgres', () {
    setUpAll(() async {
      SecureStorage.setInstance(const RefusingSecureStorage());
      await startDockerCompose();
      await waitForDatabaseReady();
      admin = await getTestConnection();

      await admin.execute('DROP DATABASE IF EXISTS "$databaseName" WITH (FORCE)');
      await admin.execute('CREATE DATABASE "$databaseName"');

      appDatabase = await AppDatabase.create(configFor(databaseName));
      await appDatabase.open();
      database = Database(appDatabase);
      conn = await connectTo(databaseName);
      preferences = await Preferences.create(db: database);

      fixtureUp = true;
    });

    tearDownAll(() async {
      if (!fixtureUp) return;
      try {
        await conn.close();
      } catch (_) {/* an already-closed connection is not a failure */}
      try {
        await database.close();
      } catch (_) {/* same */}
      try {
        await admin
            .execute('DROP DATABASE IF EXISTS "$databaseName" WITH (FORCE)');
      } catch (_) {/* a leftover database is noise, not a failure */}
      await admin.close();
      await stopDockerCompose();
    });

    setUp(() async {
      await conn.execute('TRUNCATE TABLE alarm_history');
    });

    // ------------------------------------------------------------------ 1 --
    test(
        'arm 1: a row exists WHILE the alarm stands, carrying the plant\'s '
        'instant and no deactivation', () async {
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1),
          reason: 'D-4 opens a row on ACTIVATION. Until this plan the table '
              'only ever saw a row when an alarm cleared, so an alarm '
              'currently standing was invisible to every stop analysis and to '
              'the panel\'s own history read.');

      final row = rows.single;
      expect(row['alarm_uid'], 'CN04.MOT01');
      expect(row['active'], isTrue);
      expect(row['deactivated_at'], isNull);
      expect(row['deactivated_reason'], isNull);
      expect(row['rule_index'], 0,
          reason: 'NULLs are distinct in the partial unique index (14-01 arm '
              '5), so a writer that omits the rule index gets no open-row '
              'protection at all');
      expect(row['ts_source'], 'plant');

      expect(parseStored(row['created_at']), plantOnset,
          reason: 'the row must carry the PLANT\'s instant, not the machine\'s. '
              'The backend clock read $machineNow throughout this arm, and if '
              'the two ever agree the assertion is worth nothing.');
      expect(parseStored(row['created_at']), isNot(machineNow));

      await h.dispose();
    });

    // ------------------------------------------------------------------ 2 --
    test(
        'arm 2b: a clear whose verdict is the first after a suspension closes '
        'as inferred_input_recovery, at the recovery instant', () async {
      // The SVN rig's cooler alarm, run forward to the day the sensor comes
      // back: activation on a good reading, the input dies (D-3 holds, row
      // stays open — correctly), then the input returns with the condition
      // over. The engine never watched the condition go false; writing
      // `cleared` here would date the stop's end to whenever maintenance got
      // to the cabinet, and writing `inferred_restart` would blame a backend
      // that never went down.
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();
      final openedId = (await historyRows()).single['id'];

      h.values.push('a',
          bad(relay.Quality.badStale, at: plantOnset.add(const Duration(seconds: 12))));
      await h.settleAll();
      expect((await historyRows()).single['deactivated_at'], isNull,
          reason: 'the hold is not a clear — the row stays open');

      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final row = (await historyRows()).single;
      expect(row['id'], openedId);
      expect(row['active'], isFalse);
      expect(row['deactivated_reason'],
          AlarmHistoryWriter.reasonInferredInputRecovery,
          reason: 'a bound must be tellable from a measurement (T-14-23), '
              'and a sensor outage tellable from a restart');
      expect(parseStored(row['deactivated_at']), plantClear,
          reason: 'the best-known bound: the instant the sensor came back');
      expect(parseStored(row['created_at']), plantOnset,
          reason: 'the onset is untouched');

      await h.dispose();
    });

    test('arm 2: clearing UPDATEs that row — there is never a second one',
        () async {
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();
      final openedId = (await historyRows()).single['id'];

      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1),
          reason: 'two rows double-count every stop: alarmHistoryOverlaps '
              '(alarm.dart:212) and StopIntervalSource both read a row as ONE '
              'interval with a nullable end');
      final row = rows.single;
      expect(row['id'], openedId, reason: 'the SAME row, updated');
      expect(row['active'], isFalse);
      expect(parseStored(row['deactivated_at']), plantClear,
          reason: 'stamped by the CLEARING evaluation, from the plant');
      expect(row['deactivated_reason'], AlarmHistoryWriter.reasonCleared);
      expect(parseStored(row['created_at']), plantOnset,
          reason: 'and the onset is untouched');

      await h.dispose();
    });

    // ------------------------------------------------------------------ 3 --
    test(
        'arm 3: deactivated_at on an open row is a real SQL NULL, and the '
        'insert does not raise the timestamp syntax error', () async {
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();

      // Asserted with IS NULL at the server, not with an empty-string
      // comparison in Dart: `''` and NULL are indistinguishable once a row has
      // been read into an object, and it is the server that tells them apart.
      expect(await openRowCount(), 1,
          reason: 'P-2. `alarm.dart:490` binds '
              "`alarm.deactivated?.toIso8601String() ?? ''` and 14-01 arm 6 "
              "measured `''::timestamp` raising SQLSTATE 22007 against a real "
              'server. The activation row is the first insert this codebase '
              'has ever made with an empty deactivation, so it meets that on '
              'day one.');

      final empties = await conn.execute(
          "SELECT count(*) FROM alarm_history WHERE deactivated_at = ''");
      expect(empties.first.first, 0,
          reason: 'an empty string is not an absent deactivation; a stop '
              'analysis reading it would see a clear at the beginning of time');

      expect(
        h.logs.where(
            (l) => l.toLowerCase().contains('invalid input syntax for type')),
        isEmpty,
        reason: 'the engine swallows persistence failures by design (T-14-24), '
            'so a broken insert shows up as a log line and an empty table '
            'rather than as a thrown error. This is the line it would leave.',
      );

      await h.dispose();
    });

    // ------------------------------------------------------------------ 4 --
    test(
        'arm 4: a restart ADOPTS an open row whose rule is still true — no '
        'second row, and the ORIGINAL created_at survives', () async {
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
      );

      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      // The rule's FIRST post-restart evaluation, and it is still true.
      h.values.push('a', good(20.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1),
          reason: 'adopting means inserting NOTHING. A second row here is a '
              'plant that appears to have stopped twice for one fault.');
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull);
      expect(parseStored(rows.single['created_at']), plantOnset,
          reason: 'keeping the plant\'s own start instant across a restart is '
              'the whole point of D-4\'s adopt branch; re-stamping it with the '
              'restart would shorten every stop that spans one');

      // And the live entry agrees with the row it adopted.
      final entry = h.lastPayload.entries.single;
      expect(entry.uid, 'CN04.MOT01');
      expect(entry.activeAt, plantOnset);
      expect(entry.historyId, '$seededId');
      expect(h.engine.pendingAdoptionCount, 0);

      await h.dispose();
    });

    // ------------------------------------------------------------------ 5 --
    test(
        'arm 5: a restart CLOSES an open row whose rule is no longer true, and '
        'labels it inferred_restart', () async {
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
      );

      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1), reason: 'closed, never erased');
      expect(rows.single['id'], seededId);
      expect(rows.single['active'], isFalse);
      expect(parseStored(rows.single['deactivated_at']), plantClear,
          reason: 'the instant of the evaluation that found it false — the '
              'best-known bound on when it really cleared');
      expect(rows.single['deactivated_reason'],
          AlarmHistoryWriter.reasonInferredRestart,
          reason: 'labelled, so a stop analysis can tell a measured clear from '
              'a reconstructed one. Writing `cleared` here would make a guess '
              'indistinguishable from a measurement.');
      expect(h.engine.active, isEmpty);
      expect(h.engine.pendingAdoptionCount, 0);

      await h.dispose();
    });

    // ------------------------------------------------------------------ 6 --
    test(
        'arm 6: a restart CLOSES an open row whose alarm definition is gone — '
        'and getRecentAlarms would never have found it', () async {
      final seededId = await seedOpenRow(
        uid: 'DELETED.ALARM',
        ruleIndex: 0,
        createdAt: plantOnset,
      );

      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();
      await h.engine.persistenceIdle();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['active'], isFalse);
      expect(rows.single['deactivated_reason'],
          AlarmHistoryWriter.reasonInferredConfigChange);
      expect(parseStored(rows.single['deactivated_at']), machineNow,
          reason: 'there is no rule left to evaluate, so there is no plant '
              'instant to be had; the backend\'s own receipt is what it is, '
              'and it is labelled as such');

      // The control. `getRecentAlarms` drops every row whose alarmUid is not
      // in the current config (alarm.dart:525-533), which is EXACTLY the set
      // this branch exists to close (P-9). Reading open rows through it would
      // leave a deleted alarm's row open forever, invisibly.
      final alarmMan = await AlarmMan.create(preferences, UnusedStateMan(),
          // Required as of 14-07 (D-2: no file on the alarm path reads a real
          // clock). This file's own fixed backend instant, so nothing here
          // reads a wall clock either.
          clock: () => machineNow);
      final recent = await alarmMan.getRecentAlarms();
      expect(recent.map((a) => a.alarm.config.uid), isNot(contains('DELETED.ALARM')),
          reason: 'if getRecentAlarms ever DID return this row, the direct '
              'query in loadOpenRows would be redundant and this arm would '
              'have stopped being evidence for it');

      await h.dispose();
    });

    // ------------------------------------------------------------------ 7 --
    test(
        'arm 7: an open row whose rule never reaches a good evaluation is left '
        'ALONE, and the engine says so', () async {
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
      );

      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      // The input arrives, but never in the good band — 13-RIG-PROBE FIND-2's
      // measured shape for a first-ever subscriber. D-3 suspends the rule, so
      // there is no first evaluation and therefore no verdict to reconcile on.
      h.values.push('a', bad(relay.Quality.uncertainNotYetKnown, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull,
          reason: '"we do not know" is the honest state (D-4\'s fourth row). '
              'Closing it would invent a clear; deleting it would erase a stop '
              'that may still be running.');
      expect(parseStored(rows.single['created_at']), plantOnset);

      expect(h.engine.pendingAdoptionCount, 1);
      expect(
        h.logs.where((l) => l.contains('left open by a previous process')),
        isNotEmpty,
        reason: 'an unresolved row that nothing reports is the silence this '
            'whole milestone exists to remove',
      );

      await h.dispose();
    });

    // ------------------------------------------------------------------ 8 --
    test(
        'arm 8: the DATABASE refuses a second open row for one alarm-rule, '
        'with SQLSTATE 23505', () async {
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      final alarm = alarmConfig('CN04.MOT01', ['a > 10']);

      Future<int> open() => h.writer.openActivation(
            alarm: alarm,
            ruleIndex: 0,
            rule: alarm.rules.first,
            expression: 'a > 10',
            stamp: plantStamp(plantOnset),
          );

      await open();

      final clash = await errorOf(() async {
        await open();
      });
      expect(clash, isNotNull,
          reason: 'two open rows for one alarm-rule were storable. Discipline '
              'does not survive a crash between the SELECT and the INSERT, so '
              'the guarantee has to live in the schema.');
      expect(sqlState(clash), '23505',
          reason: 'and it must be the partial unique index that refuses, not '
              'the application politely declining: got ${describe(clash)}');
      expect(await historyRows(), hasLength(1));

      await h.dispose();
    });

    // ------------------------------------------------------------------ 9 --
    test('arm 9: historyId reaches the wire, so a panel can correlate without '
        'a second query', () async {
      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();

      final rowId = (await historyRows()).single['id'];
      final entry = h.lastPayload.entries.single;
      expect(entry.uid, 'CN04.MOT01');
      expect(entry.ruleIndex, 0);
      expect(entry.historyId, '$rowId',
          reason: 'D-9: the row id travels with the live entry. Null here is '
              'what 14-05 shipped and what this plan replaces.');
      expect(h.publisher.records.last.value.quality, relay.Quality.good);

      await h.dispose();
    });

    // ----------------------------------------------------------------- 11 --
    test(
        'arm 11: an alarm title containing a SQL payload round-trips intact, '
        'and the table is still there', () async {
      const payload = "Frystir '); DROP TABLE alarm_history; --";
      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'],
            title: payload, description: payload),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1),
          reason: 'T-14-21: operator text reaches SQL. If the table were gone '
              'this query would raise 42P01 instead of returning a row.');
      expect(rows.single['alarm_title'], payload,
          reason: 'intact, character for character — bound, never interpolated');
      expect(rows.single['alarm_description'], payload);

      await h.dispose();
    });

    // ----------------------------------------------------- CR-02 (14-REVIEW)
    //
    // `pending_ack` was write-once-false. The INSERT bound
    // `Variable.withBool(false)` and NO statement in `backend_alarm_history`
    // ever updated the column, so the engine's `existing.pendingAck = true`
    // lived in memory and nowhere else.
    //
    // What that costs is not theoretical, because this backend restarts on
    // **every** `alarm_man_config` or `key_mappings` save (`main.dart:436-458`).
    // An `acknowledgeRequired` rule that fires at 08:00 and clears at 08:01
    // with nobody at the screen is, at 08:05, an open row whose rule evaluates
    // false — so `_resolveAdoption` closed it as `inferred_restart`. The fault
    // never reached any banner, and the history said "reconstructed after a
    // restart" rather than "an unacknowledged fault occurred". The whole
    // `acknowledgeRequired` feature did not survive a restart.
    //
    // **The related hazard the fix must not open**, named by the reviewer:
    // persisting the column alone makes `backend_alarms.dart:836`
    // (`adopted.pendingAck = pending.pendingAck`) live, and then a row that is
    // `pending_ack = TRUE` while its rule is TRUE AGAIN at restart is adopted
    // pending-ack — after which `acknowledge()` takes the `entry.pendingAck`
    // branch and CLOSES a standing alarm's row at the receipt instant. That is
    // T-14-56, the exact invariant 14-14 exists for. Arm 15 is that arm.

    // ----------------------------------------------------------------- 12 --
    test(
        'arm 12: an acknowledgeRequired rule that clears writes pending_ack on '
        'its OPEN row', () async {
      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();
      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      // The engine's own view: held on the banner, badged, row still open.
      expect(h.lastPayload.entries.single.pendingAck, isTrue,
          reason: 'the premise: the engine is holding this one for an '
              'acknowledgement');

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['deactivated_at'], isNull,
          reason: 'an acknowledgeRequired rule that cleared is still on the '
              'banner and its row is still open — 14-14\'s shape, unchanged');
      expect(rows.single['pending_ack'], isTrue,
          reason: 'the row must say that a fault is waiting to be seen. It '
              'said FALSE, always, because the INSERT bound the literal false '
              'and nothing ever updated the column — so the only record of an '
              'unacknowledged fault was a boolean in this process\'s memory, '
              'and this backend restarts on every alarm_man_config or '
              'key_mappings save.');

      await h.dispose();
    });

    // ----------------------------------------------------------------- 13 --
    test(
        'arm 13: a restart does NOT erase an unacknowledged fault — the row '
        'stays open and the alarm is back on the banner, badged', () async {
      // Exactly what the previous process left behind: fired, cleared, nobody
      // saw it, backend restarted.
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
        pendingAck: true,
      );

      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();

      // The rule's first post-restart evaluation, and it is false — because
      // the condition really did clear before the restart.
      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull,
          reason: 'the row was closed as inferred_restart and the fault '
              'vanished. An acknowledgeRequired rule that fires and clears '
              'between two glances at the screen is exactly the fault that '
              'feature exists for, and a restart erased it.');
      expect(rows.single['deactivated_reason'], isNull);

      final entries = h.lastPayload.entries;
      expect(entries, hasLength(1),
          reason: 'and nobody was ever told. Got: $entries');
      expect(entries.single.uid, 'CN04.MOT01');
      expect(entries.single.pendingAck, isTrue,
          reason: 'held, badged, waiting to be seen — the state the previous '
              'process was in when it went down');
      expect(entries.single.activeAt, plantOnset,
          reason: 'and it keeps the plant\'s own onset, as every adoption does');
      expect(h.engine.pendingAdoptionCount, 0);

      await h.dispose();
    });

    // ----------------------------------------------------------------- 14 --
    test(
        'arm 14: acknowledging that adopted fault closes the row, and says the '
        'end instant is a reconstruction', () async {
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
        pendingAck: true,
      );

      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();
      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      await h.engine.acknowledge('CN04.MOT01', 0);
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['active'], isFalse);
      expect(parseStored(rows.single['acknowledged_at']), machineNow,
          reason: 'somebody saw it, and that is a durable fact');
      expect(parseStored(rows.single['deactivated_at']), plantClear,
          reason: 'the first post-restart evaluation that found the rule '
              'false is the best-known bound on when it really cleared. This '
              'process never watched the clear happen — the previous one did '
              'and did not record when.');
      expect(rows.single['deactivated_reason'],
          AlarmHistoryWriter.reasonInferredRestart,
          reason: 'NOT "acknowledged". That reason means the row closed at the '
              'clearing evaluation this engine MEASURED; here the instant is '
              'reconstructed, and a stop analysis must be able to tell those '
              'apart (T-14-23). The acknowledgement is still recorded — in '
              'acknowledged_at, which is where it belongs.');
      expect(h.engine.active, isEmpty);
      expect(h.engine.acknowledgedStandingCount, 0);

      await h.dispose();
    });

    // ----------------------------------------------------------------- 15 --
    test(
        'arm 15: THE TRAP — a pending_ack row whose rule is TRUE again is '
        'adopted STANDING, and acknowledging it leaves the row OPEN', () async {
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
        pendingAck: true,
      );

      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();

      // The condition is true at the first post-restart evaluation. Whatever
      // the row says about a previous clear, this alarm is HAPPENING.
      h.values.push('a', good(20.0, at: plantClear));
      await h.settleAll();

      expect(h.lastPayload.entries.single.pendingAck, isFalse,
          reason: 'a rule that is true is standing, not waiting to be seen. '
              'Adopting the row\'s pending_ack here is what makes the '
              'acknowledge below close a stop that is still running.');

      await h.engine.acknowledge('CN04.MOT01', 0);
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull,
          reason: 'T-14-56, and it is the headline of 14-14: acknowledging is '
              'NOT clearing. The condition is still true, so the stop is still '
              'happening. A row closed here reports a two-hour stop as having '
              'lasted as long as it took an operator to press a button — '
              'silently, in the direction nobody audits.');
      expect(rows.single['deactivated_reason'], isNull);
      expect(rows.single['active'], isTrue);
      expect(parseStored(rows.single['acknowledged_at']), machineNow,
          reason: 'silenced and recorded, which is all an acknowledgement is');
      expect(h.engine.acknowledgedStandingCount, 1,
          reason: 'the engine still holds it — its row is open and this object '
              'is the only thing that can close it when the plant finally does');
      expect(h.engine.active, isEmpty, reason: 'and it is off the banner');

      await h.dispose();
    });

    // ---------------------------------------------------------------- 15b --
    test(
        'arm 15b: a pending_ack row that was ALREADY acknowledged is closed, '
        'not put back on the banner', () async {
      // The only way this row exists is that the close after the
      // acknowledgement did not land — a database outage between the two
      // writes. Re-badging it would ask an operator to acknowledge something
      // they already have, and would overwrite the instant they first saw it.
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
        pendingAck: true,
        acknowledgedAt: machineNow,
      );

      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();
      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNotNull,
          reason: 'it cleared, somebody saw it, and the row had no reason to '
              'stay open');
      expect(rows.single['deactivated_reason'],
          AlarmHistoryWriter.reasonInferredRestart);
      expect(parseStored(rows.single['acknowledged_at']), machineNow,
          reason: 'and the original acknowledgement stands, unre-stamped');
      expect(h.lastPayload.entries, isEmpty);

      await h.dispose();
    });

    // ----------------------------------------------------------------- 16 --
    test(
        'arm 16: a STANDING acknowledged alarm survives a restart still OPEN '
        'and still off the banner', () async {
      // The property the CR-02 fix is judged against as much as on the ones it
      // repairs: nothing here may regress. 14-14 pinned it end to end over a
      // socket; this is the same claim in the engine lane, where it can be run
      // in seconds against every mutation below.
      final seededId = await seedOpenRow(
        uid: 'CN04.MOT01',
        ruleIndex: 0,
        createdAt: plantOnset,
        acknowledgedAt: machineNow,
      );

      final h = await Harness.create([alarmConfig('CN04.MOT01', ['a > 10'])]);
      await h.engine.start();
      h.values.push('a', good(20.0, at: plantClear));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(1));
      expect(rows.single['id'], seededId);
      expect(rows.single['deactivated_at'], isNull,
          reason: 'the stop is still running');
      expect(parseStored(rows.single['acknowledged_at']), machineNow,
          reason: 'the acknowledgement the previous process recorded is the '
              'one that stands');
      expect(h.engine.acknowledgedStandingCount, 1);
      expect(h.lastPayload.entries, isEmpty,
          reason: 'an alarm an operator had already silenced came back on the '
              'banner after a restart, indistinguishable from nobody having '
              'pressed the button');

      await h.dispose();
    });

    // ----------------------------------------------------------------- 17 --
    test(
        'arm 17: a held alarm whose condition COMES BACK gets its own row, and '
        'the held one is closed rather than orphaned', () async {
      // Reachable with no restart at all, and reachable more often with one:
      // an intermittent acknowledgeRequired fault. The held entry's row is
      // still open, so the second activation's INSERT meets the v7 partial
      // unique index (23505) — which `_enqueueWrite` swallows. The new stop
      // then has no row at all and the old one stays open forever, growing.
      final h = await Harness.create([
        alarmConfig('CN04.MOT01', ['a > 10'], acknowledgeRequired: true),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: plantOnset));
      await h.settleAll();
      h.values.push('a', good(1.0, at: plantClear));
      await h.settleAll();

      final second = plantClear.add(const Duration(hours: 1));
      h.values.push('a', good(20.0, at: second));
      await h.settleAll();

      final rows = await historyRows();
      expect(rows, hasLength(2),
          reason: 'two activations are two stops. Got: $rows');

      final first = rows.first;
      expect(parseStored(first['created_at']), plantOnset);
      expect(parseStored(first['deactivated_at']), plantClear,
          reason: 'the completed stop keeps the end the plant gave it');
      expect(first['deactivated_reason'], AlarmHistoryWriter.reasonCleared);

      final latest = rows.last;
      expect(parseStored(latest['created_at']), second);
      expect(latest['deactivated_at'], isNull);
      expect(
        h.logs.where((l) => l.contains('23505')),
        isEmpty,
        reason: 'and the database was never asked for a second open row for '
            'one alarm-rule — the refusal is swallowed by design (T-14-24), so '
            'this is the only place it would show',
      );

      await h.dispose();
    });
  });
}
