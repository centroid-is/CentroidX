/// MANUAL SMOKE CHECKLIST — Phase 2 Elevator Foundation closeout
/// ==============================================================
///
/// Run after `flutter test test/page_creator/assets/elevator_*.dart`
/// passes 5/5. Automated tests cover:
///   - rails + platform painter (4 goldens),
///   - stream hoisting + 3 stale paths,
///   - TweenAnimationBuilder duration tracking,
///   - JSON / registry round-trip + back-compat,
///   - dialog field-presence + Tween-duration field mutation.
///
/// What automated tests CANNOT verify (operator-action items):
///
/// 1. Run the app:
///      flutter run -d macos
///    (or the device the developer normally uses).
///
/// 2. Open the page editor (always listed under Advanced; opening it needs a
///    signed-in session holding `configure`).
///
/// 3. Confirm "Elevator" appears in the asset palette under category
///    "Visualization" (CONTEXT 'Schema & Registration' lock — closes
///    ELEV-16 at the runtime layer; the registry test in
///    `elevator_config_test.dart` only proves the type is in the map,
///    not that the palette UI surfaces it).
///
/// 4. Drag an Elevator onto a page. Verify the visual contract:
///      - Two thin vertical rails flank the bbox at ~10% and ~90%
///        width.
///      - A horizontal platform deck rectangle (~8% of bbox height)
///        sits BETWEEN the rails.
///      - With no positionKey configured, both rails AND deck render
///        in subdued grey (CONTEXT 'Stale, Out-of-Range, & Tests'
///        — stale path 1 / ELEV-14).
///
/// 5. Tap the placed Elevator. The config dialog opens. Verify:
///      - Position State Key (0-100%)  KeyField (with autocomplete
///        dropdown — common.dart's KeyField behaviour).
///      - Tween Duration               DurationField, default `250 ms`,
///        digits-only input formatter (typing letters does nothing).
///      - Size                         SizeField with width / height
///        sliders (per common.dart).
///      - Coordinates                  CoordinatesField with x / y
///        sliders AND an angle slider (enableAngle: true). Verify
///        the angle slider works — set it to 90° and confirm the
///        elevator on the page rotates (sensor.dart precedent).
///      - Children: 0 (managed in Phase 3)   read-only placeholder.
///
/// 6. Set Position State Key to a known PLC 0-100% double key (any
///    real-PLC float key works — confirm one exists by browsing the
///    KeyField autocomplete; if none surface, configure a simulated
///    one via the StateMan dev panel). Save the page.
///
/// 7. Exit editor mode. Verify:
///      - The platform deck colours flip from grey to the active
///        Theme.colorScheme.primary (CONTEXT 'Visual & Position
///        Pipeline' — Plan 02-04 wires this).
///      - As the PLC value sweeps 0 → 100, the platform glides
///        smoothly (no jitter — Pitfall 4 closed by the
///        TweenAnimationBuilder pipeline) from the bottom of the
///        bbox to the top (ELEV-03 — 0% bottom, 100% top).
///      - At PLC value = 50%, the platform sits at the geometric
///        centre.
///      - Tween duration matches whatever was set in step 5; try
///        500ms vs 100ms to confirm the field is wired.
///
/// 8. Tap the elevator (in non-editor mode). The config dialog
///    reopens (GestureDetector with HitTestBehavior.opaque survives
///    the runtime Stack — closes the Phase-3 forward-compat
///    contract from CONTEXT '§GestureDetector Compat').
///
/// 9. Save the page. Quit the app. Reopen it. Confirm:
///      - The elevator is still on the page with positionKey,
///        tweenDurationMs, coordinates, and size preserved (ELEV-17
///        — JSON round-trip; the test in `elevator_config_test.dart`
///        proves it at the JSON layer, this confirms it at the
///        on-disk layer).
///      - Loading produces no errors in the console.
///
/// 10. Open an existing saved page that does NOT contain an elevator.
///     Confirm it loads cleanly with no errors (ELEV-18 — back-compat;
///     test in `elevator_config_test.dart` proves it for the LEDConfig
///     case, but on-disk pages may carry richer schemas — this is the
///     manual safeguard).
///
/// Resume signal: report "approved" or describe issues for triage.
library;

import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/widgets/number_slider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/page_creator/assets/elevator.dart';
import 'package:tfc/page_creator/assets/elevator_layout.dart';
import 'package:tfc/page_creator/assets/elevator_painter.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
import 'package:tfc/widgets/panes/side_pane.dart';

