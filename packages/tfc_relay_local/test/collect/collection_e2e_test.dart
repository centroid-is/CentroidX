/// **The plan's demonstration.** One process, a real PLC, a real TimescaleDB.
///
/// An in-process open62541 server publishes values, `OpcUaUpstreamLink`
/// samples them, `LocalStateMan` stores them, the collection runner declines
/// or writes them, `TimescaleSink` lands them — and this file reads them back
/// **by SQL**, from the hypertable, values and not counts. It is
/// `end_to_end_test.dart`'s sibling on the other half of the picture: that
/// file proves PLC → panel, this one proves PLC → disk, and the outage in the
/// middle of it is a gap rather than a lie.
///
/// Tagged for both lanes: `db` because a real TimescaleDB answers the SQL,
/// `opcua` because a real server publishes the values. `@TestOn('!windows')`
/// is the OPC UA fixture's constraint, not the database's —
/// `opcua_link_test.dart:1`'s reason, checked rather than assumed: the CI
/// matrix includes windows-latest and the in-process open62541 `Server` is
/// not run there, while 8b-02's db legs are.
@TestOn('!windows')
@Tags(['db', 'opcua'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:math';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_local/src/collect/timescale_sink.dart';
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart' show ServerConfig;

import '../opcua_link_test.dart' show alias, mappingFor;
import '../support/opcua_server_fixture.dart';
import '../support/permissive_resolver.dart';
import '../support/timescale_fixture.dart';

late TimescaleFixture fx;
late pg.Connection admin;

/// The per-run suffix every table name carries — 8b-02's convention: nothing
/// in the db lane owns a fixed name, so two worktrees never fight.
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

/// Everything this file creates, prefixed and not; dropped in tearDownAll.
final Set<String> createdTables = <String>{};

String freshBase(String base) {
  final name = '${base}_$suffix';
  createdTables.addAll(<String>[name, 'gw_$name']);
  return name;
}

CollectionConfig collectionConfig() => CollectionConfig(
      enabled: true,
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

/// Waits for [predicate] (possibly asking the database), or fails naming
/// what never happened. Every row assertion in this file sits inside one of
/// these — four asynchronous boundaries separate a PLC from a hypertable
/// (the publishing interval, the ingest, the sink's buffer, the wrapped
/// layer's flush timer) and an instant read after any of them is a race.
Future<Duration> until(
  Future<bool> Function() predicate, {
  Duration budget = const Duration(seconds: 45),
  String? describe,
}) async {
  final stopwatch = Stopwatch()..start();
  while (!await predicate()) {
    if (stopwatch.elapsed > budget) {
      fail('${describe ?? 'condition'} never became true within '
          '${budget.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  stopwatch.stop();
  return stopwatch.elapsed;
}

/// `count(*)` tolerant of the table not existing yet (SQLSTATE 42P01) — the
/// polling shape from `side_by_side_test.dart`.
Future<int> countOrZero(String table, {String where = ''}) async {
  try {
    final rows =
        await admin.execute('SELECT count(*) FROM "$table" $where');
    return rows.first.first! as int;
  } on Object catch (error) {
    if (error.toString().contains('42P01')) return 0;
    rethrow;
  }
}

/// One gateway + one collection chain over one in-process PLC, composed the
/// way `bin/relay_gateway.dart` composes it — sink, plan (with `unroutable:`
/// from the router ingest), runner on the plant's own health producer.
final class CollectionChain {
  CollectionChain._(this.fixture, this.gateway, this.sink, this.runner);

  final OpcUaServerFixture fixture;
  final Gateway gateway;
  final TimescaleSink sink;
  final CollectionRunner runner;

  LocalStateMan get plant => gateway.plant;

  static Future<CollectionChain> standUp({
    required Map<String, KeyMappingEntry> mappings,
    Iterable<String> valueKeys = const <String>[],
    Map<String, Map<String, Object>> structKeys =
        const <String, Map<String, Object>>{},
    bool viaFaultProxy = false,
    Duration staleAfter = const Duration(seconds: 30),
    String publisherId = 'e2e',
  }) async {
    final fixture = await OpcUaServerFixture.start(
      valueKeys: valueKeys,
      structKeys: structKeys,
      viaFaultProxy: viaFaultProxy,
    );
    addTearDown(fixture.dispose);

    final keyMappings = KeyMappings(nodes: mappings);
    final gateway = await buildGateway(
      resolver: const PermissiveSeriesResolver(),
      GatewayConfig(
        server: ServerConfig(port: 0, tick: ServerConfig.minTick),
        links: <UpstreamLinkConfig>[
          UpstreamLinkConfig(
            alias: alias,
            protocol: UpstreamProtocol.opcUa,
            endpoint: fixture.endpoint,
            useIsolate: false,
          ),
        ],
        keyMappingsPath: '',
        staleAfter: staleAfter,
      ),
      mappings: keyMappings,
      log: Logger(level: Level.off),
      onError: (_, __, ___) {},
    );
    addTearDown(gateway.stop);
    await gateway.plant.start();
    await gateway.server.start();

    // The composition root's wiring, mirrored exactly — including the
    // ingest's own rejected keys as `unroutable:`, never re-derived.
    final config = collectionConfig();
    final sink = TimescaleSink(
      config,
      publisherId: publisherId,
      useIsolate: false,
      sleep: fastSleep,
    );
    addTearDown(sink.close);
    final plan = CollectionPlan.from(
      keyMappings,
      config,
      unroutable: gateway.plant.router.lastIngest.rejected.keys.toSet(),
    );
    await sink.start();
    final runner = CollectionRunner(
      plan: plan,
      stateMan: gateway.plant,
      sink: sink,
      health: gateway.plant.collectHealth,
    );
    addTearDown(runner.stop);
    await runner.start();
    expect(runner.entryFailures, isEmpty,
        reason: 'every entry in this leg must start, or the arms below '
            'assert against a chain that never stood up');
    return CollectionChain._(fixture, gateway, sink, runner);
  }
}

void main() {
  setUpAll(() async {
    fx = await TimescaleFixture.start();
    admin = await fx.connect(applicationName: 'relay-e2e-admin');
  });

  tearDownAll(() async {
    for (final table in createdTables) {
      await admin.execute('DROP TABLE IF EXISTS "$table" CASCADE');
    }
    await admin.close();
    await fx.stop();
  });

  test(
      'a scalar tag reaches rows carrying the published values in order; the '
      'table is a hypertable with the configured retention; the health keys '
      'are ordinary keys on a panel; the unprefixed table never moves',
      () async {
    final leg = Stopwatch()..start();
    const speedKey = 'ST101.CN01.MOT01.speed';
    final base = freshBase('e2e_speed');

    // Anti-vacuity BEFORE any count: this is a real TimescaleDB, not a
    // plain Postgres that would take the rows and fail only the catalogue
    // assertions (8b-02's first case, repeated here because this file's
    // verdicts depend on it).
    final ext = await admin.execute(
        "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'");
    expect(ext, isNotEmpty,
        reason: 'the timescaledb extension is absent, so nothing below '
            'measures what it claims to');
    print('E2E   timescaledb extversion = ${ext.first.first}');

    // The app-shaped unprefixed table — 8b-02's isolation case, stood up
    // here too: the end-to-end path must honour the prefix like the unit
    // path does, and an empty table is only evidence if it exists.
    await admin.execute('CREATE TABLE "$base" '
        '("time" TIMESTAMPTZ NOT NULL, "value" BIGINT)');

    final chain = await CollectionChain.standUp(
      valueKeys: const <String>[speedKey],
      mappings: <String, KeyMappingEntry>{
        speedKey: mappingFor(speedKey)
          ..collect = CollectEntry(
            key: speedKey,
            name: base,
            retention: const RetentionPolicy(dropAfter: Duration(days: 10)),
          ),
      },
      publisherId: 'e2e-scalar',
    );

    // A changing value: three genuine publishes, each awaited into the
    // hypertable before the next, so the ORDER below is the server's order.
    const published = <int>[1477, 1478, 1479];
    for (final value in published) {
      chain.fixture.setValue(speedKey, value);
      await until(
          () async =>
              await countOrZero('gw_$base', where: 'WHERE "value" = $value') >=
              1,
          describe: 'the published value $value reaching a hypertable row');
    }

    // Values, not counts: a count-only assertion passes when the wrong
    // tag's rows land in the right table, which is exactly what a
    // keymapping edit produces.
    final rows = await admin
        .execute('SELECT "value", "time" FROM "gw_$base" ORDER BY "time"');
    final values = <int>[
      for (final row in rows)
        if (published.contains(row.first)) row.first! as int,
    ];
    expect(values, published,
        reason: 'the values the server published, in publish order — with '
            'only the node\'s initial sample allowed besides them');
    for (final row in rows) {
      expect(published.contains(row.first) || row.first == 0, isTrue,
          reason: 'a value nobody published is in the history: ${row.first}');
    }
    print('E2E   rows in gw_$base = ${rows.length} '
        '(published ${published.length} + the node\'s initial sample)');

    // The catalogue's own word for it — never our config object's.
    final hyper = await admin.execute(
        "SELECT hypertable_name FROM timescaledb_information.hypertables "
        "WHERE hypertable_name = 'gw_$base'");
    expect(hyper, hasLength(1),
        reason: 'the table the gateway wrote is not a hypertable, so '
            'retention and chunking silently do not apply');
    final retention = await admin.execute(
        "SELECT config ->> 'drop_after' FROM timescaledb_information.jobs "
        "WHERE proc_name = 'policy_retention' "
        "AND hypertable_name = 'gw_$base'");
    expect(retention, hasLength(1));
    // The catalogue renders the interval as HH:MM:SS — 240 hours IS the
    // configured 10 days, and 8b-02's isolation case recorded the same
    // rendering ('240:00:00.000000' for its 10-day policy).
    expect('${retention.first.first}', contains('240:00:00'),
        reason: 'the configured retention (10 days = 240 h), read back from '
            'TimescaleDB\'s job catalogue: ${retention.first.first}');
    print('E2E   retention drop_after = ${retention.first.first}');

    // The health keys are ordinary keys: a real panel over a real socket
    // reads them through the same call it uses for the motor speed.
    final panel = RemoteStateMan(
      uri: Uri.parse('ws://127.0.0.1:${chain.gateway.server.port}'),
      config: ClientConfig(),
      keys: <String>{
        speedKey,
        PipeKeys.collectConnected,
        PipeKeys.collectRowsWritten,
      },
    );
    addTearDown(panel.dispose);
    await until(() async => panel.linkState == LinkState.ready,
        describe: 'the panel reaching ready');
    await until(() async => panel.read(speedKey) != null,
        describe: 'the motor speed crossing to the panel');
    await until(() async => panel.read(PipeKeys.collectConnected)?.value == true,
        describe: 'PIPE.collect.connected reading true on the panel');
    await until(
        () async {
          final written = panel.read(PipeKeys.collectRowsWritten)?.value;
          return written is int && written >= published.length;
        },
        describe: 'PIPE.collect.rows_written reaching the panel with the '
            'written count');
    print('E2E   panel PIPE.collect.connected    = '
        '${panel.read(PipeKeys.collectConnected)!.value}');
    print('E2E   panel PIPE.collect.rows_written = '
        '${panel.read(PipeKeys.collectRowsWritten)!.value}');

    // Nothing else in the database moved: the app-shaped table is exactly
    // as empty as it was created.
    expect(await countOrZero(base), 0,
        reason: 'gateway rows in the unprefixed table means the prefix '
            'guarantee failed end to end — the side-by-side hazard 8b-01\'s '
            'four-fact argument exists to prevent');
    print('E2E   scalar leg wall clock = ${leg.elapsed.inSeconds}s');
  });

  test(
      'a struct tag with sample_members reaches one row per sample, one '
      'column per named member, absent members absent from the row',
      () async {
    final leg = Stopwatch()..start();
    const structKey = 'ST101.CN03.MOT01';
    final base = freshBase('e2e_struct');

    final chain = await CollectionChain.standUp(
      structKeys: const <String, Map<String, Object>>{
        // The FB_Motor shape in miniature: three members, of which the
        // collect block names two — `b` must never become a column.
        structKey: <String, Object>{'a': 2, 'b': 5.8, 'c': true},
      },
      mappings: <String, KeyMappingEntry>{
        structKey: mappingFor(structKey)
          ..collect = CollectEntry(
            key: structKey,
            name: base,
            sampleMembers: const <String>['a', 'c'],
          ),
      },
      publisherId: 'e2e-struct',
    );

    await until(() async => await countOrZero('gw_$base') >= 1,
        describe: 'the struct\'s sample reaching a hypertable row');

    final columns = await admin.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name = 'gw_$base' ORDER BY column_name");
    final names = <String>[for (final row in columns) row.first! as String];
    expect(names, <String>['a', 'c', 'time'],
        reason: 'one column per named member plus time — and NOT the '
            'member the collect block did not name: an absent member '
            'null-filled into a column is a schema the sample never '
            'carried');
    final first = await admin.execute(
        'SELECT "a", "c" FROM "gw_$base" ORDER BY "time" LIMIT 1');
    expect(first.first.toList(), <Object?>[2, true],
        reason: 'the member values the PLC held, keyed by the paths the '
            'collect block named — what extractSampleMembers returns, '
            'landed as columns');
    print('E2E   struct columns = $names, first row = '
        '${first.first.toList()}');
    print('E2E   struct rows = ${await countOrZero('gw_$base')}');
    print('E2E   struct leg wall clock = ${leg.elapsed.inSeconds}s');
    // Silences the unused warning while keeping the chain alive to here.
    expect(chain.runner.entryFailures, isEmpty);
  });

  test(
      'an upstream outage is a gap, not a flat line: no rows during, the '
      'dropped counter grew, rows resume after', () async {
    final leg = Stopwatch()..start();
    const levelKey = 'ST101.CN02.TNK01.level';
    final base = freshBase('e2e_level');

    final chain = await CollectionChain.standUp(
      valueKeys: const <String>[levelKey],
      viaFaultProxy: true,
      // The sweep is the outage detector on this path: values a blackholed
      // link can no longer vouch for go badStale after two seconds, and
      // from that instant every tick declines and counts.
      staleAfter: const Duration(seconds: 2),
      mappings: <String, KeyMappingEntry>{
        levelKey: mappingFor(levelKey)
          ..collect = CollectEntry(
            key: levelKey,
            name: base,
            sampleInterval: const Duration(milliseconds: 100),
          ),
      },
      publisherId: 'e2e-outage',
    );

    chain.fixture.setValue(levelKey, 5);
    await until(() async => await countOrZero('gw_$base') >= 2,
        describe: 'the steady value trending into the hypertable');

    final dropsBefore =
        chain.plant.read(PipeKeys.collectRowsDropped)!.value! as int;

    // The outage: every byte in both directions is dropped, the TCP
    // connection stays formally open — the frozen-session failure.
    chain.fixture.proxy!.blackhole();
    await until(
        () async => !(chain.plant.read(levelKey)?.quality.isGood ?? true),
        describe: 'the freshness sweep noticing the silence');

    // The gap window opens at the first DECLINED tick, not at the first
    // degraded read: `read` re-derives staleness synchronously (the sweep's
    // judge), while the runner's held value degrades only when the sweep's
    // periodic pass writes to the store — up to one sweep interval later.
    // A tick in that window legitimately writes a value that was still
    // vouched for when it was held.
    await until(
        () async =>
            (chain.plant.read(PipeKeys.collectRowsDropped)!.value! as int) >
            dropsBefore,
        describe: 'PIPE.collect.rows_dropped growing while ticks decline');
    final gapStart = DateTime.now().toUtc();

    // Several sample intervals of confirmed outage.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final gapEnd = DateTime.now().toUtc();
    chain.fixture.proxy!.blackhole(enabled: false);

    chain.fixture.setValue(levelKey, 7);
    await until(
        () async =>
            await countOrZero('gw_$base', where: 'WHERE "value" = 7') >= 1,
        describe: 'rows resuming after the restore, carrying the new value');

    final inGap = await countOrZero('gw_$base',
        where: "WHERE \"time\" > '${gapStart.toIso8601String()}' "
            "AND \"time\" < '${gapEnd.toIso8601String()}'");
    final dropsAfter =
        chain.plant.read(PipeKeys.collectRowsDropped)!.value! as int;
    final total = await countOrZero('gw_$base');

    print('OUTAGE gap window        = ${gapStart.toIso8601String()} .. '
        '${gapEnd.toIso8601String()} '
        '(${gapEnd.difference(gapStart).inMilliseconds} ms)');
    print('OUTAGE rows inside gap   = $inGap');
    print('OUTAGE drops before/after = $dropsBefore / $dropsAfter');
    print('OUTAGE rows total        = $total');

    expect(inGap, 0,
        reason: 'rows written through the outage are a flat, plausible '
            'trend somebody later reads as "the line was running steady" — '
            'the class of lie this project exists to prevent. The gap is '
            'the honest record');
    expect(dropsAfter, greaterThan(dropsBefore),
        reason: 'and the gap is COUNTED where an operator can read it: '
            'PIPE.collect.rows_dropped is the answer to "why is there no '
            'data between 14:02 and 14:20"');
    expect(await countOrZero('gw_$base', where: 'WHERE "value" = 7'),
        greaterThanOrEqualTo(1),
        reason: 'recovery resumes the trend with the new value');
    print('E2E   outage leg wall clock = ${leg.elapsed.inSeconds}s');
  });
}
