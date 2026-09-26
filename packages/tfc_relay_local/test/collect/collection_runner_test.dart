/// The runner: LocalStateMan's value path → the sink, with the one decision
/// the app's collector could never make — whether the value is worth writing
/// down.
///
/// The app's collector historises whatever arrives, because open62541's
/// `DynamicValue` has no quality field to consult (08-RESEARCH §A.2). The
/// gateway's values carry `quality` for real, so for the first time the
/// historian can decline — and a declined sample is a counted sample, never a
/// silent one.
///
/// No database anywhere in this file: the sink is 8b-01's `FakeSink`, and the
/// plant is a `FakeUpstreamLink` behind a real `LocalStateMan`, which is the
/// point — collection subscribes exactly the way a panel does.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_dart/core/boolean_expression.dart'
    show Expression, ExpressionConfig;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_dart/tfc_dart.dart' show RetentionPolicy;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fake_sink.dart';
import '../support/fake_upstream_link.dart';
import '../support/keymap_fixtures.dart';

// --------------------------------------------------------------- the fixture

const String plantAlias = 'ST101';
const String speedKey = 'ST101.CN01.MOT01.speed';
const String structKey = 'ST101.CN03.MOT01';

/// The tick used by every interval case. Short enough that a case sees
/// several ticks inside its `until()` budget, long enough that a loaded
/// runner still fires between two polls.
const Duration tick = Duration(milliseconds: 25);

/// A keymapping entry that asks to be collected.
KeyMappingEntry collectedEntry(
  String key, {
  String? name,
  Duration? interval,
  List<String>? members,
  ExpressionConfig? expression,
  RetentionPolicy? retention,
}) =>
    KeyMappingEntry(
      opcuaNode: opcUaEntry(alias: plantAlias, identifier: key).opcuaNode,
      collect: retention == null
          ? CollectEntry(
              key: key,
              name: name,
              sampleInterval: interval,
              sampleMembers: members,
              sampleExpression: expression,
            )
          : CollectEntry(
              key: key,
              name: name,
              sampleInterval: interval,
              sampleMembers: members,
              sampleExpression: expression,
              retention: retention,
            ),
    );

/// A keymapping entry that is routable but not collected — a gate variable.
KeyMappingEntry plainEntry(String key) => KeyMappingEntry(
    opcuaNode: opcUaEntry(alias: plantAlias, identifier: key).opcuaNode);

/// An expression over [formula], as the keymapping editor stores one.
ExpressionConfig expr(String formula) =>
    ExpressionConfig(value: Expression(formula: formula));

typedef Plant = ({LocalStateMan plant, FakeUpstreamLink link});

/// One `LocalStateMan` over one fake link, connected, torn down by the case.
Plant plantOver(Map<String, KeyMappingEntry> nodes) {
  final link = FakeUpstreamLink(alias: plantAlias);
  final plant = LocalStateMan(
    links: [link],
    router:
        KeyRouter.overLinks([link], mappings: KeyMappings(nodes: nodes)),
    // Long enough that the freshness sweep never degrades a value in the
    // middle of a case — staleness has its own suite.
    staleAfter: const Duration(minutes: 5),
  );
  unawaited(link.connect(deadline: const Duration(seconds: 1)));
  unawaited(plant.start());
  addTearDown(plant.dispose);
  return (plant: plant, link: link);
}

typedef Rig = ({
  LocalStateMan plant,
  FakeUpstreamLink link,
  CollectionPlan plan,
  FakeSink sink,
  CollectionRunner runner,
});

/// The plant plus a runner over it, not yet started.
Rig rig(Map<String, KeyMappingEntry> nodes, {StateManApi? stateMan}) {
  final over = plantOver(nodes);
  final plan =
      CollectionPlan.from(KeyMappings(nodes: nodes), CollectionConfig());
  final sink = FakeSink();
  final runner = CollectionRunner(
    plan: plan,
    stateMan: stateMan ?? over.plant,
    sink: sink,
    health: over.plant.collectHealth,
  );
  addTearDown(runner.stop);
  return (
    plant: over.plant,
    link: over.link,
    plan: plan,
    sink: sink,
    runner: runner,
  );
}

