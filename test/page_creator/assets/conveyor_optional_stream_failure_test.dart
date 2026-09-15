import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

// Regression test: a failing OPTIONAL stream must not take the conveyor down.
//
// BUG (2026-08-18, production): every conveyor on one page
// rendered as disconnected (grey), while conveyors on another page on the SAME
// three PLCs, over the SAME sessions, were fine.
//
// The conveyor combines drive + batches + frequency + trip with
// CombineLatestStream, which propagates an error from ANY input, and the
// builder turns `snapshot.hasError` straight into the disconnected visual.
// So binding `batchesKey` to a node the PLC answered with BadDeviceFailure
// blanked the whole asset even though its drive key was healthy and reading
// all along. The wet-area conveyors have no `batchesKey`, which is why they
// were untouched -- and what identified the mechanism.
//
// The same line has a quieter second failure: CombineLatest does not emit
// until EVERY input has produced a first value, so an optional stream that
// merely stays silent blanks the asset just as effectively as one that
// errors.
//
// `key` (the drive) stays fatal on purpose: without it the conveyor really
// has no state, and grey is the honest answer.

/// A conveyor is "disconnected" when the builder took its error/no-data
/// path, which is exactly when [ConveyorPainter.showExclamation] is set.
///
/// Do NOT test this by comparing the painter colour to [Colors.grey]: the
/// disconnected colour is `HmiStateColors.of(context).grey`, which under a
/// bare `MaterialApp` falls back to Solarized `base1` and never equals
/// `Colors.grey`. Such a check reads "connected" for every rendered
/// conveyor and passes whether or not the bug is fixed.
bool _isDisconnected(WidgetTester tester) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter is ConveyorPainter) return painter.showExclamation;
  }
  return true; // no conveyor painter at all == nothing rendered
}

/// Healthy drive, exploding batches: the exact production shape.
class _DriveOkBatchesFailStateMan extends Fake implements StateMan {
  _DriveOkBatchesFailStateMan({
    required this.driveKey,
    required this.batchesKey,
    this.batchesSilent = false,
  });

  final String driveKey;
  final String batchesKey;

  /// When true the batches stream never emits and never errors, exercising
  /// the "CombineLatest waits for every input" half of the bug.
  final bool batchesSilent;

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key == driveKey) {
      final dv = DynamicValue();
      dv['p_stat_State'] = 2;
      dv['p_stat_Frequency'] = 50.0;
      return Stream<DynamicValue>.value(dv);
    }
    if (key == batchesKey) {
      if (batchesSilent) return const Stream<DynamicValue>.empty();
      // What the PLC actually said.
      return Stream<DynamicValue>.error(
          StateManException('Failed to read value: BadDeviceFailure'));
    }
    return const Stream<DynamicValue>.empty();
  }
}

Widget _wrap(ConveyorConfig config, StateMan stateMan) {
  return ProviderScope(
    overrides: [
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

void main() {
  ConveyorConfig configWith({String? batchesKey}) => ConveyorConfig(
        key: 'Line1.Belt2.Drive',
        batchesKey: batchesKey,
      )..size = const RelativeSize(width: 1.0, height: 1.0);

  testWidgets(
    'a batchesKey that errors does not disconnect a conveyor whose drive is healthy',
    (tester) async {
      final config = configWith(batchesKey: 'Line1.Belt2.Batches');
      await tester.pumpWidget(_wrap(
        config,
        _DriveOkBatchesFailStateMan(
          driveKey: 'Line1.Belt2.Drive',
          batchesKey: 'Line1.Belt2.Batches',
        ),
      ));
      await tester.pumpAndSettle();

      expect(_isDisconnected(tester), isFalse,
          reason: 'BadDeviceFailure on the decorative batches stream greyed '
              'out a conveyor whose drive key was reading fine');
    },
  );

  testWidgets(
    'a batchesKey that never reports does not disconnect the conveyor either',
    (tester) async {
      final config = configWith(batchesKey: 'Line1.Belt2.Batches');
      await tester.pumpWidget(_wrap(
        config,
        _DriveOkBatchesFailStateMan(
          driveKey: 'Line1.Belt2.Drive',
          batchesKey: 'Line1.Belt2.Batches',
          batchesSilent: true,
        ),
      ));
      await tester.pumpAndSettle();

      expect(_isDisconnected(tester), isFalse,
          reason: 'CombineLatest withheld every frame because one optional '
              'stream had not produced a first value');
    },
  );

  testWidgets(
    'the drive key is still fatal — no key data means the conveyor is grey',
    (tester) async {
      final config = configWith();
      await tester.pumpWidget(_wrap(
        config,
        // Drive key resolves to nothing at all.
        _DriveOkBatchesFailStateMan(driveKey: 'other', batchesKey: 'unused'),
      ));
      await tester.pumpAndSettle();

      expect(_isDisconnected(tester), isTrue,
          reason: 'a conveyor with no drive state must still read as '
              'disconnected — that part was never the bug');
    },
  );
}
