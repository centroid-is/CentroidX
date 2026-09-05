/// PIPE-11 + PIPE-13 criterion 4: one blackholed PLC is one PLC's blast radius.
///
/// This is the property the whole pipe exists for. Before it, a single stalled
/// OPC UA server took the collection isolate's event loop with it — `runIterate`
/// is a blocking FFI `select()` and a silent socket makes it sleep its full
/// timeout, on whatever isolate made the call (open62541_dart #116). Every other
/// server sharing that isolate went quiet at the same time, and an operator
/// three screens away, watching a machine that was perfectly healthy, saw
/// numbers that had stopped moving and no badge saying so.
///
/// The topology that fixes it is one acquisition isolate per server, with a
/// conflating pipe to main. This file is the measurement that the fix holds
/// **through the stack that ships**: two real workers spawned from the
/// production entry body ([runAcquisitionIsolate], 12-07's seam), each with its
/// own real in-process OPC UA server on its own kernel-allocated port, both
/// feeding one [PipeMainEndpoint], with values reaching main only through
/// [PipeMainEndpoint.subscribe] — the same path `RemoteStateMan` will use.
///
/// ## The two arms must disagree
///
/// `tfc_relay_local/test/slow_upstream_isolation_test.dart:33-40` states the
/// rule this file inherits: *a two-term predicate needs the terms to disagree,
/// or the case is decoration.* An isolation test where both arms look healthy
/// has not proven isolation — it has proven that the probe cannot see
/// starvation, and it would go on passing after the isolation was deleted.
///
/// So the fault window asserts three things, and the third is the load-bearing
/// one:
///
///  1. the healthy server's arm keeps arriving on main at cadence;
///  2. the blackholed server's arm stops advancing (or degrades to a bad
///     quality badge, which is the other honest outcome);
///  3. **the two rates disagree by a wide margin.** If they ever converge —
///     both healthy or both starved — this file fails, and the failure says so
///     in those words.
///
/// Thresholds are **baseline-relative, never ideal-relative**. The healthy
/// link's own polling and the two in-process servers' 10 ms cranks already cost
/// a large fraction of the ideal tick count while everything is perfectly well
/// (measured at ~36% of ideal in the relay's arm), so the ideal is the wrong
/// yardstick and an absolute threshold derived from it would fail on a loaded
/// CI box for reasons that have nothing to do with isolation. What the blackhole
/// must not do is make the healthy arm *worse than it already was*.
///
/// Dynamic ports only — every port here comes from the kernel, via the fixture
/// or [freePort]. A literal collides deterministically with the same suite
/// running in a parallel worktree (project memory).
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';

import 'package:postgres/postgres.dart' show Endpoint;
import 'package:test/test.dart';
import 'package:tfc_dart/core/data_acquisition_isolate.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/pipe_main_endpoint.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import '../support/free_port.dart';
import '../support/opcua_server_fixture.dart';

/// A [Database] that answers everything and connects to nothing.
///
/// The acquisition stack takes a [Database] object rather than a connection
/// (12-04's OQ-3 seam), so it stands up with one that has no server behind it
/// and this file stays out of the Docker lane. Copied rather than shared for
/// the same reason `pipe_write_roundtrip_test.dart` copies it: it has to be
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

/// The production worker, with Postgres swapped out and nothing else.
///
/// [runAcquisitionIsolate] is the entire body of
/// [dataAcquisitionIsolateEntry] — same handshake, same [PipeControlInbox],
/// same `buildAcquisitionStack`, same `PipeWorkerEndpoint` attach, same
/// `runZonedGuarded`. A hand-assembled stand-in would prove that the stand-in
/// isolates well, which is not a claim anybody needs.
///
/// Must be top-level: closures are not sendable (dartbug.com/36983). Both
/// workers in this file are spawned from this one function.
@pragma('vm:entry-point')
Future<void> isolationWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: NoopDatabase());

/// How often each server's tag is given a new value.
///
/// Faster than the 100 ms default publishing interval
/// (`OpcUAConfig.publishingIntervalMs`) on purpose: the cadence main sees is
/// then set by the subscription and the pipe, not by how often the test
/// remembers to move a number.
const Duration valuePumpPeriod = Duration(milliseconds: 50);

/// How long each measured window runs.
const Duration window = Duration(seconds: 5);

/// Settling time before the baseline window opens.
///
/// Both workers have already handshaked and both keys have already carried a
/// first reading by the time this starts — this is the subscription finding its
/// rhythm, not the rig finding its feet.
const Duration warmUp = Duration(seconds: 3);

/// The healthy server, and the tag main watches on it.
const String aliasA = 'PLC-A';
const String keyA = 'plcA.line.counter';

/// The server whose wire goes dark half way through.
const String aliasB = 'PLC-B';
const String keyB = 'plcB.line.counter';

