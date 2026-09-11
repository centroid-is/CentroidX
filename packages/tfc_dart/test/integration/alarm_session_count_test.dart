/// ALRM-01 criterion 1, **counted**: the backend holds one OPC UA connection
/// per spawned acquisition worker, and the alarm engine holds none of its own.
///
/// Until 14-08 this backend built a second `StateMan` on main —
/// `alias: 'alarmman'`, `useIsolate: false`, from a copy of the same config —
/// so that an `AlarmMan`, the *panel* class, could evaluate alarm rules on the
/// backend. That was **one extra OPC UA session per configured server**, on the
/// main isolate, against controllers that count sessions and refuse the next
/// connection when they run out. 14-08 deleted the block. This file is what
/// says the deletion actually removed a connection.
///
/// ## What this file measures, and what it does NOT (read this before trusting
/// either half)
///
/// `main()` in `bin/main.dart` is not a callable function with injectable
/// config — it reads `CENTROID_STATEMAN_FILE_PATH`, dials Postgres, and binds a
/// WebSocket — and refactoring it into one is out of this plan's scope. So
/// **these arms do not boot the container.** They compose the *same objects in
/// the same order* `bin/main.dart` composes:
///
///     spawn worker(s)  ->  pipe.addWorker(link, keys)
///                      ->  BackendLiveValues
///                      ->  BackendFreshnessSweep
///                      ->  AlarmEngine(values: freshness, clock: ...)
///                      ->  await engine.start()
///
/// and then count live TCP connections at the far end of the wire.
///
/// Criterion 1's claim therefore rests on **two arms that must disagree if the
/// block comes back** (D-13):
///
///  * `test/core/alarm_structure_test.dart` arms 1-3 — a comment-stripped
///    source scan saying `bin/main.dart` builds no second `StateMan`, names no
///    `alarmman` alias and constructs no `AlarmMan`. That is the half which
///    covers the composition this file cannot execute.
///  * **this file** — what that composition costs in connections, measured
///    through [TcpProxy.livePairs] in front of a real in-process OPC UA server.
///
/// Neither half is sufficient alone. A source scan cannot see a session opened
/// by a collaborator three files away; a connection count cannot see a block in
/// a `main()` it did not run. Together they cannot both stay green if the
/// duplicate session returns, and sabotage (a) below is the run that proves the
/// second half bites.
///
/// ## Why `livePairs` and not a log line
///
/// [TcpProxy.livePairs] is the count of client/server socket pairs the proxy is
/// still holding open — the connections that exist, at the far end, right now.
/// Its own doc names why that is the number worth taking: it is *"the
/// difference between 'the client never closed' and 'the client closed and the
/// proxy did not pass it on' — two different bugs that look identical from the
/// server."* A parsed log line, or an absent constructor call, is neither.
///
/// The proxy is not a fault seam here. It is a meter. Nothing in this file
/// breaks the wire.
///
/// Dynamic ports only — every port comes from the kernel, via the fixture or
/// [freePort]. A literal collides deterministically with the same suite running
/// in a parallel worktree (project memory).
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' show Endpoint;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_dart/core/relay/backend_freshness.dart';
import 'package:tfc_dart/core/relay/backend_live_values.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../proxy.dart';
import '../support/free_port.dart';
import '../support/opcua_server_fixture.dart';

/// A [Database] that answers everything and connects to nothing.
///
/// The acquisition stack takes a [Database] object rather than a connection
/// (12-04's OQ-3 seam), so it stands up with one that has no server behind it
/// and this file stays out of the Docker lane — and therefore out of the way of
/// port 15432, which a parallel worktree may be using. Copied rather than
/// shared for the reason `pipe_isolation_test.dart` copies it: it has to be
/// reachable from an isolate entry point in *this* library.
class NoopDatabase implements Database {
  @override
  Future<void> registerRetentionPolicy(String t, RetentionPolicy r) async {}

  @override
  Future<void> insertTimeseriesData(String t, DateTime time, dynamic v) async {}

  @override
  Future<List<TimeseriesData<dynamic>>> queryTimeseriesData(
          String tableName, DateTime to,
          {String? orderBy = 'time ASC', DateTime? from}) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The production worker body, with Postgres swapped out and nothing else.
///
/// [runAcquisitionIsolate] is the whole of [dataAcquisitionIsolateEntry] — same
/// handshake, same `buildAcquisitionStack`, same `StateMan`, same
/// `PipeWorkerEndpoint`. A hand-assembled stand-in would open a hand-assembled
/// number of sessions, which is not a number anybody needs.
///
/// Must be top-level: closures are not sendable (dartbug.com/36983).
@pragma('vm:entry-point')
Future<void> sessionCountWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: NoopDatabase());

