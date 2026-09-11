/// `sample_expression` over the shipped `Expression` evaluator, gated on
/// quality: an entry collects only while an operator-authored condition is
/// true — and a condition nobody can currently evaluate is a condition that
/// has NOT been met.
///
/// The parser, the operator table and `evaluate` are reused from
/// `boolean_expression.dart` verbatim — the pure part is the part with the
/// edge cases. Only the binding is new, and the binding is where the two
/// classes named `DynamicValue` meet (08-RESEARCH §A.2): the relay one
/// carries a quality, the open62541 one the evaluator reads does not, and
/// the one conversion site between them is where the quality check lives.
///
/// No database, no network: `FakeSink`, `FakeUpstreamLink`, real
/// `LocalStateMan`.
@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_dart/core/boolean_expression.dart'
    show Expression, ExpressionConfig;
import 'package:tfc_dart/core/collector.dart' show CollectEntry;
import 'package:tfc_dart/core/state_man.dart' show KeyMappingEntry, KeyMappings;
import 'package:tfc_relay_local/tfc_relay_local.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../support/fake_sink.dart';
import '../support/fake_upstream_link.dart';
import '../support/keymap_fixtures.dart';

const String plantAlias = 'ST101';
const String dataKey = 'ST101.CN01.MOT01.speed';
const String flagKey = 'ST101.CN06.RUN.flag';
const String levelKey = 'ST101.CN06.TNK01.level';

/// An expression over [formula], as the keymapping editor stores one.
ExpressionConfig expr(String formula) =>
    ExpressionConfig(value: Expression(formula: formula));

KeyMappingEntry mapped(String key, {ExpressionConfig? expression}) =>
    KeyMappingEntry(
      opcuaNode: opcUaEntry(alias: plantAlias, identifier: key).opcuaNode,
      collect: expression == null
          ? null
          : CollectEntry(key: key, sampleExpression: expression),
    );

typedef Rig = ({
  LocalStateMan plant,
  FakeSink sink,
  CollectionRunner runner,
});

Rig rig(Map<String, KeyMappingEntry> nodes) {
  final link = FakeUpstreamLink(alias: plantAlias);
  final plant = LocalStateMan(
    links: [link],
    router: KeyRouter.overLinks([link], mappings: KeyMappings(nodes: nodes)),
    staleAfter: const Duration(minutes: 5),
  );
  unawaited(link.connect(deadline: const Duration(seconds: 1)));
  unawaited(plant.start());
  addTearDown(plant.dispose);
  final sink = FakeSink();
  final runner = CollectionRunner(
    plan: CollectionPlan.from(KeyMappings(nodes: nodes), CollectionConfig()),
    stateMan: plant,
    sink: sink,
    health: plant.collectHealth,
  );
  addTearDown(runner.stop);
  return (plant: plant, sink: sink, runner: runner);
}

void feed(LocalStateMan plant, String key, Object? value,
        {Quality quality = Quality.good}) =>
    plant.applyUpstreamBatch(<String, DynamicValue>{
      key: DynamicValue(value: value, quality: quality),
    });

