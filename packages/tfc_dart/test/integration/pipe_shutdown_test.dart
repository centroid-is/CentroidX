/// PIPE-13 criterion 5, measured: the backend stops in milliseconds, with a
/// blackholed PLC still attached.
///
/// The number this file exists because of is **5 759 ms** — the measured cost of
/// `StateMan.close()` against an upstream that has stopped answering
/// (`lib/core/state_man.dart:2249-2259`: a synchronous `Client.disconnect()`
/// followed by an awaited `delete()`, per client). A backend that takes almost
/// six seconds to stop is a backend Docker kills half way through, and what it
/// is killed in the middle of is a write.
///
/// [PipeMainEndpoint.shutdown] refuses to await any of it: it is
/// `Isolate.kill(priority: immediate)` per worker and nothing else. 12-06 pinned
/// that **structurally** — `test/core/pipe_shutdown_structure_test.dart` scans
/// `bin/` and `lib/core/pipe*.dart` for a graceful teardown on a shutdown path
/// and fails if one appears. A source scan cannot say how long the thing takes,
/// which is the half this file measures.
///
/// ## Two arms, and they must disagree
///
///  * **The kill path** — two real workers, one of them with a blackholed
///    upstream, torn down through the shipping `shutdown()`. Wall clock, from
///    the call to both isolates being confirmed gone, asserted **< 1000 ms**.
///  * **The graceful path** — the same blackholed link, closed the way the
///    backend used to close it. If this arm does not stall, then the bound above
///    is satisfied by a machine on which nothing is slow, and the measurement
///    proves nothing about the stall it claims to have removed.
///
/// A bound that everything passes is not a bound. This is
/// `slow_upstream_isolation_test.dart:33-40`'s rule applied to a clock instead
/// of a cadence. Measured on the development machine: the kill path confirms
/// both isolates dead **8-13 ms** after the call; the graceful path on the same
/// blackholed link takes **~8 100 ms** — worse than the 5 759 ms on record, and
/// three orders of magnitude apart from the path that ships.
///
/// Dynamic ports only.
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';

import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:postgres/postgres.dart' show Endpoint;
import 'package:test/test.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../support/free_port.dart';
import '../support/opcua_server_fixture.dart';

/// The bound. Far below the 5 759 ms stall, and not a round number chosen to
/// be comfortable: the kill path measures in single-digit milliseconds, so a
/// second of headroom is the difference between "instant" and "something
/// started waiting for the network".
const Duration kShutdownBound = Duration(milliseconds: 1000);

/// A [Database] that answers everything and connects to nothing (12-04's OQ-3
/// seam). Copied because it must be reachable from an isolate entry point in
/// this library.
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

/// The production worker with Postgres swapped out and nothing else.
@pragma('vm:entry-point')
Future<void> shutdownWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: NoopDatabase());

const String aliasHealthy = 'PLC-HEALTHY';
const String keyHealthy = 'healthy.counter';
const String aliasDark = 'PLC-DARK';
const String keyDark = 'dark.counter';

KeyMappings _mappingsFor(String key, String alias) =>
    KeyMappings(nodes: <String, KeyMappingEntry>{
      key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
          ..serverAlias = alias,
      ),
    });

OpcUAConfig _serverConfig(String endpoint, String alias) => OpcUAConfig()
  ..endpoint = endpoint
  ..serverAlias = alias;

