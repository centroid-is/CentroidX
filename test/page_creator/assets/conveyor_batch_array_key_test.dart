import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541.dart' show DynamicValue;

// The batch array moved, PLC-side, out of the conveyor's settings struct and
// into the conveyor's own function block. On a line downloaded before the move
// the length and the array are two members of ONE node; after it they are two
// different nodes, and only the length is still on the settings struct.
//
// Lines are downloaded at different times, so both layouts are live at once
// and one page can show both. Hence an extra optional key rather than a
// migration: unset, the overlay reads what it always read.
//
// Why this needed catching rather than waiting for a bug report: the batch
// stream is optional, and `_optional` swallows its error to null on purpose
// (see the comment block above it — a dead decorative node must not grey out a
// conveyor whose drive is healthy). So a page still pointed at the old member
// does not go red, does not log, and does not blank: the overlay just stops
// being drawn, on an asset that otherwise looks entirely correct.
//
// Fixtures here are deliberately neutral: `line.conveyor.*`, not any real tag.

const _driveKey = 'line.conveyor.drive';
const _settingsKey = 'line.conveyor.settings';
const _arrayKey = 'line.conveyor.batch_array';
const _recipeKey = 'line.recipe';

const _beltLength = 1000.0;
const _slotPosition = 250.0;

/// One element of the batch array. The member names are unchanged by the
/// move — only the node the array hangs off changed — which is the whole
/// reason one decoder can serve both layouts.
DynamicValue _slot({required bool occupied, required double position}) {
  final slot = DynamicValue();
  slot['xOccupied'] = occupied;
  slot['position'] = position;
  return slot;
}

DynamicValue _oneOccupiedSlot() =>
    _slot(occupied: true, position: _slotPosition);

/// The conveyor settings struct. [slots] present is the old layout, where the
/// array sits beside the length; absent is the refactored one.
DynamicValue _settings({List<DynamicValue>? slots}) {
  final dv = DynamicValue();
  dv['p_stat_Length'] = _beltLength;
  if (slots != null) dv['p_stat_Batches'] = DynamicValue.fromList(slots);
  return dv;
}

/// The conveyor's function-block instance, which is where the array lives
/// after the move.
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
/// answers for a node that is not there.
class _MapStateMan extends Fake implements StateMan {
  _MapStateMan(this.values, {this.erroring = const <String>{}});

  final Map<String, DynamicValue> values;
  final Set<String> erroring;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
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
      'with no batch-array key the array is read from the settings node, '
      'exactly as before the key existed',
      (tester) async {
        await _pump(
          tester,
          _config(),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(slots: [_oneOccupiedSlot()]),
          }),
        );

        final batches = _batches(tester);
        expect(batches.keys, ['0']);
        expect(batches['0']!.start, closeTo(0.25, 1e-9));
        expect(batches['0']!.end, closeTo(0.75, 1e-9),
            reason: 'the pre-existing layout must keep reading the array out '
                'of the settings struct, at the historical 500 mm slot');
      },
    );

    testWidgets(
      'with the batch-array key set the array comes off its own node while '
      'the length still comes from the settings node',
      (tester) async {
        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            // Refactored PLC: settings carries the length and nothing else.
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
      'xOccupied and position decode to the same overlay under either layout',
      (tester) async {
        final slots = [
          _slot(occupied: true, position: 0),
          _slot(occupied: false, position: 300),
          _slot(occupied: true, position: 400),
        ];

        await _pump(
          tester,
          _config(),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(slots: slots),
          }),
        );
        final together = {
          for (final e in _batches(tester).entries)
            e.key: (start: e.value.start, end: e.value.end)
        };

        await _pump(
          tester,
          _config(batchArrayKey: _arrayKey),
          _MapStateMan({
            _driveKey: _drive(),
            _settingsKey: _settings(),
            _arrayKey: _functionBlock(slots),
          }),
        );
        final apart = {
          for (final e in _batches(tester).entries)
            e.key: (start: e.value.start, end: e.value.end)
        };

        expect(apart, together,
            reason: 'only the node moved — the element members did not, so '
                'both layouts must paint the same slots');
        // Index 1 was unoccupied, so it is absent from both.
        expect(together.keys, ['0', '2']);
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
      'a settings struct that no longer carries the array draws no overlay '
      'instead of throwing out of build',
      (tester) async {
        // The un-reconfigured page on a refactored line: the key still points
        // at the settings node, which reads fine but has no array member.
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
        _config(),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(slots: [_oneOccupiedSlot()]),
        }),
      );

      expect(_batches(tester)['0']!.end, closeTo(0.75, 1e-9),
          reason: '(250 + 500) / 1000 — unchanged for every page on disk');
    });

    testWidgets('falls back to 500 mm when the recipe node is dead',
        (tester) async {
      await _pump(
        tester,
        _config(batchLengthKey: _recipeKey),
        _MapStateMan(
          {
            _driveKey: _drive(),
            _settingsKey: _settings(slots: [_oneOccupiedSlot()]),
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
        _config(batchLengthKey: _recipeKey),
        _MapStateMan({
          _driveKey: _drive(),
          _settingsKey: _settings(slots: [_oneOccupiedSlot()]),
          _recipeKey: _recipe(0),
        }),
      );

      expect(_batches(tester)['0']!.end, closeTo(0.75, 1e-9));
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
          reason: 'the new keys are additive — an existing page is not '
              'migrated and behaves exactly as it did');
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