Future<void> pump([int ms = 0]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

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

/// Asserts that [ms] of activity produced no new rows — the negative arm
/// every gate case needs, bounded rather than instant.
Future<void> noNewRows(FakeSink sink, {int ms = 60, String? reason}) async {
  final before = sink.accepted.length;
  await pump(ms);
  expect(sink.accepted.length, before, reason: reason);
}

void main() {
  group('the gate opens and closes collection', () {
    test('with the gate false, changes produce no rows; when it goes true, '
        'the next value is inserted; false again stops it', () async {
      final r = rig({
        dataKey: mapped(dataKey, expression: expr('$flagKey == true')),
        flagKey: mapped(flagKey),
      });
      await r.runner.start();
      await pump();

      // The gate variable has no reading yet: unevaluable, therefore false.
      feed(r.plant, dataKey, 1.0);
      await noNewRows(r.sink,
          reason: 'changes to the collected key while the gate is false '
              'produce no rows');

      feed(r.plant, flagKey, true);
      await until(() => r.sink.accepted.length == 1,
          reason: 'the gate going true inserts the next value — the app\'s '
              'gated collector samples the current value on every satisfied '
              'evaluation, and this is that behaviour\'s first sample');
      expect(r.sink.accepted.single.value, 1.0);

      feed(r.plant, dataKey, 2.0);
      await until(() => r.sink.accepted.length == 2,
          reason: 'while the gate is true, changes collect');
      expect(r.sink.accepted.last.value, 2.0);

      feed(r.plant, flagKey, false);
      await pump(10);
      feed(r.plant, dataKey, 3.0);
      await noNewRows(r.sink,
          reason: 'the gate closing stops collection again');
    });
  });

  group('a gate variable that is not good-band means the gate is FALSE', () {
    for (final (quality, name) in <(Quality, String)>[
      (Quality.uncertainLastKnown, 'uncertainLastKnown'),
      (Quality.badCommFault, 'badCommFault'),
      (Quality.errorConfig, 'errorConfig'),
    ]) {
      test('$name on the gate variable closes the gate — fail-safe, '
          'not last-known', () async {
        final r = rig({
          dataKey: mapped(dataKey, expression: expr('$flagKey == true')),
          flagKey: mapped(flagKey),
        });
        await r.runner.start();
        await pump();

        feed(r.plant, flagKey, true);
        feed(r.plant, dataKey, 1.0);
        await until(() => r.sink.accepted.isNotEmpty,
            reason: 'anti-vacuity: the gate is genuinely open before the '
                'degradation, or the case below asserts nothing');

        // The gate variable degrades. Its VALUE still says true — but a
        // condition nobody can currently evaluate is a condition that has
        // not been met, the same instinct as the insert path's own gate.
        feed(r.plant, flagKey, true, quality: quality);
        await pump(10);
        feed(r.plant, dataKey, 2.0);
        await noNewRows(r.sink,
            reason: 'a $name gate variable must close the gate: "the last '
                'known value of the condition" is a condition the field is '
                'no longer confirming, and sampling on it is the quality '
                'gate\'s flat-line lie moved one level up');
      });
    }
  });

  group('a variable that cannot resolve rejects that entry at start', () {
    test('a templated \$variable costs exactly that entry; every other '
        'entry collects', () async {
      final r = rig({
        dataKey: mapped(dataKey,
            expression: expr(r'$machine.speed > 10')),
        levelKey: mapped(levelKey, expression: expr('$flagKey == true')),
        flagKey: mapped(flagKey),
      });
      await r.runner.start();
      await pump();

      expect(r.runner.entryFailures.keys, [dataKey],
          reason: 'substitution is client-local by frozen decision '
              '(state_man_api.dart:26-31) and the router refuses \$ names '
              'at the door — an expression naming one can never evaluate, '
              'which is also what bit the shipped collector '
              '(collector.dart:159-167)');
      expect(r.runner.liveSubscriptions, 1,
          reason: 'the healthy sibling entry still collects');

      feed(r.plant, flagKey, true);
      feed(r.plant, levelKey, 4.2);
      await until(() => r.sink.accepted.isNotEmpty,
          reason: 'one rejected expression costs one entry, never the plan');
    });

    test('a formula that cannot be parsed rejects the entry too', () async {
      final r = rig({
        dataKey: mapped(dataKey,
            // Whitespace inside a variable name: Expression's own parser
            // throws ArgumentError for this shape.
            expression: expr('not a formula >')),
        flagKey: mapped(flagKey),
      });
      await r.runner.start();
      await pump();

      expect(r.runner.entryFailures.keys, [dataKey]);
      expect(r.runner.liveSubscriptions, 0,
          reason: 'nothing of the rejected entry is left running');
    });
  });

  group('the shipped operators behave identically over relay values', () {
    test('a comparison: > selects exactly the values the Expression unit '
        'tests say it selects', () async {
      final r = rig({
        dataKey: mapped(dataKey, expression: expr('$levelKey > 10')),
        levelKey: mapped(levelKey),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, levelKey, 9.0);
      feed(r.plant, dataKey, 1.0);
      await noNewRows(r.sink, reason: '9 > 10 is false');

      feed(r.plant, levelKey, 11.0);
      await until(() => r.sink.accepted.length == 1,
          reason: '11 > 10 is true, and the satisfied gate samples');
    });

    test('a boolean combination: AND requires both sides', () async {
      final r = rig({
        dataKey: mapped(dataKey,
            expression: expr('$levelKey > 10 AND $flagKey == true')),
        levelKey: mapped(levelKey),
        flagKey: mapped(flagKey),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, levelKey, 11.0);
      feed(r.plant, flagKey, false);
      feed(r.plant, dataKey, 1.0);
      await noNewRows(r.sink, reason: 'true AND false is false');

      feed(r.plant, flagKey, true);
      await until(() => r.sink.accepted.length == 1,
          reason: 'true AND true is true');
    });

    test('an equality: == on a number', () async {
      final r = rig({
        dataKey: mapped(dataKey, expression: expr('$levelKey == 5')),
        levelKey: mapped(levelKey),
      });
      await r.runner.start();
      await pump();

      feed(r.plant, levelKey, 4);
      feed(r.plant, dataKey, 1.0);
      await noNewRows(r.sink, reason: '4 == 5 is false');

      feed(r.plant, levelKey, 5);
      await until(() => r.sink.accepted.length == 1,
          reason: '5 == 5 is true — the numeric arm of the shipped '
              'operator table, unchanged');
    });
  });

  group('lifecycle', () {
    test('stopping the runner cancels the gate\'s subscriptions — no stream '
        'outlives stop()', () async {
      final r = rig({
        dataKey: mapped(dataKey, expression: expr('$flagKey == true')),
        flagKey: mapped(flagKey),
      });
      await r.runner.start();
      await pump();
      expect(r.plant.openUpstreamSubscriptions, 2,
          reason: 'anti-vacuity: the collected key AND the gate variable '
              'are both held open while the runner runs');

      await r.runner.stop();
      expect(r.plant.openUpstreamSubscriptions, 0,
          reason: 'the gate detaches like any other subscriber; a gate '
              'subscription that outlives the runner is a leaked monitored '
              'item on the PLC');
    });
  });
}
