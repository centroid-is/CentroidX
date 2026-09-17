import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:logger/logger.dart';

// The batch array lives in the conveyor's own function block, a different node
// from the conveyor settings struct that carries the belt length. The overlay
// therefore reads two nodes: `batchesKey` for the length and `batchArrayKey`
// for the array. The array is never read out of the settings struct, even
// when that struct still carries one.
//
// Why this needed catching rather than waiting for a bug report: the batch
// stream is optional, and `_optional` swallows its error to null on purpose
// (see the comment block above it — a dead decorative node must not grey out a
// conveyor whose drive is healthy). So a page pointed at the wrong node does
// not go red, does not log, and does not blank: the overlay just stops being
// drawn, on an asset that otherwise looks entirely correct.
//
// Fixtures here are deliberately neutral: `line.conveyor.*`, not any real tag.

const _driveKey = 'line.conveyor.drive';
const _settingsKey = 'line.conveyor.settings';
const _arrayKey = 'line.conveyor.batch_array';
const _recipeKey = 'line.recipe';

const _beltLength = 1000.0;
const _slotPosition = 250.0;

/// One element of the batch array.
DynamicValue _slot({required bool occupied, required double position}) {
  final slot = DynamicValue();
  slot['xOccupied'] = occupied;
  slot['position'] = position;
  return slot;
}

DynamicValue _oneOccupiedSlot() =>
    _slot(occupied: true, position: _slotPosition);

/// The conveyor settings struct. [slots] present is a struct that still
/// carries an array member, which the overlay must ignore.
DynamicValue _settings({List<DynamicValue>? slots}) {
  final dv = DynamicValue();
  dv['p_stat_Length'] = _beltLength;
  if (slots != null) dv['p_stat_Batches'] = DynamicValue.fromList(slots);
  return dv;
}

/// The conveyor's function-block instance, which is where the array lives.
DynamicValue _functionBlock(List<DynamicValue> slots) {
  final dv = DynamicValue();
  dv['p_stat_Batches'] = DynamicValue.fromList(slots);
  return dv;
}

/// The line recipe, which now publishes how long one slot is.
DynamicValue _recipe(double batchLengthMm) {
  final dv = DynamicValue();
  dv['batchLength'] = batchLengthMm;
  return dv;
}

DynamicValue _drive() {
  final dv = DynamicValue();
  dv['p_stat_State'] = 2;
  dv['p_stat_Frequency'] = 50.0;
  return dv;
}

/// Serves a canned value per key; keys in [erroring] answer the way a PLC
/// answers for a node that is not there, and keys in [live] are driven by the
/// test through their controller.
class _MapStateMan extends Fake implements StateMan {
  _MapStateMan(
    this.values, {
    this.erroring = const <String>{},
    this.live = const <String, StreamController<DynamicValue>>{},
  });

  final Map<String, DynamicValue> values;
  final Set<String> erroring;
  final Map<String, StreamController<DynamicValue>> live;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final controller = live[key];
    if (controller != null) return controller.stream;
    if (erroring.contains(key)) {
      return Stream<DynamicValue>.error(
          StateManException('Failed to read value: BadNodeIdUnknown'));
    }
    final value = values[key];
    if (value == null) return const Stream<DynamicValue>.empty();
    return Stream<DynamicValue>.value(value);
  }
}

Widget _wrap(ConveyorConfig config, StateMan stateMan) => ProviderScope(
      overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 80,
              child: Conveyor(config),
            ),
          ),
        ),
      ),
    );

ConveyorPainter _painter(WidgetTester tester) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter is ConveyorPainter) return painter;
  }
  fail('no ConveyorPainter in the tree');
}

Map<String, Batch> _batches(WidgetTester tester) => _painter(tester).batches;

/// The conveyor took the builder's error/no-data path — see
/// `conveyor_optional_stream_failure_test.dart` for why this, and not a
/// colour comparison, is the honest probe.
bool _isDisconnected(WidgetTester tester) => _painter(tester).showExclamation;