/// A value genuinely arriving from upstream, through the production ingest
/// seam — the same route `readMany` and the link fan-in use.
void feed(LocalStateMan plant, String key, Object? value,
        {Quality quality = Quality.good}) =>
    plant.applyUpstreamBatch(<String, DynamicValue>{
      key: DynamicValue(value: value, quality: quality),
    });

Future<void> pump([int ms = 0]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Waits for [predicate] to hold, or fails naming what never happened.
Future<void> until(
  bool Function() predicate, {
  Duration within = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(within);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the condition did not hold within ${within.inMilliseconds} ms'
          '${reason == null ? '' : ' — $reason'}');
    }
    await pump(2);
  }
}

/// A [TimeseriesSink] whose `ensureTable` parks on a completer — the lever
/// for landing `stop()` in the middle of an in-flight `collectEntry`
/// (WR-04's arm). Everything else delegates to a [FakeSink].
final class _ParkedEnsureSink implements TimeseriesSink {
  final FakeSink inner = FakeSink();
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> ensureTable(String table, RetentionPolicy? retention) async {
    await gate.future;
    await inner.ensureTable(table, retention);
  }

  @override
  Future<void> insert(String table, DateTime time, Object? value) =>
      inner.insert(table, time, value);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();

  @override
  SinkStats get stats => inner.stats;

  @override
  Stream<bool> get connected => inner.connected;
}

/// The runner reached only through `subscribe` — any other member is an
/// architecture violation, not a stub gap. One key throws, to drive the
/// per-entry isolation the plan is about.
final class _SubscribeOnly implements StateManApi {
  _SubscribeOnly(this._inner, {this.throwOn});
  final StateManApi _inner;
  final String? throwOn;

  @override
  Stream<DynamicValue> subscribe(String key) {
    if (key == throwOn) {
      throw StateError('deliberately unstartable in this case: "$key"');
    }
    return _inner.subscribe(key);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'the runner reached ${invocation.memberName} — collection subscribes '
      'through the ordinary value path and uses nothing else on the API');
}

