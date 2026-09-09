import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc/mcp/state_man_state_reader.dart';

/// Minimal mock for testing StateManStateReader logic.
///
/// Since StateMan is tightly coupled to OPC UA FFI, we cannot easily
/// instantiate it in unit tests. Instead, we test StateManStateReader
/// via its public interface by constructing it with controllable streams
/// using the test-only constructor.
void main() {
  group('StateManStateReader', () {
    test('keys returns all provided keys', () {
      final reader = StateManStateReader.forTest(
        keys: ['tag1', 'tag2', 'tag3'],
        streams: {},
      );

      expect(reader.keys, unorderedEquals(['tag1', 'tag2', 'tag3']));
    });

    test('getValue returns null for unsubscribed key', () {
      final reader = StateManStateReader.forTest(
        keys: ['tag1'],
        streams: {},
      );

      expect(reader.getValue('tag1'), isNull);
      expect(reader.getValue('nonexistent'), isNull);
    });

    test('getValue returns cached value after stream emits', () async {
      final controller = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['temp'],
        streams: {'temp': controller.stream},
      );

      await reader.init();

      // Emit a value
      controller.add(DynamicValue(value: 42));
      // Allow async propagation
      await Future.delayed(Duration.zero);

      expect(reader.getValue('temp'), equals(42));

      await controller.close();
      reader.dispose();
    });

    test('getValue returns updated value when stream emits new data', () async {
      final controller = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['pressure'],
        streams: {'pressure': controller.stream},
      );

      await reader.init();

      controller.add(DynamicValue(value: 100.5));
      await Future.delayed(Duration.zero);
      expect(reader.getValue('pressure'), equals(100.5));

      controller.add(DynamicValue(value: 200.0));
      await Future.delayed(Duration.zero);
      expect(reader.getValue('pressure'), equals(200.0));

      await controller.close();
      reader.dispose();
    });

    test('currentValues returns map of all cached pairs', () async {
      final ctrl1 = StreamController<DynamicValue>.broadcast();
      final ctrl2 = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['a', 'b'],
        streams: {'a': ctrl1.stream, 'b': ctrl2.stream},
      );

      await reader.init();

      ctrl1.add(DynamicValue(value: 'hello'));
      ctrl2.add(DynamicValue(value: true));
      await Future.delayed(Duration.zero);

      final values = reader.currentValues;
      expect(values, {'a': 'hello', 'b': true});
      // Should be unmodifiable
      expect(() => values['c'] = 1, throwsUnsupportedError);

      await ctrl1.close();
      await ctrl2.close();
      reader.dispose();
    });

    test('handles DynamicValue with string value', () async {
      final controller = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['status'],
        streams: {'status': controller.stream},
      );

      await reader.init();

      controller.add(DynamicValue(value: 'running'));
      await Future.delayed(Duration.zero);

      expect(reader.getValue('status'), equals('running'));

      await controller.close();
      reader.dispose();
    });

    test('handles DynamicValue with boolean value', () async {
      final controller = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['flag'],
        streams: {'flag': controller.stream},
      );

      await reader.init();

      controller.add(DynamicValue(value: false));
      await Future.delayed(Duration.zero);

      expect(reader.getValue('flag'), equals(false));

      await controller.close();
      reader.dispose();
    });

    test('a never-resolving subscribe does not stall the remaining keys',
        () async {
      // Regression: a key whose mapping names no server leaves
      // StateMan.subscribe pending forever instead of throwing. Sequential
      // warm-up used to stop dead there, leaving every later key null.
      final controllers = {
        for (final key in ['before', 'after1', 'after2'])
          key: StreamController<DynamicValue>.broadcast(),
      };

      final reader = StateManStateReader.forTest(
        keys: ['before', 'hangs', 'after1', 'after2'],
        subscribe: (key) async {
          if (key == 'hangs') return Completer<Stream<DynamicValue>>().future;
          return controllers[key]!.stream;
        },
        subscribeTimeout: const Duration(milliseconds: 50),
      );

      await reader.init();

      for (final entry in controllers.entries) {
        expect(entry.value.hasListener, isTrue,
            reason: '${entry.key} should have been subscribed');
        entry.value.add(DynamicValue(value: 7));
      }
      await Future.delayed(Duration.zero);

      expect(reader.getValue('before'), equals(7));
      expect(reader.getValue('after1'), equals(7));
      expect(reader.getValue('after2'), equals(7));
      expect(reader.getValue('hangs'), isNull);

      reader.dispose();
      for (final c in controllers.values) {
        await c.close();
      }
    });

    group('a mapping accepted after startup', () {
      // The situation an accepted key-mapping proposal creates: StateMan's
      // updateKeyMappings makes the key readable immediately, but this reader
      // used to have copied the key list at construction — so get_tag_value
      // answered "Tag not found" for a key the rest of the app was already
      // reading, until the app was restarted. The MCP server's own
      // instructions tell an agent to verify a new mapping with
      // get_tag_value, so the stale snapshot broke the exact workflow the
      // server prescribes.

      test('appears in keys without a restart', () async {
        final live = ['old'];
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => List.of(live),
        );
        await reader.init();
        expect(reader.keys, ['old']);

        live.add('accepted.later');
        expect(reader.keys, unorderedEquals(['old', 'accepted.later']),
            reason: 'keys must consult the mapping source live');
      });

      test('is subscribed on first touch and readable on the next', () async {
        final live = <String>[];
        final controller = StreamController<DynamicValue>.broadcast();
        final subscribed = <String>[];
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => List.of(live),
          subscribe: (key) async {
            subscribed.add(key);
            return controller.stream;
          },
        );
        await reader.init();
        expect(subscribed, isEmpty);

        live.add('accepted.later');
        // First touch: nothing cached yet — null, honestly — but the
        // subscription starts.
        expect(reader.getValue('accepted.later'), isNull);
        await Future.delayed(Duration.zero);
        expect(subscribed, ['accepted.later']);

        controller.add(DynamicValue(value: true));
        await Future.delayed(Duration.zero);
        expect(reader.getValue('accepted.later'), isTrue,
            reason: 'the next read sees the live value');

        await controller.close();
        reader.dispose();
      });

      test('a burst of reads opens one subscription, not one per read',
          () async {
        final controller = StreamController<DynamicValue>.broadcast();
        var subscribes = 0;
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => ['fresh'],
          subscribe: (key) async {
            subscribes++;
            await Future.delayed(const Duration(milliseconds: 5));
            return controller.stream;
          },
        );
        for (var i = 0; i < 10; i++) {
          reader.getValue('fresh');
        }
        await Future.delayed(const Duration(milliseconds: 20));
        expect(subscribes, 1);

        await controller.close();
        reader.dispose();
      });

      test('a key that is not mapped is not subscribed', () async {
        var subscribes = 0;
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => ['known'],
          subscribe: (key) async {
            subscribes++;
            return const Stream<DynamicValue>.empty();
          },
        );
        reader.getValue('never.mapped');
        await Future.delayed(Duration.zero);
        expect(subscribes, 0,
            reason: 'lazy subscription is gated on the mapping existing');
        reader.dispose();
      });

      test('a failed subscribe does not lock the key out', () async {
        var attempts = 0;
        final controller = StreamController<DynamicValue>.broadcast();
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => ['flaky'],
          subscribe: (key) async {
            attempts++;
            if (attempts == 1) throw StateError('server was rebooting');
            return controller.stream;
          },
        );
        reader.getValue('flaky');
        await Future.delayed(Duration.zero);
        expect(attempts, 1);

        // The next human-paced query tries again and succeeds.
        reader.getValue('flaky');
        await Future.delayed(Duration.zero);
        controller.add(DynamicValue(value: 7));
        await Future.delayed(Duration.zero);
        expect(reader.getValue('flaky'), 7);

        await controller.close();
        reader.dispose();
      });

      test('a removed mapping disappears from keys', () async {
        final live = ['doomed'];
        final reader = StateManStateReader.forTest(
          keys: const [],
          liveKeys: () => List.of(live),
        );
        expect(reader.keys, ['doomed']);
        live.clear();
        expect(reader.keys, isEmpty);
      });
    });

    group('structured values are not rendered until somebody reads them', () {
      // A 45s sampling profile of an idle production station (latest-profile
      // AOT build) put DynamicValue.toString at 0.9% of self time (130 of
      // ~14000 samples), with MapBase.mapToString, StringBuffer.write and
      // this reader's _extractValue all in the call tree above it. The reader
      // subscribes to every key in the mapping, and a struct-valued key used
      // to be rendered to a String on *every* update -- into a cache nothing
      // reads except the MCP tag tools, at human pace.

      test('a burst of struct updates renders nothing', () async {
        final controller = StreamController<DynamicValue>.broadcast();
        final reader = StateManStateReader.forTest(
          keys: ['conveyor.status'],
          streams: {'conveyor.status': controller.stream},
        );
        await reader.init();

        const updates = 500;
        final members = <_CountingDynamicValue>[];
        for (var i = 0; i < updates; i++) {
          final speed = _CountingDynamicValue(i.toDouble());
          final running = _CountingDynamicValue(i.isEven);
          members
            ..add(speed)
            ..add(running);
          controller.add(_struct({'speed': speed, 'running': running}));
        }
        await pumpEventQueue();

        expect(members.map((m) => m.toStringCalls), everyElement(0),
            reason: '$updates struct updates arrived and nobody asked for any '
                'of them; rendering them eagerly cost ${members.length} '
                'DynamicValue.toString calls plus a map walk per update');

        // The read still produces exactly what the eager version cached.
        expect(
            reader.getValue('conveyor.status'),
            _struct({
              'speed': DynamicValue(value: (updates - 1).toDouble()),
              'running': DynamicValue(value: (updates - 1).isEven),
            }).value.toString());

        // Only the surviving update is rendered, and only once: a second read
        // reuses the string rather than rebuilding it.
        reader.getValue('conveyor.status');
        final live = members.sublist(members.length - 2);
        expect(live.map((m) => m.toStringCalls), everyElement(1));
        expect(
            members.sublist(0, members.length - 2).map((m) => m.toStringCalls),
            everyElement(0),
            reason: 'superseded updates must never be rendered at all');

        await controller.close();
        reader.dispose();
      });

      test('currentValues renders the deferred entries', () async {
        final scalar = StreamController<DynamicValue>.broadcast();
        final structured = StreamController<DynamicValue>.broadcast();
        final reader = StateManStateReader.forTest(
          keys: ['n', 's'],
          streams: {'n': scalar.stream, 's': structured.stream},
        );
        await reader.init();

        scalar.add(DynamicValue(value: 3));
        structured.add(_struct({'on': DynamicValue(value: true)}));
        await pumpEventQueue();

        expect(reader.currentValues, {
          'n': 3,
          's': _struct({'on': DynamicValue(value: true)}).value.toString(),
        });
        expect(() => reader.currentValues['x'] = 1, throwsUnsupportedError);

        await scalar.close();
        await structured.close();
        reader.dispose();
      });

      test('an array value renders the same way a struct does', () async {
        final controller = StreamController<DynamicValue>.broadcast();
        final reader = StateManStateReader.forTest(
          keys: ['recipe.steps'],
          streams: {'recipe.steps': controller.stream},
        );
        await reader.init();

        final member = _CountingDynamicValue(1);
        controller.add(DynamicValue.fromList([member]));
        await pumpEventQueue();

        expect(member.toStringCalls, 0);
        expect(reader.getValue('recipe.steps'),
            DynamicValue.fromList([DynamicValue(value: 1)]).value.toString());
        expect(member.toStringCalls, 1);

        await controller.close();
        reader.dispose();
      });
    });

    test('dispose cancels all subscriptions', () async {
      final controller = StreamController<DynamicValue>.broadcast();
      final reader = StateManStateReader.forTest(
        keys: ['tag'],
        streams: {'tag': controller.stream},
      );

      await reader.init();
      expect(controller.hasListener, isTrue);

      reader.dispose();
      expect(controller.hasListener, isFalse);
    });
  });
}

/// A [DynamicValue] that counts every time something renders it as a String.
///
/// Subclassing is what makes the waste countable: the reader stringified the
/// *containing* map, and `MapBase.mapToString` calls `toString()` on each
/// member, so a counter on the members counts the whole render.
class _CountingDynamicValue extends DynamicValue {
  _CountingDynamicValue(Object? value) : super(value: value);

  int toStringCalls = 0;

  @override
  String toString() {
    toStringCalls++;
    return super.toString();
  }
}

/// A struct-valued [DynamicValue] -- the shape most plant keys carry, and the
/// shape whose rendering the profile caught.
DynamicValue _struct(Map<String, DynamicValue> members) {
  final dv = DynamicValue();
  members.forEach((name, member) => dv[name] = member);
  return dv;
}
