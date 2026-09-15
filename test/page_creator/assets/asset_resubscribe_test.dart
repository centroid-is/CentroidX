// No asset re-opens its PLC subscriptions when it is merely redrawn.
//
// Every asset that reads a key used to build its stream inside `build`, so
// `StreamBuilder` was handed a new stream object on every rebuild — and a new
// object means cancel the old subscription and open a fresh one. Resizing a
// window rebuilds continuously, and so does dragging an asset around the page
// editor. Measured on the plant HMI while a window edge was dragged: ~130 KiB
// of log a second against nothing once the mouse stopped, and a window that
// lagged the mouse.
//
// This drives each asset through twenty frames of a resize and asserts that
// what reaches StateMan does not move.
//
// It also catches the subtler way of getting this wrong. `keyStreamProvider`
// is auto-disposed, so it stays alive only while something *watches* it — and
// a `ref.watch` is only a watch when it happens during that widget's own
// build. Reading it from inside a `StreamBuilder`'s builder instead, which
// belongs to a different element, registers nothing: the dependency lapses
// and the shared stream is disposed underneath the asset. Rendering each one
// for real is what shows the difference.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/common.dart' show BaseAsset;
import 'package:tfc/page_creator/assets/conveyor_gate.dart';
import 'package:tfc/page_creator/assets/elcab.dart';
import 'package:tfc/page_creator/assets/led.dart';
import 'package:tfc/page_creator/assets/number.dart';
import 'package:tfc/page_creator/assets/text.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// Counts what actually reaches StateMan.
class _CountingStateMan extends Fake implements StateMan {
  final Map<String, int> subscribes = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    subscribes[key] = (subscribes[key] ?? 0) + 1;
    return Stream<DynamicValue>.value(DynamicValue(value: true))
        .asBroadcastStream();
  }

  int get total => subscribes.values.fold(0, (a, b) => a + b);
}

/// Holds the asset at a size the test can change, without rebuilding the
/// `ProviderScope` around it — re-creating the providers each pump would be
/// measuring the harness rather than the asset.
class _Harness extends StatelessWidget {
  const _Harness({required this.stateMan, required this.size, required this.child});

  final _CountingStateMan stateMan;
  final ValueNotifier<Size> size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [stateManProvider.overrideWith((ref) async => stateMan)],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<Size>(
              valueListenable: size,
              builder: (context, value, _) => SizedBox(
                width: value.width,
                height: value.height,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  /// Renders [config]'s widget, settles it, then drives twenty frames of a
  /// window being dragged and reports what reached StateMan.
  Future<({int settled, int afterResize})> resize(
      WidgetTester tester, BaseAsset config) async {
    final stateMan = _CountingStateMan();
    final size = ValueNotifier(const Size(300, 160));
    await tester.pumpWidget(_Harness(
      stateMan: stateMan,
      size: size,
      child: Builder(builder: (context) => config.build(context)),
    ));
    await tester.pumpAndSettle();
    final settled = stateMan.total;

    for (var frame = 1; frame <= 20; frame++) {
      size.value = Size(300 + frame * 5.0, 160 + frame * 2.0);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    return (settled: settled, afterResize: stateMan.total);
  }

  final cases = <String, BaseAsset Function()>{
    'Led': () => LEDConfig(key: 'IO.Led'),
    'ElCab': () => ElCabConfig(key: 'IO.Door'),
    'Number': () => NumberConfig(key: 'IO.Value'),
    'Text': () => TextAssetConfig(textContent: r'flow is $IO.Flow'),
    'ConveyorGate': () => ConveyorGateConfig()
      ..stateKey = 'Gate.State'
      ..forceOpenFeedbackKey = 'Gate.ForcedOpen'
      ..forceCloseFeedbackKey = 'Gate.ForcedClosed',
  };

  group('a resize does not re-open an asset\'s subscriptions', () {
    cases.forEach((name, make) {
      testWidgets(name, (tester) async {
        final counts = await resize(tester, make());
        expect(counts.settled, greaterThan(0),
            reason: '$name subscribed to nothing — the case proves nothing');
        expect(counts.afterResize, counts.settled,
            reason: 'before this change $name re-subscribed once per frame');
      });
    });
  });

  testWidgets('a gate reads its force feedback as the gate, not as its builder',
      (tester) async {
    // The nested `StreamBuilder` belongs to a different element, so reading
    // the shared streams from inside it would register no dependency at all
    // and let them be disposed. Both feedback keys have to be subscribed, and
    // stay subscribed, while the gate is on screen.
    final config = ConveyorGateConfig()
      ..stateKey = 'Gate.State'
      ..forceOpenFeedbackKey = 'Gate.ForcedOpen'
      ..forceCloseFeedbackKey = 'Gate.ForcedClosed';
    final stateMan = _CountingStateMan();
    final size = ValueNotifier(const Size(300, 160));
    await tester.pumpWidget(_Harness(
      stateMan: stateMan,
      size: size,
      child: Builder(builder: (context) => config.build(context)),
    ));
    await tester.pumpAndSettle();

    expect(stateMan.subscribes.keys,
        containsAll(['Gate.State', 'Gate.ForcedOpen', 'Gate.ForcedClosed']));
    expect(stateMan.subscribes.values, everyElement(1));
  });
}
