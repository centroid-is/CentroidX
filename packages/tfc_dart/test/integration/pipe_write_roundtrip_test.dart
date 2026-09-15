/// PIPE-12 criterion 3, end to end, through the stack that ships.
///
/// The unit lanes prove the classification (12-05) and the routing (12-06)
/// against fakes. This file proves the *composition*: an operator write on main
/// crosses a real `Isolate`, is executed by a real `StateMan` against a real
/// in-process OPC UA server, and comes back applied, rejected or unknown — with
/// the three distinguishable from each other through
/// [PipeMainEndpoint.write]'s own return value and nothing else.
///
/// Three properties, and each one is a different way for the write path to lie
/// to somebody standing next to a machine:
///
///  1. **All three states are reachable and distinct.** A pipe that can only
///     say `unknown` is safe and useless; one that says `rejected` when it does
///     not know is dangerous, because "rejected" is the answer that invites a
///     second press of the button.
///  2. **A killed worker resolves its in-flight write inside the deadline.**
///     Not "eventually", not "at the deadline" — the `onExit` fast path is
///     supposed to answer sooner than the timer, and a regression to an
///     unbounded await must fail loudly instead of parking the suite. Every
///     await here is therefore bounded.
///  3. **Nothing is ever re-sent.** The oracle is the *server's* own counter
///     ([OpcUaServerFixture.writeCount]) — the far end of the wire is the only
///     place that can tell a re-issued write from a re-tried one — and it is
///     read across a death and a respawn, which is the one moment the pipe
///     holds a request it could be tempted to replay.
///
/// ## Why a real isolate rather than a fake link
///
/// Phase 10's CR-01 lesson: the composition nothing assembles is the only one
/// that ships untested. Both endpoints have green unit suites; what neither can
/// show is that they agree — that main's `PipeWriteRequest` survives the deep
/// copy across the port, that the worker's `sourceTypeId` round-trip produces a
/// payload open62541 will actually encode, and that a `Bad_NotWritable` raised
/// by a server callback is still a *named* refusal by the time it reaches the
/// caller on main.
///
/// The one thing that is not real here is Postgres: the worker runs the
/// production entry body with a [NoopDatabase] injected (12-04's OQ-3 seam), so
/// this file stays in the fast lane and needs no Docker.
///
/// Dynamic ports only — every port in this file comes from the kernel, via the
/// fixture or [freePort]. A literal collides deterministically with the same
/// suite running in a parallel worktree (project memory).
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:isolate';

import 'package:open62541/open62541.dart' show UA_STATUSCODE_BADNOTWRITABLE;
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
/// The same shape as `test/core/pipe_worker_lifecycle_test.dart`'s and
/// `test/core/acquisition_isolate_fatal_test.dart`'s: the acquisition stack
/// takes a [Database] object rather than a connection, so it stands up with one
/// that has no server behind it. Copied rather than shared because it has to be
/// reachable from an isolate entry point in *this* file.
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
/// [runAcquisitionIsolate] is the body of [dataAcquisitionIsolateEntry] — the
/// same handshake, the same [PipeControlInbox], the same
/// `buildAcquisitionStack`, the same `PipeWorkerEndpoint` attach, inside the
/// same `runZonedGuarded`. Only the [Database] differs, which is exactly the
/// seam 12-04 built for this (OQ-3). Anything more heavily stubbed than this
/// would be a composition of test doubles, and a composition of test doubles is
/// the thing this file exists to stop trusting.
///
/// Must be a top-level function: closures are not sendable (dartbug.com/36983).
@pragma('vm:entry-point')
Future<void> pipeWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: NoopDatabase());

/// The server alias every key in this file is routed through.
const String kAlias = 'fixture';

/// Everything one arm needs standing up: a real server, a real worker isolate
/// talking to it, and main's endpoint holding the other end.
class _Rig {
  _Rig(this.fixture, this.worker, this.pipe);

  final OpcUaServerFixture fixture;
  final DataAcquisitionWorker worker;
  final PipeMainEndpoint pipe;
}