ConveyorConfig _config({
  String? batchesKey = _settingsKey,
  String? batchArrayKey,
  String? batchLengthKey,
}) =>
    ConveyorConfig(
      key: _driveKey,
      batchesKey: batchesKey,
      batchArrayKey: batchArrayKey,
      batchLengthKey: batchLengthKey,
    )..size = const RelativeSize(width: 1.0, height: 1.0);

Future<void> _pump(
    WidgetTester tester, ConveyorConfig config, StateMan stateMan) async {
  await tester.pumpWidget(_wrap(config, stateMan));
  await tester.pumpAndSettle();
}

void main() {
  group('batch array source', () {
    testWidgets(
      'the array comes off its own node while the length comes from the '
      'settings node',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            // The settings carry the length and nothing else.
            _settingsKey: _settings(),
            _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          }),
        );

        final batches = _batches(tester);
        expect(batches.keys, ['0']);
        // 0.25 is position/length, so the length was taken from the settings
        // node even though the array came from somewhere else entirely.
        expect(batches['0']!.start, closeTo(0.25, 1e-9));
        expect(batches['0']!.end, closeTo(0.75, 1e-9));
      },
    );

    testWidgets(
      'the array key may be bound at the array node itself, not only at the '
      'struct holding it',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
            _arrayKey: DynamicValue.fromList([_oneOccupiedSlot()]),
          }),
        );

        final batches = _batches(tester);
        expect(batches.keys, ['0']);
        expect(batches['0']!.start, closeTo(0.25, 1e-9));
        expect(batches['0']!.end, closeTo(0.75, 1e-9));
      },
    );

    testWidgets(
      'an array still inside the settings struct is never read',
      (tester) async {
        await _pump(
          tester,
          _config(),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(slots: [_oneOccupiedSlot()]),
          }),
        );

        expect(tester.takeException(), isNull);
        expect(_isDisconnected(tester), isFalse);
        expect(_batches(tester), isEmpty,
            reason: 'only the batch-array key supplies the array; a settings '
                'struct that still carries one is ignored');
      },
    );

    testWidgets(
      'with both bound, the array node wins over an array in the settings',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(slots: [
              _slot(occupied: true, position: 0),
              _slot(occupied: true, position: 100),
            ]),
            _arrayKey: _functionBlock([
              _slot(occupied: false, position: 0),
              _oneOccupiedSlot(),
            ]),
          }),
        );

        final batches = _batches(tester);
        expect(batches.keys, ['1']);
        expect(batches['1']!.start, closeTo(0.25, 1e-9));
      },
    );

    testWidgets(
      'the array key alone draws nothing, because the length is missing',
      (tester) async {
        await _pump(
          tester,
          _config(batchesKey: null, batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          }),
        );

        expect(tester.takeException(), isNull);
        expect(_batches(tester), isEmpty);
      },
    );
  });

  group('a batch source that is not there', () {
    testWidgets(
      'an erroring batch-array node leaves the rest of the conveyor drawing',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan(
            {
              _driveKey: _drive(),
              _settingsKey: _settings(),
            },
            erroring: {_arrayKey},
          ),
        );

        expect(_isDisconnected(tester), isFalse,
            reason: 'a dead optional node must cost its own overlay and '
                'nothing else');
        expect(_batches(tester), isEmpty);
      },
    );

    testWidgets(
      'a batch-array node that never reports does not blank the conveyor',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          // _arrayKey is absent from the map, so its stream stays silent.
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
          }),
        );

        expect(_isDisconnected(tester), isFalse,
            reason: 'CombineLatest withholds every frame unless the optional '
                'stream is seeded — see _optional');
        expect(_batches(tester), isEmpty);
      },
    );

    testWidgets(
      'a page with only the settings bound draws no overlay and does not '
      'throw',
      (tester) async {
        // The un-reconfigured page: the settings node reads fine but nothing
        // supplies the array.
        await _pump(
          tester,
          _config(),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
          }),
        );

        expect(tester.takeException(), isNull);
        expect(_isDisconnected(tester), isFalse);
        expect(_batches(tester), isEmpty);
      },
    );

    testWidgets(
      'an array of the wrong thing is skipped rather than thrown',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
            // A key bound one node off still yields an array.
            _arrayKey: DynamicValue.fromList([DynamicValue(value: 1.0)]),
          }),
        );

        expect(tester.takeException(), isNull);
        expect(_isDisconnected(tester), isFalse);
        expect(_batches(tester), isEmpty);
      },
    );

    testWidgets(
      'an array node that goes dead clears the batches it drew',
      (tester) async {
        final array = StreamController<DynamicValue>();
        addTearDown(array.close);

        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan(
            {
              _driveKey: _drive(),
              _settingsKey: _settings(),
            },
            live: {_arrayKey: array},
          ),
        );
        expect(_batches(tester), isEmpty);

        array.add(_functionBlock([_oneOccupiedSlot()]));
        await tester.pumpAndSettle();
        expect(_batches(tester).keys, ['0']);

        array.addError(
            StateManException('Failed to read value: BadNodeIdUnknown'));
        await tester.pumpAndSettle();
        expect(_isDisconnected(tester), isFalse);
        expect(_batches(tester), isEmpty,
            reason: 'the overlay must blank, not freeze on the last batches '
                'a node that stopped reporting drew');
      },
    );

    testWidgets(
      'an array element that stops decoding drops its batch',
      (tester) async {
        final array = StreamController<DynamicValue>();
        addTearDown(array.close);

        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan(
            {
              _driveKey: _drive(),
              _settingsKey: _settings(),
            },
            live: {_arrayKey: array},
          ),
        );

        array.add(_functionBlock([_oneOccupiedSlot()]));
        await tester.pumpAndSettle();
        expect(_batches(tester).keys, ['0']);

        array.add(DynamicValue.fromList([DynamicValue(value: 1.0)]));
        await tester.pumpAndSettle();
        expect(_batches(tester), isEmpty);
      },
    );
  });

  // The overlay is a picture of one reading of the array, so it is replaced by
  // one reading. Edited in place — which is what it used to do — it kept slots
  // that were no longer in the reading that produced them, because the only
  // thing that ever removed an index was the loop reaching that index again.
  group('the overlay is whatever the newest reading says, and only that', () {
    /// Drives the array node by hand, so the overlay can be watched across
    /// successive readings.
    Future<StreamController<DynamicValue>> liveArray(WidgetTester tester) async {
      final array = StreamController<DynamicValue>();
      addTearDown(array.close);
      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey),
        _MapStateMan(
          {
            _driveKey: _drive(),
            _settingsKey: _settings(),
          },
          live: {_arrayKey: array},
        ),
      );
      return array;
    }

    List<DynamicValue> occupiedSlots(int count) => [
          for (var i = 0; i < count; i++)
            _slot(occupied: true, position: i * 100.0),
        ];

    testWidgets('a shorter array does not leave the slots past its end drawn',
        (tester) async {
      final array = await liveArray(tester);

      array.add(_functionBlock(occupiedSlots(5)));
      await tester.pumpAndSettle();
      expect(_batches(tester).keys, ['0', '1', '2', '3', '4']);

      // The belt is re-declared with three slots — a PLC restarted with a
      // shorter array, or a key re-pointed in the page editor.
      array.add(_functionBlock(occupiedSlots(3)));
      await tester.pumpAndSettle();
      expect(_batches(tester).keys, ['0', '1', '2'],
          reason: 'slots 3 and 4 are not in the reading any more, so they '
              'must not still be painted on the belt');
    });

    testWidgets('an array that comes back empty clears the belt',
        (tester) async {
      final array = await liveArray(tester);

      array.add(_functionBlock(occupiedSlots(3)));
      await tester.pumpAndSettle();
      expect(_batches(tester), isNotEmpty);

      array.add(_functionBlock(const []));
      await tester.pumpAndSettle();
      expect(_batches(tester), isEmpty,
          reason: 'an empty array is a reading, not the absence of one: the '
              'belt is empty and must be drawn empty');
    });

    testWidgets('a slot of the wrong shape costs that slot and no other',
        (tester) async {
      final array = await liveArray(tester);

      array.add(_functionBlock([
        _slot(occupied: true, position: 0),
        // One element of something the key is bound one node off from.
        DynamicValue(value: 1.0),
        _slot(occupied: true, position: 500),
      ]));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_isDisconnected(tester), isFalse);
      expect(_batches(tester).keys, ['0', '2'],
          reason: 'the slots that did decode are still a true reading; only '
              'the one that did not is dropped');
    });

    testWidgets(
        'a settings node that loses its length blanks the overlay rather '
        'than freezing it', (tester) async {
      final settings = StreamController<DynamicValue>();
      addTearDown(settings.close);

      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey),
        _MapStateMan(
          {
            _driveKey: _drive(),
            _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          },
          live: {_settingsKey: settings},
        ),
      );

      settings.add(_settings());
      await tester.pumpAndSettle();
      expect(_batches(tester).keys, ['0']);

      // The same node, answering without the member the slot positions are
      // measured against — the shape the struct actually took when the PLC
      // side of this was rewritten.
      settings.add(DynamicValue()..['p_stat_Frequency'] = 50.0);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_isDisconnected(tester), isFalse,
          reason: 'the drive is reading fine; a settings struct that changed '
              'shape must cost the overlay and nothing else');
      expect(_batches(tester), isEmpty);
    });
  });

  group('batch length', () {
    testWidgets('comes from the recipe key when it is set', (tester) async {
      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey, batchLengthKey: _recipeKey),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(),
          _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          _recipeKey: _recipe(200),
        }),
      );

      final batch = _batches(tester)['0']!;
      expect(batch.start, closeTo(0.25, 1e-9));
      expect(batch.end, closeTo(0.45, 1e-9),
          reason: '(250 + 200) / 1000 — the recipe length, not the constant');
    });

    testWidgets('may be bound at the length member directly', (tester) async {
      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey, batchLengthKey: _recipeKey),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(),
          _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          _recipeKey: DynamicValue(value: 200.0),
        }),
      );

      expect(_batches(tester)['0']!.end, closeTo(0.45, 1e-9));
    });

    testWidgets('is the historical 500 mm when no recipe key is set',
        (tester) async {
      expect(ConveyorConfig.defaultBatchLengthMm, 500);

      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(),
          _arrayKey: _functionBlock([_oneOccupiedSlot()]),
        }),
      );

      expect(_batches(tester)['0']!.end, closeTo(0.75, 1e-9),
          reason: '(250 + 500) / 1000');
    });

    testWidgets('falls back to 500 mm when the recipe node is dead',
        (tester) async {
      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey, batchLengthKey: _recipeKey),
        _MapStateMan(
          {
            _driveKey: _drive(),
            _settingsKey: _settings(),
            _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          },
          erroring: {_recipeKey},
        ),
      );

      expect(_isDisconnected(tester), isFalse);
      expect(_batches(tester)['0']!.end, closeTo(0.75, 1e-9),
          reason: 'a dead recipe must not empty the overlay it only sizes');
    });

    testWidgets('refuses a non-positive length rather than emptying the belt',
        (tester) async {
      await _pump(
        tester,
        _config(batchArrayKey: _arrayKey, batchLengthKey: _recipeKey),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(),
          _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          _recipeKey: _recipe(0),
        }),
      );

      expect(_batches(tester)['0']!.end, closeTo(0.75, 1e-9));
    });
  });

  // A batches key bound one node off used to be completely silent. It still
  // must not shout: this runs from a `StreamBuilder` builder, which is re-run
  // on every rebuild rather than on every PLC update, so an ungated line here
  // is a line a frame per conveyor on the page.
  group('what it says about a batches key it cannot use', () {
    /// Everything the conveyor logged while [body] ran.
    Future<List<String>> logged(Future<void> Function() body) async {
      final lines = <String>[];
      void listen(LogEvent event) => lines.add(event.message.toString());
      Logger.addLogListener(listen);
      addTearDown(() => Logger.removeLogListener(listen));
      await body();
      return lines;
    }

    List<String> about(List<String> lines, String fragment) =>
        [for (final line in lines) if (line.contains(fragment)) line];

    testWidgets('an array node of the wrong shape is named once, not once a '
        'frame', (tester) async {
      final lines = await logged(() async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
            _arrayKey: DynamicValue(value: 1.0),
          }),
        );
        // Rebuild the way resizing a window does.
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      });

      expect(about(lines, 'neither an array of slots'), hasLength(1),
          reason: 'said once, and then not again while nothing has changed');
    });

    testWidgets('a settings node with no length says which half is missing',
        (tester) async {
      final lines = await logged(() async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: DynamicValue()..['p_stat_Frequency'] = 50.0,
            _arrayKey: _functionBlock([_oneOccupiedSlot()]),
          }),
        );
      });

      expect(about(lines, 'p_stat_Length'), hasLength(1));
    });

    testWidgets('a key that is simply unbound is not complained about',
        (tester) async {
      final lines = await logged(() async {
        // The un-reconfigured page: settings bound, no array key at all.
        await _pump(
          tester,
          _config(),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
          }),
        );
      });

      expect(about(lines, 'draws no batches'), isEmpty,
          reason: 'not having bound a key is a configuration, not a fault');
    });

    testWidgets('a node that fails, answers, then fails again is named both '
        'times', (tester) async {
      final array = StreamController<DynamicValue>();
      addTearDown(array.close);

      final lines = await logged(() async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan(
            {
              _driveKey: _drive(),
              _settingsKey: _settings(),
            },
            live: {_arrayKey: array},
          ),
        );

        array.addError(StateManException('Failed to read value: BadNodeIdUnknown'));
        await tester.pumpAndSettle();
        array.add(_functionBlock([_oneOccupiedSlot()]));
        await tester.pumpAndSettle();
        array.addError(StateManException('Failed to read value: BadNodeIdUnknown'));
        await tester.pumpAndSettle();
      });

      expect(about(lines, 'the batchArray node failed'), hasLength(2),
          reason: 'a belt that drops out, comes back and drops out again is '
              'the case most worth seeing, so the gate is reset by a value');
    });
  });

  group('config', () {
    test('the new keys survive a JSON round trip', () {
      final config = _config(
        batchArrayKey: _arrayKey,
        batchLengthKey: _recipeKey,
      );

      final restored = ConveyorConfig.fromJson(config.toJson());

      expect(restored.batchesKey, _settingsKey);
      expect(restored.batchArrayKey, _arrayKey);
      expect(restored.batchLengthKey, _recipeKey);
    });

    test('the roller variant carries them too', () {
      final config = RollerConveyorConfig(
        key: _driveKey,
        batchesKey: _settingsKey,
        batchArrayKey: _arrayKey,
        batchLengthKey: _recipeKey,
      )..size = const RelativeSize(width: 1.0, height: 1.0);

      final restored = RollerConveyorConfig.fromJson(config.toJson());

      expect(restored.batchArrayKey, _arrayKey);
      expect(restored.batchLengthKey, _recipeKey);
    });

    test('a config written before these fields existed still loads', () {
      final json = _config().toJson()
        ..remove('batchArrayKey')
        ..remove('batchLengthKey');

      final restored = ConveyorConfig.fromJson(json);

      expect(restored.batchesKey, _settingsKey);
      expect(restored.batchArrayKey, isNull);
      expect(restored.batchLengthKey, isNull,
          reason: 'the new keys are additive, so an existing page still '
              'loads; it draws no batches until the array key is bound');
    });

    test('both new keys are reported as keys the asset depends on', () {
      final keys = _config(
        batchArrayKey: _arrayKey,
        batchLengthKey: _recipeKey,
      ).allKeys;

      expect(keys, containsAll([_driveKey, _settingsKey, _arrayKey, _recipeKey]),
          reason: 'anything asking which keys a page needs — unused-key '
              'cleanup, for one — must see these');
    });
  });
}
