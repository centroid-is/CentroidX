import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

// Regression test: "Simulate batches" toggle must start the simulation timer
// even when no PLC keys are configured.
//
// BUG: In the runtime Conveyor widget, the start/stop logic for the batch
// simulation timer was buried inside StreamBuilder.builder, which only fires
// once at least one stream has data. With no keys configured, the widget
// early-returned before reaching the simulation toggle check, so flipping
// `simulateBatches` had no visible effect.
//
// We verify behavior by reaching into the painter's `batches` map: the timer
// inserts a Batch on its first tick, so a non-empty map after pumping a few
// frames proves the simulation timer is running.

/// Walks the rendered tree from [tester] looking for a [CustomPaint] whose
/// painter exposes a `batches` field (i.e. the internal _ConveyorPainter).
/// Returns the painter or null if not found.
dynamic _findConveyorPainter(WidgetTester tester) {
  final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
  for (final cp in paints) {
    final painter = cp.painter;
    if (painter == null) continue;
    // Duck-typed access; _ConveyorPainter is library-private.
    try {
      final dyn = painter as dynamic;
      final batches = dyn.batches;
      if (batches is Map) return painter;
    } catch (_) {
      // Wrong painter type — keep looking.
    }
  }
  return null;
}

Widget _wrap(ConveyorConfig config, {StateMan? stateMan}) {
  return ProviderScope(
    overrides: [
      // No real StateMan — provider future will not complete, but the
      // Conveyor widget should still react to the simulateBatches flag.
      if (stateMan == null)
        stateManProvider.overrideWith(
          (ref) => throw StateError('No StateMan in tests'),
        )
      else
        stateManProvider.overrideWith((ref) async => stateMan),
    ],
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
}

/// Fake StateMan that emits a single canned batches DynamicValue (matching the
/// shape `_updateBatches` expects: p_stat_Length + p_stat_Batches[xOccupied,
/// position]). All slots are unoccupied so a naive `_updateBatches` call would
/// REMOVE the simulator's `'0'` batch entry, defeating the simulation.
class _PreviewBatchesStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    final dv = DynamicValue();
    dv['p_stat_Length'] = 1000.0;
    // Two unoccupied slots — _updateBatches would call _batches.remove('0')
    // and remove('1') on every emission, wiping the simulator's batch.
    final slot0 = DynamicValue();
    slot0['xOccupied'] = false;
    slot0['position'] = 0.0;
    final slot1 = DynamicValue();
    slot1['xOccupied'] = false;
    slot1['position'] = 500.0;
    dv['p_stat_Batches'] = DynamicValue.fromList([slot0, slot1]);
    return Stream<DynamicValue>.value(dv);
  }
}

void main() {
  testWidgets(
    'simulateBatches=true with no PLC keys still starts the simulation timer',
    (tester) async {
      final config = ConveyorConfig(simulateBatches: true)
        ..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(_wrap(config));

      // First frame: timer should be scheduled but hasn't ticked yet.
      // Pump a few frames to allow the 20ms periodic timer to fire.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final painter = _findConveyorPainter(tester);
      expect(painter, isNotNull,
          reason: 'Could not locate _ConveyorPainter in widget tree');

      final batches = (painter as dynamic).batches as Map;
      expect(batches.isNotEmpty, isTrue,
          reason:
              'simulateBatches=true must populate the batches map even with no PLC keys');
    },
  );

  testWidgets(
    'simulateBatches=false leaves the batches map empty',
    (tester) async {
      final config = ConveyorConfig(simulateBatches: false)
        ..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(_wrap(config));

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final painter = _findConveyorPainter(tester);
      expect(painter, isNotNull);
      final batches = (painter as dynamic).batches as Map;
      expect(batches, isEmpty,
          reason:
              'simulateBatches=false must not populate the batches map');
    },
  );

  testWidgets(
    'simulateBatches=true overrides preview-key snapshot data driving the painter',
    (tester) async {
      // batchesKey is configured AND the StateMan emits real (preview) data
      // with unoccupied slots — without the fix, _updateBatches() inside the
      // StreamBuilder.builder wipes the simulator's batches every emission.
      final config = ConveyorConfig(
        batchesKey: 'preview',
        simulateBatches: true,
      )..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(_wrap(config, stateMan: _PreviewBatchesStateMan()));

      // Allow the StateMan future + stream to flush, then let the simulation
      // timer tick.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final painter = _findConveyorPainter(tester);
      expect(painter, isNotNull);
      final batches = (painter as dynamic).batches as Map;
      expect(batches.isNotEmpty, isTrue,
          reason:
              'simulateBatches must drive the painter even when batchesKey '
              'emits real (preview) data — simulation should override the '
              'incoming snapshot, not be clobbered by it');
    },
  );

  testWidgets(
    'simulateBatches keeps simulating when only batchesKey is configured but no data arrives',
    (tester) async {
      // batchesKey present, but stateManProvider throws so no stream data
      // ever arrives. Simulation toggle must still drive the painter.
      final config = ConveyorConfig(
        batchesKey: 'irrelevant',
        simulateBatches: true,
      )..size = const RelativeSize(width: 1.0, height: 1.0);

      await tester.pumpWidget(_wrap(config));

      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final painter = _findConveyorPainter(tester);
      expect(painter, isNotNull);
      final batches = (painter as dynamic).batches as Map;
      expect(batches.isNotEmpty, isTrue,
          reason:
              'simulateBatches must run regardless of whether stream data has arrived');
    },
  );
}