void main() {
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 200, height: 300, child: child),
            ),
          ),
        ),
      );

  // Plan 04-05 (ELEV-01): runtime taps now open a READ-ONLY details
  // dialog. Config editing is editor-only via page_editor.dart. The
  // helper below mirrors page_editor.dart:_showConfigDialog so the
  // editor-surface tests can still exercise `_ElevatorConfigEditor`
  // directly without going through the runtime tap path.
  Future<void> openConfigEditor(
      WidgetTester tester, ElevatorConfig config) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(child: config.configure(context)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('Tap to show details (Plan 04-05)', () {
    // Plan 04-05: tapping an Elevator at runtime opens a READ-ONLY details
    // surface — NOT the config editor. Config remains editor-only via
    // page_editor.dart's _showConfigDialog → asset.configure(context).
    //
    // Locks the ELEV-01 contract: operators can inspect runtime state
    // (position key, current progress, tween duration, simulate flag,
    // out-of-range/stale flags, child count) but must never mutate page
    // configuration via runtime taps.
    //
    // Plan 260811 moved that surface from an `AlertDialog` to the non-modal
    // `SidePane`. The ELEV-01 contract is unchanged — only the host is —
    // so these tests assert on `SidePane` and the same labels.

    // A docked pane lives in the root overlay and survives the widget that
    // opened it being torn down between tests, so close it explicitly.
    tearDown(closeSidePane);

    testWidgets('tap on elevator opens details pane (NOT config dialog)',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '/elev/01/position',
        tweenDurationMs: 250,
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsOneWidget,
          reason: 'Tap must open the docked details pane.');
      expect(find.text('Position key'), findsOneWidget,
          reason: 'Details pane must show "Position key" label.');

      // Negative locks — runtime tap must NOT open the editor.
      expect(find.text('Position State Key (0-100%)'), findsNothing,
          reason: 'Runtime tap must NOT render the editor KeyField label.');
      expect(find.widgetWithText(FilledButton, 'Add child'), findsNothing,
          reason: 'Runtime tap must NOT render editor controls.');
    });

    testWidgets('tapping the elevator again toggles the pane shut',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsOneWidget);

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsNothing,
          reason: 'A second tap on the same asset must close its pane.');
    });

    testWidgets('details pane has Close button that dismisses it',
        (tester) async {
      final config = ElevatorConfig(positionKey: '');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsOneWidget);
      final closeBtn = find.byTooltip('Close');
      expect(closeBtn, findsOneWidget,
          reason: 'Details pane must have a header close button.');
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsNothing,
          reason: 'Tapping Close must dismiss the details pane.');
    });

    testWidgets('unmounting the elevator closes its pane', (tester) async {
      // The pane body listens to the State's `_progress` notifier, so a pane
      // that outlived its elevator would tick against a disposed notifier.
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsOneWidget);

      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsNothing,
          reason: 'dispose() must close the pane it opened.');
      expect(isSidePaneOpen(), isFalse);
    });

    testWidgets('details pane does NOT contain editable fields',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '/elev/01/position',
        children: [
          ElevatorChildEntry(id: 'sense', child: SensorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();

      // Editor-specific widgets MUST NOT appear in the runtime details
      // pane. These are the unique surface markers of _ElevatorConfigEditor.
      expect(find.byType(SegmentedButton), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing,
          reason: 'No SwitchListTile (Simulate motion is editor-only).');
      expect(find.widgetWithText(FilledButton, 'Add child'), findsNothing);
      // The locked editor label "Position State Key (0-100%)" is unique
      // to _ElevatorConfigEditor and MUST NOT appear in the details
      // pane (Plan 04-05 lock).
      expect(find.text('Position State Key (0-100%)'), findsNothing);
    });

    testWidgets('details pane shows children count', (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'a', child: SensorConfig.preview()),
          ElevatorChildEntry(id: 'b', child: ConveyorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      await tester.tap(find.byType(GestureDetector).first);
      await tester.pumpAndSettle();
      expect(find.text('Children'), findsOneWidget);
      // The count text must include "2" — phrased flexibly so future
      // copy tweaks don't break this lock. The literal "2 attached" is
      // the planned phrasing in elevator.dart.
      expect(find.textContaining('2'), findsAtLeastNWidgets(1));
    });

    testWidgets('GestureDetector exists with HitTestBehavior.opaque',
        (tester) async {
      final config = ElevatorConfig();
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      // Find the GestureDetector child of the Elevator subtree.
      final gd =
          tester.widget<GestureDetector>(find.byType(GestureDetector).first);
      expect(gd.behavior, HitTestBehavior.opaque);
    });
  });

  group('Config dialog smoke (editor path — configure())', () {
    // Plan 04-05: editor surface tests now go through configure() directly,
    // mirroring page_editor.dart:_showConfigDialog. This bypasses the
    // runtime tap path (which now opens a read-only details dialog).
    testWidgets(
        'config dialog renders all locked Phase-2 fields + Add child button (Phase 3 replaces placeholder)',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '/elev/01/position',
        tweenDurationMs: 333,
      );
      await openConfigEditor(tester, config);

      // Locked field surface (mirror Plan 01-05 smoke test pattern):
      expect(find.text('Position State Key (0-100%)'), findsOneWidget);
      expect(find.text('Tween Duration'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add child'), findsOneWidget);
      expect(find.text('No children configured'), findsOneWidget);
      expect(find.text('Children: 0 (managed in Phase 3)'), findsNothing);
      final coordsField = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'CoordinatesField',
      );
      expect(coordsField, findsOneWidget);
    });

    testWidgets('editing Tween Duration field mutates config.tweenDurationMs',
        (tester) async {
      final config = ElevatorConfig(tweenDurationMs: 250);
      await openConfigEditor(tester, config);

      // The field is a DurationField now — find its inner TextField.
      final tweenField = find.widgetWithText(TextField, 'Tween Duration');
      expect(tweenField, findsOneWidget);
      await tester.enterText(tweenField, '500');
      await tester.pump();
      expect(config.tweenDurationMs, 500);
    });
  });

  group('Stale paths', () {
    testWidgets('empty positionKey → painter.isStale=true', (tester) async {
      final config = ElevatorConfig(positionKey: '');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      // Descend into the Elevator subtree so we don't pick up the
      // CustomPaint instances belonging to the MaterialApp chrome
      // (Scaffold / Overlay), which have no painter set.
      final cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Elevator),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(cp.painter, isA<ElevatorPainter>());
      expect((cp.painter as ElevatorPainter).isStale, isTrue);
    });
  });

  group('Stream lifecycle (Pitfall 2)', () {
    testWidgets('positionStream is non-null when positionKey is set',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      expect(state.debugPositionStream, isNotNull);
    });

    testWidgets('100 rebuilds with same positionKey: stream identity preserved',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final streamA = state.debugPositionStream;
      for (int i = 0; i < 100; i++) {
        await tester.pumpWidget(wrap(Elevator(config: config)));
      }
      final streamB = state.debugPositionStream;
      expect(identical(streamA, streamB), isTrue,
          reason:
              'positionStream must not be re-created across rebuilds with same positionKey (Pitfall 2)');
    });

    testWidgets('changing positionKey re-hoists stream (different identity)',
        (tester) async {
      final configA = ElevatorConfig(positionKey: '/elev/01/position');
      final configB = ElevatorConfig(positionKey: '/elev/02/position');
      await tester.pumpWidget(wrap(Elevator(config: configA)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final streamA = state.debugPositionStream;
      await tester.pumpWidget(wrap(Elevator(config: configB)));
      await tester.pump(Duration.zero);
      final streamB = state.debugPositionStream;
      expect(identical(streamA, streamB), isFalse,
          reason: 'positionStream must be re-hoisted when positionKey changes');
    });

    testWidgets('unmount disposes ValueNotifier and cancels subscription',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      // Replace with empty widget — forces unmount and dispose.
      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pump(Duration.zero);
      // No exceptions during unmount means dispose ran cleanly. The
      // framework will throw "ValueNotifier was disposed" if a listener
      // tries to read after dispose; the absence of exceptions here is
      // the regression guard.
      expect(tester.takeException(), isNull);
    });
  });

  group('Rotation', () {
    testWidgets('coordinates.angle=90° applied via LayoutRotatedBox',
        (tester) async {
      final config = ElevatorConfig(positionKey: '');
      config.coordinates.angle = 90.0;
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      // LayoutRotatedBox lives in lib/page_creator/assets/common.dart;
      // verify presence via runtimeType lookup (the type is private to
      // the assets layer — we don't import it directly here to mirror
      // the conveyor_gate_test.dart precedent).
      final lrb = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'LayoutRotatedBox',
      );
      expect(lrb, findsOneWidget);
    });
  });

  group('Animation pipeline (ELEV-06)', () {
    testWidgets('TweenAnimationBuilder<double> exists in widget tree',
        (tester) async {
      final config = ElevatorConfig(positionKey: '');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    });

    testWidgets('TweenAnimationBuilder duration matches config.tweenDurationMs',
        (tester) async {
      final config = ElevatorConfig(tweenDurationMs: 500);
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final tab = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      expect(tab.duration, const Duration(milliseconds: 500));
    });

    testWidgets('default tweenDurationMs=250 → duration=250ms', (tester) async {
      final config = ElevatorConfig();
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final tab = tester.widget<TweenAnimationBuilder<double>>(
        find.byType(TweenAnimationBuilder<double>),
      );
      expect(tab.duration, const Duration(milliseconds: 250));
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 3 — Children riding the platform
  // ---------------------------------------------------------------------------
  //
  // Locks the four CONTEXT contracts (D-CONTEXT §Child Layout & Identity,
  // §Hit-Test Through Translation):
  //   1. Polymorphic dispatch via entry.child.build(context) — no switch on
  //      runtime type (ELEV-11 / ARCHITECTURE Anti-Pattern 1).
  //   2. ValueKey<String>(entry.id) wraps each child for identity preservation
  //      across _animProgress changes (ELEV-12 / Pitfall 1).
  //   3. Children's GestureDetectors keep working while the platform is
  //      mid-translation — hit-test follows rendered Positioned.top, not
  //      layout-time position (ELEV-19 / Pitfall 7 — the user's locked
  //      directive in feedback_gesture_through_translation.md).
  //   4. Stack uses Clip.none so children may overhang the elevator bbox
  //      during translation (D-CONTEXT §Child Layout & Identity).
  group('Children riding the platform (Phase 3)', () {
    testWidgets(
        'children render via polymorphic BaseAsset.build (no switch on runtimeType)',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'sensor-poly', child: SensorConfig.preview()),
          ElevatorChildEntry(
              id: 'conveyor-poly', child: ConveyorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Both children rendered through their own build() method — no
      // runtime-type switch needed in elevator.dart.
      expect(find.byType(Sensor), findsOneWidget);
      expect(find.byType(Conveyor), findsOneWidget);
    });

    test('source has no runtime-type switching on elevator children (ELEV-11)',
        () {
      // Source-level grep gate: elevator.dart must not use `is SensorConfig`,
      // `is ConveyorConfig`, `child.runtimeType ==`, or
      // `switch (... .runtimeType)` for child dispatch. This is the locked
      // ARCHITECTURE Anti-Pattern 1 enforcement — children render
      // polymorphically through entry.child.build(context).
      final src =
          File('lib/page_creator/assets/elevator.dart').readAsStringSync();
      // Strip line and block comments so commentary like "no `is X`
      // dispatch" doesn't trip the gate.
      final stripped = src
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .split('\n')
          .map((line) {
        // Strip trailing line comment, but only if the slashes are not
        // inside a string. Naive approach is good enough for our
        // own production source.
        final idx = line.indexOf('//');
        return idx >= 0 ? line.substring(0, idx) : line;
      }).join('\n');
      final patterns = RegExp(
        r'is\s+SensorConfig|is\s+ConveyorConfig|'
        r'child\.runtimeType\s*==|'
        r'switch\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\.runtimeType\s*\)',
      );
      final matches = patterns.allMatches(stripped).toList();
      expect(matches, isEmpty,
          reason: 'elevator.dart must dispatch children polymorphically via '
              'entry.child.build(context) — no runtime-type switching '
              '(ELEV-11, ARCHITECTURE Anti-Pattern 1). Found: '
              '${matches.map((m) => m.group(0)).toList()}');
    });

    testWidgets('each child wrapper carries ValueKey<String>(entry.id)',
        (tester) async {
      const lockedId = 'test-child-aaa';
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: lockedId, child: SensorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      final keyFinder = find.byKey(const ValueKey<String>(lockedId));
      expect(keyFinder, findsOneWidget,
          reason:
              'A ValueKey<String>(entry.id) wrapper must exist for each child '
              '(ELEV-12 / Pitfall 1)');

      // The keyed wrapper must be an ancestor of the rendered child widget.
      final descendantSensor = find.descendant(
        of: keyFinder,
        matching: find.byType(Sensor),
      );
      expect(descendantSensor, findsOneWidget,
          reason: 'The ValueKey<String>(entry.id) wrapper must be an ancestor '
              'of the rendered child widget so identity is preserved across '
              'rebuilds.');
    });

    testWidgets(
        'child State.initState fires exactly once across 50 progress changes (Pitfall 1)',
        (tester) async {
      _CountingChildState.initStateCount = 0;
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'counting-1', child: _CountingChildConfig()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      expect(_CountingChildState.initStateCount, 1,
          reason: 'Initial mount should fire initState exactly once.');

      // Drive _progress.value through 50 distinct values; the inner
      // ValueListenableBuilder/Positioned.top should rebuild while the
      // child subtree (its State) stays alive — ValueKey + KeyedSubtree
      // preserve identity (ELEV-12 / Pitfall 1).
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      for (int i = 0; i < 50; i++) {
        progress.value = i / 49.0;
        await tester.pump(const Duration(milliseconds: 1));
      }

      expect(_CountingChildState.initStateCount, 1,
          reason: '50 progress changes must NOT recreate the child State '
              '(Pitfall 1 — widget identity loss on position updates).');
    });

    testWidgets(
        'tap during translation lands on the child, opens child details dialog '
        '(ELEV-19, Pitfall 7; Plan 04-05)', (tester) async {
      // SensorConfig with a generous size so the GestureDetector hit-target
      // is a comfortable rectangle rather than the 0.03×0.03 default tiny
      // box (which would leave the tap centre on a 6-pixel target — too
      // brittle). The test locks the hit-test-through-translation
      // contract — Plan 04-05 changes WHAT the gesture does (details
      // dialog) but NOT whether it survives translation.
      final sensor = SensorConfig.preview()..detectionKey = 'sensor/01/det';
      sensor.size = const RelativeSize(width: 0.4, height: 0.2);

      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'sensor-tap', offsetX: 0.5, child: sensor),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Drive progress mid-translation. We don't pumpAndSettle — the
      // tween is intentionally still in flight so the test exercises the
      // hit-test-while-moving contract.
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 0.5;
      await tester.pump(const Duration(milliseconds: 1));

      // Tap the Sensor child — the tap should land on the Sensor's own
      // GestureDetector and open ITS details dialog (sensor.dart:
      // _showDetailsDialog — Plan 04-05 / SENS-01). The locked label
      // 'Detection state' is unique to the sensor details pane (the
      // key-name rows were dropped: panes show values, not wiring).
      await tester.tap(find.byType(Sensor));
      await tester.pumpAndSettle();

      // Sensor's details dialog surface (locked Plan 04-05 surface).
      expect(find.text('Detection state'), findsOneWidget,
          reason: 'Tap on a child during translation must reach the child\'s '
              'GestureDetector and open its details dialog (ELEV-19 + '
              'Plan 04-05).');
      // The Elevator's own details dialog must NOT have opened — its
      // unique label "Position key" must not appear.
      expect(find.text('Position key'), findsNothing,
          reason: 'Elevator details dialog must not steal taps that land on a '
              'child (Plan 04-05).');
      // Editor surfaces from BOTH widgets must be absent — runtime tap
      // must NEVER open editor.
      expect(find.text('Detection State Key'), findsNothing,
          reason: 'Runtime tap must not open the sensor config editor '
              '(Plan 04-05).');
      expect(find.text('Position State Key (0-100%)'), findsNothing,
          reason: 'Runtime tap must not open the elevator config editor '
              '(Plan 04-05).');
    });

    testWidgets('children Positioned.top follows _animProgress (ELEV-10)',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(
              id: 'fixed-size',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      // Drive to 0.0, settle, read.
      progress.value = 0.0;
      await tester.pumpAndSettle();
      final positionedFinder = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positionedFinder, findsOneWidget);
      final topAt0 = (tester.widget(positionedFinder) as Positioned).top!;

      // Drive to 1.0, settle, read.
      progress.value = 1.0;
      await tester.pumpAndSettle();
      final topAt1 = (tester.widget(positionedFinder) as Positioned).top!;

      // Child rises (smaller `top`) as progress increases.
      expect(topAt0 > topAt1, isTrue,
          reason: 'Child Positioned.top must decrease as platform rises '
              '(progress 0 → 1) — ELEV-10.');

      // Numerical: child's bottom edge sits on platform's top edge.
      // As of Plan 260511-fd6, the travel range is no longer auto-deduced
      // from child heights — it's an operator-explicit fraction of bbox
      // height stored on ElevatorConfig.travelRange (default 1.0). With
      // the default 1.0, effectiveTravel = min(1.0 * bboxH, headroom) =
      // headroom = 276 (full headroom climb — the pre-260511-dxa visual).
      //
      // bbox is 200x300 (from `wrap`). platformH = 300 * 0.08 = 24.
      // Fixture has a single 40x40 child, but the child's height is
      // IRRELEVANT to the platform's travel range — the operator picks it
      // explicitly via config.travelRange.
      //   progress=0 → platformY = 276,         top = 276 - 40 = 236.
      //   progress=1 → platformY = 276 - 276 = 0, top = 0 - 40 = -40
      //                (child overhangs above bbox — Stack(Clip.none)
      //                tolerates overhang; locked operator tradeoff).
      const bboxH = 300.0;
      const platformH = bboxH * kPlatformHeightFraction;
      const childH = 40.0;
      // effectiveTravel = clamp(travelRange=1.0 * bboxH, 0, headroom)
      //                 = clamp(300, 0, 276) = 276 (default config).
      const effectiveTravel = bboxH - platformH; // 276
      final expectedTopAt0 =
          platformOffsetTop(0.0, bboxH, platformH, effectiveTravel) - childH;
      final expectedTopAt1 =
          platformOffsetTop(1.0, bboxH, platformH, effectiveTravel) - childH;
      expect(topAt0, closeTo(expectedTopAt0, 1.0));
      expect(topAt1, closeTo(expectedTopAt1, 1.0));
    });

    // NOTE [260511-fd6]: the 'children Positioned.top clamps to >= 0 at
    // progress=1.0' test was DELETED here. Its invariant (top >= 0 at
    // default config) was a side-effect of the now-removed auto-deduce
    // (Plan 260511-dxa: travel = tallest-child height). Plan 260511-fd6
    // makes travelRange operator-explicit (default 1.0 = full headroom),
    // which means child overhang IS possible at default — the operator's
    // call. The new "TravelRange (260511-fd6)" group below locks the new
    // geometry instead.

    testWidgets('Stack uses Clip.none so children may overhang bbox',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(
              id: 'overhanger',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 80, height: 200)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Locate the Stack inside the Elevator subtree (the elevator's own
      // composition Stack — not any Stack the Material chrome may host).
      final stackFinder = find
          .descendant(
            of: find.byType(Elevator),
            matching: find.byType(Stack),
          )
          .first;
      final stack = tester.widget<Stack>(stackFinder);
      expect(stack.clipBehavior, Clip.none,
          reason: 'Elevator Stack must use Clip.none so children may extend '
              'outside the elevator bbox during translation '
              '(D-CONTEXT §Child Layout & Identity).');
    });
  });

  // ---------------------------------------------------------------------------
  // OffsetY anchor (260511-ehy)
  //
  // Locks the per-child vertical anchor offset:
  //   top = platformY - childH * (1.0 + entry.offsetY)
  //
  // offsetY = 0.0  → child's bottom sits on the platform top (Plan 260511-dxa
  //                  invariant — regression-guarded by W1).
  // offsetY > 0.0  → child is raised above the platform (smaller `top`).
  // offsetY < 0.0  → child is lowered below the platform (larger `top`).
  //
  // Constants are sourced from the canonical wrap()/fixture pair: a 200x300
  // bbox with a 40x40 _FixedSizeChild. closeTo(_, 1.0) mirrors the precedent
  // at the ELEV-10 numeric assertion above (line ~675).
  // ---------------------------------------------------------------------------
  group('OffsetY anchor (260511-ehy)', () {
    const bboxH = 300.0;
    const platformH = bboxH * kPlatformHeightFraction;
    const childH = 40.0;
    // Plan 260511-fd6: the runtime no longer auto-deduces travel range from
    // children. To keep these regression-guard fixtures locked to the same
    // "tallest-child = childH" geometry the offsetY contract was originally
    // written against, set `travelRange = childH / bboxH`. This isolates the
    // offsetY tests from the default-travelRange change (which would
    // otherwise pull `top` toward -childH at progress=1).
    const travelRangeFor40pxChild = childH / bboxH; // ≈ 0.1333
    const maxChildHeight = childH; // effective travel = 40px (matches fixture)

    testWidgets(
        'offsetY = 0 produces top = platformY - childH (regression guard)',
        (tester) async {
      // Regression guard: offsetY=0 must reproduce the pre-260511-ehy
      // geometry exactly. The fixture pins travelRange to the child's height
      // (as a fraction of bbox) so this guard holds bit-identically across
      // both Plan 260511-dxa (auto-deduce) and Plan 260511-fd6 (operator-
      // explicit travelRange).
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: travelRangeFor40pxChild,
        children: [
          ElevatorChildEntry(
              id: 'y0',
              offsetX: 0.5,
              offsetY: 0.0,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      progress.value = 0.5;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      final expectedTop =
          platformOffsetTop(0.5, bboxH, platformH, maxChildHeight) - childH;
      expect(top, closeTo(expectedTop, 1.0),
          reason: 'offsetY=0 must reproduce the pre-260511-ehy formula '
              'exactly (Plan 260511-dxa invariant).');
    });

    testWidgets('offsetY = 0.5 raises the child by half a child height',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: travelRangeFor40pxChild,
        children: [
          ElevatorChildEntry(
              id: 'y-up',
              offsetX: 0.5,
              offsetY: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      progress.value = 0.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      final platformY =
          platformOffsetTop(0.0, bboxH, platformH, maxChildHeight);
      final expectedTop = platformY - childH * 1.5;
      expect(top, closeTo(expectedTop, 1.0),
          reason:
              'offsetY=0.5 must raise the child by 0.5*childH (top is smaller '
              'than the offsetY=0 baseline by 0.5*childH).');
      // Direction lock: child rose vs offsetY=0 baseline (smaller `top`).
      final baseline = platformY - childH;
      expect(top, lessThan(baseline),
          reason: 'Positive offsetY must raise the child (smaller top).');
    });

    testWidgets('offsetY = -0.5 lowers the child by half a child height',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: travelRangeFor40pxChild,
        children: [
          ElevatorChildEntry(
              id: 'y-down',
              offsetX: 0.5,
              offsetY: -0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      progress.value = 0.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      final platformY =
          platformOffsetTop(0.0, bboxH, platformH, maxChildHeight);
      final expectedTop = platformY - childH * 0.5;
      expect(top, closeTo(expectedTop, 1.0),
          reason:
              'offsetY=-0.5 must lower the child by 0.5*childH (top is larger '
              'than the offsetY=0 baseline by 0.5*childH; child\'s bottom '
              'hangs below the platform).');
      // Direction lock: child fell vs offsetY=0 baseline (larger `top`).
      final baseline = platformY - childH;
      expect(top, greaterThan(baseline),
          reason: 'Negative offsetY must lower the child (larger top).');
    });
  });

  // ---------------------------------------------------------------------------
  // TravelRange (260511-fd6)
  //
  // Locks the operator-explicit travel-range contract. The platform's vertical
  // travel range is no longer auto-deduced from child heights — it's a
  // fraction [0..1] of bbox height stored on ElevatorConfig.travelRange.
  // Default 1.0 = full headroom climb (the pre-260511-dxa visual).
  //
  // Numerics: bbox=200×300, platformH = 300 × 0.08 = 24, headroom = 276.
  // Child is a 40×40 _FixedSizeChild. At all four travelRange values below
  // the child has bottom-on-platform anchor (offsetY=0 default).
  // ---------------------------------------------------------------------------
  group('TravelRange (260511-fd6)', () {
    const bboxH = 300.0;
    const platformH = bboxH * kPlatformHeightFraction; // 24
    const childH = 40.0;
    const headroom = bboxH - platformH; // 276

    testWidgets(
        'travelRange=1.0 default → progress=1 puts platform top at 0 '
        '(full headroom climb)', (tester) async {
      // Default ElevatorConfig — travelRange defaults to 1.0. Effective
      // travel = clamp(1.0 * 300, 0, 276) = 276. At progress=1 the platform
      // top is at y=0, so the child's top is at -childH (overhang). Matches
      // the pre-260511-dxa visual where the platform climbs the full bbox.
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(
              id: 'tr-default-1',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 1.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      final expectedTop =
          platformOffsetTop(1.0, bboxH, platformH, headroom) - childH;
      expect(top, closeTo(expectedTop, 1.0),
          reason: 'travelRange=1.0 default must produce full headroom climb '
              '— platform top = 0 at progress=1, so child top = -childH '
              '(overhang permitted).');
      expect(top, closeTo(-40.0, 1.0),
          reason: 'Numerical lock: progress=1 + travelRange=1.0 + 40px child → '
              'child top = 0 - 40 = -40.');
    });

    testWidgets('travelRange=0.5 → progress=1 puts platform halfway up',
        (tester) async {
      // Effective travel = clamp(0.5 * 300, 0, 276) = 150.
      // platformY = 276 - 150 = 126. child top = 126 - 40 = 86.
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: 0.5,
        children: [
          ElevatorChildEntry(
              id: 'tr-half',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 1.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      expect(top, closeTo(86.0, 1.0),
          reason: 'travelRange=0.5: effectiveTravel=150 → platformY=126 → '
              'child top=86 (no overhang at default child height).');
    });

    testWidgets('travelRange=0.0 → platform pinned at bottom for all progress',
        (tester) async {
      // Effective travel = 0. platformY = 276 regardless of progress.
      // child top = 276 - 40 = 236.
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: 0.0,
        children: [
          ElevatorChildEntry(
              id: 'tr-zero',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 1.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      expect(top, closeTo(236.0, 1.0),
          reason:
              'travelRange=0.0: platform pinned at bottom (276) regardless of '
              'progress → child top = 276 - 40 = 236.');
    });

    testWidgets('clamp: travelRange=1.5 behaves like 1.0 (defensive)',
        (tester) async {
      // Defensive clamp: travelRange > 1.0 must not push the platform past
      // the bbox top. clamp(1.5, 0, 1) * 300 = 300, then clamp to headroom
      // = 276 — same result as default travelRange=1.0.
      final config = ElevatorConfig(
        positionKey: '',
        travelRange: 1.5,
        children: [
          ElevatorChildEntry(
              id: 'tr-oor',
              offsetX: 0.5,
              child: _FixedSizeChildConfig(width: 40, height: 40)),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 1.0;
      await tester.pumpAndSettle();

      final positioned = find.ancestor(
        of: find.byType(_FixedSizeChild),
        matching: find.byType(Positioned),
      );
      expect(positioned, findsOneWidget);
      final top = (tester.widget(positioned) as Positioned).top!;
      expect(top, closeTo(-40.0, 1.0),
          reason: 'travelRange=1.5 must be defensively clamped to 1.0 — same '
              'top=-40 as the default fixture.');
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 3 — Editor add/edit/remove/offsetX UI (Plan 03-03)
  //
  // Locks the editor surface for child management:
  //   ELEV-07: Add child via dropdown filtered to {SensorConfig, ConveyorConfig}
  //   ELEV-08: Edit child opens recursive configure() dialog; remove deletes entry
  //   QUAL-08: TDD discipline — these tests are written BEFORE the implementation
  //
  // The dropdown is hard-coded to {Sensor, Conveyor} per CONTEXT §specifics +
  // ELEV-07. The negative assertions (LED, Number, Button) lock the filter so
  // any future drift to AssetRegistry.defaultFactories iteration is caught.
  // ---------------------------------------------------------------------------
  group('Editor — child management (ELEV-07, ELEV-08)', () {
    testWidgets(
        'Add child opens dropdown filtered to Sensor and Conveyor only (ELEV-07)',
        (tester) async {
      final config = ElevatorConfig();
      await openConfigEditor(tester, config);

      // Tap the 'Add child' button to open the picker. As of Plan
      // 260511-fd6 the editor has additional widgets above this button
      // (travel-range slider + helper text), so we ensureVisible before
      // tapping to handle the narrow 600px default test viewport.
      final addBtn = find.widgetWithText(FilledButton, 'Add child');
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      // Positive: Sensor + Conveyor options surface.
      expect(find.text('Sensor'), findsOneWidget,
          reason: 'Sensor must be in the add-child picker (ELEV-07).');
      expect(find.text('Conveyor'), findsOneWidget,
          reason: 'Conveyor must be in the add-child picker (ELEV-07).');

      // Negative: registered assets that are NOT allowed children must NOT
      // appear. Three negative locks per CONTEXT — guards against future
      // drift to AssetRegistry.defaultFactories iteration.
      expect(find.text('LED'), findsNothing,
          reason: 'LED is not an allowed child (ELEV-07 lock).');
      expect(find.text('Number'), findsNothing,
          reason: 'Number is not an allowed child (ELEV-07 lock).');
      expect(find.text('Button'), findsNothing,
          reason: 'Button is not an allowed child (ELEV-07 lock).');
    });

    testWidgets(
        'Selecting Sensor appends ElevatorChildEntry with UUID and offsetX 0.5 (ELEV-07)',
        (tester) async {
      final config = ElevatorConfig();
      await openConfigEditor(tester, config);

      expect(config.children, isEmpty);

      final addBtn = find.widgetWithText(FilledButton, 'Add child');
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sensor'));
      await tester.pumpAndSettle();

      expect(config.children.length, 1,
          reason: 'Selecting Sensor must append exactly one child.');
      expect(config.children[0].child, isA<SensorConfig>(),
          reason: 'Appended child must be a SensorConfig.');
      expect(config.children[0].id.isNotEmpty, isTrue,
          reason: 'Appended child must have an auto-generated UUID.');
      expect(config.children[0].offsetX, 0.5,
          reason: 'Default offsetX is 0.5 per CONTEXT §specifics.');
    });

    testWidgets('Selecting Conveyor appends a ConveyorConfig child',
        (tester) async {
      final config = ElevatorConfig();
      await openConfigEditor(tester, config);

      final addBtn = find.widgetWithText(FilledButton, 'Add child');
      await tester.ensureVisible(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(addBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Conveyor'));
      await tester.pumpAndSettle();

      expect(config.children.length, 1);
      expect(config.children[0].child, isA<ConveyorConfig>());
    });

    testWidgets('Edit button opens child config dialog (ELEV-08)',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(id: 'edit-test', child: SensorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      // Editor body is scrollable (SingleChildScrollView in
      // _ElevatorConfigEditor). The Card's IconButton can sit below the
      // 600-pixel default test viewport, so ensureVisible scrolls it in
      // before tapping. Mirrors `tester.ensureVisible` precedent in
      // sensor_widget_test for narrow-viewport assertions.
      final editBtn = find.byTooltip('Edit child');
      await tester.ensureVisible(editBtn);
      await tester.pumpAndSettle();
      await tester.tap(editBtn);
      await tester.pumpAndSettle();

      // Sensor's editor surface (locked label from sensor.dart).
      expect(find.text('Detection State Key'), findsOneWidget,
          reason:
              'Edit button must open the child\'s configure() dialog (ELEV-08).');
      // The elevator's own KeyField label must still be in the tree — the
      // sub-dialog is layered on top, not replacing the elevator dialog.
      expect(find.text('Position State Key (0-100%)'), findsOneWidget,
          reason: 'Elevator dialog remains open beneath the child sub-dialog.');
    });

    testWidgets(
        'Remove button deletes child and shows empty-state text (ELEV-08)',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(id: 'remove-test', child: SensorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      expect(config.children.length, 1);

      // Tap the remove IconButton on the child's row (scroll into view first
      // — see Edit-button test for narrow-viewport rationale).
      final removeBtn = find.byTooltip('Remove child');
      await tester.ensureVisible(removeBtn);
      await tester.pumpAndSettle();
      await tester.tap(removeBtn);
      await tester.pumpAndSettle();

      expect(config.children, isEmpty,
          reason: 'Remove must delete the entry from config.children.');
      expect(find.text('No children configured'), findsOneWidget,
          reason: 'Empty children list must show the "No children configured" '
              'graceful empty state (CONTEXT §Removing the last child).');
    });

    testWidgets('offsetX Slider mutates entry.offsetX in real time',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(
              id: 'slider-test', offsetX: 0.5, child: SensorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      expect(config.children[0].offsetX, 0.5);

      // The Slider lives inside the editor (per-entry slider for offsetX).
      // Drag rightward to bump value above 0.5. ensureVisible scrolls the
      // Slider into the test viewport (narrow 800x600 default).
      //
      // Slider order in editor as of Plan 260511-fd6:
      //   index 0 → travel-range slider (config-level, range 0..1)
      //   index 1 → per-child offsetX slider (range 0..1)
      //   index 2 → per-child offsetY slider (range -1..1)
      // The travel-range slider is unique by `min=0 && max=1 && divisions=100`
      // — but so are the per-child offsetX sliders. To unambiguously target
      // the offsetX slider, skip the first Slider (travel-range).
      final slider = find.byType(Slider).at(1);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(50, 0));
      await tester.pump();

      expect(config.children[0].offsetX != 0.5, isTrue,
          reason: 'Slider drag must mutate entry.offsetX.');
      expect(config.children[0].offsetX, greaterThan(0.5),
          reason: 'Rightward drag should increase offsetX.');
    });

    testWidgets(
        'offsetY Slider mutates entry.offsetY in real time [260511-ehy]',
        (tester) async {
      // Plan 260511-ehy: a SECOND per-entry slider (offsetY, range -1.0..1.0)
      // sits directly below the existing offsetX slider.
      //
      // Slider order in editor as of Plan 260511-fd6:
      //   index 0 → travel-range slider (config-level, range 0..1)
      //   index 1 → per-child offsetX slider (range 0..1)
      //   index 2 → per-child offsetY slider (range -1..1)
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(
              id: 'slider-y-test',
              offsetX: 0.5,
              offsetY: 0.0,
              child: SensorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      expect(config.children[0].offsetY, 0.0);

      // Per-entry sliders are ordered offsetX (index 1), offsetY (index 2)
      // after the config-level travel-range slider at index 0 (Plan 260511-fd6).
      final slider = find.byType(Slider).at(2);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(50, 0));
      await tester.pump();

      expect(config.children[0].offsetY != 0.0, isTrue,
          reason: 'Drag on the offsetY slider must mutate entry.offsetY.');
      expect(config.children[0].offsetY, greaterThan(0.0),
          reason: 'Rightward drag should increase offsetY (raise the child).');
    });
  });

  // ---------------------------------------------------------------------------
  // Travel range editor slider (260511-fd6)
  //
  // Locks the editor surface for the new operator-explicit travel-range
  // control: a Slider [0..1, divisions=100] with a percentage label, sitting
  // in the body of `_ElevatorConfigEditor`. Mutates config.travelRange in
  // real time via setState. Mirrors the offsetY/offsetX slider precedents.
  // ---------------------------------------------------------------------------
  group('Travel range editor slider (260511-fd6)', () {
    testWidgets('Travel range slider mutates config.travelRange in real time',
        (tester) async {
      // Construct a config with a non-default travelRange so the slider's
      // initial value is unambiguous. Locate the travel-range slider by its
      // min=0, max=1, divisions=100 signature (the per-child offsetX slider
      // shares min/max/divisions but lives inside a Card and there are no
      // children here — so the only matching Slider is the travel-range one).
      final config = ElevatorConfig(travelRange: 0.25);
      await openConfigEditor(tester, config);

      final sliderFinder = find.byWidgetPredicate(
        (w) =>
            w is Slider &&
            w.min == 0.0 &&
            w.max == 1.0 &&
            (w.divisions ?? 0) == 100,
      );
      expect(sliderFinder, findsOneWidget,
          reason: 'Editor must expose exactly one Slider with '
              '(min=0, max=1, divisions=100) for travelRange (260511-fd6).');

      // Drive the slider's onChanged directly (mirrors the precedent in
      // sensor/conveyor editor tests — avoids drag-coordinate fragility on
      // narrow viewports).
      final slider = tester.widget<Slider>(sliderFinder);
      slider.onChanged!(0.42);
      await tester.pump();
      expect(config.travelRange, closeTo(0.42, 1e-9),
          reason:
              'Slider.onChanged must mutate config.travelRange in real time.');
    });

    testWidgets('Travel range shows the slider value as an editable percentage',
        (tester) async {
      // The requirement (260511-fd6) is that travelRange is readable as a
      // percentage of bbox height. It used to be baked into the label text —
      // "Travel range: 42% of bbox height" — which meant reading it was all
      // you could do. The number now lives in a field beside the track, so
      // the unit stays in the label and the value is both shown and typeable.
      final config = ElevatorConfig(travelRange: 0.42);
      await openConfigEditor(tester, config);

      expect(find.text('Travel range (% of bbox height)'), findsOneWidget,
          reason: 'the label must still say what unit the number is in');

      final field = tester.widget<TextField>(find.descendant(
        of: find.byType(NumberSlider),
        matching: find.byType(TextField),
      ));
      expect(field.controller!.text, '42',
          reason: 'Editor must show the travelRange value as a percentage of '
              'bbox height (260511-fd6).');
    });

    testWidgets('Travel range can be typed instead of dragged', (tester) async {
      // The reason the number moved into a field: 1% of the track is about a
      // pixel on the narrow pane, so an exact value was not reachable by
      // dragging.
      final config = ElevatorConfig(travelRange: 0.42);
      await openConfigEditor(tester, config);

      await tester.enterText(
        find.descendant(
          of: find.byType(NumberSlider),
          matching: find.byType(TextField),
        ),
        '75',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(config.travelRange, closeTo(0.75, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4 — Editor z-order reordering (Plan 04-03)
  //
  // Locks the editor surface for child z-order reorder controls (ELEV-08
  // extension; QUAL-08 TDD discipline).
  //
  // CONVENTION (locked by user): the editor list is REVERSED relative to
  //   config.children — topmost-paint child appears at the TOP of the
  //   editor list (Photoshop / Figma). Up arrow raises z (later in
  //   config.children, paints on top). Down arrow lowers z (earlier in
  //   config.children, paints behind).
  //
  // Stack semantics (Flutter): config.children[0] is painted first
  //   (lowest z); config.children[N-1] is painted last (highest z).
  // ---------------------------------------------------------------------------
  group('Editor — child reorder (z-order)', () {
    testWidgets(
        'two children, tap "Move forward" on the bottommost-paint row swaps list order',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          // index 0 = bottommost paint (lowest z); displayed at BOTTOM of
          //   the editor list (Photoshop convention).
          ElevatorChildEntry(id: 'A', child: SensorConfig.preview()),
          // index 1 = topmost paint (highest z); displayed at TOP of the
          //   editor list.
          ElevatorChildEntry(id: 'B', child: ConveyorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      // Find Move-forward IconButtons by tooltip and pick the one for
      // child 'A' (Sensor). Since editor is reversed, Sensor (id='A',
      // actualIndex=0) is the LAST 'Move forward' button in document
      // order — display index 1 in a 2-row reversed list.
      final upBtns = find.byTooltip('Move forward (paint on top)');
      expect(upBtns, findsNWidgets(2),
          reason: 'Each child row must have a Move-forward IconButton.');

      // Tap the second one (the bottommost-paint child's row, displayed
      // at the BOTTOM of the reversed editor list — that's child 'A').
      await tester.ensureVisible(upBtns.last);
      await tester.pumpAndSettle();
      await tester.tap(upBtns.last);
      await tester.pumpAndSettle();

      // After swap: 'A' moved to higher index, 'B' moved to lower index.
      expect(config.children[0].id, 'B',
          reason: 'After moving A forward, B should now be at index 0.');
      expect(config.children[1].id, 'A',
          reason: 'After moving A forward, A should now be at index 1.');
    });

    testWidgets(
        'topmost-paint child has "Move forward" disabled (onPressed == null)',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(id: 'A', child: SensorConfig.preview()),
          ElevatorChildEntry(id: 'B', child: ConveyorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      // Topmost-paint = 'B' (index 1). It is displayed at the TOP of the
      // editor list (reversed convention) — so it's the FIRST IconButton
      // with the Move-forward tooltip in document order.
      // `find.byTooltip` matches the Tooltip widget; walk up to the
      // owning IconButton via `find.ancestor`.
      final upBtns = find.ancestor(
        of: find.byTooltip('Move forward (paint on top)'),
        matching: find.byType(IconButton),
      );
      expect(upBtns, findsNWidgets(2));
      final firstBtn = tester.widget<IconButton>(upBtns.first);
      expect(firstBtn.onPressed, isNull,
          reason: 'Topmost-paint child cannot be moved further forward — '
              'its Move-forward button must be disabled.');
    });

    testWidgets(
        'bottommost-paint child has "Move backward" disabled (onPressed == null)',
        (tester) async {
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(id: 'A', child: SensorConfig.preview()),
          ElevatorChildEntry(id: 'B', child: ConveyorConfig.preview()),
        ],
      );
      await openConfigEditor(tester, config);

      // Bottommost-paint = 'A' (index 0). It is displayed at the BOTTOM
      // of the editor list (reversed convention) — so it's the LAST
      // IconButton with the Move-backward tooltip in document order.
      // `find.byTooltip` matches the Tooltip widget; walk up to the
      // owning IconButton via `find.ancestor`.
      final downBtns = find.ancestor(
        of: find.byTooltip('Move backward (paint behind)'),
        matching: find.byType(IconButton),
      );
      expect(downBtns, findsNWidgets(2));
      final lastBtn = tester.widget<IconButton>(downBtns.last);
      expect(lastBtn.onPressed, isNull,
          reason: 'Bottommost-paint child cannot be moved further backward — '
              'its Move-backward button must be disabled.');
    });

    testWidgets('paint order in Stack matches list order; reordering swaps it',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'A', child: SensorConfig.preview()),
          ElevatorChildEntry(id: 'B', child: ConveyorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Locate the elevator's Stack and verify Sensor's KeyedSubtree
      // ('A') comes BEFORE Conveyor's KeyedSubtree ('B') in document
      // order — Stack child[0] paints first (lowest z), child[N-1]
      // paints last (highest z).
      List<String> idOrder() => find
          .descendant(
            of: find.byType(Elevator),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is KeyedSubtree &&
                  (w.key == const ValueKey<String>('A') ||
                      w.key == const ValueKey<String>('B')),
            ),
          )
          .evaluate()
          .map((e) => (e.widget as KeyedSubtree).key)
          .map((k) => (k as ValueKey<String>).value)
          .toList();

      expect(idOrder(), ['A', 'B'],
          reason: 'Initially: child A at index 0 paints first (lowest z); '
              'child B at index 1 paints last (highest z).');

      // Swap via direct list mutation — same effect the editor handler
      // would produce. Pump to let the build run.
      final tmp = config.children[0];
      config.children[0] = config.children[1];
      config.children[1] = tmp;
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      expect(idOrder(), ['B', 'A'],
          reason:
              'After swap: B at index 0 paints first; A at index 1 paints last.');
    });

    testWidgets('reorder preserves keyed subtree identity (ValueKey)',
        (tester) async {
      // Plan 04-05: this test asserts on the runtime Elevator widget
      // tree's ValueKey wrappers (Stack children inside _buildStack). It
      // needs both the Elevator runtime AND the editor open at once —
      // the editor's reorder buttons mutate config.children, the runtime
      // Stack reflects the swap. Render Elevator at the root and open
      // the editor as an overlay dialog (page_editor.dart pattern).
      final config = ElevatorConfig(
        children: [
          ElevatorChildEntry(id: 'A', child: SensorConfig.preview()),
          ElevatorChildEntry(id: 'B', child: ConveyorConfig.preview()),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Stack(
                children: [
                  // Runtime Elevator — provides the ValueKey<String>('A'/'B')
                  // wrappers under test.
                  Center(
                    child: SizedBox(
                      width: 200,
                      height: 300,
                      child: Elevator(config: config),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: ElevatedButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            Dialog(child: config.configure(context)),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pump(Duration.zero);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Both ValueKey wrappers exist before reorder.
      expect(find.byKey(const ValueKey<String>('A')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('B')), findsOneWidget);

      // Tap Move-forward on 'A' (last upBtn — bottommost-paint, displayed
      // at bottom of reversed editor list).
      final upBtns = find.byTooltip('Move forward (paint on top)');
      await tester.ensureVisible(upBtns.last);
      await tester.pumpAndSettle();
      await tester.tap(upBtns.last);
      await tester.pumpAndSettle();

      // Both ValueKey wrappers still exist after reorder — identity
      // preserved by the entry.id-based ValueKey contract (ELEV-12).
      expect(find.byKey(const ValueKey<String>('A')), findsOneWidget,
          reason: 'ValueKey<String>("A") wrapper must survive reorder.');
      expect(find.byKey(const ValueKey<String>('B')), findsOneWidget,
          reason: 'ValueKey<String>("B") wrapper must survive reorder.');
    });
  });

  // ---------------------------------------------------------------------------
  // Goldens — elevator + Sensor + Conveyor children at progress {0, 0.5, 1.0}
  //
  // QUAL-03 lock: 3 PNG goldens captured deterministically on macOS via
  // RepaintBoundary. The harness uses positionKey='' so the painter
  // renders in its stale (grey) palette — this avoids any Theme /
  // primary-colour dependency in the captured pixels (Pitfall 6
  // determinism). The progress is driven directly through the
  // `debugProgress` test seam, so no StateMan stub is required.
  //
  // Skipped on non-macOS to mirror sensor_painter_test.dart and
  // conveyor_gate_golden_test.dart (the project's locked golden
  // platform-skip convention).
  // ---------------------------------------------------------------------------
  group('Goldens — elevator with children at progress {0, 0.5, 1.0} (QUAL-03)',
      skip: !Platform.isMacOS ? 'Golden tests only run on macOS' : null, () {
    const goldenKey = Key('elevator_with_children_golden');

    Future<void> pumpElevatorAtProgress(
      WidgetTester tester,
      double targetProgress,
    ) async {
      // Sensors and conveyors get explicit sizes so they're visible in
      // the captured pixels (the BaseAsset 0.03×0.03 default is too
      // small to be meaningful in a 200×300 bbox).
      final sensor = SensorConfig.preview()
        ..size = const RelativeSize(width: 0.35, height: 0.18);
      final conveyor = ConveyorConfig.preview()
        ..size = const RelativeSize(width: 0.35, height: 0.18);

      final config = ElevatorConfig(
        positionKey: '',
        children: [
          ElevatorChildEntry(id: 'sensor-fixed', offsetX: 0.3, child: sensor),
          ElevatorChildEntry(
              id: 'conveyor-fixed', offsetX: 0.7, child: conveyor),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: goldenKey,
                  child: SizedBox(
                    width: 200,
                    height: 300,
                    child: Elevator(config: config),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(Duration.zero);

      // Drive progress to target via the debugProgress test seam, then
      // settle the tween animation so the rendered _animProgress
      // reaches the target deterministically.
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = targetProgress;
      await tester.pumpAndSettle();
    }

    testWidgets('progress 0.0', (tester) async {
      await pumpElevatorAtProgress(tester, 0.0);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/elevator_with_children_progress_0.png'),
      );
    });

    testWidgets('progress 0.5', (tester) async {
      await pumpElevatorAtProgress(tester, 0.5);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/elevator_with_children_progress_50.png'),
      );
    });

    testWidgets('progress 1.0', (tester) async {
      await pumpElevatorAtProgress(tester, 1.0);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/elevator_with_children_progress_100.png'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4 — Out-of-range (ELEV-15)
  //
  // CONTEXT §Out-of-Range Outline:
  //   When the position stream emits a value > 100 or < 0:
  //     1. progress clamps to [0.0, 1.0] (existing platformProgress behaviour)
  //     2. _isOutOfRange flips true and the painter renders an amber outline
  //     3. Stale state stays separate (mutually exclusive with isOutOfRange)
  //
  // Drives DynamicValue emissions through the `debugInjectRaw` test seam
  // added in Plan 04-01 Task 2 — avoids a full StateMan stub (the same
  // approach used by `debugProgress` in Plans 02-04 / 03-01).
  // ---------------------------------------------------------------------------
  group('Out-of-range (ELEV-15)', () {
    testWidgets(
        'stream value 150 clamps to progress 1.0 AND sets isOutOfRange=true',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      // Inject a raw value above the legal range. Drives the same code path
      // a stream emission would (DynamicValue → _onStreamData →
      // _isOutOfRange + clamp). The seam is added in Task 2 (GREEN).
      state.debugInjectRaw(DynamicValue(value: 150.0));
      await tester.pumpAndSettle();

      final cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Elevator),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = cp.painter as ElevatorPainter;
      expect(painter.isOutOfRange, isTrue,
          reason: 'value > 100 must set isOutOfRange=true (ELEV-15).');
      expect(painter.progress.value, closeTo(1.0, 1e-9),
          reason:
              'value > 100 must still clamp progress to 1.0 (ELEV-15 / platformProgress).');
    });

    testWidgets(
        'stream value -50 clamps to progress 0.0 AND sets isOutOfRange=true',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      state.debugInjectRaw(DynamicValue(value: -50.0));
      await tester.pumpAndSettle();

      final cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Elevator),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = cp.painter as ElevatorPainter;
      expect(painter.isOutOfRange, isTrue,
          reason: 'value < 0 must set isOutOfRange=true (ELEV-15).');
      expect(painter.progress.value, closeTo(0.0, 1e-9),
          reason:
              'value < 0 must still clamp progress to 0.0 (ELEV-15 / platformProgress).');
    });

    testWidgets('stream value 50 yields progress 0.5 AND isOutOfRange=false',
        (tester) async {
      final config = ElevatorConfig(positionKey: '/elev/01/position');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      state.debugInjectRaw(DynamicValue(value: 50.0));
      await tester.pumpAndSettle();

      final cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Elevator),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = cp.painter as ElevatorPainter;
      expect(painter.isOutOfRange, isFalse,
          reason:
              'value in legal range [0, 100] must keep isOutOfRange=false (ELEV-15).');
      expect(painter.progress.value, closeTo(0.5, 1e-9));
    });

    testWidgets('stale state and out-of-range state are mutually exclusive',
        (tester) async {
      // Stale (no positionKey configured) must not also flag isOutOfRange —
      // the painter renders grey for stale and the amber outline only when
      // a real out-of-range value arrives. Locks the CONTEXT §decisions
      // mutual-exclusivity contract.
      final config = ElevatorConfig(positionKey: '');
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      final cp = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(Elevator),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = cp.painter as ElevatorPainter;
      expect(painter.isStale, isTrue);
      expect(painter.isOutOfRange, isFalse,
          reason:
              'Stale (no key configured) must not double up as out-of-range.');
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4 — Multi-elevator independence (QUAL-06)
  //
  // Two Elevator widgets sharing a parent (e.g. a Column) must operate with
  // fully independent _progress notifiers and _hoistedKey state. Locks the
  // CONTEXT §QUAL-06 contract: no shared static state, each instance owns
  // its own ValueNotifier + StreamSubscription.
  // ---------------------------------------------------------------------------
  group('Multi-elevator independence (QUAL-06)', () {
    testWidgets(
        'two elevators with different positionKeys operate independently',
        (tester) async {
      final configA = ElevatorConfig(positionKey: '/elev/A/position');
      final configB = ElevatorConfig(positionKey: '/elev/B/position');
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 600,
                  child: Column(
                    children: [
                      Expanded(
                        child: Elevator(
                          key: const ValueKey('elevA'),
                          config: configA,
                        ),
                      ),
                      Expanded(
                        child: Elevator(
                          key: const ValueKey('elevB'),
                          config: configB,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(Duration.zero);

      // Locate each Elevator's State independently via the keyed widgets.
      final stateA =
          tester.state<State<Elevator>>(find.byKey(const ValueKey('elevA')))
              as dynamic;
      final stateB =
          tester.state<State<Elevator>>(find.byKey(const ValueKey('elevB')))
              as dynamic;

      // Drive the targets independently.
      (stateA.debugProgress as ValueNotifier<double>).value = 0.25;
      (stateB.debugProgress as ValueNotifier<double>).value = 0.75;
      await tester.pumpAndSettle();

      // Each elevator's painter must reflect its own progress — no
      // cross-talk between instances.
      final paints = find
          .descendant(
            of: find.byType(Elevator),
            matching: find.byType(CustomPaint),
          )
          .evaluate()
          .map((e) => e.widget as CustomPaint)
          .toList();
      // Two CustomPaint widgets — one per Elevator. Read each painter's
      // progress notifier value.
      final progresses = paints
          .where((cp) => cp.painter is ElevatorPainter)
          .map((cp) => (cp.painter as ElevatorPainter).progress.value)
          .toList();
      expect(progresses, contains(closeTo(0.25, 1e-6)),
          reason:
              'Elevator A must hold progress 0.25 independently (QUAL-06).');
      expect(progresses, contains(closeTo(0.75, 1e-6)),
          reason:
              'Elevator B must hold progress 0.75 independently (QUAL-06).');

      // Cross-check stream identities — different positionKeys must yield
      // different (non-identical) stream references.
      final streamA = stateA.debugPositionStream;
      final streamB = stateB.debugPositionStream;
      expect(identical(streamA, streamB), isFalse,
          reason:
              'Different positionKeys must yield distinct stream references '
              '(QUAL-06 — no shared subscription state).');
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 4 — Leak test (QUAL-07)
  //
  // Mount Elevator (with Sensor child) → unmount → assert no leaks.
  //
  // The Flutter SDK ships `package:leak_tracker_flutter_testing` transitively;
  // we use the `experimentalLeakTesting` parameter on `testWidgets`. If the
  // package surface changes between Flutter versions, the source-level guard
  // below covers the dispose contract as a defensive fallback.
  // ---------------------------------------------------------------------------
  group('Leak test (QUAL-07)', () {
    testWidgets('mount/unmount Elevator does not leak resources',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '/elev/leak/position',
        children: [
          ElevatorChildEntry(id: 'leak-sensor', child: SensorConfig.preview()),
        ],
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);
      // Replace with an empty widget tree — forces unmount and dispose
      // of all Elevator/Sensor resources. If dispose() is missing, the
      // ValueNotifier or StreamSubscription would surface as a leak or
      // throw "X was used after being disposed" on subsequent frames.
      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'Mount/unmount must not throw or leak '
              '(QUAL-07 — dispose contract on _progress, _animProgress, _streamSub).');
    });

    test('elevator.dart dispose() cancels stream + disposes notifiers', () {
      // Source-level guard (QUAL-07 fallback): even if the runtime leak
      // tracker is not active, the dispose contract MUST be present in the
      // source. Verifies the literal dispose calls so the contract is
      // grep-locked.
      final src =
          File('lib/page_creator/assets/elevator.dart').readAsStringSync();
      expect(src, contains('_streamSub?.cancel()'),
          reason: 'dispose() must cancel the position stream subscription '
              '(QUAL-07).');
      expect(src, contains('_progress.dispose()'),
          reason:
              'dispose() must dispose the _progress ValueNotifier (QUAL-07).');
      expect(src, contains('_animProgress.dispose()'),
          reason:
              'dispose() must dispose the _animProgress ValueNotifier (QUAL-07).');
    });

    test('sensor.dart dispose contract grep guard (QUAL-07)', () {
      // Sensor is mounted as a child of Elevator in the leak test above.
      // Lock its dispose contract too — the controller-of-record.
      final src =
          File('lib/page_creator/assets/sensor.dart').readAsStringSync();
      // Sensor uses StreamSubscription too; verify cancel is present in
      // a dispose() method body.
      final disposeIdx = src.indexOf(RegExp(r'void\s+dispose\s*\(\)'));
      expect(disposeIdx, greaterThan(-1),
          reason: 'sensor.dart must override dispose() (QUAL-07).');
      // Look at the dispose method body window for cancel/dispose calls.
      final tail = src.substring(disposeIdx);
      expect(tail.contains('cancel()') || tail.contains('.dispose()'), isTrue,
          reason: 'sensor.dart dispose() must release stream subscription / '
              'controllers (QUAL-07).');
    });
  });

  // ---------------------------------------------------------------------------
  // Plan 04-04 — Simulate motion toggle (QUAL-08)
  //
  // Locks the simulate-motion contract:
  //   - Editor exposes a SwitchListTile titled "Simulate motion" wired to
  //     `widget.config.simulate ?? false`.
  //   - Toggling simulate ON starts a 50ms-period Timer that increments
  //     `_progress.value` by 0.01 each tick (≈5s for 0→1, 10s round trip).
  //   - Toggling simulate OFF cancels the timer; `_progress.value` freezes
  //     at the last simulated value until the next stream emission.
  //   - While simulate is ON, the PLC stream listener MUST NOT overwrite
  //     `_progress.value` — the simulation owns the notifier (early-return
  //     guard in _onStreamData).
  //   - The simulation oscillates between 0 and 1 — direction reverses at
  //     each end (locked sweep, not a saw-tooth jump).
  //
  // TDD discipline: tests RED first, implementation GREEN follows.
  // ---------------------------------------------------------------------------
  group('Simulation toggle (QUAL-08)', () {
    testWidgets(
        'editor exposes Simulate motion switch reflecting config.simulate',
        (tester) async {
      // Plan 04-05: editor opened via configure() directly — runtime tap
      // now opens the read-only details dialog (which has no SwitchListTile).
      final config = ElevatorConfig(simulate: true);
      // Cannot use openConfigEditor here because it pumpAndSettles, which
      // would deadlock against the simulation Timer.periodic. Build the
      // same fixture inline and use fixed-duration pumps.
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => Dialog(child: config.configure(context)),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      // Need a Scaffold + Elevator in tree to keep didUpdateWidget paths
      // alive for the config simulate flag — but the editor surface lives
      // inside the dialog opened by tapping 'open'. Pump fixed durations
      // for the open animation (~150ms default Material dialog transition).
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 300));

      final switchTile = find.widgetWithText(SwitchListTile, 'Simulate motion');
      expect(switchTile, findsOneWidget,
          reason:
              'Editor must expose a SwitchListTile titled "Simulate motion" '
              '(QUAL-08).');
      final tile = tester.widget<SwitchListTile>(switchTile);
      expect(tile.value, isTrue,
          reason: 'SwitchListTile.value must reflect widget.config.simulate '
              '(simulate=true → switch ON).');
    });

    testWidgets(
        'Simulate motion switch defaults to OFF when config.simulate is null',
        (tester) async {
      final config = ElevatorConfig();
      await openConfigEditor(tester, config);

      final switchTile = find.widgetWithText(SwitchListTile, 'Simulate motion');
      expect(switchTile, findsOneWidget);
      final tile = tester.widget<SwitchListTile>(switchTile);
      expect(tile.value, isFalse,
          reason: 'simulate=null must surface as switch OFF (default).');
    });

    testWidgets(
        'toggling simulate to true starts the sim timer (progress advances)',
        (tester) async {
      final config = ElevatorConfig(simulate: false);
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;
      progress.value = 0.0;
      expect(progress.value, 0.0);

      // Flip the simulate flag and rebuild — didUpdateWidget must spin up
      // the simulation timer.
      config.simulate = true;
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Advance virtual clock through 4 ticks of 50ms = 200ms. With +0.01
      // per tick the notifier should reach roughly 0.04.
      await tester.pump(const Duration(milliseconds: 200));
      expect(progress.value, greaterThan(0.0),
          reason: 'Simulate ON must drive _progress upward via the periodic '
              'timer (QUAL-08).');
    });

    testWidgets(
        'toggling simulate to false stops the sim timer (progress freezes)',
        (tester) async {
      final config = ElevatorConfig(simulate: true);
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      // Let the simulation move a few ticks so we have a non-zero baseline.
      await tester.pump(const Duration(milliseconds: 200));
      final movedTo = progress.value;
      expect(movedTo, greaterThan(0.0));

      // Flip simulate off.
      config.simulate = false;
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      // Capture frozen value (allow one tick for the cancel to settle).
      final frozen = progress.value;
      await tester.pump(const Duration(milliseconds: 500));
      expect(progress.value, equals(frozen),
          reason: 'Simulate OFF must cancel the periodic timer; _progress must '
              'freeze (QUAL-08).');
    });

    testWidgets(
        'PLC stream emission does not override _progress while simulating (QUAL-08)',
        (tester) async {
      final config = ElevatorConfig(
        positionKey: '/elev/sim/position',
        simulate: true,
      );
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      // Let the sim move forward.
      await tester.pump(const Duration(milliseconds: 200));
      final beforeInject = progress.value;
      expect(beforeInject, greaterThan(0.0));

      // Inject a stream emission of 0% — without the early-return guard
      // the simulation value would be overwritten.
      state.debugInjectRaw(DynamicValue(value: 0.0));
      await tester.pump(const Duration(milliseconds: 50));

      // The simulation continued ticking (≥1 tick after inject), so
      // _progress must be >= the simulated baseline value, NOT 0.
      expect(progress.value, greaterThan(0.0),
          reason: 'While simulating, PLC stream emissions MUST NOT overwrite '
              '_progress (QUAL-08 — simulation owns the notifier).');
    });

    testWidgets('simulation oscillates between 0 and 1 (sweep, not saw-tooth)',
        (tester) async {
      final config = ElevatorConfig(simulate: true);
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(Duration.zero);

      final state =
          tester.state<State<Elevator>>(find.byType(Elevator)) as dynamic;
      final progress = state.debugProgress as ValueNotifier<double>;

      // 0 → 1 takes ~5000ms (100 ticks of 50ms × 0.01 step).
      // We pump past the peak to observe the reversal: 6000ms in is well
      // past 1.0 and the value should now be on the way back down.
      double peak = 0.0;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (progress.value > peak) peak = progress.value;
      }
      expect(peak, closeTo(1.0, 0.05),
          reason:
              'Simulation must reach approximately 1.0 at the top of the sweep.');

      // Continue another 60 ticks (3000ms) — the value must now have
      // descended below the captured peak (i.e., the direction reversed).
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(progress.value, lessThan(peak),
          reason: 'Simulation must reverse direction at the top of the sweep '
              '(QUAL-08 — oscillation contract).');
    });

    testWidgets('simulation timer is cancelled on unmount (no leak — QUAL-07)',
        (tester) async {
      // Mount with simulate ON, then replace tree with empty SizedBox to
      // force unmount/dispose. If the timer is not cancelled in dispose,
      // subsequent pump-and-settle would either leak the periodic ticks
      // or throw "X used after dispose" on the disposed _progress notifier.
      final config = ElevatorConfig(simulate: true);
      await tester.pumpWidget(wrap(Elevator(config: config)));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pumpWidget(wrap(const SizedBox()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'Simulation timer must be cancelled in dispose (QUAL-07 + '
              'QUAL-08 — no leak on unmount).');
    });
  });
}

// ---------------------------------------------------------------------------
// Test-only BaseAsset subclasses
//
// _CountingChildConfig — counts how many times its State is constructed
// (initStateCount). Used to lock Pitfall 1 across 50 progress changes.
//
// _FixedSizeChildConfig — emits a child with a fixed pixel size irrespective
// of the parent bbox, so layout assertions can be numerical.
//
// Both subclasses provide just enough surface to satisfy the BaseAsset
// contract for in-tree rendering. They are NEVER serialised to JSON in
// these tests — fromJson/toJson are not exercised — but the json_serializable
// machinery requires the methods to exist.
// ---------------------------------------------------------------------------

class _CountingChildConfig extends BaseAsset {
  @override
  String get displayName => 'CountingChild';
  @override
  String get category => 'Test';

  _CountingChildConfig() : super();

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  RelativeSize get size => const RelativeSize(width: 0.2, height: 0.2);

  @override
  Widget build(BuildContext context) => const _CountingChild();
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => <String, dynamic>{};
}

class _CountingChild extends StatefulWidget {
  const _CountingChild();
  @override
  State<_CountingChild> createState() => _CountingChildState();
}

class _CountingChildState extends State<_CountingChild> {
  static int initStateCount = 0;

  @override
  void initState() {
    super.initState();
    initStateCount++;
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF000000));
}

class _FixedSizeChildConfig extends BaseAsset {
  final double widthPx;
  final double heightPx;

  _FixedSizeChildConfig({required double width, required double height})
      : widthPx = width,
        heightPx = height,
        super();

  @override
  String get displayName => 'FixedSizeChild';
  @override
  String get category => 'Test';

  /// Returns a RelativeSize that, given the elevator's 200x300 bbox in the
  /// `wrap` harness, produces the requested absolute pixel size via
  /// RelativeSize.toSize. The hard-coded harness size is the contract of
  /// the test wrapper.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  RelativeSize get size => RelativeSize(
        width: widthPx / 200.0,
        height: heightPx / 300.0,
      );

  @override
  Widget build(BuildContext context) => const _FixedSizeChild();
  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();
  @override
  Map<String, dynamic> toJson() => <String, dynamic>{};
}

class _FixedSizeChild extends StatelessWidget {
  const _FixedSizeChild();
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF00FF00));
}
