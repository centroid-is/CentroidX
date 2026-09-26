// Rebuilding a conveyor must not re-open its PLC subscriptions.
//
// The conveyor assembled its streams inside `build`, so `StreamBuilder` was
// handed a brand-new stream object every time the widget rebuilt. A new
// object means cancel the old subscription and open a fresh one. Resizing the
// window rebuilds continuously — so does dragging an asset around the page
// editor — and every conveyor on the page dropped and re-made all of its
// subscriptions once a frame.
//
// What that cost, measured on the plant HMI:
//
//   * ~130 KiB of log a second while a window edge was being dragged, against
//     nothing at all once the mouse stopped. The app log had reached 1.5 GB.
//   * StateMan's retry ladder never advanced. It climbs 1s, 10s, 60s, 600s and
//     then logs only every tenth attempt, so a key bound to a node the PLC
//     does not have should cost about six lines an hour. Every restart put it
//     back at the beginning: across a 4 MB slice of log, attempts 1 through 4
//     appeared 590 times and attempt 5 never once.
//   * A window that visibly lagged the mouse, because each frame asked the
//     server for a fresh set of monitored items and threw away the ones it
//     had made a frame earlier.
//
// The visible symptom in the log is a tight cycle, per key, per frame:
//
//     listener added (count=1) → listener removed (count=0)
//       → no listeners left, starting 600s idle timer → listener added …
//
// So: one subscription per key, held across rebuilds, and re-made only when
// the conveyor is actually pointed at different keys.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/providers/state_man.dart' show stateManProvider;
import 'package:tfc_dart/core/state_man.dart' show StateMan;

/// Counts how many times each key is subscribed to, and how many listeners
/// each handed-out stream currently has.
class _CountingStateMan extends Fake implements StateMan {
  final Map<String, int> subscribes = {};
  final Map<String, int> listeners = {};

  @override
  Future<Stream<DynamicValue>> subscribe(String key) async {
    subscribes[key] = (subscribes[key] ?? 0) + 1;
    late StreamController<DynamicValue> controller;
    controller = StreamController<DynamicValue>(
      onListen: () {
        listeners[key] = (listeners[key] ?? 0) + 1;
        controller.add(DynamicValue(value: true));
      },
      onCancel: () => listeners[key] = (listeners[key] ?? 0) - 1,
    );
    return controller.stream;
  }
}

/// The tree under test, pumped once.
///
/// The `ProviderScope` and its overrides are built a single time and then left
/// alone: a resize does not re-create the app's providers, and a harness that
/// re-created them on every pump would be measuring its own churn rather than
/// the widget's.
class _Harness extends StatelessWidget {
  const _Harness({required this.stateMan, required this.view});

  final _CountingStateMan stateMan;
  final ValueNotifier<({Size size, ConveyorConfig config})> view;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        stateManProvider.overrideWith((ref) async => stateMan),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<({Size size, ConveyorConfig config})>(
              valueListenable: view,
              builder: (context, value, _) => SizedBox(
                width: value.size.width,
                height: value.size.height,
                child: Conveyor(value.config),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  ConveyorConfig config() => ConveyorConfig(key: 'CV.Drive')
    ..runningKey = 'CV.Running'
    ..frequencyKey = 'CV.Frequency';

  /// Pumps the harness and returns the knob that drives it.
  Future<ValueNotifier<({Size size, ConveyorConfig config})>> pump(
      WidgetTester tester, _CountingStateMan stateMan,
      {ConveyorConfig? initial}) async {
    final view = ValueNotifier((
      size: const Size(400, 120),
      config: initial ?? config(),
    ));
    await tester.pumpWidget(_Harness(stateMan: stateMan, view: view));
    await tester.pumpAndSettle();
    return view;
  }

  testWidgets('resizing the window does not re-open the subscriptions',
      (tester) async {
    final stateMan = _CountingStateMan();
    final view = await pump(tester, stateMan);

    final settled = Map<String, int>.from(stateMan.subscribes);
    expect(settled.keys,
        containsAll(['CV.Drive', 'CV.Running', 'CV.Frequency']));
    expect(settled.values, everyElement(1),
        reason: 'one subscription per key to begin with');

    // Twenty frames of a window edge being dragged.
    for (var frame = 1; frame <= 20; frame++) {
      view.value =
          (size: Size(400 + frame * 7.0, 120 + frame * 3.0), config: view.value.config);
      await tester.pump();
    }

    expect(stateMan.subscribes, settled,
        reason: 'a resize re-opened subscriptions; before this change each of '
            'these counts climbed by one per frame');
    expect(stateMan.listeners.values, everyElement(lessThanOrEqualTo(1)),
        reason: 'and never held more than one listener per key at a time');

    await tester.pumpAndSettle();
  });

  testWidgets('nor does a rebuild that changes nothing at all', (tester) async {
    final stateMan = _CountingStateMan();
    final view = await pump(tester, stateMan);
    final settled = Map<String, int>.from(stateMan.subscribes);

    for (var i = 0; i < 10; i++) {
      view.value = (size: view.value.size, config: view.value.config);
      view.notifyListeners();
      await tester.pump();
    }

    expect(stateMan.subscribes, settled);
    await tester.pumpAndSettle();
  });

  testWidgets('but pointing the conveyor at a different key does',
      (tester) async {
    // The cache is keyed on what is actually read, so rebinding in the page
    // editor still takes effect — otherwise this would quiet the log at the
    // cost of an asset that ignores its own configuration.
    final stateMan = _CountingStateMan();
    final view = await pump(tester, stateMan);
    expect(stateMan.subscribes['CV.Drive'], 1);

    view.value = (
      size: view.value.size,
      config: ConveyorConfig(key: 'CV.OtherDrive')
        ..runningKey = 'CV.Running'
        ..frequencyKey = 'CV.Frequency',
    );
    await tester.pumpAndSettle();

    expect(stateMan.subscribes['CV.OtherDrive'], 1,
        reason: 'the newly bound key is subscribed');
    // And only that one. The subscription belongs to the key rather than to
    // the widget drawing it, so the keys that did not change are not
    // disturbed by one that did.
    expect(stateMan.subscribes['CV.Running'], 1,
        reason: 'rebinding one key must not re-open the others');
    await tester.pumpAndSettle();
  });

  testWidgets('and so does adding a key that was not bound before',
      (tester) async {
    final stateMan = _CountingStateMan();
    final view =
        await pump(tester, stateMan, initial: ConveyorConfig(key: 'CV.Drive'));
    expect(stateMan.subscribes.containsKey('CV.Trip'), isFalse);

    view.value = (
      size: view.value.size,
      config: ConveyorConfig(key: 'CV.Drive')..tripKey = 'CV.Trip',
    );
    await tester.pumpAndSettle();

    expect(stateMan.subscribes['CV.Trip'], 1);
    await tester.pumpAndSettle();
  });
}
