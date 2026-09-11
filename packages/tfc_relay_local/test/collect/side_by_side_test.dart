/// Two writers, one database, and the proof that neither sees the other's
/// rows — against a **real TimescaleDB** (the fixture refuses to run
/// against plain Postgres; that is the first case in the file).
///
/// The stand-in for the app's collector is not an impression of it: it is a
/// bare `Database` doing `registerRetentionPolicy` then
/// `insertTimeseriesData` against the unprefixed name, which is literally
/// what `collector.dart:216` and `:248` do per entry. The gateway side is
/// the real `TimescaleSink` on its production connect path, advisory lock
/// included.
///
/// Every table name carries a per-run random suffix and every test drops
/// what it created; the last case asserts the suite left nothing behind. A
/// suite that leaves hypertables behind poisons the next run's counts, and
/// on a developer's machine it poisons them for months.
@TestOn('vm')
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:math';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_relay_local/src/collect/advisory_lock.dart';
import 'package:tfc_relay_local/src/collect/timescale_sink.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart'
    show CollectionConfig, CollectionEndpoint;
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import '../support/timescale_fixture.dart';
import 'package:tfc_stateman_contract/testing/runner_budget.dart'
    show budgetScale, useRunnerBudgets;

late TimescaleFixture fx;
late pg.Connection admin;

/// The per-run suffix every table name carries.
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

/// Everything any test created; dropped in its own tearDown, and the last
/// case proves the set is empty server-side.
final Set<String> createdTables = <String>{};
final List<TimescaleSink> sinks = <TimescaleSink>[];
final List<Database> writers = <Database>[];

String freshTable(String base) {
  final name = '${base}_$suffix';
  createdTables.addAll([name, 'gw_$name', 'gwb_$name']);
  return name;
}

CollectionConfig gatewayConfig({String prefix = 'gw_', bool sole = false}) =>
    CollectionConfig(
      enabled: true,
      tablePrefix: prefix,
      soleWriter: sole,
      endpoint: CollectionEndpoint(
        host: fx.host,
        port: fx.port,
        database: fx.database,
        username: fx.username,
        password: fx.password,
      ),
      connectTimeout: const Duration(seconds: 2),
      queryTimeout: const Duration(seconds: 5),
    );

Future<void> fastSleep(Duration _) =>
    Future<void>.delayed(const Duration(milliseconds: 100));

TimescaleSink newSink(String publisher,
    {String prefix = 'gw_', bool sole = false}) {
  final sink = TimescaleSink(
    gatewayConfig(prefix: prefix, sole: sole),
    publisherId: publisher,
    useIsolate: false, // the fixture knob: keep Postgres work in-process
    sleep: fastSleep,
  );
  sinks.add(sink);
  return sink;
}

/// The app's collector, reduced to the two calls it actually makes.
Future<Database> appWriter() async {
  final db = Database(await AppDatabase.create(DatabaseConfig(
    postgres: pg.Endpoint(
      host: fx.host,
      port: fx.port,
      database: fx.database,
      username: fx.username,
      password: fx.password,
    ),
    sslMode: pg.SslMode.disable,
    connectTimeout: const Duration(seconds: 2),
    queryTimeout: const Duration(seconds: 5),
    applicationName: 'app-collector-standin',
  )));
  await db.open();
  writers.add(db);
  return db;
}

Future<void> waitConnected(TimescaleSink sink, String who) => within(
    sink.connected.firstWhere((up) => up), '$who reaching the database',
    budget: const Duration(seconds: 30));

Future<int> countOrZero(String table) async {
  try {
    final rows = await admin.execute('SELECT count(*) FROM "$table"');
    return rows.first.first as int;
  } on Object catch (error) {
    if (error.toString().contains('42P01')) return 0; // does not exist yet
    rethrow;
  }
}