/// One arm's behaviour over one measured window.
final class _WindowStats {
  _WindowStats(this.arm, this.updates, this.maxGapMs, this.windowMs);

  /// Which arm this describes, so a failure message names it.
  final String arm;

  /// Values that actually reached main's cache and changed it, in this window.
  ///
  /// Counted at the [relay.ValueStore] node, which notifies only on a genuine
  /// change — so a link that keeps re-delivering the same stale number counts
  /// as the silence it is.
  final int updates;

  /// The longest interval between two arrivals in this window.
  final int maxGapMs;

  final int windowMs;

  /// Arrivals per millisecond. The comparable figure between two windows of
  /// slightly different length — and the windows always are, because a mark is
  /// taken when the test gets around to it rather than on a clock edge.
  double get rate => windowMs == 0 ? 0 : updates / windowMs;

  @override
  String toString() => '$arm(updates: $updates, maxGap: ${maxGapMs}ms, '
      '${(rate * 1000).toStringAsFixed(1)}/s over ${windowMs}ms)';
}

/// A cadence probe on one key of main's cache.
///
/// Listens to the [relay.ValueStore] node [PipeMainEndpoint.listen] hands out —
/// which is exactly the object a widget would hold — so what is being measured
/// is what an operator's screen would receive, not an internal counter that
/// could be healthy while the screen is frozen.
final class _Arm {
  _Arm(this.name, this.key, this._node, this._clock) {
    _node.addListener(_onChanged);
    _windowStartMs = _clock.elapsedMilliseconds;
    _lastMs = _windowStartMs;
  }

  final String name;
  final String key;
  final relay.ValueListenable<relay.DynamicValue> _node;
  final Stopwatch _clock;

  int _updates = 0;
  int _maxGapMs = 0;
  int _lastMs = 0;
  int _windowUpdates = 0;
  int _windowStartMs = 0;

  void _onChanged() {
    final now = _clock.elapsedMilliseconds;
    final gap = now - _lastMs;
    if (gap > _maxGapMs) _maxGapMs = gap;
    _lastMs = now;
    _updates++;
  }

  /// Closes the current window, reports it, and opens the next one.
  _WindowStats mark() {
    final now = _clock.elapsedMilliseconds;
    final stats = _WindowStats(
        name, _updates - _windowUpdates, _maxGapMs, now - _windowStartMs);
    _windowStartMs = now;
    _windowUpdates = _updates;
    _maxGapMs = 0;
    // A gap that spans a mark belongs to the window it ends in.
    _lastMs = now;
    return stats;
  }

  void detach() => _node.removeListener(_onChanged);
}

/// Two servers, two real workers, one main endpoint, one value pump.
final class _Rig {
  _Rig({
    required this.serverA,
    required this.serverB,
    required this.workerA,
    required this.workerB,
    required this.pipe,
    required this.armA,
    required this.armB,
  });

  final OpcUaServerFixture serverA;
  final OpcUaServerFixture serverB;
  final DataAcquisitionWorker workerA;
  final DataAcquisitionWorker workerB;
  final PipeMainEndpoint pipe;
  final _Arm armA;
  final _Arm armB;

  /// Takes both arms' windows at as near the same instant as one isolate can.
  (_WindowStats, _WindowStats) mark() => (armA.mark(), armB.mark());
}

KeyMappings _mappingsFor(String key, String alias) =>
    KeyMappings(nodes: <String, KeyMappingEntry>{
      key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
          ..serverAlias = alias,
      ),
    });