Future<DataAcquisitionWorker> _spawnWorker({
  required String alias,
  required String endpoint,
  required KeyMappings mappings,
}) async {
  final worker = await spawnWorkerForTest(
    DataAcquisitionIsolateConfig(
      serverJson: _serverConfig(endpoint, alias).toJson(),
      dbConfigJson: DatabaseConfig(
        postgres: Endpoint(
            host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
      ).toJson(),
      keyMappingsJson: mappings.toJson(),
    ),
    alias,
    entryPoint: shutdownWorkerEntry,
  );
  addTearDown(worker.kill);
  await worker.ready.timeout(const Duration(seconds: 60),
      onTimeout: () => fail('$alias never handed back its control port'));
  return worker;
}

/// Polls [predicate] until it holds or [within] elapses.
///
/// [every] is 5 ms here rather than the usual 25: this file's whole content is
/// a duration, and the poll interval is the resolution of the measurement.
Future<void> _waitUntil(bool Function() predicate, Duration within,
    {required String reason,
    Duration every = const Duration(milliseconds: 5)}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('not true within ${within.inMilliseconds}ms: $reason');
    }
    await Future<void>.delayed(every);
  }
}

void main() {
  test(
      'shutdown with a blackholed upstream kills every worker in well under a '
      'second', () async {
    final healthyServer =
        await OpcUaServerFixture.start(valueKeys: const <String>[keyHealthy]);
    addTearDown(healthyServer.dispose);
    final darkServer = await OpcUaServerFixture.start(
        valueKeys: const <String>[keyDark], viaProxy: true);
    addTearDown(darkServer.dispose);

    final healthyMappings = _mappingsFor(keyHealthy, aliasHealthy);
    final darkMappings = _mappingsFor(keyDark, aliasDark);

    final healthyWorker = await _spawnWorker(
        alias: aliasHealthy,
        endpoint: healthyServer.endpoint,
        mappings: healthyMappings);
    final darkWorker = await _spawnWorker(
        alias: aliasDark,
        endpoint: darkServer.endpoint,
        mappings: darkMappings);

    final pipe = PipeMainEndpoint();
    addTearDown(pipe.dispose);
    pipe.addWorker(AcquisitionWorkerLink(healthyWorker), healthyMappings.keys);
    pipe.addWorker(AcquisitionWorkerLink(darkWorker), darkMappings.keys);

    var tick = 0;
    final pump = Timer.periodic(const Duration(milliseconds: 50), (_) {
      tick++;
      healthyServer.setValue(keyHealthy, tick);
      darkServer.setValue(keyDark, tick);
    });
    addTearDown(pump.cancel);

    // Both workers must be genuinely WORKING before they are stopped. A
    // shutdown that is fast because there was nothing running is not a
    // measurement of anything — it is the same figure a broken spawn would
    // produce.
    pipe.subscribe(keyHealthy);
    pipe.subscribe(keyDark);
    await _waitUntil(
      () =>
          pipe.read(keyHealthy).value != null && pipe.read(keyDark).value != null,
      const Duration(seconds: 60),
      reason: 'a worker never piped a first reading, so this run would be '
          'timing the teardown of something that was never up',
      every: const Duration(milliseconds: 25),
    );
    expect(darkWorker.isolate, isNotNull);
    expect(healthyWorker.isolate, isNotNull);

    // The state where a graceful teardown costs 5.76 s: the session is up at
    // the server, the socket forwards nothing back, and the client's own
    // disconnect handshake will therefore wait out its full timeout. Given a
    // second to settle so the link is unambiguously in it.
    darkServer.proxy!.bufferServerToClient = true;
    await Future<void>.delayed(const Duration(seconds: 1));

    final watch = Stopwatch()..start();
    pipe.shutdown();
    final callMs = watch.elapsedMilliseconds;
    // The call returning fast is necessary and not sufficient: `shutdown()`
    // returns void precisely so nobody can await it, which also means a
    // shutdown that kills nothing would look identical from here. The claim is
    // that the ISOLATES ARE GONE, so the clock runs until the VM says so.
    await _waitUntil(
      () => healthyWorker.isolate == null && darkWorker.isolate == null,
      const Duration(seconds: 30),
      reason: 'an isolate outlived the shutdown that killed it — with a '
          'blackholed upstream, which is exactly the case where a graceful '
          'teardown would still be waiting',
    );
    watch.stop();
    final deadMs = watch.elapsedMilliseconds;
    print('criterion 5: shutdown() returned in ${callMs}ms; both isolates '
        'confirmed dead ${deadMs}ms after the call, with one upstream '
        'blackholed (the graceful path on the same fault is measured by the '
        'next arm)');

    expect(callMs, lessThan(kShutdownBound.inMilliseconds),
        reason: 'shutdown() itself blocked. It is Isolate.kill(immediate) per '
            'worker and nothing else; anything measurable here is something '
            'waiting on a network that has stopped answering. '
            'Measured ${callMs}ms');
    expect(deadMs, lessThan(kShutdownBound.inMilliseconds),
        reason: 'the backend was still alive ${deadMs}ms after being told to '
            'stop, with a blackholed PLC attached. The stall this replaced was '
            '5759ms; the point of the kill is that the dark link cannot charge '
            'us for its own silence');

    // Dead, and staying dead. The supervisor's backoff floor is 2 s, so a
    // shutdown that killed the isolate without setting the no-respawn guard
    // (12-04's sabotage 2) would look perfect above and resurrect the worker
    // immediately afterwards — a "stopped" backend that reconnects to a plant.
    final generationsAtKill =
        <int>[healthyWorker.generation, darkWorker.generation];
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(healthyWorker.isolate, isNull,
        reason: 'the healthy worker came back after the backend was stopped');
    expect(darkWorker.isolate, isNull,
        reason: 'the blackholed worker came back after the backend was '
            'stopped');
    expect(<int>[healthyWorker.generation, darkWorker.generation],
        generationsAtKill,
        reason: 'a new generation handshaked after shutdown: the kill fired '
            'but the no-respawn guard did not, so the supervisor rebuilt what '
            'the operator asked to be stopped');
  });

  test(
      'the graceful teardown shutdown refuses to await really does stall on a '
      'blackholed link', () async {
    const key = 'stalling.counter';
    const alias = 'PLC-STALL';

    final fixture = await OpcUaServerFixture.start(
        valueKeys: const <String>[key], viaProxy: true);
    addTearDown(fixture.dispose);

    // A StateMan in THIS isolate — the same object the worker holds, closed the
    // way the backend closed it before this phase. Nothing about the stall is
    // specific to running inside a worker; what is specific to the worker is
    // that we never call this.
    final stateMan = await OpcUaStateMan.create(
      config: StateManConfig(
          opcua: <OpcUAConfig>[_serverConfig(fixture.endpoint, alias)]),
      keyMappings: _mappingsFor(key, alias),
      useIsolate: false,
      alias: 'hazard',
    );

    var samples = 0;
    final stream = await stateMan.subscribe(key);
    final subscription =
        stream.listen((DynamicValue _) => samples++, onError: (Object _) {});
    addTearDown(subscription.cancel);

    var tick = 0;
    final pump = Timer.periodic(const Duration(milliseconds: 50), (_) {
      tick++;
      fixture.setValue(key, tick);
    });
    addTearDown(pump.cancel);

    await _waitUntil(() => samples > 0, const Duration(seconds: 60),
        reason: 'the hazard link never delivered a sample, so there is no live '
            'session for a graceful close to stall on',
        every: const Duration(milliseconds: 25));

    fixture.proxy!.bufferServerToClient = true;
    await Future<void>.delayed(const Duration(seconds: 1));

    final watch = Stopwatch()..start();
    await stateMan.close();
    watch.stop();
    print('criterion 5 (hazard): StateMan.close() on a blackholed link took '
        '${watch.elapsedMilliseconds}ms');

    expect(watch.elapsed, greaterThan(kShutdownBound),
        reason: 'the graceful teardown did NOT stall on a dark link, so the '
            '<${kShutdownBound.inMilliseconds}ms bound in the arm above is '
            'satisfied by a machine on which nothing is slow and proves '
            'nothing about the 5759ms stall it claims to have removed. Either '
            'disconnect() stopped blocking (a good problem — revisit this '
            'file) or the blackhole did not take. '
            'Measured ${watch.elapsedMilliseconds}ms');
  });
}
