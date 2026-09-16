// A wagon answers a tap by the region it was painted in — and the traverse
// drive used to have no region at all.
//
// BUG: `ConveyorPainter.hitTest` accepted a wagon tap anywhere inside
// `wagonRect`, which is `beltRect.expandToInclude(_chassisRect)`. Subtract
// the belt from that and what is left is exactly the two `overhang`-wide
// bumper strips either side — which are exactly `safetyEdgeRect(left:)` and
// `safetyEdgeRect(left: false)`. The dispatch tested the two edges first and
// returned, then offered the motor "anything not on the belt". With both
// safety-edge keys bound there was nothing in that set: the traverse drive's
// pane could not be opened at all, on any pixel.
//
// FIX: the rail band — full box width, the strip of track ink `_paintTrack`
// draws — is the traverse drive's target. It is painted ink rather than dead
// space, so claiming it keeps the file's rule ("claim only the painted belt,
// not the whole box") while giving the motor a target the length of the run,
// and it leaves the bumpers drawn and tapped exactly as they were.

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/sensor.dart' show SensorFbFields;
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc_dart/core/state_man.dart';

const _driveKey = 'line1.wagon1.belt';
const _motorKey = 'line1.wagon1.traverse';
const _leftKey = 'line1.wagon1.edgeLeft';
const _rightKey = 'line1.wagon1.edgeRight';

class _WagonStateMan extends Fake implements StateMan {
  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    if (key == _leftKey || key == _rightKey) {
      return Stream<DynamicValue>.value(
          DynamicValue.fromMap(LinkedHashMap<String, dynamic>.from({
        SensorFbFields.output: false,
        SensorFbFields.fault: false,
      })));
    }
    // Plain-bool drives: running, and with no frequency there is no
    // animation for `pumpAndSettle` to wait on.
    return Stream<DynamicValue>.value(DynamicValue(value: true));
  }
}

/// The box the wagon is laid out in. Half the 800x600 test window, so the
/// painter's resolved size equals the `SizedBox` — the same arrangement
/// `conveyor_hit_test_test.dart` uses.
const _box = Size(400, 300);
const _relSize = RelativeSize(width: 0.5, height: 0.5);

Widget _wrap(ConveyorConfig config) => ProviderScope(
      overrides: [
        stateManProvider.overrideWith((ref) async => _WagonStateMan()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _box.width,
              height: _box.height,
              child: Conveyor(config),
            ),
          ),
        ),
      ),
    );

ConveyorPainter _painterOf(WidgetTester tester) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter is ConveyorPainter) return painter;
  }
  fail('no ConveyorPainter was rendered');
}