/// The alarm engine's clock, frozen.
///
/// Nothing in this file measures an instant, and a frozen clock keeps it that
/// way: an arm that accidentally depended on wall time would be a flake dressed
/// as a session count. The plant-instant measurements live in
/// `alarm_source_time_test.dart`.
final DateTime kFrozenNow = DateTime.utc(2024, 3, 1, 12);

/// How often each server's tag is given a new value.
const Duration valuePumpPeriod = Duration(milliseconds: 50);

void main() {
  // ------------------------------------------------------------------ arm 1
  test(
      'one server, one connection: a booted composition holds exactly one live '
      'OPC UA connection per spawned worker, and the alarm engine holds none '
      'of its own', () async {
    final rig = await _Rig.standUp(servers: 1);

    // Every rule variable has carried a real reading, so the engine is
    // demonstrably doing its job through this wire rather than sitting idle
    // next to it. A connection count taken over a dead composition would be a
    // count of nothing.
    await rig.awaitFirstReadings();

    expect(rig.proxies.single.livePairs, 1,
        reason: 'ALRM-01: the backend must hold ONE connection to this server '
            '— the acquisition worker\'s. Before 14-08 this measured 2: the '
            'worker\'s and the duplicate `alarmman` StateMan\'s, the second '
            'opened on main purely so an AlarmMan could read values this '
            'process was already reading. ${rig.evidence()}');

    // Stated as a relation and not only as a literal, so the two-server arm and
    // this one are the same claim rather than two coincidences.
    expect(rig.proxies.single.livePairs, rig.workers.length,
        reason: 'the live connection count must equal the spawned worker '
            'count. ${rig.evidence()}');
  });

  // ------------------------------------------------------------------ arm 2
  test(
      'the engine adds none: livePairs is unchanged across start(), which '
      'subscribes every rule variable', () async {
    // Composed but NOT started, so the before/after brackets exactly the
    // engine's own work.
    final rig = await _Rig.standUp(servers: 1, startEngine: false);

    // The worker's session must already be up, or the "before" reading would be
    // measuring the connect race rather than the engine. `bin/main.dart` does
    // not wait for this either — it does not have to, because nothing there
    // takes a number.
    await rig.awaitConnected();
    final before = rig.proxies.single.livePairs;

    await rig.engine.start();
    await rig.awaitFirstReadings();

    final after = rig.proxies.single.livePairs;

    expect(rig.engine.started, isTrue);
    expect(rig.subscribedKeys(), rig.alarmKeys.toSet(),
        reason: 'the engine must actually have subscribed every rule variable, '
            'or "the count did not change" is true for the boring reason. '
            '${rig.evidence()}');
    expect(after, before,
        reason: 'AlarmEngine.start() subscribed '
            '${rig.alarmKeys.length} rule variable(s) and the live connection '
            'count moved from $before to $after. The engine is a refcounted '
            'READER of a session somebody else owns; a session of its own is '
            'the thing ALRM-01 deleted. ${rig.evidence()}');
    expect(after, 1, reason: rig.evidence());
  });

  // ------------------------------------------------------------------ arm 3
  test(
      'two servers, two connections: one engine with rules spanning both holds '
      'one connection on each, not three', () async {
    // A rule that spans two servers is the case the roadmap's Notes name as the
    // reason alarms live on main with the global view — ST101 and a weigher in
    // one formula. It is also the case where a per-server evaluator would have
    // to open something extra, so it is the case worth counting.
    final rig = await _Rig.standUp(servers: 2, spanningRule: true);
    await rig.awaitFirstReadings();

    for (var i = 0; i < rig.proxies.length; i++) {
      expect(rig.proxies[i].livePairs, 1,
          reason: 'server $i must carry exactly one connection — its own '
              'worker\'s. ${rig.evidence()}');
    }
    final total = rig.proxies
        .fold<int>(0, (sum, proxy) => sum + proxy.livePairs);
    expect(total, rig.workers.length,
        reason: 'the total live connection count across the plant equals the '
            'spawned worker count, with nothing added by the engine that reads '
            'across both of them. ${rig.evidence()}');

    // The spanning rule is really spanning: both servers' keys are bound.
    expect(rig.subscribedKeys(), rig.alarmKeys.toSet());
    expect(rig.alarmKeys.length, 2, reason: rig.evidence());
  });

  // ------------------------------------------------------------------ arm 4
  test(
      'subscriptions precede any client: every alarm input is live before a '
      'relay server exists and before any WebSocket client does', () async {
    final rig = await _Rig.standUp(servers: 1);

    // No relay. `composeBackendRelay` was never called, no `RelayServer` was
    // constructed, no port is bound and no client exists in this process or any
    // other. That is the whole point: ALRM-02 says the inputs are subscribed
    // before any panel connects, and the only way to measure "before any panel"
    // is to have no panel at all.
    expect(rig.pipe.workerCount, 1);

    for (final key in rig.alarmKeys) {
      // Read back through the SAME value source the engine reads through.
      // `BackendLiveValues.read` returns null for a key that has never carried
      // a reading and null for one still badged `uncertainNotYetKnown` — the
      // two states this arm has to exclude. A non-null answer here means a
      // monitored item exists at the PLC for a key nothing but the alarm engine
      // has ever asked for.
      await _waitUntil(() => rig.freshness.read(key) != null,
          const Duration(seconds: 60),
          reason: 'alarm input "$key" never carried a reading with no client '
              'attached, which is the roadmap\'s named trap: inputs that only '
              'exist because a panel asked for them. ${rig.evidence()}');

      final value = rig.freshness.read(key)!;
      expect(value.quality.isGood, isTrue,
          reason: '"$key" is live but badged ${value.quality.code}. '
              '${rig.evidence()}');
      expect(value.value, isNotNull,
          reason: '"$key" answered with no payload. ${rig.evidence()}');
    }

    // And the engine reached a verdict off them, with nobody listening to
    // `activeAlarms()` at any point in this test.
    expect(rig.engine.evaluations, greaterThan(0),
        reason: 'the inputs are subscribed but no rule was ever evaluated — '
            'which is `AlarmMan`\'s onListen defect wearing a different '
            'costume. ${rig.evidence()}');
  });

  // ------------------------------------------------------------------ arm 5
  test(
      'the last panel leaving changes nothing: a stand-in panel takes and drops '
      'a subscription on an alarm input and the value keeps arriving', () async {
    final rig = await _Rig.standUp(servers: 1);
    await rig.awaitFirstReadings();
    final key = rig.alarmKeys.first;

    // 13-03 refcounts on the 0->1 listener transition, so the danger is the
    // 1->0 on the way out: if the engine's own reference were not held for the
    // life of the process, the last panel closing would release the monitored
    // item and the alarm would stop being evaluated because nobody happened to
    // be looking. That is the roadmap's named trap, and this is it measured
    // rather than reasoned about.
    final panelSaw = <relay.DynamicValue>[];
    final panel = rig.freshness.subscribe(key).listen(panelSaw.add);
    await _waitUntil(() => panelSaw.isNotEmpty, const Duration(seconds: 30),
        reason: 'the stand-in panel never received a value, so its departure '
            'cannot prove anything. ${rig.evidence()}');
    await panel.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The connection is still there...
    expect(rig.proxies.single.livePairs, 1,
        reason: 'a panel leaving must not take the plant\'s session with it. '
            '${rig.evidence()}');

    // ...and so is the data. Measured on the value itself, not on a refcount:
    // a refcount that is right while the numbers have stopped is not the claim
    // an operator cares about.
    final evaluationsAfterPanel = rig.engine.evaluations;
    final valueAfterPanel = rig.freshness.read(key)!.value;
    await _waitUntil(
      () =>
          rig.freshness.read(key)!.value != valueAfterPanel &&
          rig.engine.evaluations > evaluationsAfterPanel,
      const Duration(seconds: 60),
      reason: 'after the stand-in panel dropped its subscription the value for '
          '"$key" stopped moving (last seen $valueAfterPanel) and/or the '
          'engine stopped evaluating (stuck at $evaluationsAfterPanel). The '
          'engine\'s own reference must never drop. ${rig.evidence()}',
    );

    expect(rig.freshness.read(key)!.quality.isGood, isTrue,
        reason: 'the surviving monitored item is delivering under a bad badge. '
            '${rig.evidence()}');
  });
}