void main() {
  group('the quality gate: only a good-band value becomes a row', () {
    test('a good-band value is inserted, into the validated table name',
        () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 3.5);
      await until(() => r.sink.accepted.length == 1,
          reason: 'a good-band change in change-driven mode is a row');
      expect(r.sink.accepted.single.value, 3.5);
      expect(r.sink.accepted.single.table, 'gw_$speedKey',
          reason: 'the table is CollectionEntry.table — computed once by the '
              'plan, never re-derived here');
      expect(r.runner.skippedSamples, 0);
    });

    test('uncertainLastKnown is not inserted, and the skip is counted',
        () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 42.0, quality: Quality.uncertainLastKnown);
      await until(() => r.runner.skippedSamples == 1);
      expect(r.sink.accepted, isEmpty,
          reason: '"the last known value" is by definition a value the field '
              'is no longer confirming. Inserting it at now() manufactures a '
              'reading that never happened: a flat, plausible trend across '
              'an outage that somebody later reads as "the line was running '
              'steady"');
    });

    test('badCommFault is not inserted, and the skip is counted', () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, null, quality: Quality.badCommFault);
      await until(() => r.runner.skippedSamples == 1);
      expect(r.sink.accepted, isEmpty,
          reason: 'a value stamped by a dead link is not a measurement; an '
              'upstream drop must leave a gap in the history, not a row');
    });

    test('badStale is not inserted, and the skip is counted', () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 42.0, quality: Quality.badStale);
      await until(() => r.runner.skippedSamples == 1);
      expect(r.sink.accepted, isEmpty,
          reason: 'a stale number written every sample interval is exactly '
              'the flat line an operator reads as a running machine');
    });

    test('errorConfig — the fourth band — is not inserted, and counted',
        () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, null, quality: Quality.errorConfig);
      await until(() => r.runner.skippedSamples == 1);
      expect(r.sink.accepted, isEmpty,
          reason: 'all four bands are driven: good inserts, uncertain, bad '
              'and error do not');
    });
  });

  group('the held value tracks the key\'s CURRENT state (CR-01)', () {
    const gateKey = 'ST101.CN06.RUN.flag';

    test('a degraded arrival while the gate is closed invalidates the held '
        'value: the gate opening inserts nothing, and the skip was counted',
        () async {
      final r = rig({
        speedKey:
            collectedEntry(speedKey, expression: expr('$gateKey == true')),
        gateKey: plainEntry(gateKey),
      });
      await r.runner.start();
      await pump();

      // The machine is stopped: the gate reads false.
      feed(r.plant, gateKey, false);
      await pump(10);

      // A good value arrives while the gate is closed — held, not written,
      // not counted (a closed gate is configuration doing its job).
      feed(r.plant, speedKey, 5.0);
      await pump(10);
      expect(r.sink.accepted, isEmpty);
      expect(r.runner.skippedSamples, 0);

      // The key goes dark: link loss stages badCommFault. The skip counts.
      feed(r.plant, speedKey, null, quality: Quality.badCommFault);
      await until(() => r.runner.skippedSamples == 1);

      // The machine restarts and the gate variable repaints good BEFORE the
      // entry's own key does — the outage-restore ordering, no exotic
      // timing needed.
      feed(r.plant, gateKey, true);
      await pump(30);

      expect(r.sink.accepted, isEmpty,
          reason: 'the held value is a reading the plant stopped confirming; '
              'inserting it at now() writes a good-quality row for a tag '
              'that was dark at that instant — a reading that never '
              'happened (CR-01)');
      expect(r.runner.skippedSamples, 1);

      // Recovery: a fresh good value with the gate open is a row again.
      feed(r.plant, speedKey, 6.0);
      await until(() => r.sink.accepted.length == 1);
      expect(r.sink.accepted.single.value, 6.0);
    });

    test('the same outage through the member-extraction path: a degraded '
        'sample none of whose members resolve still invalidates the hold',
        () async {
      final r = rig({
        structKey: collectedEntry(structKey,
            members: const ['motor.speed'],
            expression: expr('$gateKey == true')),
        gateKey: plainEntry(gateKey),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, gateKey, false);
      await pump(10);

      feed(r.plant, structKey, {
        'motor': {'speed': 10},
      });
      await pump(10);
      expect(r.sink.accepted, isEmpty);

      // The outage value is a null struct: no member resolves, so the
      // sample never reaches the band check — the hold must be invalidated
      // on this path too, or the gate opening replays the pre-outage row.
      feed(r.plant, structKey, null, quality: Quality.badCommFault);
      await pump(10);

      feed(r.plant, gateKey, true);
      await pump(30);
      expect(r.sink.accepted, isEmpty,
          reason: 'a degraded arrival whose members do not resolve is still '
              'the plant no longer confirming this key — the held row from '
              'before the outage must not be written at now() (CR-01)');
    });
  });

  group('the replayed snapshot is not a row', () {
    test('subscribe\'s cached first value produces no insert; the next '
        'genuine change does', () async {
      final over = plantOver({speedKey: collectedEntry(speedKey)});
      // The store holds a perfectly good value BEFORE collection starts —
      // the shape a runner restart meets on a warm gateway.
      feed(over.plant, speedKey, 41.0);

      final sink = FakeSink();
      final runner = CollectionRunner(
        plan: CollectionPlan.from(
            KeyMappings(nodes: {speedKey: collectedEntry(speedKey)}),
            CollectionConfig()),
        stateMan: over.plant,
        sink: sink,
        health: over.plant.collectHealth,
      );
      addTearDown(runner.stop);
      await runner.start();
      await pump(20);

      expect(sink.accepted, isEmpty,
          reason: 'the first value a subscription yields is the cache '
              'replaying, not news from the plant — inserting it stamps an '
              'old reading with a fresh now() (T-8b-11)');

      feed(over.plant, speedKey, 42.0);
      await until(() => sink.accepted.length == 1);
      expect(sink.accepted.single.value, 42.0,
          reason: 'the first genuine change after the snapshot is the first '
              'row');
    });
  });

  group('interval mode: the tick is the sample', () {
    test('inserts on the tick, including unchanged values', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 7.0);
      await until(() => r.sink.accepted.length >= 3,
          reason: 'a five-second trend of a steady value is the trend, not '
              'a bug: the value arrived once and the ticks keep sampling it');
      expect(r.sink.accepted.map((row) => row.value).toSet(), {7.0});
      expect(r.runner.skippedSamples, 0);
    });

    test('inserts nothing before the first value has arrived', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump(150);

      expect(r.sink.accepted, isEmpty,
          reason: 'no value has arrived, so there is nothing to sample — '
              'and the subscribe snapshot placeholder is not a value');
      expect(r.runner.skippedSamples, 0,
          reason: 'a row that never existed is not a lost row; counting the '
              'not-yet-known placeholder would inflate the drop counter on '
              'every key whose PLC has simply not published yet');
    });

    test('a held value that stops being good-band stops being written — '
        'a gap, not a flat line — and resumes on recovery', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 5.0);
      await until(() => r.sink.accepted.length >= 2);

      // The outage: the held value degrades. Every tick from here on must
      // decline and count, not write the last number under a fresh time.
      feed(r.plant, speedKey, null, quality: Quality.badCommFault);
      await until(() => r.runner.skippedSamples >= 2,
          reason: 'the declined ticks are counted where an operator can '
              'read them — that counter is the answer to "why is there no '
              'data between 14:02 and 14:20"');
      await pump(30);
      final during = r.sink.accepted.length;
      await pump(120);
      expect(r.sink.accepted.length, during,
          reason: 'rows written through an upstream outage are a flat, '
              'plausible trend that reads as "the line was running steady" '
              '— precisely the lie this project exists to prevent');

      feed(r.plant, speedKey, 6.0);
      await until(() => r.sink.accepted.length > during,
          reason: 'recovery resumes the trend');
      expect(r.sink.accepted.last.value, 6.0);
    });

    test('a wake-up tick after a stall declines the held value instead of '
        'stamping it at now() (09-09, F22e)', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump();

      feed(r.plant, speedKey, 9.0);
      await until(() => r.sink.accepted.length >= 2);
      final skippedBefore = r.runner.skippedSamples;
      final rowsBefore = r.sink.accepted.length;

      // The stall: a synchronous block freezes this isolate's event loop —
      // the sample timer misses whole windows exactly as it does under
      // Isolate.pause or a VM snapshot, and `t.tick` jumps on the wake-up
      // callback. 400 ms over a 25 ms tick is ~15 missed windows, well past
      // the runner's quarter-second decline floor and far past anything a
      // scheduler pause produces.
      final stallEnd = DateTime.now().add(const Duration(milliseconds: 400));
      while (DateTime.now().isBefore(stallEnd)) {
        // Busy-wait on purpose: dart:io sleep() would also work, but a spin
        // keeps this file import-identical and the property is the same —
        // no event loop, no timers, no sweeps.
      }

      // The wake-up tick must DECLINE and COUNT — the held 9.0 predates the
      // stall, and writing it at now() manufactures a reading from inside a
      // window nobody sampled (the one-row flat line F22e catches at the
      // gate level, against a real hypertable).
      await until(() => r.runner.skippedSamples > skippedBefore,
          reason: 'the wake-up tick neither declined nor counted: the '
              'missed windows are a real loss the operator reads off '
              'PIPE.collect.rows_dropped');
      // And the trend resumes on its own: the value is still vouched for
      // (nothing degraded it), so the next ON-SCHEDULE tick writes again.
      await until(() => r.sink.accepted.length > rowsBefore,
          reason: 'one declined wake-up tick must cost exactly the missed '
              'windows, never the trend that follows them');
      expect(r.runner.skippedSamples, skippedBefore + 1,
          reason: 'the stall is one wake-up tick, so it is one counted '
              'decline — Timer.periodic coalesces the missed windows into '
              'a single callback, and counting more would inflate the drop '
              'counter for a single gap');
    });
  });

  group('struct members become one row', () {
    test('an entry with sample_members inserts one value per sample, keyed '
        'by full dotted path', () async {
      final r = rig({
        structKey: collectedEntry(structKey,
            members: const ['motor.speed', 'motor.temp']),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, structKey, {
        'motor': {'speed': 10, 'temp': 30, 'ignored': 99},
      });
      await until(() => r.sink.accepted.length == 1);
      expect(r.sink.accepted.single.value, {
        'motor.speed': 10,
        'motor.temp': 30,
      },
          reason: 'exactly what extractSampleMembers returns: the full path '
              'is the key so two members with one leaf name cannot collide');

      // A member absent from the sample is absent from the row — never
      // null-filled, so the table schema does not learn a column from a
      // sample that did not carry it.
      feed(r.plant, structKey, {
        'motor': {'speed': 11},
      });
      await until(() => r.sink.accepted.length == 2);
      expect(r.sink.accepted.last.value, {'motor.speed': 11});
    });

    test('a sample where no member resolves inserts nothing and is counted',
        () async {
      final r = rig({
        structKey: collectedEntry(structKey,
            members: const ['motor.speed', 'motor.temp']),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, structKey, {'other': 1});
      await until(() => r.runner.skippedSamples == 1);
      expect(r.sink.accepted, isEmpty,
          reason: 'a table of empty rows is worse than a gap: the gap is '
              'visible');
    });
  });

  group('retention', () {
    test('registered once per table at start, before the first insert; an '
        'adjusted entry registers none at all', () async {
      final kept = 'ST101.CN04.MOT01.speed';
      final adjusted = 'ST101.CN05.MOT01.speed';
      final r = rig({
        kept: collectedEntry(kept,
            retention:
                const RetentionPolicy(dropAfter: Duration(days: 10))),
        // Under the one-minute floor: 8b-01 marks it `adjusted` and carries
        // a NULL retention — install no policy, keep everything.
        adjusted: collectedEntry(adjusted,
            retention:
                const RetentionPolicy(dropAfter: Duration(seconds: 30))),
      });
      expect(r.plan.adjusted, hasLength(1),
          reason: 'the fixture is the adjusted case, or this asserts nothing');

      await r.runner.start();

      expect(r.sink.ensuredTables.keys,
          containsAll(<String>['gw_$kept', 'gw_$adjusted']));
      expect(r.sink.ensuredTables['gw_$kept']?.dropAfter,
          const Duration(days: 10));
      expect(r.sink.ensuredTables['gw_$adjusted'], isNull,
          reason: 'an unusable retention becomes NO policy, not an unusable '
              'one — the table keeps everything until the retention is '
              'fixed, which is the safe direction to fail in');
      expect(r.sink.ensureCalls, 2, reason: 'once per table, not per sample');
      expect(r.sink.accepted, isEmpty,
          reason: 'retention was registered before anything was inserted');
    });
  });

  group('one entry\'s failure costs one entry', () {
    test('400 entries, one unstartable: the other 399 collect and the '
        'failure is recorded against its key', () async {
      final keys = <String>[for (var i = 0; i < 400; i++) 'Line$i.Motor1'];
      final nodes = <String, KeyMappingEntry>{
        for (final key in keys) key: collectedEntry(key),
      };
      const badKey = 'Line7.Motor1';

      final over = plantOver(nodes);
      final sink = FakeSink();
      final runner = CollectionRunner(
        plan: CollectionPlan.from(
            KeyMappings(nodes: nodes), CollectionConfig()),
        stateMan: _SubscribeOnly(over.plant, throwOn: badKey),
        sink: sink,
        health: over.plant.collectHealth,
      );
      addTearDown(runner.stop);
      await runner.start();
      await pump();

      expect(runner.entryFailures.keys, [badKey],
          reason: 'the failure is recorded against its key — one unstartable '
              'key must cost exactly that key, never the batch '
              '(collector.dart:159-172 is the incident this repeats-by-not-'
              'repeating: an uncaught async error killed acquisition for the '
              'whole server)');
      expect(runner.entryFailures[badKey], contains('unstartable'));
      expect(runner.liveSubscriptions, 399);

      feed(over.plant, 'Line0.Motor1', 1.0);
      feed(over.plant, 'Line399.Motor1', 2.0);
      await until(() => sink.accepted.length == 2,
          reason: 'the neighbours of the failed entry collect normally');
    });
  });

  group('collection is a subscriber, and the refcount says so', () {
    test('a panel leaving a collected key does not release the upstream '
        'subscription underneath it', () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      // The runner's own subscription is up. Everything below is asserted
      // as a DELTA across the panel's visit — never a balance
      // (state_man.dart:848-861: the link counts creates and no deletes,
      // so only this side's bookkeeping can answer "did we release").
      final openBefore = r.plant.openUpstreamSubscriptions;
      final createdBefore = r.link.upstreamSubscriptionsCreated;
      expect(openBefore, 1,
          reason: 'collection holds the key open with nobody watching — '
              'historisation is the process\'s own job');

      final panel = r.plant.subscribe(speedKey).listen((_) {});
      await pump();
      expect(r.link.upstreamSubscriptionsCreated - createdBefore, 0,
          reason: 'the panel shares the runner\'s upstream subscription — '
              'thirty panels on one collected key still cost the PLC one '
              'monitored item');

      await panel.cancel();
      await pump();
      expect(r.plant.openUpstreamSubscriptions - openBefore, 0,
          reason: 'the last PANEL leaving is not the last SUBSCRIBER '
              'leaving: collection keeps the refcount off zero, which is a '
              'deliberate change to 08-05\'s steady state (T-8b-13, '
              'accepted and asserted)');
      expect(r.link.upstreamSubscriptionsCreated - createdBefore, 0);
    });
  });

  group('the six health keys', () {
    const sixKeys = <String>[
      PipeKeys.collectEnabled,
      PipeKeys.collectConnected,
      PipeKeys.collectRowsWritten,
      PipeKeys.collectRowsDropped,
      PipeKeys.collectQueuedRows,
      PipeKeys.collectLastError,
    ];

    test('with collection off, all six read null under errorConfig — never '
        'false, never zero', () async {
      final over = plantOver({speedKey: collectedEntry(speedKey)});
      // No runner anywhere in this case: this gateway does not collect.
      for (final key in sixKeys) {
        final value = over.plant.read(key);
        expect(value, isNotNull,
            reason: '$key must be seeded — a health indicator that reads '
                'unknown until the first fault tells an operator nothing at '
                'the moment they most need telling');
        expect(value!.value, isNull,
            reason: '$key with no reading is null, never a plausible zero '
                'or false: connected=false on a gateway that was never '
                'asked to collect sends an engineer to a database that is '
                'fine');
        expect(value.quality, Quality.errorConfig,
            reason: '$key: not configured is a configuration statement — '
                'waiting does not fix it');
      }
    });

    test('with collection on: enabled is true, connected follows the sink, '
        'and the counters move as rows are written and skipped', () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      await r.runner.start();
      await pump();

      await until(() => r.plant.read(PipeKeys.collectEnabled)?.value == true);
      expect(r.plant.read(PipeKeys.collectEnabled)!.quality.isGood, isTrue);

      // The sink has said nothing yet, so `connected` is still the honest
      // absence of a reading — not false.
      expect(r.plant.read(PipeKeys.collectConnected)!.value, isNull);

      r.sink.goDown();
      await until(
          () => r.plant.read(PipeKeys.collectConnected)?.value == false,
          reason: 'connected follows the sink\'s own stream');
      r.sink.comeUp();
      await until(
          () => r.plant.read(PipeKeys.collectConnected)?.value == true);

      feed(r.plant, speedKey, 1.5);
      await until(
          () => r.plant.read(PipeKeys.collectRowsWritten)?.value == 1,
          reason: 'a written row moves the written counter');

      feed(r.plant, speedKey, 2.5, quality: Quality.badStale);
      await until(
          () => r.plant.read(PipeKeys.collectRowsDropped)?.value == 1,
          reason: 'a quality-gate skip increments PIPE.collect.rows_dropped '
              '— dropped, skipped or refused, one counter (the roster is '
              'six keys, pinned by the protocol suite)');

      r.sink.goDown();
      feed(r.plant, speedKey, 3.5);
      await until(
          () => r.plant.read(PipeKeys.collectQueuedRows)?.value == 1,
          reason: 'a row buffered while the database is down is queued, '
              'the early warning for the drop counter');
    });

    test('last_error carries the sink\'s already-redacted string', () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      r.sink.failingTables.add('gw_$speedKey');
      await r.runner.start();
      await pump();

      expect(r.plant.read(PipeKeys.collectLastError)!.value, isNull,
          reason: 'no error yet is a null under good quality once asked — '
              'the gateway looked, and the answer is "nothing"');

      feed(r.plant, speedKey, 9.0);
      await until(() =>
          (r.plant.read(PipeKeys.collectLastError)?.value as String?)
              ?.contains('set to fail') ??
          false);
      final published =
          r.plant.read(PipeKeys.collectLastError)!.value as String;
      expect(published, r.sink.stats.lastError,
          reason: 'the sink\'s string is served verbatim: it is redacted at '
              'the sink (T-8b-14) and this code must not widen it');
    });

    test('the six keys are subscribable through the ordinary value path',
        () async {
      final r = rig({speedKey: collectedEntry(speedKey)});
      final seen = <Object?>[];
      final sub = r.plant
          .subscribe(PipeKeys.collectEnabled)
          .listen((value) => seen.add(value.value));
      addTearDown(sub.cancel);
      await pump();

      expect(seen, [null],
          reason: 'the seeded not-configured reading replays to a new '
              'subscriber, like any other key');
      await r.runner.start();
      await until(() => seen.contains(true),
          reason: 'the same subscription sees collection come up — no '
              'health method, no second API');
    });
  });

  group('shutdown', () {
    test('stop() cancels every subscription and timer, flushes the sink, '
        'and releases the upstream', () async {
      final r = rig({
        speedKey: collectedEntry(speedKey, interval: tick),
        structKey: collectedEntry(structKey),
      });
      await r.runner.start();
      await pump();
      feed(r.plant, speedKey, 1.0);
      await until(() => r.sink.accepted.isNotEmpty);

      await r.runner.stop();

      expect(r.runner.liveSampleTimers, 0,
          reason: 'no pending timer may outlive the runner');
      expect(r.runner.liveSubscriptions, 0);
      expect(r.sink.flushCalls, greaterThanOrEqualTo(1),
          reason: 'what was buffered goes toward the database before the '
              'process lets go of it');
      expect(r.plant.openUpstreamSubscriptions, 0,
          reason: 'the runner detaches like any other subscriber, and at '
              'refcount zero the upstream is released');

      final after = r.sink.accepted.length;
      feed(r.plant, speedKey, 2.0);
      await pump(100);
      expect(r.sink.accepted.length, after,
          reason: 'a stopped runner writes nothing');
    });

    test('a re-collect cancels the previous sample timer rather than '
        'orphaning it', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump();
      feed(r.plant, speedKey, 9.0);
      await until(() => r.sink.accepted.length >= 2);

      // A mapping edit re-collects the entry. The first timer must be
      // cancelled by the replacement (collector.dart:297's guard: without
      // it the orphan keeps inserting alongside its replacement).
      await r.runner.collectEntry(
          r.plan.entries.singleWhere((entry) => entry.key == speedKey));
      await pump();
      final atRecollect = r.sink.accepted.length;
      await until(() => r.sink.accepted.length > atRecollect,
          reason: 'the replacement keeps collecting');

      await r.runner.stop();
      await pump(40);
      final atStop = r.sink.accepted.length;
      await pump(120);
      expect(r.sink.accepted.length, atStop,
          reason: 'stop() cancels the timers it knows about; an orphaned '
              'first timer would be one it does not know about, and these '
              'inserts after stop are its doubled rows');
      expect(r.runner.liveSampleTimers, 0);
    });

    test('stop() racing an in-flight collectEntry resurrects nothing: no '
        'timer, no subscription, no upstream refcount (WR-04)', () async {
      final nodes = {speedKey: collectedEntry(speedKey, interval: tick)};
      final over = plantOver(nodes);
      final sink = _ParkedEnsureSink();
      final plan =
          CollectionPlan.from(KeyMappings(nodes: nodes), CollectionConfig());
      final runner = CollectionRunner(
        plan: plan,
        stateMan: over.plant,
        sink: sink,
        health: over.plant.collectHealth,
      );
      addTearDown(runner.stop);

      // collectEntry parks on the sink's ensureTable; stop() lands while it
      // is suspended, tears everything down — and then the suspended call
      // resumes into a runner that reports itself stopped.
      final inFlight = runner.collectEntry(plan.entries.single);
      await pump();
      await runner.stop();
      sink.gate.complete();
      await inFlight;
      await pump();

      expect(runner.liveSampleTimers, 0,
          reason: 'a timer created after stop() is one stop() can never '
              'cancel — its inserts go to a sink the composition root is '
              'about to close, and vanish uncounted (WR-04)');
      expect(runner.liveSubscriptions, 0);
      expect(over.plant.openUpstreamSubscriptions, 0,
          reason: 'the resumed call must not re-attach the fan-in refcount '
              'after teardown released it');
    });

    test('a re-collect that switches interval → change mode cancels the old '
        'timer: zero ticks from it afterwards (CR-02)', () async {
      final r = rig({speedKey: collectedEntry(speedKey, interval: tick)});
      await r.runner.start();
      await pump();
      feed(r.plant, speedKey, 9.0);
      await until(() => r.sink.accepted.length >= 2,
          reason: 'the interval entry is collecting before the edit');

      // A mapping edit removes sample_interval: the same key re-collects in
      // change mode. The old timer's closure holds the OLD call's frozen
      // `latest`; if it survives, it writes that frozen band-0 value at a
      // fresh now() every tick until stop() — the flat-line fabrication the
      // class doc says the guard prevents.
      await r.runner.collectEntry(CollectionEntry(
        key: speedKey,
        table: 'gw_$speedKey',
      ));
      await pump();
      expect(r.runner.liveSampleTimers, 0,
          reason: 'the replacement is change mode: no timer may remain, '
              'and liveSampleTimers must reflect the truth');

      final atSwitch = r.sink.accepted.length;
      await pump(150);
      expect(r.sink.accepted.length, atSwitch,
          reason: 'ZERO ticks from the old timer after the switch — every '
              'row here is the orphaned first timer inserting a frozen '
              'value alongside its replacement (CR-02)');

      // The replacement still collects, on change.
      feed(r.plant, speedKey, 10.0);
      await until(() => r.sink.accepted.length == atSwitch + 1);
      expect(r.sink.accepted.last.value, 10.0);
    });
  });
}
