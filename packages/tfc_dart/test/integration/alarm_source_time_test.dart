/// ALRM-03 criterion 3, **end to end**: an alarm carries the instant the PLANT
/// says the reading was produced, not the instant this machine happened to
/// receive it.
///
/// `alarm.dart:595` used to stamp every activation with `DateTime.now()`. On a
/// healthy link those two instants differ by a publishing interval and nobody
/// notices. On a link that stalled for four minutes, on a backend that was
/// restarted, or on a plant whose controller clock has drifted, they differ by
/// the whole of the thing a downtime report is built from — and the operator has
/// no way to tell which number they are looking at.
///
/// ## Why this file needs a data-source node, and why that is not a detail
///
/// Every rule here binds a **data-source** key ([OpcUaServerFixture.writeKeys]),
/// never a plain variable key. The fixture's own doc records the measurement
/// (12-02) that settled it: a plain variable node *"cannot carry a chosen source
/// instant"* — `Server.write` writes the Variant only and open62541 stamps the
/// source instant when the node is read, so a plain node's offset between source
/// and arrival is the publishing interval, i.e. the transport. That is exactly
/// the offset an arrival-stamping implementation would also produce, so an arm
/// built on a plain node **could not fail**. A data-source node's read callback
/// serves an explicit [OpcUaServerFixture.setSourceTimestamp], which is how a
/// sample is made provably older than its own arrival by a chosen margin.
///
/// ## The three clocks, and why none of them can be accidentally equal
///
///  * **[kPlantInstant]** — what the server says. `2024-03-01T12:00:00.250Z`.
///  * **[kBackendNow]** — what the injected clock says, ten minutes later. This
///    is what a receipt-stamping implementation would produce.
///  * **the wall clock** — a real instant, years away from both, because these
///    are fixed dates. This is what an `arrivedAt`-stamping implementation would
///    produce.
///
/// Three distinct answers, so a passing arm has excluded two named wrong ones
/// rather than merely agreed with itself. Nothing here is anchored on
/// `DateTime.now()`.
///
/// Dynamic ports only — every port comes from the kernel, via the fixture or
/// [freePort].
@TestOn('vm')
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:postgres/postgres.dart' show Endpoint;
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
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

import '../support/free_port.dart';
import '../support/opcua_server_fixture.dart';

/// A [Database] that answers everything and connects to nothing.
///
/// See `alarm_session_count_test.dart` for why it is copied rather than shared:
/// it has to be reachable from an isolate entry point in *this* library.
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
@pragma('vm:entry-point')
Future<void> sourceTimeWorkerEntry(DataAcquisitionIsolateConfig config) =>
    runAcquisitionIsolate(config, database: NoopDatabase());

/// What the plant says. Whole milliseconds, so the round trip through OPC UA's
/// 100 ns FILETIME ticks is exact and the arm can assert to the millisecond.
final DateTime kPlantInstant = DateTime.utc(2024, 3, 1, 12, 0, 0, 250);

/// What the backend's injected clock says: ten minutes after the plant.
///
/// A receipt-stamping implementation lands here, and the arms name it when they
/// fail.
final DateTime kBackendNow = kPlantInstant.add(const Duration(minutes: 10));

/// The older of arm 2's two source instants: ten minutes before [kPlantInstant].
///
/// `min` over the bound set lands here, which is D-1's rejected rule and
/// sabotage (d).
final DateTime kOlderPlantInstant =
    kPlantInstant.subtract(const Duration(minutes: 10));

/// A PLC whose clock is five minutes fast (D-2, arm 5).
final DateTime kFutureInstant = kBackendNow.add(const Duration(minutes: 5));

const String kAlias = 'ST101';
const String keyA = 'st101.tank.level';
const String keyB = 'st101.pump.pressure';