// --------------------------------------------------------------- the fixtures

/// The alias one server is known by. Index-suffixed so a two-server rig's
/// failure messages name which one.
String _aliasFor(int index) => 'PLC-$index';

/// The tag one server serves, and the variable one alarm rule binds.
///
/// Dotted, like every real key at SVN. `Expression`'s tokenizer treats a dotted
/// name as one variable (it only rejects whitespace), so this is not a
/// simplification the arms are quietly relying on.
String _keyFor(int index) => 'plc$index.line.level';

/// Polls [predicate] until it holds or [within] elapses.
Future<void> _waitUntil(bool Function() predicate, Duration within,
    {required String reason}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('not true within ${within.inMilliseconds}ms: $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// N servers behind N meters, N real workers, one pipe, one value source, one
/// freshness sweep, one alarm engine — composed in `bin/main.dart`'s order.
final class _Rig {
  _Rig._({
    required this.fixtures,
    required this.workers,
    required this.pipe,
    required this.liveValues,
    required this.freshness,
    required this.engine,
    required this.alarmKeys,
  });

  final List<OpcUaServerFixture> fixtures;
  final List<DataAcquisitionWorker> workers;
  final PipeMainEndpoint pipe;
  final BackendLiveValues liveValues;
  final BackendFreshnessSweep freshness;
  final AlarmEngine engine;

  /// Every variable the configured alarm rules bind, in configuration order.
  final List<String> alarmKeys;

  /// The meters, one per server, positionally aligned with [fixtures].
  List<TcpProxy> get proxies => [for (final f in fixtures) f.proxy!];

  /// What the engine's watchers actually subscribed to.
  ///
  /// Read off the watchers rather than off the configuration, so an arm cannot
  /// pass because the engine subscribed to nothing at all.
  Set<String> subscribedKeys() => {
        for (final alarm in engine.config?.alarms ?? const <AlarmConfig>[])
          for (final rule in alarm.rules) ...rule.expression.value
              .extractVariables(),
      };

  /// One line naming everything a failure needs in order to be diagnosable.
  String evidence() => 'livePairs=${[for (final p in proxies) p.livePairs]}, '
      'workers=${workers.length}, alarmKeys=$alarmKeys, '
      'readings=${[for (final k in alarmKeys) '$k=${freshness.read(k)?.value}']}, '
      'evaluations=${engine.evaluations}, active=${engine.active.length}, '
      'refusals=${engine.refusals}';

  /// Waits until the worker(s) have a live connection at the meter.
  Future<void> awaitConnected() => _waitUntil(
        () => proxies.every((p) => p.livePairs >= 1),
        const Duration(seconds: 60),
        reason: 'a spawned worker never connected to its server, so there is '
            'no baseline to measure the engine against: '
            'livePairs=${[for (final p in proxies) p.livePairs]}',
      );

  /// Waits until every alarm input has carried a real reading.
  Future<void> awaitFirstReadings() => _waitUntil(
        () => alarmKeys.every((k) => freshness.read(k) != null),
        const Duration(seconds: 60),
        reason: 'an alarm input never carried a first reading, so nothing '
            'measured here describes a working composition: ${evidence()}',
      );

  /// Composes the backend, in `bin/main.dart`'s order.
  ///
  /// [spanningRule] puts every server's key into ONE rule, which is the
  /// cross-server case; otherwise each server gets its own alarm.
  static Future<_Rig> standUp({
    required int servers,
    bool spanningRule = false,
    bool startEngine = true,
  }) async {
    final logger = Logger(level: Level.warning);

    final fixtures = <OpcUaServerFixture>[];
    final mappings = <String, KeyMappingEntry>{};
    for (var i = 0; i < servers; i++) {
      // Every server gets a meter. The proxy is not a fault seam in this file
      // — nothing here breaks the wire — it is the only place a live
      // connection COUNT can be taken.
      final fixture = await OpcUaServerFixture.start(
          valueKeys: <String>[_keyFor(i)], viaProxy: true);
      addTearDown(fixture.dispose);
      fixtures.add(fixture);
      mappings[_keyFor(i)] = KeyMappingEntry(
        opcuaNode:
            OpcUANodeConfig(namespace: fixtureNamespace, identifier: _keyFor(i))
              ..serverAlias = _aliasFor(i),
      );
    }

    final keyMappings = KeyMappings(nodes: mappings);

    // ---- the spawn loop, one worker per server, exactly as bin/main.dart does
    final workers = <DataAcquisitionWorker>[];
    final pipe = PipeMainEndpoint();
    addTearDown(pipe.dispose);

    for (var i = 0; i < servers; i++) {
      final filtered = keyMappings.filterByServer(_aliasFor(i));
      final server = OpcUAConfig()
        ..endpoint = fixtures[i].endpoint
        ..serverAlias = _aliasFor(i);

      final worker = await spawnWorkerForTest(
        DataAcquisitionIsolateConfig(
          serverJson: server.toJson(),
          // A port nothing listens on. The injected NoopDatabase means it is
          // never dialled; naming a dead port is what makes a regression of
          // that seam fail as a silent pipe rather than as a mysterious hang.
          dbConfigJson: DatabaseConfig(
            postgres: Endpoint(
                host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
          ).toJson(),
          keyMappingsJson: filtered.toJson(),
        ),
        _aliasFor(i),
        entryPoint: sessionCountWorkerEntry,
      );
      // Registered BEFORE the ready await, so a worker that never announces
      // itself is still torn down.
      addTearDown(worker.kill);
      await worker.ready.timeout(const Duration(seconds: 60),
          onTimeout: () => fail(
              '${_aliasFor(i)} never handed back its control port — no '
              'worker, no session, no measurement'));
      workers.add(worker);
      pipe.addWorker(AcquisitionWorkerLink(worker), filtered.keys);
    }

    // ---- the value pump, so the plant is actually saying something
    var tick = 0;
    final pump = Timer.periodic(valuePumpPeriod, (_) {
      tick++;
      for (var i = 0; i < servers; i++) {
        // Above every threshold below, so the rules go true and the engine is
        // measurably doing work rather than merely holding subscriptions.
        fixtures[i].setValue(_keyFor(i), 100 + tick);
      }
    });
    addTearDown(pump.cancel);

    // ---- the value source, built unconditionally and NOT inside a relay block
    // (D-8 / bin/main.dart:237-276). There is no relay in this file at all,
    // which is exactly the deployment SVN runs today and the one arm 4 needs.
    final liveValues = BackendLiveValues(
      pipe: pipe,
      keyMappings: keyMappings,
      staleAfter: kBackendStaleAfter,
      logger: logger,
    );
    final freshness = BackendFreshnessSweep(
      values: liveValues,
      staleAfter: kBackendStaleAfter,
      pipe: pipe,
      logger: logger,
    );
    addTearDown(freshness.dispose);

    // ---- the alarms
    final alarms = spanningRule
        ? <AlarmConfig>[
            _alarm('cross-plant', <String>[
              [for (var i = 0; i < servers; i++) '${_keyFor(i)} > 10']
                  .join(' AND '),
            ]),
          ]
        : <AlarmConfig>[
            for (var i = 0; i < servers; i++)
              _alarm('alarm-$i', <String>['${_keyFor(i)} > 10']),
          ];

    final preferences = InMemoryPreferences();
    await preferences.setString(kAlarmManConfigKey,
        jsonEncode(AlarmManConfig(alarms: alarms).toJson()));

    final engine = AlarmEngine(
      values: freshness,
      preferences: preferences,
      // The production publisher, into the pipe's own store — so `ALARM.active`
      // is a real `ValueStoreNode` here, as it is on the backend.
      publisher: PipeStoreAlarmPublisher(pipe),
      // Frozen: see [kFrozenNow]. `bin/main.dart` supplies `DateTime.now`.
      clock: () => kFrozenNow,
      // The frozen clock disagrees with the real server's source instants by
      // years, so every transition would fire the skew warning and bury this
      // file's own failure messages in it. The skew behaviour is a property of
      // the STAMP, and it is measured — unclamped, warned about — in
      // `alarm_source_time_test.dart` arm 5, against a chosen offset rather
      // than against an artefact of a frozen clock.
      skewWarnAfter: const Duration(days: 365000),
      // No `AlarmHistoryWriter`: this file measures connections, and a Postgres
      // dependency would put it in the Docker lane behind port 15432, which a
      // parallel worktree may hold (project memory).
      logger: logger,
    );
    addTearDown(engine.dispose);

    final rig = _Rig._(
      fixtures: fixtures,
      workers: workers,
      pipe: pipe,
      liveValues: liveValues,
      freshness: freshness,
      engine: engine,
      alarmKeys: <String>[for (var i = 0; i < servers; i++) _keyFor(i)],
    );

    // ---- start(), AFTER every pipe.addWorker(...). A subscribe for a key no
    // worker owns costs no message and is silently dropped (P-4), so an engine
    // started before the spawn loop starts, logs, publishes an empty active set
    // and never fires. Sabotage (f) is that ordering, and it turns arm 4 red
    // with nothing thrown anywhere.
    if (startEngine) await engine.start();

    return rig;
  }
}

/// One alarm with one rule per formula.
AlarmConfig _alarm(String uid, List<String> formulas) => AlarmConfig(
      uid: uid,
      title: 'Level high on $uid',
      description: 'The measured level crossed its limit',
      rules: <AlarmRule>[
        for (final formula in formulas)
          AlarmRule(
            level: AlarmLevel.error,
            expression: ExpressionConfig(value: Expression(formula: formula)),
            acknowledgeRequired: false,
          ),
      ],
    );