/// Flushes and re-counts until [table] holds [expected] rows — and fails on
/// an overshoot immediately, because an overshoot IS the doubling defect.
Future<void> pumpUntilCount(TimescaleSink sink, String table, int expected,
    {Duration budget = const Duration(seconds: 30)}) async {
  // Scaled for a hosted runner — `check.dart`'s `budgetScale`. These are
  // liveness bounds against a real Postgres, and 30 s written here was a
  // bet about the macOS agent that this file lost.
  final deadline = DateTime.now().add(budget * budgetScale);
  while (true) {
    await sink.flush();
    final n = await countOrZero(table);
    if (n >= expected) {
      expect(n, expected,
          reason: '"$table" holds more rows than its one writer produced — '
              'a second writer is in the namespace');
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('"$table" held $n of $expected rows after '
          '${budget.inSeconds}s of flushing');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> eventuallyAsync(
    Future<bool> Function() condition, String what,
    {Duration budget = const Duration(seconds: 30)}) async {
  // Scaled for a hosted runner — `check.dart`'s `budgetScale`. These are
  // liveness bounds against a real Postgres, and 30 s written here was a
  // bet about the macOS agent that this file lost.
  final deadline = DateTime.now().add(budget * budgetScale);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('$what did not become true within ${budget.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<bool> lockSessionExists(String applicationName) async {
  final rows = await admin.execute(
    r'SELECT count(*) FROM pg_stat_activity WHERE application_name = $1',
    parameters: [applicationName],
  );
  return (rows.first.first as int) > 0;
}

void main() {
  useRunnerBudgets();

  final realLevel = Logger.level;

  setUpAll(() async {
    Logger.level = Level.off;
    fx = await TimescaleFixture.start();
    admin = await fx.connect();
  });

  tearDownAll(() async {
    await admin.close();
    await fx.stop();
    Logger.level = realLevel;
  });

  tearDown(() async {
    // Writers first, THEN tables: a sink closed after its table is dropped
    // would recreate it from its own retry queue on the way down.
    for (final sink in sinks) {
      await sink.close();
    }
    sinks.clear();
    for (final writer in writers) {
      await writer.close();
    }
    writers.clear();
    for (final table in createdTables) {
      await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
    }
  });

  test('anti-vacuity: the server is TimescaleDB, not plain Postgres',
      () async {
    final rows = await admin.execute(
        "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'");
    expect(rows, isNotEmpty,
        reason: 'no timescaledb extension — this suite would pass every '
            'count assertion against plain Postgres and prove nothing '
            'about hypertables (T-8b-09). Fix the fixture, not the test');
    final version = rows.first.first as String?;
    print('timescaledb extversion: $version');
    expect(version, isNotNull);
  });

  test('the lock key is computed in Dart: FNV-1a 64, deterministic, '
      'namespace-sensitive', () {
    // Reference values, so the number cannot silently depend on a Postgres
    // version's hashtext(): FNV-1a 64 of '' is the offset basis, of 'a' the
    // published test vector.
    expect(fnv1a64(''), 0xcbf29ce484222325);
    expect(fnv1a64('a'), 0xaf63dc4c8601ec8c);

    final key = AdvisoryLock.lockKeyFor(database: 'testdb', tablePrefix: 'gw_');
    expect(key, AdvisoryLock.lockKeyFor(database: 'testdb', tablePrefix: 'gw_'),
        reason: 'two gateways must compute the same key or the lock guards '
            'nothing');
    expect(key,
        isNot(AdvisoryLock.lockKeyFor(database: 'testdb', tablePrefix: '')),
        reason: 'the lock is per namespace, not per database');
    expect(key,
        isNot(AdvisoryLock.lockKeyFor(database: 'other', tablePrefix: 'gw_')),
        reason: 'and per database');
  });

  test('rows land: N rows in the prefixed table, and it is a hypertable',
      () async {
    final base = freshTable('landing');
    final sink = newSink('alpha');
    await sink.start();
    await waitConnected(sink, 'the gateway sink');

    await sink.ensureTable(
        'gw_$base', const RetentionPolicy(dropAfter: Duration(days: 30)));
    for (var i = 1; i <= 7; i++) {
      await sink.insert('gw_$base',
          DateTime.utc(2026, 1, 1).add(Duration(seconds: i)), i.toDouble());
    }
    await pumpUntilCount(sink, 'gw_$base', 7);

    final hyper = await admin.execute(
      r'SELECT hypertable_name FROM timescaledb_information.hypertables '
      r'WHERE hypertable_name = $1',
      parameters: ['gw_$base'],
    );
    expect(hyper, isNotEmpty,
        reason: 'the prefixed table must be a real hypertable, not a plain '
            'table that happens to hold rows');

    final unprefixed = await admin.execute(
      r'SELECT count(*) FROM information_schema.tables WHERE table_name = $1',
      parameters: [base],
    );
    expect(unprefixed.first.first, 0,
        reason: 'the gateway must not have created the unprefixed table — '
            'that name belongs to the app\'s collector');
  });

  test("the app's table is untouched: N, M, and N+M nowhere — and its "
      'retention policy does not flip', () async {
    final base = freshTable('iso');

    // The app side first: M rows, retention 10 days, unprefixed — the two
    // calls collector.dart makes, nothing else.
    const appRetention = RetentionPolicy(dropAfter: Duration(days: 10));
    final app = await appWriter();
    await app.registerRetentionPolicy(base, appRetention);
    for (var m = 1; m <= 5; m++) {
      await app.insertTimeseriesData(base,
          DateTime.utc(2026, 2, 1).add(Duration(seconds: m)), m * 1.0);
    }
    await app.flush();
    await eventuallyAsync(() async => await countOrZero(base) == 5,
        "the app stand-in's five rows landing");

    final before = await app.db.getRetentionPolicy(base);
    expect(before, isNotNull);
    expect(before!.dropAfter, appRetention.dropAfter,
        reason: 'the app installed 10 days and 10 days must be there before '
            'the gateway enters');
    print('app table retention before gateway: ${before.dropAfter}');

    // The gateway side: N rows, a DIFFERENT retention, prefixed.
    final sink = newSink('alpha');
    await sink.start();
    await waitConnected(sink, 'the gateway sink');
    await sink.ensureTable(
        'gw_$base', const RetentionPolicy(dropAfter: Duration(days: 3)));
    for (var n = 1; n <= 7; n++) {
      await sink.insert('gw_$base',
          DateTime.utc(2026, 2, 2).add(Duration(seconds: n)), n * 10.0);
    }
    await pumpUntilCount(sink, 'gw_$base', 7);

    // The three numbers.
    final appCount = await countOrZero(base);
    final gatewayCount = await countOrZero('gw_$base');
    expect(gatewayCount, 7, reason: 'N in the prefixed table');
    expect(appCount, 5, reason: 'M in the unprefixed table, exactly');
    expect(appCount, isNot(12),
        reason: 'N+M in the app\'s table is the doubling defect');
    expect(gatewayCount, isNot(12),
        reason: 'N+M in the gateway\'s table is the same defect mirrored');

    // The retention fight not happening: remove_retention_policy /
    // add_retention_policy never ran against the app's table, even though
    // the gateway is configured with a different retention.
    final after = await app.db.getRetentionPolicy(base);
    expect(after, isNotNull);
    expect(after!.dropAfter, before.dropAfter,
        reason: 'two collectors whose configs differ would uninstall each '
            'other\'s policy at every start (database.dart:847-864) — '
            'distinct namespaces is what makes that fight impossible');
    print('app table retention after gateway ran: ${after.dropAfter}');
  });

  test('a second gateway on the same namespace is refused, names the '
      'holder, and the first keeps working', () async {
    final base = freshTable('lock1');
    final first = newSink('alpha');
    await first.start();
    await waitConnected(first, 'the first gateway');
    await first.ensureTable(
        'gw_$base', const RetentionPolicy(dropAfter: Duration(days: 30)));
    for (var i = 1; i <= 3; i++) {
      await first.insert('gw_$base',
          DateTime.utc(2026, 3, 1).add(Duration(seconds: i)), i.toDouble());
    }
    await pumpUntilCount(first, 'gw_$base', 3);

    final second = newSink('bravo');
    await second.start();
    await eventuallyAsync(
        () async => second.stats.lastError?.contains('alpha') ?? false,
        "the refusal naming the holder's application_name");
    print('second gateway lastError: ${second.stats.lastError}');

    // The refused gateway does not insert — not even rows handed to it.
    await second.insert('gw_$base', DateTime.utc(2026, 3, 2), 99.0);
    await second.flush();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await countOrZero('gw_$base'), 3,
        reason: 'a refused gateway that still writes has refused nothing');

    // The lock survives pool traffic on other connections: the first
    // gateway keeps collecting through its pool while holding the lock on
    // its dedicated session, and the second stays refused.
    await first.insert('gw_$base', DateTime.utc(2026, 3, 3), 4.0);
    await pumpUntilCount(first, 'gw_$base', 4);
    expect(second.stats.lastError, contains('alpha'),
        reason: 'pool activity must not recycle the lock away — it lives on '
            'a dedicated session outside the pool');
  });

  test('a second gateway with a different prefix is allowed — the lock is '
      'per namespace', () async {
    final base = freshTable('lock2');
    final first = newSink('alpha');
    final other = newSink('charlie', prefix: 'gwb_');
    await first.start();
    await other.start();
    await waitConnected(first, 'the gw_ gateway');
    await waitConnected(other, 'the gwb_ gateway');

    await other.ensureTable(
        'gwb_$base', const RetentionPolicy(dropAfter: Duration(days: 30)));
    for (var i = 1; i <= 2; i++) {
      await other.insert('gwb_$base',
          DateTime.utc(2026, 4, 1).add(Duration(seconds: i)), i.toDouble());
    }
    await pumpUntilCount(other, 'gwb_$base', 2);
  });

  test('close() releases the lock: the second gateway takes the namespace '
      'after the first leaves', () async {
    final base = freshTable('lock3');
    final first = newSink('alpha');
    await first.start();
    await waitConnected(first, 'the first gateway');

    final second = newSink('bravo');
    await second.start();
    await eventuallyAsync(
        () async => second.stats.lastError?.contains('alpha') ?? false,
        'the second gateway being refused while the first holds');

    // WR-01's arm: rows handed to the refused gateway during the contested
    // window. If any of them survives to the takeover, the replay writes a
    // second writer's samples into the window the first gateway owned.
    for (var m = 1; m <= 3; m++) {
      await second.insert('gw_$base',
          DateTime.utc(2026, 5, 1).add(Duration(seconds: m)), 90.0 + m);
    }
    await eventuallyAsync(() async => second.stats.rowsDropped >= 3,
        "the refused gateway's rows becoming counted drops, not a pen");

    await first.close();
    await waitConnected(second, 'the second gateway after the first closed');
    await second.ensureTable(
        'gw_$base', const RetentionPolicy(dropAfter: Duration(days: 30)));
    for (var i = 1; i <= 2; i++) {
      await second.insert('gw_$base',
          DateTime.utc(2026, 5, 1).add(Duration(minutes: 1, seconds: i)),
          i.toDouble());
    }
    // pumpUntilCount fails on an overshoot: 2 means the two post-takeover
    // rows and NOTHING replayed from the refused window.
    await pumpUntilCount(second, 'gw_$base', 2);
  });

  test('losing the lock connection degrades collection, and the sink '
      're-acquires instead of thrashing', () async {
    final base = freshTable('lock4');
    final sink = newSink('echo');
    await sink.start();
    await waitConnected(sink, 'the gateway');
    await sink.ensureTable(
        'gw_$base', const RetentionPolicy(dropAfter: Duration(days: 30)));
    await sink.insert('gw_$base', DateTime.utc(2026, 6, 1), 1.0);
    await pumpUntilCount(sink, 'gw_$base', 1);

    const lockName = 'centroidx-gateway-collector-echo:lock';
    expect(await lockSessionExists(lockName), isTrue,
        reason: 'the lock session must be visible under its own '
            'application_name — that is how an engineer finds the holder');

    // The server kills the lock session; detection rides the insert path.
    await admin.execute(
      r'SELECT pg_terminate_backend(pid) FROM pg_stat_activity '
      r'WHERE application_name = $1',
      parameters: [lockName],
    );
    await eventuallyAsync(() async {
      await sink.insert('gw_$base', DateTime.utc(2026, 6, 2), 2.0);
      return await lockSessionExists(lockName);
    }, 'the lock being re-acquired on a fresh session');
  });

  test('cutover mode, recorded on purpose: an empty prefix with soleWriter '
      'shares the table and the count is N+M', () async {
    final base = freshTable('cutover');

    const sharedRetention = RetentionPolicy(dropAfter: Duration(days: 10));
    final app = await appWriter();
    await app.registerRetentionPolicy(base, sharedRetention);
    for (var m = 1; m <= 5; m++) {
      await app.insertTimeseriesData(base,
          DateTime.utc(2026, 7, 1).add(Duration(seconds: m)), m * 1.0);
    }
    await app.flush();
    await eventuallyAsync(() async => await countOrZero(base) == 5,
        "the app stand-in's five rows landing");

    final sink = newSink('delta', prefix: '', sole: true);
    await sink.start();
    await waitConnected(sink, 'the cutover gateway');
    await sink.ensureTable(base, sharedRetention);
    for (var n = 1; n <= 7; n++) {
      await sink.insert(base,
          DateTime.utc(2026, 7, 2).add(Duration(seconds: n)), n * 10.0);
    }
    await eventuallyAsync(() async {
      await sink.flush();
      return await countOrZero(base) == 12;
    }, 'both writers\' rows landing in the one table');

    expect(await countOrZero(base), 12,
        reason: 'N+M in one table is what cutover looks like when the '
            'app\'s collector has NOT been stopped — this number is the '
            'documentation of what the prefix prevents, and the reason the '
            'empty prefix demands the soleWriter declaration');
  });

  test('the suite cleaned up after itself: no table carries this run\'s '
      'suffix', () async {
    final rows = await admin.execute(
      r"SELECT count(*) FROM information_schema.tables "
      r"WHERE table_name LIKE '%' || $1 || '%'",
      parameters: [suffix],
    );
    expect(rows.first.first, 0,
        reason: 'a suite that leaves hypertables behind poisons the next '
            'run\'s counts — every test drops what it creates, and this '
            'case is what notices the one that forgot');
  });
}
