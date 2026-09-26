/// `AlarmEngine`: the one alarm evaluator, on backend main.
///
/// Every arm runs against the shared fake `BackendValueSource`
/// (`fake_backend_value_source.dart`), a fake publisher and an in-memory
/// `Preferences`. No pipe, no database, no plant, no wall clock.
///
/// **The four properties these arms exist to pin**, in the order they cost
/// most if they regress:
///
///  1. **The engine is not gated on a consumer.** `alarm.dart:305` hangs the
///     whole of `AlarmMan` off `_activeAlarmsController.onListen`, so on a
///     headless backend with no panel attached, no rule is evaluated, no row
///     is written, and nothing anywhere says alarms are off. Arms 1, 2 and 14
///     are what make that unrepresentable here; `bin/main.dart:94`'s
///     subscribe-to-your-own-stream workaround is what those arms replace.
///  2. **The subscriptions are the engine's, for the life of the process.**
///     Holding one is what makes the pipe issue `PipeSubscribe` upstream
///     (D-7), so the 0→1 refcount transition must never reverse because the
///     last panel closed.
///  3. **`ALARM.active` is a self-sufficient snapshot**, one entry per active
///     alarm-*rule*, with the instant as epoch-millisecond DATA (P-7 — the
///     panel's `toUaValue` conversion drops metadata, and a per-entry stamp
///     inside a list has nowhere else to live).
///  4. **Operator input is refused by name and never kills the backend.** A
///     mangled `alarm_man_config` was measured doing exactly that at
///     13-RIG-PROBE FIND-4 (T-14-15); one unparseable formula must not
///     suppress every other alarm (T-14-16).
library;

import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/alarm_stamp.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/relay/backend_alarms.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

import 'fake_backend_value_source.dart';