/// Spawns one real acquisition worker against one endpoint.
///
/// The mappings handed here are one server's `filterByServer` partition, which
/// is exactly what `bin/main.dart` hands its own spawns — so the router on main
/// cannot disagree with the topology.
Future<DataAcquisitionWorker> _spawnWorker({
  required String alias,
  required String endpoint,
  required KeyMappings mappings,
}) async {
  final server = OpcUAConfig()
    ..endpoint = endpoint
    ..serverAlias = alias;

  final worker = await spawnWorkerForTest(
    DataAcquisitionIsolateConfig(
      serverJson: server.toJson(),
      // A port nothing listens on. The injected NoopDatabase means it is never
      // dialled; naming a dead port here is what makes a regression of that
      // seam fail as a silent pipe rather than as a mysterious hang.
      dbConfigJson: DatabaseConfig(
        postgres: Endpoint(
            host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
      ).toJson(),
      keyMappingsJson: mappings.toJson(),
    ),
    alias,
    entryPoint: isolationWorkerEntry,
  );
  // Registered BEFORE the ready await, so a worker that never announces itself
  // is still torn down. `kill` is `Isolate.kill(priority: immediate)`: it does
  // not ask the worker to cooperate, so a wedged isolate cannot hang teardown —
  // which is why this file needs no grace period around it.
  addTearDown(worker.kill);
  await worker.ready.timeout(const Duration(seconds: 60),
      onTimeout: () =>
          fail('$alias never handed back its control port — no worker, no arm'));
  return worker;
}

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

Future<_Rig> _standUp() async {
  final serverA = await OpcUaServerFixture.start(valueKeys: const <String>[keyA]);
  addTearDown(serverA.dispose);
  // Only B gets a proxy: the blackhole is the one asymmetry in this rig, and
  // everything else — server kind, node kind, mapping shape, worker entry
  // point, pump period — is identical, so a difference between the arms can
  // only have come from the fault.
  final serverB = await OpcUaServerFixture.start(
      valueKeys: const <String>[keyB], viaProxy: true);
  addTearDown(serverB.dispose);

  final mappingsA = _mappingsFor(keyA, aliasA);
  final mappingsB = _mappingsFor(keyB, aliasB);

  final workerA = await _spawnWorker(
      alias: aliasA, endpoint: serverA.endpoint, mappings: mappingsA);
  final workerB = await _spawnWorker(
      alias: aliasB, endpoint: serverB.endpoint, mappings: mappingsB);

  final pipe = PipeMainEndpoint();
  addTearDown(pipe.dispose);
  pipe.addWorker(AcquisitionWorkerLink(workerA), mappingsA.keys);
  pipe.addWorker(AcquisitionWorkerLink(workerB), mappingsB.keys);

  var tick = 0;
  final pump = Timer.periodic(valuePumpPeriod, (_) {
    tick++;
    serverA.setValue(keyA, tick);
    serverB.setValue(keyB, tick);
  });
  addTearDown(pump.cancel);

  // THE path. Without this call the workers pipe nothing at all — they send
  // only what main asked for — and criterion 4 could not be observed, because
  // both arms would be silent for a reason that has nothing to do with any
  // fault.
  pipe.subscribe(keyA);
  pipe.subscribe(keyB);

  await _waitUntil(
    () => pipe.read(keyA).value != null && pipe.read(keyB).value != null,
    const Duration(seconds: 60),
    reason: 'one of the two arms never carried a first reading '
        '(A: ${pipe.read(keyA)}, B: ${pipe.read(keyB)}) — both must be alive '
        'before either can be shown to have starved',
  );

  final clock = Stopwatch()..start();
  final armA = _Arm('healthy/$aliasA', keyA, pipe.listen(keyA), clock);
  final armB = _Arm('blackholed/$aliasB', keyB, pipe.listen(keyB), clock);
  addTearDown(armA.detach);
  addTearDown(armB.detach);

  return _Rig(
    serverA: serverA,
    serverB: serverB,
    workerA: workerA,
    workerB: workerB,
    pipe: pipe,
    armA: armA,
    armB: armB,
  );
}

void main() {
  test(
      'one blackholed server starves only its own isolate: the other server\'s '
      'values keep arriving on main at cadence', () async {
    final rig = await _standUp();

    // ---------------------------------------------------------- the baseline
    await Future<void>.delayed(warmUp);
    rig.mark(); // discard the warm-up window
    await Future<void>.delayed(window);
    final (baseA, baseB) = rig.mark();

    expect(baseA.updates, greaterThan(10),
        reason: 'the healthy arm has no baseline, so nothing measured after '
            'the fault can mean anything: $baseA');
    // The precondition that makes the fault window a measurement rather than a
    // coincidence: B must be DEMONSTRABLY healthy before it is broken. An arm
    // that was never delivering cannot be shown to have stopped.
    expect(baseB.updates, greaterThan(10),
        reason: 'the arm about to be blackholed was not delivering in the '
            'first place, so its silence afterwards proves nothing: $baseB');

    final aBefore = rig.pipe.read(keyA).value;
    final bBefore = rig.pipe.read(keyB).value;

    // ------------------------------------------------------------- the fault
    // Server→client held, client→server still forwarded: the session stays up
    // at the server and the fault is a SILENCE rather than a disconnect. That
    // is the production failure — a link that looks fine and answers nothing —
    // and it is the one that used to block `runIterate` for its full timeout.
    rig.serverB.proxy!.bufferServerToClient = true;

    await Future<void>.delayed(window);
    final (faultA, faultB) = rig.mark();

    final aAfter = rig.pipe.read(keyA).value;
    final bAfter = rig.pipe.read(keyB).value;
    final bQuality = rig.pipe.read(keyB).quality;
    final evidence = 'baseline: $baseA / $baseB — fault: $faultA / $faultB. '
        'A moved $aBefore -> $aAfter; B moved $bBefore -> $bAfter '
        '(quality ${bQuality.code})';

    // Printed, not only attached to failures: this arm's whole content is a
    // measurement, and a measurement nobody can read after a green run is a
    // claim rather than evidence. It is one line against the logger's flood.
    print('criterion 4: $evidence');

    // ---------------------------------------------------------- arm 1: A held
    expect(faultA.updates, greaterThan(10),
        reason: 'the healthy server published all through the blackhole; '
            'silence on ITS arm is the other server\'s stall escaping its '
            'isolate, which is the whole failure this phase removed. '
            '$evidence');
    // Baseline-relative, deliberately. The healthy link's own polling and the
    // two in-process server cranks already eat a large share of this isolate
    // while everything is well, so the ideal rate is the wrong yardstick; what
    // the blackhole must not do is make the healthy arm worse.
    expect(faultA.rate, greaterThan(baseA.rate * 0.5),
        reason: 'the healthy arm\'s cadence more than halved when the OTHER '
            'server went dark. $evidence');
    expect(faultA.maxGapMs, lessThan(1000),
        reason: 'a 100 ms publishing interval should never gap a second unless '
            'something stalled. $evidence');
    expect(aAfter, isNot(aBefore),
        reason: 'the healthy arm\'s value did not move at all across the fault '
            'window — a cadence count can be satisfied by quality flapping, a '
            'moving number cannot. $evidence');

    // ------------------------------------------------------ arm 2: B starved
    // Either honest outcome counts: the values stop advancing, or the key is
    // badged bad. What must NOT happen is fresh-looking numbers on a link that
    // is delivering nothing.
    final bStopped = faultB.rate < baseB.rate * 0.2 || bAfter == bBefore;
    final bDegraded = !bQuality.isGood;
    expect(bStopped || bDegraded, isTrue,
        reason: 'THE PROBE IS BROKEN, not the code: the blackholed arm kept '
            'delivering fresh values at cadence through a wire that forwards '
            'nothing back. Nothing downstream of a dead link can be honest, so '
            'either the blackhole did not take or this arm is measuring '
            'something other than what arrives on main. $evidence');

    // ------------------------------- the mandatory disagreement, stated once
    //
    // slow_upstream_isolation_test.dart:33-40. Everything above can be
    // satisfied by two arms that are BOTH healthy (if the fault never landed)
    // or BOTH starved (if the stall escaped). This is the assertion that
    // refuses both of those worlds, and it is the one that keeps the file
    // honest if somebody later deletes the isolation.
    expect(faultB.rate, lessThan(faultA.rate * 0.5),
        reason: 'THE TWO ARMS DID NOT DISAGREE. An isolation test whose arms '
            'agree has measured nothing: if both are healthy the blackhole '
            'never landed, and if both are starved the blast radius is the '
            'whole backend — which is the bug. $evidence');

    // ------------------------------- arm 3: the starving arm says so, in time
    //
    // Stopping is only half of honest. A frozen number under a good badge is
    // precisely the silent-stale failure this project exists to remove — worse
    // than a gap, because the operator has no way to tell. So the blackholed
    // key must also become *visibly* bad, while the healthy one must not.
    //
    // Measured at ~4 s past the fault window (so ~9 s of blackhole) on this
    // machine; the bound below is loose because the mechanism is the OPC UA
    // subscription's own heartbeat and its timing is the server's business,
    // while the property — it arrives at all, and only on the dark link — is
    // this file's.
    final badge = Stopwatch()..start();
    await _waitUntil(
      () => !rig.pipe.read(keyB).quality.isGood,
      const Duration(seconds: 45),
      reason: 'the blackholed key was still badged GOOD long after its link '
          'went dark. It stopped moving (proven above) and said nothing about '
          'it, which is the one outcome worse than a gap. $evidence',
    );
    badge.stop();
    final (tailA, tailB) = rig.mark();
    print('criterion 4: B badged ${rig.pipe.read(keyB).quality.code} '
        '${badge.elapsedMilliseconds}ms after the fault window closed; '
        'tail $tailA / $tailB');

    expect(rig.pipe.read(keyB).quality.code, relay.Quality.badCommFault.code,
        reason: 'badCommFault is the band that says "the link is sick, waiting '
            'may fix it" — which is exactly true of a blackholed wire, and a '
            'different instruction to an operator than errorConfig. $evidence');
    expect(rig.pipe.read(keyB).value, isNull,
        reason: 'no payload under a bad badge: a number nobody measured, '
            'greyed out, is still a number nobody measured. $evidence');
    expect(rig.pipe.read(keyA).quality.isGood, isTrue,
        reason: 'the healthy server was badged bad because a DIFFERENT server '
            'went dark — the blast radius escaped, in the badge if not in the '
            'values. $evidence');
    expect(tailA.updates, greaterThan(0),
        reason: 'the healthy arm stopped arriving while the other arm was '
            'being badged. $evidence');
  });
}