/// Stands up fixture → worker → pipe, and registers the teardown.
///
/// Teardown order is not decoration: the worker is killed *first* so its client
/// stops talking to a server that is about to be deleted, and the fixture's own
/// `dispose` then runs its documented order (driver → proxy → shutdown →
/// delete). Getting that wrong SEGVs the VM and destroys the result of the arm
/// that just ran.
Future<_Rig> _startRig({
  List<String> valueKeys = const <String>[],
  List<String> writeKeys = const <String>[],
  bool viaProxy = false,
}) async {
  final fixture = await OpcUaServerFixture.start(
    valueKeys: valueKeys,
    writeKeys: writeKeys,
    viaProxy: viaProxy,
  );
  addTearDown(fixture.dispose);

  final keys = <String>[...valueKeys, ...writeKeys];
  final mappings = KeyMappings(nodes: <String, KeyMappingEntry>{
    for (final key in keys)
      key: KeyMappingEntry(
        opcuaNode: OpcUANodeConfig(
            namespace: fixtureNamespace, identifier: key)
          ..serverAlias = kAlias,
      ),
  });

  final server = OpcUAConfig()
    ..endpoint = fixture.endpoint
    ..serverAlias = kAlias;

  final worker = await spawnWorkerForTest(
    DataAcquisitionIsolateConfig(
      serverJson: server.toJson(),
      // A port nothing listens on. The injected NoopDatabase means it is never
      // dialled; if the seam ever regressed, the stack would sit in
      // connectWithRetry and the handshake — which is sent BEFORE the database
      // — would still arrive, so the arm would fail on a silent pipe rather
      // than on a spawn timeout. Naming the dead port here is what makes that
      // failure legible.
      dbConfigJson: DatabaseConfig(
        postgres: Endpoint(
            host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
      ).toJson(),
      keyMappingsJson: mappings.toJson(),
    ),
    kAlias,
    entryPoint: pipeWorkerEntry,
  );
  // Kills a wedged worker rather than hanging the suite on the defect under
  // test. Registered before the ready await, so a worker that never announces
  // itself is still cleaned up.
  addTearDown(worker.kill);
  await worker.ready.timeout(const Duration(seconds: 30),
      onTimeout: () => fail('the worker never handed back its control port'));

  final pipe = PipeMainEndpoint();
  addTearDown(pipe.dispose);
  pipe.addWorker(AcquisitionWorkerLink(worker), mappings.keys);

  return _Rig(fixture, worker, pipe);
}

/// Polls [predicate] until it holds or [within] elapses.
///
/// A poll rather than a flat delay so a fast machine does not pay for the slow
/// machine's margin — and so the failure names what never happened instead of
/// an expectation on a value that simply had not arrived yet.
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

/// Subscribes [key] and waits for the pipe to carry a first real reading.
///
/// Every write arm does this first, and not only as a settling step: main fills
/// a write payload's `sourceTypeId` from its cache
/// ([PipeMainEndpoint.write] → `_withTypeId`), and without an observed reading
/// the only source left is the Dart runtime type — which cannot tell an `Int16`
/// node from an `Int64` one and earns a `Bad_TypeMismatch`. An operator's write
/// in production follows a subscribed readout for the same reason.
Future<void> _subscribeAndSettle(_Rig rig, String key) async {
  rig.pipe.subscribe(key);
  await _waitUntil(
    () => rig.pipe.read(key).value != null,
    const Duration(seconds: 30),
    reason: 'the pipe never carried a first reading for "$key" — the worker '
        'is up but nothing is crossing the port',
  );
}

/// A write left in flight when its worker was killed.
class _KilledWrite {
  _KilledWrite(this.pending, this.sinceKill);

  /// The caller's future, still unsettled at the moment of the kill.
  final Future<relay.WriteResult> pending;

  /// Started at the kill, so a measurement is "how long after the death", not
  /// "how long after the button".
  final Stopwatch sinceKill;
}

/// Starts a write the link will not answer, waits until the SERVER has it, and
/// then kills the owning isolate out from under it.
///
/// Two details carry the weight:
///
///  * the link is blackholed **before** the write, so the request is genuinely
///    in flight rather than already answered — otherwise the kill would race a
///    completed future and the arm would pass on nothing;
///  * the kill waits for `writeCount` to reach 1, so the request provably
///    reached the far end. Without that wait, "the server saw one write" could
///    be satisfied by a re-send after the respawn and the no-retry oracle would
///    be vacuous (12-06's mutation H: an arm that asserts an absence proves
///    nothing until the presence has been made possible).
///
/// The isolate is killed directly rather than through
/// [DataAcquisitionWorker.kill], which sets the no-respawn guard — this arm
/// needs a crash the supervisor will answer, not a shutdown.
Future<_KilledWrite> _writeThenKillOwner(
    _Rig rig, String key, Object? value) async {
  rig.fixture.proxy!.bufferServerToClient = true;

  final pending = rig.pipe.write(key, relay.DynamicValue(value: value));
  await _waitUntil(
    () => rig.fixture.writeCount(key) >= 1,
    const Duration(seconds: 20),
    reason: 'the write never reached the server, so there is nothing in '
        'flight to kill and nothing a retry could duplicate',
  );

  final isolate = rig.worker.isolate;
  expect(isolate, isNotNull, reason: 'nothing to kill');
  final sinceKill = Stopwatch()..start();
  isolate!.kill(priority: Isolate.immediate);
  return _KilledWrite(pending, sinceKill);
}

/// A [relay.WriteResult] as a failure message reads it.
///
/// The sealed type's `toString` is the class name, so a failed arm would say
/// only "not an instance of WriteRejected" and the reason — the whole content
/// of the answer — would be lost. Every expectation on an outcome in this file
/// carries this.
String _describe(relay.WriteResult result) => switch (result) {
      relay.WriteApplied(readback: final readback) =>
        'WriteApplied(readback: $readback)',
      relay.WriteRejected(reason: final reason) =>
        'WriteRejected(${reason.kind}, status: ${reason.status}, '
            '${reason.message})',
      relay.WriteUnknown(reason: final reason) =>
        'WriteUnknown(${reason.kind}, status: ${reason.status}, '
            '${reason.message})',
      // `writeStatus` only — nothing on this path can mint one, and the switch
      // is exhaustive so that stays a compile-time fact rather than a comment.
      relay.WriteNotReceived() => 'WriteNotReceived',
    };

void main() {
  group('the three states, through a real worker against a real server', () {
    test('a writable node answers APPLIED, and the value really moves',
        () async {
      const key = 'pump.setpoint';
      final rig = await _startRig(valueKeys: const <String>[key]);
      await _subscribeAndSettle(rig, key);

      final result = await rig.pipe
          .write(key, relay.DynamicValue(value: 7))
          .timeout(const Duration(seconds: 20),
              onTimeout: () => fail('the write never settled at all'));

      expect(result, isA<relay.WriteApplied>(),
          reason: 'a plain writable node accepted the write; anything less '
              'than "applied" here means the composed path cannot report '
              'success even when there is success to report. Got '
              '${_describe(result)}');

      // Applied is a claim about the machine, not about the pipe. The readback
      // is the only confirmation this system accepts (CLAUDE.md), and it
      // arrives the same way an operator's screen gets it: as a piped sample.
      await _waitUntil(
        () => rig.pipe.read(key).value == 7,
        const Duration(seconds: 20),
        reason: 'the write was reported applied but the served value never '
            'became 7 — "applied" that did not move the node is the worst of '
            'the three answers',
      );
    });

    test('a node whose server callback refuses answers REJECTED, by name',
        () async {
      const key = 'gate.command';
      final rig = await _startRig(writeKeys: const <String>[key]);
      await _subscribeAndSettle(rig, key);

      // A NAMED refusal. The classifier reads the code's name out of
      // UaStatusException.toString(); an unnamed failure is Bad_InternalError,
      // which is not in the refusal table and is therefore unknown — the safe
      // half. Both halves have to be reachable or neither is evidence.
      rig.fixture.setWriteRefusal(key, UA_STATUSCODE_BADNOTWRITABLE);

      final result = await rig.pipe
          .write(key, relay.DynamicValue(value: 3))
          .timeout(const Duration(seconds: 20),
              onTimeout: () => fail('the refused write never settled'));

      expect(result, isA<relay.WriteRejected>(),
          reason: 'the server named its refusal; reporting that as unknown '
              'would send an operator to inspect a machine that had already '
              'told them no. Got ${_describe(result)}');
      expect((result as relay.WriteRejected).reason.status, 'Bad_NotWritable',
          reason: 'the name survives StateMan flattening the exception into a '
              'StateManException message, which is the only channel it has');

      expect(rig.fixture.writeCount(key), 1,
          reason: 'the server saw the write exactly once — a refusal is not a '
              'reason to try again, ever');
    });

    test('a blackholed link answers UNKNOWN, inside the deadline, never hangs',
        () async {
      const key = 'gate.command';
      final rig = await _startRig(
          writeKeys: const <String>[key], viaProxy: true);
      await _subscribeAndSettle(rig, key);

      // Server→client held, client→server still forwarded: the session stays
      // alive at the server and the fault is a SILENCE rather than a
      // disconnect. That is the production failure mode — a link that looks up
      // and answers nothing — and it is the one where a pipe without a
      // deadline parks a caller forever.
      rig.fixture.proxy!.bufferServerToClient = true;

      final stopwatch = Stopwatch()..start();
      final result = await rig.pipe
          .write(key, relay.DynamicValue(value: 4))
          .timeout(kPipeWriteDeadline + const Duration(seconds: 10),
              onTimeout: () => fail('the write never settled — an unbounded '
                  'await on a silent link is the hang this deadline exists '
                  'to remove'));
      stopwatch.stop();

      expect(result, isA<relay.WriteUnknown>(),
          reason: 'nobody can say whether the request landed; "unknown" is '
              'the only honest answer and the pipe has to be able to give '
              'it. Got ${_describe(result)}');
      expect(
        (result as relay.WriteUnknown).reason.kind,
        anyOf('plc_timeout', 'pipe_timeout'),
        reason: 'got ${_describe(result)}. '
            'plc_timeout is the worker saying the request reached the '
            'link; pipe_timeout is main saying the worker said nothing. Both '
            'are honest here and which one wins is a race between two '
            'deadlines — but a third kind would mean neither fired',
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 9)),
          reason: 'the worker answers at 4s and main at 5s; anything past '
              'that is an await nothing bounds. Measured: '
              '${stopwatch.elapsedMilliseconds}ms');
    });
  });

  group('a worker killed with a write in flight', () {
    test('resolves that write UNKNOWN well inside the deadline', () async {
      const key = 'gate.command';
      final rig = await _startRig(
          writeKeys: const <String>[key], viaProxy: true);
      await _subscribeAndSettle(rig, key);

      final killed = await _writeThenKillOwner(rig, key, 5);

      final result = await killed.pending.timeout(kPipeWriteDeadline,
          onTimeout: () => fail('the pending write outlived the deadline — a '
              'write whose isolate is gone must not be left to a timer, and '
              'must certainly not hang'));
      killed.sinceKill.stop();

      expect(result, isA<relay.WriteUnknown>(),
          reason: 'the isolate that held the request is gone; nobody can say '
              'whether the PLC moved. Got ${_describe(result)}');
      expect((result as relay.WriteUnknown).reason.kind, 'worker_died',
          reason: 'the onExit fast path answered, not a deadline. A '
              'pipe_timeout here would mean main learned of the death from a '
              'timer rather than from the death itself. Got '
              '${_describe(result)}');
      expect(killed.sinceKill.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'death is an EVENT: the answer arrives on the turn the null '
              'sentinel does. The 5s deadline would have answered roughly 4.7s '
              'after this kill, so a figure near that is the timer winning — '
              'the exact decay this phase replaced. Measured: '
              '${killed.sinceKill.elapsedMilliseconds}ms');
    });

    test('never re-sends it across the respawn, and the pipe recovers',
        () async {
      const key = 'gate.command';
      final rig = await _startRig(
          writeKeys: const <String>[key], viaProxy: true);
      await _subscribeAndSettle(rig, key);

      final killed = await _writeThenKillOwner(rig, key, 5);
      final result = await killed.pending.timeout(kPipeWriteDeadline,
          onTimeout: () => fail('the pending write never settled'));
      expect(result, isA<relay.WriteUnknown>(),
          reason: 'precondition for the no-retry claim: the operator has '
              'already been told the outcome is unknown. Got '
              '${_describe(result)}');

      // The link comes back before the replacement dials it. Nothing about the
      // no-retry property depends on the link being down — the point is that
      // the pipe has every opportunity to re-send and does not take it.
      rig.fixture.proxy!.bufferServerToClient = false;

      await _waitUntil(
        () => rig.worker.generation >= 2 && rig.worker.controlPort != null,
        const Duration(seconds: 90),
        reason: 'the supervisor never brought the worker back (backoff floor '
            'is 2s), so there was no respawn for a re-send to ride',
      );
      // The replacement is not merely alive: it has been replayed main's
      // subscription snapshot and is piping again. Waiting for the value the
      // dead generation's write left at the server is what makes the count
      // below a measurement rather than a race — a re-send would have to have
      // happened by now to be a re-send at all.
      await _waitUntil(
        () => rig.pipe.read(key).value == 5,
        const Duration(seconds: 60),
        reason: 'the new generation never piped a reading — main replays a '
            'snapshot on ready, and without it the respawned worker sends '
            'nothing and this arm cannot see a re-send either',
      );

      expect(rig.fixture.writeCount(key), 1,
          reason: 'ONE operator write, one write at the server. The pipe held '
              'a request whose fate it had already reported unknown; '
              're-sending it here would execute a command the operator was '
              'told did not necessarily happen, on a machine somebody may be '
              'standing next to. Server saw: ${rig.fixture.writeLog(key).map(
                    (v) => v.value,
                  ).toList()}');

      // Recovery is the other half: only the in-flight write was dropped.
      final after = await rig.pipe
          .write(key, relay.DynamicValue(value: 9))
          .timeout(const Duration(seconds: 20),
              onTimeout: () => fail('the post-respawn write never settled'));
      expect(after, isA<relay.WriteApplied>(),
          reason: 'the pipe survived the death of one generation; a worker '
              'that comes back and cannot be written to is a pipe that only '
              'looks recovered. Got ${_describe(after)}');
      expect(rig.fixture.writeCount(key), 2,
          reason: 'two operator writes, two writes at the server — the '
              'invariant is one per write, not one for all time');
      await _waitUntil(
        () => rig.pipe.read(key).value == 9,
        const Duration(seconds: 20),
        reason: 'the post-respawn write was reported applied but the served '
            'value never moved',
      );
    });
  });
}