void main() {
  group('AlarmEngine', () {
    // --------------------------------------------------------------- arm 1
    test('evaluates and maintains the active set with NOBODY listening to '
        'activeAlarms()', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      // Not one call to activeAlarms() has been made.
      expect(h.engine.active, hasLength(1));
      expect(h.engine.active.single.uid, 'seal');
      expect(h.engine.evaluations, 1);

      final evaluationsBefore = h.engine.evaluations;
      final subscribesBefore = Map.of(h.values.subscribeCalls);

      // A panel arrives late and is handed the CURRENT set, not an empty one
      // it has to wait for the next transition to fill.
      final seen = <Set<relay.AlarmActiveEntry>>[];
      final sub = h.engine.activeAlarms().listen(seen.add);
      await settle();

      expect(seen, hasLength(1));
      expect(seen.single.single.uid, 'seal');
      expect(h.engine.evaluations, evaluationsBefore,
          reason: 'subscribing must not BE the thing that evaluates');
      expect(h.values.subscribeCalls, subscribesBefore,
          reason: 'nor the thing that subscribes upstream');

      await sub.cancel();
      await h.dispose();
    });

    // --------------------------------------------------------------- arm 2
    test('every alarm input is subscribed the moment start() returns, before '
        'any client exists', () async {
      final h = await _Harness.create([
        _alarm('seal', ['a > 10', 'b > 2 AND b < 4']),
        _alarm('door', ['c == 1']),
      ]);

      expect(h.values.subscribeCalls, isEmpty,
          reason: 'nothing is subscribed by construction alone');

      await h.engine.start();

      // The roadmap's named trap: a backend that subscribes only once a panel
      // asks. Zero clients exist at this instant.
      expect(h.values.subscribeCalls, {'a': 1, 'b': 1, 'c': 1});
      expect(h.values.liveListeners, {'a': 1, 'b': 1, 'c': 1});
      expect(h.engine.started, isTrue);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 3
    test('the engine\'s subscription survives the last panel leaving', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();
      expect(h.values.liveListeners['a'], 1);

      // A panel takes its own subscription on the same key and then goes away.
      final panel = h.values.subscribe('a').listen((_) {});
      await settle();
      expect(h.values.liveListeners['a'], 2);
      await panel.cancel();
      await settle();

      expect(h.values.liveListeners['a'], 1,
          reason: 'the 0->1 refcount transition that makes the pipe issue '
              'PipeSubscribe must never reverse while the engine lives');

      // And it is still fed.
      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.engine.active, hasLength(1));

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 4
    test('ALARM.active is published, as a list carrying the uid and the rule '
        'index', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      final published = h.publisher.records
          .where((r) => r.key == relay.AlarmKeys.active)
          .toList();
      expect(published, hasLength(2),
          reason: 'the constructor seed, then the activation');

      final payload = _decode(published.last.value);
      expect(payload.entries, hasLength(1));
      expect(payload.entries.single.uid, 'seal');
      expect(payload.entries.single.ruleIndex, 0);
      expect(published.last.value.quality, relay.Quality.good);
      expect(payload.truncated, isFalse);

      // P-7: the instant is DATA, not metadata. `toUaValue` on the panel drops
      // sourceTime, and a per-entry instant inside a list has nowhere to live.
      expect(payload.entries.single.activeAtMs, t0.millisecondsSinceEpoch);
      expect(payload.entries.single.activeAt, t0);
      expect(payload.entries.single.tsSource,
          relay.AlarmActiveEntry.tsSourcePlant);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 5
    test('one entry per alarm-RULE, distinguished by ruleIndex', () async {
      final h = await _Harness.create([
        _alarm('seal', ['a > 10', 'a > 20']),
      ]);
      await h.engine.start();

      h.values.push('a', good(30.0, at: t0));
      await settle();

      final payload = _decode(h.publisher.records.last.value);
      expect(payload.entries, hasLength(2));
      expect(payload.entries.map((e) => e.uid).toSet(), {'seal'});
      expect(payload.entries.map((e) => e.ruleIndex).toSet(), {0, 1});
      expect(h.engine.active, hasLength(2));

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 6
    test('the entry is self-sufficient -- a panel one restart behind can still '
        'name the alarm', () async {
      final h = await _Harness.create([
        _alarm(
          'seal',
          ['a > 10'],
          title: 'Seal bar over temperature',
          description: 'The seal bar exceeded its limit for more than 5 s.',
          group: const ['Line 3', 'Multivac'],
          level: AlarmLevel.warning,
        ),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      final entry = _decode(h.publisher.records.last.value).entries.single;
      expect(entry.title, 'Seal bar over temperature');
      expect(entry.description,
          'The seal bar exceeded its limit for more than 5 s.');
      expect(entry.level, 'warning');
      expect(entry.group, ['Line 3', 'Multivac'],
          reason: 'outermost first, as AlarmConfig.group is read');
      expect(entry.expression, contains('20'),
          reason: 'the formula as it read when it fired');
      expect(entry.historyId, isNull, reason: '14-06 fills this, not 14-05');
      expect(entry.pendingAck, isFalse);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 7
    test('seeded honestly at construction: an EMPTY list at '
        'uncertainNotYetKnown, good only after the first evaluation', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);

      // Before start(). "No alarms are active" and "the engine has not
      // evaluated yet" are different facts, and only one of them is
      // reassuring. Research Open Question 3's recommendation, taken.
      expect(h.publisher.records, hasLength(1));
      final seed = h.publisher.records.single;
      expect(seed.key, relay.AlarmKeys.active);
      expect(seed.value.quality, relay.Quality.uncertainNotYetKnown);
      expect(_decode(seed.value).entries, isEmpty);

      await h.engine.start();
      expect(h.publisher.records, hasLength(1),
          reason: 'start() alone has evaluated nothing');

      // The first completed evaluation comes out FALSE, and that is still the
      // moment the answer becomes knowable.
      h.values.push('a', good(1.0, at: t0));
      await settle();

      expect(h.publisher.records, hasLength(2));
      expect(h.publisher.records.last.value.quality, relay.Quality.good);
      expect(_decode(h.publisher.records.last.value).entries, isEmpty);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 8
    test('republished on CHANGE only -- ten updates, one publication',
        () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.engine.publications, 1);

      for (var i = 1; i <= 10; i++) {
        h.values.push('a', good(20.0 + i, at: t0.add(Duration(seconds: i))));
      }
      await settle();

      expect(h.engine.evaluations, 11,
          reason: 'every update WAS evaluated -- it just did not change');
      expect(h.engine.publications, 1,
          reason: 'a fan-out to every connected panel per value update is the '
              'cost this guard exists to avoid');
      expect(h.publisher.records, hasLength(2),
          reason: 'the constructor seed plus that one publication');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm 9
    test('the reserved ALARM. namespace is defended at start()', () async {
      final h = await _Harness.create([_alarm('seal', ['a > 10'])]);
      // An operator has named a plant tag into the engine's namespace. Nothing
      // upstream refuses this: `tfc_relay_local`'s KeyRouter:439 covers the
      // gateway path and has no backend twin, so T-14-08 lands here.
      h.values.declaredKeys.add('ALARM.tank_level');

      await expectLater(
        h.engine.start(),
        throwsA(isA<UnsupportedError>()
            .having((e) => e.message, 'message', contains('AlarmEngine.start'))
            .having((e) => e.message, 'message', contains('ALARM.tank_level'))
            .having((e) => e.message, 'message', contains('BackendValueSource'))
            .having((e) => e.message, 'message',
                contains(relay.AlarmKeys.active))),
      );

      // ALARM.active itself is of course allowed: the value source declares it
      // so the relay server answers a subscription rather than `unknownKey`.
      final ok = await _Harness.create([_alarm('seal', ['a > 10'])]);
      ok.values.declaredKeys.add(relay.AlarmKeys.active);
      await expectLater(ok.engine.start(), completes);

      await h.dispose();
      await ok.dispose();
    });

    // -------------------------------------------------------------- arm 10
    test('a malformed formula does not take the backend down -- it is named, '
        'and every other alarm still evaluates', () async {
      final h = await _Harness.create([
        _alarm('good-one', ['a > 10']),
        _alarm('broken', ['foo bar > 5']),
        _alarm('good-two', ['b > 10']),
      ]);

      await expectLater(h.engine.start(), completes);
      expect(h.engine.started, isTrue);

      expect(h.engine.refusals, hasLength(1));
      expect(h.engine.refusals.single, contains('broken'),
          reason: 'the alarm uid, so an operator can find the row');
      expect(h.engine.refusals.single, contains('foo bar > 5'),
          reason: 'and the formula, so they can see what is wrong with it');

      h.values.push('a', good(20.0, at: t0));
      h.values.push('b', good(20.0, at: t0));
      await settle();

      expect(h.engine.active.map((e) => e.uid).toSet(), {'good-one', 'good-two'},
          reason: 'one bad formula must not suppress every alarm (T-14-16)');

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 11
    test('a malformed alarm_man_config refuses by name and does not throw out '
        'of start()', () async {
      final h = await _Harness.createRaw('{"alarms": [{"uid": ');

      await expectLater(h.engine.start(), completes,
          reason: 'FormatException escaping here is what killed the backend at '
              '13-RIG-PROBE FIND-4 (T-14-15)');
      expect(h.engine.started, isTrue);

      expect(h.engine.refusals, hasLength(1));
      final refusal = h.engine.refusals.single;
      expect(refusal, contains('alarm_man_config'),
          reason: 'the preference key, because that is the row to go and fix');
      expect(refusal, contains('offset'),
          reason: 'and where in it the parse gave up');
      expect(refusal, contains('no alarm is being evaluated'),
          reason: 'one sentence saying what the consequence is');

      // The engine is up, empty and honest rather than absent.
      expect(h.engine.active, isEmpty);
      expect(h.publisher.records.last.value.quality,
          relay.Quality.uncertainNotYetKnown,
          reason: 'a config that did not parse has evaluated nothing, so the '
              'seeded not-yet-known must NOT be promoted to good');

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 12
    test('the published payload is bounded, with an explicit marker and a log '
        'line', () async {
      final h = await _Harness.create(
        [for (var i = 0; i < 5; i++) _alarm('alarm-$i', ['a > 10'])],
        maxPublishedEntries: 3,
      );
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();

      expect(h.engine.active, hasLength(5),
          reason: 'the cap bounds the PAYLOAD, never the engine\'s own truth');

      final payload = _decode(h.publisher.records.last.value);
      expect(payload.entries, hasLength(3));
      expect(payload.truncated, isTrue);
      expect(payload.omitted, 2);

      // Deciding the ceiling beats discovering it on a bad day, and a silent
      // ceiling is one nobody discovers at all.
      expect(
          h.logs.where(
              (l) => l.contains('truncat') && l.contains(relay.AlarmKeys.active)),
          isNotEmpty,
          reason: 'the truncation must reach the log');

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 13
    test('suspended rules are observable (CD-6) -- the count rises and falls',
        () async {
      final h = await _Harness.create([
        _alarm('seal', ['a > 10']),
        _alarm('door', ['b > 10']),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      h.values.push('b', good(1.0, at: t0));
      await settle();
      expect(h.engine.suspendedRuleCount, 0);

      h.values.push('a',
          bad(relay.Quality.badCommFault, at: t0.add(const Duration(minutes: 1))));
      await settle();
      expect(h.engine.suspendedRuleCount, 1);
      expect(h.engine.active, hasLength(1),
          reason: 'and the alarm is HELD, not cleared (D-3)');

      h.values.push('a', good(20.0, at: t0.add(const Duration(minutes: 2))));
      await settle();
      expect(h.engine.suspendedRuleCount, 0);

      await h.dispose();
    });

    // -------------------------------------------------------------- arm 14
    test('activeAlarms() has NO side effect -- calling it twice and never '
        'calling it observe the same source', () async {
      final untouched = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await untouched.engine.start();
      untouched.values.push('a', good(20.0, at: t0));
      await settle();

      final watched = await _Harness.create([_alarm('seal', ['a > 10'])]);
      await watched.engine.start();
      final one = watched.engine.activeAlarms().listen((_) {});
      final two = watched.engine.activeAlarms().listen((_) {});
      watched.values.push('a', good(20.0, at: t0));
      await settle();

      // This is `bin/main.dart:94`'s workaround -- a backend subscribing to
      // its own alarm stream so that the onListen body runs -- being
      // structurally impossible rather than merely absent.
      expect(watched.values.subscribeCalls, untouched.values.subscribeCalls);
      expect(watched.values.liveListeners, untouched.values.liveListeners);
      expect(watched.engine.evaluations, untouched.engine.evaluations);
      expect(watched.engine.publications, untouched.engine.publications);
      expect(watched.engine.active.length, untouched.engine.active.length);

      await one.cancel();
      await two.cancel();
      await settle();

      // And leaving does not stop it either.
      watched.values.push('a', good(5.0, at: t0.add(const Duration(minutes: 1))));
      await settle();
      expect(watched.engine.active, isEmpty);
      expect(watched.engine.publications, 2);

      await untouched.dispose();
      await watched.dispose();
    });

    // -------------------------------------------------------------- arm 15
    //
    // Added during the sabotage pass, and the SUMMARY says so. Mutation (c1) --
    // dropping the engine's own `if (changed || firstVerdict)` guard and
    // publishing on every transition -- left all fourteen arms above GREEN,
    // because arm 8's ten updates produce no transition at all: the watcher's
    // boolean dedup absorbs them one layer down. So the *engine's* half of "on
    // change only" was being asserted by nothing, and a future edit that made
    // the engine fan out per transition would have cost one publication to
    // every connected panel per rule per evaluation with no test noticing.
    //
    // The case that separates the two layers is a transition that genuinely
    // arrives and genuinely changes nothing: a second rule's first verdict,
    // coming out false, after another rule has already made the set knowable.
    test('a transition that changes nothing publishes nothing', () async {
      final h = await _Harness.create([
        _alarm('seal', ['a > 10', 'b > 10']),
      ]);
      await h.engine.start();

      h.values.push('a', good(20.0, at: t0));
      await settle();
      expect(h.engine.publications, 1, reason: 'rule 0 activated');
      final afterFirst = h.publisher.records.length;

      // Rule 1 reaches its first verdict, and it is false. A real transition
      // (isFirstEvaluation), a real evaluation -- and no change to the set.
      h.values.push('b', good(1.0, at: t0.add(const Duration(seconds: 1))));
      await settle();

      expect(h.engine.evaluations, 2, reason: 'both rules HAVE evaluated');
      expect(h.engine.publications, 1,
          reason: 'the set is what it was; the wire must not move');
      expect(h.publisher.records, hasLength(afterFirst));
      expect(h.engine.active, hasLength(1));

      await h.dispose();
    });
  });

  group('AlarmEngine makes the D-3 hold visible on the wire', () {
    // The rig measurement these arms encode, 2026-09-08: at backend boot the
    // OPC UA server answered the initial read of a dead node with 0.0 at GOOD
    // quality, `cooler.temp.avg < 0.1` fired within 700 ms, the sweep staled
    // the input at +12.5 s, and D-3 held the warning true — correctly, and
    // invisibly, for as long as anybody watched. The hold is right; a hold
    // nobody can see is the alarm-shaped version of the silent staleness this
    // milestone exists to remove.

    // --------------------------------------------------------------- arm S1
    test('an activation from a good type-default read, then a dead input: '
        'the published entry says HELD, on which key, since when', () async {
      final h = await _Harness.create([
        _alarm('cooler', ['a < 0.1'], level: AlarmLevel.warning),
      ]);
      await h.engine.start();

      // The boot window: the dead node's one good-quality default reading.
      h.values.push('a', good(0.0, at: t0));
      await settle();
      expect(h.engine.active, hasLength(1));
      final live = h.engine.active.single;
      expect(live.staleInputs, isEmpty,
          reason: 'no input is stale yet; the badge must not cry wolf');
      expect(live.staleSinceMs, isNull);

      // The sweep ages the key. The set has not changed — but what the banner
      // must SAY about it has, so the wire moves.
      final before = h.publisher.records.length;
      final tHold = t0.add(const Duration(seconds: 12));
      h.clock.at = tHold;
      h.values.push('a', bad(relay.Quality.badStale, at: tHold));
      await settle();

      expect(h.publisher.records.length, before + 1,
          reason: 'a suspension on a PUBLISHED alarm re-encodes the payload');
      final held = _decode(h.publisher.records.last.value).entries.single;
      expect(held.staleInputs, ['a'],
          reason: 'the operator\'s next act is to check this sensor by name');
      expect(held.staleSinceMs, tHold.millisecondsSinceEpoch,
          reason: 'over the injected clock, as data — the panel must render '
              '"since 12:00:12" without consulting its own clock');
      expect(held.activeAtMs, t0.millisecondsSinceEpoch,
          reason: 'the onset is untouched; the hold is a fact ABOUT the '
              'entry, not a new entry');

      // And the observation surface a reader polls agrees with the wire.
      expect(h.engine.active.single.staleInputs, ['a']);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm S2
    test('recovery clears the badge on the wire, without touching the onset',
        () async {
      final h = await _Harness.create([
        _alarm('cooler', ['a < 0.1'], level: AlarmLevel.warning),
      ]);
      await h.engine.start();

      h.values.push('a', good(0.0, at: t0));
      await settle();
      h.clock.at = t0.add(const Duration(seconds: 12));
      h.values.push('a',
          bad(relay.Quality.badStale, at: t0.add(const Duration(seconds: 12))));
      await settle();

      // The sensor returns and the condition still holds: same boolean, live
      // badge gone, one republication.
      final before = h.publisher.records.length;
      h.values
          .push('a', good(0.05, at: t0.add(const Duration(minutes: 30))));
      await settle();

      expect(h.publisher.records.length, before + 1);
      final entry = _decode(h.publisher.records.last.value).entries.single;
      expect(entry.staleInputs, isEmpty,
          reason: 'a badge that survives recovery teaches operators to '
              'ignore the badge');
      expect(entry.staleSinceMs, isNull);
      expect(entry.activeAtMs, t0.millisecondsSinceEpoch);

      await h.dispose();
    });

    // --------------------------------------------------------------- arm S3
    test('a suspension with nothing on the banner moves nothing on the wire',
        () async {
      final h = await _Harness.create([
        _alarm('cooler', ['a < 0.1'], level: AlarmLevel.warning),
      ]);
      await h.engine.start();

      // Rule evaluated false — nothing published beyond the first verdict.
      h.values.push('a', good(10.0, at: t0));
      await settle();
      expect(h.engine.active, isEmpty);

      final before = h.publisher.records.length;
      h.values.push('a',
          bad(relay.Quality.badStale, at: t0.add(const Duration(seconds: 12))));
      await settle();

      expect(h.publisher.records.length, before,
          reason: 'no visible entry changed shape; fanning out an identical '
              'payload on every sweep cycle would be noise, not news');
      expect(h.engine.suspendedRuleCount, 1,
          reason: 'the aggregate still counts it — the hold is real, it is '
              'just not on a banner');

      await h.dispose();
    });

    // --------------------------------------------------------------- arm S4
    //
    // `suspendedRuleCount` predates these arms and had no consumer at all —
    // an accessor that looks like coverage and is not. Its consumer is the
    // engine's own edge log: the aggregate an operator greps for when three
    // rules go quiet at once.
    test('the suspension edge is logged with the aggregate count, once per '
        'edge', () async {
      final h = await _Harness.create([
        _alarm('cooler', ['a < 0.1'], level: AlarmLevel.warning),
      ]);
      await h.engine.start();

      h.values.push('a', good(0.0, at: t0));
      await settle();
      h.values.push('a',
          bad(relay.Quality.badStale, at: t0.add(const Duration(seconds: 12))));
      h.values.push('a',
          bad(relay.Quality.badStale, at: t0.add(const Duration(seconds: 22))));
      await settle();

      final aggregate = h.logs
          .where((line) => line.contains('1 of 1 alarm rule(s) suspended'))
          .toList();
      expect(aggregate, hasLength(1),
          reason: 'once per EDGE — a line per sweep tick is the '
              'logger-hot-path stall T-14-14 measured');

      h.values.push('a', good(0.0, at: t0.add(const Duration(minutes: 1))));
      await settle();
      expect(
          h.logs.where(
              (line) => line.contains('0 of 1 alarm rule(s) suspended')),
          hasLength(1),
          reason: 'the exit edge carries the aggregate too');

      await h.dispose();
    });
  });

  group('AlarmActiveEntry agrees with AlarmTsSource across the package '
      'boundary', () {
    // `tfc_relay_protocol` must not import `tfc_dart`, so the two wire strings
    // are declared twice. `pipe_keys.dart`'s own doc says the way two rosters
    // are kept honest is a test that compares them; this is that test.
    test('the two rosters are the same two strings', () {
      expect(relay.AlarmActiveEntry.tsSourcePlant, AlarmTsSource.plant.wireName);
      expect(relay.AlarmActiveEntry.tsSourceBackendReceipt,
          AlarmTsSource.backendReceipt.wireName);
      expect(
        {
          relay.AlarmActiveEntry.tsSourcePlant,
          relay.AlarmActiveEntry.tsSourceBackendReceipt,
        },
        {for (final s in AlarmTsSource.values) s.wireName},
        reason: 'a third provenance added on one side must fail here rather '
            'than be refused as unknown in the plant',
      );
    });
  });
}

// ------------------------------------------------------------------ fixtures

({List<relay.AlarmActiveEntry> entries, bool truncated, int omitted}) _decode(
        relay.DynamicValue value) =>
    relay.AlarmActiveEntry.decodeList(value.toJson(slim: true));

AlarmConfig _alarm(
  String uid,
  List<String> formulas, {
  String title = 'A title',
  String description = 'A description',
  List<String> group = const [],
  AlarmLevel level = AlarmLevel.error,
  bool acknowledgeRequired = false,
}) =>
    AlarmConfig(
      uid: uid,
      title: title,
      description: description,
      group: group,
      rules: [
        for (final formula in formulas)
          AlarmRule(
            level: level,
            expression: ExpressionConfig(value: Expression(formula: formula)),
            acknowledgeRequired: acknowledgeRequired,
          ),
      ],
    );

/// An engine, its fakes and everything the arms read off them.
final class _Harness {
  _Harness._(this.values, this.preferences, this.publisher, this.logs);

  static Future<_Harness> create(
    List<AlarmConfig> alarms, {
    int maxPublishedEntries = 200,
  }) =>
      createRaw(jsonEncode(AlarmManConfig(alarms: alarms).toJson()),
          maxPublishedEntries: maxPublishedEntries);

  /// Seeds `alarm_man_config` with [configJson] verbatim, so an arm can hand
  /// the engine bytes no encoder would ever produce.
  static Future<_Harness> createRaw(
    String? configJson, {
    int maxPublishedEntries = 200,
  }) async {
    final preferences = InMemoryPreferences();
    if (configJson != null) {
      await preferences.setString('alarm_man_config', configJson);
    }
    final logs = <String>[];
    final h = _Harness._(
      FakeBackendValueSource(),
      preferences,
      _RecordingPublisher(),
      logs,
    );
    h.engine = AlarmEngine(
      values: h.values,
      preferences: preferences,
      publisher: h.publisher,
      clock: h.clock.call,
      maxPublishedEntries: maxPublishedEntries,
      logger: Logger(
        filter: ProductionFilter(),
        level: Level.all,
        printer: SimplePrinter(colors: false),
        output: _RecordingOutput(logs),
      ),
    );
    return h;
  }

  final FakeBackendValueSource values;
  final InMemoryPreferences preferences;
  final _RecordingPublisher publisher;
  final List<String> logs;
  final CountingClock clock = CountingClock(t0);
  late final AlarmEngine engine;

  Future<void> dispose() async {
    await engine.dispose();
    await values.dispose();
  }
}

typedef _Record = ({String key, relay.DynamicValue value});

/// Records every publication in order, so "exactly one" is countable.
final class _RecordingPublisher implements AlarmStatePublisher {
  final List<_Record> records = [];

  @override
  void publish(String key, relay.DynamicValue value) =>
      records.add((key: key, value: value));
}

final class _RecordingOutput extends LogOutput {
  _RecordingOutput(this.lines);

  final List<String> lines;

  @override
  void output(OutputEvent event) => lines.addAll(event.lines);
}