void main() {
  ConveyorConfig wagon({bool bindEdges = true}) => ConveyorConfig(
        key: _driveKey,
        onRails: true,
        wagonMotorKey: _motorKey,
        safetyLeftKey: bindEdges ? _leftKey : null,
        safetyRightKey: bindEdges ? _rightKey : null,
      )..size = _relSize;

  /// Taps [local] (in the conveyor's own coordinates) and answers the key of
  /// whatever pane that opened, or null if nothing did.
  ///
  /// The pane's id is `conveyor:<identity>:<key>`, so the tail names the
  /// device whose handler ran. Read straight after the tap and before the
  /// pane's body is pumped: this test is about which region routed the tap,
  /// and the panes themselves are covered by their own tests — several of
  /// them want providers (access templates, the collector) that have nothing
  /// to do with hit testing.
  Future<String?> tapAndReadPane(WidgetTester tester, Offset local) async {
    closeSidePane(immediate: true);
    final topLeft = tester.getTopLeft(find.byType(Conveyor));
    await tester.tapAt(topLeft + local);
    final id = SidePaneHost.openId;
    closeSidePane(immediate: true);
    await tester.pump();
    // Whatever the pane body needed to build is not this test's subject.
    tester.takeException();
    return id?.split(':').last;
  }

  Future<ConveyorPainter> pumpWagon(WidgetTester tester,
      {bool bindEdges = true}) async {
    await tester.pumpWidget(_wrap(wagon(bindEdges: bindEdges)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return _painterOf(tester);
  }

  testWidgets('with both safety edges bound the traverse drive is reachable',
      (tester) async {
    final painter = await pumpWagon(tester);
    final rail = painter.railBandRect(_box)!;
    final wagonRect = painter.wagonRect(_box);

    // A point on the rail, clear of the carriage — the empty run ahead of
    // the wagon.
    final probe = Offset(wagonRect.right + 20, rail.center.dy);
    expect(_box.contains(probe) && !wagonRect.contains(probe), isTrue,
        reason: 'test setup: the probe must be on bare rail');

    expect(await tapAndReadPane(tester, probe), _motorKey,
        reason: 'before the fix every pixel off the belt was already claimed '
            'by a safety edge, so the traverse drive had no target at all');
  });

  testWidgets('each region opens the device that is painted there',
      (tester) async {
    final painter = await pumpWagon(tester);
    final rail = painter.railBandRect(_box)!;
    final belt = painter.beltRect(_box);
    final left = painter.safetyEdgeRect(_box, left: true)!;
    final right = painter.safetyEdgeRect(_box, left: false)!;

    expect(await tapAndReadPane(tester, belt.center), _driveKey);
    expect(await tapAndReadPane(tester, left.center), _leftKey);
    expect(await tapAndReadPane(tester, right.center), _rightKey);
    expect(await tapAndReadPane(tester, Offset(10, rail.center.dy)),
        _motorKey);
  });

  testWidgets('the empty box above and below the track stays inert',
      (tester) async {
    final painter = await pumpWagon(tester);
    final rail = painter.railBandRect(_box)!;
    final wagonRect = painter.wagonRect(_box);

    for (final probe in [
      const Offset(10, 4),
      Offset(10, _box.height - 4),
    ]) {
      expect(rail.contains(probe) || wagonRect.contains(probe), isFalse,
          reason: 'test setup: the probe must be off both rail and wagon');
      expect(await tapAndReadPane(tester, probe), isNull,
          reason: 'dead space has to fall through so assets behind the '
              'conveyor stay reachable');
    }
  });

  testWidgets('an unbound bumper still answers for the traverse drive',
      (tester) async {
    // The bumper is part of the carriage. With no edge key on it there is
    // nothing else it could mean, and that was the behaviour before this
    // change — only the both-edges-bound case was broken.
    final painter = await pumpWagon(tester, bindEdges: false);
    final left = painter.safetyEdgeRect(_box, left: true)!;
    expect(await tapAndReadPane(tester, left.center), _motorKey);
  });

  test('the rail band is a region of its own, not a slice of the wagon', () {
    // The arithmetic the bug came down to: wagon minus belt is exactly the
    // two safety-edge strips, so the motor needs a region from somewhere
    // else entirely.
    final painter = ConveyorPainter(
      color: Colors.green,
      batches: const {},
      angle: 0,
      paintSize: _box,
      onRails: true,
      wagonPosition: 0.5,
      wagonFraction: 0.25,
    );
    final belt = painter.beltRect(_box);
    final wagonRect = painter.wagonRect(_box);
    final left = painter.safetyEdgeRect(_box, left: true)!;
    final right = painter.safetyEdgeRect(_box, left: false)!;
    final rail = painter.railBandRect(_box)!;

    // Across the carriage band — the rows where the wagon is actually
    // painted — everything that is not belt is one of the two bumper
    // strips. That is the whole of the bug: the two regions the dispatch
    // consumes first are the entire painted remainder of the wagon, so with
    // both edges bound the motor was left only the unpainted corner slivers
    // above and below the bumpers, which no operator would ever find.
    // Strictly inside: `Rect.contains` excludes the right and bottom edges,
    // so a probe exactly on `wagonRect.right` belongs to no region at all.
    for (var x = wagonRect.left + 0.5; x < wagonRect.right; x += 1) {
      for (var y = left.top + 0.5; y < left.bottom; y += 4) {
        final p = Offset(x, y);
        if (belt.contains(p)) continue;
        expect(left.contains(p) || right.contains(p), isTrue,
            reason: 'carriage minus belt must be exactly the bumper strips, '
                'which is why the motor had nothing usable left: $p');
      }
    }
    // The slivers, for the record: painted by neither the belt nor the
    // carriage, and all that the traverse drive had before the rail band.
    final sliver = Offset(left.center.dx, left.top - 4);
    expect(wagonRect.contains(sliver), isTrue);
    expect(belt.contains(sliver) || left.contains(sliver), isFalse);

    // And the rail runs well past the carriage at both ends, so there is
    // always somewhere to tap it.
    expect(rail.left, lessThan(wagonRect.left - 10));
    expect(rail.right, greaterThan(wagonRect.right + 10));
    expect(painter.hitTest(Offset(10, rail.center.dy)), isTrue,
        reason: 'the rail has to get past the hit test or the gesture '
            'detector never sees the tap');
    expect(painter.hitTest(const Offset(10, 4)), isFalse,
        reason: 'the empty box must stay inert');
  });
}
