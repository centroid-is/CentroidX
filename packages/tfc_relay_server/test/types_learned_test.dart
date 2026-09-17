/// A type learned AFTER a panel subscribed still reaches it.
///
/// The defect this is written against, measured on the plant on 2026-09-17: a
/// dictionary cannot be complete when a panel subscribes, because a type is
/// learned from the first sample of it and that sample arrives BECAUSE
/// somebody subscribed. The first panel to connect after a gateway starts is
/// therefore the one whose own subscription causes the learning, and the one
/// that never heard the answer — every conveyor drew violet for "mode
/// unknown" after signing in, and only a full page reload cured it. A probe
/// connecting a minute later saw a complete dictionary and could not
/// reproduce it, which is exactly why it survived a day of looking.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/tick_engine.dart';

import 'support/panels.dart';

/// The drive-mode enum the conveyors colour from, in miniature.
TypeDescriptor _runMode() => TypeDescriptor(
      ua: 'ns=5;s=#Type|hmis_e',
      enumFields: {
        0: const EnumField(value: 0, name: 'fault'),
        2: const EnumField(value: 2, name: 'auto'),
      },
    );

List<Map<String, Object?>> _framesOf(List<String> frames, String method) => [
      for (final raw in frames)
        if (jsonDecode(raw) case final Map<String, Object?> decoded)
          if (decoded['method'] == method) decoded,
    ];

void main() {
  group('a type learned after the snapshot', () {
    test('reaches a panel that subscribed before it existed', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CVS01.CN01.FD01');
      final key = keys.single;
      final panel = await plant.connect('page', keys);
      final engine = TickEngine(
        registry: plant.registry,
        config: plant.config,
        clock: plant.clock.now,
      );

      // Nothing was known at subscribe time — the state the first panel after
      // a gateway start is always in.
      panel.frames.clear();
      engine.tickOnce(plant.clock.nowMs);
      expect(_framesOf(panel.frames, Methods.typesLearned), isEmpty,
          reason: 'nothing has been learned, so there is nothing to announce '
              'and the sweep must be silent');

      // The first sample lands and the gateway learns the type.
      plant.api.learnType(key, 'ns=5;s=#Type|hmis_e', _runMode());
      engine.tickOnce(plant.clock.nowMs);

      final announced = _framesOf(panel.frames, Methods.typesLearned);
      expect(announced, hasLength(1),
          reason: 'the panel subscribed before the type existed, so the only '
              'way it can ever name this enum is a push. Frames seen: '
              '${panel.frames}');
      final frame = TypesLearnedParams.fromJson(
          (announced.single['params']! as Map).cast<String, Object?>());
      expect(frame.sub, 'page');
      expect(frame.types.keys, contains('ns=5;s=#Type|hmis_e'),
          reason: 'the descriptor itself has to cross: the panel has never '
              'seen this type id before');
      expect(frame.keys.values, contains('ns=5;s=#Type|hmis_e'),
          reason: 'and which handle carries it, or the panel has a dictionary '
              'it cannot apply to anything');
    });

    test('is announced once, not on every tick afterwards', () async {
      final plant = Plant();
      final keys = plant.seed(1, prefix: 'CVS01.CN01.FD01');
      final panel = await plant.connect('page', keys);
      final engine = TickEngine(
        registry: plant.registry,
        config: plant.config,
        clock: plant.clock.now,
      );
      plant.api.learnType(keys.single, 'ns=5;s=#Type|hmis_e', _runMode());
      panel.frames.clear();
      engine.tickOnce(plant.clock.nowMs);
      engine.tickOnce(plant.clock.nowMs);
      engine.tickOnce(plant.clock.nowMs);

      expect(_framesOf(panel.frames, Methods.typesLearned), hasLength(1),
          reason: 'the dictionary version is compared once per tick and the '
              'subscription remembers what it was told, so a settled plant '
              'sends this frame never. Re-sending it every tick would put the '
              'whole type book on the wire four times a second');
    });
  });
}