void main() {
  // ------------------------------------------------------------------ arm 1
  test(
      'the plant\'s instant reaches the alarm: a sample stamped ten minutes '
      'before the backend\'s clock activates an alarm at the plant\'s instant, '
      'labelled plant', () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA],
      sourceStamps: <String, DateTime>{keyA: kPlantInstant},
      formula: '$keyA > 10',
    );
    await rig.awaitFirstReadings();

    rig.cross(keyA);
    final entry = await rig.awaitActivation();

    expect(entry.tsSource, AlarmTsSource.plant.wireName,
        reason: 'the server supplied a source timestamp for every bound value, '
            'so the provenance is the plant\'s. ${rig.evidence()}');
    expect(entry.activeAtMs, kPlantInstant.millisecondsSinceEpoch,
        reason: 'the activation must carry the instant the SERVER stamped '
            '(${kPlantInstant.toIso8601String()}). It carries '
            '${DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs, isUtc: true).toIso8601String()}. '
            '${rig.diagnoseStamp(entry.activeAtMs)} ${rig.evidence()}');

    // The two named wrong answers, excluded by name rather than by implication.
    expect(entry.activeAtMs, isNot(kBackendNow.millisecondsSinceEpoch),
        reason: 'the alarm was stamped with the BACKEND\'S clock. A stamp '
            'within a second of the receipt instant is precisely the failure '
            'this arm exists to catch. ${rig.evidence()}');
    expect(
        DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs, isUtc: true).year,
        kPlantInstant.year,
        reason: 'the alarm was stamped with the WALL clock — the arrival '
            'instant `translateOpcUaSample` substitutes when a server sends no '
            'source timestamp. This server sent one. ${rig.evidence()}');

    // And the margin is the one that was chosen, not one a transport could
    // explain. Ten minutes is not a publishing interval.
    expect(kBackendNow.difference(kPlantInstant), const Duration(minutes: 10));
  });

  // ------------------------------------------------------------------ arm 2
  test(
      'max(sourceTime) across two variables, end to end: two inputs ten '
      'minutes apart crossing together stamp the alarm with the NEWER',
      () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA, keyB],
      sourceStamps: <String, DateTime>{
        // Deliberately the older one first in the formula, so a rule that
        // simply took the first bound variable's instant would also land on
        // the wrong answer.
        keyA: kOlderPlantInstant,
        keyB: kPlantInstant,
      },
      formula: '$keyA > 10 AND $keyB > 10',
    );
    await rig.awaitFirstReadings();

    // The precondition that makes this a measurement rather than a
    // coincidence: the two instants really did arrive, really are different,
    // and really came through the worker -> pipe path.
    expect(rig.freshness.read(keyA)!.sourceTime?.toUtc(), kOlderPlantInstant,
        reason: 'the older input\'s source instant did not survive the pipe, '
            'so a max over the two would be a max over one. ${rig.evidence()}');
    expect(rig.freshness.read(keyB)!.sourceTime?.toUtc(), kPlantInstant,
        reason: rig.evidence());

    rig.cross(keyA);
    rig.cross(keyB);
    final entry = await rig.awaitActivation();

    expect(entry.activeAtMs, kPlantInstant.millisecondsSinceEpoch,
        reason: 'D-1: a conjunction becomes true when the LAST of its '
            'conditions does, so the stamp is the newest contributing source '
            'instant. ${rig.diagnoseStamp(entry.activeAtMs)} '
            '${rig.evidence()}');
    expect(entry.activeAtMs, isNot(kOlderPlantInstant.millisecondsSinceEpoch),
        reason: 'the alarm took the OLDEST bound instant. `min` is actively '
            'wrong: the bound set includes setpoints and constants that have '
            'not moved since the last PLC restart, and stamping this minute\'s '
            'alarm with that instant is a stop report nobody can audit. '
            '${rig.evidence()}');
    expect(entry.tsSource, AlarmTsSource.plant.wireName,
        reason: rig.evidence());
  });

  // ------------------------------------------------------------------ arm 3
  test(
      'ALARM.active carries the same instant: the published payload\'s '
      'activeAtMs is the plant\'s instant in epoch milliseconds UTC', () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA],
      sourceStamps: <String, DateTime>{keyA: kPlantInstant},
      formula: '$keyA > 10',
    );
    await rig.awaitFirstReadings();
    rig.cross(keyA);
    final entry = await rig.awaitActivation();

    // Read off the pipe's own ValueStore, which is where
    // `PipeStoreAlarmPublisher` puts it and where a relay client would read it
    // from — not off the engine's in-memory set a second time.
    final published = rig.pipe.read(relay.AlarmKeys.active);
    expect(published.quality, relay.Quality.good, reason: rig.evidence());

    final decoded =
        relay.AlarmActiveEntry.decodeList(published.toJson(slim: true));
    expect(decoded.entries, hasLength(1), reason: rig.evidence());
    expect(decoded.truncated, isFalse);

    final wire = decoded.entries.single;
    expect(wire.activeAtMs, kPlantInstant.millisecondsSinceEpoch,
        reason: 'criterion 5\'s "the same timestamps" begins here: what the '
            'engine holds and what every panel is told must be one number. '
            '${rig.diagnoseStamp(wire.activeAtMs)} ${rig.evidence()}');
    expect(wire.activeAtMs, entry.activeAtMs, reason: rig.evidence());
    expect(wire.tsSource, AlarmTsSource.plant.wireName);
    expect(wire.uid, 'level-high');
    expect(wire.ruleIndex, 0);

    // Epoch milliseconds UTC, spelled out: a payload carrying a local-time
    // millisecond count would agree with itself and disagree with every reader.
    expect(
        DateTime.fromMillisecondsSinceEpoch(wire.activeAtMs, isUtc: true)
            .toIso8601String(),
        kPlantInstant.toIso8601String());
  });

  // ------------------------------------------------------------------ arm 4
  //
  // SKIPPED, and the reason is a FINDING rather than a limitation of the test.
  // It was written, run and measured before it was skipped; see the gap arm
  // immediately below, which pins what was measured so the gap cannot widen
  // unobserved. Flagged for phase verification.
  //
  // Two independent things stand between this arm and a green run, and only
  // the second is fixable in this repository:
  //
  //  1. **The fixture cannot serve a null source timestamp.**
  //     `test/support/opcua_server_fixture.dart:318` — *"Passing `null` clears
  //     it, and open62541 goes back to stamping the read."* Measured on
  //     2026-09-06: with no chosen stamp, `sourceTime` on the wire was
  //     `2026-09-06T22:18:37.409Z`, a real instant the SERVER minted. The
  //     `sourceTimestamp == null` branch is therefore never reached from an
  //     OPC UA server at all.
  //  2. **The provenance would not survive the pipe if it were.**
  //     `lib/core/opcua_value_translation.dart:161-163` substitutes
  //     `arrivedAt` for a missing stamp **at the worker** and calls
  //     `onSourceTimeFallback`; the only record of the substitution is
  //     `PipeWorkerEndpoint._sourceTimeFallbacks`
  //     (`lib/core/pipe_worker_endpoint.dart:298,437`), an `int` counter local
  //     to the worker isolate that never crosses the port. What reaches
  //     `resolveAlarmStamp` on main is a non-null instant, so it is labelled
  //     `plant` — correctly, given what it was told, and wrongly, given what
  //     happened.
  //
  // D-2's `backend_receipt` label is therefore reachable today only from the
  // engine's own `_receiptStamp()` (the config-change close) and from a rule
  // that binds no variables — never from a server that omits a stamp. The unit
  // half of this property is covered against a fake value source in
  // `test/core/relay/alarm_rule_watcher_test.dart`; what is missing is the
  // end-to-end half, and it is missing because the provenance has nowhere to
  // ride.
  test(
      'a server that sends no source timestamp is labelled, not silent: the '
      'activation is stamped by the injected clock and labelled '
      'backend_receipt', () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA],
      // `null` hands the stamp back to the server (see the fixture's doc for
      // [setSourceTimestamp]).
      sourceStamps: const <String, DateTime>{},
      formula: '$keyA > 10',
    );
    await rig.awaitFirstReadings();
    rig.cross(keyA);
    final entry = await rig.awaitActivation();

    expect(entry.tsSource, AlarmTsSource.backendReceipt.wireName,
        reason: 'no source timestamp was chosen, so the stamp is this '
            'backend\'s receipt instant and must SAY SO. ${rig.evidence()}');
    expect(entry.activeAtMs, kBackendNow.millisecondsSinceEpoch,
        reason: rig.evidence());
  },
      skip: 'RECORDED GAP, measured 2026-09-06, not a test limitation. '
          '(1) opcua_server_fixture.dart:318 — "Passing null clears it, and '
          'open62541 goes back to stamping the read" — so no OPC UA server can '
          'produce the null this arm needs; measured sourceTime on the wire '
          'was 2026-09-06T22:18:37.409Z and tsSource was "plant". '
          '(2) Even then it would not survive: '
          'opcua_value_translation.dart:161-163 substitutes arrivedAt at the '
          'WORKER and records the substitution only in '
          'pipe_worker_endpoint.dart:298,437, an isolate-local counter that '
          'never crosses the port. Un-skip when a fallback flag rides the '
          'wire. Flagged for phase verification.');

  // ------------------------------------------------------- arm 4's gap, pinned
  //
  // **This arm passing is the DEFECT, not the property.** It exists so the gap
  // arm 4 records is a measured, executable fact rather than a paragraph, and
  // so that a change to either half above turns something red instead of
  // quietly making the skip stale. When arm 4 can run, this arm should be
  // deleted in the same commit.
  test(
      'RECORDED GAP (arm 4\'s blocker), measured: an unstamped server sample '
      'arrives labelled "plant" carrying an instant nobody in the plant chose',
      () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA],
      sourceStamps: const <String, DateTime>{},
      formula: '$keyA > 10',
    );
    await rig.awaitFirstReadings();
    rig.cross(keyA);
    final entry = await rig.awaitActivation();

    final onTheWire = rig.freshness.read(keyA)!.sourceTime;
    print('arm 4 gap measured: sourceTime on the wire = '
        '${onTheWire?.toIso8601String()}, tsSource = ${entry.tsSource}, '
        'activeAtMs = '
        '${DateTime.fromMillisecondsSinceEpoch(entry.activeAtMs, isUtc: true).toIso8601String()}');

    // Half 1: the fixture cannot produce the null. open62541 stamps the read.
    expect(onTheWire, isNotNull,
        reason: 'THE GAP HAS CLOSED, or at least changed: the fixture served a '
            'null sourceTime after all. Re-run arm 4 un-skipped and delete '
            'this arm. ${rig.evidence()}');
    expect(onTheWire!.toUtc().year, greaterThan(2025),
        reason: 'the served instant is not a wall-clock one, so something '
            'other than open62541\'s read stamp produced it. ${rig.evidence()}');

    // Half 2: and so the engine calls it the plant's word.
    expect(entry.tsSource, AlarmTsSource.plant.wireName,
        reason: 'THE GAP HAS CLOSED: the provenance of a server-minted stamp '
            'now reaches the engine. Un-skip arm 4 and delete this one. '
            '${rig.evidence()}');
    expect(entry.activeAtMs, onTheWire.toUtc().millisecondsSinceEpoch,
        reason: 'the activation carries the server\'s read stamp verbatim. '
            '${rig.evidence()}');
    expect(entry.activeAtMs, isNot(kBackendNow.millisecondsSinceEpoch),
        reason: 'the injected clock never entered it, which is why the '
            'backend_receipt label is unreachable from this path at all. '
            '${rig.evidence()}');
  });

  // ------------------------------------------------------------------ arm 5
  test(
      'a skewed clock is written, not clamped: a source instant five minutes '
      'in the future is carried unchanged and warned about', () async {
    final rig = await _Rig.standUp(
      keys: const <String>[keyA],
      sourceStamps: <String, DateTime>{keyA: kFutureInstant},
      formula: '$keyA > 10',
      // The default (60 s). Named here so the arm's margin — five minutes — is
      // visibly outside it rather than accidentally so.
      skewWarnAfter: kAlarmSkewWarnAfter,
    );
    await rig.awaitFirstReadings();
    rig.cross(keyA);
    final entry = await rig.awaitActivation();

    expect(entry.activeAtMs, kFutureInstant.millisecondsSinceEpoch,
        reason: 'D-2: a source instant in the future is written UNCHANGED. '
            'Clamping it to the receipt instant would hide a real PLC clock '
            'fault, which is exactly the class of thing this milestone exists '
            'to make visible. ${rig.diagnoseStamp(entry.activeAtMs)} '
            '${rig.evidence()}');
    expect(entry.activeAtMs,
        greaterThan(kBackendNow.millisecondsSinceEpoch),
        reason: 'the future instant was clamped back to (or behind) the '
            'backend\'s clock. ${rig.evidence()}');
    expect(entry.tsSource, AlarmTsSource.plant.wireName,
        reason: 'a skewed plant instant is still the plant\'s word, and '
            'relabelling it backend_receipt would launder the fault. '
            '${rig.evidence()}');

    // Unclamped is only half of honest. The other half is that somebody is
    // told.
    expect(
        rig.logs.where((l) => l.contains('from this backend\'s clock')),
        isNotEmpty,
        reason: 'the five-minute skew was carried silently. An unclamped wrong '
            'number nobody was warned about is worse than a clamped one, '
            'because it looks deliberate. Logs: ${rig.logs}');
    expect(rig.logs.where((l) => l.contains('clamping would hide')), isNotEmpty,
        reason: 'Logs: ${rig.logs}');
  });
}

// --------------------------------------------------------------- the fixtures

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

/// One server serving data-source nodes, one real worker, one pipe, one value
/// source, one freshness sweep, one alarm engine.
final class _Rig {
  _Rig._({
    required this.fixture,
    required this.pipe,
    required this.freshness,
    required this.engine,
    required this.keys,
    required this.logs,
  });

  final OpcUaServerFixture fixture;
  final PipeMainEndpoint pipe;
  final BackendFreshnessSweep freshness;
  final AlarmEngine engine;
  final List<String> keys;

  /// Everything the engine and its watchers logged, so arm 5 can assert that
  /// the skew was reported rather than merely tolerated.
  final List<String> logs;

  /// Puts [key] above every threshold in this file's formulas.
  ///
  /// The served `sourceTimestamp` is untouched: only the VALUE moves, which is
  /// what makes the offset between source and arrival a chosen number rather
  /// than a transport artefact.
  void cross(String key) => fixture.setValue(key, 100);

  String evidence() => 'keys=$keys, '
      'readings=${[
        for (final k in keys)
          '$k=${freshness.read(k)?.value}@'
              '${freshness.read(k)?.sourceTime?.toIso8601String()}'
      ]}, '
      'evaluations=${engine.evaluations}, active=${engine.active.length}, '
      'suspended=${engine.suspendedRuleCount}, refusals=${engine.refusals}';

  /// Names which of the three clocks an unexpected stamp came from.
  ///
  /// A failure that says "expected X got Y" leaves the reader to work out
  /// whether Y is the machine's wristwatch or the wire's arrival instant. This
  /// says so.
  String diagnoseStamp(int actualMs) {
    final actual = DateTime.fromMillisecondsSinceEpoch(actualMs, isUtc: true);
    if (actual == kBackendNow) {
      return 'That is THE INJECTED CLOCK — the alarm was stamped with the '
          'backend\'s receipt instant instead of the plant\'s.';
    }
    if (actual == kOlderPlantInstant) {
      return 'That is the OLDEST bound source instant — D-1\'s rejected `min`.';
    }
    if (actual.year > 2100 || actual.isAfter(DateTime.utc(2025))) {
      return 'That is a WALL-CLOCK instant — the arrival time '
          '`translateOpcUaSample` substitutes for a missing stamp, which this '
          'server did not omit.';
    }
    return 'It matches none of the three clocks this file knows about.';
  }

  Future<void> awaitFirstReadings() => _waitUntil(
        () => keys.every((k) => freshness.read(k) != null),
        const Duration(seconds: 60),
        reason: 'an alarm input never carried a first reading: ${evidence()}',
      );

  /// Waits for exactly one activation and hands back its wire entry.
  Future<relay.AlarmActiveEntry> awaitActivation() async {
    await _waitUntil(() => engine.active.isNotEmpty,
        const Duration(seconds: 60),
        reason: 'the rule never went true, so there is no stamp to judge: '
            '${evidence()}');
    expect(engine.active, hasLength(1), reason: evidence());
    return engine.active.single;
  }

  static Future<_Rig> standUp({
    required List<String> keys,
    required Map<String, DateTime> sourceStamps,
    required String formula,
    Duration skewWarnAfter = const Duration(days: 365000),
  }) async {
    final logs = <String>[];
    final logger = Logger(
      filter: ProductionFilter(),
      level: Level.warning,
      printer: SimplePrinter(colors: false),
      output: _RecordingOutput(logs),
    );

    // **writeKeys, not valueKeys, and this is the whole arm.** A data-source
    // node's read callback serves an explicit sourceTimestamp; a plain variable
    // node cannot carry a chosen source instant at all (fixture doc, measured
    // 12-02), so an arm built on one would compare arrival against arrival and
    // could never fail.
    final fixture = await OpcUaServerFixture.start(writeKeys: keys);
    addTearDown(fixture.dispose);
    for (final entry in sourceStamps.entries) {
      fixture.setSourceTimestamp(entry.key, entry.value);
    }

    final keyMappings = KeyMappings(nodes: <String, KeyMappingEntry>{
      for (final key in keys)
        key: KeyMappingEntry(
          opcuaNode:
              OpcUANodeConfig(namespace: fixtureNamespace, identifier: key)
                ..serverAlias = kAlias,
        ),
    });

    final server = OpcUAConfig()
      ..endpoint = fixture.endpoint
      ..serverAlias = kAlias;

    final worker = await spawnWorkerForTest(
      DataAcquisitionIsolateConfig(
        serverJson: server.toJson(),
        dbConfigJson: DatabaseConfig(
          postgres: Endpoint(
              host: '127.0.0.1', port: await freePort(), database: 'nowhere'),
        ).toJson(),
        keyMappingsJson: keyMappings.toJson(),
      ),
      kAlias,
      entryPoint: sourceTimeWorkerEntry,
    );
    addTearDown(worker.kill);
    await worker.ready.timeout(const Duration(seconds: 60),
        onTimeout: () => fail('the worker never handed back its control port'));

    final pipe = PipeMainEndpoint();
    addTearDown(pipe.dispose);
    pipe.addWorker(AcquisitionWorkerLink(worker), keyMappings.keys);

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

    final preferences = InMemoryPreferences();
    await preferences.setString(
      kAlarmManConfigKey,
      jsonEncode(AlarmManConfig(alarms: <AlarmConfig>[
        AlarmConfig(
          uid: 'level-high',
          title: 'Level high',
          description: 'The measured level crossed its limit',
          rules: <AlarmRule>[
            AlarmRule(
              level: AlarmLevel.error,
              expression: ExpressionConfig(value: Expression(formula: formula)),
              acknowledgeRequired: false,
            ),
          ],
        ),
      ]).toJson()),
    );

    final engine = AlarmEngine(
      values: freshness,
      preferences: preferences,
      publisher: PipeStoreAlarmPublisher(pipe),
      // The backend's own instant, ten minutes AFTER the plant's. Injected, so
      // "the plant's time" and "the machine's time" can never accidentally be
      // equal — which is the only condition under which these arms can fail.
      clock: () => kBackendNow,
      skewWarnAfter: skewWarnAfter,
      logger: logger,
    );
    addTearDown(engine.dispose);
    await engine.start();

    return _Rig._(
      fixture: fixture,
      pipe: pipe,
      freshness: freshness,
      engine: engine,
      keys: keys,
      logs: logs,
    );
  }
}

final class _RecordingOutput extends LogOutput {
  _RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}
